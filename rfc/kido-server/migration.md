# Migration: from P1 to `ko` replacing kido (appendix to design.md)

Status: plan, 2026-10-30. Written after P1 landed on the `ko` branch
(nine commits, `bde368f6` to `76ea5374`). It replaces the plan written
before P1.

Decisions the user made on 2026-10-30, which this plan applies:

1. kido as a product ends. `ko` replaces it. The tmux server, the
   launcher, the sidebar, the fork, `kido-tmux.conf`, the shims' tmux,
   `lib_tmux`, `kido rpc` and the stamp all go. The executable is `ko`.
2. The ko terminal client is complete as a UI: one pane at a time
   from a flat list in the sidebar. Never splits, tabs or windows.
3. The agent features move into ko: runs and subagents, the pi
   extension as ko's harness, agent status from OSC 7501 and OSC 133,
   prompt delivery. Agent status shows in the existing sidebar rows.
4. Kido.app keeps all of its current functionality: sessions,
   windows, split layouts, floats, zoom, navigation, the sidebar tree
   and feed, find, images, clipboard, remote hosts. It becomes a ko
   client over HTTP and WebSocket with its libghostty mirror.
5. The layout lives in the ko coordinator as **one JSON document**
   for the whole server that describes sessions, windows, split
   trees, floats, names, order, zoom and active panes, and contains
   pane ids. Not per-pane layout fields, not separate session or
   window resources. The server understands and validates its schema
   and updates it itself when a pane is created or removed. Session
   and window variables live inside it. A client changes it by
   whole-document replace with a revision check: `PUT /layout` with
   the revision the client read, `409` with the current document on a
   mismatch, and the client reapplies its change and retries. Every
   change, server-made or client-made, bumps the revision and is
   announced on `/client`. The terminal client groups its flat list
   by session and still shows one pane at a time.
6. Every pane carries **arbitrary client-set JSON variables**, set,
   read and deleted through the HTTP API and announced as events on
   `/client`. They replace the tmux user options `@kido_session`,
   `@kido_name`, `@kido_inbox`, `@kido_activity`, `@kido_run` and
   `@kido_ssh`. They have a high size limit. They live with their
   pane: an in-place upgrade keeps them, `kill-server` removes them,
   nothing persists to disk.
7. Remote is a ko server attached over an SSH unix-socket forward,
   for both clients. `kido ssh` stays as `ko ssh`: the user often
   sshes to hosts without ko and wants the remote shell primed with
   OSC 133 there. The two are complementary.
8. Images and clipboard are in scope for both clients.
9. Linux measurements are a step.

Earlier decisions stand: no backward compatibility, `kill-server` by
peer pid, the client is its `/client` WebSocket, performance goals
follow kitty's balance.

## 1. Where P1 left the code

P1 delivered, on the `ko` branch:

| part | lines | state |
|---|---|---|
| `ko_pane/` | 1,586 | pty, libghostty-vt, ring, control frames, compression, sanitizer and fuzz targets |
| `ko_vt/` | 894 | the mirror binding, snapshot decoder, terminfo |
| `ko_server/` | 2,894 | `Loop`, `Pane_proc`, `Pane`, `Panes`, `Client`, `View`, `Input`, `Http`, `Connection`, `State`, `Protocol`, `Config`, `Server_stop` |
| `ko_tui/` | 2,080 | the terminal client: mirror, differ, sidebar, keys, outer modes, attach-or-start, `Api` |
| `bin/ko.ml` | 205 | `ko`, `ko server`, `ko kill-server`, `ko api`, `ko version` |
| `test_e2e_ko/` | 2,211 | about 40 Go tests: protocol, streams, state, client under an outer tmux |
| `bench/` | | the P1.3 table against tmux and kitty |

`ko-pane` registers only the title and pwd callbacks. The pinned
libghostty-vt has `GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT` and
`GHOSTTY_TERMINAL_OPT_PROGRAM_STATUS`, and `test_pane.c` feeds OSC 133
and OSC 7501 through a pane, but nothing reports them yet. The server
holds a flat set of panes and no layout. Nothing in `lib/` depends on
the `ko_*` directories, and nothing in them reads kido's state.

The P1 plan said 23 to 34 agent-days. The code landed in one calendar
day of parallel agent work, about 9,700 lines with tests. The
estimates below use the plan's yardstick, about 350 lines of new code
with tests per agent-day, against the lines each stage must write or
move. Calendar time is much shorter than agent-days when stages run
in parallel.

## 2. What Kido.app uses tmux for today

From design-app.md and `app/App/*.swift`. Each row names what ko
supplies instead.

