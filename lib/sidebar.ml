module String_map = Map.Make (String)

module Run_map = Map.Make (struct
  type t = Run.id

  let compare = Run.compare_id
end)

type options = { interval : float; client : string; tmux : Tmux.t; dir : string; grace : float }

let default_interval = 0.1

type lingering = {
  name : string;
  parent : Run.id option;
  outcome : Run.result option;
  kind : Run.kind;
  started : Timestamp.t;
}

type snapshot = {
  server : (int * Tmux.server) option;
  client : Tmux.client option;
  state : State.t;
  visible : State.t;
  err : string option;
  lingering : lingering String_map.t;
}

let empty =
  {
    server = None;
    client = None;
    state = State.empty;
    visible = State.empty;
    err = None;
    lingering = String_map.empty;
  }

let active snap =
  if Option.is_some snap.err then None
  else
    Option.flat_map (fun (c : Tmux.client) -> State.active_pane snap.visible c.session) snap.client

let lingering_subagents ~dir runs =
  Tmux.Pane_map.fold
    (fun _ (r : Run.t) ->
      String_map.add (Run.string_of_id r.meta.id)
        {
          name = Run.name r;
          parent = r.meta.parent;
          outcome = Option.map (fun (o : Run.outcome) -> o.result) (Run.read_outcome ~dir r.meta.id);
          kind = r.meta.kind;
          started = r.meta.started_at;
        })
    runs String_map.empty

let take ~opts conn prev client =
  Option.iter (fun (c : Tmux.client) -> Tmux.Client.follow conn c.session_id) client;
  let tmux = Tmux.Client.tmux conn in
  let read =
    let open Result.Infix in
    let* server =
      match prev.server with
      | Some (dial, _) when Int.equal dial (Tmux.Client.dials conn) -> Ok prev.server
      | _ -> Result.map (fun s -> Some (Tmux.Client.dials conn, s)) (Tmux.server tmux)
    in
    Result.map (fun state -> (server, state)) (State.read ~dir:opts.dir tmux)
  in
  match read with
  | Error e -> { prev with client; err = Some e }
  | Ok (server, state) ->
      if not (List.is_empty state.panes) then
        Reap.collect opts.tmux ~dir:opts.dir ~grace:opts.grace state ~now:(Unix.gettimeofday ());
      let visible =
        { state with panes = List.filter (fun (p : State.pane) -> not p.modal) state.panes }
      in
      {
        server;
        client;
        state;
        visible;
        err = None;
        lingering = lingering_subagents ~dir:opts.dir state.runs;
      }

let same a b =
  let drawn (p : State.pane) =
    {
      p with
      window_index = 0;
      window_layout = "";
      current_path = "";
      active = false;
      pane_active = false;
    }
  in
  let session (_, (s : Run.pi)) = { s with ts = 0. } in
  Option.equal Stdlib.( = ) a.server b.server
  && Option.equal Stdlib.( = ) a.client b.client
  && Option.equal Tmux.equal_pane_id (active a) (active b)
  && Option.is_none a.err && Option.is_none b.err
  && List.equal (fun x y -> Stdlib.( = ) (drawn x) (drawn y)) a.visible.panes b.visible.panes
  && Tmux.Pane_map.equal
       (fun x y -> Stdlib.( = ) (session x) (session y))
       a.state.agents b.state.agents
  && String_map.equal Stdlib.( = ) a.lingering b.lingering

type client = { session : Tmux.session_id; window : Tmux.window_id; pane : Tmux.pane_id }
type run = { kind : Run.kind; started : Timestamp.t }

type lifecycle =
  | Live of { status : Pane_status.kind; run : run option }
  | Ended of { result : Run.result option; run : Run.kind }

type row = { pane : Tmux.pane_id; window : Tmux.window_id; title : string; lifecycle : lifecycle }

type node = Group of { name : string; first : item; rest : item list } | Item of item
and item = { row : row; children : node list }

type section = { id : Tmux.session_id; name : string; current : bool; nodes : node list }
type pane = { pane : State.pane; track : Pane_status.track; status : Pane_status.kind }

type model = {
  opts : options;
  snap : snapshot;
  sessions : section list;
  pane_data : pane Tmux.Pane_map.t;
  client : client option;
  now : unit -> float;
  at : float;
}

let make ~now opts =
  {
    opts;
    snap = empty;
    sessions = [];
    pane_data = Tmux.Pane_map.empty;
    client = None;
    now;
    at = now ();
  }

let track m =
  if Option.is_some m.snap.err then m
  else
    let states = m.snap.state.agents in
    let pane_data =
      List.fold_left
        (fun data (p : State.pane) ->
          if Tmux.Pane_map.mem p.pane_id data then data
          else
            let kind = Pane_kind.classify ~states p in
            let track, status =
              Pane_status.observe ~now:m.at p kind
                (Option.map (fun d -> d.track) (Tmux.Pane_map.find_opt p.pane_id m.pane_data))
            in
            Tmux.Pane_map.add p.pane_id { pane = p; track; status } data)
        Tmux.Pane_map.empty m.snap.visible.panes
    in
    { m with pane_data }

let pi_run lingering (p : State.pane) =
  Option.exists
    (fun run ->
      match String_map.find_opt run lingering with
      | Some ({ kind = Pi; _ } : lingering) -> true
      | _ -> false)
    p.run

