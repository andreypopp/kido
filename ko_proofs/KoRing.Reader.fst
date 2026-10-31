module KoRing.Reader
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
module Cast = FStar.Int.Cast
module KA = KoAtomic

let with_lr (g: rghost) (l: log) : rghost = { g with lr = l }
inline_for_extraction
let with_seen (v: rstate) (h: U64.t) : rstate = { v with seen = h }

(* Load the head: the records published since the last load become the
   reader's, and the log it knows grows to the writer's. *)
fn observe (r: ring) (rs: ref rstate) (#g: erased gst) (#rg: erased rghost) (#v: erased rstate)
  preserves is_ring r g
  requires reader_at r g rs rg v
  returns vv: rstate
  ensures exists* (rg': rghost). reader_at r g rs rg' vv **
    pure (rg'.tl == rg.tl /\ log_le rg.lr rg'.lr /\ vv == with_seen v vv.seen /\
          reader_pure (capn r) rg' vv)
{
  let cap : capt = capn r;
  unfold reader_at;
  with s1. assert (A.pts_to_mask r.data s1 (rng cap rg.tl rg.lr.hd));
  unfold is_ring;
  let h = with_invariants U64.t emp_inames g.i (ring_inv r g.gw g.gr)
    (GR.pts_to g.gr #0.5R rg ** A.pts_to_mask r.data s1 (rng cap rg.tl rg.lr.hd) **
     pure (reader_facts cap rg v s1))
    (fun h -> exists* (l: log) (s: bytes). GR.pts_to g.gr #0.5R (with_lr rg l) **
       A.pts_to_mask r.data s (rng cap rg.tl l.hd) **
       pure (log_le rg.lr l /\ U64.v h == l.hd /\ wf cap l /\ l.hd <= rg.tl + cap /\
             Seq.length s == cap /\ hdr_ok cap l s rg.tl l.hd /\ inited s (rng cap rg.tl l.hd)))
  fn _ {
    unfold ring_inv;
    with w rgi hv tv rvv s2 s3. _;
    gather_half g.gr #rg #rgi;
    rewrite A.pts_to_mask r.data s2 (rng (capn r) rgi.lr.hd w.lw.hd)
         as A.pts_to_mask r.data s2 (rng cap rg.lr.hd w.lw.hd);
    let h = KA.load r.head;
    join_at r.data cap rg.tl rg.lr.hd w.lw.hd #s1 #s2;
    with s. assert (A.pts_to_mask r.data s (rng cap rg.tl w.lw.hd));
    hdr_ok_join cap rg.lr w.lw s1 s2 s rg.tl rg.lr.hd w.lw.hd;
    inited_join cap s s1 s2 rg.tl rg.lr.hd w.lw.hd;
    split_at r.data cap rg.tl w.lw.hd w.lw.hd;
    inited_empty cap s w.lw.hd;
    hdr_ok_empty cap w.lw s w.lw.hd;
    let rg2 : erased rghost = with_lr rg w.lw;
    update_halves g.gr rg2;
    log_le_refl w.lw;
    rewrite A.pts_to_mask r.data s (rng cap w.lw.hd w.lw.hd)
         as A.pts_to_mask r.data s (rng (capn r) rg2.lr.hd w.lw.hd);
    rewrite A.pts_to_mask r.data s3 (rng (capn r) (w.wt + capn r) (rgi.tl + capn r))
         as A.pts_to_mask r.data s3 (rng (capn r) (w.wt + capn r) (rg2.tl + capn r));
    fold (ring_inv r g.gw g.gr);
    rewrite GR.pts_to g.gr #0.5R rg2 as GR.pts_to g.gr #0.5R (with_lr rg w.lw);
    h
  };
  fold (is_ring r g);
  with l s. assert (A.pts_to_mask r.data s (rng cap rg.tl l.hd));
  let vv = !rs;
  let v' = with_seen vv h;
  rs := v';
  log_le_boundary cap rg.lr l rg.tl;
  log_le_boundary cap rg.lr l (U64.v vv.settled);
  evicted_grows rg.lr l (U64.v vv.evicted) rg.tl;
  rewrite A.pts_to_mask r.data s (rng cap rg.tl l.hd)
       as A.pts_to_mask r.data s (rng (capn r) (with_lr rg l).tl (with_lr rg l).lr.hd);
  fold (reader_at r g rs (with_lr rg l) v');
  v'
}

inline_for_extraction
let u (b: U8.t) : x: U64.t{U64.v x == U8.v b} = Cast.uint8_to_uint64 b

inline_for_extraction
let le4_u64 (b0 b1 b2 b3: U8.t) : x: U64.t{U64.v x == le4 b0 b1 b2 b3 /\ U64.v x < 4294967296} =
  U64.add (u b0) (U64.mul 256uL (U64.add (u b1) (U64.mul 256uL (U64.add (u b2) (U64.mul 256uL (u b3))))))

inline_for_extraction
let le8_u64 (b0 b1 b2 b3 b4 b5 b6 b7: U8.t) : x: U64.t{U64.v x == le8 b0 b1 b2 b3 b4 b5 b6 b7} =
  U64.add (u b0) (U64.mul 256uL (U64.add (u b1) (U64.mul 256uL (U64.add (u b2) (U64.mul 256uL
  (U64.add (u b3) (U64.mul 256uL (U64.add (u b4) (U64.mul 256uL (U64.add (u b5) (U64.mul 256uL
  (U64.add (u b6) (U64.mul 256uL (u b7))))))))))))))

inline_for_extraction
let ends_ok (tagv: U8.t) (i pos len cap seen: U64.t)
  : Pure bool (requires U64.v len < 4294967296 /\ U64.v i < 4294967296 /\ U64.v pos < 0x4000000000000000)
              (ensures fun b -> b <==> (1 <= U8.v tagv /\ U8.v tagv <= 4 /\
                 U64.v i + 13 + U64.v len <= U64.v cap /\ U64.v pos + 13 + U64.v len <= U64.v seen))
= U8.gte tagv 1uy && U8.lte tagv 4uy &&
  U64.lte (U64.add i (U64.add 13uL len)) cap &&
  U64.lte (U64.add pos (U64.add 13uL len)) seen

(* A record header as read: [ok] says the checks passed. *)
noeq type hdr_view = { ok: bool; htag: U8.t; hlen: U64.t; hoff: U64.t }

let rec_at (l: log) (p: nat{Some? (l.m p)}) : record = Some?.v (l.m p)

(* For a record of the log the checks pass and the fields are the record's:
   no wrap, a valid tag, 0 <= off <= p, and its length. *)
let hdr_spec (cap: capt) (rg: rghost) (pos: nat) (h: hdr_view) : prop =
  (rg.tl <= pos /\ pos < rg.lr.hd /\ Some? (rg.lr.m pos) ==>
     h.ok /\ U8.v h.htag == tag (rec_at rg.lr pos).kind /\
     U64.v h.hlen == (rec_at rg.lr pos).len /\ U64.v h.hoff == (rec_at rg.lr pos).off) /\
  (h.ok ==> 1 <= U8.v h.htag /\ U8.v h.htag <= 4 /\ rg.tl <= pos /\
            pos + 13 + U64.v h.hlen <= rg.lr.hd /\ pos % cap + 13 + U64.v h.hlen <= cap)

let header_lemma (cap: capt) (rg: rghost) (s: bytes) (pos: nat)
    (b0 b1 b2 b3 b4 b5 b6 b7 b8 b9 b10 b11 b12: U8.t)
  : Lemma
    (requires wf cap rg.lr /\ hdr_ok cap rg.lr s rg.tl rg.lr.hd /\ rg.tl <= pos /\ pos < rg.lr.hd /\
              pos % cap + 13 <= Seq.length s /\
              Seq.index s (pos % cap) == Some b0 /\ Seq.index s (pos % cap + 1) == Some b1 /\
              Seq.index s (pos % cap + 2) == Some b2 /\ Seq.index s (pos % cap + 3) == Some b3 /\
              Seq.index s (pos % cap + 4) == Some b4 /\ Seq.index s (pos % cap + 5) == Some b5 /\
              Seq.index s (pos % cap + 6) == Some b6 /\ Seq.index s (pos % cap + 7) == Some b7 /\
              Seq.index s (pos % cap + 8) == Some b8 /\ Seq.index s (pos % cap + 9) == Some b9 /\
              Seq.index s (pos % cap + 10) == Some b10 /\ Seq.index s (pos % cap + 11) == Some b11 /\
              Seq.index s (pos % cap + 12) == Some b12)
    (ensures Some? (rg.lr.m pos) ==> (let r = rec_at rg.lr pos in
              pos + inc r <= rg.lr.hd /\ pos % cap + inc r <= cap /\ r.off <= pos /\
              U8.v b0 == tag r.kind /\ le4 b1 b2 b3 b4 == r.len /\
              le8 b5 b6 b7 b8 b9 b10 b11 b12 == r.off))
= if Some? (rg.lr.m pos) then begin
  let r = rec_at rg.lr pos in
  wf_rec cap rg.lr pos;
  wf_head cap rg.lr;
  let e (j: nat{j < 13}) : Lemma (hdr_at cap rg.lr s pos j) = hdr_ok_elim cap rg.lr s rg.tl rg.lr.hd pos j in
  e 0; e 1; e 2; e 3; e 4; e 5; e 6; e 7; e 8; e 9; e 10; e 11; e 12;
  le4_enc r; le8_enc r
  end

let rec_fits (cap: capt) (l: log) (pos: nat)
  : Lemma (requires wf cap l)
          (ensures Some? (l.m pos) ==> pos + inc (rec_at l pos) <= l.hd /\ pos % cap + inc (rec_at l pos) <= cap)
= if Some? (l.m pos) then wf_rec cap l pos

let hdr_final (cap: capt) (rg: rghost) (pos: nat) (tagv: U8.t) (len off i seen: U64.t) (ok: bool)
  : Lemma
    (requires
      (Some? (rg.lr.m pos) ==> (let r = rec_at rg.lr pos in
         pos + inc r <= rg.lr.hd /\ pos % cap + inc r <= cap /\
         U8.v tagv == tag r.kind /\ U64.v len == r.len /\ U64.v off == r.off)) /\
      U64.v i == pos % cap /\ U64.v seen == rg.lr.hd /\ rg.tl <= pos /\
      (ok <==> (1 <= U8.v tagv /\ U8.v tagv <= 4 /\
                U64.v i + 13 + U64.v len <= cap /\ pos + 13 + U64.v len <= U64.v seen)))
    (ensures hdr_spec cap rg pos (Mkhdr_view ok tagv len off))
= ()

fn header (r: ring) (rs: ref rstate) (pos: U64.t)
  (#g: erased gst) (#rg: erased rghost) (#v: erased rstate)
  preserves reader_at r g rs rg v
  returns h: hdr_view
  ensures pure (hdr_spec (capn r) rg (U64.v pos) h)
{
  let cap : capt = capn r;
  unfold reader_at;
  with s. assert (A.pts_to_mask r.data s (rng cap rg.tl rg.lr.hd));
  let vv = !rs;
  wf_head cap rg.lr;
  let i = U64.rem pos r.cap;
  rec_fits cap rg.lr (U64.v pos);
  assert pure (U64.v i < 4294967296 /\ U64.v vv.seen <= 0x4000000000000000 /\ U64.v i == U64.v pos % cap /\
               U64.v vv.seen == rg.lr.hd /\ U64.v vv.rtail == rg.tl);
  if (U64.lte vv.rtail pos && U64.lt pos vv.seen &&
      U64.lte (U64.add i 13uL) r.cap && U64.lte (U64.add pos 13uL) vv.seen) {
    hdr_in cap rg.tl rg.lr.hd (U64.v pos);
    let idx = index_of r pos;
    let b0 = A.mask_read r.data idx;
    let b1 = A.mask_read r.data (SZ.add idx 1sz);
    let b2 = A.mask_read r.data (SZ.add idx 2sz);
    let b3 = A.mask_read r.data (SZ.add idx 3sz);
    let b4 = A.mask_read r.data (SZ.add idx 4sz);
    let b5 = A.mask_read r.data (SZ.add idx 5sz);
    let b6 = A.mask_read r.data (SZ.add idx 6sz);
    let b7 = A.mask_read r.data (SZ.add idx 7sz);
    let b8 = A.mask_read r.data (SZ.add idx 8sz);
    let b9 = A.mask_read r.data (SZ.add idx 9sz);
    let b10 = A.mask_read r.data (SZ.add idx 10sz);
    let b11 = A.mask_read r.data (SZ.add idx 11sz);
    let b12 = A.mask_read r.data (SZ.add idx 12sz);
    let len = le4_u64 b1 b2 b3 b4;
    let off = le8_u64 b5 b6 b7 b8 b9 b10 b11 b12;
    header_lemma cap rg s (U64.v pos) b0 b1 b2 b3 b4 b5 b6 b7 b8 b9 b10 b11 b12;
    let ok = ends_ok b0 i pos len r.cap vv.seen;
    hdr_final cap rg (U64.v pos) b0 len off i vv.seen ok;
    fold (reader_at r g rs rg v);
    Mkhdr_view ok b0 len off
  } else {
    fold (reader_at r g rs rg v);
    Mkhdr_view false 0uy 0uL 0uL
  }
}

let with_tl (g: rghost) (t: nat) : rghost = { g with tl = t }
inline_for_extraction
let with_tail (v: rstate) (t e: U64.t) : rstate = { v with rtail = t; evicted = e }

(* Store the tail: the bytes before it go back to the writer. *)
inline_for_extraction
fn release (r: ring) (rs: ref rstate) (nt ne: U64.t)
  (#g: erased gst) (#rg: erased rghost) (#v: erased rstate)
  preserves is_ring r g
  requires reader_at r g rs rg v
  requires pure (boundary rg.lr (U64.v nt) /\ rg.tl <= U64.v nt /\ U64.v nt <= U64.v v.settled /\
                 evicted_ok rg.lr (U64.v ne) (U64.v nt))
  ensures reader_at r g rs (with_tl rg (U64.v nt)) (with_tail v nt ne)
{
  let cap : capt = capn r;
  unfold reader_at;
  with s1. assert (A.pts_to_mask r.data s1 (rng cap rg.tl rg.lr.hd));
  split_at r.data cap rg.tl (U64.v nt) rg.lr.hd;
  inited_split cap s1 rg.tl (U64.v nt) rg.lr.hd;
  shift r.data cap rg.tl (U64.v nt);
  inited_shift cap s1 rg.tl (U64.v nt);
  let rg2 : erased rghost = with_tl rg (U64.v nt);
  unfold is_ring;
  with_invariants unit emp_inames g.i (ring_inv r g.gw g.gr)
    (GR.pts_to g.gr #0.5R rg ** A.pts_to_mask r.data s1 (rng cap (rg.tl + cap) (U64.v nt + cap)) **
     pure (reader_facts cap rg v s1 /\ inited s1 (rng cap (rg.tl + cap) (U64.v nt + cap))))
    (fun _ -> GR.pts_to g.gr #0.5R rg2)
  fn _ {
    unfold ring_inv;
    with w rgi hv tv rvv s2 s3. _;
    gather_half g.gr #rg #rgi;
    rewrite A.pts_to_mask r.data s3 (rng (capn r) (w.wt + capn r) (rgi.tl + capn r))
         as A.pts_to_mask r.data s3 (rng cap (w.wt + cap) (rg.tl + cap));
    join_at r.data cap (w.wt + cap) (rg.tl + cap) (U64.v nt + cap) #s3 #s1;
    with s3'. assert (A.pts_to_mask r.data s3' (rng cap (w.wt + cap) (U64.v nt + cap)));
    inited_join cap s3' s3 s1 (w.wt + cap) (rg.tl + cap) (U64.v nt + cap);
    KA.store r.tail nt;
    update_halves g.gr rg2;
    rewrite A.pts_to_mask r.data s3' (rng cap (w.wt + cap) (U64.v nt + cap))
         as A.pts_to_mask r.data s3' (rng (capn r) (w.wt + capn r) (rg2.tl + capn r));
    rewrite A.pts_to_mask r.data s2 (rng (capn r) rgi.lr.hd w.lw.hd)
         as A.pts_to_mask r.data s2 (rng (capn r) rg2.lr.hd w.lw.hd);
    fold (ring_inv r g.gw g.gr);
  };
  fold (is_ring r g);
  let vv = !rs;
  rs := with_tail vv nt ne;
  hdr_ok_narrow cap rg.lr s1 rg.tl (U64.v nt) rg.lr.hd;
  rewrite A.pts_to_mask r.data s1 (rng cap (U64.v nt) rg.lr.hd)
       as A.pts_to_mask r.data s1 (rng (capn r) rg2.tl rg2.lr.hd);
  rewrite GR.pts_to g.gr #0.5R rg2 as GR.pts_to g.gr #0.5R (with_tl rg (U64.v nt));
  fold (reader_at r g rs (with_tl rg (U64.v nt)) (with_tail v nt ne));
}

(* Store read: the head the reader has scanned up to. *)
inline_for_extraction
fn set_read (r: ring) (rs: erased (ref rstate)) (upper: U64.t)
  (#g: erased gst) (#rg: erased rghost) (#v: erased rstate)
  preserves is_ring r g
  preserves reader_at r g rs rg v
  requires pure (U64.v upper <= rg.lr.hd)
{
  unfold reader_at;
  unfold is_ring;
  with_invariants unit emp_inames g.i (ring_inv r g.gw g.gr)
    (GR.pts_to g.gr #0.5R rg) (fun _ -> GR.pts_to g.gr #0.5R rg)
  fn _ {
    unfold ring_inv;
    with w rgi hv tv rvv s2 s3. _;
    gather_half g.gr #rg #rgi;
    KA.store r.read upper;
    update_halves g.gr rg;
    rewrite A.pts_to_mask r.data s2 (rng (capn r) rgi.lr.hd w.lw.hd)
         as A.pts_to_mask r.data s2 (rng (capn r) rg.lr.hd w.lw.hd);
    rewrite A.pts_to_mask r.data s3 (rng (capn r) (w.wt + capn r) (rgi.tl + capn r))
         as A.pts_to_mask r.data s3 (rng (capn r) (w.wt + capn r) (rg.tl + capn r));
    fold (ring_inv r g.gw g.gr);
  };
  fold (is_ring r g);
  fold (reader_at r g rs rg v);
}
