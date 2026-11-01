type message =
  | Tick
  | Key of Matrix_input.Key.event
  | Mouse of Mosaic.Event.mouse
  | Paste of string
  | Size
  | Focus of bool

type sidebar = Hidden | Visible | Choosing of int

type view =
  | No_view
  | Showing of {
      pane : Ko_server.Ids.Pane_id.t;
      mirror : Mirror.t;
      mutable latest : Ko_vt.frame option;
    }

type t = {
  wire : Wire.t;
  socket : string;
  id : Ko_server.Ids.Client_id.t;
  matrix : Matrix.app;
  modes : Modes.t;
  renderer : Renderer.t;
  limits : Ko_server.Config.limits;
  pager : string;
  lock : Mutex.t;
  mutable panes : Ko_server.Protocol.row list;
  mutable failure : string option;
  mutable view : view;
  mutable sidebar : sidebar;
  mutable warning : bool;
  mutable geometry : int * int;
  mutable focused : bool;
  mutable closed : bool;
  mutable thread : Thread.t option;
  pending : bool Atomic.t;
  mutable dispatch : (message -> unit) option;
  mutable delay : float option;
  mutable last_paint : float;
  mutable immediate : bool;
}

let rows t = Mutex.protect t.lock (fun () -> t.panes)
let pane t = match t.view with No_view -> None | Showing v -> Some v.pane
let mirror t = match t.view with No_view -> None | Showing v -> Some v.mirror
let sidebar_x sidebar ~cols = match sidebar with Hidden -> 0 | _ -> Sidebar.pane_x ~cols
let pane_x t = sidebar_x t.sidebar ~cols:(fst t.geometry)
let warning_rows warning = if warning then 1 else 0

let pane_size ~geometry:(cols, rows) ~sidebar ~warning =
  {
    Ko_server.Protocol.cols = max 1 (cols - sidebar_x sidebar ~cols);
    rows = max 1 (rows - warning_rows warning);
    cell_px = None;
  }

let size t = pane_size ~geometry:t.geometry ~sidebar:t.sidebar ~warning:t.warning

let dead t =
  match t.view with
  | No_view -> None
  | Showing v ->
      List.find_map
        (fun (p : Ko_server.Protocol.row) ->
          if Ko_server.Ids.Pane_id.equal p.id v.pane then p.dead else None)
        (rows t)

let layout t =
  let cols, height = t.geometry in
  {
    Renderer.cols;
    rows = height;
    pane_x = pane_x t;
    pane_rows = max 0 (height - warning_rows t.warning);
    warning = t.warning;
    dead = Option.map Sidebar.dead_line (dead t);
    choosing = (match t.sidebar with Choosing i -> Some i | _ -> None);
    sidebar = (match t.sidebar with Hidden -> [] | _ -> Sidebar.rows ~selected:(pane t) (rows t));
  }

let notify t =
  if (not t.closed) && Atomic.compare_and_set t.pending false true then
    Option.iter (fun f -> f Tick) t.dispatch

let send t json = Option.iter (fun m -> Mirror.send m json) (mirror t)
let request ?consume t route body = Wire.request ~socket:t.socket ~client:t.id ?consume ~route body

let resize t =
  t.geometry <- Matrix.size t.matrix;
  Wire.send t.wire (Ko_server.Protocol.Request.client_to_json (Size (size t)))

let switch t pane =
  Option.iter
    (fun m ->
      Mirror.send m (Ko_server.Protocol.Request.view_to_json (Input (Focus false)));
      Mirror.close m)
    (mirror t);
  t.view <- No_view;
  (match t.sidebar with Choosing _ -> t.sidebar <- Visible | _ -> ());
  Modes.reset t.modes;
  Renderer.invalidate t.renderer;
  Wire.send t.wire (Ko_server.Protocol.Request.client_to_json (Select pane));
  let m =
    Mirror.open_view ~socket:t.socket ~client:t.id ~pane ~limits:t.limits ~notify:(fun () ->
        notify t)
  in
  t.view <- Showing { pane; mirror = m; latest = None };
  send t (Ko_server.Protocol.Request.view_to_json (Input (Focus t.focused)));
  t.delay <- None;
  t.immediate <- true

