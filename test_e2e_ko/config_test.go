package ko_test

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"os/exec"
	"strings"
	"testing"
)

func TestDefaultsAndPaneEnvironment(t *testing.T) {
	t.Parallel()
	s := start(t, "--scrollback-bytes", "80M", "--scrollback-lines", "5000")
	var version struct {
		Limits struct {
			Scrollback   [2]json.RawMessage
			Continuation int `json:"continuation_max_bytes"`
		}
	}
	s.request("GET", "/version", nil, 200, &version)
	var scrollback map[string]int
	if err := json.Unmarshal(version.Limits.Scrollback[1], &scrollback); err != nil {
		t.Fatal(err)
	}
	if string(version.Limits.Scrollback[0]) != `"scrollback"` || scrollback["max_bytes"] != 80*1024*1024 || scrollback["max_lines"] != 5000 || version.Limits.Continuation != 65*1024*1024 {
		t.Fatalf("terminal contract: %+v", version)
	}
	output, err := exec.Command(koBin, "version").Output()
	if err != nil {
		t.Fatal(err)
	}
	var cli struct{ Build string }
	if err := json.Unmarshal(output, &cli); err != nil {
		t.Fatal(err)
	}
	t.Logf("ko version: %s", output)
	c, _ := s.client("")
	var created struct{ Pane string }
	s.request("POST", "/panes", map[string]any{"cwd": "/tmp", "env": []map[string]string{{"name": "X", "value": "custom"}, {"name": "TERM", "value": "wrong"}, {"name": "KO_PANE", "value": "wrong"}}}, 200, &created)
	view := s.dialWS("/panes/"+created.Pane+"/view", nil, 101)
	defer view.Close()
	promptEnd := "$ "
	if os.Geteuid() == 0 {
		promptEnd = "# "
	}
	s.ready(view, promptEnd)
	prompt := s.request("GET", "/panes/"+created.Pane+"/screen?format=plain", nil, 200, nil)
	t.Logf("/bin/sh -l prompt: %q", strings.TrimSpace(prompt))
	for _, entry := range s.cmd.Env {
		if strings.HasPrefix(entry, "PROMPT_COMMAND=") {
			t.Logf("launcher %s", entry)
		}
	}

	command := "printf '%s|%s|%s|%s|%s|%s\\n' \"$TERM\" \"$KO_PANE\" \"$KO_SOCKET\" \"$X\" \"$TERM_PROGRAM\" \"$TERM_PROGRAM_VERSION\"; pwd; exit\n"
	s.request("POST", "/panes/"+created.Pane+"/input", []any{"text", base64.StdEncoding.EncodeToString([]byte(command))}, 200, nil)
	event(t, c, "dead")
	screen := s.request("GET", "/panes/"+created.Pane+"/screen?history=all", nil, 200, nil)
	expected := "xterm-ghostty|" + created.Pane + "|" + s.dir + "/socket|custom|ko|" + cli.Build
	if !strings.Contains(screen, expected) || !strings.Contains(screen, "/tmp") {
		t.Fatalf("pane environment: %q", screen)
	}
	if cli.Build == "" {
		t.Error("ko version has no build field")
	}
	s.request("POST", "/panes", map[string]any{"cwd": "relative"}, 400, nil)
	s.request("POST", "/panes", []string{"invalid"}, 400, nil)
}
