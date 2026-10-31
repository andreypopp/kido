type t

val of_int : int -> t option
val to_int : t -> int
val signal : t -> int -> (unit, Unix.error) result

module Group : sig
  type pid := t
  type t
  type verdict = Child of t | Gone | Foreign

  val verify : parent:pid -> int -> verdict
  val leader : t -> pid
  val signal : t -> int -> unit
end
