// Command httpclient drives spikes/http/server.exe: it opens one WebSocket
// view per pane over the unix socket, reads them, stalls some readers and
// measures throughput, skips and echo latency. "sockbuf" measures macOS unix
// stream socket buffers.
package main

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/coder/websocket"
)

type viewStats struct {
	bytes, snapshots, skipped, gaps atomic.Int64
}

var rcvbufReadBack atomic.Int64

type stats struct {
	Now        float64 `json:"now"`
	User       float64 `json:"user"`
	Sys        float64 `json:"sys"`
	MinorWords float64 `json:"minor_words"`
	Records    int64   `json:"records"`
	Bytes      int64   `json:"bytes"`
	Skips      int64   `json:"skips"`
	Lapped     int64   `json:"lapped"`
	Pins       int64   `json:"pins"`
	PinMs      [3]int  `json:"pin_ms"`
	WStalls    int64   `json:"writer_stalls"`
	WStallMs   [3]int  `json:"writer_stall_ms"`
	STicks     int64   `json:"stalled_ticks"`
	Blocks     int64   `json:"blocks"`
	Copied     int64   `json:"copied"`
	Accepted   int64   `json:"accepted"`
	Refused    int64   `json:"refused"`
	Sndbuf     int64   `json:"sndbuf"`
	Rcvbuf     int64   `json:"rcvbuf"`
	WSchedule  float64 `json:"words_schedule"`
	WIovecs    float64 `json:"words_iovecs"`
	WTryWrite  float64 `json:"words_try_write"`
	Writes     int64   `json:"writes"`
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "sockbuf" {
		sockbuf()
		return
	}
	socket := flag.String("socket", "", "server socket")
	views := flag.Int("views", 50, "views, one per pane; pane 0 is quiet")
	stall := flag.Int("stall", 10, "views 1..stall stall their reader")
	stallMs := flag.Int("stall-ms", 300, "stall length")
	periodMs := flag.Int("period-ms", 1000, "stall period")
	rcvbuf := flag.Int("rcvbuf", 1<<20, "SO_RCVBUF on each view, 0 to keep the default")
	warm := flag.Duration("warm", 2*time.Second, "warm-up")
	duration := flag.Duration("duration", 10*time.Second, "measured time")
	echoEvery := flag.Duration("echo", 20*time.Millisecond, "echo interval")
	flag.Parse()

	httpc := &http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{
		MaxIdleConnsPerHost: 2,
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			c, err := (&net.Dialer{}).DialContext(ctx, "unix", *socket)
			if err != nil {
				return nil, err
			}
			if *rcvbuf > 0 {
				if err := c.(*net.UnixConn).SetReadBuffer(*rcvbuf); err != nil {
					return nil, err
				}
			}
			raw, _ := c.(*net.UnixConn).SyscallConn()
			_ = raw.Control(func(fd uintptr) {
				v, _ := syscall.GetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_RCVBUF)
				rcvbufReadBack.Store(int64(v))
			})
			return c, nil
		},
	}}
	ctx, cancel := context.WithTimeout(context.Background(), *warm+*duration+30*time.Second)
	defer cancel()

	vs := make([]*viewStats, *views)
	conns := make([]*websocket.Conn, *views)
	var mu sync.Mutex
	sent := map[string]time.Time{}
	lat := map[bool][]float64{}
	var measuring atomic.Bool
	for i := range *views {
		dctx, dcancel := context.WithTimeout(ctx, 5*time.Second)
		c, _, err := websocket.Dial(dctx, fmt.Sprintf("ws://ko/panes/pane_%d/view", i), &websocket.DialOptions{HTTPClient: httpc})
		dcancel()
		if err != nil {
			fmt.Fprintln(os.Stderr, "dial", i, err)
			os.Exit(1)
		}
		c.SetReadLimit(4 << 20)
		conns[i] = c
		vs[i] = &viewStats{}
		go read(ctx, c, vs[i], i >= 1 && i <= *stall, time.Duration(*stallMs)*time.Millisecond, time.Duration(*periodMs)*time.Millisecond, func(tag string) {
			mu.Lock()
			if t, ok := sent[tag]; ok && measuring.Load() {
				lat[strings.HasPrefix(tag, "Q")] = append(lat[strings.HasPrefix(tag, "Q")], float64(time.Since(t).Microseconds())/1000)
			}
			delete(sent, tag)
			mu.Unlock()
		})
	}
	flooded := *views - 1
	go func() {
		t := time.NewTicker(*echoEvery)
		defer t.Stop()
		for n := 0; ; n++ {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
			}
			for _, e := range []struct {
				prefix string
				view   int
			}{{"Q", 0}, {"F", flooded}} {
				tag := fmt.Sprintf("%s%07d", e.prefix, n)
				mu.Lock()
				sent[tag] = time.Now()
				mu.Unlock()
				if err := conns[e.view].Write(ctx, websocket.MessageText, []byte(tag)); err != nil {
					return
				}
			}
		}
	}()

	time.Sleep(*warm)
	mark(httpc)
	s0 := getStats(httpc)
	base := snapshot(vs)
	measuring.Store(true)
	time.Sleep(*duration)
	measuring.Store(false)
	s1 := getStats(httpc)
	end := snapshot(vs)
	wall := s1.Now - s0.Now

	var group [2][]float64
	var skips, snaps [2]int64
	var gaps int64
	for i := range *views {
		mbs := float64(end[i][0]-base[i][0]) / wall / 1e6
		stalled := 0
		if i >= 1 && i <= *stall {
			stalled = 1
		}
		if i == 0 {
			continue
		}
		group[stalled] = append(group[stalled], mbs)
		skips[stalled] += end[i][1] - base[i][1]
		snaps[stalled] += end[i][2] - base[i][2]
		gaps += end[i][3]
	}
	var total float64
	for _, g := range group {
		for _, v := range g {
			total += v
		}
	}
	records := s1.Records - s0.Records
	fmt.Printf("views %d (stalled %d: %dms every %dms), rcvbuf %d (read back %d), server sndbuf read back %d rcvbuf %d\n",
		*views, *stall, *stallMs, *periodMs, *rcvbuf, rcvbufReadBack.Load(), s1.Sndbuf, s1.Rcvbuf)
	fmt.Printf("aggregate %.1f MB/s over %.1fs; server wrote %.1f MB/s in %d records (%.0f records/s)\n",
		total, wall, float64(s1.Bytes-s0.Bytes)/wall/1e6, records, float64(records)/wall)
	fmt.Printf("per-view MB/s  live: %s   stalled: %s\n", spread(group[0]), spread(group[1]))
	fmt.Printf("coordinator cpu %.1f%% (user %.2fs sys %.2fs); minor words/record %.1f\n",
		100*((s1.User-s0.User)+(s1.Sys-s0.Sys))/wall, s1.User-s0.User, s1.Sys-s0.Sys, (s1.MinorWords-s0.MinorWords)/float64(max(records, 1)))
	writes := max(s1.Writes-s0.Writes, 1)
	fmt.Printf("minor words: per scheduled record %.1f; per write: iovec subs %.1f, Luv try_write %.1f (%d writes, %.2f records/write)\n",
		(s1.WSchedule-s0.WSchedule)/float64(max(records, 1)), (s1.WIovecs-s0.WIovecs)/float64(writes), (s1.WTryWrite-s0.WTryWrite)/float64(writes), writes, float64(records)/float64(writes))
	fmt.Printf("skips: live views %d, stalled views %d (server total %d); snapshots live %d stalled %d; blocked writes %d, non-ring bytes copied on block (frame headers, skip notes, snapshots) %d; offset gaps without a skip %d\n",
		skips[0], skips[1], s1.Skips-s0.Skips, snaps[0], snaps[1], s1.Blocks-s0.Blocks, s1.Copied-s0.Copied, gaps)
	mu.Lock()
	fmt.Printf("ring pinned by a blocked write: %d writes, ms p50/p99/max %v; pane writer blocked: %d times, ms p50/p99/max %v, %d stalled ticks; lapped views %d\n",
		s1.Pins-s0.Pins, s1.PinMs, s1.WStalls-s0.WStalls, s1.WStallMs, s1.STicks-s0.STicks, s1.Lapped-s0.Lapped)
	fmt.Printf("echo quiet pane  ms %s\n", pcts(lat[true]))
	fmt.Printf("echo flooded pane ms %s\n", pcts(lat[false]))
	mu.Unlock()
	fmt.Printf("peer uid: accepted %d refused %d\n", s1.Accepted, s1.Refused)
}

