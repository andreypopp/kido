# koa: its own formula

Status: design, not built. Base: origin/main a89c2fbbb.

koa gets its own Homebrew formula `koa` and its own release cadence.
ko (`ko`, `ko-bin`) and Kido.app stop shipping koa. The repository
stays one. When the work is complete, the design moves into
docs/design-koa.md ("Where koa lives"), docs/build.md, docs/release.md
and docs/design.md, and this plan is deleted.

## Decisions of this design

1. **Three top-level trees.** `koa/` (from `share/koa/`), `webview/`
   (from `share/webview/`) and `share/ko/` (unchanged). `share/` then
   holds only what ko installs as `share/ko`.
2. **The SDK is ko's; koa ships a copy.** `webview/` stays ko's Node
   SDK: ko installs it as `share/ko/webview`, as today, for other
   programs. koa's build copies the same source beside its program.
   The rule "koa/ and webview/ are siblings in every layout"
   (design-koa.md:122) stays, so koa's `../webview/` imports need no
   change. The reason for the top-level move of `webview/`: a `koa/`
   at the top with `share/webview/` breaks that rule in the checkout.
3. **`ko-api.d.ts` moves to `webview/ko-api.d.ts`.** It is ko's API
   for TypeScript, and the SDK is ko's TypeScript package.
   `webview/index.ts:9` imports it from `../koa/`, which does not
   exist in a ko install without koa. koa imports it from
   `../webview/ko-api.d.ts`, type-only.
4. **The server runs the `koa` of its own PATH.** No shim, no
   configuration key. A missing koa stays a failed start
   (cause `failed`), with the path in the message.
5. **koa needs only a `ko` on PATH at runtime**, which every pane has
   (`share/ko/bin/ko`, first on PATH). The formula does not depend on
   ko.
6. **One formula `koa`, prebuilt, no `koa-bin`.** koa is TypeScript
   and one bundled page: it has no architecture. The release uploads
   one tarball; the formula unpacks it. A container image and a remote
   host install the same tarball.
7. **No compatibility check in code.** See "Compatibility".

## 1. The move

Layouts after the work:

    checkout     koa/  webview/  share/ko/
    koa build    build/koa/bin/koa
                 build/koa/share/koa/koa/      KOA_SRC, page.html, page.css, page.js, skills/
                 build/koa/share/koa/webview/  index.ts, ko-api.d.ts, package.json
    koa install  <prefix>/bin/koa, <prefix>/share/koa/   (the same tree)
    ko build     build/ko/  without share/ko/koa and share/ko/bin/koa

`<prefix>/share/koa` is Homebrew's `pkgshare`, which brew links, so
`bin/koa` finds its program as `${0%/*}/../share/koa/koa/koa.ts`
through the linked directory, and a `brew upgrade koa` changes the
files under a running koa as a Kido.app update does today
(`koa-identity.ts` then makes `/reload` restart it).

Every reference, with its change:

- `git mv share/koa koa`, `git mv share/webview webview`,
  `git mv koa/ko-api.d.ts webview/ko-api.d.ts`.
- **koa's imports of `ko-api.d.ts`**: `koa-float.ts`, `records.ts`,
  `agents.ts`, `runtime-exec.ts`, `koa-agents.ts`, `koa-inbox.ts`,
  `koa-agent.ts`, `koa-agent-fixture.ts`, `koa-editor.test.ts`,
  `agents.test.ts` change `./ko-api.d.ts` to
  `../webview/ko-api.d.ts`; `webview/index.ts:9` to `./ko-api.d.ts`.
  `koa/testdata/replay.ts:6` loses one `../`.
- **`Cargo.toml:3`**: the member `koa/testdata/fake_ko`. The package
  name `fake_ko` and `make build-fake-ko` (`Makefile:222-224`) stay.
- **`Makefile`**: unit 1 only replaces the paths in lines 99-113 and
  125. Unit 2 moves `KOA_SRC`, `KOA_ESBUILD`, `koa-page`, `koa-watch`
  and the `node_modules` rule of koa into a new `koa/Makefile`
  (targets `build`, `watch`, `install PREFIX=`), as `app/` has its
  own. koa's Makefile runs no cargo and no git, so it works in an
  unpacked tarball. The root `%/node_modules/.package-lock.json`
  rule (line 102) stays for `scripts/openapi`. Unit 3 removes `koa`
  from `SHARE` (line 96), the `koa-page` prerequisite of `build`
  (line 119), and `preview-pi`/`unpreview-pi` (lines 69-86) with
  `KOA_FILES`: a preview is `make -C koa install PREFIX=DIR` with
  `DIR/bin` on PATH.
