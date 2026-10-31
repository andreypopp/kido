module KoRing.Init
#lang-pulse
open Pulse.Lib.Pervasives
open KoRing.Spec
open KoRing.Mask
open KoRing.Inv
module U8 = FStar.UInt8
module U64 = FStar.UInt64
module A = Pulse.Lib.Array
module GR = Pulse.Lib.GhostReference
module Seq = FStar.Seq

let wzero : wstate = { whead = 0uL; woff = 0uL; wtail = 0uL }
let rzero : rstate = { rtail = 0uL; seen = 0uL; settled = 0uL; soff = 0uL; evicted = 0uL }

(* A zero-filled mapping with zero indices splits into the shared invariant,
   the writer and the reader; each party's operations need only its own part
   and the duplicable [is_ring], so the two may run in parallel. *)
ghost
fn init (r: ring) (ws: ref wstate) (rs: ref rstate) (#d: erased (Seq.seq U8.t))
  requires pts_to r.head 0uL ** pts_to r.tail 0uL ** pts_to r.read 0uL
  requires A.pts_to r.data d
  requires pts_to ws wzero
  requires pts_to rs rzero
  returns g: gst
  ensures is_ring r g ** writer r g ws ** reader r g rs
{
  let cap : capt = capn r;
  A.pts_to_len r.data;
  A.to_mask r.data;
  with s. assert (A.pts_to_mask r.data s (fun _ -> True));
  A.mask_mext r.data #_ #s (rng cap 0 cap);
  split_at r.data cap 0 0 cap;
  split_at r.data cap 0 0 0;
  split_at r.data cap 0 cap cap;
  rewrite A.pts_to_mask r.data s (rng cap cap cap)
       as A.pts_to_mask r.data s (rng cap (0 + cap) (0 + cap));
  empty_wf cap;
  hdr_ok_empty cap empty_log s 0;
  let w0 : wghost = { wt = 0; lw = empty_log };
  let g0 : rghost = { tl = 0; lr = empty_log };
  let gw = GR.alloc w0;
  GR.share gw;
  let gr = GR.alloc g0;
  GR.share gr;
  rewrite A.pts_to_mask r.data s (rng cap 0 0) as A.pts_to_mask r.data s (rng (capn r) g0.lr.hd w0.lw.hd);
  rewrite A.pts_to_mask r.data s (rng cap (0 + cap) (0 + cap))
       as A.pts_to_mask r.data s (rng (capn r) (w0.wt + capn r) (g0.tl + capn r));
  fold (ring_inv r gw gr);
  let i = new_invariant (ring_inv r gw gr);
  let g : gst = { gw; gr; i };
  rewrite inv i (ring_inv r gw gr) as is_ring r g;
  rewrite GR.pts_to gw #0.5R w0 as GR.pts_to g.gw #0.5R w0;
  rewrite A.pts_to_mask r.data s (rng cap 0 cap) as A.pts_to_mask r.data s (rng (capn r) w0.lw.hd (w0.wt + capn r));
  fold (writer_at r g ws w0 wzero);
  fold (writer r g ws);
  rewrite GR.pts_to gr #0.5R g0 as GR.pts_to g.gr #0.5R g0;
  rewrite A.pts_to_mask r.data s (rng cap 0 0) as A.pts_to_mask r.data s (rng (capn r) g0.tl g0.lr.hd);
  fold (reader_at r g rs g0 rzero);
  fold (reader r g rs);
  g
}
