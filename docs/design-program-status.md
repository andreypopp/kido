# Program status

How kido decides what a pane is: a terminal, an agent or a wired in pi agent,
and what state each of those is in. kido reports classification and
semantic status (`Pane_status`); glyphs, labels, captions and seen
outcomes belong to each frontend.

A pane is classified by:
- what its programs transmit to the terminal:
  - OSC 7501 ([spec](https://www.superlogical.com/rex/docs/build/program-status))
  - OSC 133 ([semantic prompts](https://gitlab.freedesktop.org/Per_Bothner/specifications/-/blob/master/proposals/semantic-prompts.md))
  - the pane title, OSC 0/2 ([xterm control sequences](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h3-Operating-System-Commands))
- presence of state and run records (only for local pi agents)
- the pane option `@kido_ssh`, set by kido's ssh shim

## Sources

### OSC 7501 records

OSC 7501 payload is handled by tmux into `#{pane_program_status}` per pane
variable. Topology is authoritative: every topology read includes it in
`Tmux_pane.format` and parses it once into the pane, for control-mode and
one-shot views alike. `%program-status` notifications only wake the tick;
their payload is ignored.

The records supply:

A program may report several records, each under an `id`; ids nest with
`/` (`build`, `build/test`). The [root record](https://www.superlogical.com/rex/docs/build/program-status#records-and-ids)
is the one reported without an id: the program's own overall status.

- `app` of the root record: the program that
  owns the pane. A root whose app is `pi` or `claude-code` makes the pane
  an agent.
- `state`: idle, working (running), blocked (waiting, with an optional
  kind: permission, question or auth; an unknown kind is dropped), and the
  final done and error, which produce outcomes (below).
- `msg` and `progress`: the status's message and progress.
- `title`: a `Terminal`'s title.

Records other than the root are drawn under the pane's row as child
rows, nested by id, in id order: the record's `title` (its id when
empty), its raw state as the indicator, its `msg` as the caption. No
visit acknowledges them. They are for display only and take no cursor or
clicks. Claude Code reports each of its subagents this way, titled by the
subagent's description.

All of a pane's records reduce to one status (`Pane_status.observe`):
blocked > working > idle for a terminal's generic report, with an agent
adding an outstanding ask above blocked and stall between blocked and
working. Ties go to the smallest bytewise id. The **representative**
record, which supplies the message (and a terminal's title), is the
first blocked, else working, else the retained outcome's record, else
idle, else any record.

An **outcome** is a record entering done or error, from anything else or
from absence (a first sight, a reappearance, done to error and back),
stamped with that read's pane serial; a final record left unchanged,
however its message, title or the serial move, never makes another.
Entries in one read take the smallest id. The outcome shows at aggregate
idle; arriving while other records work it waits, and a new live episode
after idle clears it. Removing a record keeps it. `since` is when the
feed first saw the current state (or, at idle, the current outcome).
Tracking resets when an agent's root app changes, appears or clears, its
State session changes, or an ssh destination changes. A terminal's report
changing app or clearing does not reset, so a report's outcome survives
the program exiting and clearing its records, until a command is promoted
to running or a new report episode begins.

`Tmux.Program_status` owns the record types, parsing and encoding, root and
app lookup, and progress extraction; reduction and tracking belong to
`Pane_status`, acknowledgement to each frontend.

### OSC 133

The shell marks the parts of its command cycle:

- `A`: a prompt starts. `N` is the same, also starting a new command.
- `C`: the user's command line was entered and the command starts
- `D`: the command finished, with its exit status.

kido reads them through `#{pane_last_prompt_time}` and `#{pane_command_*}`,
into a shell phase:

- Unknown: no prompt has been seen (an unintegrated shell). Not idle.
- Idle: at a known prompt, with the last command's exit (code, command
  line, start and end) captured whole from one read while tmux still holds
  it. A C without a D yields no exit; a later prompt is not success.
- Running: a command observed for 0.2s on kido's clock, from its first
  observation; a new start restarts the wait, and until then the previous
  Idle is reported, so a short command never runs. Promotion drops the
  previous exit and any report outcome from before the command.
- The alternate screen runs at once (`fullscreen`), keeping the OSC 133
  command when one is known and otherwise of unknown origin; leaving it
  while that command still runs stays running.

### Pane title

OSC 0/2, read via `#{pane_title}` tmux var.

An agent row's title, verbatim: a `Some_agent`'s, and a `Pi_agent`'s
without a `/name`. A `Terminal` row does not use it.

Claude Code sets `Claude Code` at startup and then a summary of the session
(observed: `Reply with ok`).

### State records

One per local pi session running kido's extensions (`kido-status.ts`),
keyed by session id: pid, pane, name (pi's `/name`), inbox socket,
parent and depth, model, activity text and the report time (heartbeat).
They carry identity and coordination.

### Run records

`<state>/runs/<run-id>/`: the launch metadata (kind agent, bash or
stream; name, parent, start), the outcome once ended, and the
`@kido_run` mark on the run's pane. See
[design-subagents.md](design-subagents.md).

### The ssh mark

`kido ssh`, which kido's `ssh` shim runs, resolves the destination with
`ssh -G` and sets the pane option `@kido_ssh` (`set-option -p`) to
`<user>@<host>` just before it replaces itself with ssh, and never unsets
it. kido believes `@kido_ssh` only while `#{pane_current_command}` is
`ssh`; the next `kido ssh` in the pane overwrites it.

## Pane kinds

A pane's kind, `pane_kind`, is classified in this order:

1. A believed ssh mark gives `Ssh`, whose `pane` is the kind of the root
   record arriving from the remote: `Remote_agent { name = app }` if its app
   is `pi` or `claude-code`, otherwise `Remote_terminal`.
2. A root record with `app = "pi"` and a live State record naming the
   pane gives `Pi_agent`.
3. A root record with `app = "claude-code"`, or `app = "pi"` without
   such a State record, gives `Some_agent { name = app }`.
4. Anything else is `Terminal`.

A run pane (`@kido_run`) is any of these kinds; its run record adds the
run's name, elapsed time and outcome on top (below).

## The matrix

|                  | local                     | over ssh                                      |
|------------------|---------------------------|-----------------------------------------------|
| shell            | `Terminal`                | `Ssh { pane = Remote_terminal }`              |
| some agent       | `Some_agent`              | `Ssh { pane = Remote_agent }`                 |
| local pi agent   | `Pi_agent`                |                                               |

### `Terminal`

- Detected: no agent root app, no believed ssh mark.
- Status: the shell phase from OSC 133, and a separate report from any
  other program's records (a plain tool's OSC 7501 or OSC 9;4), present
  in every phase.
- Title: the representative record's `title`, then its `app`, then
  `#{pane_current_command}`; a live run with no records uses the run name.
  The TUI shows a running, non-fullscreen command's line instead when
  there is no report.

### `Some_agent { name }`

- Detected: the root record's app. Examples: Claude Code
  (`app=claude-code`), pi without kido's extensions (`app=pi`, no State).
- Title: the pane title, or `name` when that is empty.
- Status: the records' reduction; never stalled.
- Supports: `kido prompt`, by paste, when it is the only agent in scope.

Pi and Claude Code report their status through OSC 7501.

### `Pi_agent`

- Detected: root app pi and a live State record naming the pane.
- Title: the State `name` when set, otherwise the pane title.
- Status: as `Some_agent`, from the pi root (pi 1.1's native emitter),
  with an open ask making it waiting on that ask and `msg` dropped when it
  repeats the title; the State `activity` is the message when there is
  no `msg`.
- Stall: a working root and a State report older than the stall
  threshold (heartbeat), unless the host slept since.
- Supports: everything in design.md and design-subagents.md: the inbox
  for `kido prompt` and message_agent/ask/steer/interrupt, name
  addressing when named, list_runs, asks, parent links and run records.

### `Ssh { user; host; pane }`

- Detected: the ssh mark, believed while the pane's command is `ssh`. A
  remote program's OSC 133 and OSC 7501 reach the local pane through ssh
  like any other output; `pane` is the kind of the remote root record.
- Destination: typed `user` and `host`. The TUI labels a remote terminal
  `ssh <user>@<host>`, adding `: <command line>` while an interactive
  remote command runs; a `Remote_agent` keeps its agent title.
- Status: with a `Remote_agent`, its records' reduction. Otherwise,
  until a remote OSC 133 prompt strictly later than ssh's start, the pane
  is an ordinary command: running while ssh runs. Once a remote prompt
  arrives the session is `interactive`, latched for that destination, and
  the remote shell's markers drive the phase.
- Priming: `kido ssh` primes the remote shell when stdin is a terminal,
  there is no remote command and none of `-N -T -W -f -s -n -O -Q -V -G`
  is given; otherwise it runs ssh with the arguments unchanged.

## Precedence

- A run's ending wins over everything: a pane whose run has an outcome,
  or is dead, is Ended with that outcome (unknown until it is recorded).
- A terminal's report wins over its shell phase for the frontend's
  indicator and message while present; a shell prompt (`A`) clears the
  non-final records.
- For `Pi_agent`, State gives identity and name, OSC 7501 gives status.
- A pane's kind decides only its row and `kido prompt` scope. Messaging,
  control, list_runs, asks and runs follow live State records, so a local
  pi whose root was cleared or replaced stays reachable.

## Frontends

The TUI composes each row from the title and status: glyphs by state
(running, waiting, stalled, an unseen success or failure), a caption from
message and progress or else the run's elapsed clock, an ended run's
result. It marks the active pane's outcomes seen each successful tick,
using the pane under a modal pane while it is open;
an exit that ended before the TUI started is seen. After a drawn run
finishes it keeps
drawing it running for 0.5s, unless an unseen exit takes the column, and
a new command started inside that hold is drawn at once instead of after
the 0.2s promotion.
