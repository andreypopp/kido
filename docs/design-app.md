# Kido.app

Open gaps and accepted limits are tracked in [Known issues](known-issues-app.md).

Kido.app (`app/`) is a native macOS client of a ko server. It renders
every pane with libghostty, beside a native sidebar. The app talks to
the server only through `ko_client`, ko's Rust client core, which it
links as a static library and calls through its C ABI
(`ko_client/include/ko_client.h`, wrapped by `app/App/Ko/KoClient.swift`).
Sessions, windows, panes, layout, history and status live in the server;
the app holds none of them. The core owns the connection, the reconnect,
the client model, seen marks, layout-edit convergence and each pane's
view feed. A Ghostty surface is a mirror that its view feeds: its grid is
the server's pane size, and its content is the server's snapshot plus the
bytes after it. Purely client/UI state (scroll position, selection, find,
sidebar UI, gestures, fonts and themes) belongs to Kido.app.

## Release signing

`make -C app release VERSION=x.y.z` builds Release with the free Apple
Development (Personal Team) identity. `app/project.yml` selects the common
name `Apple Development` and the team ID; Xcode resolves a valid identity
from the keychain and fails if none is available, without ad-hoc fallback.
The bundling phase signs every nested Mach-O executable and dylib with
Xcode's resolved identity before Xcode signs `com.andreypopp.kido`. The release
script verifies the final bundle with `codesign --verify --strict --deep`
before packaging.

The certificate-based designated requirement keeps TCC grants such as Screen
Recording stable across upgrades. An ad-hoc cdhash requirement changes with
every build. Team signing also supplies the TeamIdentifier that Shortcuts and
App Intents require. Renew the Apple Development certificate in Xcode about
once a year, with the same Personal Team. Rebuild and check the designated
requirement after the renewal. A change of team or signing identity can
require another TCC grant.

Hardened runtime is disabled and no entitlements are added: notarization is not
part of this release path, and enabling runtime/JIT or library-validation
restrictions would need separate GhosttyKit and bundled-helper validation.
Personal Team signing is not Developer ID signing or notarization. Gatekeeper
can still reject quarantined downloads; the cask retains its quarantine-removal
instructions. Debug, test, visual and stress builds stay ad-hoc. Demo builds
explicitly stay ad-hoc even in Release; direct `all CONFIG=Release` builds use
the same team signing as the release script.

## One ko client

Each `WindowOwner` has one `KoClient`. `WindowOwner.dial` calls
`ko_client_connect` with a hello (`KoHello`: the owner id as the client
name, `sizes_windows`), and the core posts its events on the main queue:
welcome, layout, model, selected, failed, mismatch, clipboard write and
clipboard read (`KoEvent`); the app ignores the core's other alerts.
The model is a snapshot: a layout, model or selected event marks it
stale, and once per main-queue turn the owner reads it again with
`ko_client_model`, decodes it into `KoModel` and derives the session view,
the sidebar `Snapshot` and the tabs from it. The owner keeps only that
model; the layout editor still gets every layout revision. The owner's link is
`down`, `starting`, `mismatch`, `changed` (the bundle changed on disk) or
`connected`. There is no second long-lived connection: an image fetch
(`ko_client_image`) is one request on its own short connection.

The app and `ko` share one server: the server directory is ko's default
directory, which `ko_client_default_dir` reads from
`ko_server::config::dir` with the app's environment, so the rule has one
source. A `ko` in a terminal and Kido.app attach to the same sessions. An app that
Finder or the Dock opens gets launchd's environment, not the shell's: a
`KO_STATE_DIR` or `XDG_STATE_HOME` that only the shell sets selects another
server for `ko`. `KIDO_APP_SERVER` overrides the directory, in VISUAL and STRESS
builds only. The app never stops the server on quit; only the local
mismatch sheet's Restart stops it. When no local server runs, the app
starts one: every local connection (at launch, for each new local window
and on Reconnect) runs `KoServer.launch`, which calls
`ko_client_launch(dir, bundled ko)` on a detached task. It starts a server
unless one runs there and returns the socket; then the owner dials. Two
windows that connect at once end with one server (docs/design-ko.md,
"Lifecycle and the command line"). `ko_client_launch` starts the server with
the app's own environment, so `app/App/Server.swift` removes the pane
identity variables from it and sets a UTF-8 `LANG` when none
is set. The core reaps the server process that it
started. Every dial is one stderr line, `dialing SOCKET (cause) [owner]`.

The first welcome must arrive within 20 s (`WindowOwner.welcomeTimeout`),
else the banner reads "Kido could not reach …" with Start. After that the
core reconnects by itself; a `failed` event shows "Disconnected from HOST …
Reconnecting…". A local server that ends while the app runs (killed,
crashed, `ko kill-server`) is started again: a local owner answers the
core's `KO_ERR_NO_SERVER` with one `KoServer.launch` ("Starting the ko
server…"), and the core's next attempt attaches with a fresh welcome.
The core reports that code at most once for each outage
(`ko_client/include/ko_client.h`, "Reconnect"), so a server that cannot
start never loops: a failed start shows "Could not start the ko server",
and a start that brings no welcome shows "Disconnected", both with Start.
A launch result that arrives after the welcome changes nothing. A remote
window's redial only attaches ([Remote hosts](#remote-hosts)). Start also
remains after a failed dial and the welcome deadline; on "No sessions" it
creates a session. When the first welcome of a local owner's connection,
or a `fresh` one, shows no session, the owner sends one `ensure_session`
edit (one pane in the home directory). The edit adds the session only to
a layout without one, and the core applies it again to the newer document
after a revision conflict, so two windows that connect to an empty server
at once end with one session. A same-instance reconnect, and a layout
that another client emptied later, create nothing: the window shows "No
sessions" with Start. A remote owner creates nothing at connect, because
the home directory is the Mac's, not the host's. A welcome with `fresh`
(another server instance) resets the
session view and the model, because ids mean something only to the server
that issued them, the owner makes a new `LayoutEditor` (a held edit's
revision belongs to the old server) and selects the first session again. A welcome
of the same instance keeps the selection: the core sends the client's
selection again in every hello. `invalidate()` advances the owner's
generation and closes the client on a utility queue, because the close
waits for the worker, every decoder and the calls in flight; the client
stays alive until it returns. `KoClient` counts its calls in flight under
a lock: a call after the close returns `KO_ERR_CLOSED` without touching
the handle. Late callbacks check the generation.

The owner reports focus with `ko_client_focus` while its window is key in
the active app, has no sheet and a pane of the shown window is first
responder. `SessionView.requestSize` sends the window size with
`ko_client_size`, at most once per main-queue turn and only when it
changed; `present` sends it at once. The size carries the cell size in pixels from a shown pane, so
the server answers `CSI 14t`/`16t` and `TIOCGWINSZ` with real values; 0 and 0 mean unknown.
The cell's pixels are part of the size that is compared: a font or
backing-scale change (a display move) that keeps the grid still sends a size.
A floating sidebar changes no size.

**Version mismatch.** A server of another protocol or terminal revision
refuses the `/client` upgrade (426 or 409, docs/protocol.md, section 1).
The core then reads `GET /version`, which goes without the version
headers, so an incompatible server answers it. The result is one
`KO_EVENT_MISMATCH` with the code and both `ko_version`s (protocol, vt,
build), and the core does not retry. A server that differs only in its
build is compatible and connects. The usual case is a server that another
ko build started on the shared directory (a Homebrew ko, an older
checkout). The owner keeps its last snapshot read-only, shows
"Disconnected" with Reconnect and opens a native alert sheet. For a local
server the sheet is "Restart the local ko server": the running server is a
different version and must be restarted to upgrade, the differing value and
both builds, and the warning that sessions, panes, commands and agents end
and other clients disconnect. A selectable line gives the command that
does the same from a terminal, `ko kill-server --server DIR`. The
directory is always named, because a terminal's `KO_STATE_DIR` or
`XDG_STATE_HOME` can select another default than the app's. Restart Server is destructive and has
no key equivalent; Close is the default and Escape action. Restart stops the
server with `ko_client_stop_server`, then posts a notification with the
server directory, and every local owner in the mismatch state on that
directory dials again. A failed restart is a banner, "Could not restart
the ko server", with Reconnect. The bundle's `Resources/ko/BUILD-ID` is
read at launch; a different value at a later connection means that the app
was replaced on disk and requires a relaunch.
## Remote hosts

A remote window reaches the ko server on the host through an SSH forward
of a unix socket. The app owns the SSH layer; the ko client connects to the
forward's local socket as to a local server, and its engine does the
reconnect, the resume by offset and the `instance` gate as for a local
server. Each remote window has its own `SSH`: one ControlMaster, one 0700
directory `/tmp/ka-<12>` with the control socket `c` and the forward's
local end `socket`. Two windows to one host have two masters and two
forwards. The app never starts a remote server: the server on the host
starts only with an explicit `ssh HOST ko server`, which the banner names.

The connect sequence (`open` in `app/App/Remote.swift`) runs on one
task of the owner, with each ssh child off main:

1. `ssh -G` for the resolved `user@host`, then the master (`-M -N -T`),
   ready when `-O check` succeeds, within 10 s.
2. A passenger `ko server --print-socket`. `ko_remote_socket` classifies
   its result with the same code and texts as `ko HOST`
   (`ko_client/src/remote.rs`): no `ko` on the PATH of ssh commands, an
   ssh failure, a reply that is not a socket path, or the remote socket.
3. `ssh -O forward -L <dir>/socket:<remote socket>`. Exit 255 is an ssh
   failure. Any other result goes on to the probe, because OpenSSH
   reports a missing remote socket and a refused forward with the same
   exit 0, and a connect through such a forward gets EOF.
4. The agent publication (below), in parallel with the probe.
5. `ko_client_probe`, a `GET /version` through the forward within 20 s.
   A compatible server is dialled; another protocol or terminal revision
   opens the mismatch sheet. A forward that leads nowhere runs the
   passenger `ko api --server <remote dir> /version`: exit 0 means that
   the host refuses unix-socket forwarding (`AllowStreamLocalForwarding`),
   else no server runs there. `ko_remote_unreachable` gives the text.

Each failure is a banner with Reconnect (`RemoteFailure.banner`). The
title is the app's; the detail is the core's text, so `ko HOST` and the
app name a failure alike.
The no-server banner has no button that starts a server: `ko server` runs
in the foreground, and a remote server starts only on an explicit command (docs/design-ko.md, "Remote").

**Outage.** A `failed` event from the core shows "Disconnected from HOST"
with "The connection to HOST is down." for an absent socket and the
button Reconnect, which runs the whole sequence again. When the master
ends, the owner runs a recovery loop: a new master at the same
`ControlPath` in the same directory, `-O check` within 15 s, the same
forward again (`StreamLocalBindUnlink=yes` lets ssh bind over the stale
socket file) and the agent publication again. The remote socket path is
kept; the engine's next retry finds the socket and its own version check
runs. Before the new master, the loop removes the old control socket:
a killed master leaves `c`, and ssh then starts a master that serves no
control socket and reports nothing. The loop's attempts back off from
1 s to 30 s with no deadline, so a Mac that slept for hours connects again
at wake (the master ends through `ServerAliveInterval=15` and
`ServerAliveCountMax=3`); only a terminal ssh failure (authentication, a
host key) stops it. `ko HOST` has a 60 s deadline instead, because it is a
foreground command. The banner shows the loop's last error, and a welcome
hides it. A welcome of another `instance` resets the session view as for a
local server.

**Mismatch.** A remote sheet has Reconnect and Close (the default and
Escape); nothing is destructive and the app stops no remote server: the
user decides on the host. A server of a lower protocol major reads "Update
ko on HOST", a higher one "Update Kido.app to connect to HOST", another
terminal revision "Kido.app and ko on HOST are from different releases".
The text gives both versions and builds, then tells the user to stop the
server on the host with `ko kill-server` (the selectable line) and run
`ko server`, and that its sessions and panes end.

**SSH agent forwarding.** `ko server` gives every pane
`SSH_AUTH_SOCK=<state dir>/agent.sock`. After the query, the app links that
path to the agent that its master forwards: one short passenger that keeps
the configured `ForwardAgent` of the destination runs `sh -c` with the
remote state directory. If `SSH_AUTH_SOCK` is a socket and `agent.sock` is
absent or a symlink, the script makes a link under a temporary name and
renames it over `agent.sock` without following a symlink there (`mv -h` on
BSD and macOS, `mv -T` on GNU); a regular file or a directory stays. It
exits 0, and its stderr goes to the log. The dial does not wait for it, and
it is skipped when `ssh -G` reports `forwardagent no`. OpenSSH sets up agent forwarding
once for each connection and keeps the forwarded socket until the
connection ends, so the short session suffices. The master itself honours
the configuration (`ForwardAgent` yes, no, a path); every other passenger
and the check have `ForwardAgent=no` and run under `env -u SSH_AUTH_SOCK`.
After a master loss the link dangles until the recovery loop publishes
again. The last publication wins across windows and Macs, and a window
close leaves the link. Setting up the remote (the master, the query, the
forward, the link) is administrative and may write in the server's state
directory; the client actions (the dial, views, image fetches, API calls,
the probe) only connect to `<dir>/socket`.

The entry points below route every remote request to a remote owner.

On macOS Tahoe, the Shortcuts action **Connect to Remote Host in Kido**
(`app/App/RemoteIntent.swift`) has a required Host string in its parameter
summary. It works only in team-signed builds: Linkd rejects ad-hoc bundles
with `requiresValidatedBundle`. Spotlight does not list the action directly.

