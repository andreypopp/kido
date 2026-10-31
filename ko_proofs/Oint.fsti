module Oint
#lang-pulse
open Pulse.Lib.Pervasives
module U64 = FStar.UInt64

(* OCaml's int: every operation is a Stdlib primitive on an unboxed int, and
   its precondition rules out overflow. *)
let min_int : int = -0x4000000000000000
let max_int : int = 0x3fffffffffffffff
let fits (x: int) : prop = min_int <= x /\ x <= max_int

[@@custard_extern "int"]
new val t : eqtype
val v (x: t) : GTot (y: int{fits y})
val v_inj (a b: t) : Lemma (requires v a == v b) (ensures a == b) [SMTPat (v a); SMTPat (v b)]

[@@custard_extern "Stdlib.( + )"]
val add (a b: t) : Pure t (requires fits (v a + v b)) (ensures fun c -> v c == v a + v b)
[@@custard_extern "Stdlib.( - )"]
val sub (a b: t) : Pure t (requires fits (v a - v b)) (ensures fun c -> v c == v a - v b)
[@@custard_extern "Stdlib.( < )"]
val lt (a b: t) : r: bool{r <==> v a < v b}
[@@custard_extern "Stdlib.( <= )"]
val le (a b: t) : r: bool{r <==> v a <= v b}
[@@custard_extern "Stdlib.( = )"]
val eq (a b: t) : r: bool{r <==> v a == v b}

[@@custard_extern "0"]
val zero : z: t{v z == 0}
[@@custard_extern "1"]
val one : z: t{v z == 1}
[@@custard_extern "13"]
val c13 : z: t{v z == 13}
[@@custard_extern "65536"]
val c65536 : z: t{v z == 65536}
[@@custard_extern "1073741824"]
val c2p30 : z: t{v z == 1073741824}

(* Conversions for proofs about the ring; the extracted code never calls them. *)
[@@custard_extern "Fun.id"]
val of_u64 (x: U64.t{U64.v x <= max_int}) : y: t{v y == U64.v x}
[@@custard_extern "Fun.id"]
val to_u64 (x: t{v x >= 0}) : y: U64.t{U64.v y == v x}

(* An OCaml int array, indexed without a bounds check: the preconditions
   prove every index. *)
[@@custard_extern "int array"]
new val arr : Type0
val arr_pts (a: arr) (s: Seq.seq t) : slprop

[@@custard_extern "Array.make"]
fn arr_make (n: t{0 <= v n /\ v n <= 1024}) (x: t)
  returns a: arr
  ensures arr_pts a (Seq.create (v n) x)

[@@custard_extern "Array.unsafe_get"]
fn arr_get (a: arr) (i: t) (#s: erased (Seq.seq t){0 <= v i /\ v i < Seq.length (reveal s)})
  preserves arr_pts a s
  returns x: t
  ensures pure (x == Seq.index s (v i))

[@@custard_extern "Array.unsafe_set"]
fn arr_set (a: arr) (i: t) (x: t) (#s: erased (Seq.seq t){0 <= v i /\ v i < Seq.length (reveal s)})
  requires arr_pts a s
  ensures arr_pts a (Seq.upd s (v i) x)
