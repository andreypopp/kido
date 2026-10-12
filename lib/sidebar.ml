module String_map = Map.Make (String)

type options = {
  interval : float;
  client : string;
  tmux : Tmux.t;
  dir : string;
  threshold : float;
  grace : float;
}

let default_interval = 0.1

type lingering = {
  stamp : (int * float) option;
  name : string;
  parent : string;
  outcome : Subrun.result option;
  kind : Subrun.kind;
  started : Timestamp.t;
}

type ask_target = Live of Tmux.pane_id | Revivable | Unavailable
type ask = { ask : Ask.t; target : ask_target }

type snapshot = {
  server : (int * Tmux_pane.server) option;
  client : Tmux_pane.client_state option;
  active : Tmux.pane_id option;
  panes : Tmux_pane.t list;
  states : (string * State.session) Tmux.Pane_map.t;
  wake : float option;
  err : string option;
  lingering : lingering String_map.t;
  asks : ask list;
}

let empty =
  {
    server = None;
    client = None;
    active = None;
    panes = [];
    states = Tmux.Pane_map.empty;
    wake = None;
    err = None;
    lingering = String_map.empty;
    asks = [];
  }

let lingering_subagents ~dir panes prev =
  List.fold_left
    (fun out (p : Tmux_pane.t) ->
      match Option.map Subrun.parse_id p.run with
      | Some (Ok run_id) -> (
          let key = Subrun.string_of_id run_id in
          let outcome () =
            Option.map (fun (o : Subrun.outcome) -> o.result) (Subrun.read_outcome ~dir run_id)
          in
          match String_map.find_opt key prev with
          | _ when String_map.mem key out -> out
          | cached -> (
              let stamp =
                try
                  let s = Unix.stat (Subrun.meta_path ~dir run_id) in
                  Some (s.st_ino, s.st_mtime)
                with Unix.Unix_error (ENOENT, _, _) -> None
              in
              let meta =
                if Option.is_none stamp || Option.exists (fun l -> Stdlib.(l.stamp = stamp)) cached
                then None
                else Subrun.read_meta ~dir run_id
              in
              match cached with
              | Some l ->
                  let name = Option.map_or ~default:l.name (fun (m : Subrun.meta) -> m.name) meta in
                  String_map.add key
                    { l with stamp; name; outcome = Option.or_lazy ~else_:outcome l.outcome }
                    out
              | None -> (
                  match meta with
                  | None -> out
                  | Some meta ->
                      String_map.add key
                        {
                          stamp;
                          name = meta.name;
                          parent = meta.parent_session;
                          outcome = outcome ();
                          kind = meta.kind;
                          started = meta.started_at;
                        }
                        out)))
      | _ -> out)
    String_map.empty panes

let take ~opts conn prev client =
  Option.iter (fun (c : Tmux_pane.client_state) -> Tmux.Client.follow conn c.session_id) client;
  let tmux = Tmux.Client.tmux conn in
  let read =
    let open Result.Infix in
    let* server =
      match prev.server with
      | Some (dial, _) when Int.equal dial (Tmux.Client.dials conn) -> Ok prev.server
      | _ -> Result.map (fun s -> Some (Tmux.Client.dials conn, s)) (Tmux_pane.server tmux)
    in
    Result.map (fun panes -> (server, panes)) (Tmux_pane.list_panes tmux)
  in
  match read with
  | Error e -> { prev with client; active = None; err = Some e }
  | Ok (server, panes) ->
      let live = State.load_live ~dir:opts.dir in
      let states = State.by_pane live in
      if not (List.is_empty panes) then
        Reap.collect opts.tmux ~dir:opts.dir ~grace:opts.grace panes live
          ~now:(Unix.gettimeofday ());
      {
        server;
        client;
        active =
          Option.flat_map
            (fun (c : Tmux_pane.client_state) -> Tmux_pane.active_pane panes c.session)
            client;
        panes;
        states;
        wake = State.wake ~dir:opts.dir;
        err = None;
        lingering = lingering_subagents ~dir:opts.dir panes prev.lingering;
        asks =
          List.map
            (fun (a : Ask.t) ->
              let pane =
                Option.flat_map
                  (fun (s : State.session) -> s.pane)
                  (List.assoc_opt ~eq:String.equal a.session live)
              in
              let target =
                match pane with
                | Some pane -> Live pane
                | None -> if Option.is_none (Ask.revival_error a) then Revivable else Unavailable
              in
              let name = Ask.display_name ~panes ~live a in
              { ask = { a with name }; target })
            (Ask.list ~dir:opts.dir);
      }

