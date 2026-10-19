let wait ~dir id =
  let open Result.Infix in
  let* meta =
    Option.to_result
      (Printf.sprintf "run %s has no meta" (Run.string_of_id id))
      (Run.read_meta ~dir id)
  in
  let read_pane () = State.read_run (Tmux.create ()) meta in
  let rec poll () =
    match Run.read_outcome ~dir id with
    | Some outcome -> Ok outcome
    | None -> (
        match read_pane () with
        | Error e -> Error (Printf.sprintf "cannot read the tmux state: %s" e)
        | Ok state -> (
            match State.run_ending ~dir state meta with
            | Some outcome -> Ok outcome
            | None ->
                Unix.sleepf Sidebar.default_interval;
                poll ()))
  in
  poll ()
