package ko_test

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestHostileClientsDoNotAffectOthers(t *testing.T) {
	t.Parallel()
	s := start(t)
	p := s.pane("stty -echo -icanon min 1 time 0; printf READY; exec cat -v")
	good := s.dialWS("/panes/"+p+"/view?history=all", nil, 101)
	s.ready(good, "READY")
	head := fmt.Sprintf("Ko-Protocol: 1.0\r\nKo-Vt: %s\r\n", s.vt)
	upgrade := "GET /panes/" + p + "/view?history=all HTTP/1.1\r\nHost: ko\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n" + head + "\r\n"
	for i, hostile := range [][]byte{
		[]byte("GET /version HTTP/1.1\r\nHost: ko\r\n" + strings.Repeat("A: b\r\n", 20000) + "\r\n"),
		[]byte("POST /panes HTTP/1.1\r\nHost: ko\r\n" + head + "Content-Length: 99999999999\r\n\r\n{"),
		[]byte("POST /panes HTTP/1.1\r\nHost: ko\r\n" + head + "Transfer-Encoding: chunked\r\n\r\n{}"),
		[]byte("\x16\x03\x01\x02\x00\x01\x00\x01\xfc\x03\x03"),
		append([]byte(upgrade), 0x81, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0),
		append([]byte(upgrade), 0x01, 0x80, 0, 0, 0, 0, 0x80, 0x80, 0, 0, 0, 0),
		append([]byte(upgrade), bytes.Repeat([]byte{0x89, 0x80, 0, 0, 0, 0}, 5000)...),
	} {
		conn, err := s.dial(context.Background(), "", "")
		if err != nil {
			t.Fatal(err)
		}
		conn.SetDeadline(time.Now().Add(5 * time.Second))
		conn.Write(hostile)
		conn.(*net.UnixConn).CloseWrite()
		// Linux resets a unix socket whose peer closed with unread input; macOS reports EOF.
		if _, err = io.Copy(io.Discard, io.LimitReader(conn, 8<<20)); err != nil && !errors.Is(err, syscall.ECONNRESET) {
			t.Fatalf("hostile input %d kept the connection open: %v", i, err)
		}
		conn.Close()
		select {
		case err := <-s.wait:
			t.Fatalf("server exited after hostile input %d: %v: %s", i, err, s.log.String())
		default:
		}
		s.request("GET", "/version", nil, 200, nil)
		s.typeText(good, fmt.Sprintf("alive%d", i))
		output(t, good, fmt.Sprintf("alive%d", i))
	}
}

func TestClientGridLimit(t *testing.T) {
	t.Parallel()
	s := start(t)
	grid := func(cols, rows int) map[string]any {
		return map[string]any{"cols": cols, "rows": rows, "cell_px": map[string]int{"width": 65535, "height": 65535}}
	}
	hello := func(cols, rows int) *websocket.Conn {
		c := s.dialWS("/client", nil, 101)
		send(t, c, []any{"hello", map[string]any{"kind": "terminal", "name": "t", "focused": true, "size": grid(cols, rows)}})
		return c
	}
	c := hello(4096, 4096)
	_, welcome := read(t, c)
	if tag, _ := tagged(welcome); tag != "welcome" {
		t.Fatalf("4096x4096 refused: %s", tag)
	}
	_, topology := read(t, c)
	if tag, _ := tagged(topology); tag != "topology" {
		t.Fatalf("expected topology, got %s", tag)
	}
	send(t, c, []any{"size", grid(4097, 24)})
	if _, _, err := c.ReadMessage(); err == nil {
		t.Fatal("size 4097 accepted")
	}
	c = hello(4097, 24)
	if _, _, err := c.ReadMessage(); err == nil {
		t.Fatal("hello 4097 accepted")
	}
	s.request("GET", "/version", nil, 200, nil)
}
