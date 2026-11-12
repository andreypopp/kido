# koa only: the harness extension becomes a part of koa

The user decided: "we abandon `ko-pi` and focus on `koa`; `ko-pi.ts`
becomes a part of `koa`". This plan says what that means for each
place that today dispatches on `ko-pi`, terminal pi or koa, what the
new layout is, what a user loses, and the units of work. Base:
`main` at f44b8156.

Open questions are marked **Q**. Each has a recommendation. The
units below assume the recommendations.

## What exists today

`share/pi/ko-pi.ts` (3224 lines) is the one pi extension: the agent
tools, the message stream, the registry in the pi session, jobs, the
routed runtime mode, the pane variables and the peers client. Two
programs load it:

- the shim `share/ko/bin/ko-pi`, which runs the real pi in the pane's
  terminal with `--extension ko-pi.ts` and `PI_IMAGE_PROTOCOL=kitty`;
- `koa` (`share/koa/koa.ts`), which runs `pi --mode rpc --extension
  ko-pi.ts --extension koa-sessions.ts --harness koa|koa-browser`
  and renders the session through a webview page.

The extension learns its host from the `--harness` flag. With the
flag, `spawn_agent` starts a child as `ko shell -- koa [--browser]`;
without it, as `ko shell -- ko-pi`. Everything else of a child is the
same in both hosts. `share/pi/` holds the extension, its suite
(`ko-pi-*.test.ts` on the fake ko of `testdata/fake_ko/`), its
fixture, `ko-api.d.ts`, the ko skill, the prompt fixture, and six
modules that koa imports at run time (`text.ts`, `agents.ts`,
`token.ts`, `records.ts`, `completion-context.ts`,
`runtime-exec.ts`).

ko itself (the server, `ko_client`, `ko_tui`, Kido.app) never names
`ko-pi` or `koa`. A pane is a `PiAgent` when its OSC 7501 root has
`app=pi` and the pane holds `pi.session`; a `SomeAgent` when it has
the root alone. pi's own interactive mode writes the root
(`program-status-reporter.js` in pi 1.5.0); koa writes it itself for
its RPC pi; the extension writes `pi.session`, `pi.name`,
`pi.activity` and `pi.runtime`. No Rust, Swift or e2e code changes in
this plan.

## The decision in one rule

koa is the one pi harness. The extension is koa's extension inside
koa's pi child, as `koa-sessions.ts` already is. There is no other
loader, so every code path that exists only for pi's terminal UI
goes, and every dispatch on "which host" goes with it. A pi that the
user starts as plain `pi` is not Kido's harness: it stays a
`SomeAgent` through pi's own OSC 7501.

## Every dispatch, and what happens to it