| today | ko |
|---|---|
| sessions and windows: `list-sessions`, `list-windows`, `new-session -d -s -c`, `new-window -a`, `kill-session`, `kill-window`, `rename-session`, `rename-window`, `select-window`, `switch-client -c -t`, `%session-*`, `%window-*`, `%sessions-changed` | the layout document (section 3): its `sessions` and `windows`, edited and `PUT` back; the `{layout}` event; `select` on `/client` |
| the split tree: `split-window -h/-v -c`, `kill-pane`, `move-pane -f/-b`, `swap-pane`, `resize-pane -L/R/U/D/-x/-y`, `resize-pane -Z`, `select-layout -E`, `%layout-change`, `#{window_layout}` as the fork's JSON tree, `#{window_visible_layout}` | the `tree` of each window with cell geometry; a tree edit in a `PUT`, normalized by the server; `DELETE /panes/pane_N` |
| floats: `new-pane -x/-y/-X/-Y -B -T`, `move-pane -z 0`, float geometry in the layout JSON | `floats` in each window with `x, y, cols, rows, border, title, z`, edited in a `PUT` |
| the active pane: `select-pane -t/-L/R/U/D/:.+/:.-`, `%window-pane-changed`, `#{window_active}` | `active` in each window, in a `PUT`; the `{layout}` event |
| window size: `refresh-client -C WxHxXPxYP`, `window-size latest`, hidden-window `resize-pane -x -y` | a `size` message on `/client` for the client's current window; the sizing client of design.md 4.5; the server scales the tree |
| pane content: `%output`, `%extended-output`, `send-keys -H`, `%pause`, `%continue`, `refresh-client -A` | views, snapshots, input events, skips (design.md 4.4, 4.6, 4.7) |
| restore and Load more: `capture-pane -p -r -G -a -S -E`, `-F -L -T -N` metadata, `#{history_size}`, `#{alternate_on}` | a full snapshot; no paging; `/screen` for text |
| find: 5,000-row `capture-pane` chunks | the mirror's own search when full; `/panes/pane_N/search` when partial |
| `clear-history` | the `clear_history` request on the pane |
| images: `capture-pane -G -K -k`, the image-only control client, `image-shm`, `refresh-client -C` pixel size | `/panes/pane_N/images/<id>`, shared memory by name, cell pixels in the `size` message |
| clipboard: OSC 52 through raw output, `send-keys -H` replies | `clipboard_write` and `clipboard_read` on `/client` |
| the feed: `kido rpc` snapshots, `switch-window`, `switch-session`, `new-window`, `new-session`, `reorder`, `prompt-resolve`, `prompt-send` | `status` on each `/panes` row and `{pane, status}` events; the tree built in the app from the layout, the panes and `/runs`; `select` and `switch` on `/client`, a `PUT /layout`, `/prompt` |
| `#{pane_current_path}` for a split's cwd | the pane row's `pwd` |
| `@kido_ssh_args` | the pane variable `ssh.args` |
| discovery: `kido server` JSON, the stamp, `kill-server`, `detach-client` | `/version` and its headers; `ko kill-server`; closing `/client` |
| the pi harness: `set-option -p`, `list-panes -a` | pane variables; `/panes` |

The app loses nothing that this table names. It loses tmux's
`%begin`/`%end` protocol and the two-emulator sync, which is the point.

## 3. The layout document and pane variables

This section is the design that decisions 5 and 6 need. design.md 4.5
and 4.9 and protocol.md 7 now say the same.

### 3.1 The document

One document per server. The coordinator holds it in memory, with a
`revision` that increases on every change. The server validates its
schema and keeps its invariants; it is not opaque client data.

    {
      sessions: [                       in display order
        {id: "session_N", name, vars: {...},
         windows: [                     in display order
           {id: "window_N", name, vars: {...},
            cols, rows, cell_px: {width, height} | absent,
            active: "pane_N", zoom: "pane_N" | null,
            tree: node,
            floats: [{pane: "pane_N", x, y, cols, rows, z,
                      border: bool, title}]}]}]
    }

    node = {pane: "pane_N", cols, rows}
         | {split: "h" | "v", children: [node, ...]}

Structural invariants, refused with `invalid` (400): every live pane
is a leaf or a float of exactly one window; every leaf names a live
pane; a window has at least one pane; a session has at least one
window; `active` and `zoom` name a pane of the window; names are
UTF-8 with no control characters, at most 256 bytes; ids are the
server's. Session, window and pane ids are allocated once per server
life.

Geometry is **normalized**, not refused. A client may omit `cols` and
`rows` on a leaf or a float, or send sizes that do not fit. The
server then fills and rescales them deterministically, as tmux's
`layout.c` does today: a split's children are scaled proportionally
to the parent's size minus one cell per divider; a child with no
size gets an equal share; a new leaf beside an old one takes half;
a float is clamped into the window. The answer and the event carry
the normalized document. Thus the app's split, resize, equalize,
move and swap are tree edits with at most two sizes written, and
the arithmetic exists once, in the coordinator's `Layout` module,
about a thousand lines of OCaml with inline tests over recorded
trees. The app does not get a layout engine of its own.

### 3.2 Changing it

    GET /layout                     -> {revision, layout}
    PUT /layout {revision, layout}  -> 200 {revision, layout}   the normalized document
                                       409 {revision, layout}   the client's revision is stale
                                       400 {kind: invalid, message}
    event on /client: ["layout", {revision, layout}]   on every change

A client reads the document, edits it, and sends it back with the
revision it read. On `409` it takes the current document from the
body, applies its change again and retries. Every change bumps the
revision, whether a client sent it or the server made it:

- A pane is created inside a `PUT`: a leaf or float whose `pane` is
  `{new: {cwd?, command?, env?, vars?, run?}}` instead of an id. The
  server starts the pane and answers with its id in place. `POST
  /panes` goes. A run's window is such a `PUT` by the server itself.
- A pane is removed by `DELETE /panes/pane_N`, by the terminal
  client's `Ctrl+D` on a dead pane, or by its `ko-pane` dying. The
  server removes the leaf and gives its cells to its sibling, or
  removes the float; an empty window and an empty session go.
- The sizing client of design.md 4.5 claims a window by focus or by
  switching to it and sends its size on `/client`. The server scales
  the window's tree to that size and resizes each pane's pty to its
  leaf. The terminal client claims only a window with one pane and
  no floats; a pane inside a split is shown clipped or padded at that
  pane's size, never resized by the terminal client.
- A pane's pty follows its leaf: a `PUT` that changes a leaf's size
  resizes the pane and sends the resize marker on its views.

The document is small: a hundred panes are a few kilobytes, and a
`PUT` during a drag is one message per coalesced gesture step, as the
app's command batches are today. A `409` happens when the server
scaled a window or removed a pane between the read and the write;
the retry costs one round trip.

Per client, the server keeps the current session, window and pane
(`hello` and `select` on `/client`), as design.md 4.5 says. They are
not in the document.

### 3.3 Pane variables

    GET    /panes/pane_N/vars                  -> {name: value, ...}
    PUT    /panes/pane_N/vars/<name>  <JSON>   -> {}
    DELETE /panes/pane_N/vars/<name>           -> {}
    events on /client: ["var", {pane, name, value}] and ["var_deleted", {pane, name}]