let create_pane t =
  let body =
    Ko_server.Protocol.Request.create_pane_to_json
      { cwd = Some (Sys.getcwd ()); command = None; env = [] }
    |> Yojson.Basic.to_string
  in
  let p =
    request t Create_pane body |> Yojson.Basic.from_string |> Ko_server.Protocol.created_of_json
  in
  switch t p.pane

let selected_index t all =
  match
    List.find_idx
      (fun (p : Ko_server.Protocol.row) ->
        Option.exists (Ko_server.Ids.Pane_id.equal p.id) (pane t))
      all
  with
  | Some (i, _) -> i
  | None -> 0

let choose t delta =
  let all = rows t in
  let n = List.length all in
  let i = selected_index t all in
  if n > 0 then switch t (List.nth all ((i + delta + n) mod n)).id

let paint t =
  let now = Unix.gettimeofday () in
  if t.immediate || Float.(now -. t.last_paint >= 0.008) then (
    let fresh =
      match t.view with
      | No_view -> false
      | Showing v -> (
          match Mirror.frame v.mirror with
          | None -> false
          | Some frame ->
              v.latest <- Some frame;
              true)
    in
    let frame = match t.view with No_view -> None | Showing v -> v.latest in
    if Renderer.paint t.renderer ~modes:t.modes ~layout:(layout t) ~frame then t.last_paint <- now;
    if fresh then t.immediate <- false)

let close t =
  t.closed <- true;
  Option.iter Mirror.close (mirror t);
  Wire.close t.wire;
  Option.iter Thread.join t.thread;
  t.view <- No_view

let create ~wire ~socket ~matrix ~modes ~pager =
  let geometry = Matrix.size matrix and warning = not (Matrix.capabilities matrix).kitty_keyboard in
  let sidebar = if warning || Sidebar.visible ~cols:(fst geometry) then Visible else Hidden in
  Wire.upgrade wire ~route:Client ();
  Wire.send wire
    (Ko_server.Protocol.Request.client_to_json
       (Hello
          {
            kind = Terminal;
            name = "ko";
            pane = None;
            focused = true;
            size = pane_size ~geometry ~sidebar ~warning;
            ignore_size = false;
          }));
  let text () =
    match Wire.receive wire with
    | `Text s -> Yojson.Basic.from_string s
    | _ -> raise (Wire.Error "client event missing")
  in
  let id, limits =
    match Ko_server.Protocol.Event.client_of_json (text ()) with
    | Welcome { client; limits } -> (client, limits)
    | _ -> raise (Wire.Error "welcome missing")
  in
  let panes =
    match Ko_server.Protocol.Event.client_of_json (text ()) with
    | Topology panes -> panes
    | _ -> raise (Wire.Error "topology missing")
  in
  let t =
    {
      wire;
      socket;
      id;
      matrix;
      modes;
      renderer = Renderer.create ();
      limits;
      pager;
      lock = Mutex.create ();
      panes;
      failure = None;
      view = No_view;
      sidebar;
      warning;
      geometry;
      focused = true;
      closed = false;
      thread = None;
      pending = Atomic.make false;
      dispatch = None;
      delay = None;
      last_paint = 0.;
      immediate = true;
    }
  in
  (match panes with [] -> create_pane t | p :: _ -> switch t p.id);
  t.thread <-
    Some
      (Thread.create
         (fun () ->
           try
             while not t.closed do
               let event =
                 match Wire.receive wire with
                 | `Text s -> Ko_server.Protocol.Event.client_of_json (Yojson.Basic.from_string s)
                 | _ -> raise (Wire.Error "server closed the client")
               in
               Mutex.protect t.lock (fun () ->
                   match event with
                   | Topology panes -> t.panes <- panes
                   | Title { pane; title } ->
                       t.panes <-
                         List.map
                           (fun (p : Ko_server.Protocol.row) ->
                             if Ko_server.Ids.Pane_id.equal p.id pane then { p with title } else p)
                           t.panes
                   | Dead { pane; dead } ->
                       t.panes <-
                         List.map
                           (fun (p : Ko_server.Protocol.row) ->
                             if Ko_server.Ids.Pane_id.equal p.id pane then
                               { p with dead = Some dead }
                             else p)
                           t.panes
                   | Welcome _ | Pwd _ -> ());
               notify t
             done
           with e ->
             if not t.closed then (
               Mutex.protect t.lock (fun () -> t.failure <- Some (Printexc.to_string e));
               notify t))
         ());
  t

