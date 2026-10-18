let test_at = 1_700_000_000.
let temp () = Filename.temp_dir "kido-ui" ""

let pane ?ssh ?(session = "sess") ?(window = "@1") ?(command = "") ?(title = "") ?(pid = 0) ?run
    ?dead_at ?dead_status ?dead_signal ?(alternate = false) ?(running = false) ?start ?prompt ?exit
    ?(command_line = "") ?(active = false) ?kido_session ?kido_name ?kido_inbox ?kido_activity
    pane_id : State.pane =
  {
    (Test_fixture.pane ~session ~created:0. ~window ~cmd:command ~title ~pid ?run ?dead_status
       ?dead_signal ~active ~attached:active ~running ?start ?prompt ?kido_session ?kido_name
       ?kido_inbox ?kido_activity pane_id)
    with
    alternate_on = alternate;
    last_exit = Option.map (fun (code, at) -> { State.code; at }) exit;
    command_line;
    dead_at;
    ssh;
  }

type fake_agent = { activity : string }

let session ?(activity = "") () : fake_agent = { activity }

let states l =
  List.fold_left
    (fun m (pane, (id, (s : fake_agent))) ->
      let pane = Tmux.pane_id_of_string pane in
      Tmux.Pane_map.add pane (Test_fixture.run_id id, s) m)
    Tmux.Pane_map.empty l

let meta ?(parent = "") id name : Run.meta =
  {
    id;
    name;
    parent = Option.map (fun id -> Run.Run id) (Test_fixture.owned parent);
    pane = None;
    pid = 0;
    cwd = "";
    started_at = test_at;
  }

let state l panes : State.t =
  let agents = states l in
  {
    panes =
      List.map
        (fun (p : State.pane) ->
          match Tmux.Pane_map.find_opt p.pane_id agents with
          | Some (id, (s : fake_agent)) ->
              {
                p with
                run = Some (Option.value p.run ~default:(Run.string_of_id id));
                session = Some (Run.string_of_id id);
                activity = (if String.is_empty s.activity then p.activity else Some s.activity);
                program_status =
                  (if List.is_empty p.program_status.records then
                     Result.get_exn
                       (Tmux.Program_status.parse
                          {|{"serial":1,"records":[{"id":"","app":"pi","state":"working"}]}|})
                   else p.program_status);
              }
          | None -> p)
        panes;
    runs = Tmux.Pane_map.map (fun (id, _) -> meta id "") agents;
  }

let new_run ?id ~dir ?(parent = "") ?result name =
  let id = match id with Some id -> Test_fixture.run_id id | None -> Run.new_id () in
  Run.write_meta ~dir (meta ~parent id name);
  Option.iter
    (fun result -> ignore (Run.record_outcome ~dir id { result; text = ""; at = None }))
    result;
  Run.string_of_id id

let client session =
  Some
    {
      Tmux.name = "/dev/ttys000";
      session;
      session_id = Tmux.session_id_of_string "$0";
      focused = false;
      control = false;
    }
