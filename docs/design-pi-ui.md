# A native UI for pi (proposal)

Status: proposal, not built. Research behind it: pi 0.99.1's installed docs
(`docs/rpc.md`, `rpc-commands.md`, `rpc-extension-ui.md`, `json.md`,
`session-format.md`) and source, and the tmux fork's `window.c`,
`control.c` and `input.c`.

The goal is a native surface for the pi coding agent: transcript, tool
calls, diffs, thinking, prompt editor, model and thinking controls,
dialogs. It is not pi's TUI drawn by a terminal. The same architecture
serves a Mac app showing a local or a remote pi, and later an iOS app.

## The shape

`kido-pi` is the command a pane runs instead of `pi`. It starts
`pi --mode rpc` as its child and uses its own terminal as a two-way
channel: messages go out as private OSC sequences in its output and come
in as framed sequences in its input. Whatever displays the terminal can
render the native UI from them; anything else sees a minimal plain-text
view kido-pi draws.

    GUI ⇄ tmux control mode (%output / send-keys -H) ⇄ pane pty [⇄ ssh] ⇄ kido-pi ⇄ pi --mode rpc

One channel covers every case:

- **A local pane:** Kido.app reads the pane's output from control mode
  and writes with `send-keys -H`, as it does for typing.
- **A remote pi:** `ssh -tt -e none host kido-pi` in a local pane: `-tt`
  because ssh allocates no remote tty for a command, `-e none` so a
  newline-`~` in the stream is not ssh's escape. The GUI renders locally.
  A remote tmux is attached over ssh in control mode, as in the iOS plan.
- **iOS:** tmux control mode over SSH, with the same protocol and session
  model and its own views.
- **The standalone debug app:** kido-pi in a pty of its own, no tmux; its
  command can be the ssh line above.

Nothing new is installed on a remote beyond kido-pi and pi. kido-pi is a
Node TypeScript program: every host that runs pi has Node, not
necessarily kido's binary.

## The terminal as a channel

tmux queues a pane's bytes for each control client before its own parser
sees them (`window.c:1661`), as `%output`, or `%extended-output` under
`pause-after` (`control.c:823`), octal-escaping control bytes and
backslash: the GUI unescapes once, then deframes. tmux sends nothing for a
paused pane, one outside the client's session, or with output off
(`control.c:603`); the GUI resumes a paused pane before asking for a
snapshot.

tmux's OSC dispatch ignores an unknown number (`input.c`,
`input_exit_osc`), and discards an OSC over its 1 MB input buffer rather
than printing it (`input.c:1288`). A sequence left unfinished for five
seconds is cut by tmux's timer and its rest would print, so kido-pi writes
each frame whole, small (4 KB), in one write, and an unfinished frame is a
bug. APC is not used: tmux reads APC as a title. Ghostty discards an
unknown OSC to its terminator (`osc.zig`: after `6` only `66` is known),
so the surface under the native view shows nothing; 5522, the first
choice, is kitty's clipboard protocol, which Ghostty implements.

kido-pi's terminal is raw: no ICANON, ECHO, ISIG, IXON, ISTRIP, ICRNL or
output translation, restored on exit. macOS's tty input queue is small
(`MAX_INPUT` 1024), so inbound frames are at most 512 bytes and flow
controlled (below). Outbound writes wait on the pty's backpressure.

Throughput is not the limit: streaming is a few KB/s, a large tool output
a few MB, and tmux forwards on read. The spike measures 10 MB through a
real tmux to a control client and through ssh to localhost.

## Wire format

A frame is `ESC ] 6767 ; <header> ; <base64> BEL`, the base64 of a slice
of one JSON message. Out, `<header>` is `<seq>,<last>`: `seq` counts
frames from kido-pi's start, so a gap is detected, and `last` ends a
message. Out frames are written one at a time, so a message's frames are
consecutive.

In, `<header>` is `<client>,<msg>,<index>,<last>`: `client` a random
UUID per GUI connection, `msg` counting that client's messages from 1,
`index` the frame within the message from 0, so frames of different
clients interleaving on one tty reassemble apart. An in frame is at most
512 bytes and is one `send-keys -H`, which tmux writes to the pty
contiguously. kido-pi acks every frame,
`{"type":"ack","client":...,"msg":...,"index":...}`, and a client has one
frame unacked at a time: that is the flow control against the tty's small
input queue. A frame at or below the last one accepted from its client is
re-acked and dropped, so a resend after a lost ack is harmless. A
malformed frame is dropped whole; bytes inside an `ESC ] 6767` sequence
never reach the plain view as keys, and a lone ESC is a key after a short
timeout.