let same a b =
  let drawn (p : Tmux_pane.t) =
    {
      p with
      window_index = 0;
      window_layout = "";
      current_path = "";
      active = false;
      pane_active = false;
    }
  in
  let session (_, (s : State.session)) = { s with ts = 0. } in
  Option.equal Stdlib.( = ) a.server b.server
  && Option.equal Stdlib.( = ) a.client b.client
  && Option.equal Tmux.equal_pane_id a.active b.active
  && Option.is_none a.err && Option.is_none b.err
  && Option.equal Float.equal a.wake b.wake
  && List.equal (fun x y -> Stdlib.( = ) (drawn x) (drawn y)) a.panes b.panes
  && Tmux.Pane_map.equal (fun x y -> Stdlib.( = ) (session x) (session y)) a.states b.states
  && String_map.equal
       (fun x y -> Stdlib.({ x with stamp = None } = { y with stamp = None }))
       a.lingering b.lingering
  && List.equal Stdlib.( = ) a.asks b.asks

type reading = { wall : Timestamp.t; mono : Mtime.t }

let read_clock () = { wall = Timestamp.now (); mono = Mtime_clock.now () }

let detect_pause prev now =
  let mono = Mtime.Span.to_float_ns (Mtime.span prev.mono now.mono) /. 1e9 in
  Float.(now.wall - prev.wall - mono > 5.)

type client = { session : Tmux.session_id; window : Tmux.window_id; pane : Tmux.pane_id }
type run = { kind : Subrun.kind; started : Timestamp.t }

type lifecycle =
  | Live of { status : Pane_status.kind; run : run option }
  | Ended of { result : Subrun.result option; run : Subrun.kind }

type row = { pane : Tmux.pane_id; window : Tmux.window_id; title : string; lifecycle : lifecycle }

type node = Group of { name : string; first : item; rest : item list } | Item of item
and item = { row : row; children : node list }

type section = { id : Tmux.session_id; name : string; current : bool; nodes : node list }
type pane = { pane : Tmux_pane.t; track : Pane_status.track; status : Pane_status.kind }

type model = {
  opts : options;
  snap : snapshot;
  sessions : section list;
  pane_data : pane Tmux.Pane_map.t;
  client : client option;
  now : unit -> float;
  at : float;
  clock : reading;
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
    clock = read_clock ();
  }

let track ~prev m =
  if Option.is_some m.snap.err then (m, false)
  else
    let stalled_at (m : model) (p : Tmux_pane.t) (kind : State.pane_kind) =
      match kind with
      | Pi_agent { session; _ } ->
          State.stalled_since
            ~root:(Tmux.Program_status.root p.program_status)
            ~threshold:m.opts.threshold ~wake:m.snap.wake ~now:m.at session
      | Terminal | Some_agent _ | Ssh _ -> false
    in
    let pane_data, changed =
      List.fold_left
        (fun (data, changed) (p : Tmux_pane.t) ->
          if Tmux.Pane_map.mem p.pane_id data then (data, changed)
          else
            let kind = State.pane_kind ~states:m.snap.states p in
            let ask =
              match kind with
              | Pi_agent { id; _ } ->
                  List.find_map
                    (fun a -> if String.equal a.ask.session id then Some a.ask.id else None)
                    m.snap.asks
              | Terminal | Some_agent _ | Ssh _ -> None
            in
            let stalled = stalled_at m p kind in
            let track, status =
              Pane_status.observe ~now:m.at ~ask ~stalled p kind
                (Option.map (fun d -> d.track) (Tmux.Pane_map.find_opt p.pane_id m.pane_data))
            in
            ( Tmux.Pane_map.add p.pane_id { pane = p; track; status } data,
              changed
              || Option.exists
                   (fun d ->
                     not
                       (Bool.equal stalled
                          (stalled_at prev d.pane (State.pane_kind ~states:prev.snap.states d.pane))))
                   (Tmux.Pane_map.find_opt p.pane_id prev.pane_data) ))
        (Tmux.Pane_map.empty, false) m.snap.panes
    in
    ( { m with pane_data },
      changed
      || Tmux.Pane_map.exists
           (fun pane d ->
             (not (Tmux.Pane_map.mem pane pane_data))
             && stalled_at prev d.pane (State.pane_kind ~states:prev.snap.states d.pane))
           prev.pane_data )

