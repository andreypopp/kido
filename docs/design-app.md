# Kido.app

Open gaps and accepted limits are tracked in [Known issues](known-issues-app.md).

Kido.app (`app/`) is a native macOS view of the kido server: a tmux
control-mode client that renders every pane with libghostty, beside a
native sidebar fed by `kido rpc`. Sessions, windows and panes
live in tmux; the app holds none of them. tmux is always the source of
truth for pane content, including history and its line wrapping, and
for geometry. Ghostty's reflow during a resize is provisional, replaced
by a tmux capture once the gesture ends. The app never retains
Ghostty-derived content that disagrees with tmux. Purely client/UI state
(scroll position, selection, find, sidebar UI, gestures, fonts and themes)
belongs to Kido.app, not tmux.

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
Recording stable across upgrades, unlike an ad-hoc cdhash requirement. Expect
one last permission re-grant after installing the first team-signed release.
Team signing also supplies the TeamIdentifier required by Shortcuts/App Intents.
Renew the Apple Development certificate in Xcode roughly yearly, retaining the
same Personal Team. Rebuild and check the designated requirement after renewal;
a team or signing-identity change can require another TCC grant.

Hardened runtime is disabled and no entitlements are added: notarization is not
part of this release path, and enabling runtime/JIT or library-validation
restrictions would need separate GhosttyKit and bundled-helper validation.
Personal Team signing is not Developer ID signing or notarization. Gatekeeper
can still reject quarantined downloads; the cask retains its quarantine-removal
instructions. Debug, test, visual and stress builds stay ad-hoc. Demo builds
explicitly stay ad-hoc even in Release; direct `all CONFIG=Release` builds use
the same team signing as the release script.

## One control client

Each native window attaches one control client (`kido-tmux -u -S <socket>
-N -T hyperlinks -C attach-session -f pause-after=N,new-layouts,no-detach-on-destroy`)
and behaves like a normal client: all sidebar and tab navigation and shell
creation use correlated `kido rpc` requests, and the app follows tmux's
notifications. The control client owns terminal I/O and pane mechanics. So the client's current session, window and pane are
always the ones shown, which kido's `watched`, done-until-visited and
reaping rules depend on. A client per session would mark every session
attached. When its session is destroyed, `no-detach-on-destroy` moves
the client to another session where `detach-on-destroy` would detach
it, and the app follows as it follows any switch.

`-N` keeps a redial from starting a server behind the user's back: a
server is started only by `kido server --server DIR`, on explicit connection
or the banner's Start button.
The directory is `$XDG_STATE_HOME/kido-app`, else `~/.local/state/kido-app`;
the JSON endpoint supplies its `DIR/socket` path. Helpers never set
`KIDO_STATE_DIR`: panes resolve the server directory from `$TMUX`. A
`%exit detached ...` is a deliberate detach and is not redialed; any
other ending is. A reconnect is a full reset, since ids mean something
only to the server that issued them. Every connection close, redial
and quit is one line on stderr, with its reason or trigger.
Build identity is checked only at discovery and explicit restart; automatic
redial only re-attaches, so a different kido manually started in that directory
is rejected at the next discovery.

## Remote hosts

On macOS Tahoe, the Shortcuts action **Connect to Remote Host in Kido**
has a required Host string in its parameter summary. It works only in
team-signed builds: Linkd rejects ad-hoc bundles with `requiresValidatedBundle`.
Spotlight does not list the action directly. The cold-launch gate passed on
screen through Shortcuts with a team-signed build.

