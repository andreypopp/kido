package ko_test

import (
	"encoding/base64"
	"strings"
	"testing"
)

func TestDefaultsAndPaneEnvironment(t *testing.T) {
	t.Parallel()
	s := start(t, "--scrollback", "80M")
	var version struct {
		Terminal struct {
			Scrollback   int `json:"scrollback_max_bytes"`
			Continuation int `json:"continuation_max_bytes"`
		}
	}
	s.request("GET", "/version", nil, 200, &version)
	if version.Terminal.Scrollback != 80*1024*1024 || version.Terminal.Continuation != 65*1024*1024 {
		t.Fatalf("terminal contract: %+v", version)
	}
	c, _ := s.client("")
	var created struct{ Pane string }
	s.request("POST", "/panes", map[string]any{"cwd": "/tmp", "env": map[string]string{"X": "custom", "TERM": "wrong", "KO_PANE": "wrong"}}, 200, &created)
	command := "printf '%s|%s|%s|%s\\n' \"$TERM\" \"$KO_PANE\" \"$KO_SOCKET\" \"$X\"; pwd; exit\n"
	s.request("POST", "/panes/"+created.Pane+"/input", map[string]any{"text": base64.StdEncoding.EncodeToString([]byte(command))}, 200, nil)
	event(t, c, "dead")
	screen := s.request("GET", "/panes/"+created.Pane+"/screen?history=all", nil, 200, nil)
	expected := "xterm-ghostty|" + created.Pane + "|" + s.dir + "/socket|custom"
	if !strings.Contains(screen, expected) || !strings.Contains(screen, "/tmp") {
		t.Fatalf("pane environment: %q", screen)
	}
	s.request("POST", "/panes", map[string]any{"cwd": "relative"}, 400, nil)
	s.request("POST", "/panes", []string{"invalid"}, 400, nil)
}
