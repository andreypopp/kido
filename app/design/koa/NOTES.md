# koa — the webview harness, reference mockups

The files beside this one are self-contained mockups: inline CSS and
JS, no network. Open them from a static server (`python3 -m
http.server` in `app/design`) and use their controls: theme
(kido-light, kido-dark) and pane width (980pt, or 60 terminal cells).
Each numbered section is one state of the page, rendered inside a
frame that stands for the pane's content area. Click a run line or a
step line to fold or unfold it.

These notes give the look; docs/design-koa.md gives koa's design. Git
keeps the superseded designs and the rejected alternatives; these
notes describe only the current state, and the last section, the
question controls, is approved but not built yet.

## Index: the authoritative state of each part

| Part | Reference | Sections here |
| --- | --- | --- |
| Colours, fonts, the column | `mockup.html` | "Rules the page follows", "The transcript", "Compact spacing" |
| User message | `agents.html` (every page has it) | "The user message is the accent at 18%" |
| Runs and steps | `blocks.html` | "The run", "No step counts" to "No exit codes", "Times end at one edge" |
| The composer and its glass | `composer.html` | "The composer", "The composer floats over the transcript" |
| The composer's foot: state, model, level, context, cwd | `composer.html` | "The composer's foot" |
| A working agent | `composer.html`, the foot's breathing dot | "The composer", "The composer's foot" |
| Notifications and extension status | `composer.html` | "The composer's foot" |
| Dialogs, queue, pickers, exit card | `mockup.html` | "Dialogs from extensions", "The queue while koa works", "The model and thinking pickers", "pi has exited" |
| The completion popup | `complete.html` | "The completion popup" |
| Images, attachments, Quick Look | `media.html` | "Images, attachments and Quick Look" |
| Agent cards and job lines | `agents.html` | "Agent messages and job notices" |
| Question controls in a reply | `questions.html` | "Question controls in a reply" |
| The user message | `user.html` | "The user message is the accent at 18%" |
| `!` runs a command | `bang.html` | "`!` runs a command" |
| Built-in slash commands | `commands.html` | "Built-in slash commands" |
| Sessions inside the page | `sessions.html` | "Sessions inside the page" |
| Markdown in a thinking step | `thinking.html` | "Markdown inside a thinking step" |
| The foot at narrow widths | `foot.html` | "The foot at narrow widths" |

`working.html` holds the five working-state variants from which the
user chose; the foot of `composer.html` replaced the chosen one.
On 2026-11-11 `mockup.html`, `agents.html`, `complete.html`,
`media.html` and `working.html` got the shipped composer foot of
`composer.html` (status, model and level, context, cwd; no button)
and lost their bottom status bar, which the page has not had since
24b2451e. `composer.html` stays the reference for the foot's states.
`mockup.html`'s "Composer" and "User message" controls keep earlier
treatments for reference only.

## Rules the page follows

- **Only `--ko-*`.** The page's colours are `--ko-bg`, `--ko-fg`,
  `--ko-cursor` and the palette (`--ko-color-N`), and every other
  tone is a `color-mix` of them: muted text 55% fg, faint 35%,
  hairlines 12% and 18%, wells 5% and 8%. The accent is palette 4
  (blue), ok is 2, error is 1, warning is 3, so a theme's own palette
  colours the page. The `:root` block at the top of the mockup is the
  browser fallback, kido-light and kido-dark copied from
  `app/Resources/ghostty/themes`; in Kido.app the properties the app
  sets override it; in a browser the fallback follows
  `prefers-color-scheme`.
