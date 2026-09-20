package ui

import "strings"

// Claude Code does not report a dismissed prompt. Pressing Esc on an
// AskUserQuestion dialog, or answering No to a permission request, fires no
// hook at all (checked on v2.1.267: the last event is PermissionRequest and
// nothing follows until a Notification idle_prompt about a minute later), so
// the waiting status kido recorded would stick for that minute. The pane's
// screen is the only timely evidence, and #{pane_title} is not it: Claude
// Code titles a pane "✳ <session name>" whether it is idle, busy or blocked
// on a prompt.
//
// What the screen does say is whether the input box is back. Idle and busy
// both end in Claude Code's prompt box - a horizontal rule, a line starting
// with "❯", a second rule, then a footer line:
//
//	────────────────────────────────────────
//	❯
//	────────────────────────────────────────
//	  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents
//
// while a question or permission dialog replaces the box with its options
// and a hint line ("Esc to cancel · Tab to amend"), whose own "❯ 1. Yes" is
// not preceded by a rule. Busy is told apart from idle by the footer, which
// gains "esc to interrupt" for as long as the model or a tool is running.
//
// atInputPrompt only ever downgrades a waiting pane to idle, so the
// conservative direction is to say no: a screen kido cannot read leaves the
// status exactly as the hooks reported it.

// footerLines is how many lines may follow the input box's closing rule.
// The footer is one line; the allowance is for a wrapped one.
const footerLines = 2

// isRule reports whether line is one of the box-drawing rules Claude Code
// frames its input box with.
func isRule(line string) bool {
	t := strings.TrimSpace(line)
	if len(t) < 4 {
		return false
	}
	return strings.Trim(t, "─") == ""
}

// atInputPrompt reports whether a captured Claude Code screen shows the
// input box with nothing running: no dialog is open and no work is in
// flight, so the session is sitting at the prompt waiting for the user.
func atInputPrompt(lines []string) bool {
	for len(lines) > 0 && strings.TrimSpace(lines[len(lines)-1]) == "" {
		lines = lines[:len(lines)-1]
	}

	// The box's closing rule, at the bottom of the screen bar the footer.
	bottom := -1
	for i := len(lines) - 1; i >= 0 && i >= len(lines)-1-footerLines; i-- {
		if isRule(lines[i]) {
			bottom = i
			break
		}
	}
	if bottom < 0 {
		return false
	}

	// Its opening rule, with the "❯" input line right below it. A dialog's
	// selected option also starts with "❯" but follows its question text.
	top := -1
	for i := bottom - 1; i >= 0; i-- {
		if isRule(lines[i]) {
			top = i
			break
		}
	}
	if top < 0 || top+1 >= bottom {
		return false
	}
	if !strings.HasPrefix(strings.TrimLeft(lines[top+1], " \t"), "❯") {
		return false
	}

	// The footer offers to interrupt only while something is running.
	for _, line := range lines[bottom+1:] {
		if strings.Contains(line, "to interrupt") {
			return false
		}
	}
	return true
}