A value is any JSON. A name is UTF-8 with no control characters, at
most 256 bytes. Limits, high by decision 6: one value at most 1 MiB,
one pane's variables at most 8 MiB in total, at most 1,024 names per
pane. The value limit equals the WebSocket message cap of protocol.md
1, so an event carries any value whole. The per-pane total bounds the
memory one client can pin and the size of the upgrade state file. A
write over a limit is `invalid` (400). A `{new}` pane in a `PUT`
takes `vars`, so a run's pane has its variables from its first
event. `GET /panes` rows carry each pane's variables.

Variables are client data. The server stores and announces them and
reads none, except that `Model` reads the harness names below under
the trust rule, exactly as kido reads the tmux options:

| tmux option | variable | writer | trust |
|---|---|---|---|
| `@kido_run` | `ko.run` | `ko run` and `ko run-child` with the pane's creation | the sweep checks the run's meta names the pane |
| `@kido_session`, `@kido_name`, `@kido_inbox`, `@kido_activity` | `pi.session`, `pi.name`, `pi.inbox`, `pi.activity` | the harness through `ko api` | believed only while the root OSC 7501 app is `pi` |
| `@kido_ssh`, `@kido_ssh_args` | `ssh.dest`, `ssh.args` | `ko ssh` before it execs ssh | believed only while the pane's foreground process is `ssh` |
| session `@kido-order` | the document's order | | |

Session and window variables live inside the document (`vars` on
each) and change with a `PUT /layout`, under the same limits. An
in-place upgrade (design.md 4.12) writes the document and every
pane's variables into `state.json`. `kill-server` ends the panes, so
nothing remains.

## 4. Rules for the whole migration

- **Coexistence.** kido and ko never share a state directory. kido
  uses `~/.local/state/kido`, ko uses `~/.local/state/ko`. No code
  translates one into the other. Until the cut-over, `main` ships
  kido and the `ko` branch carries ko. A user who wants ko runs it from
  a checkout; its panes are its own.
- **Every pane is in the document.** A pane is created inside a
  `PUT /layout`, never by a bare request. A pane exists in exactly
  one window. The terminal client shows one pane and ignores the
  geometry.
- **The harness contract** stays the run commands and their JSON. The
  extension calls `ko run`, `ko run-child`, `ko runs --json`,
  `ko run-wait --json`, `ko run-stop`, `ko run-outcome`, and replaces
  its tmux calls with `ko api` requests: `PUT` and `DELETE` on
  `/panes/$KO_PANE/vars/<name>` and `GET /panes`. There are no
  `ko pane` commands (decided 2026-10-30). It never opens the socket
  itself; `ko api` does.
- **One model, in the server; no tree.** `Pane_status.observe` and
  the run rules run once, in the coordinator, on events. Their result
  is the `status` field of each pane, read from `/panes` and announced
  as a `status` event on `/client` for the pane that changed. There is
  no `/feed` and no snapshot: a client builds its own tree from the
  layout document, the panes and the runs.
- **Tests move with the logic.** A kido e2e test that checks a run
  rule, a status rule, prompt delivery or a layout operation is
  rewritten against `ko` in `test_e2e_ko/`, with the Go protocol
  client in place of tmux reads. A test that checked a tmux mechanism
  is deleted.

## 5. Stages

Each stage is one unit of work under one manager, or two in parallel
where marked. Each ends with `make verify` green and an on-screen
check by the user. "Deletes" names kido code that the stage makes
dead; the deletion itself happens at the cut-over (S8), so that
`main` keeps working until then.

### S1. Agent and shell status, pane variables, and `ko ssh` (8 to 12 agent-days)

[s1.md](s1.md) is the full specification. In short:

- `ko-pane` reports OSC 133 steps, OSC 7501 reports, the foreground
  process (only on events, never on a timer) and the active screen as
  four control frames.
- The coordinator keeps the shell phase, the record set with the
  fork's rules (64 records, the unchanged-report rule, the clear
  rules), the foreground command and the alternate flag; `Model`
  runs kido's `Pane_status` rules once per change, at most every
  16 ms, and publishes one `status` per pane on `GET /panes` and as
  a `status` event on `/client`. No tree, no snapshot.
- Pane variables: any JSON, 1 MiB a value, 8 MiB and 1,024 names a
  pane, `/panes/pane_N/vars`, `var` events, set through the
  HTTP API only (`ko api` by hand, `ko ssh` directly). The server
  reads only the `pi.*` and `ssh.*` names under kido's trust rules.
- `ko shell` and `ko ssh` from `Shell`, `Prime` and `Ssh`, with the
  mark as `ssh.dest` and `ssh.args`, trusted while the foreground is
  `ssh`; the `ko` and `ssh` shims first on every pane's PATH.
- The terminal sidebar gains one status column with kido's glyphs and
  colours (green `◼`, yellow `◆`, green `✓`, red `◼`, blank) and
  kido's seen rule in the client, and nothing else (decided
  2026-10-30); the rest of the sidebar stays without colours; session
  headers come with S2 and indented subagents with S3.
- Names: code that moves into ko uses ko's names at once (`KO_*`,
  `ko_*`, `share/ko`); only kido's own code keeps kido names until
  the cut-over. The same rule applies to every later stage.

Moves from kido: `Pane_status`, `Pane_kind`, `Program_status` (the
rules, not the tmux format), `Prime`, `Shell`, `Ssh`, `Bin_dir`, the
shell integrations and the shims. Their inline tests move with them.

Tests that close it: s1.md section 11, which rewrites
`program_status`, `claude_program_status`, `child_program_status`,
`render` (shell rows), `ssh_mark`, `ssh_prime`, `ssh_remote`,
`bindir`, `dotfiles`, `login_command` and `pi_coordination_status`
against `ko`, and adds the variable, foreground and idle-wakeup
tests.

Risk: low. The rules exist and are tested; the inputs change from
whole-second tmux formats to nanosecond events, which removes the tie
and the stuck-flag workaround.

### S2. The layout document (7 to 10 agent-days)

Depends on P1 only. Runs in parallel with S1.

Adds to ko, as section 3 specifies:

- `Layout`: the document, its validation, the normalization engine,
  the revision, `PUT` with the `409` path, pane creation inside a
  `PUT` with `vars`, removal, scaling on a `size` message, the `layout`
  event, session and window `vars` inside the document.
- `/client`: `hello {session?, window?, pane?}`, `select`, `switch`,
  the per-client current session and window, the sizing client per
  window. `POST /panes` goes.
- `ko_tui`: the flat list is grouped by session: one header row per
  session with its name, not selectable, then that session's panes in
  document order (windows, then leaves and floats, depth first).
  `Ctrl+Shift+N` adds a window with one pane to the shown pane's
  session, after its window. `Ctrl+D` on a dead pane is
  `DELETE /panes/pane_N`. `Ctrl+Shift+Up` and `Down` move through the
  whole list across sessions. Nothing else changes on screen.
- The CLI: `ko panes [--json]`, `ko layout` (prints the document),
  `ko layout put FILE` for tests and scripts, with the retry.
- Upgrade state: the document is in the state file's shape from the
  start, so S9 adds no field.

Tests that close it: the Go suite edits the document through the
client for every edit of section 2's table and asserts the normalized
document and each pane's pty size with `stty size`; a `PUT` with a
stale revision gets `409` and the current document, and the retry
lands; a server-made change (a pane death) bumps the revision and
reaches a second client; two clients on one window with different
sizes, the sizing rule; removal of the last pane of a window and of a
session; a split tree scaled down to one column per pane and back;
the terminal client's grouped list with three sessions.

Risk: medium. The normalization engine is new code that must agree
with the app's expectations of tmux's arithmetic. The recorded layout
trees of the app's stress harness are its fixtures.

### S3. Runs, subagents, prompt and the harness (10 to 15 agent-days)

Depends on S1 (the trust rule reads the OSC 7501 root) and S2 (a run
is a window).

Adds to ko:

- `Runs` in the coordinator: `runs/<id>/` as `Run` writes it today,
  `pane` as `pane_N`, first-write-wins outcomes through `link`, the
  screen capture through `/panes/pane_N/screen` on the dead pane, the
  sweep in the model tick once per server. The orphan rule reads the
  parent's status from the server's own panes: a `Run` parent by the
  outcome rule, a `Pane` parent when its pane is gone, dead, or shows
  neither a pi root nor `pi.session`. The linger grace and stop
  escalation are server options with the same environment knobs. The
  sweep's close is `DELETE /panes/pane_N`; the last-window refusal
  goes, because an empty session simply ends.
- `POST /runs` creates the run and its window in one server-made
  layout change, in the caller's or `--session`'s session, detached:
  no client is switched. `GET /runs`, `/runs/<id>`, `/runs/<id>/wait`
  (a long poll), `/runs/<id>/outcome`, `/runs/<id>/stop` as
  protocol.md 10.
- The `ko` subcommands `run`, `run-child`, `runs`, `run-wait`,
  `run-stop`, `run-outcome`, `reap`, `prompt`, with kido's flags,
  exit codes and JSON. `KO_RUN_ID` and `KO_RUN_OUTPUT` go into the
  pane's environment; the argv is the pane's command, no wrapper.
- `ko prompt`: `Msg` moves as is. The paste path is one
  `POST /panes/pane_N/input {paste}` and one `{key}` for Enter; the
  pane's bracketed paste mode decides the wrapping, so the 0.1 s
  delay goes. Scope is the caller's window, else its session, as
  today, from the caller's `Ko-Pane` and the document. Exit codes 0,
  1, 4, 5 as today.
- The harness, `share/pi/ko-pi.ts`: the 25 `tmux` call sites become
  the three `ko` commands; `TMUX_PANE` becomes `KO_PANE`; "inside ko"
  is `KO_RUN_ID` set, or `KO_SOCKET` set and `ko` on PATH; "tmux
  session" becomes "session" in every tool description. The inbox,
  the agent map, the envelopes, `run-wait` streaming and the report
  rules do not change. The TypeScript suite's fake `kido` becomes a
  fake `ko` with the same gates; the fake `tmux` goes.
- Runs on `/client`: a `run` event with the run's id, name, parent,
  pane, start and outcome when a run starts or ends, so a client needs no poll of
  `/runs` for its tree. Each client builds the tree itself: `Tree`
  moves to `ko_tui`, which nests a run's pane under its parent's pane
  from the layout, the panes and the runs, as kido's sidebar does
  today. The terminal client lists a session's panes in that order, so
  a subagent follows its parent, indented one column (section 11,
  question 3). Kido.app does the same in Swift (S5).

Moves from kido: `Run`, `Reap`, `Run_wait`, `Run_stop`,
`Run_history`, `Prompt`, `Msg`, `Run_window`'s name checks, the
`run*` and `prompt` bodies of `bin/main.ml`; `Tree` into `ko_tui`.

Tests that close it: the run suites of `test_e2e/` (`run_commands`,
`run_creation`, `runs`, `reap`, `agent`, `async_bash`, `inbox`, `msg`,
`prompt`, `pi_name_ending`, `subagent_elapsed`, `spawn_model`,
`watchdog`, `refusal`, `split_pane`) rewritten against `ko`; the
TypeScript suite green on the fake `ko`; a spawn tree of depth 2
under `ko` that reports, is stopped and is swept, with the parent's
notices asserted.

Risk: medium. Mostly moving tested logic. The new parts are the long
poll in place of the `run-wait` poll and the sweep as a layout
change.

### S4. Linux, CI and the test scaffold (3 to 5 agent-days, in parallel with S2 and S3)

- Run `bench/table.sh` on a Linux box. Record the rows beside the
  macOS rows in p1-mvp.md 6.5. Check `SO_SNDBUF` behaviour, the 4 KiB
  pty read, `memfd_create`, `SO_PEERCRED` and the sanitizer build.
- CI runs `test_e2e_ko` on Ubuntu and macOS with Zig from the
  installer, without the tmux fork.
