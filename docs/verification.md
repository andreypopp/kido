# Verifying Kido

This file describes the checks of ko: `make verify` and its stages,
the e2e suite and its harness, the loom models, the Verus proofs, the
fuzz targets, Miri, the view harness, CI and the Linux reproduction.
AGENTS.md, "Tests", holds the rules: which verification a unit runs,
test speed and the preference for e2e tests. [build.md](build.md)
describes the build. Kido.app's checks are in design-app.md,
"Testing".

## make verify

`make verify` runs, in this order: a scrubbed `make build`, `make
build-linux check-static` (build-linux), fmt, clippy and
`scripts/lint.sh` (lint; lint-rs is the stage without lint.sh), ko's
cargo tests (unit), ko's e2e (e2e), the TypeScript suite (ts), and
`make verus`. `STAGES=` selects stages, and `E2E=client_` limits the
e2e stage to the tests whose names contain the text (a cargo test
filter). The stages `lint-sh` (`scripts/lint.sh` only), `app` (the
app's `make test`), `ko-test` and `visual` (the app's `make visual`,
which runs in the guest VM of docs/build.md, "The visual-test VM",
limited by `VISUAL_ONLY`) are not in the default list;
`scripts/checks.sh` selects them. Every selected stage runs even after
a failure and prints PASS/FAIL/SKIP with its time.

`scripts/verify.sh` scrubs the environment: it unsets `KO_STATE_DIR`,
`KO_PANE`, `KO_SOCKET`, `KO_PANE_TOKEN` and every `KO_AGENT_*`, and
removes installed `share/ko/bin` entries from PATH, so the developer's
own pane does not enter the tests. The build, lint and ts stages need
Node 24 or newer; `KO_TS_TEST_REQUIRED=1`, which verify sets itself,
makes a missing node a failure.

`scripts/checks.sh` (`make checks`; `DRY=1` prints only the plan,
`BASE=ref` sets the base) reads the paths that the unit changed (`git
diff --name-only` against the merge-base with the upstream branch or
`origin/main`, and the untracked files), finds the checks of each
path in the one table of the script, prints the plan and runs the
checks through `scripts/verify.sh`. A path that the table does not
name selects every check.

koa's stress runs are manual and never in verify:
`share/koa/stress/run.sh` (headless Chrome) and `make -C app
koa-stress` (off-screen Kido); no window shows on the screen.

## CI

CI (`.github/workflows/ci.yml`) runs on Ubuntu and macOS on every
push and PR: one `make verify` with the default stages, under
`KO_VERUS_REQUIRED=1`, `KO_E2E_HOST_SSH=1` and `E2E_THREADS=16`, then
the installed layout check (`make install PREFIX=$HOME/ko-install`,
`ko version` from it, and the `ko` shim executable under its
`share/ko/bin`). Its `app` job builds Kido.app and runs the app's
`make test` and `make ko-test` (design-app.md, "Testing"), not `make
visual` (known-issues-app.md, "Visual tests do not run in CI"). Visual
snapshots are recorded and checked only in the guest, never on the host:
the host's macOS build is not the reference.
`scripts/main-watch.sh` watches main and reports each observed head's
CI. `/gh-watch` starts it through streamed `async_bash`.

The scheduled workflow `.github/workflows/ko-nightly.yml` runs each
fuzz target for 600 s in its own job, and `make miri`, and uploads a
finding. It never changes a corpus.

## Unit tests

Tests are `#[cfg(test)] mod tests` at the bottom of the file under
test. A test starts a process only through `ko_sys::spawn::program`,
which closes every descriptor but its targets and stderr in the
child: `POSIX_SPAWN_CLOEXEC_DEFAULT` on macOS,
`posix_spawn_file_actions_addclosefrom_np` above the targets on
Linux. On macOS, `UnixStream::pair` and `accept` set close-on-exec
only after they create the descriptor, so a `std::process::Command` in
another test thread can inherit it and keep a peer open. A test that
closes a peer waits, with a deadline, until the other end sees the
hangup: a `posix_spawn` in another thread holds every descriptor
until its child execs.

`ko_pane/tests/pane.rs` drives the `ko-pane` binary over a socketpair
and a ring. The `Server` SIGTERM test starts the `ko-pane` that `make
test` builds and names in `KO_PANE_EXE`.

**The view harness** (`ko_server/src/harness.rs`, a test module)
drives the real `State` and a real `ko-pane` through views with fast,
slow and stalled readers, resizes, resyncs, resumes, closes, EOF and a
crash. It compares every view's mirror, and a fresh snapshot, with
the pane's terminal. It runs 20 random cases under `cargo test`;
`PROPTEST_CASES` scales them.

