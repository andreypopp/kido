# Kido.app configuration in `config.yaml`

Status: plan, 2026-11-04. Design only; no code exists yet.

Kido.app reads its terminal settings from `~/.config/kido/kido-app.conf`
in Ghostty's syntax and gives that file to Ghostty whole
(`app/App/GhosttyRuntime.swift:264-330`). Every one of Ghostty's
several hundred keys reaches the surfaces, and `config-file` includes
pull in more files. The user's direction: a fixed set of options, which
Kido controls, in YAML.

The decisions of the top-level session on 2026-11-04 that this plan
builds on:

- ONE configuration file for everything:
  `$XDG_CONFIG_HOME/ko/config.yaml`, else `~/.config/ko/config.yaml`;
  `ko server --config FILE` names another.
- A new crate `ko_config` (unit ko-rt-yaml builds it now) owns the
  file: the `Config` struct, the YAML 1.2 decode (saphyr-parser into a
  typed tree: a typed field gets a core-schema bool, int or float; a
  string field takes any plain scalar as text), the path, and the JSON
  schema `share/ko/config-schema.json`. `ko_server` and `ko_client`
  depend on it. Kido.app links it through `ko_client`.
- One parser and one owner for the whole file. Every config type is
  serde-derived (`Deserialize`, `deny_unknown_fields`) with a
  schemars-derived schema. A rule that serde cannot express is a
  newtype with `#[serde(try_from = ...)]`. No hand-written per-type
  parsing.
- Server keys (`runtimes:`) are top-level. The app's settings live
  under one top-level `app:` key.
- The app reads and validates the file through `ko_client`'s C ABI,
  which returns the decoded config as JSON matching the schema, or
  errors with line and column. Its Swift types are generated from
  `config-schema.json` as `KoSchema.swift` is generated from
  `openapi.json`. The Swift side maps the typed values to the Ghostty
  config string.
- On a remote host the server reads only its keys; the app reads
  `app:` from the Mac's file.

This plan adds the `app:` types to `ko_config`, the C ABI, the Swift
mapping, the themes, the errors and reload, and the move of the app.

## 1. Goals and non-goals

Goals:

- A closed whitelist of terminal options. Each one has a type, a
  default, a range and one Ghostty key. Ghostty gets only a string
  that the app generated from typed values
  (`ghostty_config_load_string`). No user file, theme file included,
  reaches Ghostty unchecked.
- The app's own settings (the sidebar shade, the unfocused shift, the
  clipboard policy, the theme pair) come from the same typed value,
  not from a second reader of the same text.
- An error names the file, the line, the column and the key, and the
  user sees it in the app, not only on stderr.
- The theme picker keeps writing the file.

Non-goals:

- Reading Ghostty's own configuration (`~/.config/ghostty/config`) or
  `config-file` includes. Both stop. A user who wants the same font in
  Ghostty and Kido writes it twice.
- Every Ghostty option. A key that the whitelist lacks is an unknown
  key, an error. The whitelist grows by a decision, one key at a time.
- Keybinds in the first version (section 4.3).
- A preferences window. The file is the UI; the palette's Theme mode
  stays the one in-app writer.
- Migration of `kido-app.conf`. The old file stops being read
  (AGENTS.md, "No backward compatibility"). Section 9 says what the
  user does once.
- `kido.conf` (the old kido file that `website/src/pages/index.astro:99`
  and `:107` still describe). Nothing reads it today; the website
  text is stale and section 9 removes it.

## 2. What exists today

The app's Ghostty configuration (`app/App/GhosttyRuntime.swift`):

- The path: `$XDG_CONFIG_HOME/kido/kido-app.conf`, else
  `~/.config/kido/kido-app.conf` (`:147`). Tests pass their own file.
- `loadConfig` (`:264`) builds a `ghostty_config_t` in layers: the
  defaults string (`:266`: the theme pair, `cursor-style-blink = false`,
  `alpha-blending = linear`, `scrollback-limit = 536870912`, four
  `keybind = super+...=unbind`), then the user's file whole
  (`ghostty_config_load_file`, `:268`), then its `config-file` includes
  (`ghostty_config_load_recursive_files`, `:269`), then the tiling
  string `/kido` (`:318`: no padding, no scrollbar), then the theme
  override of a preview or a session theme (`:320`). After `finalize`
  it reads the user's clipboard policy back out of Ghostty (`:104`)
  and then loads `clipboard-read = deny` and `clipboard-write = deny`
  over it (`:112`), because the server, not the mirror, answers OSC 52.