- The client tests replace their outer kido-tmux with an outer `ko`
  server on a private socket: the test creates a pane that runs the
  inner `ko`, sends keys with `POST /input` and reads the screen with
  `/screen?format=plain`. The outer pane's libghostty-vt answers DA1
  and the kitty keyboard query, so the inner client starts without the
  warning. This removes ko's last use of the fork before S8 deletes
  it.

Risk: low, except that a Linux number can miss a target and force a
tuning step.

### S5. Kido.app as a ko client, text only (20 to 30 agent-days, in the app repo)

Depends on S1 for the status events and S2 for the layout. Its first
step can start at once.

1. Spike 2 of design.md 8, still open: `restore_snapshot` on a
   Ghostty surface in the app's fork, shown on the pen, charset and
   pending-wrap cases of known-issues. 2 to 3 agent-days. A failure
   here changes the app's plan, not the server's.
2. `KoClient` package: HTTP/1.1 and WebSocket over `NWConnection` on
   the unix socket, `/version` and the headers, `/client` with its
   events, `/panes`, `/layout` with the read-edit-`PUT`-retry loop,
   views with the decoder thread, input events, `/runs`, `/prompt`,
   `/search`. Generated from the same fixtures as the Go client.
   The server adds an `instance` field to the `Welcome` event: the
   identity of this server process, which survives an in-place
   upgrade. The app reuses a view offset on reconnect only when the
   instance equals the one it saw before, because a new server
   restarts pane ids at `pane_1` and an old offset would resume on an
   unrelated pane. P1 has no such identity; kido's `server_instance`
   served the same purpose.
   The sidebar model moves from replacing a snapshot to applying
   events: `layout`, `status`, `var` and `run`
   update one tree that the app builds from the document, the panes
   and the runs, with the nesting of kido's `Tree`; seen state and
   notifications read the same tree.
3. The layout from the document: `WindowView` and `PaneLayout` read
   `tree`, `floats`, `zoom` and `active` from `layout` events
   instead of the fork's layout JSON; every menu, toolbar, drag and
   gesture is one edit of the document and one `PUT`, coalesced per
   gesture step as the command batches are today. Tabs project the
   current session's windows from the app's tree as today. Sessions,
   windows and floats keep their UI.
4. `PaneView` feeds its surface from a view: a full snapshot on show,
   bytes live, resize markers applied by the mirror, no capture, no
   Load more, no anchors. Find uses Ghostty's search over the full
   mirror; a remote partial mirror uses `/search`.
5. Delete `TmuxControl`, `PaneSync`, `HistoryCapture`,
   `SearchCapture`, `ScrollAnchor`, the image client, the `-G`/`-K`
   fill, the marker hack, pause recovery, the `kido rpc` subprocess
   and its reconnect, the server-stamp discovery; from the fork the
   authoritative grids, held placements, fill images,
   `restore_output`, the manual-IO reply suppression and the
   prepend-history atomics.

Tests that close it: a local window on ko passes the pen, charset,
wrap and reflow cases that fail today; resize and 100k-line restore
timings against the P1 table; two windows on one server with
independent current windows and the sizing rule; the stress harness
on layout edits; the off-screen sidebar, tabs, prompt and notification
tests on recorded `/client` event sequences from `ko`.

Risk: medium. The app part deletes more than it adds, but it is the
largest refactor of the plan, and the fork change is the one spike
P1 did not run.

### S6. Images and clipboard, both clients (8 to 12 agent-days)

The terminal client part depends only on P1; the app part on S5.

- `ko-pane`: `KITTY_IMAGE_PAYLOAD` filtering for `images=none`; the
  `snapshot` frame's `images` field; the `image` frame that copies an
  image's pixels once into a per-image shm object `/ko-<pid>-<n>`
  (0600, under 31 bytes) and answers with its name and geometry, or
  `not found`; `image_gone` when it unlinks one on eviction, a new
  generation or exit; the clipboard callbacks as `clipboard_write`
  and `clipboard_read` frames. Pixels never go through the ring: an
  image can exceed its 1 MiB, every attaching client reads the same
  pixels again, and a local client maps the object directly.
- `Images` in the coordinator: `GET /panes/pane_N/images/<id>`; the
  name to a local client with `Ko-Accept-Shm`, else the pixels
  streamed from the coordinator's own mapping; the `<dir>/shm` leak
  record kept by the coordinator from `ko-pane`'s replies and
  `image_gone`, cleaned at start and after a `ko-pane` crash
  (protocol.md 5, 14).
- `Clipboard` in the coordinator: one answerer by focus, the 8 s
  deadline, `clipboard_answer` on `/client` (protocol.md 9).
- `ko_tui`: kitty passthrough of placements to an outer terminal that
  answers the kitty query, nothing drawn otherwise; OSC 52 writes
  forwarded to the outer terminal; reads answered by an OSC 52 query
  to the outer terminal through the reply router of P1.2.
- Kido.app: the zero-copy path on the mapped object, pixel bodies
  remotely, consent and grants unchanged.

Tests that close it: an image uploaded with `t=s` is shown by the
app without a copy and fetched as a body by a remote client; a
placement survives detach and reattach; an evicted image is 404 and
its object is gone; a killed `ko-pane` leaves no object after the
coordinator's cleanup, and a killed coordinator none after the next
start; one
clipboard read gets exactly one answer with two clients attached; an
OSC 52 write reaches the outer terminal from the terminal client.

Risk: medium. Shared memory by name is spike 5, not yet run.

### S7. Remote over SSH (6 to 10 agent-days)

Depends on S5 for the app; the terminal client part on P1.

- `ko user@host`: the client starts an `ssh -M -N -T` master with a
  private `ControlPath`, asks for a unix-socket forward with
  `-O forward -L <local>:<remote dir>/socket`, and connects to
  `<local>` as to a local server. Nothing runs on the remote besides
  `ko`. The remote server starts only on an explicit
  `ssh host ko server`, never by the client.