## The e2e suite

The e2e suite is `ko_e2e/`: one integration-test binary,
`ko_e2e/tests/e2e/main.rs`, with one module for each area, because
cargo runs test binaries one after another and the tests of one
binary in parallel. It is a workspace member outside
`default-members`, so `make test` does not run it. The suite drives
`build/ko/bin/ko`, which `make e2e` builds first; a test never runs
make or cargo.

Its second binary, `ko-fake` (`ko_e2e/fake/main.rs`), is the fake
program of the status and ssh tests: a test copies it under the name
it stands for (`ssh`, `ko-probe`), because macOS reports a `#!`
script's interpreter as its process name. A pane that runs `stty raw
-echo; exec cat` echoes the OSC 133 and OSC 7501 bytes that a test
sends as `text` input, so no fake agent exists. It also echoes the
terminal's kitty graphics reply (`ESC _ G i=N;OK`) back as a new
command that replaces image N, so a test sends graphics with `q=2`.

**Tests that need a host.** The ssh tests that use the host's sshd
run only with `KO_E2E_HOST_SSH=1`: sshd starts the real user's shell,
which reads that user's dotfiles whatever `HOME` the test sets; with
the variable set, a failed ssh probe or a missing zsh is a failure,
not a skip. The remote tests (`remote.rs`) and the ssh runtime tests
(`runtime_ssh.rs`) run under the same variable, with a private `sshd`
(`sshd.rs`: its own config, and host and client keys made once for
each process), so a test can refuse forwarding, lower `MaxSessions`
or need a key passphrase, and an `ssh` wrapper on the client's PATH
that adds `-F`. They never read the user's `~/.ssh`. CI sets the
variable on both runners; its step "Set up localhost SSH" starts sshd
and authorizes a key for localhost.

The container test (`container.rs`) runs only with
`KO_E2E_CONTAINER=1`, on a Mac where Apple's `container system
status` succeeds and the image `debian:trixie` is present: it runs
the aarch64 static ko of `build/ko/share/ko/linux/aarch64` in a
container and compares its `ko version` with the host's, and it
drives a `container` runtime through one server
(design-runtimes.md, "The container kind"). Its runtime name carries
the test's pid, so the container `ko-<name>` is its own, and a drop
guard deletes that container on every exit; it never touches another
container and pulls no image. It needs `make build-linux` first; with
the variable set, a missing layout or `container` CLI is a failure.
CI does not set it. The podman test (also in `container.rs`) runs
only with `KO_E2E_PODMAN=1`, on a Linux host with podman and the
image `docker.io/library/debian:trixie`: it drives a `podman` runtime
through one server with the host's static ko, under the same naming,
drop-guard and no-pull rules as the container test; with the variable
set, a missing `podman`, image or layout is a failure. CI sets it on
the Ubuntu runner only, after a pull of the image.

**How a test reads.** A test reads like command-line use: a step that
a `ko` command can do (`ko api`, `ko kill-server`, `ko version`) runs
that command through `Server::ko`, or `run_ko` without a started
server or with its own environment, and asserts its stdout, stderr
and exit code, with the request path written out at the call site.
Raw requests, written as literal bytes and parsed with httparse, stay
only for HTTP framing, exact statuses, hostile input and polling
loops. WebSocket views and clients use tungstenite's client role; the
hostile tests send raw frame bytes. The outer terminal's steps name
keys and text (`prefix("s")`, `line("echo abc")`, `contains`,
`gone`). Snapshots decode in the test process through
`ko_vt::Terminal::decode`.

**The outer terminal** (`outer.rs`) is a client test: an interactive
`/bin/sh` on a pty from `ko_sys::pty::spawn`, with job control off
(`set +m`; with it, bash 3.2's `setpgid` for the attach child can fail
with `EPERM`, and the client's tty read fails with `EIO`), and a
`ko_vt::Terminal` that gets every byte from the master and writes its
replies back, so the client's queries get a real terminal's answers.
An outer terminal without extended keys drops the kitty keyboard
query (`CSI ? u`) before the terminal sees it. The screen, the cursor
and the modes that the tests read change only outside synchronized
output (mode 2026), as a real terminal paints.

**Environment and state.** Each child gets an explicit environment
through `spawn::program`'s `Env::Only`, scrubbed as
`harness::test_env` does, with a private `HOME` and XDG directories;
the test process never sets its own environment. A server's private
`HOME` is its state directory, which `harness::start_with` gives an
empty `.zshrc`: without it, Debian's zsh-newuser-install menu blocks
a login zsh. State directories are under `/tmp`, for the 104-byte
socket path limit.

**Waits.** Every wait reads a socket or polls a condition with a
deadline of 5 s. `scripts/lint.sh` refuses `thread::sleep` and
`thread::park_timeout` in `ko_e2e/` except through its table of exact
statements; `harness.rs` holds the poll tick. The cargo feature `e2e`
of `ko_sys` holds the OS calls that only the suite needs
(`signal_descendant`, `Pid::parent`, `Pid::has_ended`,
`Pid::wait_exit`, `Signal::Stop`, `Signal::Cont`,
`fd::wait_readable`, `fd::wait_writable_within`), and only `ko_e2e`
enables it. A `Child` of the harness reaps its process under the lock
that its signals take, after a wait that keeps the zombie, so no
signal reaches a reaped pid.

**Threads.** `make e2e` runs the tests with
`--test-threads=$(E2E_THREADS)`. The default is 64, so on a
developer's Mac every test starts at once. CI sets 16: its runners
have 3 (macOS) and 4 (Ubuntu) cores, and at 64 the CPU work of all
tests at once exceeds the 5 s deadlines. A lower count does not fix a
test that fails at 64: that test has a race or does too much work.

`ko_e2e`'s `hostile.rs` is the only hostile-input check outside
cargo-fuzz: hostile input against a real `ko server`, with other
clients unaffected. Its `defaults_and_pane_environment` runs `ko
version` with fuzz variables set to junk.

## loom

`ko_pane_wire::ring::model` checks the ring's records and the wakeup
handshake on the real `Reader` and `Writer` under `--cfg loom`
(AGENTS.md, "Proved modules"). `make test` runs them in
`target/loom`. loom does not model a `SeqCst` access as sequentially
consistent, so the model puts a `fence(SeqCst)` beside each one (its
comment has the issue). The acquire/release twin of the wakeup model
is `#[should_panic]`. The models show the handshake on the Rust code:
`records_reach_the_reader_whole_and_in_order`,
`a_seq_cst_handshake_loses_no_wakeup`, and
`an_acquire_release_handshake_loses_a_wakeup` (`#[should_panic]`).

