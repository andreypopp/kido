package ui

import (
	"strings"
	"testing"
)

// The fixtures below are the bottom rows of real Claude Code v2.1.267
// screens, captured with capture-pane -p.

const (
	idleScreen = `
✻ Sautéed for 3s · done 11:52 AM

────────────────────────────────────────
❯
────────────────────────────────────────
  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents
`
	// The same box, in the other permission mode and with text typed in.
	idleTypingScreen = `
────────────────────────────────────────
❯ touch /tmp/probe-file
────────────────────────────────────────
  ⏸ manual mode on · ? for shortcuts · ← for agents
`
	// A narrow pane - the sidebar takes 40 columns of the window - wraps
	// the footer onto a second line, which footerLines allows for.
	idleWrappedFooterScreen = `
──────────────────────────────────
❯
──────────────────────────────────
  ⏵⏵ auto mode on (shift+tab to
  cycle) · ← for agents
`
	busyScreen = `
✳ Ideating… (5s · ↓ 156 tokens)
  ⎿  Tip: Did you know you can drag and drop image files into your terminal?

────────────────────────────────────────
❯
────────────────────────────────────────
  ⏵⏵ auto mode on (shift+tab to cycle) · esc to interrupt · ← for agents
`
	questionScreen = `
 ☐ Beverage

Do you prefer tea or coffee?

❯ 1. Tea
     You prefer tea
  2. Coffee
     You prefer coffee
  3. Type something.
────────────────────────────────────────
  4. Chat about this

Enter to select · ↑/↓ to navigate · Esc to cancel
`
	permissionScreen = `
 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and always allow access to /tmp from this project
   3. Yes, and switch to auto mode · auto mode handles these prompts for you
   4. No

 Esc to cancel · Tab to amend
`
	// The folder-trust prompt shown before a session starts.
	trustScreen = `
 ❯ No, exit
   Yes, I trust this folder

 Enter to confirm · Esc to cancel
`
)

func TestAtInputPrompt(t *testing.T) {
	for _, c := range []struct {
		name   string
		screen string
		want   bool
	}{
		{"idle", idleScreen, true},
		{"idle with text typed", idleTypingScreen, true},
		{"idle with a wrapped footer", idleWrappedFooterScreen, true},
		{"busy", busyScreen, false},
		{"question dialog", questionScreen, false},
		{"permission dialog", permissionScreen, false},
		{"trust prompt", trustScreen, false},
		{"empty", "", false},
	} {
		lines := strings.Split(strings.Trim(c.screen, "\n"), "\n")
		// A real screen is padded to the pane's height.
		lines = append(lines, "", "", "")
		if got := atInputPrompt(lines); got != c.want {
			t.Errorf("atInputPrompt(%s) = %v, want %v", c.name, got, c.want)
		}
	}
}
