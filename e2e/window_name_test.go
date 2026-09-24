package e2e

import (
	"os"
	"path/filepath"
	"testing"
)

// TestFreshServerSessionIsMain pins the launcher's session name: a fresh
// kido server used to leave tmux to pick one, which is a bare integer
// ("0") rather than anything meaningful.
func TestFreshServerSessionIsMain(t *testing.T) {
	t.Parallel()
	r := newKidoRun(t)
	r.launch("first")
	r.waitUp()

	if got := r.mustKido("list-sessions", "-F", "#{session_name}"); got != "main" {
		t.Errorf("session name = %q, want main", got)
	}
}

// TestFirstWindowNameIsNotQuoteDebris is the other half of the bug this
// pins: with automatic-rename off (as a user's kido.conf may set,
// sourcing their own ~/.tmux.conf), tmux never renames a window after it
// is created (check_window_name, third_party/tmux/names.c, returns
// immediately when the option is off), so the name given at spawn time -
// what default_window_name() derives from default-command - is
// permanent.
//
// Pre-fix, default-command was written as `'"<path>" shell'`: two nested
// quoting layers that default_window_name()'s single unquoting pass does
// not undo, leaving the window named a single backslash. The fix drops
// the inner quoting when the path does not need it, which
// default_window_name then reduces to the basename of the command's
// first word - "kido", not the "zsh" stock tmux would give a plain
// `default-command zsh`, since what is actually run is `kido shell`.
// That residual gap is accepted (see cmd/kido/launch.go's confCommand)
// and this asserts it stays there rather than regressing to quote
// debris.
func TestFirstWindowNameIsNotQuoteDebris(t *testing.T) {
	t.Parallel()
	r := newKidoRun(t)
	conf := filepath.Join(r.config, "kido")
	if err := os.MkdirAll(conf, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(conf, "kido.conf"),
		[]byte("set -g automatic-rename off\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	r.launch("first")
	r.waitUp()

	want := filepath.Base(kidoBin)
	if got := r.mustKido("list-windows", "-F", "#{window_name}"); got != want {
		t.Errorf("first window name = %q, want %q (the kido binary's basename, "+
			"since the pane runs `kido shell`)", got, want)
	}
}