Messages are pi's RPC JSON unchanged (commands with `id`, `response`,
session events, `extension_ui_request` / `extension_ui_response`), with a
command's `id` prefixed `<client>:` so each client picks out its own
responses; a dialog answer keeps pi's dialog id. kido-pi's own messages:

    hello         {type, instance, sessionId, sessionFile, cwd}
    bye           {type, instance}
    snapshot      in {type, id}; out {type, id|null, hello, seq, generation, record}
    history       in {type, id, generation, before, limit};
                  out {type, id, generation, entries, before|null}
    ack           {type, client, msg, index}
    dialog_closed {type, generation, id}

`seq` in a snapshot is the last frame sent before it; the GUI applies
frames after the snapshot's own. `history` pages the active branch
backwards from the entry id `before`, oldest first.

The canonical snapshot `record` fields are `entries`, `leafId`,
`partialAssistant`, `tools`, `bash`, `queues`, `dialogs`, `status`,
`widgets`, `notifications`, `title`, `state`, `models`, `thinkingLevels`,
`commands`, and optional `retry` and `compaction`. `tools` is keyed by
`toolCallId`: each value is the `tool_execution_start` event with its latest
`partialResult`. `dialogs` is keyed by id and holds the requests themselves.
Clients render keyed values in key order. `message_update` carries deltas,
not a cumulative message. There are no pending-message or stats fields.

The bridge adds `uiId` to `message_start` and `message_end`, to
`partialAssistant`, and to the corresponding entries returned by
`get_entries`, history and snapshots. It assigns the identity once at
message start (or end for messages without a start), scoped to instance
and generation. Entry reconciliation consumes ended messages in order by
role and timestamp, never by text. Historical entries without a live
identity use their entry ID. Block identities add their content index;
tools use their call ID. Partial thinking blocks carry `active: true`
between `thinking_start` and `thinking_end` (`false` after end), so an
assistant continuing to stream text does not imply it is still thinking.

An ended tool remains in `tools` with `ended: true`, `result` and
`isError` until its persisted result entry arrives; execution metadata and
partial output remain available during this interval. `bash` is keyed by
command ID, with `command`, literal accumulated `output`, and final
response fields plus `ended: true`. The bridge broadcasts `bash_execution_start {type, id, command}` before
forwarding a direct bash command. Finished direct executions remain until
`get_entries` supplies their `bashExecution` entry; the bridge gives that
entry the command's `uiId` and removes its transient `bash` value. Entries
are reconciled in completion order with the matching command. `clear_queue` responses carry the removed queues
in `data.steering` and `data.followUp`; clients restore those returned
values, not a queue captured before the request, before requesting abort.

The first hello waits for all bootstrap queries. A generation change
broadcasts an unsolicited snapshot (`id: null`) after those queries finish;
clients replace their complete state, including when another client caused
it. Clients resend the identical inbound frame after a bounded ack timeout
and discard in-flight frames on disconnect or instance change.

## Source of truth

The pi process is the truth while it runs, its session JSONL after it
exits. kido-pi is pi's one RPC client and sees every event, so it keeps
what RPC cannot replay, all in one session record: the entries (from
`get_entries` at start, then appended from events and `get_entries` with
`since`), the leaf, the partial assistant message, running tools and
direct bash with their latest output, the queues (`queue_update` carries
them whole), retry and compaction state, extension status and widgets,
and open dialogs. The GUI holds nothing a snapshot cannot rebuild.

A snapshot is that record's current value with the `seq` it was taken at,
built in one turn of kido-pi's event loop, so it is consistent with the
frames that follow. It carries the newest entries of the active branch;
older ones are sliced from kido-pi's record on request (`history`), the
way the terminal restores its newest 10k rows and loads more. A
`generation` in the snapshot changes on `new_session`, `switch_session`,
`fork` and `clone`, and the GUI resets on a new one.

The GUI asks for a snapshot on connect, reconnect, when a pane is shown
again, and on a `seq` gap. The JSONL is never tailed: pi persists no
deltas and moves the leaf in memory without writing.

## Finding kido-pi panes, and trust

Terminal output is untrusted: any program in any pane can print these
sequences (`cat` of a hostile file). The GUI never sends to a pane it has
not seen a `hello` from in the current instance, and a message only
affects that pane's own surface. Input is as trusted as typing into the
pane.

