# A color for each connection in Kido.app

Status: research done, no code changed. Paths are under `app/`.
This plan builds on `plans/app-no-tab-bar.md` (the title is in the
sidebar top row) and on the work that now makes the focus ring show on a
single or zoomed pane and gives the title the ring color. Do that work
first, or do both in one pass.

## The problem

Windows for Local and for each remote look the same. The user cannot see
at a glance which machine a window is connected to. A per-connection color
fixes this. The color is used for the window title and for the focused-pane
ring. The title also shows `user@ip`, which is not a name.

Wanted:

1. Each connection (Local, each remote) can have its own color. About 8
   presets and a custom color picker.
2. The color is used for the title text and the focused-pane ring.
3. The title shows the connection name (for example "devbox"), not
   credentials or an IP address.

## Verified facts (from code and docs; the app was not run)

### What a connection is

- `enum Host { case local; case remote(String) }`
  (`App/Host.swift:28`). The remote payload is the dial destination, an
  SSH alias or `user@hostname`, validated at `Host.swift:34`.
- `Host.clipboardKey` is `"local"` or `"ssh:<destination>"`
  (`Host.swift:51`). It is already the key of persisted per-host grants
  (`ClipboardConsent`, `Host.swift:3`, UserDefaults keys such as
  `clipboardReadHosts`). `docs/design-app.md` (Clipboard) says SSH aliases
  are not merged with resolved hostnames.
- `Host.label` is `"Local"` or the destination (`Host.swift:55`).
- There are no "saved remotes". There is only a recent list:
  `RecentHosts` (`Packages/SidebarFeed/Sources/SidebarFeed/RecentHosts.swift:3`),
  entries of `{host: String, date: Date}`, stored as JSON in UserDefaults
  key `recentHosts` (`App/RemoteIntent.swift:31,34`). It is refreshed by
  every remote path (`RemoteIntent.swift:41`) and cleared by "Clear Recent
  Hosts". Background (test) runs keep no preferences
  (`RemoteIntent.swift:29`).
- Remote windows are created from the Connect mode of the palette
  (`App/Palette.swift:5`, `PaletteMode.connect`; entries in
  `App/PaletteEntries.swift:150-170`), `kido-app://` URLs, the App Intent
  and File > Connect to Remote Host (`App/main.swift:217`). No settings
  window exists. No connection has a user-given name.
- Stable identity: the destination string, that is `clipboardKey`. There
  is no rename feature, so "stable across renames" means: if the user
  edits an alias in `~/.ssh/config`, nothing is renamed in the app. A new
  alias is a new connection, with a new color.
- Each `WindowOwner` has an immutable `let host: Host`
  (`App/WindowOwner.swift:52`). Two windows to one host are two owners
  with the same host.

### How the title is computed

- `WindowOwner.show(title:)` sets `window.title` and
  `sidebar.windowTitle` (`WindowOwner.swift:284-287`).
- Connected: Local shows `SessionModel.title`, `"<session> — <window>"`
  (`App/SessionModel.swift:29-33`). Remote shows
  `"\(identity ?? host.label) / \(model.title)"` (`WindowOwner.swift:832`).
  Offline: `"Local"` or `identity ?? host.label` (`WindowOwner.swift:1102`).
- `identity` is the string `user@hostname` from `ssh -G`
  (`App/SSH.swift:115-120`: `user + "@" + hostname`), so an alias "devbox"
  shows as `alex@10.0.3.7`. This is what the user does not want. Before the
  `ssh -G` result arrives, the title uses the alias.
- `identity` is also used for: the upload sheet text (`WindowOwner.swift:541`),
  the pending-connect tuple (`WindowOwner.swift:223`), the notification
  subtitle (docs: "using the resolved identity the window title shows",
  `docs/design-app.md:1503-1506`), `testIdentity` (`WindowOwner.swift:1134`)
  and `RemoteTests.swift:377`. It also invalidates the tab strip layout
  (`WindowOwner.swift:79`), which the no-tab-bar plan removes.
- `docs/design-app.md:102-104` states the current title rule.

### Where the accent is drawn

`controlAccentColor` is used in these places (grep of `App/`):