- **`scripts/test-ts.sh:36-54`**: `cd koa`; `make -C koa
  node_modules/.package-lock.json`; `make -C koa build` in place of
  `make -C ../.. koa-page`; the `../../` prefixes become `../`.
- **`scripts/lint.sh`**: the globs of line 101, the signal sites of
  line 102, the prefix test of line 135, the `ko-api.d.ts` output of
  lines 284-286 (`webview/ko-api.d.ts`), the fixture of line 289
  (`koa/testdata/ko-prompts.txt`).
- **`scripts/dump-prompts.ts`**: the imports of lines 16 and 40 and
  the texts of lines 4, 46 and 78. The fixture is regenerated (`make
  prompts`), because it prints the source path.
- **`scripts/checks.sh:83-87`**: the five rows take `koa/` and
  `webview/` for `share/koa/` and `share/webview/`. No row before
  them matches `koa/*` (`ko/*` and `ko_*/*` do not).
- **`scripts/release.sh:61-62`**: the fixture path (unit 1); the
  rest in "The release flow".
- **`scripts/ci-like.sh:194`**, `.dockerignore:3`, `.gitignore:1,3`:
  `koa/node_modules`, `koa/.copy-*`.
- **The suites' own paths**: `build/ko/share/ko/koa` in
  `koa-page.test.ts:89`, `koa-program-transcript.test.ts:50,52,105`,
  `koa-program-reload.test.ts:16-17`,
  `koa-program-lifecycle.test.ts:14`, `koa-program-picker.test.ts:14`,
  `koa-program-commands.test.ts:16,41`, `testdata/replay.ts:25`,
  `stress/run.ts:21,61`, `stress/run.sh:20-26`. Unit 1 changes only
  the number of `../`; unit 2 changes the target to
  `build/koa/share/koa/koa`.
- **Kido.app** has no Xcode phase that copies koa:
  `app/scripts/bundle-ko.py:53` copies `build/ko` whole, so the
  bundle follows the ko layout with no change there. The visual
  tests name the checkout: `app/VisualTests/KoaFixture.swift:7,19,48,60`,
  `KoaWebviewTests.swift:31`, `KoaFocusTests.swift:18`,
  `KoaStressTests.swift:30` (`share/koa/` to `koa/`), and
  `KoaFixture.swift:64` starts `tools.prefix + "/share/ko/bin/koa"`,
  which becomes the checkout's `build/koa/bin/koa` in unit 2. The
  `visual` and `koa-stress` targets of `app/Makefile` then run `make
  -C ../koa build` first, because the app's ko phase no longer builds
  koa after unit 3.
- **Docs** (the manager writes them; `scripts/lint.sh` checks the
  references): `AGENTS.md:296-299, 364-378, 498, 557`;
  `README.md:160-169, 191-192, 214-225`; `docs/design-koa.md`,
  "Where koa lives" and every `share/koa/` path; `docs/build.md:60,
  193-208, 220-226, 383-405`; `docs/design.md:414-422, 850-860, 964`;
  `docs/design-webview.md:144-149, 330`; `docs/design-subagents.md:33,
  75, 729`; `docs/design-program-status.md:213`;
  `docs/design-runtimes.md:1107-1110, 1205-1210, 1248-1252`;
  `docs/design-app.md:2414-2422, 3428-3440`;
  `docs/verification.md:45-47, 150-172, 523-524`; `docs/release.md`;
  `webview/README.md` (its install line stays `brew --prefix ko`);
  `plans/koa.md:16`. `app/design/koa/*.html` are mockups and keep
  their text.
- **`.pi/`**: `.pi/tests/no-git-writes.test.ts` is named only by
  `scripts/test-ts.sh`; `.pi/prompts/release.md` changes in "The
  release flow". `.pi/extensions/` names no path of koa.

## 2. How ko finds koa

**The host.** `Config::koa()` (`ko_server/src/config.rs:274-287`)
becomes one lookup: the first executable `koa` on the server's own
PATH (`ko_sys::file::look_path` over `env_path(&self.env)`), else the
path `koa` beside the server's executable, which then does not exist.
The `bin_dir` arm goes: `--bin-dir` is the shim directory and holds no
koa. The lookup runs for each request, so `brew install koa` needs no
server restart.

`Command::Koa` in `ko_server/src/panes.rs:147-193` keeps its shape:
`entered = is_executable(&path)` and the `ko shell --` wrap (lines
201-205) stay, so koa still starts under the login shell, where
`node` and `pi` are. A missing koa is still the direct exec of a path
that does not exist: cause `failed`, the row stays, `command[0]` is
that path.