func read(ctx context.Context, c *websocket.Conn, s *viewStats, stalls bool, stall, period time.Duration, echo func(string)) {
	next := int64(-1)
	afterSkip := true
	nextStall := time.Now().Add(period)
	hdr := make([]byte, 9)
	small := make([]byte, 64)
	for {
		if stalls && !time.Now().Before(nextStall) {
			time.Sleep(time.Until(nextStall.Add(stall)))
			nextStall = nextStall.Add(period)
		}
		typ, r, err := c.Reader(ctx)
		if err != nil {
			return
		}
		if typ == websocket.MessageText {
			b, _ := io.ReadAll(r)
			if strings.Contains(string(b), "skipped") {
				s.skipped.Add(1)
				afterSkip = true
			}
			continue
		}
		if _, err := io.ReadFull(r, hdr); err != nil {
			return
		}
		off := int64(binary.LittleEndian.Uint64(hdr[1:]))
		var n int64
		switch hdr[0] {
		case 2:
			s.snapshots.Add(1)
			n, _ = io.Copy(io.Discard, r)
			next = off
			afterSkip = false
		case 1:
			if next >= 0 && off != next && !afterSkip {
				s.gaps.Add(1)
			}
			afterSkip = false
			k, _ := io.ReadFull(r, small)
			if k > 0 && k < 64 && (small[0] == 'Q' || small[0] == 'F') {
				echo(string(small[:k]))
			}
			m, _ := io.Copy(io.Discard, r)
			n = int64(k) + m
			next = off + n
		}
		s.bytes.Add(n + 9)
	}
}