let pane_label m (d : pane) =
  let p = d.pane in
  let states = m.snap.state.agents in
  let lingering =
    if pi_run m.snap.lingering p then None
    else Option.flat_map (fun run -> String_map.find_opt run m.snap.lingering) p.run
  in
  let title, lifecycle =
    match lingering with
    | Some l when Option.is_some l.outcome || Option.is_some p.dead_at ->
        ( (match Tmux.Pane_map.find_opt p.pane_id states with
          | Some (_, s) -> State.run_display_name m.snap.state s
          | _ -> l.name),
          Ended { result = l.outcome; run = l.kind } )
    | _ ->
        ( (let kind = Pane_kind.classify ~states p in
           match (kind, lingering) with
           | (Pi_agent _ | Some_agent _ | Ssh { pane = Remote_agent _; _ }), _ ->
               Option.value ~default:"" (Pane_kind.title p kind)
           | (Terminal | Ssh { pane = Remote_terminal; _ }), Some l
             when List.is_empty p.program_status.records ->
               l.name
           | (Terminal | Ssh { pane = Remote_terminal; _ }), _ -> Pane_status.label d.track p),
          Live
            {
              status = d.status;
              run =
                Option.map (fun (l : lingering) -> { kind = l.kind; started = l.started }) lingering;
            } )
  in
  { pane = p.pane_id; window = p.window_id; title; lifecycle }

type placement = { panes : State.pane list; anchor : Tmux.pane_id option }

let order_windows_by_tree windows states lingering =
  let window_id (w : State.pane list) = (List.hd w).window_id in
  let by_session =
    List.fold_left
      (fun acc w ->
        List.fold_left
          (fun acc (p : State.pane) ->
            match Tmux.Pane_map.find_opt p.pane_id states with
            | Some (id, _) -> Run_map.add id (window_id w, p.pane_id) acc
            | _ -> acc)
          acc w)
      Run_map.empty windows
  in
  let parent_of_window (w : State.pane list) =
    List.find_map
      (fun (p : State.pane) ->
        let open Option.Infix in
        let* r = p.run in
        let* l = String_map.find_opt r lingering in
        l.parent)
      w
  in
  let ordered =
    Tree.order
      ~id:(fun (w, _) -> window_id w)
      ~parent:(fun (_, found) -> Option.map fst found)
      (List.map
         (fun w ->
           (w, Option.flat_map (fun id -> Run_map.find_opt id by_session) (parent_of_window w)))
         windows)
  in
  List.fold_left
    (fun (placed, out) (w, found) ->
      let anchor =
        match found with
        | Some (window, pane) when List.mem ~eq:Tmux.equal_window_id window placed -> Some pane
        | _ -> None
      in
      (window_id w :: placed, { panes = w; anchor } :: out))
    ([], []) ordered
  |> snd |> List.rev

let windows_in_order (state : State.t) lingering =
  List.concat_map
    (fun (s : State.session) -> order_windows_by_tree s.windows state.agents lingering)
    (State.order_sessions state)

let window_target ~next ~session ~window ~lingering windows =
  let first w = List.hd w.panes in
  let parent w =
    Option.flat_map
      (fun anchor ->
        List.find_opt
          (fun candidate ->
            Tmux.equal_session_id (first candidate).session_id (first w).session_id
            && List.exists
                 (fun (p : State.pane) -> Tmux.equal_pane_id p.pane_id anchor)
                 candidate.panes)
          windows)
      w.anchor
  in
  match
    List.find_opt
      (fun w ->
        Tmux.equal_session_id (first w).session_id session
        && Tmux.equal_window_id (first w).window_id window)
      windows
  with
  | None -> None
  | Some current -> (
      let rec root w = match parent w with Some p -> root p | None -> w in
      let adjacent =
        let open Option.Infix in
        let* p = parent current in
        let siblings =
          List.concat_map
            (fun (pane : State.pane) ->
              List.filter
                (fun w ->
                  Tmux.equal_session_id (first w).session_id session
                  && Option.equal Tmux.equal_pane_id w.anchor (Some pane.pane_id))
                windows)
            p.panes
          |> Array.of_list
        in
        let* i, _ =
          Array.find_idx (fun w -> Tmux.equal_window_id (first w).window_id window) siblings
        in
        let j = i + if next then 1 else -1 in
        if j >= 0 && j < Array.length siblings then Some (first siblings.(j))
        else if next then None
        else Some (first p)
      in
      match adjacent with
      | Some _ -> adjacent
      | None ->
          let roots = List.filter (fun w -> Option.is_none (parent w)) windows |> Array.of_list in
          let active = first (root current) in
          let n = Array.length roots in
          let rec find j k =
            if k = 0 then None
            else if
              List.for_all
                (fun (p : State.pane) -> Option.is_none p.run || pi_run lingering p)
                roots.(j).panes
            then Some (first roots.(j))
            else find ((j + (if next then 1 else -1) + n) mod n) (k - 1)
          in
          Option.flat_map
            (fun (i, _) -> find ((i + (if next then 1 else -1) + n) mod n) n)
            (Array.find_idx
               (fun w ->
                 Tmux.equal_session_id (first w).session_id active.session_id
                 && Tmux.equal_window_id (first w).window_id active.window_id)
               roots))

