module Ring_proof
#lang-pulse
open Pulse.Lib.Pervasives
open KoRing.Spec
open KoRing.Inv
open KoRing.Reader
open Ring
module O = Oint
module U8 = FStar.UInt8
module U64 = FStar.UInt64
module W = KoRing.Walk

(* Each of Ring's contracts, met by the reader: ring.ml makes the same calls of
   the extracted C. *)

ghost
fn facts_impl (h: t) (#g: erased gst) (#rg: erased rghost)
  preserves res h g rg
  ensures pure (sane h rg)
{
  unfold res;
  reader_known h.r h.rs;
  fold (res h g rg);
}
let facts_proved : facts_t = facts_impl

fn head_impl (h: t) (#g: erased gst) (#rg: erased rghost)
  requires res h g rg
  returns n: O.t
  ensures exists* rg'. res h g rg' ** pure (loaded h rg rg' /\ O.v n == rg'.lr.hd)
{
  unfold res;
  let x = observe h.r h.rs;
  reader_known h.r h.rs;
  fold (res h g _);
  O.of_u64 x.seen
}
let head_proved : head_t = head_impl

fn tail_impl (h: t) (#g: erased gst) (#rg: erased rghost)
  preserves res h g rg
  returns n: O.t
  ensures pure (O.v n == rg.tl)
{
  unfold res;
  reader_known h.r h.rs;
  unfold reader_at;
  let vv = !h.rs;
  fold reader_at;
  fold (res h g rg);
  O.of_u64 vv.rtail
}
let tail_proved : tail_t = tail_impl

(* The record's header, which the ring proves valid at a visible position. *)
fn hdr (h: t) (pos: O.t) (#g: erased gst) (#rg: erased rghost{vis rg (O.v pos)})
  preserves res h g rg
  returns x: hdr_view
  ensures pure (x.ok /\ U8.v x.htag == tag (rec_of rg (O.v pos)).kind /\
                U64.v x.hlen == (rec_of rg (O.v pos)).len /\ U64.v x.hoff == (rec_of rg (O.v pos)).off /\
                O.v pos + 13 + U64.v x.hlen <= rg.lr.hd /\ rg.lr.hd <= max_pos /\
                U64.v x.hoff <= O.v pos)
{
  facts_impl h;
  wf_rec (cap h) rg.lr (O.v pos);
  unfold res;
  let x = header h.r h.rs (O.to_u64 pos);
  fold (res h g rg);
  x
}

fn kind_impl (h: t) (pos: O.t) (#g: erased gst) (#rg: erased rghost{vis rg (O.v pos)})
  preserves res h g rg
  returns k: rkind
  ensures pure (k == kind_of rg (O.v pos))
{
  let x = hdr h pos;
  of_spec (KoRing.Spec.kind_of (U8.v x.htag))
}
let kind_proved : read_t rkind (fun rg p k -> k == kind_of rg p) = kind_impl

fn length_impl (h: t) (pos: O.t) (#g: erased gst) (#rg: erased rghost{vis rg (O.v pos)})
  preserves res h g rg
  returns n: O.t
  ensures pure (O.v n == (rec_of rg (O.v pos)).len)
{
  let x = hdr h pos;
  O.of_u64 x.hlen
}
let length_proved : read_t O.t (fun rg p n -> O.v n == (rec_of rg p).len) = length_impl

fn offset_impl (h: t) (pos: O.t) (#g: erased gst) (#rg: erased rghost{vis rg (O.v pos)})
  preserves res h g rg
  returns n: O.t
  ensures pure (O.v n == (rec_of rg (O.v pos)).off)
{
  let x = hdr h pos;
  O.of_u64 x.hoff
}
let offset_proved : read_t O.t (fun rg p n -> O.v n == (rec_of rg p).off) = offset_impl

fn next_impl (h: t) (pos: O.t) (#g: erased gst) (#rg: erased rghost{vis rg (O.v pos)})
  preserves res h g rg
  returns n: O.t
  ensures pure (O.v n == next_of rg (O.v pos))
{
  let x = hdr h pos;
  O.add pos (O.add O.c13 (O.of_u64 x.hlen))
}
let next_proved : read_t O.t (fun rg p n -> O.v n == next_of rg p) = next_impl

fn reachable_impl (h: t) (pos: O.t{O.v pos >= 0}) (#g: erased gst) (#rg: erased rghost)
  preserves res h g rg
  returns a: option O.t
  ensures pure ((None? a ==> lost rg.lr rg.tl (O.v pos)) /\
                (Some? a ==> ~(lost rg.lr rg.tl (O.v pos)) /\
                             O.v (Some?.v a) == (if O.v pos < rg.tl then rg.tl else O.v pos)))
{
  unfold res;
  reader_known h.r h.rs;
  let a = W.reachable h.r h.rs (O.to_u64 pos);
  fold (res h g rg);
  if a.found { Some (O.of_u64 a.value) } else { None }
}
let reachable_proved : reachable_t = reachable_impl

fn advance_impl (h: t) (upper: O.t) (keep: O.t{O.v keep >= 0}) (#g: erased gst)
  (#rg: erased rghost{O.v upper == rg.lr.hd})
  requires res h g rg
  ensures exists* rg'. res h g rg' **
    pure (sane h rg' /\ W.advanced (cap h) rg rg' (O.v upper) (O.v keep))
{
  facts_impl h;
  unfold res;
  let ok = W.advance h.r h.rs (O.to_u64 upper) (O.to_u64 keep);
  reader_known h.r h.rs;
  fold (res h g _);
}
let advance_proved : advance_t = advance_impl

fn end_offset_impl (h: t) (#g: erased gst) (#rg: erased rghost)
  requires res h g rg
  returns n: O.t
  ensures exists* rg'. res h g rg' ** pure (loaded h rg rg' /\ O.v n == rg'.lr.hoff)
{
  unfold res;
  let a = W.end_offset h.r h.rs;
  reader_known h.r h.rs;
  fold (res h g _);
  O.of_u64 a.value
}
let end_offset_proved : end_offset_t = end_offset_impl

fn oldest_offset_impl (h: t) (#g: erased gst) (#rg: erased rghost)
  requires res h g rg
  returns n: O.t
  ensures exists* rg'. res h g rg' ** pure (loaded h rg rg' /\ off_at rg'.lr rg.tl <= O.v n)
{
  facts_impl h;
  let tl = tail_impl h;
  let hd = head_impl h;
  if (O.lt tl hd) {
    offset_impl h tl
  } else {
    end_offset_impl h
  }
}
let oldest_offset_proved : oldest_offset_t = oldest_offset_impl

fn resume_impl (h: t) (target: O.t{O.v target >= 0}) (#g: erased gst) (#rg: erased rghost)
  requires res h g rg
  returns n: (n: O.t{O.v n >= 0})
  ensures exists* rg'. res h g rg' ** pure (loaded h rg rg' /\ W.resumes rg' (O.v target) (O.v n))
{
  unfold res;
  let a = W.resume h.r h.rs (O.to_u64 target);
  reader_known h.r h.rs;
  fold (res h g _);
  O.of_u64 a.value
}
let resume_proved : resume_t = resume_impl

let at_proved (h: t) (pos: O.t{O.v pos >= 0}) : n: O.t{O.v n == body h (O.v pos)} =
  O.of_u64 (U64.add 45uL (U64.rem (O.to_u64 pos) h.r.cap))
