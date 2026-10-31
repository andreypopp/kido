module Ring
#lang-pulse
open Pulse.Lib.Pervasives
open KoRing.Spec
open KoRing.Inv
module O = Oint

(* ko_server/ring.mli as the proved callers see it. Each function is the OCaml
   one, a call of the extracted reader; Ring_proof proves each contract from
   KoRing.Reader and KoRing.Walk, so pane, view and ring share one log, tail
   and seen head. *)

type rkind = | Bytes | Marker | Slice | Pad

let of_spec (k: KoRing.Spec.kind) : rkind =
  match k with
  | KoRing.Spec.Bytes -> Bytes | KoRing.Spec.Marker -> Marker
  | KoRing.Spec.Slice -> Slice | KoRing.Spec.Pad -> Pad

(* Ring.t: the mapping and the reader's state. *)
noeq type t = { r: ring; rs: ref rstate }

let res (h: t) (g: gst) (rg: rghost) : slprop =
  is_ring h.r g ** (exists* (v: rstate). reader_at h.r g h.rs rg v)

let cap (h: t) : capt = capn h.r

(* A record the reader may read: published, seen and not released. *)
let vis (rg: rghost) (p: int) : prop = rg.tl <= p /\ p < rg.lr.hd /\ Some? (rg.lr.m p)

let rec_of (rg: rghost) (p: int{vis rg p}) : record = Some?.v (rg.lr.m p)
let next_of (rg: rghost) (p: int{vis rg p}) : int = p + inc (rec_of rg p)
let kind_of (rg: rghost) (p: int{vis rg p}) : rkind = of_spec (rec_of rg p).kind

(* A head load: the same tail, a longer log. *)
let grows (rg rg': rghost) : prop = rg'.tl == rg.tl /\ log_le rg.lr rg'.lr

(* What the reader may rely on about its own view of the ring. *)
let sane (h: t) (rg: rghost) : prop =
  wf (cap h) rg.lr /\ boundary rg.lr rg.tl /\ rg.tl <= rg.lr.hd /\ rg.lr.hd <= rg.tl + cap h /\
  rg.lr.hd <= max_pos /\ rg.lr.hoff <= rg.lr.hd /\ None? (rg.lr.m rg.lr.hd)

(* Where the record's body starts in the mapping. *)
let body (h: t) (p: nat) : int = 32 + p % cap h + 13

let loaded (h: t) (rg rg': rghost) : prop = sane h rg' /\ grows rg rg'

let facts_t = h: t -> #g: erased gst -> #rg: erased rghost ->
  stt_ghost unit emp_inames (res h g rg) (fun _ -> res h g rg ** pure (sane h rg))
let head_t = h: t -> #g: erased gst -> #rg: erased rghost ->
  stt O.t (res h g rg) (fun n -> exists* rg'. res h g rg' ** pure (loaded h rg rg' /\ O.v n == rg'.lr.hd))
let tail_t = h: t -> #g: erased gst -> #rg: erased rghost ->
  stt O.t (res h g rg) (fun n -> res h g rg ** pure (O.v n == rg.tl))
let read_t (a: Type0) (post: (rg: rghost) -> (p: int{vis rg p}) -> a -> prop) =
  h: t -> pos: O.t -> #g: erased gst -> #rg: erased rghost{vis rg (O.v pos)} ->
  stt a (res h g rg) (fun x -> res h g rg ** pure (post rg (O.v pos) x))
let reachable_t = h: t -> pos: O.t{O.v pos >= 0} -> #g: erased gst -> #rg: erased rghost ->
  stt (option O.t) (res h g rg) (fun a -> res h g rg **
    pure ((None? a ==> lost rg.lr rg.tl (O.v pos)) /\
          (Some? a ==> ~(lost rg.lr rg.tl (O.v pos)) /\
                       O.v (Some?.v a) == (if O.v pos < rg.tl then rg.tl else O.v pos))))
let advance_t = h: t -> upper: O.t -> keep: O.t{O.v keep >= 0} -> #g: erased gst ->
  #rg: erased rghost{O.v upper == rg.lr.hd} ->
  stt unit (res h g rg) (fun _ -> exists* rg'. res h g rg' **
    pure (sane h rg' /\ KoRing.Walk.advanced (cap h) rg rg' (O.v upper) (O.v keep)))
let end_offset_t = h: t -> #g: erased gst -> #rg: erased rghost ->
  stt O.t (res h g rg) (fun n -> exists* rg'. res h g rg' ** pure (loaded h rg rg' /\ O.v n == rg'.lr.hoff))
let oldest_offset_t = h: t -> #g: erased gst -> #rg: erased rghost ->
  stt O.t (res h g rg) (fun n -> exists* rg'. res h g rg' **
    pure (loaded h rg rg' /\ off_at rg'.lr rg.tl <= O.v n))
let resume_t = h: t -> target: O.t{O.v target >= 0} -> #g: erased gst -> #rg: erased rghost ->
  stt (n: O.t{O.v n >= 0}) (res h g rg) (fun n -> exists* rg'. res h g rg' **
    pure (loaded h rg rg' /\ KoRing.Walk.resumes rg' (O.v target) (O.v n)))

val facts : facts_t
[@@custard_extern "Ring.head"] val head : head_t
[@@custard_extern "Ring.tail"] val tail : tail_t
[@@custard_extern "Ring.kind"] val kind : read_t rkind (fun rg p k -> k == kind_of rg p)
[@@custard_extern "Ring.length"] val length : read_t O.t (fun rg p n -> O.v n == (rec_of rg p).len)
[@@custard_extern "Ring.offset"] val offset : read_t O.t (fun rg p n -> O.v n == (rec_of rg p).off)
[@@custard_extern "Ring.next"] val next : read_t O.t (fun rg p n -> O.v n == next_of rg p)
[@@custard_extern "Ring.reachable"] val reachable : reachable_t
[@@custard_extern "Ring.advance"] val advance : advance_t
[@@custard_extern "Ring.end_offset"] val end_offset : end_offset_t
[@@custard_extern "Ring.oldest_offset"] val oldest_offset : oldest_offset_t
[@@custard_extern "Ring.resume"] val resume : resume_t
[@@custard_extern "Ring.at"] val at (h: t) (pos: O.t{O.v pos >= 0}) : n: O.t{O.v n == body h (O.v pos)}

(* The mapping as OCaml holds it. *)
[@@custard_extern "Bigstringaf.t"] new val buffer : Type0
[@@custard_extern "Ring.buffer"] val buffer_of (h: t) : buffer