let append_windows m placements =
  let placements = Array.of_list placements in
  let drawn = Array.make (Array.length placements) false in
  let anchored =
    Array.foldi
      (fun acc k (pl : placement) ->
        match pl.anchor with
        | None -> acc
        | Some a -> Tmux.Pane_map.update a (fun l -> Some (k :: Option.get_or ~default:[] l)) acc)
      Tmux.Pane_map.empty placements
  in
  let rec emit i =
    if drawn.(i) then None
    else begin
      drawn.(i) <- true;
      let item (p : State.pane) =
        let kids =
          List.rev (Option.get_or ~default:[] (Tmux.Pane_map.find_opt p.pane_id anchored))
        in
        Option.map
          (fun data -> { row = pane_label m data; children = List.filter_map emit kids })
          (Tmux.Pane_map.find_opt p.pane_id m.pane_data)
      in
      match placements.(i).panes with
      | [] -> None
      | [ p ] -> Option.map (fun item -> Item item) (item p)
      | p :: rest -> (
          match List.filter_map item (p :: rest) with
          | [] -> None
          | first :: rest -> Some (Group { name = p.window_name; first; rest }))
    end
  in
  Array.foldi
    (fun acc i _ -> match emit i with None -> acc | Some node -> node :: acc)
    [] placements
  |> List.rev

let rebuild m =
  let order = State.order_sessions m.snap.visible in
  let sessions =
    List.map
      (fun (s : State.session) ->
        {
          id = s.id;
          name = s.name;
          current =
            Option.exists (fun (c : Tmux.client) -> String.equal s.name c.session) m.snap.client;
          nodes =
            append_windows m (order_windows_by_tree s.windows m.snap.state.agents m.snap.lingering);
        })
      order
  in
  { m with sessions }

let poll ?wait ~(opts : options) conn (prev : snapshot) =
  Option.iter (fun timeout -> Tmux.Client.await_notifications conn ~timeout) wait;
  let client = ref prev.client in
  let failed e = { prev with client = !client; err = Some e } in
  match
    client := Tmux.find_client (Tmux.Client.tmux conn) opts.client;
    take ~opts conn prev !client
  with
  | snap -> snap
  | exception (Failure e | Sys_error e | Invalid_argument e) -> failed e
  | exception Unix.Unix_error (e, fn, arg) -> failed (Fs.unix_message e fn arg)

let step m (snap : snapshot) =
  let was = m.snap in
  let pending = Tmux.Pane_map.exists (fun _ d -> Pane_status.pending d.track) m.pane_data in
  let client =
    match (snap.client, active snap) with
    | Some (c : Tmux.client), Some active -> (
        match
          List.find_opt
            (fun (p : State.pane) ->
              Tmux.equal_pane_id p.pane_id active && Tmux.equal_session_id p.session_id c.session_id)
            snap.visible.panes
        with
        | Some p -> Some { session = p.session_id; window = p.window_id; pane = p.pane_id }
        | None -> m.client)
    | _ -> m.client
  in
  let pane_data =
    if
      Option.equal Tmux.equal_server (Option.map snd was.server) (Option.map snd snap.server)
      || Option.is_none was.server
    then m.pane_data
    else Tmux.Pane_map.empty
  in
  let m = track { m with at = m.now (); snap; client; pane_data } in
  if (not (same snap was)) || pending then (rebuild m, true) else (m, false)

type direction = Next | Prev
type switched = { session : Tmux.session_id; window : Tmux.window_id }
type position = Before | After
type 'a move = { source : 'a; anchor : 'a; position : position }

let movable ~eq ~missing ids { source; anchor; _ } =
  if not (List.mem ~eq source ids && List.mem ~eq anchor ids) then Error missing
  else if eq source anchor then Error "cannot reorder relative to itself"
  else Ok ()

type _ request =
  | Switch_window : direction -> (switched option, string) result request
  | Switch_session : direction -> (switched option, string) result request
  | New_window : Tmux.window_id -> (client, string) result request
  | New_session : (client, string) result request
  | Select_window : switched -> (client, string) result request
  | Select_session : Tmux.session_id -> (client, string) result request
  | Jump : client -> (client, string) result request
  | Release_side_focus : (unit, string) result request
  | Reorder_session : Tmux.session_id move -> (unit, string) result request
  | Reorder_window : Tmux.session_id * Tmux.window_id move -> (unit, string) result request
  | Prompt_resolve : Tmux.pane_id -> (Prompt.candidate list, Prompt.error) result request
  | Prompt_send : Prompt.send -> (Prompt.via, Prompt.error) result request

