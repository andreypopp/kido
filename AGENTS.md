# Developing Kido

[README.md](README.md) describes Kido and its installation. This file
supplies context that the code does not contain: the rules that a
change can break, even if the change looks correct, and the way agents
work in this repository.

[docs/design-ko.md](docs/design-ko.md) contains the design of the
server `ko` and its decisions. [docs/protocol.md](docs/protocol.md)
describes the protocol's behaviour. [docs/design.md](docs/design.md)
describes the agent features: the store for each fact, the
messages and addressing, spawning and the window lifecycle, and the
boundary between ko and its pi extension.
[docs/design-subagents.md](docs/design-subagents.md) describes
subagents. [docs/design-program-status.md](docs/design-program-status.md)
describes pane classification and status. [docs/design-runtimes.md](docs/design-runtimes.md)
describes runtimes: the configuration, the link, the identity on a
runtime connection and the exec session. [docs/design-app.md](docs/design-app.md)
describes Kido.app. Before you change these mechanisms, read these
files. The code comments and this file do not repeat them.

Work in progress has a plan in `plans/`, with one markdown file per
plan. A plan describes work that is not complete. When the work is
complete, its agreed design moves into `docs/`. The plan is then
deleted.

## Code rules

These rules apply to Rust, TypeScript and Swift.

**No backward compatibility, ever.** The server, the clients, the
extension and the shims ship together from one checkout. When they
must agree, both sides change. Do not write fallbacks for state from
an older ko: old variables, record fields, flags or environment
variables. Do not add version gates, deprecated aliases or migration
paths. Change both sides.

Delete the old one.

State from an older ko is not a bug if a restart or user action
clears it.

**A feature fits the model; it is not bolted on.** A significant
feature can change what the existing abstractions must express.
Before it adds code, its design finds every place that dispatches on
the concepts it touches (an enum, a classification, a set of cases)
and decides whether to extend or replace them. A new case goes into
the type that names the cases, so that every match handles it. Do
not add a filter, an `Option` branch or a parallel field beside the
existing dispatch, and do not add a new abstraction where an
existing one extends.

**Plain functions over data.** Use abstraction only when it has a benefit.
Do not use a trait, generic or trait object without a second
implementation. Express the design through data structures. Make illegal
states unrepresentable.

- Use an enum for a set of cases (a discriminated union in TS).
  Do not use a struct of options or a combination of bools.
- Give a value with its own rules its own type, with a private field.
  Parse it once at the edge. Do not check a string in several places.
- Do not use strings for typed values. A closed set of names is an
  enum, even in a record that only goes to JSON. Only the codec
  knows the strings.
- Do not give a number a special meaning. "Unknown" is `None`, not
  `0`. "Disabled" is its own variant, not `0`. The magic value exists
  only in the codec at the edge: a C API, a frame or a flag.
- One `None` has one meaning in a record. Do not use `None` for
  "no limit" in one field and for "disabled" in the next.
- Use one record for parallel fields or maps that describe one thing.
  Fields that are known or unknown together are one option of a
  record, not two fields.

**Minimal line count.** Do not abstract something with one use. Inline a
function, type, trait, constant, option struct or test helper with
one caller. Do not add wrappers that only forward. Do not add traits
or swappable variables without a second implementation. Remove dead
code and unused parameters.

Put duplicated logic in one place.

**Module boundaries.** Each subcomponent has its own module. Use its
exported surface. `ko/src/main.rs` connects subcommands to the library
crates. It contains commands too small for library code. Domain logic
belongs in the module that owns the domain.

A type that exists only for the wire and a protocol constant belong to
the protocol module, not to the settings module. A setting that the
protocol reports stays with the settings.
A type whose module cannot construct it is probably in the wrong
module.

**Library code returns, the CLI reports.** A library function returns
its result: a value, an `Option` or a `Result`. It does not print,
panic or exit. A command body belongs in `ko/src/main.rs` if it only
calls the library, prints and returns an exit code.

**No display logic in the libraries.** Human-facing formatting belongs
in `ko/`. This includes tables, alignment, padding, truncation, glyphs,
styles, local time, usage text, and labels and captions composed from
facts. A wire type contains only semantic data: plain titles and typed
status, as uncut text.

**State.** Use one source of truth for each fact. Never hold the same
fact in two stores:

- A layout row and a pane variable.
- A Rust record and a TS or Swift copy.
- A file and an in-memory mirror.
- A doc and the code.

Docs do not repeat what the code defines: field lists, JSON examples,
byte layouts, enum values or flag tables. They name the file that
defines it and give only what the code cannot say: semantics,
ordering, rationale and decisions. A plan for code that does not exist
yet can give shapes, until the code exists.

Do not store a fact that you can derive. Compute it when necessary.
The exception is a value that needs validation or I/O to resolve,
such as a checked path. Resolve it once at the edge and store it in
the record that every caller reads.
Read and write each piece of state through its owner module only.

**No comments unless absolutely necessary.** Code should explain itself.
Do not add narration or doc comments that repeat the name. Do not add
history ("previously", "no longer", "since this fix"). Design rationale
belongs in `docs/`, not comments. Keep only these comments:

- A verified external constraint that the code cannot express:
  a libghostty-vt, pi, Claude Code or OS quirk.
- The reason for a workaround, while that workaround exists.
- A link to the issue for either case.
- The `///` doc comment that clap turns into help text, and the
  `///` on a wire type that becomes its OpenAPI description.

Build, compiler and formatter directives are not comments. If a
diagnostic suppression hides a correctness failure, fix the cause.
A stale comment is worse than no comment because readers trust it.
When a mechanism changes, use grep to find prose that describes it.
Check each statement in a comment against its source: a header, the
code or a test. Do not write a fact that you did not read.

## Communication

Always use ASD-STE100:

- When you communicate with the user.
- When you produce commit messages or commit descriptions.
- When you produce PR titles or PR descriptions.
- When you add code comments (see **no comments unless absolutely necessary** above).

## Rust

These requirements are fixed:

- **Layout.** One cargo workspace at the root. A package has the
  name of its directory, with the underscore ("Layout" below). `ko/` is
  the binary `ko`: `ko/src/main.rs` holds the command table and the
  small command bodies, which print and return the exit code.
  `ko_pane/` is the crate `ko_pane`: the binary `ko-pane`
  (`src/main.rs`) over a library that the `control` fuzz target also
  calls. One `ko-pane` process runs for each pane. `fuzz/` is the
  cargo-fuzz crate, a workspace member outside `default-members`:
  clippy checks it on stable, and only `make fuzz` runs it.
  `ko_tui/` is the terminal client that `ko` runs without a
  command: the mirror, the renderer, the input and the tty.
  `ko_client/` is the client core that `ko_tui` and `ko` use and
  Kido.app links: the launcher, the wire layer, the API client, the
  `/client` model and the SSH remote (`remote.rs`: the master, the
  forward and their cleanup). It never depends on `ko_vt` or
  libghostty-vt. `ko_shell/` is the crate `ko_shell` that `ko shell`,
  `ko ssh` and `ko server --bin-dir` use: the priming of a local or
  remote login shell, the ssh arguments, the bin directory lookup,
  and `ko enter`, with the exec session's supervisor (`session.rs`).
  It embeds the shell integrations of `share/ko/` with `include_str!`;
  `make build` installs `share/ko/bin` (the `ko`, `ssh` and
  `ko-pi` shims), `share/ko/shim.sh`, `share/pi/ko-pi.ts` (as
  `share/ko/pi/ko-pi.ts`) and `share/pi/skills` (as
  `share/ko/pi/skills`) beside `bin/ko` in `build/ko/`, the layout
  that `ko_shell/src/bin_dir.rs` finds as installed.
  `ko_config/` is the crate `ko_config`: the configuration file
  `config.yaml` (its types, the path rule, the YAML decode in
  `yaml.rs`, the theme writer and its JSON schema; docs/design-ko.md,
  "The configuration file"), the values that the file and the wire share
  (`RuntimeName`, `AbsPath`, ...) and the ssh option classifier
  (`ssh_args.rs`). It depends on no ko crate.
  `share/pi/testdata/fake_ko/` is the crate `fake_ko`, the fake `ko`
  of the TypeScript suite, a workspace member outside
  `default-members` that `make build-fake-ko` builds for
  `scripts/test-ts.sh`. `ko_bench/` is the binary `ko-bench`, the
  benchmark modes, which `make build-bench` builds into `target/release`
  and never installs. ko has no C of its own; the only C is the
  measurement helpers of `bench/`, which `make build-bench` compiles.
  Do not add new C.
- **Toolchain.** `rust-toolchain.toml` pins the toolchain of the
  pinned Verus release. They move together. Homebrew's keg-only
  `rustup` formula supplies it (`brew install rustup`, then
  `$(brew --prefix rustup)/bin/rustup toolchain install`, which reads
  `rust-toolchain.toml`; with rustup 1.28 or later, `rustup show`
  installs nothing). Its `bin` is not on PATH, and Kido does not ask the user
  to change PATH. The Makefile is the one place that finds cargo: it
  puts that `bin` first on PATH, and it calls `$(CARGO)` by its full
  path, because make 3.81 on macOS looks up a recipe's command
  through its own PATH, not the exported one. Thus, every cargo
  command runs through a Makefile target. Scripts call make, never
  cargo. CI's toolchain install and `cargo fetch` steps are the
  exception. Every cargo command passes `--locked`. `Cargo.lock` is
  committed. zig comes from PATH, at the release that
  `scripts/install-zig.sh` pins; it must equal the
  `.minimum_zig_version` of `third_party/ghostty/build.zig.zon`, and
  `scripts/lint.sh` checks that. `rust-toolchain.toml` also lists the
  targets `aarch64-unknown-linux-musl` and `x86_64-unknown-linux-musl`
  of the static Linux ko ("Layout" below), so `rustup toolchain
  install` adds them. For them, `.cargo/config.toml` names the linker
  wrappers `scripts/zig-cc-<arch>-linux-musl` (`zig cc -target
  <arch>-linux-musl`) and sets `-C link-self-contained=no`: with
  rustc's own `crt1.o`, `_start` is defined twice. Both names are
  symlinks to `scripts/zig-cc-musl`, which reads the target from its
  own name and drops `-Wl,--fix-cortex-a53-843419`, which zig's
  linker refuses.
  Nightly exists only for cargo-fuzz
  and Miri: `scripts/nightly.sh` pins it, and `scripts/fuzz.sh`,
  `scripts/miri.sh` and `.github/workflows/ko-nightly.yml` source it.
  The two scripts run the nightly cargo through `make nightly-cargo
  ARGS=...`. Without that toolchain, or without cargo-fuzz or the
  `miri` component, the two scripts print SKIP and exit 0. Agents do
  not install it.
