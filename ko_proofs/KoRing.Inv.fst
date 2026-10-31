module KoRing.Inv
#lang-pulse
open Pulse.Lib.Pervasives
open KoRing.Spec
open KoRing.Mask
module U8 = FStar.UInt8
module U64 = FStar.UInt64
module A = Pulse.Lib.Array
module GR = Pulse.Lib.GhostReference
module Seq = FStar.Seq

(* The mapping's header and data, as the C struct ko_ring lays them out. *)
noeq type ring = {
  cap: c: U64.t { min_cap <= U64.v c /\ U64.v c <= max_cap };
  head: ref U64.t;
  tail: ref U64.t;
  read: ref U64.t;
  data: d: A.array U8.t { A.length d == U64.v cap };
}

let capn (r: ring) : capt = U64.v r.cap

(* The writer's ghost: the tail it last loaded and the log it has published. *)
noeq type wghost = { wt: nat; lw: log }
(* The reader's ghost: the tail it stored and the log it saw at its last head load. *)
noeq type rghost = { tl: nat; lr: log }

[@@erasable]
noeq type gst = { gw: GR.ref wghost; gr: GR.ref rghost; i: iname }

let inv_facts (cap: capt) (w: wghost) (g: rghost) (hv tv rv: U64.t) (s2 s3: bytes) : prop =
  U64.v hv == w.lw.hd /\ U64.v tv == g.tl /\ U64.v rv <= w.lw.hd /\
  wf cap w.lw /\ wf cap g.lr /\ log_le g.lr w.lw /\
  w.wt <= g.tl /\ g.tl <= g.lr.hd /\ w.lw.hd <= w.wt + cap /\
  boundary g.lr g.tl /\
  Seq.length s2 == cap /\ Seq.length s3 == cap /\
  hdr_ok cap w.lw s2 g.lr.hd w.lw.hd /\
  inited s2 (rng cap g.lr.hd w.lw.hd) /\ inited s3 (rng cap (w.wt + cap) (g.tl + cap))

(* Held in the invariant: the three indices, the published bytes the reader
   has not seen yet, and the bytes the reader released that the writer has
   not taken yet. *)
let ring_inv (r: ring) (gw: GR.ref wghost) (gr: GR.ref rghost) : slprop =
  exists* (w: wghost) (rg: rghost) (hv tv rv: U64.t) (s2 s3: bytes).
    GR.pts_to gw #0.5R w ** GR.pts_to gr #0.5R rg **
    pts_to r.head hv ** pts_to r.tail tv ** pts_to r.read rv **
    A.pts_to_mask r.data s2 (rng (capn r) rg.lr.hd w.lw.hd) **
    A.pts_to_mask r.data s3 (rng (capn r) (w.wt + capn r) (rg.tl + capn r)) **
    pure (inv_facts (capn r) w rg hv tv rv s2 s3)

ghost
fn gather_half (#t: Type0) (r: GR.ref t) (#x #y: erased t)
  requires GR.pts_to r #0.5R x
  requires GR.pts_to r #0.5R y
  ensures GR.pts_to r #1.0R x
  ensures pure (reveal x == reveal y)
{
  GR.gather r #x #y;
  rewrite GR.pts_to r #(0.5R +. 0.5R) x as GR.pts_to r #1.0R x;
}

ghost
fn update_halves (#t: Type0) (r: GR.ref t) (#x: erased t) (y: erased t)
  requires GR.pts_to r #1.0R x
  ensures GR.pts_to r #0.5R y
  ensures GR.pts_to r #0.5R y
{
  GR.write r y;
  GR.share r;
  rewrite GR.pts_to r #(1.0R /. 2.0R) y as GR.pts_to r #0.5R y;
  rewrite GR.pts_to r #(1.0R /. 2.0R) y as GR.pts_to r #0.5R y;
}

let is_ring (r: ring) (g: gst) : slprop = inv g.i (ring_inv r g.gw g.gr)

(* The writer's state in C: its head, the stream offset at the head and the
   tail it last loaded. *)
noeq type wstate = { whead: U64.t; woff: U64.t; wtail: U64.t }

let writer_facts (cap: capt) (w: wghost) (v: wstate) (s: bytes) : prop =
  U64.v v.whead == w.lw.hd /\ U64.v v.woff == w.lw.hoff /\ U64.v v.wtail == w.wt /\
  wf cap w.lw /\ w.wt <= w.lw.hd /\ w.lw.hd <= w.wt + cap /\
  Seq.length s == cap /\ inited s (rng cap w.lw.hd (w.wt + cap))

(* The writer owns the free bytes [head, tail + cap). *)
let writer_at (r: ring) (g: gst) (ws: ref wstate) (w: wghost) (v: wstate) : slprop =
  exists* (s: bytes).
    GR.pts_to g.gw #0.5R w ** pts_to ws v **
    A.pts_to_mask r.data s (rng (capn r) w.lw.hd (w.wt + capn r)) **
    pure (writer_facts (capn r) w v s)

let writer (r: ring) (g: gst) (ws: ref wstate) : slprop =
  exists* (w: wghost) (v: wstate). writer_at r g ws w v

(* The reader's state in C: its tail, the head it last loaded, the settled
   position with the stream offset there, and where the last released data
   record ends. *)
noeq type rstate = { rtail: U64.t; seen: U64.t; settled: U64.t; soff: U64.t; evicted: U64.t }

let reader_pure (cap: capt) (g: rghost) (v: rstate) : prop =
  U64.v v.rtail == g.tl /\ U64.v v.seen == g.lr.hd /\
  wf cap g.lr /\ boundary g.lr g.tl /\ g.tl <= g.lr.hd /\ g.lr.hd <= g.tl + cap /\
  boundary g.lr (U64.v v.settled) /\ g.tl <= U64.v v.settled /\ U64.v v.settled <= g.lr.hd /\
  U64.v v.soff == off_at g.lr (U64.v v.settled) /\ evicted_ok g.lr (U64.v v.evicted) g.tl

let reader_facts (cap: capt) (g: rghost) (v: rstate) (s: bytes) : prop =
  reader_pure cap g v /\
  Seq.length s == cap /\ hdr_ok cap g.lr s g.tl g.lr.hd /\ inited s (rng cap g.tl g.lr.hd)

(* The reader owns the published bytes [tail, seen). *)
let reader_at (r: ring) (g: gst) (rs: ref rstate) (rg: rghost) (v: rstate) : slprop =
  exists* (s: bytes).
    GR.pts_to g.gr #0.5R rg ** pts_to rs v **
    A.pts_to_mask r.data s (rng (capn r) rg.tl rg.lr.hd) **
    pure (reader_facts (capn r) rg v s)

let reader (r: ring) (g: gst) (rs: ref rstate) : slprop =
  exists* (rg: rghost) (v: rstate). reader_at r g rs rg v

ghost
fn reader_known (r: ring) (#g: erased gst) (rs: ref rstate) (#rg: erased rghost) (#v: erased rstate)
  preserves reader_at r g rs rg v
  ensures pure (reader_pure (capn r) rg v /\ rg.lr.hd <= max_pos /\ rg.lr.hoff <= rg.lr.hd /\
                None? (rg.lr.m rg.lr.hd))
{
  unfold reader_at;
  fold (reader_at r g rs rg v);
  wf_head (capn r) rg.lr;
  assert pure (wf (capn r) rg.lr);
  assert pure (None? (rg.lr.m rg.lr.hd))
}

(* The physical index of position [p]. *)
inline_for_extraction
let index_of (r: ring) (p: U64.t) : i: FStar.SizeT.t{FStar.SizeT.v i == U64.v p % capn r} =
  let x = U64.rem p r.cap in
  FStar.SizeT.fits_lte (U64.v x) (A.length r.data);
  FStar.SizeT.uint64_to_sizet x

(* The capacities the proof covers, for the C that maps a ring. *)
let min_capacity : c: U64.t{U64.v c == min_cap} = 64uL
let max_capacity : c: U64.t{U64.v c == max_cap} = 0x40000000uL
