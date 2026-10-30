# Migration and effort (appendix to design.md)

## 1. Coexistence rule

tmux-kido and ko never share a state directory. Each kido
binary knows both until stage 4; the launcher selects by `ko.conf`
(`server = tmux | ko`) with tmux as the default until stage 4 flips it.
No code path translates one into the other. A user who switches runs
two servers for a while, in two directories.

The pi extension and the CLI talk to whichever server their pane is in.
A pane under tmux has `TMUX`; a pane under ko has
`KO_SOCKET` and `KO_PANE`. The extension branches on that at the
few call sites that touch the server (today 24 `tmux` mentions in
`share/pi/kido-pi.ts`, all behind a handful of helpers).

## 2. What changes where

### kido (OCaml)

New: `ko_pane/` (the pane process, in C), `ko_server/` (the modules of
design.md 4.2), `ko_vt/` (the mirror binding), `bin/ko.ml`, C stubs for
peer uid and `shm_open`, the opam packages `luv`, `httpun` and
`httpun-ws`, a
`third_party/ghostty` submodule (the same revision as the app's fork, or upstream once the app's renderer commits
no longer need a fork) built by zig into `libghostty-vt.a` through a
dune rule, as `install-tmux-fork.sh` builds tmux today.

Changed: `Server_dir` (unchanged rules, new socket owner); `Launch`
(start `ko`, no `server.conf`, no stamp; the version triple
replaces it); `State` and `Sidebar` (the model runs in the server; the
TUI consumes the feed); `Prompt` (requests instead of tmux calls);
`Run`, `Reap`, `Run_wait`, `Run_stop` (library code moves into the
server, the CLI sends requests); `Protocol` (the JSON RPC becomes a
thin bridge over the binary protocol for one release, then goes).

Removed at stage 4: `lib_tmux/`, `share/tmux/`, the `tmux` shim,
`scripts/install-tmux-fork.sh`, the stamp, `third_party/tmux`.

### Kido.app (Swift, Ghostty fork)

New: a `KoClient` package (an HTTP/1.1 and WebSocket client over
`NWConnection`, the view record decoder, JSON types) that
replaces `TmuxControl` (952 source lines today, 2758 with tests). A `restore_snapshot` surface
API in the Ghostty fork, which swaps the surface's terminal for the
decoded one; there is no history prepend.

Removed from the fork when stage 1 lands: authoritative grids, held
placements, fill images, `restore_output`, the manual-IO reply
suppression (the mirror has no pty; nothing to suppress), the
prepend-history atomics. Kept: the renderer commits (pixel scroll,
stable rows, tokened renders, blink and compression timers, selection
and clipboard embedder APIs, shm images without a copy).

Removed from the app: `PaneSync`, `HistoryCapture`, `SearchCapture`,
`ScrollAnchor`, the image client, the `-G`/`-K` fill, the marker hack,
pause recovery, the `kido rpc` subprocess and its reconnect, the
server-stamp discovery. Kept: everything visual, consent, seen state,
notifications, the palette, drags.

### pi extension

`tmux set-option -p` becomes `kido pane set-agent`; `list-panes`
discovery becomes `kido panes --json` (a `topology.get`). `TMUX_PANE`
becomes `KO_PANE`. The inbox, the agent map, `run-wait` streaming and
the envelopes do not change.

### e2e

The harness talks to `ko` through a Go client of the protocol
(generated from the same vectors) instead of an outer tmux for most
tests. The outer tmux and pty stay only for terminal-client tests. The
fake `node` binaries that emit titles and OSC 7501 keep working, because
panes are still ptys.

## 3. Stages

Each stage ends with `make verify` green in both repos and an on-screen
check by the user. Effort is agent-days of implementation; add about a
third for review and verification under the manager structure.

### P1: the MVP (20 to 30 days)

[p1-mvp.md](p1-mvp.md): `ko_pane`, `ko_vt`, `ko_server`, `ko_tui`,
`bin/ko.ml`,
flat panes, one on screen, a sidebar, benchmarks. Stages 1 to 5 start
from this code and add sessions and windows, kido's features, the app,
images, remote and the retirement of tmux.

### Stage 0: spikes 2 and 4 (3 to 4 days, in parallel with P1)