- **Platforms.** ko builds and is verified on macOS and Linux (glibc
  2.34 or newer, for `posix_spawn_file_actions_addclosefrom_np`; the
  static Linux ko uses musl).
  Each OS call that differs has its two halves in `ko_sys`, behind
  `cfg(target_os)`. The static Linux ko builds against musl, which
  has no `addclosefrom_np`: `ko_sys::spawn` adds a close for each
  entry of `/proc/self/fd` there, behind `cfg(target_env)`. Outside
  `ko_sys`, only the C++ runtime that `ko_vt_sys/build.rs` and
  `build-bench` link (`c++` on macOS and musl, `stdc++` on glibc), `ko_client::ffi` (code that only the ffi uses
  lives in it; an item that needs another module's private fields,
  as `Model::json`, carries `cfg(target_vendor = "apple")` on itself
  and on the imports that only it uses, never an
  `#[allow(dead_code)]`), and tests that pin a platform's behaviour
  branch on the platform. On Linux, a read of a unix socket whose peer closed
  with unread input fails with `ECONNRESET`; `ko_sys::fd::read`
  returns it as `Ok(0)`, the end of the source.
- **Dependencies.** The production crates are `libc`, `httparse`,
  `tungstenite` (feature `handshake` only), `serde` (`derive`),
  `serde_json`, `schemars` (`default-features = false`, with
  `derive` only), `vte` and `clap` (`default-features = false`, with
  exactly `std`, `derive`, `help`, `usage` and `error-context`),
  `miniz_oxide` (`default-features = false`, with `with-alloc`
  only; it brings `adler2`) in `ko_server` and as a
  dev-dependency of `ko_client`, `ko_tui` and `ko_e2e`, and `vstd`
  and `verus_state_machines_macros` in `ko_pane_wire` and `vstd` in
  `ko_server`, pinned with `=` to the crates version of `scripts/verus.sh`
  (`scripts/lint.sh` compares them), and `saphyr-parser` (it brings
  `arraydeque` and `thiserror`) in `ko_config`, and `clap_complete`
  (pinned with `=`, `default-features = false`, with
  `unstable-dynamic` only; it brings `is_executable`, `shlex` and
  `clap_lex`, and enables clap's `unstable-ext`) in `ko`.
  `proptest` and `loom` are dev-dependencies.
  `scripts/crates.txt` lists every package of `Cargo.lock`, ko's own
  crates included. `scripts/lint.sh` fails on a package that the list
  does not name, and on a listed name that `Cargo.lock` does not
  have. A new direct crate, or a new feature that adds packages, is a
  decision for the user, with the cost of the hand-written
  alternative in the request. No async runtime and no crate that
  needs one: no `tokio`, `hyper`, `mio`, `futures`, `async-std` or
  `smol`, and no `async fn` in ko's code.
- **Formatting and lints.** `cargo fmt` with `rustfmt.toml`.
  `cargo clippy --all-targets -- -D warnings` is clean.
  `[workspace.lints]` in `Cargo.toml` holds the denied lints, and
  every crate inherits them. `clippy.toml` permits `unwrap`, `expect`,
  `panic!` and indexing in tests. The readers of untrusted bytes
  (`ko_pane_wire`'s `frame.rs` and `ring.rs`, `ko_server`'s
  `pane_proc.rs`, `exec_wire.rs`, `http.rs` and `ws.rs`, `ko_pane`'s
  `io.rs`) also deny `clippy::indexing_slicing` and
  `clippy::arithmetic_side_effects`. `print_stdout` and `print_stderr`
  are denied: the CLI writes through `writeln!` on a locked stream, and
  only `ko_bench/src/main.rs` and the fake ko's `main.rs` allow the
  macros. Inside `verus!`, Verus
  also proves that each index is in bounds and that no arithmetic
  overflows.
- **The command line is a contract** with `ko_e2e/`, `bench/`,
  `share/` and Kido.app. A long option is `--name`. clap's derive
  generates `--help` and the usage errors: the doc comment on each
  command and argument is its help text. A usage error exits 124.
  `ko api`'s flags, exit codes and output are the contract with the
  pi extension (docs/design.md, "The pi extension, ko-pi").

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
  `Box<dyn Error>` in ko's code. A crate's error becomes ko's own
  error at the edge that received it. A command body in `ko/src/main.rs`
  prints a failure as `ko <name>: <message>` and returns 1.
- **Visibility is the interface.** An item is `pub` only when another
  crate uses it, and `pub(crate)` only when another module uses it.
  `lib.rs` lists modules and re-exports nothing. `unreachable_pub`
  catches a `pub` item that the crate root cannot reach, but rustc
  does not report an unused `pub` item of a library. Thus, review
  checks that another crate uses each export.
- **Tests** are `#[cfg(test)] mod tests` at the bottom of the file
  under test. Expectations are `assert_eq!` on values or strings.
  Property tests use proptest in the same module. No unit test execs
  the `ko` binary; the e2e suite does that. `ko_pane/tests/pane.rs` drives
  the `ko-pane` binary over a socketpair and a ring. The `Server` SIGTERM test starts the
  `ko-pane` that `make test` builds and names in `KO_PANE_EXE`. A test starts a process only through
  `ko_sys::spawn::program`, which closes every descriptor but its
  targets and stderr in the child: `POSIX_SPAWN_CLOEXEC_DEFAULT` on
  macOS, `posix_spawn_file_actions_addclosefrom_np` above the targets
  on Linux. On macOS, `UnixStream::pair` and `accept` set
  close-on-exec only after they create the descriptor, so a
  `std::process::Command` in another test thread can inherit it and
  keep a peer open. A test
  that closes a peer waits, with a deadline, until the other end sees
  the hangup: a `posix_spawn` in another thread holds every
  descriptor until its child execs.
- **The e2e suite** is `ko_e2e/`: one integration-test binary,
  `ko_e2e/tests/e2e/main.rs`, with one module for each area, because
  cargo runs test binaries one after another and the tests of one binary
  in parallel. It is a workspace member outside `default-members`, so
  `make test` does not run it. Its second binary, `ko-fake`
  (`ko_e2e/fake/main.rs`), is the fake program of the status and ssh
  tests: a test copies it under the name it stands for (`ssh`,
  `ko-probe`), because macOS reports a `#!` script's interpreter as
  its process name. A pane that runs `stty raw -echo; exec cat`
  echoes the OSC 133 and OSC 7501 bytes that a test sends as `text`
  input, so no fake agent exists. It also echoes the
  terminal's kitty graphics reply (`ESC _ G i=N;OK`) back as a new
  command that replaces image N, so a test sends graphics with
  `q=2`. The ssh tests that use the
  host's sshd run only with `KO_E2E_HOST_SSH=1`: sshd starts the real
  user's shell, which reads that user's dotfiles whatever `HOME` the
  test sets; with the variable set, a failed ssh probe or a missing
  zsh is a failure, not a skip. The remote tests (`remote.rs`) and the
  ssh runtime tests (`runtime_ssh.rs`) run under the same variable,
  with a private `sshd` (`sshd.rs`: its own config, and host and
  client keys made once for each process), so a test can refuse
  forwarding, lower `MaxSessions` or need a key passphrase, and an
  `ssh` wrapper on the client's PATH that adds `-F`. They never read the user's `~/.ssh`. CI sets the variable on
  both runners; its step "Set up localhost SSH" starts sshd and
  authorizes a key for localhost. The container test (`container.rs`)
  runs only with `KO_E2E_CONTAINER=1`, on a Mac where Apple's
  `container system status` succeeds and the image `debian:trixie`
  is present: it runs the aarch64 static ko of
  `build/ko/share/ko/linux/aarch64` in a container and compares its
  `ko version` with the host's, and it drives a `container` runtime
  through one server (docs/design-runtimes.md, "The container kind").
  Its runtime name carries the test's pid, so the container `ko-<name>`
  is its own, and a drop guard deletes that container on every exit;
  it never touches another container and pulls no image. It needs
  `make build-linux` first; with the variable set, a missing layout
  or `container` CLI is a failure. CI does not set it.
  The podman test (also in `container.rs`) runs only with `KO_E2E_PODMAN=1`, on
  a Linux host with podman and the image
  `docker.io/library/debian:trixie`: it drives a `podman` runtime
  through one server with the host's static ko, under the same
  naming, drop-guard and no-pull rules as the container test; with the
  variable set, a missing `podman`, image or layout is a failure. CI
  sets it on the Ubuntu runner only, after a pull of the image.
  The suite drives `build/ko/bin/ko`,
  which `make e2e` builds first; a test never runs make or cargo.
  A test reads like command-line use: a step that a `ko` command can
  do (`ko api`, `ko kill-server`, `ko version`) runs that command
  through `Server::ko`, or `run_ko` without a started server or with
  its own environment, and asserts its stdout, stderr and exit code,
  with the request path written out at the call site. Raw requests,
  written as literal bytes and parsed with httparse, stay only for
  HTTP framing, exact statuses, hostile input and polling loops.
  WebSocket views and clients use tungstenite's client role; the hostile
  tests send raw frame bytes. The outer terminal's steps name keys and
  text (`prefix("s")`, `line("echo abc")`, `contains`, `gone`). Snapshots
  decode in the test process through `ko_vt::Terminal::decode`. A client
  test is the outer terminal (`outer.rs`): an interactive `/bin/sh` on a
  pty from `ko_sys::pty::spawn`, with job control off (`set +m`;
  with it, bash 3.2's `setpgid` for the attach child can fail with
  `EPERM`, and the client's tty read fails with `EIO`), and a `ko_vt::Terminal` that gets every
  byte from the master and writes its replies back, so the client's
  queries get a real terminal's answers. An outer terminal without
  extended keys drops the kitty keyboard query (`CSI ? u`) before the
  terminal sees it. The screen, the cursor and the modes that the tests
  read change only outside synchronized output (mode 2026), as a real
  terminal paints. Each child gets an explicit environment through
  `spawn::program`'s `Env::Only`, scrubbed as `harness::test_env` does,
  with a private `HOME` and XDG directories; the test process never sets
  its own environment. A server's private `HOME` is its state
  directory, which `harness::start_with` gives an empty `.zshrc`:
  without it, Debian's zsh-newuser-install menu blocks a login zsh.
  State directories are under `/tmp`, for the
  104-byte socket path limit. Every wait reads a socket or polls a
  condition with a deadline of 5 s. `scripts/lint.sh` refuses
  `thread::sleep` and `thread::park_timeout` in `ko_e2e/` except through
  its table of exact statements; `harness.rs` holds the poll tick. The
  cargo feature `e2e` of `ko_sys` holds the OS calls that only the suite
  needs (`signal_descendant`, `Pid::parent`, `Pid::has_ended`,
  `Pid::wait_exit`, `Signal::Stop`, `Signal::Cont`, `fd::wait_readable`,
  `fd::wait_writable_within`), and only `ko_e2e` enables it. A `Child`
  of the harness reaps its process under the lock that its signals take,
  after a wait that keeps the zombie, so no signal reaches a reaped pid.
  `make e2e` runs the tests with `--test-threads=$(E2E_THREADS)`.
  The default is 64, so on a developer's Mac every test starts at
  once. CI sets 16: its runners have 3 (macOS) and 4 (Ubuntu) cores,
  and at 64 the CPU work of all tests at once exceeds the 5 s
  deadlines. A lower count does not fix a test that fails at 64: that
  test has a race or does too much work.
- **loom.** `ko_pane_wire::ring::model` checks the ring's records
  and the wakeup handshake on the real `Reader` and `Writer` under
  `--cfg loom` ("Proved modules" below). `make
  test` runs them in `target/loom`. loom does not model a `SeqCst`
  access as sequentially consistent, so the model puts a
  `fence(SeqCst)` beside each one (its comment has the issue). The
  acquire/release twin of the wakeup model is `#[should_panic]`.
- **Verus.** `ko_pane_wire::ring`, `ko_pane_wire::frame::Req`,
  `ko_server::delivery`, `ko_server::view` and `conn.rs`'s `Batch` are
  verified with Verus (`make verus`, `scripts/verus.sh`, the pinned
  release archive in `build/verus/<release>/`). A verified crate has
  `[package.metadata.verus] verify = true` and builds with plain
  cargo, because `verus!` erases the ghost code. Specs and proofs are
  in `verus!{}` beside the code: `ring/spec.rs` (the log),
  `ring/machine.rs` (the state machine and its invariant),
  `ring/mark.rs` (the reader's log marks) and
  `ring/backend.rs` (the trusted base). `cfg(verus_only)` guards only
  `use` statements. `#[verifier::external_body]` and
  `external_fn_specification` occur only in `ring/backend.rs`,
  `delivery.rs`, `view.rs` and `conn.rs`. In `ring/backend.rs`: the
  constructor of each role (`Backend::mint_reader`,
  `Backend::mint_writer`), the mapping's creation
  (`create_handle`, with no `ensures`), the capacity getter, the
  header word load and store, the byte accessors, the pty read into
  the writer's bytes (`Backend::read`, read(2)'s contract) and the
  opaque types that they use. A record publishes only over payload
  bytes that were written. In `delivery.rs`: the sink call (`hand_over`, with
  no contract), the stamp counter's constructor (`mint_stamps`, one
  for each process, with the opaque token `Bound` of the stamps that
  it handed out), `bind_fresh`, which ties a stamp that `Bound` does
  not hold to its ring's mark instance, and `exhausted` (the error
  value, with no contract). The coordinator's `Panes` owns the one
  `Stamps`. Verus proves that its stamps increase, never repeat and
  never wrap. In `view.rs`: the
  WebSocket sends (`reject_ws`, `emit_marked`, `emit_dead`,
  `emit_skipped`, `write_slice`) and the marker decode (`resize_marker`). In
  `conn.rs`: `Output`'s `waiting`, `available`, `close` and
  `send_batch` over the opaque `closed` and `waits`, and
  `Header::new` (the record header). Each has an `// Assumes:` comment that
  names its assumption. No `external_body` function has an `ensures`
  that its body does not establish beyond that comment. No `assume`
  and no `admit` occur. The functions that `tokenized_state_machine!`
  generates are `pub`, so everything that their contracts name is
  `pub`, and the ring's proof modules allow `unreachable_pub`. rustfmt
  does not format the inside of `verus!`. `scripts/verus.sh` cleans
  each verified crate first, so every run verifies, and it fails
  without a "verification results" line of 0 errors for each crate:
  it verifies one crate for each `cargo verus verify` run and reads
  the last result and time of that run, because Verus names no crate
  on the line. It keeps each crate's whole output in
  `target/verus/<crate>.log` and prints it only on a failure.
  `ko_server::delivery` (`Delivery`) owns the pane's
  `Reader`, its snapshot queues, the delivered position and the mint
  of every `Req` (a u64 serial; the `Req` is its low 32 bits). A
  snapshot request's floor is the head that `request` loads. Its
  `wf` keeps the delivered position at a boundary of the log and the
  queued serials unique and in mint order. A slice reaches a view only as a
  `Handle` that `deliver` constructs, and a snapshot's end only as a
  `Done` that `snapshot_done` or `fail_all` constructs. The views get
  `&mut Delivery`, whose methods keep the tail, so only `scan`
  advances the ring. A `View` keeps its `Delivery`'s stamp, its
  request's serial and slice count, and a `Mark` of the log. `open`
  and `pump` compare the stamp at run time; `on_slice` and `on_done`
  compare the stamp and the serial. The `View`'s `wf` holds through
  every `pub(crate)` method, because its fields are private. A view
  places its cursor through `Delivery::seek`, and the cursor lemmas
  are facts of the log in `ring/spec.rs`. `delivery.rs` denies
  `clippy::arithmetic_side_effects` but not `indexing_slicing`:
  vstd specifies only `VecDeque::len` and its index, and Verus proves
  each index in bounds. The `verus`
  stage of `make verify` fails when the verification of ko's
  crates takes more than 120 s, and it is SKIP when the archive cannot
  be fetched, except with `KO_VERUS_REQUIRED=1` (CI).
