# Building Kido

This file describes the build of ko: the crates and their layout,
the toolchain, the platforms, the installed layout under `build/ko/`,
the static Linux ko, the `ko_client` xcframework and the share tree.
AGENTS.md, "Rust", holds the rules that a change can break;
design-ko.md, "Crates", maps the coordinator's modules.
[verification.md](verification.md) describes the checks.

## The crates

One cargo workspace at the root. A package has the name of its
directory, with the underscore.

- `ko/` is the binary `ko`: `ko/src/main.rs` holds the command table
  and the small command bodies, which print and return the exit code.
- `ko_server/` is the coordinator (design-ko.md, "Crates").
- `ko_pane/` is the crate `ko_pane`: the binary `ko-pane`
  (`src/main.rs`) over a library that the `control` fuzz target also
  calls. One `ko-pane` process runs for each pane.
- `ko_pane_wire/` is the frame codec and the ring.
  `ko_pane_wire::frame` is the one source of the frame's constants
  for both processes.
- `ko_wire/` is the crate `ko_wire`: what the server and its clients
  share. It holds the wire types (`protocol`), the ids, the pane
  variables, the HTTP framing, the route declarations and the OpenAPI
  schema, the portable half of the WebSocket (the record parser, the
  upgrade, the frame reader), the exec session's frames
  (`exec_wire.rs`), the ssh grammar, the local endpoint (`local.rs`:
  the state directory and the socket path) and the build id. It has
  no platform gate and no process code.
- `ko_client/` is the client core that `ko_tui` and `ko` use and
  Kido.app links: the launcher, the wire layer, the API client, the
  `/client` model and the SSH remote (`remote.rs`: the portable
  failure classifiers; `remote/desktop.rs`: the master, the forward
  and their cleanup). It never depends on `ko_vt`, libghostty-vt or
  `ko_server` (only the macOS FFI tests take `ko_server` as a
  dev-dependency, for a real server).
- `ko_tui/` is the terminal client that `ko` runs without a command:
  the mirror, the renderer, the input and the tty.
- `ko_shell/` is the crate `ko_shell` that `ko shell`, `ko ssh` and
  `ko server --bin-dir` use: the priming of a local or remote login
  shell, the ssh arguments, the bin directory lookup, and `ko enter`,
  with the exec session's supervisor (`session.rs`). It embeds the
  shell integrations of `share/ko/` with `include_str!`.
- `ko_config/` is the crate `ko_config`: the configuration file
  `config.yaml` (its types, the path rule, the YAML decode in
  `yaml.rs`, the theme writer and its JSON schema; design-ko.md,
  "The configuration file"), the values that the file and the wire
  share (`RuntimeName`, `AbsPath`, ...) and the ssh option classifier
  (`ssh_args.rs`). It depends on no ko crate.
- `ko_vt/` and `ko_vt_sys/` are libghostty-vt: the safe wrapper and
  the generated bindings.
- `ko_sys/` is the OS layer.
- `fuzz/` is the cargo-fuzz crate, a workspace member outside
  `default-members`: clippy checks it on stable, and only `make fuzz`
  runs it.
- `ko_e2e/` is the e2e suite, a workspace member outside
  `default-members` (verification.md, "The e2e suite").
- `share/koa/testdata/fake_ko/` is the crate `fake_ko`, the fake `ko`
  of the TypeScript suite, a workspace member outside
  `default-members` that `make build-fake-ko` builds for
  `scripts/test-ts.sh`. It reads and writes ko's wire only through
  `ko_wire::protocol`'s types.
- `ko_bench/` is the binary `ko-bench`, the benchmark modes, which
  `make build-bench` builds into `target/release` and never installs.

ko has no C of its own; the only C is the measurement helpers of
`bench/`, which `make build-bench` compiles. Every C file of `bench/`
starts with `#define _DARWIN_C_SOURCE` and `#define _GNU_SOURCE`,
before its includes: the build uses `-std=c11`, which hides
`clock_gettime` on Linux.