| Place | File:line | Role | Follows the connection color? |
| --- | --- | --- | --- |
| Pane edge, spacing 0 (`FocusEdge.stroke`, 50% alpha) | `PaneChrome.swift:7` | focused pane | Yes |
| Card ring, spacing > 0 (1.5pt) | `PaneChrome.swift:81` | focused pane | Yes |
| Sidebar column focus edge (`FocusEdge` instance) | `Sidebar.swift:45,178`, `PaneChrome.swift:4` | keyboard focus is in the sidebar | Yes: it is the same "where focus is" cue |
| Window title text | `Sidebar.swift:123` | title | Yes |
| Pane drop preview fill (30%) | `PaneChrome.swift:121` | transient drag target | No, keep system (transient) |
| Toolbar capsule ring (40%) | `PaneChrome.swift:197` | control highlight | No, keep system |
| Sidebar reorder insertion mark | `SidebarView.swift:32` | transient drag target | No |
| Session rename field edge (40%) | `SidebarRow.swift:231` | text editing | No |
| Palette "Connect to <text>" row text | `Palette.swift:126` | app-level palette | No |
| Icon button hover tint | `IconButton.swift:82` | control | No |
| Prompt box Send fill, quote bar | `PromptBox.swift:124,304` | control | No (could follow later) |

Find highlights are drawn by Ghostty, not by the app. The sidebar row
selection does not use `controlAccentColor`. The mute rule: color that
means "this window / where you are" follows the connection. Color that
means a control state stays the system accent.

All focus strokes draw inside `performAsCurrentDrawingAppearance`
(`PaneChrome.swift:20,70`), so a dynamic system color resolves at draw
time. The focus treatment is set in `WindowView.updateFocusTreatment`
(`App/WindowView.swift:361`), called from layout, appearance and focus
changes.

### Where state lives

- `GhosttyRuntime` is one instance for the whole app (`AppDelegate` owns
  it; `main.swift:79-80`). Views hold `runtime` (for example
  `PaneChrome.runtime`). It is global, so it cannot carry a per-host value
  by itself. It holds `KidoSettings` (`GhosttyRuntime.swift:34`:
  `sidebarShade`, `unfocusedShift`, `paneSpacing`).
- `WindowOwner` is per window and has `host`, the `Sidebar`
  (`sidebar.windowTitle`) and the session views. `updateAppearance()`
  (`WindowOwner.swift:289`) already pushes the theme to the sidebar and
  `session?.updateBackground()`. It runs on every config change
  (`main.swift:79`). This is the natural place to push an accent.
- `WindowRoutes` (`RemoteIntent.swift:26`) is the app-owned preference
  store for hosts (`recentHosts`). `AppDelegate` owns it as `routes`.

### Config versus app state