- **Derives.** Every type derives `Debug`. Derive `Clone`, `Copy`,
  `PartialEq` and `Eq` where the type is a value. Derive `PartialOrd`
  and `Ord` only where the order has a meaning, `Default` only when
  every field has a meaningful default, and `Hash` only for a map key.
- **Newtypes.** A value with its own rules is a newtype with a private
  field and one validating constructor. A closed set is an `enum`. "Unknown" is `None`. "Disabled" is a variant.
- **Unsafe.** `unsafe` is permitted in `ko_sys`, in `ko_vt_sys` (the
  generated bindings), in `ko_vt` (the safe wrapper over them), in
  `ko_pane_wire::ring::mapping` and `ring::model` (the loom backing),
  in `ko_client::ffi` and its modules `ffi::engine` and `ffi::view`
  (the C ABI of Kido.app, beside `ko_client/include/ko_client.h`) and
  in `ko_bench/src/alloc.rs` (the counting global allocator).
  Every other crate and module denies it. Each block has a
  `// SAFETY:` line that names the invariant. A safe wrapper takes
  typed arguments and returns `Result`. Descriptors are `OwnedFd` and
  `BorrowedFd`; no raw descriptor crosses a module boundary. A signal
  handler only sets its pending flag and writes its pipe. A callback
  from libghostty-vt never unwinds and never calls back into the
  terminal.
- **JSON.** serde derives every codec. `ko_server::protocol` owns
  the wire types. An enum with a payload variant has `#[serde(tag =
  "type", rename_all = "snake_case")]`, so a message is one flat
  object; a primitive, list, id or enum payload is a struct variant
  with one named field. The error body flattens its kind with the tag
  `kind`. A unit enum uses `rename_all = "snake_case"`. An option field has
  `#[serde(default, skip_serializing_if = "Option::is_none")]`. A
  value with its own rules (an id, a size, a key, base64 text)
  validates in its `TryFrom`, through `#[serde(try_from = ...)]` on
  the derived codec. Every untrusted body and WebSocket message
  decodes through `protocol::decode`, which refuses a JSON array for a
  record at every level; serde's derive alone accepts one. It decodes
  through the derive and, when the input has an array, compares the
  input's shape with the re-encoded value. Do not write a codec by hand, and do not walk a
  `serde_json::Value` to decode a wire type. Catch a decode error only
  at an untrusted-input edge: an HTTP body or a WebSocket text
  message. Every wire type derives `JsonSchema` (schemars). A type
  with a `try_from` codec writes its `JsonSchema` by hand, with the
  pattern or range that its `TryFrom` checks. A range that a `///`
  states is also a `#[schemars(range(...))]`.
