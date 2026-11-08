# koa — the webview harness, reference mockup

`mockup.html` beside this file is self-contained: inline CSS and JS,
no network. Open it from a static server (`python3 -m http.server`
in `app/design`) and use the two controls: theme (kido-light,
kido-dark) and pane width (980pt, or 60 terminal cells). Each
numbered section is one state of the page, rendered inside a frame
that stands for the pane's content area. Click a run line or a step
line to fold or unfold it.

Status: reviewed by the user on 2026-11-08. Decided: prose in the
system font; a failed run stays collapsed; the status bar at the
bottom; the context bar always shows; a user message carries a
timestamp (below, "The transcript").

## Rules the page follows

- **Only `--ko-*`.** The page's colours are `--ko-bg`, `--ko-fg`,
  `--ko-cursor` and the palette (`--ko-color-N`), and every other
  tone is a `color-mix` of them: muted text 55% fg, faint 35%,
  hairlines 12% and 18%, wells 5% and 8%. The accent is palette 4
  (blue), ok is 2, error is 1, warning is 3, so a theme's own palette
  colours the page. The `:root` block at the top of the mockup is the
  browser fallback, kido-light and kido-dark copied from
  `app/Resources/ghostty/themes`; in Kido.app the properties the app
  sets override it, and `prefers-color-scheme` is not consulted.