## Verus

`ko_pane_wire::ring`, `ko_pane_wire::frame::Req`,
`ko_server::delivery`, `ko_server::view` and `conn.rs`'s `Batch` are
verified with Verus (`make verus`, `scripts/verus.sh`, the pinned
release archive in `build/verus/<release>/`). A verified crate has
`[package.metadata.verus] verify = true` and builds with plain cargo,
because `verus!` erases the ghost code. Specs and proofs are in
`verus!{}` beside the code: `ring/spec.rs` (the log),
`ring/machine.rs` (the state machine and its invariant),
`ring/mark.rs` (the reader's log marks) and `ring/backend.rs` (the
trusted base). `cfg(verus_only)` guards only `use` statements.
`vstd` and `verus_state_machines_macros` are pinned with `=` to the
crates version of `scripts/verus.sh` (`scripts/lint.sh` compares
them). Inside `verus!`, Verus also proves that each index is in
bounds and that no arithmetic overflows.

**The trusted base.** `#[verifier::external_body]` and
`external_fn_specification` occur only in `ring/backend.rs`,
`delivery.rs`, `view.rs` and `conn.rs`. In `ring/backend.rs`: the
constructor of each role (`Backend::mint_reader`,
`Backend::mint_writer`), the mapping's creation (`create_handle`,
with no `ensures`), the capacity getter, the header word load and
store, the byte accessors, the pty read into the writer's bytes
(`Backend::read`, read(2)'s contract) and the opaque types that they
use. A record publishes only over payload bytes that were written. In
`delivery.rs`: the sink call (`hand_over`, with no contract), the
stamp counter's constructor (`mint_stamps`, one for each process,
with the opaque token `Bound` of the stamps that it handed out),
`bind_fresh`, which ties a stamp that `Bound` does not hold to its
ring's mark instance, and `exhausted` (the error value, with no
contract). The coordinator's `Panes` owns the one `Stamps`. Verus
proves that its stamps increase, never repeat and never wrap. In
`view.rs`: the WebSocket sends (`reject_ws`, `emit_marked`,
`emit_dead`, `emit_skipped`, `write_slice`) and the marker decode
(`resize_marker`). In `conn.rs`: `Output`'s `waiting`, `available`,
`close` and `send_batch` over the opaque `closed` and `waits`, and
`Header::new` (the record header). Each has an `// Assumes:` comment
that names its assumption. No `external_body` function has an
`ensures` that its body does not establish beyond that comment. No
`assume` and no `admit` occur.

