package main

import (
	"fmt"
	"strings"
)

// The markers around the block setup-tmux keeps in ~/.tmux.conf. Same job
// as the zsh ones: find the block again, rewrite it when the path changes,
// and leave nothing behind when it is deleted by hand.
const (
	tmuxConfBegin = "# >>> kido sidebar >>>"
	tmuxConfEnd   = "# <<< kido sidebar <<<"
)

// tmuxConfUnsafe are the characters a path cannot contain and still be
// written into the block below. The `if-shell` line nests three parsers -
// tmux's, then sh's, then tmux's again for source-file - and there is no
// escape that survives all three: a single quote would end tmux's string,
// and `$`, `#`, a backslash or a backtick would be expanded by sh or by
// tmux rather than taken literally. Spaces are fine, which is the case
// that actually happens; the rest is refused rather than written broken.
const tmuxConfUnsafe = "'\"$#\\`\n\r"

// tmuxConfBlock is the block setup-tmux keeps in ~/.tmux.conf: the
// source-file guarded by the file being there, because the config outlives
// the install. A kido uninstalled, or moved by an upgrade that repointed a
// prefix symlink, would otherwise make every tmux start report a config
// error from a line the user did not write.
func tmuxConfBlock(source string) (string, error) {
	if i := strings.IndexAny(source, tmuxConfUnsafe); i >= 0 {
		return "", fmt.Errorf("cannot source %s from tmux.conf: the path contains %q", source, source[i:i+1])
	}
	return fmt.Sprintf(`%s
if-shell '[ -f "%s" ]' \
  'source-file "%s"'
%s
`, tmuxConfBegin, source, source, tmuxConfEnd), nil
}

// setupTmux makes tmux load the sidebar config that ships with kido, by
// keeping a marked block in the user's ~/.tmux.conf.
func setupTmux() error {
	return installBlock(blockSpec{
		rcName: ".tmux.conf",
		rel:    "kido-side.tmux",
		begin:  tmuxConfBegin,
		end:    tmuxConfEnd,
		body:   tmuxConfBlock,
		reload: "run `tmux source-file ~/.tmux.conf` (or restart tmux) to load it",
	})
}
