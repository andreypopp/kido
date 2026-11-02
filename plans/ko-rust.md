# ko in Rust

Status: plan, 2026-11-01. Branch `ko-rust`, rebased onto `ko` at
e38b032d. The tree is the OCaml reference at that commit: the poll
loop, `ko_proofs/`, `ko_pane/genmc/`, `scripts/install-zig.sh` and the
current `test_e2e_ko/`; every path in this plan was a path of this
worktree then. R5 deleted the OCaml ko, the C `ko-pane` and the F*
build, and `ko_pane/genmc/` went after it (decision 111); a path to
one of them names the reference, which `~/Workspace/kido-ko` keeps.
`~/Workspace/kido-ko` (branch `ko`) holds the same
reference and does not change. The wire protocol does not change
([rfc/kido-server/protocol.md](../rfc/kido-server/protocol.md)). The
Go suite `test_e2e_ko/` is the acceptance oracle.

## Decisions

The user decided:

1. Rewrite ko in Rust, the server first, then the terminal client.
2. Use the minimum number of crates; keep the OCaml ko as the
   reference until the Rust ko replaces it.
3. No async runtime: no tokio, no hyper, no async code. Each process
   is one thread with a readiness loop over `poll(2)`, non-blocking
   descriptors, an explicit state enum per connection, a read buffer
   and a write queue per connection, signals through a self-pipe that
   the loop watches, the next deadline as the timeout and no timeout
   without one, and back-pressure by removing `POLLIN` from the
   interest. One loop module serves the server, `ko-pane` and the
   terminal client (3.6). Crates do the parsing: httparse for HTTP
   heads, tungstenite for WebSocket, serde and serde_json for JSON
   (section 2).
4. vte tokenizes the terminal client's input; ko translates its
   events into keys (2.2).
5. A request head over 16 KiB gets `431`, also after the responses to
   earlier pipelined requests (section 5, row 5).
6. tungstenite is the WebSocket crate (2.1).
7. ko's own HTTP/1.1 client on httparse serves `ko api` and the
   terminal client (3.6).
8. The toolchain comes from Homebrew's keg-only `rustup` formula;
   `rust-toolchain.toml` pins 1.99.1 (4.3).
9. `proptest` and `loom` are dev-dependencies (2.4, 6.3, 6.5).
10. Verus writes the specs, starting with the ring, from the F*/Pulse
    proof (6.7).
11. `ko-pane` is rewritten in Rust in the main line, not kept in C
    (1.3); the cut deletes the C `ko-pane`. It stays one process per
    pane, is built from the same workspace, and shares the loop, the
    ring, the frame codec and the handshake code with the server, so
    Verus verifies both ring halves from one source. `panic = "abort"`
    stays: a panic ends one pane.
12. `ko_vt_sys/src/bindings.rs` is generated once by the `bindgen`
    CLI and committed with the header hash (2.4).
13. R5 deletes the OCaml ko and the C `ko-pane` in one cut (7).
14. The Go suite edit of 4.1: `KO_BIN` and `KO_DECODE` from R0 to
    R4, the fixed paths from R5 until RE replaces the suite.
15. Verus covers `view.rs` from `View_core.fst` in a stage after RV2
    (6.7).
16. The coordinator allocates nothing on the heap per ring record in
    steady state (section 7's bench target).
17. `ko-pane` is a separate binary from the crate `ko_pane`, not a
    `ko` subcommand.
18. Verus runs on every push and in `make verify-ko` while the
    verification of ko's crates stays under its time cap; a module
    over the cap moves to the scheduled workflow by a recorded
    decision (6.7).
19. The poll timeout is the earliest deadline, which for an idle
    server is the earliest ping deadline; there is no periodic timer.
20. The release profile has `panic = "abort"` and
    `overflow-checks = true`.
21. No shipped snapshot decoder: the Go suite's decoder is the
    test-only example `ko_vt/examples/decode.rs` (`cargo build
    --release --example decode`), never installed; RE removes it.
22. Stage RE ports `test_e2e_ko/` to Rust integration tests after R5,
    and deletes the Go suite when the Rust one covers every Go test
    (7).
23. The outer terminal of the Rust client tests is the test process
    over its own pty with a `ko_vt` terminal (RE, 7): no tmux fork and
    no second server; the warning tests drop the kitty query
    themselves.
24. Every CI job and every download has a deadline (e38b032d), the
    Rust jobs and the Verus archive fetch included (4.4).
25. The JSON wire is not fixed. R0 to RE keep it; stage RW, after
    RE, moves every enum with a payload to serde's internal tagging
    (`"type"`), deletes the `compact!` macro and bumps the protocol
    major (2.6, 7).
26. The Rust ko is macOS-only until the end. Every stage before RL
    builds, tests and verifies on macOS only. The Linux build, Linux
    CI for the Rust ko and the Linux-only carry-over rows (row 37's
    `ppoll`, row 44's `ECONNRESET`, `SO_PEERCRED`, `memfd_create`,
    `/proc/<pid>/stat`) form the last stage, RL, after parity (7).
    Until R5, Linux CI keeps the Go suite on the OCaml `ko` and the
    OCaml decoder; from R5 to RL, Linux CI runs no ko stage.
27. No push of `ko-rust` until the end of RL, the last stage. The
    first push measures the CI job time (4.4). (During R3 the user
    moved the first push from the end of R5 to the end of RL.)

R0 forced these decisions:

28. `ko_vt` is a fourth place where `unsafe` is permitted: it is the
    safe wrapper over `ko_vt_sys`, whose functions are `unsafe extern`
    (3.4).
29. `make build-ko` also builds the `decode` example, so `TestMain`
    runs only `make build-ko` and never cargo (4.1, 4.3).
30. In R0 the `e2e-ko` stage runs the Go suite once, with the OCaml
    `ko` as `KO_BIN` and the Rust `decode` example as `KO_DECODE`,
    because no Rust server exists. The two runs of 4.2 start when the
    Rust server passes the server tests. The Makefile owns the two
    defaults; `TestMain` requires both variables until then (4.1).
31. The Makefile calls cargo as `$(CARGO)`, the full path in
    `RUSTUP_BIN`: make 3.81 on macOS looks up a recipe's command
    through its own PATH, not the exported one (4.3).
32. `scripts/crates.txt` lists ko's own crates too, so a new
    workspace crate also adds a line. R0 creates no `ko_pane` or
    `ko_bench` crate: RP and R3 add them, so no empty `ko-pane`
    binary exists beside the C one.
33. `ko_vt` checks the 1..=4096 dimension rule itself in R0. R1
    adds `Dim` (3.3) and `ko_vt` takes it, so the rule has one
    place.

R1 forced these decisions:

34. `pane_proc` takes the loop's state for each call (`Io`, with an
    optional sink that receives each snapshot slice and each scan).
    It hands out ring slices at once, before the tail moves, and
    returns done, title, dead and reply notices as events, so row 39
    holds by construction. `Server::turn` takes the sink for each
    call; R2's views take its place.
35. `Limits`, `Scrollback` and `Medium` live in `ko_pane_wire::frame`,
    so one type serves the init frame and the terminal; `ko_vt` takes
    them and `Dim` (decision 33). `ko_pane_wire` depends on `ko_sys`.
36. The ring `Writer` exists from R1, without a feature gate, for the
    tests of `ko_pane_wire` and `ko_server`; RP makes it `ko-pane`'s
    writer.
37. `unsafe` is permitted in `ko_pane_wire::ring::model` too, the loom
    backing of the mapping. loom does not model a `SeqCst` access as
    sequentially consistent, so without a correction the `SeqCst`
    wakeup model also lost the wakeup; the model puts a
    `fence(SeqCst)` before each `SeqCst` load and after each `SeqCst`
    store. `records_reach_the_reader_whole_and_in_order` runs with
    preemption bound 5: unbounded, it did not end in 15 minutes.
38. The spawn of `ko-pane` uses `POSIX_SPAWN_CLOEXEC_DEFAULT` and keeps
    fd 2 through `posix_spawn_file_actions_addinherit_np`, which
    `ko_sys` declares, because the `libc` crate does not.
39. Under `EMFILE`, macOS drops the connection that `accept` refused,
    so the row-35 test connects a new client after it frees
    descriptors.
