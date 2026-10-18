# Program status

kido identifies each pane as a terminal, an agent or a pi agent with
kido integration. It also identifies the state of each pane.
kido reports classification and semantic status (`Pane_status`).
Each frontend controls glyphs, labels, captions and seen outcomes.

kido classifies a pane with these sources:
- what its programs transmit to the terminal:
  - OSC 7501 ([spec](https://www.superlogical.com/rex/docs/build/program-status))
  - OSC 133 ([semantic prompts](https://gitlab.freedesktop.org/Per_Bothner/specifications/-/blob/master/proposals/semantic-prompts.md))
  - the pane title, OSC 0/2 ([xterm control sequences](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h3-Operating-System-Commands))
- presence of state and run records (only for local pi agents)
- the pane option `@kido_ssh`, set by kido's ssh shim

## Sources

### OSC 7501 records

tmux puts the OSC 7501 payload in the per-pane variable
`#{pane_program_status}`. Topology is the authoritative source.
Every topology read includes this variable in `State.format` and
parses it once into the pane. This applies to control-mode and one-shot
views. `%program-status` notifications only wake the tick.
kido ignores their payload.
When it parses records, kido removes any working record with progress 0
and no app, title or msg.

A program can report several records, each under an `id`.
IDs nest with `/` (`build`, `build/test`). The [root record](https://www.superlogical.com/rex/docs/build/program-status#records-and-ids)
has no id and reports the program's overall status.

The records supply:

- `app` of the root record: the program that owns the pane.
  If the root app is `pi` or `claude-code`, the pane is an agent.
- `state`: idle, working (running), blocked (waiting), or the final states
  done and error. Blocked has an optional kind: permission, question or
  auth. kido removes an unknown kind. Done and error produce outcomes
  (below).
- `msg` and `progress`: the status message and progress.
- `title`: a `Terminal`'s title.

The frontend draws non-root records as child rows under the pane row,
nested by id, in id order. Each child row shows:

- The record's `title`, or its id if the title is empty.
- Its raw state as the indicator.
- Its `msg` as the caption.

A visit does not acknowledge these records. They are only for display
and do not accept the cursor or clicks. Claude Code reports each subagent
this way, with the subagent's description as its title.

`Pane_status.observe` reduces all records for a pane to one status.
A terminal's generic report and an agent use this order: blocked >
working > idle. The smallest bytewise id resolves ties.

The **representative** record supplies the message and a terminal's title.
It is the first available record in this order:

1. Blocked.
2. Working.
3. The retained outcome's record.
4. Idle.
5. Any record.

An **outcome** occurs when a record enters done or error from another
state or from absence. This includes first observation, reappearance,
and transitions from done to error and back. The outcome has that read's
pane serial. An unchanged final record never makes another outcome,
even if its message, title or serial changes. Entries in one read use
the smallest id.

The outcome shows at aggregate idle. If it arrives while other records
work, it waits. A new live episode after idle clears it. Removing a
record keeps its outcome. `since` is when the feed first observes the
current state, or the current outcome at idle.

Tracking resets when:

- An agent's root app changes, appears or clears.
- Its pane run changes.
- An ssh destination changes.

A terminal report's app change or removal does not reset tracking.
Thus, its outcome remains after the program exits and clears its records.
It remains until a command is promoted to running or a new report
episode begins.

`Tmux.Program_status` controls record types, parsing, encoding, root and
app lookup, and progress extraction. `Pane_status` controls reduction and
tracking. Each frontend controls acknowledgement.

### OSC 133

The shell marks the parts of its command cycle:

- `A`: a prompt starts. `N` has the same meaning and also starts a new
  command.
- `C`: the user has entered the command line, and the command starts.
- `D`: the command finishes and reports its exit status.

kido reads these markers through `#{pane_last_prompt_time}` and
`#{pane_command_*}` to determine the shell phase:

- Unknown: kido has seen no prompt, as with an unintegrated shell.
  This is not idle.
- Idle: the shell is at a known prompt. kido captures the last command's
  complete exit information from one read while tmux still holds it:
  code, command line, start and end. A `C` without a `D` gives no exit.
  A later prompt does not mean success.
- Running: kido observes a command for 0.2s on its clock, starting from
  the first observation. A new start restarts the wait. Until promotion,
  kido reports the previous Idle, so a short command never reports running.
  Promotion removes the previous exit and any report outcome from before
  the command.
- The alternate screen reports running immediately (`fullscreen`).
  It keeps the OSC 133 command if known. Otherwise, its origin is unknown.
  If that command still runs when the alternate screen ends, the phase
  remains running.

### Pane title

kido reads OSC 0/2 through the tmux variable `#{pane_title}`.

An agent row uses this title without changes for `Some_agent` and for `Pi_agent`
without a `/name`. A `Terminal` row does not use it.

Claude Code sets `Claude Code` at startup, then a session summary
(observed: `Reply with ok`).

### Run records

Every tracked process has one run, `<state>/runs/<run-id>/`. Its
`meta.json` contains launch metadata: kind (pi, agent, bash or stream),
name, parent and start. It contains the outcome after the run ends. The
run's pane has the `@kido_run` mark. See
[design-subagents.md](design-subagents.md).

Each local pi session with a UI that runs kido's extensions
(`kido-status.ts`) claims the run of its session id. Its `pi.json`
contains:

- pid
- Pane
- Name (pi's `/name`)
- Inbox socket
- pi session file
- Model
- Activity text
- Report time: the last identity report. `list_runs` orders agents by it.

These records supply identity and coordination. The claim also sets
`@kido_run` on the pi's pane. The pane's run is the run that the mark
names, if its `pi.json` names the pane and a live pid.

### The ssh mark

kido's `ssh` shim runs `kido ssh`. This command resolves the destination
with `ssh -G`. It sets the pane option `@kido_ssh` (`set-option -p`) to
`<user>@<host>` immediately before it replaces itself with ssh.
It never unsets the option. kido trusts `@kido_ssh` only while
`#{pane_current_command}` is `ssh`. The next `kido ssh` in the pane
overwrites it.

Before exec, `kido ssh` also sets the pane option `@kido_ssh_args`.
Its value is a JSON array of strings. The last element is the destination
as entered, not the host from `ssh -G`. The preceding elements are ssh
options and their values, in the user's order, before the destination.
Grouped options and attached values become separate elements. ssh parses
options before and after the destination, until `--` or the first remote
command argument. `--` before the destination also stops option parsing
after it. The remote command is not included.

A consumer must put its required `-o` settings before the recorded
arguments. OpenSSH uses the first value for each setting. For example,
`-o BatchMode=yes` must precede a recorded `-o BatchMode=no`.
The recorded `-o` values stay unchanged.

The command keeps these options:

- `-p`, `-J`, `-F`, `-i`, `-l`, `-o`: port, jump hosts, configuration,
  identity, user and configuration options. Each `-o` value stays intact.
- `-4`, `-6`: address family.
- `-B`, `-b`: interface and source address.
- `-c`, `-m`: cipher and MAC selection.
- `-I`, `-K`, `-k`: PKCS#11 provider and GSSAPI authentication.
- `-P`: configuration tag.
- `-C`: compression.
- `-S`: control socket. A new connection can use the same master.

It removes `-t`, `-T`, `-L`, `-R`, `-D`, `-A`, `-a`, `-g`, `-X`,
`-Y`, `-x`, `-N`, `-f`, `-n`, `-q`, `-v`, `-y`, `-E` and `-e`.
These options control the terminal, forwarding, background operation,
stdin, messages, logs or escape characters, not the connection target.

It does not record `-O` (a control operation), `-M` (master mode),
`-W` (stdio forwarding), `-w` (a tunnel), `-s` (a subsystem),
`-G`, `-Q` or `-V` (configuration, query or version output).
These modes cannot supply an ordinary remote command. An unknown option,
a missing option value, an absent, empty or hyphen-prefixed destination,
or invalid UTF-8 in any argument also prevents recording. Valid non-ASCII
text stays intact. JSON escaping preserves control bytes.

Each call replaces `@kido_ssh_args`, or unsets it if the arguments cannot
be recorded. The value remains after ssh exits. The command sets the
option through tmux argv, without format expansion or a shell command
string. If the set fails, it attempts to unset the option. A failed set
or unset does not stop ssh and produces no warning, as with `@kido_ssh`.
If tmux cannot accept the unset, an old value can remain.

A client reads the value with `show-options -p -v -t %P @kido_ssh_args`.
It must use the same foreground-ssh check as for `@kido_ssh`. This option
is not part of RPC. It does not change the RPC protocol or server stamp:
the fork revision, server configuration and launcher environment stay
the same.

## Pane kinds

kido classifies a pane's kind, `pane_kind`, in this order:

1. A trusted ssh mark gives `Ssh`. Its `pane` is the kind of the root
   record from the remote side. If the app is `pi` or `claude-code`, the
   kind is `Remote_agent { name = app }`. Otherwise, it is
   `Remote_terminal`.
2. A root record with `app = "pi"` and a pane run gives `Pi_agent`.
3. A root record with `app = "claude-code"`, or `app = "pi"` without a
   pane run, gives `Some_agent { name = app }`.
4. Anything else is `Terminal`.

A run pane (`@kido_run`) can have any of these kinds. Its run record adds
the run's name, elapsed time and outcome (below).

## The matrix

|                  | local                     | over ssh                                      |
|------------------|---------------------------|-----------------------------------------------|
| shell            | `Terminal`                | `Ssh { pane = Remote_terminal }`              |
| some agent       | `Some_agent`              | `Ssh { pane = Remote_agent }`                 |
| local pi agent   | `Pi_agent`                |                                               |

### `Terminal`

- Detected: no agent root app and no trusted ssh mark.
- Status: the shell phase from OSC 133, plus a separate report from any
  other program's records. This report uses a plain tool's OSC 7501 or
  OSC 9;4 and is present in every phase.
- Title: the representative record's `title`, then its `app`, then
  `#{pane_current_command}`. A live run with no records uses the run name.
  If there is no report, the TUI instead shows the line of a running,
  non-fullscreen command.

### `Some_agent { name }`

- Detected: the root record's app. Examples: Claude Code
  (`app=claude-code`), pi without kido's extensions (`app=pi`, no run).
- Title: the pane title, or `name` when that is empty.
- Status: the records' reduction.
- Supports: `kido prompt`, by paste, when it is the only agent in scope.

Pi and Claude Code report their status through OSC 7501.

### `Pi_agent`

- Detected: root app `pi` and a pane run.
- Title: the `name` in `pi.json` when set, otherwise the pane title.
- Status: as `Some_agent`, from the pi root (pi 1.1's native emitter).
  kido removes `msg` if it repeats the title. If there is no `msg`, the `pi.json` `activity`
  supplies the message.
- Supports: everything in `design.md` and `design-subagents.md`:
  - The inbox for `kido prompt` and `message_agent`/ask/steer/interrupt.
  - Name addressing when named.
  - `list_runs`.
  - Parent links.
  - Run records.

### `Ssh { user; host; pane }`

- Detected: the ssh mark, trusted while the pane's command is `ssh`.
  A remote program's OSC 133 and OSC 7501 reach the local pane through
  ssh like other output. `pane` is the kind of the remote root record.
- Destination: typed `user` and `host`. The TUI labels a remote terminal
  `ssh <user>@<host>`. While an interactive remote command runs, it adds
  `: <command line>`. A `Remote_agent` keeps its agent title.
- Status: a `Remote_agent` uses its records' reduction. Otherwise, the
  pane is an ordinary command until a remote OSC 133 prompt strictly
  later than ssh's start. It reports running while ssh runs. Once that
  remote prompt arrives, the session stays `interactive` for that
  destination. The remote shell's markers then determine the phase.
- Priming: `kido ssh` primes the remote shell if all these conditions apply:
  - stdin is a terminal.
  - There is no remote command.
  - None of `-N -T -W -f -s -n -O -Q -V -G` is given.

  Otherwise, it runs ssh with unchanged arguments.

## Precedence

- A run's ending has the highest precedence. If its run has an outcome
  or the pane is dead, the pane is Ended with that outcome.
  The outcome is unknown until recorded.
- While present, a terminal report has precedence over its shell phase
  for the frontend's indicator and message. A shell prompt (`A`) clears
  the non-final records.
- For `Pi_agent`, the run gives identity and name. OSC 7501 gives status.
- A pane's kind determines only its row and `kido prompt` scope.
  Messaging, control, `list_runs` and runs use runs by id.
  Thus, local pi remains reachable if its root clears or another root
  replaces it.

## Frontends

The TUI makes each row from the title and status:

- Glyphs for running, waiting, or an unseen success or failure.
- A caption from message and progress, or otherwise the run's elapsed clock.
- The result of an ended run.

On each successful tick, it marks the active pane's outcomes seen.
While a modal pane is open, it uses the pane under that modal pane.
An exit that ends before the TUI starts counts as seen.

After a displayed run finishes, the TUI continues to show it running for
0.5s, unless an unseen exit uses the column. If a new command starts
during that hold, the TUI shows it immediately instead of after the
0.2s promotion.
