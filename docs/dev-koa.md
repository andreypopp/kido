# koa: development

This file is koa's development workflow: the source layout, the
build, installation and runs from a checkout, the tests and their
fixtures, the page's visual checks and measurement. The design of
koa, its page and its agent extension is in
[design-koa.md](design-koa.md). The repository's rules for agents,
tests and waits are in `AGENTS.md`.

## Source layout and types

Start at these owners rather than duplicating their contracts:

- `koa/koa.ts`: program startup, HTTP dispatch and view selection.
- `koa/koa-agents.ts`, `koa/koa-view.ts`, `koa/koa-inbox.ts`: agent
  lifetime, session projection and pane message delivery.
- `koa/koa-agent.ts`: tools, registry, routed operations and jobs.
- `koa/koa-records.ts`, `koa/records.ts`: page records and extension
  details. `webview/ko-api.d.ts` is generated from ko's schema
  (`make schemas`).
- `koa/page/`: page composition, editor, Markdown and pure rendering
  models. `koa/page/page.html` is the real DOM structure used by tests.
- `webview/index.ts`: pane and browser transports.
- `koa/scripts/`: the check entry `test.sh`, the Node gate `node.sh`,
  the lint `lint.py` and the prompt dump `dump-prompts.ts`.
- `koa/testdata/`: fixtures, replay, scenarios, fake ko, themes and
  the prompt snapshot.
- `koa/visual/`: the page's visual checks, a SwiftPM tool with its
  references in `koa/visual/__Snapshots__/`.

`koa/package.json` and its lockfile pin the build and test
dependencies, including the real pi used by tests. Each target that
needs them runs `npm ci` when the lockfile changed. TypeScript checks
the Node side with `koa/tsconfig.json` and the page with
`koa/page/tsconfig.json`. The page check has DOM globals only. Keep
type-only ko imports at the boundary; do not hand-copy API shapes.

## Build, install and run

Install the released harness with Homebrew:

```sh
brew install andreypopp/tap/koa
```

A checkout needs Node 24 or newer with npm. koa builds independently
of cargo and git:

```sh
make -C koa
build/koa/bin/koa --help
build/koa/bin/koa --browser
make -C koa install PREFIX=/path/to/prefix
```

`koa/Makefile` is the installed-file manifest. Its output in
`build/koa/` has a launcher and a share tree with the program, built
page, extension, skill and webview SDK. The program and SDK remain
TypeScript; only the page is bundled. The bundle is unminified for
WebKit inspection and is not committed. The checkout and installed
share tree keep koa and webview as siblings so relative imports agree.
`make -C koa install` copies the tree under `PREFIX`, default
`~/.local`.

Run the built launcher in a pane for the native page. Outside a pane,
use browser mode. Select a different pi executable with koa's pi
option. The program loads that executable's package, so a development
pi and the test pin need not be the same installation.

For page-only iteration:

```sh
make -C koa watch
```

In another terminal, start the built launcher with
`KOA_PAGE_RELOAD=1`. Reload Page then assembles from the rebuilt
assets. The watcher updates page assets, not a running Node module
cache. Program or extension changes need a build and process restart.

For an installed preview, install into a preview prefix and put its
bin directory before Homebrew in the login shell's PATH. New Agent
resolves that PATH at each start; a change of only the server's
environment does not select the preview.

Use a private ko server under `/tmp` for integration work. Do not
stop or change the live server that runs the developer's pane.

## Checks

`koa/Makefile` is the one entry point of koa's checks, and
`koa/scripts/test.sh` runs them:

- `make -C koa typecheck` checks both TypeScript projects (`koa/` and
  `koa/page/`).
- `make -C koa lint` runs `koa/scripts/lint.py` (TS hygiene, the
  `process.kill` sites, history comments, also in `webview/`) and
  compares `koa/testdata/ko-prompts.txt` with the output of
  `koa/scripts/dump-prompts.ts`.
- `make -C koa test` builds fake ko (`make build-fake-ko`) and koa
  and runs the Node suite; `koa/testdata/run-tests.mjs` schedules it
  with the long files first. `FILE=` runs only the named files.
- `make -C koa check` runs these three. It is the fast gate of a
  TypeScript change.
