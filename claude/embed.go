// Package claude holds the Claude Code settings kido ships: the hooks
// that report a session to the sidebar. It is one file with two readers.
// The claude in kido's bin directory hands the installed copy to Claude
// Code with --settings, and `kido setup-claude` merges the embedded one
// into the user's own settings.json.
package claude

import (
	_ "embed"
	"encoding/json"
)

//go:embed settings.json
var settings []byte

// Hooks is the shipped file's hooks, by Claude Code event name: each
// event's list of matcher entries, as settings.json spells them.
func Hooks() (map[string][]any, error) {
	var s struct {
		Hooks map[string][]any `json:"hooks"`
	}
	if err := json.Unmarshal(settings, &s); err != nil {
		return nil, err
	}
	return s.Hooks, nil
}
