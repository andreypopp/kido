// Command kido renders a tmux sidebar listing sessions, panes and their
// processes, with Claude Code sessions badged by activity status.
package main

import (
	"flag"
	"fmt"
	"os"
	"time"

	"kido/internal/tmux"
	"kido/internal/ui"
)

func main() {
	opts := ui.Options{}
	flag.DurationVar(&opts.Interval, "interval", 500*time.Millisecond, "refresh interval")
	flag.BoolVar(&opts.Popup, "popup", false, "popup mode: exit after jumping to a pane")
	flag.BoolVar(&opts.ShowSelf, "show-self", false, "list kido sidebar panes too")
	width := flag.Int("width", 40, "pinned sidebar width")
	flag.StringVar(&tmux.Socket, "socket", "", "tmux server socket path (tmux #{socket_path}); needed when run from a tmux hook")
	pane := flag.String("pane", "", "pane whose window toggle/ensure acts on (tmux pane id); defaults to TMUX_PANE")
	flag.StringVar(&opts.Focus, "focus", "", "pane to select at startup (tmux #{pane_id}); defaults to the client's active pane")
	flag.StringVar(&opts.Client, "client", "", "tmux client to switch on jump; defaults to the client tmux reports for this process")
	// Subcommand form: `kido toggle|ensure|focus [-pane %id] [-width N]`.
	sub := ""
	if len(os.Args) > 1 && (os.Args[1] == "toggle" || os.Args[1] == "ensure" || os.Args[1] == "focus") {
		sub = os.Args[1]
		flag.CommandLine.Parse(os.Args[2:])
	} else {
		flag.Parse()
	}

	if sub != "" {
		self, err := os.Executable()
		if err != nil {
			self = "kido"
		}
		switch sub {
		case "toggle":
			err = tmux.ToggleSidebar(*pane, *width, self)
		case "ensure":
			err = tmux.EnsureSidebar(*pane, *width, self)
		case "focus":
			err = tmux.FocusSidebar(*pane, *width, self)
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, "kido:", err)
			os.Exit(1)
		}
		return
	}

	opts.Width = *width
	// Running inside a tmux side status column (fork with
	// side-status-command): no pane of our own, keep running after jumps,
	// and act on the client that owns the column.
	if os.Getenv("TMUX_SIDE") == "1" {
		opts.Side = true
		opts.Popup = false
		if opts.Client == "" {
			opts.Client = os.Getenv("TMUX_SIDE_CLIENT")
		}
	}
	if os.Getenv("TMUX") == "" {
		fmt.Fprintln(os.Stderr, "kido: must run inside tmux")
		os.Exit(1)
	}
	if err := ui.Run(opts); err != nil {
		fmt.Fprintln(os.Stderr, "kido:", err)
		os.Exit(1)
	}
}