- The two app keys `kido-sidebar-shade` and
  `kido-unfocused-background-shift` (`:254`) are read by a second,
  hand-written line parser of the same file and of its `config-file`
  includes in Ghostty's order (`:271-316`), and their "unknown field"
  diagnostics are filtered out (`:258`).
- Each pane reads `mouse-scroll-multiplier` by serializing the whole
  config and scanning for the line (`app/App/PaneView.swift:640-651`).
- Each pane clones the app config and loads a per-pane string
  (`background-opacity = 0` for the unfocused shift,
  `image-storage-limit` from the server's limit;
  `app/App/PaneView.swift:877`). This stays: it is generated, not user
  input.
- Reload: a file watcher on the file and its directory (`:369-414`),
  a 100 ms debounce (`:415`), Ghostty's `reload_config` action (`:466`),
  a serialize-and-compare to find whether Ghostty's part changed
  (`:349-355`), `font-size` compared separately so every pane gets the
  new size (`:357-362`).
- Diagnostics: Ghostty's, kept in `diagnostics` and `fileDiagnostics`
  and printed to stderr through `note` (`app/App/main.swift:613`). The
  palette's Theme mode reads them to mark a theme that failed
  (`app/App/PaletteTheme.swift:62-76`).

Themes (`app/App/PaletteTheme.swift`, `app/App/ThemeConf.swift`):

- Six bundled themes in `app/Resources/ghostty/themes` (`:41`), found
  by bare name because `app/App/main.swift:625` sets
  `GHOSTTY_RESOURCES_DIR`. Ghostty searches `~/.config/ghostty/themes`
  first, so a user file of the same name there shadows a bundled
  theme today (docs/design-app.md:319-322). User themes are the files
  of `~/.config/kido/themes` (`:55`), named by absolute path.
- A theme file is a Ghostty config file. Ghostty loads it with every
  key it may contain (`third_party/ghostty/src/config/Config.zig:4660`,
  `loadTheme`), and the picker's swatch loads it the same way
  (`:85-88`). Only the bundled themes are "audited to set safe keys"
  (`Config.zig:578`).
- `ThemeConf` reads and rewrites the one `theme` line of
  `kido-app.conf`, keeps every other byte, writes a temporary file
  beside the resolved target and renames it (`ThemeConf.swift:52-88`).

The user's file today (`~/.config/kido/kido-app.conf`): `font-family`,
three `font-feature` lines, `font-size` and
`kido-unfocused-background-shift`. Nothing else. There is no
`~/.config/ghostty`.

Other app settings: `UserDefaults` holds only window state
(`sidebarCollapsed`, `nativeSidebarWidth`:
`app/App/Sidebar.swift:169,227`, `app/App/WindowOwner.swift:223,242`)
and remote-host grants (`app/App/Host.swift:5`,
`app/App/RemoteIntent.swift:27`). They stay in `UserDefaults`: they
are state that the app writes, not configuration that the user
writes.

The ko side: the app starts its server with `server --server DIR`
only (`ko_client/src/launch.rs:160`), so the scrollback limits
(`ko/src/main.rs:241-253`) and the knobs of docs/design.md "Knobs"
(`KO_*` variables, `ko_server/src/config.rs:362-382`) are at their
defaults in Kido.app. The server reads `config.yaml` through
`ko_config` (docs/design-runtimes.md, "The configuration file").

## 3. The file and its readers

### 3.1 Shape and ownership

    runtimes:     the server's (ko-rt-yaml)
    app:          Kido.app's (this plan)
      theme:
      font:
      cursor:
      keyboard:
      mouse:
      clipboard:
      window:

`ko_config::Config` gets one field `app: App` (`#[serde(default)]`),
and `App` and its sections are types of `ko_config` (a module
`ko_config::app`), serde- and schemars-derived, every record with
`deny_unknown_fields`, every rule in a newtype (section 4). The
server decodes the whole struct and uses `runtimes` only; the app
decodes the whole struct and uses `app` only. One file is valid or
invalid as a whole: a wrong app key fails the server's runtime
requests too, and a wrong runtime fails the app's reload. That is the
cost of one file and one owner, and the plan accepts it: the error
names the line either way, and the user fixes one file.

A remote window (docs/design-app.md "Remote hosts") shows a server on
another host with this Mac's font and theme: the app reads `app:` from
the Mac's `~/.config/ko/config.yaml`, and the server on the host reads
`runtimes:` from the host's `~/.config/ko/config.yaml`. One format,
one path on every host, each host reads its own copy. The app never
sends its settings to a server, and a server never serves its file.
The app must also work with no server: at launch, before the first
dial, and while the local server is stopped. So the app parses the
file itself, through `ko_client`, which links `ko_config`.