- `kido-app.conf` is Ghostty syntax, hand-edited, reloaded live by file
  watch (`GhosttyRuntime.loadConfig`, `GhosttyRuntime.swift:200-272`; the
  app's three own keys at `:207-211`; `docs/design-app.md:294-372`). The
  app never writes it.
- UserDefaults holds what the user changes in the UI: `recentHosts`,
  `sidebarCollapsed`, `nativeSidebarWidth`, clipboard grants
  (`WindowOwner.swift:215,228`, `Sidebar.swift:161,211`, `Host.swift`).

### Contrast (reasoning; not measured)

- The title sits on the sidebar shade (the terminal background shifted 5%,
  `docs/design-app.md:309-312`) when docked, and on the canvas (terminal
  background) when collapsed (`Sidebar.swift:228-240`). The sidebar has
  its own light/dark appearance from the luminance of its shade
  (`docs/design-app.md:339-349`), and the title label takes it
  (`Sidebar.swift:236`). Collapsed, the label uses the window appearance
  (`Sidebar.swift:230`), which follows the terminal background
  (`WindowOwner.swift:297-299`).
- System colors (`.systemRed`, ...) adapt to the appearance they resolve
  in. A custom `NSColor(srgbRed:...)` does not. Light-theme variants of
  yellow, orange and green are known to be low-contrast on white. This
  must be measured in step 1 and not assumed.
- The theme can be any `kido-app.conf` background, so no preset is safe
  on every background. A runtime check is the only complete answer.

## Options

### Where the color is stored

| Option | For | Against |
| --- | --- | --- |
| A. UserDefaults, one dictionary `hostAccents: [clipboardKey: Accent]` | Same place as every other per-host user choice. Set from UI. No file writes by the app. One source of truth. | Not editable by hand. |
| B. `kido-app.conf` keys, for example `kido-accent-local`, `kido-accent-ssh-devbox` | Hand-editable, live reload exists. | The app must write a Ghostty-syntax file that the user also edits (two writers). A UI choice would have to rewrite a file with includes. Keys are dynamic, but the config reader knows three fixed keys. |
| C. Store inside the recent list | Reuses `RecentHosts`. | The user clears recents: that would lose the color. Local is not in it. Mixes two facts. |

**Recommend A.** The color is a UI choice, not theme configuration.
`kido-app.conf` stays the file the user writes and the app only reads.
Hosts cleared from recents keep their color (the color is not a recent
fact).

### How the user picks the color

| Option | For | Against |
| --- | --- | --- |
| 1. Palette mode "Color" (list of swatches + "Custom…") | One command palette for the whole app (`docs/design-app.md:1323`). Keyboard-first. Same shape as Rename mode. The menu item gives it a shortcut-less command row. | A new palette mode: chip, foot, tests, mockup. |
| 2. Menu with a submenu of swatches (Window > Connection Color) | Native, visible, small. | Menu images for swatches need drawing. A submenu is not reachable in the palette (the palette reads fixed commands from menu items; submenus are skipped). |
| 3. Context menu on the sidebar title | Direct. | Hidden. The title in the collapsed state is not a control. |
| 4. Always open `NSColorPanel` | Full freedom. | No presets. The panel is a separate floating window. |

**Recommend 1**, with a menu item Window > "Connection Color…" that
enters the mode (like Rename Session…). The mode lists the 8 presets as
rows with a swatch and the name, plus "Automatic" (reset) and "Custom…".
"Custom…" closes the palette and opens the shared `NSColorPanel`, opaque
colors only (`showsAlpha = false`). Its action target is the anchor owner
and is cleared when the panel closes.

### Default color before the user picks

| Option | For | Against |
| --- | --- | --- |
| a. Everything system accent | Zero new behavior. | No clue where you are. |
| b. Local: system accent. Remote: a preset chosen from a stable hash of the key | Remote hosts differ with no action. Nothing stored, so no stale state. | Two hosts can collide. The hash must be stable (not Swift `hashValue`, which varies per launch): use FNV-1a over the key. |
| c. Remote: sequential first unused preset, then stored | No collisions at first. | Stores a derived choice. Order depends on history. |

**Recommend b.** Local keeps the system accent, so an existing user sees
no change on Local. "Automatic" in the palette removes the stored value.

## Recommendation

1. Data (one source of truth). A value `Accent`:
   `.automatic`, `.preset(Preset)` or `.custom(red, green, blue)`
   (sRGB components, Double). `Preset` is an enum of 8 names: red, orange,
   green, teal, blue, indigo, purple, pink. Yellow and gray are left out
   (low contrast). A preset maps to the matching `NSColor.systemX`, so it
   adapts to light and dark by itself. Custom stores one color; it is
   used as is for the ring.
2. A store `HostAccents` (UserDefaults key `hostAccents`, JSON
   `[String: Accent]` by `Host.clipboardKey`). Plain value type with
   `accent(for:) -> Accent`, which resolves `.automatic` as above.
   `AppDelegate` owns it next to `routes`. No UserDefaults in background
   runs, like `routes`.
3. `WindowOwner` has a computed `accent: NSColor` (resolved value for its
   host). The owner pushes it from `updateAppearance()` to
   `sidebar.accent` (title and sidebar edge) and to the session views
   (`WindowView` sets it on each `PaneChrome` in `updateFocusTreatment`;
   `FocusEdge.stroke` takes the color as an argument). A change of the
   store calls `updateAppearance()` on every live owner of that host.
4. Title text uses `accent.legible(on: titleBackground)`: if the contrast
   ratio is below 4.5:1, mix the color toward the foreground by the
   smallest 5% steps (existing `NSColor.mixed(toward:amount:)`,
   `GhosttyRuntime.swift:20`) until it is. The ring uses the raw color
   (non-text UI needs 3:1; a ring that fails 3:1 against the pane paper
   gets the same mix). One helper, one rule, in the file of `Accent`.
5. The title shows the connection name. See step 5.

## Open questions for the user

1. Is the ssh alias the right "connection name"? The plan uses the
   destination as typed (alias or `user@host`), with no user-given name.
   A separate "display name" can come later and would be a second field.
2. Should Local also get an automatic distinct color, or keep the system
   accent? The plan keeps the system accent.
3. Should the notification subtitle and upload sheet also use the new
   name? The plan says yes (one name for one fact).

## Implementation steps

1. **Measure first.** A small throw-away script (not committed) that
   computes WCAG contrast of each preset, in the light and dark built-in
   themes, against the sidebar shade and the canvas, for the text (4.5:1)
   and the ring (3:1). Drop or adjust any preset that fails both themes.
   Record the numbers in this plan before step 3.
2. **Data model.** Add `App/Accent.swift`: `Accent`, `Preset`, `Codable`,
   `nsColor`, `legible(on:)`, the FNV-1a automatic choice. Add
   `HostAccents` with the UserDefaults store (follow `WindowRoutes`). Unit
   tests next to it (see Tests).
3. **Wire the color.**
   - `AppDelegate` creates `HostAccents`; `WindowOwner` reads the color
     and pushes it in `updateAppearance()` (`WindowOwner.swift:289`).
   - `Sidebar.titleLabel.textColor` (`Sidebar.swift:123`) and the sidebar
     `FocusEdge` take the accent; set on each `updateAppearance`.
   - `FocusEdge.stroke(_:floating:)` (`PaneChrome.swift:7`) and the card
     ring (`PaneChrome.swift:81`) take the color from a `PaneChrome.accent`
     property, set in `WindowView.updateFocusTreatment`
     (`WindowView.swift:361`) with `needsDisplay` on change.
   - All other `controlAccentColor` uses stay (table above).
4. **UI.** Add `PaletteMode.color` (symbol `paintpalette`, chip "Color")
   in `Palette.swift`, entries in `PaletteEntries.swift` (8 presets with
   swatch, "Automatic", "Custom…"), the menu item Window > "Connection
   Color…" in `main.swift`, and the root row (commands are read from menu
   items). Choosing a row writes the store and closes the palette.
   "Custom…" opens `NSColorPanel`. The row for the current value is
   marked. Local and remote windows use the same mode.