The unsigned alternative is `kido-app://<host>`: in Shortcuts use
**Ask for Input** with prompt **Host**, then **Open URLs** with
`kido-app://<Provided Input>`. It needs no signing. The percent-decoded
authority is the SSH destination: `kido-app://localhost` or
`kido-app://user@myhost`. An empty path or `/` connects to the default
session; non-empty paths are reserved for future session selection and rejected
for now. Ports, passwords, queries, fragments, empty hosts, whitespace,
controls, SSH options and shell syntax are rejected with one stderr line.
URL delivery and the App Intent share Host validation and window routing. Each request
creates a new native window, including repeated requests for one alias.
Host is trimmed and accepts an SSH alias or user@hostname, not options,
whitespace, controls or shell syntax. Ports and jump hosts belong in SSH
config. File → **Connect to Remote Host…** (Shift-Command-K) opens the
[command palette](#command-palette) in its Connect mode. The mode uses the same
remote routing as URLs and the App Intent. The cold
remote-launch gate still holds Local requests back. Dock reopen still focuses
existing windows; with no window it opens a Local window. The app opts out of
automatic termination at launch: AppKit marks a windowless app as terminated
by the transparent app lifecycle (TAL), and a Dock reopen then does not reach
the process. The recent list lives in preferences (`recentHosts`) and is
refreshed by every remote path, palette, URL or intent alike. There is no
remote restore. Off-screen FileMenuTests create inert window owners without
starting a server.
Local keeps `SessionModel.title` (session and current window); remote prefixes
it with resolved `user@host / `. The original dialing alias is the window
content's tooltip. Offline titles drop the session/window name.

`AppDelegate` owns shared Ghostty configuration, app lifecycle and menus.
Each `WindowOwner` owns its immutable Host, generation, transport, Connection,
Feed, model and SessionView/surface cache. Main menu actions target the key
owner; source-pane actions stay with that pane's owner. Configuration changes
broadcast to live owners. Late discovery, command, feed and control callbacks
check liveness/generation; dead-master callbacks cannot publish channel results.
Surface disposal cancels find/gestures, denies pending paste exactly once,
rejects deferred actions/input, and retains parser-quiescent main-thread freeing.
Closing a native window stops only its channels/master, never a pane or a
remote session, so it never asks for confirmation; reopening redials. Closed
owners stay retained until their transport cleanup completes; quit replies
after asynchronous process-reaping completion, including retiring transports.
The terminate-later reply is a common-mode main RunLoop block, not a main
DispatchQueue block: AppKit's nested termination event loop cannot re-enter a
main-dispatch callback that called terminate. A bounded off-screen quit probe
reproduced that wait in `NSApplication._shouldTerminate` before the reply fix.
Closing the last window leaves the app available for another intent.

Launch bootstrap initializes shared resources and drains queued Host requests;
it does not open Local. Ordinary AppKit untitled/reopen delivery opens Local
only when no live window exists; reopening with a live window focuses it.
There is no timer, debounce or compensating close of a Local window. Off-screen
routing tests prove queued cold and warm behavior. The launch gate requires
`launchIsDefaultUserInfoKey == true` and an initial `oapp` (if available);
non-default launches discard queued Local requests and suppress ordinary-open
until the requested remote arrives. Apple's
[launch key](https://developer.apple.com/documentation/appkit/nsapplication/launchisdefaultuserinfokey)
defines non-default launches as false. URL launch is a non-default `GURL`
request, handled by
[application(_:open:)](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/application(_:open:)).
This uses the same gate without timers, whether URL delivery precedes or
follows launch completion. Actual URL-launch notification/event ordering is
not measured by off-screen routing tests; the user retests it on screen.

### Transport and discovery

System `/usr/bin/ssh` supplies one retained foreground `-M -N -T` master per
native remote window. Its unique `/tmp/ka-…/c` ControlPath directory is 0700.
Bounded `-O check` readiness precedes discovery. BatchMode, strict pretrusted
host keys, ConnectTimeout=10, one attempt and keepalive=15×3 apply to all
channels. X11/inherited port forwarding, tty, RemoteCommand, ControlPersist,
fork-after-authentication, null stdin, LocalCommand, SendEnv and host-key
updates are disabled. User/account/port/identity/ProxyJump and configured
known_hosts remain OpenSSH's responsibility. The master and control session
honor per-host ForwardAgent from the user's SSH config, including socket paths
and IdentityAgent selection; helpers force forwarding off and scrub incoming
remote SSH_AUTH_SOCK. Authentication/trust failures stop automatic setup and
ask the user to establish trust/unlock keys with ordinary ssh in Terminal.
No passwords, credentials, interactive shell sourcing or automatic installation.

Remote servers start with SSH_AUTH_SOCK pointing to their state directory's
stable `agent.sock`. Before attaching, the control session validates that directory
as user-owned and 0700, atomically publishes a symlink to its forwarded socket
when available, and supplies the stable path to both tmux's global environment
and the attaching client. Across windows and Macs, the last successful publication
wins; an attach without forwarding leaves the link alone, and a dead winner
leaves a dangling link with no fallback.

Discovery runs a fixed `/bin/sh` probe remotely: absolute `command -v kido`
and `${XDG_STATE_HOME:-$HOME/.local/state}/kido-app`. Missing kido gives an
install/noninteractive-PATH banner; there are no guessed installation locations.
Relative/control-containing paths or noisy/malformed stdout are errors. Explicit
Connect may call that kido's `server --server DIR`; JSON tmux/socket paths are
opaque remote values, not local files. The returned socket must end in `/socket`;
its parent is retained for feed/navigation. Local retains bundled-tmux validation.
Discovery requires the binary's RPC protocol to be exactly 6.0, as does
RPC hello; both major and minor must match. Server compatibility is separate:
the opaque server stamp must equal the expected stamp from the same binary's
discovery JSON. A null stamp is incompatible. The app has no stamp constant.
Mismatches block the affected window with a native alert sheet; Close leaves
a disconnected, read-only view with Reconnect to check again. For every local mismatch, the sheet includes the warning
that sessions, panes, commands and agents end and other clients disconnect.
Its destructive Restart acts immediately; Close is the default and Escape action.
There is no second confirmation or Cancel-back flow. Newer-local title and guidance
are retained with the same destructive Restart/Close controls. A successful local restart notifies owners on the same socket:
their mismatch sheets close and they repeat discovery and connect to the new server,
without another user action. Restart failures remain banners.
Remote sheets offer Reconnect, advise updating the app for a newer major or minor,
and read discovery's binary protocol before recommending an upgrade: an
already-compatible binary only needs its server restarted when its stamp
differs. RPC hello retains the binary protocol and server/expected stamps for
later mismatches. Stamp mismatch copy describes a different build or config;
protocol mismatch copy names the required and actual RPC versions. No server is restarted automatically.
Reconnect repeats discovery after the user fixes the mismatch.
There is no compatibility waiver or remote restart. The bundle's captured
BUILD-ID detects an app replaced on disk and requires relaunch independently
of the server stamp and RPC protocol.

Control attach and duplex RPC (including switch-window and switch-session) share the owned master,
with `ControlMaster=no`. One audited POSIX single-quote function quotes every
remote argv element after `exec`; Host is never interpolated into shell text.
Remote HOME/PATH/XDG are resolved there, not forwarded from the Mac. Only
VISUAL/STRESS test injection supplies private remote HOME/XDG/PATH. The tested
login shell is zsh; the fixed probe uses /bin/sh. Protocol stdout and bounded
16KiB stderr are separate. One-shots have deadlines and cancellation; channels
terminate then escalate to SIGKILL rather than relying on stdin EOF. Channels
are stopped before the master (1.5s grace), which is reaped before removing
its private directory. Initial topology plus a valid v2 feed snapshot must
arrive within 20s of attach to dismiss the connection banner.

Unexpected control loss redials with capped backoff and a full surface/model
reset. It recreates the master and attaches the **remembered** socket using
`-N`, never running start-capable discovery. A missing server leaves the explicit
**Start remote server** action. Deliberate `%exit detached` stays down. Feed-only
failure restarts the feed on healthy control; master loss invalidates both and
cancels commands together. OpenSSH can fall back to a direct connection after
a master dies: launches refuse a known-dead/stopped master, and the owner rejects
old-generation/dead-master completions rather than accepting fallback as recovery.

Two native windows on the same server/session share tmux's current window and
pane grid, sized by its latest elected client. This coupling is accepted; there
are no grouped sessions. Models, client names, feeds, surface caches, find and
scroll state remain disjoint even when both endpoints issue `$0/@0/%0`.
Authoritative external layouts are clipped, not resized into independent grids.
OSC 8 links from local panes and all links from remote panes share one app
handler: HTTP/HTTPS opens on the Mac through NSWorkspace; file paths and other
schemes are refused with the same diagnostic and alert. Local non-OSC 8 links,
including regex-detected URLs, retain Ghostty's own OS opener and scheme policy.
Ghostty's fallback OSC 8 safety guard stays enabled but is not reached. Both
control transports advertise hyperlinks with `-T hyperlinks`, so tmux preserves
OSC 8 links. No implicit port forwarding/file transfer.
Mac clipboard/paste and unsafe-paste sheets remain local. OSC 52 uses the same
raw control output and pane-input path over SSH; the wider remote/auth/URL
matrix remains in known issues.

### Prepared localhost and manual entry-point check

The user may add this **only for noninteractive SSH** to `~/.zshenv` (no startup
stdout); it does not shadow Homebrew kido in ordinary terminals or interactive SSH:

```zsh
if [[ -n ${SSH_CONNECTION-} && ! -o interactive ]]; then
  path=("$HOME/Workspace/kido-app/app/build/xcode.noindex/derived-remote/Build/Products/Release/Kido.app/Contents/Resources/kido/bin" $path)
fi
```

Check `ssh -T -o BatchMode=yes -o StrictHostKeyChecking=yes localhost
'command -v kido; kido --version'`. Keep the bundle's bin directory together so
its kido finds its matching sibling fork/resources. The app connects to the
account's kido-app server, not the normal Homebrew kido server. Tests do not
change startup/SSH files and always inject private `/tmp` HOME/XDG and explicit
server/socket paths over localhost.

Before shipping, the user/parent must prepare a **distinct app identity**, not
register the default derived Kido.app over the running installed app:

```sh
make -C app all CONFIG=Release DERIVED=build/xcode.noindex/derived-remote XCODE_SETTINGS='PRODUCT_BUNDLE_IDENTIFIER=com.andreypopp.kido.remote-test INFOPLIST_KEY_CFBundleDisplayName=KidoRemoteTest'
```

The output is `app/build/xcode.noindex/derived-remote/Build/Products/Release/Kido.app`,
displayed as KidoRemoteTest. Xcode defaults live under `app/build/xcode.noindex/`
to keep built apps out of Spotlight; private builds should use
`DERIVED=build/xcode.noindex/derived-<name>`. Explicit DERIVED paths are honored.
Non-app caches such as GhosttyKit remain outside that directory.
Check its Metadata.appintents and `codesign --verify --deep --strict` before
registration; use a clean build if an incremental metadata addition invalidates
the signature. Register only that absolute bundle path with
`/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f`.
A distinct bundle ID isolates **app routing, not server state**: these user-driven
checks attach the account's real kido-app server. They require deliberate user
approval for that attachment, must never Restart/kill it, and are not agent-run
private-state tests. Shell-exported HOME/XDG around lsregister does not prove
Spotlight inherits them.

Quit only KidoRemoteTest, then run a saved Shortcuts workflow containing that
team-signed test app's **Connect to Remote Host in Kido** action and Host=localhost.
Stop if the action's identity is ambiguous. Verify exactly one remote native
window and **no Local window** on cold launch. Repeat while running: another
remote window must appear, not replace the first. This cold-launch check passed
on screen; Spotlight does not list the action directly. Also retest the URL
recipe above cold and warm; it works with ad-hoc builds too.
Separately quit only the test app and plain-open it with
`open -b com.andreypopp.kido.remote-test`: one Local window must appear. Warm
intent delivery then adds remote without replacing Local; reopening with a live
remote window must not create Local. Finally quit only the test app, unregister
only its absolute bundle path with lsregister `-u`, and remove only the user's
test workflow. If URL ordering fails, record the lifecycle. OS-delivery steps
are user-run, never part of the off-screen implementation checks.

## Panes

A pane is drawn by a Ghostty surface in manual-IO mode
(`MANUAL_MIRROR`): `%output` is fed in, typed bytes come back out as
`send-keys -H`, and the emulator's own query replies are suppressed
because tmux answers them. tmux prefix bindings therefore do not fire
from the app; its menus and Ghostty's split and tab actions stand in.

Ghostty's configuration is `kido-app.conf` beside `kido.conf`
(`$XDG_CONFIG_HOME/kido/`, else `~/.config/kido/`), in Ghostty's syntax,
and Ghostty's own config files are not read; `config-file =
~/.config/ghostty/config` there shares them. It is read over built-in
light and dark themes that follow the macOS appearance and switch live
on existing panes. The file overrides these defaults, including the
theme, background and non-blinking cursor. The window and pane chrome
follow the effective Ghostty background and its light or dark
appearance. Colours derived from the theme stay in `GhosttyRuntime`.
Every other chrome colour, alpha and shadow is a named role in
`app/App/Chrome.swift`: system colours, the macOS accent, fixed values,
and the constants that are mixed with theme colours. A role is named for
its use, not for its value, so two roles can have the same value.
`app/scripts/lint-colors.sh` runs first in `make test`. It refuses colour
constructors, system colour names, `withAlphaComponent` and literal
shadow values in `app/App` and `app/Packages/*/Sources` outside
`Chrome.swift`. A line with a trailing `// chrome-allow: <reason>` is
exempt; the theme derivations in `GhosttyRuntime` use this marker.
`app/VisualTests` is not checked. The `PromptMarkdown` package cannot
import the app, so the prompt view passes it its three ink roles.

The defaults are `theme = light:kido-light,dark:kido-dark`, by bare name.
`main.swift` sets `GHOSTTY_RESOURCES_DIR` to the bundle's `ghostty` folder
before Ghostty starts, and Ghostty searches a bare theme name in
`$XDG_CONFIG_HOME/ghostty/themes` (else `~/.config/ghostty/themes`), then in
`<resources dir>/themes`. Thus, a name in the user's file still resolves
after the app moves or in a dev build. Spawned tmux and shells inherit the
variable; Ghostty never starts a shell in Kido, so it has no effect there.
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
quit. `loadConfig` keeps Ghostty's diagnostics, and
the mode reads them to dim a theme file that fails after it was listed.

`app/App/ThemeConf.swift` reads and writes only the `theme` line of
`kido-app.conf` itself. It does not walk `config-file` includes, and an
include that sets `theme` wins in Ghostty without the picker knowing. The
last line whose trimmed key is `theme` counts. Its value is a pair if it
contains `,`, `:` or `=`, as in Ghostty, else one name for both sides. A pair
needs both `light:` and `dark:`; Ghostty rejects a line without them and keeps
the value before it, and so does the parse. With no valid line, the pair is
the defaults. A save merges the chosen side into
that pair and always writes `theme = light:L,dark:D`. It replaces the line
or appends one, and keeps every other byte, CRLF included. It writes
`<target>.tmp-<pid>` beside the target with the target's mode (0600 for a
new file), syncs it and renames it over the target. The target is the
conf's resolved path, so a symlinked conf keeps its link; a dangling link
writes its target. A missing directory is created with mode 0700. If the
merged pair equals the file's pair, nothing is written. The watcher sees the
rename and reloads; the override is cleared before, so the reload shows the
written theme with no flash.

The built-in defaults unbind Ghostty's `super+k`. The app has no Clear
command, and Ghostty binds Command-K to `clear_screen` by default. That
action clears only the Ghostty surface. Under `MANUAL_MIRROR` the surface
then no longer agrees with tmux's grid, so the key does nothing.

The sidebar list's background is a shade of the terminal background.
The shade mixes the terminal background toward black on a light
terminal background and toward white on a dark one, with the same light
or dark decision as the window appearance. The default is 5%.
Thus the default follows each reload and each live theme switch.
`kido-sidebar-shade = <percent>` is the app's own key
in that file. Ghostty does not know it, and its unknown-field
diagnostic is hidden only for the app's two keys, this one and
`kido-unfocused-background-shift`. The value is a decimal number from -100
to 100 (digits, an optional leading `-` and an optional fraction), with or
without `%` and optionally in double quotes. The app uses its absolute
value, and the theme gives the direction. The mix is per sRGB component (as CSS
`color-mix(in srgb, ...)`).
`NSColor.blended` is not used: it mixes in generic RGB and gives a
different colour. An absent key and an empty value (`kido-sidebar-shade =`,
Ghostty's reset syntax) give the default. An invalid value gives a note
on stderr and the default. AppKit's sidebar glass is not shown. The
app reads the key from the same files as Ghostty: the main file, then
its `config-file` includes in Ghostty's breadth-first order, with
relative paths, `~/`, optional `?` paths and cycles resolved as Ghostty
resolves them. The last value wins.

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
gives the built-in defaults. If the directory does not exist, the app
watches the nearest existing ancestor until the directory appears. If
the file is a symlink, the app also watches the directory of its
target. A change to another file in a watched directory does not cause
a reload. A burst of events gives one reload. Each reload reads the included files
again, but the app does not watch them: a change to an include has no
automatic reload. Ghostty's reload action for the app also reads the
file and its includes again.

Launch and reload build the config in the same way, and a reload prints
its diagnostics to stderr as at launch. If Ghostty's part of the config
is different, a reload applies the new config to each live pane inside
`PaneView.reflow`, so that a font change
resizes the pane and its tmux grid. A change to only the shade does not
reflow the panes, so it does not end copy mode or resync a pane. The
app gets the config without surface propagation. `PaneView.reflow` can
delay its change while a pane replays, so the delayed change reads the
current config of the app. The chrome of every window then follows the new
background and appearance.

tmux has one grid, so every pane has one font size. ⌘+, ⌘− and ⌘0 change
it on one surface, and `SessionView.fontChanged` gives that size to every
pane with Ghostty's `set_font_size:` action. Ghostty keeps a size set in
this way when the config reloads. Thus a reload that changes `font-size`
gives the new value to every pane of every window, hidden panes included,
after the pane gets the new config. The runtime compares the new
`font-size` with the one that it loaded last. A new pane starts at the
current size with the same action, so Ghostty also keeps its size. Thus a
reload that does not change `font-size` keeps one adjusted size in all
panes.

A pane is synced by one command line: its captures, pending parser
bytes and mode state. tmux queues `%output` ahead of the reply, so
output before the reply is wiped by the restore and output after it is
fed live. The same resync follows a `%pause`.

Every restore captures the newest 10,000 physical history rows plus
screen, pending parser bytes and mode state in one command batch, then
resets and replays the surface. Initial sync, reconnect, resize and showing
a content-dirty pane share that path. History uses styled `-e -J` and
plain `-F -L -T -N` companions; a plain screen companion joins the same
logical rows across the history/screen seam. The oldest partial logical
line is omitted. A line spanning the entire interval is omitted rather
than expanding the restore. Extra history loaded earlier is deliberately
dropped.

Wheel and thumb cover only Ghostty's retained rows. They never capture
history or expose unloaded blank space. One native Load more pill appears
near the loaded top when tmux has older rows. A click loads the next
10,000-row chunk, aligned to whole logical lines, through the shared
loader. Explicit loads can expand a chunk for a long line, bounded by
tmux's total. Empty or malformed captures stop without pretending to be
memory pressure. A refused nonempty insertion leaves the same pill;
another click raises that surface's byte budget and retries. Refusal
survives metadata refreshes. There is no idle trim.

`ghostty_surface_prepend_history` snapshots the primary grid and page
identity under the renderer mutex, parses a scratch terminal outside it,
then validates and clones the pages under the mutex. Existing pins and
selections stay attached to their content. The chunk is accepted whole
or not at all, without evicting newer rows. Kido defaults to a 512 MiB
scrollback budget; configuration can override it. Raised limits survive
appearance/config updates but not surface destruction or reconnect.
Ghostty's normal byte-budget eviction and the app's surface LRU remain.

Connection keeps tmux's sampled history total separate from retained
Ghostty rows. Output invalidates metadata/exhaustion but never loads
older history. Restore/load/search requests read metadata; wheel and
scroller requests reaching the loaded top also refresh it without loading
history. Hidden panes refresh on show. There is no history timer, and
renderer notifications do not query tmux. A fresh shrink/clear invalidates navigation and repairs content
through the common restore, joining an active gesture's final repair.
tmux has no universal history-content generation: arbitrary same-sized
external replacement between samples is not immediately observable.

A resize captures the viewport's logical count and text once at its first
intent. Intermediate accepted grids are installed and confirmed inline;
Ghostty's local reflow is provisional. Capture waits for gesture end and
the final client-size or floating-command/layout drain. A newer gesture
invalidates an in-flight snapshot even if its dimensions end unchanged.
There is at most one snapshot in flight and one coalesced successor;
already-sent obsolete transactions drain without publishing. Move-only
or unchanged-cell gestures need no new content capture unless a prior
restore obligation or content invalidation remains.

The anchor resolves only inside that snapshot, with nearest matching text
within ±32 logical lines, ties toward newer rows, and an in-range count
fallback. An anchor outside the capture or actual budget-shortened
retention goes to the live bottom. It never pages or clamps to the oldest
loaded row. Scrolling, typing, paste and find cancel the old viewport
intent without canceling required content repair.

Retained hidden panes install accepted grid changes too, so subsequent
output is parsed at tmux's width. Dirty epochs survive A→B→A and equal
dimensions; only a current authoritative restore clears them. Showing a
dirty pane repairs it. Possible font/scale/config reflow follows the same
invalidation and confirmed-grid path; color-only changes remain local.

Each pane draws one thin overlay scroller, shown during scrolling or
hovering and fading afterwards. The scroller track spans the expanded content while its thumb and targets count whole grid rows. Ghostty's own scrollbar is disabled. The
thumb uses the loaded history rows plus the screen, with a native-style
minimum knob size. The knob is one CALayer: a step moves it, and the scroller
never redraws a backing store. A hidden or faded scroller, or one in an
invisible window, does not move the knob, because each move commits a CA
transaction; a reveal or unhide moves it to the current geometry. Its colour resolves from the effective
appearance when the appearance changes, when it is shown and on hover or drag.
A reveal moves one fade deadline 1 s ahead. A burst arms one main-queue timer,
which re-arms only if the deadline moved, and then fades over 0.3 s.
Ghostty's SCROLLBAR action refreshes the scroller only while the app owns no
scroll target; while it owns one, the worker's applies publish the geometry.
Every precise wheel event adds its delta 1:1 to the
fractional target, including nonzero ended packets. At most one apply is
pending on the pane's serial scroll worker; it starts immediately and reads
the latest output-adjusted target when it runs. Its main callback coalesces
presentation, then applies a changed target.
Ghostty schedules rendering; a per-pane NSView CADisplayLink is created on the
first pacing demand while the view can receive ticks. When demand ends or the
view becomes unavailable, the link is paused, not invalidated, and the next
demand resumes it. Disposal invalidates it. Each main-thread
tick only notifies the renderer's draw async; token presentation remains immediate.
The app adds no deferred packet, easing or momentum filter.
Ghostty's mouse-scroll-multiplier precision setting remains the user's speed
override; precision 2 restores the previous speed. Discrete wheel notches
are unchanged. An active selection gesture uses integral wheel steps.
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
Capture publication
updates loaded geometry and requests presentation, never moving the viewport
itself; unchanged geometry and memory-limit state do not request another
apply. Snapshot replay invalidates applied viewport revisions at both its
start and end, then asynchronously reapplies the latest preserved target even
when capture metadata is unchanged. Replay cannot complete a final render;
revision validation and acknowledgement commit share the scroll-intent lock.
Main snaps and resets stamp the revision captured before their apply, so replay
cannot make an older apply appear current. Replay never enters live-output
pin-delta accounting.
Live output shares the serial worker and pins a scrolled viewport,
adjusting its distance from the bottom; a zero target follows the bottom.
Hidden and occluded panes retain their renderer rules and do no idle
scrolling work.
`KIDO_APP_DEBUG=1` logs wheel timestamps, phases and deltas, and each applied
target's row and fractional pixel offset.
The thumb's range and size use loaded geometry. Colours resolve in the current
effective appearance when drawn.

Command-F opens a pane's native find bar. Each query scans tmux's history
and screen in 5000-row, whole-logical-line chunks on a worker queue,
retaining only match distances from the screen and discarding captured
text. Matching is plain substring, ASCII case-insensitive like Ghostty.
Search uses one `-F -L -T -N` capture per chunk, joining bodies on wrap
flags without trimming their whitespace. Query edits and closing the bar
cancel the scan. Output immediately invalidates results and cancels chunks;
stale results cannot navigate. A new scan starts after 300 ms of quiet,
or at most every two seconds during continuous output. Connection owns
this lifetime: resync invalidates immediately and restarts only after a
successful restore. Alternate screens search only their screen. Next and previous wrap through the newest-first
match list. An unloaded match submits a tokened coverage goal to the same
10k loader as the pill, automatically raising the surface budget on
refusal. Later navigation replaces that goal, including cancellation when
a loaded match is selected. Query changes, output and resize cancel it;
a post-restore scan does not automatically reload a canceled old goal. Ghostty
search supplies the highlights and loaded-match selection; it is restarted
after prepending history. Each restart ends the previous Ghostty lifetime.
Ghostty tags totals and selected indices with that lifetime's immutable
generation and rejects queued events after it ends. The surface's delivery
epoch advances on each new search and both public stop operations, including
stops with no active search. Nonempty edits in a live search keep its epoch.
The runtime captures the main-only epoch getter when accepting an action,
then checks it again inside the weak, asynchronous PaneView delivery.
Clearing or invalidating without restarting therefore rejects already accepted
actions too. A replaced search cannot
inherit an old count or selection. End-search also captures the find-view
identity on main, so its queued close cannot close an empty reopened bar,
which has not issued a new Ghostty lifetime yet. Nonempty needle changes without stopping remain in one lifetime;
these generations are not per-query tokens for arbitrary Ghostty clients.
Budget retries and chunk expansion are bounded; genuine resource or capture
failure reports a failed search without evicting newer rows. Command-G and Shift-Command-G (also Return
and Shift-Return) navigate; Escape closes the bar and clears highlights.

In copy mode, Command-F, `/` and `?` open or focus the same bar without leaving
copy mode. The bar searches only what Ghostty has loaded: no tmux scan, no history
load, and no restart on output, because the pane is frozen. The count reads
“N matches (loaded)”. `?` searches toward older text and `/` toward newer text;
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
through the same scroll path as the keys, only within loaded rows. It never
loads history.

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
focused pane, and when the pane's tmux session has no agent that kido's
`prompt` can reach: no sidebar row of that session is an agent outside a run
window. Then ⌘O beeps and opens nothing, also in copy mode. In copy mode, `p`
enters Prompt mode only with a selection, and beeps without one. While copy
mode is still entering, mouse clicks are ignored, except that a held
Shift-press gesture continues. The wheel still scrolls.

The `Feed` has no timeout for a request. Thus, a `prompt` send that blocks
kido's RPC loop until the inbox times out does not restart the helper.

### Focus treatment

In a window with two or more visible tiled panes, the focused pane is the
only one with the pure terminal background. Every other tiled pane gets
the shifted paper: the terminal background mixed 3% toward black on a light
background and 3% toward white on a dark one (relative luminance < 0.5), per
sRGB component. This is the direction rule of the sidebar shade, and one
helper computes both. The titlebar and toolbar band uses this shifted
paper in all sidebar modes and in full screen. Thus it matches an inactive
pane. The pane shift does not follow `kido-sidebar-shade`, so a strong
sidebar value does not make inactive panes hard to read. Its own
key, `kido-unfocused-background-shift = <percent>`, has the syntax, range,
include order and diagnostic rules of `kido-sidebar-shade`, with
a 3% default, and the same reader reads both keys. A reload that changes only this key repaints the
panes and the band. The focused pane also gets a 1pt `controlAccentColor`
stroke at 50% alpha, inside its chrome rect, over the padding and not over
cells. A single-pane window draws no shift and no edge on its pane, in
every focus state. Floating panes keep a 45% theme-background overlay when
they are not active.

A pane has Ghostty surface focus, and a solid cursor, only while it is its
window's first responder and that window is key, or while no app window is
key. Each pane observes the key-window notifications. Thus, a key panel
over the window, such as the [command palette](#command-palette), makes
the focused pane's cursor hollow without moving the window's first
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
A `kido-app.conf` reload clones the new config for each surface. On a
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

### Clipboard

Live OSC 52 writes copy text to the Mac general pasteboard. Reads use Ghostty's
asynchronous completion through the original pane's `send-keys -H` input path,
not tmux clipboard commands. `c`, `p` and `s` share that text pasteboard; replies
retain the requested selector. Empty clipboard text gets an empty reply. Text
is capped at 1 MiB; NUL-containing writes are ignored and reads refused with an
empty reply. Clipboard contents are not logged.

Application reads always use `clipboard-read = ask`, including configuration
updates; explicit `deny` wins. Before accessing the pasteboard, the first read
asks: “Allow applications on “HOST” to read your Mac clipboard?” The sheet notes
that this also permits applications reached through SSH inside its panes.
**Allow for this connection**, **Always allow** and **Deny** grant or deny that
window's connection. A connection's Deny wins over its Allow, then persisted host grants; otherwise the read asks. Edit → Reset Clipboard Permissions clears all persisted grants and every open window's connection answer, without confirmation. Always allow is shared between windows and persisted in
UserDefaults by exact configured destination, with Local separately keyed.
SSH aliases are not merged with resolved hostnames; retargeting an allowed alias
retains its grant. Local is not implicitly trusted and includes SSH launched
inside local panes. Background test composition has no persistent grant store
and injects a named pasteboard; production supplies the general pasteboard.

The guarded WindowOwner presenter shows consent only in a visible window.
An unapproved hidden pane/window read is denied immediately, never deferred.
There is one pending read per pane and at most one consent sheet per host;
additional reads receive empty replies. Eight seconds without a decision
completes with an empty reply; an overdue sheet answer does the same. Pane removal, window close, eviction and connection
retirement cancel the opaque Ghostty state without input, before freeing its
surface. Late sheet responses and retired-surface input are ignored.

Snapshot restore explicitly resets Ghostty's parser before replay, including
when its old state was mid-OSC. Restore mode suppresses clipboard operations at
the parser boundary, before surface messages are queued. Pending `capture-pane
-P` bytes retain parser state: only a subsequent live terminator may perform
one operation. For ST, ESC is the dispatching byte: a captured sequence already
ending in ESC is historical, and the live backslash does not re-fire it. Already
queued live operations remain live across ordinary resync. MANUAL_MIRROR still suppresses every other parser reply.

Guarantees cover displayed panes only, with one clipboard-enabled app per pane.
Hidden/evicted output and pause-after losses are best effort. The app leaves the server's `get-clipboard` setting alone.
Nested tty-mode tmux needs OSC forwarding and preauthorization; see known issues.

Cmd-V and unsafe paste are separate from application reads. An unsafe paste is
asked about in a sheet showing its text, and completed exactly once: pasted,
or refused with an empty completion on Cancel or when its surface is freed.

**Uploads.** File drops prefer existing file URLs. Local panes paste their
original paths; remote panes copy the files. If no file URLs exist, Kido
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
directory, with its seven-day cleanup. Remote and Local-pane SSH consent
rules still apply. Text and web links without files or promises are refused.

Surfaces are kept per window, for the most recently shown windows of
any session while their panes total at most 32; the rest have none. A
window gains its surfaces when shown. Showing another window evicts the
least recent past the budget, never the shown one, off the switch path;
surfaces are freed one per main-queue turn and at least a second after
they were created, since a young one takes hundreds of milliseconds to
free. A hidden surface is occluded and its renderer released. Shown surfaces
follow the app window's occlusion during resize too. Provisional Ghostty reflow
remains visible while the authoritative capture is in flight. After replay and
the successful restored viewport apply, an asynchronous tokened render fences
completion, not visibility. Its acknowledgement must match the pane's epoch,
backing dimensions, inset and viewport revision/target. Superseded requests
coalesce. Ghostty discards a tokened presentation when the layer's pixel size
changes between the draw and the main-queue commit, when a newer surface
generation commits first, or when the surface is unrealized or zero-sized; a
current discarded request gets one asynchronous retry. Backend
failure remains incomplete and diagnostic, without a visibility hold. tmux sends no `%output` for panes outside the client's session,
so a window that left it is synced again when next shown. Surfaces of closed windows and sessions are freed.

tmux's layout is authoritative: every Ghostty surface is exactly its
pane's grid, and `PaneLayout` maps cells to points. On each axis a
pane's two inner paddings sum to one cell minus one device pixel, split
floor/ceil in physical pixels so surfaces and dividers stay on the pixel
grid. tmux's border cell between two panes is then exactly their
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
window with `move-pane -f`. Window edges preview the resulting half-window;
centre drops preview the whole target for a swap. Pane edges show a 4pt
insertion bar, not a predicted size: tmux splits the target before removing
the source and redistributes its space (`third_party/tmux/cmd-join-pane.c`,
`cmd_join_pane_exec`), so predicting that size would duplicate its layout code.
Window-edge drops let
tmux handle already-spanning panes; one tiled pane has no drop targets.
The accent highlight follows
the effective appearance. A drop sends one `move-pane` or `swap-pane`, and
only tmux's layout notification moves the views. A click, Escape, a drop
on the source or a floating pane cancels. Dragging is disabled while zoomed.
Floating grips and padding share one move gesture, starting after 4pt of
movement; resize edges follow the pointer immediately. A press without movement
raises a covered float with `move-pane -z 0`. Draggable padding is inside the
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
per float after release. Coalesced, one-in-flight command batches send its
rounded cell geometry to tmux with the border-dependent position and size
semantics. Nested command batches finish at a private marker on a separate
input line: tmux gives nested replies the same control flag as direct ones,
and a failed batch drops the remainder of its line. Ordinary command batches
still pair by count, with no marker or extra round trip. PaneLayout owns the point-to-cell inverse and floating bounds.
Layout installs and placement validate free frames against that same conversion;
presentation validates hidden windows too. A changed placement cancels an active
gesture and drains only the already-sent commands. Zoom, removal, layer changes
and reconnect also clear free frames. Nothing is persisted. Ghostty remains exactly tmux's whole-cell grid,
with the fractional size remainder in the right and bottom padding. Chrome,
mask, shadow and hit areas use the drawn frame; pixel clamping keeps it inside
the window grid. Resizing clamps only the dragged edges, preserving their
opposite edges; a right or bottom resize never moves the origin. Each pointer
update places only that float, its backing and toolbar, and unchanged clamped
frames do no placement or cursor invalidation. Full placement assigns each
pane's final frame once. Placement skips unchanged backing, toolbar and scroller
frames and retains an installed mask rather than assigning it again. In-flight gestures retain their pixel frame until a follow-up
command reply has drained the final batch's layout notifications, then keep it
only if it matches tmux. Escape stops further commands,
not changes tmux has already applied. Pane command errors appear in a sheet.
Sidebar drops are not supported.

Frame changes place only the shown window; membership and stacking are
reconciled only when tmux’s topology changes. Hidden windows are placed
when shown. Terminal focus survives resizing and sidebar collapse;
showing another window or creating the active pane’s view can move focus.

The standard window buttons are AppKit's: the toolbar re-lays them out
at will, so nothing moves them. The fixed top clears them and the
sidebar toggle, which AppKit keeps in the collapsed titlebar,
so the terminal never moves vertically when the sidebar collapses.

## Threads

Client callbacks run on the client's reader queue, and the pane map is
touched only there. Output is fed synchronously on the pane's scroll queue,
serializing live output with asynchronous viewport applies. Main must never
wait for that queue: parsing can fill Ghostty's app mailbox, whose surface
messages are drained by `ghostty_app_tick` on main. Ghostty's stream handler
releases the renderer mutex before waiting for mailbox capacity, so main can
still take that mutex through the thread-safe pixel-scroll API to snap before
handling input. The viewport lock serializes snaps with worker applies, but
is never held across output parsing. Its cumulative snap adjustment removes
snap-induced offset changes from feed's before/after output-pinning delta:
`D1 - D0 - sum(snap movements)`. The ledger is cumulative across feed intervals
and is not reset while one can be active. It distinguishes multiple snaps
from concurrent output, even when history grows between a read and an apply.
A zero target still follows the bottom. Lock order is viewport then target
or renderer, with neither held while waiting for viewport. MANUAL_MIRROR
applies grid resizes inline in Termio, not on a debounced IO-thread callback;
grid confirmation reads the actual grid under the renderer mutex.
Only feed synchronizes with the scroll queue, from the client queue, never
main or a Ghostty callback. Snapshot/prepend admission validates the content
epoch under a short app lock, which is released before parsing. While a
mutation is admitted, main coalesces the latest accepted grid/reflow rather
than waiting for the worker. Completion installs and confirms that grid.
If output was dropped while a grid was unconfirmed, incremental feed stays
suspended until a current reset-and-replay commits; a provisional parse
cannot clear a newer dirty epoch. Renderer
callbacks publish asynchronously to main; runtime wakeups coalesce main ticks.
External pacing is selected before renderer initialization, so app surfaces never
allocate a CVDisplayLink, including with vsync disabled. Renderer demand and its
scheduled notification share one mutex; notifications enqueue strongly retained
driver jobs on main without reentry. Main drains latest demand and publishes tick
availability without a mailbox push. Unavailable views render event-driven, without
a fallback timer. The fork's renderer starts the cursor blink timer only while
the surface is focused and the terminal's cursor-blinking mode is set, and the
timer stops at its next tick when either ends. Thus, the default non-blinking
cursor costs no idle frames. Viewport moves and output do
not reset an active scrollback compression timer. Its callback samples the
PageList activity token every 250 ms, so compression normally starts
250–500 ms after the last activity, once it gets the terminal lock. Disposal terminally closes pacing and invalidates its link before
parser-quiescent retirement; the driver context survives surface free and renderer
join. Queued jobs retain only the closed driver, never a pane or live surface.
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
tradeoff for preserving command order. Other main-to-renderer blocking sends
are not removed by this change.
A pane leaving the layout is held on main until the queue has
dropped it, so its
surface is freed on main. A layout reaches main synchronously. Unless a
parser/prepend mutation is admitted, its grid is installed and verified through
Ghostty's mutex-protected actual metrics before layout installation returns.
During an admitted mutation the latest desired layout is recorded instead;
unconfirmed geometry suspends feed until installation/readback and a current
authoritative restore. A failed setter or mismatched
grid rejects feed and prepend, logs a diagnostic and closes the control
client through its ordinary redial lifecycle; failure is never confirmation. Main never waits on the
reader queue.

## Sidebar

The sidebar runs the bundled `kido rpc --server DIR --client NAME` with
the app's own client name, so kido's rules follow what the app shows. The
in-repo [RPC contract](../share/rpc/contract.md) is authoritative. The first line
must be a compatible hello; a server mismatch stops the feed and uses the same
banner as discovery, without automatic retry. Window and session navigation
use numbered RPC requests. Replies can interleave with
snapshots and arrive out of order; pending callbacks live on the feed reader
queue and complete once, including failure when the connection ends or restarts.
The app decodes v2 snapshots of protocol 6.0 only. Pane items carry a plain
`title`, a typed `lifecycle` (Live pane kind with its agent or shell status,
or Ended with a run result) and the raw `program_status`; their variants,
null rules and percentages are enforced, and a malformed snapshot restarts
the feed. Only the raw-record enums and the Ended result decode unknown values
as unknown; kido never sends an unknown result. An item's `run` is the opaque
run id of the pane, or null; the app never reads a run's kind. Every snapshot carries the tmux `server_instance`;
sessions are source-list sections,
window groups contain panes, and pane items can contain arbitrarily deep
hoisted child windows. A node's identity is scoped to its session; linked
windows may appear in several sections.

`Sidebar` is an `NSSplitViewController` with a sidebar item, which
supplies the floating glass, collapse animation and saved width (236pt,
200-360pt). The window has an icon-only unified toolbar only because the
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

Tabs project the current session's top-level windows from the
feed; descendant windows activate their ancestor tab. The control client's
window list is filtered by the feed: with a snapshot, an unlisted window
gets a tab only if it is the session's current window, so a new detached run
window does not flash as a top-level tab before the snapshot nests it under
its parent. With no snapshot, every window shows. Each title
is the composed label of that window's active pane, falling back to the
tmux window name until its feed label arrives. A tab whose active pane is an
agent is drawn like its sidebar row: semibold, with the display-only
@ prefix when that row has one; other tabs are regular with no @. WindowView's active
pane, read from tmux layouts and `%window-pane-changed`, is shared with terminal
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
new-window plus; hovering brightens only its icon. No session folding remains.
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
side by side. A quiet target closes at once. The close kills descendant windows
before the target, and a failed kill reports "Pane command failed" in another
sheet. Only one alert is prepared at a time.

File → Close Window and Session → Close Session have no shortcut. They
use the same confirmation. Close Window kills the key window's current tmux
window. On a session's last window this also ends the session, with no
extra warning. Close Session checks every pane of every window of the
session, and asks with "Processes are still running in this session.
Closing the session will end them." It then sends `kill-session`. The
control client is attached with `no-detach-on-destroy`. Thus, tmux moves it to
another session, and the window follows that switch as it follows any switch.
If the session was the last one, the server exits, and the window stays open
with the no-server banner and its Start button. The native window's close
button still only disconnects ([Remote hosts](#remote-hosts)). With no window,
the Window and Session menus and Close Window are disabled.

Captions use a display-only 200ms debounce per row. New text must remain
stable for 200ms; empty text must persist for 200ms before the old caption
is hidden. The first snapshot after launch or reconnect shows captions
immediately. Row height and accessibility use the displayed caption. One
timer serves the next pending deadline; removed rows lose their state.

All pane and program rows are 32pt single-line or 48pt with a caption, with
7pt vertical padding. Titles are 13pt regular on an 18pt line; captions are
11pt on a 15pt line, 1pt below the title. Titles of panes whose lifecycle is a
live agent (Pi_agent, Some_agent or a remote agent) and all program-record
rows are semibold; every other pane title, Ended and Terminal runs included,
is regular. Rows have
a 12pt leading inset, a 16pt leading slot holding the status indicator, and an
8pt gap; there are no leading icons. The trailing inset is 12pt and the
trailing column holds only the 10pt tabular clock. The activity line is one
line, truncated with an ellipsis, from the title's leading edge to the
trailing inset. Nesting steps 15pt at every depth. Only the focused pane row has a 10%
labelColor fill, with 7pt corners. Independent keyboard selection also has
7pt corners and clears on mouse press. No window-wide fills or focus marks remain.

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
a live Pi_agent pane. A run pane gets no @ while it is a Terminal or Ended: its
inbox is not up yet or is gone. A native agent pane (Some_agent, such as
Claude Code) and an agent over SSH (an Ssh pane with a remote agent, out of
reach of message_agent, which only reaches pi sessions on the same server)
cannot be messaged, so they keep the semibold title without the @. Idle local shell panes
(Live Terminal at a known Idle prompt, no run, idle/done/failed indicator) display secondary-colored
`Terminal`; an Unknown phase, full-screen programs, SSH, and run items keep their labels. Both display
rules leave raw pane labels and tab/window titles unchanged.

The app composes what kido no longer sends. The label is the wire title,
except that a local shell without a program report and not in a run shows a
non-empty running non-fullscreen command, and a remote terminal shows
`ssh user@host`, adding `: command` only for an interactive, report-free,
non-fullscreen running command. The caption is the agent's or report's `msg`
and progress percentage, joined by a space; Ended rows show their result
except completed or unknown, which show none: the green check alone marks
completion, while accessibility still reads "gone, completed". A run's
start metadata drives the clock even when a caption is shown. The indicator comes from the agent state
(running, waiting, idle with an outcome), else for shells: a live
run without a report is running, a report wins over the phase (fullscreen
included), otherwise fullscreen has none, Unknown has none, Running is running and Idle shows its last command
exit. Ended completed is done, failed and died are errors, stopped and
unknown are quiet. The indicator sits in the leading slot, centered at
x=20pt plus 15pt per nesting level and vertically on the title line; the
header plus center is 15pt from the right edge. Indicators are 6pt dots:
idle and quiet gray (secondaryLabelColor at 45%), running/compacting green,
waiting rows of any kind orange, failures red. Done/completed is
a plain green checkmark, about 6×4pt at a 2pt stroke, visually centered on
the dot position. Tabs aggregate the same mapping, with running and done
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
External tmux switches update selection without taking keyboard focus.

The toolbar and Shift-Command-S toggle the sidebar; the View menu's
Show/Hide title follows its collapsed state. Focus Sidebar uses
Command-S. Control-Command-F enters full screen.
Command-{/} and Ghostty previous/next tab use RPC switch-window; there are
no Control-Command-J/K shortcuts. Nested windows step among direct siblings,
prev from the first child selects its parent, and next from the last child
steps from its top-level ancestor. Top-level steps skip run windows and wrap
across sessions; a sole eligible window can select itself and null is a no-op.
Option-Command-]/[ switches sessions in the
sidebar session order, with wraparound and a single-session no-op.
Session navigation uses RPC switch-session and selects the returned current window.
Command-N and toolbar plus create a session via new-session. File → New
Session with no key window uses an open local window that is not key, or opens
a local window. The window that it opens has the dial cause `newSession`: it
makes a session on its first error-free snapshot, once. The intent belongs to
that window. Closing it before its snapshot drops the intent, and a later
ordinary open does not make a session. Each session
header plus creates a window after that session's current window via new-window.
Command-T sends new-window with the current window id; the server inserts
immediately after it using its active pane's cwd. Numbered and last tabs use
select-window; absolute sessions use select-session. In the table, arrows and j/k
move pane-only selection, Return activates with exactly one
RPC jump, and Escape releases side focus via RPC and returns to the pane.
Left/Right do nothing; headers do not activate or fold. Only correlated success
returns focus when the authoritative pane view is current; failures preserve
focus. One monotonic UI-intent revision advances on selection/focus changes
and navigation. Each request captures it; only a still-current completion
leaves the sidebar or installs deferred focus. Any new intent
cancels deferred focus, which is consumed on pane changes as well as window
topology. Pending requests fail once on disconnect and are never replayed.
Replies do not synthesize topology.

Pane indicators come from the typed lifecycle, never
re-derived from raw program records. A tab's mark summarizes its window and
descendants' row statuses in error > waiting > running > unseen done > quiet
order; docked tabs show only error and waiting marks.

Kido does not acknowledge anything: the app owns seen. One app-wide record,
keyed by host, holds per pane and outcome source (agent, program report,
shell command) the identity of the last outcome shown: the pane serial for
agent and report outcomes, the command's start and end seconds for an exit.
An outcome whose identity matches is seen and drawn quiet; an unseen success
draws a checkmark and an unseen failure red until then. A window is attended
while the app is active and the window is key, not minimized and visible;
on every snapshot and whenever it becomes attended, its client's active pane's
current outcomes are marked seen. Every window of the host redraws its rows
and tab dots from the shared record. A changed `server_instance` drops the
host's entries; a successful snapshot prunes absent panes, while an error
snapshot neither prunes nor marks. Outcomes already finished when a host's record
first observes an error-free snapshot count as seen. Seen is not persisted across launches. Control-mode
%program-status lines remain unrecognized and unused; Ghostty is unchanged.
The sidebar is visible by default; it does not automatically collapse
at narrow widths.

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

- The sessions and panes of every connected owner, in sidebar order. The
  anchor comes first, then the other owners. A session row has the
  `square.stack` symbol and selects the session through one RPC. A pane row
  has its status mark and jumps through one RPC, as a sidebar row does. The
  row's window comes to the front first. A remote owner's rows start their
  detail with the host. An owner that is offline or reconnecting adds no rows.
- Each recent host that has no open Kido window, newest first, with the
  `globe` symbol and the detail "Connect". This holds also when windows are
  open.
- A fixed list of commands, each read from its menu item (found by action and
  represented object, never by title) for its title, menu path and current
  key equivalent: New Session, Rename Session…, Close Session, New Window,
  Close Window, Split Right, Split Down, Close Pane, Zoom Pane, Connect to
  Remote Host…, Hide/Show Sidebar, Focus Sidebar, Enter Full Screen, Find…,
  Copy Mode, Prompt…, Reset Clipboard and Upload Permissions and Theme…. The window
  commands need an anchor. The pane commands need a live focused pane: a
  connected anchor whose saved responder is a visible pane of that window, or
  a view inside one, such as its Find bar. Prompt… also needs an agent in the
  pane's session, as its menu item does.
  Navigation items, Select Pane, the numbered lists, Find Next/Previous, Hide,
  Quit and the palette item are never in the list.

While the palette is open, each owner snapshot or model change and each window
close rebuilds the entries from the saved owner and responder. The panel stays
key. The query is applied again, and the selection is kept by entry identity,
else row 0. A row is checked again when it runs. A session or pane row needs
an owner of the same host with the same `server_instance` whose rows still
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

The palette has four modes besides the root. A mode shows a chip left of the
field (22pt, the mode's symbol and name) and a foot that names its keys.
Entering a mode clears the query and the error. An error is a red line between
the field and the list; an edit clears it.

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
  the field, selected. Return commits through `SessionRename`, the rules of the
  sidebar's inline rename: an empty or unchanged name closes the palette with
  no change; a name with `:` or `.` or a duplicate name shows the rule's message
  and selects the text again; a tmux refusal shows tmux's message. The sidebar's
  inline rename and this mode call the same `WindowOwner.renameSession`.
- **Prompt** (`bubble.left`). It sends a prompt to an agent through kido's
  `prompt` RPC ([Prompting an agent](design-rpc.md#prompting-an-agent)). It
  replaces the list with its own view, `PalettePrompt`, described below.
- **Theme** (`paintpalette`, "Search themes"). View → Theme… (no shortcut)
  and its root row enter it, also with no window. It is described below.

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
  the source is that agent's own pane, preselected, with no quote. On any
  other row, ⌘O acts as the Prompt… row. Only the highlighted agent row shows "⌘O prompt" in its
  shortcut column. In another mode, ⌘O does nothing.
- The root row Prompt…: the focused pane, with its current selection.

The pane entries first check for an agent in the source pane's session, from
the snapshot that the sidebar draws. Agents in a run window do not count,
because kido's `prompt` excludes every pane of a run window. Without one, a
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

An entry first sends a `prompt` resolve request for the source pane. Nothing
changes on screen until the reply: a closed palette stays closed, and the root
list stays as it is. Then the palette opens or enters Prompt mode with the
target, its draft and the appended quote at the final height. Thus, no field
accepts text before its target is known: a reply that arrives after the user
started to type would replace that text. A second entry while a resolve is
pending starts no other request. If no reply arrives in 5 s, the prompt opens
failed with "kido did not reply" and Retry, because the feed's requests have no
time limit. A palette close, a mode change, an owner close, a changed server
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
- `refused`: a red triangle, kido's message, and Retry, which sends again. An
  edit returns to ready.
- `unknown`, or a feed failure after the send was written: kido's message with
  " It may have arrived; not resent." and Copy Prompt, which puts the composed
  text on the pasteboard. The field is read-only and muted: all its text,
markers included, is in the secondary label colour. Send is hidden, and
  the palette never sends again by itself. The draft stays.
- `invalid`, `Feed.notReady` or an error with no `kind`: the message in red.
  The picker stays enabled. An edit or another target returns to ready.

A late reply after the mode changed or the palette closed does nothing.
While Prompt mode is open, each owner snapshot checks the source. A changed
`server_instance` or a closed owner closes the palette as `.moved`. A source
pane that is in no sidebar row of its session sets "pane closed". When the
chosen agent is in the source window, the picker reads "in window <name> (pane
closed)" with the window name captured at open. In the ready state, the status
reads "Source pane closed; agents resolved earlier stay available."; the other
states keep their own status. The candidates stay, and the palette does not resolve again. A
send to a target that is gone fails as `invalid` from kido.

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
no longer in the snapshot, and an owner close drops its host's drafts. A pane
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
runs it; Escape returns from Connect or Rename to the root and closes at
the root;
Backspace on an empty field in a mode returns to the root. Command-P has no
Ghostty default. From a pane, `PaneView.performKeyEquivalent` offers an
unbound Command key to the main menu, which is how Command-P reaches the
palette.

The field's accessibility label names the mode: "Command palette", "Connect
to remote host", "Rename session" or "Theme". In Prompt mode, the field is "Prompt",
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

- The bundled themes in one fixed order: `kido-light`, `kido-dark`,
  `ahrefs-light`, `ahrefs-dark`, `solarized-light`, `solarized-dark`. They
  are written by bare name.
- Then the regular files in `themes` beside `kido-app.conf`
  (`$XDG_CONFIG_HOME/kido/themes`, else `~/.config/kido/themes`), sorted
  with `localizedStandardCompare`. Dotfiles and names that contain `,`, `:`
  or `=` are not listed; a symlink to a regular file is. They are written
  by absolute path, because Ghostty does not search this directory.
  `~/.config/ghostty/themes` is not listed, but a name there still resolves.

Each row loads its file through a private Ghostty config for the swatch: the
background with "Aa" in the foreground, and palette colours 4, 2, 1 and 3.
The "light" or "dark" tag is the background's luminance. The row shows the
file name. "✓ Light" and "✓ Dark" mark the rows that the conf's pair
names: a bundled row by bare name, a user row by path with `~/` expanded. A
file that is missing or has diagnostics is a dimmed row with an empty swatch,
no tag and "theme file not found" or "invalid: <diagnostic>" in red. It can
be selected and hovered; then the preview shows the theme that
`kido-app.conf` sets now, not the broken file. Return and click on it do
nothing. A file that disappears after the list was read is dimmed when it is
previewed or saved, and the save writes nothing. The marks and the list are
read once, when the mode opens; an external edit of the conf does not change
them.

If Ghostty fails to load the theme that a side of the pair names, the red
status says "<value>: not found. The current config names it for
<Light|Dark>; Ghostty's default colours are shown instead.", or "<value>:
invalid: <diagnostic>. …" for a file with errors. The user's `theme` line
replaces kido's defaults, so Ghostty falls back to its own colours. A theme
that Ghostty loads but the list does not show (from
`~/.config/ghostty/themes` or another path) gets no status and no mark. The
current appearance's side is checked first.

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
and "This session only · not saved to kido-app.conf". Up/Down move the
radio. Return or a click writes, applies and closes. The session row writes
nothing and reads nothing: the theme becomes the session theme for both
appearances until quit or the next successful save, and its foot says
"applies until quit; <conf path> is not changed".
Escape or ⌫ goes back to the list with the query, the selection and the
preview kept. The foot shows the exact line, from the same
`ThemeConf.line` that the writer calls, and the conf path. Both writes the
one theme to both sides.

If the write fails, the list stays open with the red status "Could not write
<path>: <reason>. <name> is applied for this session only." and "Reveal in
Finder", which selects the conf or, if it is absent, its directory. The
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
user or fails out of sight, and withdraws it when the reason is gone. kido
reports status and retained outcomes; the app decides what the user has
seen and what deserves a banner. `SidebarFeed/Notifications.swift` is the
pure step; `App/Notifications.swift` holds the two posters and the
app-wide `Notifier`; `main.swift` installs the delegate and routes clicks.

**Eligibility.** A pane wants a notification when its lifecycle is Live,
it is not a run nested under another item (the parent agent gets the notice;
a run at the top level of the tree, even inside its window's group, has no
parent and notifies), and `Item.indicator(seen)` shows waiting (an agent
or a shell program report, in any phase) or an unseen error. The
indicator keeps the sidebar's precedence, so a quiet report masks a
command exit for the banner exactly as for the row. Waiting is one plain
reason: a changed kind while still waiting does not repost. A
failure's reason is its outcome source and identity, so a new failure
reposts. Done, finished runs, successes, running, Ended rows and
a command exit of 130 never notify.

**One notifier, entries per window.** Every `WindowOwner` has its own
entries, keyed by owner and pane; there is no primary feed per host, and
two windows on one server may repeat a notification. Attendance is
shared: `shown` is the set of tmux windows currently displayed by the
host's attended windows (app active, key, not miniaturized, visible).
Per entry the states are absent, posted(reason) and acknowledged(reason).
On every error-free snapshot of an owner, for each wanting pane:

- a baseline snapshot, a pane whose tmux window is shown, or a reason
  that starts or changes while Kido.app is active, acknowledges it,
  withdrawing any earlier post: it is on screen, or the user is present
  and what starts meanwhile counts as noticed;
- otherwise a new or changed reason posts, replacing an earlier post;
- an unchanged reason does nothing, posted or acknowledged.

A pane that stops wanting (seen, new work, success, no longer waiting,
or gone from the snapshot) is withdrawn and forgotten. Error snapshots
produce nothing and keep the baseline pending. Closing a window withdraws
its entries; quit withdraws everything, so Notification Center never
offers a jump that cannot be honoured. Attendance changes (key, active,
miniaturize, occlusion) re-step the host.

**Baseline.** The first error-free snapshot of a new or restarted feed,
and the first after a changed `server_instance`, records what wants a
notification as acknowledged and posts nothing. At launch the seen
baseline has already quieted finished outcomes, so this covers waiting
panes; after a feed restart on the same server an outcome re-derived
under a new serial shows red but does not post; a changed server
instance clears the sidebar's seen entries without a baseline (rows red)
and the notifier's entries with one (no banners). That asymmetry is
deliberate.

**Content.** Title is the sidebar row's title. Subtitle is the session
name; for a remote window `user@host · session`, using the resolved
identity the window title shows; for a `kido ssh` remote agent in a Local
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
(not in background builds), and performs the existing RPC jump, which
moves that window's client; the pane becomes active in an attended
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
and there is no in-app toggle. `SystemNotifications` is the only file
importing UserNotifications. Background, visual and stress builds use
`RecordedNotifications`, which records posts, withdrawals, badge counts
and authorization calls and never touches Notification Center.
`NotificationsTests` in SidebarFeed cover the step: attendance,
baselines, suppression and acknowledgement, reposts, every withdrawal,
exclusions, precedence and content; the hosted `NotificationTests` drive
two owners, feed restart and `route` against the recording poster.

## Testing

`make visual` runs hosted SnapshotTesting tests against a private tmux
socket, never activating a window. Clipboard sheets use visible windows placed
far off screen, as do native-button local-mismatch tests;
the other fixtures keep their windows unordered. Menlo 13 and the built-in
light/dark themes isolate terminal-area image and compact layout references:
single panes at three heights, splits, floats, zoom, fractional history,
alternate screen, settled resize and the Load more pill. A test-only
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
filtered, filtered2, nomatch, connect, connect-typing, connect-invalid,
connect-none, rename, rename-error, rename-error2, nowindow, match-run,
theme, theme-filtered, theme-preview, theme-save, theme-save-session,
theme-err-write and theme-err-file. The theme images are recorded last in the same test. Their
conf lives in the visual scheme's private `HOME` (`XDG_CONFIG_HOME` is
`$HOME/.config`), so the paths read `~/.config/kido`; the test checks that
`HOME` is that private directory before it writes. theme-err-file removes the
built app's bundled theme file and restores its bytes in a `defer`.
`ThemeConfTests` tests the conf text functions and the writer.
`palette.light-window-root.png` records the card over a real two-pane window
at the mockup's 1100x740pt, with the panes' cursors hollow. The fixture
clears the panes' tmux history after fixed output, because `respawn-pane -k`
keeps history. It lays the window out completely before the presented-frame
fences, and it checks the pane frames against the tmux layout: a layout pass
after the fences resizes the panes and the sidebar shadow after the captured
frames. The background
test app has the `.prohibited` activation policy, so AppKit does not make
the unordered panel key. The key tests therefore assert `canBecomeKey` and
the panel's field editor, not `isKeyWindow`. They send Command keys as real
events through the panel's `performKeyEquivalent`, the call that
`NSApplication` makes for a key window, and other keys through its
`sendEvent`.


`make tsan` and `make asan` build Debug with ReleaseSafe GhosttyKit into
`build/xcode.noindex/derived-{tsan,asan}`. ASan defaults to `use_sigaltstack=0` because Zig
threads replace its alternate signal stack with thread-local storage.

The Main Thread Checker needs no rebuild: launch a Debug build with
`DYLD_INSERT_LIBRARIES=$DEVELOPER_DIR/usr/lib/libMainThreadChecker.dylib`
and `MTC_RESET_INSERT_LIBRARIES=1`, which keeps it out of the feed and
tmux. Leaks are checked with `MallocStackLogging=1` and `leaks`,
`footprint` and `heap` on the pid, compared after attaching, after
switching past the surface budget, and after closing all but one window.

`KIDO_APP_SERVER` (a private 0700 directory) and `KIDO_APP_TMUX` point the app at a private
server; `KIDO_APP_FEED` names a stand-in feed. `KIDO_APP_BACKGROUND=1`
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
  `WindowOwner.reorderTimeout` (2 s, local host), `Upload.promiseTimeout` and `WindowView.toolbarFadeDuration` (0.15 s)
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
  It does not wait for tmux replies or child processes, so it is not a quiet
  window: an absence check uses a fixed, bounded wait.
  `VsyncTests` keeps its own fixed 200 ms `drainAnimation`, because its
  idle-CPU windows depend on that settle.
- A fixed wait remains only where it is the check ("never activates", quiet
  windows) or where no event exists.

### Stress harness

`make stress SEED=N DURATION=S [FIND=0]` builds the app with the
`KIDO_STRESS` compilation condition into `build/xcode.noindex/derived-stress` and runs it
for S seconds against a private tmux server; `make tsan-stress` and
`make asan-stress` do the same with the sanitizers (own derived dirs). The
condition is set only by these targets: `App/Stress.swift` holds only a typealias in every
other build and `main.swift` has one `#if KIDO_STRESS` call site.

`scripts/stress.py` (stdlib Python) builds the demo-like layout, including
1M- and 100k-line history panes, with `scrollback-limit = 8 MiB`, and every 0.4s
applies a tmux action chosen from `SEED` (switches, splits, kills, zoom,
resizes, move-pane, client resizes, feed kills, server restarts at 40% and
80%). In the app `Stress` does the same on the main queue, also seeded: wheel,
scroller drags, scroll requests, find and next, resync, window resize
bursts, load-more, pane grip drags (some killed mid-drag), edge resizes,
detach and reconnect, appearance. It writes one JSON line per action to
stderr (`build/stress/<target>-<seed>/stderr.log`; `actions.jsonl` is the tmux
side; `summary.json` the counts). `FIND=0` swaps the find actions for scroll
requests. A run fails, exits 1 and prints its replay command on a sanitizer
report, panic, non-zero exit, an app that did not finish, a new
`Kido*.ips`, or a step that saw the window visible, key, main or active.
A seed is a best-effort reproduction: choices also depend on the observed
tmux topology, and timing against live output is not reproducible.
`actions.jsonl` records the tmux actions actually taken.

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
logic, not AppKit event delivery or hover. Stress pane-command failures are
logged instead of opening an error sheet. Only a “can't find pane” error for
a pane tmux reported gone or either harness side logged as killed is expected
(`killed_race`); every other
pane-command error fails the run.

`KIDO_ALT_VERIFY=1` on a stress build runs a bounded deterministic mailbox
pressure probe instead of random actions. It seeds numbered history, applies
a fractional viewport and immediately double-clicks through PaneView to check
the selected row after snapping. A background feed then enters/exits alternate
screen around 20000 title changes and output rows. Main holds mailbox draining until 65 app wakeups from the parser thread
establish pressure against the 64-entry app mailbox, then snaps during that
feed; both main and worker must complete. Renderer-thread wakeups do not count.
`KIDO_INPUT_VERIFY=1` uses that same barrier, waits for the search sender at the
full app mailbox, and submits 256 alternating navigation commands plus needle
changes before stopping without a main drain. `KIDO_SNAP_VERIFY=1` rendezvouses
output between main's snap preparation and apply, checking one and two snaps,
bottom following, a rejected revision followed by success, and pinned numbered
rows after the pending worker apply. `KIDO_FIND_VERIFY=1` checks deferred stale
actions, real current navigation/selection, history prepend, and close/reopen.
The Zig counterpart checks that current selection enqueues a renderer highlight;
together these are two halves, not an end-to-end rendered-highlight observation.
`scripts/concurrency-probes.py <absolute-app-path> <KIDO_*_VERIFY> <log-name>`
launches each off screen against its own private socket with a 25-second process
deadline, killing only that launched pid on timeout. Every probe records the
same invisibility/focus checks as random stress. No Swift Task spins a run loop.
`KIDO_RESIZE_VERIFY=1` enables rendering only for unordered test surfaces,
checks a rejected unrealized final frame, compares stopped-output IOSurface
pixels against a fresh replay with identical geometry and a 19px inset,
asserts red/blue fixture content, and checks stability and failed-grid feed
rejection. `KIDO_GRID_VERIFY=1` isolates the failed-setter assertion.
`KIDO_REPLAY_VERIFY=1` establishes a new scroll target's successful apply before
snapshot replay, then checks its restored viewport, reference pixels and final
acknowledgement with unchanged metadata. `KIDO_REPLAY_FENCE_VERIFY=1` adds an
app-validator fixtures: a replay reset between a snap's apply and publication
must invalidate that apply, and a synthetic old presentation callback delivered
during barrier-held replay must not acknowledge it. Normal replay completion must then
produce the current viewport, pixels and real render acknowledgement.
`KIDO_VIEWPORT_VERIFY=1`
rejects a final frame when a same-target viewport revision failed all three
apply attempts. These
probes do not establish Metal's late GPU-completion ordering; the bounded
same-queue handler gate probe could not advance past its older handler.
Set `KIDO_MTC_VERIFY=1` with `DEVELOPER_DIR` for Main Thread Checker: the runner
injects it only into Kido and verifies its mapped image in that PID. Injecting
it into the Python launcher with `MTC_RESET_INSERT_LIBRARIES=1` removes the
injection variable before Kido starts, so does not check Kido.

To cover a new feature, add a case to `Stress.Action` and its weighted array,
and an exhaustive branch in `Stress.perform` driving existing internal API; add tmux
actions in `scripts/stress.py` if the feature reacts to server state.
