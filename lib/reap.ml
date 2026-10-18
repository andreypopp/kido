type close = Window of Tmux.window_id | Pane of { window : Tmux.window_id; pane : Tmux.pane_id }

let release tmux = function
  | Window w -> Tmux.run tmux [ "kill-window"; "-t"; Tmux.string_of_window_id w ]
  | Pane { pane; _ } -> Tmux.run tmux [ "kill-pane"; "-t"; Tmux.string_of_pane_id pane ]

let close_of state window pane =
  if not (State.last_pane state window) then Some (Pane { window; pane })
  else if State.last_window state window then None
  else Some (Window window)

let decide state window_id =
  if State.window_focused state window_id then None
  else
    match State.find_window_run state window_id with
    | None -> None
    | Some { dead_at = None; _ } -> None
    | Some run -> close_of state window_id run.pane_id

let sweep tmux ~dir ~grace ({ panes; runs; _ } as state : State.t) ~now =
  let mark ((closing, endings) as acc) (p : State.pane) (m : Run.meta) outcome =
    let window = p.window_id in
    let closes = function Window w | Pane { window = w; _ } -> Tmux.equal_window_id w window in
    match close_of state window p.pane_id with
    | Some close when not (State.window_focused state window || List.exists closes closing) ->
        ignore (Run.save_screen tmux ~dir m.id (Some p.pane_id));
        let ending = Run_ending.record_ending ~dir m outcome in
        (closing @ [ close ], endings @ Option.to_list ending)
    | _ -> acc
  in
  List.fold_left
    (fun acc (p : State.pane) ->
      match Tmux.Pane_map.find_opt p.pane_id runs with
      | Some { meta = m; _ } when Option.equal Tmux.equal_pane_id m.pane (Some p.pane_id) -> (
          match p.dead_at with
          | Some dead when Float.(now -. dead >= grace) -> (
              match State.run_ending ~dir state m with
              | Some outcome -> mark acc p m { outcome with at = Some now }
              | None -> acc)
          | Some _ -> acc
          | None ->
              if Option.is_some (Option.bind m.parent (State.parent_ended ~dir state)) then
                mark acc p m { result = Failed; text = "its parent ended"; at = Some now }
              else acc)
      | _ -> acc)
    ([], []) panes

let collect tmux ~dir ~grace state ~now =
  let closing, endings = sweep tmux ~dir ~grace state ~now in
  List.iter (fun c -> ignore (release tmux c)) closing;
  List.iter (fun e -> ignore (Run_ending.send ~dir e)) endings

