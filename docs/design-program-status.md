# Program status

ko identifies each pane as a terminal, an agent or a pi agent with
ko's harness, and the state of each pane. The server computes one
`status` for each pane (`PaneStatus` in `ko_wire/src/protocol.rs`)
and announces a change as a `status` event. Each client controls
glyphs, labels, captions and seen outcomes.

The sources:

- What the pane's programs transmit to the terminal, which `ko-pane`
  forwards as frames ([protocol.md](protocol.md), section 14):
  - OSC 7501 ([spec](https://www.superlogical.com/rex/docs/build/program-status)).
  - OSC 133 ([semantic prompts](https://gitlab.freedesktop.org/Per_Bothner/specifications/-/blob/master/proposals/semantic-prompts.md)).
  - The pane title, OSC 0/2.
  - The foreground process of the pty and the active screen.
- The status route `POST /panes/pane_N/status` (protocol.md,
  section 6), the second edge of the OSC 7501 record set.
- The pane variables `pi.session`, `pi.name` and
  `pi.activity` of pi's harness, only for local pi agents.
- The pane variables `ssh.dest` and `ssh.args`, set by `ko ssh`.

Every time is a nanosecond of the server's monotonic clock. There is
no whole-second tie and no polling: a report is an event.

## Sources

Two programs identify agent panes through OSC 7501 root records:
`pi` (design.md, "The harness extension") and `claude-code`. The
`pi` root comes from koa, which writes it for its RPC pi, or from a
plain pi's own interactive mode. Claude
Code 2.1.295 queries OSC 7501. Then it emits a root `app=claude-code`
record: idle, working, done, or blocked with permission/question kind
and a base64 message. Escape on a permission dialog emits idle
immediately. Exit clears all records.
`CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` also disables this reporting.
Its OSC 0 title is "Claude Code" at startup and "Reply with ok" for
the session. Kido ships no Claude Code shim.

### The record set

`ko_server/src/program_status.rs` keeps one record set for each pane
under these rules. A report comes from one of two edges, and both
produce the one report type, `StatusReport` in
`ko_wire/src/protocol.rs`. libghostty-vt validates an OSC 7501
report before the callback; `ko-pane` and the coordinator parse
nothing of it. The route decodes its body through that type, whose
fields have the limits of Ghostty's parser. Where Ghostty drops an
invalid option, the route refuses the whole body, and an absent field
is omitted, not empty. The route's text is plain, not base64. An OSC
report that a field type refuses after Ghostty accepted it is dropped,
not a fault of the pane. Nothing in the set records the edge of a
report, so every rule below applies to both, and an OSC `clear`
removes a record that the route set.

- A record has an id, a state, and optional app, title, message and
  progress. An empty string in a report is an absent field. The
  [root record](https://www.superlogical.com/rex/docs/build/program-status#records-and-ids)
  has the empty id and reports the program's overall status. Ids nest
  with `/` (`build`, `build/test`).
- The set holds at most 64 records. A new record over the limit
  removes the one updated longest ago.
- A report whose id is in the set and whose fields equal the stored
  record changes nothing: no serial, no event, no move in the
  eviction order. Otherwise the stored record is removed and the new
  one appended, which makes it the newest.
- A `clear` with the empty id removes every record. A `clear` with id
  `x` removes `x` and every record whose id starts with `x/`.
- A primary prompt start (OSC 133 `A`) removes every record whose
  state is not done or error. Pane death and RIS remove every record.
- The set stamps a non-root record with `started`, the server's `Mono`
  time when the set first stored its id. A later report of the same id
  keeps the stamp; a report after a `clear` of the id, or after any other
  removal, gets a new one. The root record has none. A report cannot
  supply the stamp: it is a fact of the set, not of the program.
- The serial starts at 0 and increases by one on every change.
- The published records are sorted by id, bytewise. A working record
  with progress 0 and no app, title or message is dropped from the
  published set, not from the stored one.

The records supply:

- `app` of the root record: the program that owns the pane. A record
  without an app takes the app of its nearest ancestor by `/`, else
  the root's. If the root app is `pi` or `claude-code`, the pane is an
  agent.
- `state`: idle, working, blocked (with an optional kind: permission,
  question or auth), or the final states done and error. Done and
  error produce outcomes (below).
- `msg` and `progress`: the message and the progress.
- `title`: a terminal's title.

Kido.app draws non-root records as child rows under the pane row,
nested by id, in id order: a record nests under each ancestor id that
is present among the non-root records. Each child row shows the record's title, or
its id, its raw state and its message. A visit does not acknowledge
them. Claude Code reports each subagent this way, and koa's agent extension
each job
(design-subagents.md, "A job's row").

### Reduction

`ko_server/src/pane_status.rs` reduces a pane's records to one status.
An agent's status comes from its root record alone. Its child records
show only as child rows: a working job or subagent does not make the
agent run, and a child's done or error makes no outcome. The reason: an
agent whose turn ended must show its end, also while a long job, such
as a server, runs.

A terminal's report reduces all its records in this order: blocked >
working > idle. The smallest bytewise id resolves ties. The rules below
apply to the records that the reduction reads: the root alone for an
agent, all records for a terminal's report.

The **representative** record supplies the message and a terminal's
title. It is the first available record in this order: blocked,
working, the retained outcome's record, idle, any record.

An **outcome** occurs when a record enters done or error from another
state or from absence. This includes the first observation, a
reappearance, and a change from done to error and back. The outcome
has that change's set serial. An unchanged final record never makes
another outcome, even if its message, title or serial changes.

The outcome shows at aggregate idle. A new live episode after idle
clears it. In a terminal's report, an outcome that arrives while other
records work waits, and removing a record keeps its outcome. `since`
is when the model first observed the current state, or the current
outcome at idle.

Tracking resets when an agent's root app changes, appears or clears,
when its `pi.session` changes, or when the ssh destination changes. A
terminal report's app change or removal does not reset tracking, so its
outcome remains after the program exits and clears its records, until
a command is promoted to running or a new report episode begins.

### OSC 133

The shell marks the parts of its command cycle: `A`, a prompt starts;
`C`, the command starts, with its command line; `D`, the command
finishes with its exit status. `ko-pane` forwards primary `A`, `C` and
`D`. The coordinator keeps them in `ko_server/src/telemetry.rs`: the
last prompt's time, the last command with its start, its line and
whether `D` has not arrived, and the last exit, which `D` sets and the
next `C` clears. An `A` ends a command that never reported `D`, in
one line: there is no stuck flag to heal.

The shell phase:

- Unknown: no prompt was seen, as with an unintegrated shell. This is
  not idle.
- Idle: the shell is at a known prompt. The last exit carries the
  code, the command line, the start and the end. A `C` without a `D`
  gives no exit; a later prompt does not mean success.
- Pending: a `C` arrived and the command is not yet promoted. It keeps the last exit of the Idle that
  came before. Clients show it as that Idle, so a short command never
  shows running; only the close decision tells the two apart
  (design-app.md, closing).
- Running: the model observes a command for 0.2 s on its clock, from
  the first observation (`DEBOUNCE` in `pane_status.rs`), then promotes
  it. On ssh, a command with no prompt since ssh started stays Unknown
  until then. Promotion removes the last exit and any
  report outcome from before the command. The model arms one timer of
  `DEBOUNCE` for a pane with a pending promotion (`ko_server/src/model.rs`).
- The alternate screen reports running at once (`fullscreen`). It
  keeps the OSC 133 command if known. If that command still runs when
  the alternate screen ends, the phase remains running.

### The foreground and the active screen

`ko-pane` reads the pty's foreground process group only on events
(protocol.md, section 14) and sends a `foreground` frame when the pid
or the name changed, and an `alternate` frame when the active screen
changed after a write. The known limit: a shell sends `C` before it
forks, so a program that prints nothing shows the shell as the
foreground until its first output or its `D`. ssh prints at once, so
the case that matters is covered.

### The pane title

The pane title is OSC 0/2 as the terminal holds it. An agent row uses
it unchanged for `SomeAgent`, and for `PiAgent` without a name. A
`Terminal` row does not use it. Claude Code sets `Claude Code` at
startup, then a session summary.

A local pi that runs ko's harness (koa) owns the `pi.*` variables,
through its agent extension (`share/koa/koa-agent.ts`). The server reads only `pi.session`,
`pi.name` and `pi.activity`, and trusts them only while the pane has
an OSC 7501 root with `app=pi`. ko stores nothing for a pi session.

### The ssh mark

ko's `ssh` shim runs `ko ssh` (`ko_shell/src/ssh.rs`). Inside a pane
(`KO_PANE` and `KO_SOCKET` set), before it replaces itself with ssh, it
writes two pane variables through the API, with a 2 s deadline, and a
failed or refused write never stops ssh:

- `ssh.dest`: the destination as typed. ko does not resolve it: `ssh
  fish000` and `ssh -l bob fish000` give `fish000`, and `ssh
  bob@fish000` gives `bob@fish000`. If ko cannot parse the arguments,
  or the destination is absent, empty or hyphen-prefixed, it deletes
  the variable but still runs ssh.
- `ssh.args`: a JSON array of strings. The last element is the
  destination. The preceding elements are the kept options and their
  values, in the user's order. The remote command is not included.

The variables stay after ssh exits. The server trusts them only while
the pane's foreground process is `ssh`. The next `ko ssh` in the pane
replaces them.

`ko_config/src/ssh_args.rs` classes each option letter: an option that
names the connection target (port, jump hosts, configuration,
identity, user, address family, ciphers, a control socket) is kept
with its value; an option that controls the terminal, forwarding,
background operation, stdin, messages or logs is dropped; a mode that
cannot supply an ordinary remote command (a control operation, master
mode, stdio forwarding, a tunnel, a subsystem, a query) prevents
recording, as does a missing option value, a bad destination or an
argument that is not UTF-8. A consumer must put its own `-o` settings
before the recorded arguments, because OpenSSH takes the first value
for each setting.

ssh parses options before and after the destination, until `--` or
the first remote command argument.

## Pane kinds

`Kind` in `ko_server/src/pane_kind.rs` classifies a pane in this
order. A variable that is not a JSON string counts as absent.

1. The pane is in a runtime (born there or on a visit): `Runtime`,
   with the `LocalKind` of steps 3 to 5. Its foreground is the
   transport's process, which says nothing about the program inside,
   so `ssh.dest` and the foreground are not read
   (design-runtimes.md, "Status").
2. `ssh.dest` is a non-empty string and the foreground process is
   `ssh`: `Ssh`. Its `pane` is `RemoteKind::Agent` when the root record's
   app is `pi` or `claude-code`, else `RemoteKind::Terminal`.
3. The root app is `pi` and `pi.session` is a non-empty string:
   `PiAgent`, with its name and activity from `pi.name` and
   `pi.activity`.
4. The root app is `claude-code`, or `pi` without the session
   variable: `SomeAgent` with the app as its name.
5. Anything else: `Terminal`.

On the host, steps 3 to 5 give `Host`. A routed pi (`koa
--runtime`) runs on the host, so it is a `Host` pane. A plain `pi`
(not koa) has the root without `pi.session`, so it is a `SomeAgent`.

The trust rule is the gate above and nothing else: a stale
`pi.session` on a shell pane is no agent; a stale `ssh.dest` after ssh
exits is no `Ssh`.

## The matrix

|                  | host                | in a runtime           | over ssh                             |
|------------------|---------------------|------------------------|--------------------------------------|
| shell            | `Host { Terminal }` | `Runtime { Terminal }` | `Ssh { pane: RemoteKind::Terminal }` |
| some agent       | `Host { SomeAgent }` | `Runtime { SomeAgent }` | `Ssh { pane: RemoteKind::Agent }`   |
| koa              | `Host { PiAgent }`  | `Runtime { PiAgent }`  |                                      |

The sections below describe a `LocalKind`; it has the same rules on
the host and in a runtime, except that a runtime pane's row title
never falls back to the foreground process name. The wire's
`Live` (`ko_wire/src/protocol.rs`) has the same shape and carries
no runtime name: the row's `runtime` is the one source of it.

### `Terminal`

- Status: the shell phase from OSC 133, plus a separate report from any
  other program's records, present in every phase.
- Row title: the representative record's title, then its app, then the
  foreground process name (on the host only); while a non-fullscreen command runs with no
  report, the command line.

### `SomeAgent`

- Detected: the root record's app: Claude Code (`claude-code`), or pi
  without ko's harness (`pi`, no `pi.session`).
- Row title: the pane title, or the app name when that is empty.
- Status: the records' reduction.
- Supports: `ko prompt`, by paste, when it is the only agent in scope.

### `PiAgent`

- Detected: root app `pi` and `pi.session`.
- Row title: `pi.name` when set, else the pane title.
- Status: as `SomeAgent`, from the pi root. A message that repeats the
  title is dropped; without a message, `pi.activity` supplies it.
- Supports: everything in design.md and design-subagents.md: the
  message stream for `ko prompt` and `message_agent`, name addressing,
  `list_agents`, parent links.

### `Ssh`

- Detected: the ssh mark, trusted while the foreground is `ssh`. A
  remote program's OSC 133 and OSC 7501 reach the local pane through
  ssh like other output.
- Row title: `ssh <destination>`; while an interactive remote command
  runs outside the alternate screen, `: <command line>` follows. A
  `RemoteKind::Agent` keeps its agent title.
- Status: a `RemoteKind::Agent` uses its records' reduction. Otherwise the
  pane is an ordinary running command until a remote OSC 133 prompt
  later than ssh's start. Then the session stays `interactive` for
  that destination, and the remote shell's markers give the phase.
- Priming: `ko ssh` primes the remote shell when stdin is a terminal,
  there is no remote command, and none of `-N -T -W -f -s -n -O -Q -V
  -G` is given (design.md, "Priming a remote shell"). Otherwise it
  runs ssh with unchanged arguments.

## The published status

The model (`ko_server/src/model.rs`) writes, for each pane, the typed
status (the kind with its phase or agent state), the published record
set, the row title, the caption's message and progress, and `since`.
The row title and caption rules are in the server because Kido.app and
the terminal client both show them. The terminal client shows the mark
and the title; Kido.app shows the caption and the child rows too.

## Precedence

- A pane's death has the highest precedence: a dead pane is ended
  with its exit status, signal or start failure, and its status
  records no longer apply.
- While present, a terminal report has precedence over its shell phase
  for the indicator and the message. A prompt start clears the
  non-final records.
- For `PiAgent`, `pi.session` and `pi.name` give identity and name.
  OSC 7501 gives status.
- A pane's kind determines only its row and `ko prompt` scope. The
  harness's messaging and control use the message stream, the
  `parent` edges and session ids under the same trust rule. A child's report and the parent watch
  read only `pi.session` and pane death (design.md, "The trust rule").

## Clients

A client makes each row from the title and the status
(`ko_client/src/status.rs`): a glyph for running, waiting, or an
unseen success or failure; a caption from the message and progress;
the result of a dead pane. A visit
acknowledges the shown pane's outcomes, and an exit that ended before
the client started counts as seen. The seen state is the client's;
nothing goes to the server.
