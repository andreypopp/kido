# ko: upgrade in place

Status: plan. The one open stage of ko after the cut-over. Until it is
built, an upgrade of `ko` restarts the server and ends its panes.

Terminal state lives in the pane processes, so a coordinator upgrade
moves none of it. `ko upgrade` (sent by the launcher when the binary
differs from the running coordinator, or by Kido.app's Restart) does:

1. The coordinator stops accepting clients and stops reading the pane
   control sockets.
2. It writes `<dir>/upgrade/state.json` (serde): the layout document
   and its revision, panes with their ring and control descriptor
   numbers, ring tails and `ko-pane` pids, their variables, run ties,
   OSC 7501 records, OSC 133 phases, the `instance` of the `Welcome`
   event (so a client's reconnect sees the same server) and the
   shared-memory name counter (the pid stays, so names would collide).
   The ring is not written; views reopen with a snapshot.
3. It clears `CLOEXEC` on the rings, the control sockets and the
   listening socket and `execve`s the new binary with
   `--resume-upgrade <dir>/upgrade`. The pid stays, so the pane
   processes stay children and `waitpid` works; connects queue on the
   inherited listener instead of failing.
4. The new binary reads the state, maps the rings, resumes reading the
   control sockets, and clients reconnect: each sends a new hello and
   reopens its views with snapshots. Client connections are not
   inherited; a client is its connection.

A `ko-pane` upgrade (a libghostty-vt bump) is separate and for each
pane: the coordinator asks the old process for a full snapshot into a
0600 file, starts a new `ko-pane` on the same pty master (passed over
the control socket with `SCM_RIGHTS`, a new `master` frame, and
`sendmsg` and `recvmsg` added to `ko_sys/src/sock.rs`), which decodes the file with
the continuation retained, then closes the old one. A pane whose
snapshot fails to decode (a snapshot format change) gets an empty
terminal with the modes, kitty flags, title and pwd that the
coordinator knows, and keeps its program. The user loses the screen
and scrollback of that pane; input keeps working because the modes
are back. The coordinator does this one pane at a time, idle panes
first, and never for a pane in the alternate screen unless asked.

A crash of the coordinator still kills the panes. A `ko-pane` could
survive one if it listened on its own socket for a new coordinator;
that is a daemon, and the user decided against it (2026-10-30).

The Verus item: the inherited ring breaks the assumption of
`Backend::mint_reader` in `ko_pane_wire/src/ring/backend.rs` that the
reader created a zero-filled mapping. This stage adds one trusted
constructor that adopts a ring at a recorded tail, with its
`// Assumes:` line, and nothing else in the proofs changes.

Order: a spike first (about one agent-day): a toy coordinator with two
`ko-pane` children, the state file, the exec, mapping the rings and
reading the control sockets, on macOS and Linux; and a `ko-pane`
handoff of the pty master over `SCM_RIGHTS`. Then the stage, 7 to 10
agent-days. A failure of the exec path falls back to a normal restart,
which kills the panes.
