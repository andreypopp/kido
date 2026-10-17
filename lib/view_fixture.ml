let test_at = 1_700_000_000.
let temp () = Filename.temp_dir "kido-ui" ""

let pane ?ssh ?(session = "sess") ?(window = "@1") ?(command = "") ?(title = "") ?(pid = 0) ?run
    ?dead_at ?(alternate = false) ?(running = false) ?start ?prompt ?exit ?(command_line = "")
    ?(active = false) pane_id : State.pane =
  {
    (Test_fixture.pane ~session ~created:0. ~window ~cmd:command ~title ~pid ?run ~active
       ~attached:active ~running ?start ?prompt pane_id)
    with
    alternate_on = alternate;
    last_exit = Option.map (fun (code, at) -> { State.code; at }) exit;
    command_line;
    dead_at;
    ssh;
  }

let session ?(ts = test_at) ?(activity = "") pane : Run.pi = Test_fixture.pi ~pane ~ts ~activity ()

let states l =
  List.fold_left
    (fun m (pane, (id, (s : Run.pi))) ->
      let pane = Tmux.pane_id_of_string pane in
      Tmux.Pane_map.add pane (Test_fixture.run_id id, { s with pane = Some pane }) m)
    Tmux.Pane_map.empty l

let meta ?(kind = Run.Agent) ?(parent = "") id name : Run.meta =
  {
    id;
    name;
    kind;
    parent = Test_fixture.owned parent;
    pane = None;
    pid = 0;
    cwd = "";
    model = "";
    tools = [];
    started_at = test_at;
  }

let state l panes : State.t =
  let agents = states l in
  {
    panes =
      List.map
        (fun (p : State.pane) ->
          match Tmux.Pane_map.find_opt p.pane_id agents with
          | Some (id, _) ->
              {
                p with
                run = Some (Option.value p.run ~default:(Run.string_of_id id));
                program_status =
                  (if List.is_empty p.program_status.records then
                     Result.get_exn
                       (Tmux.Program_status.parse
                          {|{"serial":1,"records":[{"id":"","app":"pi","state":"working"}]}|})
                   else p.program_status);
              }
          | None -> p)
        panes;
    runs = Tmux.Pane_map.map (fun (id, pi) -> { Run.meta = meta id ""; pi = Some pi }) agents;
    agents;
  }

let new_run ~dir ?(parent = "") ?(kind = Run.Agent) ?result name =
  let id = Run.new_id () in
  Run.create ~dir id "task";
  Run.write_meta ~dir (meta ~kind ~parent id name);
  Option.iter
    (fun result -> ignore (Run.record_outcome ~dir id { result; text = ""; at = None }))
    result;
  Run.string_of_id id

let ssh_pane ?command_line prompt start running status =
  pane ~ssh:("deploy", "build-box") ~session:"alpha" ~command:"ssh" ~pid:4242 ~prompt ~start
    ~running
    ?exit:(if (not running) && status >= 0 then Some (status, start +. 1.) else None)
    ?command_line "%1"

let client session =
  Some
    {
      Tmux.name = "/dev/ttys000";
      session;
      session_id = Tmux.session_id_of_string "$0";
      focused = false;
      control = false;
    }