let pane_label m (d : pane) =
  let p = d.pane in
  let lingering = Option.flat_map (fun run -> String_map.find_opt run m.snap.lingering) p.run in
  let live_title () =
    let kind = State.pane_kind ~states:m.snap.states p in
    match (kind, lingering) with
    | (Pi_agent _ | Some_agent _ | Ssh { pane = Remote_agent _; _ }), _ ->
        Option.value ~default:"" (State.pane_title p kind)
    | (Terminal | Ssh { pane = Remote_terminal; _ }), Some l
      when List.is_empty p.program_status.records ->
        l.name
    | (Terminal | Ssh { pane = Remote_terminal; _ }), _ -> Pane_status.label d.track p
  in
  let title, lifecycle =
    match lingering with
    | Some l when Option.is_some l.outcome || Option.is_some p.dead_at ->
        ( (match Tmux.Pane_map.find_opt p.pane_id m.snap.states with
          | Some (_, ({ agent = Pi; _ } as s)) -> State.display_name [ p ] s
          | _ -> l.name),
          Ended { result = l.outcome; run = l.kind } )
    | _ ->
        ( live_title (),
          Live
            {
              status = d.status;
              run =
                Option.map (fun (l : lingering) -> { kind = l.kind; started = l.started }) lingering;
            } )
  in
  { pane = p.pane_id; window = p.window_id; title; lifecycle }

type placement = { panes : Tmux_pane.t list; anchor : Tmux.pane_id option }

let order_windows_by_tree windows states lingering =
  let window_id (w : Tmux_pane.t list) = (List.hd w).window_id in
  let by_session =
    List.fold_left
      (fun acc w ->
        List.fold_left
          (fun acc (p : Tmux_pane.t) ->
            match Tmux.Pane_map.find_opt p.pane_id states with
            | Some (id, _) when not (String.is_empty id) ->
                String_map.add id (window_id w, p.pane_id) acc
            | _ -> acc)
          acc w)
      String_map.empty windows
  in
  let parent_of_window (w : Tmux_pane.t list) =
    match
      List.find_map
        (fun (p : Tmux_pane.t) ->
          Option.flat_map
            (fun (_, (s : State.session)) ->
              Option.map (fun (pa : State.parent) -> pa.session) s.parent)
            (Tmux.Pane_map.find_opt p.pane_id states))
        w
    with
    | Some parent -> parent
    | None ->
        Option.value ~default:""
          (List.find_map
             (fun (p : Tmux_pane.t) ->
               Option.map
                 (fun l -> l.parent)
                 (Option.flat_map (fun r -> String_map.find_opt r lingering) p.run))
             w)
  in
  let ordered =
    Tree.order
      ~id:(fun (w, _) -> window_id w)
      ~parent:(fun (_, found) -> Option.map fst found)
      (List.map (fun w -> (w, String_map.find_opt (parent_of_window w) by_session)) windows)
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

let windows_in_order panes states lingering =
  List.concat_map
    (fun (s : Tmux_pane.session) -> order_windows_by_tree s.windows states lingering)
    (Tmux_pane.order_sessions panes)

