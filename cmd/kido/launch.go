package main

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"

	"kido/internal/state"
	"kido/internal/tmux"
	tmuxconf "kido/tmux"
)

// kidoSocket is the tmux socket kido's own server answers on. It is a
// name rather than a path, so the server lands under $TMUX_TMPDIR exactly
// where tmux would put it, and kido-tmux never shares a server with a
// stock tmux: the two speak different protocol versions.
const kidoSocket = "kido"

// launch is bare `kido`: attach to the kido server, starting it first if
// nobody has. It replaces this process with the tmux client, so the
// terminal, the signals and the exit status are the client's own; it only
// returns when there is nothing to attach to.
func launch() error {
	if inside := os.Getenv("TMUX"); inside != "" {
		// A multiplexer already owns this terminal, kido's own included:
		// nesting gives a second prefix and a second status line for no
		// gain, and inside a kido pane the server being asked for is the
		// one already there.
		return fmt.Errorf("already inside tmux (%s); run kido from a plain terminal",
			strings.SplitN(inside, ",", 2)[0])
	}
	bin := tmux.Binary()
	switch probeServer(bin) {
	case serverMismatch:
		return fmt.Errorf("the kido server on socket %q is running an older kido-tmux than this one, "+
			"so it refuses this client; restart it once its windows are free (detach, then "+
			"%s -L %s kill-server)", kidoSocket, bin, kidoSocket)
	case serverUp:
		return execTmux(bin, "-L", kidoSocket, "attach-session")
	}
	conf, err := writeServerConf()
	if err != nil {
		return err
	}
	return execTmux(bin, "-L", kidoSocket, "-f", conf, "new-session")
}

// execTmux replaces this process with tmux. It returns only on failure.
func execTmux(bin string, args ...string) error {
	path, err := exec.LookPath(bin)
	if err != nil {
		return err
	}
	return syscall.Exec(path, append([]string{bin}, args...), os.Environ())
}

// serverState is what the kido socket answered when kido asked.
type serverState int

const (
	serverDown     serverState = iota // nothing is listening, or the socket is stale
	serverUp                          // a server kido can talk to
	serverMismatch                    // a server, refusing this client's protocol
)

// probeServer asks the kido socket for its sessions, which is the
// cheapest question that needs a whole client handshake, and reads the
// answer for the one failure worth naming. Every other failure is treated
// as "no server": starting one reports tmux's own error if the socket is
// unusable for some further reason, which is a better message than a
// guess made here would be.
func probeServer(bin string) serverState {
	cmd := exec.Command(bin, "-L", kidoSocket, "list-sessions")
	var errb bytes.Buffer
	cmd.Stderr = &errb
	return classifyProbe(cmd.Run(), errb.String())
}

// classifyProbe reads the probe's outcome. The one failure worth telling
// apart is tmux's own wording from client.c, "protocol version mismatch
// (client N, server M)", which is what a kido-tmux upgraded under a
// running server answers every new client until that server restarts.
func classifyProbe(err error, stderr string) serverState {
	switch {
	case err == nil:
		return serverUp
	case strings.Contains(stderr, "protocol version mismatch"):
		return serverMismatch
	}
	return serverDown
}

// serverConfPath is the file kido starts its server with. It is generated
// on every launch and lives with kido's state rather than with the user's
// configuration, because nothing the user writes there would survive the
// next start.
func serverConfPath() string { return filepath.Join(state.Dir(), "server.conf") }

// userConfPath is the user's own kido configuration, in tmux's syntax:
// $XDG_CONFIG_HOME/kido/kido.conf, else ~/.config/kido/kido.conf. The
// user's ~/.tmux.conf is deliberately not read - a config written for
// stock tmux fights the side column, and a user who wants theirs writes
// one source-file line in this file.
func userConfPath() (string, error) {
	if dir := os.Getenv("XDG_CONFIG_HOME"); dir != "" {
		return filepath.Join(dir, "kido", "kido.conf"), nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".config", "kido", "kido.conf"), nil
}

// confCommand quotes a path, with any fixed arguments after it, as one
// command word of the generated configuration.
// Both places a path is written there - side-status-command and
// default-command - are command strings tmux hands to /bin/sh after
// expanding them as formats, so the word is single-quoted for tmux and
// double-quoted for the shell inside that, which leaves a space (the case
// that actually happens) working. The characters no such nesting can
// carry are refused rather than written broken, exactly as in the block
// setup-tmux writes: tmuxConfUnsafe is the same list for the same reason.
func confCommand(path string, args ...string) (string, error) {
	if i := strings.IndexAny(path, tmuxConfUnsafe); i >= 0 {
		return "", fmt.Errorf("cannot start a kido server: the path %s contains %q", path, path[i:i+1])
	}
	word := `'"` + path + `"`
	for _, a := range args {
		word += " " + a
	}
	return word + "'", nil
}

// sourceWord quotes a path for source-file, which takes a filename
// rather than a command: one level of tmux quoting and no shell.
func sourceWord(path string) (string, error) {
	if strings.ContainsAny(path, "'\n\r") {
		return "", fmt.Errorf("cannot source %s: the path contains a quote or a newline", path)
	}
	return "'" + path + "'", nil
}

// writeServerConf generates the file the kido server starts with and
// returns its path. Three layers, in this order:
//
//   - kido's defaults, the file `kido setup-tmux` sources for a user
//     running kido inside their own tmux;
//   - the user's kido.conf, which may override any of them;
//   - what kido owns, which the user may not: the side column runs this
//     kido by absolute path, and every pane's shell is primed by it.
//
// The user's own default-command is captured before it is overridden, so
// `kido shell` can still run it (see shellCmd).
func writeServerConf() (string, error) {
	exe, err := invokedPath(os.Args[0])
	if err != nil {
		return "", err
	}
	kido, err := confCommand(exe)
	if err != nil {
		return "", err
	}
	kidoShell, err := confCommand(exe, "shell")
	if err != nil {
		return "", err
	}
	userConf, err := userConfPath()
	if err != nil {
		return "", err
	}
	user, err := sourceWord(userConf)
	if err != nil {
		return "", err
	}

	var b bytes.Buffer
	fmt.Fprintf(&b, "# Generated by kido on every launch; edits here are lost.\n"+
		"# Your own configuration belongs in %s.\n\n", userConf)
	b.Write(tmuxconf.Defaults)
	fmt.Fprintf(&b, "\n# The user's configuration, if there is one: -q, because there\n"+
		"# usually is not.\nsource-file -q %s\n", user)
	fmt.Fprintf(&b, "\n# What kido owns, set last so nothing above can take it away. The\n"+
		"# side column and every pane's shell run this kido by the path it\n"+
		"# was started as, so a second install elsewhere on PATH cannot\n"+
		"# answer for this server. A default-command the user set above is\n"+
		"# kept for `kido shell` to run, primed, in place of a bare shell.\n"+
		"set -gF %s '#{default-command}'\n"+
		"set -g side-status-command %s\n"+
		"set -g default-command %s\n", userCommandOption, kido, kidoShell)

	path := serverConfPath()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return "", err
	}
	if err := os.WriteFile(path, b.Bytes(), 0o644); err != nil {
		return "", err
	}
	return path, nil
}