- `make -C koa prompts` (or the root `make prompts`) regenerates
  `koa/testdata/ko-prompts.txt` when the extension's prompt text
  changes on purpose.
- `make -C koa visual` runs the page's visual checks ("Host visual
  checks"). `make -C koa verify` runs `check` and `visual`.

```sh
make -C koa test FILE=koa-scroll.test.ts
make -C koa test FILE="koa-program-session.test.ts koa-webview-sdk.test.ts"
```

`koa/scripts/node.sh`, which every target sources, skips without
Node 24 or newer and scrubs pane identity from the test environment.
Under `KO_TS_TEST_REQUIRED=1`, which CI sets, a missing Node is a
failure. Fixture children get private home and agent directories. A
gate waits for a test action, not elapsed time.

The repository's checks call these targets. `scripts/lint.sh` calls
`make -C koa lint`. The `ts` stage of `scripts/verify.sh` runs `make
-C koa typecheck test` and `scripts/test-pi.sh`; the local stage
`koa-visual` runs `make -C koa visual`. `scripts/checks.sh` selects
them from the changed paths: a change in `koa/`, `webview/` or
`.pi/` selects `build`, `lint` and `ts`; a change of the page or the
replay scenarios adds `koa-visual`; a change in `koa/visual/` selects
only `koa-visual`; a change of the theme files selects `koa-visual`
and the app's `ko-test`. Final unit verification uses `make checks`;
`make checks DRY=1` prints its plan. CI runs the `ts` stage and
installs koa with `make -C koa install`, then runs the installed
`koa --help`. CI does not run `koa-visual`.

## Choose the test boundary

Use the narrowest test that observes the rule:

- Pure parsers, queue matching, scrolling, Markdown, extents and
  annotation conversion belong in the corresponding
  `koa/koa-*.test.ts` files.
- DOM presence, order and event handling belong in
  `koa/koa-dom.test.ts`. Its fake document uses the real page HTML
  but does not implement CSS layout. Drive its frame, observer and
  clock seams for reveal behavior; do not assert browser geometry.
- Extension tools and registry behavior use
  `koa/koa-agent-fixture.ts`. These tests have a fake pi and host,
  plus the typed fake ko. They do not need a real model session just
  to inspect tool registration.
- Session, startup, reload, switch, route and feed behavior use
  `koa/koa-program-fixture.ts`: real pinned pi in koa and a scripted
  model. This catches SDK event-order assumptions that a fake pi
  cannot establish.
- Page appearance and browser-computed geometry use the replay-driven
  WebKit cases of `koa/visual/`. Host-state changes alone must not
  rewrite page snapshots.
