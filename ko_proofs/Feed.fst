module Feed
open KoRing.Spec
open KoRing.Inv

(* A snapshot request's progress, shared by the pane that produces its slices
   and the view that consumes them. *)
type st =
  | Absent
  | Pending : g: int -> floor: int -> st
  | Sliced : g: int -> floor: int -> last: int -> st
  | Finished : g: int -> hold: int -> st

let gen_of (s: st) : int =
  match s with Absent -> -1 | Pending g _ -> g | Sliced g _ _ -> g | Finished g _ -> g

(* A slice at [pos] for generation [g]: after the floor and after the last one. *)
let slice_step (prior now: st) (g: int) (pos: int) : prop =
  match prior with
  | Pending g' fl -> g' == g /\ fl <= pos /\ now == Sliced g fl pos
  | Sliced g' fl last -> g' == g /\ last < pos /\ now == Sliced g fl pos
  | _ -> False

(* snapshot_done for generation [g]: the tail is still at or before the
   position after its last slice. *)
let done_step (prior: st) (g: int) (rg: rghost) : prop =
  match prior with
  | Finished g' hold -> g' == g /\ rg.tl <= hold /\ hold <= rg.lr.hd /\ boundary rg.lr hold
  | _ -> False