let%test_module "Tests" =
  (module struct
    open Test_fixture

    let now = 1_700_000_000.

    let pane ?run ?dead ?dead_status ?dead_signal ?(watched = false) pane_id window_id : State.pane
        =
      {
        (Test_fixture.pane ~session:"s" ~created:0. ~window:window_id ~active:watched
           ~attached:watched ?run ?dead_status ?dead_signal pane_id)
        with
        dead_at = Option.map (fun secs -> now -. Float.of_int secs) dead;
      }

    let meta ?(kind = Run.Agent) ?parent ?pane id : Run.meta =
      {
        id = run_id id;
        name = "";
        kind;
        parent;
        pane = Option.map Tmux.pane_id_of_string pane;
        pid = 0;
        cwd = "";
        model = "";
        tools = [];
        started_at = 0.;
      }

    let marked (panes : State.pane list) (m : Run.meta) =
      let id = Some (Run.string_of_id m.id) in
      List.find_opt (fun (p : State.pane) -> Option.equal String.equal p.run id) panes

    let state ~dir ~bystander panes metas =
      List.iter (Run.write_meta ~dir) metas;
      let panes =
        panes @ if bystander then [ Test_fixture.pane ~session:"s" ~window:"@99" "%99" ] else []
      in
      let runs =
        List.filter_map
          (fun (m : Run.meta) ->
            let pane =
              match m.pane with
              | Some p -> Some p
              | None -> (
                  match m.kind with
                  | Run.Pi -> Option.map (fun (p : State.pane) -> p.pane_id) (marked panes m)
                  | _ -> None)
            in
            Option.map (fun p -> (p, m)) pane)
          metas
      in
      let runs =
        List.fold_left
          (fun map (p, m) -> Tmux.Pane_map.add p { Run.meta = m; pi = None } map)
          Tmux.Pane_map.empty runs
      in
      { State.panes; runs }

    let show label (closing, endings) =
      Printf.printf "%s closes=%d\n" label (List.length closing);
      List.iter
        (fun (e : Run_ending.ending) ->
          Printf.printf "  %s %s %S\n" (Run.string_of_id e.meta.id)
            (Run.string_of_result e.outcome.result)
            e.outcome.text)
        endings

    let sweep_panes ?(metas = []) ?(bystander = true) ~dir panes =
      let state = state ~dir ~bystander panes metas in
      sweep (Tmux.create ()) ~dir ~grace:1. state ~now

    let%expect_test "decide: closes, or none" =
      let show w panes =
        match
          let runs =
            List.fold_left
              (fun m (p : State.pane) ->
                match p.run with
                | Some id ->
                    Tmux.Pane_map.add p.pane_id
                      { Run.meta = View_fixture.meta (Test_fixture.run_id id) ""; pi = None }
                      m
                | None -> m)
              Tmux.Pane_map.empty panes
          in
          decide { panes; runs } (Tmux.window_id_of_string w)
        with
        | Some (Window w) -> Printf.printf "close %s\n" (Tmux.string_of_window_id w)
        | Some (Pane { window; pane }) ->
            Printf.printf "close %s pane %s\n" (Tmux.string_of_window_id window)
              (Tmux.string_of_pane_id pane)
        | None -> print_endline "none"
      in
      let focused = pane ~watched:true "%1" "@1" in
      show "@2" [ focused; pane ~run:"run-x" ~dead:1 "%2" "@2"; pane "%3" "@2" ];
      show "@2" [ focused; pane ~run:"run-x" ~dead:1 "%2" "@2" ];
      show "@2" [ focused; pane ~run:"run-x" "%2" "@2"; pane ~dead:1 "%3" "@2" ];
      show "@2" [ pane "%1" "@1"; pane ~run:"run-x" "%2" "@2"; pane "%3" "@2" ];
      show "@2" [ pane "%1" "@1"; pane ~dead:1 "%2" "@2" ];
      show "@1" [ pane ~run:"run-x" ~dead:1 "%1" "@1" ];
      show "@1" [ pane ~run:"run-x" ~dead:1 "%1" "@1"; pane "%2" "@1" ];
      show "@2"
        [ focused; pane ~run:"run-x" ~dead:1 "%2" "@2"; pane ~run:"run-y" ~dead:1 "%3" "@2" ];
      [%expect
        {|
    close @2 pane %2
    close @2
    none
    none
    none
    none
    close @1 pane %1
    close @2 pane %2
    |}]

    let%expect_test "rule 1: a dead pane's ending, once it has outlived the grace" =
      let dir = Filename.temp_dir "kido-reap" "" in
      let show label dead_at (p : State.pane) =
        let id = "run-" ^ label in
        let p = { p with dead_at = Some dead_at; run = Some id } in
        show label (sweep_panes ~metas:[ meta ~pane:"%1" id ] ~dir [ p ])
      in
      show "young" (now -. 0.5) (pane ~dead_status:3 "%1" "@1");
      show "exit3" (now -. 2.) (pane ~dead_status:3 "%1" "@1");
      show "zero" (now -. 2.) (pane ~dead_status:0 "%1" "@1");
      show "signal" (now -. 2.) (pane ~dead_signal:"TERM" "%1" "@1");
      show "bare" (now -. 2.) (pane "%1" "@1");
      [%expect
        {|
        young closes=0
        exit3 closes=1
          run-exit3 failed "exit 3"
        zero closes=1
          run-zero completed ""
        signal closes=1
          run-signal failed "signal TERM"
        bare closes=1
          run-bare died ""
        |}]

    let%expect_test "rule 2: the orphan rule over run status and the pane options" =
      let dir = Filename.temp_dir "kido-reap" "" in
      let live_parent =
        { (pane ~run:"parent" "%9" "@9") with program_status = State_fixture.root }
      in
      let dead_parent = { live_parent with dead_at = Some now } in
      let no_root = { live_parent with program_status = Tmux.Program_status.empty } in
      let ended_parent = meta ~pane:"%9" "parent" in
      let run_outcome () =
        ignore
          (Run.record_outcome ~dir (run_id "parent") { result = Completed; text = ""; at = None })
      in
      let child label parent panes metas =
        let id = "child-" ^ label in
        show label
          (sweep_panes ~dir
             ~metas:(meta ?parent ~pane:"%1" id :: metas)
             (pane ~run:id "%1" "@1" :: panes))
      in
      child "parentless" None [] [];
      child "run alive" (Some (Run (run_id "parent"))) [ live_parent ] [ ended_parent ];
      child "run ended" (Some (Run (run_id "parent"))) [] [];
      child "pane parent alive" (Some (Pane (Tmux.pane_id_of_string "%9"))) [ live_parent ] [];
      child "pane parent dead" (Some (Pane (Tmux.pane_id_of_string "%9"))) [ dead_parent ] [];
      child "pane parent no pi root" (Some (Pane (Tmux.pane_id_of_string "%9"))) [ no_root ] [];
      child "pane parent gone" (Some (Pane (Tmux.pane_id_of_string "%8"))) [] [];
      run_outcome ();
      child "run parent completed" (Some (Run (run_id "parent"))) [ live_parent ] [ ended_parent ];
      [%expect
        {|
        parentless closes=0
        run alive closes=0
        run ended closes=1
          child-run ended failed "its parent ended"
        pane parent alive closes=0
        pane parent dead closes=1
          child-pane parent dead failed "its parent ended"
        pane parent no pi root closes=1
          child-pane parent no pi root failed "its parent ended"
        pane parent gone closes=1
          child-pane parent gone failed "its parent ended"
        run parent completed closes=1
          child-run parent completed failed "its parent ended"
        |}]

    let%expect_test "the sweep never closes the client's window or a session's last window" =
      let dir = Filename.temp_dir "kido-reap" "" in
      let metas = [ meta ~pane:"%1" "run-a" ] in
      show "focused" (sweep_panes ~dir ~metas [ pane ~run:"run-a" ~dead:2 ~watched:true "%1" "@1" ]);
      show "last" (sweep_panes ~dir ~bystander:false ~metas [ pane ~run:"run-a" ~dead:2 "%1" "@1" ]);
      [%expect {|
    focused closes=0
    last closes=0
    |}]
  end)
