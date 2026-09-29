let max_depth = 2

(* MAX_PROMPT_BYTES in pi/kido-status.ts: both deliver a session's first user message. *)
let max_task_bytes = 1024 * 1024
let max_window_name_len = 64

let usage =
  "usage: kido spawn_subagent --parent-pid PID --parent-session ID --name NAME --task-file FILE|- \
   [--fork SESSION_ID] [--model M] [--tools T,...] [--keep-alive] [-- COMMAND...]\n\
  \   or: kido spawn_subagent --no-parent --name NAME --task-file FILE|- [--model M] [--tools \
   T,...] [--keep-alive] [-- COMMAND...]\n\
  \   or: kido spawn_subagent --resume RUN_ID [--parent-pid PID --parent-session ID | --no-parent] \
   [--keep-alive] [-- COMMAND...]"

type tmux = {
  new_window :
    session:string ->
    name:string ->
    cwd:string ->
    env:string list ->
    string list ->
    Tmux.Exec.window;
  mark_run : string -> string -> unit;
  window_exists : string -> bool;
  kill_window : string -> unit;
}

let tmux =
  {
    new_window = Tmux.Exec.new_window;
    mark_run = Tmux.Exec.mark_run;
    window_exists = Tmux.Exec.window_exists;
    kill_window = Tmux.Exec.kill_window;
  }

type pi = {
  list_models : unit -> (string, string) result;
  session_dir : string;
  agent_dir : string;
  home : string;
}

(* Run with kido's own environment and pi's stderr dropped, as Go's Output() would. *)
let list_models ~path () =
  match Tmux.Exec.look_path ~path "pi" with
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
  | Resume of { run : Subrun.id; adopt : bool }

type request = {
  mode : mode;
  parent : State.parent option;
  keep_alive : bool;
  command : string list;
}

let check_window_name name =
  Result.iter_err failwith (Launch.tmux_safe "window name" name);
  if String.length name > max_window_name_len then
    failwith
      (Printf.sprintf "refusing window name %S: %d bytes is over the %d byte limit" name
         (String.length name) max_window_name_len)

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
    (try fill () with Sys_error e -> failwith (Printf.sprintf "reading task from stdin: %s" e));
    if Buffer.length buf > max_task_bytes then
      failwith (Printf.sprintf "task on stdin is over the %d byte task limit" max_task_bytes);
    Buffer.contents buf
  end
  else
    let fail e = failwith (Printf.sprintf "--task-file %S: %s" path (Unix.error_message e)) in
    match Unix.stat path with
    | exception Unix.Unix_error (e, _, _) -> fail e
    | { st_kind = S_DIR; _ } ->
        failwith (Printf.sprintf "--task-file %S is a directory, not a task file" path)
    | { st_size; _ } when st_size > max_task_bytes ->
        failwith
          (Printf.sprintf "--task-file %S is %d bytes, over the %d byte task limit" path st_size
             max_task_bytes)
    | _ -> (
        match In_channel.with_open_bin path In_channel.input_all with
        | task -> task
        | exception Sys_error e -> failwith (Printf.sprintf "--task-file %S: %s" path e))

let parse (f : flags) =
  let refuse why = failwith (why ^ "\n" ^ usage) in
  let command = if List.is_empty f.command then [ "pi" ] else f.command in
  let given = f.parent_pid > 0 || not (String.is_empty f.parent_session) in
  let parent : State.parent option =
    if f.no_parent && given then
      refuse "--no-parent contradicts --parent-pid/--parent-session; pass one or the other"
    else if f.parent_pid > 0 && not (String.is_empty f.parent_session) then
      Some { pid = f.parent_pid; session = f.parent_session }
    else if given then
      refuse "--parent-pid and --parent-session name one parent and are given together"
    else None
  in
  let mode =
    if not (String.is_empty f.resume) then begin
      if not (String.is_empty f.task_file) then
        refuse "--resume keeps the run's original task; --task-file is refused alongside it";
      if not (String.is_empty f.name) then
        refuse "--resume keeps the run's original window name; --name is refused alongside it";
      if not (String.is_empty f.fork) then
        refuse
          "--resume continues a run's own session; --fork starts a new one from somebody else's, \
           and the two cannot both be asked for";
      match Subrun.parse_id f.resume with
      | Error e -> refuse e
      | Ok run -> Resume { run; adopt = Option.is_none parent && not f.no_parent }
    end
    else begin
      if Option.is_none parent && not f.no_parent then
        refuse
          "--parent-pid and --parent-session are required (or --no-parent for a child owned by \
           nobody)";
      if String.is_empty f.name then refuse "--name is required";
      if String.is_empty f.task_file then refuse "--task-file is required";
      check_window_name f.name;
      Result.iter_err failwith (Launch.tmux_safe "--fork" f.fork);
      let task = read_task f.task_file in
      let tools = if String.is_empty f.tools then [] else String.split_on_char ',' f.tools in
      Fresh { name = f.name; task; fork = f.fork; model = f.model; tools }
    end
  in
  { mode; parent; keep_alive = f.keep_alive; command }

let fields line =
  String.map (fun c -> if Char.is_whitespace_ascii c then ' ' else c) line
  |> String.split_on_char ' '
  |> List.filter (fun f -> not (String.is_empty f))

(* A model no configured provider can run makes pi print "Use /login ..." and exit 0 having run
   no turn. pi --list-models prints a header, then one row per model: provider, model id. *)
let validate_model list_models command =
  let model =
    match command with
    | "pi" :: _ ->
        let rec after = function "--model" :: m :: _ -> m | _ :: rest -> after rest | [] -> "" in
        after command
    | _ -> ""
  in
  if not (String.is_empty model) then
    match list_models () with
    | Error e ->
        failwith (Printf.sprintf "could not validate model %S: pi --list-models: %s" model e)
    | Ok out ->
        let rows =
          List.filter_map
            (fun line -> match fields line with p :: m :: _ -> Some (p, m) | _ -> None)
            (List.drop 1 (String.lines out))
        in
        if not (List.exists (fun (p, m) -> String.equal (p ^ "/" ^ m) model) rows) then
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
          failwith
            (Printf.sprintf "model %S is not a model of a configured provider; configured: %s" model
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

let caller_pane panes self =
  match List_agents.find_pane panes self with
  | Some p -> p
  | None -> failwith (Printf.sprintf "pane %S not found" self)

(* new-window gives the child the tmux server's environment, so KIDO_AGENT_* is its only channel;
   internal/reap reads a zero parent as an orphan's, so an absent one is left out. *)
let run_env ~runs id parent depth ~keep_alive =
  [
    "KIDO_AGENT_TASK_FILE=" ^ Subrun.task_path ~dir:runs id;
    "KIDO_AGENT_RUN_ID=" ^ Subrun.string_of_id id;
    "KIDO_AGENT_DEPTH=" ^ string_of_int depth;
  ]
  @ (match parent with
    | Some ({ pid; session } : State.parent) ->
        [ "KIDO_AGENT_PARENT_PID=" ^ string_of_int pid; "KIDO_AGENT_PARENT_SESSION=" ^ session ]
    | None -> [])
  @ if keep_alive then [ "KIDO_AGENT_KEEP_ALIVE=1" ] else []

let failed ~runs (meta : Subrun.meta) text =
  ignore
    (Subrun.record_outcome ~dir:runs meta.id
       { result = Failed; text; at = Some (Timestamp.now ()) })

(* The mark is what makes a window reapable at all, so a failed mark kills the window. A window
   already gone cannot be marked: a bash run's wrapper reports its own ending, an agent run has
   nobody else to. *)
let create_run_window ~runs tmux (meta : Subrun.meta) ~session ~env command =
  let w =
    match tmux.new_window ~session ~name:meta.name ~cwd:meta.cwd ~env command with
    | w -> w
    | exception Failure e ->
        failed ~runs meta e;
        failwith e
  in
  let meta = { meta with pane = w.pane_id; pid = w.pane_pid } in
  Subrun.write_meta ~dir:runs meta;
  let id = Subrun.string_of_id meta.id in
  (match tmux.mark_run w.pane_id id with
  | () -> ()
  | exception Failure _ when Stdlib.(meta.kind = Some Bash) && not (tmux.window_exists w.window_id)
    ->
      ()
  | exception Failure e ->
      (try tmux.kill_window w.window_id with Failure _ -> ());
      failed ~runs meta e;
      failwith e);
  match meta.kind with
  | Some Bash ->
      String.concat " " [ w.window_id; w.pane_id; id; Subrun.output_path ~dir:runs meta.id ]
  | Some Agent | None -> String.concat " " [ w.window_id; w.pane_id; id ]

let insert_after_head extra = function head :: rest -> (head :: extra) @ rest | [] -> extra

let spawn ~dir ~self ~panes ~tmux ~pi req =
  let runs = Filename.concat dir "runs" in
  let pane = caller_pane (Lazy.force panes) self in
  let live = State.load_live ~dir in
  let own = State.Panes.find_opt pane.pane_id (State.by_pane live) in
  let parent =
    match (req.mode, own) with
    | Resume { adopt = true; _ }, Some (id, s) -> Some State.{ pid = s.pid; session = id }
    | _ -> req.parent
  in
  let depth = 1 + Option.map_or ~default:0 (fun (_, (s : State.session)) -> s.depth) own in
  if depth > max_depth then
    failwith
      (Printf.sprintf
         "refusing to spawn at depth %d: maximum nesting is %d (root 0, subagent 1, subagent 2)"
         depth max_depth);
  Option.iter
    (fun ({ session; _ } : State.parent) ->
      if not (List.mem_assoc ~eq:String.equal session live) then
        failwith
          (Printf.sprintf
             "--parent-session %S names no currently live agent; the child would be closed within \
              moments as an orphan (internal/reap's rule 2) - pass --no-parent for a child owned \
              by nobody, or name an agent that is actually running"
             session))
    parent;
  let is_pi = match req.command with "pi" :: _ -> true | _ -> false in
  let meta, command, mint =
    match req.mode with
    | Fresh f ->
        let id = Subrun.new_id () in
        let meta : Subrun.meta =
          {
            id;
            name = f.name;
            kind = Some Agent;
            parent_session = "";
            depth = 0;
            pane = "";
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
        (meta, (if is_pi then insert_after_head flags req.command else req.command), false)
    | Resume { run; _ } ->
        let meta =
          match Subrun.read_meta ~dir:runs run with
          | Some m -> m
          | None ->
              failwith
                (Printf.sprintf "run %S: no readable %s" (Subrun.string_of_id run)
                   (Filename.concat (Filename.concat runs (Subrun.string_of_id run)) "meta.json"))
        in
        if Option.is_none (Subrun.effective_outcome ~dir:runs meta.id ~pid:meta.pid) then
          failwith
            (Printf.sprintf "run %S is still running (pid %d); resuming a live agent makes no sense"
               (Subrun.string_of_id meta.id) meta.pid);
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
        (meta, command, mint)
  in
  validate_model pi.list_models command;
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
      Subrun.create ~dir:runs meta.id task;
      Subrun.write_meta ~dir:runs meta
  | Resume _ -> Subrun.reset_for_resume ~dir:runs meta.id ~delivered:mint);
  create_run_window ~runs tmux meta ~session:pane.session_id
    ~env:(run_env ~runs meta.id parent depth ~keep_alive:meta.keep_alive)
    command
