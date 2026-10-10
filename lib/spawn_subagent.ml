let max_depth = 2

(* MAX_PROMPT_BYTES in share/pi/kido-status.ts: both deliver a session's first user message. *)
let max_task_bytes = 1024 * 1024
let max_window_name_len = 64

let usage =
  "usage: kido tool spawn_subagent --parent-pid PID --parent-session ID --name NAME --task-file \
   FILE|- [--fork SESSION_ID] [--model M] [--tools T,...] [--keep-alive] [-- COMMAND...]\n\
  \   or: kido tool spawn_subagent --no-parent --name NAME --task-file FILE|- [--model M] [--tools \
   T,...] [--keep-alive] [-- COMMAND...]\n\
  \   or: kido tool spawn_subagent --resume RUN_ID [--parent-pid PID --parent-session ID | \
   --no-parent] [--keep-alive] [-- COMMAND...]"

type pi = { path : string; session_dir : string; agent_dir : string; home : string }

type flags = {
  parent_pid : int;
  parent_session : string;
  name : string;
  task_file : string;
  model : string;
  tools : string;
  resume : string;
  fork : string;
  keep_alive : bool;
  no_parent : bool;
  command : string list;
}

type mode =
  | Fresh of { name : string; task : string; fork : string; model : string; tools : string list }
  | Resume of Subrun.id

type owner = Given of State.parent | Nobody | Adopt
type request = { mode : mode; owner : owner; keep_alive : bool; command : string list }

let check_window_name name =
  let open Result.Infix in
  let* () = Launch.tmux_safe "window name" name in
  if String.length name > max_window_name_len then
    Error
      (Printf.sprintf "refusing window name %S: %d bytes is over the %d byte limit" name
         (String.length name) max_window_name_len)
  else Ok ()

let read_task path =
  if String.equal path "-" then begin
    let buf = Buffer.create 4096 in
    let chunk = Bytes.create 65536 in
    let rec fill () =
      if Buffer.length buf <= max_task_bytes then
        match In_channel.input stdin chunk 0 (Bytes.length chunk) with
        | 0 -> ()
        | n ->
            Buffer.add_subbytes buf chunk 0 n;
            fill ()
    in
    match fill () with
    | exception Sys_error e -> Error ("reading task from stdin: " ^ e)
    | () when Buffer.length buf > max_task_bytes ->
        Error (Printf.sprintf "task on stdin is over the %d byte task limit" max_task_bytes)
    | () -> Ok (Buffer.contents buf)
  end
  else
    match Unix.stat path with
    | exception Unix.Unix_error (e, _, _) ->
        Error (Printf.sprintf "--task-file %S: %s" path (Unix.error_message e))
    | { st_kind = S_DIR; _ } ->
        Error (Printf.sprintf "--task-file %S is a directory, not a task file" path)
    | { st_size; _ } when st_size > max_task_bytes ->
        Error
          (Printf.sprintf "--task-file %S is %d bytes, over the %d byte task limit" path st_size
             max_task_bytes)
    | _ -> (
        match In_channel.with_open_bin path In_channel.input_all with
        | task -> Ok task
        | exception Sys_error e -> Error (Printf.sprintf "--task-file %S: %s" path e))

let parse (f : flags) =
  let open Result.Infix in
  let refuse why = Error (why ^ "\n" ^ usage) in
  let command = if List.is_empty f.command then [ "pi" ] else f.command in
  let given = f.parent_pid > 0 || not (String.is_empty f.parent_session) in
  let* owner =
    if f.no_parent && given then
      refuse "--no-parent contradicts --parent-pid/--parent-session; pass one or the other"
    else if f.parent_pid > 0 && not (String.is_empty f.parent_session) then
      Ok (Given { pid = f.parent_pid; session = f.parent_session })
    else if given then
      refuse "--parent-pid and --parent-session name one parent and are given together"
    else if f.no_parent then Ok Nobody
    else Ok Adopt
  in
  let+ mode =
    if not (String.is_empty f.resume) then
      if not (String.is_empty f.task_file) then
        refuse "--resume keeps the run's original task; --task-file is refused alongside it"
      else if not (String.is_empty f.name) then
        refuse "--resume keeps the run's original window name; --name is refused alongside it"
      else if not (String.is_empty f.fork) then
        refuse
          "--resume continues a run's own session; --fork starts a new one from somebody else's, \
           and the two cannot both be asked for"
      else match Subrun.parse_id f.resume with Error e -> refuse e | Ok run -> Ok (Resume run)
    else
      match owner with
      | Adopt ->
          refuse
            "--parent-pid and --parent-session are required (or --no-parent for a child owned by \
             nobody)"
      | Given _ | Nobody ->
          if String.is_empty f.name then refuse "--name is required"
          else if String.is_empty f.task_file then refuse "--task-file is required"
          else
            let* () = check_window_name f.name in
            let* () = Launch.tmux_safe "--fork" f.fork in
            let+ task = read_task f.task_file in
            let tools = if String.is_empty f.tools then [] else String.split_on_char ',' f.tools in
            Fresh { name = f.name; task; fork = f.fork; model = f.model; tools }
  in
  { mode; owner; keep_alive = f.keep_alive; command }

let thinking_levels = [ "off"; "minimal"; "low"; "medium"; "high"; "xhigh"; "max" ]

(* A model no configured provider can run makes pi print "Use /login ..." and exit 0 having run
   no turn. pi --list-models prints a header, then one row per model: provider, model id. *)
let validate_model ~path command =
  let open Result.Infix in
  let argument =
    match command with
    | "pi" :: _ ->
        let rec after = function "--model" :: m :: _ -> m | _ :: rest -> after rest | [] -> "" in
        after command
    | _ -> ""
  in
  if String.is_empty argument then Ok ()
  else
    let listed =
      match Fs.look_path ~path "pi" with
      | None -> Error {|exec: "pi": executable file not found in $PATH|}
      | Some pi -> (
          let r, w = Unix.pipe ~cloexec:true () in
          let null = Unix.openfile "/dev/null" [ Unix.O_WRONLY; Unix.O_CLOEXEC ] 0 in
          let pid =
            Fun.protect
              ~finally:(fun () -> List.iter Unix.close [ w; null ])
              (fun () -> Unix.create_process pi [| "pi"; "--list-models" |] Unix.stdin w null)
          in
          let out =
            Fun.protect
              ~finally:(fun () -> Unix.close r)
              (fun () -> In_channel.input_all (Unix.in_channel_of_descr r))
          in
          match snd (Unix.waitpid [] pid) with
          | WEXITED 0 -> Ok out
          | WEXITED n -> Error (Printf.sprintf "exit status %d" n)
          | WSIGNALED n | WSTOPPED n -> Error (Printf.sprintf "signal %d" n))
    in
    match listed with
    | Error e ->
        Error (Printf.sprintf "could not validate model %S: pi --list-models: %s" argument e)
    | Ok out ->
        let rows =
          List.filter_map
            (fun line ->
              match Procs.split_fields line with [ p :: m :: _ ] -> Some (p, m) | _ -> None)
            (List.drop 1 (String.lines out))
        in
        let configured id = List.exists (fun (p, m) -> String.equal (p ^ "/" ^ m) id) rows in
        let* model =
          if configured argument then Ok argument
          else
            match String.rindex_opt argument ':' with
            | None -> Ok argument
            | Some i ->
                let id = String.sub argument 0 i in
                let level = String.sub argument (i + 1) (String.length argument - i - 1) in
                if List.mem ~eq:String.equal level thinking_levels then Ok id
                else
                  Error
                    (Printf.sprintf "unknown thinking level %S; valid levels: %s" level
                       (String.concat ", " thinking_levels))
        in
        if configured model then Ok ()
        else
          let providers =
            List.rev
              (List.fold_left
                 (fun acc (p, _) -> if List.mem ~eq:String.equal p acc then acc else p :: acc)
                 [] rows)
          in
          let group p =
            p ^ "/{"
            ^ String.concat ","
                (List.filter_map (fun (q, m) -> if String.equal p q then Some m else None) rows)
            ^ "}"
          in
          Error
            (Printf.sprintf "model %S is not a model of a configured provider; configured: %s"
               argument
               (String.concat ", " (List.map group providers)))

(* pi 0.85.1's getDefaultSessionDirPath (session-manager.js): PI_CODING_AGENT_SESSION_DIR, else
   <PI_CODING_AGENT_DIR or ~/.pi/agent>/sessions/--<cwd, / \ : as ->--, files named
   "<timestamp>_<id>.jsonl". pi's settings.json "sessionDir" is not read. With no home the check
   cannot be made and reads as present. *)
let pi_session_file_exists pi cwd id =
  let dir =
    if not (String.is_empty pi.session_dir) then Some pi.session_dir
    else
      let agent_dir =
        if not (String.is_empty pi.agent_dir) then Some pi.agent_dir
        else if String.is_empty pi.home then None
        else Some (Filename.concat pi.home ".pi/agent")
      in
      Option.map
        (fun agent_dir ->
          let cwd = Option.get_or ~default:cwd (String.chop_prefix ~pre:"/" cwd) in
          let safe = String.map (function '/' | '\\' | ':' -> '-' | c -> c) cwd in
          Filename.concat (Filename.concat agent_dir "sessions") ("--" ^ safe ^ "--"))
        agent_dir
  in
  match dir with
  | None -> true
  | Some dir -> (
      let suffix = "_" ^ Subrun.string_of_id id ^ ".jsonl" in
      match Sys.readdir dir with
      | exception Sys_error _ -> false
      | names -> Array.exists (String.suffix ~suf:suffix) names)

let run_env ~dir id parent depth =
  [
    "KIDO_AGENT_TASK_FILE=" ^ Subrun.task_path ~dir id;
    "KIDO_AGENT_RUN_ID=" ^ Subrun.string_of_id id;
    "KIDO_AGENT_DEPTH=" ^ string_of_int depth;
  ]
  @
  match parent with
  | Some ({ pid; session } : State.parent) ->
      [ "KIDO_AGENT_PARENT_PID=" ^ string_of_int pid; "KIDO_AGENT_PARENT_SESSION=" ^ session ]
  | None -> []

let create_run_window ?resume ~dir (meta : Subrun.meta) ~session ~env command =
  let tmux = Tmux.create () in
  let open Result.Infix in
  let fail e =
    ignore
      (Subrun.record_outcome ~dir meta.id
         { result = Failed; text = e; at = Some (Timestamp.now ()) });
    Error e
  in
  let* w =
    match Tmux.new_window tmux ~session ~name:meta.name ~cwd:meta.cwd ~env command with
    | Ok w -> Ok w
    | Error e -> fail e
  in
  let meta = { meta with pane = Some w.pane_id; pid = w.pane_pid } in
  Subrun.write_meta ~dir meta;
  Option.iter (fun delivered -> Subrun.reset_for_resume ~dir meta.id ~delivered) resume;
  let id = Subrun.string_of_id meta.id in
  let+ () =
    match Tmux_pane.mark_run tmux w.pane_id id with
    | Ok () -> Ok ()
    | Error e -> (
        match meta.kind with
        | (Bash | Stream) when not (Tmux.window_exists tmux w.window_id) -> Ok ()
        | Bash | Stream | Agent ->
            ignore (Tmux.run tmux [ "kill-window"; "-t"; Tmux.string_of_window_id w.window_id ]);
            fail e)
  in
  match meta.kind with
  | Bash | Stream ->
      String.concat " "
        [
          Tmux.string_of_window_id w.window_id;
          Tmux.string_of_pane_id w.pane_id;
          id;
          Subrun.output_path ~dir meta.id;
        ]
  | Agent ->
      String.concat " "
        [ Tmux.string_of_window_id w.window_id; Tmux.string_of_pane_id w.pane_id; id ]

let insert_after_head extra = function head :: rest -> (head :: extra) @ rest | [] -> extra

let caller ~dir ~self owner =
  let open Result.Infix in
  let* panes = Tmux_pane.list_panes (Tmux.create ()) in
  let+ pane = List_runs.caller_pane panes self in
  let own = Tmux.Pane_map.find_opt pane.pane_id (State.by_pane (State.load_live ~dir)) in
  let parent =
    match (owner, own) with
    | Given p, _ -> Some p
    | Adopt, Some (session, s) -> Some State.{ pid = s.pid; session }
    | Adopt, None | Nobody, _ -> None
  in
  (pane, parent, 1 + Option.map_or ~default:0 (fun (_, (s : State.session)) -> s.depth) own)

let spawn ~dir ~self ~pi req =
  let open Result.Infix in
  let* pane, parent, depth = caller ~dir ~self req.owner in
  let* () =
    if depth > max_depth then
      Error
        (Printf.sprintf
           "refusing to spawn at depth %d: maximum nesting is %d (root 0, subagent 1, subagent 2)"
           depth max_depth)
    else
      match parent with
      | Some { session; _ }
        when not
               (Option.exists
                  (fun (s : State.session) -> State.alive s.pid)
                  (State.get ~dir session)) ->
          Error
            (Printf.sprintf
               "--parent-session %S names no currently live agent; the child would be closed \
                within moments as an orphan by the reap sweep - pass --no-parent for a child owned \
                by nobody, or name an agent that is actually running"
               session)
      | _ -> Ok ()
  in
  let is_pi = match req.command with "pi" :: _ -> true | _ -> false in
  let* meta, command, mint =
    match req.mode with
    | Fresh f ->
        let id = Subrun.new_id () in
        let meta : Subrun.meta =
          {
            id;
            name = f.name;
            kind = Agent;
            parent_session = "";
            depth = 0;
            pane = None;
            pid = 0;
            cwd = pane.current_path;
            model = f.model;
            tools = f.tools;
            keep_alive = false;
            started_at = Timestamp.now ();
          }
        in
        (* pi 0.85.1 composes --fork with --session-id: the fork is made under the given id, so a
           forked child still holds its run id. *)
        let flags =
          (if String.is_empty f.fork then [] else [ "--fork"; f.fork ])
          @ [ "--session-id"; Subrun.string_of_id id ]
        in
        Ok (meta, (if is_pi then insert_after_head flags req.command else req.command), false)
    | Resume run ->
        let* meta =
          Option.to_result
            (Printf.sprintf "run %S: no readable %s" (Subrun.string_of_id run)
               (Subrun.meta_path ~dir run))
            (Subrun.read_meta ~dir run)
        in
        let* () =
          if State.alive meta.pid then
            Error
              (Printf.sprintf
                 "run %S is still running (pid %d); resuming a live agent makes no sense"
                 (Subrun.string_of_id meta.id) meta.pid)
          else Ok ()
        in
        (* With no pi session file the id is free rather than stale, so --session-id mints one
           under it and the stored task is delivered again. *)
        let mint = not (pi_session_file_exists pi meta.cwd meta.id) in
        let id = Subrun.string_of_id meta.id in
        let command =
          if not is_pi then req.command
          else
            let command =
              insert_after_head [ (if mint then "--session-id" else "--session"); id ] req.command
            in
            let lacks flag = not (List.mem ~eq:String.equal flag (List.tl command)) in
            command
            @ (if (not (String.is_empty meta.model)) && lacks "--model" then
                 [ "--model"; meta.model ]
               else [])
            @
            if (not (List.is_empty meta.tools)) && lacks "--tools" then
              [ "--tools"; String.concat "," meta.tools ]
            else []
        in
        Ok (meta, command, mint)
  in
  let* () = validate_model ~path:pi.path command in
  (* A resume keeps the run's own cwd: pi sessions are project-scoped, and `pi --session` from
     another directory asks to fork instead of resuming. *)
  let meta =
    {
      meta with
      parent_session = Option.map_or ~default:"" (fun (p : State.parent) -> p.session) parent;
      depth;
      keep_alive = meta.keep_alive || req.keep_alive;
    }
  in
  (match req.mode with
  | Fresh { task; _ } ->
      Subrun.create ~dir meta.id task;
      Subrun.write_meta ~dir meta
  | Resume _ -> ());
  let resume = match req.mode with Fresh _ -> None | Resume _ -> Some mint in
  create_run_window ?resume ~dir meta ~session:pane.session_id
    ~env:(run_env ~dir meta.id parent depth)
    command
