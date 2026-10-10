include Tmux_pane_fixture
include Test_support

let session ?(agent = State.Pi) ?(pane = "%1") ?(pid = Unix.getpid ()) ?(ts = 1_700_000_000.)
    ?(inbox = "") ?(activity = "") ?parent ?(depth = 0) () : State.session =
  {
    agent;
    name = "";
    pane = Tmux.Pane.of_string pane;
    pid;
    ts;
    inbox;
    activity;
    parent = Option.map (fun session : State.parent -> { session; pid = 0 }) parent;
    depth;
    model = "";
  }

let run ~dir ?(name = "") ?(kind = Subrun.Agent) ?(parent = "") ?(pane = "") ?(pid = 0) ?(cwd = "")
    ?(started_at = 1_700_000_000.) ?command id =
  let id = Result.get_exn (Subrun.parse_id id) in
  Subrun.create ~dir id "do the thing";
  Option.iter (Subrun.write_command ~dir id) command;
  let meta : Subrun.meta =
    {
      id;
      name;
      kind;
      parent_session = parent;
      depth = 1;
      pane = Tmux.Pane.of_string pane;
      pid;
      cwd;
      model = "";
      tools = [];
      keep_alive = false;
      started_at;
    }
  in
  Subrun.write_meta ~dir meta;
  meta
