# Page snapshots from recorded records

`KoaWebviewTests` (`app/VisualTests/KoaWebviewTests.swift`) snapshots
koa's page in a real WebKit. Today each of its tests runs the whole
chain: a private ko server, koa, a pi (the scripted `koa-fake-pi.ts`
on `main`; a real pi over the fake provider in unit 3 of
[koa-subagents.md](koa-subagents.md)) and the page. The chain is the
problem: a host change moves page snapshots that the page did not
change. Unit 3 moved 141 snapshots and cost 3.5 hours; unit 4
rewrites the host again.

The user decided: the page tests test the page against recorded page
records, not a live pi. A page snapshot moves only when the page's
code or the page-record format changes.

## Decisions

1. **The replay server is a test program beside koa's test data,**
   `share/koa/testdata/replay.ts`, not a mode of koa. It serves the
   page that koa serves (`assemblePage`), speaks the page's routes
   from a typed scenario script, and runs in a pane through the
   webview SDK as koa does. It is not installed and loads no pi. A
   mode of koa would put a test path and its `--replay` flag into
   the product, and would still start the SDK and read pi's package.
2. **Scenario scripts are TypeScript, typed against
   `koa-records.ts`,** in `share/koa/testdata/scenarios/`, one module
   for each scenario of `KoaScenario`. The records are `PageRecord`
   values and the canned route answers are the page's own route
   types, so a change of the record format fails `tsc` in the `ts`
   stage, never silently. The scripts are recorded once, in the
   migration, from the chain of unit 3, with a tap in the page; the
   tap goes with the migration. After it, a new scenario is written
   by hand from the types, as `koa-dom.test.ts` writes its records.