## The toolchain

`rust-toolchain.toml` pins the toolchain of the pinned Verus release.
They move together. Homebrew's keg-only `rustup` formula supplies it
(`brew install rustup`, then `$(brew --prefix rustup)/bin/rustup
toolchain install`, which reads `rust-toolchain.toml`; with rustup
1.28 or later, `rustup show` installs nothing). Its `bin` is not on
PATH, and Kido does not ask the user to change PATH. The Makefile is
the one place that finds cargo: it puts that `bin` first on PATH, and
it calls `$(CARGO)` by its full path, because make 3.81 on macOS looks
up a recipe's command through its own PATH, not the exported one.
Thus, every cargo command runs through a Makefile target. CI's
toolchain install and `cargo fetch` steps are the exception.

zig comes from PATH, at the release that `scripts/install-zig.sh`
pins with its checksums; it must equal the `.minimum_zig_version` of
`third_party/ghostty/build.zig.zon`, and `scripts/lint.sh` checks
that. CI and `scripts/ci-like/Dockerfile` install zig through the
script. A ghostty bump that changes `.minimum_zig_version` also
changes the script.

`rust-toolchain.toml` also lists the targets
`aarch64-unknown-linux-musl` and `x86_64-unknown-linux-musl` of the
static Linux ko, and `aarch64-apple-ios` and `aarch64-apple-ios-sim`
of `ko_client`'s iOS slices, so `rustup toolchain install` adds them.
For the musl targets, `.cargo/config.toml` names the linker wrappers
`scripts/zig-cc-<arch>-linux-musl` (`zig cc -target
<arch>-linux-musl`) and sets `-C link-self-contained=no`: with
rustc's own `crt1.o`, `_start` is defined twice. Both names are
symlinks to `scripts/zig-cc-musl`, which reads the target from its
own name and drops `-Wl,--fix-cortex-a53-843419`, which zig's linker
refuses.

Nightly exists only for cargo-fuzz and Miri: `scripts/nightly.sh`
pins it, and `scripts/fuzz.sh`, `scripts/miri.sh` and
`.github/workflows/ko-nightly.yml` source it. The two scripts run the
nightly cargo through `make nightly-cargo ARGS=...`. Without that
toolchain, or without cargo-fuzz or the `miri` component, the two
scripts print SKIP and exit 0.

**libghostty-vt.** `ko_vt_sys/build.rs` builds it with zig from
PATH. Every cargo profile and target directory shares one zig cache,
so libghostty-vt compiles once for release, test and clippy. The
cache is `target/zig-cache`: `.cargo/config.toml` gives its absolute
path to every cargo command as `KO_ZIG_CACHE`, and the Makefile's
terminfo rule uses the same directory. The path does not come from
`OUT_DIR`, because cargo writes `CACHEDIR.TAG` only when it creates
`target/` itself, and CI's cache restore creates it first.

