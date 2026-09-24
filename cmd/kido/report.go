package main

import (
	"strings"

	"kido/internal/subrun"
)

// maxReportBytes is how much of a notify_parent report the parent is
// handed. It is spliced whole into the parent's next turn, so it is
// bounded; what it is not is the whole report, which is kept on disk
// (docs/design-subagents.md, "Reporting").
const maxReportBytes = 4000

// reportNotice is the notice text for a report, and the file the rest of
// it was written to. A report within the cap is returned byte for byte
// with no file: nothing was lost, so there is nothing to point at.
//
// Over the cap the report is written to the run's directory whole and
// the notice is its head plus a line naming the file, the two together
// still inside the cap - a parent reading a report cut mid-sentence used
// to have no way of knowing there had been more of it, let alone where.
// runID is the sender's own run ($KIDO_AGENT_RUN_ID); a sender kido never
// spawned has no run directory to write to, and its report is simply
// truncated as it always was. So is one whose write fails, which is why
// the error is returned alongside a usable notice rather than instead of
// one: the point of the call is that the parent hears something.
func reportNotice(report, runID string) (notice, path string, err error) {
	if len(report) <= maxReportBytes {
		return report, "", nil
	}
	if runID == "" {
		return headWithin(report, maxReportBytes), "", nil
	}
	path = subrun.ReportPath(runID)
	if err := subrun.WriteReport(runID, report); err != nil {
		return headWithin(report, maxReportBytes), "", err
	}
	suffix := "\n\nfull report: " + path
	return headWithin(report, maxReportBytes-len(suffix)) + suffix, path, nil
}

// headWithin is the first max bytes of s, cut back off a partial UTF-8
// rune - trimPartialRune's rule (ending_notice.go) in the other
// direction, and for the same reason: the send path refuses a message
// that is not valid UTF-8 outright, so a cut through a multi-byte
// character would cost the report the one notice it gets.
func headWithin(s string, max int) string {
	if max <= 0 {
		return ""
	}
	if len(s) <= max {
		return s
	}
	b := trimPartialRune([]byte(s[:max]), false)
	return strings.ToValidUTF8(string(b), "\uFFFD")
}
