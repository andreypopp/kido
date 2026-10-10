let value = "2.1"
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
  let identifier parse = function
    | Some (`String s) -> ( try Some (parse s) with Invalid_argument _ -> None)
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
                  ( identifier Tmux.session_id_of_string
                      (List.assoc_opt ~eq:String.equal "session" location),
                    identifier Tmux.window_id_of_string
                      (List.assoc_opt ~eq:String.equal "window" location),
                    identifier Tmux.pane_id_of_string
                      (List.assoc_opt ~eq:String.equal "pane" location) )
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
            | [ ("new-window", value) ] ->
                Option.map
                  (fun window -> Any (Sidebar.New_window window))
                  (identifier Tmux.window_id_of_string (Some value))
            | [ ("select-session", value) ] ->
                Option.map
                  (fun session -> Any (Sidebar.Select_session session))
                  (identifier Tmux.session_id_of_string (Some value))
            | [ ("new-session", `Bool true) ] -> Some (Any Sidebar.New_session)
            | [ ("select-window", `Assoc target) ] when List.length target = 2 -> (
                match
                  ( identifier Tmux.session_id_of_string
                      (List.assoc_opt ~eq:String.equal "session" target),
                    identifier Tmux.window_id_of_string
                      (List.assoc_opt ~eq:String.equal "window" target) )
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

let location (c : Sidebar.client) =
  `Assoc
    [
      ("session", Tmux.yojson_of_session_id c.session);
      ("window", Tmux.yojson_of_window_id c.window);
      ("pane", Tmux.yojson_of_pane_id c.pane);
    ]

let result_reply id key encode = function
  | Error e -> error id e
  | Ok value -> `Assoc [ ("reply", `Assoc [ ("id", `Int id); (key, encode value) ]) ]

let switched =
  Option.map_or ~default:`Null (fun (target : Sidebar.switched) ->
      `Assoc
        [
          ("session", Tmux.yojson_of_session_id target.session);
          ("window", Tmux.yojson_of_window_id target.window);
        ])

let reply : type a. int -> a Sidebar.request -> a -> Yojson.Safe.t =
 fun id request response ->
  match request with
  | Sidebar.Switch_window _ -> result_reply id "switched" switched response
  | Sidebar.Switch_session _ -> result_reply id "switched" switched response
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
            ("id", Tmux.yojson_of_window_id g.first.row.window);
            ("window", Tmux.yojson_of_window_id g.first.row.window);
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
        ("id", Tmux.yojson_of_pane_id r.pane);
        ("pane", Tmux.yojson_of_pane_id r.pane);
        ("window", Tmux.yojson_of_window_id r.window);
        ("indicator", indicator_json r.indicator);
        ( "program_status",
          Option.map_or
            ~default:(`Assoc [ ("serial", `Int 0); ("records", `List []) ])
            Tmux.Program_status.yojson_of_t
            (Option.map
               (fun (p : Tmux_pane.t) -> p.program_status)
               (Tmux_pane.find m.snap.panes r.pane)) );
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
                       ("created", Timestamp.yojson_of_t a.created);
                       ("pane", Option.map_or ~default:`Null Tmux.yojson_of_pane_id pane);
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
                       ("id", Tmux.yojson_of_session_id s.id);
                       ("name", `String s.name);
                       ("current", `Bool s.current);
                       ("nodes", `List (List.map node s.nodes));
                     ])
                 m.sessions) );
        ])
    m.client

