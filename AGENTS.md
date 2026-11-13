# Developing Kido

[README.md](README.md) describes Kido and its installation. This file
supplies context that the code does not contain: the rules that a
change can break, even if the change looks correct, and the way agents
work in this repository. The docs hold the mechanisms. Before you
change one, read its file; the code comments and this file do not
repeat them.

- [docs/design-ko.md](docs/design-ko.md): the server `ko`.
- [docs/protocol.md](docs/protocol.md): the protocol's behaviour.
- [docs/design.md](docs/design.md): the agent features and the
  boundary between ko and its pi extension.
- [docs/design-subagents.md](docs/design-subagents.md): subagents.
- [docs/design-program-status.md](docs/design-program-status.md):
  pane classification and status.
- [docs/design-runtimes.md](docs/design-runtimes.md): runtimes.
- [docs/design-webview.md](docs/design-webview.md): webview panes.
- [docs/design-koa.md](docs/design-koa.md): koa, the pi harness that
  renders through a page.
- [docs/design-app.md](docs/design-app.md): Kido.app.
- [docs/build.md](docs/build.md): the crates, the toolchain, the
  platforms, the installed layout and the share tree.
- [docs/verification.md](docs/verification.md): `make verify`, the
  e2e harness, loom, Verus, fuzzing, Miri, CI and ci-like.
- [docs/release.md](docs/release.md): the release mechanics.

Work in progress has a plan in `plans/`, one markdown file per plan.
When the work is complete, its agreed design moves into `docs/` and
the plan is deleted.

## Code rules

These rules apply to Rust, TypeScript and Swift.

**No backward compatibility, ever.** The server, the clients, the
extension and the shims ship together from one checkout. When they
must agree, both sides change. Do not write fallbacks for state from
an older ko: old variables, record fields, flags or environment
variables. Do not add version gates, deprecated aliases or migration
paths. Change both sides. Delete the old one. State from an older ko
is not a bug if a restart or user action clears it.

**A feature fits the model; it is not bolted on.** A significant
feature can change what the existing abstractions must express.
Before it adds code, its design finds every place that dispatches on
the concepts it touches (an enum, a classification, a set of cases)
and decides whether to extend or replace them. A new case goes into
the type that names the cases, so that every match handles it. Do not
add a filter, an `Option` branch or a parallel field beside the
existing dispatch, and do not add a new abstraction where an existing
one extends.

**Plain functions over data.** Use abstraction only when it has a
benefit. Do not use a trait, generic or trait object without a second
implementation. Express the design through data structures. Make
illegal states unrepresentable.

- Use an enum for a set of cases (a discriminated union in TS). Do
  not use a struct of options or a combination of bools.
- Give a value with its own rules its own type, with a private field.
  Parse it once at the edge. Do not check a string in several places.
- Do not use strings for typed values. A closed set of names is an
  enum, even in a record that only goes to JSON. Only the codec knows
  the strings.
- Do not give a number a special meaning. "Unknown" is `None`, not
  `0`. "Disabled" is its own variant, not `0`. The magic value exists
  only in the codec at the edge: a C API, a frame or a flag.
- One `None` has one meaning in a record. Do not use `None` for "no
  limit" in one field and for "disabled" in the next.
- Use one record for parallel fields or maps that describe one thing.
  Fields that are known or unknown together are one option of a
  record, not two fields.

**Minimal line count.** Do not abstract something with one use.
Inline a function, type, trait, constant, option struct or test helper
with one caller. Do not add wrappers that only forward. Remove dead
code and unused parameters. Put duplicated logic in one place.

**Module boundaries.** Each subcomponent has its own module. Use its
exported surface. `ko/src/main.rs` connects subcommands to the library
crates and contains commands too small for library code. Domain logic
belongs in the module that owns the domain. A type that exists only
for the wire and a protocol constant belong to the protocol module,
not to the settings module. A setting that the protocol reports stays
with the settings. A type whose module cannot construct it is probably
in the wrong module.

**Library code returns, the CLI reports.** A library function returns
its result: a value, an `Option` or a `Result`. It does not print,
panic or exit. A command body belongs in `ko/src/main.rs` if it only
calls the library, prints and returns an exit code.

**No display logic in the libraries.** Human-facing formatting belongs
in `ko/`: tables, alignment, padding, truncation, glyphs, styles,
local time, usage text, and labels and captions composed from facts.
A wire type contains only semantic data: plain titles and typed
status, as uncut text.

**State.** Use one source of truth for each fact. Never hold the same
fact in two stores: a layout row and a pane variable; a Rust record
and a TS or Swift copy; a file and an in-memory mirror; a doc and the
code. Docs do not repeat what the code defines: field lists, JSON
examples, byte layouts, enum values or flag tables. They name the
file that defines it and give only what the code cannot say:
semantics, ordering, rationale and decisions. A plan for code that
does not exist yet can give shapes, until the code exists. Do not
store a fact that you can derive; compute it when necessary. The
exception is a value that needs validation or I/O to resolve, such as
a checked path: resolve it once at the edge and store it in the
record that every caller reads. Read and write each piece of state
through its owner module only.

**No comments unless absolutely necessary.** Code should explain
itself. Do not add narration or doc comments that repeat the name, or
history ("previously", "no longer", "since this fix"). Design
rationale belongs in `docs/`. Keep only: a verified external
constraint that the code cannot express (a libghostty-vt, pi, Claude
Code or OS quirk); the reason for a workaround, while it exists; a
link to the issue for either; the `///` that clap turns into help
text or that becomes a wire type's OpenAPI description. Build,
compiler and formatter directives are not comments. If a diagnostic
suppression hides a correctness failure, fix the cause. A stale
comment is worse than no comment because readers trust it. When a
mechanism changes, use grep to find prose that describes it. Check
each statement in a comment against its source. Do not write a fact
that you did not read.

