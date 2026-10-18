package e2e

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
)

type feedOutcome struct {
	Serial *int    `json:"serial"`
	Result *string `json:"result"`
}

type feedStatus struct {
	Since    *float64
	Msg      *string
	State    string
	Progress *int
	Kind     *string
	Outcome  *feedOutcome
}

type feedExit struct {
	Code      *int     `json:"code"`
	Command   *string  `json:"command"`
	StartedAt *float64 `json:"started_at"`
	EndedAt   *float64 `json:"ended_at"`
}

type feedShell struct {
	Phase      string
	Last       *feedExit
	Origin     string
	Command    *string
	StartedAt  *float64
	Fullscreen *bool
	Report     *feedStatus
}

type feedLifecycle struct {
	Ended       bool
	Result      *string
	Kind        string
	Name        *string
	User, Host  *string
	Remote      string
	Interactive *bool
	Agent       *feedStatus
	Shell       *feedShell
}

func feedValue[T any](p *T) T {
	if p == nil {
		panic("missing or null required feed value")
	}
	return *p
}

func feedDecode(raw json.RawMessage, v any) error {
	d := json.NewDecoder(bytes.NewReader(raw))
	d.DisallowUnknownFields()
	return d.Decode(v)
}

func feedVariant(raw json.RawMessage, cases map[string]any) (string, error) {
	var parts []json.RawMessage
	if err := json.Unmarshal(raw, &parts); err != nil || len(parts) == 0 || len(parts) > 2 {
		return "", fmt.Errorf("not a variant: %s", raw)
	}
	var tag string
	if err := json.Unmarshal(parts[0], &tag); err != nil {
		return "", err
	}
	v, ok := cases[tag]
	if !ok || (v == nil && len(parts) != 1) || (v != nil && len(parts) != 2) {
		return "", fmt.Errorf("unexpected variant: %s", raw)
	}
	if v != nil {
		return tag, feedDecode(parts[1], v)
	}
	return tag, nil
}

func decodeStatus(raw json.RawMessage) (*feedStatus, error) {
	s := &feedStatus{}
	var wire struct {
		Since *float64        `json:"since"`
		Msg   *string         `json:"msg"`
		State json.RawMessage `json:"state"`
	}
	if err := feedDecode(raw, &wire); err != nil {
		return nil, err
	}
	s.Since, s.Msg = wire.Since, wire.Msg
	cases := map[string]any{
		"Running": &struct {
			Progress **int `json:"progress"`
		}{&s.Progress},
		"Waiting": &struct {
			Kind     **string `json:"kind"`
			Progress **int    `json:"progress"`
		}{&s.Kind, &s.Progress},
		"Idle": &struct {
			Outcome **feedOutcome `json:"outcome"`
		}{&s.Outcome},
	}
	var err error
	s.State, err = feedVariant(wire.State, cases)
	if err == nil && s.Outcome != nil {
		result := feedValue(s.Outcome.Result)
		if result != "success" && result != "failure" {
			err = fmt.Errorf("outcome result %s", raw)
		}
	}
	return s, err
}

func decodeShell(raw json.RawMessage) (*feedShell, error) {
	var wire struct {
		Phase  json.RawMessage `json:"phase"`
		Report json.RawMessage `json:"report"`
	}
	if err := feedDecode(raw, &wire); err != nil {
		return nil, err
	}
	s := &feedShell{}
	var origin json.RawMessage
	var err error
	s.Phase, err = feedVariant(wire.Phase, map[string]any{
		"Unknown": nil,
		"Idle": &struct {
			Last **feedExit `json:"last"`
		}{&s.Last},
		"Running": &struct {
			Origin     *json.RawMessage `json:"origin"`
			Fullscreen **bool           `json:"fullscreen"`
		}{&origin, &s.Fullscreen},
	})
	if err == nil && s.Phase == "Running" {
		s.Origin, err = feedVariant(origin, map[string]any{
			"Command": &struct {
				Command   **string  `json:"command"`
				StartedAt **float64 `json:"started_at"`
			}{&s.Command, &s.StartedAt},
			"Unknown": nil,
		})
		if err == nil && s.Origin == "Unknown" && !feedValue(s.Fullscreen) {
			err = fmt.Errorf("running origin %s", raw)
		}
	}
	if err == nil && wire.Report != nil && string(wire.Report) != "null" {
		s.Report, err = decodeStatus(wire.Report)
	}
	return s, err
}

