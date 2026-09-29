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

let hook = function
  | _ :: _ ->
      prerr_endline "usage: kido hook";
      0
  | [] ->
      let debug =
        not (String.is_empty (Option.value (Sys.getenv_opt "KIDO_HOOK_DEBUG") ~default:""))
      in
      let json = Yojson.Safe.from_string (In_channel.input_all stdin) in
      let input = Result.get_or_failwith (Hook.input_of_yojson json) in
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
      |> Result.iter_err (fun holder -> Cli.error "hook" (State.held_message id holder));
      0

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
  let rec boundary n = if n > 0 && Char.code s.[n] land 0xC0 = 0x80 then boundary (n - 1) else n in
  let s = if String.length s <= max then s else String.sub s 0 (boundary max) in
  String.rdrop_while (Char.equal ' ') s

let agent_status ~agent ~session:id ~status ~title ~inbox ~activity ~parent_pid ~parent_session
    ~depth ~model ~ended ~remove args =
  let usage =
    "usage: kido agent-status --agent NAME --session ID --status "
    ^ String.concat "|" (List.map fst State.statuses)
    ^ " [--title TITLE] [--inbox PATH] [--activity TEXT] [--parent-pid PID] [--parent-session ID] \
       [--depth N] [--model NAME] [--ended] [--remove]"
  in
  (match args with arg :: _ -> Cli.failf "unknown argument %S\n%s" arg usage | [] -> ());
  if String.is_empty agent || String.is_empty id then
    failwith ("--agent and --session are required\n" ^ usage);
  let dir = State.dir () in
  let outcome =
    if remove then State.remove ~dir id ~pid:(Unix.getppid ())
    else
      match List.assoc_opt ~eq:String.equal status State.statuses with
      | None -> Cli.failf "unknown status %S\n%s" status usage
      | Some status ->
          record ~dir id
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
            ~ended
  in
  match outcome with
  | Ok () -> 0
  | Error holder ->
      Cli.error "agent-status" (State.held_message id holder);
      6