## Communication

Always use ASD-STE100: when you communicate with the user, in commit
messages and descriptions, in PR titles and descriptions, and in code
comments.

## Rust

docs/build.md names each crate and describes the toolchain, the
platforms and the installed layout. These requirements are fixed:

- **Layout.** One cargo workspace at the root. A package has the name
  of its directory, with the underscore. `ko/src/main.rs` holds the
  command table and the small command bodies. `fuzz/`, `ko_e2e/`,
  `fake_ko` and `ko_bench/` are workspace members outside
  `default-members`. ko has no C of its own, only the measurement
  helpers of `bench/`. Do not add new C.
- **Toolchain.** `rust-toolchain.toml` pins the toolchain of the
  pinned Verus release; they move together. Every cargo command runs
  through a Makefile target, because only the Makefile finds cargo,
  and passes `--locked`. Scripts call make, never cargo. `Cargo.lock`
  is committed. zig comes from PATH at the release of
  `scripts/install-zig.sh`, which must equal the ghostty pin's
  `.minimum_zig_version`. Nightly exists only for cargo-fuzz and
  Miri, whose scripts print SKIP without it. Agents do not install it.
- **Platforms.** ko builds and is verified on macOS and Linux;
  `ko_client` also builds for iOS, as a library. Each OS call that
  differs has its two halves in `ko_sys`, behind `cfg(target_os)`.
  Outside `ko_sys`, only the C++ runtime that `ko_vt_sys/build.rs`
  links, `ko_client::ffi`, the podman kind's refusal and tests that
  pin a platform's behaviour branch on the platform (docs/build.md,
  "Platforms").
- **Dependencies.** `scripts/crates.txt` lists every package of
  `Cargo.lock`, and `scripts/lint.sh` compares the two. A new direct
  crate, or a new feature that adds packages, is a decision for the
  user, with the cost of the hand-written alternative in the request.
  No async runtime and no crate that needs one: no `tokio`, `hyper`,
  `mio`, `futures`, `async-std` or `smol`, and no `async fn` in ko's
  code. `proptest` and `loom` are dev-dependencies.
- **Formatting and lints.** `cargo fmt` with `rustfmt.toml`. `cargo
  clippy --all-targets -- -D warnings` is clean. `[workspace.lints]`
  in `Cargo.toml` holds the denied lints; `clippy.toml` permits
  `unwrap`, `expect`, `panic!` and indexing in tests. A reader of
  untrusted bytes (the frame, ring and webview parsers of
  `ko_pane_wire`, the HTTP, WebSocket and exec readers of `ko_wire`,
  `ko_server`'s `pane_proc.rs` and `ws.rs`, `ko_pane`'s `io.rs`) also
  denies `clippy::indexing_slicing` and
  `clippy::arithmetic_side_effects`. `print_stdout` and
  `print_stderr` are denied: the CLI writes through `writeln!` on a
  locked stream; only `ko_bench` and the fake ko allow the macros.
- **The command line is a contract** with `ko_e2e/`, `bench/`,
  `share/` and Kido.app. A long option is `--name`. clap's derive
  generates `--help` and the usage errors: the doc comment on each
  command and argument is its help text. A usage error exits 124.
  `ko api`'s flags, exit codes and output are the contract with the
  agent extension (docs/design.md, "The harness extension").

Conventions:

- **No panics in library code.** A library function returns `Result`.
  `unwrap`, `expect`, `panic!`, indexing on untrusted lengths and
  unchecked arithmetic on wire values do not occur outside tests and
  `build.rs`. The release profile sets `panic = "abort"` and
  `overflow-checks = true`: a panic is a bug, and a loud stop is
  better than a half-state.
- **Errors.** `std::io::Error` carries an OS error and propagates with
  `?`. If callers distinguish cases, the module defines an enum and
  implements `Display` manually. Do not use `anyhow`, `thiserror` or
  `Box<dyn Error>`. A crate's error becomes ko's own error at the
  edge that received it. A command body in `ko/src/main.rs` prints a
  failure as `ko <name>: <message>` and returns 1.
- **Visibility is the interface.** An item is `pub` only when another
  crate uses it, and `pub(crate)` only when another module uses it.
  `lib.rs` lists modules and re-exports nothing. rustc does not
  report an unused `pub` item of a library, so review checks that
  another crate uses each export.
- **Tests** are `#[cfg(test)] mod tests` at the bottom of the file
  under test. Expectations are `assert_eq!` on values or strings.
  Property tests use proptest in the same module. No unit test execs
  the `ko` binary; the e2e suite does that. A test starts a process
  only through `ko_sys::spawn::program`, and a test that closes a
  peer waits, with a deadline, until the other end sees the hangup
  (docs/verification.md, "Unit tests").
- **The e2e suite** is `ko_e2e/`, outside `default-members`
  (docs/verification.md, "The e2e suite"). It drives
  `build/ko/bin/ko`; a test never runs make or cargo. A test reads
  like command-line use: a step that a `ko` command can do runs it
  through `Server::ko` or `run_ko` and asserts stdout, stderr and the
  exit code; raw requests stay only for HTTP framing, exact statuses,
  hostile input and polling loops. Each child gets an explicit
  environment through `Env::Only` with a private `HOME`; the test
  process never sets its own. State directories are under `/tmp`.
  Every wait polls with a deadline of 5 s; lint refuses
  `thread::sleep` in `ko_e2e/` except through its table. The tests
  that need a host run only under `KO_E2E_HOST_SSH=1`,
  `KO_E2E_CONTAINER=1` or `KO_E2E_PODMAN=1`, and then a missing host
  facility is a failure, not a skip. A lower `E2E_THREADS` does not
  fix a test that fails at 64: that test has a race or does too much
  work.