let handle : type a. tmux:Tmux.t -> dir:string -> client:string -> a request -> a =
 fun ~tmux ~dir ~client request ->
  let switched result =
    Result.map (Option.map (fun (session, window) -> { session; window })) result
  in
  let jump (target : client) =
    Result.map
      (fun () -> target)
      (Tmux.jump tmux ~client ~session:target.session ~window:target.window target.pane)
  in
  let create window =
    let open Result.Infix in
    let* target =
      match window with
      | Some window -> Ok (`Window window)
      | None -> (
          match Tmux.find_client tmux client with
          | Some c -> Ok (`Session c.session_id)
          | None -> Error "no current tmux session")
    in
    let from, command, missing =
      match target with
      | `Window window ->
          let id = Tmux.string_of_window_id window in
          (id, [ "new-window"; "-a"; "-t"; id ], "no such window")
      | `Session session ->
          (Tmux.string_of_session_id session ^ ":", [ "new-session" ], "no such session")
    in
    let* cwd = Tmux.exec tmux [ "display-message"; "-p"; "-t"; from; "#{pane_current_path}" ] in
    let* session, window, pane =
      if String.is_empty cwd then Error missing
      else
        let* out =
          Tmux.exec tmux
            (command @ [ "-d"; "-P"; "-F"; "#{session_id}:#{window_id}:#{pane_id}"; "-c"; cwd ])
        in
        let unreadable = Printf.sprintf "created shell but could not read its location: %S" out in
        match String.split ~by:":" out with
        | [ session; window; pane ] -> (
            try
              Ok
                ( Tmux.session_id_of_string session,
                  Tmux.window_id_of_string window,
                  Tmux.pane_id_of_string pane )
            with Invalid_argument _ -> Error unreadable)
        | _ -> Error unreadable
    in
    Result.map_err
      (fun e ->
        Printf.sprintf "created %s:%s.%s but selection failed: %s"
          (Tmux.string_of_session_id session)
          (Tmux.string_of_window_id window) (Tmux.string_of_pane_id pane) e)
      (jump { session; window; pane })
  in
  match request with
  | Select_window target -> (
      let open Result.Infix in
      let* state = State.read ~dir tmux in
      match
        List.find_opt
          (fun (p : State.pane) ->
            Tmux.equal_session_id p.session_id target.session
            && Tmux.equal_window_id p.window_id target.window
            && p.pane_active)
          state.panes
      with
      | None -> Error "no such window in session"
      | Some p -> jump { session = target.session; window = target.window; pane = p.pane_id })
  | Select_session session -> (
      let open Result.Infix in
      let* state = State.read ~dir tmux in
      match
        List.find_opt
          (fun (p : State.pane) -> Tmux.equal_session_id p.session_id session && p.active)
          state.panes
      with
      | None -> Error "no such window in session"
      | Some p -> jump { session; window = p.window_id; pane = p.pane_id })
  | New_window window -> create (Some window)
  | New_session -> create None
  | Jump target ->
      let open Result.Infix in
      let* state = State.read ~dir tmux in
      if
        List.exists
          (fun (p : State.pane) ->
            Tmux.equal_session_id p.session_id target.session
            && Tmux.equal_window_id p.window_id target.window
            && Tmux.equal_pane_id p.pane_id target.pane)
          state.panes
      then jump target
      else Error "no such pane in session/window"
  | Release_side_focus -> Tmux.release_side_focus tmux client
  | Prompt_resolve pane -> Prompt.resolve ~tmux ~dir pane
  | Prompt_send request -> Prompt.send ~tmux ~dir request
  | Reorder_session ({ source; anchor; position } as move) ->
      let open Result.Infix in
      let* state = State.read ~dir tmux in
      let ids = List.map (fun (s : State.session) -> s.id) (State.order_sessions state) in
      let* () = movable ~eq:Tmux.equal_session_id ~missing:"no such session" ids move in
      List.concat_map
        (fun id ->
          if Tmux.equal_session_id id source then []
          else if Tmux.equal_session_id id anchor then
            match position with Before -> [ source; id ] | After -> [ id; source ]
          else [ id ])
        ids
      |> List.mapi (fun i id ->
          (if i = 0 then [] else [ ";" ])
          @ [ "set-option"; "-t"; Tmux.string_of_session_id id; Tmux_vars.order; string_of_int i ])
      |> List.concat |> Tmux.run tmux
  | Reorder_window (session, ({ source; anchor; position } as move)) ->
      let open Result.Infix in
      let* state = State.read ~dir tmux in
      let roots =
        match
          List.find_opt
            (fun (s : State.session) -> Tmux.equal_session_id s.id session)
            (State.order_sessions state)
        with
        | Some (s : State.session) ->
            order_windows_by_tree s.windows state.agents (lingering_subagents ~dir state.runs)
            |> List.filter_map (fun (w : placement) ->
                match w.anchor with None -> Some (List.hd w.panes).window_id | Some _ -> None)
        | None -> []
      in
      let* () =
        movable ~eq:Tmux.equal_window_id ~missing:"no such top-level window in session" roots move
      in
      let id = Tmux.string_of_session_id session in
      let* grouped =
        Tmux.exec tmux [ "display-message"; "-p"; "-t"; id ^ ":"; "#{session_grouped}" ]
      in
      if String.equal grouped "1" then Error "cannot reorder windows in a grouped session"
      else
        let target window = Printf.sprintf "'%s:%s'" id (Tmux.string_of_window_id window) in
        let move_window =
          Printf.sprintf "move-window -d %s -s %s -t %s"
            (match position with Before -> "-b" | After -> "-a")
            (target source) (target anchor)
        in
        Tmux.run tmux
          [
            "if-shell";
            "-F";
            "-t";
            id ^ ":";
            Printf.sprintf "#{==:#{window_id},%s}" (Tmux.string_of_window_id source);
            Printf.sprintf "%s ; select-window -t %s" move_window (target source);
            move_window;
            ";";
            (* tmux renumbers after move-window only without -s (cmd-move-window.c). *)
            "if-shell";
            "-F";
            "-t";
            id ^ ":";
            "#{renumber-windows}";
            Printf.sprintf "move-window -r -t '%s'" id;
          ]
  | Switch_window direction ->
      switched
        (Result.flat_map
           (fun (state : State.t) ->
             let next = match direction with Next -> true | Prev -> false in
             let lingering = lingering_subagents ~dir state.runs in
             let windows = windows_in_order state lingering in
             match
               let open Option.Infix in
               let* (c : Tmux.client) = Tmux.find_client tmux client in
               let* (a : State.pane) =
                 List.find_opt
                   (fun (p : State.pane) -> String.equal p.session_name c.session && p.active)
                   (List.concat_map (fun w -> w.panes) windows)
               in
               window_target ~next ~session:a.session_id ~window:a.window_id ~lingering windows
             with
             | Some target ->
                 Result.map
                   (fun () -> Some (target.session_id, target.window_id))
                   (Tmux.run tmux
                      [
                        "switch-client";
                        "-c";
                        client;
                        "-t";
                        Tmux.string_of_session_id target.session_id;
                        ";";
                        "select-window";
                        "-t";
                        Tmux.string_of_window_id target.window_id;
                      ])
             | None -> Ok None)
           (State.read ~dir tmux))
  | Switch_session direction ->
      switched
        (Result.flat_map
           (fun (state : State.t) ->
             let sessions = Array.of_list (State.order_sessions state) in
             let length = Array.length sessions in
             if length < 2 then Ok None
             else
               let current = Tmux.find_client tmux client in
               match
                 Array.find_idx
                   (fun (s : State.session) ->
                     Option.exists (fun (c : Tmux.client) -> String.equal c.session s.name) current)
                   sessions
               with
               | Some (i, _) -> (
                   let target =
                     sessions.((i + (match direction with Next -> 1 | Prev -> -1) + length)
                               mod length)
                   in
                   let active =
                     List.find_opt (fun (p : State.pane) -> p.active) (List.concat target.windows)
                   in
                   match active with
                   | Some p ->
                       Result.map
                         (fun () -> Some (target.id, p.window_id))
                         (Tmux.run tmux
                            [
                              "switch-client";
                              "-c";
                              client;
                              "-t";
                              Tmux.string_of_session_id target.id;
                            ])
                   | None -> Ok None)
               | None -> Ok None)
           (State.read ~dir tmux))