### 3.2 The C ABI

Two functions join `ko_client/include/ko_client.h`,
`ko_client/src/ffi.rs` and `ko_client/exports.txt` together (AGENTS.md
"Layout"). Both are thin wrappers over `ko_config` functions.

    ko_code ko_config_load(const char *path, ko_buffer *out);

Reads and decodes the file. `out` is JSON. On success,
`{"config": Config}`: the decoded `Config` as JSON matching
`config-schema.json`, defaults filled in, so the app decodes it with
the generated Swift types and reads `config.app`. A missing file is
the default `Config`. On failure, the code is `KO_ERR_INVALID` (or the
existing code that the header uses for a refused input) and `out` is
`{"error": {"line": N, "column": N, "message": "..."}}`, the same text
that `ko runtime` prints for the same file (`<file>:<line>:<column>:
<message>`), so the app and the CLI name a fault alike. The function
blocks on one file read; the app calls it on main, as it reads the
file today.

    ko_code ko_config_set_theme(const char *path, const char *light, const char *dark, ko_buffer *out);

The theme picker's writer (section 6.3), a function of `ko_config`
because `ko_config` owns the file. On success `out` is
`{"written": true|false}`; on failure the same error object.

The Swift types: `app/scripts/gen-ko-model.py` takes a third input,
`share/ko/config-schema.json`, and writes `Config`, `App` and the
section types into `KoSchema.swift` as it writes `ModelJson`. The
schema test (`app/KoTests/KoSchemaTests.swift:5`) then covers them, so
a schema change without `make ko-model` fails the app's tests, as
today for the model. The script must learn the `oneOf` of `theme`
(4.1) if it does not already express an untagged union; its "a shape
that this script cannot express stops it" rule applies.

### 3.3 Editors

`share/ko/config-schema.json` is the editor's schema. The docs give an
optional first line,
`# yaml-language-server: $schema=https://raw.githubusercontent.com/andreypopp/kido/main/share/ko/config-schema.json`,
and `ko api-schema --config` (the ko-rt-yaml command, whatever its
flag) for a local copy. The app writes no such line: the file is the
user's. Open question 4.

## 4. The whitelist

The keys under `app:`, as YAML, with the type in `ko_config::app` and
the Ghostty key that section 5 emits. Every key is optional; an absent
key is its default. A value outside its range is an error with its
line and column. A range is a newtype with `TryFrom` and a hand-written
`JsonSchema` that states the range (AGENTS.md "JSON"), as `WaitMs` and
the ids do; a closed set is an enum with `rename_all = "snake_case"`.

### 4.1 Keys

`theme:` either one name, for both appearances, or a pair:

    app:
      theme: kido-dark
      theme:
        light: kido-light
        dark: kido-dark

