package e2e

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestImageProtocolShim(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "pi"), []byte("#!/bin/sh\nprintf '<%s>' \"${PI_IMAGE_PROTOCOL-unset}\"\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct {
		env  []string
		want string
	}{
		{nil, "<kitty>"},
		{[]string{"PI_IMAGE_PROTOCOL="}, "<>"},
		{[]string{"PI_IMAGE_PROTOCOL=none"}, "<none>"},
	} {
		cmd := exec.Command(filepath.Join(shareDir, "bin", "kido-pi"))
		cmd.Env = append([]string{"PATH=" + dir}, test.env...)
		if got, err := cmd.CombinedOutput(); err != nil || string(got) != test.want {
			t.Fatalf("shim env %q: %v %q, want %q", test.env, err, got, test.want)
		}
	}
}

func TestImageCapture(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	if got := h.in("display-message", "-p", "#{image_support}"); got != "1" {
		t.Fatalf("image_support = %q", got)
	}
	pane := h.in("new-session", "-d", "-s", "images", "-x", "80", "-y", "24", "-P", "-F", "#{pane_id}", "printf '\033]2;image-ready\007'; exec sleep 60")
	h.in("set-option", "-t", "images", "status", "off")
	h.in("set-option", "-t", "images", "default-size", "80x24")
	h.in("set-option", "-t", "images", "window-size", "manual")
	h.in("resize-window", "-t", pane, "-x", "80", "-y", "24")
	h.waitFor(func() bool { return h.in("display-message", "-p", "-t", pane, "#{pane_title}") == "image-ready" }, settle, msgf("image recorder ready"))
	attach := func(flags string) func(string) (string, bool) {
		cmd := exec.Command(tmuxBin, "-S", h.inner, "-C", "attach-session", "-E", "-t", "images", "-f", flags)
		cmd.Env = cleanEnv("TMUX=")
		var errb bytes.Buffer
		cmd.Stderr = &errb
		input, err := cmd.StdinPipe()
		if err != nil {
			t.Fatal(err)
		}
		output, err := cmd.StdoutPipe()
		if err != nil {
			t.Fatal(err)
		}
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		lines := make(chan string, 64)
		failedCommand := false
		go func() {
			defer close(lines)
			scanner := bufio.NewScanner(output)
			for scanner.Scan() {
				lines <- scanner.Text()
			}
		}()
		t.Cleanup(func() {
			input.Close()
			timer := time.AfterFunc(5*time.Second, func() { cmd.Process.Kill() })
			defer timer.Stop()
			var tail []string
			for line := range lines {
				tail = append(tail, line)
			}
			if err := cmd.Wait(); err != nil && !(failedCommand && cmd.ProcessState.ExitCode() == 1) {
				t.Errorf("image control client %s: %v stderr=%s tail=%q", flags, err, errb.String(), tail)
			}
		})
		exchange := func(command string) (string, bool) {
			if command != "" {
				if _, err := io.WriteString(input, command+"\n"); err != nil {
					t.Fatal(err)
				}
			}
			var reply strings.Builder
			begun := false
			deadline := time.NewTimer(20 * time.Second)
			defer deadline.Stop()
			for {
				select {
				case line, ok := <-lines:
					if !ok {
						t.Fatal("image control client closed")
					}
					if strings.HasPrefix(line, "%output ") {
						reply.WriteString(line)
						reply.WriteByte('\n')
						continue
					}
					if strings.HasPrefix(line, "%begin ") {
						begun = true
						continue
					}
					if begun && (strings.HasPrefix(line, "%end ") || strings.HasPrefix(line, "%error ")) {
						failed := strings.HasPrefix(line, "%error ")
						failedCommand = failedCommand || failed
						return reply.String(), failed
					}
					if begun {
						reply.WriteString(line)
						reply.WriteByte('\n')
					}
				case <-deadline.C:
					t.Fatal("image control reply timed out")
				}
			}
		}
		if reply, failed := exchange(""); failed {
			t.Fatalf("image attach: %s", reply)
		}
		return exchange
	}
	main := attach("no-output")
	if reply, failed := main("refresh-client -C 80x24x9x18"); failed {
		t.Fatal(reply)
	}
	for _, size := range []string{"80x24x9", "80x24x4294967296x18", "80x24x9x18junk", "80x24x9x18x1", "80x24x-1x18"} {
		if got, failed := main("refresh-client -C " + size); !failed || strings.TrimSpace(got) != "bad size argument" {
			t.Fatalf("invalid pixel size %q: %v %q", size, failed, got)
		}
	}
	images := attach("no-output,ignore-size")
	query := func(want string) {
		path := filepath.Join(h.dir, "image-query-"+strconv.Itoa(len(want)))
		h.in("new-window", "-d", "-t", "images:", "sh", "-c", fmt.Sprintf("stty raw -echo; printf '\033[16t'; dd bs=1 count=%d of=%s 2>/dev/null", len(want), shellQuote(path)))
		h.waitFor(func() bool { data, _ := os.ReadFile(path); return string(data) == want }, settle, msgf("cell pixel reply %q", want))
	}
	query("\033[6;18;9t")
	second := attach("no-output")
	if reply, failed := second("refresh-client -C 80x24x10x20"); failed {
		t.Fatal(reply)
	}
	query("\033[6;20;10t")
	if reply, failed := second("refresh-client -C 80x24"); failed {
		t.Fatal(reply)
	}
	tty := h.in("display-message", "-p", "-t", pane, "#{pane_tty}")
	output, err := os.OpenFile(tty, os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { output.Close() })
	serial := 0
	emit := func(data []byte) {
		serial++
		title := fmt.Sprintf("image-%d", serial)
		if _, err := output.Write(append(bytes.Clone(data), []byte("\033]2;"+title+"\007")...)); err != nil {
			t.Fatal(err)
		}
		h.waitFor(func() bool { return h.in("display-message", "-p", "-t", pane, "#{pane_title}") == title }, settle, msgf("image output %s", title))
	}
	chunks := func(data []byte, finalMore int) []string {
		encoded := base64.StdEncoding.EncodeToString(data)
		var result []string
		for {
			n := min(4096, len(encoded))
			more := finalMore
			if n < len(encoded) {
				more = 1
			}
			result = append(result, fmt.Sprintf("m=%d;%s", more, encoded[:n]))
			encoded = encoded[n:]
			if len(encoded) == 0 {
				return result
			}
		}
	}
	kitty := func(keys string, data []byte) []byte {
		var out strings.Builder
		for _, chunk := range chunks(data, 0) {
			fmt.Fprintf(&out, "\033_G%s,%s\033\\", keys, chunk)
			keys = "q=2"
		}
		return []byte(out.String())
	}
	capture := func(flags ...string) string {
		return h.in(append([]string{"capture-pane", "-p", "-t", pane}, flags...)...)
	}
	pixels := func(extra string) (string, bool) { return images("capture-pane -p -K -t " + pane + " " + extra) }
	frame := bytes.Repeat([]byte{255, 0, 0, 255}, 16)
	emit(kitty("a=T,i=91,f=32,s=4,v=4,c=1,r=1,C=1,q=2", frame))
	emit(kitty("a=f,i=91,r=1,f=32,s=2,v=2,x=1,y=1,X=1,q=2", bytes.Repeat([]byte{0, 255, 0, 255}, 4)))
	for _, y := range []int{1, 2} {
		copy(frame[(y*4+1)*4:], bytes.Repeat([]byte{0, 255, 0, 255}, 2))
	}
	wantFrame := "\033_Ga=t,i=91,f=32,s=4,v=4,q=2,m=0;" + base64.StdEncoding.EncodeToString(frame) + "\033\\\n"
	if got, failed := pixels(""); failed || got != wantFrame {
		t.Fatalf("edited root pixels: failed=%v got=%q want=%q", failed, got, wantFrame)
	}
	t.Run("animation capture", func(t *testing.T) {
		want := wantFrame
		for _, frame := range []struct {
			keys string
			data []byte
		}{
			{"a=f,i=91,f=32,s=4,v=4,X=1,z=75,q=2", bytes.Repeat([]byte{0, 255, 0, 255}, 16)},
			{"a=f,i=91,f=32,s=4,v=4,X=1,z=-1,q=2", bytes.Repeat([]byte{0, 0, 255, 255}, 16)},
		} {
			emit(kitty(frame.keys, frame.data))
			want += string(kitty(frame.keys, frame.data)) + "\n"
		}
		emit(kitty("a=a,i=91,r=1,z=100,c=2,s=1,v=4,q=2", nil))
		want += "\033_Ga=a,i=91,r=1,z=100,c=2,s=1,v=4,q=2\033\\\n"
		if got, failed := pixels(""); failed || got != want {
			t.Fatalf("animation pixels and playback: failed=%v got=%q want=%q", failed, got, want)
		}
	})
	emit(kitty("a=d,d=A,q=2", nil))
	bitmap := image.NewRGBA(image.Rect(0, 0, 32, 32))
	for y := 0; y < 32; y++ {
		for x := 0; x < 32; x++ {
			bitmap.SetRGBA(x, y, color.RGBA{uint8(x * 7), uint8(y * 7), uint8(x * y), 255})
		}
	}
	var pngData bytes.Buffer
	encoder := png.Encoder{CompressionLevel: png.NoCompression}
	if err := encoder.Encode(&pngData, bitmap); err != nil {
		t.Fatal(err)
	}
	data := pngData.Bytes()
	emit(append([]byte("\033cabcdefghij\033[1;11H"), append(kitty("a=T,i=81,f=100,c=1,r=1,C=1,q=2", data), append([]byte("\033[1;3H"), kitty("a=T,i=82,f=100,c=1,r=1,C=1,q=2", data)...)...)...))
	left := "\033_Ga=p,i=82,q=2,C=1,c=1,r=1,x=0,y=0,w=32,h=32\033\\"
	right := strings.Replace(left, "i=82,", "i=81,", 1)
	if got := capture("-G", "-S", "0", "-E", "0"); got != "ab"+left+"cdefghij"+right {
		t.Fatalf("reverse drawing order: %q", got)
	}
	emit(append(kitty("a=d,d=A,q=2", nil), append([]byte("\033c\033[1;11H"), kitty("a=T,i=83,f=100,c=1,r=1,C=1,q=2", data)...)...))
	indent := strings.Repeat(" ", 10) + strings.Replace(left, "i=82,", "i=83,", 1)
	for _, flags := range [][]string{nil, {"-J"}, {"-N"}, {"-e"}} {
		if got := capture(append([]string{"-G", "-S", "0", "-E", "0"}, flags...)...); got != indent {
			t.Fatalf("indentation flags %v: %q", flags, got)
		}
	}
	emit(kitty("a=d,d=A,q=2", nil))
	emit(append([]byte("\033[2J\033[Habc"), append(kitty("a=T,i=7,f=100,c=4,r=2,C=1,q=2", data), []byte("text")...)...))
	placement := "\033_Ga=p,i=7,q=2,C=1,c=4,r=2,x=0,y=0,w=32,h=32\033\\"
	if got := capture("-G", "-S", "0", "-E", "1"); got != "abc"+placement+"text" {
		t.Fatalf("placement: %q", got)
	}
	emit(append([]byte("\033[H\033[31mabc"), append(kitty("a=T,i=7,f=100,c=4,r=2,C=1,q=2", data), []byte("\033[32mtext")...)...))
	for _, flags := range [][]string{{"-e"}, {"-e", "-J"}} {
		want := "\033[31mabc" + placement + "\033[32mtext"
		if len(flags) == 1 {
			want += "\033[39m"
		}
		if got := capture(append([]string{"-G", "-S", "0", "-E", "1"}, flags...)...); got != want {
			t.Fatalf("styled placement flags %v: %q want %q", flags, got, want)
		}
	}
	emit(append([]byte("\033[0m\033[2J\033[Habc"), append(kitty("a=T,i=7,f=100,c=4,r=2,C=1,q=2", data), []byte("text")...)...))
	var expected strings.Builder
	for i, chunk := range chunks(data, 0) {
		if i == 0 {
			expected.WriteString("\033_Ga=t,i=7,f=100,q=2,")
		} else {
			expected.WriteString("\033_G")
			chunk = strings.Replace(chunk, ";", ",q=2;", 1)
		}
		expected.WriteString(chunk + "\033\\\n")
	}
	if got, failed := pixels(""); failed || got != expected.String() {
		t.Fatalf("PNG pixels: failed=%v got=%q want=%q", failed, got, expected.String())
	}
	cmd := exec.Command(tmuxBin, "-S", h.inner, "capture-pane", "-K", "-p", "-t", pane)
	cmd.Env = cleanEnv("TMUX=")
	if got, err := cmd.Output(); err != nil || string(got) != expected.String() {
		t.Fatalf("one-shot pixels: %v %q", err, got)
	}
	emit([]byte("\033[?1049hALT"))
	if got := capture("-a", "-G", "-S", "0", "-E", "1"); got != "abc"+placement+"text" {
		t.Fatalf("saved main placement: %q", got)
	}
	if got, failed := pixels("-a"); failed || got != expected.String() {
		t.Fatalf("saved main pixels: %v %q", failed, got)
	}
	if got, failed := pixels(""); failed || got != "" {
		t.Fatalf("alternate pixels: %v %q", failed, got)
	}
	emit([]byte("\033[?1049l"))
	emit(kitty("a=p,i=7,p=3,c=4,r=2,C=1,q=2", nil))
	if got := capture("-G"); !strings.Contains(got, "a=p,i=7,p=3,") {
		t.Fatalf("named placement: %q", got)
	}
	emit([]byte("\033[24;1H\n\n\n"))
	if got := capture("-G", "-S", "-3", "-E", "-1"); !strings.Contains(got, "abc"+placement+"text") {
		t.Fatalf("history placement: %q", got)
	}
	if got := capture("-G", "-S", "-2", "-E", "-1"); !strings.Contains(got, "c=4,r=1,x=0,y=16,w=32,h=16") {
		t.Fatalf("history crop: %q", got)
	}
	emit(kitty("a=d,d=I,i=7,q=2", nil))
	if got := capture("-G", "-S", "-"); strings.Contains(got, "\033_G") {
		t.Fatalf("deleted placement: %q", got)
	}
	if got, failed := pixels("-S -"); failed || got != "" {
		t.Fatalf("deleted pixels: %v %q", failed, got)
	}
	if got, want := capture("-e", "-J", "-G"), capture("-e", "-J"); got != want {
		t.Fatalf("plain -G: %q != %q", got, want)
	}
	emit(append([]byte("\033[2J\033[H"), kitty("a=T,i=7,f=100,c=4,r=16,C=1,q=2", data)...))
	emit([]byte("\033[24;1H" + strings.Repeat("\n", 50)))
	if got := capture("-G", "-S", "-40", "-E", "-30"); !strings.Contains(got, "c=4,r=6,x=0,y=20,w=32,h=12") {
		t.Fatalf("deep history crop: %q", got)
	}
	if got, failed := pixels("-S -40 -E -30"); failed || got != expected.String() {
		t.Fatalf("deep history pixels: %v %q", failed, got)
	}
	emit(kitty("a=d,d=I,i=7,q=2", nil))
	h.in("set-option", "-g", "image-size-limit", "1")
	emit(kitty("a=T,i=7,f=100,c=4,r=2,C=1,q=2", data))
	if got, failed := pixels("-S -"); failed || got != "" {
		t.Fatalf("size limit: %v %q", failed, got)
	}
	h.in("set-option", "-gu", "image-size-limit")

	large := bytes.Repeat([]byte{9, 17, 33, 255}, 1280*1320)
	var pending strings.Builder
	pending.WriteString("\033[2J\033[H")
	keys := "a=T,f=32,s=1280,v=1320,c=4,r=2,C=1,z=-1,q=2"
	for _, chunk := range chunks(large[:len(large)-3072], 1) {
		fmt.Fprintf(&pending, "\033_G%s,%s\033\\", keys, chunk)
		keys = "q=2"
	}
	emit([]byte(pending.String()))
	if got := capture("-G"); strings.Contains(got, "\033_G") {
		t.Fatal("oversized in-flight image was replayed")
	}
	emit(kitty("q=2", large[len(large)-3072:]))
	largePlacement := regexp.MustCompile(`a=p,i=(\d+),z=-1,`).FindStringSubmatch(capture("-G"))
	if len(largePlacement) != 2 {
		t.Fatalf("large no-id placement: %q", capture("-G"))
	}
	fetch := func(want [][]byte) string {
		var streams [][]byte
		var current []byte
		token := ""
		firstToken := ""
		calls := 0
		for {
			args := ""
			if token != "" {
				args += " -k " + token
			}
			reply, failed := pixels(args)
			if failed {
				t.Fatal(reply)
			}
			calls++
			if len(reply) > 8*1024*1024 {
				t.Fatalf("reply exceeds budget: %d", len(reply))
			}
			token = ""
			for _, line := range strings.Split(strings.TrimSuffix(reply, "\n"), "\n") {
				if strings.HasPrefix(line, "more ") {
					token = strings.TrimPrefix(line, "more ")
					if firstToken == "" {
						firstToken = token
					}
					continue
				}
				keys, payload, ok := strings.Cut(strings.TrimSuffix(strings.TrimPrefix(line, "\033_G"), "\033\\"), ";")
				if !ok {
					t.Fatalf("image chunk: %q", line)
				}
				if len(current) == 0 {
					if len(streams) == 0 && !strings.HasPrefix(keys, "a=t,i="+largePlacement[1]+",") {
						t.Fatalf("no-id transmit does not match placement: %q", keys)
					}
					if !strings.HasPrefix(keys, "a=t,i=") {
						t.Fatalf("first chunk keys: %q", keys)
					}
				} else if keys != "m=1,q=2" && keys != "m=0,q=2" {
					t.Fatalf("continuation keys: %q", keys)
				}
				part, err := base64.StdEncoding.DecodeString(payload)
				if err != nil {
					t.Fatal(err)
				}
				if len(part) > 3072 {
					t.Fatalf("chunk size %d", len(part))
				}
				current = append(current, part...)
				if strings.Contains(keys, "m=0") {
					streams = append(streams, current)
					current = nil
				} else if len(part) != 3072 {
					t.Fatalf("short nonfinal chunk: %d", len(part))
				}
			}
			if token == "" {
				break
			}
			if calls > 10 {
				t.Fatal("continuation did not finish")
			}
		}
		if calls < 2 || len(current) != 0 || len(streams) != len(want) {
			t.Fatalf("calls=%d streams=%d pending=%d", calls, len(streams), len(current))
		}
		for i := range want {
			if !bytes.Equal(streams[i], want[i]) {
				t.Fatalf("image %d does not match input", i)
			}
		}
		return firstToken
	}
	token := fetch([][]byte{large})
	id, _, _ := strings.Cut(token, ":")
	if got, failed := pixels("-k " + id + ":" + strconv.Itoa(len(large))); !failed || strings.TrimSpace(got) != "image changed" {
		t.Fatalf("end offset continuation: %v %q", failed, got)
	}
	emit(append([]byte("\033[4;1H"), kitty("a=T,i=72,f=100,c=4,r=2,C=1,q=2", data)...))
	fetch([][]byte{large, data})
	emit(kitty("a=d,d=A,q=2", nil))
	if got, failed := pixels("-k " + token); !failed || strings.TrimSpace(got) != "image changed" {
		t.Fatalf("deleted no-id continuation: %v %q", failed, got)
	}
	for _, bad := range []string{"bad", "0:0", "1:1", "1:99999999999999999999999999999"} {
		if got, failed := pixels("-k " + bad); !failed || strings.TrimSpace(got) != "image changed" {
			t.Fatalf("bad token %q: %v %q", bad, failed, got)
		}
	}
	if got, failed := images("display-message -p done"); failed || got != "done\n" {
		t.Fatalf("image client after failed continuation: %v %q", failed, got)
	}
	helper := filepath.Join(h.dir, "image-shm")
	compiler := exec.Command("cc", "-x", "c", "-o", helper, "-")
	compiler.Stdin = strings.NewReader(`#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
 int fd, input;
 struct stat sb;
 void *p;
 if (argc < 3) return 1;
 if (!strcmp(argv[1], "unlink")) { shm_unlink(argv[2]); return 0; }
 if (!strcmp(argv[1], "create")) {
  input = open(argv[3], O_RDONLY);
  if (input < 0 || fstat(input, &sb)) return 2;
  fd = shm_open(argv[2], O_CREAT|O_EXCL|O_RDWR, 0600);
  if (fd < 0 || ftruncate(fd, sb.st_size)) return 3;
  p = mmap(NULL, sb.st_size, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0);
  if (p == MAP_FAILED || read(input, p, sb.st_size) != sb.st_size) return 4;
  close(input);
 } else {
  fd = shm_open(argv[2], O_RDONLY, 0);
  if (fd < 0 || fstat(fd, &sb)) return 5;
  if (sb.st_size < 64) return 7;
  sb.st_size = 64;
  p = mmap(NULL, sb.st_size, PROT_READ, MAP_SHARED, fd, 0);
  if (p == MAP_FAILED || fwrite(p, 1, sb.st_size, stdout) != sb.st_size) return 6;
 }
 munmap(p, sb.st_size);
 close(fd);
 return 0;
}
`)
	if output, err := compiler.CombinedOutput(); err != nil {
		t.Fatalf("build shm helper: %v: %s", err, output)
	}
	runHelper := func(args ...string) []byte {
		output, err := exec.Command(helper, args...).CombinedOutput()
		if err != nil {
			t.Fatalf("shm helper %q: %v: %s", args, err, output)
		}
		return output
	}

	shmData := bytes.Repeat([]byte{255, 0, 0, 255}, 16)
	payload := filepath.Join(h.dir, "image-pixels")
	if err := os.WriteFile(payload, shmData, 0o600); err != nil {
		t.Fatal(err)
	}
	name := fmt.Sprintf("/kido-test-%d", os.Getpid())
	runHelper("create", name, payload)
	t.Cleanup(func() { exec.Command(helper, "unlink", name).Run() })
	local := attach("image-shm,ignore-size")
	emit(append([]byte("\033c"), kitty("a=T,i=71,f=32,s=4,v=4,t=s,q=2,C=1", []byte(name))...))
	raw, failed := local("display-message -p barrier")
	if failed || !strings.Contains(raw, "t=s,q=2") || strings.Contains(raw, "t=d") {
		t.Fatalf("flagged pane output: %v %q", failed, raw)
	}
	direct := capture("-K")
	match := regexp.MustCompile(`;([^;]*)\x1b\\`).FindStringSubmatch(direct)
	if len(match) != 2 || !strings.Contains(direct, "m=0") {
		t.Fatalf("direct capture: %q", direct)
	}
	decoded, err := base64.StdEncoding.DecodeString(match[1])
	if err != nil || !bytes.Equal(decoded, shmData) {
		t.Fatalf("direct bytes: %x, %v", decoded, err)
	}
	restored, failed := local("capture-pane -K -p -t " + pane)
	match = regexp.MustCompile(`\x1b_Ga=t,i=71,f=32,s=4,v=4,t=s,S=64,q=2;([^;]*)\x1b\\`).FindStringSubmatch(restored)
	if failed || len(match) != 2 || strings.Contains(restored, "m=") {
		t.Fatalf("shm capture: %v %q", failed, restored)
	}
	decoded, err = base64.StdEncoding.DecodeString(match[1])
	if err != nil {
		t.Fatal(err)
	}
	restoredName := string(decoded)
	defer exec.Command(helper, "unlink", restoredName).Run()
	if got := runHelper("read", restoredName); !bytes.Equal(got, shmData) {
		t.Fatalf("restored shm bytes: %x, want %x", got, shmData)
	}
}