| Place | Today | Decision |
|---|---|---|
| `share/ko/bin/ko-pi` | the terminal loader | delete |
| `share/ko/bin/koa` | checks node 24 and pi, execs `koa.ts` | keep |
| `--harness` flag (`ko-pi.ts:1136`, `:2335`, `:3018`, `:3180`; `koa.ts:282`) | `undefined` = terminal, `koa`, `koa-browser` | delete; a boolean flag `--koa-browser` that only koa passes replaces the browser case (**Q5**) |
| `spawn_agent`'s argv (`ko-pi.ts:2334-2337`) | `ko shell -- ko-pi` or `-- koa [--browser]` | always `ko shell -- koa`, `--browser` when the parent runs in browser mode; `--runtime NAME` unchanged |
| toplevel vs child, `resume_from`, `fork`, the registry, the notices | host-independent | keep, unchanged |
| the routed mode (`--runtime`, `startRouted`, the seven routed tools, `user_bash`) | host-independent; the refusal text names `ko-pi` (`:2977`) | keep; text says `koa` |
| the inside mode (`pi: "runtime"`, `inside` in `createPane`) | child runs `ko shell -- ko-pi` inside the runtime | keep as `koa`; the image now needs node 24 and pi (**Q6**) |
| peers (`/client` stream of a top-level host pi) | host-independent; hello name `ko-pi` (`:1306`) | keep; hello name `koa` |
| status sources (`pane_kind.rs`, `pane_status.rs`, `ko_client`, `KoSchema.swift`) | `app=pi` root plus `pi.session` | keep, unchanged; koa writes the root, the extension the variables |
| `pi.*` variable writes, the conditional delete, the `exit` handler | host-independent | keep |
| the message renderers (`:2446-2485`), `handleClick` (`:225-235`), `inboundExpanded`, `tuiMode` | TUI only; koa reads `details` | delete |
| the pending-notice widget (`:1605-1630`, the second half of `message_start` `:2486-2495`) | TUI only | delete; `deliverNotice` keeps the message and its details |
| `ko-job-hint` widget, ctrl+b `onTerminalInput`, `call.move("key")`, the `hint` state of a bash call (`:2019`, `:3087-3095`, `:3192`) | TUI only; koa has no key path | delete; the 60 s move and the `/reload` move stay |
| the `@` autocomplete provider (`:3047-3072`) | TUI only; `koa-complete.ts` has its own over `agents.ts` | delete |
| `@earendil-works/pi-tui` import, `rawKeyHint`, `MessageRenderer`, `Theme` | TUI only | delete; `pi-tui` leaves the devDependencies if no file imports it (`koa-resume.ts` still does) |
| `ctx.ui.notify`, `ctx.hasUI`, the `active` rule | RPC mode has a UI; `pi --print` has none | keep |
| `project_trust`, `resources_discover` (the skill), `before_agent_start` (the guideline) | host-independent | keep; the skill directory moves with the file |
| `PI_IMAGE_PROTOCOL=kitty` in the shim | for pi's TUI | delete (**Q7**) |
| `koa-sessions.ts` relay of the restart state, `koa-identity.ts` exclusion of `ko-pi.ts` | koa | keep; the exclusion names the new file |
| `koa-commands.ts` deferral text "ko-pi did not answer" | koa | text says the extension |
| session entry types `ko-pi.*`, `ko-pi.task`, `Symbol.for("ko-pi.jobs")`, `/tmp/ko-pi/`, `__koPiExtensionCopy` | names | rename to `koa.*` (**Q4**) |
| the ko_tui and remote clients | a koa pane shows `[webview]`; a ko-pi pane shows pi's TUI | no terminal harness remains (**Q1**) |
| Makefile (`build` copies `share/ko/pi/`; `KOA_SRC`; `preview-pi`; `SHARE`) | two directories | one directory, `share/ko/koa/` |
| `scripts/lint.sh` (`signal_sites`, `core`, the doc list, the schemas path, the prompt fixture path) | `share/pi/...` paths | new paths; the suite's files exempt from TS hygiene (**Q8**) |
| `scripts/checks.sh` table (`share/pi/*` row) | | row goes |
| `scripts/test-ts.sh` (cd `share/pi`, two `npm ci`, the file list) | | cd `share/koa`, one `npm ci`, one glob |
| `scripts/dump-prompts.ts`, `scripts/release.sh`, `scripts/ci-like.sh` | `share/pi/...` paths | new paths |
| `Cargo.toml` member `share/pi/testdata/fake_ko` | | `share/koa/testdata/fake_ko` |
| CI | runs `make verify`; no `ko-pi` reference | no change |
| release | "removed command needs a minor bump"; release notes say restart panes when the harness changed | ko gets a minor bump; Kido.app releases after it (the bundled harness) |
| docs, README, AGENTS.md | name `ko-pi` as the harness | rewrite, listed under "Docs" |

## The new layout