let update t message =
  let command = ref Mosaic.Cmd.none in
  (match message with
  | Size ->
      resize t;
      t.immediate <- true
  | Focus focused ->
      t.focused <- focused;
      Wire.send t.wire (Ko_server.Protocol.Request.client_to_json (Focused focused));
      send t (Ko_server.Protocol.Request.view_to_json (Input (Focus focused)))
  | Paste text ->
      t.immediate <- true;
      send t
        (Ko_server.Protocol.Request.view_to_json
           (Input (Paste { text; check_safe = false; id = None })))
  | Key k -> (
      t.immediate <- true;
      Option.iter Mirror.bottom (mirror t);
      let dead = Option.is_some (dead t) in
      let effective event =
        match Input.command event with Some Remove when not dead -> None | c -> c
      in
      let action = effective k in
      if t.warning && k.modifier.ctrl && k.modifier.shift then (
        t.warning <- false;
        match action with Some Toggle_sidebar | Some Detach -> () | _ -> resize t);
      let release = match k.event_type with Release -> true | _ -> false in
      if
        release
        && (Option.is_some (effective { k with event_type = Press })
           || match t.sidebar with Choosing _ -> true | _ -> false)
      then ()
      else
        match action with
        | Some Detach -> command := Mosaic.Cmd.quit
        | Some Toggle_sidebar ->
            t.sidebar <-
              (match t.sidebar with Hidden -> Choosing (selected_index t (rows t)) | _ -> Hidden);
            resize t
        | Some Pager -> (
            match pane t with
            | None -> ()
            | Some pane ->
                let path, oc =
                  Filename.open_temp_file ~mode:[ Open_binary ] ~perms:0o600 "ko-scrollback-" ".txt"
                in
                Fun.protect
                  ~finally:(fun () ->
                    close_out_noerr oc;
                    Sys.remove path)
                  (fun () ->
                    ignore
                      (request ~consume:(output_string oc) t (Screen (pane, Ansi, Full_history)) "");
                    close_out oc;
                    Modes.reset t.modes;
                    Matrix.suspend ~leave_alt:true t.matrix;
                    Fun.protect
                      ~finally:(fun () ->
                        Matrix.resume t.matrix;
                        Renderer.invalidate t.renderer;
                        Option.iter Mirror.bottom (mirror t))
                      (fun () ->
                        let pid =
                          Unix.create_process "/bin/sh"
                            [| "/bin/sh"; "-c"; t.pager ^ " \"$1\""; "ko-pager"; path |]
                            Unix.stdin Unix.stdout Unix.stderr
                        in
                        ignore (Unix.waitpid [] pid))))
        | Some New -> create_pane t
        | Some Remove -> (
            match t.view with
            | No_view -> ()
            | Showing v -> (
                Mirror.close v.mirror;
                t.view <- No_view;
                ignore (request t (Delete_pane v.pane) "");
                let all =
                  request t List_panes "" |> Yojson.Basic.from_string |> Yojson.Basic.Util.to_list
                  |> List.map Ko_server.Protocol.row_of_json
                in
                Mutex.protect t.lock (fun () -> t.panes <- all);
                match all with [] -> create_pane t | p :: _ -> switch t p.id))
        | Some Previous -> choose t (-1)
        | Some Next -> choose t 1
        | None -> (
            match (t.sidebar, k.key) with
            | Choosing i, (Up | Down) ->
                let n = List.length (rows t) in
                if n > 0 then
                  t.sidebar <-
                    Choosing ((i + if Matrix_input.Key.equal k.key Up then n - 1 else 1) mod n)
            | Choosing i, Enter ->
                Option.iter
                  (fun (p : Ko_server.Protocol.row) -> switch t p.id)
                  (List.nth_opt (rows t) i)
            | Choosing _, Escape -> t.sidebar <- Visible
            | _ ->
                (match t.sidebar with Choosing _ -> t.sidebar <- Visible | _ -> ());
                send t (Ko_server.Protocol.Request.view_to_json (Input (Key (Input.key k))))))
  | Mouse event -> (
      let module M = Mosaic.Event.Mouse in
      let x = M.x event and y = M.y event in
      let l = layout t in
      if x >= 0 && x < l.cols && y >= 0 && y < l.pane_rows then
        if x < l.pane_x then
          match M.kind event with
          | Down _ when x < l.pane_x - 1 ->
              Option.iter (fun r -> switch t r.Sidebar.pane) (List.nth_opt l.sidebar y)
          | _ -> ()
        else
          match t.view with
          | No_view -> ()
          | Showing v -> (
              match v.latest with
              | None -> ()
              | Some f -> (
                  if not (Ko_vt.equal_mouse_tracking f.mouse Ko_vt.Off) then
                    send t
                      (Ko_server.Protocol.Request.view_to_json
                         (Input (Mouse (Input.mouse ~pane_x:l.pane_x event))))
                  else
                    match M.kind event with
                    | Scroll { direction; delta } ->
                        t.immediate <- true;
                        Mirror.scroll v.mirror
                          (if M.equal_scroll_direction direction Scroll_up then -3 * delta
                           else 3 * delta)
                    | _ -> ())))
  | Tick ->
      Atomic.set t.pending false;
      (match Mutex.protect t.lock (fun () -> t.failure) with
      | Some message -> raise (Wire.Error message)
      | None -> ());
      Option.iter (fun m -> Option.iter (fun e -> raise (Wire.Error e)) (Mirror.error m)) (mirror t);
      if t.warning && (Matrix.capabilities t.matrix).kitty_keyboard then (
        t.warning <- false;
        t.sidebar <- (if Sidebar.visible ~cols:(fst t.geometry) then Visible else Hidden);
        resize t);
      let repaint = t.last_paint +. 0.008 -. Unix.gettimeofday () in
      let hold = Option.flat_map Mirror.delay (mirror t) in
      t.delay <-
        (if (not t.immediate) && Float.(repaint > 0.) then
           Some (match hold with None -> repaint | Some h -> Float.min h repaint)
         else hold));
  ((), !command)

let start t dispatch startup =
  t.dispatch <- Some dispatch;
  dispatch Tick;
  List.iter
    (function
      | Matrix_input.Key k -> dispatch (Key k)
      | Paste text -> dispatch (Paste text)
      | Focus -> dispatch (Focus true)
      | Blur -> dispatch (Focus false)
      | _ -> ())
    startup

let subscriptions t =
  let open Mosaic in
  Sub.batch
    ([
       Sub.On_key_all (fun e -> Some (Key (Event.Key.data e)));
       Sub.On_mouse_all (fun e -> Some (Mouse e));
       Sub.On_paste_all (fun e -> Some (Paste (Event.Paste.text e)));
       Sub.On_resize (fun ~width:_ ~height:_ -> Size);
       Sub.On_focus (Focus true);
       Sub.On_blur (Focus false);
     ]
    @ match t.delay with None -> [] | Some delay -> [ Sub.every delay (fun () -> Tick) ])