- Kido.app: the same forward on the master it already owns
  (design-app.md, "Transport and discovery"); discovery reads
  `/version` through the forward instead of running `kido server`.
- Reconnect by offset, gated on the `Welcome`'s instance (S5),
  `deflate` on history and image bodies,
  `permessage-deflate` on `/client`.
- Measured: attach, 100k-line restore and echo at 50, 150 and 300 ms
  RTT, with a throttled link.
- `ko ssh` (S1) stays beside this: a host without ko gets a primed
  shell in a local pane; a host with ko gets a full attach.

Tests that close it: a real localhost sshd (`KO_E2E_HOST_SSH=1`, the
CI step kido has today) with the forward, attach, detach and
reconnect; master loss and recovery; the RTT table.

Risk: medium. The transport is standard; the app's lifecycle code
already exists for a stdio transport and changes shape.

### S8. The cut-over (5 to 8 agent-days)

Depends on S3, S5, S6 and S7. One unit of work that merges `ko` into
`main`.

- Delete from the kido repo: `lib_tmux/`, `third_party/tmux`,
  `scripts/install-tmux-fork.sh`, `share/tmux/`, the `tmux` shim,
  `bin/main.ml`, `bin/kido_sidebar.ml`, `bin/sidebar_theme.ml`,
  `lib/launch.ml`, `lib/state.ml`, `lib/sidebar.ml`,
  `lib/protocol.ml`, `lib/server_dir.ml`,
  `lib/tmux_vars.ml`, the fixtures, `test_e2e/`, `share/rpc/`, the
  fork sections of CI and `scripts/verify.sh`,
  `scripts/fork-sanitize.sh`, `make clean-forks`, `make e2e`,
  `make flake`'s fork path.
- Rename: the package and executable are `ko`; `kido-pi` becomes
  `ko-pi`; `share/kido` becomes `share/ko`; every `KIDO_*` variable
  becomes `KO_*` (section 7); the pi state directory becomes `ko-pi`.
- `ko.conf` is not added. `ko server` keeps its command-line options.
- `make install`, `scripts/release.sh` and the Homebrew tap ship `ko`
  (section 11, question 4). `make preview-pi` targets `ko-pi.ts`.
- Docs: section 8. `rfc/kido-server/` moves into `docs/` as ko's
  design and is deleted as an RFC, per AGENTS.md's rule for plans.
- The website describes ko.
- Kido.app's release follows with the ko client as its only
  transport.

Tests that close it: `make verify` with no tmux on PATH;
`scripts/lint.sh` on the new docs; the TypeScript suite; a fresh
install from the tap on a clean machine attaching to a new server.

Risk: low in code, high in omissions: the stage is mostly deletion
and prose, and `lint.sh` finds stale references only in the files it
knows.

### S9. Upgrade in place (6 to 10 agent-days, after the cut-over)

design.md 4.12: the state file with the document and the variables,
`execve` with inherited rings and control sockets, the per-pane
`ko-pane` handoff over `SCM_RIGHTS`. Spike 4 first (1 agent-day).
Until then a ko upgrade restarts the server and ends its panes, as a
fork bump does under kido today (section 11, question 5).

### Totals

| stage | agent-days | depends on |
|---|---|---|
| S1 status, variables and `ko ssh` | 8 to 12 | P1 |
| S2 layout | 7 to 10 | P1 (parallel with S1) |
| S3 runs and harness | 10 to 15 | S1, S2 |
| S4 Linux, CI, scaffold | 3 to 5 | P1 (parallel) |
| S5 app, text | 20 to 30 | S1, S2 (step 1 at once) |
| S6 images, clipboard | 8 to 12 | P1; S5 for the app part |
| S7 remote | 6 to 10 | P1; S5 for the app part |
| S8 cut-over | 5 to 8 | S3, S5, S6, S7 |
| S9 upgrade | 6 to 10 | S8 |

To the cut-over: 67 to 102 agent-days of implementation, plus review
and verification. The critical path is S2, S5, S6, S7, S8; S1, S3
and S4 run beside S5.

## 6. What happens to each part of kido

### Modules in `lib/`

| module | fate |
|---|---|
| `launch.ml`, `server_dir.ml` | deleted; `ko_server/Config.default_dir` and `ko_tui/Launch` exist |
| `build_id.ml` | moved; `ko version` prints it |
| `shell.ml`, `prime.ml` | moved whole to `ko shell` and `ko ssh` in S1 |
| `bin_dir.ml`, `fs.ml`, `timestamp.ml` | kept as is |
| `tmux_vars.ml` | deleted |
| `state.ml`, `sidebar.ml` | deleted; the model is `ko_server/Model` on events, one `status` per pane; the tree is each client's |
| `pane_kind.ml`, `pane_status.ml` | moved in S1, with new input types |
| `ssh.ml` | moved to `ko ssh` in S1; the mark is two pane variables |
| `msg.ml` | moved as is in S3 |
| `tree.ml` | moved as is into `ko_tui` in S3; Kido.app has the same walk in Swift |
| `reap.ml` | rewritten in S3: the sweep over the server's panes, the close is a pane removal |
| `run.ml` | moved in S3: `pane_N` ids, screen through the protocol |
| `protocol.ml` | deleted; `ko_server/Protocol` is the wire |
| `run_window.ml` | deleted; its name checks move into `Runs`, the window is a server-made layout change |
| `prompt.ml` | rewritten in S3 over `/prompt` and `POST /input` |
| `run_wait.ml`, `run_stop.ml`, `run_history.ml` | moved in S3 over `/runs` |
| `test_fixture.ml`, `view_fixture.ml`, `state_fixture.ml`, `sh.ml`, `test_support.ml` | deleted with their subjects; `Sh` kept if a test still shells out |
| `lib/test/tmux_server/` | deleted |

### `lib_tmux/`, `bin/`, `share/`, the rest

