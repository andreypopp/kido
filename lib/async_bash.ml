let usage = "usage: kido async_bash [--name NAME] [--stream] -- COMMAND [ARG...]"

(* One word is a shell command line ("make -j8 && ./run"); several are an argv. *)
let command_argv = function [] -> [] | [ line ] -> [ "bash"; "-c"; line ] | argv -> argv

let derived_name args =
  let first =
    match args with
    | a :: _ -> ( match Procs.split_fields a with (w :: _) :: _ -> Filename.basename w | _ -> "")
    | [] -> ""
  in
  let name = String.filter (fun c -> Char.Ascii.is_alphanum c || String.contains "-_." c) first in
  if String.is_empty name then "bash"
  else String.sub name 0 (min (String.length name) Spawn_subagent.max_window_name_len)

let async_bash ~dir ~self ~exe ~panes ~tmux ~name ~stream args =
  let argv = command_argv args in
  if List.is_empty argv then failwith ("no command given\n" ^ usage);
  let name = if String.is_empty name then derived_name args else name in
  Spawn_subagent.check_window_name name;
  let pane = List_agents.caller_pane (Lazy.force panes) self in
  let own = State.String_map.find_opt pane.pane_id (State.by_pane (State.load_live ~dir)) in
  let runs = Filename.concat dir "runs" in
  let id = Subrun.new_id () in
  Subrun.create ~dir:runs id (String.concat " " args);
  Subrun.write_command ~dir:runs id argv;
  let meta : Subrun.meta =
    {
      id;
      name;
      kind = Some Bash;
      parent_session = Option.map_or ~default:"" fst own;
      depth = 1 + Option.map_or ~default:0 (fun (_, (s : State.session)) -> s.depth) own;
      pane = "";
      pid = 0;
      cwd = pane.current_path;
      model = "";
      tools = [];
      keep_alive = false;
      started_at = Timestamp.now ();
    }
  in
  Subrun.write_meta ~dir:runs meta;
  let parent =
    Option.map (fun (session, (s : State.session)) -> State.{ pid = s.pid; session }) own
  in
  let env =
    Spawn_subagent.run_env ~runs id parent meta.depth ~keep_alive:false
    @ [ "KIDO_STATE_DIR=" ^ dir ]
  in
  Spawn_subagent.create_run_window ~runs tmux meta ~session:pane.session_id ~env
    ([ exe; "async-run"; "--run-id"; Subrun.string_of_id id ]
    @ if stream then [ "--stream" ] else [])