40. The acceptance probe is `ko_server/examples/ring_probe.rs`, run by
    `make probe-ko` and not by verify. It drives the real `Server`,
    and it fails on a lost record, a gap in the offsets, an invalid
    record or a byte total other than the producer's. The producer
    clears `OPOST`, so the total must match exactly. R3's `ko-bench
    throughput` replaces it.
41. `make test` keeps its dependency on `build-ko`: the Go suite in it
    reads the OCaml `ko` from dune's install tree and the Rust
    decoder. A no-op `build-ko` takes 1.0 s, 0.9 s of it `dune build
    @install`; after an edit, 1.35 to 1.56 s.
42. `Server::new` takes a `Timing` (the accept retry, the output tick,
    the shutdown grace), so tests shorten them through the argument.
43. The `Server` SIGTERM test starts the C `ko-pane` in a re-executed
    test process. `make test-ko` builds it with dune first and names
    it in `KO_PANE_EXE`; without the variable the test fails.
44. These exports have no caller in another crate until R2 or R4 and
    stay `pub` for them: `ko_sys::sock::{peer_pid,
    set_receive_buffer}`; `ko_pane_wire::ring::Reader::{reachable,
    resume, end_offset, oldest_offset, marker, payload}`, `Reach`,
    `Marker`; `ko_pane_wire::frame::{KeyCode::new, KeyAction,
    MouseAction, MouseButton}`; `ko_server::config::{dir, socket,
    Config::create}`; `ko_server::ids::{ClientId, InvalidId}` and
    `PaneId`'s `FromStr`; `Pane::{command, sizer, resize, claim}`;
    `PaneProc::{child_pid, title, snapshot, screen, input, resize}`,
    `Input`, `Refusal`, `Event`, `Io`, `Sink`; `Panes::{iter, remove}`,
    `AddError`; `Verified::into_stream`. R2's review checks that each
    has its caller.
45. `BUILD` comes from `option_env!("KO_BUILD_ID")`, which nothing
    sets yet, so it is `unknown` until R2 adds `ko_server/build.rs`
    with `KO_VT` (4.1).

During R2 the user decided:

46. The command line uses clap with derive, so `--help` and the usage
    errors are generated from the doc comments on the declarations, as
    cmdliner does. clap has `default-features = false` and exactly the
    features `std`, `derive`, `help`, `usage` and `error-context`:
    `help` and `usage` generate the help and usage text,
    `error-context` keeps the reason in a usage error. `color`,
    `suggestions` and `wrap_help` add packages and are not used
    (2.4, 2.5).

R2 forced these decisions:

47. `pane_proc` hands each delivery to the sink as the `Reader`, the
    request and the position; `Delivery::Scanned` is gone. A view
    needs the `Reader` (`end_offset`, the head), so the server pumps
    the views after each scan, in the same turn.
48. Each connection owns its `View` or its `Client`; there are no
    parallel lists. A closed connection is removed at the end of the
    turn, and the interests are computed again then.
49. A request body (at most 1 MiB) is read whole before dispatch.
    Only a paste and a `/screen` request wait in `Handling` for
    `ko-pane`.
50. The server encodes and decodes base64 itself (about 40 lines);
    `data-encoding` stays a package of tungstenite only, not a direct
    crate of ko.
51. `make e2e-ko` and `make test` run `scripts/verify.sh ko-suite`. It
    lists the test functions of `test_e2e_ko/`, runs the client tests
    of its list (4.2) against `KO_OCAML` and every other test against `KO_RUST`,
    and filters both by `E2E_KO`; on Linux `KO_RUST` is unset, so all
    tests run the OCaml `ko`. These variables replace the Makefile's
    `KO_BIN`, which stays the suite's own variable (4.1, 4.2).
52. `ko_server/examples/ring_probe.rs` reads the ring as a real view
    client over the socket, through `http.rs`, `Route` and
    tungstenite's client role, because the server's test sink is
    gone; its CPU figure includes the client thread.
53. The server records the owner of each pane request once, when the
    request goes out: `State`'s map from the pane and the request to
    an `Owner` (a `/screen` reply, an HTTP paste, a view's paste, a
    view's snapshot). Every reply from `ko-pane` finds its owner with
    one lookup. The OCaml stores a reply closure with the request;
    closures in `pane_proc` would break the rule of no callbacks.
54. A refused HTTP request gets the reply of the OCaml ko, byte for
    byte: a bad header line or `Content-Length` gets `400 Bad
    Request` with the body `400` and a close; a request line that is
    not HTTP gets a close with no reply; a body over 1 MiB on create
    or input gets the JSON `invalid` 400 and the connection continues.
    httparse differs from httpun in three cases that no client sends:
    it refuses `HTTP/1.2`, accepts a head with bare LF line ends, and
    refuses control bytes in a header value. A route without a body
    answers a body over 1 MiB only after 1 MiB has arrived.
55. Test processes start through `ko_sys::spawn::program` with
    `POSIX_SPAWN_CLOEXEC_DEFAULT`, the flag of the pane spawn
    (decision 38): on macOS, `UnixStream::pair` sets close-on-exec
    after it creates the socket, and a concurrent `Command` in another
    test thread inherited it, so a dropped peer stayed open and two
    `pane_proc` tests failed about once in 12 runs. A lock around the
    tests' own sockets cannot cover the sockets that production code
    makes during a test.
56. `make test` and `make e2e-ko` set `KIDO_E2E_REQUIRED=1`, so the
    client tests fail, not skip, without the pinned fork.
57. Decision 44's exports after R2: `peer_pid`, the `Reader` methods
    with `Reach` and `Marker`, the frame key and mouse types and
    `config::{dir, socket, Config::create}` have callers in other
    crates; `Pane`, `PaneProc`, `Input`, `Refusal`, `Event`, `Io`,
    `Sink`, `Panes`, `AddError`, `Verified::into_stream` and
    `ClientId` are private to `ko_server`; `set_receive_buffer` is
    deleted. `InvalidId` and `PaneId`'s `FromStr` stay `pub` without
    an outside caller, because `PaneId` is in the public `Route`.

The user also decided during R2:

58. `SIGINT` and `SIGHUP` stop `ko server` as `SIGTERM` does: the
    panes stop, the grace runs and the socket goes. This is a
    deliberate difference from the OCaml ko, which handles only
    `SIGTERM`, so C-c left its socket behind.
59. `ko server` removes a stale socket before it binds, under the
    launch lock and only when a connect is refused, as the OCaml
    client's attach path does; the OCaml `ko server` refused it as
    already in use.

RP forced these decisions:

60. The R2 server broke row 13: after a write that the socket
    refused whole, the view was not waiting, so the next pump decided
    a skip mid-stream (`TestStalledViewSkips` failed 4 times in 320
    runs under load). `conn::Output` now stays waiting until
    `POLLOUT`, as `connection.ml`'s `Blocked -> wait t` does; the Go
    test is unchanged and passed 640 of 640 runs.
61. The R2 setup failures were not an exhaustion. macOS `openpty`
    fails now and then with errno -6 when other processes allocate
    ptys at the same moment (8 concurrent loops: about 1 in 4,000
    calls); during the parallel server suite, ptys in use rose by 13
    over a base of 38 (511 allowed) and processes peaked at 1,047
    (10,666 allowed). `ko_sys::pty::spawn` tries `openpty` up to
    three times, but not after `EAGAIN`, `ENOMEM`, `EMFILE` or
    `ENFILE`.
62. A setup failure of `ko-pane` sends an `error` frame that names
    the call and the OS error ("openpty: Too many open files (os
    error 24)"), which reaches the client as the cause `failed`. An
    `exec` failure is a dead pane with exit 127, and a failure of
    `chdir`, `setsid` or `TIOCSCTTY` before it a dead pane with exit
    126, as `pane.c` reports them. By the user's decision,
    `ko_sys::pty::spawn` forks and execs itself: the child runs only
    async-signal-safe calls and reports its failed step and errno
    through a close-on-exec pipe record, and the parent builds the
    `Program` only after EOF on that pipe.
63. The title and pwd callbacks only record a change, because a
    callback must not re-enter the terminal; after the write,
    `ko-pane` reads the value and sends one frame. Several changes in
    one write give one frame with the last value.
64. `fuzz/` is a workspace member outside `default-members`, so
    clippy checks the targets on stable and `cargo test` does not
    build libFuzzer. `libfuzzer-sys` adds `arbitrary` and
    `jobserver`. The `control` target has no terminal pool and the
    run lines of `scripts/fuzz.sh` for the Rust targets are R3's.
65. The Rust `ko-pane` refuses three inputs that the C one accepts: a
    size with exactly one zero cell dimension (`Size` holds the cell
    size as one option of two nonzero values, decision 35), a
    snapshot request with images (the protocol has only
    `Images::None`), and key or paste text that is not UTF-8 (the
    wire carries JSON strings). The only client is the coordinator,
    which sends none of them; a refused frame fails the pane with an
    `error` frame.

R3 forced these decisions:

66. R3 builds six of the new fuzz targets: `ring`, `loop`, `head`,
    `http`, `decode` and `frames`. `client` and `ws` come with R4,
    beside the client's `wire.rs`, which is the other reader of
    responses and frames.
67. `scripts/fuzz.sh` runs only the Rust cargo-fuzz targets. The long
    runs of the C and OCaml targets, the AFL++ runs among them, leave
    the script; their fast paths under `dune test` stay until the
    cut, which also deletes `dune-workspace.afl` and `dune.afl.lock`.
68. The fuzz entries of `ko_pane_wire`, `ko_sys` and `ko_server` are a
    module `fuzz` under `cfg(any(test, feature = "fuzz"))`. Only
    `fuzz/Cargo.toml` enables the feature, so no shipped binary
    contains a target or its model. `ko_pane::control` stays as RP
    left it.
69. The nightly pin is `nightly-2026-10-14` in `scripts/nightly.sh`,
    the day after rustc 1.99.1's commit, with `miri` for arm64 macOS.
    `ko-nightly.yml` runs each target in its own job of a matrix
    that `scripts/fuzz.sh --list` gives, for 600 s, with a job limit
    of 40 minutes (the fuzz time, 15 minutes for the cargo-fuzz
    install and build, 15 spare). The nightly cargo runs only through
    `make nightly-cargo` (decision 31).
70. Miri does not cover `conn` and `pane_proc`: their `Output` and
    control socket are unix sockets, and neither has an in-memory
    writer. Under `cfg(miri)`, `ko_sys::Mapping` is heap memory with
    `/dev/null` as its descriptor, so the ring runs under Miri with
    `-Zmiri-disable-isolation`.
71. The `head` target requires one result for every cut of an input
    under 16 KiB, and for a longer input a refusal for every cut, but
    not one kind: read whole, httparse can refuse (`Invalid`) a byte
    past the limit, while cut, the limit (`TooLarge`) comes first.
    The server's read buffer is 16 KiB, so it never parses past the
    limit.
72. `unsafe` is permitted in `ko_bench/src/alloc.rs`, the counting
    global allocator. It counts in a thread-local cell, so the figure
    is the server thread's; `ko-bench` runs the drains as threads of
    its own and reports the server thread's CPU time.
73. Decision 16 held for every stream except the two with title and
    pwd changes: `State` built their event JSON with no client
    registered (0.14 and 1.00 allocations per record on `tui.vt` and
    `shell.vt`). It now builds them only for a registered client.
    With a client, a title or pwd change still allocates its event,
    once for each change, not for each record.
74. `TestNoIdleWakeups` reads the server's CPU time and wakeups with
    `proc_pid_rusage` (cgo, `internal/rusage`), because `ps` counts
    in 10 ms steps. Primed panes come with S1, so its three idle
    panes run `read` with one view each.
75. `TestKillServerSignalsByPeerPID` was a test race. On macOS
    `kill(pid, 0)` succeeds on a zombie, so `ko kill-server` returned
    only after Go's `cmd.Wait` had reaped the stand-in, and the test
    then read the `exited` channel with `default` before the
    goroutine had closed it. The test now waits up to 5 s for the
    channel.
76. `ko-bench throughput` replaces `ko_server/examples/ring_probe.rs`
    (decision 40): `make probe-ko` runs it, with `BYTES` and `PANE=c`,
    and it fails on the same faults. `ko-bench` reads and writes the
    wire through `ko_server::protocol` and `ko_server::ws`, so the
    wire types that it uses are `pub`.
77. The latency modes stamp the receive at different points: the
    OCaml bench when its 2 ms timer scans the ring, before the view
    write; `ko-bench` after the view client's `read`, which adds the
    write and the client's wakeup. The producer stamps a record every
    1 ms, under the 2 ms output tick, so both figures mostly measure
    the wait for the tick.

After R3 the user decided:

78. The bench targets are relative to a fresh OCaml run in the same
    session, on AC power, at load average under 2: coordinator CPU
    per GiB within 5 percent of the OCaml figure, and the five-pane
    flood within 10 percent. The absolute targets of 0.80 s per GiB
    and 0.26 core are dropped: both servers missed them on the same
    machine (on AC power, OCaml 0.914 s and Rust 0.912 s per GiB;
    flood 0.28 and 0.30 core).
79. The hop latency row measures one hop. The producer stamps at an
    interval that does not alias the 2 ms output tick, and both
    benches stamp the receive at the same point (decision 77 records
    the fault). The target is the same or better than a fresh OCaml
    run of the fixed bench in the same session.

RV forced these decisions:

80. The data bytes are a tracked map from index to an opaque
    `ByteTok` (the role of F*'s `pts_to_mask`), not a ghost copy in
    the state machine. The published and the released bytes are
    `storage_map` fields of the machine, as in `ring_inv`. A token
    carries its value as an `Option<u8>`, as F*'s `bytes` does: a
    payload that `Writer::payload` lends out is `None` until it is
    published, and a read gives no claim for a `None` byte. One Verus
    instance cannot span two processes, so each role has its own
    trusted constructor and its own instance: `Backend::mint_reader`
    (the reader created the zero-filled mapping, and owns no data
    byte) and `Backend::mint_writer` (the writer attaches once for each
    ring, before any record, and owns every data byte). The other
    process holding the other token of the same ring is the trusted
    "one heap" assumption of F*. The in-process writer of
    `Reader::writer` is a second mapping with its own words, so it
    also takes `mint_writer`.
81. `Reader::record` has no `requires` beyond `wf`, because its
    callers in `ko_server` are not verified; it ensures its fields
    only for a position in the log. Its `debug_assert!` lost the
    conjunct `header.off <= pos`, which a hostile peer can break.
82. `Writer::available` returns room 0 when its pad record is
    refused, which can happen only within one capacity of
    `MAX_HEAD`; before, it returned the room as if the pad was
    published.
83. The `verus` stage maps the `SKIP:` line of `make verus` to exit
    code 77, which `scripts/verify.sh` prints as SKIP. The archive
    fetch has `--max-time 600`, the 10-minute deadline of decision 24.

R4 forced these decisions:

84. The terminal client's plain requests (create a pane, delete a
    pane, list the panes, `/screen` for the pager) are blocking calls
    with the deadlines of the OCaml client (5 s to connect, 40 s to
    read), as the OCaml `Wire.request` is. Only `/client` and the
    shown view are sources of the loop (3.6).
85. The compressor thread has no pipe to the loop. It changes no
    visible cell, so the loop never needs its wakeup, as in the OCaml
    client, whose loop wakes only for the view reader. The thread
    waits on the `Condvar`: between steps of 1 ms it yields for
    500 us, and when the mirror is settled it waits without a
    timeout until the loop notifies it of an update (3.5).
86. vte swallows an APC string, so the client's input gives no reply
    for a kitty graphics `_G` answer. The client does not use that
    reply. The replies test of P1.2 expects no key and three replies
    (XTVERSION, the kitty flags, DA1), not four. The client sends one
    startup probe: the DECRQM queries of `modes.rs`, the kitty flags
    query, XTVERSION and DA1. It ends at the DA1 answer, the last
    reply, or after 500 ms. It replaces Matrix's capability probe and the mode
    query of the OCaml client.
87. `ko_tui` denies `unsafe`, so the raw mode, the window size and the
    input flush are in `ko_sys::tty`. The client starts a missing
    server through `ko_sys::spawn::detached`: `posix_spawn` with
    `POSIX_SPAWN_SETSID` (0x0400 in macOS's `<spawn.h>`, which
    `ko_sys` declares because the `libc` crate does not, as decision
    38), `POSIX_SPAWN_CLOEXEC_DEFAULT` and the log as fd 1 and 2. The
    client does no `fork`.
88. The client releases the launch lock as soon as it has spawned the
    server. The Rust server takes the same lock in its bind (decision
    59), so a client that held it would stall the start for its 5 s
    deadline.
89. The client has no ping deadline of its own. The server pings an
    idle link after 30 s (protocol.md 1); a client that has received
    no frame on `/client` or the shown view for 40 s fails with "ko
    socket timed out".

RV2 forced these decisions:

90. `ko_server::delivery` is the verified module of RV2: `Delivery`
    owns the pane's `Reader`, the queue of reading requests, the queue
    of finished ones and the delivered position, and keeps the front
    request's last slice as a ghost field. `Stage::Open` and
    `Stage::Closed` hold a `Delivery` in place of the `Reader`.
    `observed` and `busy` stay in `PaneProc`, outside the proof.
    `ko_server` gains `vstd` as a direct dependency (no new package).
91. `Delivery::ring_mut` lends `&mut Reader` to unverified code (the
    views, until RV3), which may call only the methods that keep the
    tail (`head`, `end_offset`, `oldest_offset`, `resume`); `wf`
    survives them (`inv_grows`). `scripts/lint.sh` refuses
    `.advance(` in `ko_server/src` outside `delivery.rs`. A type for
    the views' ring replaces the lint in RV3, when `view.rs` is
    verified. A `type_invariant` on `Reader` was tried and dropped:
    Verus checks it at each field assignment, which broke RV's proofs.
92. `deliver` updates its state at each record, so it allocates
    nothing (the `done` vector went); it moves `delivered` past a
    slice before it reads the slice's `last` flag, as `Pane_core`
    does. A ring error drains every request, so the events do not
    change.
93. `scripts/verus.sh` runs `cargo verus verify` once for each crate
    and reads the last result and time of each run: Verus names no
    crate on its result line, cargo builds crates in parallel, and on
    a cold run vstd's lines come first.
94. `Delivery::wf` is `pane_inv` without the tokens' ring and
    generation (`tring`, `tgen` and the generation clauses of
    `slice_step` and `done_step`). Each `Delivery` owns its ring, so
    the ring clause holds by construction; the generation is the
    routing of a `Req` to its view in `state.rs`, unverified until
    RV3.

RV3 forced these decisions:

95. `Delivery` mints every `Req` (snapshot, screen and paste) from a
    u64 serial; the wire `Req` is its low 32 bits and still wraps. The
    queued entries, the slice handles and the view carry the serial,
    so a request and its entry match for the life of the process. The
    mint refuses when the new `Req` equals the oldest queued one (the
    span of 2^32) and at `u64::MAX`. A refused snapshot rejects the
    view, a refused screen answers "pane process ended" with no
    owner, a refused paste is `Refusal::Ended`. Neither is reachable
    in practice. This closes decision 94.
96. A view finds its `Delivery` through unverified `state.rs`, so the
    identity is checked at run time: each `Delivery` takes a stamp
    from the coordinator's counter, and the view keeps it. `open` and
    `pump` compare the `Delivery`'s stamp; `on_slice` and `on_done`
    compare the stamp and the serial of the `Handle` or `Done` that
    only `delivery.rs` constructs. That is one compare for each call,
    never for each record. The counter refuses to wrap, and
    `Delivery::create` then fails. Decision 117 proves the counter.
97. The view proves its invariant against the log through
    `ko_pane_wire::ring::mark`: a state machine with the reader's
    current log and persistent marks below it. The view keeps a
    `Mark` and, after the stamp compare, grows its facts to the
    current log. F*'s ghost `floor`, `snapped` and `last_slice` and
    the two assumed ghost steps go: the unverified sink can drop or
    reorder a slice, so the order is checked at run time instead.
    `on_slice` rejects a slice whose offset is before `coff` (one
    compare for each slice, on the snapshot path only). `Delivery`
    counts the slices that it hands over for each request, and the
    view counts the slices that it takes. `on_done` takes a `Done`
    with the stamp, the serial, the hold and the count, and makes the
    view live only if it took every slice (the counts agree and are
    not 0) and its cursor is the hold; otherwise it rejects the view.
    Then `on_done` ensures `View_core`'s `linked` (the cursor is the
    hold) and `resumable` (the tail at the done is at or before the
    cursor). ko-pane writes a last slice before every `SnapshotDone`,
    and a slice's offset is at or after the head at the request, so
    no check rejects in normal operation.
98. Small behaviour changes that the proof needed: `started` clears
    `wanted`; a skip sets `coff` to the head that its event names;
    `open` acts only on a fresh view; `View::close` always calls
    `Output::close`, which is idempotent.
99. The views take `&mut Delivery` in place of `Delivery::ring_mut`.
    Its `head`, `end_offset`, `oldest_offset` and `resume` keep the
    tail, and only `scan` calls `Reader::advance`. The lint row of
    decision 91 is deleted.
100. `Output`'s socket I/O is an `external_fn_specification` in
    `conn.rs` over the opaque `closed` and `waits` (the model of
    `Connection.fsti`), and the WebSocket sends of the view are
    `external_body` functions in `view.rs`. `Batch` is verified.

Decisions 101 to 109 are not used. Before R5 the user decided:

110. The `yes` row of the client measures client CPU per MB parsed,
     and its target is no more than the reference. The target "under
     1 core" is dropped. The Rust client parses the whole stream
     (77.9 MB/s, 0 view skips, about 9.6 ms of CPU per MB). The OCaml
     client parses only for its parse budget of 4 ms in each 8 ms,
     so it parses about 19 MB/s with 18 view skips per second (about
     40 ms of CPU per MB). A producer that floods keeps a parser at
     one core, as in kitty and Ghostty. The client gets no parse
     budget.

R5 forced these decisions:

111. `ko_proofs/` keeps every F*/Pulse source (`.fst`, `.fsti`) as
     the specification that the Verus stages port; RV3 ports
     `View_core.fst` and its contracts from it. Only what exists for
     the OCaml and C build goes: the extraction (`extract.sh`), its
     OCaml outputs `pane_core.ml` and `view_core.ml`, `make proofs`,
     `scripts/install-fstar.sh` and CI's `proofs` job. With no
     extracted code in a build, F* verifies nothing that ships, so
     no job checks the sources. GenMC's models of the extracted C
     ring went after R5 with `ko_ring_proved.h` and `ko_atomic.h`;
     their result stays: the ring model ran 17,519 executions with no
     error, and the wakeup model lost a wakeup under acquire/release
     and none under `seq_cst`. loom on the Rust ring replaces them
     (6.5).
112. With the OCaml ko gone, the bench reference is the Rust ko at
     the R5 commit. A later bench run builds that commit in a
     scratch worktree (`git worktree add --detach /tmp/ko-ref-XXXXXX
     <commit>`, then `make build-ko` there) and measures it first, in
     the same session, on AC power, at load average under 2, as
     decisions 78 and 79 did with the OCaml ko. The rules stay
     relative: coordinator CPU per GiB within 5 percent of the
     reference, the five-pane flood within 10 percent, the latency,
     attach and resize rows the same or better, `yes` client CPU per
     MB no more than the reference (decision 110), zero allocations
     per record. A change that moves a row past its rule names the
     new reference commit in the plan or in docs/ with the reason.
     The R3 and R4 tables stay as the record of the OCaml
     comparison, not as fixed targets: absolute figures drift with
     the machine and its load. R5 runs no benchmark; its acceptance
     has no bench row.
113. `make build-bench` compiles the kept C helpers of `bench/`
     (`produce`, `drain`, `wait_master`, and `pty_read` and `parse`
     against the libghostty-vt of `ko_vt_sys/build.rs`) with `cc`
     into `build/bench/`; dune builds no part of
     ko. `ko-bench` finds `ko-pane` beside itself and `produce` at
     `build/bench/produce` of its checkout, from its own path; it
     reads no variable for either. The bench scripts share their
     setup in one sourced file.
114. Two bench rows go with the OCaml bench: `bench/kitten.sh`
     (`kitten __benchmark__` in `ko-pane`, through
     `coordinator.exe run`, a mode that `ko-bench` does not have) and
     the C tail-acker row of `bench/baselines.sh` (`acker.c` drove the
     C `ko-pane`). The kitty and tmux comparisons of p1-mvp.md 6
     stay as recorded figures.
115. Off macOS, `scripts/verify.sh` prints SKIP for the `e2e-ko`
     stage and for `ko-suite` (`make test`, `make e2e-ko`) until
     RL; `make verify-ko` is not run there.
116. `ko_pane_wire` has no test against a C header: the Verus spec
     (`ring/spec.rs`) is the one source of the ring's constants.
117. The `Delivery` stamp counter is proved, not trusted. `Stamps`
     is a plain `u64` counter that the coordinator's `Panes` owns and
     passes to `Delivery::create` by `&mut`; every production
     `Delivery::create` runs on the coordinator thread (`Panes::add`).
     Verus proves that a stamp is the counter's `next`, that `next`
     increases with `checked_add`, and that at `u64::MAX` the counter
     refuses and stays unchanged. The refusal is "the Delivery stamp
     counter is exhausted" from `exhausted`, a trusted body with no
     contract that only builds the error. The counter carries an
     opaque tracked token `Bound`, the set of stamps that it handed
     out: empty at `mint_stamps`, which starts `next` at 1, only
     grown by one stamp for each `bind`, and all below `next`. Two
     more trusted items remain, in the form of
     `Backend::mint_reader` (decision 80):
     `mint_stamps` assumes that the process mints one counter, and so
     one `Bound`; `bind_fresh`, a proof function, defines
     `instance_of` at a stamp that `Bound` does not hold and adds the
     stamp to it. Its freshness `requires` is proved from the
     counter, and a second call for the same stamp fails it. Nothing
     in the types stops a second `mint_stamps` call. The test and
     fuzz code mints one counter for each `Delivery`; only the
     server's binary holds to the one-counter assumption.

RE forced these decisions:

118. `TestNoIdleWakeups` (decision 74), which R3 added after the RE
     table was written, is ported too, as `idle.rs`'s
     `no_idle_wakeups`: the Rust suite has 45 tests, not 44. It reads
     the server's CPU time and wakeups through `ko_sys::clock`'s
     `process_cpu` (`proc_pid_rusage`); its 5 s window is the one
     entry of the `thread::sleep` table. `internal/rusage/` goes with
     the Go ko suite.
119. The suite is one integration-test binary,
     `ko_e2e/tests/e2e/main.rs`, with one module for each Go file in
     `ko_e2e/tests/e2e/` and the shared `harness.rs` and `outer.rs`.
     cargo runs test binaries one after another, so one binary for
     each Go file would run the files in series; one binary keeps the
     parallelism of `t.Parallel()` and links once. The entry is
     `main.rs` in the directory, because a file `tests/e2e.rs` would
     make cargo take each module file in `tests/` for another test
     binary.
120. The `ko_sys` feature is `e2e`, not `test-signals`: it holds
     the OS calls that only the suite needs (`signal_descendant`,
     `Pid::parent`, `Pid::has_ended`, `Pid::wait_exit`, `Signal::Stop`,
     `Signal::Cont`, `fd::wait_readable`, `fd::wait_writable_within`).
     `spawn::program` takes an `Env` (`Inherit` or `Only`, with the
     entry form of `pty::spawn`), so each child of a test gets an
     explicit environment and the test process never sets its own.
     `make e2e-ko` passes `--test-threads=64`: libtest starts tests
     in name order on a pool of one thread for each CPU, and the
     5 s window of `no_idle_wakeups` waited for a free thread behind
     the 20 tests that sort before it.
121. `make build-ko` replaces each installed binary with a new file.
     `cp -f` over the binary of an earlier run wrote the file in
     place, and macOS then killed every exec of it (`Killed: 9`); both
     suites failed all 45 tests until the copy changed.
122. The branch is not pushed before RL (decision 27), so "passes in
     CI on macOS" in the RE text became "passes in the final local
     `make verify` on macOS", and the deletion of the Go suite is in
     the same change as the Rust suite; there was no period with an
     `e2e-rs` stage.
123. The client draws the dead line from the shown view's dead marker,
     not from the `dead` event of the `/client` link. The two travel on
     different sockets, so the event could arrive before the pane's
     last output and the line was drawn over an empty snapshot
     (`client_dead_pane_line` failed about once in 33 runs). A view
     whose snapshot starts after the marker would never see it, so
     `ko-pane` puts the dead marker into the ring again after every
     snapshot of a dead pane; views already past it get a repeat that
     changes nothing. The sidebar's `†` and Ctrl+D still follow the
     event.
124. The suite was trimmed from 45 tests to 29, because each server
     start costs the whole suite and a test earns its time. Thirteen
     tests merged into a test with the same setup, on its server:
     `client_output_without_outer_input` into
     `client_initial_cursor_and_synchronized_output`;
     `client_sidebar_release` into `client_lifecycle`;
     `client_nvim_normal_mode_shifted_keys` into
     `client_legacy_shifted_key`, as rows with kitty flags 1 checked on
     the pane's received bytes, so no test needs nvim;
     `resume_skips_resize_markers_before_the_offset`,
     `unsafe_paste_is_not_written` and `detach_keeps_kitty_input` into
     `view_resume_resize_and_input`; `death_has_one_timestamp` and
     `live_synchronized_snapshot_and_history` into
     `pane_dead_snapshot` (a live pane and a dead pane take the same
     snapshot path in `ko_pane`, so the dead snapshot checks it);
     `pane_process_crash_kills_program` into `pane_process_failure`;
     `partial_resize_snapshot` into
     `unfocused_first_client_sizes_pane`; `scrollback_lines_limit` and
     `fuzz_variables_do_not_reach_the_binary` into
     `defaults_and_pane_environment`;
     `view_input_frame_split_across_writes` into
     `paste_then_enter_during_snapshot`, which writes its batch in two
     parts cut inside a frame. Three tests went, because a unit test
     checks the same fact: `client_snapshot_interruption` and its
     proxy (`ko_tui::mirror`), `sigterm_kills_programs`
     (`ko_server::server`; `kill_server` keeps the program that
     ignores SIGHUP) and `view_input_frames_in_one_write`
     (`ko_server::ws`). `client_grid_limit` stays: the unit test of
     `ko_server::protocol` checks the decoded size, not that the
     server closes the connection. The modules no longer follow the
     Go files: `views.rs` holds the view and pane tests, `protocol.rs`
     the server and API tests, and `input_frames.rs`, `state.rs` and
     `streams.rs` went. `no_idle_wakeups` measures a shorter window
     with the same CPU bound for each second, and the flood of
     `client_history_and_alternate_screen` is shorter but still more
     than the socket buffer and the ring. `full_snapshot_slow_reader`
     stays: the view harness never fills the socket buffer.

The e2e readability pass forced this decision:

140. An e2e test reads like command-line use. A step that a `ko`
     command can do (`ko api` with `-X`, `--input` and `-i`, `ko
     kill-server`, `ko version`) runs that command through
     `Server::ko` and asserts its stdout, stderr and exit code, with
     the request path written out at the call site; no named helper
     hides the path of a request that a test asserts on. The setup
     helpers `Server::pane` and `Server::text` and the pid reads stay.
     `ko api` exits 0 for every 2xx, and `ko_server::http::Status` has
     no 2xx but 200, so exit 0 asserts the 200 of the raw request.
     This replaces RE's rule that the client side
     writes every request as literal bytes. The trade-off: an ordinary
     request now goes through ko's own HTTP client and server, so a
     fault that both ends share can hide there. The framing stays
     covered by the raw-byte tests (`hostile.rs`, the exact statuses
     of `version_and_origin`), the unit tests of `http.rs` and the
     `head`, `http` and `client` fuzz targets. Raw requests also stay
     where a test polls (`pane_pids` in `client_lifecycle`, the
     `/version` read after each record of `full_snapshot_slow_reader`),
     because a process start for each request would add its cost to
     the loop, and in `start`, the setup of every test, which reads the
     `vt` value of `/version` for the `Ko-Vt` header. WebSocket
     views and clients stay raw, because `ko api` refuses those
     endpoints. `client_grid_limit` merged into
     `hostile_clients_do_not_affect_others`, on its server: 28 tests.

RW forced these decisions:

150. `protocol::decode` decodes through the derive straight from the
     bytes, so serde still refuses a duplicate field or tag. Only when
     the bytes contain a `[` does it also parse a `serde_json::Value`
     and refuse an array where the re-encoded value has an object.
     This replaces the `Objects` deserializer wrapper (about 200
     lines): an internally tagged enum buffers its input in serde's
     private `Content`, so the wrapper no longer sees the nested
     records. Key, mouse, text, paste, size and view events have no
     array and pay nothing; a create or a topology pays one `Value`
     and one re-encoding, on the control path (decision 16).
151. The fuzz corpora move to the new wire form with a one-off script
     in the change, not with `make fuzz MERGE=1`: agents do not run
     `make fuzz`. The script converts each input that parses as the
     old form, names it by its SHA-1 and drops the inputs that become
     identical; hostile bytes stay as they are. `decode` kept 18
     inputs (13 converted), `http` 13 (11 converted, only the
     `Ko-Protocol` header). AGENTS.md permits this for a format
     migration in the same change as the code.
152. `make verify` runs kido's stages and ko's (`build-ko`,
     `unit-ko`, `e2e-ko`, `lint-rs`, `verus`) in one run, so one
     command checks everything; `make verify-ko` stays for ko-only
     work. `make lint-rs` is cargo fmt and clippy; `make lint-ko`
     adds `scripts/lint.sh`, which `make verify` runs once, in its
     `ts` stage. The stage `build` is always kido's `dune build`, and
     `build-ko` is ko's. Off macOS, every ko stage prints SKIP.

The yardstick for estimates is migration.md's: about 350 lines of new
code with tests per agent-day. Line counts of the OCaml ko come from
`wc -l` on 2026-10-31.

## 1. Scope and order

### 1.1 What exists

| part | lines | language | what it is |
|---|---|---|---|
| `ko_server/` | about 3,800 OCaml, 450 C | OCaml on its own `Event_loop` (`poll(2)` through iomux), httpun, httpun-ws | the coordinator; `pane_core.ml` and `view_core.ml` are extracted from F* |
| `ko_proofs/` | 4,208 | F*/Pulse, extracted C | the ring, `Pane_core`, `View_core` and their contracts (6.7) |
| `ko_server/fuzz/` | 1,573 | OCaml, QCheck2 | the ring, view and HTTP properties |
| `ko_pane/` | 1,021 C in `pane.c`, 300 C in headers, 500 C tests | C | the pane process: pty, libghostty-vt, the ring writer, the frame codec |
| `ko_vt/` | 366 OCaml, 354 C stubs | OCaml, C | the mirror binding and the snapshot decoder |
| `ko_tui/` | 2,080 | OCaml on Mosaic and Matrix | the terminal client |
| `bin/ko.ml` | 215 | OCaml, cmdliner | the command table |
| `bench/` | 534 OCaml in `coordinator.ml`, 99 `mirror.ml`, 45 `usage.ml`, 692 Python, 600 C | | the benchmarks |
| `test_e2e_ko/` | 2,450 | Go | 44 tests: 28 drive the server over the socket or run `ko` (`TestFuzzVariablesDoNotReachTheBinary`), 16 `TestClient*` drive the client inside an outer kido-tmux |

### 1.2 Order

1. **The server** (`ko server`, `ko kill-server`, `ko api`, `ko
   version`) against the C `ko-pane`. Acceptance: the 28
   server tests of the Go suite pass.
2. **`ko-pane` in Rust** (decision 11), which replaces the C one under
   the Rust server. Acceptance: the same 28 tests, the ported C tests
   and fuzz targets, and the ingest rows of the benchmark table.
3. **The terminal client** (`ko`, the attach-or-start path, the
   mirror). Acceptance: the 16 client tests pass.
4. **Delete the OCaml ko and the C `ko-pane`** and move the docs. One
   implementation in one language.
5. **The e2e suite in Rust** (RE), then delete `test_e2e_ko/`.
6. **The serde wire** (RW): the shapes of 2.6 in one change.

Verus (decision 10) runs beside steps 2 and 3 once the Rust ring
writer exists (6.7).

### 1.3 `ko-pane` in Rust

`ko-pane` is rewritten in Rust in the main line (decision 11), after
the server passes against the C `ko-pane`. The order gives the Rust
server a known-good writer for its ring reader first; then the Rust
writer must pass the same Go tests under the same server. The C
`ko-pane` stays for the OCaml server's client tests until the cut
(4.2), and the cut deletes it.

What moves where:

| C | Rust |
|---|---|
| `ko_pane/protocol.h`, `ring.h` | the shared crate `ko_pane_wire`: `frame` (the kinds, `MAX_FRAME`, `MAX_DIMENSION`, the codec of both directions) and `ring` (the header layout, the mapping, the writer that `ko-pane` uses and the reader that the coordinator uses). One source for both processes; until the cut, one unit test also checks the constants against `ko_pane/protocol.h` |
| `pane.c` | the binary crate `ko_pane` (`ko_pane/Cargo.toml` and `ko_pane/src/` beside the C files until the cut): the loop, init, dispatch, the pty read into the ring, the dead marker, shutdown |
| `compress.h`, `snapshot_cut.h`, the 44 libghostty-vt calls | `ko_vt` over `ko_vt_sys`, shared with the mirror: the terminal with its callbacks (`WRITE_PTY`, title, pwd), the key, mouse, focus and paste encoders, the formatter, the snapshot encoder with the cut, the compression tick |
| `group_signal`, `struct group` | `ko_sys::pid`: the one signal module of the tree. `Group::spawned(&Child)` is the only constructor that `ko-pane` has; it exists only for the child that `ko_sys::pty::spawn` returned after a successful `exec` |
| `openpty`, `fork`, `setsid`, `TIOCSCTTY`, `dup2`, `chdir`, `execve`, the close-on-exec start pipe | `ko_sys::pty`: `libc::openpty`, then its own `fork` and `execve`, as `pane.c` does: the child runs only async-signal-safe calls on memory prepared before the fork and reports a failed step and its errno through a close-on-exec pipe; EOF on the pipe means `exec` succeeded (decision 62) |
| `waitid(..., WNOWAIT)`, the final `waitpid` | `ko_sys::pid::peek_exit` (`waitid` with `WEXITED | WNOHANG | WNOWAIT`) and `reap`. `ko-pane` never calls `Child::wait` before its final group kill, so the zombie holds the pid and the group id, as row 2 requires |
| the `SIGCHLD` self-pipe, `SIGHUP` and `SIGTERM` flags | `ko_sys::signal`: `libc::sigaction` with a handler that only writes one byte to a pipe |
| the `poll(2)` loop over the control socket, the pty master and the signal pipe | `ko_pane/src/main.rs` over `ko_sys::event`, the loop that the server and the client use too (3.6) |
| `test_pane.c`, `test_compress.c` | Rust tests in `ko_pane` (drive the binary over a socketpair and a mapping, as `test_pane.c` does) and in `ko_vt` (the compression tick table) |
| `fuzz_frame.c`, `fuzz_control.c`, `ko_pane/fuzz/control/` | cargo-fuzz targets `frame` and `control` (6.4); the corpus moves to `fuzz/corpus/control/` in the same mode-byte format |

The C `ko-pane` of the reference already writes the ring through the
Pulse-extracted writer (`ko_pane/ring.h` includes
`ko_proofs/ko_ring_proved.h`; `ko_ring_attach` refuses a capacity
outside `KoRing_Inv_min_capacity` and `max_capacity`, 64 bytes to
1 GiB). The Rust writer of RP is unverified until RV lands, so RV
follows RP at once (7), and RP keeps the reference's capacity bounds
and room rule, tested against a pure model of the ring as the
reference's Monolith `ring` target does (6.4).

Size: about 1,300 lines of Rust, most of them in `ko_pane` and the
server half of `ko_vt`. The ring writer's proof is now Rust code
verified in place (6.7), so the C writer's trusted payload writes
leave the trusted base.

### 1.4 `ko_vt` and `ko_tui`

The client's mirror (`ko_vt`) becomes the Rust crate `ko_vt` over a
`ko_vt_sys` FFI crate (section 2.4). The two C helpers that the
mirror shares with `ko-pane` today, `compress.h` (62 lines) and
`snapshot_cut.h` (80 lines), are ported to Rust inside `ko_vt`, and
the Rust `ko-pane` uses the same code (1.3).

The client (`ko_tui`) loses Mosaic and Matrix. What they supply today,
and the Rust replacement:

| today | Rust |
|---|---|
| `Matrix_input.Parser`: CSI u and legacy keys, SGR 1006 mouse, focus, bracketed paste, DECRPM and DA1 replies, APC `_G` replies, split reads | `vte` tokenizes the bytes (2.2); `ko_tui/src/input.rs` translates its CSI, ESC, print and execute events into keys, mouse, focus, paste and replies, about 250 lines, with the P1.2 tests (one read with XTVERSION, kitty flags and DA1 gives no key event) |
| `Matrix.Terminal`: raw mode, size, the output writer | `ko_tui/src/tty.rs` on `libc::tcgetattr`, `tcsetattr`, `TIOCGWINSZ`, about 120 lines |
| `Mosaic.run`, `Cmd`, `Sub`, the loop and `SIGWINCH` | `ko_sys::event`, the loop of every ko process (3.5, 3.6); `SIGWINCH` through its signal pipe |
| `Matrix.Grid`, `Matrix.Text.find_wrap_pos`, `Ansi.Style.sgr_sequence` | the renderer already composes its own cells; width from `ko_vt`'s cells and a 60-line East Asian width table for the sidebar text; SGR emission is the 53-line differ, already own code |

P1.3 measured that Mosaic drew nothing and cost 600 us per echo
before that was removed, so nothing of value is lost.

## 2. Dependencies

The rule: no async runtime (decision 3). ko owns its I/O: one
readiness loop over `poll(2)` per process (3.6) and the HTTP/1.1
framing on top of a parser crate. Crates do the parts whose own code
would be a large or security-relevant surface: the HTTP head parser,
the WebSocket protocol, JSON, the terminal input tokenizer. `libc`
covers the OS calls. Facts from crates.io and the probes of 2.5, on
2026-11-01.

### 2.1 The four needs

**Event loop: own code, `ko_sys::event`** (decision 3), about 250
lines: a `poll(2)` set, interest per descriptor, the next deadline as
the timeout, and a self-pipe for signals. It is the model of the OCaml
server's own loop (`ko_server/event_loop.ml`, 68232448, which
replaced luv), used by `loop.ml` and `connection.ml`. The server,
`ko-pane` and the terminal client use the one module. `poll(2)` also
watches a pty master and a tty on macOS, which kqueue does not
(p1-mvp.md 6.1), so one loop serves all three processes.

**HTTP/1.1: httparse 1.10.1** (2025-03, no dependencies) parses
request heads in the server and response heads in the client. ko
writes the framing: the head limit, `Content-Length` bodies, `411` for
chunked, keep-alive and pipelining in order, response writing, the
`Origin` refusal (3.6). About 250 lines for the server and 120 for
the client.

**WebSocket: tungstenite 0.30.0** (2026-07-11, MSRV 1.85), its
synchronous core over the non-blocking socket, with the `handshake`
feature and no other.

| candidate | verdict |
|---|---|
| tungstenite 0.30.0 | **chosen** (decision 6). `WebSocket::from_partially_read(stream, read_buf, role, config)` takes the bytes that ko read past the head. Over a non-blocking stream, a `WouldBlock` returns to the loop as an error and the state machine resumes on the next call. `WebSocketConfig` has `max_message_size`, `max_frame_size`, `write_buffer_size`. `handshake::derive_accept_key` computes `Sec-WebSocket-Accept`. `protocol::frame::FrameHeader::format` writes a frame header into a buffer, and `Frame::format` masks the client's frames |
| fastwebsockets 0.10.0 | rejected: built on tokio's `AsyncRead`, so it needs a runtime |
| soketto 0.8.1 | rejected: built on `futures-io`, so it needs an executor |

The `handshake` feature adds `http`, `data-encoding` and `sha1` (10
packages with `sha1`'s tree, 2.5) for `derive_accept_key`. Without
it, ko would write SHA-1 and base64 itself; the feature is the
smaller risk.

**JSON: serde 1 with derive, and serde_json 1.**

| candidate | verdict |
|---|---|
| serde 1.0.229 and serde_json 1.0.154 (MSRV 1.71) | **chosen**. Every shape of protocol.md maps to an attribute or to one small macro (2.3). serde_json has a recursion limit of 128 by default, which bounds a hostile nested body |
| miniserde 0.1.46 | rejected: no enums with data, and the protocol is mostly such enums |
| nanoserde 0.2.1 | rejected: its own derive with a fixed enum encoding that is not the compact array form, and no validating conversion attribute |
| facet 0.46 (MSRV 1.92) | rejected: a reflection framework at 0.x that changes its API often |

### 2.2 The terminal client's input

**vte 0.15.0** (Alacritty, 2025-02, MSRV 1.62.1, deps `arrayvec` and
`memchr`) tokenizes the outer terminal's input (decision 4).

| candidate | verdict |
|---|---|
| vte 0.15.0 | **chosen**. A DEC parser state machine: CSI with private markers and `:` sub-parameters (kitty `CSI u`, SGR 1006 `CSI <`, DECRPM `CSI ? … $ y`, DA1), DCS replies (XTVERSION) through `hook`, `put`, `unhook`, and APC strings (`_G` replies) are swallowed. DEL arrives as `print('\x7f')`. `advance_until_terminated` stops at `CSI 200~`, so the paste body is copied raw to `CSI 201~`. vte has no Escape timeout; `input.rs` holds back a read that ends in a lone `ESC` and emits Escape after 50 ms. ko still writes the translation to keys (about 250 lines) |
| hand-written | rejected: about 500 lines |
| termwiz 0.23 | rejected: about 40 crates for a whole terminal library |
| crossterm 0.29 | rejected: its parser is private and owns the tty; it drops the DECRPM and DA1 replies that the client reads |
| anstyle 1.0 | not a parser; style types only, and the differ already writes SGR |

### 2.3 How the wire shapes map to serde

| shape (jsonkit today) | serde |
|---|---|
| a record | `#[derive(Serialize, Deserialize)]`; unknown fields are ignored by default, as in jsonkit |
| an option field omitted when `None` | `#[serde(default, skip_serializing_if = "Option::is_none")]`; an explicit `null` decodes as `None` |
| a field with a default (`ignore_size`, `env`, `history`) | `#[serde(default)]` |
| a renamed field (`to_` as `to`) | `#[serde(rename = "to")]` |
| a validating id (`pane_N`, `client_N`) | `#[serde(try_from = "String", into = "String")]` on the newtype; `TryFrom<String>` is the one validator |
| an enum with a payload variant (since RW, 2.6) | internal tagging, `#[serde(tag = "type")]`; until RW a `compact!` macro gave jsonkit's `["name", payload]` form |
| a closed set of names (`History`, key and mouse actions) | `#[serde(rename_all = "snake_case")]` on a unit enum gives `"none"`, `"all"`; jsonkit's lowercase `[@json.name]` |
| a decode error | `serde_json::Error`, caught only at an untrusted edge (an HTTP body, a WebSocket text message), mapped to `invalid` (400) |

A unit test per wire type round-trips the JSON that the OCaml codec
produces for the same value, captured once from `ko_server` with
`jsonkit`, so the two encoders agree byte for byte before R5 deletes
the OCaml one.

### 2.4 The whole table

| need | choice |
|---|---|
| the loop, timers, signals | `ko_sys::event` over `libc::poll`, a self-pipe for `SIGCHLD`, `SIGTERM`, `SIGHUP`, `SIGINT`, `SIGQUIT`, `SIGWINCH` (decision 3) |
| unix sockets | `std::os::unix::net` with `set_nonblocking`; `write_vectored` with `IoSlice`s that borrow the mapping is the `writev` from the ring |
| `SO_SNDBUF`, `SO_RCVBUF`, peer credentials | `libc::setsockopt`, `getsockopt` (`LOCAL_PEERCRED`, `LOCAL_PEERPID`; Linux's `SO_PEERCRED` in RL) |
| HTTP/1.1 server and client | httparse for heads; own framing (3.6) |
| WebSocket | tungstenite (`handshake`) |
| JSON | serde (`derive`), serde_json |
| process spawn of `ko-pane` by the coordinator | `libc::posix_spawn` with file actions: `adddup2` of the control socket onto 0 and 1 and of the mapping onto 3; every fd the coordinator holds is `OwnedFd` and so close-on-exec |
| the program's pty and spawn in `ko-pane` | `libc::openpty`; own `fork` and `execve` with a close-on-exec report pipe; `waitid` with `WNOWAIT` (1.3) |
| shared memory | `libc::shm_open`, `shm_unlink`, `mmap` (Linux's `memfd_create` in RL); the header words as `AtomicU64::from_ptr` |
| process identity and signals | `libc::proc_pidinfo` (Linux's `/proc/<pid>/stat` in RL), `getsid`, `waitpid`; `libc::kill` only in `ko_sys::pid` |
| CLI | clap with derive, minimal features (decision 46) |
| terminal input | vte (2.2) and own translation |
| libghostty-vt FFI | `extern "C"` declarations generated once by the `bindgen` CLI and committed as `ko_vt_sys/src/bindings.rs`; `scripts/bindgen.sh` regenerates them; lint checks the recorded header hash against the ghostty pin |
| the zig build | `ko_vt_sys/build.rs` runs `zig build` with the flags of `ko_vt/dune` and links `ghostty-vt` and the C++ runtime; zig comes from PATH, installed by the reference's `scripts/install-zig.sh` (the version of Ghostty's `build.zig.zon`, checked by SHA-256) |
| terminfo | `ko_vt/dune`'s rules (`zig run`, `tic`) until R5; then the Makefile |
| property tests, interleavings | `proptest`, `loom` (dev-dependencies, decision 9) |
| fuzzing | `cargo-fuzz` with `libfuzzer-sys` and `arbitrary`, in `fuzz/` |
| specs and proofs | Verus: `vstd` and its macro crates as dependencies of `ko_pane_wire` (6.7); the verifier is a pinned release archive |
| Miri | a toolchain component (6.6) |

### 2.5 The cost of the set

Measured on 2026-11-01 with cargo 1.99.1 on arm64 macOS, in scratch
probes whose `main` uses each crate (httparse's `Request::parse`,
tungstenite's `from_partially_read`, `read`, `FrameHeader::format`
and `derive_accept_key`, serde derives, vte):

| set | compiled packages | `Cargo.lock` | release binary, stripped |
|---|---|---|---|
| `libc` only | 1 | 1 | 0.34 MB |
| `libc`, `httparse`, `tungstenite` without features, `serde`, `serde_json`, `vte` | 25 | 27 | 0.48 MB |
| the same with tungstenite's `handshake` (**chosen**) | 35 | 36 | 0.54 MB |
| the chosen set with `vstd` (6.7) | 46 | 48 | 0.54 MB (no exec code of `vstd` is called) |

- **The direct crates (6)**: `libc`, `httparse`, `tungstenite`,
  `serde`, `serde_json`, `vte`; `vstd` in the verified crates.
- **The 35 compiled packages**: the six; tungstenite's `bytes`,
  `log`, `thiserror`, `thiserror-impl`, `rand`, `rand_core`,
  `chacha20`, `getrandom`, `cfg-if`, and with `handshake` `http`,
  `data-encoding`, `sha1`, `digest`, `crypto-common`, `hybrid-array`,
  `typenum`, `block-buffer`, `const-oid`, `cpufeatures`; serde's
  `serde_core`, `serde_derive`, `proc-macro2`, `quote`, `syn`,
  `unicode-ident`; serde_json's `itoa`, `memchr`, `zmij`; vte's
  `arrayvec`.
- `vstd` adds 11: `vstd`, `verus_builtin`, `verus_builtin_macros`,
  `verus_state_machines_macros`, `verus_syn`, `verus_prettyplease`,
  `synstructure`, `convert_case`, `indexmap`, `hashbrown`,
  `equivalent`.
- tungstenite's `rand` tree (5 crates) exists only to mask client
  frames; ko's client masks with it, the server never does.
- **MSRV**: 1.85 (tungstenite, rand); proptest needs 1.88. The pin is
  1.99.1 (4.3).
- **Maintenance**: serde and serde_json released within the last four
  months, tungstenite in July 2026, httparse in March 2025 (stable,
  used by hyper), vte in February 2025, maintained with Alacritty.
- **Unsafe surface**: httparse (SIMD), bytes, tungstenite (the mask
  XOR, aligned to `u32`), vte (UTF-8 decoding), serde_json (little).
  ko's own `unsafe` stays in four places (3.4).
- **Measured in R0** (2026-11-01, cargo 1.99.1, arm64 macOS, the
  workspace's real `Cargo.lock` without `vstd` and `fuzz/`):
  `Cargo.lock` has 98 packages, 7 of them ko's. The other 91 include
  the `proptest` and `loom` trees and Windows-only packages that
  never compile on macOS. A release build compiles 43 packages: 7 of
  ko's and 36 others. Stripped release sizes: the skeleton `ko` 341,960 bytes; the
  `decode` example, which links libghostty-vt, 1,672,760 bytes. A
  clean release build takes 66 to 68 s, most of it the zig build of
  libghostty-vt. Every profile shares one zig cache, so `cargo test`
  and `cargo clippy` do not compile that library again.
- **Measured in R2** (2026-11-01, the same machine), clap with the
  features of decision 46 adds 6 packages: `clap`, `clap_builder`,
  `clap_derive`, `clap_lex`, `anstyle` and `heck`. `Cargo.lock` grows
  from 98 to 104 packages, and a release build of the binaries and the
  `decode` example compiles 48 packages (7 of them ko's) in place of
  42. Before review, the stripped `ko` with R2's four commands was
  1,083,880 bytes with clap and 830,392 bytes with a scratch
  hand-written parser: clap adds 253,488 bytes, 31 percent. After
  review, the stripped `ko` is 1,067,128 bytes.
- **Supply chain**: `scripts/lint.sh` compares the package names in
  `Cargo.lock` with the committed list `scripts/crates.txt`. A new
  transitive crate fails lint until the same commit adds it to the
  list, so every new crate is visible in review.

The bindgen policy and the `ko-pane` binary are decisions 12 and 17.

### 2.6 Wire shapes that RW changes

Decision 25. R0 to RE keep the wire of `ko_server/protocol.ml` and
`ko_server/config.ml` byte for byte: the Go suite and the OCaml runs
of 4.2 read it. RW (7) then changes, in one commit, every shape that
serde cannot derive.

**The rule: internal tagging, `#[serde(tag = "type", rename_all =
"snake_case")]`, on every enum with a payload variant.** A message is
then one flat object, and a reader dispatches on one key. That is what
`bench/client.py`, a browser client or `jq` reads most easily. Adjacent
tagging (`{"type": ..., "value": ...}`) would accept every payload
without a change, but it puts a struct payload one level down, and
most of ko's payloads are structs. No ko record has a field named
`type`, so the tag never clashes with a field.

Internal tagging accepts unit variants (`{"type": "disabled"}`) and
struct payloads, whose fields go beside the tag. It refuses three
payload kinds, and each gets one fix:

- **A primitive, a list or an id** (`Exited of int`, `Text of string`,
  `Topology of row list`): the variant becomes a struct variant with
  one named field. The field name is the noun of the value, listed in
  the table.
- **An enum**, which would also carry `type` (`Input of input`): a
  struct variant with one named field, so the inner tag is one level
  down.
- **The error body**: `error_kind` is `#[serde(flatten)]` into `error`
  with the tag `kind`, the field name of today. So a refusal is one
  object, `{"kind": "protocol_mismatch", "protocol": ..., "vt": ...,
  "build": ..., "message": ...}`, and a client of either major reads
  `kind` and `message` where they were.

An enum whose variants are all units stays a JSON string through
`rename_all`; that is jsonkit's form today, so those seven enums do
not change. serde decodes an internally tagged enum through its
buffered `Content` value, which allocates. That is acceptable, because
the JSON is the control path, not a ring record (decision 16 counts
records).

RW applied this rule to the ten enums with a payload variant;
`ko_server/src/protocol.rs` and its wire tests now define every shape.
The other codecs of the plan stay as they are: the
validating ids (`try_from = "String"`, a real rule), the screen query
string (not JSON), the binary record header (protocol.md 9, not
JSON), and `GET /version` and `ko version`, whose shape protocol.md 2
freezes across versions.

## 3. Architecture in Rust

### 3.1 Workspace

One cargo workspace at the repo root (`Cargo.toml`, `Cargo.lock`,
`rust-toolchain.toml`, `rustfmt.toml`, `clippy.toml`). `target/` is
ignored by git. dune keeps building kido from the same root; the two
do not share files. A package has the name of its directory, with
the underscore, so there is one spelling.

    ko_sys/        the libc calls that the crates do not cover: pid (Pid,
                   Group, the only kill), pty (openpty and the program's
                   spawn), event (the poll(2) loop of every process),
                   sock (SO_SNDBUF, SO_RCVBUF, peer uid and pid),
                   signal (the self-pipe),
                   spawn of ko-pane, Mapping (mmap and shared memory),
                   process identity, waitid
                   and waitpid, the monotonic clock, retry on EINTR
    ko_pane_wire/  shared by both processes: frame (kinds, limits, the
                   codec) and ring (layout, mapping, Writer, Reader, the
                   handshake), verified with Verus (6.7)
    ko_vt_sys/     the libghostty-vt bindings and build.rs (zig)
    ko_vt/         the safe libghostty-vt API for the mirror and for
                   ko-pane: Terminal with its callbacks, snapshot encoder
                   with the cut, decoder, render state, formatter,
                   encoders, scroll, the compression tick
    ko_pane/       the binary ko-pane (Cargo.toml and src/ beside the C
                   files, which the cut deletes)
    ko_server/     the coordinator library
    ko_tui/        the terminal client library
    ko/            the binary ko: src/main.rs
    ko_bench/      the benchmark binary (the port of bench/coordinator.ml,
                   mirror.ml and usage.ml); bench/*.c and client.py stay
    fuzz/          the cargo-fuzz crate, outside the default members
    ko_proofs/     the reference's F*/Pulse proofs, read as the specs
                   for Verus (decision 111)

### 3.2 Module map

| OCaml | Rust | notes |
|---|---|---|
| `ko_server/ring.ml`, `mem.ml`, the ring stubs; `ko_pane/ring.h`, `protocol.h` | `ko_pane_wire/src/ring.rs`, `frame.rs` | positions and offsets are types (3.3); reads are `u64::from_le_bytes` on validated slices |
| `pid.ml`, `pane.c`'s `group_signal` | `ko_sys/src/pid.rs` | the only file with `libc::kill` |
| `ko_pane/pane.c`, `compress.h`, `snapshot_cut.h`, `buffer.h`, `pixels.h`, `now.h` | `ko_pane/src/` (`run.rs`: the loop; `pane.rs`: init, dispatch, the pty reads into the ring, the dead marker, the shutdown; `io.rs`: the control socket, the output, the ring room and the nested wait; `control.rs`: the `control` fuzz entry), `ko_vt/src/` (`compress.rs`, `cut.rs`, the encoders), `ko_sys` (pty, signal, poll, the clock) | 1.3 |
| `test_pane.c`, `test_compress.c`, `fuzz_frame.c`, `fuzz_control.c` | `ko_pane/tests/pane.rs`, `ko_vt` unit tests, `fuzz/fuzz_targets/{frame,control}.rs` | |
| `pane_proc.ml` | `ko_server/src/pane_proc.rs` | the request table, the life variant, over `ko_pane_wire::frame`; the control socket is a source of the loop, read into a reused buffer |
| `pane.ml`, `panes.ml` | `pane.rs`, `panes.rs` | |
| `view.ml` | `view.rs` | `decide` stays a pure function with its table test |
| `connection.ml` (the write queue, the batch, the record write, the ping, the head limit) | `conn.rs` (the `Phase` state machine of 3.6, the read buffer, the write queue, the batch, the record write), `link.rs` (the WebSocket phase and its ping) | the model of `connection.ml`, with `poll(2)` in place of libuv |
| `ws.ml`, `sha1.ml`, httpun-ws | `ws.rs`: the tungstenite adapter (`Io`, 3.6) and `record_header` over `FrameHeader::format` | no own frame parser, SHA-1 or base64 |
| `http.ml`, httpun | `http.rs` (the head reader over httparse, the head limit, `Content-Length` bodies, the response writer, the client's request writer and response reader), `router.rs` (the dispatch, the version and `Origin` checks, `411`, the 101 response) | routes stay in `protocol.rs` as `Route` |
| `protocol.ml`, `ids.ml` | `protocol.rs` (serde derives, internally tagged since RW, 2.6), `ids.rs` | |
| `client.ml`, `state.ml` | `client.rs`, `state.rs` | |
| `config.ml` | `config.rs` | |
| `loop.ml`, `uv.ml`, `native_stubs.c` | `ko_sys::event` (the loop), `ko_server/src/server.rs` (the listener, the uid check, the output tick, `SIGCHLD`, `SIGTERM`) | |
| `ko_server/fuzz/*` | `#[cfg(test)]` proptest modules in `ring.rs`, `view.rs`, `router.rs`; the harness of `fuzz_view.ml` in `ko_server/src/harness.rs` under `cfg(test)`; byte-level targets in `fuzz/` | |
| `bin/ko.ml` | `ko/src/main.rs`, `cli.rs` | |
| `ko_vt/ko_vt.ml`, `ko_vt_stubs.c`, `decode.ml` | `ko_vt/src/lib.rs`, `ko_vt/examples/decode.rs` | the example serves only the Go suite and goes in RE |
| `ko_tui/{client,mirror,wire,renderer,differ,sidebar,input,modes,tty,launch,api}.ml` | the same names under `ko_tui/src/` | `wire.rs` is the client side of `http.rs` and tungstenite with the client role; `tty.rs` replaces the Matrix backend |
| `bench/coordinator.ml`, `mirror.ml`, `usage.ml`, `bench_terminal.ml` | `ko_bench/src/` | the modes `throughput`, `flood`, `latency`, `snapshot`, `cpu-check` of the reference keep their names and output lines, so `bench/run.sh`, `baselines.sh` and `flood.sh` change only the executable path |

### 3.3 Types that make illegal states unrepresentable

- `Pid` is a newtype over `i32` with a private field. `Pid::new`
  returns `None` for a value of 1 or less, above `i32::MAX`, the
  process's own pid or its own process group. `Group { leader: Pid,
  start: u64 }` has one public constructor, `Group::verify(parent, pid)`,
  which returns `Verdict::{Child(Group), Gone, Foreign}` from the OS
  check. `Group::signal` loads the identity again and signals only
  when the start time and the group id still match. This is `pid.ml`
  as it is. `ko-pane`'s program is the one value that
  `ko_sys::pty::spawn` returns after `exec`: it owns the child, its
  group signal, the exit check and the reap, and it is not `Copy`, so
  no group signal can follow the reap (RP).
- The ring has two integer types: `Pos`, a position in the record
  stream including headers (what the ring's `head`, `tail`, `read`
  and a view's cursor hold), and `Offset`, a pty byte offset (what a
  record header, a marker and the wire carry). They do not add to
  each other. `Ring::reachable(pos) -> Reach::{Behind, At(Pos)}`
  replaces the `int option`.
- `RecordKind::{Bytes, Marker, Slice, Pad}`; `Marker::{Resize(Size),
  Dead(Dead)}`; `Slice { first, last, screen }`.
- `Size { cols: Dim, rows: Dim, cell_px: Option<CellPx> }` in
  `ko_pane_wire::frame` (decision 35), where
  `Dim` is built only from 1 to `KO_MAX_DIMENSION` and `CellPx`
  from 1 to 65535. A hello, a size and a resize carry a `Size`, so
  the 4096 cap has one place.
- `PaneId(u64)` and `ClientId(u64)` with `Display` as `pane_N` and a
  validating `FromStr`; the JSON codec calls them.
- `view::State::{Live { cursor, history }, Snapshotting(Snapshot),
  Closed}` and `Decision::{Resume, Snapshot(History), Skip}`, as
  `view.ml`.
- `conn::Phase::{Head, Body, Handling, Ws(Link), Closing}` (3.6) and
  `conn::Written::{Accepted, Queued, Blocked, Closed}`.
- `pane_proc::Life::{Open, Closed, Reaped}`, `Claim::{Awaiting,
  Reported(Option<Group>)}`, `Reply::{Snapshot(..), Screen(..),
  Paste(..)}`.
- `ErrorKind` with its status code in one `fn status`.
- `History::{None, All}`, `Images::{None}`, `Cause::{Exited(i32),
  Signaled(i32), Failed(String)}`.
- `Mono(u64)` for nanoseconds of the monotonic clock on the wire (a
  death's `at`, a frame's time). The loop's deadlines are
  `std::time::Instant`, which is monotonic too; no process reads the
  wall clock for a timer.
- File descriptors are `std::os::fd::OwnedFd` and `BorrowedFd`. No
  raw `i32` crosses a module boundary.

### 3.4 Unsafe boundaries

Every `unsafe` block has a `// SAFETY:` line, which is the one
comment kind this plan adds to the rules (it is a verified external
constraint, and clippy's `undocumented_unsafe_blocks` lint requires
it). `unsafe` is permitted in four places (the three below and
`ko_vt`, the safe wrapper over `ko_vt_sys`, decision 28) and denied
elsewhere through `[workspace.lints]`, including all of `ko_pane`:

The crates' own `unsafe` is listed in 2.5; ko does not audit it
beyond choosing widely used crates and running Miri on its own
modules (6.6).

1. **`ko_sys`**: each libc call is wrapped in one safe function with
   typed arguments (`BorrowedFd`, `Pid`, `Duration`) and a `Result`.
   `retry` loops on `EINTR` around every call that can return it.
   `Mapping` owns the `mmap` and unmaps on drop. Between `fork` and
   `execve`, `pty::spawn`'s child calls only async-signal-safe
   functions; it allocates nothing and takes no lock. The signal handler only writes one byte to its pipe.
2. **`ko_vt_sys`**: the generated declarations. `ko_vt` wraps each in
   a safe method on `Terminal`, `Decoder`, `RenderState`,
   `Formatter`. A callback from libghostty-vt into Rust runs inside
   the call that wrote; it must not unwind across the FFI, so
   callbacks only push to a `Vec` on the terminal's state and never
   call back into the terminal.
3. **`ko_pane_wire::ring::mapping`**, a submodule that holds every
   raw access of both the writer and the reader: the header's `capacity`, `head`, `tail`, `read` are
   `&AtomicU64` from `AtomicU64::from_ptr` on the mapping; all loads
   and stores are `SeqCst` (section 5, row 7). A record's bytes are a
   `&[u8]` built with `slice::from_raw_parts` only after the record's
   header passed the length check against the capacity and the
   loaded head. The invariant that makes this sound is the protocol's:
   `ko-pane` writes only at or above `head` and below `tail +
   capacity`, so bytes between `tail` and the head that the reader
   loaded do not change until the reader stores a new `tail`. The
   `Ring` type keeps the loaded head in a field and hands out slices
   only below it. The writer gets a `&mut [u8]` only for its room,
   `[head, tail + capacity)`, before the commit. The rest of
   `ring.rs` (`available`, `put_record`, `advance`, `resume`,
   `end_offset`, the record walk) is safe code over `mapping`'s
   slices, and Verus verifies it (6.7); the `mapping` functions are its
   `external_body` trusted base. Miri and loom test this module with
   an in-memory backing (section 6).

Atomics elsewhere: none. The client's compressor thread shares the
mirror under a `Mutex`, as the OCaml client does.

### 3.5 Threads

Every process is one thread that runs `ko_sys::event` (3.6), with one
exception: the terminal client's mirror compressor.

| process | thread | what it watches |
|---|---|---|
| `ko server` (the coordinator) | the loop | the listener, every connection, every pane's control socket, the signal pipe; deadlines: the 2 ms output tick while a pane is busy, each WebSocket's ping, the 500 ms shutdown grace |
| `ko-pane` | the loop | the control socket, the pty master, the signal pipe; deadline: the compression tick (`ko_vt::compress`) |
| `ko` (the terminal client) | the loop | stdin (a tty, which `poll(2)` watches on macOS), the `/client` socket, the shown view's socket, the signal pipe (`SIGWINCH`, `SIGHUP`, `SIGTERM`, `SIGINT`, `SIGQUIT`, and `SIGCHLD` for the pager, which runs while the loop keeps the links and stops reading stdin and painting); deadlines: the 8 ms paint pacing, the 150 ms synchronized-output hold, the 50 ms Escape timeout, the 40 s receive watchdog (decision 89); plain requests block (decision 84) |
| `ko` (the terminal client) | the compressor | the mirror under its `Mutex` and a `Condvar`, as `ko_tui/mirror.ml` has (`ko_vt::Terminal` holds a `NonNull` and so is not `Send`; R4 adds `unsafe impl Send` with a SAFETY line that it checks against libghostty-vt's threading rules; the `Mutex` serializes every call); it does CPU work only (`ghostty_terminal_compress` steps of about 1 ms) and never wakes the loop (decision 85) |

The OCaml client's view reader thread is gone: the view socket is a
source of the loop, and the snapshot decoder reads from memory. The
loop appends each snapshot slice to the view's snapshot buffer. When
the READY record is in the buffer, the client decodes a screen
terminal from the bytes so far and shows it, as the OCaml client does
at READY (p1-mvp.md 6.4); when the last slice is in, it decodes the
whole buffer and swaps terminals. Both decodes read an in-memory
reader whose end is the decoder's EOF, so nothing blocks the loop
beyond the decode itself: P1.0 measured 6.7 ms for 6 MB of history,
under one 8 ms frame. Bytes and markers that arrive meanwhile queue
behind the snapshot, as today.

### 3.6 The loop and the connection state machines

**`ko_sys::event`**, shared by the three processes, about 250 lines.
Its reference is `ko_server/event_loop.ml` (454 lines with its tests)
and its model-based fuzz target `ko_server/fuzz/fuzz_loop.ml`; the
Rust module keeps their rules:

- **The descriptor table.** Each source has a token, an interest
  (`Idle`, `Read`, `Write`, `ReadWrite`) and a slot in one
  `Vec<libc::pollfd>`; `Idle` removes the slot by swapping in the
  last one, so `poll` sees only active descriptors. A turn copies the
  ready entries before it dispatches, so a source that a handler adds
  or removes does not hide the rest of the turn's batch.
- **Timers** are a binary heap of deadlines on the monotonic clock. A
  turn's timeout is the nearest deadline; with no deadline the
  timeout is infinite, so an idle process does not wake; a turn with
  neither sources nor deadlines returns at once. On Linux (RL),
  `ppoll` gives a nanosecond timeout; macOS rounds a timeout up to whole
  milliseconds, so a deadline 0.4 ms away never becomes a busy
  zero-timeout loop. `EINTR` from `poll` is a turn with no events.
- **Fair reads.** A readable source is read into the window that its
  owner gives (a reused buffer) at most 16 times per turn; a full
  window while the owner still reads is a protocol error that closes
  the source (the 16 KiB connection buffer, row 4). `Ok(0)` is the
  end, reported once; `WouldBlock` is "not ready" (row 3).
- **Signals**: a `sigaction` handler with `SA_RESTART` sets a pending
  flag for its signal and writes one byte to a non-blocking self-pipe;
  the loop drains the pipe and runs each signal whose flag it clears,
  once per wakeup. A signal that arrives while the pipe is full is not
  lost, because the flag is set first (the reference's test "a signal
  that arrives with a full pipe is not lost, and runs once per
  wakeup"). `SA_RESTART` is a convenience; every own call still
  retries `EINTR` (row 20).
- **The listener** accepts at most 16 connections per turn; `EMFILE`,
  `ENFILE`, `ENOBUFS` or `ENOMEM` sets its interest to `Idle` and arms
  a short retry deadline, so a descriptor shortage never spins;
  `ECONNABORTED` is skipped.
- **Back-pressure is the interest**: a source that must not be read
  loses `Read`; a source with queued output gains `Write` until the
  queue is empty.
- **No callbacks registered with the loop**: the owner (the server's
  `State`, `ko-pane`'s `Pane`, the client's `Client`) matches on the
  ready tokens and the due timers and calls its own handlers with
  `&mut self`. State is one struct per process; no `Rc<RefCell<..>>`.
  The reference's `Outbox` (a write queue of strings with a byte
  count and a vectored flush) becomes `conn::Queue`.

**The coordinator's connections** (`ko_server`), each a `Conn` with a
read buffer of 16 KiB, a write queue (`VecDeque<Vec<u8>>`, the 64 MiB
cap of row 11) and a state:

    enum Phase {
        Head { scanned: usize },                 // reading a request head
        Body { request: Head, left: usize },     // reading a Content-Length body
        Handling,                                // a body waits for its handler; IN off
        Ws(Link),                                // after the upgrade
        Closing,                                 // flush the queue, then close
    }

- **Accept.** `accept` on the listener, then `getsockopt` for the
  peer uid; another uid closes the stream before any byte is read
  (row 25). Then `SO_SNDBUF` 1 MiB, non-blocking, `IN` interest.
- **Head** (`http.rs`, about 250 lines with the response writer). The
  connection reads into its buffer and calls `httparse::Request::parse`
  over the unconsumed bytes with an array of 128 headers on the
  stack, and grows to a heap array of 4,096 only when httparse
  reports `TooManyHeaders`, so a head's byte count is the only limit,
  as in the OCaml server, whose test sends 4,000 headers. A head that
  is still `Partial` at 16,384 bytes of this request gets `431` with
  `connection: close` appended to the write queue, after any response
  already queued for an earlier pipelined request, then `Closing`
  (row 5). A `Transfer-Encoding` header gets `411` and `Closing`. A
  head with `Origin` gets `refused`. The version headers, `Ko-Client`
  and the route are checked here (`router.rs`).
- **Body.** `Content-Length` bytes up to 1 MiB are read into the
  request's body; more is `400` and `Closing`. While the handler has
  not taken a complete body (a pane request that waits for
  `ko-pane`), the connection is in `Handling` and loses `IN`, so a
  client that writes on blocks in its own socket (row 4). Pipelined
  requests wait in the buffer, are parsed after the response is
  queued, and are answered in order.
- **Responses.** A response is a status line, `content-length` or
  `transfer-encoding: chunked` (only for `/screen`, whose chunks
  arrive from `ko-pane` and are queued as they come), headers and
  the body, appended to the write queue. Keep-alive is the default; a
  client's half-close after a complete request still gets its reply.
- **The upgrade** (`/client`, `/panes/pane_N/view`): the head is
  checked for `Upgrade: websocket`, `Sec-WebSocket-Key` and version
  13; the 101 response with `derive_accept_key` is queued; the bytes
  past the head become `from_partially_read`'s prefix, and the phase
  becomes `Ws(Link)`.

**A `Link`** owns one tungstenite `WebSocket<ws::Io>` with
`write_buffer_size(0)`, `max_message_size(Some(1 MiB))` and
`max_frame_size(Some(1 MiB))`. `ws::Io` implements `Read` as the
prefix first, then the socket's non-blocking `read` (a `WouldBlock`
passes through), and `Write` as an append to the connection's queue,
which never blocks. So every byte that tungstenite writes (a text
message, a pong, a close with its reason) enters the one queue in
order, and only the connection writes the fd.

- **Reading.** On `IN`, the link calls `ws.read()` until `WouldBlock`.
  tungstenite returns every complete message already in its buffer
  before it reads the socket again (row 18). While a view's input
  waits for its pane, the link drops `IN` (row 4).
- **Text writes** (client events, view markers and skips, the close
  reason): `ws.send(Message::Text(..))` appends to the queue; the
  connection writes the queue with `write_vectored` over its `Vec`s
  and keeps `OUT` while it is not empty.
- **View records are written by the connection, not by tungstenite.**
  A view record is one binary frame whose payload is two pieces: the
  9-byte record header and the ring slice. A batch is up to 64 such
  frames in one `writev`. tungstenite's `Message::Binary` takes an
  owned `Bytes`, so each record would cost an allocation and a copy of
  every byte, which the 0-allocations-per-record target of section 7
  refuses. So the connection writes the frame header with
  `FrameHeader::format` into a stack buffer, puts header, record
  header and ring slice into `IoSlice`s, and calls `write_vectored`
  only while the queue is empty, as `Connection.available` does
  today. On a partial write it copies the unsent rest into the queue
  (row 12); on `WouldBlock` the view keeps only its cursor. No pending
  write references the ring, because a `write_vectored` call is over
  when it returns.
- **The ping**: each link's deadline is 30 s after its last received
  frame; at the deadline it sends a ping and sets the deadline 10 s
  later for the pong (protocol.md 1). An idle server's only deadlines
  are these.

**A pane's control socket** is a source of the same loop: on `IN` the
coordinator reads into the pane's reused buffer and parses frames in
place (`pane_proc.rs`). A `head` frame scans the ring and pumps the
pane's views at once, in the same turn. The 2 ms output tick is a
deadline that exists only while a pane is busy.

**The client side** (`ko_tui/wire.rs` and `ko api`, decision 7): one
HTTP/1.1 client of about 120 lines over the same `http.rs` writer and
`httparse::Response::parse`. `ko api` and `ko ssh` (S1) send one
request on a blocking socket with a 5 s deadline and read the
response; they need no loop. The terminal client's plain requests (create a
pane, delete a pane, `/screen` for the pager, streamed into the 0600
file) block, as `ko api` does (decision 84). Its two upgrades
(`/client` and the shown view) block until the 101, as the OCaml
`Wire.upgrade` does: the upgrade request is written, the 101 is parsed
with httparse, and the bytes past it go to `from_partially_read` with
`Role::Client`. Then the link becomes a source of the loop. The
client's frames are masked by tungstenite.

### 3.7 Errors

A library function returns `Result`. `std::io::Error` carries the OS
error (the `Unix_error` of today) and propagates with `?`. A failure
with a message to print is a `String` error that holds the message (R1).
Where callers distinguish cases, the module defines an enum
(`api::Error::{Websocket, NoServer, Failed(String)}` as `ko_tui/api.ml`
has). `Display` is implemented by hand; ko's own code uses no
`thiserror` and no `anyhow` (tungstenite uses `thiserror` inside).
httparse's, tungstenite's and serde_json's errors are mapped to
`ErrorKind` at the edge that received them.

## 4. Build integration

### 4.1 Make and the Go suite

`make build-ko` is the one entry point. It runs one `cargo build
--locked --release` of the binaries and the `decode` example (which
builds the zig library through `ko_vt_sys/build.rs` and links it into
`ko` and `ko-pane`), and assembles the installed layout. Until R5,
`dune build @install` builds the terminfo (`ko_vt/dune`) and the C
`ko-pane`, and `build-ko` copies both from dune's install tree; R5
moves the terminfo rule (`zig run`, `tic`) into the Makefile. From RP on, `ko-pane` is the Rust binary; before RP it is the
C one that `ko_pane/dune` builds:

    build/ko/bin/ko
    build/ko/bin/ko-pane
    build/ko/share/ko/terminfo/x/xterm-ghostty
    build/ko/share/ko/terminfo/78/xterm-ghostty

`Config::shipped` finds `ko-pane` beside `ko` and the terminfo at
`../share/ko/terminfo`, as `config.ml` does, so the layout is what the
server needs. `make install` copies `build/ko` under `PREFIX`.

The Go suite's `TestMain` (`test_e2e_ko/protocol_test.go`) sets
`buildDir` from `DUNE_BUILD_DIR` (default `_build`), runs `dune build
@install ko_vt/decode.exe`, and reads `<buildDir>/install/default/bin/ko`
and, in `decode()`, `<buildDir>/default/ko_vt/decode.exe`. The suite
has no variable for the binary. The edit (decision 14), in two steps:

- **R0**, while the OCaml client is still tested (4.2): `TestMain`
  reads `KO_BIN` and `KO_DECODE` from the environment, builds
  nothing and uses them; without both it fails its setup. The
  Makefile owns the defaults (decision 30), and `make e2e-ko` builds
  first. When the Rust server exists, `TestMain` gains the branch
  for neither: it runs `make build-ko`, which also builds the example
  (decision 29), and uses `build/ko/bin/ko` and
  `target/release/examples/decode`. `decode()` (`protocol_test.go`) calls
  the `KO_DECODE` path instead of `<buildDir>/default/ko_vt/decode.exe`,
  so `buildDir` goes. No test function changes.
- **R5**: the two variables go. `TestMain` runs the
  two builds and uses the two fixed paths. This is the whole suite
  edit. A suite that builds its subject cannot be unchanged across a
  build system change.

The reference's suite also gained `TestFuzzVariablesDoNotReachTheBinary`
(it runs `ko version` with `KO_FUZZ_*` and `KO_AFL_*` set to junk). The
Rust `ko` reads no fuzz variable at all (the fuzz crates read theirs),
so the test passes without a change, and the lint rule that kept those
variables inside `ko_server/fuzz_run.ml` becomes "only `fuzz/` and
the test modules read `KO_FUZZ_*`".

The `decode` example prints the same JSON line as `decode.ml`:
`sync`, `rows`, `screen`, `history`, with `--full`. It serves both
runs of 4.2, because both servers pin the same libghostty-vt. It is
not installed and not in `build/ko/bin`; RE deletes it, because the
Rust suite calls `ko_vt` directly.

**The build id and the vt revision.** `/version` and `ko version`
report `vt`, the ghostty pin that `ko_server/dune` reads with `git
ls-files -s third_party/ghostty`, and `build`, the dune-build-info
version that promotion substitutes (`unknown` in an unpromoted
binary). In Rust, `ko_server/build.rs` supplies both as compile-time
environment:

- `KO_VT`: `build.rs` runs the same `git ls-files -s
  third_party/ghostty`, fails the build unless the result is 40 hex
  characters (as the dune rule does), and emits
  `cargo:rustc-env=KO_VT=<revision>` with `rerun-if-changed` on
  `.gitmodules` and on the gitlink's file under
  `.git/modules/third_party/ghostty/HEAD`.
- `KO_BUILD`: `make build-ko` exports `KO_BUILD_ID=$(git describe
  --always --dirty)`; `build.rs` emits `cargo:rustc-env=KO_BUILD=`
  with that value, or `unknown` when the variable is unset, with
  `rerun-if-env-changed=KO_BUILD_ID`. A bare `cargo build` reports
  `unknown`, as `_build/default/bin/main.exe` does for kido.

Tests: Go `TestDefaultsAndPaneEnvironment` runs `ko version` and
checks that a pane's `TERM_PROGRAM_VERSION` equals its `build`; the
suite's `start` reads `vt` from `/version` and sends it as `Ko-Vt`,
so every other test fails if `vt` is not what the server checks;
`TestVersionAndOrigin` checks the mismatch replies. `scripts/lint.sh`
checks that the committed bindings' header hash matches the pin
(section 2), which ties `KO_VT` to the code that was built.

### 4.2 Stages in `scripts/verify.sh`

`make verify-ko` keeps its name and its PASS/FAIL lines:

| stage | runs |
|---|---|
| `build` | `make build-ko` |
| `unit-ko` | `make test-ko`: `cargo test --locked --workspace`, then the loom tests under `RUSTFLAGS=--cfg loom`, then the corpus replay tests of `fuzz/`. Until R5 also the C `ko_pane` tests and fuzz replays (`test-pane`, `test-compress`, `fuzz-frame`, `fuzz-control`) through Makefile rules, because the OCaml server's client tests still use the C `ko-pane` |
| `e2e-ko` | `make e2e-ko`, which sets `KO_BIN` and `KO_DECODE` (4.1) |
| `lint` | `make lint-ko`: `cargo fmt --check`, `cargo clippy --locked --workspace --all-targets -- -D warnings`, `scripts/lint.sh` (the signal grep, the package list `scripts/crates.txt`, the bindings hash, the `vstd` pin, the docs references), the TypeScript lint as today |
| `verus` | `make verus`: `cargo verus verify` on the verified crates (6.7); SKIP without the release archive, FAIL in CI |

From the Rust server's first passing run (R1 or R2) to the end of R4
(section 7; R0 runs it once, decision 30), `e2e-ko` runs the Go suite
twice, with the `KO_BIN` and `KO_DECODE` variables of 4.1 that
`verify.sh` sets per run. `verify.sh` holds the list of the 16
`TestClient*` functions of `client_test.go` once (among them
`TestClientHistoryAndAlternateScreen`, the reference's new name of
`TestClientHistoryAndTop`), as a regex
`$client` (not the prefix `TestClient`, which also matches
`TestClientGridLimit` and `TestClientCloseClosesItsViews`, two
server tests):

    KO_BIN=build/ko/bin/ko KO_DECODE=target/release/examples/decode \
      go test ./test_e2e_ko/ -count=1 -skip "$client"
    KO_BIN=${DUNE_BUILD_DIR:-_build}/install/default/bin/ko KO_DECODE=target/release/examples/decode \
      go test ./test_e2e_ko/ -count=1 -run "$client"

The `build` stage runs `dune build @install` beside `make build-ko`
in this period. The OCaml client starts its own server from its own
executable (`Launch.attach` passes `Fs.self`), so the client tests
cannot mix a Rust server with the OCaml client. R5 removes the second
run, the `dune build`, the regex and the two variables.

`make verify` (the kido suite) does not change. Only `make verify-ko`
changes, because CI's ko job and ko work use it.

### 4.3 Toolchain

Installation (decision 8): Homebrew's `rustup` formula.

    brew install rustup
    $(brew --prefix rustup)/bin/rustup toolchain install   # the toolchain of rust-toolchain.toml; rustup show installs nothing since rustup 1.28

The formula is keg-only: `rustup`, `cargo` and `rustc` are in
`/opt/homebrew/opt/rustup/bin`, not on PATH. ko does not ask the
user to change PATH. The **Makefile** is the one place that finds
cargo:

    RUSTUP_BIN := $(firstword $(wildcard $(HOMEBREW_PREFIX)/opt/rustup/bin /opt/homebrew/opt/rustup/bin /usr/local/opt/rustup/bin))
    export PATH := $(if $(RUSTUP_BIN),$(RUSTUP_BIN):)$(PATH)

It does not call `brew` (half a second per call). Every cargo
command in the repo runs through a Makefile target: `make build-ko`,
`make test-ko`, `make lint-ko`, `make verus`, `make fuzz`, `make
miri`. `scripts/verify.sh` calls those targets and never cargo
directly, and the Go suite's `TestMain` runs `make build-ko` (4.1),
so neither needs PATH. On a CI runner the directories do not exist
and the runner's own rustup on PATH is used.

`rust-toolchain.toml` pins `channel = "1.99.1"` with the components
`rustfmt` and `clippy`. 1.99.1 is the current stable, and it is also
the toolchain that Verus pins (`rust-toolchain.toml` of
`verus-lang/verus`, 2026-10-31), so one toolchain builds and verifies
ko. A bump moves with the Verus release (6.7) in one commit that says
why. The edition is 2024. `cargo-fuzz` and Miri need nightly; the pin
for them is `nightly-YYYY-MM-DD` in `scripts/fuzz.sh` and
`scripts/miri.sh`, not in the toolchain file, so stable builds never
see nightly.

`Cargo.lock` is committed. Every cargo invocation passes `--locked`.
No vendoring: CI has network, and `dune.lock` is not vendored either.
If the user wants builds with no network, `cargo vendor` into
`vendor/` with a `.cargo/config.toml` is a one-commit change later.

### 4.4 CI

The reference's CI already installs zig through
`scripts/install-zig.sh` (the release that Ghostty's `build.zig.zon`
names, checked by SHA-256, cached by its key) before anything builds,
and runs `make proofs` in a `proofs` job on Linux x86_64 and macOS
arm64. The `test` job gains, on the macOS runner only (decision 26), after the zig step:

- `rustup toolchain install` with `timeout-minutes: 5` (the runner images ship
  rustup; this installs the pinned toolchain from
  `rust-toolchain.toml`; no third-party action).
- `cargo fetch --locked` with `timeout-minutes: 5`, as e38b032d's `go
  mod download` step, so a stalled crates.io mirror fails in its own
  step.
- `actions/cache` on `~/.cargo/registry` and `~/.cargo/git`, keyed
  by OS and `Cargo.lock`; on the shared zig cache of libghostty-vt,
  keyed by OS, the ghostty pin and the zig release; not on `target/`,
  because an exact key never saves again; and on the Verus archive
  (452 MB for arm64 macOS, 1.4 GB unpacked), keyed by the release of
  `scripts/verus.sh`.
- The Verus archive fetch on a cache miss, a step of its own with
  `timeout-minutes: 10`; `scripts/verus.sh` calls `curl -fL
  --connect-timeout 15 --max-time 900`, as `scripts/install-zig.sh`
  and `scripts/install-fstar.sh` do.
- `KO_VERUS_REQUIRED=1`, so the `verus` stage fails instead of
  skipping.
- `make verify-ko` in place of the current `make e2e-ko` step, so
  CI runs the same stages as the user. The kido steps stay until
  migration.md's S8.

The deadlines of e38b032d stay as they are: the `test` job's
`timeout-minutes: 30`, the `proofs` job's 25, a 5 to 20 minute limit
on each install step, and apt's `Acquire::Retries "3"` with 30 s
timeouts (also in `scripts/ci-like/Dockerfile`). The `test` job's 30
minutes now covers the Rust build, the `verus` stage and, from R0 to
R4 and during RE, two e2e runs. No push happens before the end of
RL (decision 27); that first push measures the job and raises its
limit in the same change if the measured time is over two thirds of
it. Each job of `ko-nightly.yml` gets `timeout-minutes` at its budget
below plus 15 minutes.

For the Rust ko, Ubuntu needs `tic` (`ncurses-bin`, already
present) and zig (RL); macOS needs the same. The `proofs` job and `scripts/install-fstar.sh` stay while
the C `ko-pane` and the OCaml cores use extracted code, and R5 removes
them (7).

**The scheduled workflow is new.** Today `.github/workflows/` holds
only `ci.yml` and `website.yml`; nothing runs `make fuzz`. R3 adds
`ko-nightly.yml`, on `schedule` (daily) and `workflow_dispatch`, on
macOS (RL adds Ubuntu), with the nightly pin of `scripts/fuzz.sh`. Its
jobs and their time budgets:

| job | runs | about |
|---|---|---|
| fuzz | `make fuzz TARGET=t TIME=600` in one matrix job for each target of `scripts/fuzz.sh` (`frame`, `control`, `ring`, `loop`, `head`, `http`, `decode`, `frames`; R4 adds `client` and `ws`), all on cargo-fuzz | 60 min |
| miri | `scripts/miri.sh` (6.6) | 15 min |

A finding fails its job and uploads the artifact (the libFuzzer
crash file, the proptest regression, the Miri report). The fix lands
with its case in the fast path: a corpus file, a committed proptest
regression or a unit test, as AGENTS.md's fuzzing rule requires. The
workflow never changes a corpus; only `make fuzz MERGE=1` by hand
does.

## 5. Carry-over of hard-won fixes

Each row names the commit on `ko`, the invariant, where it lives in
Rust, and the test that pins it. "Go" names a test of `test_e2e_ko/`
that passes unchanged; "unit" is a `#[test]` ported from the OCaml
inline test of the same meaning; "property" is a proptest module;
"loom" is section 6.5.

| # | fix | commit | invariant | Rust home | test |
|---|---|---|---|---|---|
| 1 | `kill(-1)` from a frame's pid | 7c877215, b77d3ac2 | no signal to a pid that the coordinator did not verify; `Pid` refuses 0, 1, negatives, values over `i32::MAX`, the own pid and the own group; a `Group` exists only after the OS showed the pid is the spawned `ko-pane`'s child and leads its own group and session; `Group::signal` checks the start time again; `ESRCH` and `EPERM` are not errors (ed21d4a4) | `ko_sys/src/pid.rs`, the only `libc::kill`, used by the coordinator and by `ko-pane` | unit: the three `pid.ml` tests (refusals and a child; the `judge` table; the tampered start); Go `TestPaneProcessCrashKillsProgram`, `TestSIGTERMKillsPrograms`, `TestPaneProcessFailure`; lint (6.8) |
| 2 | `ko-pane` sends `ready` only after `exec`, holds the zombie with `WNOWAIT`, `SIGKILL`s the group 250 ms after `SIGHUP` | 7c877215, b77d3ac2, ad858e14 | the pid and group id cannot be reused while `ko-pane` lives; `ready` names a program that has run `setsid` and `exec` | `ko_sys::pty::spawn` (EOF on its report pipe means `exec` succeeded; the child runs `setsid` first), `ko_sys::pid::peek_exit` (`waitid` with `WNOWAIT`), `ko_pane/src/pane.rs` (the `ready` after spawn unless the program already exited; the shutdown: `SIGHUP` to the group, 250 ms, `SIGKILL`, then the reap) | Rust tests in `ko_pane/tests/pane.rs` ported from `test_pane.c` (the held zombie still answers `waitid` and `kill(pid, 0)`); Go `TestPaneProcessCrashKillsProgram`, `TestSIGTERMKillsPrograms` |
| 3 | a 0-byte read after a full buffer is not a close | a24ce22c | a read that returns `WouldBlock` after one that filled the buffer is "not ready"; only `Ok(0)` is EOF | `conn.rs`, `pane_proc.rs` and `ws::Io`: each source reads until `WouldBlock` and treats only `Ok(0)` as EOF | unit: a socketpair filled to exactly the buffer size delivers every byte and no close (from `uv.ml`); the control-frame test with a 64 KiB `screen` reply |
| 4 | read back-pressure | 7b5422a4 | no byte is read from a connection while its request body or its WebSocket message waits for a handler; the read buffer is 16 KiB and never holds unread bytes beyond it; a client that writes without end blocks in its socket | `conn.rs`: the `Handling` phase and a waiting view input drop `POLLIN` from the interest (3.6) | unit: the `connection.ml` test "bytes that arrive while the runtime yields reading are kept"; Go `TestHostileClientsDoNotAffectOthers` (the `Content-Length: 99999999999` case) |
| 5 | the 16 KiB head limit | 616cdef2 | a request head over 16,384 bytes, across reads, gets `431` through the write queue after any earlier pipelined response, then the connection closes; a chunked request gets `411`; the heap does not grow with the head; `/client` and upgrades pass through the same limit | `http.rs` (the byte count per request head, httparse with 128 stack headers and up to 4,096 on the heap), `conn.rs` (the queue order) | unit: the three `connection.ml` tests (the limit as a whole, the boundary at 16,383, 16,384 and 16,385 bytes and the 7-byte split; the heap; the pipelined 431 after a 3 MB response); Go hostile test (20,000 headers, chunked); fuzz `http` and `head` |
| 6 | the 4096 grid cap | 7c877215 | `cols` and `rows` are 1 to `KO_MAX_DIMENSION` in a hello, a size and a resize; `ko-pane` refuses the same | `ko_pane_wire::frame::Dim` (decision 35); `pane.c` | unit: the `protocol.ml` size test; Go `TestClientGridLimit` |
| 7 | the seq_cst wakeup handshake | protocol.md 14; the `read` index of P1.1 (0d71779f, p1-mvp.md 6.3) | the writer stores `head` then loads `read`; the reader stores `read` then, on its next turn, loads `head`; both as sequentially consistent atomics, because with release and acquire alone the two store-then-load pairs can both miss and a wakeup is lost. GenMC shows it: `ko_pane/genmc/wakeup_mc.c` (the store-buffering handshake over the extracted ring `ko_proofs/ko_ring_proved.h`; `ko_pane/genmc/run.sh sc|acqrel wakeup`) finds a lost wakeup with `ko_pane/genmc/acqrel/ko_atomic.h` and none with `ko_proofs/ko_atomic.h`, and `ko_pane/genmc/ring_mc.c` (a 64-byte ring, 5 records) finds no error in 17,519 executions | `ko_pane_wire::ring` (writer and reader): every header access is `SeqCst`; no other ordering exists in the crate (clippy cannot check this, lint greps for `Ordering::` and accepts only `SeqCst`; the loom model uses its own orderings, so this lint is the only guard of `ring/mapping.rs`'s orderings) | loom (6.5): replays of `wakeup_mc.c` (`SeqCst` passes, the `AcqRel` twin is `#[should_panic]`) and `ring_mc.c`; Verus (6.7): the handshake as a state-machine property; bench `latency` (section 7) |
| 8 | `tail` never passes undelivered snapshot slices | cd74d3c1 | retention keeps every slice of a snapshot whose `snapshot_done` has not arrived, and a finished snapshot's cursor until its done frame | `pane_proc.rs` (`deliver`, `scan`) | unit: "the tail never passes snapshot slices that were not delivered", "a finished snapshot keeps its cursor in the ring until its snapshot_done" |
| 9 | retention and a blocked view | 09ba9cd4 | a view's cursor is a ring position; a cursor behind the tail gets a snapshot; `advance` retains at most half a ring behind the head | `ring.rs` (`advance`, `reachable`), `view.rs` | property: the ring contract (the port of `fuzz_ring.ml`: writes, advances, resumes, the `invariants`); Go `TestStalledViewLearnsResizeAfterRingRetention` |
| 10 | resume by offset | 09ba9cd4 | a resume replays no marker from before the offset; bytes resume from the first record that ends after the offset | `ring.rs` (`resume`) | property (replay in `fuzz_ring`); Go `TestResumeSkipsResizeMarkersBeforeTheOffset`, `TestViewResumeResizeAndInput` |
| 11 | one snapshot per view, resync coalesces, the queue cap | 09ba9cd4 | a view holds one snapshot at a time; a resync during one waits and the last request wins; a link with more than 64 MiB queued is closed | `view.rs`, `conn.rs` (the queue refuses a write past the cap, and the connection closes) | unit: "a view that never reads is closed before its queue grows without bound"; Go `TestFullSnapshotSlowReader` |
| 12 | no pending write references the ring; a partial `writev` copies the rest | 0d71779f, p1-mvp.md 6.3 | on `WouldBlock` the view keeps only its cursor; the unsent tail of a partially written frame is copied into the queue; a snapshot slice the socket does not take is copied | `conn.rs` (`record`, `batch_send` over `write_vectored`; 3.6), never through tungstenite | unit: "a partial write inside the last batch record is flushed once the reader drains"; P1.0's measurement is the reason (a stalled reader blocked the pane 283 ms) |
| 13 | a partial write at the end of a batch stalled the view | cd74d3c1 | after a partial batch write the view marks itself blocked and waits for writable | `view.rs` (`flush_batch`) | the unit test of row 12; property: the view harness (6.3) |
| 14 | two views snapshot each other forever | 7c877215 | an idle view never takes a snapshot because another view took one | `view.rs`, `pane_proc.rs` | property harness explicit case "two views with a large history do not snapshot each other forever" and the `check` step's snapshot-count assertion |
| 15 | a snapshot is never restarted or downgraded because the socket blocked | 0d71779f | | `view.rs` | property harness (`apply_record`: "snapshot restarted inside a snapshot" fails) |
| 16 | a resume threshold counted only after a block | P1.0 (bde368f6), `view.ml` | the 64 KiB skip rule applies only to the backlog after a blocked write, never to a live view's record | `view::decide` | unit: the `decide` table; Go `TestStalledViewSkips` |
| 17 | death has one timestamp; dead only on the control frame | cd74d3c1, db5b2536 | the `at` of the ring marker and the `dead` frame are one value; the pane becomes dead on the frame, after the title and pwd frames that preceded it | `pane_proc.rs` | Go `TestDeathHasOneTimestamp`, `TestPaneDeadSnapshot` |
| 18 | queued WebSocket frames inside one read | ed21d4a4, p1-mvp.md 6.4 | after one socket read, every complete frame in the buffer is processed before the next read | `link.rs`: `ws.read()` until `WouldBlock`; tungstenite returns buffered messages without I/O | Go `TestViewInputFramesInOneWrite`, `TestViewInputFrameSplitAcrossWrites`; unit: two frames in one write and one frame across two writes, over `ws::Io` |
| 19 | shifted characters under kitty flags | 76ea5374 | Shift counts as consumed when the text is one printable character other than the unshifted codepoint and no Ctrl, Alt or Super; Option is Alt; a CSI u key without text gets its shifted text in the client | `ko_vt`'s key encoder wrapper (`shift_made_text`, `MACOS_OPTION_AS_ALT`) used by `ko_pane/src/input.rs`; `ko_tui/input.rs` | unit: `shift_made_text`'s table; Go `TestClientLegacyShiftedKey`, `TestClientNvimNormalModeShiftedKeys` |
| 20 | `EINTR` | a94fd3a0 (the test), the stubs' loops | a signal during a pane's screen reply does not fail the pane; no syscall fails on `EINTR` | `ko_sys::event`: an `EINTR` from `poll` is a turn with no events; `ko_sys::retry` around `read`, `write`, `waitpid`, `posix_spawn`, `shm_open` | property harness explicit case "a signal while a screen reply waits for its pipe does not fail the pane"; unit: `retry` and the loop return after a `SIGCHLD` |
| 21 | `kill-server` by peer pid | 66e75d30 | `ko kill-server` reads the peer pid and uid from the socket, refuses another user, sends `SIGTERM` through `Pid`, waits 5 s for the process and the socket | `ko_tui/launch.rs`, `ko_sys::peer` | Go `TestKillServer`, `TestKillServerSignalsByPeerPID` |
| 22 | `SIGTERM` ends the programs | ad858e14, 3.1 of p1-mvp.md | `SIGHUP` to every pane, 500 ms, `SIGKILL`; a failed pane process gets its program group killed through the verified `Group` | `server.rs`, `pane_proc.rs` | Go `TestSIGTERMKillsPrograms`, `TestPaneProcessCrashKillsProgram` |
| 23 | the missing cwd is `400`, not `500`; chunked is `411` | 7c877215 | | `panes.rs`, `http.rs` | property: "bad bodies are answered with 400 or 411, not a crash or a 500" |
| 24 | `Origin` refused; version headers; `/version` exempt | 0d71779f | | `router.rs` | Go `TestVersionAndOrigin` |
| 25 | the peer uid check on accept | design.md 4.1 | a connection from another uid is closed before any byte is read | `server.rs`: `ko_sys::peer::uid` right after `accept` | no Go test can run as another user; by construction `Conn::new` takes a `Verified` stream type that only the uid check constructs |
| 26 | the sizing client | review (`TestUnfocusedFirstClientSizesPane`), design.md 4.5 | a focused client claims; an unfocused one claims only when no other focused client shows the pane; `ignore_size` never claims | `client.rs` (`claim`) | Go `TestUnfocusedFirstClientSizesPane`, `TestClientDifferentSizesAndSignalCleanup` |
| 27 | forced pane environment | ed21d4a4 | `TERM`, `TERM_PROGRAM`, `TERM_PROGRAM_VERSION`, `TERMINFO_DIRS`, `KO_SOCKET`, `KO_PANE` override the request and the inherited environment | `panes.rs` | Go `TestDefaultsAndPaneEnvironment` |
| 28 | `SO_SNDBUF` 1 MiB on a view, 2 ms coalescing, `read` until `EAGAIN` | P1.0, P1.1 | | `server.rs` (`ko_sys::sock`), `state.rs`; `ko_pane` | bench (section 7) |
| 29 | pixel size overflow | 09ba9cd4 | `cols * cell_px` is computed in 64 bits and clamped to 65535 | `ko_pane`'s `winsize` (a `u16` result of a saturating `u32` product) | unit: 4096 columns of 65535 pixels give 65535 |
| 30 | the control-frame reader checks each frame's own length | cd74d3c1 | a short body fails the pane instead of reading into the next frame | `pane_proc.rs` | unit: "a frame body shorter than its fields fails"; property: "a frame never reads the bytes after it", "frames split anywhere give the same effects" |
| 31 | the client's one writer, output wakes the loop, no frame pacing | ed21d4a4, ad858e14 | one cell differ draws pane and sidebar; output on a view socket wakes the loop directly; a wheel event draws at once | `ko_tui/client.rs`, `renderer.rs` | Go `TestClientSidebarOwnership`, `TestClientOutputWithoutOuterInput`, `TestClientHistoryAndTop` |
| 32 | outer modes: resets before sets, restore exactly, pop kitty flags, `DECSCUSR 0`, never RIS | 0d5bccf8, p1-mvp.md 5 | | `ko_tui/modes.rs` | Go `TestClientWinchAndOuterModes`, `TestClientUnknownCursorModeAndKeyboardStack`, `TestClientModesBeforeAttachAndUnattachedDA1` |
| 33 | compression during continuous output | 66e75d30, ad858e14 | after 2 s without an idle period, one incremental step per 10 ms | `ko_vt/src/compress.rs`, one state machine for `ko-pane` and the mirror, as `compress.h` is | unit: the tick table ported from `test_compress.c` |
| 34 | fair reads and accepts | 68232448 | a readable source is read at most 16 times per turn and the listener accepts at most 16 connections per turn, so one flooding peer cannot starve the others | `ko_sys::event`, `server.rs` | unit: the reference's "a stream reads up to the bound per step and reports the end once" (25 reads of a 100-byte stream through a 4-byte window over three turns); fuzz `loop` |
| 35 | the listener under descriptor shortage | 68232448 | `EMFILE`, `ENFILE`, `ENOBUFS` or `ENOMEM` from `accept` parks the listener and arms a retry deadline instead of spinning; `ECONNABORTED` is skipped | `server.rs` | unit: a child test process with a lowered `RLIMIT_NOFILE` accepts until the limit, parks, and accepts again after a descriptor is freed |
| 36 | a signal is never lost and runs once per wakeup | 68232448 | the handler sets a per-signal pending flag before it writes the pipe, so a full pipe loses no signal; the loop runs each pending signal once per wakeup | `ko_sys::signal` | unit: the reference's 200,000 simulated `SIGUSR1` and one `SIGUSR2` give one dispatch each, then none |
| 37 | timeouts that neither spin nor oversleep | 68232448 | no deadline means an infinite timeout; a turn with no sources and no deadlines returns; a sub-millisecond deadline is rounded up on macOS and exact with `ppoll` on Linux (RL) | `ko_sys::event` | unit: timers fire in deadline order, repeat and cancel (the reference's test); a 0.4 ms deadline makes one wakeup, not a loop of zero timeouts; fuzz `loop` |
| 38 | sources added in a dispatch do not hide the rest of the batch | 68232448 | a turn copies its ready entries before it dispatches | `ko_sys::event` | unit: the reference's test, where the first handler adds 100 sources and the second still runs |
| 39 | done callbacks after the state change | 43440688 | a snapshot's done callback runs after the pane's own state has moved on, so a snapshot asked for from that callback gets the slices after it | `pane_proc.rs` | unit: "a snapshot asked for from a snapshot's done callback gets the slices after it" |
| 40 | a snapshot that cannot be sent closes its view | 43440688 | a snapshot request that cannot be sent is refused and its callback never runs; the view closes instead of waiting forever | `pane_proc.rs`, `view.rs` | unit: "a snapshot request that cannot be sent is refused, and its callback never runs" |
| 41 | `snapshot_done` in request order | 43440688 | a `snapshot_done` for a request that still reads its slices ends that request as incomplete, because `ko-pane` ended it without its last slice, and the pane stays open; a `snapshot_done` for any other request is ignored (`Pane_core.fst`, `snapshot_done`) | `pane_proc.rs` | unit: a `snapshot_done` for a reading request ends it incomplete, and one for another request changes nothing; RV2 proves the order (6.7) |
| 42 | run-time contract checks | 43440688 | the postconditions that run-time state can show (the ring's, the connection's batch result, the delivery contracts) are checked in tests and fuzz runs and cost nothing in release | `debug_assert!` at the same points as the reference's `Contract.check` (`ring.rs`, `conn.rs`, `pane_proc.rs`); `make test-ko` and cargo-fuzz build with debug assertions, the release profile without | the unit and fuzz runs themselves; a broken contract panics with the contract's name |
| 43 | the pager runs outside ko's alternate screen | 37ea03a8 | before `$PAGER` runs, the client leaves the alternate screen (and restores the outer modes), and enters it again after | `ko_tui/client.rs`, `modes.rs` | Go `TestClientHistoryAndAlternateScreen` |
| 44 | `ECONNRESET` is a close | 37ea03a8 | on Linux a unix socket whose peer closed with unread input reads `ECONNRESET`; ko treats it as the end of the source, as `Ok(0)` | `ko_sys::event`'s read, `wire.rs` | Go `TestHostileClientsDoNotAffectOthers` on Linux (RL) |

Rows 34 to 44 come from the reference's commits after 93d03095
(68232448, 4a7ea19b, 43440688, 37ea03a8). Every row now has a Rust home. Until the cut, the C `ko-pane` keeps
its own tests for the OCaml server's client run (4.2); the cut
deletes them with it.

## 6. Verification and testing

### 6.1 Unit tests

`#[cfg(test)] mod tests` at the bottom of each file. Every inline
OCaml test of `ko_server/`, `ko_vt/` and `ko_tui/` is ported with its
expectation unchanged, as the list above names them. Expectations are
`assert_eq!` on strings or values; there is no snapshot crate.

### 6.2 The Go suite as the oracle

Section 4.1. `make e2e-ko` and `E2E_KO=TestFoo` keep their meaning.
The suite's `signal_test.go` helper stays the only signal call in Go.

### 6.3 Property and stateful tests

Ports of `ko_server/fuzz/` with proptest, as `#[cfg(test)]` modules:

- `ring.rs`: the operation list of `fuzz_ring.ml` (writes of each
  kind, advances to a boundary, head or tail, resumes) against the
  model's `invariants`: `end_offset`, `oldest_offset`, `reachable`,
  the replay equals the expected bytes and retained markers.
- `view.rs` and `harness.rs`: the view harness of `fuzz_view.ml`: a
  real `ko-pane` fed through a FIFO, views on socketpairs with fast,
  slow and stalled readers, resizes, resyncs, resumes from retired
  mirrors, closes, EOF and a crash; the `check` step compares every
  mirror with the recorder, the pane's own screen with the mirror,
  and a fresh snapshot. Its three explicit cases (rows 14, 20 of
  section 5 and the two libghostty-vt findings) stay as named tests.
  This harness needs `ko_vt` (the mirror), so it lives in
  `ko_server`'s dev-dependencies on `ko_vt`.
- `router.rs`: the decoder and route properties of `fuzz_http.ml`
  ("decoders return only the errors their callers handle", "routes
  return only `Invalid`"), and "the server answers any request with
  a status or a close, and stays healthy" over an in-process server
  (the loop, `conn.rs`, the router and a link) on a socketpair.
- `http.rs`: a request cut into random pieces gives the same result
  as the whole; a head of N bytes is answered for N up to 16,384 and
  gets `431` above, also after a queued pipelined response.
- `protocol.rs`: for each wire type, a generated value encodes and
  decodes to itself, and its JSON equals the captured jsonkit JSON of
  2.3 for the fixed cases.

proptest-state-machine is not needed: the operation lists are plain
`Vec<Op>` generators with proptest's shrinking, as QCheck2's were.

`PROPTEST_CASES` scales the counts; `dune test`'s fixed seeds become
`proptest`'s persisted regressions in `proptest-regressions/`, which
are committed, so a found case replays in the fast path.

### 6.4 Fuzzing

`fuzz/` holds cargo-fuzz targets that call public functions of the
library crates with a byte slice:

| target | function | replaces |
|---|---|---|
| `ring` | a sequence of writer and reader operations on the real `ko_pane_wire::ring` (in-memory backing) against a pure model of the ring and of `ko-pane`'s room rule, compared after every operation | the reference's Monolith `ring` target (4a7ea19b, `ko_server/fuzz/fuzz_ring.ml`), which found the old resume bug in 12 operations; cargo-fuzz with `arbitrary` decodes the operation list, and a failure is minimized by `cargo fuzz tmin` |
| `loop` | `ko_sys::event` over socketpairs and a pipe with interest changes, sends, full buffers, peer closes, timers and simulated signals, against a model: the read count, every byte once and in order, no callback after removal, timers never early and in deadline order, one dispatch per pending signal | the reference's QCheck2 `loop` target (68232448, `ko_server/fuzz/fuzz_loop.ml`); a signal is simulated by calling the handler body, as `ko_signal_deliver` does, never by sending one |
| `head` | `http.rs`'s head reader over the bytes cut at fuzzer-chosen points: it returns a head, `Partial`, `431` or `400`, never reads past its buffer, never holds more than 16 KiB of one head, and gives the same result for every cut | new: ko's own framing over httparse |
| `http` | one connection fed the bytes, over the in-process server (the loop, `conn.rs`, the router, a link, one `cat` pane); the server is made once per fuzz process, a fresh socketpair per input | `fuzz_http`'s byte-level part and the hostile test's inputs; it covers the framing, the upgrade and the link together |
| `client` | the client's response reader (`http.rs`) over the bytes | new |
| `ws` | a `Link` after the upgrade fed the bytes as client frames, against a fake view: tungstenite's reader, the caps, the close reasons, the link's queue | new |
| `decode` | each `Request` decoder of `protocol.rs` over the bytes (serde_json and `protocol::decode`'s shape check, decision 150) | the decoder part of `fuzz_http` |
| `frames` | `pane_proc`'s frame reader over the bytes, with a fake ring; each input is also fed in two parts at a fuzzer-chosen cut and must give the same effects | the reference's Monolith `pane-proc` target, which compares a frame fed whole with one fed in two parts |
| `frame` | `ko_pane_wire::frame`'s frame-size reader: every accepted frame is at least 5 bytes, at most the input and at most `MAX_FRAME + 4` | `fuzz_frame.c` |
| `control` | `ko-pane`'s control dispatch in process (`ko_pane::control`), with a fresh terminal per input (R3 adds the pool, decision 64), no pty and an in-memory ring; the first byte picks the mode (a fresh terminal or none, a stream read or frame by frame), as `fuzz_control.c` does | `fuzz_control.c`; its 188-input corpus moves from `ko_pane/fuzz/control/` to `fuzz/corpus/control/` unchanged, with `control.dict` and `max_len = 4000` |

Each target has a `#[test]` in the library crate that replays
`fuzz/corpus/<target>/` through the same function on stable, so
`cargo test` is the fast path, as `dune test` is today. `make fuzz
TARGET=... TIME=...` runs `cargo +nightly fuzz run` boxed in its own
process group for `TIME` seconds, with the dictionary and
`max_len` from `fuzz/<target>.options`; `MERGE=1` keeps its meaning.
`scripts/fuzz.sh` keeps its structure; only the build and run lines
change. Agents do not run it; CI does.

The reference added AFL++ runs (`ring-afl`, `pane-proc-afl`,
`http-afl`, with `dune-workspace.afl`) because an OCaml build cannot
instrument its dependencies for libFuzzer; cargo-fuzz instruments every
crate already, so the Rust targets need no second engine. The
reference's 100 s `http-afl` run reached 1,226 edges at 6,000 inputs
per second; R3 records the same figures for `http` as a baseline.

cargo-fuzz instruments every dependency, so coverage feedback reaches
into httparse, tungstenite and serde_json, and the fuzzer learns their
branches as well as ko's. The consequences:

- The targets test ko's framing and its use of the crates: ko's own
  HTTP framing is the main new surface, so `head`, `http` and
  `client` get the larger share of the scheduled time. A finding
  inside a crate is reported upstream and pinned by a `Cargo.lock`
  change and a corpus case, not patched in ko.
- The in-process targets build their server once per fuzz process and
  feed a fresh socketpair per input; the loop has no runtime to start.
- The seed corpora start from the inputs that ko already has: the
  hostile test's seven inputs, the `fuzz_http` generators' fixed
  cases and the tests of `connection.ml`, so the fuzzer starts past
  the request line.
- `-fsanitize=address` builds every crate, so a build of `fuzz/`
  takes minutes; only `make fuzz` and the scheduled workflow pay it.

### 6.5 loom

`ko_pane_wire::ring` has a `model` module under `cfg(loom)` with three
tests that replay the GenMC models of row 7 on the real `Writer` and
`Reader` (the atomics go through a `cfg(loom)` alias of `AtomicU64`);
the GenMC models and the extracted C ring went after R5 (decision
111). `records_reach_the_reader_whole_and_in_order` replays
`ring_mc.c`: a writer and a reader thread on a 64-byte
ring, 5 records of 9 bytes whose payloads are their stream offsets;
the reader checks every byte once and advances the tail.
`a_seq_cst_handshake_loses_no_wakeup` replays `wakeup_mc.c`, the handshake with two threads over the three
header atomics and a one-slot "frame sent" flag: the writer commits a record (store `head`,
load `read`, send a `head` frame if equal to the old head); the reader
scans (load `head`, store `read`) and then, if no frame arrived, must
find the new head on its next load. The property: after both run,
either a frame was sent or the reader's last load saw the final head.
loom explores every interleaving and models the stale loads that
release and acquire permit, so the `SeqCst` version passes and the
`AcqRel` version fails, which the `#[should_panic]` twin pins. It runs in `unit-ko` under
`RUSTFLAGS=--cfg loom` on its own target directory, in a few seconds.
The model corrects loom's `SeqCst` (decision 37).
loom models the two processes' shared atomics only; no ko process
has threads that share state, except the client's compressor, which
uses a `Mutex`.

### 6.6 Miri

`scripts/miri.sh` runs `cargo +nightly miri test` on the modules with
no sockets and no FFI: `ko_pane_wire::ring` (the
writer and the reader on an in-memory backing, the one module with
ko's own raw-pointer `unsafe`), `ko_pane_wire::frame`, `protocol` (serde_json and
`decode`'s shape check), `ids` and `http.rs`'s head reader over byte buffers.
`conn` and `pane_proc` run on sockets and stay out (decision 70).
httparse, tungstenite and serde_json are not in Miri's scope beyond
what these tests call; their projects test themselves. It runs in the
scheduled CI workflow beside `make fuzz`, because Miri is tens of
times slower than native. A finding becomes a unit test.

### 6.7 Verus

Decision 10: Verus writes ko's specs. The state of Verus on
2026-10-31, from its repository and crates.io:

- `vstd`, `verus_builtin`, `verus_builtin_macros` and
  `verus_state_machines_macros` are on crates.io with date versions
  (`vstd 0.0.0-2026-10-25-0158`). The verifier and `cargo verus` come
  as release archives for arm64 and x86 macOS and Linux
  (`release/0.2026.10.26.d17fbd0`), with Z3 inside.
- Verus pins its Rust toolchain; `main` pins **1.99.1**, which is
  ko's pin (4.3).
- A crate with `verus!{}` code builds with a plain `cargo build`: the
  macro erases the ghost code. A probe crate with `vstd` and a
  `verus!` function with `requires` and `ensures` built with cargo
  1.99.1 in 6 s. Its tree has 15 packages; 11 are new to ko's set
  (`vstd`, `verus_builtin`, `verus_builtin_macros`,
  `verus_state_machines_macros`, `verus_syn`, `verus_prettyplease`,
  `synstructure`, `convert_case`, `indexmap`, `hashbrown`,
  `equivalent`), and `syn`, `quote`, `proc-macro2`, `unicode-ident`
  are shared. So the verified module is the
  production module; no proof-only mirror is needed.
- `cargo verus verify -p CRATE` verifies the crates whose
  `Cargo.toml` has `[package.metadata.verus] verify = true`. The
  `verus_only` cfg may guard only `use` statements (the guide's
  "Ghost Erasure" warns that code under it can be unsound).
- vstd's atomics are sequentially consistent, which is ko's rule (row
  7). Verus has no weak-memory model, so the acq/rel failure stays a
  loom and GenMC fact (6.5).

**The references** are committed in the reference tree (43440688);
this tree keeps only the `.fst` and `.fsti` sources (decision 111): `ko_proofs/` (F*/Pulse, 4,208
lines; `make proofs` installs the pinned F* through
`scripts/install-fstar.sh`, verifies, extracts and compares) and
`ko_pane/genmc/`.

- The ring: `ko_proofs/KoRing.Spec.fst` (the log model, `kind_of`,
  `wf`, `boundary`), `KoRing.Inv.fst` (the shared invariant over
  `head`, `tail`, `read` with the writer's and reader's halves and the
  ghost log), `KoRing.Writer.fst` (`available`, `put_record`,
  padding), `KoRing.Reader.fst` (`observe`, `header`, `release`,
  `set_read`), `KoRing.Walk.fst` (`advance`, `end_offset`, `resume`),
  `KoRing.Mask.fst` (byte windows, initialized bytes, header facts),
  `KoRing.Init.fst` (a zeroed mapping splits into the invariant). It
  proves, with no admits: the five writer facts that an earlier WhyML
  proof had to assume as axioms (records never wrap, tags are valid,
  boundaries are dense, `0 <= off <= pos`, the offset step); one owner
  per byte (the writer never writes unreleased space, the reader
  reads only `[tail, seen)`); the log is append-only and each boundary
  is walked once in order; `advance` moves `tail` to the first
  boundary at or after `min(head - cap/2, keep)` and no further;
  positions stay below 2^62. `ko_proofs/ko_ring_proved.h` is the
  extracted C that `ko_pane/pane.c` and the coordinator's ring stubs
  call.
- `ko_proofs/Ring.fsti` states the contracts of the OCaml reader
  (`ko_server/ring.ml`), and `Ring_proof.fst` proves each against the
  proved model; only `ring.ml`'s correspondence with that model is
  trusted. In Rust there is no such gap: the verified module is the
  reader.
- Trusted there: `ko_proofs/ko_atomic.h` (`KoAtomic.fsti`), the
  construction of the ring view from the mapping (`ko_ring_attach`),
  a zero-filled mapping, `pane.c`'s payload writes within the room
  and before the commit, the two processes treated as one heap, and
  the callers' `keep` and cursors.
- The cores: `ko_proofs/Pane_core.fst` (`deliver`, `scan`, `keep`,
  the snapshot hold with the livelock fix, the done-callback order of
  row 39, the refusal of row 40) and `View_core.fst` (the cursor,
  resume, snapshots, one in flight, the progress rule, and
  `flush_batch`'s "not sent means closed or blocked"), extracted to
  `ko_server/pane_core.ml` and `view_core.ml`, against the assumed
  I/O contracts `Delivery_io.fsti`, `Connection.fsti`, `Feed.fst`,
  `Oint.fsti` (native ints), which `KO_CHECK_CONTRACTS` checks at run
  time (row 42). Known gaps: two assumed ghost steps
  (`start_stream`, `set_snapshotting`; the Verus port drops their
  fields for run-time checks, decision 97),
  the glue from tokens to generations, and no liveness (safety only).
- GenMC: `ko_pane/genmc/ring_mc.c` (the writer and the reader as two
  threads on a 64-byte ring, 5 records of 9 bytes: no errors under SC
  and under acq/rel, 17,519 executions) and `wakeup_mc.c` (the
  store-buffering handshake: a lost wakeup under acq/rel, none under
  seq_cst), run by `ko_pane/genmc/run.sh sc|acqrel ring|wakeup` with
  `ko_proofs/ko_atomic.h` or `ko_pane/genmc/acqrel/ko_atomic.h`. Both
  include `ko_proofs/ko_ring_proved.h`.

**What Verus verifies in production, in this order:**

1. **`ko_pane_wire::ring`, both halves** (stage RV). A
   `tokenized_state_machine!` with the ghost log of `KoRing.Spec`
   (`log`, `rec_ok`, `wf`, `log_le` as `spec fn`s), the shared
   variables `head`, `tail`, `read`, and two tokens: the writer's
   (owns `[head, tail + capacity)`) and the reader's (owns `[tail,
   seen)`). The transitions are `put_record`, `observe`, `release`
   and `set_read`; the invariant is `KoRing.Inv`'s. The exec code is
   `Writer::available`, `Writer::put_record`, `Reader::observe`,
   `Reader::header`, `advance`, `end_offset`, `resume`, with the
   `ensures` of `KoRing.Writer` and `KoRing.Walk`. Each header word is
   an `AtomicU64` whose ghost invariant ties its value to the state
   machine. Because the writer is now Rust (1.3), the five writer
   facts and the payload writes within the room are proved, not
   trusted.
2. **The wakeup handshake** (stage RV): the theorem of `wakeup_mc.c`
   as a transition property: if `put_record` reports `Published`
   (the reader's `read` was not the old head), the reader's next
   `observe` after its `set_read` sees the new head; `Idle` (the
   reader was idle at the old head) is the case where the writer
   sends the head frame. The
   loom twins of 6.5 replay `wakeup_mc.c` and `ring_mc.c` beside it,
   because Verus models only SC.
3. **`pane_proc`'s `deliver`, `scan` and `keep`** (stage RV2), from
   `Pane_core.fst`. This is where bug 2 of 09ba9cd4 and the livelock
   of 7c877215 were, and bug 2 passed every module proof while the
   call site was wrong; so RV2 verifies the caller in
   `pane_proc.rs`, not only the ring.
4. **`view.rs`'s cursor, resume and snapshot rules** (stage RV3,
   decisions 95 to 100), from `View_core.fst`.

Not Verus: `Pid` and `Group` (their facts come from the OS; unit tests
and the type's one constructor); the frame codec's bounds (the `clippy::indexing_slicing`
and `arithmetic_side_effects` lints, the `frame` fuzz target and
Miri). Kani is not planned: Verus covers the ring arithmetic.

**Still trusted after RV:** the mapping itself (one
`#[verifier::external_body]` constructor for each role,
`Backend::mint_reader` and `Backend::mint_writer`, makes that role's
header word and data byte permissions from the mapping and states that
the region is zero-filled at creation, attached before any record and
shared by exactly two owners, one per token, decision 80; and the
capacity getter); the header word load
and store (vstd's `from_ptr_load` and `from_ptr_store` contracts); the
byte accessors (`external_body` reads and writes of a range that
`requires` the permission over it, a few lines each); vstd and
the verifier; the libghostty-vt calls that fill a payload; and the
callers outside the verified modules until RV2. After RV3:
`delivery.rs`'s sink call, its one stamp counter for each process
(`mint_stamps`) and the definition of a fresh stamp's ring instance
(`bind_fresh`, decision 117), the WebSocket sends and marker decode of `view.rs`,
and `Output`'s socket I/O in `conn.rs` (decision 100).

**The lessons of the Pulse work that the port keeps:** no trusted
function with an unconditional `ensures` (the WhyML `writer_causal`
val proved false); no ghost fields inside trusted I/O models; the
state in one struct passed as `&mut`, not separate cells with a ghost
mirror; verify the callers, not only the module; one sequence of
pairs instead of parallel sequences; nine modules or fewer for the
ring, not twelve. Extraction does not arise: Verus checks the code
that runs.

**How it runs.** `make verus` downloads the pinned Verus release
archive into `build/verus/<release>/` once (checked against a SHA-256
in `scripts/verus.sh`, as `scripts/install-fstar.sh` does for F*) and
runs `cargo verus verify -p ko_pane_wire` (and `-p ko_server` after
RV2). Verus needs the rustup toolchain named `1.99.1-<host>`, which is
the one that `rust-toolchain.toml` installs (4.3). `make verify-ko`
gains a stage `verus`; it is SKIP when the archive cannot be fetched,
and FAIL in CI (`KO_VERUS_REQUIRED=1`). `vstd`'s and
`verus_state_machines_macros`' versions in `Cargo.toml` are pinned
with `=` to the release, and lint checks that they agree.

**Measured cost** (2026-11-01, an M5 Max, Verus
`0.2026.10.26.d17fbd0` for arm64 macOS, a scratch probe under `/tmp`):
the archive is 452 MB (1.4 GB unpacked) and installing the pinned
toolchain took 15 s. The probe is an SPSC index model: a
`tokenized_state_machine!` with `cap`, `head`, `tail`, `read`, its
invariant `tail <= read <= head <= tail + cap`, four transitions with
their inductiveness proofs, and two exec functions (`available`,
`advance`) with `requires` and `ensures` over `u64` indices. It
verifies in 0.27 s with the `verus` binary (`--time`: 131 ms of
verification, 3 ms in Z3). `cargo verus verify` on the probe crate
takes 12.9 s cold, almost all of it the build of `vstd`, and 0.5 s
when `vstd` is built.

**The per-push budget** (decision 18): the `verus` stage of `make
verify-ko` and CI has a cap of **120 s** for the verification of ko's
crates, measured by `scripts/verus.sh` with the `vstd` build excluded;
over the cap the stage fails with the time of each module from Verus's
`--time` output. The fix is a faster proof (an `rlimit`, a split
lemma); if a module cannot meet the cap, a recorded decision moves its
verification to the scheduled workflow. The ring port is about ten
times the probe's transitions and much more exec code than the probe;
an estimate from the probe is 10 to 40 s, and RV records the real
figure. CI's cost is the cache restore of the archive and, on every
run, the cold build and verification of `vstd` (about 15 s, RV's
result), because CI does not cache `target/`; the 120 s cap does not
count it. The Verus crates also build in each cargo target directory
(debug, release, `target/loom`, clippy).

The production dependency allowlist (section 8) gains the 11 new
packages. Most are compile-time macros, and the ghost code is erased;
RV records the release binary's size with and without `vstd`.

Estimates: RV (the ring and the handshake) 6 to 9 agent-days; RV2
(`deliver`, `scan`, `keep`) 3 to 5. RV needs RP's Rust writer and runs
beside R3 and R4; RV2 needs RV.

### 6.8 The signal rule in Rust

`scripts/lint.sh` extends `signal_pattern` to `*.rs`:
`libc::kill\b|libc::killpg\b|\bkillpg\b|nix::sys::signal|Command::new\(\s*"kill"`,
over `ko_sys ko_pane_wire ko_pane ko_server ko_tui ko ko_bench fuzz`,
excluding `ko_sys/src/pid.rs`. `pid.rs` exports `Pid::signal` and
`Group::signal` only. The Go helper and the Python `signal_child`
keep their rows; `pane.c`'s `group_signal` row goes with the C
`ko-pane` at the cut.

### 6.9 What `make verify-ko` does not run

Long fuzz runs and Miri. A scheduled workflow runs them. A finding
of either adds its case to the fast path. Verus is a stage of `make
verify-ko` (6.7).

## 7. Stages

Each stage is one unit of work under one manager. Each ends with
`make verify-ko` green.

### R0. Toolchain, skeleton, oracle (2 agent-days)

- `rust-toolchain.toml`, the workspace, `rustfmt.toml` (`max_width =
  100`, as ocamlformat's margin), `clippy.toml`, the crate skeletons.
- `ko_vt_sys` with `build.rs` (zig) and the committed bindings;
  `scripts/bindgen.sh`.
- `ko_vt` with `Terminal::new`, `write`, `resize`, `dump`,
  `dump_history`, `mode`, `total_rows`, the snapshot `Decoder`
  (pull reader; zero-byte read is EOF).
- `ko_vt/examples/decode.rs`. `make build-ko`, the installed layout,
  the `TestMain` edit, the `verify.sh` stages, CI.
- `Cargo.lock` with the crate set of 2.4, `scripts/crates.txt` and
  its lint check; the measured package count and release binary
  size, which replace the estimates of 2.5.
- Acceptance: the `decode` example decodes the recorded snapshots of
  `bench/streams/` runs through the OCaml `ko_vt` to the same JSON;
  `make verify-ko` prints its stages with `build` and `lint` PASS.
- Result (2026-11-01, macOS): 63 comparisons (7 streams, 3 sizes,
  full and screen snapshots, with and without `--full`) are
  byte-identical; the 44 Go tests pass with the Rust decoder.
  Decisions 28 to 33 came from R0.

### R1. The loop and the coordinator core (5 to 6 agent-days)

- `ko_sys`: `event` (the loop, about 250 lines, with its tests: a
  deadline wakes, no deadline means no timeout, `EINTR` is an empty
  turn, interest changes take effect on the next turn), `signal`,
  `retry`, `pid`, `sock`, `Mapping`, spawn of `ko-pane`, process
  identity, `waitpid`, the clock.
- `ko_pane_wire`: `frame` and the ring's `Reader` (the `Writer` comes
  in RP); the agreement test against `ko_pane/protocol.h`.
- `ko_server`: `server.rs` over the loop (the listener, the signal
  pipe, the output tick), `ids`, `pane_proc` (spawn, the control
  socket as a source, requests, deliver and scan), `pane`, `panes`,
  `config`, all against the C `ko-pane`.
- The unit tests of rows 1, 3, 8, 30 of section 5; the ring property
  (6.3); the loom test (6.5).
- Acceptance: a Rust probe starts the C `ko-pane`, feeds 1 GiB from
  `bench/produce.exe`, and the ring reader keeps up with no lost
  record; `make test-ko` green, the loom tests included.
- Result (2026-11-01, macOS, load average 1.7): `make probe-ko`
  read 1 GiB of the seven `bench/streams` through the C `ko-pane` and
  the real `Server` at 79.5 MB/s (13.50 s), with 0.755 s of
  coordinator CPU (0.06 core): 1,048,634 records, 1,073,741,824
  bytes, exactly the producer's total, no lost record, no gap in the
  offsets and no invalid record. The ring's back-pressure is what
  keeps a record from being lost; the probe checks the result. A
  first run, before review, measured the C tail-acker at 77.4 MB/s on
  the same machine. The loom models take 0.6 s;
  the acquire/release twin loses the wakeup. Decisions 34 to 45 came
  from R1.

### R2. HTTP, WebSocket, views, clients (5 to 7 agent-days)

- `http.rs` (the head reader over httparse with the 16 KiB limit,
  `Content-Length` bodies, `411`, the response writer, and the
  client's request writer and response reader; about 370 lines with
  the client), `conn.rs` (the `Phase` machine, the read buffer, the
  queue, the batch, the record write), `protocol` (serde derives, the
  `compact!` macro, `Route`) with the captured jsonkit JSON of 2.3;
  `router` (the version and `Origin` checks, the dispatch, the 101);
  `ws` (the tungstenite adapter, `record_header`); `link` (the
  WebSocket phase, the ping); `view`, `client`, `state`; `ko server`,
  `ko kill-server`, `ko api` (the blocking client of 3.6), `ko
  version` in `ko/`.
- The unit tests of rows 4, 5, 6, 11, 12, 16, 18 of section 5, the
  three head-limit tests of `connection.ml` first; the `http.rs`,
  router and protocol properties.
- Acceptance: the 28 server tests of the Go suite pass against
  `build/ko/bin/ko` with the C `ko-pane` on macOS;
  `TestHostileClientsDoNotAffectOthers` and `TestClientGridLimit`
  included.
- Result (2026-11-01, macOS): `make verify-ko` passes (build 2.7 s,
  unit-ko 10.3 s, e2e-ko 4.7 s, lint 1.5 s). The 28 server tests pass
  against `build/ko/bin/ko` with the C `ko-pane`, the hostile and grid
  tests included; the 16 client tests pass against the OCaml `ko`.
  `make probe-ko` read 1 GiB at 79.0 MB/s before review and 64 MiB at
  77.8 MB/s after it, with no lost record.
  Decisions 46 to 57 came from R2.

### RP. `ko-pane` in Rust (4 to 6 agent-days)

- `ko_pane_wire::ring`'s `Writer` (`available`, `put_record`, the
  pad record, the `full` wait); the ring property test of R1 then
  derives the model's room from its record list, not from the
  writer's own formula; `ko_vt`'s server half (the terminal
  with its callbacks, the encoders, the formatter, the snapshot
  encoder with `cut.rs`, `compress.rs`); `ko_sys`'s `pty`,
  `peek_exit`, `reap`; the `ko_pane` binary on R1's loop and signal
  pipe (1.3).
- `ko_pane/tests/pane.rs` with `test_pane.c`'s cases (the held
  zombie, the frames over a recorded stream: title, pwd, OSC 133 and
  7501 bytes, a 2026 mode cleared in the snapshot, the markers, the
  dead marker); the compression tick table; the `frame` and `control`
  fuzz targets with the converted corpus and their replay tests;
  rows 2, 19, 29, 33 of section 5.
- `make build-ko` installs the Rust `ko-pane`; the C one remains only
  for the OCaml run of 4.2.
- Acceptance: the 28 server tests pass with the Rust `ko-pane`; the
  ingest rows of `bench/baselines.sh` with the Rust `ko-pane` are
  within 5 percent of the C one on the same machine (row 3, `ko-pane`
  and the ring with the C tail-acker: 81.0 MB/s at 0.97 core in
  p1-mvp.md 6.2; 78.7 MB/s in 6.5), and the idle `ko-pane` footprint
  stays under 2 MiB (1.5 MiB in p1-mvp.md 6.5).
- Result (2026-11-01, macOS, load average 3.9 to 5.2, after review):
  row 3 with 1 GiB, three alternating runs, gave the C `ko-pane`
  78.7, 79.1 and 79.7 MB/s and the Rust one 77.4, 80.4 and 78.9
  MB/s (0.5 percent below on the mean). `make probe-ko` through the
  Rust server gave 77.7 MB/s at 1.068 CPU-s per GiB with the C
  `ko-pane` and 77.1 MB/s at 1.061 with the Rust one, with no lost
  record. The idle footprint is 1,824 KB for Rust and 1,552 KB for
  C. Decisions 60 to 65 came from RP.

### R3. Harness, fuzz, Miri, bench (4 to 5 agent-days)

- The view harness (6.3) and its three explicit cases; `fuzz/` with
  the six targets of decision 66, corpora and replays; `scripts/fuzz.sh`;
  `scripts/miri.sh`; the scheduled workflow of 4.4 with its fuzz and
  miri jobs.
- `ko_bench` with the modes of `coordinator.ml`; a counting
  `#[global_allocator]` in the bench binary reports allocations per
  record.
- Acceptance, measured with the commands below on the same machine
  as a fresh run of the OCaml numbers, both on AC power at load
  average under 2 (decision 78):

| metric | command | OCaml ko | Rust target |
|---|---|---|---|
| coordinator CPU, one pane, 1 GiB mixed stream | `ko-bench throughput writev 1073741824 2 bench/streams/*.vt` (row 4 of `bench/baselines.sh`) | 0.80 s per GiB (cd74d3c1); 79.1 MB/s end to end at 1.17 cores (p1-mvp.md 6.5) | within 5 percent of a fresh OCaml run, CPU per GiB and MB/s (decision 78) |
| allocation per record | the same, `allocations/record` in place of `minor_words/record` | 1.5 minor words on the poll loop (68232448; 2.3 on luv) | 0 heap allocations per record in steady state (decision 16) |
| five flooding panes with views | `bench/flood.sh` (`ko-bench flood`) | 0.26 core (cd74d3c1) | within 10 percent of a fresh OCaml run (decision 78) |
| hop latency, pty byte to the view write | `ko-bench latency writev 5000 2` | p50 33 us, p99 109 us (p1-mvp.md 6.2) | the same or better than a fresh OCaml run of the fixed bench (decision 79) |
| key to frame, view only | `python3 bench/client.py latency` | p50 0.09 ms, p99 0.17 ms (p1-mvp.md 6.5) | the same or better |
| attach, 100k lines | `python3 bench/client.py attach` (after R4) | screen 14 ms, history 39 ms | the same or better |
| resize, 100k lines, to READY | `python3 bench/client.py resize` (after R4) | 5.7 ms, p99 6.8 | the same or better |
| coordinator idle, no panes | `python3 bench/client.py memory` | RSS 13.7 MiB, footprint 8.5 MiB | under 15 MiB RSS; expected well under |
| idle wakeups | `sample` 10 s on macOS (`strace -c` on Linux in RL), with three idle panes | one 1 s ping timer (`loop.ml`, still in 37ea03a8) | no periodic wakeup (decision 19); the ping deadline only, at most one wakeup per 30 s per idle connection (protocol.md 1: the server pings after 30 s of idleness) |

The idle criterion is s1.md 12's `TestNoIdleWakeups` brought forward:
the coordinator's CPU grows less than 5 ms over 5 s with three idle
primed panes. It becomes a Go test in R3.

Result (2026-11-02, macOS, one run of each row, OCaml first, load
average 1.1 to 1.99, RV paused):

| metric | OCaml ko, this session | Rust ko | target |
|---|---|---|---|
| coordinator CPU, 1 GiB | 0.876 s, 79.5 MB/s | 0.881 s, 82.8 MB/s | missed: 0.80 s; MB/s met (+4 percent) |
| allocation per record | 1.53 minor words | 0.00 allocations | met |
| five flooding panes with views, 2 ms window, 128 MiB each | 0.27 core, 229.9 MB/s | 0.32 core, 238.2 MB/s | missed: 0.26 core |
| hop latency, `latency writev 5000 2` | p50 1,288 us, p99 2,561 us | p50 1,303 us, p99 2,577 us | missed by both: 33 and 109 us (decision 77) |
| key to frame, view only, 500 samples | p50 0.19, p99 0.53 ms (0.14 and 0.34 over the raw pty) | p50 0.18, p99 0.32 ms (0.13 and 0.20 over the raw pty) | met |
| coordinator idle, no panes | RSS 13.5 MiB, footprint 8.5 MiB | RSS 2.6 MiB, footprint 1.5 MiB | met |
| idle wakeups, three idle panes with views | | `TestNoIdleWakeups`: 12 us of CPU and 1 wakeup in 5 s | met |

`client.py latency` attaches a terminal client before its view row,
so the view row of the Rust ko ran through a scratch driver that
calls the same functions without the client, for both servers in
one session. The attach and resize rows wait for R4.

### RV. Verus: the ring and the handshake (6 to 9 agent-days)

- `ko_pane_wire::ring` as a `tokenized_state_machine!` with the spec
  ported from `KoRing.Spec`, `KoRing.Inv`, `KoRing.Writer`,
  `KoRing.Reader` and `KoRing.Walk` (6.7, steps 1 and 2); `make
  verus`, `scripts/verus.sh`, the `verus` stage and its CI cache.
- Depends on RP (the Rust writer). It runs beside R3 and R4.
- Acceptance: `cargo verus verify -p ko_pane_wire` passes with no
  `assume` and no `admit`, the only `external_body` functions being
  the mapping and the byte accessors of 6.7; the loom replays of the
  GenMC models pass; the ingest bench rows do not move.
- Result (2026-11-02, macOS): `ko_pane_wire` verifies with 111
  obligations, no `assume` and no `admit`, in about 1.4 s warm; a cold run
  takes about 15 s, most of it vstd. The packages that Verus adds
  are 8 of the 11 of 2.5 (`vstd`, `verus_builtin`,
  `verus_builtin_macros`, `verus_state_machines_macros`, `verus_syn`,
  `verus_prettyplease`, `synstructure`, `convert_case`) and a second
  `syn` (2.0.119, for `verus_builtin_macros` and `synstructure`).
  vstd pins `verus_builtin` itself (`0.0.0-2026-10-11-0230`). The
  stripped release `ko` and `ko-pane` with `vstd` differ by 48 bytes
  from the build without it. Decisions 80 to 83 came from RV.

### RV2. Verus: `deliver`, `scan` and `keep` (3 to 5 agent-days)

- `pane_proc.rs`'s retention from `Pane_core.fst`, verified at the
  call site with the ring's spec (6.7, step 3).
- Depends on RV; beside R4 or after R5.
- Acceptance: `cargo verus verify -p ko_server` passes on
  `pane_proc`; the unit tests of rows 8 and 14 still pass.
- Result (2026-11-02, macOS): `ko_server::delivery` verifies with 14
  obligations (1.0 s) and `ko_pane_wire` with 117 (1.3 s), no
  `assume` and no `admit`; the `verus` stage takes 3.4 s warm,
  with the Verus build of both crates. The stripped release `ko` grew by
  16 bytes (1,067,464 to 1,067,480). Decisions 90 to 94 came from
  RV2.

### R4. The terminal client (7 to 9 agent-days)

- `ko_vt`'s render state, scroll, `snapshot` (for the harness and
  bench), `compress`, `memory`, `differences`.
- `ko_tui`: `tty`, `input` (vte and the translation, 2.2), `modes`,
  `wire` (the client side of `http.rs` and tungstenite with the
  client role, as sources of the loop, 3.6), `mirror` (the snapshot
  buffer, the in-memory decodes at READY and at the last slice, the
  compressor thread, 3.5), `differ`, `renderer`,
  `sidebar`, `client` (the loop over stdin, `/client`, the view and
  the signal pipe), `launch` (attach-or-start with the lock file),
  `api`; `ko` with no arguments.
- `ko_bench`'s `mirror` and `usage` modes.
- Acceptance: the 16 client tests pass against `build/ko/bin/ko`
  under the outer kido-tmux; `client.py` rows `latency`, `yes`,
  `attach`, `resize`, `memory`, `scroll` within the table above and
  the client rows of p1-mvp.md 6.5 (client CPU under 1 core on `yes`;
  100k-line mirror footprint 18 MiB against the 40 MiB target).
- Result (2026-11-02, macOS, AC power, RV paused, one run of each
  row, OCaml first): `make verify-ko` passes, and every Go test runs
  against the Rust `ko`, the 16 client tests included. The two
  clients gave byte-identical outer screens (`capture-pane -e`) over
  27 steps of the same input: attach, SGR and wide text, the sidebar,
  a new pane, pane switches, two resizes, vi, wheel scrolls,
  Alt+Backspace, a bracketed paste, sidebar clicks, the pager, the
  alternate screen, a dead pane and detach.

| row | load | OCaml ko | Rust ko | target |
|---|---|---|---|---|
| hop latency, `latency writev 5000 2` | 2.4, 2.2 | p50 13.3, p99 19.6 us | p50 14, p99 20 us | met (the Rust bench prints whole microseconds) |
| key to frame through the client, 500 samples | 1.5 | p50 1.34, p99 3.35 ms | p50 0.53, p99 0.69 ms | met |
| key to frame, view only | 1.5 | p50 0.18, p99 0.30 ms | p50 0.18, p99 0.26 ms | met |
| `yes` 5 s, shown: client CPU | 1.4, 1.6 | 0.63 core | 1.00 core | met by decision 110: about 9.6 ms of CPU per MB parsed, OCaml about 40 |
| attach, 100k lines: screen, history in the mirror | 1.7, 2.2 | 29 ms, 66 ms | 6 ms, 26 ms | met |
| resize, 100k lines, to READY | 1.6 | p50 5.14, p99 5.55 ms | p50 4.99, p99 5.44 ms | met |
| client, 100k-line mirror, footprint | 1.6, 1.5 | 16.9 MiB (RSS 100.9) | 13.4 MiB (RSS 93.3) | met |
| coordinator idle, footprint | 1.6, 1.5 | 8.5 MiB | 1.5 MiB | met |
| one wheel notch to the first output | 1.5, 1.4 | p50 0.72, p99 3.00 ms | p50 0.45, p99 0.53 ms | met |
| 240 notches per second: client CPU | 1.5, 1.4 | 0.34 core | 0.09 core | met |

  The hop row needed two fixes of the OCaml bench beyond decision 79.
  The producer stamps every 3.3 ms. Both benches stamp the receive
  in their view reader after `read`. The OCaml bench polled the ring
  only on its own repeating 2 ms timer, but the real server scans and
  pumps at once on a pane's first output after idle. In latency mode
  the OCaml bench now flushes on every output notice. Before these
  fixes, the OCaml figure was p50 1,307 us (the 2 ms poll); the
  Rust figure was p50 47 us at load 1.7 and 14 us at load 2.2.
  On `yes`, the client's time is in `ghostty_terminal_vt_write` in
  the mirror: `sample` gave 1,935 of 2,115 samples there and 88 in
  the paint. The client is limited by the parse, so it uses the whole
  core. The OCaml client uses less because its parse budget skips
  views; decision 110 replaces the target.
  The first attach row gave 70 ms and 117 ms: the probe waited 50 ms
  after the DA1 answer. It now ends at the DA1 answer, the last
  reply.

### R5. One implementation (2 to 3 agent-days)

- Delete `ko_server/`, `ko_vt/`, `ko_tui/`, `bin/ko.ml`, `bin/ko.mli`,
  `bench/*.ml`, `bench/*.mli`, `bench/dune`'s OCaml stanzas, the C
  `ko-pane` (`ko_pane/*.c`, `*.h`, `build.sh`, `dune`, `fuzz/`), the
  Makefile rules of its C tests, the `protocol.h` agreement test, the
  `group_signal` row of `scripts/lint.sh`, the extracted
  `ko_server/pane_core.ml` and `view_core.ml` with the OCaml, `make
  proofs`, `ko_proofs/extract.sh`, `scripts/install-fstar.sh` and
  CI's `proofs` job, the AFL workspace (`dune-workspace.afl`,
  `dune.afl.lock`), the ko packages from `dune-project` (`iomux`,
  `httpun`, `httpun-ws`, `jsonkit`, `qcheck-core`, `monolith`,
  `ppx_deriving_qcheck`) and re-lock `dune.lock` with the pinned
  repositories rule of AGENTS.md.
- `ko_proofs/`: every `.fst` and `.fsti` stays as the specification
  of the Verus stages (decision 111). `lib/fs.ml` and `lib/timestamp.ml` stay with
  kido.
- `verify.sh` loses the two-binary split; `lint.sh` loses the OCaml
  ko rows (QCheck, `Ko_server` doc references) and gains the Rust
  ones.
- Docs: AGENTS.md gets section 8 in place of the OCaml rules for ko
  and a Rust layout; `rfc/kido-server/p1-mvp.md` 2 and the "in OCaml"
  phrases of design.md 4.1 and 4.2 name the Rust crates;
  migration.md's S8 list drops `bin/ko.ml`. The manager writes them.
- Linux CI's ko step (the OCaml `ko` with the OCaml decoder) goes;
  Linux CI runs no ko stage until RL (decision 26).
- Acceptance: `make verify-ko` green with no OCaml ko in the tree;
  `make verify` (kido) still green; `dune build` builds kido only.

R5 is where the OCaml ko and the C `ko-pane` go, in one cut: the
OCaml client needs the OCaml server and its C `ko-pane` (4.2), and one
cut keeps the Go suite whole at every commit.

### RE. The ko e2e suite in Rust (6 to 8 agent-days, after R5)

Decision 22. The crate `ko_e2e/` holds integration tests
(`ko_e2e/tests/*.rs`) that drive the built `ko` and `ko-pane` of
`build/ko/bin` over the wire, as the Go suite does.

- **The client side of the tests** sends ordinary requests through
  `ko api` (decision 140). Raw requests, written as literal bytes and
  parsed with `httparse` directly, not through ko's `http.rs`, stay
  for framing, exact statuses, hostile input and polling. WebSocket
  goes through tungstenite's client role.
  So a fault in ko's own framing cannot hide behind the same code on
  both ends. tungstenite is on both ends, as gorilla was not; the
  hostile tests send raw frame bytes and check raw replies, which
  covers the framing that ko does not delegate.
- **Snapshots** are decoded by calling `ko_vt`'s decoder in the test
  process, so `ko_vt/examples/decode.rs` and `KO_DECODE` go.
- **The client tests**: the test is the outer terminal. It opens a
  pty with `ko_sys::pty`, starts `ko` on the slave, and feeds
  everything the client writes into a `ko_vt::Terminal` whose
  replies (`Terminal::replies`) the pty thread writes back into the
  master, as a real terminal answers DA1, DECRQM and the kitty
  keyboard query. Keys are bytes written to the master; the screen,
  the cursor and the modes that the Go tests read from tmux
  (`#{pane_private_modes}`, the mouse and SGR flags) are read from
  that terminal; the raw output that `pipe-pane` captured is the bytes
  themselves. For the two tests of the warning
  (`TestClientAttachOrStartAndWarning`, `TestClientWarningMouseBounds`)
  and the narrow terminal of `TestClientSidebarOwnership`, the Go
  outer tmux without extended keys, the harness drops the kitty query
  (`CSI ? u`) before the terminal sees it, as tmux did. The pty is read on a test thread. This
  removes ko's last use of the tmux fork without an outer server.
- **Parallelism**: every test calls its own server on its own state
  directory, and the one test binary (decision 119) runs every test
  on a thread pool, as `t.Parallel()` does. A state directory is a
  new mode-0700 directory under `/tmp`, named by the pid, a counter
  and the time, so a socket path stays under the 104-byte macOS
  limit. The harness scrubs the
  environment as `internal/e2eenv` does: a private `HOME`,
  `XDG_CONFIG_HOME`, `XDG_STATE_HOME`, no `ZDOTDIR`, `ENV`, `BASH_ENV`,
  `PROMPT_COMMAND`, `KO_*`, `KIDO_*` or exported bash functions.
- **Wait for the event, not for a time**: every wait reads a socket
  or polls a condition until it holds, with a 5 s deadline; there is
  no sleep. `scripts/lint.sh` refuses `thread::sleep` in `ko_e2e/`
  except through its table of exact statements, as it does for
  `time.Sleep` in Go.
- **Signals**: a test signals a process that it spawned through its
  `Pid`, and any other process only if it descends from the server
  that the test started or from the outer terminal's shell, through `ko_sys::pid::signal_descendant(root,
  pid, signal)`, which walks the parent chain (at most 64 hops) as
  `signal_test.go`'s `signalOwned` does and then calls `Pid::signal`.
  It is behind the cargo feature `e2e` of `ko_sys` (decision 120),
  which only `ko_e2e` enables, so the one `kill` stays in `pid.rs`.
- **Crates**: none new. `ko_e2e`'s dev-dependencies are `httparse`,
  `tungstenite`, `serde_json` and the workspace crates `ko_sys`,
  `ko_vt` and `ko_pane_wire` (the terminal's `Dim`, `Limits` and
  `Size`).
- **The mapping**, one Rust module in `ko_e2e/tests/e2e/` per Go
  file, one test per Go test with its name in snake case without
  `Test`:

| Go file | Go tests | Rust file |
|---|---|---|
| `protocol_test.go` | `TestPaneDeadSnapshot`, `TestViewResumeResizeAndInput`, `TestKillServer`, `TestKillServerSignalsByPeerPID`, `TestVersionAndOrigin`, `TestApi` | `tests/e2e/protocol.rs` |
| `review_test.go` | `TestFullSnapshotSlowReader`, `TestPasteThenEnterDuringSnapshot`, `TestPaneProcessFailure`, `TestUnfocusedFirstClientSizesPane`, `TestStalledViewLearnsResizeAfterRingRetention`, `TestResumeSkipsResizeMarkersBeforeTheOffset`, `TestDeathHasOneTimestamp` | `tests/e2e/review.rs` |
| `state_test.go` | `TestLiveSynchronizedSnapshotAndHistory`, `TestUnsafePasteIsNotWritten`, `TestSIGTERMKillsPrograms`, `TestClientCloseClosesItsViews`, `TestScrollbackLinesLimit`, `TestPaneProcessCrashKillsProgram` | `tests/e2e/state.rs` |
| `streams_test.go` | `TestStalledViewSkips`, `TestDetachKeepsKittyInput`, `TestPartialResizeSnapshot` | `tests/e2e/streams.rs` |
| `hostile_test.go` | `TestHostileClientsDoNotAffectOthers`, `TestClientGridLimit` | `tests/e2e/hostile.rs` |
| `input_frames_test.go` | `TestViewInputFramesInOneWrite`, `TestViewInputFrameSplitAcrossWrites` | `tests/e2e/input_frames.rs` |
| `config_test.go` | `TestDefaultsAndPaneEnvironment`, `TestFuzzVariablesDoNotReachTheBinary` | `tests/e2e/config.rs` |
| `client_test.go` | the 16 `TestClient*` of 4.2 | `tests/e2e/client.rs` |
| `idle_test.go` | `TestNoIdleWakeups` (decision 118) | `tests/e2e/idle.rs` |
| `signal_test.go` | the `signalOwned` and `gone` helpers | `ko_sys::pid::signal_descendant`, `Pid::has_ended` (feature `e2e`) |

  This is the mapping of the port. The trim of decision 124 merged or
  removed 16 of these tests and moved the rest into other modules;
  the suite has 29.

- When every row of the table passes in the final local `make
  verify` on macOS (decision 122), the same change deletes
  `test_e2e_ko/`, `internal/rusage/` and the `decode` example, and
  `make e2e-ko` runs the Rust suite. `go.mod`, `go.sum` and
  `internal/e2eenv/` stay, because kido's `test_e2e/` uses them.
- Acceptance: the Rust suite's 45 tests (decision 118) pass on
  macOS; its wall time is not more than the Go suite's on the same
  machine.
- Result (2026-11-02, macOS): 45 of 45 Go tests ported and passing.
  Wall time, back to back with `make build-ko` in each: Go 6.51 s,
  Rust 6.47 s (both 45 of 45), before the review; after the review,
  with `--test-threads=64`, the Rust tests take 5.70 s, most of it
  the 5 s window of `no_idle_wakeups`. The final `make verify` with
  ko's stages added passed: build 1.0 s, unit 2.5 s, e2e 17.9 s,
  e2e-ko 5.9 s, ts 8.1 s, unit-ko 12.4 s, lint 1.8 s, verus 5.2 s.
  Two client tests stay flaky. `client_dead_pane_line` (the Go
  suite's known flake) failed in about 1 of 5 runs of the suite, and
  `client_lifecycle` in 2 of about 30. In both, ko's client wrote the
  sidebar but never the pane's content, and the raw bytes from the
  client show it, so the cause is in ko, not in the harness. The
  review found one more failure path of `client_dead_pane_line`: the
  client can paint the layout, with the dead line, before the pane's
  snapshot arrives, and the test fails at once when no output is
  directly above the line. The test keeps the Go semantics.
- Trim (decision 124, 2026-11-02, macOS): 29 tests. The tests take
  2.66 s, not 5.80 s, and the `e2e-ko` stage of `make verify-ko`
  2.9 s, not 8.9 s. The final `make verify-ko` passed: build 0.2 s,
  unit-ko 11.1 s, e2e-ko 2.9 s, lint 1.8 s, verus 5.0 s.

### RW. The serde wire (about 1 agent-day, after RE)

Decision 25. One change applies every row of 2.6:

- `protocol.rs` and `config.rs`: `#[serde(tag = "type", rename_all =
  "snake_case")]` on the 10 enums, the named fields of 2.6, the
  flattened `error_kind`; the `compact!` macro and its tests go.
- The protocol version goes from 1.0 to 2.0 in `protocol.rs`: a
  changed field encoding is a MAJOR change by protocol.md 13 ("a field
  changed in meaning"). A 1.x client gets the mismatch refusal, whose
  `kind` and `message` stay where they were (2.6).
- `rfc/kido-server/protocol.md`: every JSON example and shape
  description of the changed types, and the version in its examples.
  The manager writes it.
- `ko_tui`: no code change beyond the derives, because it uses the
  types of `protocol.rs`; its tests' JSON literals change.
- `ko_e2e/`: its request and event literals, and the hostile tests'
  JSON bodies.
- `bench/client.py`: the four sends of 2.6 and its `Ko-Protocol`
  header (`"1.0"` to `"2.0"`).
- The `decode` and `http` fuzz corpora, converted by a one-off script
  (decision 151), not merged with `make fuzz MERGE=1`.
- Acceptance: `make verify` green (with ko's stages, decision 152);
  `grep` finds no `compact!` and no `["`-form wire value in `ko_e2e/`,
  `bench/`, protocol.md and the tests (except inputs that a test
  refuses); version 2.0 everywhere; a test shows the refusal of a 1.x
  client.

### RV3. Verus: `view.rs` (5 to 8 agent-days, after RV2)

Decision 15. The view's cursor, resume, snapshot and flush rules from
`ko_proofs/View_core.fst`, verified at the call sites in `view.rs` and
`conn.rs` (decisions 95 to 100). Acceptance: `cargo verus verify -p
ko_server` passes on `view` within the cap of decision 18.
`ko_proofs/` keeps `View_core.fst` and its contracts as the
specification (decision 111).
- Result (2026-11-02, macOS): `ko_server` verifies with 81
  obligations (1.6 s) and `ko_pane_wire` with 132 (1.4 s), no
  `assume` and no `admit`; the `verus` stage takes 4.3 s. The
  stripped release `ko` grew by 16,504 bytes (2,674,040 to
  2,690,544); `ko-pane` did not change. Decisions 95 to 100 came
  from RV3.

### RL. Linux (3 to 5 agent-days, last, after parity)

Decision 26. Every earlier stage is macOS-only; RL makes the Rust ko
build and pass on Linux.

- The Linux build: `ko_vt_sys/build.rs` links `stdc++` (as
  `ko_vt/cxx.sh` did), the Makefile's platform choice builds the Rust
  ko on Linux, `scripts/ci-like/Dockerfile` installs the toolchain of
  `rust-toolchain.toml`.
- The Linux halves of `ko_sys`: `SO_PEERCRED` for the peer uid and
  pid, `memfd_create` for the ring mapping, `/proc/<pid>/stat` for
  the process identity of `Group::verify`, `ppoll` for exact
  sub-millisecond deadlines (row 37), `ECONNRESET` as the end of a
  source (row 44), each with its unit test on Linux.
- Linux CI for the Rust ko: the Ubuntu runner gets the macOS steps
  of 4.4 and runs `make verify-ko`, the `verus` stage included;
  `ko-nightly.yml` adds Ubuntu.
- The idle-wakeup row of section 7's bench table with `strace -c`.
- Acceptance: `make verify-ko` green on Ubuntu in
  `scripts/ci-like.sh`, and on both runners in CI on the first push
  of `ko-rust` (decision 27), which measures the job time; the ko e2e suite of that time passes on
  Ubuntu, `TestHostileClientsDoNotAffectOthers` with its
  `ECONNRESET` case included.

### Totals

| stage | agent-days |
|---|---|
| R0 toolchain and oracle | 2 |
| R1 the loop and the coordinator core, against the C `ko-pane` | 5 to 6 |
| R2 HTTP framing, WebSocket, views | 5 to 7 |
| RP `ko-pane` in Rust | 4 to 6 |
| R3 harness, fuzz, Miri, bench | 4 to 5 |
| R4 terminal client | 7 to 9 |
| R5 one implementation, one language | 2 to 3 |
| total to one implementation | 29 to 38 |
| RE the e2e suite in Rust, after R5 | 6 to 8 |
| total with RE | 35 to 46 |
| RW the serde wire, after RE | about 1 |
| total with RE and RW | 36 to 47 |
| RV Verus: the ring and the handshake, beside R3 and R4 | 6 to 9 |
| RV2 Verus: `deliver`, `scan`, `keep` | 3 to 5 |
| RV3 Verus: `view.rs` | 5 to 8 |
| RL Linux, last, after parity | 3 to 5 |

The own I/O adds about 250 lines of loop and 370 of HTTP framing
(server and client) over the crate-based plan, and the client loses
its reader thread for an in-memory decode; at 350 lines per agent-day
that is the 2 to 3 agent-days by which R1, R2 and R4 grew. RP shrinks
by one day because `ko-pane` uses the shared loop.

Plus review and verification under the usual manager, implementer
and reviewer structure. R1's loop comes first; the HTTP framing of R2
can start beside the rest of R1; RP needs R2; R3's harness needs RP; RV needs RP; RV2 needs
RV; RV3 needs RV2; RE needs R5; RW needs RE; RL comes last, after
every other stage. With two managers, the Verus stages are off the
critical path, which stays R0, R1, R2, RP, R3, R4, R5, RE, RW, RL.

## 8. Rust code rules for AGENTS.md

R0 moved into AGENTS.md, "Rust (ko)", the rules that its code obeys.
Each later stage moves the bullets for its code when that code
lands. The text below is the whole set.
The general rules (no backward compatibility, plain functions
over data, minimal line count, module boundaries, one source of
truth, no comments) apply as they are.

---

## Rust

These requirements are fixed:

- **Layout.** One cargo workspace at the root. `ko/src/main.rs`
  holds the command table and the small command bodies; it prints
  and returns exit codes. `ko_server/` is the coordinator library,
  `ko_tui/` the terminal client library, `ko_pane/` the pane
  process, `ko_pane_wire/` the frame codec and the ring that both
  processes share, `ko_vt/` the libghostty-vt API over `ko_vt_sys/`,
  `ko_sys/` the OS layer, `ko_bench/` the benchmarks, `fuzz/` the
  cargo-fuzz crate. There is no C of ko's own.
- **Toolchain.** `rust-toolchain.toml` pins 1.99.1, the toolchain of
  the pinned Verus release; they move together. Homebrew's keg-only
  `rustup` provides it; the Makefile puts its `bin` first on PATH, and
  every cargo command runs through a Makefile target. Every cargo
  command passes `--locked`. `Cargo.lock` is committed. Nightly
  exists only in `scripts/fuzz.sh` and `scripts/miri.sh`.
- **Dependencies.** The production crates are `libc`, `httparse`,
  `tungstenite` (feature `handshake` only), `serde` (`derive`),
  `serde_json`, `vte`, `clap` (the features of decision 46), and `vstd` (pinned with `=` to the Verus
  release) in the verified crates. `proptest` and `loom` are
  dev-dependencies;
  `libfuzzer-sys` and `arbitrary` belong to `fuzz/`.
  `scripts/crates.txt` lists every package of `Cargo.lock`, and
  `scripts/lint.sh` fails on a package that the list does not name.
  A new direct crate, or a new feature that adds packages, is a
  decision for the user, with the hand-written cost in the request.
  No async runtime and no crate that needs one: no `tokio`,
  `hyper`, `mio`, `futures`, `async-std` or `smol`, and no `async fn`
  in ko's code.
- **Formatting and lints.** `cargo fmt` with `rustfmt.toml`
  (`max_width = 100`). `cargo clippy --all-targets -- -D warnings`
  is clean. Library crates deny `unsafe_code` (except the three
  modules below), `unreachable_pub`, `clippy::unwrap_used`,
  `clippy::expect_used`, `clippy::panic`, `clippy::todo`,
  `clippy::unimplemented`, `clippy::undocumented_unsafe_blocks` and
  `unsafe_op_in_unsafe_fn`. The readers of untrusted bytes
  (`pane_proc`, `ring`, `link`) also deny
  `clippy::indexing_slicing` and `clippy::arithmetic_side_effects`:
  they use `get`, `checked_add` and `split_at_checked`.
- **The command line is a contract** with `test_e2e_ko/`, `bench/`
  and `share/`. A long option is `--name`.

Conventions:

- **No panics in library code.** A library function returns
  `Result`. `unwrap`, `expect`, `panic!`, indexing on untrusted
  lengths and unchecked arithmetic on wire values do not appear
  outside tests. The release profile sets `panic = "abort"` and
  `overflow-checks = true`: a panic is a bug, and a loud stop with a
  core is better than a half-state. Tests may `unwrap`.
- **Errors.** `std::io::Error` carries an OS error and propagates
  with `?`. A message to print is a `String` error. If
  callers distinguish cases, the module defines an enum and
  implements `Display` by hand. No `anyhow`, no `thiserror`, no
  `Box<dyn Error>` in ko's code. A crate's error (httparse,
  tungstenite, serde_json) becomes an `ErrorKind` at the edge that
  received it.
- **Visibility is the `.mli`.** An item is `pub` only when another
  crate uses it and `pub(crate)` only when another module does.
  `lib.rs` lists modules; it re-exports nothing. `unreachable_pub`
  and `dead_code` are denied, so an unused export fails the build.
- **The e2e suite** is `ko_e2e/` (RE): it drives the built binaries
  over the wire with its own byte-level client, waits for events with
  a deadline and never sleeps, and signals only descendants of its own
  server through `ko_sys::pid::signal_descendant`.
- **Tests** are `#[cfg(test)] mod tests` at the bottom of the file
  under test. Expectations are `assert_eq!` on values or strings.
  Property tests use proptest in the same module; a found case is a
  committed regression in `proptest-regressions/`. No test execs the
  binary; the Go suite does that.
- **Derives.** Every type derives `Debug`. `Clone`, `Copy`,
  `PartialEq`, `Eq` where the type is a value. `PartialOrd` and
  `Ord` only where the order means something (`Pos`, `Offset`,
  ids). `Default` only when every field has a meaningful default.
  `Hash` only for a map key.
- **Newtypes.** A value with its own rules is a newtype with a
  private field and one validating constructor: `Pid`, `Dim`,
  `PaneId`, `ClientId`, `Pos`, `Offset`, `Mono`. A closed set is an
  `enum`. "Unknown" is `None`; "disabled" is a variant.
- **JSON.** serde derives every codec; `protocol.rs` owns the wire
  types. An enum with payloads has `#[serde(tag = "type",
  rename_all = "snake_case")]`; a primitive, list, id or enum payload
  is a struct variant with one named field (2.6). A unit enum
  uses `rename_all = "snake_case"`. An option field has
  `#[serde(default, skip_serializing_if = "Option::is_none")]`. Only
  the ids validate, through `try_from = "String"`. No codec is
  written by hand, and no code walks a
  `serde_json::Value` to decode a wire type. Decoding errors are
  handled only at an untrusted-input edge: an HTTP body or a
  WebSocket text message.
- **Unsafe.** `unsafe` is permitted in `ko_sys`, `ko_vt_sys`'s
  generated file and `ko_pane_wire::ring::mapping`; `ko_pane`,
  `ko_server` and `ko_tui` deny it. A forked child calls only
  async-signal-safe functions until `execve`, and a signal handler only writes its
  pipe. Each block has a
  `// SAFETY:` line that names the invariant. A safe wrapper takes
  typed arguments (`BorrowedFd`, `Pid`, `Duration`) and returns
  `Result`. No raw `i32` descriptor crosses a module boundary;
  descriptors are `OwnedFd` and `BorrowedFd`. A callback from
  libghostty-vt never unwinds and never re-enters the terminal.
- **Atomics.** The ring header's loads and stores are `SeqCst`. No
  other `Ordering` exists in `ko_server`; lint greps for it.
- **Signals.** `libc::kill` exists only in `ko_sys/src/pid.rs`.
  `Pid::new` refuses 1 or less, values over `i32::MAX`, the own pid
  and the own group. A `Group` exists only after `Group::verify`
  saw the OS's answer (the coordinator), or as `Group::spawned` for
  the child that `pty::spawn` returned after `exec` and whose zombie
  `ko-pane` holds (`ko-pane`); `Group::signal` checks the start time
  again. Tests signal only through `Pid`, and never a pid they did
  not create. `scripts/lint.sh` refuses every other call, in Rust,
  C, Go and Python.
- **Syscalls.** Every own libc call that can return `EINTR` goes
  through `ko_sys::retry`; an `EINTR` from `poll` is a turn with no
  events. A read of zero bytes is EOF; `WouldBlock` is "not ready".
  Signal handlers are installed with `SA_RESTART`, as the
  reference's are, but no call relies on it.
- **Fuzz variables.** `KO_FUZZ_*` is read only in `fuzz/` and in test
  modules; the shipped binaries read no fuzz or test variable
  (`defaults_and_pane_environment` in `ko_e2e`).
- **The loop and threads.** Every process is one thread on
  `ko_sys::event`: non-blocking descriptors, one state enum per
  connection, a read buffer and a write queue per connection, the
  next deadline as the `poll` timeout and none without one. Signals
  reach the loop only through the self-pipe. Back-pressure is the
  interest: a source that must not be read loses `IN`. A handler gets
  the process's one state struct as `&mut`; no `Rc<RefCell<..>>`, no
  callback registered with the loop. The only extra thread is the
  client's compressor, which shares the mirror under a `Mutex` and
  wakes the loop through a pipe.
- **The view write path.** A view record is written by `conn.rs`
  with `write_vectored` over `IoSlice`s that borrow the ring, only
  while the connection's queue is empty; a partial write copies the
  rest into the queue. Every other byte of a WebSocket goes through
  tungstenite into the same queue. No other code writes a
  connection's fd.
- **HTTP.** `http.rs` is the only code that reads or writes HTTP
  framing, for the server and the client. httparse parses heads; a
  head's limit is 16 KiB of bytes per request, and pipelined requests
  are answered in order, a `431` included.
- **Time.** `Mono(u64)` is nanoseconds of `CLOCK_MONOTONIC`
  (`CLOCK_UPTIME_RAW` on macOS, as `ko_now_ns` uses) on the wire;
  the loop's deadlines are `std::time::Instant`. Timeouts are `Duration` arguments, not
  statics.
- **FFI bindings.** `ko_vt_sys/src/bindings.rs` is generated by
  `scripts/bindgen.sh` from `third_party/ghostty/include` and
  committed with the header hash. A change of the ghostty pin
  regenerates it in the same commit; lint checks the hash.
- **The pane process.** `ko_pane_wire::frame` is the one source of
  the frame kinds, `MAX_FRAME` and `MAX_DIMENSION` for both
  processes. `ko-pane` has no policy. It runs on `ko_sys::event`
  like every process, and a panic aborts it, which ends one pane.
- **Verus.** A verified crate has `[package.metadata.verus] verify =
  true` and builds with plain cargo. Specs and proofs live inside
  `verus!{}` beside the code they describe. `cfg(verus_only)` guards
  only `use` statements. An `external_body` function is trusted
  base: each has a `// SAFETY:`-style line that names what it
  assumes, and none has an unconditional `ensures` that its body
  does not establish. `make verus` passes before a change to a
  verified module lands.

---

## 9. Open questions for the user

None: the user has answered every question, and the answers are the
Decisions at the top.