- **Routes.** `ko_server::api` declares every route in one
  `routes!` block (the macro is in `ko_server::route`). The block
  generates `Route` (path and query, parsed from the head before the
  body), `Request` (the route with its decoded body), one marker type
  for each route in `routes::` and `ROUTES`, the catalog from which
  `ko_server::schema` builds the OpenAPI document of `ko api-schema`. A query or path parameter type implements
  `Param`, and its validation (the wait cap, a range) is in that type,
  not in the router. `router.rs` matches `Request` exhaustively and
  replies through `ok::<routes::X>` and `alt::<routes::X, STATUS>`, so
  a reply that the declaration does not name does not compile. To add
  a route: add its block with its `///` doc (the OpenAPI description),
  add the arm in `router.rs`, then run `make schemas`. `make schemas`
  (`scripts/lint.sh --update-schemas`) rewrites
  `share/ko/openapi.json`, `share/ko/client-model.json` and
  `share/ko/config-schema.json` from `ko api-schema` and `share/pi/ko-api.d.ts` from the first through
  openapi-typescript (pinned in `share/pi/package.json`). lint fails
  when a file differs from the generated output. `ko-pi.ts` takes its
  HTTP and `/client` shapes from `ko-api.d.ts` and writes none by hand.
- **HTTP.** `ko_server::http` is the only code that reads or writes
  HTTP framing, for the server and for the client. httparse parses
  heads. A request head has a limit of 16 KiB of bytes; a longer head
  gets `431` after the responses to earlier pipelined requests.
  Pipelined requests get their responses in order.
- **The view write path.** `ko_server::conn` writes a view record
  with `write_vectored` over `IoSlice`s, only while the connection's
  queue is empty. A `bytes` record borrows the ring; a snapshot
  slice is deflated into the scratch buffer of the coordinator's
  one `Deflate` (`ko_server::deflate`) and written from it. A
  partial write copies the rest into the queue. Every other byte of a WebSocket goes through
  tungstenite into the same queue. The queue has a cap: a view's
  output past it goes to an unlinked spill file of the state
  directory (`ko_server::spill`, over `ko_sys::file::unlinked`),
  drained after the queue, and a spill over its limit closes the view
  with close code 1013 (docs/protocol.md, section 4); every other link
  closes at the cap. No other code writes a connection's descriptor.
- **Atomics.** The ring header's loads and stores are `SeqCst`
  ("The ring indices are sequentially consistent" below).
  `scripts/lint.sh` refuses any other `Ordering` in `ko_pane`,
  `ko_pane_wire` and `ko_server`, except in the loom model
  `ring/model.rs`.
- **Signals.** `libc::kill` occurs only in `ko_sys/src/pid.rs`.
  `scripts/lint.sh` refuses it, `killpg`, `nix::sys::signal` and a
  `kill` command elsewhere. `Pid::new` refuses 1 or less, values over
  `i32::MAX`, the own pid and the own process group. A `Group` exists
  only after `Group::verify` read from the OS that the pid is a child
  of the given parent and leads its own group and session.
  `Group::signal` checks the start time and the group again.
  `ko-pane` signals its program's group only through the
  `ko_sys::pid::Program` that `pty::spawn` returned after `exec`;
  `ko enter --exec` signals its command's group only through the
  `Program` that `spawn::grouped` returned.
  It owns the child and is not `Copy`, and its reap consumes it, so
  no group signal follows the reap. `ESRCH`
  is not an error, and neither is `EPERM` on a group signal.
  In Python, `bench/client.py` signals only through `signal_child`.
  In TypeScript, `share/pi/ko-pi.ts` signals only the process groups
  of the jobs that it spawned itself, through `signalJob`, which takes
  a record of its job registry; `scripts/lint.sh` refuses
  `process.kill(` anywhere else in `share/pi/` (docs/design-subagents.md, "Stopping a job").
  `ko_e2e` signals a process that it
  spawned through its `Pid`, and any other process only through
  `ko_sys::pid::signal_descendant`, which refuses a pid that does not
  descend, within 64 hops of the parent chain, from the given root:
  the server that the test started or the outer terminal's shell.
  `scripts/lint.sh` refuses the other signal calls in `bench/`:
  `killpg`, a C `kill(-` and Python `os.kill`.
- **Syscalls.** Every own libc call that can return `EINTR` goes
  through `ko_sys::retry`. An `EINTR` from the loop's wait (`poll`, `select` on macOS for a
  deadline below 1 ms, or `ppoll` on Linux) is a turn with no
  events. A read of zero bytes is the end; `WouldBlock` is "not
  ready". Signal handlers have `SA_RESTART`, but no call relies on it.
- **The loop.** Every ko process is one thread on `ko_sys::event`,
  except for the terminal client's mirror compressors and the threads
  of `ko_client::ffi` (both below):
  non-blocking descriptors, the nearest deadline as the `poll`
  timeout and none without one, at most 16 reads of a source per
  turn. The server's listener accepts at most 16 connections per
  turn. Signals reach the loop only through the self-pipe
  of `ko_sys::signal`, one `Signals` per process. Back-pressure is the
  interest. The owner matches on the ready tokens and the due timers
  and calls its own handlers with `&mut self`; no callback is
  registered with the loop, and no `Rc<RefCell<..>>` exists. A
  request that waits (a pane stop with a wait, a message's wait for
  its ack)
  is a connection in `Phase::Handling` with a waiter stored in
  `State` and, for its deadline, a timer of the loop, never a thread
  (docs/design-ko.md, "The loop rule").
- **The terminal client.** `ko_tui`'s loop watches stdin, the
  `/client` link, the view of each visible pane and the signal pipe. Its plain
  requests (create, delete, list, layout edits, the pager's
  `/screen`) block with
  the deadlines of `ko api`. While the pager runs, the loop keeps
  every link and stops reading stdin and painting until `SIGCHLD`
  reports the pager's exit, so pings get their answers. A turn
  handles `SIGWINCH` after it dispatches the stdin events that it
  read, so input that the terminal sent before a resize maps to the
  old layout. It handles the other signals at once. The
  compressor thread of each mirror shares it
  under a `Mutex` and a `Condvar`. It does CPU work only and never
  wakes the loop. `ko_vt::Terminal` is `Send` only for these threads,
  and the `Mutex` serializes every call. vte tokenizes the outer
  terminal's input, and `ko_tui::input` translates its events.
- **The C ABI.** `ko_client::ffi` builds only for
  `target_vendor = "apple"`; no other crate uses it, and the Linux
  build has none of it. The header comment of
  `ko_client/include/ko_client.h` is the contract: handles, memory,
  threads, close and reconnect. The ffi lives in the app's process,
  so it has threads: one I/O thread (`ffi::engine`) on
  `ko_sys::event` that owns the `/client` link, every view link and
  the reconnect, and one decoder
  thread for each view (`ffi::view`) that runs the restore and feed
  callbacks. A call wakes the I/O thread through a
  `ko_sys::event::Wake`. A second `Wake`, set at close, is the
  cancellation that ends the blocking calls (`ko_sys::fd::wait` with
  a cancel descriptor). Events reach the
  app only through `dispatch_async_f` on the caller's serial queue.
  `ko_client_put_layout` is conditional on the document's
  revision: when the layout changed, it returns `KO_ERR_CONFLICT`
  with the newer document in its buffer, and the caller applies its
  edit to that document and sends it again. A view gives the restore
  the `continuation_max_bytes` of the client's `Welcome`
  (docs/protocol.md, section 4).
  `ko_config_defaults`, `ko_config_load` and `ko_config_set_theme`
  take no handle and block on at most one file; the app calls them on
  main.
- **Time.** `Mono` is nanoseconds of `CLOCK_UPTIME_RAW` on macOS, as
  `ko_now_ns` reads it, and of `CLOCK_MONOTONIC` on Linux. The loop's deadlines are `std::time::Instant`.
  Timeouts are `Duration` arguments, not statics.
- **Environment.** Read the environment at the edge
  (`ko_server/src/config.rs`, `ko/src/main.rs`). Pass its values to
  functions as arguments. Tests pass a temporary directory. No test
  sets an environment variable of its own process.
