type close = Window of Tmux.window_id | Pane of { window : Tmux.window_id; pane : Tmux.pane_id }

let release tmux = function
  | Window w -> Tmux.run tmux [ "kill-window"; "-t"; Tmux.string_of_window_id w ]
  | Pane { pane; _ } -> Tmux.run tmux [ "kill-pane"; "-t"; Tmux.string_of_pane_id pane ]

let close_of state window pane =
  if not (State.last_pane state window) then Some (Pane { window; pane })
  else if State.last_window state window then None
  else Some (Window window)

let sweep tmux ~dir ~grace ({ panes; runs; _ } as state : State.t) ~now =
  let mark closing (p : State.pane) (m : Run.meta) outcome =
    let window = p.window_id in
    let closes = function Window w | Pane { window = w; _ } -> Tmux.equal_window_id w window in
    match close_of state window p.pane_id with
    | Some close when not (State.window_focused state window || List.exists closes closing) ->
        ignore (Run.save_screen tmux ~dir m.id (Some p.pane_id));
        ignore (Run.record_outcome ~dir m.id outcome);
        closing @ [ close ]
    | _ -> closing
  in
  List.fold_left
    (fun closing (p : State.pane) ->
      match Tmux.Pane_map.find_opt p.pane_id runs with
      | Some m when Option.equal Tmux.equal_pane_id m.pane (Some p.pane_id) -> (
          match p.dead_at with
          | Some dead when Float.(now -. dead >= grace) -> (
              match State.run_ending ~dir state m with
              | Some outcome -> mark closing p m { outcome with at = Some now }
              | None -> closing)
          | Some _ -> closing
          | None ->
              if Option.is_some (Option.bind m.parent (State.parent_ended ~dir state)) then
                mark closing p m { result = Failed; text = "its parent ended"; at = Some now }
              else closing)
      | _ -> closing)
    [] panes

let collect tmux ~dir ~grace state ~now =
  List.iter (fun c -> ignore (release tmux c)) (sweep tmux ~dir ~grace state ~now)

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

    let meta ~dir ?parent ?pane id : Run.meta =
      let m = Test_fixture.run ~dir ?pane id in
      { m with parent }

    let state ~dir ~bystander panes metas =
      List.iter (Run.write_meta ~dir) metas;
      let panes =
        panes @ if bystander then [ Test_fixture.pane ~session:"s" ~window:"@99" "%99" ] else []
      in
      let runs =
        List.fold_left
          (fun map (m : Run.meta) ->
            match m.pane with Some p -> Tmux.Pane_map.add p m map | None -> map)
          Tmux.Pane_map.empty metas
      in
      { State.panes; runs }

    let show label ~dir ids closing =
      Printf.printf "%s closes=%d\n" label (List.length closing);
      List.iter
        (fun id ->
          match Run.read_outcome ~dir (run_id id) with
          | Some o -> Printf.printf "  %s %s %S\n" id (Run.string_of_result o.result) o.text
          | None -> ())
        ids

    let sweep_panes ?(metas = []) ?(bystander = true) ~dir panes =
      let state = state ~dir ~bystander panes metas in
      sweep (Tmux.create ()) ~dir ~grace:1. state ~now

    let%expect_test "rule 1: a dead pane's ending, once it has outlived the grace" =
      let dir = Filename.temp_dir "kido-reap" "" in
      let show label dead_at (p : State.pane) =
        let id = "run-" ^ label in
        let p = { p with dead_at = Some dead_at; run = Some id } in
        let closing = sweep_panes ~metas:[ meta ~dir ~pane:"%1" id ] ~dir [ p ] in
        show label ~dir [ id ] closing
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
      let ended_parent = meta ~dir ~pane:"%9" "parent" in
      let run_outcome () =
        ignore
          (Run.record_outcome ~dir (run_id "parent") { result = Completed; text = ""; at = None })
      in
      let child label parent panes metas =
        let id = "child-" ^ label in
        let closing =
          sweep_panes ~dir
            ~metas:(meta ~dir ?parent ~pane:"%1" id :: metas)
            (pane ~run:id "%1" "@1" :: panes)
        in
        show label ~dir [ id ] closing
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
      let metas = [ meta ~dir ~pane:"%1" "run-a" ] in
      show "focused" ~dir [ "run-a" ]
        (sweep_panes ~dir ~metas [ pane ~run:"run-a" ~dead:2 ~watched:true "%1" "@1" ]);
      show "last" ~dir [ "run-a" ]
        (sweep_panes ~dir ~bystander:false ~metas [ pane ~run:"run-a" ~dead:2 "%1" "@1" ]);
      [%expect {|
    focused closes=0
    last closes=0
    |}]
  end)