- **Verus.** `ko_pane_wire::ring`, `ko_pane_wire::frame::Req`,
  `ko_server::delivery`, `ko_server::view` and `conn.rs`'s `Batch` are
  verified with Verus (`make verus`; docs/verification.md, "Verus").
  Specs and proofs are in `verus!{}` beside the code.
  `#[verifier::external_body]` and `external_fn_specification` occur
  only in `ring/backend.rs`, `delivery.rs`, `view.rs` and `conn.rs`,
  each with an `// Assumes:` comment that names its assumption, and
  no `ensures` beyond that comment. No `assume` and no `admit` occur.
  The `verus` stage fails when verification takes more than 120 s
  and is SKIP without the archive, except under `KO_VERUS_REQUIRED=1`
  (CI).
- **Derives.** Every type derives `Debug`. Derive `Clone`, `Copy`,
  `PartialEq` and `Eq` where the type is a value. Derive `PartialOrd`
  and `Ord` only where the order has a meaning, `Default` only when
  every field has a meaningful default, and `Hash` only for a map key.
- **Unsafe.** `unsafe` is permitted in `ko_sys`, `ko_vt_sys`, `ko_vt`,
  `ko_pane_wire::ring::mapping` and `ring::model`, `ko_client::ffi`
  with `ffi::engine` and `ffi::view`, and `ko_bench/src/alloc.rs`.
  Every other crate and module denies it. Each block has a
  `// SAFETY:` line that names the invariant. A safe wrapper takes
  typed arguments and returns `Result`. Descriptors are `OwnedFd` and
  `BorrowedFd`; no raw descriptor crosses a module boundary. A signal
  handler only sets its pending flag and writes its pipe. A callback
  from libghostty-vt never unwinds and never calls back into the
  terminal.
- **JSON.** serde derives every codec; `ko_wire::protocol` owns the
  wire types. An enum with a payload variant has `#[serde(tag =
  "type", rename_all = "snake_case")]`; a primitive, list, id or enum
  payload is a struct variant with one named field. The error body
  flattens its kind with the tag `kind`. A unit enum uses `rename_all
  = "snake_case"`. An option field has `#[serde(default,
  skip_serializing_if = "Option::is_none")]`. A value with its own
  rules validates in its `TryFrom`, through `#[serde(try_from =
  ...)]`. Every untrusted body and WebSocket message decodes through
  `protocol::decode`, which refuses a JSON array for a record at
  every level. Do not write a codec by hand or walk a
  `serde_json::Value`. Catch a decode error only at an untrusted
  edge. Every wire type derives `JsonSchema`; a `try_from` type
  writes its `JsonSchema` by hand with the pattern or range that its
  `TryFrom` checks, and a range in a `///` is also a
  `#[schemars(range(...))]`.
- **Routes.** `ko_wire::api` declares every route in one `routes!`
  block (docs/design-ko.md, "Crates"). A parameter type implements
  `Param` and holds its own validation. `router.rs` matches `Request`
  exhaustively. To add a route: add its block with its `///` doc, add
  the arm in `router.rs`, then run `make schemas`; lint fails when a
  generated file differs. The agent extension takes its shapes from
  `ko-api.d.ts` and writes none by hand.
- **HTTP.** `ko_wire::http` is the only code that reads or writes
  HTTP framing, for the server and for the client.
- **The view write path.** Only `ko_server::conn` writes a
  connection's descriptor (docs/design-ko.md, "Views and flow
  control").
- **Signals.** `libc::kill` occurs only in `ko_sys/src/pid/desktop.rs`;
  `scripts/lint.sh` refuses it, `killpg`, `nix::sys::signal` and a
  `kill` command elsewhere. `Pid::new` refuses 1 or less, values over
  `i32::MAX`, the own pid and the own process group. A `Group` exists
  only after `Group::verify` read from the OS that the pid is a child
  of the given parent and leads its own group and session;
  `Group::signal` checks the start time and the group again.
  `ko-pane` signals its program's group only through the
  `ko_sys::pid::Program` that `pty::spawn` returned after `exec`, and
  `ko enter --exec` only through the `Program` that `spawn::grouped`
  returned: it owns the child, is not `Copy`, and its reap consumes
  it, so no group signal follows the reap. `ESRCH` is not an error,
  and neither is `EPERM` on a group signal. `bench/client.py` signals
  only through `signal_child`. `share/koa/koa-agent.ts` signals only the
  groups of the jobs it spawned, through `signalJob`, which takes a
  record of its registry; koa only the children it spawned, through
  `signalChild` in `share/koa/koa-child.ts`; lint refuses
  `process.kill(` elsewhere in `share/` (docs/design-subagents.md,
  "Stopping a job"). Elsewhere a child gets a signal only through its
  own `ChildProcess.kill`. `ko_e2e` signals a process that it spawned
  through its `Pid`, and any other only through
  `ko_sys::pid::signal_descendant`, which refuses a pid that does not
  descend from the given root within 64 hops. lint refuses the other
  signal calls in `bench/`.
- **Syscalls.** Every own libc call that can return `EINTR` goes
  through `ko_sys::retry`. An `EINTR` from the loop's wait is a turn
  with no events. A read of zero bytes is the end; `WouldBlock` is
  "not ready". No call relies on `SA_RESTART`. Between `fork` and
  `execve` the child calls only async-signal-safe functions on memory
  prepared before the fork.
- **The loop.** Every ko process is one thread on `ko_sys::event`,
  except for the terminal client's mirror compressors and the threads
  of `ko_client::ffi` (docs/design-ko.md, "The terminal client";
  docs/design-app.md, "One ko client"). Signals reach the loop only
  through the self-pipe of `ko_sys::signal`, one `Signals` per
  process. Back-pressure is the interest. The owner matches on the
  ready tokens and the due timers and calls its own handlers with
  `&mut self`; no callback is registered with the loop, and no
  `Rc<RefCell<..>>` exists. A request that waits is a connection in
  `Phase::Handling` with a waiter in `State` and a timer of the loop,
  never a thread (docs/design-ko.md, "The loop rule").
