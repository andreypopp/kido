# Program status

How kido decides what a pane is: a terminal, an agent or a wired in pi agent,
and what state each of those is in.

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
variable. kido reads each pane's records from `#{pane_program_status}`:

A program may report several records, each under an `id`; ids nest with
`/` (`build`, `build/test`). The [root record](https://www.superlogical.com/rex/docs/build/program-status#records-and-ids)
is the one reported without an id: the program's own overall status.

- `app` of the root record: the program that
  owns the pane. A root whose app is `pi` or `claude-code` makes the pane
  an agent.
- `state`: idle is idle, working is running, blocked is waiting and asks
  for attention, done and error are done and failed and ask for
  attention until seen.
- `msg`: the row's caption; `progress` follows it.
- `title`: the row's title for a `Terminal`'s record.

Records other than the root are drawn under the pane's row as child
rows, nested by id, in id order: the record's `title` (its id when
empty), its state as the indicator, its `msg` as the caption. They are
for display only and take no cursor or clicks. Claude Code reports each
of its subagents this way, titled by the subagent's description.

A pane shows its **representative** record: the most urgent of blocked,
error, working, done, idle. Visiting a pane marks its done and error
records seen, and a seen record is skipped until a newer report.

### OSC 133

The shell marks the parts of its command cycle:

- `A`: a prompt starts. `N` is the same, also starting a new command.
- `C`: the user's command line was entered and the command starts
- `D`: the command finished, with its exit status.

kido reads them through `#{pane_last_prompt_time}` and `#{pane_command_*}`

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

A pane's kind, `pane_kind`, is computed once per pane, every tick, in this order:

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

- Detected: no agent root app, no believed ssh mark. Any other
  program's records still drive its indicator and caption.
- Title: `#{pane_command_line}` while an OSC 133 command runs, otherwise
  `#{pane_current_command}`; a record shows its own `title`, then its `app`.
- Indicator: the shell phase from OSC 133; with any records present (a
  plain tool's OSC 7501 or OSC 9;4), the representative record instead.
  A program on the alternate screen shows no indicator.
- Caption: the record's `msg` and progress, if any.

### `Some_agent { name }`

- Detected: the root record's app. Examples: Claude Code
  (`app=claude-code`), pi without kido's extensions (`app=pi`, no State).
- Title: the pane title, or `name` when that is empty.
- Indicator and attention: the representative record.
- Caption: the representative's `msg`, then its progress.
- Supports: `kido prompt`, by paste, when it is the only agent in scope.

Pi and Claude Code report their status through OSC 7501.

### `Pi_agent`

- Detected: root app pi and a live State record naming the pane.
- Title: the State `name` when set, otherwise the pane title.
- Indicator, attention and caption: as `Some_agent`, from the pi root
  (pi 1.1's native emitter), with an open ask turning it to waiting and
  `msg` dropped when it repeats the title; the State `activity` is the
  caption when there is no `msg`.
- Stall: a working root and a State report older than the stall
  threshold (heartbeat), unless the host slept since.
- Supports: everything in design.md and design-subagents.md: the inbox
  for `kido prompt` and message_agent/ask/steer/interrupt, name
  addressing when named, list_runs, asks, parent links and run records.

### `Ssh { user; host; pane }`

- Detected: the ssh mark, believed while the pane's command is `ssh`. A
  remote program's OSC 133 and OSC 7501 reach the local pane through ssh
  like any other output; `pane` is the kind of the remote root record.
- Title: `ssh <user>@<host>`, and `: <command line>` while a remote OSC
  133 command runs; with a `Remote_agent`, its title as for a `Some_agent`.
- Indicator: with a `Remote_agent`, its representative record.
  Otherwise, until the first remote OSC 133 prompt the row is an ordinary
  command: running while ssh runs, then succeeded or failed by its exit
  status. Once a remote prompt arrives (a prompt time later than ssh's
  start) the session is interactive and the remote shell's markers drive
  the row: idle at the prompt, running for each remote command.
- Priming: `kido ssh` primes the remote shell when stdin is a terminal,
  there is no remote command and none of `-N -T -W -f -s -n -O -Q -V -G`
  is given; otherwise it runs ssh with the arguments unchanged.

## Precedence

- A pane's OSC 7501 records win over OSC 133 for the indicator while any
  exist; a shell prompt (`A`) clears the non-final ones, and the shell
  phase is back.
- A run's ending wins over everything: a pane whose run has an outcome,
  or is dead, shows the run's name dimmed and its outcome.
- For `Pi_agent`, State gives identity and name, OSC 7501 gives status.
- A pane's kind decides only its row and `kido prompt` scope. Messaging,
  control, list_runs, asks and runs follow live State records, so a local
  pi whose root was cleared or replaced stays reachable.