func (l *feedLifecycle) UnmarshalJSON(raw []byte) error {
	var live json.RawMessage
	tag, err := feedVariant(raw, map[string]any{
		"Ended": &struct {
			Result **string `json:"result"`
		}{&l.Result},
		"Live": &live,
	})
	if err != nil {
		return err
	}
	l.Ended = tag == "Ended"
	if l.Ended {
		return nil
	}
	var shell, agent, remote json.RawMessage
	l.Kind, err = feedVariant(live, map[string]any{
		"Terminal": &shell,
		"Pi_agent": &struct {
			ID     **string         `json:"id"`
			Status *json.RawMessage `json:"status"`
		}{&l.Name, &agent},
		"Some_agent": &struct {
			Name   **string         `json:"name"`
			Status *json.RawMessage `json:"status"`
		}{&l.Name, &agent},
		"Ssh": &struct {
			User **string         `json:"user"`
			Host **string         `json:"host"`
			Pane *json.RawMessage `json:"pane"`
		}{&l.User, &l.Host, &remote},
	})
	if err == nil && l.Kind == "Ssh" {
		l.Remote, err = feedVariant(remote, map[string]any{
			"Remote_terminal": &struct {
				Interactive **bool           `json:"interactive"`
				Status      *json.RawMessage `json:"status"`
			}{&l.Interactive, &shell},
			"Remote_agent": &struct {
				Name   **string         `json:"name"`
				Status *json.RawMessage `json:"status"`
			}{&l.Name, &agent},
		})
	}
	if err == nil {
		if l.Kind == "Terminal" || l.Remote == "Remote_terminal" {
			l.Shell, err = decodeShell(shell)
		} else {
			l.Agent, err = decodeStatus(agent)
		}
	}
	return err
}

func (r feedRow) isAgent() bool { return r.Lifecycle.Agent != nil }

func (r feedRow) isShell() bool { return r.Lifecycle.Kind == "Terminal" }

func (r feedRow) state() string {
	l := r.Lifecycle
	switch {
	case l.Ended:
		return "Ended"
	case l.Agent != nil:
		return l.Agent.State
	case l.Shell.Report != nil:
		return l.Shell.Report.State
	}
	return l.Shell.Phase
}

func (r feedRow) caption() string {
	l := r.Lifecycle
	s := l.Agent
	switch {
	case l.Ended:
		if feedValue(l.Result) == "unknown" {
			return ""
		}
		return feedValue(l.Result)
	case s == nil:
		s = l.Shell.Report
	}
	if s == nil {
		return ""
	}
	var parts []string
	if s.Msg != nil {
		parts = append(parts, *s.Msg)
	}
	if s.Progress != nil {
		parts = append(parts, fmt.Sprintf("%d%%", *s.Progress))
	}
	return strings.Join(parts, " ")
}

func feedGlyph(r feedRow) string {
	l := r.Lifecycle
	status := func(s *feedStatus) string {
		switch s.State {
		case "Running":
			return "◼"
		case "Waiting":
			return "◆"
		}
		switch {
		case s.Outcome == nil:
			return " "
		case feedValue(s.Outcome.Result) == "success":
			return "✓"
		}
		return "◼"
	}
	switch {
	case l.Ended && feedValue(l.Result) == "completed":
		return "✓"
	case l.Ended:
		return "×"
	case l.Agent != nil:
		return status(l.Agent)
	case l.Shell.Phase == "Running" && feedValue(l.Shell.Fullscreen):
		return " "
	case l.Shell.Report != nil:
		return status(l.Shell.Report)
	case l.Shell.Phase == "Running", l.Shell.Phase == "Unknown" && r.Started != nil:
		return "◼"
	}
	return " "
}

func feedLabel(r feedRow) string {
	l := r.Lifecycle
	if l.Ended || l.Agent != nil {
		return r.Title
	}
	s := l.Shell
	command := ""
	if s.Report == nil && s.Phase == "Running" && s.Origin == "Command" && !feedValue(s.Fullscreen) {
		command = feedValue(s.Command)
	}
	if l.Kind == "Ssh" {
		label := "ssh " + feedValue(l.User) + "@" + feedValue(l.Host)
		if feedValue(l.Interactive) && command != "" {
			label += ": " + command
		}
		return label
	}
	if command != "" {
		return command
	}
	return r.Title
}