let window_target ~next ~session ~window windows =
  let first w = List.hd w.panes in
  let parent w =
    Option.flat_map
      (fun anchor ->
        List.find_opt
          (fun candidate ->
            Tmux.equal_session_id (first candidate).session_id (first w).session_id
            && List.exists
                 (fun (p : Tmux_pane.t) -> Tmux.equal_pane_id p.pane_id anchor)
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
        Option.flat_map
          (fun p ->
            let siblings =
              List.concat_map
                (fun (pane : Tmux_pane.t) ->
                  List.filter
                    (fun w ->
                      Tmux.equal_session_id (first w).session_id session
                      && Option.equal Tmux.equal_pane_id w.anchor (Some pane.pane_id))
                    windows)
                p.panes
              |> Array.of_list
            in
            Option.flat_map
              (fun (i, _) ->
                let j = i + if next then 1 else -1 in
                if j >= 0 && j < Array.length siblings then Some (first siblings.(j))
                else if next then None
                else Some (first p))
              (Array.find_idx (fun w -> Tmux.equal_window_id (first w).window_id window) siblings))
          (parent current)
      in
      match adjacent with
      | Some _ -> adjacent
      | None ->
          let roots = List.filter (fun w -> Option.is_none (parent w)) windows |> Array.of_list in
          let active = first (root current) in
          let n = Array.length roots in
          let rec find j k =
            if k = 0 then None
            else if List.for_all (fun (p : Tmux_pane.t) -> Option.is_none p.run) roots.(j).panes
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
      let item (p : Tmux_pane.t) =
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
  let order = Tmux_pane.order_sessions m.snap.panes in
  let sessions =
    List.map
      (fun (s : Tmux_pane.session) ->
        {
          id = s.id;
          name = s.name;
          current =
            Option.exists
              (fun (c : Tmux_pane.client_state) -> String.equal s.name c.session)
              m.snap.client;
          nodes = append_windows m (order_windows_by_tree s.windows m.snap.states m.snap.lingering);
        })
      order
  in
  { m with sessions }

let poll ?wait ~(opts : options) conn (prev : snapshot) =
  Option.iter (fun timeout -> Tmux.Client.await_notifications conn ~timeout) wait;
  let client = ref prev.client in
  let failed e = { prev with client = !client; active = None; err = Some e } in
  match
    client := Tmux_pane.client_state (Tmux.Client.tmux conn) opts.client;
    take ~opts conn prev !client
  with
  | snap -> snap
  | exception (Failure e | Sys_error e | Invalid_argument e) -> failed e
  | exception Unix.Unix_error (e, fn, arg) -> failed (Fs.unix_message e fn arg)

let step m (snap : snapshot) =
  let was = m.snap in
  let pending = Tmux.Pane_map.exists (fun _ d -> Pane_status.pending d.track) m.pane_data in
  let clock = read_clock () in
  (if detect_pause m.clock clock then
     try State.record_pause ~dir:m.opts.dir clock.wall with Unix.Unix_error _ | Sys_error _ -> ());
  let client =
    match snap.client with
    | Some (c : Tmux_pane.client_state) -> (
        match
          List.find_opt
            (fun (p : Tmux_pane.t) ->
              Option.equal Tmux.equal_pane_id (Some p.pane_id) snap.active
              && Tmux.equal_session_id p.session_id c.session_id)
            snap.panes
        with
        | Some p -> Some { session = p.session_id; window = p.window_id; pane = p.pane_id }
        | None -> m.client)
    | None -> m.client
  in
  let pane_data =
    if
      Option.equal Tmux_pane.equal_server (Option.map snd was.server) (Option.map snd snap.server)
      || Option.is_none was.server
    then m.pane_data
    else Tmux.Pane_map.empty
  in
  let m, stall_changed = track ~prev:m { m with at = m.now (); clock; snap; client; pane_data } in
  if (not (same snap was)) || pending || stall_changed then (rebuild m, true) else (m, false)

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
  | Activate_ask : Ask.id -> (client, string) result request
  | Delete_ask : Ask.id -> (unit, string) result request
  | Release_side_focus : (unit, string) result request
  | Reorder_session : Tmux.session_id move -> (unit, string) result request
  | Reorder_window : Tmux.session_id * Tmux.window_id move -> (unit, string) result request

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
          match Tmux_pane.client_state tmux client with
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
      let* panes = Tmux_pane.list_panes tmux in
      match
        List.find_opt
          (fun (p : Tmux_pane.t) ->
            Tmux.equal_session_id p.session_id target.session
            && Tmux.equal_window_id p.window_id target.window
            && p.pane_active)
          panes
      with
      | None -> Error "no such window in session"
      | Some p -> jump { session = target.session; window = target.window; pane = p.pane_id })
  | Select_session session -> (
      let open Result.Infix in
      let* panes = Tmux_pane.list_panes tmux in
      match
        List.find_opt
          (fun (p : Tmux_pane.t) -> Tmux.equal_session_id p.session_id session && p.active)
          panes
      with
      | None -> Error "no such window in session"
      | Some p -> jump { session; window = p.window_id; pane = p.pane_id })
  | New_window window -> create (Some window)
  | New_session -> create None
  | Jump target ->
      let open Result.Infix in
      let* panes = Tmux_pane.list_panes tmux in
      if
        List.exists
          (fun (p : Tmux_pane.t) ->
            Tmux.equal_session_id p.session_id target.session
            && Tmux.equal_window_id p.window_id target.window
            && Tmux.equal_pane_id p.pane_id target.pane)
          panes
      then jump target
      else Error "no such pane in session/window"
  | Activate_ask id -> (
      let open Result.Infix in
      let* ask =
        match Ask.read ~dir id with
        | Some ask -> Ok ask
        | None -> Error ("no ask " ^ Ask.string_of_id id)
      in
      let* current =
        match Tmux_pane.client_state tmux client with
        | Some c -> Ok c
        | None -> Error "no current tmux session"
      in
      let* pane = Ask.target ~tmux ~dir ~session:current.session_id ask in
      let* panes = Tmux_pane.list_panes tmux in
      let candidates =
        List.filter (fun (p : Tmux_pane.t) -> Tmux.equal_pane_id p.pane_id pane) panes
      in
      let target =
        match
          List.find_opt
            (fun (p : Tmux_pane.t) -> Tmux.equal_session_id p.session_id current.session_id)
            candidates
        with
        | Some p -> Some p
        | None -> List.head_opt candidates
      in
      match target with
      | None -> Error "asking agent has no pane"
      | Some p -> jump { session = p.session_id; window = p.window_id; pane })
  | Delete_ask id -> Ask.remove ~dir ~self:"" id
  | Release_side_focus -> Tmux.release_side_focus tmux client
  | Reorder_session ({ source; anchor; position } as move) ->
      let open Result.Infix in
      let* panes = Tmux_pane.list_panes tmux in
      let ids = List.map (fun (s : Tmux_pane.session) -> s.id) (Tmux_pane.order_sessions panes) in
      let* () = movable ~eq:Tmux.equal_session_id ~missing:"no such session" ids move in
      Tmux_pane.rank_sessions tmux
        (List.concat_map
           (fun id ->
             if Tmux.equal_session_id id source then []
             else if Tmux.equal_session_id id anchor then
               match position with Before -> [ source; id ] | After -> [ id; source ]
             else [ id ])
           ids)
  | Reorder_window (session, ({ source; anchor; position } as move)) ->
      let open Result.Infix in
      let* panes = Tmux_pane.list_panes tmux in
      let roots =
        List.find_opt
          (fun (s : Tmux_pane.session) -> Tmux.equal_session_id s.id session)
          (Tmux_pane.order_sessions panes)
        |> Option.map_or ~default:[] (fun (s : Tmux_pane.session) ->
            order_windows_by_tree s.windows
              (State.by_pane (State.load_live ~dir))
              (lingering_subagents ~dir panes String_map.empty)
            |> List.filter_map (fun (w : placement) ->
                match w.anchor with None -> Some (List.hd w.panes).window_id | Some _ -> None))
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
           (fun panes ->
             let states = State.by_pane (State.load_live ~dir) in
             let next = match direction with Next -> true | Prev -> false in
             let windows =
               windows_in_order panes states (lingering_subagents ~dir panes String_map.empty)
             in
             let active =
               Option.flat_map
                 (fun (c : Tmux_pane.client_state) ->
                   List.find_opt
                     (fun (p : Tmux_pane.t) -> String.equal p.session_name c.session && p.active)
                     (List.concat_map (fun w -> w.panes) windows))
                 (Tmux_pane.client_state tmux client)
             in
             match
               Option.flat_map
                 (fun (a : Tmux_pane.t) ->
                   window_target ~next ~session:a.session_id ~window:a.window_id windows)
                 active
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
           (Tmux_pane.list_panes tmux))
  | Switch_session direction ->
      switched
        (Result.flat_map
           (fun panes ->
             let sessions = Array.of_list (Tmux_pane.order_sessions panes) in
             let length = Array.length sessions in
             if length < 2 then Ok None
             else
               let current = Tmux_pane.client_state tmux client in
               match
                 Array.find_idx
                   (fun (s : Tmux_pane.session) ->
                     Option.exists
                       (fun (c : Tmux_pane.client_state) -> String.equal c.session s.name)
                       current)
                   sessions
               with
               | Some (i, _) -> (
                   let target =
                     sessions.((i + (match direction with Next -> 1 | Prev -> -1) + length)
                               mod length)
                   in
                   let active =
                     List.find_opt (fun (p : Tmux_pane.t) -> p.active) (List.concat target.windows)
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
           (Tmux_pane.list_panes tmux))

let%test_module "Tests" =
  (module struct
    open View_fixture

    let model ?(dir = temp ()) ?(clock = ref test_at) () =
      let m =
        make
          ~now:(fun () -> !clock)
          {
            interval = default_interval;
            client = "";
            tmux = Tmux.create ();
            dir;
            threshold = 180.;
            grace = 30.;
          }
      in
      { m with at = !clock }

    let server = Some (1, { Tmux_pane.started_at = 1_700_000_000; pid = 42 })
    let agent_pane ?run w p title = pane ~window:w ~title ?run p

    let label m (p : Tmux_pane.t) =
      let row = pane_label m (Tmux.Pane_map.find p.pane_id m.pane_data) in
      Printf.sprintf "%S %s" row.title
        (match row.lifecycle with
        | Live { status; run } ->
            Yojson.Safe.to_string (Pane_status.yojson_of_kind status)
            ^ Option.map_or ~default:""
                (fun (r : run) -> " run=" ^ Subrun.string_of_kind r.kind ^ " started")
                run
        | Ended { result; run } ->
            Printf.sprintf "ended %s run=%s"
              (Option.map_or ~default:"unknown" Subrun.string_of_result result)
              (Subrun.string_of_kind run))

    let tick ?(m = model ()) snap = fst (track ~prev:m { m with snap = { snap with server } })

    let%expect_test "a run ends on death or a recorded outcome, which replaces unknown" =
      let p = agent_pane ~run:"run" "@20" "%30" "helper" in
      let states = states [ ("%30", ("run", session ~activity:"checking tests" "")) ] in
      let snap outcome p =
        {
          empty with
          states;
          panes = with_programs states [ p ];
          lingering =
            String_map.singleton "run"
              {
                stamp = None;
                name = "helper";
                parent = "";
                outcome;
                kind = Agent;
                started = test_at;
              };
        }
      in
      List.iter
        (fun (p, outcome) ->
          let snap = snap outcome p in
          print_endline (label (tick snap) (List.hd snap.panes)))
        [ (p, None); ({ p with dead_at = Some 1. }, None); (p, Some Subrun.Completed) ];
      [%expect
        {|
        "helper" ["Pi_agent",{"id":"run","status":{"since":1700000000.0,"msg":"checking tests","state":["Running",{"progress":null}]}}] run=agent started
        "helper" ended unknown run=agent
        "helper" ended completed run=agent
        |}]

    let%expect_test "a run ends with its local pi State name even after its root was cleared" =
      let dir = temp () in
      let id = new_run ~dir "the run" in
      let st = states [ ("%30", ("pi-1", { (session "") with name = "Named" })) ] in
      let p = pane ~window:"@20" ~dead_at:1. ~run:id ~title:"π - pane" "%30" in
      let m =
        tick ~m:(model ~dir ())
          {
            empty with
            states = st;
            panes = [ p ];
            lingering = lingering_subagents ~dir [ p ] String_map.empty;
          }
      in
      print_endline (label m p);
      [%expect {| "Named" ended unknown run=agent |}]

    let%expect_test "titles: pi name, native pane title or app, shell record, app or command" =
      let st = states [ ("%1", ("pi-1", { (session "") with name = "named" })) ] in
      let records json p =
        {
          p with
          Tmux_pane.program_status =
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
        ]
      in
      let m =
        tick
          {
            empty with
            states = st;
            panes;
            lingering =
              String_map.singleton "run"
                {
                  stamp = None;
                  name = "a run";
                  parent = "";
                  outcome = None;
                  kind = Bash;
                  started = test_at;
                };
          }
      in
      List.iter
        (fun p ->
          print_endline (pane_label m (Tmux.Pane_map.find p.Tmux_pane.pane_id m.pane_data)).title)
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
        |}]

    let%expect_test "an outstanding ask outranks a blocked record; several asks take the first" =
      let st = states [ ("%1", ("pi-1", session "")) ] in
      let p =
        {
          (pane ~title:"agent" "%1") with
          program_status =
            Result.get_exn
              (Tmux.Program_status.parse
                 {|{"serial":3,"records":[{"id":"","app":"pi","state":"blocked","kind":"auth"}]}|});
        }
      in
      let ask id session : ask =
        {
          ask =
            {
              id = Result.get_exn (Ask.parse_id id);
              session;
              session_file = "";
              cwd = "";
              name = "";
              text = "";
              created = test_at;
            };
          target = Revivable;
        }
      in
      List.iter
        (fun asks -> print_endline (label (tick { empty with states = st; panes = [ p ]; asks }) p))
        [ []; [ ask "A0" "other"; ask "Ab" "pi-1"; ask "Aa" "pi-1" ] ];
      [%expect
        {|
        "agent" ["Pi_agent",{"id":"pi-1","status":{"since":1700000000.0,"msg":null,"state":["Waiting",{"source":["Blocked",{"kind":"auth"}],"progress":null}]}}]
        "agent" ["Pi_agent",{"id":"pi-1","status":{"since":1700000000.0,"msg":null,"state":["Waiting",{"source":["Ask",{"id":"Ab"}],"progress":null}]}}]
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
      let snap = { empty with client = client "sess"; panes = [ p ] } in
      let other = Some (1, { Tmux_pane.started_at = 1_700_000_000; pid = 43 }) in
      step "first" 0. server snap;
      step "same server" 0.3 server snap;
      step "read error" 0.1 server { snap with err = Some "gone" };
      step "new server" 0.1 other snap;
      step "debounced" 0.3 other snap;
      step "removed" 0.1 other { snap with panes = [] };
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

    let placements windows st lingering =
      List.iter
        (fun (pl : placement) ->
          Printf.printf "%s anchor=%s\n"
            (Tmux.string_of_window_id (List.hd pl.panes).window_id)
            (Option.map_or ~default:"-" Tmux.string_of_pane_id pl.anchor))
        (order_windows_by_tree windows (states st) lingering)

    let w ?run id = [ pane ~window:("@" ^ id) ?run ("%" ^ id) ]

    let%expect_test "order_windows_by_tree: child after parent, anchored to the parent's pane" =
      placements
        [ w "200"; w "201"; w "203"; w "202" ]
        [
          ("%201", ("root-sess", session ""));
          ("%203", ("", session ~parent:"root-sess" ~depth:1 ""));
          ("%202", ("", session ~parent:"root-sess" ~depth:1 ""));
        ]
        String_map.empty;
      placements
        [ w "200"; w "204" ]
        [ ("%204", ("orphan-sess", session ~parent:"elsewhere-sess" ~depth:1 "")) ]
        String_map.empty;
      placements
        [ w "201"; w "205"; w "206" ]
        [
          ("%201", ("root-sess", session ""));
          ("%205", ("kid-sess", session ~parent:"root-sess" ~depth:1 ""));
          ("%206", ("gk-sess", session ~parent:"kid-sess" ~depth:1 ""));
        ]
        String_map.empty;
      placements
        [ w "207"; w "208" ]
        [
          ("%207", ("a-sess", session ~parent:"b-sess" ""));
          ("%208", ("b-sess", session ~parent:"a-sess" ""));
        ]
        String_map.empty;
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

    let%expect_test
        "order_windows_by_tree: the lingering fallback, and a record beating a stale mark" =
      let lingering parent =
        String_map.singleton "run-1"
          { stamp = None; name = ""; parent; outcome = None; kind = Agent; started = test_at }
      in
      placements
        [ w "201"; w ~run:"run-1" "205" ]
        [ ("%201", ("root-sess", session "")) ]
        (lingering "root-sess");
      placements
        [ w "201"; w "209"; w ~run:"run-1" "205" ]
        [
          ("%201", ("root-sess", session ""));
          ("%209", ("other-sess", session ""));
          ("%205", ("kid-sess", session ~parent:"root-sess" ""));
        ]
        (lingering "other-sess");
      placements [ w "200"; w ~run:"run-1" "205" ] [] (lingering "elsewhere-sess");
      placements [ w ~run:"run-1" "205" ] [] (lingering "nonexistent-sess");
      placements
        [ [ pane ~window:"@13" "%21"; pane ~window:"@13" "%101" ]; w "210"; w "211" ]
        [
          ("%21", ("top-sess", session ""));
          ("%101", ("second-sess", session ""));
          ("%210", ("kid1-sess", session ~parent:"top-sess" ~depth:1 ""));
          ("%211", ("kid2-sess", session ~parent:"second-sess" ~depth:1 ""));
        ]
        String_map.empty;
      [%expect
        {|
    @201 anchor=-
    @205 anchor=%201
    @201 anchor=-
    @205 anchor=%201
    @209 anchor=-
    @200 anchor=-
    @205 anchor=-
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
              ~window:(Tmux.window_id_of_string window) windows
          in
          Printf.printf "%s:%s %s -> %s\n" session window
            (if next then "next" else "prev")
            (Option.map_or ~default:"null"
               (fun (p : Tmux_pane.t) ->
                 Tmux.string_of_session_id p.session_id ^ ":" ^ Tmux.string_of_window_id p.window_id)
               target))
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
                (Option.map_or ~default:"null"
                   (fun (p : Tmux_pane.t) -> Tmux.string_of_window_id p.window_id)
                   (window_target ~next ~session:root.session_id ~window:root.window_id windows)))
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
      let windows =
        windows_in_order
          (List.concat
             [
               w "201";
               w "209";
               w ~run:"child1" "202";
               w ~run:"child2" "203";
               w ~run:"grandchild" "212";
             ])
          (states
             [
               ("%201", ("root-session", session ""));
               ("%202", ("child1-session", session ~parent:"root-session" ""));
               ("%203", ("child2-session", session ~parent:"root-session" ""));
               ("%212", ("grandchild-session", session ~parent:"child2-session" ""));
             ])
          String_map.empty
      in
      List.iter
        (fun (next, window) ->
          Printf.printf "%s %s -> %s\n"
            (if next then "next" else "prev")
            window
            (Option.map_or ~default:"-"
               (fun (p : Tmux_pane.t) -> Tmux.string_of_window_id p.window_id)
               (window_target ~next ~session:(Tmux.session_id_of_string "$0")
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
                  windows)))
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

    let%expect_test "lingering entries carry forward; only a missing outcome is re-read" =
      let dir = temp () in
      let id = new_run ~dir "subagent" in
      let panes = [ pane ~window:"@20" ~dead_at:1. ~run:id "%30" ] in
      let first = lingering_subagents ~dir panes String_map.empty in
      let show l =
        let (l : lingering) = String_map.find id l in
        Printf.printf "%s %s\n" l.name
          (Option.map_or ~default:"-" Subrun.string_of_result l.outcome)
      in
      show first;
      Sys.remove (Subrun.meta_path ~dir (Result.get_exn (Subrun.parse_id id)));
      ignore
        (Subrun.record_outcome ~dir
           (Result.get_exn (Subrun.parse_id id))
           { result = Completed; text = ""; at = None });
      show (lingering_subagents ~dir panes first);
      [%expect {|
    subagent -
    subagent completed
    |}]

    let%expect_test "pane_title" =
      let st = states [ ("%1", ("agent", session "%1")) ] in
      List.iter
        (fun title ->
          Printf.printf "%s -> %s\n" title
            (Option.value ~default:"(not an agent)"
               (let p = List.hd (with_programs st [ pane ~title "%1" ]) in
                State.pane_title p (State.pane_kind ~states:st p))))
        [
          "✳ Tmux config";
          "✳ 2 panes";
          "π - kido - kido";
          "π - kido";
          "π - ";
          "plain title";
          "π-no-space";
          "";
          "✳ ";
          "~/src/kido";
        ];
      [%expect
        {|
    ✳ Tmux config -> ✳ Tmux config
    ✳ 2 panes -> ✳ 2 panes
    π - kido - kido -> π - kido - kido
    π - kido -> π - kido
    π -  -> π -
    plain title -> plain title
    π-no-space -> π-no-space
     ->
    ✳  -> ✳
    ~/src/kido -> ~/src/kido
    |}]

    let%expect_test
        "same ignores a heartbeat's ts and catches any other change; panes compare by exclusion" =
      let snap ts =
        { empty with panes = [ pane "%1" ]; states = states [ ("%1", ("i", session ~ts "")) ] }
      in
      Printf.printf "ts only: %b\n" (same (snap test_at) (snap (test_at +. 60.)));
      Printf.printf "status: %b\n"
        (same (snap test_at)
           { (snap test_at) with panes = with_programs (snap test_at).states (snap test_at).panes });
      let p = pane ~command:"zsh" "%1" in
      Printf.printf "layout: %b\n"
        (same { empty with panes = [ p ] }
           { empty with panes = [ { p with window_layout = "x" } ] });
      Printf.printf "window name: %b\n"
        (same { empty with panes = [ p ] } { empty with panes = [ { p with window_name = "x" } ] });
      Printf.printf "exit: %b\n"
        (same { empty with panes = [ p ] }
           { empty with panes = [ { p with last_exit = Some { code = 1; at = 1. } } ] });
      Printf.printf "command: %b\n"
        (same { empty with panes = [ p ] }
           { empty with panes = [ { p with current_command = "vim" } ] });
      [%expect
        {|
    ts only: true
    status: false
    layout: true
    window name: false
    exit: false
    command: false
    |}]

    let%expect_test "a pause is the wall clock outrunning the monotonic one" =
      let reading wall mono_s : reading =
        { wall; mono = Mtime.of_uint64_ns (Int64.of_float (mono_s *. 1e9)) }
      in
      List.iter
        (fun (name, wall, mono) ->
          Printf.printf "%-26s %b\n" name
            (detect_pause (reading 1000. 1000.) (reading (1000. +. wall) (1000. +. mono))))
        [
          ("awake, tick on schedule", 0.1, 0.1);
          ("awake, tick genuinely slow", 300., 300.);
          ("just under the slack", 4.999, 0.);
          ("just over the slack", 5.001, 0.);
          ("asleep for minutes", 300., 0.05);
        ];
      [%expect
        {|
    awake, tick on schedule    false
    awake, tick genuinely slow false
    just under the slack       false
    just over the slack        true
    asleep for minutes         true
    |}]
  end)