**The server's PATH** is the user's login PATH in both starts: the
`ko` launcher writes its own environment into the launchd plist
(design-ko.md, "Lifecycle"), and Kido.app gives the server the PATH
of `LoginPath.read` (design-app.md:159-173). A server whose PATH has
no koa (a failed `LoginPath` probe, an install into a directory that
the login PATH lacks) gets the failed start.

**The error.** `ko-pane` prints `ko: exec: No such file or directory`
(`ko_pane/src/pane.rs:458`). The unit adds `argv[0]` to that line for
every start failure of the exec step (`ko: exec PATH: ...`), so the
screen names koa. No hint text enters the server: the README and the
release notes carry the install command.

**Runtimes** (`ko_config/src/runtime.rs:17-27`). `RuntimeKoa::Host`:
the host rule above, with `--runtime`. `RuntimeKoa::Runtime`:
unchanged in ko (`panes.rs:154`, the bare `koa` under `ko enter`'s
login shell), but the static Linux layout no longer brings koa
(`SHARE`), so the image or the remote host installs koa itself, as it
already installs node and pi: the release tarball unpacked into a
prefix on PATH. design-runtimes.md, "Inside", says so. The end of
such a pane stays the transport's exit.

**Decision reversed.** design.md:964 ("The server runs only its own
koa on the host", 2026-11-17) becomes a new dated decision: the
server runs the koa of its PATH.

**Tests that fail first.** `ko_e2e/tests/e2e/runtime.rs:2947`
(`a_koa_command_runs_the_shipped_koa_...`): the prefix has no
`share/ko/bin/koa`; the fake koa is in a directory of the server's
PATH (the present `stray`, lines 2987-2990, becomes the koa that
runs); the missing case removes it and expects cause `failed` and
`command[0]` beside `bin/ko`. The unit test at `panes.rs:948` gets
the new path.

## 3. What koa needs from ko

- **The `ko` executable**, found on PATH (`findKo`,
  `koa/runtime-exec.ts:171`; `koa-agents.ts:46`; `koa.ts:94`). In a
  pane that is the server's own shim, so koa always talks to the ko
  that runs its pane. Nothing to install.
- **The webview SDK**: koa's own copy ("Decisions", 2). Its contract
  with ko is the command line of `ko webview serve`, as before.
- **`ko-api.d.ts`**: build time and type check only, from the same
  checkout (`make schemas`). It is copied into the install only
  because `index.ts` names it.
- **The shims**: none. `share/ko/bin/koa` is deleted. The new
  `koa/bin/koa` is that file without `shim.sh`: the node and pi
  checks, the OSC title, then `exec node
  "${0%/*}/../share/koa/koa/koa.ts"`. `share/ko/shim.sh` and the `ko`
  and `ssh` shims stay ko's.
- **The ko skill** (`koa/skills/ko/`) stays koa's.

## 4. Kido.app

- The bundle has no koa after unit 3, with no change to
  `bundle-ko.py`. A checkout that built before unit 3 keeps a stale
  `build/ko/share/ko/koa`; the app release runs after `rm -rf
  build/ko`.
- **New Agent** sends the same typed command
  (`app/App/Ko/LayoutEditor.swift:124`). No app code changes. Without
  koa the window shows the failed pane.
- **The shim directory** stays first on PATH and holds `ko` and
  `ssh`. `koa` in a pane is the first `koa` of the user's PATH.
- **Release notes** of the first Kido.app and ko releases without
  koa: "koa is now a separate package. Run `brew install
  andreypopp/tap/koa` before you update, or New Agent and `koa` fail.
  Update koa with `brew upgrade koa`; `/reload` in a koa pane takes
  the new version." The ko formulas' caveats lose their koa line and
  name the `koa` formula.

## 5. The formula and the release flow

**The formula** `Formula/koa.rb`, which the release script writes as
`app/scripts/release.sh` writes the cask: `url` of the release asset
`koa-X.Y.Z.tar.gz` (top-level `bin/` and `share/`), `sha256`,
`version`, `depends_on "node"`, `depends_on
"andreypopp/tap/pi-coding-agent"`, `prefix.install "bin", "share"`,
a caveat (koa runs in a pane of ko, from Kido.app, `ko` or `ko-bin`), and a test `koa --help --pi
/nonexistent`. No dependency on ko: three packages supply it.

**The build**: `make -C koa build` (npm ci, esbuild, the copy) into
`build/koa`; the tarball is that directory.

**The release**: `scripts/release.sh PRODUCT VERSION`, with `ko` or
`koa` as the first argument (`make release PRODUCT= VERSION=`). The
shared parts stay one copy: the arguments, HEAD equal to origin/main,
green CI, the clean taps, the pull, the version increase, the tap
commit and push.

- `ko`: the present body, without the `node` build guard (lines
  44-47; the tap's `ko.rb` drops `depends_on "node" => :build`) and
  without the tool list (lines 61-62 and the `tool:` names): only
  removed commands need a minor bump.
- `koa`: the tool list of `koa/testdata/ko-prompts.txt` against the
  same file at tag `koa/<formula's version>` (no formula: no
  comparison); a removed tool needs a minor bump. Then `rm -rf
  build/koa`, `make -C koa build`, the tarball, the tag `koa/X.Y.Z`,
  its push, `gh release create`, the formula.

