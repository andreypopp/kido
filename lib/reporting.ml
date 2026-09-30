let record ~dir id (s : State.session) ~ended =
  let ended =
    match State.get ~dir id with
    | _ when not ended -> None
    | Some { status = Idle; ended = Some prev; _ } -> Some prev
    | _ -> Some s.ts
  in
  State.record ~dir id { s with ended }

let session ~agent ~pid status : State.session =
  {
    agent;
    pane = Option.value (Sys.getenv_opt "TMUX_PANE") ~default:"";
    pid;
    status;
    ts = Timestamp.now ();
    title = "";
    inbox = "";
    ended = None;
    background = false;
    tool_pending = false;
    activity = "";
    parent = None;
    depth = 0;
    model = "";
  }

let log_hook ~dir json (input : Hook.input) action =
  try
    Fs.mkdir_p dir;
    Out_channel.with_open_gen [ Open_append; Open_creat; Open_wronly ]
      0o600 (Filename.concat dir "debug.log") (fun oc ->
        Printf.fprintf oc "%s\t%s\t%s\t%s\n"
          (Timestamp.to_string (Timestamp.now ()))
          (Option.value (Sys.getenv_opt "TMUX_PANE") ~default:"")
          (Yojson.Safe.to_string json) (Hook.describe input action))
  with Sys_error _ | Unix.Unix_error _ -> ()

let hook text =
  let open Result.Infix in
  let debug = not (String.is_empty (Option.value (Sys.getenv_opt "KIDO_HOOK_DEBUG") ~default:"")) in
  let* json =
    match Yojson.Safe.from_string text with
    | json -> Ok json
    | exception Yojson.Json_error m -> Error m
  in
  let* input = Hook.input_of_yojson json in
  let dir = State.dir () in
  let id = input.session_id in
  let parked =
    (not (String.is_empty id))
    && Option.exists (fun (s : State.session) -> s.background) (State.get ~dir id)
  in
  let action = Hook.apply input ~parked in
  if debug then log_hook ~dir json input action;
  let claude status = session ~agent:Claude ~pid:(Procs.reporter_pid ()) status in
  (match action with
    | Ignore -> Ok ()
    | Remove -> State.remove ~dir id ~pid:(Procs.reporter_pid ())
    | Ended -> record ~dir id (claude Idle) ~ended:true
    | Report { status; background; tool_pending } ->
        record ~dir id { (claude status) with background; tool_pending } ~ended:false)
  |> Result.map_err (State.held_message id)

let one_line s ~max =
  let b = Buffer.create (String.length s) in
  let rec clean i =
    if i < String.length s then begin
      let d = String.get_utf_8_uchar s i in
      let c = Uchar.to_int (Uchar.utf_decode_uchar d) in
      if (not (Uchar.utf_decode_is_valid d)) || c < 0x20 || (c >= 0x7F && c <= 0x9F) || c = 0xFFFD
      then Buffer.add_char b ' '
      else Buffer.add_utf_8_uchar b (Uchar.utf_decode_uchar d);
      clean (i + Uchar.utf_decode_length d)
    end
  in
  clean 0;
  let s = Buffer.contents b in
  String.rdrop_while (Char.equal ' ') (Msg.utf_8_prefix s max)

type status_error = Invalid of string | Held of string

let agent_status ~agent ~session:id ~status ~title ~inbox ~activity ~parent_pid ~parent_session
    ~depth ~model ~ended ~remove args =
  let usage =
    "usage: kido agent-status --agent NAME --session ID --status "
    ^ String.concat "|" (List.map fst State.statuses)
    ^ " [--title TITLE] [--inbox PATH] [--activity TEXT] [--parent-pid PID] [--parent-session ID] \
       [--depth N] [--model NAME] [--ended] [--remove]"
  in
  let held r = Result.map_err (fun holder -> Held (State.held_message id holder)) r in
  match args with
  | arg :: _ -> Error (Invalid (Printf.sprintf "unknown argument %S\n%s" arg usage))
  | [] when String.is_empty agent || String.is_empty id ->
      Error (Invalid ("--agent and --session are required\n" ^ usage))
  | [] -> (
      let dir = State.dir () in
      if remove then held (State.remove ~dir id ~pid:(Unix.getppid ()))
      else
        match List.assoc_opt ~eq:String.equal status State.statuses with
        | None -> Error (Invalid (Printf.sprintf "unknown status %S\n%s" status usage))
        | Some status ->
            held
            @@ record ~dir id
                 {
                   (session ~agent:(State.agent_of_string agent) ~pid:(Unix.getppid ()) status) with
                   title;
                   inbox;
                   activity = one_line activity ~max:256;
                   parent =
                     (if String.is_empty parent_session then None
                      else Some { session = parent_session; pid = parent_pid });
                   depth;
                   model;
                 }
                 ~ended)
