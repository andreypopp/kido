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
  let identifier prefix = function
    | Some (`String s)
      when String.length s > 1
           && Char.equal s.[0] prefix
           && String.for_all
                (fun c -> Char.compare c '0' >= 0 && Char.compare c '9' <= 0)
                (String.sub s 1 (String.length s - 1)) ->
        Some s
    | _ -> None
  in
  match Yojson.Safe.from_string line with
  | `Assoc fields -> (
      match List.assoc_opt ~eq:String.equal "id" fields with
      | Some (`Int id) -> (
          let request =
            match
              List.filter
                (fun (key, _) ->
                  List.mem ~eq:String.equal key
                    [
                      "switch-window";
                      "switch-session";
                      "jump";
                      "new-window";
                      "new-session";
                      "select-window";
                      "select-session";
                      "activate-ask";
                      "delete-ask";
                      "release-side-focus";
                    ])
                fields
            with
            | [ (key, `Assoc [ ("direction", `String direction) ]) ]
              when (String.equal key "switch-window" || String.equal key "switch-session")
                   && (String.equal direction "next" || String.equal direction "prev") ->
                let direction =
                  if String.equal direction "next" then Sidebar.Next else Sidebar.Prev
                in
                Some
                  (if String.equal key "switch-window" then Any (Sidebar.Switch_window direction)
                   else Any (Sidebar.Switch_session direction))
            | [ ("jump", `Assoc location) ] when List.length location = 3 -> (
                match
                  ( identifier '$' (List.assoc_opt ~eq:String.equal "session" location),
                    identifier '@' (List.assoc_opt ~eq:String.equal "window" location),
                    identifier '%' (List.assoc_opt ~eq:String.equal "pane" location) )
                with
                | Some session, Some window, Some pane ->
                    Some (Any (Sidebar.Jump { session; window; pane }))
                | _ -> None)
            | [ (key, `String id) ]
              when String.equal key "activate-ask" || String.equal key "delete-ask" ->
                Result.to_opt
                  (Result.map
                     (fun id ->
                       if String.equal key "activate-ask" then Any (Sidebar.Activate_ask id)
                       else Any (Sidebar.Delete_ask id))
                     (Ask.parse_id id))
            | [ (key, value) ]
              when String.equal key "new-window" || String.equal key "select-session" ->
                Option.map
                  (fun session ->
                    if String.equal key "new-window" then Any (Sidebar.New_window session)
                    else Any (Sidebar.Select_session session))
                  (identifier '$' (Some value))
            | [ ("new-session", `Bool true) ] -> Some (Any Sidebar.New_session)
            | [ ("select-window", `Assoc target) ] when List.length target = 2 -> (
                match
                  ( identifier '$' (List.assoc_opt ~eq:String.equal "session" target),
                    identifier '@' (List.assoc_opt ~eq:String.equal "window" target) )
                with
                | Some session, Some window ->
                    Some (Any (Sidebar.Select_window { session; window }))
                | _ -> None)
            | [ ("release-side-focus", `Bool true) ] -> Some (Any Sidebar.Release_side_focus)
            | _ -> None
          in
          match request with
          | Some request -> Request (id, request)
          | None -> Invalid (id, "invalid or unknown request"))
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

let location (c : Sidebar.client) =
  `Assoc [ ("session", `String c.session); ("window", `String c.window); ("pane", `String c.pane) ]

let result_reply id key encode = function
  | Error e -> error id e
  | Ok value -> `Assoc [ ("reply", `Assoc [ ("id", `Int id); (key, encode value) ]) ]

let reply : type a. int -> a Sidebar.request -> a -> Yojson.Safe.t =
 fun id request response ->
  match request with
  | Sidebar.Switch_window _ -> switched_reply id response
  | Sidebar.Switch_session _ -> switched_reply id response
  | Sidebar.New_window _ -> result_reply id "created" location response
  | Sidebar.New_session -> result_reply id "created" location response
  | Sidebar.Select_window _ -> result_reply id "selected" location response
  | Sidebar.Select_session _ -> result_reply id "selected" location response
  | Sidebar.Jump _ -> result_reply id "jumped" location response
  | Sidebar.Activate_ask _ -> result_reply id "activated" location response
  | Sidebar.Delete_ask _ -> result_reply id "deleted" (fun () -> `Bool true) response
  | Sidebar.Release_side_focus -> result_reply id "released" (fun () -> `Bool true) response

open Sidebar

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
        ( "run",
          Option.map_or ~default:`Null
            (fun (r : run) -> `String (Subrun.string_of_kind r.kind))
            r.run );
        ( "started",
          Option.map_or ~default:`Null
            (fun t -> `Float t)
            (Option.flat_map (fun (r : run) -> r.started) r.run) );
        ("attention", `Bool (attention m r.pane));
        ("children", `List (List.map node i.children));
      ]
  in
  Option.map
    (fun (c : client) ->
      `Assoc
        [
          ("v", `Int 2);
          ("client", location c);
          ( "asks",
            `List
              (List.map
                 (fun (entry : Sidebar.ask) ->
                   let a = entry.ask in
                   let pane =
                     match entry.target with
                     | Live pane -> Some pane
                     | Revivable | Unavailable -> None
                   in
                   `Assoc
                     [
                       ("id", `String (Ask.string_of_id a.id));
                       ("session", `String a.session);
                       ("name", `String a.name);
                       ("text", `String a.text);
                       ("created", Timestamp.to_yojson a.created);
                       ("pane", Option.map_or ~default:`Null (fun p -> `String p) pane);
                       ("ended", `Bool (Option.is_none pane));
                       ( "revivable",
                         `Bool
                           (match entry.target with
                           | Revivable -> true
                           | Live _ | Unavailable -> false) );
                     ])
                 m.snap.asks) );
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
