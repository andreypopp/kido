type active = {
  mutable pane : string option;
  mutable size : Config.size;
  mutable focused : bool;
  ignore_size : bool;
}

type t = { id : string; connection : Connection.t; mutable state : active option }

let create id connection = { id; connection; state = None }
let id t = t.id
let connection t = t.connection
let registered t = Option.is_some t.state

let claim panes clients t active =
  let focused_elsewhere =
    List.exists
      (fun c ->
        (not (String.equal c.id t.id))
        &&
        match c.state with
        | Some peer ->
            peer.focused && (not peer.ignore_size)
            && Option.equal String.equal peer.pane active.pane
        | None -> false)
      clients
  in
  if (not active.ignore_size) && (active.focused || not focused_elsewhere) then
    Option.iter
      (fun id ->
        Option.iter (fun p -> Pane.claim p ~client:t.id ~size:active.size) (Panes.find panes id))
      active.pane

let receive panes ~clients t input =
  try
    (match (t.state, input) with
    | None, Protocol.Hello hello ->
        if not (String.equal hello.kind "terminal" || String.equal hello.kind "app") then
          invalid_arg "invalid client kind";
        if not (Config.valid_size hello.size) then invalid_arg "invalid size";
        let active =
          {
            pane = hello.pane;
            size = hello.size;
            focused = hello.focused;
            ignore_size = hello.ignore_size;
          }
        in
        t.state <- Some active;
        claim panes clients t active;
        Connection.json t.connection (Protocol.yojson_of_welcome { welcome = { client = t.id } });
        Connection.json t.connection
          (Protocol.yojson_of_topology { topology = { panes = Panes.rows panes } })
    | None, _ -> invalid_arg "hello must be first"
    | Some active, Select id ->
        if Option.is_none (Panes.find panes id) then invalid_arg "pane not found";
        active.pane <- Some id;
        claim panes clients t active
    | Some active, Size size ->
        if not (Config.valid_size size) then invalid_arg "invalid size";
        active.size <- size;
        Option.iter
          (fun id ->
            Option.iter
              (fun p ->
                if Option.equal String.equal (Pane.sizer p) (Some t.id) then Pane.resize p size)
              (Panes.find panes id))
          active.pane
    | Some active, Focused focused ->
        active.focused <- focused;
        if focused then claim panes clients t active
    | Some _, Hello _ -> invalid_arg "hello already received");
    Ok ()
  with Invalid_argument message -> Error message
