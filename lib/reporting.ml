let record ~dir id (s : State.session) ~ended =
  let ended =
    if not ended then None
    else
      match State.get ~dir id with
      | Some { status = Idle; ended = Some prev; _ } -> Some prev
      | _ -> Some s.ts
  in
  State.record ~dir id { s with ended }

let session ~agent ~pane ~pid status : State.session =
  {
    agent;
    pane;
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

let debug_log ~dir = Filename.concat dir "debug.log"

let log_hook ~dir ~pane json (input : Hook.input) action =
  try
    Fs.mkdir_p ~perm:0o700 dir;
    Out_channel.with_open_gen [ Open_append; Open_creat; Open_wronly ] 0o600 (debug_log ~dir)
      (fun oc ->
        Printf.fprintf oc "%s\t%s\t%s\t%s\n"
          (Timestamp.to_string (Timestamp.now ()))
          (Option.map_or ~default:"" Tmux.Pane.to_string pane)
          (Yojson.Safe.to_string json) (Hook.describe input action))
  with Sys_error _ | Unix.Unix_error _ -> ()

let hook ~dir ~pane ~debug text =
  let open Result.Infix in
  let* json =
    match Yojson.Safe.from_string text with
    | json -> Ok json
    | exception Yojson.Json_error m -> Error m
  in
  let* input = Hook.input_of_yojson json in
  let id = input.session_id in
  let parked =
    (not (String.is_empty id))
    && Option.exists (fun (s : State.session) -> s.background) (State.get ~dir id)
  in
  let action = Hook.apply input ~parked in
  if debug then log_hook ~dir ~pane json input action;
  let claude status = session ~agent:Claude ~pane ~pid:(Procs.reporter_pid ()) status in
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

let agent_status ~dir ~pane ~agent ~session:id ~title ~inbox ~activity ~parent_pid ~parent_session
    ~depth ~model ~ended status =
  record ~dir id
    {
      (session ~agent:(State.agent_of_string agent) ~pane ~pid:(Unix.getppid ()) status) with
      title;
      inbox;
      activity = one_line activity ~max:256;
      parent =
        (if String.is_empty parent_session then None
         else Some { session = parent_session; pid = parent_pid });
      depth;
      model;
    }
    ~ended
