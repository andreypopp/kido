let max_name_len = 64

let check_name name =
  let open Result.Infix in
  let* () = Tmux.safe "window name" name in
  if String.length name > max_name_len then
    Error
      (Printf.sprintf "refusing window name %S: %d bytes is over the %d byte limit" name
         (String.length name) max_name_len)
  else Ok ()

type created = { meta : Run.meta; window : Tmux.window_id; pane : Tmux.pane_id; output : string }
type error = Refused_name of string | Failed of string

let create ?(env = []) ~dir (meta : Run.meta) ~session command =
  let id = Run.string_of_id meta.id in
  let env =
    [
      "KIDO_AGENT_TASK_FILE=" ^ Run.task_path ~dir meta.id;
      "KIDO_AGENT_RUN_ID=" ^ id;
      "KIDO_RUN_ID=" ^ id;
      "KIDO_RUN_OUTPUT=" ^ Run.output_path ~dir meta.id;
    ]
    @ (match meta.parent with
      | Some (Run.Run p) -> [ "KIDO_AGENT_PARENT_SESSION=" ^ Run.string_of_id p ]
      | Some (Run.Pane _) | None -> [])
    @ env
  in
  let tmux = Tmux.create () in
  let open Result.Infix in
  let fail e =
    ignore
      (Run.record_outcome ~dir meta.id { result = Failed; text = e; at = Some (Timestamp.now ()) });
    Error e
  in
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
  Ok { meta; window = w.window_id; pane = w.pane_id; output = Run.output_path ~dir meta.id }

let start ?parent ~kind ~dir ~name ~cwd ~session ~env command =
  let open Result.Infix in
  let* () = check_name name |> Result.map_err (fun e -> Refused_name e) in
  let id = Run.new_id () in
  let meta : Run.meta =
    {
      id;
      name;
      kind;
      parent;
      pane = None;
      pid = 0;
      cwd;
      model = "";
      tools = [];
      started_at = Timestamp.now ();
    }
  in
  Run.write_meta ~dir meta;
  Run.write_command ~dir id command;
  create ~env ~dir meta ~session command |> Result.map_err (fun e -> Failed e)

let resolve_parent ~dir ~state = function
  | "" -> Ok None
  | s -> (
      match Run.parse_parent s with
      | Error e -> Error e
      | Ok parent -> (
          match State.parent_ended ~dir state parent with
          | Some why -> Error why
          | None -> Ok (Some parent)))