The functions that `tokenized_state_machine!` generates are `pub`, so
everything that their contracts name is `pub`, and the ring's proof
modules allow `unreachable_pub`. rustfmt does not format the inside
of `verus!`.

**The delivery path.** `ko_server::delivery` (`Delivery`) owns the
pane's `Reader`, its snapshot queues, the delivered position and the
mint of every `Req` (a u64 serial; the `Req` is its low 32 bits). A
snapshot request's floor is the head that `request` loads. Its `wf`
keeps the delivered position at a boundary of the log and the queued
serials unique and in mint order. A slice reaches a view only as a
`Handle` that `deliver` constructs, and a snapshot's end only as a
`Done` that `snapshot_done` or `fail_all` constructs. The views get
`&mut Delivery`, whose methods keep the tail, so only `scan` advances
the ring. A `View` keeps its `Delivery`'s stamp, its request's serial
and slice count, and a `Mark` of the log. `open` and `pump` compare
the stamp at run time; `on_slice` and `on_done` compare the stamp and
the serial. The `View`'s `wf` holds through every `pub(crate)`
method, because its fields are private. A view places its cursor
through `Delivery::seek`, and the cursor lemmas are facts of the log
in `ring/spec.rs`. `delivery.rs` denies
`clippy::arithmetic_side_effects` but not `indexing_slicing`: vstd
specifies only `VecDeque::len` and its index, and Verus proves each
index in bounds.

**The script.** `scripts/verus.sh` cleans each verified crate first,
so every run verifies, and it fails without a "verification results"
line of 0 errors for each crate: it verifies one crate for each
`cargo verus verify` run and reads the last result and time of that
run, because Verus names no crate on the line. It keeps each crate's
whole output in `target/verus/<crate>.log` and prints it only on a
failure. The `verus` stage of `make verify` fails when the
verification of ko's crates takes more than 120 s, and it is SKIP
when the archive cannot be fetched, except with `KO_VERUS_REQUIRED=1`
(CI).

## Fuzzing

ko has no VT-parser target: Ghostty fuzzes libghostty-vt upstream.
`scripts/fuzz.sh` names the targets, all cargo-fuzz targets in
`fuzz/fuzz_targets/`, each with a dictionary in `fuzz/<target>.dict`
and its `max_len` in `fuzz/<target>.options`. A target calls one
function of a library crate. That crate has a `#[test]` that replays
the target's corpus `fuzz/corpus/<target>/`, or fixed cases if the
target has no corpus, through the same function on stable. Except for
`ko_pane::control`, the entry functions are in a module `fuzz` under
`cfg(any(test, feature = "fuzz"))`; only `fuzz/Cargo.toml` enables the
feature, so the shipped binaries do not contain the targets or their
models. A model in a target never reuses the formula of the code
under test.

- `frame` and `control`: `ko-pane`'s frame sizes and its control
  dispatch in process (`ko_pane::control`). The first byte of a
  `control` input selects the mode.
- `webview`: the OSC 7502 parser over the bytes; a path that it
  accepts keeps the path rules and parses again to itself
  (`ko_pane_wire::fuzz`).
- `ring`: an operation list on the real ring writer and reader,
  compared after every operation with a pure model of the ring and of
  `ko-pane`'s room rule (`ko_pane_wire::fuzz`).
- `loop`: `ko_sys::event` over socketpairs and a pipe with interest
  changes, sends, full buffers, peer closes, timers and signals,
  compared with a model (`ko_sys::fuzz`). It simulates a signal
  through the handler body and sends no signal.
- `head` and `decode` (`ko_wire::fuzz`), `http` and `frames`
  (`ko_server::fuzz`): the head reader over the bytes cut at the
  chosen points; one connection of an in-process server fed the
  bytes; each request decoder, whose value must encode and decode to
  itself; `pane_proc`'s frame reader, fed whole and in two parts,
  with the same effects. `http` makes its server once for each
  process and a fresh socketpair for each input. Its first pane runs
  `cat` under the real `ko-pane`. Every later pane starts
  `/usr/bin/true` in place of `ko-pane`, so a fuzzed request never
  runs its command. It needs `ko-pane` in `KO_PANE_EXE`, which the
  script builds.
- `client` (`ko_wire::fuzz`) and `ws` (`ko_server::fuzz`): the
  client's response and upgrade readers over the bytes, whole and cut
  at the chosen points, with the same result; a server-side WebSocket
  over a connection fed the bytes as client frames, whole and in two
  parts, with the same messages and close, and no message over 1 MiB.

