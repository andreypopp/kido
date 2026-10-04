# A native UI for pi (proposal)

Status: proposal, not built. Research behind it: pi 0.99.1's installed docs
(`docs/rpc.md`, `rpc-commands.md`, `rpc-extension-ui.md`, `json.md`,
`extensions.md`, `session-format.md`, `sdk.md`) and source.

The goal is a native macOS surface for the pi coding agent: transcript,
tool calls, diffs, thinking, prompt editor, model and thinking controls,
dialogs. It is not pi's TUI drawn by Ghostty, which Kido.app already does.
It is built first as a standalone debug app and later hosted by Kido.app
as a pane surface.

## Two pieces, built in order

1. **PiSurface** (`app/Packages/PiSurface`), a Swift package with the
   protocol client, one `@Observable` transcript model and the views. It
   knows nothing of tmux, Ghostty or kido. **PiView**, a small standalone
   app target, starts `pi --mode rpc` itself (cwd and arguments from a
   launch form) or replays a recorded RPC transcript, and shows the
   surface. Replay is how UI work is iterated without model tokens.
2. **Kido.app integration**: the same surface, hosted with one
   `NSHostingView`, attached to the pi of a pane.

## The protocol is pi's RPC

The surface speaks pi's RPC JSONL and nothing else: commands with an `id`,
their `response`, session events, and `extension_ui_request` /
`extension_ui_response`. Any byte stream carrying those lines works: a
child's stdio (PiView), a unix socket (Kido.app, local pane), an ssh exec
channel (a remote pane, the iOS idea). One reader function takes the
stream; there is no transport abstraction beyond that.

On connect the client builds its state from `get_state`, `get_entries`
(raw entries plus `leafId`, the active branch followed from the leaf) and
`get_available_models`, then applies events. Streaming deltas
(`message_update` text/thinking/toolcall deltas, `tool_execution_update`)
update the last partial block; `message_end` replaces it with the final
message. A turn is over at `agent_settled`, not `agent_end`.

Codable types cover only what is rendered; other events are ignored.

## Source of truth

The pi process is the truth while it runs; its session JSONL is the truth
after it exits (resume with `--session <file>`). The surface holds nothing
that a reconnect cannot rebuild from `get_state` and `get_entries`. The
JSONL is never tailed: pi writes it at `message_end`, does not persist
deltas, and moves the tree's leaf in memory without writing, so a tail
cannot show the live state. Two pi processes on one JSONL are two agents,
never two views.

## Integrating with Kido.app: who owns pi

pi has no attach socket and RPC is one stdio stream with one client. So
Kido.app needs either a side channel into an interactive pi (A) or a
process that owns an RPC pi and serves clients (B).

**A. Extension channel into the TUI pi.** A kido extension in the normal
pi serves an RPC-shaped socket, forwarding extension events and mapping
commands to `pi.sendUserMessage`, `ctx.abort`, `pi.setModel`,
`pi.setThinkingLevel`. The pane keeps pi's real TUI.
Against: the extension API is not RPC parity. No queue clearing, retry or
compaction toggles, stats, no prompt acknowledgement, and no supported way
to answer another extension's `select`/`confirm`/`input` dialog: those
stay in the terminal. The socket must re-derive RPC's event shapes from
extension events and keep the partial message for reconnects.

**B. A bridge owns `pi --mode rpc`.** `kido pi-bridge` runs in the pane,
starts pi in RPC mode as its child, serves the RPC lines on a socket in
kido's inbox directory, fans events out to every connected client and
routes each `response` and dialog answer back by id. It keeps the current
partial assistant message so a client connecting mid-stream sees it. The
pane shows a minimal line view: the transcript as plain text and a line
prompt, enough for a plain terminal, a second client or ssh.
For: everything RPC has, including native dialogs, extension slash
commands (they work in RPC), queues, stats and session switching. The
surface talks to the bridge exactly as PiView talks to its child.
Against: the pane no longer shows pi's TUI. Lost there: built-in TUI
commands (`/tree`, `/settings`, ... which need native replacements over
RPC methods), extensions' custom terminal components and shortcuts, and
kido-agents' pending-notice widget and `@agent` completion (native
replacements from kido data). kido-status keeps working: it runs inside
the RPC pi, in the pane's process tree.

**Recommendation: B, opt-in per pane.** Native-primary is the point of
the feature, and RPC is pi's supported interface for it. Plain `pi` stays
the TUI; Kido.app's "New pi" (or `pi --kido-native`, handled by the shim)
starts the bridge. The surface is the same code as PiView, so the
standalone work carries over unchanged. The pane's fallback is "show the
terminal": the bridge's line view, and for a TUI-only need, the user
resumes the session in a TUI pi (`pi --session <file>`) after closing
the bridged one.

## Input

| Action | RPC |
|---|---|
| prompt, while idle | `prompt` |
| while streaming | `prompt` with `streamingBehavior` `steer` (Return) or `followUp` (Option-Return) |
| Escape | `clear_queue`, restore its text to the editor, then `abort` |
| model, thinking | `set_model`, `set_thinking_level`; lists from `get_available_models`, `get_available_thinking_levels` |
| extension slash commands | `prompt("/cmd ...")`; completion from `get_commands` |
| built-in commands | native controls over RPC methods: `new_session`, `switch_session`, `fork`, `compact`, `get_session_stats`, `export_html` |
| select, confirm, input, editor | `extension_ui_request` shown as a sheet, answered by `extension_ui_response` |
| notify, setStatus, setTitle, string widgets | shown as status text; `custom()` components are not rendered (pi resolves them undefined in RPC) |

## What it shows

Messages as markdown; thinking collapsed; tool calls as disclosure rows
with arguments and streamed output; the edit tool's `details.patch` as a
diff; bash executions; kido's custom messages (`kido-message`, `-ask`,
`-reply`, `-notice`, `-stream`) as cards from their `details`; compaction
and branch summaries as markers; status, queue, usage and cost from
events and `get_session_stats`. Subagent and run trees stay in Kido.app's
sidebar, from the feed.

## UI building blocks

Standard macOS components, minimal code: SwiftUI by default (`ScrollView`
with `LazyVStack` and a bottom anchor, `Text` from
`AttributedString(markdown:)`, `DisclosureGroup`, `.sheet`, `Picker`,
`.toolbar`). An AppKit view behind `NSViewRepresentable` replaces one
SwiftUI view only where a measurement shows SwiftUI failing; the likely
ones are streaming into a long transcript, drag selection across a message
or a large tool output (`NSTextView`), and the editor's keys.

## First spike

PiView with replay and live RPC: launch form, transcript with streaming
text, thinking, tool calls and edit diffs, prompt/steer/abort, model and
thinking pickers, dialog sheets. Plus a recorded fixture transcript and a
long one to measure the SwiftUI transcript. No kido, no Kido.app changes.
Low risk, roughly half a day of agent time. The bridge and the Kido.app
surface follow once the spike settles the views: medium risk, about a day
of agent time each.
