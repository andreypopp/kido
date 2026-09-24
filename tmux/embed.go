// Package tmuxconf holds the tmux configuration kido ships, embedded so
// the launcher can write it into the file it starts the server with
// (`kido-tmux -f`). `kido setup-tmux` sources the same file from where the
// package installed it, which is why it is a file here and not a Go
// string: one copy, two ways of reaching it.
package tmuxconf

import _ "embed"

//go:embed kido-side.tmux
var Defaults []byte
