# A native UI for pi (proposal)

Status: proposal, not built. Research behind it: pi 0.99.1's installed docs
(`docs/rpc.md`, `rpc-commands.md`, `rpc-extension-ui.md`, `json.md`,
`session-format.md`) and source, and the tmux fork's `window.c` and
`input.c`.

The goal is a native surface for the pi coding agent: transcript, tool
calls, diffs, thinking, prompt editor, model and thinking controls,
dialogs. It is not pi's TUI drawn by a terminal. The same architecture
serves a Mac app showing a local or a remote pi, and later an iOS app.

## The shape

`kido-pi` is the command a pane runs instead of `pi`. It starts
`pi --mode rpc` as its child and uses its own terminal as a two-way
channel: RPC traffic goes out as private OSC sequences in its output, and
comes in as framed sequences in its input. Whatever displays the terminal
can render the native UI from those sequences; anything else sees a
minimal plain-text view kido-pi draws.

    GUI ⇄ tmux control mode (%output / send-keys -H) ⇄ pane pty [⇄ ssh] ⇄ kido-pi ⇄ pi --mode rpc

That one channel covers every case:

- **A local pane:** Kido.app reads `%output` and writes with
  `send-keys -H`, as it does for typing.
- **A remote pi:** `ssh host kido-pi` in a local pane. ssh carries the
  bytes unchanged both ways; the GUI renders locally. A remote tmux is
  attached over ssh in control mode, the same as the iOS plan.
- **iOS:** tmux control mode over SSH, the iOS app's plan, with the same
  protocol and client model and its own views.
- **The standalone debug app:** runs kido-pi in a pty of its own, no tmux;
  its command can be `ssh host kido-pi` for a remote one.

Nothing new is installed on a remote beyond kido-pi and pi. kido-pi is a
Node TypeScript program, because every host that runs pi has Node and not
necessarily kido's binary.

## Why the terminal works as a channel

tmux hands every control client a pane's bytes raw, before its own parser
sees them (`window.c`, `window_pane_read_callback`: `control_write_output`
runs before `input_parse_pane`). tmux's OSC dispatch ignores a number it
does not know (`input.c`, `input_exit_osc`), as does Ghostty, so a plain
client attached to the same session and the Ghostty surface under the
native view show nothing. APC is not used: tmux reads APC as a title.

Throughput is not the limit: streaming is a few KB/s, a large tool output
a few MB, and tmux forwards `%output` on read. The pty's small buffer is,
so kido-pi writes with backpressure. The spike measures 10 MB through a
real tmux to a control client and through ssh to localhost.

## Wire format

Out, kido-pi to GUI: `ESC ] 5522 ; <seq> ; <more> ; <base64> BEL`. A
message is one JSON object, base64'd and split into chunks of at most
32 KB, so a cut sequence never exceeds tmux's 1 MB input buffer and spills
onto the screen. `<more>` is 1 on every chunk but the last; `<seq>` counts
chunks, so a gap is detected.

In, GUI to kido-pi: the same framing, `ESC ] 5522 ; ...` as pane input.
kido-pi's terminal is raw; it parses framed messages out of its input and
treats every other byte as a key for its plain view.

Messages are pi's RPC JSON unchanged (commands with `id`, `response`,
session events, `extension_ui_request` / `extension_ui_response`) plus a
few kido-pi kinds: `hello` (version, pi session id and file, cwd),
`snapshot`, and `history` (an older page).

Ids are unique per GUI client, so two clients reading the same output
pick out their own responses. A dialog is answered once; kido-pi forwards
the first answer and drops the rest.

## Source of truth

The pi process is the truth while it runs, its session JSONL after it
exits. kido-pi is the one RPC client of its pi and holds what RPC does not
replay: the current partial assistant message and open dialogs. The GUI
holds nothing a snapshot cannot rebuild.

A snapshot is `get_state`, the newest entries of the active branch from
`get_entries` (followed from `leafId`), the partial message, open dialogs
and the current `seq`. Older entries load on demand by entry id, like the
terminal's newest-10k restore and Load more; a whole long history is
never resent.

