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
