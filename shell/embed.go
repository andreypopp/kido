// Package shell holds the shell integrations kido ships, embedded so a
// command that has to send one somewhere - `kido ssh` primes a remote zsh
// with it - needs no lookup on disk. `kido setup-zsh` and `kido
// setup-bash` still source the installed copy, which is the same file.
package shell

import _ "embed"

//go:embed zsh/integration.zsh
var ZshIntegration []byte

//go:embed bash/integration.bash
var BashIntegration []byte
