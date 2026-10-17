let max_depth = 2

(* MAX_PROMPT_BYTES in share/pi/kido-status.ts: both deliver a session's first user message. *)
let max_task_bytes = 1024 * 1024

type flags = {
  name : string;
  task_file : string;
  model : string;
  tools : string option;
  resume : string;
  fork : string;
  keep_alive : bool;
  no_parent : bool;
  command : string list;
}

type mode =
  | Fresh of { name : string; task : string; fork : string; model : string }
  | Resume of Run.id

type request = {
  mode : mode;
  no_parent : bool;
  tools : string list option;
  keep_alive : bool;
  command : string list;
}

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

type error = Usage of string | Invalid of string

let parse (f : flags) =
  let open Result.Infix in
  let refuse why = Error (Usage why) and invalid r = Result.map_err (fun e -> Invalid e) r in
  let command = if List.is_empty f.command then [ "pi" ] else f.command in
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
      else match Run.parse_id f.resume with Error e -> refuse e | Ok run -> Ok (Resume run)
    else if String.is_empty f.name then refuse "--name is required"
    else if String.is_empty f.task_file then refuse "--task-file is required"
    else
      let* () = invalid (Run_window.check_name f.name) in
      let* () = invalid (Tmux.safe "--fork" f.fork) in
      let+ task = invalid (read_task f.task_file) in
      Fresh { name = f.name; task; fork = f.fork; model = f.model }
  in
  let tools =
    Option.map (fun s -> if String.is_empty s then [] else String.split_on_char ',' s) f.tools
  in
  { mode; no_parent = f.no_parent; tools; keep_alive = f.keep_alive; command }

(* A model no configured provider can run makes pi print "Use /login ..." and exit 0 having run
   no turn. pi --list-models prints a header, then one row per model: provider, model id. *)
let validate_model ~path command =
  let thinking_levels = [ "off"; "minimal"; "low"; "medium"; "high"; "xhigh"; "max" ] in
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
            (fun line -> match Text.fields line with p :: m :: _ -> Some (p, m) | _ -> None)
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

let insert_after_head extra = function head :: rest -> (head :: extra) @ rest | [] -> extra

let spawn ~dir ~self ~caller ~path req =
  let open Result.Infix in
  let* state = State.read ~dir (Tmux.create ()) in
  let* pane = State.caller_pane state self in
  let parent = if req.no_parent then None else Option.map fst caller in
  let depth =
    Option.map_or ~default:0
      (fun id -> 1 + Option.map_or ~default:0 (Run.depth ~dir) (Run.read_meta ~dir id))
      parent
  in
  let* () =
    match (parent, caller) with
    | None, None when (not req.no_parent) && match req.mode with Fresh _ -> true | _ -> false ->
        Error
          "no calling agent session ($PI_SESSION_ID names none); pass --no-parent for a child \
           owned by nobody"
    | _ when depth > max_depth ->
        Error
          (Printf.sprintf
             "refusing to spawn at depth %d: maximum nesting is %d (root 0, subagent 1, subagent 2)"
             depth max_depth)
    | Some id, Some (_, (s : Run.pi)) when not (Run.alive s.pid) ->
        Error
          (Printf.sprintf
             "the calling session %S is not live; the child would be closed within moments as an \
              orphan by the reap sweep - pass --no-parent for a child owned by nobody"
             (Run.string_of_id id))
    | _ -> Ok ()
  in
  let is_pi = match req.command with "pi" :: _ -> true | _ -> false in
  let* meta, command, start =
    match req.mode with
    | Fresh f ->
        let id = Run.new_id () in
        let meta : Run.meta =
          {
            id;
            name = f.name;
            kind = Agent;
            parent = None;
            pane = None;
            pid = 0;
            cwd = pane.current_path;
            model = f.model;
            tools = [];
            keep_alive = false;
            started_at = Timestamp.now ();
          }
        in
        (* pi 0.85.1 composes --fork with --session-id: the fork is made under the given id, so a
           forked child still holds its run id. *)
        let flags =
          (if String.is_empty f.fork then [] else [ "--fork"; f.fork ])
          @ [ "--session-id"; Run.string_of_id id ]
        in
        let command = if is_pi then insert_after_head flags req.command else req.command in
        Ok (meta, command, Run.Fresh_start)
    | Resume run ->
        let* meta =
          Option.to_result
            (Printf.sprintf "run %S: no readable %s" (Run.string_of_id run) (Run.meta_path ~dir run))
            (Run.read_meta ~dir run)
        in
        let id = Run.string_of_id meta.id in
        let* () =
          match meta.kind with
          | Pi ->
              Error (Printf.sprintf "run %S is not a subagent run: kido did not start its pi" id)
          | _ when Run.alive meta.pid ->
              Error
                (Printf.sprintf
                   "run %S is still running (pid %d); resuming a live agent makes no sense" id
                   meta.pid)
          | _ -> Ok ()
        in
        (* With no pi session file the id is free rather than stale, so --session-id mints one
           under it and the stored task is delivered again. *)
        let session =
          Option.map (fun (p : Run.pi) -> p.session_file) (Run.read_pi ~dir run)
          |> Option.filter Fs.is_file
        in
        let command =
          if not is_pi then req.command
          else
            let command =
              insert_after_head
                (Option.map_or ~default:[ "--session-id"; id ]
                   (fun f -> [ "--session"; f ])
                   session)
                req.command
            in
            let lacks flag = not (List.mem ~eq:String.equal flag (List.tl command)) in
            command
            @
            if (not (String.is_empty meta.model)) && lacks "--model" then [ "--model"; meta.model ]
            else []
        in
        Ok (meta, command, if Option.is_none session then Run.Restart_task else Run.Continue_session)
  in
  let tools = Option.get_or ~default:meta.tools req.tools in
  let tools =
    match parent with
    | Some _
      when is_pi
           && (not (List.is_empty tools))
           && not (List.mem ~eq:String.equal "notify_parent" tools) ->
        tools @ [ "notify_parent" ]
    | _ -> tools
  in
  let command =
    if is_pi && not (List.is_empty tools) then command @ [ "--tools"; String.concat "," tools ]
    else command
  in
  let* () = validate_model ~path command in
  (* A resume keeps the run's own cwd: pi sessions are project-scoped, and `pi --session` from
     another directory asks to fork instead of resuming. *)
  let meta = { meta with tools; parent; keep_alive = meta.keep_alive || req.keep_alive } in
  (match req.mode with
  | Fresh { task; _ } ->
      Run.create ~dir meta.id task;
      Run.write_meta ~dir meta
  | Resume _ -> ());
  let+ line = Run_window.create ~start ~dir meta ~session:pane.session_id command in
  Option.iter
    (fun (old : State.pane) ->
      Result.iter
        (fun c -> ignore (Reap.release (Tmux.create ()) c))
        (Reap.decide state old.window_id))
    (Option.flat_map (State.find state)
       (Option.filter (fun _ -> match start with Fresh_start -> false | _ -> true) meta.pane));
  line
