type t = {
  config : Config.t;
  panes : Panes.t;
  mutable clients : Client.t list;
  mutable views : View.t list;
  mutable next_client : int;
  activity : unit -> bool;
}

let create config ~activity =
  { config; panes = Panes.create config; clients = []; views = []; next_client = 1; activity }

let panes t = t.panes
let clients t = t.clients

let rec has_clients = function
  | [] -> false
  | client :: rest -> Client.registered client || has_clients rest

let broadcast t make =
  if has_clients t.clients then begin
    let json = make () in
    List.iter
      (fun c -> if Client.registered c then Connection.json (Client.connection c) json)
      t.clients
  end

let topology t =
  broadcast t (fun () -> Protocol.Event.client_to_json (Topology (Panes.rows t.panes)))

let pump t = List.iter View.pump t.views
let waiting t = List.exists View.waiting t.views

let close_views t id =
  List.iter (fun v -> if Ids.Pane_id.equal (Pane.id (View.pane v)) id then View.close v) t.views

let rec pump_views id = function
  | [] -> ()
  | view :: rest ->
      if Ids.Pane_id.equal (Pane.id (View.pane view)) id then View.pump view;
      pump_views id rest

let event t id (event : Pane_proc.event) =
  match event with
  | Title ->
      if has_clients t.clients then
        Option.iter
          (fun pane ->
            broadcast t (fun () ->
                Protocol.Event.client_to_json
                  (Title { pane = id; title = Pane_proc.title (Pane.proc pane) })))
          (Panes.find t.panes id)
  | Pwd ->
      if has_clients t.clients then
        Option.iter
          (fun pane ->
            broadcast t (fun () ->
                Protocol.Event.client_to_json
                  (Pwd { pane = id; pwd = Pane_proc.cwd (Pane.proc pane) })))
          (Panes.find t.panes id)
  | Dead dead -> (
      broadcast t (fun () -> Protocol.Event.client_to_json (Dead { pane = id; dead }));
      match dead.cause with Failed _ -> close_views t id | Exited _ | Signaled _ -> ())
  | Output -> (
      let leading = t.activity () in
      match Panes.find t.panes id with
      | Some pane when leading || not (Pane_proc.busy (Pane.proc pane)) ->
          ignore (Pane_proc.scan (Pane.proc pane) : bool);
          pump_views id t.views
      | Some _ | None -> ())

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
  ignore (t.activity () : bool)

let remove_view t view = t.views <- List.filter (fun v -> not Stdlib.(v == view)) t.views
let limits t = t.config.limits

let registered t id =
  List.exists (fun c -> Ids.Client_id.equal (Client.id c) id && Client.registered c) t.clients