- **Two fonts.** Prose (user and assistant text, thinking, the
  composer's text) is the system font at `--ko-font-size`, line
  height 1.6. Everything that is a terminal fact is the terminal font
  (`--ko-font-family`): code, the run and step lines, diffs, bash
  output, the composer's footer hints and the status bar.
- **No header.** The pane's sidebar row and the title tabs already
  name the agent and its session. The page is transcript, composer,
  status bar, nothing above.
- **No chrome of its own.** No borders around messages, no avatars,
  no bubbles. A user message is a 2pt left bar in the accent colour.
  An assistant message is plain prose. Hairlines separate only the
  status bar.

## The transcript

- Content column: 720pt wide, centred, 22pt top and 24pt side
  padding. In the narrow pane it is fluid with 14pt sides.
- Markdown: headings in the prose font, 1.3/1.15/1em, 600 weight;
  lists with muted markers; inline code in an 8% well with 4pt
  corners; code blocks in a 5% well with a 12% hairline, 7pt corners,
  the language as a faint label at the top right; tables with a
  hairline under each row, uppercase muted header cells, no vertical
  lines; blockquotes with an 18% left bar.
- A user message's timestamp (user, 2026-11-08): the time of sending
  at the right of the message's first line, terminal font at 80%,
  faint, tabular digits, 14pt after the text, never wrapping; the
  text wraps in the remaining width. Form: `14:32` (local, 24-hour)
  for today, `Nov 7 14:32` for an earlier day, `2025 Nov 7 14:32` for
  an earlier year. A `<time datetime>` element, so it is machine
  readable. Assistant messages and runs carry no timestamp; the run
  has its elapsed time.
- Streaming: the text appears as it arrives; a 2pt caret in
  `--ko-cursor` blinks at the end of the streamed text (1s, steps).
  The transcript stays scrolled to the bottom while it streams and
  stops following when the user scrolls up.

## The run

A run is every consecutive thinking block and tool call between two
assistant texts (or between the user's message and the first text).

- **Collapsed** (default): one terminal-font line, muted. A chevron,
  then the summary, then the elapsed time at the right. While running
  the summary is a spinner and the current step in the fg colour
  ("running **make cargo …** · step 4 of 4"); done, it is a green check
  and the count by kind ("✓ 4 steps · thinking, 1 read, 1 edit, 1
  command"). A failed run leads with a red ✕ and "1 command failed";
  an aborted one with a warning ⊘ and "aborted · you pressed Escape".
- **Expanded to lines**: the steps, indented 18pt under a 12%
  hairline. One line per step: a mark for the kind in a 12pt column
  (`$` bash, `✎` edit, `◇` read, `∴` thinking), the command or path
  in the fg colour, the step's own detail in faint (`+5 −1`, `212
  lines`, the thinking's first words), and the result at the right:
  green ✓ with the time, red `exit N` with the time, or `aborted`.
  Summaries ellipsize before the time; the time never wraps.
- **Expanded to details**: bash shows `cwd` and the output in a well,
  cut to 260pt and scrollable; an edit shows the file name in a
  header bar and a diff with added lines on a 12% green tint and
  removed lines on an 11% red tint, markers in the margin; thinking
  shows the full text as muted prose, 260pt cut and scrollable.
- Fold state is per run and per step, kept while the session is open.
  A run that is running stays collapsed unless the user opened it.

## The composer

- A 9pt-radius field with an 18% hairline, 9pt 12pt padding. Focused:
  the hairline darkens to 40%. The text grows to six lines and then
  scrolls.
- **One button**, at the bottom right inside the field: a 26pt
  rounded square with an 8pt radius, the shape of the palette's Send
  control, no border and no text, an icon in the paper colour (14pt,
  2pt stroke). Send is the accent colour with a right arrow while the
  field has text, and the 18% hairline tone, inert, while it is empty.
  While koa works the same spot holds stop: the fg colour with a
  rounded 7pt square; red on hover. Clicking send sends (a steer while
  koa works), clicking stop aborts. No pill, no labelled button, no
  circle (user, 2026-11-08: the text pill, the `↩ send` label and a
  round button were each rejected).
- The key hints are faint terminal-font text at the left of the same
  line, shown only while the field is focused or koa works: `⇧↩
  newline` with text present, `↩ steers while koa works` while it
  works. The send key is not spelled out; the button says it.
- Placeholder "Message koa…"; while koa works, "Steer koa…".
- **While the agent works** the field stays editable and a thin accent
  sweep runs along its top edge. Escape anywhere on the page aborts;
  a second Escape clears the field.

## The status bar, one line

24pt, terminal font at 82%, a 12% hairline above. Segments left to
right, separated by hairlines:

1. state: a 6pt dot and a word — gray "idle", green "working 12s",
   orange "waiting for you", gray "aborted";
2. the model, then "· thinking high" (muted);
3. context: a 44pt bar (18% track, faint fill; warning colour over
   75%), the exact "84k / 200k" in faint, and the percent;
4. a flexible gap;
5. the cwd with its last component in the fg colour and the branch,
   a `*` in the warning colour when dirty.

In the narrow pane the thinking label, the exact token numbers and
the cwd's leading directories go first; the bar, the percent, the
model, the state and `kido · main*` stay.

## The narrow pane (60 cells)

Same page. The transcript column loses its centring margin, tables
and code blocks scroll inside their block, run summaries ellipsize,
the status bar drops the segments above. Nothing hides otherwise.

## What the page needs from koa

- The session as items: user text, assistant text (streaming deltas),
  thinking blocks, tool calls with their arguments, start and end
  times, result or error, and an abort marker.
- For each tool a one-line summary rule: bash → the command; edit →
  the path and the line counts; read → the path and the line count;
  anything else → the tool name and its first argument.
- The status facts: model, thinking level, context tokens used and
  the limit, cwd, branch and dirty flag, and the run state with its
  start time.
- Steer and abort as requests from the page.

## Decisions (user, 2026-11-08)

1. Prose in the system font; terminal facts in the terminal font.
2. A finished run stays collapsed, also after a failure.
3. The status bar is at the bottom, under the composer.
4. The context bar always shows.
5. A user message carries a timestamp, no label.

## Dialogs from extensions (unit 5)

pi's extension UI requests (`select`, `confirm`, `input`, `editor`)
are one card above the composer, in the content column: a 9pt
radius, the 18% hairline, 11pt 12pt padding. The title is 600
weight; the message, when there is one, muted under it. A request
with a timeout shows the seconds left in the terminal font at the
right of the title and a 2pt accent fuse along the card's top edge
that shrinks to zero; at zero the request is cancelled as pi does.
The buttons sit at the bottom right, secondary (hairline) then
primary (accent fill): Cancel / Select, No / Yes, Cancel / Submit,
each with its key in a faint kbd. The hint at the bottom left is
the terminal font at 80%.

- `select`: the options as rows, the current one filled (8% well)
  with a `›` in the accent colour; an option's description, when pi
  gives one, muted after it. ↑↓ move, ↩ selects, ⎋ cancels, a digit
  jumps.
- `confirm`: no field. ↩ is Yes, ⎋ is No.
- `input`: one line in a 7pt-radius hairline field, focused on
  arrival, prefilled when pi says so. ↩ submits, ⎋ cancels.
- `editor`: the same field at four lines, growing to ten; ↩ and ⇧↩
  are newlines (the text is multi-line), ⌃↩ submits, ⎋ cancels. Not
  ⌘↩: every Command key goes to Kido's menu first (⇧⌘↩ is Zoom Pane,
  ⌘↩ is unused today, but the page should not depend on that), and
  ⌃↩ has no Cocoa text binding.

One card at a time, in request order. A second queued request is a
one-line note under the card, "+1 queued · its title", and takes
the card when the first is answered. While a card is up the composer
stays visible, inert (the field keeps its text, the button is off),
the status bar says "waiting for you" with the orange dot, and focus
is in the card; ⎋ in the card cancels the request, not the run.

## The queue while koa works

Steering and follow-up messages that pi holds are listed under the
field, inside the composer column: one line each, a tag in the
terminal font (`steer`, `follow-up`) in a 62pt column, the text
ellipsized. Under them, the count and a "take back ⌥⌫" button, the
hairline button style, no key of its own (⌥⌫ is delete-word in the
field; Tab from the field reaches the button, ↩ or Space presses
it): it calls pi's `clear_queue` and puts every message into the
composer, each on its own paragraph in queue order, caret at the
end, the queue line gone. The composer's own hint line stays as it
is while working (↩ steers, ⌥↩ queues a follow-up).

## The model and thinking pickers

A click on the model segment or the thinking segment of the status
bar opens a popover above that segment. The two segments are
buttons: Tab from the composer reaches them (after the queue's
button when it shows), ↩ or Space opens. No key inside the field
opens them: ⌃M and ⌃T are Cocoa text bindings (newline, transpose)
that WebKit fields honour. The popover is
anchored at the segment's left edge, 30pt above the bar's top, 220pt
minimum, a 9pt radius, the 18% hairline, a soft shadow (fg 14%, 8pt
down, 28pt blur), 6pt padding, the terminal font at 88%. A faint
caption (Model, Thinking), then the rows: a 10pt tick column (✓ in
the accent colour on the current entry), the name, and for a model
the provider faint at the right. The highlighted row is the 8% well.
The bottom hint row reads "↑↓ move · ↩ choose · ⎋ close". While the
popover is up, its segment is filled (8% well, 5pt corners). ↩
applies through pi's `set_model` / `set_thinking_level` and closes;
⎋ closes with no change; a click outside closes. The model list is
what pi reports as available, grouped in pi's order.

## Notifications and extension status in the bar

An extension's `notify` is a toast in the bar's flexible segment:
a 12pt round badge with `i`, `!` or `✕` in the accent, warning or
error colour and the message in the fg colour, ellipsized. It stays
4 s; a newer one replaces it at once; a click dismisses it. An
extension's `setStatus(key, text)` adds a segment, "key text" with
the key faint, between the context segment and the flexible one, in
key order; an empty text removes it. In the narrow pane the
extension segments hide before the toast does.

## pi has exited

When pi exits (a code, or a signal), the transcript stays as it was.
The composer's place holds a card with a hairline in the error
colour at 35%: "pi exited · code N" (or "· signal SIGKILL") in the
title line with the time at the right, the last five lines of pi's
stderr in a muted well cut to 140pt, a faint line that names where
the whole log is, and the primary button "Start pi again"; ↩ presses
it. The stderr lines are the last five koa received; the whole
output is in the pane's terminal (koa writes pi's stderr to its own
stderr and keeps no log file). The status bar's dot turns to the error colour and its word is
"pi exited · code N"; the model, thinking and context segments keep
their last values. A start replaces the card with the composer and
continues the session.

## Times

Every step shows its own time at the right of its line, the thinking
step included (`✓ 6s`); a run's time is from its first step's start
to its last step's end. An aborted run shows its elapsed time like
any other, and its aborted step shows the time it ran before the
abort (`aborted 23s`).

## Keyboard

Everything works without a mouse. Command keys go to Kido first. In
the page: ↩ sends or steers, ⇧↩ newline, ⌥↩ queues a follow-up,
⎋ aborts (twice: clears the field); in a dialog ↑↓ ↩ ⎋ as above, ⌃↩
submits an editor, and ⎋ cancels the dialog, not the run; ↑↓ ↩ ⎋
inside a picker; ↩ on the exit card starts pi again. Tab moves from
the field to the dialog's controls, the queue's button, and the
model and thinking segments, in that order; ↩ or Space presses the
focused one. No Command key and no Control-letter key is bound in
the page: Command keys go to Kido first, Control letters are Cocoa
text bindings.

## Open questions (unit 5)

1. The `editor` submit key: ⌃↩ (mockup) or ↩ with ⇧↩ for newlines
   as in the composer? Recommendation: ⌃↩, because an editor's text
   is multi-line by nature and ↩ as submit loses text; ⌘↩ would go
   to Kido first.
2. Where the queue list sits: under the field (mockup) or above it,
   where the built page has `#queue`? Recommendation: under, so the
   field keeps its place and the queue reads as what follows the
   current message.
3. Pickers from the bar only, or also a `/model` style command in the
   composer? Recommendation: bar and keys only for now.
4. Toast replace or stack? Recommendation: replace; the bar has one
   line, and the log has every message.
5. On exit, start pi again automatically after a crash (code ≠ 0)
   once? Recommendation: no; the card makes the restart one key.
