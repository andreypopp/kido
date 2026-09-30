val deliver_or_paste :
  inbox:string -> payload:string -> pane:string -> string -> ([ `Inbox | `Pasted ], string) result
(** Pastes [text] into [pane] only when the inbox is [Unavailable]: any other failure may have
    delivered already. *)

type error = No_prompt | Not_found | Several | Failed of string

val prompt : dir:string -> self:string -> window:bool -> string -> (unit, error) result