- **Two fonts.** Prose (user and assistant text, thinking, the
  composer's text) is the system font at `--ko-font-size`, line
  height 1.5. Everything that is a terminal fact is the terminal font
  (`--ko-font-family`): code, tool names, commands and paths on the
  run and step lines, times, diffs, bash output, job and notification
  lines, and the composer's foot.
- **No header.** The pane's sidebar row and the title tabs already
  name the agent and its session. The page is the transcript and the
  composer, nothing above.
- **No chrome of its own.** No borders around messages, no avatars,
  no bubbles. A user message is a block in the accent's tint ("The
  user message is the accent at 18%"); an agent card is a block in
  the 5% well. An assistant message is plain prose.

## The transcript

- Content column: 720pt wide, centred, 14pt top and 20pt side
  padding. In the narrow pane it is fluid with 12pt sides.
- An empty session shows nothing: the paper and the composer, no
  wordmark or "nothing yet" text (user, 2026-11-09).
- Markdown: headings in the prose font, 1.3/1.15/1em, 600 weight;
  lists with muted markers; inline code in an 8% well with 4pt
  corners; code blocks in a 5% well with a 12% hairline, 7pt corners,
  the language as a faint label at the top right; tables with a
  hairline under each row, uppercase muted header cells, no vertical
  lines; blockquotes with an 18% left bar.
- A user message's timestamp (user, 2026-11-08): the time of sending
  at the right of the message's first line, terminal font at 80%,
  in the accent ink ("The user message is the accent at 18%"),
  tabular digits, 14pt after the text, never wrapping; the
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
An agent card splits a run as a text does.

- **Collapsed** (default): one line, muted. A chevron, then the
  summary, then the elapsed time at the right. While running the
  summary is a gray spinner and the running label ("⟳ make cargo …",
  "⟳ thinking"); done, it is the tools by name ("thinking, read,
  edit, bash"; "bash x2" when one ran twice). A failed run colours the
  failed tool's name red; an aborted one reads "aborted, you pressed
  Escape". No counts and no icons; the sections from "No step counts"
  to "No exit codes" give each rule.
- **Expanded to lines**: the steps, under a hairline guide below the
  run line's chevron ("The steps guide under the chevron"). One line
  per step: the tool's name (a thinking block reads "thinking"), the
  command or path in the fg colour, the step's own detail in faint
  (`+5 −1`, `212 lines`, the thinking's first words), and the time at
  the right. Summaries ellipsize before the time; the time never
  wraps.
- **Expanded to details**: bash shows `cwd` and the output in a well,
  cut to 260pt and scrollable; an edit shows the file name in a
  header bar and a diff with added lines on a 12% green tint and
  removed lines on an 11% red tint, markers in the margin; thinking
  shows the full text as muted prose, 260pt cut and scrollable.
- Fold state is per run and per step, kept while the page is open.
  A run that is running stays collapsed unless the user opened it.

## The composer

- A 9pt-radius field on the dock's glass ("The composer floats over
  the transcript"), 9pt 12pt padding. Focused: the border takes
  `--ko-focus`, the pane's focus colour. The text grows to nine lines
  and then scrolls ("Question controls in a reply"); a quote line is
  in `--muted`. The editor draws its cursor in `--ko-cursor`.
- No button: Return sends (a steer while koa works), Escape aborts,
  and nothing in the field says so (user, 2026-11-10, with
  `composer.html`).
- Placeholder "Message koa…"; while koa works, "Steer koa…"; during a
  drag, "Drop to attach"; after pi exits, "pi has exited".
- **While the agent works** the field stays editable and its border
  rests; the foot's state dot breathes. Escape anywhere on the page
  aborts; a second Escape clears the field.
- **Markdown in the field** (user, 2026-11-09, without a mockup): the
  markup characters muted, strong bold, emphasis italic, code in the
  terminal font at the transcript's code size with no background,
  headings bold at the field's size, link text in fg; nothing else
  coloured.

## The narrow pane (60 cells)

Same page. The transcript column loses its centring margin, tables
and code blocks scroll inside their block, run summaries ellipsize,
and the composer's foot drops cells in the order of "The composer's
foot". Nothing hides otherwise.

## Decisions (user, 2026-11-08 and 2026-11-09)

1. Prose in the system font; terminal facts in the terminal font.
2. A finished run stays collapsed, also after a failure.
3. The context bar always shows.
4. A user message carries a timestamp, no label.
5. Compact spacing; the composer floats over the transcript on
   glass; an empty session shows nothing.

## Dialogs from extensions

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
stays visible and inert (the field keeps its text), the foot's state
says "waiting" with the orange dot, and focus is in the card; ⎋ in
the card cancels the request, not the run.

## The queue while koa works

Steering and follow-up messages that pi holds are listed above the
field (user, 2026-11-10; they were under it), inside the composer
column, with a 6pt gap under the list and none above; when the draft
has attachment chips, the order from the top is the queue, the chips,
the field: the chips belong to the draft and stay against it, the
queue is what pi already holds. A dialog card and its "+1 queued"
line stay above all of them. The list is one line each, a tag in the
terminal font (`steer`, `follow-up`) in a 62pt column, the text
ellipsized. Under them, the count and a "take back ⌥⌫" button, the
hairline button style, no key of its own (⌥⌫ is delete-word in the
field; Tab from the field reaches the button, ↩ or Space presses
it): it calls pi's `clear_queue` and puts every message into the
composer, each on its own paragraph in queue order, caret at the
end, the queue line gone. A queued row with attachments shows a
paper-clip glyph and their count after its text.

## The model and thinking pickers

The model cell of the composer's foot is two buttons: the model name
opens the model picker, the level opens the same picker with the
thinking levels. Tab from the composer reaches them (after the
queue's button when it shows), ↩ or Space opens. No key inside the
field opens them: ⌃M and ⌃T are Cocoa text bindings (newline,
transpose) that WebKit fields honour. The popover opens 8pt above the
cell, left-aligned 6pt out, 220pt minimum, a 9pt radius, the 18%
hairline, a soft shadow (fg 14%, 8pt down, 28pt blur), 6pt padding,
the terminal font at 88%. A faint caption (Model, Thinking), then the
rows: a 10pt tick column (✓ in the accent colour on the current
entry), the name, and for a model the provider faint at the right.
The highlighted row is the 8% well. The bottom hint row reads "↑↓
move · ↩ choose · ⎋ close". While the popover is up, its cell takes
`--well2`. ↩ applies through pi's `set_model` / `set_thinking_level`
and closes; ⎋ closes with no change; a click outside closes. The model
list is what pi reports as available, grouped in pi's order. When the
narrow pane drops the level's text, the model picker offers the
levels.

## pi has exited

When pi fails (a code other than 0, or a signal), the transcript
stays as it was. A card above the field has a hairline in the error
colour at 35%: "pi exited · code N" (or "· signal SIGKILL") in the
title line with the time at the right, the last five lines of pi's
stderr in a muted well cut to 140pt, a faint line that names where
the whole log is, and the primary button "Start pi again"; ↩ presses
it. The stderr lines are the last five koa received; the whole
output is in the pane's terminal (koa writes pi's stderr to its own
stderr and keeps no log file). The foot's dot turns to the error
colour and its word is "exited N" (or "signal 9"); the model, level
and context cells keep their last values. A start removes the card
and continues the session. A pi that exits with code 0 ends koa and
its pane, so it shows no card.

## Times

Every step shows its own time at the right of its line, the thinking
step included; a run's time is from its first step's start
to its last step's end. An aborted run shows its elapsed time like
any other, and its aborted step shows the time it ran before the
abort (`aborted 23s`).

## Keyboard

Everything works without a mouse. Command keys go to Kido first. In
the page: ↩ sends or steers, ⇧↩ newline, ⌥↩ queues a follow-up,
⎋ aborts (twice: clears the field), ⌃D in an empty field quits koa; in a dialog ↑↓ ↩ ⎋ as above, ⌃↩
submits an editor, and ⎋ cancels the dialog, not the run; ↑↓ ↩ ⎋
inside a picker; ↩ on the exit card starts pi again. Tab moves from
the field to the dialog's controls, the queue's button, and the
foot's model and level buttons, in that order; ↩ or Space presses the
focused one. No Command key and no other Control-letter key is bound
in the page: Command keys go to Kido first, Control letters are Cocoa
text bindings.

## Run and step lines in the system font (user, 2026-11-09)

The run line, the step lines and the thinking line are the prose
font now; only the glyphs and the code-like parts stay in the
terminal font.

- `.run`: `font: .95em/1.5 var(--prose)`, colour muted (was
  `.92em/1.6 var(--mono)`).
- Terminal font, `.92em`: the chevron, the tool names and
  "thinking" ("Tool names on the run line"), a command (`.cmd`), a
  path (`.path`) and the time at the right (`.time`, tabular digits,
  "Smaller timings"). The delta words and "aborted" are prose.
- The thinking block's text was prose already; it is `1em/1.5`,
  muted, `white-space: pre-wrap`.

## The thinking block's padding (user, 2026-11-09)

The space under an expanded thinking block came from three margins
that added up. Now: `.detail{margin:2px 0 4px 20px}`,
`.detail .think{padding:0;margin:0}`, `.detail pre{margin:3px 0 4px}`,
`.diff{margin:3px 0 4px}`. The block ends 4pt above the next step
line, like a command's output well does.

## Compact spacing (user, 2026-11-09)

| Property | Was | Now |
| --- | --- | --- |
| Pane line height (prose) | 1.6 | 1.5 |
| Transcript padding, wide | 22 24 10 | 14 20 8 |
| Transcript padding, narrow | 16 14 8 | 10 12 6 |
| Gap after a message or a run (`.msg`, `.run` margin-bottom) | 22 | 14 |
| Paragraph gap (`.assistant p`) | .9em | .65em |
| Heading margins | 1.3em 0 .5em | 1em 0 .4em |
| List margin-bottom | .9em | .65em |
| Code block (`pre`) | 1.5 line, 10 12 padding, 1em below | 1.45 line, 8 10 padding, .75em below |
| Run and step line padding, gap | 2 0, 9 | 1 0, 8 |
| Steps indent (`.steps` margin-left, padding-left) | 18, 12 | 17, 11 |
| Step margin | 1 0 | 0 |

The 720pt content column is unchanged: shorter lines read worse,
and the side margins were already the 20pt the narrow pane needs.

## The composer floats over the transcript (user, 2026-11-09)

**Layout.** The pane is the positioning context. The scroller
(`.scroll`) runs under the dock to the pane's bottom edge; the
transcript's bottom padding is the dock's height plus 8pt (`--dock-h`,
which the page measures with a ResizeObserver on the dock), so the
last message is never under the glass when scrolled to the end. The
dock (`.dock`) holds the dialog card and its "+1 queued" line, the
composer (its queue, then the chips, then the field), and the exit
card. It sits on the
pane's bottom edge, `pointer-events: none` with `auto` on its
children, so a click beside the composer reaches the transcript.

**Glass.** On `.field`, `.dialog`, `.exited .card` and `.queue` inside
the dock:

    background: color-mix(in srgb, var(--ko-bg) 72%, transparent);
    -webkit-backdrop-filter: blur(18px) saturate(1.35);
    backdrop-filter: blur(18px) saturate(1.35);
    border: 1px solid color-mix(in srgb, var(--ko-fg) 22%, transparent);
    box-shadow: inset 0 .5px 0 color-mix(in srgb, #fff 28%, transparent),
                0 6px 22px color-mix(in srgb, var(--ko-fg) 14%, transparent),
                0 1px 3px color-mix(in srgb, var(--ko-fg) 10%, transparent);

The queue list gets the same surface with `border-radius: 8px;
padding: 4px 8px 6px`; the one-line "+1 queued" note has a
`text-shadow` of the background so it reads over text. The glass is
CSS only: WebKit's private system glass material needs a private
preference and does not show in WebKit's snapshots.

**Contrast.** The glass is 72% of the pane background over an 18pt
blur: a code block or a table under it becomes a soft tone shift, not
legible shapes, and `--fg` text on it measures within a few percent of
`--fg` on the plain background.

**The unfocused pane.** The glass is a mix of `--ko-bg`, which the app
shifts to the unfocused paper together with the pane, so a focused and
an unfocused pane differ by the same step inside and outside the
composer.

## No step counts (user, 2026-11-09)

The run line names no steps: no "step i of n" while running (the
number is not known in advance), no "N steps ·" before the kinds when
done or failed, and "aborted, you pressed Escape" without a count.
The done line lists the tools by name, "xN" when one ran several
times ("thinking, read, edit, bash", "read, bash x2"); The failed
run colours that tool's name red in the same list.

## No kind marks (user, 2026-11-09)

Step lines carry no sigil ($, ✎, ◇, ∴). The action name is the mark:
"bash make verify …", "read ko_server/src/sweep.rs 212 lines", "edit …
+5 −1", "write …", a generic tool by its name, and "thinking". The
name is muted, the label in the fg colour.

## No status icons (user, 2026-11-09)

No check, cross, abort glyph or spinner on a run line or a step line.
Colour alone carries the status: gray (the muted tone) for success,
running and aborted, red (`--ko-color-1`) for a failure. No word "failed"
anywhere: on the run line the failed tool's name is red in the list
("read, bash x2" with "bash x2" red); on its step the name and the
time are red, with no outcome word and no exit code (user, 2026-11-09:
"let's not specify exit codes"); the output holds what the command
printed. A finished step shows
only its time; a running one shows the time counting, no "…". The
edit's "+5 −1" keeps green and red: it is the diff count, not a
status.

## Tool names on the run line (user, 2026-11-09)

The run line uses the tool's name, never "command": "bash", not
"command". A tool that ran N times is "bash xN", not "N commands";
once is the bare name. The same form for every tool: "read x2",
"edit". A failure is the red name, never the word "failed" or an exit code.

Tool names are in the terminal font (`--ko-font-family`, .92em like
the labels): the step's name span and the run line's list of names
(user, 2026-11-09), and the "thinking" label with them. "failed",
"running" and the aborted text stay in the prose font.

## The steps guide under the chevron (user, 2026-11-09)

The hairline at the left of a run's steps is under the run line's
chevron: .steps has margin-left 4pt (the glyph is centred in its 9pt
box, so its ink is at 4.5pt in both states) and padding-left 13pt, so
the step lines start 18pt from the run's left edge.

Tool output and diffs inside a step's detail are smaller than the step
text: .detail pre and .diff at .88em; user, 2026-11-09.

## Running: a gray spinner, no word, no bold (user, 2026-11-09)

The run line in progress shows an animated spinner in the gray tones
(8pt ring, 1.5pt, `--hair2` with a `--muted` arc, .8s) and then the
running label as regular text in the muted tone: "⟳ make verify
STAGES=unit", "⟳ thinking". The word "running" and the bold label go.
The spinner is the one animated mark; the status-icon rule still holds
for finished states (colour only).

## Even word spacing on a step line (user, 2026-11-09)

The step summary (.step .sum) is set in the terminal font at .92em, so
the spaces between the name, the label and the detail are all terminal
spaces; before, the spaces were prose spaces between terminal-font
spans and looked narrower. The detail text ("212 lines", "+5 −1", a
thinking's first line) is reset to the prose font at the step size
(1.087em of .92em).

## The chevron on the spinner's centre (user, 2026-11-09)

The chevron glyph (›) is centred in its 9pt box (text-align center)
and dropped 1pt (position relative, top 1pt), so its ink, folded or
rotated open, is centred on the spinner and on the x-height middle of
the label.

## No empty output box (user, 2026-11-09)

A tool step's detail shows the output pre only when there is output;
a running bash with nothing yet shows just its cwd line, and a tool
that ended with empty output shows no box.

## Smaller timings (user, 2026-11-09)

The times on the run line and on the step lines are .8em of the line
in the terminal font and the
faint tone as before.

## No exit codes (user, 2026-11-09)

A failed bash step shows no "exit N": only its name and its time in
red, like any other failed tool. The outcome column holds a word only
for "aborted".

## The completion popup (complete.html; approved, 2026-11-09)

`complete.html` is the reference for the composer's completion
(docs/design-koa.md, "The composer"). It copies `mockup.html`'s
style block and draws the popup over the floating glass composer in
six states, light and dark, wide and 60 columns:

1. `/` at the start: every command of `get_commands` (templates,
   skills, extension commands), first row current, 8 of 10 visible.
2. `/re`: pi's fuzzy filter; `skill:` names by their bare name first.
3. `@si`: the session's agents first, as ko-pi shows them, then
   files; a directory ends with `/`.
4. `@ko_s`: files and directories alone, the base directory's
   entries first.
5. `@` in the middle of a message, the second row current, text after
   the caret.
6. `@zzz`: no match closes the list; there is no empty state.

**The card.** The dock's glass (`--ko-bg` 72% over a blur), its 22%
hairline and shadow, radius 9pt, padding 5pt, 6pt above the field.
Width: at least 260pt, at most 460pt and never wider than the field;
it opens at the token's x (the `/` or `@`, less the 9pt row padding)
and shifts left to stay inside the field. Rows: 23pt (the .95em prose line
plus 3pt padding top and bottom), radius 6pt, 8pt horizontal
padding, the current row on the 8% well (`--well2`), at most 8 rows
(184pt) before the list scrolls. A footer in the faint
terminal font: "↑↓ move · ⇥ ↩ accept · ⎋ close".

**A row.** The label in the terminal font at .92em in the fg colour:
`/name`, `@name`, or the path (a directory with a muted trailing `/`).
The detail in the muted tone, prose at .92em, ellipsized: a command's
description; an agent's status, activity and parent ("running -
applying the review findings, subagent of kido-app"); a file has none.
A kind tag at the right in the faint terminal font at .8em for
commands (`template`, `skill`, `extension`) and agents (`agent`); files
and directories carry none, the trailing `/` tells them apart. The
fuzzy-matched letters of a command or agent name are bold; paths are
plain.

**Keys** (the plan's): ↑↓ move, Tab accepts, Enter accepts and, for a
command, sends; Escape closes. The typed token in the field is the
accent colour for `/` and the fg colour for `@`, in the mockup only, to
show where the popup anchors; the page need not colour it.

Fixtures: the extension commands `/koa`, `/runtime`, `/review` and the
skill `/skill:ko-api` are invented for the list; the templates and the
other skills are the user's. Renders: `/tmp/koa-shots/complete-<state>-<theme>-<width>.png`.

## Images, attachments and Quick Look (media.html; approved, 2026-11-10)

`media.html` is the reference for images, attachments and Quick Look
(docs/design-koa.md), ten states, light and dark, wide and 60 columns. It copies
`mockup.html`'s style block.

**Images in the transcript.**
- A `read` of an image: the step's delta is `png · 1440×900` (the
  sniffed type and the pixel size) in place of "N lines". Open, the
  detail shows pi's note ("Read image file [image/png]") in the faint
  tone at .85em, then the thumbnail: the image at its own aspect, at
  most 240pt tall in a step (160pt in a user message), a `--hair`
  border, radius 6pt, `--well` behind it while it loads; the pixel
  size in a small label at its lower right on hover. It is a button
  (`role=button`, `tabIndex 0`, zoom-in cursor): click, Space or
  Enter previews it. Several images in one result sit in a row that
  wraps, 6pt apart.
- A user message: the text, then its thumbnails (160pt), then the
  path lines of its file attachments in the terminal font at .92em
  in the muted tone, one per line. The time stays at the right of
  the first line.
- An image that is gone (404, 410): a dashed `--hair2` box, 120×80pt,
  radius 6pt, "Image unavailable" in the faint prose at .8em; not a
  button.

**Attachments.** A chip row above the field, inside the dock,
6pt gaps, wrapping. A chip is 28pt tall, radius 7pt, a `--hair2`
border, the dock's 72% glass fill, at most 320pt wide: a 20pt square
(the image's thumbnail, cover-cropped, or a document glyph on
`--well2` in the muted tone), the name (ellipsized), then the size in
the faint terminal font at .85em, then × (16pt, faint, `--well2` on
hover). A path chip shows the directory muted after the name instead
of a size. An upload shows the run line's gray spinner in the 20pt
square and "18 / 41 MB". A refused chip has its border tinted 45%
`--err` and the reason in red prose in place of the size ("over 64
MB", "too many", "not readable"). A click on the chip's body previews
it; × removes it. Drop hover: the field's border turns dashed at 45%
fg and the placeholder reads "Drop to attach"; nothing else moves. A
folder in any drop, local or not, is not attached (user, 2026-11-10:
no `@dir/` for now): one line in the chip row in the muted prose at
.85em, "Folders are not attached", for 4 s or until the next drop;
the files of the same drop still become chips. The queue: a row with attachments shows a
paper-clip glyph and the count after its text in the faint terminal
font. After Send: the chips go and the user message shows the
thumbnails and path lines above.

**Quick Look.** While ⇧ and ⌘ are both held, the path of a
`read`, `edit` or `write` step with a file takes the pointer cursor
and an underline in the muted tone, offset 2pt (a page-level `cmd`
class that keydown and keyup set from `metaKey && shiftKey`);
⇧⌘-click previews the file (user, 2026-11-10: the terminal's
Shift-Command-click on images), a plain click folds. Other steps show nothing. The browser lightbox: a fixed
overlay on the dock's glass (72% `--ko-bg`, blur 18) over the whole
pane, the image at its natural size at most the viewport less 24pt a
side and 96pt of height, radius 6pt, a shadow; a caption below in the
faint terminal font: name · pixel size · "click or ⎋ to close".

Renders: `/tmp/koa-shots/media-<state>-<theme>-<width>.png`, states
read-image, user-images, image-gone, chips, drop, folder, queue, sent,
cmd-hover, lightbox. Approved by the user on 2026-11-10 ("mockups look
good, please go ahead"), as shown.

## Agent messages and job notices (agents.html; approved, 2026-11-10)

`agents.html` is the reference for agent cards and job lines
(docs/design-koa.md): what passes between agents and what background
jobs report, light and dark, wide and 60 columns. It copies
`mockup.html`'s style block. The texts are ko-pi's (`noticeHeader`,
`senderHeader`, `RELATION_TEXT`, `steerHeader`, `jobEndText`,
`streamBatch`, the `spawn_agent` reply). The user's direction
(2026-11-10): messages look
like user messages with a "to @name" / "from @name" header, two
lines at most with a toggle; job notices are one minimal line,
name, exit and time, gray for success and red for failure, with a
toggle for the output.

**An agent message** (outgoing: `spawn_agent`, `message_agent`;
incoming: ko-pi's `ko-message`, `ko-steer`, `ko-notice` and a
report) is the user message's block: `--well` fill, radius 8pt,
padding 6pt 12pt 7pt, with a header line above the text.
- The header, one phrase in the muted prose at .92em (user,
  2026-11-10; nothing in the header is in the terminal font except
  the time): `<kind> to|from @<name> <relation>`, as "message to
  @sidebar-right", "steer from @kido-app parent", "report from
  @sidebar-right subagent"; the @name in 600 in the fg; the relation
  one word in the faint tone (`subagent`, `peer`, `parent`; none for
  ko-pi's own notices); at the right only the time, .8em terminal
  faint tabular; for incoming the relation faint after a "·" (RELATION_TEXT
  shortened: "your parent", "your subagent", "another agent in this
  session", "a subagent of your subagent"; none for ko-pi's own
  notices); the kinds: `task` (a spawn), `message`, `steer`,
  `interrupt` (outgoing); `message`, `steer`, `report`, `ended` (a
  child's end), `notice` (ko-pi's own) (incoming). No delivery status
  (user, 2026-11-10: no delivered, queued, sent, spawned): a failure
  takes the kind's place, in red ("refused to @name", "not reported
  from @name subagent"). A card splits the run
  it sits in.
- The body is the text as prose. Collapsed (the default), it is one
  line: the first line of the text, cut with an ellipsis (nowrap,
  text-overflow), so a card is two lines at most (user, 2026-11-10:
  "too much info … 2 lines max"); the ellipsis is the sign of more.
  A click anywhere on the block expands it to the whole text
  (pre-wrap); a second click collapses it. Every block toggles, so a text
  that wraps in a narrow pane also stays one line until clicked; a
  text that fits shows no ellipsis.
- No meta lines: a spawn shows no session, window, pane or model
  line, and a cut report shows no "full report: read_report(…)"
  trailer (user, 2026-11-10). A failed spawn has the name and
  "refused" in red and ko-pi's refusal as the body; a refused
  `message_agent` keeps its text and the refusal in red in place of
  "delivered".

**A job notice** (`async_bash`'s end notice, a `ko-stream` batch) is
one line; since 2026-11-11 (unit koa-jobline) it takes the run
line's look of item 5 in "refine.html": prose .95em, muted, the
name as plain row-coloured text, no end text on the folded line
(the exit code or the failure is in the opened body), the name in
`--ko-color-1` when it failed, as a failed tool call; the kind
label, the time and the opened body are as before. Before that it
was one line in the terminal font at .92em, muted: a chevron (as a
step's), the job's name in fg, the kind only when it is not a plain
job (`service`, `stream`, faint .85em), the end in ko-pi's words
("exit 0", "exit 1", "signal SIGKILL", "failed: …", "timed out
600 s"; none for a stream batch), and the time at the right in faint
tabular digits. Gray when it succeeded; the name and the end in
`--err` when it failed (exit ≠ 0, a signal, failed, timed out). A
click on the line opens the output under a 1pt `--hair` guide at
17pt, 11pt of padding (a step's geometry): the tail in a `--well`
pre, radius 7pt, at most 200pt, scrolling; consecutive stream
batches of one job in one entry, separated by "+ HH:MM" lines; then
"log: <path> · … N lines omitted" faint, ellipsized. Closed by
default.

**Plain agent tools** (`list_agents`, `read_report`, `stop_agent`,
`list_async_bash`, `stop_async_bash`) stay steps in a run, by name
with their first argument, as blocks.html draws them.

The states cover, in: a message from a parent, a child and a peer, a
steer, a notice, a report, an ended child that reported or not, job
ends with exit 0, exit 1, a signal and a timeout, and a stream; out: a
spawn and a message, with their failures; a folded text; a card
between runs; narrow.

Renders: `/tmp/koa-shots/agents-<state>-<theme>-<width>.png`, states
out, failed, in, jobs, fold-a, fold-b, tools. Approved by the user on
2026-11-10, as shown.

## The composer's foot (composer.html; approved, 2026-11-10)

`composer.html`: koa has no status bar; its facts are in the
composer's foot, the row under the text. Eight states, light and
dark, wide and 60 columns. The foot is the terminal font at .8em,
20pt tall, 2pt below the text and 5pt above the field's bottom edge,
no button; its
cells, left to right, each with a 1pt `--hair` separator 10pt either
side:

1. **The state**: a 6pt dot (faint for idle and starting, `--ko-color-2`
   breathing for working, `--ko-color-3` for waiting, `--ko-color-1`
   for exited) and the word with its time in tabular digits: "idle",
   "working 12s", "waiting", "starting", "exited 137" / "signal 9".
   **Reserved width: 15ch of the .8em terminal font plus the dot and
   its 6pt gap** (`min-width: calc(15ch + 12px)`, about 106pt at the
   13pt base), the width of "working 12m 34s"; so a state change or a
   tick moves nothing to its right (user, 2026-11-10). Escape aborts;
   nothing in the row says so.
2. **The model**: "claude-opus-5-5 · high" (the level faint), two
   buttons: the name opens the model picker, the level the thinking
   picker ("The model and thinking pickers"); the cell takes
   `--well2` while a picker is open or on hover.
3. **The context**: the 44pt bar (18% track, faint fill, warning colour
   over 75%), "84k / 200k" faint, the percent; reserved at the bar
   plus 3ch.
4. **Extension statuses**: an extension's `setStatus(key, text)` is
   one cell for each key, in the foot's cell style, gone when its
   text goes.
5. **The gap**: flexible, the one cell with no reserved width.
6. **The cwd**: the leading directories faint, the last component
   muted, at the field's right padding.

Nothing else is in the composer (user, 2026-11-10: "no icons … only
status, model picker, context, cwd"): Return sends and Escape aborts,
and nothing says so. A notification is one line in the transcript
where it arrived: terminal font .92em muted, the text
ellipsized, the time at the right in faint tabular digits as a job
line; a warning in `--warn`, an error in `--err`; no badge; it stays.

Narrow (60 columns) drops, in order: the extension statuses, the
thinking level, the cwd's leading directories, the context numbers;
the bar, the percent, the model, the state and the cwd's last
component stay, and the state keeps its reserved width. The dock sits
on the pane's bottom edge. Renders: `/tmp/koa-shots/composer-<state>-<theme>-<width>.png`,
states idle, working, waiting, exited, picker, toast, toast-err,
narrow. Approved by the user on 2026-11-10, as shown.

## Times end at one edge (user, 2026-11-10)

Every time on the page ends at the transcript column's edge. The user
message's block and the agent cards outset by their horizontal
padding, so the time inside them ends at the column's edge, and a run
line, a step line, a job line and a notification line have no right
inset, so their times end at the same edge.

## The user message is the accent at 18% (user, 2026-11-10)

The user message's block is `color-mix(in srgb, var(--accent) 18%,
var(--ko-bg))` (`--accent` is `--ko-color-4`), in place of the 5% gray
well, so it carries more weight than the agent message blocks, which
keep the 5% well; radius 8pt and padding 7pt 12pt. The user
chose it from 9, 13, 18 and 24% and from gray 12 and 16%. Every koa
mockup page has it; mockup.html's "User message" control keeps the
old treatments for reference.

Its time is not the faint gray: over the tint that read as dirty
(user, 2026-11-10). It is an accent ink, `color-mix(in srgb,
var(--accent) 60%, var(--fg))`, .8em terminal font as before, in
light and dark. The same for a blockquote in the user message (a
quote from ⌘O or a question control): the gray text read as dirty on
the tint (user, 2026-11-10), so `.msg.user blockquote` takes the
same accent ink and its 2pt bar the accent at 45% over transparent;
inline `code` in the user message takes the accent at 12% over
transparent in place of the gray well; a fenced block in the user
message is the accent at 10% over transparent with a 30% accent
edge, the text in `--fg`, no language label; the paths of sent
attachments (media.html) take the quote's ink. Nothing in the user
message is gray. user.html shows every state: one line, paragraphs
with a list and code, one quote with its answer, two quotes in one
message, a code block, attachments, a long message; light and dark,
wide and narrow. Renders: `/tmp/koa-shots/user-<state>-<theme>-<width>.png`,
states one, paras, quote, quote2, code, attach, long. agents.html's `data-ut` holds the two rejected
alternatives (fg over the tint, the bare accent) for reference.

## Question controls in a reply (questions.html; approved, 2026-11-10)

The "reply annotations" contract (docs/reply-annotations.md, and
docs/design-koa.md, "Reply annotations"): an
extension marks the questions of a final reply (range, kind, the
options of a choice), and the page puts controls in the prose. The
labels and the click rule are the TUI's (pi-infer-questions,
`extension.ts:333-360`), except that no blank line separates the
answer from its quote: a choice shows each option in
place, then Other; a choice with one option shows the option, then
Yes, Other; a yes/no question or a proposal shows Yes, No, Other; an
open question shows Answer. A click sends nothing: it puts the
question as a quote (`> ` lines) and, on the next line, the answer into the
composer, after the current text and a blank line; a second click on
the same question replaces its answer (Other replaces it with
nothing; a block per question; `answer()` in the mockup is the TUI's
function without its blank line, as the page has it since 0e4cea65).
The question's own text is not styled.

- **An option in place** (`.ann`): the question's own words as a
  button in the prose, the accent colour, a 1pt underline at 40%
  accent 3pt under the baseline (a link's is 35%: an option's is a
  shade stronger, and it is a button, not a link), 1pt horizontal
  padding, 3pt radius. Hover: a 12% accent fill and the underline at
  full accent. Selected (its answer is in the composer): the 18%
  accent fill (the user message's tint), the text in `--fg`, no
  underline, a 1pt outline of the same fill so the fill clears the
  descenders. An option that wraps keeps its fill across the break.
- **The labels** (`.ctl .ann`): chips 8pt after the question's end,
  4pt apart, in the question's line and font: .88em, the accent with a
  1pt edge at 35% accent, 5pt radius, 0 6pt padding, line-height
  1.45. Hover: the 12% fill and the edge at full accent. Selected: the
  18% fill, `--fg`, no edge. In a list item, a table cell or a
  heading, the chips follow the text where it ends; in a paragraph
  that goes on after the question ("Do you want the Linux check at
  all? It costs…") the chips sit between the sentences.
- The "Labels" control shows the TUI's form for reference (words
  with slashes, underlined, no chips); the chips are the proposal.
- **The composer** after a click: the plain Markdown, the quote
  lines (`> …`) in `--muted`, the answer on the next line in `--fg`,
  the cursor at the end; `.field .text` grows to 9 lines before it scrolls (6 before)
  so two answered questions show whole.
- Narrow: nothing changes in size; the chips wrap as words.

Renders: `/tmp/koa-shots/questions-<state>-<theme>-<width>.png`,
states reply (hover on "wait for CI" and on a "Yes"), answered (two
clicks), narrow; and `questions-reply-slash-light-wide.png` (the TUI's
labels). Approved by the user; the chips version is built
(docs/design-koa.md, "Reply annotations").

## `!` runs a command (bang.html; shipped 2026-11-10: 3695fb19, Tab completion 16c79407)

As pi's TUI: a message that starts with `!` is a shell command, not a
prompt. koa sends pi's `bash` RPC command (docs/rpc-commands.md,
"bash"; output streams as `bash_execution_update`), and pi stores a
`bashExecution` message, which the model gets as user text before its
next turn. `!!` sends it with `excludeFromContext: true`: stored and
shown, never in the model's context. `!` or `!!` followed by a space
is allowed; `!` alone is the mode with no command, and Return does
nothing.

**The composer.** The one mode cue is the font: while the text starts
with `!`, `.field .text` is `var(--ko-font-size)/1.5
var(--ko-font-family)` (the whole text, not only after the `!`). The
`!` is the accent at 600; the `!!` pair is `--muted` at normal weight
(a quiet run). The foot's state cell reads "run" or "run, quiet" in
`--muted` in place of "idle", so the row says what Return does; model,
context and cwd stay. No tag, badge or border change, no button.
Completion: `@` and `/` are off in this mode; path completion stays
(a command takes paths). Attachments: a command takes none. A drop in
`!` mode is refused with the usual line under the field ("a command
takes no attachments"); chips present when `!` is typed stay, and
Return does not send while they exist (the state cell "run" in
`--err`, tooltip "remove the attachments").

**The transcript.** A user-run command is a line of its own kind
(`.cmdrun`) in a run line's geometry, placed where it ran: a `!` in
the accent at 600 in the chevron's 9pt slot (a faint `!!` for a quiet
run, tooltip "not in the model's context"; nothing marks a `!` run),
the command in the terminal font .92em in `--fg` (`--err` when the
exit is not 0, as a failed tool's name), and at the right in the
time's place, `.8em` terminal faint: "exit N" in `--err` when N is not
0, "cancelled" for a cancelled run, then the duration. The output is
folded by default and opens on a click of the line: a step's guide
(4pt margin, 1pt `--hair`, 13pt padding) and a `pre` as a step's
output (.88em, `--well`, `--hair` edge, max 260pt, own scroll), in
`--fg`. While it runs, the spinner takes the `!`'s slot, the output
is open and streams in `--muted`, and turns `--fg` at the end. A
cancelled run keeps the output it got. Truncated output (pi's
`truncated`) ends with "… full output: <path>" in the faint terminal
font.

**Cancel, and a busy pi.** While a command runs and pi is idle, the
field stays in `!` mode with the text cleared, placeholder "running…
⎋ cancels", state cell "running Ns" with the breathing dot; Return
sends nothing, Escape cancels (pi's `abort_bash`), typing starts the
next message. While pi works, a `!` message runs at once, as pi 1.5.0
does (only the session record waits for the turn's end): its line is
appended at the end of the transcript, under the streaming reply, and
streams there while the reply goes on above it; the state cell stays
"working Ns" (the turn is the session's state; the command's spinner
says it runs); the field returns to the working placeholder "Steer
koa…". Escape then cancels the command first (`abort_bash`); a second
Escape aborts the turn.

**Tab completes, from bash** (user, 2026-11-10: Tab only, bash
only, where the command runs). Tab asks bash for the completions of
the word at the caret (bash-completion's functions where installed,
else command names and paths); nothing completes as you type. The
answer is plain words, so there are no kinds and no detail column.
One match: the word completes inline, with a space after it, or `/`
after a directory, as bash reports it. Several: the common prefix is
inserted inline first, then the list opens in the `/` popup's
geometry (`.complete.sh`): rows in the terminal font .92em in
`--fg`, bash's order, eight visible then scroll; a second Tab or ↓
moves, ↩ or Tab accepts, ⎋ closes, typing closes it (the next Tab
narrows). The list never opens by itself. None: the state cell reads
"no completions" in `--faint` for 1.5 s in place of "run"; nothing
moves (the cell's reserved width holds it). Slow (over 150 ms): the
state cell reads "completing…" with the spinner in the dot's slot
until the answer; Tab waits, typing cancels the request. Cap: 200
words fetched; over it, the last row "… N more, type to narrow" in
`.8em` `--faint`, not selectable.

Renders: `/tmp/koa-shots/bang-<state>-<theme>-<width>.png`, states
bang, bang2, runs, running, busy (both running), typing (`!` typed
while pi works), tab (five matches after the prefix), tab-none,
tab-pending, tab-cap. Shown to the user for a final look;
the spec went to the implementer the same day.

## The composer's focus border (2026-11-10)

The focused treatment (`--ko-focus` border) is a fact of the page, not
of the DOM focus: the composer looks focused whenever a keypress would
reach it. Rule: `.field.focus` is set when the document has focus
(the window is key and the pane is Kido's focused pane) and no other
text input of the page holds the focus (a dialog's field, a rename, a
search); the hairline shows otherwise. The page sets the class on
`focus`/`blur` of the window and on every focus change inside the
page; `:focus-within` is not used. Cases: a click or a selection in
the transcript keeps it focused (printable keys still go to the
composer); the completion popup, the model picker and a running `!`
command keep it focused (they are the composer's own, or typing starts
the next message); an open dialog card with its own field, and the
lightbox, show the hairline (keys go to them); pi exited shows the
hairline always (the field is disabled). The mockups already show the
treatment as a static `.focus` class and do not change.

## Built-in slash commands (commands.html; shipped: 172b8bcc)

koa runs seven of pi's built-ins itself through RPC: `/model`,
`/thinking`, `/compact`, `/session`, `/copy`, `/export`, `/quit`
(with `/name`, and `/resume` and `/new` from sessions.html). Every
other pi built-in (`/settings`, `/tree`, `/fork`, `/login`, `/reload`,
`/hotkeys`, …) gets one notice line in `--warn`, "/x is not available
in koa", and the text never reaches the model.

- **In the popup**: one list; the built-ins first, in a fixed order
  (model, thinking, compact, session, copy, export, name, resume, new,
  quit), then `get_commands` in its order; the kind column reads
  `built-in` in the same faint tone as `extension`, `template`,
  `skill`; the detail is pi's one-line description. The fuzzy filter
  runs over all together. Refused built-ins are not listed.
- **Outcomes** are lines in the transcript where the command ran, in
  the notice geometry (terminal .92em `--muted`, time at the right,
  12pt in): `/copy` "copied the last reply · N characters"; `/export`
  "exported <path>", the path in `--fg`, ⇧⌘-click Quick Look as a
  step's file label; `/model x` and `/thinking x` with an argument set
  through pi and give the existing "model: … · thinking …" notice;
  without an argument they open the foot's picker (the one the click
  opens), nothing in the transcript. A result with more than one line
  is an **info line** (`.info`, a job line's geometry: chevron, name in
  `--fg`, the rest muted, time right; closed by default, a click opens
  a body behind a step's guide): `/session` "name · N messages · $x"
  opening to a key/value grid in the terminal font (name, id, file,
  model, messages, tokens in/out/cache read/cache write, cost,
  context); `/compact` first a notice with the spinner "compacting…"
  while the state cell reads "compacting Ns" with the breathing dot,
  then the info line "compacted · 184k → 31k tokens" opening to pi's
  summary as prose; a failure "compact failed: <message>" in `--err`.
  `/quit` ends pi and koa; the pane closes as a shell's exit does;
  nothing is drawn.
- **Prompt history**: Up on the first line of an empty or unedited
  field puts the previous submitted prompt in the field, Down the next;
  a draft typed before Up comes back with Down. No cue: the field looks
  as when the user types. **Alt-Up** takes the queue back, the same as
  the queue's button; the list goes, the texts stand in the field; no
  other cue.

Renders: `/tmp/koa-shots/commands-<state>-<theme>-<width>.png`, states
pop, pop-filter, outcomes, picker, session, compact.

## Sessions inside the page (sessions.html; shipped: 55094dd9)

`/resume` opens a session picker; `/new` starts a new session (pi's
`switch_session`, `new_session`). The picker is a card in the dock
above the field, where an extension's dialog card sits (`.sess` in
the `.dialogs` column: the dialog's 9pt radius, hairline and glass;
padding 9pt 10pt 8pt; the column's 10pt under it; rows are a grid,
name and first message in the first column, date over count in the
second), so the transcript stays visible and the keys are the
dialog's; the composer under it is inert (text in `--faint`).

- **Top row**: the search field (focused; fuzzy over name and first
  message, as pi's selector), and at the right a two-part scope "this
  folder" / "all" (.8em terminal, 6pt radius, the on part in
  `--well2`); ⇥ switches it; this folder is the default.
- **Rows**, newest first, 4pt 8pt padding, 6pt radius, current in
  `--well2`, 8 visible then scroll: the name in `--fg` (the first
  message when unnamed), then `current` for the open session (.8em
  terminal faint) and, in "all", the folder in faint .9em; the first
  message under it in `--muted` .92em, ellipsized; at the right the
  date (time today, date otherwise) over the message count, .8em
  terminal faint, tabular. ↩ on the current row does nothing.
- **Empty**: "no sessions in this folder" with the hint "⇥ all
  folders" under it; "no match" with a search.
- **Switch**: the card closes, the transcript empties, the field is
  inert with "loading…", the state cell reads "loading"; then the
  session's transcript, scrolled to the end, with one notice line
  "session: <name> · N messages"; the foot shows its model and
  context. `/new`: an empty transcript and the notice "new session".
  The queue goes with the old session; the draft in the field is kept.
- **While a turn or a `!` command runs**: pi's confirm dialog first,
  "Switch session?", "koa is working on a turn; it will be aborted."
  or "a command is running; it will be cancelled.", ⎋ Cancel, ↩
  Switch; Switch aborts (`abort` or `abort_bash`), then opens the
  picker or starts the session.

Renders: `/tmp/koa-shots/sessions-<state>-<theme>-<width>.png`, states
pick, pick-all, pick-search, pick-empty, loading, after, confirm.

## Markdown inside a thinking step (thinking.html; shipped: 5e339b57, rendered when the step is expanded)

An expanded thinking step (`.think`) renders its text through the
reply's Markdown renderer. The rule: the thinking tone stays. The
whole block is `--muted`; bold is weight alone; code and quotes go a
shade quieter, not louder; headings are body size; the 260pt scroller
is the one scroll. The reply's `.prose` rules for `p`, `ul`, `ol`,
`li`, `blockquote`'s geometry, `a`'s geometry, `hr` and `table`
apply as they are. What changes, on `.think`:

- `.think`: `font: 1em/1.5 var(--prose); color: var(--muted);
  white-space: normal` (was pre-wrap); `max-height: 260px; overflow:
  auto; padding: 0 12px 0 0; margin: 0`. `.think > :first-child
  { margin-top: 0 }`, `.think > :last-child { margin-bottom: 0 }`.
- `li::marker`: `--faint`. `strong`: weight 600, colour inherited.
- `code`: `.92em var(--ko-font-family)`, colour inherited, background
  `--well` (the reply's inline code has `--well2`), radius 4pt,
  padding 1pt 5pt.
- `pre`: `.88em/1.45`, colour inherited, `--well`, 1pt `--hair`,
  radius 7pt, padding 8pt 10pt, margin .3em 0 .75em, `max-height:
  none`, `overflow: auto hidden` (horizontal scroll only), no
  `.lang` label (`display: none`). `pre code`: no background, 1em.
- `h1`–`h6`: `600 1em/1.35`, colour inherited, margin .8em 0 .3em.
- `blockquote`: colour `--faint`, bar 2pt `--hair2`, margin .3em 0
  .75em. `hr`: 1pt `--hair`, margin .6em 0. `table`: .95em, `th`
  `--faint`, rules `--hair`. `a`: colour inherited, 1pt `--hair2`
  underline (not the accent).

Renders: `/tmp/koa-shots/thinking-<state>-<theme>-<width>.png`,
states basic, rich, long.

## The foot at narrow widths (foot.html; shipped: 9b218d82)

Shipped with the 540, 340 and 200 steps below as CSS px of the field container (page.css), plus a 630px step for the extension status that the mockup does not draw.

The composer's foot drops its cells by its own width, a container
query on `.field` (`container-type: inline-size`), not the window's:
the field is what the cells must fit, whatever the pane and the
sidebar do. The pane is the foot plus 74pt (the composer's 24pt and
the field's 12pt on each side, and the 1pt borders).

- **Full**, foot 540pt and up: state · model · level · context bar,
  numbers, percent · cwd. Natural widths at 13px: state 106 (its
  reserved width), separators 1 + 10 each side, model 145 (level 38 of
  it), context 137 (numbers 63), cwd 100.
- **Step 1**, under 540: the thinking level, the cwd's leading
  directories and the context numbers go (`.lvl`, `.cwd .lead`,
  `.ctxc .n` display none; `.ctxc` min-width 44px + 6px + 3ch). The
  bar and the percent stay, "kido" stays.
- **Step 2**, under 340: the model, its separator, the gap and the
  cwd go (`.model`, `.model + .sep`, `.gap`, `.cwd`); the context takes
  `margin-left: auto`: the state at the left, the context at the
  right.
- **Step 3**, under 200: the context and the state's separator go
  (`.ctxc`, `.st + .sep`); the state's reserved `min-width` is
  released (0, overflow hidden, its text ellipsized), so the widest
  texts ("working 12m 34s", "completing…") fit a 200pt foot and
  ellipsize under it.
- The cwd is `flex: 0 1 auto; min-width: 0; max-width: 40cqw` with an
  ellipsis at its end, in every step, so a deep directory never pushes
  the other cells; the gap has no min-width (`padding: 0 5px`).
- **Reachable**: `/model` and `/thinking` open the pickers the hidden
  cell opened; `/session` lists the model and the context numbers;
  the cwd is the pane's title in the sidebar and in `/session`.
- The state texts of every mode go through the same steps with the
  cell's reserved width intact in steps 1 and 2: "run", "run, quiet",
  "completing…" with the spinner, "compacting Ns", "working Ns".

Renders: `/tmp/koa-shots/foot-<row>-<theme>.png`, rows idle, run,
quiet, comp, compact, work, cwd; each row the foot at 600, 480, 300,
200 and 150pt. Measured: no foot overflows at any width.

## refine.html: the width, the user message, agent lines, @names (2026-11-11, proposals)

Four refinements the user asked for, on the shipped page. Decided
2026-11-11: the width (1); the user message is F, solid accent (2),
with its dark rule below; the agent line without the chevron, its
lead "kind to @name relation" one run of text with ordinary spaces
(3); the links (4). Every item's time ends on the transcript's text
edge: the user block's time sits `--pad` in from the block's edge,
the agent line's and the run's at the edge.

**1 · The composer's width.** Shipped: the transcript's text is 680pt
(720 − 2×20), the user block 704 (−12/+12 of margin), the composer's
field 672 (720 − 2×24) and its text 648. Proposed: the composer takes
`--side-pad` − `--pad` (8pt; 4pt narrow) of padding and the field
`--pad` (12pt) of its own, so the field is the user block's width
and its text edge is the assistant's. `.dialogs` and `.exited` take
the same 8pt. One rule in page.css; nothing moves in the transcript.

The sides do not shrink in a narrow pane (user, 2026-11-11): the
narrow 12pt/8pt put the user block and the field 4pt from the pane's
edge, where they blended with its border. `--side-pad` stays the wide
value and `--pad` too at every width (20pt and 12pt then; 24pt and
16pt since item 6); the narrow rule keeps only its
top and bottom (10pt and 6pt in the transcript, 10pt under the
composer). The "Compact spacing" table's narrow row becomes
10 20 6.

**2 · The user message**, six treatments, a picker on the page:
A the shipped 18% accent tint; B a bubble at the right, at most 82%
wide, the time under it; C no fill, a 2pt accent bar, the text on
the transcript's text edge; D the composer's own card (background,
`--hair2` hairline, 9pt radius, a 1pt shadow at 8%), the time faint;
E no block, the text at 600 and 1.04em, a `--hair` rule under the
message; F the accent as the fill and `--ko-bg` as ink in a light
theme; in a dark theme (`--ko-appearance: dark`) the fill is the
accent at 82% over `--ko-bg` and the ink is white, because the dark
themes' accent is darker and the page's background on it does not
read. The quote, the code and the paths take the ink at 80%, 18%
and 80%; `pre code` keeps no background.

**3 · A message between agents is one line**: `kind` to|from
`@name` relation, the first line of the body ellipsized in the muted
tone, the time at the right on the text edge; .95em prose like a
run line, without a chevron (the picker shows it with one). The lead
is one run of text with ordinary spaces, not flex items with gaps;
an 8pt gap separates it from the body's start. A click opens the body under the line, 16pt in with a
`--hair` left rule like a run's steps, and hides the ellipsized
start; a second click closes it. A refused call or a failed spawn
colours the kind, the name and the start red. This replaces
agents.html's card: no fill, no two-line header.

**5 · One look for run lines and agent lines** (user, 2026-11-11;
the "Rows" picker, `unified`). A run line and an agent line (and a
job line, which drops its end text and shows a failure by its name
in `--err`; unit koa-jobline) are the same row: no chevron (the
whole line is still the
click that opens it); the prose font at the row's .95em for the tool
names, the step names and the lead, the mono only for a command or a
path inside a step; the time in the prose font at .8em with
`font-variant-numeric: tabular-nums`. While a tool runs the line
says its name, then the spinner 6pt after it ("bash ◌"), not the
command. Every row is indented by `--pad` (12pt; 16pt with item 6)
from the transcript's text edge; an opened run's steps and an
opened agent line's body (its bar at the row's start, the text 12pt
in) indent from that point, never back to the edge; the times end on the text edge, as the user
block's timestamp does (the run line's 12pt right padding goes).
Consecutive run, agent and job lines sit 2pt apart (4pt at first;
the user asked for less); the last of the group keeps the 14pt gap
after it, and an opened row keeps 14pt
under its body.

**6 · The composer's padding** (user, 2026-11-11, v3 of three): the
scale grows so the alignment of item 1 holds. `--side-pad` is 24pt
and `--pad` 16pt at every width, so the transcript's text is 672
wide, the user block and the field 704, and both sit 8pt from the
pane's edge; the user block pads 8pt 16pt, the field 12pt 16pt 8pt
(was 9pt 12pt 5pt). The narrow rule keeps only its top and bottom,
as decided for the narrow padding.

**7 · Radii** (user, 2026-11-11): the composer's field and the user
block are 12pt (were 9pt and 8pt, which looked square beside
macOS 27's rounder controls); 12pt is the pane capsule family's
radius. The other radii (code blocks 7pt, chips, the queue 8pt)
stay.

**4 · `@name` links to the agent's pane.** Every name of an agent
(an agent line's, a `@name` in the answer's or the user's prose, a
`list_agents` step) is an `<a class="who">`: 600, the text's colour,
no underline; hover is the accent with a 1pt underline at 45% and
the hand pointer; the title is "Focus the pane of @name". A click
asks the host to focus that pane, as a sidebar click does. koa links
a `@name` in prose only when the name is in ko-pi's agent list at
render time; otherwise it stays text. An ended agent keeps 600 in
the muted tone and is no link.
