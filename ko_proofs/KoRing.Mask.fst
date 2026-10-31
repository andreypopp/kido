module KoRing.Mask
#lang-pulse
open Pulse.Lib.Pervasives
open KoRing.Spec
module U8 = FStar.UInt8
module A = Pulse.Lib.Array
module Seq = FStar.Seq
module L = FStar.Math.Lemmas

(* The physical indices of the logical positions [lo, hi) of a ring with
   capacity [cap], for hi - lo <= cap. *)
let rng (cap: pos) (lo hi: nat) (i: nat) : prop =
  let s = lo % cap in
  let n = if hi >= lo then hi - lo else 0 in
  i < cap /\ (if s + n <= cap then (s <= i /\ i < s + n) else (s <= i \/ i < s + n - cap))

let mod_step (cap: pos) (lo: nat) (d: nat)
  : Lemma (requires d <= cap)
          (ensures (lo + d) % cap == (if lo % cap + d < cap then lo % cap + d else lo % cap + d - cap))
= L.modulo_distributivity lo d cap;
  if d < cap then L.small_mod d cap else L.small_mod 0 cap

let rng_split (cap: pos) (lo mid hi: nat) (i: nat)
  : Lemma (requires lo <= mid /\ mid <= hi /\ hi - lo <= cap)
          (ensures (rng cap lo hi i <==> (rng cap lo mid i \/ rng cap mid hi i)) /\
                   ~(rng cap lo mid i /\ rng cap mid hi i))
= mod_step cap lo (mid - lo)

let rng_shift (cap: pos) (lo hi: nat) (i: nat)
  : Lemma (rng cap (lo + cap) (hi + cap) i <==> rng cap lo hi i)
= L.lemma_mod_plus lo 1 cap

let rng_in (cap: pos) (lo hi p: nat) 
  : Lemma (requires lo <= p /\ p < hi /\ hi - lo <= cap) (ensures rng cap lo hi (p % cap))
= mod_step cap lo (p - lo)

type bytes = Seq.seq (option U8.t)

(* Every owned byte is initialized: the mapping starts zero-filled. *)
let inited (s: bytes) (mask: nat -> prop) : prop =
  forall (i: nat). i < Seq.length s /\ mask i ==> Some? (Seq.index s i)

let hdr_at (cap: capt) (l: log) (s: bytes) (p: nat) (j: nat) : prop =
  Some? (l.m p) ==>
    (p % cap + j < Seq.length s /\ Seq.index s (p % cap + j) == Some (enc (Some?.v (l.m p)) j))

(* Every record that starts in [lo, hi) of [l] has its header bytes in [s]. *)
[@@"opaque_to_smt"]
let hdr_ok (cap: capt) (l: log) (s: bytes) (lo hi: nat) : prop =
  forall (p: nat) (j: nat). lo <= p /\ p < hi /\ j < 13 ==> hdr_at cap l s p j

let hdr_ok_elim (cap: capt) (l: log) (s: bytes) (lo hi: nat) (p: nat) (j: nat)
  : Lemma (requires hdr_ok cap l s lo hi /\ lo <= p /\ p < hi /\ j < 13) (ensures hdr_at cap l s p j)
= reveal_opaque (`%hdr_ok) (hdr_ok cap l s lo hi)

let hdr_ok_intro (cap: capt) (l: log) (s: bytes) (lo hi: nat)
    (f: (p: nat) -> (j: nat) -> Lemma (requires lo <= p /\ p < hi /\ j < 13) (ensures hdr_at cap l s p j))
  : Lemma (hdr_ok cap l s lo hi)
= reveal_opaque (`%hdr_ok) (hdr_ok cap l s lo hi);
  Classical.forall_intro_2 (fun p -> Classical.move_requires (f p))

let rng_split_all (cap: capt) (lo mid hi: nat)
  : Lemma (requires lo <= mid /\ mid <= hi /\ hi - lo <= cap)
          (ensures forall (i: nat). (rng cap lo hi i <==> (rng cap lo mid i \/ rng cap mid hi i)) /\
                                    ~(rng cap lo mid i /\ rng cap mid hi i))
= Classical.forall_intro (Classical.move_requires (rng_split cap lo mid hi))

