module Connection
#lang-pulse
open Pulse.Lib.Pervasives
module O = Oint

(* ko_server/connection.mli as the proved view uses it. The model is only what
   the view relies on: whether the connection is closed or waiting, and how
   many byte ranges are batched. *)

[@@custard_extern "Connection.t"]
new val t : Type0

type written = | Accepted | Queued | Blocked | Closed

[@@custard_extern "Connection.batch_capacity"]
val batch_capacity : n: O.t{0 < O.v n /\ O.v n <= 1024}

noeq type cs = { closed: bool; waits: bool; bcount: int }

let conn_ok (s: cs) : prop = 0 <= s.bcount /\ s.bcount <= O.v batch_capacity

val conn (c: t) (s: cs) : slprop

let closed_now (s: cs) : cs = { s with closed = true }

[@@custard_extern "Connection.close"]
val close (c: t) (#s: erased cs)
  : stt unit (conn c s) (fun _ -> conn c (closed_now s))

[@@custard_extern "Connection.available"]
val available (c: t) (#s: erased cs)
  : stt bool (conn c s) (fun b -> conn c s ** pure (b ==> not s.closed /\ not s.waits))

[@@custard_extern "Connection.waiting"]
val waiting (c: t) (#s: erased cs)
  : stt bool (conn c s) (fun b -> conn c s ** pure (b <==> s.waits))

[@@custard_extern "Connection.batch_count"]
val batch_count (c: t) (#s: erased cs)
  : stt O.t (conn c s) (fun n -> conn c s ** pure (O.v n == s.bcount))

[@@custard_extern "Connection.batch_full"]
val batch_full (c: t) (#s: erased cs)
  : stt bool (conn c s) (fun b -> conn c s ** pure (b <==> s.bcount == O.v batch_capacity))

(* The kernel took the first [n] batched ranges; -1 means the connection closed. *)
let sent (s s': cs) (n: int) : prop =
  -1 <= n /\ n <= s.bcount /\ (n == -1 ==> s'.closed) /\ s'.bcount == 0 /\ (s.closed ==> s'.closed)

[@@custard_extern "Connection.batch_send"]
val batch_send (c: t) (b: Ring.buffer) (#s: erased cs{conn_ok s})
  : stt O.t (conn c s) (fun n -> exists* s'. conn c s' ** pure (sent s s' (O.v n)))
