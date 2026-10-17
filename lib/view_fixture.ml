let test_at = 1_700_000_000.
let temp () = Filename.temp_dir "kido-ui" ""

let pane ?ssh ?(session = "sess") ?(window = "@1") ?(command = "") ?(title = "") ?(pid = 0) ?run
    ?dead_at ?(alternate = false) ?(running = false) ?start ?prompt ?exit ?(command_line = "")
    ?(active = false) pane_id : Tmux_pane.t =
  {
    (Test_fixture.pane ~session ~created:0. ~window ~cmd:command ~title ~pid ?run ~active
       ~attached:active ~running ?start ?prompt pane_id)
    with
    alternate_on = alternate;
    last_exit = Option.map (fun (code, at) -> { Tmux_pane.code; at }) exit;
    command_line;
    dead_at;
    ssh;
  }

let session ?(ts = test_at) ?(activity = "") pane : Run.pi = Test_fixture.pi ~pane ~ts ~activity ()

let states l =
  List.fold_left
    (fun m (pane, (id, (s : Run.pi))) ->
      let pane = Tmux.pane_id_of_string pane in
      Tmux.Pane_map.add pane (id, { s with pane = Some pane }) m)
    Tmux.Pane_map.empty l

let with_programs states panes =
  List.map
    (fun (p : Tmux_pane.t) ->
      match Tmux.Pane_map.find_opt p.pane_id states with
      | Some (id, _) ->
          {
            p with
            run = Some (Option.value p.run ~default:id);
            program_status =
              Result.get_exn
                (Tmux.Program_status.parse
                   {|{"serial":1,"records":[{"id":"","app":"pi","state":"working"}]}|});
          }
      | None -> p)
    panes

let new_run ~dir ?(parent = "") ?(kind = Run.Agent) ?result name =
  let id = Run.new_id () in
  Run.create ~dir id "task";
  Run.write_meta ~dir
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
      keep_alive = false;
      started_at = test_at;
    };
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
  Some { Tmux_pane.session; session_id = Tmux.session_id_of_string "$0"; focused = false }
