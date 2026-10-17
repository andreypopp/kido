let max_name_len = 64

let check_name name =
  let open Result.Infix in
  let* () = Tmux.safe "window name" name in
  if String.length name > max_name_len then
    Error
      (Printf.sprintf "refusing window name %S: %d bytes is over the %d byte limit" name
         (String.length name) max_name_len)
  else Ok ()

let create ?resume ~dir (meta : Run.meta) ~session command =
  let env =
    [
      "KIDO_AGENT_TASK_FILE=" ^ Run.task_path ~dir meta.id;
      "KIDO_AGENT_RUN_ID=" ^ Run.string_of_id meta.id;
    ]
    @ Option.map_or ~default:[]
        (fun p -> [ "KIDO_AGENT_PARENT_SESSION=" ^ Run.string_of_id p ])
        meta.parent
  in
  let tmux = Tmux.create () in
  let open Result.Infix in
  let fail e =
    ignore
      (Run.record_outcome ~dir meta.id { result = Failed; text = e; at = Some (Timestamp.now ()) });
    Error e
  in
  let id = Run.string_of_id meta.id in
  let* w =
    match
      Tmux.new_window tmux
        ~setup:(id, [ (Tmux_vars.run, id); ("remain-on-exit", "on") ])
        ~session ~name:meta.name ~cwd:meta.cwd ~env command
    with
    | Ok w -> Ok w
    | Error e -> fail e
  in
  let meta = { meta with pane = Some w.pane_id; pid = w.pane_pid } in
  Run.write_meta ~dir meta;
  Option.iter (fun delivered -> Run.reset_for_resume ~dir meta.id ~delivered) resume;
  Ok
    (match meta.kind with
    | Bash | Stream ->
        String.concat " "
          [
            Tmux.string_of_window_id w.window_id;
            Tmux.string_of_pane_id w.pane_id;
            id;
            Run.output_path ~dir meta.id;
          ]
    | Pi | Agent ->
        String.concat " "
          [ Tmux.string_of_window_id w.window_id; Tmux.string_of_pane_id w.pane_id; id ])
