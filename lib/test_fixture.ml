include Tmux_pane_fixture
include Test_support

let pi ?(pane = "%1") ?(pid = Unix.getpid ()) ?(ts = 1_700_000_000.) ?(inbox = "") ?(activity = "")
    () : Run.pi =
  {
    pid;
    pane = (if String.is_empty pane then None else Some (Tmux.pane_id_of_string pane));
    ts;
    inbox;
    activity;
    model = "";
    name = "";
    session_file = "";
  }

let run_id s = Result.get_exn (Run.parse_id s)
let owned s = if String.is_empty s then None else Some (run_id s)

let holding ~dir ~inbox id =
  Result.get_exn (Run.write_pi ~dir (run_id id) ~holder:(Unix.getpid ()) (pi ~pane:"%2" ~inbox ()))

let run ~dir ?(name = "") ?(kind = Run.Agent) ?(parent = "") ?pane ?(pid = 0) ?(cwd = "")
    ?(started_at = 1_700_000_000.) ?command id =
  let id = run_id id in
  Run.create ~dir id "do the thing";
  Option.iter (Run.write_command ~dir id) command;
  let meta : Run.meta =
    {
      id;
      name;
      kind;
      parent = owned parent;
      pane = Option.map Tmux.pane_id_of_string pane;
      pid;
      cwd;
      model = "";
      tools = [];
      keep_alive = false;
      started_at;
    }
  in
  Run.write_meta ~dir meta;
  meta