let real_clients session =
  List.filter_map (fun (c : Tmux.client) ->
      if Tmux.equal_session_id c.session_id session && not (String.is_empty c.name || c.control)
      then Some c.name
      else None)

let resolve_client tmux ~pane ~session =
  let live =
    match pane with
    | None -> None
    | Some pane -> (
        match
          Tmux.exec tmux
            [ "display-message"; "-p"; "-t"; Tmux.string_of_pane_id pane; "#{session_id}" ]
        with
        | Ok id when not (String.is_empty id) -> Some (Tmux.session_id_of_string id)
        | _ -> None)
  in
  let target = Option.or_ ~else_:session live in
  match Option.map (fun t -> Result.map (real_clients t) (Tmux.list_clients tmux)) target with
  | Some (Ok [ c ]) -> Some c
  | _ -> None

let%test_module "Tests" =
  (module struct
    open View_fixture

    let%expect_test "standalone inference excludes control, unnamed and other-session clients" =
      let client name session control : Tmux.client =
        {
          name;
          session = "work";
          session_id = Tmux.session_id_of_string session;
          focused = false;
          control;
        }
      in
      List.iter print_endline
        (real_clients (Tmux.session_id_of_string "$0")
           [
             client "control" "$0" true;
             client "/dev/ttys001" "$0" false;
             client "" "$0" false;
             client "/dev/ttys002" "$1" false;
           ]);
      [%expect {| /dev/ttys001 |}]

    let model ?(dir = temp ()) ?(clock = ref test_at) () =
      let m =
        make
          ~now:(fun () -> !clock)
          { interval = default_interval; client = ""; tmux = Tmux.create (); dir; grace = 30. }
      in
      { m with at = !clock }

    let server = Some (1, { Tmux.started_at = 1_700_000_000; pid = 42 })
    let agent_pane ?run w p title = pane ~window:w ~title ?run p

    let label m (p : State.pane) =
      let row = pane_label m (Tmux.Pane_map.find p.pane_id m.pane_data) in
      Printf.sprintf "%S %s" row.title
        (match row.lifecycle with
        | Live { status; run } -> (
            Yojson.Safe.to_string (Pane_status.yojson_of_kind status)
            ^
            match run with
            | Some (r : run) -> " run=" ^ Run.string_of_kind r.kind ^ " started"
            | None -> "")
        | Ended { result; run } ->
            Printf.sprintf "ended %s run=%s"
              (match result with Some x -> Run.string_of_result x | None -> "unknown")
              (Run.string_of_kind run))

    let snap_of ?(l = []) panes =
      let state = state l panes in
      { empty with state; visible = state }

    let lingering ~dir pane id =
      lingering_subagents ~dir
        (Tmux.Pane_map.singleton (Tmux.pane_id_of_string pane)
           (Option.get_exn_or "run" (Run.load ~dir (Test_fixture.run_id id))))

    let tick ?(m = model ()) snap = track { m with snap = { snap with server } }

    let%expect_test "a run ends on death or a recorded outcome, which replaces unknown" =
      let p = agent_pane ~run:"run" "@20" "%30" "helper" in
      let l = [ ("%30", ("run", session ~activity:"checking tests" "")) ] in
      let snap outcome p =
        {
          (snap_of ~l [ p ]) with
          lingering =
            String_map.singleton "run"
              { name = "helper"; parent = None; outcome; kind = Agent; started = test_at };
        }
      in
      List.iter
        (fun (p, outcome) ->
          let snap = snap outcome p in
          print_endline (label (tick snap) (List.hd snap.state.panes)))
        [ (p, None); ({ p with dead_at = Some 1. }, None); (p, Some Run.Completed) ];
      [%expect
        {|
        "helper" ["Pi_agent",{"id":"run","status":{"since":1700000000.0,"msg":"checking tests","state":["Running",{"progress":null}]}}] run=agent started
        "helper" ended unknown run=agent
        "helper" ended completed run=agent
        |}]

    let%expect_test "a run ends with its local pi Run name even after its root was cleared" =
      let dir = temp () in
      let id = new_run ~dir "the run" in
      let st = [ ("%30", ("pi-1", { (session "") with name = "Named" })) ] in
      let p = pane ~window:"@20" ~dead_at:1. ~run:id ~title:"π - pane" "%30" in
      let m =
        tick ~m:(model ~dir ()) { (snap_of ~l:st [ p ]) with lingering = lingering ~dir "%30" id }
      in
      print_endline (label m p);
      [%expect {| "Named" ended unknown run=agent |}]

    let%expect_test
        "titles: pi name or title, native pane title or app, shell record, app or command" =
      let st =
        [ ("%1", ("pi-1", { (session "") with name = "named" })); ("%10", ("pi-2", session "")) ]
      in
      let records json p =
        {
          p with
          State.program_status =
            Result.get_exn
              (Tmux.Program_status.parse (Printf.sprintf {|{"serial":1,"records":%s}|} json));
        }
      in
      let panes =
        [
          records {|[{"id":"","app":"pi","state":"idle"}]|} (pane ~title:"pane title" "%1");
          records {|[{"id":"","app":"claude-code","state":"idle","title":"T3Q="}]|}
            (pane ~title:"" "%2");
          records {|[{"id":"","app":"pi","state":"idle"}]|} (pane ~title:"bare pi" "%3");
          records {|[{"id":"","app":"cargo","state":"working","title":"QnVpbGQ="}]|}
            (pane ~command:"zsh" "%4");
          records {|[{"id":"","app":"cargo","state":"working"}]|} (pane ~command:"zsh" "%5");
          records {|[{"id":"x","state":"idle"}]|} (pane ~command:"zsh" "%6");
          pane ~command:"zsh" "%7";
          pane ~ssh:("deploy", "box") ~command:"ssh" "%8";
          pane ~run:"run" ~command:"zsh" "%9";
          records {|[{"id":"","app":"pi","state":"idle"}]|} (pane ~title:"π - kido" "%10");
        ]
      in
      let m =
        tick
          {
            (snap_of ~l:st panes) with
            lingering =
              String_map.singleton "run"
                { name = "a run"; parent = None; outcome = None; kind = Bash; started = test_at };
          }
      in
      List.iter
        (fun p ->
          print_endline (pane_label m (Tmux.Pane_map.find p.State.pane_id m.pane_data)).title)
        panes;
      [%expect
        {|
        named
        claude-code
        bare pi
        Build
        cargo
        zsh
        zsh
        ssh
        a run
        π - kido
        |}]

    let%expect_test
        "tracking: kept by the same server and read errors, cleared by a new one, a pane's removal"
        =
      let clock = ref test_at in
      let m = ref (model ~clock ()) in
      let p =
        pane ~command:"make" ~prompt:(test_at -. 1.) ~start:test_at ~running:true
          ~command_line:"make" "%1"
      in
      let step label d server snap =
        clock := !clock +. d;
        m := fst (step !m { snap with server });
        Printf.printf "%-14s %s\n" label
          (match Tmux.Pane_map.find_opt p.pane_id !m.pane_data with
          | None -> "untracked"
          | Some d -> (
              match d.status with
              | Terminal { phase = Running _; _ } -> "running"
              | Terminal { phase = Idle _; _ } -> "debouncing"
              | _ -> "other"))
      in
      let snap = { (snap_of [ p ]) with client = client "sess" } in
      let other = Some (1, { Tmux.started_at = 1_700_000_000; pid = 43 }) in
      step "first" 0. server snap;
      step "same server" 0.3 server snap;
      step "read error" 0.1 server { snap with err = Some "gone" };
      step "new server" 0.1 other snap;
      step "debounced" 0.3 other snap;
      step "removed" 0.1 other { (snap_of []) with client = snap.client };
      step "back" 0.1 other snap;
      [%expect
        {|
        first          debouncing
        same server    running
        read error     running
        new server     debouncing
        debounced      running
        removed        untracked
        back           debouncing
        |}]

    let agents ?(runs = []) edges =
      ( states (List.map (fun (pane, id, _) -> (pane, (id, session ""))) edges),
        List.fold_left
          (fun m (id, parent) ->
            let parent = Test_fixture.owned parent in
            let kind : Run.kind = if Option.is_none parent then Pi else Agent in
            String_map.add id { name = ""; parent; outcome = None; kind; started = test_at } m)
          String_map.empty
          (runs @ List.map (fun (_, id, parent) -> (id, parent)) edges) )

    let marked edges =
      List.map
        (List.map (fun (p : State.pane) ->
             match
               List.find_opt
                 (fun (pane, _, _) -> String.equal pane (Tmux.string_of_pane_id p.pane_id))
                 edges
             with
             | Some (_, id, _) -> { p with run = Some id }
             | None -> p))

    let placements ?runs windows edges =
      let states, lingering = agents ?runs edges in
      List.iter
        (fun (pl : placement) ->
          Printf.printf "%s anchor=%s\n"
            (Tmux.string_of_window_id (List.hd pl.panes).window_id)
            (match pl.anchor with Some x -> Tmux.string_of_pane_id x | None -> "-"))
        (order_windows_by_tree (marked edges windows) states lingering)

    let w ?run id = [ pane ~window:("@" ^ id) ?run ("%" ^ id) ]

    let%expect_test "order_windows_by_tree: child after parent, anchored to the parent's pane" =
      placements
        [ w "200"; w "201"; w "203"; w "202" ]
        [ ("%201", "root-sess", ""); ("%203", "a", "root-sess"); ("%202", "b", "root-sess") ];
      placements [ w "200"; w "204" ] [ ("%204", "orphan-sess", "elsewhere-sess") ];
      placements
        [ w "201"; w "205"; w "206" ]
        [
          ("%201", "root-sess", "");
          ("%205", "kid-sess", "root-sess");
          ("%206", "gk-sess", "kid-sess");
        ];
      placements [ w "207"; w "208" ] [ ("%207", "a-sess", "b-sess"); ("%208", "b-sess", "a-sess") ];
      [%expect
        {|
    @200 anchor=-
    @201 anchor=-
    @203 anchor=%201
    @202 anchor=%201
    @200 anchor=-
    @204 anchor=-
    @201 anchor=-
    @205 anchor=%201
    @206 anchor=%205
    @207 anchor=-
    @208 anchor=%207
    |}]

    let%expect_test "order_windows_by_tree: a run with no live agent, and a window of two agents" =
      placements
        ~runs:[ ("run-1", "root-sess") ]
        [ w "201"; w ~run:"run-1" "205" ]
        [ ("%201", "root-sess", "") ];
      placements ~runs:[ ("run-1", "elsewhere-sess") ] [ w "200"; w ~run:"run-1" "205" ] [];
      placements
        [ [ pane ~window:"@13" "%21"; pane ~window:"@13" "%101" ]; w "210"; w "211" ]
        [
          ("%21", "top-sess", "");
          ("%101", "second-sess", "");
          ("%210", "kid1-sess", "top-sess");
          ("%211", "kid2-sess", "second-sess");
        ];
      [%expect
        {|
    @201 anchor=-
    @205 anchor=%201
    @200 anchor=-
    @205 anchor=-
    @13 anchor=-
    @210 anchor=%21
    @211 anchor=%101
    |}]

    let%expect_test "window targets: siblings, roots, runs and session occurrences" =
      let pane = Test_fixture.pane in
      let p window id = pane ~window id in
      let root = p "@1" "%1" and later_pane = p "@1" "%2" in
      let child = pane ~window:"@2" ~run:"child" "%3" in
      let sibling = pane ~window:"@3" ~run:"sibling" "%4" in
      let grandchild = pane ~window:"@4" ~run:"grandchild" "%5" in
      let earlier = p "@5" "%6" in
      let other = pane ~session:"b" ~session_id:"$1" ~window:"@6" "%7" in
      let linked = { root with session_name = "b"; session_id = other.session_id } in
      let windows =
        [
          { panes = [ root; later_pane ]; anchor = None };
          { panes = [ child ]; anchor = Some later_pane.pane_id };
          { panes = [ grandchild ]; anchor = Some child.pane_id };
          { panes = [ pane ~window:"@9" ~run:"grand-sibling" "%10" ]; anchor = Some child.pane_id };
          { panes = [ sibling ]; anchor = Some later_pane.pane_id };
          { panes = [ earlier ]; anchor = Some root.pane_id };
          { panes = [ p "@7" "%8" ]; anchor = None };
          { panes = [ pane ~window:"@8" ~run:"orphan" "%9" ]; anchor = None };
          { panes = [ linked ]; anchor = None };
          { panes = [ other ]; anchor = None };
        ]
      in
      List.iter
        (fun (session, window, next) ->
          let target =
            window_target ~next
              ~session:(Tmux.session_id_of_string session)
              ~window:(Tmux.window_id_of_string window) ~lingering:String_map.empty windows
          in
          Printf.printf "%s:%s %s -> %s\n" session window
            (if next then "next" else "prev")
            (match target with
            | Some (p : State.pane) ->
                Tmux.string_of_session_id p.session_id ^ ":" ^ Tmux.string_of_window_id p.window_id
            | None -> "null"))
        [
          ("$0", "@1", true);
          ("$0", "@5", true);
          ("$0", "@5", false);
          ("$0", "@2", false);
          ("$0", "@2", true);
          ("$0", "@3", true);
          ("$0", "@4", false);
          ("$0", "@4", true);
          ("$0", "@9", false);
          ("$0", "@9", true);
          ("$0", "@7", true);
          ("$1", "@1", false);
          ("$1", "@6", true);
          ("$0", "@1", false);
        ];
      List.iter
        (fun windows ->
          List.iter
            (fun next ->
              print_endline
                (match
                   window_target ~next ~session:root.session_id ~window:root.window_id
                     ~lingering:String_map.empty windows
                 with
                | Some (p : State.pane) -> Tmux.string_of_window_id p.window_id
                | None -> "null"))
            [ true; false ])
        [
          [];
          [ { panes = [ root ]; anchor = None } ];
          [ { panes = [ { root with run = Some "only-run" } ]; anchor = None } ];
          [ { panes = [ root; { later_pane with run = Some "split-run" } ]; anchor = None } ];
          [ { panes = [ root ]; anchor = Some (Tmux.pane_id_of_string "%999") } ];
        ];
      [%expect
        {|
    $0:@1 next -> $0:@7
    $0:@5 next -> $0:@2
    $0:@5 prev -> $0:@1
    $0:@2 prev -> $0:@5
    $0:@2 next -> $0:@3
    $0:@3 next -> $0:@7
    $0:@4 prev -> $0:@2
    $0:@4 next -> $0:@9
    $0:@9 prev -> $0:@4
    $0:@9 next -> $0:@7
    $0:@7 next -> $1:@1
    $1:@1 prev -> $0:@7
    $1:@6 next -> $0:@1
    $0:@1 prev -> $1:@6
    null
    null
    @1
    @1
    null
    null
    null
    null
    @1
    @1
    |}]

    let%expect_test "window targets: siblings precede parents, next leaves the root subtree" =
      let edges =
        [
          ("%201", "root-session", "");
          ("%202", "child1-session", "root-session");
          ("%203", "child2-session", "root-session");
          ("%212", "grandchild-session", "child2-session");
        ]
      in
      let states, lingering = agents edges in
      let windows =
        windows_in_order
          {
            State.empty with
            panes = marked edges [ w "201"; w "209"; w "202"; w "203"; w "212" ] |> List.concat;
            agents = states;
          }
          lingering
      in
      List.iter
        (fun (next, window) ->
          Printf.printf "%s %s -> %s\n"
            (if next then "next" else "prev")
            window
            (match
               window_target ~next ~session:(Tmux.session_id_of_string "$0")
                 ~window:
                   (Tmux.window_id_of_string
                      ("@"
                      ^ List.assoc ~eq:String.equal window
                          [
                            ("other", "209");
                            ("root", "201");
                            ("child2", "203");
                            ("grandchild", "212");
                          ]))
                 ~lingering windows
             with
            | Some (p : State.pane) -> Tmux.string_of_window_id p.window_id
            | None -> "-"))
        [
          (false, "other");
          (false, "root");
          (false, "child2");
          (false, "grandchild");
          (true, "child2");
          (true, "root");
        ];
      [%expect
        {|
        prev other -> @201
        prev root -> @209
        prev child2 -> @202
        prev grandchild -> @203
        next child2 -> @209
        next root -> @209
        |}]

    let%expect_test "lingering reads each tick's record afresh: a reported name, an outcome" =
      let dir = temp () in
      let id = new_run ~dir "subagent" in
      let i = Test_fixture.run_id id in
      let show () =
        let l = String_map.find id (lingering ~dir "%30" id) in
        Printf.printf "%s %s\n" l.name
          (match l.outcome with Some x -> Run.string_of_result x | None -> "-")
      in
      show ();
      ignore (Run.write_pi ~dir i ~holder:0 { (Test_fixture.pi ()) with name = "renamed" });
      ignore (Run.record_outcome ~dir i { result = Completed; text = ""; at = None });
      show ();
      [%expect {|
    subagent -
    renamed completed
    |}]

    let%expect_test
        "same ignores the report time and catches any other change; panes compare by exclusion" =
      let l ts = [ ("%1", ("i", session ~ts "")) ] in
      let snap ts = snap_of ~l:(l ts) [ pane "%1" ] in
      Printf.printf "ts only: %b\n" (same (snap test_at) (snap (test_at +. 60.)));
      let s = snap test_at in
      Printf.printf "holder died: %b\n"
        (same s { s with state = { s.state with agents = Tmux.Pane_map.empty } });
      let p = pane ~command:"zsh" "%1" in
      let panes p = snap_of [ p ] in
      Printf.printf "layout: %b\n" (same (panes p) (panes { p with window_layout = "x" }));
      Printf.printf "window name: %b\n" (same (panes p) (panes { p with window_name = "x" }));
      Printf.printf "exit: %b\n"
        (same (panes p) (panes { p with last_exit = Some { code = 1; at = 1. } }));
      Printf.printf "command: %b\n" (same (panes p) (panes { p with current_command = "vim" }));
      [%expect
        {|
    ts only: true
    holder died: false
    layout: true
    window name: false
    exit: false
    command: false
    |}]
  end)