3. **Four tests keep the real chain,** in one class
   `KoaHostTests`: startup and the interrupt, the editor float
   (Control-G), one lifecycle test (a prompt through the real feed,
   `/quit`, the pane back to the terminal) and the feed's held tail.
   Every other behaviour of the host that the page tests checked on
   the way moves to the TypeScript suite ("What leaves the visual
   suite").
4. **One ko server and one page for each test, as today.** The chain
   is not where the time goes ("Speed"): the replay server starts in
   about 150 ms and the ko server in less. A page shared across tests
   makes the tests order-dependent and the scenario one long script.
5. **The Kido.app side stays exercised** because the replay page is a
   real webview pane: the scheme handler, `window.ko` (`local`,
   `focus`, `preview`), the theme properties, `visualInitialScript`,
   the native drop and Quick Look go through the same code as with
   koa. `testKoaWebviewComposerFocus` runs on the replay page; the
   editor float runs on the real chain because the float is koa's.
6. **The unit lands after unit 3 and before unit 4,** and the
   migration moves no snapshot, with one exception that the user
   decided, the `latest` and `reveal` tests ("Migration").

## The replay server

`share/koa/testdata/replay.ts`, a Node program. Arguments: the
scenario module's path and the scenario's directory (assets, uploads).

- **The page.** `GET /` answers the document that `assemblePage`
  builds from `share/ko/koa/` of the build, with the `koa-instance`
  meta. The meta insertion moves from `koa.ts` into
  `assemblePage(location, instance, metrics?)`, so koa and the replay
  have one source. The page thus comes from the same built files that
  koa serves, so a page change is in every snapshot.
- **The pane.** `webview({ target: "pane", ko })` of
  `share/webview/index.ts`, then `show()` when `supported`, as koa
  does. The server listens on `view.socketPath`. `SIGTERM`, `SIGINT`
  and `SIGHUP` close the view and exit.
- **The feed.** `GET /events` answers `text/event-stream`. The first
  open gets the scenario's `open` records (a `reset` and a `state`,
  as koa's feed sends them), then every record that a step pushes.
  A reopen with `epoch` and `after` gets nothing new: the scripts
  have no gap, and a page that reconnects after a lost stream is the
  lifecycle test's business, not a page scenario's. A `koa` query
  that names another instance gets `reload`, as in koa, so a page
  that comes back from the back/forward cache behaves as with koa.
- **Steps.** The script is a list of steps. The server holds the
  index of the next step. A step is one of:

      type Step =
        | { on: "next"; records: PageRecord[] }
        | { on: Expect; before?: PageRecord[]; reply: Reply; after?: PageRecord[] }
      type Expect = { method: "GET" | "POST"; path: string; body?: (value: unknown) => boolean }
      type Reply = { status: number; json: object; hold?: string }

  `on: "next"` runs when the test posts `/replay/next`; this replaces
  today's `advance()`, which posted `/prompt` with the text `next` to
  make the fake pi emit its next events. `on: Expect` runs when the
  page's request matches: the server pushes `before`, writes the
  reply, then pushes `after`. A reply with `hold` waits until the test
  posts `/replay/release` with that name (the sessions scenario's
  `loading` state, the pending completion, the upload that stops at
  18 MB). A request that matches no step, or that arrives before its
  step, gets 409 with a text that names the expected and the actual
  request, and the server counts it. `GET /replay/status` answers
  `{ step, mismatches }`; the Swift helper asserts at the end of each
  test that the script ran to its end with no mismatch.
- **Routes with a body of their own.** Three routes do not fit a
  canned answer, so the replay reuses koa's modules on them:
  `attachments()` of `koa-attach.ts` for `/attachments` and the chunk
  uploads (the native-drop header, the limits, the states; the
  attachments scenario uploads 41 MB in 55 chunks, which no script
  should spell out), `stepFile` for `/steps/{seq}/{block}/file` with
  a `pathAt` that reads the scenario's items, and `serveFile` of
  `koa-http.ts` for `/images/{id}` from the scenario's directory. The
  POST content-type rule of koa (415) applies to every route, so the
  page's bodies are checked as koa checks them.
- **Types of the routes.** `koa-records.ts` gets one map type of the
  page's routes, request body and response:

      export type Routes = {
        "/prompt": { request: PromptRequest; response: PromptResult };
        "/sessions/list": { request: { scope: SessionScope }; response: { rows: SessionRow[] } };
        ...
      }

  `page/http.ts` derives its `fetchJSON` overloads from it, and
  `Reply.json` of a step for path `P` is `Routes[P]["response"]`. The
  type exists in `http.ts`'s overloads today; the map makes it one
  source that the server, the page and the scripts share. The user
  agreed to this widening; `koa.ts`'s body validators stay as they
  are.

A scenario module exports one value:

    export const scenario: Scenario = { open: PageRecord[], steps: Step[], files: Record<string, string> }

`files` maps a served path (`/images/light?e=…&r=1`) to a file name
in the scenario's directory; the Swift test writes the PNGs there, as
it draws them today.

## The Swift side

`koaWebview(width:height:scenario:captures:)` keeps its captures and
its DOM checks. What changes:

- The pane command is `node replay.ts <scenario> <dir>` with the
  checkout's `share/koa` on PATH, instead of the koa command line and
  its clock and fake-pi variables. The `now` file and the `clock`
  import go: the replay pushes recorded records whose times are in
  them, and the page's `Date` stays frozen by `visualInitialScript`.
- `advance()` posts `/replay/next`. The scenario-specific POSTs that
  the tests make themselves (`/abort`, `/dialog`, `/prompt` with a
  text, `/sessions/switch`) stay as they are: they are the page's
  routes, and the scripts expect them.
- The pi messages that the Swift file builds (`assistant(...)`,
  `result(...)`, the markdown, the queue, the dialogs) go: the
  records live in the scripts. The Swift file shrinks by about the
  700 lines that build messages and steps.
- The completion scenario's ko layout (the three agent panes with
  `pi.name`) goes: the replay answers `/complete` from the script.
  The server-side rule (koa's `agentDiscovery` over `GET /layout`)
  has its test in `agents.test.ts` and `koa-complete.test.ts`.
- The per-test assertion of `/replay/status`.
- `KoaHostTests` gets the four real-chain tests, on the fixture of
  unit 3 (`KoaFixture.swift`: the fake provider, the seeded sessions,
  `visual-ext.ts`). `KoaWebviewTests` no longer imports it.

## What leaves the visual suite

A page test on recorded records no longer proves these host facts.
Each one has, or gets, a test in `share/koa/`:

| Host fact | Test |
| --- | --- |
| Removing a path chip never deletes the original; the native-drop header; the upload limits | `koa-attach.test.ts` (present) |
| `@name` completion lists the named running agents of the ko session, not koa's own | `agents.test.ts`, `koa-complete.test.ts` (present) |
| `/sessions/list` rows, the switch, the `loading` phase, the 409 of a stale body | `koa-program-session.test.ts` (present) |
| The live `!` command's state records, the cap, the cancel | `koa-transcript.test.ts`, `koa-program-session.test.ts` (present) |
| The built-ins' outcomes (`/copy`, `/export`, `/session`, `/compact`, a refused built-in) | `koa-program-commands.test.ts` (present) |
| The dialogs' timeout and the answer's shape | `koa-program-*.test.ts` (the implementer checks; adds a case if absent) |
| The exit card after a failed start | `koa-program-session.test.ts` (present after unit 3) |

The implementer lists, in its report, each host assertion that the
old visual tests made and the TypeScript test that holds it; a fact
without a test gets one in the same unit.

## Migration

The unit starts when unit 3 is on `main`, so the records come from
the host that unit 4 changes next.

1. **The tap.** `visualInitialScript` gets, for one run, a script
   that wraps `EventSource` and `fetch`: every SSE record and every
   request with its response body go into `window.koaTrace`, in
   arrival order, with a marker for each `advance()`. At the end of
   each test, the Swift helper writes the trace to the test's
   directory and copies it under `app/build/koa-traces/<test>.json`.
   One recording run of the whole class (`make -C app visual
   ONLY=KoaWebviewTests KOA_TRACE=1`): this is the unit's first
   visual run.
2. **The generator.** `share/koa/testdata/trace-to-scenario.ts` turns
   a trace into a scenario module: the records before the first
   request become `open`, each `advance()` marker starts an `on:
   "next"` step, each request becomes an `on: Expect` step with the
   records around it split into `before` and `after`. The output is
   typed TypeScript; `tsc` checks it at once. The implementer then
   compacts the data by hand where it is obviously repeated (the
   `"    row"` lines of a read result become `repeat()`), so the
   modules stay readable.
3. **The cut.** The Swift file loses the message builders and the
   koa command; `KoaHostTests` takes the four real-chain tests.
   `koa-dom.test.ts` stays as it is: it drives `page.ts` under a fake
   document and needs no server.
4. **The check.** The second visual run of the unit records nothing:
   it compares every snapshot with the committed one. The rule: no
   snapshot moves in the migration. A snapshot that moves is a defect
   of the replay (an order of records, a missing `before`, a time in
   a record), and the implementer fixes the script or the server, not
   the snapshot. The user decided the one exception: the `latest` and
   `reveal` scenarios depend on the page's clock and are the ones
   most likely to differ by a frame; if their captures differ, their
   tests are recorded again in the final run. No other snapshot
   moves.
5. **Deletion.** The tap, the `KOA_TRACE` seam and the traces go in
   the same unit, after the scripts exist (the user's decision: no
   permanent recorder; a recorded script drifts to whatever the host
   sent, and a new scenario is written by hand from the types).
   `koa-fake-pi.ts` is gone with unit 3; `KoaFixture.swift` stays for
   `KoaHostTests` and `KoaStressTests`.

After the migration, a record-format change (unit 4 or later) fails
`tsc` in the scripts; the implementer of that change updates the
scripts by the type errors, and snapshots move only where the page
renders differently. A new page state gets a hand-written step, and
its test records its snapshot once, as every page change does.

## Speed

Measured per-test times of `KoaWebviewTests` in the VM, the whole test
with its captures:

| Test | fake pi (`main`, 2026-11-11) | real pi (unit 3, 2026-11-13) |
| --- | --- | --- |
| a foot state (one capture) | 1.1 s | 3 s |
| commands (10 captures) | 2.0 s | 4 s |
| bang (14 captures) | 2.2 s | 5 s |
| completion (6 captures, 3 agent panes) | 4.1 s | 6 s |

The real pi adds about 2 s to every test: its start, its extension
and its sessions. The replay has no pi and no startup helper, and
the completion scenario makes no agent panes. Targets, VM times for
the class of about 70 tests:

- before (unit 3's chain): about 4.5 to 5 minutes;
- after: about 2 minutes for `KoaWebviewTests`, plus about 20 s for
  `KoaHostTests`;
- a page test's fixed cost (server, replay, page load, first idle)
  under 1 s; the rest is its captures, each of which switches the
  appearance twice.

The capture's two appearance switches are the remaining cost; a
cheaper dark capture is a follow-up, not this unit, because every
snapshot must stay still here.

## Units

One unit, one manager, with a planner because the change crosses the
page, the test data and the Swift suite. Two implementers in
parallel, each in its own worktree, after the planner:

1. **The replay server and the scripts** (`share/koa/testdata/`,
   `koa-records.ts`'s `Routes`, `page/http.ts`, `koa-assemble.ts`,
   the generator). Tests: `koa-replay.test.ts` runs the server in
   browser mode on one hand-written scenario and checks the step
   order, a mismatch's 409, a held reply and `/replay/status`.
   Risk: medium. The server is about 200 lines; the risk is in the
   scripts' fidelity, which step 4 of the migration measures.
2. **The Swift side** (`KoaWebviewTests.swift`, `KoaHostTests.swift`,
   the trace seam while it lives). Risk: medium: the file is 2000
   lines of scenario-specific DOM checks that must keep their
   meaning without the message builders.

Visual runs of the unit: one recording run of the whole class, one
check run of the whole class at the end, and `ONLY=` runs of single
tests while the scripts are corrected; a re-record of `latest` or
`reveal` under the exception is an `ONLY=` run with `RECORD=1`. A
third whole-class run needs a reason in the report.

Docs: design-koa.md "Tests" and "Where koa lives", design-app.md
"Testing" (the `KoaWebviewTests` paragraph), verification.md (the
`ts` stage's list), AGENTS.md "koa is the one harness" if the
testdata layout is named there. `make koa-page` builds the page that
the replay serves; `scripts/checks.sh` maps `share/koa/testdata/*`
to `ts` and `visual` of `KoaWebviewTests.swift`.