let%test_module "Tests" =
  (module struct
    open View_fixture

    let opts ?(dir = temp ()) () : Sidebar.options =
      {
        interval = Sidebar.default_interval;
        client = "";
        tmux = Tmux.create ();
        dir;
        threshold = 180.;
        grace = 30.;
      }

    let model ?(dir = temp ()) ?(clock = ref test_at) ?(started = test_at -. 3600.) () =
      let m = Sidebar.make ~now:(fun () -> !clock) (opts ~dir ()) in
      { m with started; at = !clock }

    let prepared ~dir panes states =
      fst
        (Sidebar.step (model ~dir ())
           {
             Sidebar.empty with
             client = client "alpha";
             active = Some (Tmux.pane_id_of_string "%1");
             panes = with_programs states panes;
             states;
             lingering = Sidebar.lingering_subagents ~dir panes Sidebar.String_map.empty;
           })

    (* The feed's wire format: key order, the indicator encoding (null for an empty field, idle for an
   integrated idle shell, gone with its outcome), a running bash run's start, untruncated spans with their roles, attention from
   the predicate n/N walk, and rows grouped under their own session. *)
    let%expect_test "a snapshot as the feed sends it" =
      let dir = temp () in
      let id = new_run ~dir "helper" in
      ignore
        (Subrun.record_outcome ~dir
           (Result.get_exn (Subrun.parse_id id))
           { result = Failed; text = ""; at = None });
      let panes =
        [
          pane ~session:"alpha" ~window:"@1" ~title:"orchestrator" ~active:true "%1";
          pane ~session:"alpha" ~window:"@1" ~command:"bash" ~prompt:test_at "%2";
          pane ~session:"alpha" ~window:"@1" ~command:"vim" ~alternate:true "%3";
          pane ~session:"alpha" ~window:"@4" ~dead_at:1. ~run:id "%4";
          pane ~session:"alpha" ~window:"@6" ~run:(new_run ~dir ~kind:Bash "build") "%6";
        ]
        @ [
            {
              (pane ~session:"beta" ~window:"@5" ~title:"asker" "%5") with
              session_id = Tmux.session_id_of_string "$1";
            };
          ]
      in
      let states =
        states
          [
            ("%1", ("root", session ~activity:"reading the contract" ""));
            ("%5", ("asker", session ""));
          ]
      in
      let m = prepared ~dir panes states in
      let json m = Option.get_exn_or "client" (snapshot m) in
      print_endline (Yojson.Safe.pretty_to_string (json m));
      print_endline
        (Yojson.Safe.to_string
           (json
              (fst
                 (Sidebar.step m
                    { Sidebar.empty with client = m.snap.client; err = Some "tmux: gone" }))));
      [%expect
        {|
    {
      "v": 2,
      "client": { "session": "$0", "window": "@1", "pane": "%1" },
      "asks": [],
      "error": null,
      "sessions": [
        {
          "id": "$0",
          "name": "alpha",
          "current": true,
          "nodes": [
            {
              "kind": "window",
              "id": "@1",
              "window": "@1",
              "name": "",
              "children": [
                {
                  "kind": "agent",
                  "id": "%1",
                  "pane": "%1",
                  "window": "@1",
                  "indicator": { "kind": "running" },
                  "program_status": {
                    "serial": 1,
                    "records": [ { "id": "", "state": "working", "app": "pi" } ]
                  },
                  "title": [ { "text": "orchestrator", "role": "plain" } ],
                  "tail": [ { "text": "reading the contract", "role": "dim" } ],
                  "run": null,
                  "started": null,
                  "attention": false,
                  "children": []
                },
                {
                  "kind": "shell",
                  "id": "%2",
                  "pane": "%2",
                  "window": "@1",
                  "indicator": { "kind": "idle" },
                  "program_status": { "serial": 0, "records": [] },
                  "title": [ { "text": "bash", "role": "proc" } ],
                  "tail": [],
                  "run": null,
                  "started": null,
                  "attention": false,
                  "children": []
                },
                {
                  "kind": "shell",
                  "id": "%3",
                  "pane": "%3",
                  "window": "@1",
                  "indicator": null,
                  "program_status": { "serial": 0, "records": [] },
                  "title": [ { "text": "vim", "role": "proc" } ],
                  "tail": [],
                  "run": null,
                  "started": null,
                  "attention": false,
                  "children": []
                }
              ]
            },
            {
              "kind": "agent",
              "id": "%4",
              "pane": "%4",
              "window": "@4",
              "indicator": { "kind": "gone", "outcome": "failed" },
              "program_status": { "serial": 0, "records": [] },
              "title": [ { "text": "helper", "role": "dim" } ],
              "tail": [ { "text": "failed", "role": "dim" } ],
              "run": "agent",
              "started": null,
              "attention": false,
              "children": []
            },
            {
              "kind": "run",
              "id": "%6",
              "pane": "%6",
              "window": "@6",
              "indicator": { "kind": "running" },
              "program_status": { "serial": 0, "records": [] },
              "title": [ { "text": "build", "role": "plain" } ],
              "tail": [],
              "run": "bash",
              "started": 1700000000.0,
              "attention": false,
              "children": []
            }
          ]
        },
        {
          "id": "$1",
          "name": "beta",
          "current": false,
          "nodes": [
            {
              "kind": "agent",
              "id": "%5",
              "pane": "%5",
              "window": "@5",
              "indicator": { "kind": "running" },
              "program_status": {
                "serial": 1,
                "records": [ { "id": "", "state": "working", "app": "pi" } ]
              },
              "title": [ { "text": "asker", "role": "plain" } ],
              "tail": [],
              "run": null,
              "started": null,
              "attention": false,
              "children": []
            }
          ]
        }
      ]
    }
    {"v":2,"client":{"session":"$0","window":"@1","pane":"%1"},"asks":[],"error":"tmux: gone","sessions":[]}
    |}]

    let%expect_test "feed nodes nest a two-pane subagent window and a one-pane run" =
      let dir = temp () in
      let run = new_run ~dir ~parent:"root" ~kind:Bash "build" in
      let panes =
        [
          pane ~session:"alpha" ~window:"@1" ~title:"root" ~active:true "%1";
          pane ~session:"alpha" ~window:"@2" ~title:"kid" "%2";
          pane ~session:"alpha" ~window:"@2" ~command:"bash" "%3";
          pane ~session:"alpha" ~window:"@3" ~run "%4";
        ]
      in
      let states =
        states [ ("%1", ("root", session "")); ("%2", ("kid", session ~parent:"root" "")) ]
      in
      let m = prepared ~dir panes states in
      print_endline (Yojson.Safe.pretty_to_string (Option.get_exn_or "client" (snapshot m)));
      [%expect
        {|
    {
      "v": 2,
      "client": { "session": "$0", "window": "@1", "pane": "%1" },
      "asks": [],
      "error": null,
      "sessions": [
        {
          "id": "$0",
          "name": "alpha",
          "current": true,
          "nodes": [
            {
              "kind": "agent",
              "id": "%1",
              "pane": "%1",
              "window": "@1",
              "indicator": { "kind": "running" },
              "program_status": {
                "serial": 1,
                "records": [ { "id": "", "state": "working", "app": "pi" } ]
              },
              "title": [ { "text": "root", "role": "plain" } ],
              "tail": [],
              "run": null,
              "started": null,
              "attention": false,
              "children": [
                {
                  "kind": "window",
                  "id": "@2",
                  "window": "@2",
                  "name": "",
                  "children": [
                    {
                      "kind": "agent",
                      "id": "%2",
                      "pane": "%2",
                      "window": "@2",
                      "indicator": { "kind": "running" },
                      "program_status": {
                        "serial": 1,
                        "records": [
                          { "id": "", "state": "working", "app": "pi" }
                        ]
                      },
                      "title": [ { "text": "kid", "role": "plain" } ],
                      "tail": [],
                      "run": null,
                      "started": null,
                      "attention": false,
                      "children": []
                    },
                    {
                      "kind": "shell",
                      "id": "%3",
                      "pane": "%3",
                      "window": "@2",
                      "indicator": null,
                      "program_status": { "serial": 0, "records": [] },
                      "title": [ { "text": "bash", "role": "proc" } ],
                      "tail": [],
                      "run": null,
                      "started": null,
                      "attention": false,
                      "children": []
                    }
                  ]
                },
                {
                  "kind": "run",
                  "id": "%4",
                  "pane": "%4",
                  "window": "@3",
                  "indicator": { "kind": "running" },
                  "program_status": { "serial": 0, "records": [] },
                  "title": [ { "text": "build", "role": "plain" } ],
                  "tail": [],
                  "run": "bash",
                  "started": 1700000000.0,
                  "attention": false,
                  "children": []
                }
              ]
            }
          ]
        }
      ]
    }
    |}]

    let%expect_test "rpc decoder" =
      List.iter
        (fun line ->
          match decode line with
          | Request (id, Any request) -> (
              let show kind direction =
                Printf.printf "%d:%s:%s\n" id kind
                  (match direction with Sidebar.Next -> "next" | Prev -> "prev")
              in
              match request with
              | Sidebar.Switch_window direction -> show "window" direction
              | Sidebar.Switch_session direction -> show "session" direction
              | Sidebar.New_window _ -> Printf.printf "%d:new-window\n" id
              | Sidebar.New_session -> Printf.printf "%d:new-session\n" id
              | Sidebar.Select_session _ -> Printf.printf "%d:select-session\n" id
              | Sidebar.Select_window _ -> Printf.printf "%d:select-window\n" id
              | Sidebar.Jump _ -> Printf.printf "%d:jump\n" id
              | Sidebar.Activate_ask _ -> Printf.printf "%d:activate\n" id
              | Sidebar.Delete_ask _ -> Printf.printf "%d:delete\n" id
              | Sidebar.Release_side_focus -> Printf.printf "%d:release\n" id)
          | Invalid (id, error) -> Printf.printf "%d:%s\n" id error
          | Ignored -> print_endline "ignored")
        [
          {|{"filter":"hello"}|};
          {|{"filter":""}|};
          {|{"id":7,"switch-window":{"direction":"next"},"extra":true}|};
          {|{"id":8,"switch-window":{"direction":"prev"}}|};
          {|{"id":9,"switch-session":{"direction":"next"}}|};
          {|{"id":10,"switch-session":{"direction":"prev"}}|};
          {|{"id":11,"switch-window":{"direction":"other"}}|};
          {|{"id":12,"switch-window":{"direction":"next","extra":true}}|};
          {|{"id":13,"switch-window":{"direction":"next"},"switch-session":{"direction":"prev"}}|};
          {|{"id":14,"filter":"hello"}|};
          {|{"id":15,"unknown":true}|};
          {|{"id":"16","switch-window":{"direction":"next"}}|};
          {|{"switch-window":{"direction":"next"}}|};
          {|{"filter":"hello","extra":true}|};
          {|[]|};
          "invalid";
        ];
      [%expect
        {|
    ignored
    ignored
    7:window:next
    8:window:prev
    9:session:next
    10:session:prev
    11:invalid or unknown request
    12:invalid or unknown request
    13:invalid or unknown request
    14:invalid or unknown request
    15:invalid or unknown request
    ignored
    ignored
    ignored
    ignored
    ignored
    |}]

    let%expect_test "rpc surface" =
      let emit json = print_endline (Yojson.Safe.to_string json) in
      print_endline value;
      List.iter (fun stamp -> emit (hello stamp)) [ Some value; Some "other"; None ];
      List.iter
        (fun result -> emit (reply 7 (Sidebar.Switch_window Next) result))
        [
          Ok
            (Some
               {
                 Sidebar.session = Tmux.session_id_of_string "$3";
                 window = Tmux.window_id_of_string "@12";
               });
          Ok None;
          Error "invalid or unknown request";
        ];
      let opts : Sidebar.options =
        {
          interval = 0.1;
          client = "app";
          tmux = Tmux.create ();
          dir = "/unused";
          threshold = 180.;
          grace = 30.;
        }
      in
      let roles : Sidebar.role list =
        [ `Plain; `Current; `Proc; `Dim; `Err; `Running; `Waiting; `Done; `Stalled ]
      in
      let title = List.map (fun role -> { Sidebar.text = "span"; role }) roles in
      let indicators : Sidebar.indicator option list =
        [
          None;
          Some (Status Running);
          Some (Status Waiting);
          Some (Status Idle);
          Some Unknown;
          Some Done;
          Some Failed;
          Some Stalled;
          Some (Gone None);
          Some (Gone (Some Completed));
          Some (Gone (Some Failed));
          Some (Gone (Some Died));
          Some (Gone (Some Stopped));
        ]
      in
      let items =
        List.mapi
          (fun i indicator ->
            {
              Sidebar.row =
                {
                  pane = Tmux.pane_id_of_string ("%" ^ string_of_int i);
                  window = Tmux.window_id_of_string "@1";
                  kind = (match i mod 4 with 0 -> Agent | 1 -> Run | 2 -> Ssh | _ -> Shell);
                  indicator;
                  title = (if i = 0 then title else []);
                  caption = (if i = 0 then Text title else Elapsed 100.);
                  run =
                    (if i = List.length indicators - 1 then None
                     else
                       Some
                         {
                           kind = (match i mod 3 with 0 -> Subrun.Agent | 1 -> Bash | _ -> Stream);
                           started = (if i mod 2 = 0 then Some 100. else None);
                         });
                };
              program_rows =
                [ { id = "child"; indicator = Done; title = "child"; caption = "done" } ];
              children = [];
            })
          indicators
      in
      let first = List.hd items in
      let nodes =
        [
          Sidebar.Group { name = "window"; first; rest = List.tl items };
          Sidebar.Item { first with children = [ Sidebar.Item first ] };
        ]
      in
      let m = Sidebar.make ~now:(fun () -> 100.) opts in
      let m =
        {
          m with
          client =
            Some
              {
                session = Tmux.session_id_of_string "$0";
                window = Tmux.window_id_of_string "@1";
                pane = Tmux.pane_id_of_string "%0";
              };
          snap =
            {
              Sidebar.empty with
              states =
                Tmux.Pane_map.singleton (Tmux.pane_id_of_string "%0")
                  ("agent", Test_fixture.session ~agent:State.Pi ());
            };
          sessions =
            [ { id = Tmux.session_id_of_string "$0"; name = "session"; current = true; nodes } ];
        }
      in
      emit (Option.get_exn_or "snapshot" (snapshot m));
      emit
        (Option.get_exn_or "error snapshot"
           (snapshot
              { m with snap = { Sidebar.empty with err = Some "tmux: gone" }; sessions = [] }));
      [%expect
        {|
    2.1
    {"hello":{"protocol":"2.1"}}
    {"hello":{"protocol":"2.1","server":"other"}}
    {"hello":{"protocol":"2.1","server":null}}
    {"reply":{"id":7,"switched":{"session":"$3","window":"@12"}}}
    {"reply":{"id":7,"switched":null}}
    {"reply":{"id":7,"error":"invalid or unknown request"}}
    {"v":2,"client":{"session":"$0","window":"@1","pane":"%0"},"asks":[],"error":null,"sessions":[{"id":"$0","name":"session","current":true,"nodes":[{"kind":"window","id":"@1","window":"@1","name":"window","children":[{"kind":"agent","id":"%0","pane":"%0","window":"@1","indicator":null,"program_status":{"serial":0,"records":[]},"title":[{"text":"span","role":"plain"},{"text":"span","role":"current"},{"text":"span","role":"proc"},{"text":"span","role":"dim"},{"text":"span","role":"err"},{"text":"span","role":"running"},{"text":"span","role":"waiting"},{"text":"span","role":"done"},{"text":"span","role":"stalled"}],"tail":[{"text":"span","role":"plain"},{"text":"span","role":"current"},{"text":"span","role":"proc"},{"text":"span","role":"dim"},{"text":"span","role":"err"},{"text":"span","role":"running"},{"text":"span","role":"waiting"},{"text":"span","role":"done"},{"text":"span","role":"stalled"}],"run":"agent","started":100.0,"attention":false,"children":[]},{"kind":"run","id":"%1","pane":"%1","window":"@1","indicator":{"kind":"running"},"program_status":{"serial":0,"records":[]},"title":[],"tail":[],"run":"bash","started":null,"attention":false,"children":[]},{"kind":"ssh","id":"%2","pane":"%2","window":"@1","indicator":{"kind":"waiting"},"program_status":{"serial":0,"records":[]},"title":[],"tail":[],"run":"stream","started":100.0,"attention":false,"children":[]},{"kind":"shell","id":"%3","pane":"%3","window":"@1","indicator":{"kind":"idle"},"program_status":{"serial":0,"records":[]},"title":[],"tail":[],"run":"agent","started":null,"attention":false,"children":[]},{"kind":"agent","id":"%4","pane":"%4","window":"@1","indicator":{"kind":"unknown"},"program_status":{"serial":0,"records":[]},"title":[],"tail":[],"run":"bash","started":100.0,"attention":false,"children":[]},{"kind":"run","id":"%5","pane":"%5","window":"@1","indicator":{"kind":"done"},"program_status":{"serial":0,"records":[]},"title":[],"tail":[],"run":"stream","started":null,"attention":false,"children":[]},{"kind":"ssh","id":"%6","pane":"%6","window":"@1","indicator":{"kind":"failed"},"program_status":{"serial":0,"records":[]},"title":[],"tail":[],"run":"agent","started":100.0,"attention":false,"children":[]},{"kind":"shell","id":"%7","pane":"%7","window":"@1","indicator":{"kind":"stalled"},"program_status":{"serial":0,"records":[]},"title":[],"tail":[],"run":"bash","started":null,"attention":false,"children":[]},{"kind":"agent","id":"%8","pane":"%8","window":"@1","indicator":{"kind":"gone","outcome":null},"program_status":{"serial":0,"records":[]},"title":[],"tail":[],"run":"stream","started":100.0,"attention":false,"children":[]},{"kind":"run","id":"%9","pane":"%9","window":"@1","indicator":{"kind":"gone","outcome":"completed"},"program_status":{"serial":0,"records":[]},"title":[],"tail":[],"run":"agent","started":null,"attention":false,"children":[]},{"kind":"ssh","id":"%10","pane":"%10","window":"@1","indicator":{"kind":"gone","outcome":"failed"},"program_status":{"serial":0,"records":[]},"title":[],"tail":[],"run":"bash","started":100.0,"attention":false,"children":[]},{"kind":"shell","id":"%11","pane":"%11","window":"@1","indicator":{"kind":"gone","outcome":"died"},"program_status":{"serial":0,"records":[]},"title":[],"tail":[],"run":"stream","started":null,"attention":false,"children":[]},{"kind":"agent","id":"%12","pane":"%12","window":"@1","indicator":{"kind":"gone","outcome":"stopped"},"program_status":{"serial":0,"records":[]},"title":[],"tail":[],"run":null,"started":null,"attention":false,"children":[]}]},{"kind":"agent","id":"%0","pane":"%0","window":"@1","indicator":null,"program_status":{"serial":0,"records":[]},"title":[{"text":"span","role":"plain"},{"text":"span","role":"current"},{"text":"span","role":"proc"},{"text":"span","role":"dim"},{"text":"span","role":"err"},{"text":"span","role":"running"},{"text":"span","role":"waiting"},{"text":"span","role":"done"},{"text":"span","role":"stalled"}],"tail":[{"text":"span","role":"plain"},{"text":"span","role":"current"},{"text":"span","role":"proc"},{"text":"span","role":"dim"},{"text":"span","role":"err"},{"text":"span","role":"running"},{"text":"span","role":"waiting"},{"text":"span","role":"done"},{"text":"span","role":"stalled"}],"run":"agent","started":100.0,"attention":false,"children":[{"kind":"agent","id":"%0","pane":"%0","window":"@1","indicator":null,"program_status":{"serial":0,"records":[]},"title":[{"text":"span","role":"plain"},{"text":"span","role":"current"},{"text":"span","role":"proc"},{"text":"span","role":"dim"},{"text":"span","role":"err"},{"text":"span","role":"running"},{"text":"span","role":"waiting"},{"text":"span","role":"done"},{"text":"span","role":"stalled"}],"tail":[{"text":"span","role":"plain"},{"text":"span","role":"current"},{"text":"span","role":"proc"},{"text":"span","role":"dim"},{"text":"span","role":"err"},{"text":"span","role":"running"},{"text":"span","role":"waiting"},{"text":"span","role":"done"},{"text":"span","role":"stalled"}],"run":"agent","started":100.0,"attention":false,"children":[]}]}]}]}
    {"v":2,"client":{"session":"$0","window":"@1","pane":"%0"},"asks":[],"error":"tmux: gone","sessions":[]}
    |}]
  end)