`hello` carries a random instance id, the pi session id and file, and
cwd. kido-pi prints one at start, in every snapshot, and every few seconds
whether busy or idle, so a client that attaches later finds it within one
period without sending anything. A pane leaves kido-pi on `bye`, on a new
instance id, and on any shell prompt marker (OSC 133 `A`, which tmux
records as `last_prompt`): a crashed kido-pi or a dropped ssh leaves the
local or remote shell to print its prompt. Until then the GUI only shows
the pane natively; what reaches a shell by mistake has no Enter in it.

## Dialogs

`select`, `confirm`, `input` and `editor` are sheets. The first answer
wins; kido-pi forwards it, broadcasts `dialog_closed`, and drops later
answers. pi removes a dialog on its timeout or its abort signal without
saying so (`dist/modes/rpc/rpc-mode.js:52`), so kido-pi closes it itself on
the request's `timeout`, on an `abort`, and on a new generation. A dialog
closed by a signal alone stays up until answered; pi ignores an answer to
a removed id (`rpc-mode.js:618`).

## Input

| Action | RPC |
|---|---|
| prompt, while idle | `prompt` |
| while streaming | `prompt` with `streamingBehavior` `steer` (Return) or `followUp` (Option-Return) |
| Escape | `clear_queue`, restore its text to the editor, then `abort` |
| model, thinking | `set_model`, `set_thinking_level`; lists from `get_available_models`, `get_available_thinking_levels` |
| extension slash commands | `prompt("/cmd ...")`, which works in RPC; completion from `get_commands` |
| built-in TUI commands | native controls over RPC methods: `new_session`, `switch_session`, `fork`, `compact`, `get_session_stats`, `export_html` |
| notify, setStatus, setTitle, string widgets | status text; `custom()` components resolve undefined in RPC and are not drawn |

Two clients may both prompt, as two people at one keyboard would. A
session change from one resets the other through `generation`.

Lost against pi's TUI: extensions' custom terminal components, overlays
and shortcuts, and kido-agents' pending-notice widget and `@agent`
completion, which need native replacements from kido's data.

## kido inside kido-pi

kido's two extensions run inside the RPC pi, which is the session's one
holder in kido's state; kido-pi claims nothing and reports nothing.
Resuming a session another live pi holds makes two writers of one JSONL,
the same as two plain pis today. Subagents `spawn_subagent` starts stay
plain pi with its TUI in this proposal; making them kido-pi is a change
to the shim and kido-agents.ts, for working-on-kido, once the surface
exists.

## What it shows

Messages as markdown; thinking collapsed; tool calls as disclosure rows
with arguments and streamed output; the edit tool's `details.patch` as a
diff; bash executions; kido's custom messages (`kido-message`, `-ask`,
`-reply`, `-notice`, `-stream`) as cards from their `details`; compaction
and branch summaries as markers; status, queue, usage and cost from
events and `get_session_stats`. Subagent and run trees stay in Kido.app's
sidebar, from the feed.

## Code

- `share/kido-pi/`: kido-pi, the bridge and its plain view.
- `app/Packages/PiSurface`: the Swift package, platform-neutral below the
  views: deframing and framing, the message types (only what is
  rendered), one `@Observable` session model, and the views. It knows
  nothing of tmux or Ghostty; the host hands it bytes and takes bytes.
- `PiView`: the standalone app target in `app/project.yml`, a pty host
  around the surface, with a launch form (command, cwd, arguments) and a
  replay mode that feeds a recorded byte stream, so UI work costs no model
  tokens.
- Kido.app later: the surface in a pane, fed from the pane's output,
  writing through `send-keys -H`, with the terminal one toggle away.

Views use standard macOS components with minimal code: SwiftUI by default
(`ScrollView` and `LazyVStack` with a bottom anchor, `Text` from
`AttributedString(markdown:)`, `DisclosureGroup`, `.sheet`, `Picker`,
`.toolbar`), and an AppKit view behind `NSViewRepresentable` only where a
measurement shows SwiftUI failing: streaming into a long transcript, drag
selection across a message, a large tool output, the editor's keys.

## Ownership

Everything in this document is pi-ui's. pi itself, kido's pi extensions
and shim go through working-on-kido; Kido.app-wide refactors through
kido-app.

## First spike

kido-pi and PiView over a pty: the framing both ways with acks, `hello`
and snapshot, transcript with streaming text, thinking, tool calls and
edit diffs, prompt/steer/abort, model and thinking pickers, dialog
sheets; a recorded fixture and a long one to measure the SwiftUI
transcript; the throughput and fragmentation checks through tmux, ssh to
localhost, a stalled reader and two competing writers, on macOS and
Linux. Medium risk (the raw pty and ssh path is the unknown), about a day
of agent time. Kido.app hosting follows: medium risk, about a day.