`cargo test` replays every corpus in `fuzz/corpus/<target>/` in a
fraction of a second for each target. `make fuzz TARGET=ring
TIME=600` builds the target with debug assertions (`cargo fuzz build
-a`, so the contract checks run) and fuzzes for TIME seconds; no
TARGET lists the targets. Each run has its own process group and
scratch directory, and the script kills and removes both on every
exit. A finding is in `target/fuzz-artifacts/`. A libFuzzer run
restarts every 24000 inputs, because ASan on macOS keeps
libghostty-vt's freed memory, about 100 KiB per input. `control`
restarts every 8000 inputs: under ASan it grows by about 190 KiB per
input on macOS and Linux, and without ASan its memory stays flat, so
the growth is not a leak.

The corpora are files named by SHA-1. Only `make fuzz MERGE=1`
(`scripts/fuzz.sh --merge`) changes one, with a `-merge=1` into a
minimal set, and only with a code change that needs the new inputs.
The exception is a format migration in the same change as the code:
a one-off script converts each input to the new form, names it by
its SHA-1 and drops the inputs that become identical.

Only `fuzz/` reads `KO_FUZZ_*` (`scripts/lint.sh` refuses it in the
other crates).

## Miri

`scripts/miri.sh` (`make miri`) runs the tests of the modules without
sockets, FFI or processes: `frame`, the ring, `ids`, `protocol` and
`http`'s head reader. It selects them by name and skips the proptest
tests and the 16 MiB frame stream, which runs out of memory under
Miri in a 6 GiB container. Under `cfg(miri)`, `ko_sys`'s `Mapping`
is heap memory (`ko_sys/src/mapping/heap.rs`), so the ring's writer
and reader run on it.

## Reproducing a CI-only failure

`scripts/ci-like.sh` runs a Linux container with the repo
bind-mounted and CPU/memory capped (`make ci-like ARGS="--cpus 0.25
-- make cargo ARGS='test -p ko_e2e NAME'"`). A CPU quota alone rarely
reproduces timing failures. `--contend N` starts N busy sibling
containers; with a low `--cpu-shares`, this makes a wrapper's timer
run out of step with its command as a loaded runner does. The
siblings equally share `--budget` (default 2) minus the run's
`--cpus`. Use contention for one named failure, not a whole suite.
Never saturate the host's cores: other agents work in parallel.

The image (`scripts/ci-like/Dockerfile`, on `debian:trixie`) holds
rustup at a pinned release with its checksums, the toolchain of
`rust-toolchain.toml`, zig through `scripts/install-zig.sh` and
`strace`; its tag is `ko-ci-like:` and 12 hex digits of a digest over
the Dockerfile, `install-zig.sh` and `rust-toolchain.toml`, so a
change of one rebuilds it. `target/` and `build/` are the named
volumes `ko-ci-like-target` and `ko-ci-like-build` over the bind
mount, so a Linux build never overwrites the host's macOS outputs.
`share/pi/node_modules` and `share/koa/node_modules` are the named
volumes `ko-ci-like-pi-node-modules` and
`ko-ci-like-koa-node-modules`, so the container's `npm ci` installs
Linux packages and the ts stage runs there. The container
(`ko-ci-like-<pid>`; its busy siblings `ko-ci-like-busy-<pid>-N`)
gets `KO_STATE_DIR=/tmp/ko-state`, and the host's other `KO_*`
variables pass through, except `KO_AGENT_*`, `KO_PANE`,
`KO_PANE_TOKEN` and `KO_SOCKET`. In a linked worktree, the script
also mounts the main repository's git directory read-only, because
the Makefile runs git. Linux's check is `make ci-like ARGS="--cpus 2
--memory 6g -- make verify"`; the Rust and zig builds need more than
the default 1g. The container's `/dev/shm` is 1g (`--shm-size`): the
e2e test of a 100 MiB kitty `t=s` image needs more than podman's
default 64 MB. On Linux, `Named::create` reserves an object's pages
with `posix_fallocate`, so a full shm tmpfs is `ENOSPC` at creation,
not a SIGBUS at the first write. The Linux run does not cover the
host-sshd tests (the image has no sshd); CI's Ubuntu job does. The
podman machine on Apple silicon runs aarch64 Linux; CI's Ubuntu
runner is x86_64. For a worktree under `/tmp`, run the script from
its `/private/tmp` path: podman cannot mount the `/tmp` alias.
