// Package shell holds the shell integrations kido ships, embedded so
// `kido ssh` and `kido shell` need no lookup on disk to prime a pane.
package shell

import _ "embed"

//go:embed zsh/integration.zsh
var ZshIntegration []byte

//go:embed bash/integration.bash
var BashIntegration []byte