`.pi/prompts/release.md`: step 2 decides each product from its own
last release (`git log koa/<version>..<commit> -- koa webview` for
koa); the item "the user's agents run the koa that Kido.app bundles"
goes; a koa release needs no Kido.app or ko release; step 5 tells the
user `brew upgrade koa` and `/reload` (a restart after a removed
tool). docs/release.md gets a section "koa"; AGENTS.md, "Releasing",
names the `koa/X.Y.Z` tags and drops its last sentence.

**Compatibility.** The surface between koa and ko is the `ko`
command line (`ko api`, `ko webview serve`, `ko shell`), the route
shapes, OSC 7501 and the `koa.*` variables. A mismatch is already
loud: `ko api` exits non-zero with `HTTP 4xx` and the server's
message. The protocol major (`ko version`) is not a usable signal: it
is `1.0` after many shape changes, because it changes only by a
manual rule at a release. So the design adds no check to koa. The
one rule is in `/release`: when `webview/ko-api.d.ts` differs between
koa's last tag and the commit of a ko or Kido.app release, koa
releases in the same run, and the notes say to upgrade both.

## 6. Tests and CI

- The TypeScript suite moves with `koa/`; its stage stays `ts`
  (`scripts/test-ts.sh`), and it still needs the built ko
  (`koa-agent-runtime.test.ts:678-680`) and `fake_ko`.
- `scripts/checks.sh`: the rows of section 1.
- `.github/workflows/ci.yml` has no path filter. Its "Install" step
  (line 201) adds `make -C koa install PREFIX=$HOME/koa-install` and
  `koa --help --pi /nonexistent` from there. The node setup steps
  (lines 125, 274) stay: lint, `ts` and the app's visual build need
  node.
- New tests: the e2e change of section 2. The shim and the install
  layout are covered by the CI step and by the suite, which unit 2
  points at `build/koa`.

## 7. Units

Each unit leaves `main` installable. No ko release runs between
units 1 and 3: `scripts/release.sh` reads the fixture at one path.

1. **The move** (about half an agent-day; mechanical, full `make
   checks` because it touches the Makefile and `Cargo.toml`). The
   three `git mv`, the imports, every path of section 1, the docs'
   paths. `make build` still puts koa into `build/ko`, and
   `share/ko/bin/koa` stays. No behaviour changes.
2. **koa stands alone** (about one agent-day). `koa/Makefile`,
   `koa/bin/koa`, the layout `build/koa`; the suites, the stress
   runner and the visual fixtures use it; the root `build` copies
   `build/koa/share/koa/koa` into `build/ko/share/ko/koa` so ko still
   ships koa; `scripts/release.sh PRODUCT`, the release prompt and
   docs; the CI install step. Then the top-level session releases
   `koa 0.1.0`. Inside a pane the bundled koa still wins, so nothing
   changes for a user.
3. **ko drops koa** (about one agent-day; a planner, because it
   changes the server). `Config::koa()`, the `ko-pane` message, the
   e2e test; delete `share/ko/bin/koa`, `koa` from `SHARE`, the root
   `koa-page`, the copy of unit 2 and `preview-pi`; `app/Makefile`'s
   prerequisite; the design docs and the reversed decision. Then the
   releases of ko and Kido.app with the notes of section 4.

## Decisions of the user (2026-11-18)

- A missing koa is a failed pane whose message names `koa` and the
  path searched (unit 3).
- The formula installs the prebuilt tarball (unit 2).
- The formula has `depends_on "andreypopp/tap/pi-coding-agent"`, not
  only a caveat: koa loads pi's SDK from the installed pi
  (`koa/koa-child.ts:19-22`). The caveat names only the ko packages.
- `preview-pi` goes; a preview is `make -C koa install PREFIX=DIR`
  (unit 3).
- The top-level `webview/` with `ko-api.d.ts` in it: accepted.
- The `ko-bin` tarballs: the top-level session builds them by hand
  today; unit 3 adds that step to `scripts/release.sh`, with the ko
  layout without koa.