ghost
fn split_at (a: A.array U8.t) (cap: capt) (lo mid hi: nat) (#s: bytes)
  requires A.pts_to_mask a s (rng cap lo hi)
  requires pure (lo <= mid /\ mid <= hi /\ hi - lo <= cap)
  ensures A.pts_to_mask a s (rng cap lo mid)
  ensures A.pts_to_mask a s (rng cap mid hi)
{
  rng_split_all cap lo mid hi;
  A.split_mask a (rng cap lo mid);
  A.mask_mext a #_ #s #(mask_isect (rng cap lo hi) (rng cap lo mid)) (rng cap lo mid);
  A.mask_mext a #_ #s #(mask_diff (rng cap lo hi) (rng cap lo mid)) (rng cap mid hi);
}

ghost
fn join_at (a: A.array U8.t) (cap: capt) (lo mid hi: nat) (#s1 #s2: bytes)
  requires A.pts_to_mask a s1 (rng cap lo mid)
  requires A.pts_to_mask a s2 (rng cap mid hi)
  requires pure (lo <= mid /\ mid <= hi /\ hi - lo <= cap)
  ensures exists* (s: bytes). A.pts_to_mask a s (rng cap lo hi) **
    pure (Seq.length s == Seq.length s1 /\ Seq.length s == Seq.length s2 /\
          (forall (i: nat). i < Seq.length s ==>
             (rng cap lo mid i ==> Seq.index s i == Seq.index s1 i) /\
             (rng cap mid hi i ==> Seq.index s i == Seq.index s2 i)))
{
  rng_split_all cap lo mid hi;
  A.join_mask a #_ #s1 #s2 #(rng cap lo mid) #(rng cap mid hi);
  with s. assert (A.pts_to_mask a s (fun i -> rng cap lo mid i \/ rng cap mid hi i));
  A.mask_mext a #_ #s (rng cap lo hi);
}

(* Positions [lo, hi) and [lo + cap, hi + cap) are the same bytes. *)
ghost
fn shift (a: A.array U8.t) (cap: capt) (lo hi: nat) (#s: bytes)
  requires A.pts_to_mask a s (rng cap lo hi)
  ensures A.pts_to_mask a s (rng cap (lo + cap) (hi + cap))
{
  Classical.forall_intro (rng_shift cap lo hi);
  A.mask_mext a #_ #s (rng cap (lo + cap) (hi + cap));
}

(* Byte [j] of the record at [p] lies in any window that holds the record. *)
let rec_byte_in (cap: capt) (lo hi p: nat) (j: nat)
  : Lemma (requires lo <= p /\ p + j < hi /\ hi - lo <= cap /\ p % cap + j < cap)
          (ensures rng cap lo hi (p % cap + j))
= mod_step cap p j;
  rng_in cap lo hi (p + j)

let log_le_trans (a b c: log)
  : Lemma (requires log_le a b /\ log_le b c) (ensures log_le a c) = ()

let log_le_refl (a: log) : Lemma (log_le a a) = ()

let agree (cap: capt) (s s1: bytes) (lo hi: nat) : prop =
  Seq.length s == Seq.length s1 /\
  (forall (i: nat). i < Seq.length s /\ rng cap lo hi i ==> Seq.index s i == Seq.index s1 i)

(* Joining two windows keeps the headers each held, against the newer log. *)
let hdr_ok_join (cap: capt) (la lb: log) (s1 s2 s: bytes) (lo mid hi: nat)
  : Lemma
    (requires
      wf cap la /\ wf cap lb /\ log_le la lb /\ la.hd == mid /\ lb.hd == hi /\ lo <= mid /\ mid <= hi /\ hi - lo <= cap /\
      Seq.length s1 == cap /\ Seq.length s2 == cap /\
      hdr_ok cap la s1 lo mid /\ hdr_ok cap lb s2 mid hi /\
      agree cap s s1 lo mid /\ agree cap s s2 mid hi)
    (ensures hdr_ok cap lb s lo hi)
= let aux (p: nat) (j: nat)
    : Lemma (requires lo <= p /\ p < hi /\ j < 13) (ensures hdr_at cap lb s p j)
    = if p < mid then begin
        hdr_ok_elim cap la s1 lo mid p j;
        if Some? (la.m p) then (wf_rec cap la p; rec_byte_in cap lo mid p j)
      end else begin
        hdr_ok_elim cap lb s2 mid hi p j;
        if Some? (lb.m p) then (wf_rec cap lb p; rec_byte_in cap mid hi p j)
      end
  in
  hdr_ok_intro cap lb s lo hi aux

(* Publishing [r] at the head of [l]: the old window's headers and the new
   record's header, in the joined bytes [s]. *)
let hdr_ok_extend (cap: capt) (l: log) (r: record) (s2 sb s: bytes) (seen: nat)
  : Lemma
    (requires
      wf cap l /\ seen <= l.hd /\ l.hd + inc r - seen <= cap /\ l.hd % cap + inc r <= cap /\
      Seq.length s2 == cap /\ Seq.length sb == cap /\
      hdr_ok cap l s2 seen l.hd /\
      (forall (j: nat). j < 13 ==> Seq.index sb (l.hd % cap + j) == Some (enc r j)) /\
      agree cap s s2 seen l.hd /\ agree cap s sb l.hd (l.hd + inc r))
    (ensures hdr_ok cap (extend l r) s seen (l.hd + inc r))
= let l' = extend l r in
  let aux (p: nat) (j: nat)
    : Lemma (requires seen <= p /\ p < l'.hd /\ j < 13) (ensures hdr_at cap l' s p j)
    = if p = l.hd then rec_byte_in cap l.hd (l.hd + inc r) p j
      else if Some? (l.m p) then begin
        wf_rec cap l p;
        hdr_ok_elim cap l s2 seen l.hd p j;
        rec_byte_in cap seen l.hd p j
      end
  in
  hdr_ok_intro cap l' s seen l'.hd aux

let hdr_ok_narrow (cap: capt) (l: log) (s: bytes) (lo lo' hi: nat)
  : Lemma (requires hdr_ok cap l s lo hi /\ lo <= lo') (ensures hdr_ok cap l s lo' hi)
= hdr_ok_intro cap l s lo' hi (fun p j -> hdr_ok_elim cap l s lo hi p j)

let hdr_ok_empty (cap: capt) (l: log) (s: bytes) (lo: nat) : Lemma (hdr_ok cap l s lo lo)
= hdr_ok_intro cap l s lo lo (fun p j -> ())

let inited_join (cap: capt) (s s1 s2: bytes) (lo mid hi: nat)
  : Lemma
    (requires lo <= mid /\ mid <= hi /\ hi - lo <= cap /\ Seq.length s == cap /\
              Seq.length s1 == cap /\ Seq.length s2 == cap /\
              inited s1 (rng cap lo mid) /\ inited s2 (rng cap mid hi) /\
              agree cap s s1 lo mid /\ agree cap s s2 mid hi)
    (ensures inited s (rng cap lo hi))
= rng_split_all cap lo mid hi

let inited_split (cap: capt) (s: bytes) (lo mid hi: nat)
  : Lemma
    (requires lo <= mid /\ mid <= hi /\ hi - lo <= cap /\ inited s (rng cap lo hi))
    (ensures inited s (rng cap lo mid) /\ inited s (rng cap mid hi))
= rng_split_all cap lo mid hi

let inited_empty (cap: capt) (s: bytes) (lo: nat) : Lemma (inited s (rng cap lo lo)) = ()

let inited_shift (cap: capt) (s: bytes) (lo hi: nat)
  : Lemma (requires inited s (rng cap lo hi)) (ensures inited s (rng cap (lo + cap) (hi + cap)))
= Classical.forall_intro (rng_shift cap lo hi)

(* The 13 header bytes of a record at [p] lie in any window that holds it. *)
let hdr_in (cap: capt) (lo hi p: nat)
  : Lemma (requires lo <= p /\ p + 13 <= hi /\ hi - lo <= cap /\ p % cap + 13 <= cap)
          (ensures forall (i: nat). p % cap <= i /\ i < p % cap + 13 ==> rng cap lo hi i)
= let aux (i: nat) : Lemma (requires p % cap <= i /\ i < p % cap + 13) (ensures rng cap lo hi i)
    = rec_byte_in cap lo hi p (i - p % cap) in
  Classical.forall_intro (Classical.move_requires aux)