func snapshot(vs []*viewStats) [][4]int64 {
	out := make([][4]int64, len(vs))
	for i, v := range vs {
		out[i] = [4]int64{v.bytes.Load(), v.skipped.Load(), v.snapshots.Load(), v.gaps.Load()}
	}
	return out
}

func mark(c *http.Client) {
	resp, err := c.Get("http://ko/mark")
	if err != nil {
		fmt.Fprintln(os.Stderr, "mark", err)
		os.Exit(1)
	}
	resp.Body.Close()
}

func getStats(c *http.Client) stats {
	resp, err := c.Get("http://ko/stats")
	if err != nil {
		fmt.Fprintln(os.Stderr, "stats", err)
		os.Exit(1)
	}
	defer resp.Body.Close()
	var s stats
	if err := json.NewDecoder(resp.Body).Decode(&s); err != nil {
		fmt.Fprintln(os.Stderr, "stats", err)
		os.Exit(1)
	}
	return s
}

func spread(v []float64) string {
	if len(v) == 0 {
		return "-"
	}
	sort.Float64s(v)
	return fmt.Sprintf("min %.2f med %.2f max %.2f", v[0], v[len(v)/2], v[len(v)-1])
}

func pcts(v []float64) string {
	if len(v) == 0 {
		return "none"
	}
	sort.Float64s(v)
	at := func(p int) float64 { return v[min(len(v)-1, len(v)*p/100)] }
	return fmt.Sprintf("p50 %.3f p99 %.3f max %.3f (n=%d)", at(50), at(99), v[len(v)-1], len(v))
}

// sockbuf fills one side of a unix stream pair whose reader never reads and
// reports how many bytes the sender could write before EAGAIN.
func sockbuf() {
	for _, k := range []string{"net.local.stream.sendspace", "net.local.stream.recvspace", "kern.ipc.maxsockbuf"} {
		out, _ := sysctl(k)
		fmt.Printf("%s = %s\n", k, out)
	}
	sizes := []int{0, 64 << 10, 1 << 20, 4 << 20}
	fmt.Println("pair         snd_set  rcv_set  snd_get  rcv_get  accepted_before_EAGAIN")
	for _, kind := range []string{"socketpair", "accept"} {
		for _, snd := range sizes {
			for _, rcv := range sizes {
				w, r := pair(kind)
				if snd > 0 {
					_ = syscall.SetsockoptInt(w, syscall.SOL_SOCKET, syscall.SO_SNDBUF, snd)
				}
				if rcv > 0 {
					_ = syscall.SetsockoptInt(r, syscall.SOL_SOCKET, syscall.SO_RCVBUF, rcv)
				}
				sg, _ := syscall.GetsockoptInt(w, syscall.SOL_SOCKET, syscall.SO_SNDBUF)
				rg, _ := syscall.GetsockoptInt(r, syscall.SOL_SOCKET, syscall.SO_RCVBUF)
				_ = syscall.SetNonblock(w, true)
				buf := make([]byte, 1024)
				total := 0
				for {
					n, err := syscall.Write(w, buf)
					if err != nil {
						break
					}
					total += n
				}
				fmt.Printf("%-11s %8d %8d %8d %8d %10d\n", kind, snd, rcv, sg, rg, total)
				syscall.Close(w)
				syscall.Close(r)
			}
		}
	}
}

func pair(kind string) (int, int) {
	if kind == "socketpair" {
		fds, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_STREAM, 0)
		if err != nil {
			panic(err)
		}
		return fds[0], fds[1]
	}
	dir, _ := os.MkdirTemp("/tmp", "sockbuf-")
	defer os.RemoveAll(dir)
	path := dir + "/s"
	l, _ := syscall.Socket(syscall.AF_UNIX, syscall.SOCK_STREAM, 0)
	defer syscall.Close(l)
	if err := syscall.Bind(l, &syscall.SockaddrUnix{Name: path}); err != nil {
		panic(err)
	}
	_ = syscall.Listen(l, 1)
	c, _ := syscall.Socket(syscall.AF_UNIX, syscall.SOCK_STREAM, 0)
	if err := syscall.Connect(c, &syscall.SockaddrUnix{Name: path}); err != nil {
		panic(err)
	}
	a, _, err := syscall.Accept(l)
	if err != nil {
		panic(err)
	}
	return a, c
}

func sysctl(name string) (string, error) {
	out, err := exec.Command("sysctl", "-n", name).Output()
	return strings.TrimSpace(string(out)), err
}
