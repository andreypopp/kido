val budget : unit -> int option * float option
(** The seed and the time box that the test entry takes from KO_FUZZ_SEED and KO_FUZZ_SECONDS. *)

val check :
  ?seed:int ->
  ?seconds:float ->
  count:int ->
  name:string ->
  print:'a QCheck2.Print.t ->
  'a QCheck2.Gen.t ->
  ('a -> bool) ->
  unit
