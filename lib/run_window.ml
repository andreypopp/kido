type created = { meta : Run.meta; window : Tmux.window_id; pane : Tmux.pane_id }
type error = Refused_name of string | Failed of string

let start ?parent ~dir ~name ~cwd ~session ~env command =
  let open Result.Infix in
  let check () =
    let* () = Tmux.safe "window name" name in
    if String.length name > 64 then
      Error
        (Printf.sprintf "refusing window name %S: %d bytes is over the 64 byte limit" name
           (String.length name))
    else Ok ()
  in
  let* () = check () |> Result.map_err (fun e -> Refused_name e) in
  let id = Run.new_id () in
  let meta : Run.meta =
    { id; name; parent; pane = None; pid = 0; cwd; started_at = Timestamp.now () }
  in
  Run.write_meta ~dir meta;
  Run.write_command ~dir id command;
  let id_text = Run.string_of_id id in
  let env = [ "KIDO_RUN_ID=" ^ id_text; "KIDO_RUN_OUTPUT=" ^ Run.output_path ~dir id ] @ env in
  let tmux = Tmux.create () in
  let fail e =
    ignore (Run.record_outcome ~dir id { result = Failed; text = e; at = Some (Timestamp.now ()) });
    Error (Failed e)
  in
  let* w =
    match
      Tmux.new_window tmux
        ~setup:(id_text, [ (Tmux_vars.run, id_text); ("remain-on-exit", "on") ])
        ~session ~name ~cwd ~env command
    with
    | Ok w -> Ok w
    | Error e -> fail e
  in
  let meta = { meta with pane = Some w.pane_id; pid = w.pane_pid } in
  Run.write_meta ~dir meta;
  Ok { meta; window = w.window_id; pane = w.pane_id }

let resolve_parent ~dir ~state = function
  | "" -> Ok None
  | s -> (
      match Run.parse_parent s with
      | Error e -> Error e
      | Ok parent -> (
          match State.parent_ended ~dir state parent with
          | Some why -> Error why
          | None -> Ok (Some parent)))