Type: `enum Theme { One(ThemeName), Pair { light: ThemeName, dark:
ThemeName } }`, `#[serde(untagged)]`; its schema is `oneOf` a string
and the record. `ThemeName` is a newtype: not empty, no `/`, no
leading `.`, none of `,`, `:`, `=` (the `ThemeConf.isBareName` rule,
`ThemeConf.swift:35`), schema `pattern`. Default: `light: kido-light,
dark: kido-dark` (`ThemeConf.Pair`'s defaults). Ghostty key: `theme =
light:<path>,dark:<path>` with absolute paths that the app resolves
(section 6), never a bare name.

`font:`

| key | type | default | range | Ghostty key |
|---|---|---|---|---|
| `family` | `FontFamily` newtype of string | none (Ghostty's default: Menlo on macOS) | not empty, no newline | `font-family` |
| `size` | `FontSize` newtype of f32 | 13 | 4 to 72 | `font-size` |
| `features` | list of `FontFeature` | empty | each matches `^[+-]?[a-zA-Z0-9]{4}$` | one `font-feature = <item>` for each |
| `thicken` | bool | false | | `font-thicken` |
| `line_height` | `Percent` newtype of f32 | 0 | -50 to 100 | `adjust-cell-height = <n>%` |

The user's file today has `font-family`, `font-size` and three
`font-feature` lines; `thicken` and `line_height` are the two requests
a terminal user makes next. The bold, italic and bold-italic families
(`font-family-bold` and so on) are not in the first version: the
family's own faces serve, and a request adds them as `font.bold`,
`font.italic`, `font.bold_italic` of type `FontFamily`.

`cursor:`

| key | type | default | Ghostty key |
|---|---|---|---|
| `style` | enum `block`, `bar`, `underline`, `block_hollow` | `block` | `cursor-style` |
| `blink` | bool | false | `cursor-style-blink` |

`keyboard:`

| key | type | default | Ghostty key |
|---|---|---|---|
| `option_as_alt` | enum `off`, `on`, `left`, `right` | `off` | `macos-option-as-alt` (`false`, `true`, `left`, `right`) |

An enum, not a bool: YAML's `true` would decode into a bool field and
leave no room for `left`; the string field takes any plain scalar as
text, so `on` and `off` are words, not YAML booleans, by the decoder's
rule.

`mouse:`

| key | type | default | range | Ghostty key |
|---|---|---|---|---|
| `scroll_multiplier` | record `{precision, discrete}` of `Multiplier` (f32) | `{precision: 1, discrete: 3}` | 0.01 to 100 each | `mouse-scroll-multiplier = precision:<p>,discrete:<d>` |
| `hide_while_typing` | bool | false | | `mouse-hide-while-typing` |

The app reads `scroll_multiplier` from the typed value, not from the
serialized config (`PaneView.swift:640-651` goes away).

`clipboard:`

| key | type | default | Ghostty key |
|---|---|---|---|
| `read` | enum `ask`, `allow`, `deny` | `ask` | none: the app's `ClipboardPolicy` |
| `write` | enum `allow`, `deny` | `allow` | none: the app's `ClipboardPolicy` |
| `copy_on_select` | enum `off`, `on`, `clipboard` | `on` | `copy-on-select` (`false`, `true`, `clipboard`) |
| `paste_protection` | bool | true | `clipboard-paste-protection` |
| `trim_trailing_spaces` | bool | true | `clipboard-trim-trailing-spaces` |

`read` and `write` are the policy that `GhosttyRuntime.clipboard`
holds (`GhosttyRuntime.swift:40-48`) and the server's OSC 52 events
consult. They never reach Ghostty: the mirror's own policy is always
deny (`:112`). The three others are Ghostty's paste and copy behaviour
on the surface, which the mirror does run.

`window:`

| key | type | default | range | Ghostty key |
|---|---|---|---|---|
| `sidebar_shade` | `Percent` (f32) | 5 | -100 to 100 | none: `KidoSettings.sidebarShade` |
| `unfocused_shift` | `Percent` (f32) | 3 | -100 to 100 | none: `KidoSettings.unfocusedShift` |

The semantics stay (docs/design-app.md:370-392 and :655-667): the app
uses the absolute value, and the theme gives the direction. A number
is a number: no `%` suffix, no quotes. `Percent` is one newtype with
the range as a const generic or two newtypes; the implementer picks
the smaller. The `kido-` prefix goes, because the file is Kido's.

### 4.2 Fixed by the app, never configurable

These go into the generated string on every load and have no key:

- `window-padding-x = 0`, `window-padding-y = 0`, `scrollbar = never`
  (`GhosttyRuntime.swift:318`): the app tiles and draws its own scroller.
- `scrollback-limit = 536870912` (`:266`): ko owns scrollback
  (docs/design-ko.md:180). Ghostty's mirror keeps what the server sends.
- `alpha-blending = linear` (`:266`).
- The four `keybind = super+...=unbind` lines (`:266`): the app's menus
  own those keys.
- `clipboard-read = deny`, `clipboard-write = deny` (`:112`), last.
- `image-storage-limit` and `background-opacity` per pane
  (`PaneView.swift:877`), as today.

### 4.3 Not supported, with the reason

- **Colours outside a theme** (`background`, `foreground`, `palette`,
  `cursor-color`, `selection-*`, `bold-color`, `minimum-contrast`): a
  theme file holds them (section 6). One place for colours keeps the
  theme pair and the picker honest: a `background:` in `config.yaml`
  would override both themes, and the picker could not show it.
- **`keybind`**: Ghostty's binding syntax is its own language
  (triggers, actions, `text:`, `csi:`, `unbind`), and the app's menus
  already own Command shortcuts. A `keys:` section would need its own
  validator to keep the whitelist promise. Not in the first version;
  open question 1 gives the shape if the user wants it. The visual
  tests that use `keybind = super+e=text:X`
  (`app/VisualTests/VisualTests.swift:184`) get a test-only string
  (section 10).
- **`config-file`**: no includes. One file.
- **Window, tab, quick-terminal, shell-integration, notification,
  bell, GTK and Linux keys**: the app, not Ghostty, owns windows,
  tabs, shells and notifications; Ghostty's values would be dead or
  wrong (`confirm-close-surface`, `window-save-state`).
- **`scrollback-limit`, `image-storage-limit`,
  `background-opacity*`**: fixed (4.2).
- **`font-codepoint-map`, `font-variation*`, `font-synthetic-style`,
  `grapheme-width-method`, `freetype-load-flags`, `adjust-*` other
  than cell height**: rare; each needs a validator for its syntax.
  Added one at a time on request.
- **`link-url`, `link-osc8`, `mouse-reporting`, `cursor-click-to-move`,
  `selection-*-on-*`**: behaviour that the app or the server's
  protocol defines (copy mode, OSC 8 in `GhosttyRuntime.action`).
- **`theme` by absolute path or by a name in `~/.config/ghostty/themes`**:
  a theme is a bundled name or a file of `~/.config/ko/themes` (6.1).
- **`macos-*` other than `option-as-alt`**: titlebar, icon, dock,
  secure input: the app owns them.
- **Server options** (`scrollback` limits, the knobs): not now.
  Section 7 and open question 3.

## 5. From the typed value to Ghostty

A new `app/App/GhosttyConf.swift`, one pure function
`GhosttyConf.text(_ app: KoSchema.App, themes: ThemePaths) -> String`,
writes the Ghostty config string in this order:

1. The fixed lines of 4.2 that defaults need first (`alpha-blending`,
   `scrollback-limit`, the unbinds).
2. One line for each key of 4.1 that has a value, in the order of the
   tables, with the Ghostty key of its table. A string value is
   written as Ghostty reads it, `font-family = <value>` with no
   quotes; the newtype refuses a newline, so a value cannot start a
   second line. A list writes one line per item. An enum writes
   Ghostty's word (`off` is `false`).
3. `theme = light:<abs path>,dark:<abs path>` (6.1).
4. The tiling lines of 4.2.
5. `clipboard-read = deny` and `clipboard-write = deny`, last.

`GhosttyRuntime.loadConfig` loads this string once through
`ghostty_config_load_string` under the name `/kido`, then the override
string `/kido-theme` of a preview or a session theme as today
(`GhosttyRuntime.swift:320`), then `ghostty_config_finalize`.
`ghostty_config_load_file` and `ghostty_config_load_recursive_files`
have no caller left in the app; the `config-file` walker (`:271-316`),
`settingKeys` (`:254`), the "unknown field" filter (`:258`) and
`userClipboardPolicy` (`:104`) go. `denyMirrorClipboard` (`:112`) stays
for the `config_change` clone (`:455`), where Ghostty hands back a
config that it built.

A Ghostty diagnostic on the generated string is a bug in
`GhosttyConf`, not a user error: the app logs it with `note`, and the
tests fail on any diagnostic (section 10).

## 6. Themes

### 6.1 Resolution

A `ThemeName` resolves in Swift (`ThemePaths`, beside `GhosttyConf`)
to an absolute path:

- A bundled name (`kido-light`, `kido-dark`, `ahrefs-light`,
  `ahrefs-dark`, `solarized-light`, `solarized-dark`;
  `PaletteTheme.swift:41`) to `<bundle>/ghostty/themes/<name>`.
- Else to `~/.config/ko/themes/<name>` (the directory beside the
  file), which must be a regular file.

A bundled name wins over a user file of the same name, and
`~/.config/ghostty/themes` is never searched: the string names paths,
so Ghostty's theme search (`theme.zig:114`) does not run. The app keeps
`GHOSTTY_RESOURCES_DIR` (`main.swift:625`) for Ghostty's other
resources; it no longer matters for themes.

### 6.2 Validation

A theme file keeps Ghostty's theme syntax, so a Ghostty export from
iTerm2-Color-Schemes drops in unchanged, as the Solarized pair did.
The whitelist promise holds through a check with Ghostty's own parser,
with no hand-written parsing: before a path goes into the string,
`ThemeFile.check(path)` (Swift, beside the picker's swatch loader,
`PaletteTheme.swift:84-98`, which it replaces) loads the file into a
private `ghostty_config_t`, finalizes it, serializes it
(`ghostty_config_serialize`), and compares the lines with the
serialization of a fresh finalized config. Every line that differs
names a key the file set. Each such key must be one of `background`,
`foreground`, `cursor-color`, `cursor-text`, `selection-background`,
`selection-foreground`, `palette`, `bold-color` and
`minimum-contrast`; any other key, or a Ghostty diagnostic on the
file, is the problem `invalid: unsupported key "<key>"` or
`invalid: <diagnostic>`. The check also returns the swatch's colours
from the same config, as the loader does today. The six bundled files
pass; an XCTest reads them from the built bundle and checks it, so a
bundled theme edit that adds a key fails the test. The time between
the check and Ghostty's read is the user's own file system; it is not
a security boundary.

A theme that fails the check does not go into the string: that side
of the pair falls back to the default theme, the error reaches the
user (section 8), and the picker's text "<value>: not found. The
current config names it for Light" (`PaletteTheme.swift:72-74`) stays,
fed by the check instead of a Ghostty diagnostic.

### 6.3 The picker and the writer

`PaletteTheme` keeps its rows: the bundled six, then the regular files
of `~/.config/ko/themes` sorted as today (`PaletteTheme.swift:55-61`),
each with its check result.

The save step writes through `ko_config_set_theme` (3.2), a function
of `ko_config` because `ko_config` owns the file:

- It reads the file's text and finds the `theme:` block under `app:`:
  the `app:` line at column 0, then the `theme:` line at the first
  indentation under it, then the lines after it that are blank or
  indented deeper. It replaces that block with `theme:\n  light:
  L\n  dark: D\n` at the same indentation, or inserts the block at the
  end of `app:`, or appends `app:\n  theme:\n    ...` when there is no
  `app:`. It keeps every other byte, comments included, and writes a
  temporary file beside the resolved target, syncs it and renames it
  over the target, with the target's mode (0600 for a new file), the
  directory created 0700 when missing. This is `ThemeConf.write`
  (`ThemeConf.swift:52-88`) in Rust; the symlink and `ELOOP` rules
  move with it.
- After the edit, before the rename, it decodes the result with
  `ko_config`'s own decoder. A result that does not decode (a `theme:`
  that the line rule saw inside a block scalar, say) is not written,
  and the error returns. So the editor can be line-based and still
  never leaves a broken file.
- A pair equal to the file's pair writes nothing (`written: false`).

The palette's foot (`PaletteTheme.swift:161`) reads "writes `theme:
light: L, dark: D` to ~/.config/ko/config.yaml". The "This session
only" row's text names `config.yaml`. The seven theme snapshots change
text and are re-recorded.

`ThemeConf.swift` and `ThemeConfTests.swift` go. Their cases (replace,
append, CRLF, symlink, dangling link, read-only, ELOOP) become Rust
tests of `ko_config`, with a temporary directory.

## 7. The server's part, and server options

The server reads `runtimes` (ko-rt-yaml) when a runtime is used or
listed, and again at each link start; no watcher, no reload command
(docs/design-runtimes.md:47-52). That rule stays. The strict decode
means it refuses a file whose `app:` keys are wrong; the runtime
request's error names the line, as it does for a bad runtime.

The app's local server is `ko server --server <state>/ko-app`
(`ko_client/src/launch.rs:160`), and it reads the default path. The
app reads the same path. One file, read by both processes on the Mac.
A remote host's server reads the host's file (3.1). The one thing a
user may expect and not get is "my runtimes everywhere": a runtime is
a thing of the host that runs it, so it is defined there. The docs
say so in one sentence.

Server options do not join the file in this plan. The scrollback
limits are flags of `ko server`, and the knobs are environment
variables that tests set (docs/design.md "Knobs"). A `server:`
section (`scrollback: {bytes, lines}`, `linger_seconds`, ...) is a
small later unit if the user wants Kido.app's server configurable:
the server would read it at start, and the app's launch would stay
`server --server DIR`. Open question 3.

## 8. Validation, errors, reload

**Decode.** `ko_config` decodes; serde's error carries the field
path, and the typed tree gives the line and column of the node that
failed. The ABI returns `{"error": {"line", "column", "message"}}`
(3.2).

**What the app does with an error.** At launch, a bad file gives the
default `App` and the default string, so the app starts. On a reload,
a bad file keeps the config that is loaded. In both cases the app
shows the error:

- One line on stderr through `note`, as today's diagnostics.
- A banner in every window (`app/App/Banner.swift`, the one that shows
  "Disconnected" and "Could not reach"): the title
  "~/.config/ko/config.yaml has an error", the detail
  "<line>:<column>: <message>", and the button "Reveal in Finder"
  (`PaletteTheme.reveal`'s action, `PaletteTheme.swift:166`). The
  banner hides on the next load that succeeds. `WindowOwner` gets one
  `configError: String?` from `GhosttyRuntime` next to its link states
  and shows the banner when the link has nothing to say; a connection
  failure wins, because the user cannot work without it. A theme
  file's check failure (6.2) uses the same banner with the theme's
  path.
- The palette's Theme mode shows the same error in its red status
  (`PaletteTheme.swift:62`, `fileStatus`).

**Reload.** Today's watcher (`GhosttyRuntime.swift:369-414`) moves to
the new path: the file, its directory, and the nearest existing
ancestor when the directory is missing; symlink targets; a 100 ms
debounce; one reload per burst. The themes directory is not watched
(an edited theme file needs a save of the config or Ghostty's reload
action, as an include does today, docs/design-app.md:413-416).
`reloadConfig` (`:332`) calls `ko_config_load`, builds the string,
compares it with the loaded string (a string compare replaces the two
`ghostty_config_serialize` calls at `:349-355`, because the string is
the whole input), compares `font.size` from the typed value
(`:357-362`), and applies as today:
`ghostty_app_update_config_without_surface_propagation`, then
`onConfigReload(font)` to every owner (`main.swift:53`), where each
pane clones and reflows. A change of only `window.*` or
`clipboard.read/write` repaints without a reflow, as today for the
shade. Ghostty's `reload_config` action still reloads (`:466`). No
menu item is added: the watcher makes one unnecessary.

The server's part has no reload (section 7).

## 9. Migration

The app stops reading `~/.config/kido/kido-app.conf` and
`~/.config/kido/themes`. No code reads, converts or mentions the old
file (AGENTS.md "No backward compatibility"). The user does this once:

1. Write `~/.config/ko/config.yaml` with the keys of section 4. For
   the file that exists today:

        app:
          font:
            family: PragmataPro Mono Liga
            size: 16
            features: [ss13, -ss17, -ss18]
          window:
            unfocused_shift: 3

   A `font.features` item without a sign is `+`, as Ghostty reads it.
2. Move `~/.config/kido/themes/*` to `~/.config/ko/themes/`.
3. Delete `~/.config/kido`. The directory has nothing else that is
   read: `kido.conf` is the old kido file.

The website's two sentences about `kido.conf` (`index.astro:99,107`)
go, and one sentence names `~/.config/ko/config.yaml` with a link to
the schema. docs/design-app.md "Panes" (:296-437), "Theme mode"
(:1696-1770) and "Testing" (:1906-1915) are rewritten by the manager
from this plan; docs/design-runtimes.md "The configuration file"
(:41-70, as ko-rt-yaml leaves it) gains the `app:` key in one
paragraph; docs/design-ko.md's decision of 2026-11-04 (:729) changes
from "runtimes only" to "one file, one owner". AGENTS.md "Layout"
names the two exports and `GhosttyConf.swift`.

## 10. Tests

Rust (`ko_config`, unit tests at the bottom of each file):

- Decode of `app:`: each key with a valid value; each range's two
  ends and one value past each; an unknown key under `app:`, under
  `font:` and under `theme:`, each naming the key, the line and the
  column; `theme:` as a string and as a pair; `option_as_alt: on` is
  the enum, not a bool; a missing `app:` is the default.
- The writer (6.3): `ThemeConfTests`' cases, plus "a `theme:` block
  with comments inside is replaced whole", "no `app:` appends one",
  and "a result that does not decode is not written".
- `cargo fuzz` gains no target of this plan: the decode target that
  ko-rt-yaml adds for `Config` covers `app:` with it.

Swift (`app/`):

- `KoSchemaTests`: the generated types match the schema (the existing
  test with the third input).
- `GhosttyConfTests` (new, in `KoTests`): exact strings. The default
  `App` gives the fixed lines and the bundled theme paths; each key
  gives its line; `features` gives one line per item; the theme pair
  resolves to two paths; `off` writes `false`.
- `GhosttyRuntime`: a load of a YAML fixture gives the expected
  `settings`, `clipboard` and `scrollMultiplier`; a reload after an
  edit applies; a bad file keeps the loaded config and sets
  `configError`; Ghostty reports no diagnostic on the generated string
  for every fixture.
- `ThemeFile.check`: the six bundled files pass; a file with
  `font-family = x` fails naming the key; a file with a Ghostty
  diagnostic fails with it.
- Visual (`make visual`, re-recorded where the text changes):
  - The theme-mode snapshots (`PaletteTests`), with the new foot text
    and `config.yaml` in the paths.
  - One new snapshot of a pane under `font: {size: 15}` and
    `cursor: {style: bar}` against the Menlo 13 reference: a setting
    that changes rendering has a picture. One is enough; the string
    tests pin the other keys' lines.
  - A banner snapshot for the config error, light and dark.
  - The fixtures that write Ghostty syntax (`VisualTests.swift:184`,
    `LayoutVisualTests.swift:23`, `PaletteTests.swift:21`,
    `ToolbarTests.swift:368,490,582,608,632`,
    `ClipboardTests.swift:222,254`, `CopyModeTests.swift:231`,
    `RendererTests.swift:22`) write YAML instead. The visual suite's
    `keybind = super+e=text:X` and `super+shift+c=text:Y`
    (`VisualTests.swift:184`) become an extra string only for the visual tests
    that `GhosttyRuntime.init` loads after `/kido`: the key-bytes tests
    need a binding, and the product has none.
  - The reload test with an included file (`ToolbarTests.swift:540`)
    loses its include case and keeps the directory-event case.

## 11. Units, estimates and order

Dependencies: ko-rt-yaml (`ko_config`, the crate, the path, the schema
command, `--config`) lands first. Runtimes U4
(plans/ko-runtimes.md:1075, the app's palette entries and runtime
step) touches `Palette*.swift` too; UA2 below edits `PaletteTheme.swift`
only, so the two can run in parallel in separate worktrees, with one
merge of the palette files by the top-level session. UA1 can start in
the ko-rt-yaml worktree once `ko_config::Config` exists, or on `main`
after it lands.

- **UA1 ko_config and the ABI** (3.2, 4, 6.3's writer): `ko_config::app`
  with the newtypes, enums and ranges, `Config.app`; the writer
  `set_theme`; `ko_config_load` and `ko_config_set_theme` in
  `ko_client::ffi`, the header and `exports.txt`; `make schemas` with
  the `app:` types in `config-schema.json`; the Rust tests of section
  10; `make verify`. About 1 agent-day. Manager on Opus, implementer
  on Sonnet, the six reviewers of AGENTS.md "Review".
- **UA2 App** (5, 6.1, 6.2, 6.3's picker, 8, 9, 10): `gen-ko-model.py`
  with the third schema and `make ko-model`; `GhosttyConf.swift` and
  `ThemePaths`; `GhosttyRuntime` on `ko_config_load` with the file and
  recursive loading removed and the typed settings in place of the
  line parsers; `ThemeFile.check`; `PaletteTheme` on the check and the
  writer, `ThemeConf.swift` deleted; the banner; the watcher's path;
  the Swift and visual tests; the website sentence. About 2.25
  agent-days, of which the visual re-records and the fixture rewrites
  are about 0.5. Needs UA1 on `main` or in the same worktree. The
  manager compares every re-recorded snapshot with its previous image:
  only text and the new font picture may differ.
- **Docs** (section 9): the manager of UA2, about 0.25 agent-day,
  before UA2's final `make test` and `make visual`, and `make verify`
  for the ko side, because lint checks the docs' references.

Total about 3.5 agent-days.

## 12. Decisions (user, 2026-11-04)

1. **Keybinds are in the first version.** `app.keys:` as section 12's
   earlier proposal gave it: a map from a Ghostty trigger to an action,
   with a `Trigger` newtype and an `Action` enum of the actions Kido
   names, refusing the keys that the app's menus own. UA1 adds the
   types, UA2 the mapping. About 0.75 agent-day more.
2. **User themes use Ghostty's syntax,** with the check of 6.2.
3. **A `server:` section is in this plan,** read by `ko server` from
   the file on its own host at each use, as `runtimes:` is, so a change
   applies to new panes without a restart. Its keys:
   `scrollback: {bytes, lines}` or `scrollback: none` (the default 50 MB
   and unlimited lines), `shell`, `kitty_images_max_bytes`,
   `linger_seconds` and `runtime_idle_seconds`. The flags
   `--scrollback-bytes`, `--scrollback-lines`, `--no-scrollback` and
   `--shell` and the environment variables `KO_KITTY_IMAGES_MAX_BYTES`,
   `KO_LINGER_SECONDS` and `KO_RUNTIME_IDLE_SECONDS` are removed: one
   source for each setting. The test and tuning knobs (the view queue
   and spill sizes, the message ack, the exec wait, the stop
   escalation, the clipboard timeout, the run screen size) stay
   environment variables. Part of UA1, about 0.5 agent-day.
4. **The editor schema line:** the docs give the `yaml-language-server`
   line; the app does not write it.
5. **The `font.family` default is the system's monospaced font,** not
   Ghostty's default. The visual references change once.
6. **No hint** about the old file.
7. **The theme writer is in `ko_config`.**