- Native focus, menus, editor floats, the bridge and the real serve
  path use the app's tests in the VM
  ([build.md](build.md#the-visual-test-vm)). Browser mode is not
  their substitute: it has no `window.ko`, native theme or native
  sandbox, so a browser test does not prove that body transport,
  focus, keys, clipboard and previews work.

## Fake ko and fake model

`koa/testdata/fake_ko/` is a Rust workspace member built by
`make build-fake-ko`. It decodes and encodes real ko protocol types,
so wire changes fail its build. Files drive message arrival and gates;
stdin receives acknowledgements. Deliberately malformed messages use
the fixture's raw-feed path. Runtime exec tests run the requested argv
with only the requested environment. A separate integration case
checks the same exec client against a real command runtime.

`koa/koa-fake-provider.ts` is an HTTP model provider, not a fake pi
process. It speaks the OpenAI completions stream and scripts text,
thinking, tool argument chunks, errors and held replies. It rejects
unexpected request methods, paths, authorization, models and script
exhaustion and records violations. Tests release named gates and check
requests. Private model settings use a literal test key, so no real
credentials or model service is needed.

Use real session files for saved history and small test extensions
for dialogs, startup UI and extension errors. Do not enlarge a fake
model to invent host facts.

## Replay scenarios and snapshots

`koa/testdata/replay.ts` is a test server, not a product mode. It
serves the built page through `assemblePage` and the SDK without
loading pi. `koa/testdata/scenario.ts` types scenario steps against
PageRecord and `koa/page/http.ts`. Shared scenario data belongs in
`koa/testdata/scenario-parts.ts` only when several scenarios use it.

A script opens with records, then expects either an explicit advance
or one page request. A request step can send records before and after
its typed reply, and hold that reply until released. Unexpected method,
path or checked body produces a mismatch, not a successful default.
The test must finish with every step consumed, no mismatch and no
held reply. File and attachment requests use the product's serving
modules rather than a permissive mock. `koa/koa-replay.test.ts`
checks this harness.

Add new states as typed steps under `koa/testdata/scenarios/`.
Stable path names and explicit clock seams make captures deterministic.
A new state does not require a model recording or a product test flag.
Use one fixture with multiple phases for related states and resize it
for width changes instead of restarting the whole chain.

`koa/visual/Cases.swift` assigns capture policy;
`koa/visual/Capture.swift` crops the union of matched selectors
at the image's backing scale. Missing or out-of-page rectangles fail,
not clamp. Insets include borders and shadows. Most images cover a
component; composition anchors cover the whole page. Geometry-only
states keep their assertions without a redundant image. Capture stable
states, not an uncontrolled animation frame.

The app's `WebviewPaneTests` checks the generic sandbox and WebKit
constraints. The test files, not a duplicated method list, define
coverage.

## Host visual checks

`koa/visual/` is a SwiftPM executable that uses only AppKit and
WebKit: no app sources, no GhosttyKit, no ko_client and no Xcode
project. `make -C koa visual-build` builds it into
`build/koa-visual/`; `make -C koa visual` builds the page and the tool
and runs every fixture. It runs only on the host, never in the VM or
in CI. The decision: the page renders in WebKit alone, so the app's
pane, bridge and native chrome do not belong in its references, and a
host run takes seconds instead of a VM run of the whole app.

The tool opens an off-screen window with prohibited activation and
fails if it becomes the active or frontmost application or takes the
key window. Other applications can change focus while it runs: the
user works on the same Mac. Each fixture starts its own
`koa/testdata/replay.ts --browser --headless` process, which the tool
owns: it reads the page URL from the first line, fails on an early
exit or a missed deadline, checks that the replay consumed every step,
and terminates only that process. A page gets an explicit viewport
size in whole points and its initial scripts through its own WebKit
configuration. The tool sets one time zone (`timeZone` in
`koa/visual/Context.swift`) for the replay process and the page, so
the captured times do not depend on the host's zone. It prints one flushed line per fixture, so
`scripts/quiet-limit 60` sees progress, and a summary line `VISUAL
pass=N diff=N missing=N errors=N` at the end.

The theme is data, not a terminal: `koa/testdata/theme-light.json`
and `koa/testdata/theme-dark.json` hold what `WebviewTheme` in the app
gives a pane (colours, palette, font, cell metrics, appearance and
inset). The tool installs it as the pane's `window.ko` theme at
document start and switches it for the dark phases. The app's
`WebviewThemeTests` checks that `WebviewTheme`'s data for the bundled
light and dark themes, with a fixed font configuration and accent
colour, equals these files, so a change of the app's theme output
fails there first.

Native behaviour (the bridge, pane chrome, native find, focus, preview
and the pasteboard) is the app's to test, not koa's.

One set of references is committed in `koa/visual/__Snapshots__/`,
recorded on the user's Mac with this tool. A missing or different
reference fails the run; the actual image and the difference go to
`build/koa-visual/output/`. Select a fixture or capture with `ONLY`;
all phases of a selected fixture still run. A geometry-only fixture
runs only when it is named. Record with `RECORD=1`. Image comparison
uses the colour-space conversion in `koa/visual/Pixels.swift`.

```sh
make -C koa visual ONLY=Fixture
make -C koa visual ONLY=Fixture RECORD=1
```

Use actual names from `koa/visual/Cases.swift`. Record the affected
images once after the last implementation and review change, then
inspect them.

## Measurement

`koa/page/metrics.ts` instruments only metrics mode. The report
separates receipt, frame scheduling and frame work; a frame timestamp
is not proof of completed paint. Timing and probe passes are separate
because DOM instrumentation changes cost. The probe counts geometry
reads after writes and working-mark detachments. Chrome heap and
WebContent physical footprint are different measures and must not be
compared as the same quantity.

Loaded history remains in the model while DOM windowing limits
mounted rows. Measurement must distinguish those two costs.