The unsigned alternative is `kido-app://<host>`: in Shortcuts use
**Ask for Input** with prompt **Host**, then **Open URLs** with
`kido-app://<Provided Input>`. It needs no signing. The percent-decoded
authority is the SSH destination: `kido-app://localhost` or
`kido-app://user@myhost`. An empty path or `/` connects to the default
session. A non-empty path is refused. Ports, passwords, queries, fragments,
empty hosts, whitespace, controls, SSH options and shell syntax are refused
with one stderr line (`app/App/Host.swift`).
URL delivery and the App Intent share Host validation and window routing. Each request
creates a new native window, including repeated requests for one alias.
Host is trimmed and accepts an SSH alias or user@hostname, not options,
whitespace, controls or shell syntax. Ports and jump hosts belong in SSH
config. File → **Connect to Remote Host…** (Shift-Command-K) opens the
[command palette](#command-palette) in its Connect mode. The mode uses the same
remote routing as URLs and the App Intent. File → **Connect to Local Host**,
directly above it and with no key equivalent, opens a new Local window on each
request, also when other windows are open. Use it to open Local again after
you close the Local window while a remote window stays open. The Dock menu has
the same two items, with the same actions, and the root palette has the same
two rows. A Dock menu item does not activate the app, so Connect to Remote
Host… activates it before it opens the palette. The cold remote-launch gate
holds back ordinary Local opens (launch, reopen, New Session); Connect
to Local Host is a new-window request, which the gate does not hold back. Dock
reopen focuses an existing window; with no window it opens a Local window.
The app opts out of automatic termination at launch: AppKit marks a
windowless app as terminated by the transparent app lifecycle (TAL), and a
Dock reopen then does not reach the process. The recent list lives in
preferences (`recentHosts`), and every remote path, palette, URL or intent
alike refreshes it. There is no remote restore. The off-screen
`FileMenuTests` create inert window owners without a server.
Local keeps `SessionModel.title` (session and current window); remote prefixes
it with resolved `user@host / `. The original dialing alias is the window
content's tooltip. Offline titles drop the session/window name.

`AppDelegate` owns shared Ghostty configuration, app lifecycle and menus.
Each `WindowOwner` owns its immutable Host, generation, link, `KoClient`,
`LayoutEditor`, model, snapshot and SessionView/surface cache. Main menu
actions target the key owner; source-pane actions stay with that pane's
owner. Configuration changes broadcast to live owners. Late callbacks
check liveness and generation. Surface disposal cancels find/gestures,
denies pending paste exactly once and rejects deferred actions and input.
Closing a native window closes only its client, never a pane, so it never
asks for confirmation; reopening dials again. Quit closes every owner and
replies after that. The terminate-later reply is a common-mode main RunLoop
block, not a main DispatchQueue block: AppKit's nested termination event
loop cannot re-enter a main-dispatch callback that called terminate.
Closing the last window leaves the app available for another intent.

Launch bootstrap initializes shared resources and drains queued Host requests;
it does not open Local. Ordinary AppKit untitled/reopen delivery opens Local
only when no live window exists; reopening with a live window focuses it.
There is no timer, debounce or compensating close of a Local window. Off-screen
routing tests prove queued cold and warm behavior. The launch gate requires
`launchIsDefaultUserInfoKey == true` and an initial `oapp` (if available);
non-default launches discard queued Local requests, except new-window
requests, and suppress ordinary-open until the requested remote arrives. Apple's
[launch key](https://developer.apple.com/documentation/appkit/nsapplication/launchisdefaultuserinfokey)
defines non-default launches as false. URL launch is a non-default `GURL`
request, handled by
[application(_:open:)](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/application(_:open:)).
This uses the same gate without timers, whether URL delivery precedes or
follows launch completion. The off-screen routing tests do not measure the
order of a URL launch's notification and event; that check is on screen.

## Panes

A pane is drawn by a Ghostty surface in manual-IO mode
(`MANUAL_MIRROR`). Its view feeds it (see [Content](#content)), and typed
bytes leave through Ghostty's write callback as the bytes of
`ko_view_input`. The emulator's own query replies are suppressed, because
the server answers them.

The app encodes keys, mouse and paste with Ghostty, not the server. The
encoder reads the mirror's modes and kitty keyboard stack, which the
snapshot restores and the feed keeps current, so both encoders see the
same modes. The client knows more: the modifiers that AppKit consumed,
IME and dead keys, the user's option-as-alt and the pixel position that
SGR pixel mouse (1016) needs. `KeyBytesTests` measured both encoders on
the same keys under kitty flags 0, 1 and 3: they agree in every case but
Shift+Space, where the server's heuristic does not consume Shift and
sends `CSI 32;2u` and the app sends a space. Thus the ABI's input is bytes
only; the protocol keeps its key, mouse and paste kinds for `ko` and
`POST /panes/{id}/input`. The app's menus and Ghostty's split and tab
actions are the only pane commands. In linefeed mode (LNM), Ghostty's
termio write path turns each typed `\r` into `\r\n` once, with the same
routine for the manual and pty backends; the app and the server do not
convert again.
The app's terminal settings are the `app:` key of ko's configuration
file, `$XDG_CONFIG_HOME/ko/config.yaml`, else `~/.config/ko/config.yaml`
(design-ko.md, 4.14). The app reads the Mac's file, also for a remote
window, through `ko_config_load` of `ko_client`, so it needs no server;
`ko_config_defaults` gives the default path and the defaults.
No Ghostty file reaches Ghostty: the app does not read Ghostty's own config
or `config-file` includes.
`app/App/GhosttyConf.swift` maps the typed `KoSchema.App` to one
Ghostty config string, and `GhosttyRuntime.loadConfig` loads only that
string (named `/kido`), then the theme override (`/kido-theme`).
`GhosttyConf.text` gives the order: the app's fixed lines, which no key
changes, come first; the mirror's clipboard deny comes last, because the
server, not the mirror, answers OSC 52. The cursor does not blink, and no
key changes that (design-ko.md, 4.14). A Ghostty diagnostic on the string is a
fault of the mapping, not of the user's file: the app writes it to
stderr, and the tests fail on it. An absent `font.family` is the
system's monospaced font: the family name of
`NSFont.monospacedSystemFont` (`.AppleSystemUIFontMonospaced`), which
Ghostty's CoreText discovery resolves to its Regular face.
`copy_on_select` is a bool: Ghostty's `primary` has no effect on macOS,
so `true` is `clipboard` and `false` is `none`, Ghostty's macOS default.
`app.keys` becomes one `keybind` line for each binding; the visual
tests need bindings on menu keys, so they load a test-only string after
`/kido` (`GhosttyRuntime.loadTestBindings`, under `KIDO_VISUAL`).
Each pane reads the scroll multiplier and the clipboard policy from the
typed value, not from Ghostty's config.

If the file does not decode, the app writes `<file>:<line>:<column>:
<message>` to stderr. At launch it uses the defaults, so it starts; at a
reload it keeps the settings that it loaded. Every window then shows a
strip at the top of its terminal area (`app/App/ConfigBanner.swift`):
"~/.config/ko/config.yaml has an error", the `<line>:<column>:
<message>` on one line, cut at its end, and "Reveal in Finder". The
panes reflow below the strip, and the strip never takes the first
responder, so the user can fix the file in a pane. A link failure
shows the full veil of `Banner` and hides the strip. The next load that
succeeds hides it. A theme file that fails its check (below) shows the
same strip with the theme file's path.

The window and pane chrome follow the effective Ghostty background and its light or dark
appearance. Colours derived from the theme stay in `GhosttyRuntime`.
Every other chrome colour, alpha and shadow is a named role in
`app/App/Chrome.swift`: system colours, the macOS accent, fixed values,
and the constants that are mixed with theme colours. A role is named for
its use, not for its value, so two roles can have the same value.
`app/scripts/lint.sh` runs first in `make test`. It refuses colour
constructors, system colour names, `withAlphaComponent` and literal
shadow values in `app/App` and `app/Packages/*/Sources` outside
`Chrome.swift`. A line with a trailing `// chrome-allow: <reason>` is
exempt; the theme derivations in `GhosttyRuntime` use this marker.
`app/VisualTests` is not checked. The `PromptMarkdown` package cannot
import the app, so the prompt view passes it its three ink roles.

The default theme pair is `kido-light` and `kido-dark`. A theme name
resolves in the app (`ThemePaths`): a bundled name to
`<bundle>/ghostty/themes/<name>`, else to `themes/<name>` beside the
config file (`~/.config/ko/themes`), and the string names the absolute
paths, quoted, so Ghostty's own theme search never runs and
`~/.config/ghostty/themes` is never read. A bundled name wins over a user
file of the same name. A user theme keeps Ghostty's theme syntax, so a
Ghostty export from iTerm2-Color-Schemes drops in unchanged.
`ThemeFile.check` (`app/App/ThemeFile.swift`) checks each file with
Ghostty's own parser before its path goes into the string: it loads the
file into a private config and compares its serialized lines with those
of a fresh config. Neither is finalized, because Ghostty's finalize
resolves a `theme` key and would search the user's Ghostty themes before
the check can refuse the key. Each line that differs
names a key that the file set, and the key must be one of the colour
keys of the check's list; another key, or a Ghostty diagnostic, fails
the file. The palette row builds the swatch from the same checked file. A side whose theme
fails gets Kido's default theme for that appearance. The time between
the check and Ghostty's read of the file is the user's own file system;
it is not a security boundary.
`main.swift` sets `GHOSTTY_RESOURCES_DIR` to the bundle's `ghostty`
folder before Ghostty starts, for Ghostty's other resources. The spawned
server and shells inherit the variable; Ghostty never starts a shell in
Kido, so it has no effect there.
`project.yml` ships `app/Resources/ghostty` whole as a folder resource. Its
`themes` folder holds `kido-light` and `kido-dark`, and also `ahrefs-light` and `ahrefs-dark`
(kido's own, notes in `app/design/themes/ahrefs/`) and `solarized-light`
and `solarized-dark`. The Solarized pair are iTerm2-Color-Schemes'
Ghostty exports "iTerm2 Solarized Light" and "iTerm2 Solarized Dark",
unchanged, from the release that the notice names.
`app/Resources/ghostty/themes/LICENSE-iTerm2-Color-Schemes` is their MIT
notice, with one line per copied file that names its original.

The palette's Theme mode ([Command palette](#command-palette)) previews and
writes the theme. A preview never writes the file. `GhosttyRuntime` holds a
theme override: none, a preview or a session theme. `loadConfig` loads the
override last, as `theme = <value>` after the tiling block, so a single
value sets both appearances and a theme of the other appearance previews
anyway. Every reload applies the override, so an external edit of the file
during a preview keeps the preview. A preview step goes through the usual
reload path: every pane clones the new config, and the chrome and the open
palette card follow through `onConfigChange` (`PaletteView.themeChanged`).
The steps are debounced at 60 ms; the last selection wins. Closing the
palette ends the preview and goes back to the session theme if there is one,
else to the file. A session theme comes from the save step's "This session
only" row or from a failed write. It holds until the next successful write or
quit.

The picker writes through `ko_config_set_theme` (design-ko.md, 4.14),
which edits only `app.theme` and keeps every other byte. The written
value is always the pair; a pair equal to the file's pair writes nothing.
A file that changed during the write is not replaced (`SetError::Changed`);
the app shows it as a write failure (Theme mode, below), with the theme
kept for the session. The watcher sees the rename and reloads; the override
is cleared before, so the reload shows the written theme with no flash.

The fixed lines unbind Ghostty's `super+k`, `super+j`, `super+s` and
`super+shift+s`. The app has no Clear command, and Ghostty binds Command-K to
`clear_screen` by default. That action clears only the Ghostty surface,
which the server owns, so the key does nothing. Command-S and
Shift-Command-S are the sidebar's keys ([Sidebar](#sidebar)).

The sidebar list's background is a shade of the terminal background.
The shade mixes the terminal background toward black on a light
terminal background and toward white on a dark one, with the same light
or dark decision as the window appearance. `window.sidebar_shade` sets
it, 5% by default. Thus the default follows each reload and each live
theme switch. The app uses the absolute value, and the theme gives the
direction. The mix is per sRGB component (as CSS
`color-mix(in srgb, ...)`). `NSColor.blended` is not used: it mixes in
generic RGB and gives a different colour. AppKit's sidebar glass is not
shown.

The sidebar has its own light or dark appearance, from the relative
luminance L of its shade colour: dark (light text) when L < 0.179,
else light (dark text). At 0.179, white text and black text have the
same contrast ratio on that colour. Thus every value in the range stays
readable, also +100% on a dark theme and -100% or -60% on a light
theme. The appearance applies to the sidebar subtree: the list, its
rows, marks and focused-row fill, and the sidebar's toolbar controls
while the sidebar is shown. The rest of the window, and the toolbar
controls of a collapsed sidebar, follow the terminal background. The sidebar's
colours resolve at draw time from the sidebar's appearance, so a reload
that changes the appearance redraws them.

The file reloads live, with no polling. The app watches the file and
its directory, so a save in place, a save by atomic rename, and the
creation or deletion of the file all cause a reload. A deleted file
gives the defaults. If the directory does not exist, the app watches the
nearest existing ancestor until the directory appears. If the file is a
symlink, the app also watches the directory of its target. A change to
another file in a watched directory does not cause a reload, and the
themes directory is not watched: an edited theme file applies at the
next reload of the config or Ghostty's reload action. A burst of events gives one reload. Ghostty's reload action
for the app also reloads the file.

Launch and reload build the config in the same way. A reload checks
each different theme path once, and compares the new string and the
bytes of the checked theme files with the loaded ones; if they differ, the reload applies
the new config to each live pane inside `PaneView.reflow`. A font change
changes the cell, not the grid: the surface keeps the server's grid at
the new cell, the new pixel size reaches the server as the window size,
and the grid comes back from the server. A change of only `window` or of
`clipboard.read` and `clipboard.write` leaves the string the same, so it
repaints without a reflow and does not end copy mode. The app gets the
config without surface propagation. The chrome of every window then
follows the new background and appearance.

The server has one grid per pane, so every pane has one font size. ⌘+, ⌘−
and ⌘0 change it on one surface, and `SessionView.fontChanged` gives that
size to every pane with Ghostty's `set_font_size:` action. Ghostty keeps a
size set in this way when the config reloads. Thus a reload that changes
`font.size` gives the new value to every pane of every window, hidden panes
included, after the pane gets the new config. The runtime compares the new
`font.size` with the one that it loaded last. A new pane starts at the
current size with the same action, so Ghostty also keeps its size. Thus a
reload that does not change `font.size` keeps one adjusted size in all
panes.

### Content

`PaneView.attach` calls `ko_view_open` with `history: true` for the
pane's surface. The core runs the view's restore
and feed callbacks on the view's own decoder thread, in the server's
order, so the surface never takes bytes of an older snapshot after a
newer restore. A restore is `ghostty_surface_restore_snapshot` with the
server's snapshot and its continuation limit for long APC sequences. The
feed gives bytes to `ghostty_surface_process_output` and a
`KO_FEED_RESIZE` to `ghostty_surface_set_grid_size`.

The server's size wins. The app never sizes a grid: only the decoder
thread does, at a restore and at a resize marker. A snapshot of another
size than the surface is swapped in at its own size, and then the
fork's `GridAdopter` gives the surface that size, off the renderer lock;
the old terminal is freed, not reflowed, and no second snapshot is
needed. The layout event on `/client` and the resize marker
on the view arrive in either order, so for one round trip a pane's frame
and its grid can differ. `PaneView.layout` draws the terminal at the
grid's size, anchored at the top left. That size is the columns and rows
of `PaneView.geometry` (`SurfaceGeometry`), which the decoder thread
reads after each restore and resize marker and hands to main, so main
never reads a grid that the decoder writes. Main refreshes only the cell
after a font, scale or config change. The pane's paper fills the rest,
and the pane's mask clips a larger grid.
`WindowView.present` sends the window's size at once, before it opens
the views. The `/client` link and the view links have no order on the
server, so a view can still take its snapshot at the old size; the
adoption and the resize markers that follow handle either case. A window
is ready for a visual test only when every shown surface grid is its
pane's size in the layout. A closed view logs `view of PANE closed: …`. `PaneView.detach` runs `ko_view_close`
on a utility queue, because the close waits for a running restore or feed;
the pane, and its surface, stay alive until the close returns.

History is what the server's snapshot holds. The app loads no history of
its own and has no Load more. Copy mode freezes the content: entry moves
the feed state to entering, then frozen, and a frozen feed drops its bytes
and marks the pane dirty. Leaving copy mode asks for a new snapshot only
when the pane is dirty. Copy entry fails after `PaneView.copyEntryTimeout`
(2 s).

The surface's scrollback limits are the server's, from `welcome`
(`ko_client_limits`): the mirror contract (design-ko.md, "The pane's
terminal"). The app sets no scrollback of its own. Ghostty reads its
scrollback config only when it creates a surface, and one app config cannot
serve windows of several servers, so the decoder thread sets the limits on
the surface (`ghostty_surface_set_scrollback_limits`) after each restore: a
restore carries the snapshot's limits as adjusted to its size, not the
server's policy. A pane's history memory is thus bounded by the
server's limit under any output volume.

Each pane draws one thin overlay scroller, shown during scrolling or
hovering and fading afterwards. The scroller track spans the expanded content while its thumb and targets count whole grid rows. Ghostty's own scrollbar is disabled. The
thumb uses the mirror's history rows plus the screen, with a native-style
minimum knob size. The knob is one CALayer: a step moves it, and the scroller
never redraws a backing store. A hidden or faded scroller, or one in an
invisible window, does not move the knob, because each move commits a CA
transaction; a reveal or unhide moves it to the current geometry. Its colour resolves from the effective
appearance when the appearance changes, when it is shown and on hover or drag.
A reveal moves one fade deadline 1 s ahead. A burst arms one main-queue timer,
which re-arms only if the deadline moved, and then fades over 0.3 s.
Ghostty's SCROLLBAR action refreshes the scroller only while the app owns no
scroll target; while it owns one, the worker's applies publish the geometry.
The refresh is not a query on main: it queues one capture on the scroll
worker, at most one at a time, which publishes as output does
([Threads](#threads)).
Every precise wheel event adds its delta 1:1 to the
fractional target, including nonzero ended packets. At most one apply is
pending on the pane's serial scroll worker; it starts immediately and reads
the latest output-adjusted target when it runs. Its main callback coalesces
presentation, then applies a changed target.
Ghostty paces rendering with its own CVDisplayLink
(see [Threads](#threads)); token presentation remains immediate.
The app adds no deferred packet, easing or momentum filter.
The `mouse.scroll_multiplier` precision value is the user's speed
override. An active selection gesture uses integral wheel steps.
Thumb drags replace the target; a thumb press snaps once and suppresses
old momentum. Snaps apply the integral viewport directly on main before the
triggering input reaches Ghostty. A short viewport lock excludes worker applies
from that operation; pending applies retain their slot and read the aligned
target, while their obsolete presentation is rejected by the revision.
The pixel-scroll API returns geometry and signed whole-row viewport movement
from the same renderer lock as revision validation and mutation. A failed
attempt publishes neither; a committed move remains successful even if its
render wake fails. Snaps record only the successful attempt's movement, never
a separately sampled before/after difference.
Clicks, selection, typing, paste, IME, find, resize, font
changes and focus loss also snap and suppress momentum. Main publishes only the worker's successfully applied distance and
geometry to the thumb and presentation, not the requested target.
If all three revision attempts fail, presentation stays at the last success
and the target waits for another event or geometry update, with no idle retry.
A restore ends with a scroller refresh and one apply of the latest
target. Main snaps and resets stamp the revision captured before their
apply, so an older apply never appears current.
Live output shares the serial worker and pins a scrolled viewport,
adjusting its distance from the bottom; a zero target follows the bottom.
Hidden and occluded panes retain their renderer rules and do no idle
scrolling work.
`KIDO_APP_DEBUG=1` logs wheel timestamps, phases and deltas, and each applied
target's row and fractional pixel offset.
The thumb's range and size use the mirror's geometry. Colours resolve in the current
effective appearance when drawn.

Command-F opens a pane's native find bar. Find runs Ghostty's own search
over the mirror, which holds the whole history of the server's snapshot,
through the binding actions `search:<text>`, `navigate_search:next` and
`navigate_search:previous`, and `end_search`. Ghostty supplies the
highlights, the count and the selected match. The bar reads "i of N"
outside copy mode and "N matches" in copy mode. Each restart ends the
previous Ghostty lifetime. Ghostty tags totals and selected indices with
that lifetime's immutable generation and rejects queued events after it
ends. The surface's delivery epoch advances on each new search and both
public stop operations, including stops with no active search. Nonempty
edits in a live search keep its epoch. The runtime captures the main-only
epoch getter when accepting an action, then checks it again inside the
weak, asynchronous PaneView delivery. Clearing or invalidating without
restarting therefore rejects already accepted actions too. A replaced
search cannot inherit an old count or selection. End-search also captures
the find-view identity on main, so its queued close cannot close an empty
reopened bar, which has not issued a new Ghostty lifetime yet. Command-G
and Shift-Command-G (also Return and Shift-Return) navigate; Escape closes
the bar and clears highlights.

In copy mode, Command-F, `/` and `?` open or focus the same bar without leaving
copy mode. The bar searches the frozen mirror, with no restart on output. The count
reads “N matches”. `?` searches toward older text and `/` toward newer text;
`n` repeats that direction and `N` reverses it. The first result is the newest
match. Each selected-match event carries the match's first cell, and the copy
cursor (or the end of a `v` or `V` selection) moves there. Search never selects
the match or writes the pasteboard. A failed or empty query moves nothing. Return
in the field gives focus back to the pane and keeps the bar open. Escape or Done
closes the bar first and keeps copy mode; a second Escape exits. A query that is
open when copy mode starts stays, and it only highlights until a query edit or
`n`/`N`. After the bar closes, `n`/`N` reopen it with the same query and
direction. Copy mode exit closes the bar and starts no whole-history search.

In copy mode the app handles the mouse itself and forwards no mouse event to
Ghostty. Thus, no mouse report, `cursor-click-to-move` key or `copy-on-select`
write reaches the pty or the pasteboard, also under mouse-reporting and
alternate-screen programs. Mouse and keyboard share the copy cursor and the
`v`/`V` state. A click places the cursor. A drag selects. A double-click
selects a word and a triple-click selects the wrapped line (`V`). A drag after
a double or triple click extends by word or line. A Shift-click extends the
selection in its mode. A drag past the top or bottom edge scrolls every 50 ms
through the same scroll path as the keys, within the mirror's rows.

Outside copy mode, a left press with Shift as its only modifier enters copy
mode and starts a selection at the pressed cell. As a plain click does, the
press makes its pane the active pane and raises a floating pane. The app sends
that press, its drags and its release to neither Ghostty nor the program, so
the gesture works under every mouse-reporting mode and also when the program
requests shift capture (XTSHIFTESCAPE, `CSI > 1 s`). With shift capture, Ghostty reports a
Shift-click to the program and makes no selection (`Surface.zig`,
`mouseShiftCapture`). The drag then selects as in copy mode, and after the
release the selection and copy mode stay. A Ghostty selection that exists
before the press is extended from its start. Without one, a Shift double-click
or triple-click selects a word or a line. Entry is asynchronous. The app holds
the gesture and applies it when entry completes. If entry is refused or
cancelled, the app drops the gesture and does not send its drags and release
to Ghostty. A press with Shift and Command, Option or Control does not enter
copy mode and keeps its usual behaviour. Thus, Ghostty keeps Shift-Command-click
on links under mouse reporting. Other clicks and drags outside copy mode go to
Ghostty, which keeps its own mouse selection.

A right-click on a selection, in copy mode or not, opens a context menu with
two items: Copy (⌘C) and Prompt with Selection… (⌘O). The menu is built for each
click. Outside copy mode, Ghostty's `right-click-action` selects the word
before the menu opens. In copy mode, a right-click inside the selection or on
an empty cell keeps the selection, and a right-click on another word selects
that word. The copy cursor alone is not a selection. With no text and no
selection, no menu opens. Copy acts like `y` in copy mode and like Ghostty's
copy outside it. ⌘O is the key equivalent of an Edit menu item. It reads
"Prompt with Selection…" when the focused pane has a selection, in copy mode or
a Ghostty selection, and "Prompt…" otherwise. It enters the palette's Prompt
mode ([Command palette](#command-palette)), with the selection appended as a
markdown quote, or with no quote. ⌘O does nothing while copy mode is still entering. The title
follows the focused pane when the Edit menu opens. The item is disabled with no
focused pane, and when the pane's session has no agent that a prompt
can reach: no sidebar row of that session is an agent outside a run
window. Then ⌘O beeps and opens nothing, also in copy mode. In copy mode, `p`
enters Prompt mode only with a selection, and beeps without one. While copy
mode is still entering, mouse clicks are ignored, except that a held
Shift-press gesture continues. The wheel still scrolls.

### Images

Live kitty-graphics images from the view's feed reach Ghostty through
`process_output`, and Ghostty draws them. A mirror accepts only `t=d` on
every host (`kitty_image_media` is `DIRECT`): the pane's terminal reads
and unlinks a program's `t=s` object, so a mirror that also opened it
would race the pane, and a program can never make the app open, unlink or
read a shared-memory object or file. Every frame that the mirror cannot
fill (a refused `t=s`, a restored image, an edit of such a frame) is
pending with a stamp, and `PaneImages` completes it from the server's
frame resource (protocol.md, section 5).

After each restore and each feed of bytes, the decoder thread reads the
surface's pending generation; only when it moved does it list the pending
frames (`ghostty_surface_kitty_pending_frames`, the active screen first)
and queue the frames that are not already in flight. Every pending frame is fetched, not only the frames on screen: a
pending frame holds no pixels, and the list is bounded by the storage
limit. Each fetch runs on its own connection. A local
window asks for shared memory (`Ko-Accept-Shm`), maps the named object
read-only and gives the mapping to the surface
(`ghostty_surface_kitty_frame_adopt`), so a frame is never copied; on a
refusal the app unmaps it, and it never unlinks an object (the server
does). A remote window gets the pixels as a body and attaches a copy
(`_attach`); it keeps a bounded cache of recent bodies, so a copy-mode
resync does not download an animation again. A remote window runs at most
4 fetches at once (8 for a local one), because every fetch is one ssh
channel on the master's one TCP connection, and parallel fetches delay the
view's bytes. A fetch that failed after its retries, for example during an
outage, is queued again at the next welcome of the same instance. A local window keeps no
cache: a fetch by name is one small request. A not-found answer (evicted,
moved on) drops the key and leaves the frame blank, as the pane holds it;
a re-upload moves the stamp and fetches again. Another failure retries a
bounded number of times. The fetches of all panes of one client share
one bounded queue. Animations play from the
attached frames in Ghostty's renderer, with no app code.

The surface's `image-storage-limit` is the server's
`kitty_images_max_bytes` from `welcome` (`ko_client_limits`), not the
user's setting, so the mirror evicts what the pane evicts and a restore
keeps every image that the snapshot holds.

### Focus treatment

In a window with two or more visible tiled panes, the focused pane is the
only one with the pure terminal background. Every other tiled pane gets
the shifted paper: the terminal background mixed 3% toward black on a light
background and 3% toward white on a dark one (relative luminance < 0.5), per
sRGB component. This is the direction rule of the sidebar shade, and one
helper computes both. The titlebar and toolbar band uses this shifted
paper in all sidebar modes and in full screen. Thus it matches an inactive
pane. The pane shift does not follow `window.sidebar_shade`, so a strong
sidebar value does not make inactive panes hard to read. Its own
key, `window.unfocused_shift`, has the same range and direction rule,
with a 3% default. A reload that changes only this key repaints the
panes and the band. The focused pane also gets a 1pt `controlAccentColor`
stroke at 50% alpha, inside its chrome rect, over the padding and not over
cells. A single-pane window draws no shift and no edge on its pane while
its window is key, also under sidebar focus. Floating panes keep a 45%
theme-background overlay when they are not active.

A pane has Ghostty surface focus, and a solid cursor, only while it is its
window's first responder and that window is key (see the not-key rule
below). Thus, a key panel over the window, such as the
[command palette](#command-palette), or another frontmost app makes the
focused pane's cursor hollow without moving the window's first
responder.

The shift changes the paper, not the ink. Each tiled surface gets its own
clone of the app's Ghostty config with `background-opacity = 0` and
`background-opacity-cells = false`. Ghostty then leaves default-background
cells transparent and still draws explicit cell backgrounds, selection and
search highlights opaque. An opaque box under each tiled pane, the size of
its chrome rect, and the pane view's layer carry the pure or shifted paper.
Thus glyphs, the cursor, selection, find highlights and the COPY and
history pills keep their colours. A cell whose program sets an explicit
background equal to the default colour stays pure in an inactive pane.
A config reload clones the new config for each surface. On a
theme switch, Ghostty changes the app config, the app gives each surface
the new colour scheme, and each surface then asks for a reload of its own
config, which clones the current app config. The app sends the scheme
change only after it installs the new app config, so a clone never keeps
the old theme's foreground.

When the sidebar list is first responder, no pane looks focused: every
tiled pane takes the shift, no pane has the edge, and Ghostty draws the
active pane's cursor hollow because its surface is unfocused. Each
focus-treatment update, and each move of a pane view between windows, sets
every surface's Ghostty focus from the window's actual first responder, so
a reparented view does not keep a stale solid cursor. The sidebar
then has the same 1pt accent stroke around its whole column, including the
band behind the toolbar, also in a single-pane window. The active pane
stays remembered, and focus that returns to the terminal (a click, Escape)
restores its edge. Only one surface has the edge at a time. A mouse click
on a sidebar row, a sidebar toolbar button or a pane toolbar button does
not make that view first responder, so a click that navigates and returns
focus to a pane does not flash the sidebar edge. The pane grip is the
exception: it takes first responder for its drag and Escape. Keyboard focus to the sidebar still shows
it.

The toolbar top line and the pane dividers use the terminal background
mixed 18% toward the terminal foreground, one device pixel, so they stay
visible between two shifted surfaces. A pane divider that meets the outer
edge of the tiled tree is drawn on through the outer margin to the
terminal area's edge; its hit area and the layout do not change. The sidebar's split divider uses the
same 18% on a dark background and 28% on a light one. An app-owned
one-device-pixel line covers AppKit's divider, through the toolbar band.
The docked sidebar casts a shadow onto the terminal area from its right
edge: offset 4pt to the right, 14pt blur, spread −2pt, black at 40% on
a dark background and 18% on a light one. It falls over the paper and the
toolbar band and never over the sidebar. The floating sidebar card has an
ambient shadow with the same blur and alpha, offset 4pt down, around its
18pt corners. AppKit's glass shadow is cleared, so each mode has one
shadow. When the floating card's list is first responder, its edge is
the same stroke inset 1pt inside its hairline border, with a 17pt radius.
The panes then behave as under docked sidebar focus. Accent and
appearance-dependent colours resolve at draw time.

When the window is not key, no keyboard input goes to a pane, so no pane
looks focused. This occurs when another app is frontmost, another Kido
window is key, or a panel or sheet over the window is key, such as the
[command palette](#command-palette). Every tiled pane then takes the
shift, also in a single-pane window, the active floating pane takes the
inactive float overlay, no edge shows on a pane or on the sidebar, and
the active pane's cursor is hollow. A change of key window
runs the same focus-treatment update as a change of first responder, so
when the window becomes key again, the previous look returns at once: the
pane edge, or the sidebar edge if the sidebar list is still first
responder. A window that has never been key counts as key, so off-screen
test windows keep the focused look.

One click on a pane in a window that is not key, or in an inactive app,
activates the window and focuses that pane, as in Ghostty's own app
(`SurfaceView_AppKit.swift`, `localEventLeftMouseDown`). A local
left-mouse-down monitor on each pane makes the pane first responder and
selects it on the server. The pane does not accept first mouse, so the click
itself reaches no program: no mouse report, no selection. A window with a
sheet or an open command palette does not take this focus. A click on a
pane in a key window goes to the terminal as before. The pane hover
toolbar's buttons do not accept first mouse either, so a first click on
the grip, zoom, split or close button only activates the window.

### Runtime marks

A pane that runs in a runtime, or a routed pi's host pane whose tools
run in one, shows where it runs (design-runtimes.md, "Clients"; the
approved mockup is `app/design/runtime/`, `mockup.html` with its
`NOTES.md`). `RuntimeMark` (`KoModel/Runtime.swift`) is derived for
each pane from the model's `place` and the runtimes list once for each
model, and never stored: the name, the kind, the configured colour,
the link state and whether the pane is routed. The app turns it into
a colour (`App/RuntimeTint.swift`). A change of the panes that have a
mark moves grids and lays the window out again; a change of a mark's
state or colour only redraws its chrome and pill. A pane whose runtime is not in the list keeps the
name and the hashed colour and shows no state.

- **The stripe.** `PaneChrome` draws a 3pt band in the runtime's
  colour across the top of the chrome, over the top side of the focus
  edge. It is at 55% in an unfocused pane, dashed (8pt on, 6pt at 35%
  of it, still) while the runtime starts, and at full colour when it
  failed: the pane's screen shows the message. A float's band is its
  card's top, clipped by the card's corners; a zoomed pane keeps its
  band.
- **The label pill.** `RuntimePill`, in the COPY pill's family, at the
  chrome's top-right (8pt in, 22pt high): a 6pt swatch, the name, then
  ` · tools` for a routed pi, ` · starting` with a spinner, or
  ` · failed: <message>` in red with the whole message as its tooltip.
  It is at most 300pt wide; the state text truncates, never the name.
  It is at 70% in an unfocused pane. It hides while the hover toolbar
  or the find capsule shows, and in copy mode when it would meet the
  COPY pill. It is not in the toolbar's hot zone.
- **The band is reserved** only for a runtime pane:
  `PaneLayout.tiled(_:alternate:band:)` moves the grid down by what the
  gap above it lacks of 3pt, through the render insets, so the band
  never covers a cell. The content frame, the chrome, the cell count
  and every coordinate conversion stay those of the grid, so a host
  pane's geometry is unchanged, and a runtime pane loses no row: the
  shortfall comes from the padding below the grid.
- **The colour** is the configured `color` as given, else the hue
  `FNV-1a-32(name) mod 360` with saturation 0.73 and brightness 0.66
  on a light terminal background, 0.47 and 0.84 on a dark one
  (`Chrome.runtimeTint`). The stripe, both swatches and the palette's
  dot use it.
- **The limit of the band.** The band fits a pane whose cell is at
  least about 4pt high. Below that (Ghostty's 1pt minimum font gives a
  cell of about 2pt), the gaps above and below an inner pane's grid
  are less than 3pt together, and the stripe covers up to 0.5pt of
  the first row.

### Clipboard

A program's clipboard access (OSC 52 and the kitty protocol, OSC 5522)
reaches the app as server events, never through the mirror
(protocol.md, section 9). The surfaces get
`clipboard-read = deny`, `clipboard-write = deny` and
`kitty_clipboard = false`, so a mirror neither touches the pasteboard nor
writes a reply toward the pane; `ko-pane`'s terminal encodes every reply.
The app's policy is `clipboard.read` and `clipboard.write` of the
config: a read `deny` refuses every server read at once, `ask` asks
(below) and `allow` answers with no sheet; a write `allow` applies server
writes and `deny` ignores them.

A `clipboard_write` event writes the general pasteboard: every content
through `PasteboardMIME`, which refuses text with a NUL, text over 1 MiB
and an unknown type; one refused content drops the whole write. The
server sends writes only to clients whose window shows the pane, and `c`,
`p` and `s` share the one pasteboard. A `clipboard_read` event goes to the
one answerer that the server elects; the owner hands it to the pane's
`PaneView`, or refuses it when no pane of its session has that id. The
answer (`ko_client_clipboard_answer`) carries the requested types, the
available types when the read asks for the list, or nothing for a
refusal. The server's own limit (`MAX_CLIPBOARD` in
`ko_pane_wire/src/frame.rs`) refuses a
larger answer, and its 8 s timer makes the deadline exact. Clipboard
contents are not logged.

Before accessing the pasteboard, the first read asks: “Allow applications on “HOST” to read your Mac clipboard?” The sheet notes
that this also permits applications reached through SSH inside its panes.
**Allow for this connection**, **Always allow** and **Deny** grant or deny that
window's connection. A connection's Deny wins over its Allow, then persisted host grants; otherwise the read asks. A grant has one of three
capabilities (`ClipboardConsent.Capability` in `app/App/Host.swift`): a plain
clipboard read, a rich read of images, HTML and file lists, which asks with
its own sheet text, and an upload. Edit → Reset Clipboard and Upload
Permissions clears all persisted grants and every open window's connection
answer, without confirmation. Always allow is shared between windows and persisted in
UserDefaults by exact configured destination, with Local separately keyed.
SSH aliases are not merged with resolved hostnames; retargeting an allowed alias
retains its grant. Local is not implicitly trusted and includes SSH launched
inside local panes. Background test composition has no persistent grant store
and injects a named pasteboard; production supplies the general pasteboard.

The guarded WindowOwner presenter shows consent only in a visible window.
An unapproved hidden pane/window read is refused at once, never deferred;
the server can elect an occluded window's client, and the program then
gets its empty reply at once. There is one pending read per pane and at
most one consent sheet per host; additional reads are refused. Eight
seconds without a decision refuses; an overdue sheet answer does the same.
Pane removal, window close, eviction and connection retirement refuse the
pending read before freeing the surface. Late sheet responses are ignored.

A mode 5522 paste event stays in the app, because the mode is the
mirror's parser state: Cmd-V tells the program the available types, and
the program's next read of that pane within `PaneView.pasteEventTimeout`,
while the pasteboard is unchanged, is served without a sheet. A read in that window after the pasteboard
changed gets no contents.

Snapshot restore explicitly resets Ghostty's parser before it writes the
snapshot, including when its old state was mid-OSC. MANUAL_MIRROR
suppresses every other parser reply.

The server's election makes one answerer per read, so two attached apps
do not both answer.

Cmd-V and unsafe paste are separate from application reads. An unsafe paste is
asked about in a sheet showing its text, and completed exactly once: pasted,
or refused with an empty completion on Cancel or when its surface is freed.

**Uploads.** File drops prefer existing file URLs. Local panes paste their
original paths; remote panes copy the files. Dropped paths paste through
Ghostty's `paste_from_clipboard` binding like Cmd-V, not
`ghostty_surface_paste_text`, which completes a standard paste directly and
so skips the mode 5522 paste-event decision. If no file URLs exist, Kido
receives file promises on a dedicated operation queue into a private per-drop
directory in its process's private subdirectory of `$TMPDIR/kido-promises`
(all 0700). The process holds an exclusive flock on its subdirectory's open
file descriptor until exit. Reader callbacks are
nonisolated and send results to the main actor. A continuation and one
30-second timer wait for the source; there is no polling. Promise waits count
as uploads. Escape and pane disposal cancel them, and connection changes
prevent late results from pasting. Reader errors and timeouts show a notice.

Promised files use the same regular-file validation and copying limits as
other uploads: 64 MiB per file, 16 files, and 256 MiB total. Open file handles
keep their contents readable after Kido deletes the temporary directory.
Kido deletes it after validation and on failure, cancellation or timeout.
Late reader callbacks remove late writes and cannot paste. Owner invalidation
removes that owner's temporary files synchronously. At launch, Kido removes
only process directories whose exclusive lock it can acquire without waiting.
It holds the lock through removal and checks that the path still names the
locked directory. This clears crash and post-exit writes without deleting
another process's drops. Quit removes only this process's directory. Both
sweeps refuse symlinked parents and subdirectories. Cleanup does not depend
on cancelled tasks running in the termination loop.
Promised files never paste temporary paths, even in Local panes. They use the existing transfer script and drops
directory, with its seven-day cleanup. On both hosts the drops directory is
`${XDG_STATE_HOME:-~/.local/state}/kido-app/drops`, never inside a ko state
directory: an upload is a client action. Remote and Local-pane SSH consent
rules still apply. Text and web links without files or promises are refused.

Surfaces are kept per window, for the most recently shown windows of
any session while their panes total at most 32; the rest have none. A
window gains its surfaces when shown. Showing another window evicts the
least recent past the budget, never the shown one, off the switch path.
A surface is freed in `PaneView.deinit`, after the utility-queue
`ko_view_close` returned. A hidden surface is occluded and its renderer
released, but its view still feeds it; an evicted window opens its views
again when it is shown. Shown surfaces follow the app window's occlusion
during resize too. A visual test's presented-frame fence is an
asynchronous tokened render: its acknowledgement must match the pane's
backing dimensions, inset and viewport revision and target. Ghostty
discards a tokened presentation when the layer's pixel size changes
between the draw and the main-queue commit, when a newer surface
generation commits first, or when the surface is unrealized or zero-sized;
a current discarded request gets one asynchronous retry.

The ko layout document is authoritative: `Layout(window, visible:active:)`
builds the tree from the model's window (a zoomed window shows only its
zoomed pane, as the active one), every Ghostty surface is exactly its
pane's grid, and `PaneLayout` maps cells to points. On each axis a
pane's two inner paddings sum to one cell minus one device pixel, split
floor/ceil in physical pixels so surfaces and dividers stay on the pixel
grid. The border cell between two panes is then exactly their
paddings plus the one-pixel divider, so any tree, however asymmetric,
lines up with no surplus. Around the whole terminal area only, the
horizontal remainder is balanced over a 4pt minimum. Client rows are
floor((height - separator pixel - 12pt) / cell height), with device-pixel
rounding, reserving a 12pt bottom grid gap. The terminal area's top follows
the native safe area; PaneLayout reserves no fixed titlebar height.
The tiled grid bottom is 12pt above the terminal area bottom, rounded upward
onto a whole device pixel if necessary: the gap is at least 12pt and less
than 12pt plus one device pixel. Left, right and bottom edge panes extend their chrome to the terminal
area bounds, owning the side margins and bottom gap as padding. Background,
focus treatment and padding input reach those edges; toolbar hot zones and scroller
strips follow the new pane boundary, with the knob still 4pt inward. The
content, chrome and divider tops respect the separator's bottom edge.
Below the separator, the global vertical subcell remainder sits above the
whole tiled tree. Only outer-top tiled panes expand upward into it, rendering
the bottom slice of their preceding history row through Ghostty's top render
inset in backing pixels. Every inner tiled top and bottom expands through its
vertical padding to the horizontal divider: the top uses the floor half and
the bottom the ceil half of a cell minus one device pixel. Following rows
and history are clipped at the divider, not the grid's padding edge; the
line remains above both panes and its hit/cursor zone wins over band input.
Outer-bottom tiled panes expand down to the window
content bottom through the bottom render inset, showing following rows when
scrolled up, clipped only at the window edge. At the live bottom there are no
following rows, so the band is plain background below the fully visible last
row. Empty history shows background. Alternate-screen panes keep their
unexpanded grid view and zero insets, leaving background in both bands. Zoom uses the same rule. Each top band runs from the grid top to the separator or split divider, possibly spanning several history rows. The full-width one-device-pixel separator sits at the supplied terminal-bounds top, rounded upward to a device pixel; outer-top vertical dividers meet its bottom edge. Dividers stay behind tiled panes and floats. During a stale-root shrink, terminal content is clipped below the separator without changing its grid. Committed and free floating chrome frames are bounded below the separator too.

PaneLayout returns the grid, expanded content, clipped chrome and paired render insets
for each tiled pane. Chrome uses the content rect for hit testing;
window-edge drops and their previews use the union of the visible tiled chrome.
Top and bottom band clicks only focus/select the pane once: no terminal mouse press or selection
starts there. Entering either band clears Ghostty's hover position. Band wheels
scroll primary history without sending application mouse reports.
Mouse and IME coordinates use the grid origin below the strip. Render insets
never enter set_size or set_grid_size, scroll distances, snaps, output pinning
or resize anchors; the live bottom remains distance zero. Floats stay inset-free
in the same shifted grid coordinate space, with the point-to-cell inverse and
pixel-exact free frames unchanged. Floating bounds end at the same pixel-aligned 12pt bottom margin,
so a float's existing bottom padding remains above that margin. Dividers have
six-point hit areas; [Focus treatment](#focus-treatment) marks the focused pane; a
pane shows the window’s shared glass toolbar only in its top-right hot
zone: the toolbar frame plus 24pt to its left and below, clipped to the
pane. It splits, zooms and closes through the same commands as the menus.
The toolbar's grip drags a tiled pane: the target's outer quarters dock
left, right, above or below; its centre swaps. A 22pt
band inside the tiled area's outer edges takes precedence, docking across the whole
window. Window edges preview the resulting half-window;
centre drops preview the whole target for a swap. Pane edges show a 4pt
insertion bar, not a predicted size: the server computes the sizes, and a
prediction would duplicate its layout code. Window-edge drops let the
server handle already-spanning panes; one tiled pane has no drop targets.
The accent highlight follows
the effective appearance. A drop sends one `swap`, `dock` or `dock_window` edit, and
only the next layout moves the views. A click, Escape, a drop
on the source or a floating pane cancels. Dragging is disabled while zoomed.
Floating grips and padding share one move gesture, starting after 4pt of
movement; resize edges follow the pointer immediately. A press without movement
raises a covered float with a `float` edit of its stacking order. Draggable padding is inside the
drawn frame but outside the Ghostty grid, including the fractional right/bottom
remainder. The 5pt resize edges and corners, toolbar and scroller strip take
precedence; terminal clicks remain Ghostty's. Padding cursor rects show an open
hand. A moving or resizing float holds its gesture cursor, with the window's
cursor rects disabled until release or cancellation. Disconnect, removal from the
window, window resignation or closing, and app deactivation cancel the gesture.
Placement requests no cursor invalidation during that gesture; release enables
and invalidates the acquired window's rects once, so overlapping floats use their
current frames immediately. Tiled padding
still only selects. WindowView keeps a view-only free frame
per float after release, and sends its rounded cell geometry as a `float`
edit. PaneLayout owns the point-to-cell inverse and floating bounds.
Layout installs and placement validate free frames against that same conversion;
presentation validates hidden windows too. A changed placement cancels an active
gesture. Zoom, removal, layer changes and reconnect also clear free frames.
Nothing is persisted. Ghostty remains exactly the server's whole-cell grid,
with the fractional size remainder in the right and bottom padding. Chrome,
mask, shadow and hit areas use the drawn frame; pixel clamping keeps it inside
the window grid. Resizing clamps only the dragged edges, preserving their
opposite edges; a right or bottom resize never moves the origin. Each pointer
update places only that float, its backing and toolbar, and unchanged clamped
frames do no placement or cursor invalidation. Full placement assigns each
pane's final frame once. Placement skips unchanged backing, toolbar and scroller
frames and retains an installed mask rather than assigning it again. A float keeps its pixel frame after release until the layout shows its
last edit. Escape stops further edits, not edits that the server already
applied. Pane command errors appear in a sheet. Sidebar drops are not
supported.

Every gesture is one typed `Edit` (`KoSchema.Edit`) through the window's
`LayoutEditor` (`App/Ko/LayoutEditor.swift`). One edit is in flight, on
the editor's serial utility queue, because `ko_client_edit` waits for the
server; the core applies the edit to the newest layout and sends it again
after a conflict. A waiting edit with the same key (a divider or a float)
is replaced by a later one, so a drag sends only its latest step. The
editor holds the gesture's optimistic state while an edit is in flight and
until a layout event shows the revision of the last accepted edit; then
it reports the gestures settled. A failure ends the hold and shows the
core's message. A divider drag is a `resize_pair` edit, a float move or
resize a `float` edit, a grip drop a `swap`, `dock` or `dock_window` edit.
The pane commands map to `split`, `resize_by`, `toggle_zoom` and
`equalize` edits. The core evaluates `resize_by {pane, edge, delta}` and
`toggle_zoom` against the newest layout, so
two presses inside one round trip are two steps: the divider on the
`edge` side of the pane moves toward that edge (for the last pane of a
split, the divider before it), and a resize while zoomed unzooms first.
`ko_client_edit` returns the id of what an edit created with the new
layout;
a directional pane select is `ko_client_select`, not an edit. After a
split the new pane is selected, and after a zoom the zoomed pane. When
the active pane changes while a pane of the window has focus, the focus
follows it. Session and window creation, session rename and reorders are
edits too (`add_session`, `ensure_session`, `add_window`, `rename_session`,
`reorder_sessions`, `reorder_windows`); a reorder keeps its order on
screen until the layout shows it. `App/Ko/LayoutEditor.swift` builds these
edits; `ko layout edit EDIT-JSON` sends the same typed edit from the
command line.

Frame changes place only the shown window; membership and stacking are
reconciled only when the layout's topology changes. Hidden windows are placed
when shown. Terminal focus survives resizing and sidebar collapse;
showing another window or creating the active pane’s view can move focus.

The standard window buttons are AppKit's: the toolbar re-lays them out
at will, so nothing moves them. The fixed top clears them and the
sidebar toggle, which AppKit keeps in the collapsed titlebar,
so the terminal never moves vertically when the sidebar collapses.

## Threads

Client events arrive on the main queue (`ko_client_connect` with the main
queue), and the owner reads the model on main. Every ABI call that waits
for the server runs off main: `ko_client_edit` on the `LayoutEditor`'s
utility queue, `ko_client_delete`, `ko_client_prompt_resolve`,
`ko_client_prompt`, `ko_client_launch`, `ko_client_stop_server` and
`ko_client_probe` on detached tasks, and `ko_view_close` on a utility queue. A close of the
client ends a waiting call with `KO_ERR_CLOSED`. Each view has a
decoder thread in the core, which runs the restore and the feed in the
server's order. The feed hands bytes to the pane's serial scroll queue
(user-interactive), which serializes live output with asynchronous
viewport applies. The core joins queued byte records whose offsets follow each other
into one feed while the sum stays within `FEED_BATCH`
(`ko_client/src/ffi/view.rs`), never across a marker, a snapshot or a
gap. It never splits a record, so a larger record is one feed. After each parse the queue reads the scroll
position, the alternate screen and the mouse capture, and stores them in
the pane's one latest-state slot with a count of completed feeds. At most
one main hop is pending for each pane; it applies the latest state and the
count. Thus, the output volume of a pane sets neither the number of main
blocks nor the number of renderer-lock queries on main: main reads terminal
state only for an alternate-screen change, which snaps the viewport at most
once for each hop, and for copy-mode entry. Main must never wait for that queue: parsing can fill
Ghostty's app mailbox, whose surface messages are drained by
`ghostty_app_tick` on main. Ghostty's stream handler releases the renderer
mutex before waiting for mailbox capacity, so main can still take that
mutex through the thread-safe pixel-scroll API to snap before handling
input. The viewport lock serializes snaps with worker applies, but is never
held across output parsing. Its cumulative snap adjustment removes
snap-induced offset changes from feed's before/after output-pinning delta:
`D1 - D0 - sum(snap movements)`. A zero target still follows the bottom.
Lock order is viewport then target or renderer, with neither held while
waiting for viewport. Only the decoder moves a surface's grid; main
changes its cell, scale and insets, and the fork keeps the grid at a
cell change. The fork's `Surface.size_mutex` orders the two, so no
callback that runs under the renderer lock may call
`ghostty_surface_size` or `grid_metrics`. The decoder thread is the only writer of a surface's
terminal state: the restore, the grid and the parse run only from the view's
callbacks. The one exception is a fetched image frame: `PaneImages`
attaches or adopts it on the fetch's task, under the fork's renderer
lock. Its order against a restore needs no thread rule, because the
frame's stamp decides: a restore that replaced the terminal makes the
frame pending again, the pending generation moves, and the decoder queues
the fetch again, while the surface refuses an attach whose stamp no
longer matches a pending frame. `PaneImages.stop`, on main before the
surface is freed, waits for a running attach and lets none start.
`app/scripts/lint.sh` refuses a `restore_snapshot` or
`set_grid_size` call outside `app/App/Ko/KoClient.swift`, a
`process_output` call outside it and `app/App/PaneView.swift`, and a
`kitty_frame_attach` or `_adopt` call outside `app/App/PaneImages.swift`.
Image fetches (`ko_client_image`) block on global utility-queue work
items, never on main or the decoder thread. A `PaneView` is freed on main
(`dispatchPrecondition` in its `deinit`). Renderer callbacks publish asynchronously to main; runtime wakeups
coalesce main ticks.
Ghostty paces rendering with one CVDisplayLink for each surface, as
upstream does. The pane gives its surface the window's screen number
(`ghostty_surface_set_display_id`) each time it presents, so the link follows
the window to another display. The render thread creates a surface's CVDisplayLink the first time it
syncs the link, only if `window-vsync` is enabled. The renderer requests each start, stop and display
change of the link asynchronously, and the link changes only on main.
CoreVideo also stops and starts the link on main when a display reconfigures,
for example at wake. Thus, the two never run concurrently: a concurrent
`CVDisplayLinkStart` during `CVDisplayLinkStop` can hang the stop forever
(upstream Ghostty ffaaf5d7a). The link runs while the surface is visible
and the renderer has rebuilt cells or images or a custom shader animates.
A Kitty animation does not keep the link running. The render thread's
animation timer wakes at the next frame's deadline, and the frame update
rebuilds the images. Thus, without other render work, a Kitty animation
causes a draw only when a frame is due, at its own cadence. The link stops
when a frame has nothing to redraw. A Kitty frame's rebuild still starts
the link once; its next callback finds nothing to redraw and stops it.
A changed start or stop request always queues a sync on main, also when
the link's actual state already matches it. Thus, a sync that is
applying an earlier stop cannot lose a later start. The fork's renderer starts the cursor blink timer only while
the surface is focused and the terminal's cursor-blinking mode is set, and the
timer stops at its next tick when either ends. Thus, the default non-blinking
cursor costs no idle frames. Viewport moves and output do
not reset an active scrollback compression timer. Its callback samples the
PageList activity token every 250 ms, so compression normally starts
250–500 ms after the last activity, once it gets the terminal lock. Surface free joins the renderer and then
releases its display link on main.
If `Surface.init` fails after it started the renderer or IO threads, it
stops and joins them and releases the font grid reference before it returns.
Ghostty requests IO/process termination, marks search stopping and joins it,
then joins IO while the renderer still drains. Only after both producers have
stopped does it stop and join the renderer and release shared resources.
Search and PTY IO surface-message sends retry in 10ms intervals, checking their
stopping flag between attempts, so a full app mailbox cannot prevent these
joins on main. Canceled owning parser messages are freed. Renderer messages,
including ordinary end-search highlight clears, remain ordered and delivered;
blocking batches wake their consumer before enqueueing. Manual-output callers
must already be quiesced before destruction; joining Ghostty IO does not stop
an external parser caller.
Search input uses a mutex-protected growable FIFO. Producers append, release
the mutex and wake; the consumer detaches one batch and processes it outside
the mutex, freeing unprocessed needles on stop or failure. Main never waits
for search-input capacity, including navigation bursts while search is waiting
for main's app mailbox. Pending growth under an indefinite producer is the
tradeoff for preserving command order. The other blocking sends from main to
the renderer stay.

## Sidebar

The sidebar tree is a projection of the core's model:
`Snapshot(model:)` in `SidebarFeed/Projection.swift`. Sessions are
source-list sections. A window with one pane is a pane item, a window with
more panes is a group, and a child window is nested under the pane that
its panes' `parent` names, at any depth. The order and the parent edges
are the core's `outline` (each item carries its window; design.md, "The
sidebar tree"); the app only groups it by window. A pane item's title is
the core's label, its lifecycle comes from the pane's status and, for a
dead pane, its `close` and run (below), `run` is its run id, `started` is
the run's start while it is live, `mark` is the core's seen mark and
`inbox` tells whether the row's `inbox` is true (its message stream is
open). The snapshot's
`ServerInstance` is the model's instance string. The Swift types of the
model are generated from the schemas (see [Testing](#testing)), so the app
has no hand-written decoder and no unknown values. Ko ids (`pane_N`,
`window_N`, `session_N`) decode straight into `PaneID`, `WindowID` and
`SessionID` (`KoModel/ID.swift`), which the generator uses for the id
schemas; their string form is the ko id. `KoModel` also holds the session,
window and pane lookups and `KoModel.current`, the one rule for the
current session, window and pane: the selection, else the first
session. A node's identity is scoped
to its session.

A pane row of a runtime pane or a routed pi has a suffix after its
title ([Runtime marks](#runtime-marks)): 6pt gap, a 6pt swatch, 4pt
gap and the name in secondary colour, then ` · starting`, or
` · failed` in red with the message as the tooltip. The title
truncates first; the suffix keeps 96pt. A nested row omits the suffix
when its runtime equals that of the nearest ancestor pane row, so a
routed pi's runs and children in its runtime show none.

`Sidebar` is an `NSSplitViewController` with a sidebar item, which
supplies the floating glass, collapse animation and saved width (200pt to
360pt). The window has an icon-only unified toolbar only because the
sidebar's glass reaches the top of the window, traffic lights inside it,
when there is one; without it AppKit adds a plain titlebar strip. The
chrome follows the Ghostty theme background. The native header band, the
window background, the terminal host and the tabs' theme use it with the
inactive-pane shift ([Focus treatment](#focus-treatment)). The terminal
content view, banners and a single-pane window's paper and padding stay pure.
Full screen keeps the toolbar visible by removing `.autoHideToolbar` from
the presentation options. New Session is a standard
image toolbar item, as is the sidebar toggle, targeting the split view
controller. Both are borderless and the toolbar is not customizable.

Titlebar tabs and the remote user@host label occupy a flexible native
`NSToolbarItem` after `sidebarTrackingSeparator`, not a content overlay.
They follow the native separator when the floating sidebar opens.
`WindowOwner` computes the background and appearance once and assigns them
atomically to `WindowTabs.theme`. On theme assignment and
`viewDidMoveToWindow`, the tabs synchronize their own window's background,
appearance. Background and titlebar transparency are synchronized only in
the main window. An app-owned, non-hit-testing `HeaderBackground` is the
lowest subview of the host's contentView. In full screen the host is the
separate `NSToolbarFullScreenWindow`: its native right-hand material draws
white or grey rather than the terminal theme. The backing paints only to
the right of the live sidebar glass edge in both docked and floating modes,
leaving AppKit's own sidebar glass uncovered up to the top of the screen.
The opaque backing covers the main window's sidebar separator and shadow,
so with the docked sidebar it carries its own `SidebarSeparator` and
`SidebarShadow` at its left edge, which continue them through the band.
The main window's full-height sidebar already extends under that host. The docked list adds no rounding or outline to AppKit's
square sidebar; only the floating list has an 18pt radius and hairline
border. With the sidebar collapsed, the whole band is themed. No additional glass is installed. AppKit's glass shadow is cleared in both
modes; the sidebar shadows are the app's own ([Focus treatment](#focus-treatment)).
WindowTabs paints no background of its own.

Next Window and Previous Window (Command-} and Command-{, the menu, the
palette and Ghostty's tab actions) follow the window-cycling rule of
[design.md](design.md#the-sidebar-tree). One pure
function, `adjacentWindow` in `SidebarFeed/Windows.swift`, computes the
step. It reads the displayed order, so a pending reorder counts. From a
top-level window, a step goes to the adjacent top-level window. It never
goes into child windows, and it wraps across sessions in both directions.
A window that the snapshot does not nest under a pane is a top-level
window: a shell's, a top-level pi's or a parentless run's. From a child
window, a step goes to its adjacent sibling. Previous from the first
sibling selects the parent. Next from the last sibling selects the
top-level window after its top-level ancestor. When the target is the
current window (one top-level window), the app selects nothing.

Tabs project the current session's top-level windows from the
snapshot; descendant windows activate their ancestor tab. Each title is
the composed label of that window's focus pane, or of the client's active
pane in the shown window. A tab whose active pane is an
agent is drawn like its sidebar row: semibold, with the display-only
@ prefix when that row has one; other tabs are regular with no @. WindowView's active
pane, from the layout and the client's selection, is shared with terminal
focus. Each tab combines its window and descendants into one status mark,
ranked error (including unseen failed outcomes, command exits
too) > waiting > running > done (unseen) > quiet. With the sidebar collapsed
or floating, tabs use the pane row marks: red dot, orange dot, green running
dot and green check. Docked tabs show only red and orange; quiet shows nothing.
Accessibility labels follow the visible mark with " — error", " — waiting",
" — running" or " — done". The mark is centered 15pt from the tab surface's
leading edge. The label is inset 26pt on both sides regardless of the
mark, so nothing shifts. Hovering the mark's own 16pt slot, and only that slot,
replaces it with a 16pt × close button whose hover brightens it with a 10%
labelColor, 4pt-radius fill; leaving the slot restores the mark. A 28pt-wide,
icon-only + at the trailing end of the strip, outside the scrolling tabs,
creates a window after the current one through the same new-window request as
Command-T.

`SidebarView` is a reusable `NSTableView` backed by the pure row model in
`SidebarFeed/Rows.swift`. Sessions have noninteractive 29pt headers with
11pt semibold secondary labels and an always-visible, separately accessible
new-window plus; hovering brightens only its icon. Sessions do not fold.
Each pane's child-window trees immediately follow that pane, before its
next sibling; drawn order and navigation share the row-model traversal.
OSC 7501 non-root records follow their pane before its child windows, ordered
by slash components in UTF-8 byte order. Each record is mapped to an agent
row (title or full id, message as the activity line, state mapped
working→running, blocked→waiting, error→failed, done→done, idle after the
parent's seen suppression for done/error) and drawn through the same row
path as every other row; there is no separate record view. A record differs
from a child-window agent row only in having no @ prefix and no clock, and
in being display-only: never a navigation, click, hover or selection
target, and skipped by arrow navigation.

Hovering a pane row's status-indicator slot, the 16pt square centered on the
indicator, replaces the indicator with a 16pt × close button; the rest of the
row has no hover treatment and records have no close button. Every app-issued
close goes through one confirmation: the row and tab ×, Close Pane (Command-W)
and the menu commands. If the pane, or any pane in the window and its
descendant windows, is running or waiting, a stock `.warning` NSAlert sheet
asks `Close “name”?` with "A process is still running in this pane. Closing the
pane will end it." or "Processes are still running in this window. Closing the
window will end them."; its Close (Return) and Cancel (Escape) buttons sit
side by side. A quiet target closes at once. Only one alert is prepared at a time.

File → Close Window and Session → Close Session have no shortcut. They
use the same confirmation. Close Window deletes the key window's current
window. On a session's last window this also ends the session, with no
extra warning. Close Session checks every pane of every window of the
session, and asks with "Processes are still running in this session.
Closing the session will end them." Every close is one `ko_client_delete`
of the pane, window or session, on a detached task; the server deletes
the target with its descendants. A failed delete reports "Pane command
failed" in another sheet. When no session remains, the window shows the
"No sessions" banner, and its Start creates one session in the home
directory. The native window's close button still only disconnects
([Remote hosts](#remote-hosts)). With no window, the Window and Session
menus and Close Window are disabled.
Captions use a display-only 200ms debounce per row. New text must remain
stable for 200ms; empty text must persist for 200ms before the old caption
is hidden. The first snapshot after launch or reconnect shows captions
immediately. Row height and accessibility use the displayed caption. One
timer serves the next pending deadline; removed rows lose their state.

All pane and program rows are 32pt single-line or 48pt with a caption, with
7pt vertical padding. Titles are 13pt regular on an 18pt line; captions are
11pt on a 15pt line, 1pt below the title. Titles of panes whose lifecycle is a
live agent (a pi agent, another agent or a remote agent) and all program-record
rows are semibold; every other pane title, Ended and Terminal runs included,
is regular. Rows have
a 12pt leading inset, a 16pt leading slot holding the status indicator, and an
8pt gap; there are no leading icons. The trailing inset is 12pt and the
trailing column holds only the 10pt tabular clock. The activity line is one
line, truncated with an ellipsis, from the title's leading edge to the
trailing inset. Nesting steps 15pt at every depth. Only the focused pane row has a 10%
labelColor fill, with 7pt corners. Independent keyboard selection also has
7pt corners and clears on mouse press. There is no window-wide fill or focus
mark.

Vertical hierarchy guides draw above fills: opaque 1pt lines, light #bfbab1
or dark #4f555c, aligned to backing pixels, without horizontal arms or
stacked segments. Only a top-level multi-pane window gets a group guide, at
x=5pt, from its first pane's top+10pt to its last descendant's bottom−10pt;
single-pane and nested multi-pane windows have none. Every children block,
child windows and records alike, has a guide growing out of its parent row's
status indicator: at the indicator's center (the parent row's left+20pt),
from the indicator's bottom+3pt to the last descendant's bottom−10pt.
Geometry is derived in the row model as per-row guide segments, not
maintained in a separate view tree.
The display-only @
prefix, never doubled, marks an agent that can be messaged, which is exactly
a live pi agent pane. A run pane gets no @ while it is a Terminal or Ended: its
inbox is not up yet or is gone. A native agent pane (such as
Claude Code) and an agent over SSH (an Ssh pane with a remote agent, out of
reach of message_agent, which only reaches pi sessions on the same server)
cannot be messaged, so they keep the semibold title without the @. Idle local shell panes
(Live Terminal at a known Idle prompt, no run, idle/done/failed indicator) display secondary-colored
`Terminal`; an Unknown phase, full-screen programs, SSH, and run items keep their labels. Both display
rules leave raw pane labels and tab/window titles unchanged.

The app composes the row from the core's label. The label is the core's title,
except that a local shell without a program report and not in a run shows a
non-empty running non-fullscreen command, and a remote terminal shows
`ssh user@host`, adding `: command` only for an interactive, report-free,
non-fullscreen running command. The caption is the agent's or report's `msg`
and progress percentage, joined by a space; Ended rows show their result
except completed or unknown, which show none: the green check alone marks
completion, while accessibility still reads "gone, completed". A run's
start metadata drives the clock even when a caption is shown. A live pane's indicator is its core `mark`
(running, waiting, done, failed, or none, which is quiet); the app adds
only the Ended, lingering and run cases. A dead pane with a run, or with
`close: keep`, is Ended with its run's result, else with its exit: Ended
completed is done, failed and died are errors, stopped and unknown are
quiet. A dead pane with `close: on_exit` and no run lingers until the sweep
removes it: its lifecycle carries the cause, it has no caption, and its
indicator is a dimmed checkmark for exit 0 and a dimmed × for any other
cause, so a finished child that ko is about to close reads as gone, not as
a fresh result; accessibility names the cause (`SidebarFeed/Rows.swift`).
The lingering statuses never reach a window tab. The indicator sits in the leading slot, centered at
x=20pt plus 15pt per nesting level and vertically on the title line; the
header plus center is 15pt from the right edge. Indicators are 6pt dots:
idle and quiet gray (secondaryLabelColor at 45%), running/compacting green,
waiting rows of any kind orange, failures red. Done/completed is
a plain green checkmark, about 6×4pt at a 2pt stroke, visually centered on
the dot position. The lingering checkmark and × have the same footprint and
stroke, in the secondary ink. Tabs aggregate the same mapping, with running and done
marks visible only when the sidebar is collapsed or floating.

There are no window or child gaps and no divider rows. Each session retains
its 16pt bottom gap. The header plus is 11pt, matching its label.
Every row has positive height. Colors resolve at drawing
time; fonts are cached at
initialization. Same-shape snapshots reload only changed rows. Equal-width
clock ticks invalidate only the clock label; width changes invalidate the
first-line band from the title's leading edge through the clock, so title
truncation redraws. Indicator/title/activity draws outside the dirty rect are skipped.

Selection and scroll survive snapshots by session-scoped node identity.
Scroll anchors the first visible identity and its intra-row offset,
falling back to pixels only if that row disappears.

The single-line, truncating diagnostic sits above the table; the full
diagnostic is available in its tooltip. The sidebar has no filter. Jump
failures leave focus intact; a successful jump returns focus to the pane.
Selection changes from other clients update the selection without taking
keyboard focus.

The toolbar and Shift-Command-S toggle the sidebar; the View menu's
Show/Hide title follows its collapsed state. Focus Sidebar uses
Command-S. Control-Command-F enters full screen.
Command-{/} and Ghostty previous/next tab step through every window of
every session in sidebar tree order, nested run windows after their
parent, with wraparound, and select it with `ko_client_select`.
Option-Command-]/[ switches sessions
with `ko_client_switch`, in the server's session order, with wraparound
and a single-session no-op. Numbered and last tabs, absolute sessions and
the sidebar jump use `ko_client_select`. A jump to a pane that a zoom
hides first sends a zoom edit that ends the zoom. The server sends a
selected event for every select, also for the pane that is already
current, so the selection is only the server's; the core refuses an
unknown pane with `KO_ERR_NOT_FOUND` before it sends. Command-{/} keep
their own walk because the server's window switch follows document order,
and the sidebar puts a run window after its parent pane.
Command-N and toolbar plus create a session ([Command palette](#command-palette),
New session). File → New Session with no key window uses an open local
window that is not key, or opens a local window. The window that it opens
has the dial cause `newSession`: it makes a session on its first model,
once, also on an empty server. The intent belongs to that window. Closing
it before its model drops the intent, and a later ordinary open does not
make a session. Each session header plus and Command-T add a window after
that session's current window, made from its source pane, with an
`add_window` edit, and select it from the resulting layout. The
source pane is the pane that this client selected when the session's
current window is the client's, else that window's `focus`: another
client can move the document's focus. The menu's splits make the new
pane from the pane they act on. The new pane takes the source row's
`runtime` (`KoModel.newPane`), so a routed pi's pane gives a host
pane. Its `cwd` names the source pane, and the server moves that
pane's directory into the new pane's place (docs/protocol.md,
section 15, "The cwd of a new pane"); a new session with no focused
pane starts in the home directory. In the table,
arrows and j/k move pane-only selection, Return activates with exactly one
select, and Escape releases side focus and returns to the pane, also
without a connection. Left/Right do nothing; headers do not activate or
fold. Only the first selected event after a request installs deferred
focus; failures preserve focus. One monotonic UI-intent revision advances
on selection/focus changes and navigation. Each request captures it; only
a still-current completion leaves the sidebar or installs deferred focus.
Any new intent cancels deferred focus, which is consumed on pane changes
as well as window topology. Pending requests fail once on disconnect and
are never replayed.

Pane indicators come from the typed lifecycle and the core's mark, never
re-derived from raw program records. A tab's mark summarizes its window and
descendants' row statuses in error > waiting > running > unseen done > quiet
order; docked tabs show only error and waiting marks.

The core owns seen. When the union of the panes that the attended
windows of the host show, or `attending`, changes, the owner calls
`ko_client_observe` with it. A window is attended while the app is active
and the window is key, not minimized and visible. `Notifier.seen(host:)`
computes the union. The core acknowledges on every change and posts a
model event when a mark changes, so no owner reads its model only to push
observe. Each pane's `mark` (none, running, waiting, done or failed) is
the core's, and a report wins over a full-screen program; an unseen
success draws a checkmark and an unseen failure red. A program record's
done or error outcome becomes quiet when its pane's outcome is seen
(the core's `records_seen`). Seen is not persisted across launches. The sidebar is visible by
default; it does not automatically collapse at narrow widths.
## Command palette

Command-P (View → Command Palette…) opens the palette and closes it.
Shift-Command-P does the same. It is Ghostty's `toggle_command_palette`
default, and from a pane it arrives through Ghostty's action hook. The sidebar
has no filter; the fuzzy scorer belongs to the palette.

`AppDelegate` owns the one palette: a `PalettePanel`, a borderless, floating
`NSPanel` the size of its card, and the focus to restore (the anchor owner and
its window's first responder). `WindowOwner` has no palette state. The palette
acts on windows only through the owner's own methods (`perform`,
`confirmClose`, `renameSession`, `newSession`, `reveal`). The anchor is the
key Kido window's owner when the palette opens.

The card is always 600pt wide. Over a window, it is centred horizontally on
the content area below the toolbar, also when the window is narrower, and its
top is 20% of that area's height below the area's top. With no window, it is
centred on the main screen's visible frame, with its top 20% below the top of
that frame. The frame is then clamped into the screen's visible frame. The
panel is not a child window and does not follow a window drag: a press on the
window makes that window key, which closes the palette. The card takes the
anchor's terminal theme, or the app's theme with no window: the terminal
background mixed 7% toward the foreground, a 0.5pt edge of the foreground at
14%, and a 12pt radius. The card draws no layer shadow: the panel is exactly
the card's size, so a layer shadow would be clipped to its square corners.
The panel is clear and not opaque, and the window server draws its shadow
around the rounded card.

One close path serves every trigger: the two keys, Escape at the root, a
choice, the anchor window's resign-key or close, another window becoming key,
and the app's deactivation. It restores the saved focus: the saved responder
if it is still a view in that window, else the owner's selected pane. It does
not restore focus when another window became key, because the user moved
there. A choice restores the focus before its action runs. Thus, an action
that reads the first responder (Find…, Copy Mode, Prompt…, Split) sees the
pane, and a jump's own focus target, installed later, wins. The pane under an
open palette draws a hollow cursor ([Focus treatment](#focus-treatment)).

The root list is built from live state, in this order:

- The top-level panes of the anchor only, in sidebar order. Thus, the palette
  never jumps to another owner: not from Local to a remote host, not between
  hosts, and not to another window of the same host. With no anchor, there are
  no pane rows. A top-level pane is a sidebar pane row at indent 0
  (`SidebarRow.topLevel`, which the sidebar's drag source also uses): a child window that the snapshot nests under a pane (a subagent or a
  run) is not in the list, and neither is an OSC 7501 program record row.
  There are no session rows; the session commands below stay. A pane row has
  its status mark and jumps through one `ko_client_select`, as a sidebar row does. The
  anchor's window comes to the front first. The detail is the session name,
  after the host for a remote owner. An anchor that is offline or
  reconnecting adds no rows.
- `Host` (`desktopcomputer`, detail "this Mac"), only when the focused
  pane's row has a runtime, then one row for each runtime of the
  anchor's `Welcome` ([Runtime marks](#runtime-marks)): the title
  "Runtime: NAME", a 6pt swatch in the icon slot and the detail
  `kind · state` at the right, in the shortcut column; a failed
  runtime's detail is `kind · failed · <message>` in red, the message
  cut at 300pt. With an empty query, `Host` is selected.
- Each recent host that has no open Kido window, newest first, with the
  `globe` symbol and the detail "Connect". This holds also when windows are
  open.
- A fixed list of commands, each read from its menu item (found by action and
  represented object, never by title) for its title, menu path and current
  key equivalent: New Session ("New Session…" with an anchor), Rename Session…, Close Session, New Window,
  Close Window, Split Right, Split Down, Close Pane, Zoom Pane, Connect to
  Local Host, Connect to Remote Host…, Hide/Show Sidebar, Focus Sidebar,
  Enter Full Screen, Find…, Copy Mode, Prompt…, Reset Clipboard and Upload
  Permissions and Theme…. The window
  commands need an anchor. The pane commands need a live focused pane: a
  connected anchor whose saved responder is a visible pane of that window, or
  a view inside one, such as its Find bar. Prompt… also needs an agent in the
  pane's session, as its menu item does.
  Navigation items, Select Pane, the numbered lists, Find Next/Previous, Hide,
  Quit and the palette item are never in the list.

While the palette is open, each owner snapshot or model change and each window
close rebuilds the entries from the saved owner and responder. The panel stays
key. The query is applied again, and the selection is kept by entry identity,
else row 0. A row is checked again when it runs. A pane row needs its own
owner, still navigable, with the same `server_instance`, whose rows still
contain the target; else the palette shows "That pane is gone" and sends
nothing. A pane command needs a live focused pane again. Then a command
updates its menu and runs only if its item is enabled, through
`NSApp.sendAction`. Else the
palette shows "Not available now" and stays open.

Each row shows a detail (the host, session name or menu path) in secondary
colour, then ` › ` and the title; agents are semibold. Spaces, `>` and `›`
split the query into words. Each word must match the title or the detail, in
any order, so `main term` finds the Terminal pane of session main. A word uses
`fuzzyMatch` in SidebarFeed: the characters match in order, a run of adjacent
matches scores more, and a gap scores less. A word scores one less on the
detail than on the title, so a title match wins a tie. The row score is the
sum of its words, and equal scores keep the list order. Each run of matched
characters gets a fill of the terminal foreground at 14% with a 3pt radius;
the text keeps its colour and weight. With no match, the list shows "No
matches".

The palette has six modes besides the root (`PaletteMode` in
`app/App/Palette.swift`). A mode shows a chip left of the
field (22pt, the mode's symbol and name) and a foot that names its keys.
Entering a mode clears the query and the error. An error is a red line between
the field and the list; an edit clears it.

- **Runtime** (`PaletteMode.runtime`, nil for `Host`; the chip is the swatch and the
  name, or "Host" without a swatch; the field reads "Open as…"). A
  runtime or `Host` row of the root enters it. Its rows are New Window
  (in the anchor's current session) and, with a live focused pane,
  Split Right and Split Down; the detail follows the title. Return
  sends one layout edit whose new pane names the runtime, or none for
  `Host`; a runtime that is down starts with that pane. The foot names
  the kind and state and where the new pane runs. For a failed runtime
  a red line above the foot repeats the message and says "The new pane
  starts it again."; an edit of the query does not clear it. Each
  model change resolves the runtime again by name, so the chip, the
  foot and the red line follow its state while the step is open, and
  the query and the selection stay. There is
  no New Session row: a session holds host and runtime windows
  together.
- **Connect** (`globe`, "user@hostname or SSH alias"). The root row Connect
  to Remote Host…, File → Connect to Remote Host… and Shift-Command-K enter it.
  With text, the first row is "Connect to <text>", selected. The recent hosts
  that match follow, with their relative time. With no text, the last row is
  Clear Recent Hosts, which clears the list without confirmation. With no
  text and no recent hosts, the list shows "No recent hosts". Return on the
  typed row validates the text as a `Host`. An invalid host keeps the text and
  shows the validation message as the error, and the typed row is absent until
  the text changes. A valid host or a host row connects through the same
  remote routing as URLs and opens a new window.
- **Rename session** (`pencil`). Session → Rename Session… and its root row
  enter it. It targets the anchor's current session, with the current name in
  the field, selected. Return commits through `SessionName`, the rules of the
  sidebar's inline rename: an empty or unchanged name closes the palette with
  no change; a name with `:` or `.` or a duplicate name shows the rule's message
  and selects the text again; a refused edit shows the core's message. The
  sidebar's inline rename and this mode call the same
  `WindowOwner.renameSession`, which sends a `rename_session` edit.
- **New session** (`plus`, "Session name", foot "↩ create"). The anchored root
  row "New Session…" enters it. With no anchor, the row is "New Session" and
  runs the menu action. When the anchor has no snapshot yet, the row is "New
  Session…" and shows "Not available now". File → New Session and Command-N do
  not enter the mode: they create a session with the first unused name of
  "session", "session 2", …. The mode has the same field, Return and error
  behaviour as Rename session, with an empty field. `SessionName` checks the
  name with the same rules, except that an empty name shows "Enter a session
  name." When the anchor window closed, is not navigable or its
  `server_instance` changed, the mode shows "That window is gone".
  `WindowOwner.createSession` sends one `add_session` edit with the name and
  one pane in the cwd of the anchor's focus pane, else the home directory,
  and selects the new session from the resulting layout. A refused edit
  creates nothing; it shows the core's message and the mode stays open.
  Success closes the palette.
- **Prompt** (`bubble.left`). It sends a prompt to an agent through the core:
  `ko_client_prompt_resolve` and `ko_client_prompt`, with the source pane as
  the caller. It replaces the list with its own view, `PalettePrompt`,
  described below.
### Prompt mode

Prompt mode shows one prompt at a time. Its source is a `PromptSource`: the
owner, the server instance, the session, window and pane it was opened from,
the window name at open, the selection of this open as the quote, and an
optional preselected agent pane. The entry points are:

- ⌘O, "Prompt with Selection…" in a pane's context menu, and `p` in copy mode
  ([Panes](#panes)). The source is the focused pane, and the quote is its
  selection, if any. With the palette closed, `WindowOwner` forwards the pane
  to `AppDelegate.openPrompt`, which opens the palette over the pane's window
  with the pane as the focus to restore.
- ⌘O in the root list. On a highlighted agent pane row outside a run window,
  the source is that agent's own pane, preselected, with no quote, from the
  anchor, if the row's check still passes. On any
  other row, ⌘O acts as the Prompt… row. Only the highlighted agent row shows "⌘O prompt" in its
  shortcut column. In another mode, ⌘O does nothing.
- The root row Prompt…: the focused pane, with its current selection.

The pane entries first check for an agent in the source pane's session, from
the snapshot that the sidebar draws. Agents in a run window do not count,
because a prompt excludes every pane of a run window. Without one, a
key entry beeps and opens nothing, the context-menu item and the Edit item are
disabled, and the root list has no Prompt… row. Root ⌘O on an agent row needs
no other check, because the row is the agent. Thus, no entry opens Prompt mode
when its snapshot has no agent. Only a resolve with no candidate shows the no-agent state below.

The card's head row has the mode chip and the target picker, "Prompt
**@name** in this window ⌄" or "in window <name>", with the place in
secondary colour. Under it are the field, a status line and the foot. The
head is 47pt and the foot 40pt. The field is a plain TextKit 1 `NSTextView`
with 13pt text on 18pt lines, 9pt above and 12pt below, as the mockup render
measures. It has no placeholder. It grows with its text up to 6 lines, then it
scrolls and shows its scroller. The card keeps its top edge as it grows.

The field's text is markdown, and it is exactly the text that is sent. The
package `app/Packages/PromptMarkdown` parses it with apple/swift-markdown after
each edit and sets only display attributes; styling never changes the text.
Only the app links the package. `VisualTests` imports it with `link: false`
in `project.yml` and gets its symbols from the host app. When both targets
link it in one build, Xcode builds swift-cmark as a framework and warns that it has no
umbrella header.
The package also owns the quote-append rule below, as a text function. Quote
styling follows the parsed `BlockQuote` nodes, not lines that start with `>`:
the quote text is in the secondary label colour, its visible `>` marker and
the space after it in the tertiary label colour, and a 2pt bar in the
secondary label colour at 45% is drawn 8pt left of the text edge over each
quote line, so consecutive lines make one bar and a blank line breaks it.
Inline code is SF Mono 12pt over a fill of the label colour at 8% with a 3pt
radius. Strong text and headings are semibold at 13pt, and emphasis adds the
italic trait to the font it is in.
Every marker stays visible, and every line stays 18pt. Thus the field needs no
caret, selection or Backspace rules of its own: hidden markers would need one
for each editing gesture.

A selection is appended to the text as a quote: if the text is not empty and
does not end with a blank line, a blank line first; then an empty line for the
caret; then each selection line prefixed with `> `, or a bare `>` for an
empty line. The caret goes on the
empty line, scrolled into view. The blank line keeps the caret line out of an
earlier quote, because CommonMark makes a text line directly after a quote
line a lazy continuation of that quote. A quote may directly follow the caret
line, because a blockquote can interrupt a paragraph. An equal quote is
appended again.

The foot names the keys, "↩ send
· ⇧↩ new line · ⇥ agent · esc close, keeps draft", adds "· draft restored"
when a draft came back, and has Send at the right: 26pt, 8pt radius,
`controlAccentColor`, or the label colour at 14% when disabled.

An entry first resolves the candidates for the source pane with
`ko_client_prompt_resolve`, off main. Nothing
changes on screen until the reply: a closed palette stays closed, and the root
list stays as it is. Then the palette opens or enters Prompt mode with the
target, its draft and the appended quote at the final height. Thus, no field
accepts text before its target is known: a reply that arrives after the user
started to type would replace that text. A second entry while a resolve is
pending starts no other request. If no reply arrives in 5 s (`PalettePrompt.resolveTimeout`), the prompt
opens failed with "kido did not reply" and Retry. A palette close, a mode change, an owner close, a changed server
instance or a source pane that is gone cancels the pending open. A reply after
the cancel or the time limit does nothing. The chosen agent is the
preselected pane if it is a candidate, else the source pane itself if it is
a candidate (⌘O in an agent's own pane), else the first candidate in the
source pane's window, else the first candidate. A reply with no candidate (the
agent ended after the check) disables the picker, the field and Send, and the
picker reads "No agent in this window or session". A failed resolve shows its
message and Retry, which resolves again, with the same time limit, in the open
prompt.

The picker is an `NSControl` that pops up a native `NSMenu`: "This window"
with its agents, then "Session <name>" with the others and their window
names, the chosen one checked. A section with no agent shows a disabled "No
agents". A click or Space or Return on the focused picker opens the menu. Left
and Right with the menu closed choose the previous or next candidate. A
choice in the `invalid` state returns to ready.

Keys in the field go through the text view's `doCommandBy`: Return sends,
Shift-Return inserts a newline, Tab focuses the picker, Shift-Tab focuses
Send, and Escape closes the palette. Up and Down move the caret only. From the
picker, Shift-Tab returns to the field, Tab goes to Send (or the field when
Send is disabled) and Escape closes the palette. Tab from Send returns to the
field. An open menu handles its own keys, and Escape there closes only the
menu.

A send names the chosen target, and the source pane as its pane, or the
target itself when the source pane is gone. The text is the field's raw
markdown. Send is enabled for any text that is not blank, a quote alone
included. States:

- Sending: a spinner and "Sending to @name…". The field, the picker and Send
  are disabled.
- Delivered: the draft is removed, and the palette closes and restores the
  focus. Then, if the source pane still exists, its selection clears and copy
  mode exits.
- `refused` (`KO_ERR_REFUSED`): a red triangle, the core's message, and Retry, which sends again. An
  edit returns to ready.
- `unknown` (`KO_ERR_UNKNOWN`: the server reported an `io` failure, which
  can be a partial delivery, or the request was written and no answer
  came): the core's message with
  " It may have arrived; not resent." and Copy Prompt, which puts the composed
  text on the pasteboard. The field is read-only and muted: all its text,
markers included, is in the secondary label colour. Send is hidden, and
  the palette never sends again by itself. The draft stays.
- `invalid` (every other error, also no connection): the message in red.
  The picker stays enabled. An edit or another target returns to ready.

A late reply after the mode changed or the palette closed does nothing.
While Prompt mode is open, each owner snapshot checks the source. A changed
`server_instance` or a closed owner closes the palette as `.moved`. A source
pane that is in no sidebar row of its session sets "pane closed". When the
chosen agent is in the source window, the picker reads "in window <name> (pane
closed)" with the window name captured at open. In the ready state, the status
reads "Source pane closed; agents resolved earlier stay available."; the other
states keep their own status. The candidates stay, and the palette does not resolve again. A
send to a target that is gone fails as `invalid`.

**Drafts.** `AppDelegate.promptDrafts` holds one draft per target agent, in
memory only. The key is the host, the server instance and the agent's pane.
The value is the text. Thus, ⌘O from a pane, ⌘O in the agent's
own pane and root ⌘O on its row open the same draft. When the target becomes
known, from the resolve reply or a picker change, the field shows that
agent's draft with the caret at the end, and the foot adds "draft restored".
After the resolve reply only, this open's selection is appended to that text. Every close in Prompt mode, and the `unknown` state, stores
the field under the current target if its trimmed text is not empty, else
removes the key. A delivery removes it. A picker change from A to B stores the
field under A. If B has a draft, the field shows it. Else the field keeps its
text, A's key is removed, and the content belongs to B. Each owner
snapshot drops the drafts of that host whose instance differs or whose pane is
not in the snapshot, and an owner close drops its host's drafts. A pane
that stops being an agent for a while keeps its draft: pi clears its root
while it runs an external editor or is suspended.

While the palette is open, in every mode, no key reaches a pane. One
`OwnerWindow` check, the palette is closed or this window is key, guards each
place where a key enters a pane: the window's key delivery,
`PaneView.performKeyEquivalent`, a pane's menu validation, and the local
Command key-up monitor. Thus a main-menu item with a pane target, a Ghostty
binding or text input cannot act on a pane behind the palette.

The Edit menu has the standard nil-target text items (Undo, Redo, Cut, Copy,
Paste, Select All and the others that AppKit expects), so every text field in
the app, the prompt field included, gets the standard editing keys through the
responder chain. The prompt field supplies its own undo manager. A pane
answers Select All, Copy and Paste itself with Ghostty's `select_all`,
`copy_to_clipboard` and `paste_from_clipboard`. A pane offers a key whose
Ghostty binding is consumed, and neither `all` nor `performable`, to the main
menu first. Thus ⌘A, ⌘C and ⌘V with Ghostty's default bindings keep their
result, and the items also work from the menu. The items run these fixed
actions, not a binding that the user moved to another action
([known issue](known-issues-app.md#edit-items-can-take-a-custom-ghostty-binding)). A pane's validation
enables only these and the pane's own items.

Keys reach the panel first; no pane is in its responder chain. The panel's
`performKeyEquivalent` takes Command-P and Shift-Command-P (close),
Shift-Command-K (Connect) and Command-O (Prompt, in the root only) before the
field editor. With the palette closed, these keys keep their pane behaviour. Other Command keys go to the
main menu. The field's `control(_:textView:doCommandBy:)` handles the rest:
Up, Down, Control-P and Control-N move the selection with wraparound; Return
runs it; Escape returns from Connect, Rename or Runtime to the root and closes at
the root;
Backspace on an empty field in a mode returns to the root. Command-P has no
Ghostty default. From a pane, `PaneView.performKeyEquivalent` offers an
unbound Command key to the main menu, which is how Command-P reaches the
palette.

The field's accessibility label names the mode: "Command palette", "Connect
to remote host", "Rename session", "New session" or "Theme". In Prompt mode, the field is "Prompt",
the picker is a pop-up button "Send to @name", and the buttons are "Send
prompt", "Retry" and "Copy Prompt". Each row's label joins its title, detail
and shortcut, and adds the status as the tabs do (" — error", " — waiting",
" — running", " — done"). An error is announced at high priority. The panel's
subrole is a floating window.

New Session (Command-N) with no key window is described in
[Sidebar](#sidebar).

### Theme mode

Theme mode picks the terminal theme and shows it live. Its visuals are
`app/design/palette/` (NOTES.md "Theme mode"). The preview and the writer
are in [Panes](#panes). `PaletteTheme` reads the list once when the mode
opens:

- The bundled themes, in the fixed order of `ThemePaths.bundled`.
- Then the regular files of `~/.config/ko/themes` (the `themes` directory
  beside the config file), sorted with `localizedStandardCompare`. A name
  that is not a `ThemeName` of `ko_config` and the names of bundled
  themes are not listed; a symlink to a regular file is.

Every row is written by its name. Each row runs `ThemeFile.check` on its
file (Panes), which also gives the swatch: the background with "Aa" in
the foreground, and palette colours 4, 2, 1 and 3. The "light" or "dark"
tag is the background's luminance. The row shows the file name. "✓ Light"
and "✓ Dark" mark the rows that the loaded pair names. A file that is
missing or fails the check is a dimmed row with an empty swatch, no tag
and "theme file not found" or "invalid: <problem>" in red. It can be
selected and hovered; then the preview shows the theme that the config
sets now, not the broken file. Return and click on it do nothing. A
preview or a save checks the file again, so a file that disappears after
the list was read is dimmed then, and the save writes nothing. The marks
and the list are read once, when the mode opens; an external edit of the
config does not change them.

The mode's red status shows the config's error, if it has one. For a
theme of the pair that fails its check, it says "<name>: <problem>. The
current config names it for <Light|Dark>; Kido's default theme is shown
instead."

The selection starts on the theme of the current appearance, with no
preview. Each later selection change previews: Up/Down, a new query (its
row 0), and the pointer over the list. Hover does not move the selection;
leaving the list previews the selection again, and a scroll previews the row
now under the pointer. With no match, the last preview stays. The status
says "Previewing <name>. ↩ chooses where to use it, esc restores the current
theme." The preview is app-wide: every window and pane follow, whatever
copy mode, zoom or full screen they are in.

Return or a click on a row opens the save step. The head shows the theme as a
chip with its swatch, the field reads "Use for…" and takes no text, and three
radio rows follow: the current appearance (selected), the other one, Both,
and "This session only · not saved to config.yaml". Up/Down move the
radio. Return or a click writes, applies and closes. The session row writes
nothing and reads nothing: the theme becomes the session theme for both
appearances until quit or the next successful save, and its foot says
"applies until quit; <config path> is not changed".
Escape or ⌫ goes back to the list with the query, the selection and the
preview kept. The foot reads "writes theme: light: L, dark: D to <config path>",
with the merged pair that the save writes. Both writes the
one theme to both sides.

If the write fails, the list stays open with the red status "Could not write
<path>: <reason>. <name> is applied for this session only." and "Reveal in
Finder", which selects the config file or, if it is absent, its directory. The
theme becomes the session theme: a later preview is restored to it, not to
the file.

In the list, Escape, or ⌫ on an empty field, goes back to the root and
restores the theme. Tab and Shift-Tab do nothing in either step, and typing
does nothing in the save step. Command keys reach the menu as in the root.
Every other close path restores it too: Command-P, a click outside, another
window becoming key and the app's deactivation. The panel's `close` ends the
preview, so one place serves them all.

## Notifications

Kido.app posts a native notification when a pane starts waiting on the
user or fails out of sight, and withdraws it when the reason is gone. The
server reports status and outcomes and the core keeps the seen marks; the
app decides what deserves a banner. `SidebarFeed/Notifications.swift` is the
pure step; `App/Notifications.swift` holds the two posters and the
app-wide `Notifier`; `main.swift` installs the delegate and routes clicks.

**Eligibility.** A pane wants a notification when its lifecycle is Live,
it is not a run nested under another item (the parent agent gets the notice;
a run at the top level of the tree, even inside its window's group, has no
parent and notifies), and its core `mark` is waiting or failed. The reason
is the mark: a changed waiting kind does not repost, and a second failure
while the mark is still failed posts nothing. Done, finished runs,
successes, running, Ended rows and a command exit of 130 never notify.

**One notifier, entries per window.** Every `WindowOwner` has its own
entries, keyed by owner and pane; there is no primary window per host, and
two windows on one server may repeat a notification. Attendance is
shared: `shown` is the set of windows currently displayed by the
host's attended windows (app active, key, not miniaturized, visible).
Per entry the states are absent, posted(reason) and acknowledged(reason).
On every error-free snapshot of an owner, for each wanting pane:

- a baseline snapshot, a pane whose window is shown, or a reason
  that starts or changes while Kido.app is active, acknowledges it,
  withdrawing any earlier post: it is on screen, or the user is present
  and what starts meanwhile counts as noticed;
- otherwise a new or changed reason posts, replacing an earlier post;
- an unchanged reason does nothing, posted or acknowledged.

A pane that stops wanting (seen, new work, success, not waiting,
or gone from the snapshot) is withdrawn and forgotten. Error snapshots
produce nothing and keep the baseline pending. Closing a window withdraws
its entries; quit withdraws everything, so Notification Center never
offers a jump that cannot be honoured. Attendance changes (key, active,
miniaturize, occlusion) re-step the host.

**Baseline.** The first model of a connection in which every live pane
has a status, and the first after a changed `server_instance`, records
what wants a notification as acknowledged and posts nothing. The server
sets a pane's status on its first tick, so an earlier model would set the
baseline too early.

**Content.** Title is the sidebar row's title. Subtitle is the session
name; for a remote window `user@host · session`, using the resolved
identity the window title shows; for a `ko ssh` remote agent in a Local
window, `session · destination`. Body: `Waiting` or
`Waiting: <caption>`, else `Exit <code>: <command>` for a command, else
`Failed` or `Failed: <caption>`. Nothing is truncated by the app.
Identifier is owner and pane, so a repost replaces; thread identifier is
the host key; category `waiting` or `failed` supplies the hidden-preview
placeholders "Waiting for input" and "Failed"; sound is the default; the
click target (host, server instance, session, window, pane) travels as
JSON in `userInfo`. Linked panes take the client's session.

**Frontmost and badge.** `willPresent` returns no options: nothing is
shown while Kido.app is frontmost. The Dock badge, through
`setBadgeCount`, is the number of posted entries across all windows, set
after every step and cleared on quit.

**Click.** The delegate decodes the target and calls `route`, which
picks a live owner of that host: one whose snapshot has the same server
instance and contains the pane, preferring a client already in the
target session, then the key window; else any window of the host, key
first. It activates the app, deminiaturizes and orders the window front
(not in background builds), and performs the jump, a `ko_client_select`
that moves that window's client; the pane becomes active in an attended
window, is seen, and the notification withdraws on its own. With no
window for the host, the click opens it through `WindowRoutes.connect`
(Local as a new-window cause) and keeps a pending jump for 30s, consumed
by the first error-free snapshot of that host whose instance matches and
contains the pane, dropped on a mismatch or at the deadline. The delegate
is installed in `applicationWillFinishLaunching`, because a click that
launches the app reaches only a handler already in place.

**Authorization and builds.** Alert, sound and badge permission is
requested once, when the first owner connects, if still undetermined; a
denial and every posting failure are logged once and otherwise silent,
and there is no in-app toggle. `App/Notifications.swift` is the only file
that imports UserNotifications. Background, visual and stress builds use
`RecordedNotifications`, which records posts, withdrawals, badge counts
and authorization calls and never touches Notification Center.
`NotificationsTests` in SidebarFeed cover the step: attendance,
baselines, suppression and acknowledgement, reposts, every withdrawal,
exclusions, precedence and content; the hosted `NotificationTests` drive
two owners and `route` on a private ko server against the recording
poster.

## Testing

`app/Packages/PromptMarkdown/Package.resolved` pins only that package's graph,
for `swift test`. The project's graph, with SnapshotTesting and its
dependencies, has its own lock:
`app/Kido.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
It is the only tracked file in `app/Kido.xcodeproj`; `xcodegen` does not write
it, and `make clean` keeps it. XcodeGen 2.46 adds each local package as a folder
reference. Thus, without the project lock, `xcodebuild
-resolvePackageDependencies` writes the project's whole graph into
PromptMarkdown's lock. Xcode 27.1 rejects `-packageResolvedPath`. When a remote
package version in `project.yml` changes, the next build updates the project
lock. Commit the lock with that change.

`make visual` runs hosted SnapshotTesting tests against private ko
servers (`VisualTestCase.koServerDir()`, a `mkdtemp` directory under
`/tmp`, stopped and removed at teardown), never activating a window. Clipboard sheets use visible windows placed
far off screen, as do native-button local-mismatch tests;
the other fixtures keep their windows unordered. The default font (the
system's monospaced font at 13) and the built-in
light/dark themes isolate terminal-area image and compact layout references:
single panes at three heights, splits, floats, zoom, fractional history,
alternate screen and settled resize. The shared visual runtime's Ghostty
config is its own `$TMPDIR/kido-visual-PID.yaml`, removed in the class
teardown. `testYAMLSettingsRendering` records the system font, a font
family and size, a dark theme and a user theme of the test's own
`themes` directory; `testConfigErrorBanner` records the error strip in
light and dark. A test-only
`KIDO_VISUAL` build condition exposes an occlusion bypass through
`@testable`; normal builds retain their occlusion policy. Each image waits
for a tokened Ghostty presented-frame callback, not a timed delay. The fence
applies pending window layout first and retries a discarded frame at most
twice: the settle poll can end before a pane takes its new size, and Ghostty
discards the frame drawn at the old size. A refused request or backend failure
fails the test. Native fixture
windows use Display P3, matching the references rather than the attached
monitor's calibrated profile. The off-screen floating-sidebar fill takes its
rounded corners from the sidebar layer; the transparent corners show the
underlying window/terminal, not a cached opaque material rectangle.
Each visual target also launches a private, background copy and sends SIGTERM
to its main-dispatch handler, checking natural exit after asynchronous quit
completion.
Liquid Glass (sidebar and pane toolbar) and animation/scroll smoothness are
not covered. Re-record with `make visual RECORD=1` after intentional visual
changes, a macOS update or a different backing scale, and review the images
and layout diffs. References live in `app/VisualTests/__Snapshots__`.

`PaletteTests` records one image of the palette's content view for each
state of the approved mockup, `app/design/palette/` (`mockup.html` with its
`NOTES.md`), in light and dark: `palette.<theme>-<state>.png` for root,
filtered, match-run, filtered2, nomatch, connect, connect-typing,
connect-invalid, connect-none, new-session, new-session-error, rename,
rename-error, rename-error2, root-agent and nowindow; the prompt states
(prompt, prompt-typing, prompt-quote, prompt-markdown, prompt-twoquotes,
prompt-picker, prompt-draft, prompt-sending, prompt-refused,
prompt-unknown, prompt-invalid and prompt-paneclosed); and the theme states
(theme, theme-filtered, theme-preview, theme-save, theme-save-session,
theme-err-write and theme-err-file). The theme images are recorded last in the same test. Their
config lives in the visual scheme's private `HOME` (`XDG_CONFIG_HOME` is
`$HOME/.config`), so the paths read `~/.config/ko`; the test checks that
`HOME` is that private directory before it writes. theme-err-file removes the
built app's bundled theme file and restores its bytes in a `defer`.
`KoTests/GhosttyConfTests` checks the exact Ghostty string of every key,
that Ghostty reports no diagnostic on it, the theme resolution and
`ThemeFile.check` (the six bundled files pass, another key and a
diagnostic fail), and that `ko_config_load` refuses every key equivalent
of the app's menus, the window menu's Command-1 to Command-9 included,
as a key binding. The writer's cases are Rust tests of
`ko_config/src/theme.rs`.

`RuntimeTests.swift` records one image for each decided state of the
runtime mockup, `app/design/runtime/`, in light and dark:
`runtime.<theme>-<state>.png` for window, window-hover, zoomed,
label-find, starting, failed, float, colour-hash and colour-config
(the terminal area, against a private server), and rows, routed,
palette-root, palette-step, palette-step-failed, palette-step-host and
palette-step-nofocus (a model fixture). The mockup's alternatives
(stripe-2pt, label-left, label-tag, tui-stripe) are not the design and
have no image. The server's runtimes are `command` runtimes: the
Visual scheme sets `KO_RUNTIME_COMMAND_KIND=1`, and a test writes
`config.yaml` under `ko/` in the scheme's private `XDG_CONFIG_HOME` and
removes it at teardown. A runtime is held `Starting` by an `up` step
that reads a FIFO, and made to fail by an `up` step that exits 255. A
test never sets or unsets its own environment: `setenv` in the test
process races Ghostty's threads, which read `environ`, and crashed
the host in `ghostty_config_finalize`.

`RuntimeActionTests` in the same file runs the runtime step's rows,
the menu's splits and New Window against a private server and checks
each new pane's runtime and cwd. `KoTests/RuntimeTintTests` checks the
hash's hues against the mockup's and the hex parse.
`palette.light-window-root.png` records the card over a real two-pane window
at the mockup's 1100x740pt, with the panes' cursors hollow. The fixture
runs on a private ko server. It lays the window out completely before the
presented-frame fences, and it checks the pane frames against the layout: a layout pass
after the fences resizes the panes and the sidebar shadow after the captured
frames. The background
test app has the `.prohibited` activation policy, so AppKit does not make
the unordered panel key. The key tests therefore assert `canBecomeKey` and
the panel's field editor, not `isKeyWindow`. They send Command keys as real
events through the panel's `performKeyEquivalent`, the call that
`NSApplication` makes for a key window, and other keys through its
`sendEvent`.


`make ko-test` runs the `Ko` scheme (`app/KoTests/`): the client, view,
content bridge, layout editor, layout gesture, owner and owner-model
tests, each against its own private server in a `mktemp` directory under
`/tmp` that its teardown stops, also when the test fails. The make target
gives the host app a private `KIDO_APP_SERVER` and stops it afterwards.
Each test directory (`KoTestCase.stateDir`, `/tmp/ko-kp-*`) is listed in
`test-dirs` of that directory; its teardown waits for the app's launches
on the directory (`KoServer.finishLaunches`, a `KIDO_VISUAL` seam), stops
the server and only then removes the directory, because a launch that ends
after the stop leaves a server with no directory. After the suite,
`scripts/ko-test-leak-check.py` fails the target when a server of a listed
directory still runs. The incompatible server of the mismatch tests is
`ko-fake mismatch-server DIR` (`ko_e2e/fake/main.rs`), which answers `GET /version` without version headers with
another terminal revision and 409 `vt_mismatch` to every other request.
`make ko-fixtures` records, from a private server,
`SidebarFeedTests/Fixtures/ko-tree.json` and
`PaneGeometryTests/Fixtures/ko-layout.json`; the recorder tests skip
unless `KO_RECORD_FIXTURES` is set. Other tests build snapshots in Swift
(`SidebarFeedTests/Fixtures.swift`, `VisualTests/SidebarFixture.swift`).

`KoTests/RemoteTests.swift` connects remote owners over ssh only with
`KO_E2E_HOST_SSH=1` (`TEST_RUNNER_KO_E2E_HOST_SSH=1 make ko-test`), the
variable of ko's e2e; without it those tests skip, and with it a failed
ssh setup is a failure. The class starts one sshd on a loopback port
with its own host and client keys, `known_hosts` and an `-F` config
(the `testConfiguration` of `SSH`) whose aliases cover the cases; each test gets its
own remote home, state directory and ko server under `/tmp`. Only the
refused-forwarding case starts a second sshd. The
"remote" state directory and `ko` come from `SSH`'s test seam, which runs
each passenger under `/usr/bin/env` with a private `HOME`,
`XDG_STATE_HOME` and a `PATH` with the built `ko`; the master and its
helpers get a private local environment (`testLocalEnvironment`), so no
test uses the user's agent, `~/.ssh` or servers. The agent test runs a
private `ssh-agent` with a throwaway key and names it with
`IdentityAgent`: `IdentityAgent none` in the config would make forwarding
fail. macOS sshd puts the forwarded agent socket in the real
`~/.ssh/agent/` and removes it at disconnect; the test makes and removes
nothing there. The tests without ssh check the argv of the forward, the
helpers' agent policy, the relaunch, the remote mismatch wording and the
classifiers through the ABI.

`make rtt RTT_ARGS=...` builds the app with `KIDO_VISUAL` into
`derived-rtt` and runs `app/scripts/rtt.py`, the app's row of ko's RTT
table (kido-app-notes/k7-rtt-plan.md). With `KIDO_APP_TIMING=1`, which every
build honours, the app writes one JSON line to stderr for each attach step
from the start of the connect to the first layout, each view restore (bytes, first read, total) and each key
echo (from `ko_view_input` to the next bytes of that view). In VISUAL and
STRESS builds, `KIDO_APP_CONNECT=ALIAS` opens a remote window at launch,
`KIDO_APP_SSH_CONFIG` gives its master an `-F` config and
`KIDO_APP_RTT_REQUESTS` names a request file through which the script has
the app type keys. The script runs its own sshd, ko server and app state
under `/tmp`, with ko's delay proxy as the master's `ProxyCommand`, or
uses `--ssh-config` and `--host`; it refuses `localhost` without
`--allow-localhost`.

The Swift model types (`Packages/KoModel/Sources/KoModel/KoSchema.swift`)
are generated by `make ko-model` (`scripts/gen-ko-model.py`) from
`share/ko/openapi.json`, `share/ko/client-model.json` and
`share/ko/config-schema.json`, which `make schemas` writes from
`ko api-schema`. `scripts/lint.sh`
checks the schemas, and `KoSchemaTests` checks that the committed Swift
file is the generator's output. The generator refuses a schema shape that
it does not support. A struct with a bounded integer field (through its
`$ref`) gets an `init(from:)` that refuses a value out of the schema's
range with `DecodingError.dataCorrupted`; the typealiases stay `Int`.

The build phase "Build ko_client" runs `make -C $KO_CHECKOUT
ko-client-xcframework` (`KO_CHECKOUT` defaults to the repository root) and
links `-lko_client_private` from the `macos-arm64` slice. `bundle-ko.py`
puts `ko` and `ko-pane` with their `BUILD-ID` into `Resources/ko`. No make
target starts two builds at once; `make -j` with several targets would
race on `build/ko_client.xcframework`.

Test steps print one line per test case. Every build or test run that can
take more than 10 s runs under `quiet-limit 60`, which stops it after 60 s
without output. No app step needs a longer limit.

`make tsan` and `make asan` build Debug with ReleaseSafe GhosttyKit into
`build/xcode.noindex/derived-{tsan,asan}`. ASan defaults to `use_sigaltstack=0` because Zig
threads replace its alternate signal stack with thread-local storage.

The Main Thread Checker needs no rebuild: launch a Debug build with
`DYLD_INSERT_LIBRARIES=$DEVELOPER_DIR/usr/lib/libMainThreadChecker.dylib`
and `MTC_RESET_INSERT_LIBRARIES=1`, which keeps it out of the ko server
that `ko_client_launch` starts. Leaks are checked with `MallocStackLogging=1` and `leaks`,
`footprint` and `heap` on the pid, compared after attaching, after
switching past the surface budget, and after closing all but one window.

`KIDO_APP_SERVER` (a private 0700 directory) points a VISUAL or STRESS
build at a private server. `KIDO_APP_BACKGROUND=1`
keeps a test launch off screen: it never activates, never takes focus
and keeps no preferences. The launch sets the activation policy
`.prohibited`: macOS retries the deferred launch activation of an
`.accessory` app when a window comes to the front, and then every later
visibility check that reads `NSApp.isActive` fails. A cascade of such
failures means activation, not leaks. The opt-in `testVsyncMeasurement`
sets `.regular`, because it needs an unoccluded window. `KIDO_APP_DEBUG=1` logs each switch, eviction
and free to stderr with its timing.

### Test speed

The test-speed rules in AGENTS.md ("Tests") apply to the app's tests.
Each visual target runs one `xcodebuild test`, which builds the app, and then
`app/scripts/quit-check.py`:

- `make visual` runs every test. It is the pre-commit and release gate.
- `make visual-fast` skips the tests that `app/VisualTests/slow.txt` names,
  about 17 s of test time.
- `make visual-slow` runs only those tests.

`slow.txt` names one `Class/testName` per line, followed by
`# inherent: <reason>` or `# fix: <cause>`. An `inherent` test needs its cost
for its check: real ssh, a large history, real child processes, or a fixed
window that is the check. A `fix` test is known debt: a test change can make it
fast. A name whose class or test does not exist in `app/VisualTests/*.swift`
stops the target before `xcodebuild` runs.

An implementer runs `make test` and `make visual-fast` while it works. Before
the manager reports, the manager runs `make visual-slow` or `make visual`. An
implementer works on a slow test only when the manager reports that it fails.

A new test is fast by default: it is not in `slow.txt`. Write it to take less
than 0.5 s. It goes into `slow.txt` only as an `inherent` entry, when it is an
important check that cannot be made fast, and the manager approves the entry.

To profile the suite, read the per-test `durationInSeconds` of the newest
result bundle:

    xcrun xcresulttool get test-results tests --path \
      app/build/xcode.noindex/derived-visual/Logs/Test/Test-Visual-<timestamp>.xcresult

- A product deadline is not waited out. Under `KIDO_VISUAL`,
  `PaneView.pasteEventTimeout` (30 s), `PaneView.clipboardTimeout` (8 s),
  `PaneView.copyEntryTimeout` (2 s), `PaneScroller.fadeDelay` (1 s),
  `WindowOwner.welcomeTimeout` (20 s), `PalettePrompt.resolveTimeout` (5 s),
  `Upload.promiseTimeout` (30 s) and `WindowView.toolbarFadeDuration` (0.15 s)
  are settable. Production builds keep them constant.
  A test sets a short value only around the step that tests expiry, and waits
  for the expiry event.
- `wait` polls its predicate every 2 ms. Where the product can signal the
  event, a test waits for a `KIDO_VISUAL` probe instead of a fixed time.
  `PaneToolbar.visualAnimationsEnded` counts finished toolbar fades.
  `Upload.visualImagePreparation` holds image preparation at its start.
  `WindowOwner.visualPreparedUploads` counts upload preparations that ended,
  whatever the outcome.
- `drain` ticks Ghostty and fences the main queue. It ends after three rounds
  with no new `GhosttyRuntime.visualWakeups`, not after a fixed time.
  It does not wait for server replies or child processes, so it is not a quiet
  window: an absence check uses a fixed, bounded wait.
  `RendererTests` keeps its own fixed 200 ms `drainAnimation`, because its
  idle-CPU windows depend on that settle.
- A fixed wait remains only where it is the check ("never activates", quiet
  windows) or where no event exists.

### Stress harness

`make stress SEED=N DURATION=S [FIND=0]` builds the app with the
`KIDO_STRESS` compilation condition into `build/xcode.noindex/derived-stress`
and runs it for S seconds against a private ko server; `make tsan-stress`
and `make asan-stress` do the same with the sanitizers (own derived dirs).
The condition is set only by these targets: `App/Stress.swift` holds only a
typealias in every other build and `main.swift` has one `#if KIDO_STRESS`
call site.

`scripts/stress.py` (stdlib Python) starts `ko server` in a private
directory and puts a demo-like layout with `ko api`: four sessions of
windows with three panes, including 1M- and 100k-line history panes and a
float. Every 0.4 s it applies a server
action chosen from `SEED`: a client select, layout edits (split, zoom, add
or move a float, add or drop a session, add a window, rename, swap
windows) with `ko layout edit`; pane and window deletes; text input; `clear_history`; `ko run`
in a pane; and server restarts at 40% and 80%. The stress build logs the
client id of each welcome, and the script reads it from the app's stderr
log to select for the app's client. Stress also resizes while a window is
hidden (`hidden-resize`). In the app `Stress` does the same on the main
queue, also seeded: wheel, scroller drags, scroll requests, find and next,
window resize bursts, pane grip drags (some deleted mid-drag), edge
resizes, layout edits through the `LayoutEditor`, appearance, tabs and
sidebar jumps. After a sidebar jump it waits up to 5 s until the model
selects the row's pane (`jump-selects`). It writes one JSON line per action
to stderr (`build/bundle/stress/<target>-<seed>/stderr.log`; `actions.jsonl`
is the server side; `summary.json` the counts). `FIND=0` swaps the find actions
for scroll requests. A run fails, exits 1 and prints its replay command on
a sanitizer report, panic, non-zero exit, an app that did not finish, a new
`Kido*.ips`, a UI action that was never delivered, or a step that saw the
window visible, key, main or active. A seed is a best-effort reproduction:
choices also depend on the observed topology, and timing against live
output is not reproducible.

Off-screen rule: the window is never ordered in (`KIDO_APP_BACKGROUND=1`),
is a `StressWindow` that refuses key and main, and input is only
`NSWindow.sendEvent` with `NSEvent.mouseEvent`/`keyEvent` or a direct call.
App-local `NSApp.postEvent` queuing is allowed and needed by button tracking;
system-wide or pid-targeted CGEvent posting is forbidden. Nothing activates.
Every step logs `visible`, `key`, `main`, `active` and the number of this
process's windows in the on-screen window list. Wheel events do not reach a
view through `sendEvent` off screen, so the wheel action calls
`PaneView.scrollWheel` with an NSEvent made from a scroll CGEvent. Grip actions
expose the chosen chrome's toolbar through `mouseMoved`, then invoke that
enabled grip's existing `press` closure for down, drag, up and Escape.
Scroller drags and floating edge resizes call their own mouse entry points:
off-screen `sendEvent` does not reliably reach them. This covers the drag
logic, not AppKit event delivery or hover.
Set `KIDO_MTC_VERIFY=1` with `DEVELOPER_DIR` for Main Thread Checker: the runner
injects it only into Kido and verifies its mapped image in that PID. Injecting
it into the Python launcher with `MTC_RESET_INSERT_LIBRARIES=1` removes the
injection variable before Kido starts, so does not check Kido.

`scripts/quit-check.py` starts a private ko server with one pane, launches
the visual app off screen with `KIDO_APP_QUIT_VERIFY=1`, sends SIGTERM and
expects exit 0 within 8 s with `quit drain completed, children=[]`.

To cover a new feature, add a case to `Stress.Action` and its weighted array,
and an exhaustive branch in `Stress.perform` driving existing internal API; add
server actions in `scripts/stress.py` if the feature reacts to server state.
