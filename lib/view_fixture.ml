let test_at = 1_700_000_000.
let temp () = Filename.temp_dir "kido-ui" ""

let pane ?ssh ?(session = "sess") ?(window = "@1") ?(command = "") ?(title = "") ?(pid = 0) ?run
    ?dead_at ?(alternate = false) ?(running = false) ?start ?prompt ?exit ?(command_line = "")
    ?(active = false) pane_id : Tmux.Pane.t =
  {
    (Tmux.Fixture.pane ~session ~created:0. ~window ~cmd:command ~title ~pid ?run ~active
       ~attached:active ~running ?start ?prompt pane_id)
    with
    alternate_on = alternate;
    last_exit = Option.map (fun (code, at) -> { Tmux.Pane.code; at }) exit;
    command_line;
    dead_at;
    ssh;
  }

let session ?(agent = State.Pi) ?(parent = "") ?(depth = 0) ?(ts = test_at) ?(activity = "") pane :
    State.session =
  Test_fixture.session ~agent ~pane ~ts ~activity
    ?parent:(if String.is_empty parent then None else Some parent)
    ~depth ()

let states l =
  List.fold_left
    (fun m (pane, (id, s)) ->
      let pane = Option.get_exn_or "id" (Tmux.Pane.of_string pane) in
      Tmux.Pane.Map.add pane (id, { s with State.pane = Some pane }) m)
    Tmux.Pane.Map.empty l

let with_programs states panes =
  List.map
    (fun (p : Tmux.Pane.t) ->
      if Tmux.Pane.Map.mem p.pane_id states then
        {
          p with
          program_status =
            Result.get_exn
              (Tmux.Program_status.parse
                 {|{"serial":1,"records":[{"id":"","app":"pi","state":"working"}]}|});
        }
      else p)
    panes

let new_run ~dir ?(parent = "") ?(kind = Subrun.Agent) ?result name =
  let id = Subrun.new_id () in
  Subrun.create ~dir id "task";
  Subrun.write_meta ~dir
    {
      id;
      name;
      kind;
      parent_session = parent;
      depth = 0;
      pane = None;
      pid = 0;
      cwd = "";
      model = "";
      tools = [];
      keep_alive = false;
      started_at = test_at;
    };
  Option.iter
    (fun result -> ignore (Subrun.record_outcome ~dir id { result; text = ""; at = None }))
    result;
  Subrun.string_of_id id

let ssh_pane ?command_line prompt start running status =
  pane ~ssh:("deploy", "build-box") ~session:"alpha" ~command:"ssh" ~pid:4242 ~prompt ~start
    ~running
    ?exit:(if (not running) && status >= 0 then Some (status, start +. 1.) else None)
    ?command_line "%1"

let client session =
  Some
    {
      Tmux.Exec.session;
      session_id = Option.get_exn_or "id" (Tmux.Session.of_string "$0");
      focused = false;
    }
