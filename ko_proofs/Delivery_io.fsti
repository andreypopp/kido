module Delivery_io
#lang-pulse
open Pulse.Lib.Pervasives
open KoRing.Spec
open KoRing.Inv
open Feed
module O = Oint
module R = Ring
module C = Connection
module P = Protocol

(* The I/O the proved cores call besides Ring and Connection, realized by
   ko_server/delivery_io.ml. Everything here is trusted. *)

[@@custard_extern "Delivery_io.slice_last"]
val slice_last (h: R.t) (pos: O.t) (#g: erased gst)
  (#rg: erased rghost{R.vis rg (O.v pos) /\ R.kind_of rg (O.v pos) == R.Slice})
  : stt bool (R.res h g rg) (fun _ -> R.res h g rg)

[@@custard_extern "Delivery_io.is_resize"]
val is_resize (h: R.t) (pos: O.t) (#g: erased gst)
  (#rg: erased rghost{R.vis rg (O.v pos) /\ R.kind_of rg (O.v pos) == R.Marker})
  : stt bool (R.res h g rg) (fun _ -> R.res h g rg)

(* A view's snapshot request: its number, and its slice and done callbacks,
   which reach the view of generation [tgen] on ring [tring]. *)
[@@custard_extern "Delivery_io.token"]
new val token : Type0
val tgen (t: token) : GTot int
val tring (t: token) : GTot R.t

[@@custard_extern "Delivery_io.req"]
val req (t: token) : O.t

[@@custard_extern "Delivery_io.slice"]
val slice (t: token) (pos: O.t) (h: erased R.t) (#g: erased gst) (#rg: erased rghost)
  (#prior #now: erased st)
  : stt unit
    (R.res h g rg **
     pure (tring t == reveal h /\ slice_step prior now (tgen t) (O.v pos) /\ R.vis rg (O.v pos) /\
           R.kind_of rg (O.v pos) == R.Slice))
    (fun _ -> R.res h g rg)

(* The view's done callback runs once the pane operation returns. *)
[@@custard_extern "Delivery_io.finish"]
val finish (t: token) (ok: bool) (h: erased R.t) (#g: erased gst) (#rg: erased rghost)
  (#prior: erased st)
  : stt unit
    (R.res h g rg ** pure (tring t == reveal h /\ ~(Absent? prior) /\ (ok ==> done_step prior (tgen t) rg)))
    (fun _ -> R.res h g rg)

(* The pane's queues: requests waiting for slices with their floors, and
   finished requests waiting for snapshot_done with their holds. *)
[@@custard_extern "Delivery_io.pane_io"]
new val pane_io : Type0
noeq type queues = { qs: Seq.seq (token & int); fs: Seq.seq (token & int) }
val pio (io: pane_io) (q: queues) : slprop

let empty_queues : queues = { qs = Seq.empty; fs = Seq.empty }

[@@custard_extern "Delivery_io.pane_io_create"]
val pane_io_create (_: unit) : stt pane_io emp (fun io -> pio io empty_queues)

[@@custard_extern "Delivery_io.queue_empty"]
val queue_empty (io: pane_io) (#q: erased queues)
  : stt bool (pio io q) (fun b -> pio io q ** pure (b <==> Seq.length q.qs == 0))

[@@custard_extern "Delivery_io.queue_front"]
val queue_front (io: pane_io) (#q: erased queues{Seq.length q.qs > 0})
  : stt token (pio io q) (fun t -> pio io q ** pure (t == fst (Seq.index q.qs 0)))

[@@custard_extern "Delivery_io.queue_floor"]
val queue_floor (io: pane_io) (#q: erased queues{Seq.length q.qs > 0})
  : stt O.t (pio io q) (fun n -> pio io q ** pure (O.v n == snd (Seq.index q.qs 0)))

[@@custard_extern "Delivery_io.queue_push"]
val queue_push (io: pane_io) (t: token) (floor: O.t) (#q: erased queues)
  : stt unit (pio io q) (fun _ -> pio io { q with qs = Seq.snoc q.qs (t, O.v floor) })

[@@custard_extern "Delivery_io.queue_pop"]
val queue_pop (io: pane_io) (#q: erased queues{Seq.length q.qs > 0})
  : stt unit (pio io q) (fun _ -> pio io { q with qs = Seq.tail q.qs })

[@@custard_extern "Delivery_io.queue_to_fin"]
val queue_to_fin (io: pane_io) (hold: O.t) (#q: erased queues{Seq.length q.qs > 0})
  : stt unit (pio io q)
    (fun _ -> pio io { qs = Seq.tail q.qs; fs = Seq.snoc q.fs (fst (Seq.index q.qs 0), O.v hold) })

[@@custard_extern "Delivery_io.fin_empty"]
val fin_empty (io: pane_io) (#q: erased queues)
  : stt bool (pio io q) (fun b -> pio io q ** pure (b <==> Seq.length q.fs == 0))

[@@custard_extern "Delivery_io.fin_front"]
val fin_front (io: pane_io) (#q: erased queues{Seq.length q.fs > 0})
  : stt token (pio io q) (fun t -> pio io q ** pure (t == fst (Seq.index q.fs 0)))

[@@custard_extern "Delivery_io.fin_hold"]
val fin_hold (io: pane_io) (#q: erased queues{Seq.length q.fs > 0})
  : stt O.t (pio io q) (fun n -> pio io q ** pure (O.v n == snd (Seq.index q.fs 0)))

[@@custard_extern "Delivery_io.fin_pop"]
val fin_pop (io: pane_io) (#q: erased queues{Seq.length q.fs > 0})
  : stt unit (pio io q) (fun _ -> pio io { q with fs = Seq.tail q.fs })

(* The view's side. *)

[@@custard_extern "Delivery_io.reject_io"]
val reject_io (c: C.t) (#s: erased C.cs)
  : stt unit (C.conn c s) (fun _ -> C.conn c (C.closed_now s))

(* Batch the bytes of the Bytes record at [pos] from [skip] on. *)
[@@custard_extern "Delivery_io.batch_add"]
val batch_add (c: C.t) (offset at len: O.t) (#h: erased R.t) (#pos: erased int)
  (#rg: erased rghost{R.vis rg pos /\ R.kind_of rg pos == R.Bytes}) (#skip: erased int) (#s: erased C.cs)
  : stt unit
    (C.conn c s **
     pure (C.conn_ok s /\ s.C.bcount < O.v C.batch_capacity /\
           0 <= reveal skip /\ reveal skip <= (R.rec_of rg pos).len /\
           O.v offset == (R.rec_of rg pos).off + skip /\
           O.v at == R.body h pos + skip /\ O.v len == (R.rec_of rg pos).len - skip))
    (fun _ -> C.conn c { s with C.bcount = s.C.bcount + 1 })

let kept (s s': C.cs) : prop = s'.C.bcount == 0 /\ (s.C.closed ==> s'.C.closed)

(* The marker record at [pos], sent at its offset. *)
[@@custard_extern "Delivery_io.json_marked"]
val json_marked (c: C.t) (h: R.t) (pos: O.t) (offset: O.t) (#g: erased gst)
  (#rg: erased rghost{R.vis rg (O.v pos) /\ R.kind_of rg (O.v pos) == R.Marker}) (#s: erased C.cs)
  : stt unit
    (C.conn c s ** R.res h g rg ** pure (s.C.bcount == 0 /\ O.v offset == (R.rec_of rg (O.v pos)).off))
    (fun _ -> exists* s'. C.conn c s' ** R.res h g rg ** pure (kept s s'))

(* A skip from [from] to [head]. *)
[@@custard_extern "Delivery_io.json_skipped"]
val json_skipped (c: C.t) (head from: O.t) (#s: erased C.cs)
  : stt unit (C.conn c s ** pure (s.C.bcount == 0 /\ O.v from <= O.v head))
    (fun _ -> exists* s'. C.conn c s' ** pure (kept s s'))

(* A snapshot slice. *)
[@@custard_extern "Delivery_io.record"]
val record (c: C.t) (b: R.buffer) (offset at len: O.t) (#h: erased R.t) (#pos: erased int)
  (#rg: erased rghost{R.vis rg pos /\ R.kind_of rg pos == R.Slice}) (#s: erased C.cs)
  : stt C.written
    (C.conn c s **
     pure (s.C.bcount == 0 /\ O.v offset == (R.rec_of rg pos).off /\
           O.v at == R.body h pos /\ O.v len == (R.rec_of rg pos).len))
    (fun w -> exists* s'. C.conn c s' ** pure (kept s s' /\ (C.Closed? w ==> s'.C.closed)))

(* A view asks its pane for a snapshot; the pane answers through the view's
   token. *)
[@@custard_extern "Delivery_io.view_io"]
new val view_io : Type0

(* The pane notes the request, which loads the head. *)
[@@custard_extern "Delivery_io.request"]
val request (io: view_io) (hist: P.history) (gen: O.t) (h: erased R.t) (#g: erased gst) (#rg: erased rghost)
  : stt bool (R.res h g rg) (fun _ -> exists* rg'. R.res h g rg' ** pure (R.sane h rg ==> R.loaded h rg rg'))
