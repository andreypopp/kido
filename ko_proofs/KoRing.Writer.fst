module KoRing.Writer
#lang-pulse
open Pulse.Lib.Pervasives
open KoRing.Spec
open KoRing.Mask
open KoRing.Inv
module U8 = FStar.UInt8
module U64 = FStar.UInt64
module SZ = FStar.SizeT
module A = Pulse.Lib.Array
module GR = Pulse.Lib.GhostReference
module Seq = FStar.Seq
module KA = KoAtomic
module Cast = FStar.Int.Cast
module L = FStar.Math.Lemmas

let rec digit_pow (n: nat) (k: nat)
  : Lemma (ensures digit n k == (n / pow2 (8 * k)) % 256) (decreases k)
= if k > 0 then begin
    digit_pow (n / 256) (k - 1);
    L.division_multiplication_lemma n 256 (pow2 (8 * (k - 1)));
    L.pow2_plus 8 (8 * (k - 1))
  end

let shift_step (n: nat) (k: nat)
  : Lemma ((n / pow2 (8 * k)) / 256 == n / pow2 (8 * (k + 1)))
= L.division_multiplication_lemma n (pow2 (8 * k)) 256;
  L.pow2_plus (8 * k) 8

(* Little-endian bytes [0, n) of [x] at [idx], as ko_put writes them. *)
fn put_le (a: A.array U8.t) (idx: SZ.t) (x: U64.t) (n: SZ.t)
  (#s: erased bytes) (#mask: erased (nat -> prop))
  requires A.pts_to_mask a s mask
  requires pure (SZ.v idx + SZ.v n <= Seq.length s /\ SZ.v n <= 8 /\
                 (forall (i: nat). SZ.v idx <= i /\ i < SZ.v idx + SZ.v n ==> reveal mask i))
  ensures exists* (s': bytes). A.pts_to_mask a s' mask **
    pure (Seq.length s' == Seq.length s /\
          (forall (i: nat). SZ.v idx <= i /\ i < SZ.v idx + SZ.v n ==> i < Seq.length s' /\
             Seq.index s' i == Some (U8.uint_to_t (digit (U64.v x) (i - SZ.v idx)))) /\
          (forall (i: nat). i < Seq.length s /\ i < Seq.length s' /\ (i < SZ.v idx \/ SZ.v idx + SZ.v n <= i) ==>
             Seq.index s' i == Seq.index s i) /\
          (forall (i: nat). i < Seq.length s /\ i < Seq.length s' ==>
             Some? (Seq.index s' i) \/ Seq.index s' i == Seq.index s i))
{
  A.pts_to_mask_len a;
  let mut k = 0sz;
  let mut cur = x;
  while (SZ.lt !k n)
  invariant exists* (vk: SZ.t) (vc: U64.t) (s': bytes).
    pts_to k vk ** pts_to cur vc ** A.pts_to_mask a s' mask **
    pure (SZ.v vk <= SZ.v n /\ Seq.length s' == Seq.length s /\
          U64.v vc == U64.v x / pow2 (8 * SZ.v vk) /\
          (forall (i: nat). SZ.v idx <= i /\ i < SZ.v idx + SZ.v vk ==> i < Seq.length s' /\
             Seq.index s' i == Some (U8.uint_to_t (digit (U64.v x) (i - SZ.v idx)))) /\
          (forall (i: nat). i < Seq.length s /\ i < Seq.length s' /\ (i < SZ.v idx \/ SZ.v idx + SZ.v vk <= i) ==>
             Seq.index s' i == Seq.index s i) /\
          (forall (i: nat). i < Seq.length s /\ i < Seq.length s' ==>
             Some? (Seq.index s' i) \/ Seq.index s' i == Seq.index s i))
  decreases (SZ.v n - SZ.v !k)
  {
    let vk = !k;
    let vc = !cur;
    digit_pow (U64.v x) (SZ.v vk);
    shift_step (U64.v x) (SZ.v vk);
    A.mask_write a (SZ.add idx vk) (Cast.uint64_to_uint8 vc);
    cur := U64.div vc 256uL;
    k := SZ.add vk 1sz;
  }
}

(* The 13-byte header of [r] at [idx]. *)
inline_for_extraction
fn put_header (a: A.array U8.t) (idx: SZ.t) (tagv: U8.t) (len off: U64.t)
  (#s: erased bytes) (#mask: erased (nat -> prop)) (#r: erased record)
  requires A.pts_to_mask a s mask
  requires pure (SZ.v idx + 13 <= Seq.length s /\
                 (forall (i: nat). SZ.v idx <= i /\ i < SZ.v idx + 13 ==> reveal mask i) /\
                 U8.v tagv == tag (reveal r).kind /\ U64.v len == (reveal r).len /\
                 U64.v off == (reveal r).off)
  ensures exists* (s': bytes). A.pts_to_mask a s' mask **
    pure (Seq.length s' == Seq.length s /\
          (forall (j: nat). j < 13 ==> SZ.v idx + j < Seq.length s' /\ Seq.index s' (SZ.v idx + j) == Some (enc (reveal r) j)) /\
          (forall (i: nat). i < Seq.length s /\ i < Seq.length s' /\ (i < SZ.v idx \/ SZ.v idx + 13 <= i) ==>
             Seq.index s' i == Seq.index s i) /\
          (forall (i: nat). i < Seq.length s /\ i < Seq.length s' ==>
             Some? (Seq.index s' i) \/ Seq.index s' i == Seq.index s i))
{
  A.pts_to_mask_len a;
  A.mask_write a idx tagv;
  put_le a (SZ.add idx 1sz) len 4sz;
  put_le a (SZ.add idx 5sz) off 8sz;
}

let fits (cap: capt) (w: wghost) (n: nat) : prop =
  let e = w.lw.hd % cap + hdr + n in
  e <= cap /\ (e == cap \/ e + hdr <= cap) /\
  w.lw.hd + hdr + n <= w.wt + cap /\ w.lw.hd + hdr + n <= max_pos

let fits_next (cap: capt) (w: wghost) (n: nat)
  : Lemma (requires fits cap w n)
          (ensures (w.lw.hd + hdr + n) % cap + hdr <= cap /\ w.lw.hd % cap + hdr + n <= cap)
= mod_step cap w.lw.hd (hdr + n)

let next_rec (w: wghost) (t: nat{1 <= t /\ t <= 4}) (n: nat) : record =
  { kind = kind_of t; len = n; off = w.lw.hoff }

let after (w: wghost) (t: nat{1 <= t /\ t <= 4}) (n: nat) : wghost =
  { wt = w.wt; lw = extend w.lw (next_rec w t n) }

let after_fields (w: wghost) (t: nat{1 <= t /\ t <= 4}) (n: nat)
  : Lemma ((after w t n).lw.hoff == w.lw.hoff + (if t = 1 then n else 0) /\
           (after w t n).lw.hd == w.lw.hd + 13 + n /\ (after w t n).wt == w.wt)
= ()

(* Write the header at the head, then publish it with one store of head; the
   load of read after it says whether the reader was idle at the old head. *)
inline_for_extraction
fn publish (r: ring) (ws: ref wstate) (tagv: U8.t{1 <= U8.v tagv /\ U8.v tagv <= 4}) (n: U64.t)
  (#g: erased gst) (#w: erased wghost) (#v: erased wstate)
  preserves is_ring r g
  requires writer_at r g ws w v
  requires pure (fits (capn r) w (U64.v n))
  returns idle: bool
  ensures exists* (v': wstate).
    writer_at r g ws (after w (U8.v tagv) (U64.v n)) v'
{
  let cap : capt = capn r;
  unfold writer_at;
  with s. assert (A.pts_to_mask r.data s (rng cap w.lw.hd (w.wt + cap)));
  let vv = !ws;
  let hd = vv.whead;
  assert pure (U64.v hd == w.lw.hd);
  assert pure (w.lw.hd + 13 + U64.v n <= max_pos);
  assert pure (U64.v hd + 13 + U64.v n < pow2 64);
  fits_next cap w (U64.v n);
  assert pure ((w.lw.hd + inc (next_rec w (U8.v tagv) (U64.v n))) % cap + hdr <= cap);
  let rc : erased record = next_rec w (U8.v tagv) (U64.v n);
  hdr_in cap w.lw.hd (w.wt + cap) w.lw.hd;
  let idx = index_of r hd;
  put_header r.data idx tagv n vv.woff #_ #_ #rc;
  with sb. assert (A.pts_to_mask r.data sb (rng cap w.lw.hd (w.wt + cap)));
  let nhd = U64.add hd (U64.add 13uL n);
  split_at r.data cap w.lw.hd (U64.v nhd) (w.wt + cap);
  let w' : erased wghost = after w (U8.v tagv) (U64.v n);
  unfold is_ring;
  with_invariants unit emp_inames g.i (ring_inv r g.gw g.gr)
    (GR.pts_to g.gw #0.5R w ** A.pts_to_mask r.data sb (rng cap w.lw.hd (U64.v nhd)))
    (fun _ -> GR.pts_to g.gw #0.5R w')
  fn _ {
    unfold ring_inv;
    with wi rg hv tv rvv s2 s3. _;
    gather_half g.gw #w #wi;
    rewrite A.pts_to_mask r.data s2 (rng (capn r) rg.lr.hd wi.lw.hd)
         as A.pts_to_mask r.data s2 (rng cap rg.lr.hd w.lw.hd);
    rewrite A.pts_to_mask r.data s3 (rng (capn r) (wi.wt + capn r) (rg.tl + capn r))
         as A.pts_to_mask r.data s3 (rng (capn r) (w'.wt + capn r) (rg.tl + capn r));
    join_at r.data cap rg.lr.hd w.lw.hd (U64.v nhd) #s2 #sb;
    with s2'. assert (A.pts_to_mask r.data s2' (rng cap rg.lr.hd (U64.v nhd)));
    KA.store r.head nhd;
    update_halves g.gw w';
    extend_wf cap w.lw rc;
    log_le_trans rg.lr w.lw w'.lw;
    hdr_ok_extend cap w.lw rc s2 sb s2' rg.lr.hd;
    inited_split cap sb w.lw.hd (U64.v nhd) (w.wt + cap);
    inited_join cap s2' s2 sb rg.lr.hd w.lw.hd (U64.v nhd);
    rewrite A.pts_to_mask r.data s2' (rng cap rg.lr.hd (U64.v nhd))
         as A.pts_to_mask r.data s2' (rng (capn r) rg.lr.hd w'.lw.hd);
    fold (ring_inv r g.gw g.gr);
  };
  let rd = with_invariants U64.t emp_inames g.i (ring_inv r g.gw g.gr) emp (fun _ -> emp)
  fn _ {
    unfold ring_inv;
    let x = KA.load r.read;
    fold (ring_inv r g.gw g.gr);
    x
  };
  fold (is_ring r g);
  wf_head cap w.lw;
  let woff' = (if tagv = 1uy then U64.add vv.woff n else vv.woff);
  let v' : wstate = { whead = nhd; woff = woff'; wtail = vv.wtail };
  ws := v';
  inited_split cap sb w.lw.hd (U64.v nhd) (w.wt + cap);
  extend_wf cap w.lw rc;
  after_fields w (U8.v tagv) (U64.v n);
  assert pure (U64.v v'.whead == w'.lw.hd);
  assert pure (U64.v v'.woff == w'.lw.hoff);
  assert pure (wf cap w'.lw);
  rewrite A.pts_to_mask r.data sb (rng cap (U64.v nhd) (w.wt + cap))
       as A.pts_to_mask r.data sb (rng (capn r) w'.lw.hd (w'.wt + capn r));
  fold (writer_at r g ws w' v');
  rewrite writer_at r g ws w' v' as writer_at r g ws (after w (U8.v tagv) (U64.v n)) v';
  (rd = hd)
}

let with_wt (w: wghost) (t: nat) : wghost = { wt = t; lw = w.lw }

(* Load the tail; the bytes the reader released become the writer's. *)
inline_for_extraction
fn load_tail (r: ring) (ws: ref wstate) (#g: erased gst) (#w: erased wghost) (#v: erased wstate)
  preserves is_ring r g
  requires writer_at r g ws w v
  returns t: U64.t
  ensures exists* (v': wstate). writer_at r g ws (with_wt w (U64.v t)) v' **
    pure (w.wt <= U64.v t /\ v'.wtail == t /\ v'.whead == v.whead /\ v'.woff == v.woff)
{
  let cap : capt = capn r;
  unfold writer_at;
  with s. assert (A.pts_to_mask r.data s (rng cap w.lw.hd (w.wt + cap)));
  let vv = !ws;
  unfold is_ring;
  let t = with_invariants U64.t emp_inames g.i (ring_inv r g.gw g.gr)
    (GR.pts_to g.gw #0.5R w ** A.pts_to_mask r.data s (rng cap w.lw.hd (w.wt + cap)))
    (fun t -> exists* (s': bytes). GR.pts_to g.gw #0.5R (with_wt w (U64.v t)) **
       A.pts_to_mask r.data s' (rng cap w.lw.hd (U64.v t + cap)) **
       pure (w.wt <= U64.v t /\ U64.v t <= w.lw.hd /\ Seq.length s' == cap /\
             inited s' (rng cap w.lw.hd (U64.v t + cap))))
  fn _ {
    unfold ring_inv;
    with wi rg hv tv rvv s2 s3. _;
    gather_half g.gw #w #wi;
    rewrite A.pts_to_mask r.data s3 (rng (capn r) (wi.wt + capn r) (rg.tl + capn r))
         as A.pts_to_mask r.data s3 (rng cap (w.wt + cap) (rg.tl + cap));
    let t = KA.load r.tail;
    join_at r.data cap w.lw.hd (w.wt + cap) (rg.tl + cap) #s #s3;
    with s'. assert (A.pts_to_mask r.data s' (rng cap w.lw.hd (rg.tl + cap)));
    inited_join cap s' s s3 w.lw.hd (w.wt + cap) (rg.tl + cap);
    split_at r.data cap w.lw.hd (rg.tl + cap) (rg.tl + cap);
    inited_empty cap s' (rg.tl + cap);
    let w2 : erased wghost = with_wt w rg.tl;
    update_halves g.gw w2;
    rewrite A.pts_to_mask r.data s' (rng cap (rg.tl + cap) (rg.tl + cap))
         as A.pts_to_mask r.data s' (rng (capn r) (w2.wt + capn r) (rg.tl + capn r));
    rewrite A.pts_to_mask r.data s2 (rng (capn r) rg.lr.hd wi.lw.hd)
         as A.pts_to_mask r.data s2 (rng (capn r) rg.lr.hd w2.lw.hd);
    fold (ring_inv r g.gw g.gr);
    rewrite A.pts_to_mask r.data s' (rng cap w.lw.hd (rg.tl + cap))
         as A.pts_to_mask r.data s' (rng cap w.lw.hd (U64.v t + cap));
    rewrite GR.pts_to g.gw #0.5R w2 as GR.pts_to g.gw #0.5R (with_wt w (U64.v t));
    t
  };
  fold (is_ring r g);
  let v' : wstate = { whead = vv.whead; woff = vv.woff; wtail = t };
  ws := v';
  with s'. assert (A.pts_to_mask r.data s' (rng cap w.lw.hd (U64.v t + cap)));
  rewrite A.pts_to_mask r.data s' (rng cap w.lw.hd (U64.v t + cap))
       as A.pts_to_mask r.data s' (rng (capn r) (with_wt w (U64.v t)).lw.hd ((with_wt w (U64.v t)).wt + capn r));
  fold (writer_at r g ws (with_wt w (U64.v t)) v');
  t
}

(* How many payload bytes the next record may take, and whether a pad
   record this call published found the reader idle. *)
type avail = { room: U64.t; idle: bool }

(* The writer stops at this head rather than let positions overflow. *)
inline_for_extraction
let last_head : U64.t = 0x3fffffff00000000uL

inline_for_extraction
let room_of (free end_: U64.t) : U64.t =
  let n = if U64.lt free end_ then free else end_ in
  if U64.lte n 26uL then 0uL else U64.sub n 26uL

fn available (r: ring) (ws: ref wstate) (#g: erased gst)
  preserves is_ring r g
  requires writer r g ws
  returns a: avail
  ensures writer r g ws
{
  unfold writer;
  with w0 v0. assert (writer_at r g ws w0 v0);
  let t = load_tail r ws;
  with v1. assert (writer_at r g ws (with_wt w0 (U64.v t)) v1);
  let w : erased wghost = with_wt w0 (U64.v t);
  rewrite writer_at r g ws (with_wt w0 (U64.v t)) v1 as writer_at r g ws w v1;
  unfold writer_at;
  let vv = !ws;
  fold (writer_at r g ws w v1);
  wf_head (capn r) w.lw;
  let hd = vv.whead;
  if (U64.gte hd last_head) {
    fold (writer r g ws);
    Mkavail (0uL) false
  } else {
    let free = U64.sub r.cap (U64.sub hd t);
    let end_ = U64.sub r.cap (U64.rem hd r.cap);
    if (U64.lte end_ 26uL) {
      if (U64.lt free end_) {
        fold (writer r g ws);
        Mkavail (0uL) false
      } else {
        mod_step (capn r) w.lw.hd (U64.v end_);
        let b = publish r ws 4uy (U64.sub end_ 13uL);
        fold (writer r g ws);
        Mkavail (room_of (U64.sub free end_) r.cap) b
      }
    } else {
      fold (writer r g ws);
      Mkavail (room_of free end_) false
    }
  }
}

(* What a commit did: refused a record that does not fit, or published it
   and found the reader busy or idle at the old head. *)
type commit = | Refused | Published | Idle

fn put_record (r: ring) (ws: ref wstate) (tagv: U8.t) (n: U64.t) (#g: erased gst)
  preserves is_ring r g
  requires writer r g ws
  returns c: commit
  ensures writer r g ws
{
  unfold writer;
  with w v. assert (writer_at r g ws w v);
  unfold writer_at;
  let vv = !ws;
  fold (writer_at r g ws w v);
  wf_head (capn r) w.lw;
  if (U8.lt tagv 1uy || U8.gt tagv 4uy || U64.gt n r.cap) {
    fold (writer r g ws);
    Refused
  } else {
    let hd = vv.whead;
    let e = U64.add (U64.rem hd r.cap) (U64.add 13uL n);
    let fin = U64.add hd (U64.add 13uL n);
    if (U64.lte e r.cap && (e = r.cap || U64.lte (U64.add e 13uL) r.cap) &&
        U64.lte fin (U64.add vv.wtail r.cap) && U64.lte fin last_head) {
      let b = publish r ws tagv n;
      fold (writer r g ws);
      (if b then Idle else Published)
    } else {
      fold (writer r g ws);
      Refused
    }
  }
}