- **The C ABI.** `ko_client::ffi` builds only for `target_vendor =
  "apple"`. The header comment of `ko_client/include/ko_client.h` is
  the contract. A new exported function goes into `ko_client.h`,
  `ffi.rs` and `exports.txt` together (docs/build.md, "The ko_client
  xcframework").
- **Time.** `Mono` is nanoseconds of `CLOCK_UPTIME_RAW` on macOS and
  of `CLOCK_MONOTONIC` on Linux. The loop's deadlines are
  `std::time::Instant`. Timeouts are `Duration` arguments, not statics.
- **Environment.** Read the environment at the edge
  (`ko_server/src/config.rs`, `ko_wire/src/local.rs`,
  `ko/src/main.rs`) and pass its values as arguments. Tests pass a
  temporary directory and never set a variable of their own process.
- **Build scripts** never track the git index: `git describe --dirty`
  rewrites it on each make, which would rebuild `ko_wire` and every
  crate above it. `ko_wire/build.rs` tracks only `KO_BUILD_ID` and
  `KO_VT`, which the Makefile exports.
- **FFI bindings.** `ko_vt_sys/src/bindings.rs` is committed with the
  hash of the headers in its first line, which lint checks. A change
  of the ghostty pin regenerates it (`make bindgen`) in the same
  commit.
- **One Ghostty.** `third_party/ghostty` (the `kido-upstream` branch
  of andreypopp/ghostty) is the one Ghostty checkout of ko and
  Kido.app: libghostty-vt for ko, GhosttyKit for the app. A pin bump
  moves both, so it passes ko's verification and the app's build and
  tests. Only the top-level session moves a submodule pin. The stack
  is linear on upstream, with one commit for each feature and each
  fix folded into its feature. Before a force-push, its previous head
  is pushed as a dated branch `kido-upstream-YYYY-MM-DD`. A folded
  commit keeps the `Co-authored-by` and `Based on` trailers of every
  commit in it. The stack keeps only what the app or ko calls; an API
  whose last caller goes leaves the stack. A pin bump changes `Ko-Vt`,
  so it is a coordinated release of ko and Kido.app ("Releasing").
- **Fuzz targets.** A target in `fuzz/fuzz_targets/` calls one
  function of a library crate, and that crate has a `#[test]` that
  replays the target's corpus, or fixed cases, through the same
  function on stable. The entry functions are in a module `fuzz`
  under `cfg(any(test, feature = "fuzz"))`, which only
  `fuzz/Cargo.toml` enables. A model in a target never reuses the
  formula of the code under test. Only `fuzz/` reads `KO_FUZZ_*`.

**koa is the one harness.** koa (`share/koa/`) is Kido's one pi
harness, and no other program loads its agent extension: there is no
terminal harness. A plain `pi` is not Kido's
harness. The agent extension, `share/koa/koa-agent.ts`, runs in koa's pi
child, answers koa's session channel on fd 3 and holds every agent
tool. Nothing
in it exists only for pi's terminal UI: no widgets, renderers,
terminal input or autocomplete providers. It learns browser mode from
the boolean flag `--koa-browser` that koa passes, never from pi's
mode or the environment. It calls only `ko api` (docs/design.md,
"The harness extension", lists the routes). Of `share/koa/` it
imports only the modules that koa also uses: `text.ts`, `agents.ts`,
`records.ts`, `completion-context.ts`, `runtime-exec.ts`,
`koa-channel.ts`, `koa-session-dir.ts` and `koa-records.ts`, never
koa's program modules. Its background
commands are jobs, child processes of pi. It never opens ko's socket,
never reads ko's state directory or another agent's files, and has no
state directory of its own: its registry and reports are custom
entries in its own pi session. ko never reads the extension's files.
Its knobs are `KO_*`.

## The server

A server is its state directory, and `--server DIR` is one option of
the whole command line (docs/design-ko.md, "Lifecycle and the command
line"). Inside a pane, every `ko` command but the terminal client
sends `$KO_PANE` and `$KO_PANE_TOKEN` as the `Ko-Pane` and
`Ko-Pane-Token` headers to the pane's own server only, and a request
without them is the user (docs/protocol.md, section 1). ko has no
caller otherwise: `POST /panes` takes its parent in the body.

**Runtimes** (docs/design-runtimes.md). The rules a change breaks
most easily:

- A connection's `Origin` comes from the listener that accepted it
  and lives with the connection. On a runtime connection every
  request acts as a live pane of that runtime, with its token; the
  user does not exist there, and a route that the runtime gate does
  not name is refused.
- A visit (`ko run`) is a connection: its end is the end of that
  connection, never a message or a process name. Inside, the pane
  acts only with the visit's own token, which dies with the visit;
  the pane's own token acts only on the host socket.
- A pane token never appears in an argv: the server writes it to a
  `0600` file or an environment, and `ko enter` reads it from there.
- An exec session's command gets no caller or server environment:
  only the runtime's `env`, the request's `env` and `KO_RUNTIME`.
- The server signals only an exec helper or a step that it spawned.
- The `command` kind is test-only, behind `KO_RUNTIME_COMMAND_KIND=1`.
- The container and podman kinds stop and delete only the container
  `ko-<tag>` that they created from an image, never a
  `from.container`. Their cleanup children never get `SIGTERM`, so a
  stop completes after the link is gone. A runtime's socket is alone
  in `io/`, which the podman kind mounts and ko never removes.
- The podman kind runs only on Linux; its refusal elsewhere is the
  one platform branch outside `ko_sys` that is not an OS call.

**Native agent status.** Only OSC 7501 root apps `pi` and
`claude-code` identify agent panes (docs/design-program-status.md,
"Sources"). Three pane variables supply local pi identity, never
detection: `pi.session`, `pi.name` and `pi.activity`. ko trusts them
only while the pane has an OSC 7501 root with `app=pi`, which koa
writes for its RPC pi. ssh panes use
`ssh.dest` and `ssh.args`, trusted only while the foreground is `ssh`.
A routed pi's `pi.runtime` follows the same rule in the harness and
in the clients, where only `ko_client`'s `Model::place` reads it; the
server does not read it, and nothing reads the generic `ko.runtime`
(docs/design-runtimes.md, "Agents in a runtime" and "Clients").

**Panes and the sweep.** docs/design.md, "Who is authoritative for
what" and "Window lifecycle", gives the rules. The ones a change
breaks most easily:

- ko keeps no record of a pane after it goes; the row is the whole
  record. ko has no runs.
- The sweep reads the pane rows, never a process or pi evidence. It
  removes a pane with the default `close: exit` at once when its
  program exits or dies by a signal, focused or not, but keeps a
  start failure (cause `failed`); a `close: on_exit` pane dead for
  the linger grace; and a pane whose immutable `parent` pane is gone
  or dead (the linger collection waits while a focused client shows
  the pane). Every removal takes the pane's descendants in the same
  change; the server owns that cascade. A child's pane gets `close:
  on_exit` and its spawner's pane as `parent`. A child pane may float
  or be tiled only in its parent's window; in any other window it is
  the only tiled pane, with only its own child floats.
- A message (`/panes/{id}/messages`) is enqueued once for each
  `(pane, id)`; a repeat answers from the original. The queue drops
  with its pane, and nothing tells its senders. The server never
  reads a message's kind or text.

**Shell integrations** (`share/ko/bash`, `share/ko/zsh`) blank
control characters in the command line, limit it to 1024 characters,
and encode only `%` as `%25` and `;` as `%3B` in it. Their OSC 7
directory report has its own encoding and carries the shell's real
hostname (docs/design.md, "Priming a local shell").
`share/ko/zsh/integration.zsh` must not name a local `status`: it is
a zsh special parameter, and shadowing it silently stops the precmd
hook. The local is called `ret`.

## Proved modules

Verus is ko's one specification ("Verus" under "Rust").

**The ring indices are sequentially consistent.** The wakeup
handshake between `head` and `read` is a store-buffering pattern:
each side stores its index, then loads the other's. Under
acquire/release, both loads can read the stale values, and a wakeup
is lost. The proof assumes one interleaving, which only `seq_cst`
gives. The ring header's loads and stores are `SeqCst`;
`scripts/lint.sh` refuses any other `Ordering` in `ko_pane`,
`ko_pane_wire` and `ko_server`, except in the loom model
`ring/model.rs`, which shows the lost wakeup on the Rust code
(docs/verification.md, "loom").

## Tests

docs/verification.md describes every check. The targets agents run:

    make checks  the checks of the paths that a unit changed; DRY=1 prints the plan
    make test  ko's cargo tests and the loom models, without the e2e suite
    make e2e E2E=name  the e2e suite against build/ko/bin/ko
    make cargo ARGS='test -p ko_server'  one cargo command, for iterating on one package
    make lint    cargo fmt --check, clippy and scripts/lint.sh
    make schemas regenerate the schemas and share/koa/ko-api.d.ts
    make prompts regenerate the prompt fixture
    make fuzz TARGET=ring TIME=600  one time-boxed fuzz run, only when the user asks
    make ci-like ARGS=...  a CPU/memory-capped Linux container

`make verify STAGES=e2e` selects stages, and `E2E=client_` limits the
e2e stage to a cargo test filter. The stages `lint-sh`, `app`,
`ko-test` and `visual` are not in the default list; `scripts/checks.sh`
selects them. `scripts/verify.sh` scrubs `KO_STATE_DIR`, `KO_PANE`,
`KO_SOCKET`, `KO_PANE_TOKEN`, every `KO_AGENT_*` and the installed
`share/ko/bin` on PATH, so the developer's own pane does not enter
the tests. Kido.app has its own checks in `app/` (docs/design-app.md,
"Testing").

**Visual snapshots belong to the guest.** `make -C app visual` builds
on the host and runs in the visual-test VM on one pinned macOS build
(docs/build.md, "The visual-test VM"). Never record snapshots on the
host. A visual test never asserts a position that AppKit decides: it
reads the live view or checks the rule.

**Record the snapshots once, at the end.** A visual run costs minutes
(the host build and the one VM that every unit shares), and its
duration does not depend on the number of tests. So a unit records
its snapshots once: after the last code change, after the review
findings are applied, before the final `scripts/checks.sh`. While it
iterates, the implementer checks the page or the view through its
DOM and unit tests and the mockup, not through snapshots. A
difference that the manager finds in the recorded snapshots goes
back in one batch, and the unit records again only the tests that
batch changes.

**Which verification.** Agents verify a unit with `scripts/checks.sh`
(`make checks`; `DRY=1` prints only the plan, `BASE=ref` sets the
base). It reads the paths that the unit changed, finds the checks of
each path in the one table of the script, prints the plan and runs
the checks through `scripts/verify.sh`. A path that the table does
not name selects every check. Full `make verify` runs on CI, on
Ubuntu and macOS for every push and PR. A release, a move of the
Ghostty pin and a rebase with resolved conflicts also run full `make
verify` and the app's full `make visual`. Agents run `make fuzz` only
when the user asks; long fuzz runs occur only in CI.

**Test speed.** Tests stay very fast, because fast tests give fast
iterations. `make verify` prints the time of each stage on its
PASS/FAIL line. A change that makes a stage slower needs a reason.

- Wait for the event, not for a time. A test that only waits longer
  than necessary is a defect.
- An absence check waits for the harness's quiet window. Do not add
  one where a positive assertion shows the same fact.
- Shorten a product timer through the server's environment ("Knobs"
  in docs/design.md) or, for the linger and the runtime idle, through
  the `server:` key of the configuration file. The e2e suite runs all
  its tests at once, so each server start costs the whole suite: put
  cases that need the same setup in one test, on one server.
- Test pure logic in a unit test, not through a server.
- In the TypeScript suite, the fake `ko` is the Rust binary
  `share/koa/testdata/fake_ko`. A Node process start costs about
  70 ms. A fake delay is a `KO_FAKE_*` gate that the test releases,
  not a delay that the test waits out. A test that reads only the
  registered tools needs no fixture.
- A test earns its time. Do not keep a test that repeats another
  test, the prompt snapshot or the compiler, or that only repeats a
  constant or a one-line function.

**Prefer e2e tests.** Use `ko_e2e/` to test behaviour that a user or
agent can observe through the binary: a subcommand's output, exit
code, and effects on the server or its state. Unit tests check pure
logic that e2e cannot reach or test precisely: parsers, formats and
ordering. Do not write a unit test that execs the binary.

**Reproducing a CI-only failure.** `make ci-like ARGS="--cpus 0.25 --
make cargo ARGS='test -p ko_e2e NAME'"` runs a Linux container with
the repo bind-mounted and CPU/memory capped. A CPU quota alone rarely
reproduces timing failures; `--contend N` adds busy siblings. Use
contention for one named failure, not a whole suite. Never saturate
the host's cores: other agents work in parallel
(docs/verification.md, "Reproducing a CI-only failure").

**Fuzzing.** A bug that a fuzzer finds gets a regression test with
that case: the explicit input or operation list, not a seed. A corpus
changes only through `make fuzz MERGE=1`, and only with a code change
that needs the new inputs (docs/verification.md, "Fuzzing"). A test
that pins a libghostty-vt bug fails when the bug is fixed, so the
workaround for it can be removed. Many tests have a comment that
identifies their check or their important assertion. Before you
weaken or simplify such a test, read its comment.

## Review

A reviewer checks the change against "Code rules", "Rust" and
"Tests" above. Read each rule and look for its fault in the diff: a
rule alone does not find a fault. A reviewer reports each finding
with the file and line, the fault, and a fix. It does not edit files.

**Simplify reviewers** use the `simplify` skill
(`~/.pi/agent/skills/simplify/SKILL.md`). Each reviewer takes one
angle of its Phase 1: reuse, simplification, efficiency or altitude.
A reviewer does only Phase 1 and reports its findings. It does not
apply them: the manager decides which to apply, and the implementer
applies them.

**The correctness reviewer** looks for bugs, not style. It traces
each user action and each input end to end, with real event
sequences: keys, mouse, resize, attach, detach and reconnect. It
checks each conversion of coordinates and units: cells and pixels,
bytes and lines, offsets, seconds and nanoseconds, 0-based and
1-based. It checks that each test can fail: a test must not copy the
production formula, and a fake must not accept every input. It
compares each use of a protocol with its contract: docs/protocol.md,
the header of a C API, `share/ko/openapi.json`.

**The modules reviewer** checks each crate and module that the change
touches: an item is `pub` only when another crate uses it, and
`pub(crate)` only when another module uses it ("Visibility is the
interface"); the module is self-contained and consistent, so a module
that exports a type also exports the functions that construct and use
it (a module that is only a set of types is the exception); the
module has one purpose, and a second purpose needs a clear reason.

## Working here as a spawned agent

These rules apply to every agent in this repo: the top-level session,
the manager of a unit of work, and the implementers, investigators
and reviewers that a manager spawns. A brief names your role and does
not repeat these rules. Your role limits what you do: an implementer,
an investigator or a reviewer does its task itself, spawns no
subagents and makes no git writes. A reviewer is read-only. A manager
delegates as its brief says and does not write code.

- **The top-level session orchestrates.** It plans the work and gives
  each unit of work to one manager. It creates the unit's worktree.
  It is the one integrator: only it commits, merges and pushes, and
  only it moves a submodule pin. It never runs test suites, builds or
  other long blocking commands itself, so it stays free to answer the
  user. When verification is missing after a demo or a late edit, it
  sends the work back to the manager. A verified unit that rebases
  onto `main` without conflicts is pushed at once, and CI checks the
  combination; only a rebase whose conflicts the session resolved
  goes back to the manager for a check. The session confirms the
  commit on `origin/main` before it stops the unit's agents and
  removes the worktree, each a separate step, never in parallel with
  the commit. macOS and Linux are both first-class: a failure on
  either CI runner gets a unit, and a failure that occurs only on
  Linux is reproduced with `scripts/ci-like.sh` ("Reproducing a
  CI-only failure"). The session reads CI's result for each head that
  it pushes.
- **Models.** Name a model by its fully qualified name in every
  `spawn_agent` call without `resume_from`: without `model`, the
  agent takes the caller's model. A `resume_from`, also with `fork`,
  and a `message_agent` that revives an ended agent keep the model
  and thinking level of the saved session; name a model only to
  change it.
  - A manager runs on `claude-bridge/claude-opus-5-5`.
  - An implementer and a builder run on
    `claude-bridge/claude-sonnet-5-5:low`.
  - Investigation or reproduction work runs on
    `openai-codex/gpt-6.1-sol:low`.
  - Every reviewer (the four simplify reviewers, the correctness
    reviewer and the modules reviewer) runs on
    `openai-codex/gpt-6-astra:medium`.
  - The planner of a unit runs on `openai-codex/gpt-6-astra`.
  - Design work (a plan in `plans/`, a design in `docs/`) runs on
    `claude-bridge/claude-fable-5-1`, never on Sol. Fable also takes
    a complex task or review when the user asks for it.
- **Size the process to what the change is for,** not to its line
  count. Local tooling (the pi extensions in `.pi/`, a script that
  only agents use, a brief, a plan or other prose) gets one agent, a
  quick check such as `scripts/lint.sh`, and no tests, reviewers or
  full verification. A small product change (one behaviour, a few
  files) takes the small track: no planner, one implementer and one
  correctness reviewer, and the manager says that it chose it. A
  trivial visual change (a colour, a spacing, a font or a text, with
  an exact rule from `@kido-app-design` in the brief) takes the
  trivial track: no manager, no planner and no reviewer. The
  top-level session spawns one implementer in the quick worktree
  ("Worktrees"). The implementer makes the change, runs the tests of
  the package that it changed, records only the affected visual tests
  (`make -C app visual ONLY="<class>[/<test>] ..." RECORD=1`), opens
  the changed snapshots and reports. It does not run `scripts/checks.sh`,
  `ko-test` or the full visual stage; CI runs the rest. A finding
  outside the request (a defect seen on the way, a reviewer's idea)
  goes to the user as a follow-up item, not into the same unit.
- **Approval for new unsafe code and new routes.** Before an
  implementer writes a new `unsafe` block, `unsafe fn`, `unsafe impl`
  or `unsafe extern`, or adds a route to the `routes!` block, the
  manager sends its shape and its reason to the top-level session and
  waits for approval. The top-level session reviews it and asks the
  user when it is not sure. Moving or narrowing existing unsafe code
  needs no approval.
- **One manager for each unit of work.** The manager does not write
  code. It does these steps:
  1. For a fix or a feature that is not trivial, it first spawns one
     read-only planner. The planner reads the code path end to end
     and reports one design: the rule for each part, the existing
     abstractions that the change extends or replaces ("A feature
     fits the model"), each place that dispatches on them, what to
     delete, and the tests that must fail first. It names each place
     to change as file and line, with the shape of the new code (the
     types, the signatures, the match arms), so the implementer does
     not explore the code again. The manager checks the design
     against the code, then spawns one implementer with it. For a big
     feature, the planner stays alive as the implementer's advisor,
     named in the brief: the implementer asks it with `message_agent`
     when the code does not fit the design. The planner stays
     read-only, answers only, and reports a change of the design to
     the manager, which stops it with the implementer. A trivial
     change goes to the implementer directly.
  2. When the change builds and its new tests pass, the implementer
     reports, before any full verification. The manager writes the
     docs that the change needs itself, in `docs/`, this file and
     READMEs. The implementer reports the facts that the docs need
     and never writes them, so a smart model writes every doc.
  3. The manager spawns the four read-only reviewers of a simplify
     pass, one angle each, one correctness reviewer and one modules
     reviewer, so that review has fresh context. They review the code
     and the docs ("Review" above). Review does not wait for the full
     verification: that runs once, after the findings are applied.
  4. The manager merges their findings and decides which to apply.
     It changes the docs that the findings affect.
  5. It gives the findings to apply to the same implementer with
     `message_agent`, which keeps its context. The implementer's
     final verification runs after the last docs edit, because
     `scripts/lint.sh` checks the references in the docs.
  6. The manager reads the diff of every fix itself before it hands
     the fix back or starts a demo. For a visual change, it opens the
     changed snapshots, crops and zooms the affected area, and
     compares it with the reference state (windowed and fullscreen,
     light and dark) for seams, missing or extra lines and steps. The
     implementer's own inspection is not sufficient. The user must
     never be the first to find a visible bug in a demo.
  7. It owns the final verification. It reports to the top-level
     session: the result of the verification, and each finding with
     the reason it was applied or rejected. Then it stops the
     implementer.
- **Subagents.** Only a manager spawns subagents, for its own unit:
  its implementer, its reviewers, and parallel workers only when the
  work has a real parallelization opportunity. By default one
  implementer edits the code in the unit's worktree and builds in its
  normal `target/`. Implementers that run in parallel each get their
  own worktree. Read-only reviewers and researchers can share a
  checkout.
- **Mockups.** When the work follows a mockup, the implementer adds
  visual snapshot tests for every state of the mockup. Tests that
  only read state or frames are not sufficient. The manager reads
  each recorded snapshot, compares it with the screenshots of the
  mockup's states and sends every difference to the implementer. The
  work is not complete until the snapshots agree with the mockup.
- **Demos.** The user closes a demo that exits. Never start it again
  on your own, attached or detached. A crash is a new crash report
  for the demo's pid in `~/Library/Logs/DiagnosticReports` or a crash
  or panic in the lines of the demo's pid in
  `~/Library/Logs/Kido/app.log` (docs/design-app.md, "The log").
  Report a crash. Start a demo again only when asked.
- **No git writes.** Do not commit, push, reset, add, checkout or
  stash. Leave work uncommitted. Never use `git stash`. If
  `KO_AGENT_PARENT_SESSION` is set, `.pi/extensions/no-git-writes`
  guards bash tool calls.
- **Other agents' uncommitted changes are expected.** Work runs in
  parallel. The brief identifies your files. Do not revert, clean or
  fix anything outside those files. Report it instead.
- **You are inside the user's live ko server.** Every command runs
  against the pane's own server unless `--server` names another. `ko
  kill-server` without `--server DIR` and your own scratch directory
  kills the user's server. Start every test server on its own state
  directory under `/tmp`. Never touch the running demo or the user's
  servers.
- **Worktrees.** Each unit works in its own worktree
  `~/Workspace/kido-<unit>`, which the top-level session creates with
  `git worktree add --detach ~/Workspace/kido-<unit> <base>`. For a
  unit that does not change Ghostty, it clones the main checkout's
  built GhosttyKit for the worktree's pin (`cp -Rc
  app/build/ghosttykit/<pin>-*` into the worktree's
  `app/build/ghosttykit/`): the directory's name is the pin, the
  submodule's diff and the flags, so a match is the same build. A
  unit that runs app targets first runs `make build` under
  `scripts/quiet-limit 600`, because the app's ko phase hides the
  build's output and a cold build there can trip a 60 s limit. Agents
  start in that worktree and stay there. The top-level session merges
  the result, pushes, and removes the worktree only after every agent
  that ran in it has stopped. `.pi/extensions/no-git-writes/policy.ts`
  permits `git worktree add --detach` only to an absolute path there
  or under `/tmp`. The submodule makes `git worktree remove` refuse:
  remove the directory with `rm -rf`, then `git worktree prune`. The
  quick worktree `~/Workspace/kido-quick` is permanent: it keeps the
  submodule, its GhosttyKit and a warm `make build`, and the
  top-level session resets it to `origin/main` before each trivial
  unit, so the unit starts without setup or a cold build.
- **Every wait has a deadline.** Do not poll without a deadline in
  code or your shell. A build or test run that can take more than 10
  seconds runs through `async_bash` under `scripts/quiet-limit 60 --
  <command>`, which kills the command's process group and exits 124
  when the command prints nothing for 60 seconds, so a stuck test or
  a deadlock ends instead of hanging the agent. The one exception is
  the cold GhosttyKit build, `app/scripts/build-ghosttykit.sh`, which
  runs under `scripts/quiet-limit 600` because it does not print
  progress. Its notice arrives when it ends; read the run's log while
  it runs, and stop it with `stop_async_bash` when it is stuck. A
  demo runs through `async_bash` with `service: true`, not under
  `quiet-limit`: it runs until the user closes it, and no one stops
  it. While a background run works, end your turn; do not block on
  `sleep`. Continue when its notice arrives.
- **No signal to a pid from untrusted input.** No code, test, fuzzer
  or script gives a pid from fuzzed, synthetic or untrusted input to
  a signal call. A signal goes only through the one signal module of
  its language ("Signals" under "Rust"). Its types refuse such pids.
  A test checks the validation. It never sends a signal to prove it.
  When you change a fuzz target or a kill path, use grep to examine
  the kill paths.
- **Verify what you touched; CI runs the whole.** If a bug's cause is
  not clear from the code, write the test first. This includes a
  race, a flake, or an incorrect assumption about libghostty-vt, pi
  or Claude Code. Watch the test fail. Quote that failure. A simple
  fix or a feature needs tests that only pass. Test in proportion to
  the change: for a trivial change (a character of spacing, a word of
  text), update the expected strings that it breaks and add no new
  tests. Make sure that each test checks the intended behaviour.
  Assert the specific effect of the change, not a fact that is also
  true without it. For timing, races, deduplication or polling,
  assert the result that a defect would change. Do not break the code
  to prove that a test can fail.

  Batch the work and verify once at the end. Make all edits without
  intermediate suite runs: no repeated `make test`, `make verify` or
  the app's `make visual-fast` while you iterate. Run only the
  specific tests that you add or change. After the last edit, and
  after the review findings are applied and the last docs edit, run
  `scripts/checks.sh` once ("Which verification" under "Tests"). It
  tests only what the unit touched and controls environment
  scrubbing. Do not also run the top-level `make test`, `make e2e` or
  `make verify`. Report PASS/FAIL/SKIP as printed. An unrelated
  failure gets one run of that test alone, not a suite rerun. If a
  failure is in a file you do not own, report it. Do not fix it.
- **No repeated test runs.** A test runs again only after a change
  that can change its result. Do not run the same test or suite on
  the same code again, alone or in a loop, to reproduce a failure, to
  learn whether it was a flake, or to verify a fix: a second run of
  unchanged code shows nothing that the first did not. A fix is
  verified by a test that fails before it and passes after it.
- **A flake has a time box of 5 minutes, and no loops.** When a test
  fails only sometimes, find the cause from the failure itself: its
  output, the logs and the test's waits (see "No repeated test
  runs"). First suspect the test: a race in its waits, a read that
  discards what it waits for later, a wall-clock bound. When the output does not show the cause, add the
  diagnostics that would show it next time. A fix is verified by a
  test that forces the bad order and fails before the fix, not by
  repeated runs. A flaky test is rewritten to wait for the event, or
  dropped if it repeats another test. When the cause is a class of
  fault, such as an inherited descriptor, fix the class once, not
  each test. When the 5 minutes end without a cause, report the
  failure and the best hypothesis, and stop. The manager or the user
  decides on more work. A fuzz run or a long property-test run that
  an agent starts has the same time box of 5 minutes.
- **Your last message is your report. Keep it under 4000 characters**.
  Start with what you built and the pre-fix failures.

## Releasing

ko and Kido.app ship from `main`. ko has no release version and no
tags: the `ko` formula in `andreypopp/homebrew-tap` pins a revision
with a manually increased version. Only `kido-app/N.N.N` tags mark
Kido.app releases. `/release` (`.pi/prompts/release.md`) is the whole
sequence for an agent: Kido.app first when the schemas or the Ghostty
pin changed, then ko. After the change is on `main`, run
`scripts/release.sh VERSION`; `--dry-run` inspects its actions. It
requires HEAD equal to origin/main and green CI, and a removed or
renamed command or tool requires a minor bump. It never runs `brew
upgrade`. The user's agents run the `koa` that Kido.app bundles, so
a harness change reaches them only through a Kido.app release
(docs/release.md).

## Commit style

Use one imperative sentence, usually with no prefix and no trailing
period. The body explains *why*, in hard-wrapped prose. For a subtle
change, it also explains why the test has that design. Use recent
history as the reference:

    Send a prompt as a paste, so its newlines survive
    Quitting an editor no longer flashes the row green
    A program that has taken the terminal is not a running job
    One status vocabulary for agents and shells