The GUI asks for a snapshot on connect, on reconnect, when a pane is shown
again, and on a `seq` gap. Gaps are expected: Kido.app's `pause-after`
drops a paused pane's output, and tmux sends no `%output` for panes outside
the client's session.

The JSONL is never tailed: pi writes it at `message_end`, persists no
deltas, and moves the tree's leaf in memory without writing.

## Finding kido-pi panes

The GUI must never probe a pane blindly: a probe sent to a shell is typed
into it. Locally, the pane's command and kido's state record name kido-pi.
Over ssh the command is `ssh`, and a `hello` printed at start is missed by
a client not attached then. The robust marker is a tmux fork change: an
OSC sequence that sets a pane option, which tmux keeps and the GUI reads on
attach. Until it lands, kido-pi repeats `hello` periodically while idle.

## Trust

Any program in any pane can print these sequences (`cat` of a hostile
file). The GUI accepts them only from panes it has identified as kido-pi,
and a message only affects that pane's surface. Input is as trusted as
typing into the pane.

## Input

| Action | RPC |
|---|---|
| prompt, while idle | `prompt` |
| while streaming | `prompt` with `streamingBehavior` `steer` (Return) or `followUp` (Option-Return) |
| Escape | `clear_queue`, restore its text to the editor, then `abort` |
| model, thinking | `set_model`, `set_thinking_level`; lists from `get_available_models`, `get_available_thinking_levels` |
| extension slash commands | `prompt("/cmd ...")`, which works in RPC; completion from `get_commands` |
| built-in TUI commands | native controls over RPC methods: `new_session`, `switch_session`, `fork`, `compact`, `get_session_stats`, `export_html` |
| select, confirm, input, editor | `extension_ui_request` as a sheet, answered by `extension_ui_response` |
| notify, setStatus, setTitle, string widgets | status text; `custom()` components resolve undefined in RPC and are not drawn |

A large paste or image is chunked; `send-keys -H` costs three bytes per
byte.

Lost against pi's TUI: extensions' custom terminal components, overlays
and shortcuts, and kido-agents' pending-notice widget and `@agent`
completion, which need native replacements from kido's data. kido's two
extensions keep working inside the RPC pi, in the pane's process tree.

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
  views: the framing parser and writer, the message types (only what is
  rendered), one `@Observable` session model, and the views. It knows
  nothing of tmux or Ghostty; the host hands it bytes and takes bytes.
- `PiView`: the standalone app target in `app/project.yml`, a pty host
  around the surface, with a launch form (command, cwd, arguments) and a
  replay mode that feeds a recorded byte stream, so UI work costs no model
  tokens.
- Kido.app later: the surface in a pane, fed from the pane's `%output`,
  writing through `send-keys -H`, with the terminal one toggle away.

Views use standard macOS components with minimal code: SwiftUI by default
(`ScrollView` and `LazyVStack` with a bottom anchor, `Text` from
`AttributedString(markdown:)`, `DisclosureGroup`, `.sheet`, `Picker`,
`.toolbar`), and an AppKit view behind `NSViewRepresentable` only where a
measurement shows SwiftUI failing: streaming into a long transcript, drag
selection across a message, a large tool output, the editor's keys.

## Ownership

Everything in this document is pi-ui's. pi itself, kido's pi extensions
and shim, and the tmux fork's pane-marker change go through
working-on-kido; Kido.app-wide refactors through kido-app.

## First spike

kido-pi and PiView over a pty: the framing both ways, `hello` and
snapshot, transcript with streaming text, thinking, tool calls and edit
diffs, prompt/steer/abort, model and thinking pickers, dialog sheets; a
recorded fixture and a long one to measure the SwiftUI transcript; the
throughput check through tmux and ssh to localhost. Low to medium risk
(the framing through a raw pty and ssh is the unknown), about a day of
agent time. Kido.app hosting follows: medium risk, about a day.
