# Pi surface — implemented journal

`index.html` is a synthetic interactive visual reference; `DECISIONS.md` preserves the design session and records implementation-driven changes. Swift implementation is authoritative. Preview controls and the outer frame are not product UI.

## Layout and appearance
Flat full-width journal, rule, composer, rule, single-line status. No avatars, assistant labels, centered reading lane, window toolbar or composer card. Host owns corner clipping. Native semantic window background, primary/secondary text and separator colors; HTML colors approximate them in light/dark.

Transcript rows have 12pt horizontal and vertical padding (24pt between neighboring row contents). Body is native system body, approximately 13pt; activity is callout, status caption. User markdown is medium weight in a full-width rounded block: 8pt radius, 9pt vertical/10pt horizontal padding, 3pt accent leading edge, window background blended 6% toward label color. Code uses a quiet fill and monospaced text.

## Activity and journal
Consecutive tool/thinking blocks form one disclosure. Summary preserves chronological runs, e.g. `thinking, read ×2, bash`; repeated thinking is not counted together. Preceding history truncates before the active final tool name. No durations: pi reports no timing.

Expanded label is `Activity · N steps`. Rows use a 65pt name column, 8pt gap, one-line monospaced first-line command/code/path preview, 5pt row spacing, and a separator rail inset 4pt with 13pt content padding. Active row uses primary text and the latest three output lines inset 73pt. Failed activities have a red failure label. Clicking a row reveals its thinking/tool details (arguments, output, patches and images where available).

Service markers have a disclosure and horizontal rules; warnings/errors remain readable with semantic icons. User and assistant content render markdown. Images can be opened separately.

Expansion/collapse keeps the reading anchor, grows downward and stops following the live end. Scrolling away shows the bottom-centered `to recent messages` capsule, inset 12pt, over the journal only. Clicking it or accepting a submitted prompt resumes following. Native scrolling uses a 1pt live-end threshold. `Load older messages` exists only when older history is available; loading preserves the visible anchor.

## Composer
12pt horizontal padding, 10pt top padding; 8pt vertical stack spacing; status included with 4pt bottom padding. Short editor and controls share a row with a 10pt gap. Wrapped/newline drafts take full width with controls right-aligned beneath. Editor grows to nine lines. Controls are small, borderless, 28pt high, spaced 6pt: paperclip plus Send, or Stop while streaming. No microphone. Send is accent-colored and disabled for empty/pending prompts; controls disable while disconnected/unsynchronized or a dialog is active.

Attach accepts multiple PNG/JPEG/GIF/WebP images and displays `N images attached`. Return submits (steering while streaming); Shift-Return inserts a newline; Option-Return submits follow-up. Escape clears queued work while streaming or queued. Notifications, queued prompts and extension widgets may appear above/below the editor. Errors appear below status. Extension dialogs use native sheets.

## Status
Model uses a native small borderless popup. Thinking levels are chosen from the status area's context menu, alongside extension status text, not from the model popup. Model selection does not display a thinking-level control.

Context usage appears only when usage is reported and model context capacity is known: `· 38.4k / 200k context` (synthetic example). Status at the trailing edge is Disconnected, Synchronizing…, Compacting…, Retrying…, Running or Ready, in that precedence. Status spacing is 6pt and its content height 19pt.

## Preview scope
Theme, width, host corners, running state, reported usage and older history are preview toggles. Model/context menus, attachment count, editor growth, safe literal draft submission, activity disclosure and history navigation demonstrate the structure, not RPC integration. All sample prose, commands and output are synthetic; no private sessions or captures are embedded.
