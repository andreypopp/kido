type task = { status : string }

type input = {
  event : string;
  session_id : string;
  notification_type : string;
  trigger : string;
  tool_name : string;
  agent_id : string;
  background_tasks : task list;
}
[@@deriving of_yojson]

type action =
  | Ignore
  | Remove
  | Ended
  | Report of { status : State.status; background : bool; tool_pending : bool }

val apply : input -> parked:bool -> action
val describe : input -> action -> string