**FFI bindings.** `scripts/bindgen.sh` (`make bindgen`) generates
`ko_vt_sys/src/bindings.rs` from `third_party/ghostty/include` with
the bindgen CLI (`cargo install --locked bindgen-cli`; on macOS,
`LIBCLANG_PATH` can name the Command Line Tools' `usr/lib`). The file
is committed with the hash of the headers in its first line.
`scripts/lint.sh` checks the hash.

## Platforms

ko builds and is verified on macOS and Linux (glibc 2.34 or newer,
for `posix_spawn_file_actions_addclosefrom_np`; the static Linux ko
uses musl). `ko_client` also builds for iOS, as a library: `ko_sys`
leaves out its process code there (`spawn`, `pid/desktop.rs`,
`pty/desktop.rs`), and `ko_client` leaves out `launch`, `visit`,
`remote::desktop` and `ffi::launch`, each gated once at its module
declaration. A module whose desktop half is a submodule (`pid`,
`pty`, `remote`) keeps that half private and re-exports its items
from the parent, so callers name `ko_sys::pid::Pid` on every platform
and the gate stays at one site.

Each OS call that differs has its two halves in `ko_sys`, behind
`cfg(target_os)`. The static Linux ko builds against musl, which has
no `addclosefrom_np`: `ko_sys::spawn` adds a close for each entry of
`/proc/self/fd` there, behind `cfg(target_env)`. Outside `ko_sys`,
only these branch on the platform: the C++ runtime that
`ko_vt_sys/build.rs` and `build-bench` link (`c++` on macOS and musl,
`stdc++` on glibc); `ko_client::ffi` (code that only the ffi uses
lives in it; an item that needs another module's private fields, as
`Model::json`, carries `cfg(target_vendor = "apple")` on itself and on
the imports that only it uses, never an `#[allow(dead_code)]`); the
podman kind's refusal (design-runtimes.md, "The podman kind"); and
tests that pin a platform's behaviour. On Linux, a read of a unix
socket whose peer closed with unread input fails with `ECONNRESET`;
`ko_sys::fd::read` returns it as `Ok(0)`, the end of the source.

## The installed layout

`make build` builds the installed layout under `build/ko/`: `ko`,
`ko-pane`, `share/ko` and the terminfo, which `ko_vt/terminfo.zig`
writes from ghostty's source and `tic` compiles. It replaces each
binary with a new file, because macOS kills a process whose executable
was overwritten in place after an earlier run (`Killed: 9`). `make
install PREFIX=<prefix>` copies that layout under `<prefix>/bin` and
`<prefix>/share/ko` (default `~/.local`), Homebrew's `pkgshare` layout.

`make build` installs `share/ko/bin` (the `ko`, `ssh` and `koa`
shims), `share/ko/shim.sh`, koa's program, the agent extension, the
shared modules, `ko-api.d.ts`, the skills and the bundled page (in
`share/ko/koa/`, the files of `KOA_SRC` in the Makefile), and the SDK `share/webview/` (in
`share/ko/webview/`) beside `bin/ko` in `build/ko/`, the layout that
`ko_shell/src/bin_dir.rs` finds as installed.

`ko version` prints the JSON of `protocol::version()`, with the build
id from `git describe` at build time in `.build`. The Makefile reads
the build id and the ghostty pin of the index once and exports them
to every cargo command as `KO_BUILD_ID` and `KO_VT`; `ko_wire/build.rs`
runs no git and tracks only these two variables. A build script must
not track the git index: `git describe --dirty` rewrites it on each
make, which would rebuild `ko_wire` and every crate above it.

## The static Linux ko

`make build-linux` builds the static Linux ko for each architecture
of `LINUX_ARCHS` (`aarch64`, `x86_64`; by default the host's alone)
into `build/ko/share/ko/linux/<arch>/`: `bin/ko` and `share/ko` with
the shims, `shim.sh`, the pi extension, the webview SDK and the
terminfo. It has no `ko-pane`, because no server runs inside. zig is
the C compiler and the linker, and `ko_vt_sys/build.rs` builds
libghostty-vt with `-Dtarget=<arch>-linux-musl`, so libghostty-vt,
zig's static libc++ and musl link into one static executable; `make
check-static` checks it. `make install` builds and copies the same
architectures, so the Homebrew formula builds the host's alone, and
`make verify` and each CI runner build and check theirs: the two
runners cover both. `LINUX_ARCHS="aarch64 x86_64"` builds both. The
aarch64 build lacks the Cortex-A53 erratum 843419 workaround, because
zig's linker refuses the flag: it is correct on Apple Silicon, not on
an affected Cortex-A53.

## The ko_client xcframework

`make ko-client-xcframework` builds `ko_client` as a static library
for each rust target of `KO_CLIENT_TARGETS` (default
`aarch64-apple-darwin`; also `aarch64-apple-ios` and
`aarch64-apple-ios-sim`) into `build/ko_client.xcframework`
(`KO_CLIENT_XC` overrides the path). The xcframework holds only the
libraries, no headers: a headered xcframework copies its module map
into the products' `include/`, where it collides with GhosttyKit's. The
Swift package `app/Packages/KoClientKit` consumes it: a binary target
`KoClientCore` for `build/ko_client.xcframework` inside the package
(`app/Makefile`'s `ko-client` target builds it there), a C target
`KoClient` whose `include/ko_client.h` is a symlink to
`ko_client/include/ko_client.h`, so SwiftPM generates the module, and
the Swift target `KoClientKit`. SwiftPM resolves the binary target
when xcodebuild opens the project, so `make -C app project` builds the
xcframework first, on every app build; an Xcode build alone does not
refresh it. The macOS slice needs
`MACOSX_DEPLOYMENT_TARGET` (26.0: Kido.app supports only Apple
Silicon and macOS 26 or later), an iOS slice
`IPHONEOS_DEPLOYMENT_TARGET`; the Makefile's one table maps each
target to its SDK and clang triple and refuses another. It fails when
the production graph of `ko_client` has `ko_vt` or `ko_server`: the
app links its own libghostty-vt, and no server code ships in a
client. Each slice goes through `ld -r -exported_symbols_list` over
`ko_client/exports.txt` after the C preprocessor with
`TargetConditionals.h` for that slice (iOS has no `default_dir`,
launch or stop exports), which makes every other symbol local, and
then `nm` must show exactly the names of that list. The reason:
Rust's `compiler_builtins` and Zig's `compiler_rt` in the app's
libghostty define the same symbols, and the app's link refuses the
duplicates.

## The benchmarks

`make build-bench` builds the C helpers of `bench/` into
`build/bench/`, beside `ko-bench` in `target/release/`; `bench/run.sh`,
`bench/flood.sh` and `bench/rtt.sh` call it through `bench/setup.sh`,
which they source. `bench/client.py` runs the `ko` that `KO_BIN`
names, which measures a reference build (design-ko.md,
"Performance"), else it runs `make build` and uses `build/ko/bin/ko`.

## The visual-test VM

Kido.app's visual snapshots are recorded and checked only in one guest
VM. The host's macOS and the host's GPU are not a reference, so a host
update never changes a snapshot. `app/vm/` is a Swift package without
dependencies. `make -C app vm` builds `kido-vm` and signs it ad hoc with
the `com.apple.security.virtualization` entitlement. Its state is in
`~/.local/state/kido-vm/`, outside the repository: the sparse disk, the
restore image, the machine identity, the SSH key and the locks.

`app/vm/Sources/kido-vm/main.swift` defines the commands, the shares and
the guest settings. `install` downloads the latest supported macOS
restore image and installs it. `up` starts the VM if it is not running,
waits up to 300 s for SSH, and then sets up the guest once; it is safe to
run again. `down` stops the guest. `exec --dir PATH -- CMD` runs a
command in the guest in the same absolute path. PATH must be under
`~/Workspace` or `/tmp`: the guest shares only those two, and `exec`
refuses other paths. `exec` runs one command at a time; a second one
prints that it waits for the VM and then goes on. `make visual`,
`visual-fast` and `visual-slow` build for testing on the host, with the
existing derived data, and run `test-without-building` in the guest
through `exec`. `ONLY=` and `RECORD=1` work as before. `ko-test` and the
app's unit tests stay on the host. `make vm-up` and `make vm-down` start
and stop the guest.

The guest is macOS 27.2.1, build 26B131. `pinnedGuestBuild` in `main.swift`
is that build, and every `exec` prints the guest's macOS version and
refuses to run when the build differs, so an unnoticed guest update
never records new snapshots. To move to a new guest macOS, install it,
change `pinnedGuestBuild` and record every snapshot again in the same
commit.

What the setup does, and why:

- Xcode (read-only), Homebrew (read-only), `~/Workspace` and `/tmp`
  are virtiofs shares. The guest links `~/Workspace` and `/opt/homebrew`
  to the shares, so the host paths that the build products contain
  exist in the guest. `xcode-select` points to the shared Xcode:
  the tests start `/usr/bin/python3` with an environment without
  `DEVELOPER_DIR`. `/usr/local/bin/node` links to Homebrew's `node`,
  because koa needs `node` on the default `PATH`.
- The display is 3840x2400 at 144 ppi.
- `exec` mounts the share again before each run. Without this, the
  guest keeps a stale view of a directory that the host deleted and
  created again (`xcodegen` does this to `Kido.xcodeproj`). A new mount
  makes the first run of each binary on a share slow (about 6 s for
  `python3` and `node`), so `app/scripts/visual-guest.sh` runs both once
  before the tests.
- The guest installs no updates: the `AutomaticCheckEnabled`,
  `AutomaticDownload`, `AutomaticallyInstallMacOSUpdates`,
  `ConfigDataInstall` and `CriticalUpdateInstall` defaults are false,
  `softwareupdate --schedule off` runs, and `/etc/hosts` sends the
  Apple update servers (`swscan`, `swdist`, `swcdn`, `mesu`, `gdmf`
  and `xp.apple.com`) to `0.0.0.0`. macOS 27.2.1 still prints that
  automatic checking is on after `--schedule off`. The build pin is
  the real guard.
- The guest builds nothing: the host builds, and the guest uses the
  derived data and the resolved packages of the host
  (`-disableAutomaticPackageResolution`).

## The share tree and the scripts

    share/ko/           the source of share/ko as installed:
      bin/              the bin directory's sh shims (ko, ssh, koa)
      shim.sh           their shared helper
      bash/, zsh/       the OSC 133 integrations every primed shell sources
      openapi.json, client-model.json, config-schema.json   the generated schemas (make schemas)
    share/koa/          koa, the pi harness that renders through a
                        webview, and koa-agent.ts, the agent extension that
                        koa loads into its pi; their suites, the fake ko of
                        testdata/fake_ko/, the prompt snapshot, the ko skill,
                        ko-api.d.ts (generated from openapi.json) and the
                        shared modules (design-koa.md, "Where koa lives",
                        names each file)
    share/webview/      @kido/webview, the Node SDK for webview pages
                        (index.ts, README.md), installed as share/ko/webview
    .pi/prompts/        gh-watch.md, /gh-watch: starts scripts/main-watch.sh streamed;
                        release.md, /release: Kido.app first, then ko
    .pi/extensions/     no-git-writes, the spawned agent's bash-tool guard
    .pi/tests/          no-git-writes.test.ts, the guard's suite, which
                        scripts/test-ts.sh runs with koa's suite
    scripts/openapi/    package.json and its lockfile: openapi-typescript and
                        redocly, the generators of ko-api.d.ts and of make
                        api-docs, with the TypeScript 5 that they need, apart
                        from share/koa's TypeScript 7
    scripts/            verify.sh, scrubbed verification; checks.sh, the
                        checks of a unit's changed paths; release.sh, the
                        Homebrew tap release; lint.sh, code hygiene, signal
                        calls, doc references, schemas and prompt snapshots;
                        test-ts.sh; dump-prompts.ts, every prompt text pi
                        registers; main-watch.sh, CI for each observed main
                        head; ci-website-watch.sh; ci-like.sh and
                        ci-like/Dockerfile, the Linux reproduction;
                        install-zig.sh, the zig pin; move-subagent-sessions.py,
                        the one-off move of child sessions out of pi's
                        tree; zig-cc-musl, the musl linker wrapper of
                        .cargo/config.toml, under its names
                        zig-cc-<arch>-linux-musl; verus.sh, nightly.sh,
                        fuzz.sh, miri.sh, bindgen.sh; quiet-limit
    third_party/ghostty the Ghostty fork, a git submodule (AGENTS.md, "One Ghostty")
    website/            the kido.tools site
    bench/              the benchmark scripts, streams and C helpers
    app/                Kido.app (design-app.md)

The Makefile targets are listed in README.md, "Development".