| part | fate |
|---|---|
| `lib_tmux/tmux.ml` | deleted |
| `lib_tmux/program_status.ml` | parsing moved to `ko_server` in S1; the tmux encoding deleted |
| `bin/main.ml` | deleted; `bin/ko.ml` holds the command table |
| `bin/kido_sidebar.ml`, `bin/sidebar_theme.ml` | deleted; `ko_tui/sidebar.ml` takes the glyphs in S1 |
| `share/bin/kido`, `share/shim.sh` | renamed `ko`, kept: bare `ko` in a pane resolves to its prefix |
| `share/bin/tmux` | deleted |
| `share/bin/ssh` | kept; runs `ko ssh` |
| `share/bin/kido-pi` | renamed `ko-pi`; still sets `PI_IMAGE_PROTOCOL=kitty` |
| `share/bash/`, `share/zsh/` | kept as is |
| `share/tmux/` | deleted |
| `share/pi/kido-pi.ts` and tests | renamed `ko-pi.ts`, rewritten at its call sites in S3 |
| `share/pi/testdata/fake_kido`, `fake_tmux` | `fake_ko` kept; `fake_tmux` deleted |
| `share/rpc/contract.md` | deleted; `share/protocol/` holds the schema and fixtures |
| `third_party/tmux` | deleted; `third_party/ghostty` stays |
| `scripts/install-tmux-fork.sh`, `fork-sanitize.sh` | deleted |
| `scripts/verify.sh`, `lint.sh`, `test-ts.sh`, `release.sh`, `ci-like.sh`, `main-watch.sh` | rewritten for ko's stages and names |
| `test_e2e/` | the run, status, prompt, inbox, subagent and split suites rewritten in `test_e2e_ko/` (S3); the rest deleted |
| `website/` | rewritten for ko in S8 |

### Commands

| kido command | ko |
|---|---|
| `kido` (launcher, attach) | `ko` |
| `kido server` | `ko server` (foreground) and `ko` starting one; the JSON endpoint line goes, `/version` replaces it |
| `kido --client NAME` (the popup picker) | deleted; the sidebar is the picker |
| `kido switch-session`, `kido switch-window` | deleted; `Ctrl+Shift+Up` and `Down` in the terminal client; `select` and `switch` on `/client` for the app |
| `kido shell`, `kido shell -- CMD` | `ko shell`, `ko shell -- CMD` |
| `kido ssh` | `ko ssh` (S1) |
| `kido run`, `run-child`, `runs`, `run-outcome`, `run-wait`, `run-stop`, `reap` | the same under `ko` |
| `kido prompt [--window]` | `ko prompt [--window]` |
| `kido rpc` | deleted; `/panes` with `status`, the `/client` events, `/layout`, `/runs`, `/prompt` |
| `kido --version` | `ko version` |
| new | `ko kill-server`, `ko api`, `ko panes`, `ko layout`, `ko layout put`, `ko HOST` |

### Pane options and marks

| option | ko |
|---|---|
| `@kido_run` | the variable `ko.run`, set with the pane's creation |
| `@kido_session`, `@kido_name`, `@kido_inbox`, `@kido_activity` | the variables `pi.session`, `pi.name`, `pi.inbox`, `pi.activity` |
| `@kido_ssh`, `@kido_ssh_args` | the variables `ssh.dest` and `ssh.args`, trusted while the foreground is `ssh` |
| `@kido-order` | the document's session order |
| `@kido-user-command`, `@kido-sidebar-*-style` | deleted; no user tmux config |
| `remain-on-exit` | every pane stays dead until removed (P1) |
| `KIDO_SERVER` (the stamp) | deleted; `/version` and the `Ko-Protocol` and `Ko-Vt` headers |

## 7. Environment variables

| kido | ko |
|---|---|
| `KIDO_STATE_DIR` | `KO_STATE_DIR` (exists since P1) |
| `KIDO_TMUX` | deleted |
| `TMUX`, `TMUX_PANE`, `TMUX_SIDE_CLIENT` | `KO_SOCKET`, `KO_PANE`; no side client |
| `KIDO_RUN_ID`, `KIDO_RUN_OUTPUT` | `KO_RUN_ID`, `KO_RUN_OUTPUT` |
| `KIDO_AGENT_DIR`, `KIDO_AGENT_PARENT_SESSION`, `KIDO_AGENT_TRUSTED_ROOT`, `KIDO_AGENT_TASK_FILE` | `KO_AGENT_*`, same meaning |
| `KIDO_PI_STATE_DIR` | `KO_PI_STATE_DIR`, default `~/.local/state/ko-pi` |
| `KIDO_LINGER_SECONDS`, `KIDO_STOP_ESCALATION_MS` | `KO_*`, read by `ko server` |
| `KIDO_PARENT_POLL_MS`, `KIDO_SPAWN_TIMEOUT_MS`, `KIDO_INBOX_WAIT_MS`, `KIDO_AGENT_LIST_TTL_MS`, `KIDO_STREAM_*`, `KIDO_TIMEOUT_MS` | `KO_*`, read by the harness |
| `KIDO_ORIG_ZDOTDIR` | `KO_ORIG_ZDOTDIR` |
| `KIDO_E2E_REQUIRED`, `KIDO_E2E_HOST_SSH`, `KIDO_TS_TEST_REQUIRED`, `KIDO_FAKE_*`, `KIDO_PREVIEW_PREFIX` | `KO_*` |
| `PI_IMAGE_PROTOCOL=kitty` | kept, set by `ko-pi` |
| `TERM=xterm-ghostty`, `TERM_PROGRAM=ko`, `TERM_PROGRAM_VERSION` | set in every pane (P1) |

The `.pi/extensions/no-git-writes` guard reads `KO_AGENT_PARENT_SESSION`.

## 8. Documents