5. **Title naming (point 3).** Replace `identity ?? host.label` by
   `host.label` in the two title calls (`WindowOwner.swift:832,1102`).
   Then `identity` is used only by the upload text, the notification
   subtitle and the tuple at `:223`: switch them to `host.label` as well,
   delete `identity`, `testIdentity`, the `ssh -G` user/hostname
   parsing for it (`SSH.swift:115-120`) and the `start` return value if
   nothing else reads it. Keep `ssh -G` if it is still used for
   validation. Update `RemoteTests.swift:377`.
6. **Docs.** `docs/design-app.md`: the title rule (`:102-104`); Focus
   treatment (`:706-709`, `:741-744`, `:911`: the color is the
   connection's, system accent is not used for focus); the sidebar title
   and edge; Command palette (new Color mode, root list, accessibility
   labels, `:1323-1450`); notification subtitle (`:1503-1506`); Testing
   (`:1547`, new palette states). State that `hostAccents` is app
   state in UserDefaults and not a `kido-app.conf` key. Then delete this
   plan.
7. **Mockup.** Extend `design/palette/mockup.html` with the Color mode
   states and add a `design/connection-color/` mockup of the title and
   ring in 3 colors, light and dark. The manager compares the snapshots
   with the mockup (AGENTS.md "Working here as a spawned agent").

## Tests

- Unit (Swift packages or the app test target, whichever hosts
  `RecentHosts` tests): `Accent` JSON round trip; `HostAccents` set,
  reset, key by `clipboardKey`; the automatic color is stable for a key
  across runs and equals a fixed expected preset for 3 sample keys;
  Local is system accent; `legible(on:)` reaches 4.5:1 for every preset
  and for 3 hard custom colors (yellow, near-white, near-black) on both
  built-in themes.
- Visual snapshots (`app/VisualTests`, `make visual RECORD=1`, review the
  images):
  - Docked and collapsed sidebar, title in the preset color, light and
    dark, for Local and a remote named by alias (title shows the alias,
    not `user@ip`; update the existing remote assertion).
  - Focus ring in two preset colors and one custom color: spacing 0 and
    8, two panes, a single pane, a zoomed pane, light and dark. Also the
    sidebar-focused edge.
  - Palette Color mode: root row, mode list, current mark, after pick,
    light and dark, as the mockup states.
  - Unchanged control-state accents (drop preview, reorder mark) keep
    their old references: a negative control.
- Behavior (off-screen owner tests): two windows to one host change color
  together; a window to another host does not; the store survives
  re-creation of the store from the same UserDefaults suite.
- Run `make visual` once at the end; do not also run other recipes.