design.md section 8. Go/no-go on option C after spike 2. Spikes 1 and
3 and the transport and Mosaic spikes are inside P1.

### Stage 1: server core and the app on it, local, text only (25 to 35 days)

- `ko_pane` beyond P1: images with shared memory, clipboard frames,
  search; `ko_vt`: the mirror binding, about 30 stubs with inline
  tests against recorded streams.
- `Pane_proc`, `Loop`, `Pane`, `Window`, `Session`, `Topology`, `Client`,
  `View`, `Input`, `Http`, `Config`: the server with views, backpressure,
  snapshots, markers and the topology requests. Unit tests on the pure
  parts; a Go e2e suite against a real server for the rest.
- App: `KidoProtocol`, the fork's `restore_snapshot`, a `PaneView` that
  feeds its surface from a view, the layout from `topology`. One local
  window, no images, no clipboard, no remote, no feed (the sidebar is
  empty or shows the topology tree without status).
- Milestone: a local Kido.app window on ko passes the
  pen/charset/wrap/reflow cases that fail today, with resize and
  10k-line restore timings reported.

Risk: medium. The binding and the view machinery are new code; the app
part deletes more than it adds.

### Stage 2: kido CLI, runs, model and feed in the server (15 to 25 days)

- `Runs`, `Model`, the feed event; `kido run*`, `runs`, `prompt`,
  `switch-*`, `panes`, `pane set-agent`, `ssh` mark over the protocol.
- The pi extension on `KO_SOCKET`; its TypeScript suite with a fake
  server.
- The app's sidebar on `feed.subscribe`; notifications and seen state
  unchanged.
- e2e: the run, reap, prompt, status and subagent suites on the Go
  client.
- Milestone: an agent tree spawned under ko shows and reaps
  as under tmux, with the e2e suites green.

Risk: medium. Mostly moving tested logic; the new parts are the
subscription replacing polls.

### Stage 3: images, clipboard, remote (12 to 18 days)

- Images: `GET /panes/pane_N/images/<id>`, server-owned shared-memory
  copies by name on a local server; the app's zero-copy path on the
  mapped object.
- Clipboard routing with one answerer; 5522 paste events.
- The SSH unix socket forward, reconnect over it, deflate;
  the app's SSH master opening the forward; measured 50/150/300 ms RTT numbers.
- Milestone: parity with today's app on images and remote, with the
  image client and `-K` paging gone.

### Stage 4: terminal client and retirement (15 to 25 days)

- `ko` as the terminal client beyond P1: windows and splits in the
  mirror layout, side column from the feed, the sidebar as picker,
  the fixed key set, wheel scroll, kitty passthrough.
- The launcher starts ko by default; `ko.conf` replaces
  `kido-tmux.conf`; shims lose `tmux`.
- Delete `lib_tmux`, the fork, the installer, the stamp, `kido rpc`.
- Milestone: `make verify` with no tmux on PATH.

### Stage 5: upgrade in place, then iOS (8 to 12 days, then separate)

- `Upgrade`: encode, exec, resume; the launcher and the app's Restart
  use it; a failing decode degrades per pane.
- iOS: a libghostty-vt mirror over an SSH channel, one pane at a time,
  `ignore_size`; the ios-app-idea note's plan on this protocol.

## 4. What the user loses, stated plainly

- tmux key bindings, `.tmux.conf`, plugins, hooks, `run-shell`.
- Copy mode in a plain terminal, until a later version adds it to
  the terminal client.
- Linked and grouped sessions. Two app windows on one session now have
  independent current windows, which is what grouped sessions gave.
- Attaching with any tmux client. Only kido clients attach.
- A pane that outlives a server crash. An upgrade keeps panes; a crash
  does not.

## 5. Open questions for the user, not blocking the spikes

1. Should the terminal client get copy mode in stage 4, or does the app
   cover scrollback reading well enough that a terminal gets the wheel
   only? Recommendation: wheel only; add copy mode on demand.
2. Closed (design.md 4.3): kido's ghostty submodule pins the app's
   fork revision, because the mirror needs the fork's pending-image
   behaviour for refused kitty media.
3. `ko.conf` format: tmux-like `key value` lines, or TOML?
   Recommendation: `key = value` lines with no sections, parsed in
   OCaml, since the app's `kido-app.conf` is already Ghostty's format
   of that shape.