`share/pi/` goes (**Q2**). `share/koa/` holds everything:

    share/koa/
      koa.ts, koa-*.ts          the program and its modules, as today
      koa-agent.ts              the extension in koa's pi child (ko-pi.ts, renamed; Q3)
      koa-sessions.ts           the second extension, as today
      text.ts, agents.ts, token.ts, records.ts, completion-context.ts, runtime-exec.ts
                                the modules that koa, its page and the extension share
      ko-api.d.ts               generated by make schemas
      skills/ko/SKILL.md        the ko skill, beside the extension that discovers it
      koa-agent-fixture.ts, koa-agent-*.test.ts
                                the extension's suite (ko-pi-fixture.ts, ko-pi-*.test.ts)
      agents.test.ts, koa-webview-sdk.test.ts
      testdata/fake_ko/, testdata/ko-prompts.txt
      package.json, package-lock.json, tsconfig.json
                                one package: the page's dependencies and the
                                devDependencies of share/pi (pi-coding-agent,
                                typebox, @types/node, openapi-typescript, redocly)
      page/, stress/            as today

Installed: `share/ko/koa/` with every file of `KOA_SRC` plus the
shared modules, `ko-api.d.ts`, `skills/` and the built page.
`share/ko/pi/` does not exist. The static Linux layout follows,
because `SHARE` lists `koa`. Imports `../pi/x.ts` in koa and the
page become `./x.ts`; the `page.js` rule's prerequisites follow.

**How koa loads it.** `spawnPi` in `koa.ts` runs `pi --mode rpc
--extension <koa>/koa-agent.ts --extension <koa>/koa-sessions.ts
[--koa-browser] <pi arguments>`. The restart rule of `koa-args.ts`
keeps `--runtime` and the pi arguments as today. `koa --runtime NAME`
is the routed mode, unchanged in behaviour.

**Browser mode (Q5).** The extension registers `koa-browser` as a
boolean flag. With it, `spawn_agent` adds `--browser` to the child's
`koa`. Without the flag the child is a pane koa. The rule "a child
takes its parent's harness" becomes "a child takes its parent's
mode".

**`koa-sessions.ts` and `koa-agent.ts` stay two extensions.**
`koa-sessions.ts` owns fd 3 and is loaded again on a folder switch;
the agent extension claims one copy for each process. A merge is a
later simplification, not part of this plan.

## What a user loses

- **The `ko-pi` command.** A pane that runs `ko-pi` after the
  upgrade gets "command not found". A terminal pi pane that runs
  across the upgrade keeps its loaded extension until `/reload`,
  which then fails because the file is gone: the user restarts the
  pane as `koa`.
- **pi's terminal UI with the harness.** In Kido.app the page
  replaces it. In `ko_tui`, on a server that a terminal client
  attaches to, and in a pane of `ko HOST` viewed from a terminal, a
  koa pane shows only `[webview]` and one line; the page needs
  Kido.app or `koa --browser` on the host where koa runs (**Q1**).
  Plain `pi` still works there as a `SomeAgent`: status, title and
  `ko prompt` by paste, no tools and no messages.
- **The kitty image default** of the shim (**Q7**). A plain pi shows
  images by its own settings; koa's page shows them itself.
- **Agents inside a runtime image without node 24** (**Q6**).
- **The recorded registry of sessions written before the rename**
  (**Q4**): in a session resumed from before, `list_agents` shows no
  recorded child or peer, `read_report` finds no report, and an
  ended child cannot restart by name. A live child still lists
  through its row's `parent` and takes a message by session id. A
  `ko-pi.task` set by an old parent is not read. Nothing else in a
  session file changes: the conversation, the model and pi's own
  entries stay.
- **`make preview-pi`'s name** stays; its list changes.

`ko ssh` to a host without ko is not affected: nothing of Kido runs
there today, and a remote pi stays a `RemoteKind::Agent`.

## Questions

- **Q1. Terminal clients.** Accept that no terminal harness remains:
  `ko_tui` and a terminal view of a remote server show a koa pane as
  `[webview]`, and the page is Kido.app's or the browser's.
  Recommendation: yes, and design-koa.md's non-goals say so. The
  alternative, a terminal rendering of koa, is the UI the decision
  abandons.
- **Q2. One directory.** Dissolve `share/pi/` into `share/koa/`: one
  package, one lockfile, one tsconfig, one suite, one installed
  directory. Recommendation: yes. "What ko-pi and koa share" has no
  meaning when the extension is koa's. The alternative keeps
  `share/pi/` as "the modules that koa and its extension share",
  which is every file in it.
