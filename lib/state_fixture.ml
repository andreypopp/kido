let pane ?(session = "a") ?(created = 100.) ?(session_id = "$0") ?(index = 0) ?(window = "@1")
    ?(active = false) ?(attached = false) ?(running = false) ?start ?prompt ?run ?(pid = 0)
    ?(cmd = "") ?(cwd = "") ?(title = "") ?dead_status ?dead_signal ?kido_session ?kido_name
    ?kido_inbox ?kido_activity id : State.pane =
  {
    session_name = session;
    session_id = Tmux.session_id_of_string session_id;
    session_created = created;
    session_order = None;
    window_index = index;
    window_id = Tmux.window_id_of_string window;
    window_name = "";
    window_layout = "";
    pane_id = Tmux.pane_id_of_string id;
    active;
    pane_active = active;
    pane_pid = pid;
    current_command = cmd;
    current_path = cwd;
    alternate_on = false;
    command_running = running;
    command_start = start;
    last_prompt = prompt;
    last_exit = None;
    command_line = "";
    dead_at = None;
    dead_status;
    dead_signal;
    run;
    ssh = None;
    session_attached = attached;
    modal = false;
    program_status = Tmux.Program_status.empty;
    session = kido_session;
    name = kido_name;
    inbox = kido_inbox;
    activity = kido_activity;
    title;
  }

let root =
  Result.get_exn
    (Tmux.Program_status.parse {|{"serial":1,"records":[{"id":"","app":"pi","state":"idle"}]}|})

let state ~dir panes metas =
  List.iter (Run.write_meta ~dir) metas;
  let pane_of (m : Run.meta) =
    match m.pane with
    | Some p -> Some p
    | None -> (
        match m.kind with
        | Run.Pi ->
            let id = Some (Run.string_of_id m.id) in
            List.find_opt (fun (p : State.pane) -> Option.equal String.equal p.run id) panes
            |> Option.map (fun (p : State.pane) -> p.pane_id)
        | Agent | Bash | Stream -> None)
  in
  let runs =
    List.fold_left
      (fun map m ->
        match pane_of m with
        | Some pane -> Tmux.Pane_map.add pane { Run.meta = m; pi = None } map
        | None -> map)
      Tmux.Pane_map.empty metas
  in
  { State.panes; runs }
