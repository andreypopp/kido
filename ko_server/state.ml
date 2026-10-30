type t = {
  config : Config.t;
  panes : Panes.t;
  mutable clients : Client.t list;
  mutable views : View.t list;
  mutable next_client : int;
  started_at : int;
  mutable activity : unit -> unit;
}

let create config =
  {
    config;
    panes = Panes.create config;
    clients = [];
    views = [];
    next_client = 1;
    started_at = Int64.of_float (Unix.gettimeofday () *. 1e9) |> Int64.to_int;
    activity = ignore;
  }

let panes t = t.panes
let clients t = t.clients
let on_activity t callback = t.activity <- callback

let broadcast t json =
  List.iter
    (fun c -> if Client.registered c then Connection.json (Client.connection c) json)
    t.clients

let topology t =
  broadcast t (Protocol.yojson_of_topology { topology = { panes = Panes.rows t.panes } })

let pump t = List.iter View.pump t.views
let waiting t = List.exists View.waiting t.views

let close_views t pane =
  List.iter
    (fun v -> if String.equal (Pane.id (View.pane v)) (Pane.id pane) then View.close v)
    t.views

let event t pane = function
  | Pane.Title title -> broadcast t (Protocol.yojson_of_title_event { pane = Pane.id pane; title })
  | Pwd pwd -> broadcast t (Protocol.yojson_of_pwd_event { pane = Pane.id pane; pwd })
  | Dead dead -> broadcast t (Protocol.yojson_of_dead_event { pane = Pane.id pane; dead })
  | Failed dead ->
      broadcast t (Protocol.yojson_of_dead_event { pane = Pane.id pane; dead });
      close_views t pane
  | Output ->
      List.iter
        (fun view -> if String.equal (Pane.id (View.pane view)) (Pane.id pane) then View.pump view)
        t.views;
      t.activity ()

let add_client t connection =
  let id = "client_" ^ string_of_int t.next_client in
  t.next_client <- t.next_client + 1;
  let client = Client.create id connection in
  t.clients <- client :: t.clients;
  client

let remove_client t client =
  t.clients <- List.filter (fun c -> not (String.equal (Client.id c) (Client.id client))) t.clients;
  List.iter
    (fun v ->
      if Option.equal String.equal (View.client v) (Some (Client.id client)) then View.close v)
    t.views

let add_view t view =
  t.views <- view :: t.views;
  t.activity ()

let remove_view t view = t.views <- List.filter (fun v -> not Stdlib.(v == view)) t.views

let version t : Config.version =
  {
    protocol = Config.protocol;
    vt = Config.vt;
    server = { started_at = t.started_at; pid = Unix.getpid (); build = Config.build };
    terminal = t.config.terminal;
  }
