include State_fixture
include Test_support

let run_id s = Result.get_exn (Run.parse_id s)
let owned s = if String.is_empty s then None else Some (run_id s)

let run ~dir ?(name = "") ?(parent = "") ?pane ?(pid = 0) ?(cwd = "") ?(started_at = 1_700_000_000.)
    ?command id =
  let id = run_id id in
  Option.iter (Run.write_command ~dir id) command;
  let meta : Run.meta =
    {
      id;
      name;
      parent = Option.map (fun id -> Run.Run id) (owned parent);
      pane = Option.map Tmux.pane_id_of_string pane;
      pid;
      cwd;
      started_at;
    }
  in
  Run.write_meta ~dir meta;
  meta
