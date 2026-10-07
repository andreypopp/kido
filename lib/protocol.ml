let value = "1.1"
let matches server = Option.equal String.equal server (Some value)

let hello server =
  `Assoc
    [
      ( "hello",
        `Assoc
          ([ ("protocol", `String value) ]
          @
          if matches server then []
          else [ ("server", Option.map_or ~default:`Null (fun s -> `String s) server) ]) );
    ]

type any = Any : 'a Sidebar.request -> any
type input = Request of int * any | Invalid of int * string | Ignored

let decode line =
  match Yojson.Safe.from_string line with
  | `Assoc fields -> (
      match
        ( List.assoc_opt ~eq:String.equal "id" fields,
          List.assoc_opt ~eq:String.equal "switch-window" fields,
          List.assoc_opt ~eq:String.equal "switch-session" fields )
      with
      | Some (`Int id), Some (`Assoc [ ("direction", `String direction) ]), None
      | Some (`Int id), None, Some (`Assoc [ ("direction", `String direction) ])
        when String.equal direction "next" || String.equal direction "prev" ->
          let direction = if String.equal direction "next" then Sidebar.Next else Sidebar.Prev in
          Request
            ( id,
              if List.mem_assoc ~eq:String.equal "switch-window" fields then
                Any (Sidebar.Switch_window direction)
              else Any (Sidebar.Switch_session direction) )
      | Some (`Int id), _, _ -> Invalid (id, "invalid or unknown request")
      | _ -> Ignored)
  | _ -> Ignored
  | exception Yojson.Json_error _ -> Ignored

let error id message = `Assoc [ ("reply", `Assoc [ ("id", `Int id); ("error", `String message) ]) ]

let switched_reply id result =
  `Assoc
    [
      ( "reply",
        `Assoc
          (("id", `Int id)
          :: [
               (match result with
               | Error e -> ("error", `String e)
               | Ok target ->
                   ( "switched",
                     Option.map_or ~default:`Null
                       (fun (target : Sidebar.switched) ->
                         `Assoc
                           [
                             ("session", `String target.session); ("window", `String target.window);
                           ])
                       target ));
             ]) );
    ]

let reply : type a. int -> a Sidebar.request -> a -> Yojson.Safe.t =
 fun id request response ->
  match request with
  | Sidebar.Switch_window _ -> switched_reply id response
  | Sidebar.Switch_session _ -> switched_reply id response

open Sidebar
module P = Tmux.Pane

let role_name : role -> string = function
  | `Plain -> "plain"
  | `Current -> "current"
  | `Proc -> "proc"
  | `Dim -> "dim"
  | `Err -> "err"
  | `Running -> "running"
  | `Waiting -> "waiting"
  | `Compacting -> "compacting"
  | `Done -> "done"
  | `Stalled -> "stalled"

let kind = function
  | Status s -> State.string_of_status s
  | Unknown -> "unknown"
  | Done -> "done"
  | Failed -> "failed"
  | Stalled -> "stalled"
  | Gone _ -> "gone"

let indicator_json = function
  | None -> `Null
  | Some i ->
      `Assoc
        (("kind", `String (kind i))
        ::
        (match i with
        | Gone o ->
            [
              ( "outcome",
                Option.map_or ~default:`Null (fun o -> `String (Subrun.string_of_result o)) o );
            ]
        | Status _ | Unknown | Done | Failed | Stalled -> []))

let snapshot (m : model) =
  let panes =
    List.fold_left
      (fun panes (p : P.t) ->
        if String_map.mem p.pane_id panes then panes else String_map.add p.pane_id p panes)
      String_map.empty m.snap.panes
  in
  let spans l =
    `List
      (List.map
         (fun s -> `Assoc [ ("text", `String s.text); ("role", `String (role_name s.role)) ])
         l)
  in
  let rec node = function
    | Group g ->
        `Assoc
          [
            ("kind", `String "window");
            ("id", `String g.first.row.window);
            ("window", `String g.first.row.window);
            ("name", `String g.name);
            ("children", `List (List.map item (g.first :: g.rest)));
          ]
    | Item i -> item i
  and item i =
    let r = i.row in
    let run, started =
      match String_map.find_opt r.pane panes with
      | Some p -> (
          match Option.flat_map (fun run -> String_map.find_opt run m.snap.lingering) p.run with
          | Some l ->
              ( `String (Subrun.string_of_kind l.kind),
                if Option.is_none p.dead_at && Option.is_none l.outcome then `Float l.started
                else `Null )
          | None -> (`Null, `Null))
      | None -> (`Null, `Null)
    in
    `Assoc
      [
        ( "kind",
          `String
            (match r.kind with Agent -> "agent" | Run -> "run" | Ssh -> "ssh" | Shell -> "shell") );
        ("id", `String r.pane);
        ("pane", `String r.pane);
        ("window", `String r.window);
        ("indicator", indicator_json r.indicator);
        ("title", spans r.title);
        ("tail", spans (match r.caption with Text tail -> tail | Elapsed _ -> []));
        ("run", run);
        ("started", started);
        ("attention", `Bool (attention m r.pane));
        ("children", `List (List.map node i.children));
      ]
  in
  Option.map
    (fun (c : client) ->
      `Assoc
        [
          ("v", `Int 2);
          ( "client",
            `Assoc
              [
                ("session", `String c.session);
                ("window", `String c.window);
                ("pane", `String c.pane);
              ] );
          ("error", Option.map_or ~default:`Null (fun e -> `String e) m.snap.err);
          ( "sessions",
            `List
              (List.map
                 (fun s ->
                   `Assoc
                     [
                       ("id", `String s.id);
                       ("name", `String s.name);
                       ("current", `Bool s.current);
                       ("nodes", `List (List.map node s.nodes));
                     ])
                 m.sessions) );
        ])
    m.client