- **Q3. The file's name.** `koa-agent.ts`: the agent side of koa,
  which runs inside pi. Recommendation: that name. Alternatives:
  `koa-harness.ts` (but the docs call all of koa "the harness"),
  `koa-tools.ts` (it is more than tools).
- **Q4. The names in session files and variables.** Rename
  `ko-pi.agent`, `ko-pi.work`, `ko-pi.report`, `ko-pi.ended`,
  `ko-pi.sent` to `koa.*`; `ko-pi.task` to `koa.task`;
  `Symbol.for("ko-pi.jobs")` and `/tmp/ko-pi/` likewise.
  Recommendation: yes, in unit 2, with the loss above. AGENTS.md
  forbids a migration, and a name `ko-pi` that survives only in
  session files and a variable is a ghost that every doc must still
  explain. The alternative keeps the strings and loses nothing.
- **Q5. The browser mode's flag.** A boolean pi flag `--koa-browser`
  that koa passes, instead of `--harness koa-browser`.
  Recommendation: that. The alternative, an environment variable in
  the pi child, breaks "koa adds nothing to pi's environment" and
  leaks into every job.
- **Q6. The inside mode** (`pi: "runtime"`). Keep it as `ko shell --
  koa` inside the runtime, which needs node 24 and pi in the image.
  Recommendation: keep; the webview serve stream already works from
  a runtime pane (design-webview.md, "Remote servers and runtimes").
  The alternative deletes the mode, the `pi` key of the runtime
  configuration and the `inside` branches, which is a server change
  and a second decision.
- **Q7. `PI_IMAGE_PROTOCOL=kitty`.** Drop it with the shim.
  Recommendation: yes; a plain pi is not Kido's harness.
- **Q8. TS hygiene of the moved suite.** `scripts/lint.sh` forbids
  `as`, `any` and `!` in `share/koa/*.ts`; the moved suite and its
  fixture have 288 such sites. Recommendation: unit 2 exempts
  `koa-agent-*.test.ts` and `koa-agent-fixture.ts` by name, and a
  later unit cleans them. The alternative cleans them in unit 2 and
  roughly doubles it.

No question needs @kido-app-design: the page does not change.

## Units

Each unit leaves `main` green and goes through the full process of
AGENTS.md ("One manager for each unit of work"): planner,
implementer, the six reviewers, `scripts/checks.sh`.

### Unit 1: one harness (behaviour)

Delete the terminal host. Files: `share/ko/bin/ko-pi`, `ko-pi.ts`,
the tests that assert TUI behaviour, `koa.ts`'s `spawnPi`, the koa
tests that assert the spawn argv, the docs.

Tests that must fail first:

- `ko-pi-spawn.test.ts`: a `spawn_agent` without any flag starts
  `ko shell -- koa`; with `--koa-browser`, `-- koa --browser`.
- `koa-program-transcript.test.ts:458` and
  `koa-program-startup.test.ts:109`: the argv has no `--harness`
  and, in browser mode, `--koa-browser`.
- the fixture's fake pi refuses `setWidget`, `onTerminalInput`,
  `addAutocompleteProvider` and `registerMessageRenderer`, so a test
  shows that the extension no longer calls them. One assertion in
  the identity test is enough.

Tests that only pass: the moved 60 s job rule in `ko-pi-bash.test.ts`
without its ctrl+b cases; `ko-pi-inbound.test.ts` on the message
details, without the collapse and expand cases;
`scripts/dump-prompts.ts` with `make prompts` (the texts that name
`ko-pi` change).

Changes: the table above, rows one to the `koa-commands.ts` text.
`share/pi/package.json` drops `pi-tui` if no file imports it.