| document | fate |
|---|---|
| `AGENTS.md` | rewritten: ko's layout, build (zig, luv, httpun), the mirror contract, the pane protocol, the layout document, the test rules; the fork, OSC 133 format-string and tmux gotcha sections go |
| `docs/design.md` | rewritten from `rfc/kido-server/design.md`, with these kido sections kept and edited: who is authoritative for what (variables instead of options), the pi extension, identity, the inbox, addressing, spawning, the login environment, run outcomes, notifying the parent, the sidebar tree, priming a local shell, the bin directory, knobs, known limits |
| `docs/design-subagents.md` | kept; "tmux session" becomes "session", `move-window` becomes `move_window`, the `remain-on-exit` limit goes |
| `docs/design-rpc.md` | deleted; `docs/protocol.md` from `rfc/kido-server/protocol.md` |
| `docs/design-program-status.md` | rewritten: events with nanosecond times, no tie, no heal rule, the foreground frame instead of `pane_current_command`, variables instead of options; the matrix keeps all four kinds |
| `rfc/kido-server/p1-mvp.md` | its sections 3 to 6 become `docs/design-ko-server.md`'s record of what was built and measured; the plan parts go |
| `rfc/kido-server/migration.md` (this file) | deleted at the cut-over |
| `lib_tmux/AGENTS.md` | deleted |
| `share/pi/README.md` | edited: `ko-pi`, the ko commands |
| `README.md`, `website/` | rewritten: install, `ko`, Kido.app |
| Kido.app `docs/design-app.md` | "One control client", "Panes", "Images", "Clipboard", "Sidebar" and "Transport and discovery" rewritten for the ko client and the layout document |
| Kido.app `docs/known-issues-app.md` | the resync, reflow, history metadata, anchors, restore latency, image drift, feed restart, prefix bindings, popups, shared remote-session selection and two-responder entries close |

## 9. What the user loses, stated plainly

- In the terminal client: splits, tabs and windows on screen. It
  shows one pane from the list, grouped by session. The layout that
  Kido.app shows exists on the server, and the terminal client walks
  its panes in order.
- tmux key bindings, `kido.conf`, `.tmux.conf`, plugins, hooks,
  `run-shell`, the prefix key, the `C-s` picker popup.
- Copy mode in the terminal client. The wheel scrolls the mirror and
  `Ctrl+Shift+E` opens the scrollback in `$PAGER`.
- Ctrl+Shift chords need a terminal with the kitty keyboard protocol.
  Terminal.app gets the warning line and mouse switching (p1-mvp.md
  10).
- Attaching with any tmux client, or scripting the server with tmux
  commands. `ko api`, `ko layout put` and `curl --unix-socket` remain.
- Linked and grouped sessions. Per-client current window is what
  grouped sessions gave.
- A pane that outlives a server crash. Until S9, a ko upgrade ends
  the panes too.
- The sidebar's message and progress text in the terminal client;
  Kido.app shows them.

## 10. The cut-over

- **Until S8**, `main` ships kido. The `ko` branch carries ko and
  rebases on `main` when kido changes. The user can run `ko` from the
  checkout from S3 on, because the state directories differ. Kido.app
  stays on tmux until S5 ships in the app repo; its ko client lands
  behind no flag, as a new app release that needs a ko server.
- **At S8**, the `ko` branch merges into `main` in one unit of work
  that deletes the parts of section 6, renames the rest, rewrites the
  docs and cuts the tap. `make install` installs `bin/ko`,
  `bin/ko-pane`, `share/ko`. No release of kido follows; the `kido`
  formula gets no further revisions.
- **After S8**, a user who still runs kido has a running tmux server
  that ko does not read. The user ends it with `kido-tmux -S
  ~/.local/state/kido/socket kill-server` and deletes the directory.
  Run records under `~/.local/state/kido/runs` are not migrated.
- **Kido.app** releases its ko version the same day. An older Kido.app
  on a machine with only ko finds no `kido` and shows its install
  banner.

## 11. Open questions for the user

Only real decisions. Each has a recommendation.

1. **When does the cut-over happen?** After S7, when both clients have
   images, clipboard and remote; or after S5, with images, clipboard
   and remote following on `main`. Recommendation: after S7. Kido.app's
   remote hosts and images are in daily use; cutting over before them
   removes features the user has. The user runs `ko` from the checkout
   from S3 on, so nothing waits for the cut-over to be used.
2. Decided 2026-10-30: `kido ssh` is kept as `ko ssh` (S1), with the
   mark as the pane variables `ssh.dest` and `ssh.args`, beside the
   remote attach of S7.
3. **Subagent rows in the terminal client's list.** Decided for S1:
   one status column before the title, nothing else. Still open for
   S2 and S3: the session header rows of decision 5 and the order of
   run panes. Recommendation: inside a session the list is in feed
   order, so a subagent's pane follows its parent's pane and is
   indented one column; `Ctrl+Shift+Up` and `Down` visit every pane
   in that order with no skipping; the message and progress text are
   not shown. Accept, or ask for a second row line.
4. **Names.** Decided: code that moves into ko takes ko names in its
   stage (S1). Still open: the Homebrew formula and the project name
   at the cut-over. Recommendation: a new formula `ko` in
   `andreypopp/homebrew-tap`, and leave the `kido` formula at its
   last revision. The repo and website can keep the kido name for the
   project, or rename; that is a product-name choice this plan does
   not need.
5. **Upgrade in place.** Before or after the cut-over. Recommendation:
   after (S9). A fork or config change restarts kido's server today,
   so the cut-over loses nothing here, and S9 needs spike 4 first.
6. **Geometry in a `PUT`: normalized by the server, or exact and
   refused when inconsistent?** Recommendation: normalized (3.1).
   With an exact rule the app needs its own split, resize, equalize
   and scale arithmetic in Swift beside the server's, and a `409`
   retry after a server scale would have to recompute every size.
   Normalization keeps one engine and makes a client edit a tree
   edit with at most two sizes.
7. **A new session from the terminal client.** `Ctrl+Shift+N` adds a
   window to the shown pane's session. A session is created by
   Kido.app or by `ko layout put`. Recommendation: no key for it in
   the terminal client until asked; the grouped list already shows
   sessions that the app made.
8. **Copy mode in the terminal client.** Wheel and pager only, as P1
   ships, or copy mode before the cut-over. Recommendation: wheel and
   pager; add copy mode on demand after S8.
