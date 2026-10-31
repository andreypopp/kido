module KoRing.Walk
#lang-pulse
open Pulse.Lib.Pervasives
open KoRing.Spec
open KoRing.Mask
open KoRing.Inv
open KoRing.Reader
module U8 = FStar.UInt8
module U64 = FStar.UInt64
module Seq = FStar.Seq

(* The position below which the reader releases the ring: half a ring behind
   the head, or [keep] if that is lower. *)
let retain_of (cap: capt) (upper keep: nat) : nat =
  if upper < cap / 2 then 0 else (if upper - cap / 2 < keep then upper - cap / 2 else keep)

inline_for_extraction
let off_next (h: hdr_view) : U64.t =
  if h.htag = 1uy && U64.lt h.hoff 0x4000000000000000uL && U64.lt h.hlen 0x100000000uL
  then U64.add h.hoff h.hlen else h.hoff

(* One step of a walk from the record at [p]: the next boundary follows it
   with no record between, and the offset there is [off_next]. *)
let step (cap: capt) (l: log) (p: nat)
  : Lemma (requires wf cap l /\ Some? (l.m p))
          (ensures (let r = rec_at l p in
                    boundary l (p + inc r) /\ p + inc r <= l.hd /\ r.off <= p /\ p < max_pos /\
                    off_at l (p + inc r) == off_after r /\
                    (forall (q: nat). p < q /\ q < p + inc r ==> None? (l.m q))))
= wf_rec cap l p; wf_head cap l

(* advance's promise: the tail moved forward to the first boundary at or after
   [retain], and no further. *)
let advanced (cap: capt) (rg rg': rghost) (upper keep: nat) : prop =
  rg'.lr == rg.lr /\ upper == rg.lr.hd /\
  rg.tl <= rg'.tl /\ rg'.tl <= rg.lr.hd /\ boundary rg.lr rg'.tl /\
  (retain_of cap upper keep <= rg.tl ==> rg'.tl == rg.tl) /\
  (rg.tl < retain_of cap upper keep ==>
     retain_of cap upper keep <= rg'.tl /\
     (forall (q: nat). retain_of cap upper keep <= q /\ q < rg'.tl ==> None? (rg.lr.m q)))