Docs in this unit (the manager writes them): README.md "Agents" (one
entry point); AGENTS.md "The harness is one pi extension" (koa's
extension, its path), "Native agent status", "Signals", "Releasing";
design.md "The pi extension, ko-pi" (becomes "The harness
extension"; the shim paragraph goes; plain `pi` paragraph stays),
"The login environment", "Ending a child", "The bin directory"
(three shims: `ko`, `ssh`, `koa`), "Install layout", "Decisions";
design-subagents.md ("The tools", "What a child is given", "Jobs
across /reload", "A human at a shell": `koa` in a pane starts a
top-level agent; "A job's row": the writer runs in RPC mode only);
design-koa.md (goal 2, non-goals with Q1, "The spawn", "A child
takes its parent's harness" becomes the mode rule, "ko-pi inside the
RPC pi", "/reload" layer 2, "Agent lines"); design-runtimes.md
"Agents in a runtime" (`koa --runtime NAME`; the inside mode's
needs); design-program-status.md "Sources" and `SomeAgent`;
design-webview.md's references; release.md ("the koa that Kido.app
bundles"); `.pi/prompts/release.md` steps 2 and 5;
`app/design/sidebar/NOTES.md` and `app/design/koa/NOTES.md` where
they name ko-pi as the writer.

Estimate: one agent-day. Planner 1 h; implementer 5 h; reviewers
1 h in parallel; findings 1 h; docs 2 h; checks 30 min.

### Unit 2: the move

No behaviour change. Move `share/pi/` into `share/koa/` by the
layout above, rename `ko-pi.ts` to `koa-agent.ts`, the fixture and
the tests to `koa-agent-*`, `ko-pi-webview-sdk.test.ts` to
`koa-webview-sdk.test.ts`. With Q4, rename the entry types, the task
variable, the jobs symbol, the tmp directory and the global, and the
prompt fixture's texts.

Tests that must fail first (Q4 only): `entriesOf(s, "koa.agent")` in
the spawn and report tests; the task variable's name in
`agents.ts`'s test; the log path in the async-bash tests.

Changes: Makefile (`build`, `KOA_SRC`, the `page.js` prerequisites,
`preview-pi`, `api-docs`, `schemas`); `Cargo.toml` member;
`fake_ko/Cargo.toml` paths; `scripts/lint.sh` (`signal_sites`,
`core` with the Q8 exemption, the doc list drops
`share/pi/README.md`, `ko-api.d.ts` and the prompt fixture paths);
`scripts/checks.sh` table; `scripts/test-ts.sh`;
`scripts/dump-prompts.ts`; `scripts/release.sh`; `scripts/ci-like.sh`
(one node_modules volume); `koa-identity.ts` (one directory, the
extension excluded by name); every `../pi/` import; both
`tsconfig.json`s; `share/pi/README.md` deleted (design.md and
design-subagents.md hold its content); the installed layout.

Docs: build.md ("The installed layout", "The share tree"),
design-koa.md "Where koa lives", design-subagents.md (the entry
names, "The registry"), design.md "Install layout",
verification.md (the ci-like volumes, "Unit tests" if it names the
suite), AGENTS.md (the paths in "The harness is one pi extension",
"Signals", "Tests"), README.md "Development".

Estimate: half an agent-day, plus 3 h with Q4.

### Unit 3: release

After unit 2 is on `main`: a Kido.app release first (the bundled
harness changed), then `scripts/release.sh` with a minor bump,
because the command `ko-pi` is removed; the script does not detect a
shim's removal, so the version is the user's. The release note tells
the user to restart every terminal pi pane as `koa`. This is the
`/release` sequence, not a unit of code.

### Later, not in this plan

- Clean the moved suite to the hygiene rule and drop the exemption
  (Q8).
- Merge `koa-sessions.ts` into `koa-agent.ts`.

## A defect seen on the way

`docs/design-runtimes.md` ends in the middle of a sentence ("Skills,
prompt templates, project `.pi/` resources and `@`") and its last
line is a pasted tool note ("[Showing lines 1-923 of 1230 ...]").
The text after that point is lost on `main` since f76b6f6e. The
docs edit of unit 1 touches that section, so the manager restores
the paragraph from the commit before f76b6f6e.
