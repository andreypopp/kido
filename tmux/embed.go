// Package tmuxconf holds the tmux configuration kido ships, embedded so
// the launcher can write it into the file it starts the server with
// (`kido-tmux -f`). It is a file rather than a Go string so that it reads
// as tmux configuration and can be tried with `source-file` as it is.
package tmuxconf

import _ "embed"

//go:embed kido-tmux.conf
var Defaults []byte