- **FFI bindings.** `scripts/bindgen.sh` (`make bindgen`) generates
  `ko_vt_sys/src/bindings.rs` from `third_party/ghostty/include` with
  the bindgen CLI (`cargo install --locked bindgen-cli`; on macOS,
  `LIBCLANG_PATH` can name the Command Line Tools' `usr/lib`). The
  file is committed with the hash of the headers in its first line.
  A change of the ghostty pin regenerates it in the same commit.
  `scripts/lint.sh` checks the hash.
- **One Ghostty.** `third_party/ghostty` (the `kido-upstream` branch
  of andreypopp/ghostty) is the one Ghostty checkout of ko and
  Kido.app: libghostty-vt for ko, GhosttyKit for the app
  (`app/scripts/build-ghosttykit.sh`). A pin bump moves both, so it
  passes ko's verification and the app's build and tests. The
  top-level session moves a submodule pin, because the guard refuses
  `checkout` and `add` for agents. The stack is linear on upstream,
  with one commit for each feature and each fix folded into its
  feature. Before a force-push, its previous head is pushed as a dated
  branch `kido-upstream-YYYY-MM-DD`. A folded commit keeps the
  `Co-authored-by` and `Based on` trailers of every commit in it. The
  stack keeps only what the app or ko calls: the mirrored surface
  (manual IO, the decoder's grid, suppressed replies, the size lock),
  the embedder APIs, the pending kitty images and their frame API, and
  the snapshot restore. An API whose last caller goes leaves the stack.
  A pin bump changes `Ko-Vt`, so it is a coordinated release of ko and
  Kido.app ("Releasing").
- **libghostty-vt.** `ko_vt_sys/build.rs` builds it with zig from
  PATH. Every cargo profile and target directory shares one zig cache,
  so libghostty-vt compiles once for release, test and clippy. The
  cache is `target/zig-cache`: `.cargo/config.toml` gives its absolute
  path to every cargo command as `KO_ZIG_CACHE`, and the Makefile's
  terminfo rule uses the same directory. The path does not come from
  `OUT_DIR`, because cargo writes `CACHEDIR.TAG` only when it creates
  `target/` itself, and CI's cache restore creates it first.
- **The pane process.** `ko_pane_wire::frame` is the one source of the
  frame's constants for both processes. `ko-pane` holds its program's zombie: it never waits for the
  child before the final group kill, so the pid and the group id
  cannot be reused while it lives. `ko_sys::pty::spawn` forks and
  execs the program itself: between `fork` and `execve` the child
  calls only async-signal-safe functions on memory prepared before
  the fork, and it reports a failed step and its errno through a
  close-on-exec pipe. A setup failure sends an `error` frame that names the
  failing call and its OS error ("openpty: ..."). The frame is
  flushed before the process exits.
- **Fuzz targets.** A target in `fuzz/fuzz_targets/` calls one
  function of a library crate. That crate has a `#[test]` that
  replays the target's corpus `fuzz/corpus/<target>/`, or fixed
  cases if the target has no corpus, through the same function on
  stable. Except for `ko_pane::control`, the entry functions are in a
  module `fuzz` under `cfg(any(test, feature = "fuzz"))`; only
  `fuzz/Cargo.toml` enables the feature, so the shipped binaries do
  not contain the targets or their models. A model in a target never
  reuses the formula of the code under test.
- **Miri.** `scripts/miri.sh` (`make miri`) runs the tests of the
  modules without sockets, FFI or processes: `frame`, the ring,
  `ids`, `protocol` and `http`'s head reader. It selects them by
  name and skips the proptest tests and the 16 MiB frame stream,
  which runs out of memory under Miri in a 6 GiB container. Under `cfg(miri)`, `ko_sys`'s
  `Mapping` is heap memory (`ko_sys/src/mapping/heap.rs`), so the
  ring's writer and reader run on it.
- **Allocation.** The coordinator allocates nothing on the heap for
  each ring record in steady state. `ko-bench` counts the server
  thread's allocations with its global allocator and prints
  `allocations/record`.

## Layout

ko's crates: `ko/` (the binary), `ko_server/` (the coordinator),
`ko_client/` (the client core), `ko_config/` (the configuration
file), `ko_tui/` (the terminal client),
`ko_shell/` (shell priming, `ko ssh` and the bin directory), `ko_pane/`
(the pane process), `ko_pane_wire/` (the frame codec and the ring),
`ko_vt/` and `ko_vt_sys/` (libghostty-vt, built by zig from PATH out
of `third_party/ghostty`), `ko_sys/` (the OS layer), `ko_bench/` and
`fuzz/`. Beside them are `bench/` (the benchmark scripts, streams and
C helpers), `ko_e2e/` (the e2e suite, "The e2e suite" under "Rust")
and `app/` (Kido.app, docs/design-app.md). docs/design-ko.md, "Crates",
maps the coordinator's modules.

    share/ko/           the source of share/ko as installed:
      bin/              the bin directory's sh shims (ko, ssh, ko-pi)
      shim.sh           their shared helper
      bash/, zsh/       the OSC 133 integrations every primed shell sources
      openapi.json, client-model.json, config-schema.json   the generated schemas (make schemas)
    share/pi/           ko-pi.ts, the harness, which the ko-pi shim loads
                        with --extension; its suite ko-pi-*.test.ts on
                        the fake ko of testdata/fake_ko/; ko-api.d.ts,
                        generated from openapi.json; testdata/ko-prompts.txt,
                        the prompt snapshot; skills/ko/SKILL.md, the ko
                        skill that ko-pi offers to pi
    .pi/prompts/        gh-watch.md, /gh-watch: starts scripts/main-watch.sh streamed;
                        release.md, /release: Kido.app first, then ko
    .pi/extensions/     no-git-writes, the spawned agent's bash-tool guard
    .pi/tests/          no-git-writes.test.ts, the guard's suite, which
                        scripts/test-ts.sh runs with the ko-pi suite
    scripts/            verify.sh, scrubbed verification; release.sh, the
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
    third_party/ghostty the Ghostty fork, a git submodule ("One Ghostty")
    website/            the kido.tools site

`make build` builds the installed layout under `build/ko/`: `ko`,
`ko-pane`, `share/ko` and the terminfo, which `ko_vt/terminfo.zig`
writes from ghostty's source and `tic` compiles. It replaces each
binary with a new file, because macOS kills a process whose executable
was overwritten in place after an earlier run (`Killed: 9`). `make
install PREFIX=<prefix>` copies that layout under `<prefix>/bin` and
`<prefix>/share/ko` (default `~/.local`), Homebrew's `pkgshare` layout.

`make build-linux` builds the static Linux ko for each architecture
of `LINUX_ARCHS` (`aarch64`, `x86_64`; by default the host's alone)
into
`build/ko/share/ko/linux/<arch>/`: `bin/ko` and `share/ko` with the
shims, `shim.sh`, the pi extension and the terminfo. It has no
`ko-pane`, because no server runs inside. zig is the C compiler and the
linker, and `ko_vt_sys/build.rs` builds libghostty-vt with
`-Dtarget=<arch>-linux-musl`, so libghostty-vt, zig's static libc++ and
musl link into one static executable; `make check-static` checks it.
`make install` builds and copies the same architectures, so the
Homebrew formula builds the host's alone, and `make verify` and each
CI runner build and check theirs: the two runners cover both.
`LINUX_ARCHS="aarch64 x86_64"` builds both. The aarch64 build lacks
the Cortex-A53 erratum 843419 workaround, because zig's linker
refuses the flag: it is correct on Apple Silicon, not on an affected
Cortex-A53.
`ko version` prints the JSON of `protocol::version()`, with the build id
from `git describe` at build time in `.build`. The Makefile reads the
build id and the ghostty pin of the index once and exports them to every
cargo command as `KO_BUILD_ID` and `KO_VT`; `ko_server/build.rs` runs
no git and tracks only these two variables. A build script must not
track the git index: `git describe --dirty` rewrites it on each make,
which would rebuild `ko_server` and every crate above it.

`make ko-client-xcframework` builds `ko_client` as a static library
for arm64 macOS into `build/ko_client.xcframework`
(`KO_CLIENT_XC` overrides the path), with `ko_client/include/` (the header and the
module map) for Kido.app. It needs `MACOSX_DEPLOYMENT_TARGET` (26.0: Kido.app supports only Apple
Silicon and macOS 26 or later) and the rust target `aarch64-apple-darwin`. It fails when `ko_client` depends on `ko_vt`:
the app links its own libghostty-vt. The slice goes through
`ld -r -exported_symbols_list ko_client/exports.txt`, which makes
every other symbol local, and then `nm` must show exactly the names
of `exports.txt`. The reason: Rust's `compiler_builtins` and Zig's
`compiler_rt` in the app's libghostty define the same symbols, and
the app's link refuses the duplicates. A new exported function goes
into `ko_client.h`, `ffi.rs` and `exports.txt` together.
`make build-bench` builds the C helpers of `bench/` into
`build/bench/`, beside `ko-bench` in `target/release/`; `bench/run.sh`,
`bench/flood.sh` and `bench/rtt.sh` call it through `bench/setup.sh`,
which they source. `bench/client.py` runs
the `ko` that `KO_BIN` names, which measures a reference build
(docs/design-ko.md, "Performance"), else it runs `make build` and
uses `build/ko/bin/ko`.

`scripts/install-zig.sh` pins the zig release and its checksums. CI
and `scripts/ci-like/Dockerfile` install zig through it. A ghostty
bump that changes `.minimum_zig_version` also changes the script.
Every C file of `bench/` starts with `#define _DARWIN_C_SOURCE` and
`#define _GNU_SOURCE`, before its includes: the build uses
`-std=c11`, which hides `clock_gettime` on Linux.

**The harness is one pi extension.** `share/pi/ko-pi.ts` holds every
agent tool. It calls only `ko api`, with `--stream` for its message
stream and a routed pi's exec sessions (docs/design.md, "The pi
extension, ko-pi", lists the routes), and no run command: its
background commands are jobs, child processes of pi
(docs/design-subagents.md, "A job"). It never opens ko's socket.
That command, its flags, exit codes and JSON are the contract between
the two. ko is the mediator: the
extension never reads ko's state directory or another agent's files
and has no state directory of its own; its registry and reports are
custom entries in its own pi session (docs/design-subagents.md, "The
registry: the own pi session"). ko never reads the extension's files. Its knobs are
`KO_*`.

## The server

A server is its state directory (`$KO_STATE_DIR`, else
`$XDG_STATE_HOME/ko`, else `~/.local/state/ko`). Its socket is
`<dir>/socket`. Every command accepts `--server DIR`. Inside a pane,
`$KO_SOCKET` names the pane's own server, `$KO_PANE` the pane and
`$KO_PANE_TOKEN` its secret; every `ko` command but the terminal
client sends the pair as the
`Ko-Pane` and `Ko-Pane-Token` headers to that server only, and a
request without them is the user (docs/protocol.md, section 1). ko has
no caller otherwise: `POST /panes` takes its parent in the body.
docs/design-ko.md, "Lifecycle and the command line", gives the
directory rules, the server's options and every variable that a pane
gets.

**Runtimes** (docs/design-runtimes.md). The rules a change breaks
most easily:

- A connection's `Origin` comes from the listener that accepted it
  and lives with the connection. On a runtime connection every request
  acts as a live pane of that runtime, with its token; the user does
  not exist there, and a route that the runtime gate does not name is
  refused.
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
- The podman kind runs only on Linux: its refusal on another OS
  (`cfg!(target_os = "linux")` in `container.rs`) is the one platform
  branch outside `ko_sys` that is not an OS call.

**Native agent status.** Only OSC 7501 root apps `pi` and
`claude-code` identify agent panes. Three pane variables supply local pi
identity, never detection: `pi.session`, `pi.name` and
`pi.activity`. ko trusts them only while the pane has an OSC 7501 root
with `app=pi`. ssh panes use `ssh.dest` and `ssh.args`, trusted only
while the foreground is `ssh` (docs/design-program-status.md).
A routed pi's `pi.runtime` follows the same rule in the harness and
in the clients, where only `ko_client`'s `Model::place` reads it; the
server does not read it, and nothing reads the generic `ko.runtime`
(docs/design-runtimes.md, "Agents in a runtime" and "Clients").

Claude Code 2.1.295 queries OSC 7501. Then it emits a root
`app=claude-code` record: idle, working, done, or blocked with
permission/question kind and a base64 message. Escape on a permission
dialog emits idle immediately. Exit clears all records.
`CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` also disables this reporting.
Its OSC 0 title is "Claude Code" at startup and "Reply with ok" for
the session. Kido ships no Claude Code shim.

**Panes and the sweep.** docs/design.md, "Who is authoritative for
what" and "Window lifecycle", gives the rules. The ones a change breaks
most easily:

- ko keeps no record of a pane after it goes; the row is the whole
  record. ko has no runs.
- The sweep reads the pane rows, never a process or pi evidence. It
  removes a pane with the default `close: exit` at once when its
  program exits or dies by a signal, focused or not, but keeps a
  start failure (cause `failed`); a `close: on_exit` pane dead for
  the linger grace; and a pane whose immutable `parent` pane is gone
  or dead (the last two not while a focused client shows the pane).
  Every removal (a `DELETE`, the sweep, a stop) takes the pane's
  descendants in the same change; the server owns that cascade. A
  child's pane gets `close: on_exit` and its spawner's pane as
  `parent`, and a pane with a `parent` is alone in its window: the
  server refuses a layout that puts another pane beside it.
- `ko prompt` uses the pane's message stream when it is open, else a
  paste. It mints the message id and resends once with the same id
  only when the connection failed and the candidate's stream was
  open; the server's once-per-id rule makes that safe. A paste has no
  id and is never repeated. Exit
  codes: 0 sent,
  1 empty stdin or an error, 4 no agent in scope, 5 several. Scope is
  the caller's window, widened to the session only when the window
  has no agents; `--window` never widens. The prompt routes take the
  scope pane as `from`; the identity headers are identity only.
- A message (`/panes/{id}/messages`) is enqueued once for each
  `(pane, id)`; a repeat answers from the original. The queue drops
  with its pane, and nothing tells its senders. The server never
  reads a message's kind or text.

**Shell integrations** (`share/ko/bash`, `share/ko/zsh`) blank
control characters in the command line, limit it to 1024 characters,
and encode only `%` as `%25` and `;` as `%3B` in it. Their OSC 7
directory report has its own encoding and carries the shell's real
hostname (docs/design.md, "Priming a local shell").
`share/ko/zsh/integration.zsh`
must not name a local `status`: it is a zsh special parameter, and
shadowing it silently stops the precmd hook. The local is called
`ret`.

## Proved modules

Verus is ko's one specification ("Verus" under "Rust").

**The ring indices are sequentially consistent.** The wakeup
handshake between `head` and `read` is a store-buffering pattern:
each side stores its index, then loads the other's. Under
acquire/release, both loads can read the stale values, and a wakeup is
lost. The proof assumes one interleaving, which only `seq_cst` gives.
The ring's accesses are `SeqCst` ("Atomics" under "Rust"). The loom
models of `ko_pane_wire::ring::model` show it on the Rust code:
`records_reach_the_reader_whole_and_in_order`,
`a_seq_cst_handshake_loses_no_wakeup`, and
`an_acquire_release_handshake_loses_a_wakeup` (`#[should_panic]`).

## Tests

    make verify  the one verification, in this order: a scrubbed make build, make build-linux check-static (build-linux), fmt, clippy and scripts/lint.sh (lint; lint-rs is the stage without lint.sh), ko's cargo tests (unit), ko's e2e (e2e), the TypeScript suite (ts), and make verus
    make verus   cargo verus verify on ko_pane_wire and ko_server with the pinned Verus release, downloaded once into build/verus/
    make build  the installed layout under build/ko/; the default goal
    make build-linux  the static Linux ko under build/ko/share/ko/linux/<arch>/ (LINUX_ARCHS, default the host's); check-static checks it
    make test  ko's cargo tests and the loom models, without the e2e suite
    make e2e E2E=name  the e2e suite against build/ko/bin/ko
    make cargo ARGS='test -p ko_server'  one cargo command, with --locked added after the subcommand, for iterating on one package
    make fmt     cargo fmt on the workspace
    make lint    cargo fmt --check, clippy and scripts/lint.sh
    make build-fake-ko  the fake ko of the TypeScript suite
    make bindgen  regenerate ko_vt_sys/src/bindings.rs
    make probe BYTES=N  ko-bench throughput: the server's ring reader under ko-pane, N bytes of bench/streams (default 1 GiB); not part of verify
    make build-bench  the C helpers of bench/ in build/bench/, after build
    make prompts regenerate the prompt fixture through scripts/lint.sh --update-prompts
    make schemas regenerate share/ko/openapi.json, share/ko/client-model.json, share/ko/config-schema.json and share/pi/ko-api.d.ts through scripts/lint.sh --update-schemas
    make api-docs  one static HTML page of share/ko/openapi.json (Redocly) in build/ko-api.html; not part of verify
    make fuzz TARGET=ring TIME=600  one time-boxed fuzz run, for CI or the user; no TARGET lists the targets
    make miri    Miri on ko's modules without sockets or FFI (scripts/miri.sh); for CI or the user
    make install binary to $PREFIX/bin (default ~/.local), shared files to $PREFIX/share/ko
    make ci-like ARGS=...  a CPU/memory-capped Linux container ("Reproducing a CI-only failure")
    make preview-pi  replace the installed share/ko/pi/ko-pi.ts with the checkout's; unpreview-pi restores it
    make website the website's dev server at http://localhost:4321 (website/README.md)

`make verify STAGES=e2e` selects stages. `E2E=client_` limits
the e2e stage to the tests whose names contain the text (a cargo test
filter). Every selected stage runs even after a failure and prints
PASS/FAIL/SKIP with its time. `scripts/verify.sh` scrubs the
environment: it unsets `KO_STATE_DIR`, `KO_PANE`, `KO_SOCKET`,
`KO_PANE_TOKEN` and every `KO_AGENT_*`, and removes installed
`share/ko/bin` entries from PATH, so the developer's own pane does not
enter the tests. The lint and ts stages need Node 24 or newer;
`KO_TS_TEST_REQUIRED=1`, which verify sets itself, makes a missing node
a failure. Before a release, validation uses `make verify` in full.
Kido.app has its own checks in `app/` (`make test`, `make visual`,
`make stress`; docs/design-app.md, "Testing").

**Which verification.** `make verify` is the one command for ko,
`share/` and `scripts/`. A change that touches `app/` or the shared
`third_party/ghostty` pin also runs the app's `make test` in `app/`,
plus `make visual` for a visible change. Agents run `make fuzz` only
when the user asks. Long fuzz runs occur only in CI and never in
verify.

CI (`.github/workflows/ci.yml`) runs on Ubuntu and macOS on every
push and PR: one `make verify` with the default stages, under
`KO_VERUS_REQUIRED=1`, `KO_E2E_HOST_SSH=1` and `E2E_THREADS=16`, then the installed
layout check (`make install PREFIX=$HOME/ko-install`, `ko version`
from it, and the `ko` shim executable under its `share/ko/bin`).
It does not build Kido.app
(docs/known-issues-app.md, "App checks do not run in CI").
`scripts/main-watch.sh` watches main and reports each observed head's
CI. `/gh-watch` starts it through streamed `async_bash`.

**Test speed.** Tests stay very fast, because fast tests give fast
iterations. `make verify` prints the time of each stage on its
PASS/FAIL line. A change that makes a stage slower needs a reason.

- Wait for the event, not for a time. A test that only waits longer
  than necessary is a defect. `scripts/lint.sh` permits a sleep in
  `ko_e2e/` only through its table of exact statements.
- An absence check waits for the harness's quiet window. Do not add
  one where a positive assertion shows the same fact.
- Shorten a product timer through the server's environment
  ("Knobs" in docs/design.md) or, for the linger and the runtime
  idle, through the `server:` key of the server's configuration file. The e2e suite runs all
  its tests at once (`E2E_THREADS`), so each server start costs the whole suite:
  put cases that need the same setup in one test, on one server.
- Test pure logic in a unit test, not through a server.
- In the TypeScript suite, the fake `ko` is the Rust binary
  `share/pi/testdata/fake_ko`. A Node process start costs about
  70 ms. A fake delay is a `KO_FAKE_*` gate that the test releases,
  not a delay that the test waits out. A test that reads only the
  registered tools needs no fixture.
- A test earns its time. Do not keep a test that repeats another test,
  the prompt snapshot or the compiler. Do not keep a test that only
  repeats a constant or a one-line function.

**Prefer e2e tests.** Use `ko_e2e/` to test behaviour that a user or
agent can observe through the binary: a subcommand's output, exit
code, and effects on the server or its state. Unit tests check pure
logic that e2e cannot reach or test precisely: parsers, formats and
ordering. Do not write a unit test that execs the binary.

**Reproducing a CI-only failure:** `scripts/ci-like.sh` runs a Linux
container with the repo bind-mounted and CPU/memory capped
(`make ci-like ARGS="--cpus 0.25 -- make cargo ARGS='test -p ko_e2e
NAME'"`). A CPU quota alone rarely reproduces timing failures.
`--contend N` starts N busy sibling containers; with a low
`--cpu-shares`, this makes a wrapper's timer run out of step with its
command as a loaded runner does. The siblings equally share `--budget`
(default 2) minus the run's `--cpus`. Use contention for one named
failure, not a whole suite. Never saturate the host's cores: other
agents work in parallel. The image (`scripts/ci-like/Dockerfile`, on
`debian:trixie`) holds rustup at a pinned release with its checksums,
the toolchain of `rust-toolchain.toml`, zig through
`scripts/install-zig.sh` and `strace`; its tag is `ko-ci-like:` and
12 hex digits of a digest over the Dockerfile, `install-zig.sh` and
`rust-toolchain.toml`, so a change of one rebuilds it. `target/` and
`build/` are the named volumes `ko-ci-like-target` and
`ko-ci-like-build` over the bind mount, so a Linux build never
overwrites the host's macOS outputs. The container (`ko-ci-like-<pid>`;
its busy siblings `ko-ci-like-busy-<pid>-N`) gets
`KO_STATE_DIR=/tmp/ko-state`, and the host's other `KO_*` variables
pass through, except `KO_AGENT_*`, `KO_PANE`, `KO_PANE_TOKEN` and
`KO_SOCKET`. In a linked worktree, the script
also mounts the main repository's git directory read-only, because
the Makefile runs git. Linux's check is `make ci-like
ARGS="--cpus 2 --memory 6g -- make verify"`; the Rust and zig builds
need more than the default 1g. The container's `/dev/shm` is 1g
(`--shm-size`): the e2e test of a 100 MiB kitty `t=s` image needs
more than podman's default 64 MB. On Linux, `Named::create` reserves
an object's pages with `posix_fallocate`, so a full shm tmpfs is
`ENOSPC` at creation, not a SIGBUS at the first write. The Linux run
does not cover the host-sshd tests (the image has no sshd); CI's
Ubuntu job does. The podman machine on Apple silicon
runs aarch64 Linux; CI's Ubuntu runner is x86_64. For a worktree under
`/tmp`, run the script from its `/private/tmp` path: podman cannot
mount the `/tmp` alias.

**Fuzzing.** ko has no VT-parser target: Ghostty fuzzes libghostty-vt
upstream. `scripts/fuzz.sh` names the targets, all cargo-fuzz targets
in `fuzz/fuzz_targets/`, each with a dictionary in
`fuzz/<target>.dict` and its `max_len` in `fuzz/<target>.options`:

- `frame` and `control`: `ko-pane`'s frame sizes and its control
  dispatch in process (`ko_pane::control`). The first byte of a
  `control` input selects the mode.
- `ring`: an operation list on the real ring writer and reader,
  compared after every operation with a pure model of the ring and of
  `ko-pane`'s room rule (`ko_pane_wire::fuzz`).
- `loop`: `ko_sys::event` over socketpairs and a pipe with interest
  changes, sends, full buffers, peer closes, timers and signals,
  compared with a model (`ko_sys::fuzz`). It simulates a signal
  through the handler body and sends no signal.
- `head`, `http`, `decode` and `frames` (`ko_server::fuzz`): the
  head reader over the bytes cut at the chosen points; one connection
  of an in-process server fed the bytes; each request decoder, whose
  value must encode and decode to itself; `pane_proc`'s frame reader,
  fed whole and in two parts, with the same effects. `http` makes its
  server once for each process and a fresh socketpair for each input.
  Its first pane runs `cat` under the real `ko-pane`. Every later
  pane starts `/usr/bin/true` in place of `ko-pane`, so a fuzzed
  request never runs its command. It needs `ko-pane` in
  `KO_PANE_EXE`, which the script builds.
- `client` and `ws` (`ko_server::fuzz`): the client's response and
  upgrade readers over the bytes, whole and cut at the chosen points,
  with the same result; a server-side WebSocket over a connection fed
  the bytes as client frames, whole and in two parts, with the same
  messages and close, and no message over 1 MiB.
- `ko_e2e`'s `hostile.rs` is the only part outside cargo-fuzz:
  hostile input against a real `ko server`, with other clients
  unaffected.

`cargo test` replays every corpus in `fuzz/corpus/<target>/` in a
fraction of a second for each target. `make fuzz` builds the target with debug
assertions (`cargo fuzz build -a`, so the contract checks run) and
fuzzes for TIME seconds. Each run has its own process group and
scratch directory, and the script kills and removes both on every
exit. A finding is in `target/fuzz-artifacts/`.
A libFuzzer run restarts every 24000 inputs, because ASan on macOS
keeps libghostty-vt's freed memory, about 100 KiB per input.
A bug that a fuzzer finds gets a regression test with that case:
the explicit input or operation list, not a seed.
The corpora are files named by SHA-1. Only `make fuzz MERGE=1`
(`scripts/fuzz.sh --merge`) changes one, with a `-merge=1` into a
minimal set, and only with a code change that needs the new inputs.
The exception is a format migration in the same change as the code:
a one-off script converts each input to the new form, names it by
its SHA-1 and drops the inputs that become identical.
The scheduled workflow `.github/workflows/ko-nightly.yml` runs each
target for 600 s in its own job, and `make miri`, and uploads a
finding. It never changes a corpus.

The view harness (`ko_server/src/harness.rs`, a test module) drives
the real `State` and a real `ko-pane` through views with fast, slow
and stalled readers, resizes, resyncs, resumes, closes, EOF and a
crash. It compares every view's mirror, and a fresh snapshot, with
the pane's terminal. It runs 20 random cases under `cargo test`;
`PROPTEST_CASES` scales them.
A test that pins a libghostty-vt bug fails when the bug is fixed, so
the workaround for it can be removed.

Only `fuzz/` reads `KO_FUZZ_*` (`scripts/lint.sh` refuses it in the
other crates), and `ko_e2e`'s `defaults_and_pane_environment` runs
`ko version` with fuzz variables set to junk.

Many tests have a comment that identifies their check or their
important assertion. Before you weaken or simplify such a test, read
its comment.

## Review

A reviewer checks the change against "Code rules", "Rust" and
"Tests" above. Read each rule and look for its fault in the diff: a
rule alone does not find a fault.

**Simplify reviewers** use the `simplify` skill
(`~/.pi/agent/skills/simplify/SKILL.md`). Each reviewer takes one
angle of its Phase 1: reuse, simplification, efficiency or altitude.
A reviewer does only Phase 1 and reports its findings. It does not
apply them: the manager decides which to apply, and the implementer
applies them.

**The correctness reviewer** looks for bugs, not style:

- It traces each user action and each input end to end, with real
  event sequences: keys, mouse, resize, attach, detach and reconnect.
- It checks each conversion of coordinates and units: cells and pixels,
  bytes and lines, offsets, seconds and nanoseconds, 0-based and 1-based.
- It checks that each test can fail. A test must not copy the
  production formula, and a fake must not accept every input.
- It compares each use of a protocol with its contract:
  docs/protocol.md, the header of a C API, `share/ko/openapi.json`.

**The modules reviewer** checks each crate and module that the change
touches:

- An item is `pub` only when another crate uses it, and `pub(crate)`
  only when another module uses it ("Visibility is the interface").
- The module is self-contained and consistent. If it exports a type,
  it also exports the functions that construct and use values of that
  type. A module that is only a set of types is the exception.
- The module has one purpose. A second purpose needs a clear reason.

A reviewer reports each finding with the file and line, the fault,
and a fix. It does not edit files.

## Working here as a spawned agent

These rules apply to every agent in this repo: the top-level session,
the manager of a unit of work, and the implementers, investigators
and reviewers that a manager spawns. A brief names your role and does
not repeat these rules. Your role limits what you do: an implementer,
an investigator or a reviewer does its task itself, spawns no
subagents and makes no git writes. A reviewer is read-only. A manager
delegates as its brief says and does not write code.

- **The top-level session orchestrates.** It plans the work and gives
  each unit of work to one manager. It creates the unit's worktree. It
  is the one integrator: only it commits, merges and pushes, and only
  it moves a submodule pin. It never runs test suites, builds or other
  long blocking commands itself, so it stays free to answer the user.
  When verification is missing after a demo or a late edit, it sends
  the work back to the manager. A verified unit that rebases onto
  `main` without conflicts is pushed at once, and CI checks the
  combination; only a rebase whose conflicts the session resolved
  goes back to the manager for a check. The session confirms the
  commit on `origin/main` before it stops the unit's agents and
  removes the worktree, each a separate step, never in parallel with
  the commit. macOS is the platform that counts: a
  failure that occurs only on Linux CI gets no unit unless the user
  asks, and a brief asks for no Linux checks.
- **Models.** Name a model by its fully qualified name, in every
  `spawn_agent` call, also a resume or a fork: without `model`, the
  agent takes the caller's model.
  - A manager runs on `claude-bridge/claude-opus-5-5`.
  - An implementer, a builder, and investigation or reproduction work
    run on `openai-codex/gpt-6.1-sol:low`.
  - A simplify reviewer runs on `claude-bridge/claude-opus-5-5` or
    `openai-codex/gpt-6-astra`, mixed across the four. The correctness
    reviewer runs on `openai-codex/gpt-6-astra`. The modules reviewer
    runs on `claude-bridge/claude-opus-5-5`.
  - The planner of a unit runs on `openai-codex/gpt-6-astra`.
  - Design work (a plan in `plans/`, a design in `docs/`) runs on
    `claude-bridge/claude-fable-5-1`, never on Sol. Fable also takes
    a complex task or review when the user asks for it.
- **Size the process to what the change is for,** not to its line
  count. Local tooling (the pi extensions in `.pi/`, a script that only
  agents use, a brief, a plan or other prose) gets one agent, a quick
  check such as `scripts/lint.sh`, and no tests, reviewers or full
  verification. A small product change (one behaviour, a few files)
  takes the small track: no planner, one implementer and one
  correctness reviewer, and the manager says that it chose it.
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
     read-only planner. The planner reads the code path end to end and
     reports one design: the rule for each part, the existing
     abstractions that the change extends or replaces ("A feature fits
     the model"), each place that dispatches on them, what to delete,
     and the tests that must fail first. It names each place to change
     as file and line, with the shape of the new code (the types, the
     signatures, the match arms), so the implementer does not explore
     the code again. The manager checks the design
     against the code. Then it spawns one implementer with the design.
     For a big feature, the planner stays alive while the implementer
     works, and the brief names it as the implementer's advisor: the
     implementer asks it with `message_agent` when the code does not
     fit the design. The planner stays read-only, answers only, and
     reports a change of the design to the manager. The manager stops
     it with the implementer.
     A trivial change goes to the implementer directly.
  2. When the change builds and its new tests pass, the implementer
     reports, before any full verification. The manager writes the
     docs that the change needs itself, in `docs/`, this file and
     READMEs. The implementer reports the facts that the docs need and
     never writes them, so a smart model writes every doc.
  3. The manager spawns the four read-only reviewers of a simplify pass,
     one angle each, one correctness reviewer and one modules
     reviewer, so that review has fresh context. They review the code
     and the docs ("Review" above). Review does not wait for the full
     verification: that runs once, after the findings are applied.
  4. The manager merges their findings and decides which to apply. It
     changes the docs that the findings affect.
  5. It gives the findings to apply to the same implementer with
     `message_agent`. The implementer keeps its context. The
     implementer's final verification runs after the last docs edit,
     because `scripts/lint.sh` checks the references in the docs.
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
  visual snapshot tests for every state of the mockup. Tests that only
  read state or frames are not sufficient. The manager reads each
  recorded snapshot, compares it with the screenshots of the mockup's
  states and sends every difference to the implementer. The work is
  not complete until the snapshots agree with the mockup.
- **Demos.** The user closes a demo that exits. Never start it again
  on your own, attached or detached. A crash is a new crash report for
  the demo's pid in `~/Library/Logs/DiagnosticReports` or a crash or
  panic in the lines of the demo's pid in `~/Library/Logs/Kido/app.log`
  (docs/design-app.md, "The log"). Report a crash. Start a demo again
  only when asked.
- **No git writes.** Do not commit, push, reset, add, checkout or stash.
  Leave work uncommitted. Never use `git stash`. If
  `KO_AGENT_PARENT_SESSION` is set, `.pi/extensions/no-git-writes`
  guards bash tool calls.
- **Other agents' uncommitted changes are expected.** Work runs in
  parallel. The brief identifies your files. Do not revert, clean or
  fix anything outside those files. Report it instead.
- **You are inside the user's live ko server.**
  Every command runs against the pane's own server unless `--server`
  names another. `ko kill-server` without `--server DIR` and your own
  scratch directory kills the user's server. Start every test server
  on its own state directory under `/tmp`. Never touch the running
  demo or the user's servers.
- **Worktrees.** Each unit works in its own worktree
  `~/Workspace/kido-<unit>`, which the top-level session creates with
  `git worktree add --detach ~/Workspace/kido-<unit> <base>`. For a
  unit that does not change Ghostty, it clones the main checkout's
  built GhosttyKit for the worktree's pin
  (`cp -Rc app/build/ghosttykit/<pin>-*` into the worktree's
  `app/build/ghosttykit/`): the directory's name is the pin, the
  submodule's diff and the flags, so a match is the same build. A unit
  that runs app targets first runs `make build` under
  `scripts/quiet-limit 600`, because the app's ko phase hides the
  build's output and a cold build there trips a 60 s limit. Agents
  start in that worktree and stay there. The top-level session merges
  the result, pushes, and removes the worktree only after every agent
  that ran in it has stopped. `.pi/extensions/no-git-writes/policy.ts`
  permits `git worktree add --detach` only to an absolute path there
  or under `/tmp`. The submodule makes `git worktree remove` refuse.
  Remove the worktree directory with `rm -rf`. Then use `git worktree
  prune`.
- **Every wait has a deadline.**
  Do not poll without a deadline in code or your shell.
  macOS has no `timeout` command.
  Give the wait its deadline another way: a build or test run that
  can take more than 10 seconds runs through `async_bash` under
  `scripts/quiet-limit 60 -- <command>`, which kills the command's
  process group and exits 124 when the command prints nothing for
  60 seconds, so a stuck test or a deadlock ends instead of hanging
  the agent. The one exception is the cold GhosttyKit build,
  `app/scripts/build-ghosttykit.sh`, which prints nothing for about a
  minute, so it runs under `scripts/quiet-limit 600`.
- **Do not block on `sleep`.**
  While a background run works, end your turn.
  Continue when its notice arrives.
- **No signal to a pid from untrusted input.**
  No code, test, fuzzer or script gives a pid from fuzzed, synthetic
  or untrusted input to a signal call. A signal goes only through the
  one signal module of its language ("Signals" under "Rust").
  Its types refuse such pids. A test checks the validation. It never
  sends a signal to prove it. When you change a fuzz target or a kill
  path, use grep to examine the kill paths.
- **Verify what you touched; CI runs the whole.**
  If a bug's cause is not clear from the code, write the test first.
  This includes a race, a flake, or an incorrect assumption about
  libghostty-vt, pi or Claude Code.
  Watch the test fail.
  Quote that failure.
  A simple fix or a feature needs tests that only pass.

  Test in proportion to the change.
  For a trivial change, update the expected strings that it breaks.
  Do not add new tests for it.
  Trivial changes include a character of spacing or a word of text.

  Make sure that each test checks the intended behaviour. Assert the
  specific effect of the change, not a fact that is also true without
  it. For timing, races, deduplication or polling, assert the result
  that a defect would change. Do not break the code to prove that a
  test can fail.

  Batch the work and verify once at the end. Make all edits without
  intermediate suite runs: no repeated `make test`, `make verify` or
  the app's `make visual-fast` while you iterate. Run only the
  specific tests that you add or change. After the last edit, and
  after the review findings are applied and the last docs edit, run
  the verification once ("Which verification" under "Tests": `make
  verify` for ko, `share/` and `scripts/`; the app's `make test`, plus
  `make visual` for a visible change, for `app/` or the Ghostty pin).
  It controls environment scrubbing. Use `E2E=name` to limit the e2e
  stage to the changed behaviour. Do not also run the top-level `make
  test` or `make e2e`. Report PASS/FAIL/SKIP as printed. An unrelated
  failure gets one run of that test alone, not a suite rerun. If a
  failure is in a file you do not own, report it. Do not fix it.
- **A flake has a time box of 5 minutes.** When a test fails only
  sometimes, run one bounded loop to reproduce it, such as a shell
  loop of `make cargo ARGS='test -p ko_e2e NAME'` with a fixed count,
  one run after another, and stop at the first failure. Quote it.
  Never run a load loop that saturates the CPU: other agents work on
  the same machine. First suspect the test: a race in its waits, a
  read that discards what it waits for later, a wall-clock bound. A
  flaky test is rewritten to wait for the event, or dropped if it
  repeats another test. When the cause is a class of fault, such as
  an inherited descriptor, fix the class once, not each test. When
  the 5 minutes end without a cause, report the failure, the loop
  counts and the best hypothesis, and stop. The manager or the user
  decides on more work. A fuzz run or a long property-test run that
  an agent starts has the same time box of 5 minutes.
- **Your last message is your report. Keep it under 4000 characters**.
  Start with what you built and the pre-fix failures.

## Releasing

ko and Kido.app ship from `main`. Kido deliberately has **no release
version and no tags** for ko. Versioning uses the `ko` formula in
`andreypopp/homebrew-tap`: a git `revision:` with a manually
increased `version`. The formula builds ko from source with the
pinned toolchains (the rustup toolchain of `rust-toolchain.toml` and
the zig of `scripts/install-zig.sh`), through `make install`.

`/release` (`.pi/prompts/release.md`) is the whole sequence for an
agent: Kido.app first when the schemas or the Ghostty pin changed,
then ko.

After the change is on `main`, run `scripts/release.sh VERSION`
(or `make release VERSION=x.y.z`). Use `--dry-run` to inspect its
actions. It requires HEAD equal to origin/main and green CI for it.
It compares the command and tool lists with the tap's current
revision: the old names come from `$(brew --prefix ko)/bin/ko --help`
and `share/pi/testdata/ko-prompts.txt` at the old revision, the new
from the checkout, with no worktrees; it checks that the installed
`ko version` build is a prefix of the formula's revision. Removals or
renames require a minor bump. Panes must restart, not /reload. The
variables `KO_RELEASE_TAP`, `KO_RELEASE_SSH_TAP` and `KO_RELEASE_OLD_KO`
override its inputs for a dry run.

The script edits and commits the brew tap formula. It fast-forwards
`~/Workspace/homebrew-tap`. It pushes from that SSH checkout. It
never runs `brew upgrade`.

Only `kido-app/N.N.N` tags mark Kido.app releases.
`app/scripts/release.sh` builds them from `main`. They are published
as `Casks/kido-app.rb` in `andreypopp/homebrew-tap`. The app bundles
its own `ko` (`app/scripts/bundle-ko.py`), so the user's agents run
the `ko-pi` that Kido.app bundles, because the app's shim is first on
PATH: a harness change reaches them only through a Kido.app release.

`brew audit`/`brew style` vendor gems into the Homebrew checkout itself.
This can leave the checkout dirty.

`make preview-pi` atomically replaces the installed pi extension and
backs up the original once; `make unpreview-pi` restores it.
Afterward, run `/reload` in the panes. `KO_PREVIEW_PREFIX` selects a
prefix other than `brew --prefix ko`.

## Commit style

Use one imperative sentence, usually with no prefix and no trailing period.
The body explains *why*, in hard-wrapped prose.
For a subtle change, it also explains why the test has that design.
Use recent history as the reference:

    Send a prompt as a paste, so its newlines survive
    Quitting an editor no longer flashes the row green
    A program that has taken the terminal is not a running job
    One status vocabulary for agents and shells
