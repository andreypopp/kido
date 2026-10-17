type close = Window of Tmux.window_id | Pane of { window : Tmux.window_id; pane : Tmux.pane_id }

let release tmux = function
  | Window w -> Tmux.run tmux [ "kill-window"; "-t"; Tmux.string_of_window_id w ]
  | Pane { pane; _ } -> Tmux.run tmux [ "kill-pane"; "-t"; Tmux.string_of_pane_id pane ]

let close_of state window pane =
  if not (State.last_pane state window) then Some (Pane { window; pane })
  else if State.last_window state window then None
  else Some (Window window)

let decide state window_id =
  if State.window_focused state window_id then
    Error
      (Printf.sprintf "%s is a client's current window; leaving it for the user to read"
         (Tmux.string_of_window_id window_id))
  else
    match State.find_window_run state window_id with
    | None ->
        Error (Printf.sprintf "%s has no run pane; leaving it" (Tmux.string_of_window_id window_id))
    | Some { dead_at = None; _ } ->
        Error
          (Printf.sprintf "%s's run is still going; leaving it"
             (Tmux.string_of_window_id window_id))
    | Some run ->
        Option.to_result
          (Printf.sprintf "%s is its session's only window; closing it would destroy the session"
             (Tmux.string_of_window_id window_id))
          (close_of state window_id run.pane_id)

let sweep tmux ~dir ~grace ({ panes; runs; agents } as state : State.t) ~now =
  let live p =
    Tmux.Pane_map.exists (fun _ (id, _) -> Run.equal_id id p) agents
    || Option.is_some (Run.live_pi ~dir p)
  in
  let mark ((closing, endings) as acc) (p : State.pane) (m : Run.meta) text =
    let window = p.window_id in
    let closes = function Window w | Pane { window = w; _ } -> Tmux.equal_window_id w window in
    match close_of state window p.pane_id with
    | Some close when not (State.window_focused state window || List.exists closes closing) ->
        ignore (Run.save_screen tmux ~dir m.id (Some p.pane_id));
        let ending =
          Run_ending.record_ending ~dir m
            (match m.kind with
            | Bash | Stream -> { result = Failed; text; at = Some now }
            | Pi | Agent -> { result = Died; text = ""; at = Some now })
        in
        (closing @ [ close ], endings @ Option.to_list ending)
    | _ -> acc
  in
  List.fold_left
    (fun acc (p : State.pane) ->
      match Tmux.Pane_map.find_opt p.pane_id runs with
      | Some { meta = { kind = Agent | Bash | Stream; pane = Some pane; _ } as m; _ }
        when Tmux.equal_pane_id pane p.pane_id ->
          if Option.exists (fun d -> Float.(now - d >= grace)) p.dead_at then
            mark acc p m "ended without its wrapper reporting"
          else if Option.exists (Fun.negate live) m.parent then mark acc p m "its parent ended"
          else acc
      | _ -> acc)
    ([], []) panes

let collect tmux ~dir ~grace state ~now =
  let closing, endings = sweep tmux ~dir ~grace state ~now in
  List.iter (fun c -> ignore (release tmux c)) closing;
  List.iter (fun e -> ignore (Run_ending.send ~dir e)) endings

let%test_module "Tests" =
  (module struct
    let now = 1_700_000_000.

    let pane ?run ?dead ?(watched = false) pane_id window_id : State.pane =
      {
        (Test_fixture.pane ~session:"s" ~created:0. ~window:window_id ~active:watched
           ~attached:watched ?run pane_id)
        with
        dead_at = Option.map (fun secs -> now -. Float.of_int secs) dead;
      }

    let%expect_test "decide: close-run's refusals and closes" =
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
          decide { panes; runs; agents = Tmux.Pane_map.empty } (Tmux.window_id_of_string w)
        with
        | Ok (Window w) -> Printf.printf "close %s\n" (Tmux.string_of_window_id w)
        | Ok (Pane { window; pane }) ->
            Printf.printf "close %s pane %s\n" (Tmux.string_of_window_id window)
              (Tmux.string_of_pane_id pane)
        | Error why -> print_endline why
      in
      let focused = pane ~watched:true "%1" "@1" in
      show "@2" [ focused; pane ~run:"run-x" ~dead:1 "%2" "@2"; pane "%3" "@2" ];
      show "@2" [ focused; pane ~run:"run-x" ~dead:1 "%2" "@2" ];
      show "@2" [ focused; pane ~run:"run-x" "%2" "@2"; pane ~dead:1 "%3" "@2" ];
      show "@2"
        [ pane "%1" "@1"; pane ~run:"run-x" ~dead:1 "%2" "@2"; pane ~watched:true "%3" "@2" ];
      show "@1" [ pane ~run:"run-x" ~dead:1 "%1" "@1"; pane "%2" "@1" ];
      show "@1" [ focused; pane "%2" "@2" ];
      show "@2" [ focused; pane ~dead:1 "%2" "@2" ];
      show "@1" [ pane ~run:"run-x" ~dead:1 "%1" "@1" ];
      show "@2"
        [ focused; pane ~run:"run-x" ~dead:1 "%2" "@2"; pane ~run:"run-y" ~dead:1 "%3" "@2" ];
      [%expect
        {|
    close @2 pane %2
    close @2
    @2's run is still going; leaving it
    @2 is a client's current window; leaving it for the user to read
    close @1 pane %1
    @1 is a client's current window; leaving it for the user to read
    @2 has no run pane; leaving it
    @1 is its session's only window; closing it would destroy the session
    close @2 pane %2
    |}]
  end)
