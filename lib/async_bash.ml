let usage = "usage: kido tool async_bash [--name NAME] [--stream] -- COMMAND [ARG...]"

let derived_name args =
  let first =
    match args with
    | a :: _ -> ( match Procs.split_fields a with (w :: _) :: _ -> Filename.basename w | _ -> "")
    | [] -> ""
  in
  let name = String.filter (fun c -> Char.Ascii.is_alphanum c || String.contains "-_." c) first in
  if String.is_empty name then "bash"
  else String.sub name 0 (min (String.length name) Spawn_subagent.max_window_name_len)

let async_bash ~dir ~self ~exe ~name ~stream args =
  let open Result.Infix in
  (* One word is a shell command line ("make -j8 && ./run"); several are an argv. *)
  let argv = match args with [ line ] -> [ "bash"; "-c"; line ] | argv -> argv in
  let* () = if List.is_empty argv then Error ("no command given\n" ^ usage) else Ok () in
  let name = if String.is_empty name then derived_name args else name in
  let* () = Spawn_subagent.check_window_name name in
  let* pane, parent, depth = Spawn_subagent.caller ~dir ~self Adopt in
  let id = Subrun.new_id () in
  Subrun.create ~dir id (String.concat " " args);
  Subrun.write_command ~dir id argv;
  let meta : Subrun.meta =
    {
      id;
      name;
      kind = (if stream then Stream else Bash);
      parent_session = Option.map_or ~default:"" (fun (p : State.parent) -> p.session) parent;
      depth;
      pane = None;
      pid = 0;
      cwd = pane.current_path;
      model = "";
      tools = [];
      keep_alive = false;
      started_at = Timestamp.now ();
    }
  in
  Subrun.write_meta ~dir meta;
  let env = Spawn_subagent.run_env ~dir id parent depth in
  Spawn_subagent.create_run_window ~dir meta ~session:pane.session_id ~env
    [ exe; "async-run"; "--run-id"; Subrun.string_of_id id ]
