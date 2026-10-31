type t = {
  config : Config.t;
  panes : Panes.t;
  mutable clients : Client.t list;
  mutable views : View.t list;
  mutable next_client : int;
  mutable activity : unit -> unit;
}

let create config =
  {
    config;
    panes = Panes.create config;
    clients = [];
    views = [];
    next_client = 1;
    activity = ignore;
  }

let panes t = t.panes
let clients t = t.clients
let on_activity t callback = t.activity <- callback

let broadcast t json =
  List.iter
    (fun c -> if Client.registered c then Connection.json (Client.connection c) json)
    t.clients

let topology t = broadcast t (Protocol.Event.client_to_json (Topology (Panes.rows t.panes)))
let pump t = List.iter View.pump t.views
let waiting t = List.exists View.waiting t.views

let close_views t pane =
  List.iter
    (fun v -> if Ids.Pane_id.equal (Pane.id (View.pane v)) (Pane.id pane) then View.close v)
    t.views

let event t pane = function
  | Pane.Title title ->
      broadcast t (Protocol.Event.client_to_json (Title { pane = Pane.id pane; title }))
  | Pwd pwd -> broadcast t (Protocol.Event.client_to_json (Pwd { pane = Pane.id pane; pwd }))
  | Dead dead -> broadcast t (Protocol.Event.client_to_json (Dead { pane = Pane.id pane; dead }))
  | Failed dead ->
      broadcast t (Protocol.Event.client_to_json (Dead { pane = Pane.id pane; dead }));
      close_views t pane
  | Output ->
      List.iter
        (fun view ->
          if Ids.Pane_id.equal (Pane.id (View.pane view)) (Pane.id pane) then View.pump view)
        t.views;
      t.activity ()

let add_client t connection =
  let id = Ids.Client_id.make t.next_client in
  t.next_client <- t.next_client + 1;
  let client = Client.create id connection in
  t.clients <- client :: t.clients;
  client

let remove_client t client =
  t.clients <-
    List.filter (fun c -> not (Ids.Client_id.equal (Client.id c) (Client.id client))) t.clients;
  List.iter
    (fun v ->
      if Option.equal Ids.Client_id.equal (View.client v) (Some (Client.id client)) then
        View.close v)
    t.views

let add_view t view =
  t.views <- view :: t.views;
  t.activity ()

let remove_view t view = t.views <- List.filter (fun v -> not Stdlib.(v == view)) t.views
let limits t = t.config.limits

let registered t id =
  List.exists (fun c -> Ids.Client_id.equal (Client.id c) id && Client.registered c) t.clients
