// Package shell holds the shell integrations kido ships, embedded so a
// command that has to send one somewhere - `kido ssh` primes a remote zsh
// with it, `kido shell` a local one - needs no lookup on disk. The copy
// installed under share/kido is the same file, and is what a shell primed
// by a path rather than a payload reads.
package shell

import _ "embed"

//go:embed zsh/integration.zsh
var ZshIntegration []byte

//go:embed bash/integration.bash
var BashIntegration []byte
