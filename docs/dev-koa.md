# koa: development

This doc describes workflow developing code inside `koa/`. The design of koa
is in [design-koa.md](design-koa.md).

## Source layout and types

Start at these owners rather than duplicating their contracts:

- `koa/koa.ts`: program startup, HTTP dispatch and view selection.
- `koa/koa-agents.ts`, `koa/koa-view.ts`, `koa/koa-inbox.ts`: agent
  lifetime, session projection and message delivery.
- `koa/koa-agent.ts`: tools, registry, routed operations and jobs.
- `koa/koa-records.ts`, `koa/records.ts`: page records and extension
  details. 
- `koa/page/`: page composition, editor, Markdown and pure rendering models.
  `koa/page/page.html` is the real DOM structure used by tests.
- `koa/scripts/`: the check entry `test.sh`, the Node gate `node.sh`, the
  lint `lint.py` and the prompt dump `dump-prompts.ts`.
- `koa/testdata/`: fixtures, replay, scenarios, fake ko, themes and the
  prompt snapshot.
- `koa/visual/`: the page's visual checks, a TypeScript runner on
  Playwright's WebKit, with its references in `koa/visual/__Snapshots__/`.

- `webview/ko-api.d.ts` is generated from ko's schema (`make schemas`).
- `webview/index.ts`: pane and browser transports.

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

A checkout needs Node 24 or newer with npm:

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

`koa/Makefile` is the one entry point of koa's checks:

- `make -C koa typecheck` checks all TypeScript code in `koa/`
- `make -C koa lint` other lint checks
- `make -C koa test` runs test suite, `FILE=` runs only the named files.
- `make -C koa check` runs these three above
- `make -C koa prompts` regenerates `koa/testdata/ko-prompts.txt`
- `make -C koa visual` runs the page's visual checks 
- `make -C koa verify` runs `check` and `visual`.

```sh
make -C koa test FILE=koa-scroll.test.ts
make -C koa test FILE="koa-program-session.test.ts koa-webview-sdk.test.ts"
```

`koa/scripts/node.sh`, which every target sources, skips without
Node 24 or newer and scrubs pane identity from the test environment.
Under `KO_TS_TEST_REQUIRED=1`, which CI sets, a missing Node is a
failure. Fixture children get private home and agent directories. A
gate waits for a test action, not elapsed time.

## Choose the test boundary

Write the narrowest test that observes the rule:

- Pure logic (parsers, queues, scrolling, Markdown): the
  `koa/koa-*.test.ts` file of its module.
- DOM presence, order and events: `koa/koa-dom.test.ts`, on the real
  page HTML without CSS layout. Do not assert geometry there.
- Extension tools and the registry: `koa/koa-agent-fixture.ts`, a fake
  pi and host with the fake ko.
- Session, startup, reload and feed behaviour:
  `koa/koa-program-fixture.ts`, the real pinned pi with a scripted
  model.
- Page appearance and browser geometry: a visual case in `koa/visual/`.
- Native behaviour (focus, menus, floats, the bridge): the app's
  tests, not koa's. Browser mode does not replace them.

## Fake ko and fake model

`koa/testdata/fake_ko/` is a Rust program on ko's real protocol types,
so a wire change fails its build. `make -C koa test` builds it, and the
fixtures drive it. `koa/koa-fake-provider.ts` is the scripted model: an
HTTP provider that refuses a request that its script does not expect.
No test needs credentials or a model service.

## Replay scenarios and snapshots

`koa/testdata/replay.ts` serves the built page from a scenario,
without pi. A scenario in `koa/testdata/scenarios/` is a typed list of
steps (`koa/testdata/scenario.ts`): records to send and page requests
to expect. An unexpected request or an unused step fails the run.

`make -C koa visual` runs each fixture of `koa/visual/cases.ts`
against its replay in headless WebKit and opens no window. For a new
state, add the scenario steps, the capture and its policy in
`cases.ts`, and the actions in `koa/visual/driver.ts`. A capture is
compared with its reference in `koa/visual/__Snapshots__/`; the actual
image and the difference go to `build/koa-visual/output/`.

```sh
make -C koa visual ONLY=Fixture
make -C koa visual ONLY=Fixture/capture RECORD=1
```

Record only the captures that you changed, after the last code change,
then open the images.

## Measurement

`koa --metrics PATH` writes the page's rendering metrics
(`koa/page/metrics.ts`); `--metrics-mode` selects the measure.
