type result = Success | Failure
type outcome = { serial : int; result : result } [@@deriving yojson_of]

type agent_state =
  | Running of { progress : int option }
  | Waiting of { kind : Tmux.Program_status.kind option; progress : int option }
  | Idle of { outcome : outcome option }
[@@deriving yojson_of]

type agent = { since : float; msg : string option; state : agent_state } [@@deriving yojson_of]

type exit = { code : int; command : string; started_at : float; ended_at : float }
[@@deriving yojson_of]

type phase =
  | Unknown
  | Idle of { last : exit option }
  | Running of { command : string; started_at : float; fullscreen : bool }
  | Fullscreen
[@@deriving yojson_of]

type shell = { phase : phase; report : agent option } [@@deriving yojson_of]

type remote =
  | Remote_terminal of { interactive : bool; status : shell }
  | Remote_agent of { name : string; status : agent }
[@@deriving yojson_of]

type kind =
  | Terminal of shell
  | Some_agent of { name : string; status : agent }
  | Pi_agent of { session : string; status : agent }
  | Ssh of { user : string; host : string; pane : remote }
[@@deriving yojson_of]

type track

val observe : now:float -> State.pane -> Pane_kind.t -> track option -> track * kind
val pending : track -> bool
val label : track -> State.pane -> string
