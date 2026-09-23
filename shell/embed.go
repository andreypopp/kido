// Package shell holds the shell integration kido ships, embedded so a
// command that has to send it somewhere - `kido ssh` primes a remote zsh
// with it - needs no lookup on disk. `kido setup-zsh` still sources the
// installed copy, which is the same file.
package shell

import _ "embed"

//go:embed zsh/integration.zsh
var ZshIntegration []byte