(* The tail never passes a boundary the caller keeps. *)
let keeps (cap: capt) (rg rg': rghost) (upper keep: nat)
  : Lemma (requires advanced cap rg rg' upper keep /\ boundary rg.lr keep /\ rg.tl <= keep)
          (ensures rg'.tl <= keep)
= ()

inline_for_extraction
let with_settled (v: rstate) (st so: U64.t) : rstate = { v with settled = st; soff = so }

inline_for_extraction
fn settle (r: erased ring) (rs: ref rstate) (st so: U64.t)
  (#g: erased gst) (#rg: erased rghost) (#v: erased rstate)
  requires reader_at r g rs rg v
  requires pure (boundary rg.lr (U64.v st) /\ rg.tl <= U64.v st /\ U64.v st <= rg.lr.hd /\
                 U64.v so == off_at rg.lr (U64.v st))
  ensures reader_at r g rs rg (with_settled v st so)
{
  unfold reader_at;
  let vv = !rs;
  rs := with_settled vv st so;
  fold (reader_at r g rs rg (with_settled v st so));
}

fn advance (r: ring) (rs: ref rstate) (upper keep: U64.t)
  (#g: erased gst) (#rg: erased rghost) (#v: erased rstate)
  preserves is_ring r g
  requires reader_at r g rs rg v
  returns ok: bool
  ensures exists* (rg': rghost) (v': rstate). reader_at r g rs rg' v' **
    pure ((U64.v upper == rg.lr.hd ==> ok) /\ (ok ==> advanced (capn r) rg rg' (U64.v upper) (U64.v keep)))
{
  let cap : capt = capn r;
  reader_known r rs;
  unfold reader_at;
  let vv = !rs;
  fold (reader_at r g rs rg v);
  if (upper <> vv.seen) {
    false
  } else {
    let half = U64.div r.cap 2uL;
    let retain = (if U64.lt upper half then 0uL
                  else if U64.lt (U64.sub upper half) keep then U64.sub upper half else keep);
    let mut tail = vv.rtail;
    let mut last = 0uL;
    let mut ev = vv.evicted;
    let mut good = true;
    while (!good && U64.lt !tail retain)
    invariant exists* (vt vl ve: U64.t) (vg: bool).
      pts_to tail vt ** pts_to last vl ** pts_to ev ve ** pts_to good vg ** reader_at r g rs rg v **
      pure (boundary rg.lr (U64.v vt) /\ rg.tl <= U64.v vt /\ U64.v vt <= rg.lr.hd /\
            evicted_ok rg.lr (U64.v ve) (U64.v vt) /\
            (rg.tl < U64.v vt ==> U64.v vl == off_at rg.lr (U64.v vt)) /\ vg == true /\
            (vg ==> (U64.v vt == rg.tl \/
                     (rg.tl < U64.v retain /\
                      (forall (q: nat). U64.v retain <= q /\ q < U64.v vt ==> None? (rg.lr.m q))))))
    decreases (if !good then 1 + rg.lr.hd - U64.v !tail else 0)
    {
      let vt = !tail;
      let h = header r rs vt;
      if (h.ok) {
        unfold reader_at; with s. _; fold (reader_at r g rs rg v);
        assert pure (U64.v vt < rg.lr.hd);
        step cap rg.lr (U64.v vt);
        let rc : erased record = rec_at rg.lr (U64.v vt);
        assert pure (U64.v h.hlen == rc.len /\ U64.v h.hoff == rc.off /\ U8.v h.htag == tag rc.kind);
        assert pure (U64.v (off_next h) == off_after rc);
        evicted_step cap rg.lr (U64.v !ev) (U64.v vt);
        last := off_next h;
        let nt = U64.add vt (U64.add 13uL h.hlen);
        if (U8.lte h.htag 2uy) { ev := nt };
        tail := nt;
      } else {
        good := false;
      }
    };
    let vt = !tail;
    let vl = !last;
    let ve = !ev;
    let vg = !good;
    if (not vg) {
      false
    } else if (U64.lt vv.rtail vt) {
      if (U64.lt vv.settled vt) {
        if (U64.lt vt upper) {
          let h = header r rs vt;
          if (not h.ok) {
            false
          } else {
            settle r rs vt h.hoff;
            release r rs vt ve;
            set_read r rs upper;
            true
          }
        } else {
          settle r rs vt vl;
          release r rs vt ve;
          set_read r rs upper;
          true
        }
      } else {
        release r rs vt ve;
        set_read r rs upper;
        true
      }
    } else {
      set_read r rs upper;
      true
    }
  }
}

(* A value, or none when a header failed its checks. *)
noeq type answer = { found: bool; value: U64.t }

(* The stream offset at the head, walking the settled position up to it. *)
fn end_offset (r: ring) (rs: ref rstate) (#g: erased gst) (#rg: erased rghost) (#v: erased rstate)
  preserves is_ring r g
  requires reader_at r g rs rg v
  returns a: answer
  ensures exists* (rg': rghost) (v': rstate). reader_at r g rs rg' v' **
    pure (log_le rg.lr rg'.lr /\ rg'.tl == rg.tl /\ a.found /\ U64.v a.value == rg'.lr.hoff)
{
  let cap : capt = capn r;
  let vv = observe r rs;
  with rg1. assert (reader_at r g rs rg1 vv);
  let l : erased log = rg1.lr;
  let upper = vv.seen;
  let mut st = vv.settled;
  let mut so = vv.soff;
  let mut good = true;
  while (!good && U64.lt !st upper)
  invariant exists* (vs vo: U64.t) (vg: bool).
    pts_to st vs ** pts_to so vo ** pts_to good vg ** reader_at r g rs rg1 vv **
    pure (boundary l (U64.v vs) /\ rg.tl <= U64.v vs /\ U64.v vs <= l.hd /\
          U64.v vo == off_at l (U64.v vs) /\ vg == true)
  decreases (if !good then 1 + l.hd - U64.v !st else 0)
  {
    let vs = !st;
    let h = header r rs vs;
    if (h.ok) {
      step cap l (U64.v vs);
      so := off_next h;
      st := U64.add vs (U64.add 13uL h.hlen);
    } else {
      good := false;
    }
  };
  let vs = !st;
  let vo = !so;
  let vg = !good;
  if (vg) {
    settle r rs vs vo;
    Mkanswer true vo
  } else {
    Mkanswer false 0uL
  }
}

(* Whether the record ends at or before [target]: a view resuming there
   has seen it. *)
let before (r: record) (target: nat) : bool =
  match r.kind with
  | Bytes -> r.off + r.len <= target
  | Marker | Slice -> r.off < target
  | Pad -> true

inline_for_extraction
let before_h (h: hdr_view) (target: U64.t) : bool =
  if h.htag = 1uy then
    (if U64.lt h.hoff 0x4000000000000000uL && U64.lt h.hlen 0x100000000uL
     then U64.lte (U64.add h.hoff h.hlen) target else false)
  else if h.htag = 4uy then true
  else U64.lt h.hoff target

let before_h_spec (h: hdr_view) (target: U64.t) (r: record)
  : Lemma (requires U8.v h.htag == tag r.kind /\ U64.v h.hoff == r.off /\ U64.v h.hlen == r.len /\
                    r.off < max_pos /\ r.len < 0x100000000)
          (ensures before_h h target == before r (U64.v target))
= ()

let before_step (l: log) (tl vp: nat) (target: nat)
  : Lemma (requires (forall (q: nat). tl <= q /\ q < vp /\ Some? (l.m q) ==> before (rec_at l q) target) /\
                    Some? (l.m vp) /\ before (rec_at l vp) target /\
                    (forall (q: nat). vp < q /\ q < vp + inc (rec_at l vp) ==> None? (l.m q)))
          (ensures forall (q: nat). tl <= q /\ q < vp + inc (rec_at l vp) /\ Some? (l.m q) ==>
                     before (rec_at l q) target)
= ()

let resumes (rg: rghost) (target p: nat) : prop =
  boundary rg.lr p /\ rg.tl <= p /\ p <= rg.lr.hd /\
  (off_at rg.lr rg.tl <= target ==> off_at rg.lr p <= target) /\
  (forall (q: nat). rg.tl <= q /\ q < p /\ Some? (rg.lr.m q) ==> before (rec_at rg.lr q) target) /\
  (p < rg.lr.hd ==> Some? (rg.lr.m p) /\ not (before (rec_at rg.lr p) target))

(* The first boundary from the tail that a view resuming at [target] has not
   seen, or the head. *)
fn resume (r: ring) (rs: ref rstate) (target: U64.t)
  (#g: erased gst) (#rg: erased rghost) (#v: erased rstate)
  preserves is_ring r g
  requires reader_at r g rs rg v
  returns a: answer
  ensures exists* (rg': rghost) (v': rstate). reader_at r g rs rg' v' **
    pure (log_le rg.lr rg'.lr /\ rg'.tl == rg.tl /\ a.found /\ resumes rg' (U64.v target) (U64.v a.value))
{
  let cap : capt = capn r;
  let vv = observe r rs;
  with rg1. assert (reader_at r g rs rg1 vv);
  let l : erased log = rg1.lr;
  let upper = vv.seen;
  let mut pos = vv.rtail;
  let mut good = true;
  let mut stop = false;
  while (!good && not !stop && U64.lt !pos upper)
  invariant exists* (vp: U64.t) (vg vs: bool).
    pts_to pos vp ** pts_to good vg ** pts_to stop vs ** reader_at r g rs rg1 vv **
    pure (boundary l (U64.v vp) /\ rg.tl <= U64.v vp /\ U64.v vp <= l.hd /\
          (off_at l rg.tl <= U64.v target ==> off_at l (U64.v vp) <= U64.v target) /\
          (forall (q: nat). rg.tl <= q /\ q < U64.v vp /\ Some? (l.m q) ==> before (rec_at l q) (U64.v target)) /\
          (vs ==> U64.v vp < l.hd /\ Some? (l.m (U64.v vp)) /\ not (before (rec_at l (U64.v vp)) (U64.v target))) /\
          vg == true)
  decreases (if !good && not !stop then 1 + l.hd - U64.v !pos else 0)
  {
    let vp = !pos;
    let h = header r rs vp;
    if (h.ok) {
      step cap l (U64.v vp);
      wf_rec cap l (U64.v vp);
      before_h_spec h target (rec_at l (U64.v vp));
      if (before_h h target) {
        before_step l rg.tl (U64.v vp) (U64.v target);
        pos := U64.add vp (U64.add 13uL h.hlen);
      } else {
        stop := true;
      }
    } else {
      good := false;
    }
  };
  let vp = !pos;
  let vg = !good;
  if (vg) {
    Mkanswer true vp
  } else {
    Mkanswer false 0uL
  }
}

(* Whether a view at [pos] lost data the tail passed, and where it resumes if not. *)
fn reachable (r: erased ring) (rs: ref rstate) (pos: U64.t)
  (#g: erased gst) (#rg: erased rghost) (#v: erased rstate)
  preserves reader_at r g rs rg v
  returns a: answer
  ensures pure ((a.found <==> ~(lost rg.lr rg.tl (U64.v pos))) /\
                (a.found ==> U64.v a.value == (if U64.v pos < rg.tl then rg.tl else U64.v pos)))
{
  reader_known r rs;
  unfold reader_at;
  let vv = !rs;
  fold (reader_at r g rs rg v);
  reachable_iff (capn r) rg.lr (U64.v vv.evicted) rg.tl (U64.v pos);
  if (U64.lt pos vv.evicted) {
    Mkanswer false 0uL
  } else {
    Mkanswer true (if U64.lt pos vv.rtail then vv.rtail else pos)
  }
}
