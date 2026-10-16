let value = "4.0"
let matches ~expected server = Option.equal String.equal server (Some expected)

let hello ~expected server =
  `Assoc
    [
      ( "hello",
        `Assoc
          (("protocol", `String value)
          ::
          (if matches ~expected server then []
           else
             [
               ("server", Option.map_or ~default:`Null (fun s -> `String s) server);
               ("expected", `String expected);
             ])) );
    ]

type any = Any : 'a Sidebar.request -> any
type input = Request of int * any | Invalid of int * string | Ignored

let decode line =
  let identifier parse = function
    | Some (`String s) -> ( try Some (parse s) with Invalid_argument _ -> None)
    | _ -> None
  in
  let move parse source request =
    let field name = List.assoc_opt ~eq:String.equal name request in
    match
      (identifier parse (field source), identifier parse (field "relative-to"), field "placement")
    with
    | Some source, Some anchor, Some (`String "before") ->
        Some { Sidebar.source; anchor; position = Before }
    | Some source, Some anchor, Some (`String "after") ->
        Some { Sidebar.source; anchor; position = After }
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
                      "reorder-session";
                      "reorder-window";
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
            | [ ("reorder-session", `Assoc request) ] when List.length request = 3 ->
                Option.map
                  (fun move -> Any (Sidebar.Reorder_session move))
                  (move Tmux.session_id_of_string "session" request)
            | [ ("reorder-window", `Assoc request) ] when List.length request = 4 ->
                Option.map2
                  (fun session move -> Any (Sidebar.Reorder_window (session, move)))
                  (identifier Tmux.session_id_of_string
                     (List.assoc_opt ~eq:String.equal "session" request))
                  (move Tmux.window_id_of_string "window" request)
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
  | Sidebar.Reorder_session _ -> result_reply id "reordered" (fun () -> `Bool true) response
  | Sidebar.Reorder_window _ -> result_reply id "reordered" (fun () -> `Bool true) response

open Sidebar

let lifecycle = function
  | Live { status; _ } -> `List [ `String "Live"; Pane_status.yojson_of_kind status ]
  | Ended { result; _ } ->
      `List
        [
          `String "Ended";
          `Assoc
            [
              ("result", `String (Option.map_or ~default:"unknown" Subrun.string_of_result result));
            ];
        ]

let snapshot (m : model) =
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
        ("kind", `String "pane");
        ("id", Tmux.yojson_of_pane_id r.pane);
        ("pane", Tmux.yojson_of_pane_id r.pane);
        ("window", Tmux.yojson_of_window_id r.window);
        ("title", `String r.title);
        ("lifecycle", lifecycle r.lifecycle);
        ( "program_status",
          Tmux.Program_status.yojson_of_t
            (Option.map_or
               ~default:{ Tmux.Program_status.serial = 0; records = [] }
               (fun (p : Tmux_pane.t) -> p.program_status)
               (Tmux_pane.find m.snap.panes r.pane)) );
        ( "run",
          match r.lifecycle with
          | Live { run = Some { kind; _ }; _ } | Ended { run = kind; _ } ->
              `String (Subrun.string_of_kind kind)
          | Live { run = None; _ } -> `Null );
        ( "started",
          match r.lifecycle with
          | Live { run = Some { started; _ }; _ } -> `Float started
          | Live { run = None; _ } | Ended _ -> `Null );
        ("children", `List (List.map node i.children));
      ]
  in
  Option.map2
    (fun server (c : client) ->
      `Assoc
        [
          ("v", `Int 2);
          ("server_instance", Tmux_pane.yojson_of_server server);
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
                       ("name", `String entry.name);
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
    (Option.map snd m.snap.server) m.client

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

    let model ?(dir = temp ()) ?(clock = ref test_at) () =
      let m = Sidebar.make ~now:(fun () -> !clock) (opts ~dir ()) in
      { m with at = !clock }

    let prepared ~dir panes states =
      let panes = with_programs states panes in
      fst
        (Sidebar.step (model ~dir ())
           {
             Sidebar.empty with
             server = Some (1, { Tmux_pane.started_at = test_at |> Float.to_int; pid = 42 });
             client = client "alpha";
             active = Some (Tmux.pane_id_of_string "%1");
             panes;
             states;
             lingering = Sidebar.lingering_subagents ~dir (State.runs ~dir panes);
           })

    (* The feed's wire format: key order, the server identity, plain titles, each pane's lifecycle,
   a running bash run's start, and rows grouped under their own session. *)
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
           (json (fst (Sidebar.step m { m.snap with err = Some "tmux: gone" }))));
      [%expect
        {|
        {
          "v": 2,
          "server_instance": { "started_at": 1700000000, "pid": 42 },
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
                      "kind": "pane",
                      "id": "%1",
                      "pane": "%1",
                      "window": "@1",
                      "title": "orchestrator",
                      "lifecycle": [
                        "Live",
                        [
                          "Pi_agent",
                          {
                            "id": "root",
                            "status": {
                              "since": 1700000000.0,
                              "msg": "reading the contract",
                              "state": [ "Running", { "progress": null } ]
                            }
                          }
                        ]
                      ],
                      "program_status": {
                        "serial": 1,
                        "records": [ { "id": "", "state": "working", "app": "pi" } ]
                      },
                      "run": null,
                      "started": null,
                      "children": []
                    },
                    {
                      "kind": "pane",
                      "id": "%2",
                      "pane": "%2",
                      "window": "@1",
                      "title": "bash",
                      "lifecycle": [
                        "Live",
                        [
                          "Terminal",
                          { "phase": [ "Idle", { "last": null } ], "report": null }
                        ]
                      ],
                      "program_status": { "serial": 0, "records": [] },
                      "run": null,
                      "started": null,
                      "children": []
                    },
                    {
                      "kind": "pane",
                      "id": "%3",
                      "pane": "%3",
                      "window": "@1",
                      "title": "vim",
                      "lifecycle": [
                        "Live",
                        [
                          "Terminal",
                          {
                            "phase": [
                              "Running",
                              { "origin": [ "Unknown" ], "fullscreen": true }
                            ],
                            "report": null
                          }
                        ]
                      ],
                      "program_status": { "serial": 0, "records": [] },
                      "run": null,
                      "started": null,
                      "children": []
                    }
                  ]
                },
                {
                  "kind": "pane",
                  "id": "%4",
                  "pane": "%4",
                  "window": "@4",
                  "title": "helper",
                  "lifecycle": [ "Ended", { "result": "failed" } ],
                  "program_status": { "serial": 0, "records": [] },
                  "run": "agent",
                  "started": null,
                  "children": []
                },
                {
                  "kind": "pane",
                  "id": "%6",
                  "pane": "%6",
                  "window": "@6",
                  "title": "build",
                  "lifecycle": [
                    "Live",
                    [ "Terminal", { "phase": [ "Unknown" ], "report": null } ]
                  ],
                  "program_status": { "serial": 0, "records": [] },
                  "run": "bash",
                  "started": 1700000000.0,
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
                  "kind": "pane",
                  "id": "%5",
                  "pane": "%5",
                  "window": "@5",
                  "title": "asker",
                  "lifecycle": [
                    "Live",
                    [
                      "Pi_agent",
                      {
                        "id": "asker",
                        "status": {
                          "since": 1700000000.0,
                          "msg": null,
                          "state": [ "Running", { "progress": null } ]
                        }
                      }
                    ]
                  ],
                  "program_status": {
                    "serial": 1,
                    "records": [ { "id": "", "state": "working", "app": "pi" } ]
                  },
                  "run": null,
                  "started": null,
                  "children": []
                }
              ]
            }
          ]
        }
        {"v":2,"server_instance":{"started_at":1700000000,"pid":42},"client":{"session":"$0","window":"@1","pane":"%1"},"asks":[],"error":"tmux: gone","sessions":[{"id":"$0","name":"alpha","current":true,"nodes":[{"kind":"window","id":"@1","window":"@1","name":"","children":[{"kind":"pane","id":"%1","pane":"%1","window":"@1","title":"orchestrator","lifecycle":["Live",["Pi_agent",{"id":"root","status":{"since":1700000000.0,"msg":"reading the contract","state":["Running",{"progress":null}]}}]],"program_status":{"serial":1,"records":[{"id":"","state":"working","app":"pi"}]},"run":null,"started":null,"children":[]},{"kind":"pane","id":"%2","pane":"%2","window":"@1","title":"bash","lifecycle":["Live",["Terminal",{"phase":["Idle",{"last":null}],"report":null}]],"program_status":{"serial":0,"records":[]},"run":null,"started":null,"children":[]},{"kind":"pane","id":"%3","pane":"%3","window":"@1","title":"vim","lifecycle":["Live",["Terminal",{"phase":["Running",{"origin":["Unknown"],"fullscreen":true}],"report":null}]],"program_status":{"serial":0,"records":[]},"run":null,"started":null,"children":[]}]},{"kind":"pane","id":"%4","pane":"%4","window":"@4","title":"helper","lifecycle":["Ended",{"result":"failed"}],"program_status":{"serial":0,"records":[]},"run":"agent","started":null,"children":[]},{"kind":"pane","id":"%6","pane":"%6","window":"@6","title":"build","lifecycle":["Live",["Terminal",{"phase":["Unknown"],"report":null}]],"program_status":{"serial":0,"records":[]},"run":"bash","started":1700000000.0,"children":[]}]},{"id":"$1","name":"beta","current":false,"nodes":[{"kind":"pane","id":"%5","pane":"%5","window":"@5","title":"asker","lifecycle":["Live",["Pi_agent",{"id":"asker","status":{"since":1700000000.0,"msg":null,"state":["Running",{"progress":null}]}}]],"program_status":{"serial":1,"records":[{"id":"","state":"working","app":"pi"}]},"run":null,"started":null,"children":[]}]}]}
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
      ignore (Test_fixture.run ~dir ~parent:"root" "kid");
      let states = states [ ("%1", ("root", session "")); ("%2", ("kid", session "")) ] in
      let m = prepared ~dir panes states in
      print_endline (Yojson.Safe.pretty_to_string (Option.get_exn_or "client" (snapshot m)));
      [%expect
        {|
        {
          "v": 2,
          "server_instance": { "started_at": 1700000000, "pid": 42 },
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
                  "kind": "pane",
                  "id": "%1",
                  "pane": "%1",
                  "window": "@1",
                  "title": "root",
                  "lifecycle": [
                    "Live",
                    [
                      "Pi_agent",
                      {
                        "id": "root",
                        "status": {
                          "since": 1700000000.0,
                          "msg": null,
                          "state": [ "Running", { "progress": null } ]
                        }
                      }
                    ]
                  ],
                  "program_status": {
                    "serial": 1,
                    "records": [ { "id": "", "state": "working", "app": "pi" } ]
                  },
                  "run": null,
                  "started": null,
                  "children": [
                    {
                      "kind": "window",
                      "id": "@2",
                      "window": "@2",
                      "name": "",
                      "children": [
                        {
                          "kind": "pane",
                          "id": "%2",
                          "pane": "%2",
                          "window": "@2",
                          "title": "kid",
                          "lifecycle": [
                            "Live",
                            [
                              "Pi_agent",
                              {
                                "id": "kid",
                                "status": {
                                  "since": 1700000000.0,
                                  "msg": null,
                                  "state": [ "Running", { "progress": null } ]
                                }
                              }
                            ]
                          ],
                          "program_status": {
                            "serial": 1,
                            "records": [
                              { "id": "", "state": "working", "app": "pi" }
                            ]
                          },
                          "run": "agent",
                          "started": 1700000000.0,
                          "children": []
                        },
                        {
                          "kind": "pane",
                          "id": "%3",
                          "pane": "%3",
                          "window": "@2",
                          "title": "bash",
                          "lifecycle": [
                            "Live",
                            [
                              "Terminal", { "phase": [ "Unknown" ], "report": null }
                            ]
                          ],
                          "program_status": { "serial": 0, "records": [] },
                          "run": null,
                          "started": null,
                          "children": []
                        }
                      ]
                    },
                    {
                      "kind": "pane",
                      "id": "%4",
                      "pane": "%4",
                      "window": "@3",
                      "title": "build",
                      "lifecycle": [
                        "Live",
                        [ "Terminal", { "phase": [ "Unknown" ], "report": null } ]
                      ],
                      "program_status": { "serial": 0, "records": [] },
                      "run": "bash",
                      "started": 1700000000.0,
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
              | Sidebar.Release_side_focus -> Printf.printf "%d:release\n" id
              | Sidebar.Reorder_session { source; anchor; position } ->
                  Printf.printf "%d:reorder-session %s %s %s\n" id
                    (Tmux.string_of_session_id source)
                    (match position with Before -> "before" | After -> "after")
                    (Tmux.string_of_session_id anchor)
              | Sidebar.Reorder_window (session, { source; anchor; position }) ->
                  Printf.printf "%d:reorder-window %s %s %s %s\n" id
                    (Tmux.string_of_session_id session)
                    (Tmux.string_of_window_id source)
                    (match position with Before -> "before" | After -> "after")
                    (Tmux.string_of_window_id anchor))
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
          {|{"id":51,"reorder-session":{"session":"$3","relative-to":"$1","placement":"before"}}|};
          {|{"id":52,"reorder-window":{"session":"$3","window":"@12","relative-to":"@9","placement":"after"}}|};
          {|{"id":53,"reorder-session":{"session":"$3","relative-to":"$1","placement":"above"}}|};
          {|{"id":54,"reorder-session":{"session":"@3","relative-to":"$1","placement":"before"}}|};
          {|{"id":55,"reorder-window":{"window":"@12","relative-to":"@9","placement":"after"}}|};
          {|{"id":56,"reorder-window":{"session":"$3","window":"@12","relative-to":"@9","placement":"after","x":1}}|};
          {|{"id":57,"reorder-session":{"session":"$3","relative-to":"$1","placement":"before","window":"@1"}}|};
          {|{"id":58,"release-side-focus":{"session":"$3","window":"@12","relative-to":"@9","placement":"after"}}|};
          {|{"id":59,"jump":{"session":"$3","relative-to":"$1","placement":"before"}}|};
          {|{"id":60,"select-window":{"session":"$3","window":"@12","relative-to":"@9","placement":"after"}}|};
          {|{"id":61,"reorder-window":{"session":"$3","relative-to":"$1","placement":"before"}}|};
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
    51:reorder-session $3 before $1
    52:reorder-window $3 @12 after @9
    53:invalid or unknown request
    54:invalid or unknown request
    55:invalid or unknown request
    56:invalid or unknown request
    57:invalid or unknown request
    58:invalid or unknown request
    59:invalid or unknown request
    60:invalid or unknown request
    61:invalid or unknown request
    |}]

    let%expect_test "rpc surface" =
      let emit json = print_endline (Yojson.Safe.to_string json) in
      print_endline value;
      List.iter
        (fun stamp -> emit (hello ~expected:"0123456789ab" stamp))
        [ Some "0123456789ab"; Some "other"; None ];
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
      let move =
        {
          Sidebar.source = Tmux.window_id_of_string "@12";
          anchor = Tmux.window_id_of_string "@9";
          position = After;
        }
      in
      List.iter
        (fun result ->
          emit (reply 52 (Sidebar.Reorder_window (Tmux.session_id_of_string "$3", move)) result))
        [ Ok (); Error "no such top-level window in session" ];
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
      let open Pane_status in
      let exit = { code = 1; command = "false"; started_at = 100.; ended_at = 101. } in
      let shells : shell list =
        List.map
          (fun phase -> { phase; report = None })
          [
            Unknown;
            Idle { last = None };
            Idle { last = Some exit };
            Running { command = "make"; started_at = 100.; fullscreen = false };
            Running { command = "vim"; started_at = 100.; fullscreen = true };
            Fullscreen;
          ]
        @ List.map
            (fun (state, msg) ->
              { phase = Idle { last = None }; report = Some { since = 100.; msg; state } })
            ([
               (Running { progress = Some 42 }, None);
               (Waiting { kind = Some Auth; progress = None }, Some "Login required");
               (Waiting { kind = None; progress = Some 3 }, None);
               (Idle { outcome = None }, None);
               (Idle { outcome = Some { serial = 17; result = Success } }, Some "Built");
               (Idle { outcome = Some { serial = 18; result = Failure } }, Some "Build failed");
             ]
              : (report_state * string option) list)
      in
      let agents : agent list =
        List.map
          (fun (state, msg) : agent -> { since = 100.; msg; state })
          ([
             (Running { progress = Some 42 }, None);
             ( Waiting { source = Blocked { kind = Some Permission }; progress = None },
               Some "Approve deployment" );
             (Waiting { source = Blocked { kind = Some Question }; progress = None }, None);
             (Waiting { source = Blocked { kind = None }; progress = Some 5 }, None);
             ( Waiting { source = Ask { id = Result.get_exn (Ask.parse_id "Aa1") }; progress = None },
               None );
             (Stalled, None);
             (Idle { outcome = None }, None);
             (Idle { outcome = Some { serial = 17; result = Success } }, Some "Finished");
             (Idle { outcome = Some { serial = 18; result = Failure } }, Some "Failed");
           ]
            : (agent_state * string option) list)
      in
      let live status = Sidebar.Live { status; run = None } in
      let lifecycles =
        List.map (fun s -> live (Terminal s)) shells
        @ List.map (fun status -> live (Some_agent { name = "claude-code"; status })) agents
        @ [
            live (Pi_agent { id = "pi-session-id"; status = List.hd agents });
            live
              (Ssh
                 {
                   user = "alice";
                   host = "example.org";
                   pane = Remote_terminal { interactive = true; status = List.hd shells };
                 });
            live
              (Ssh
                 {
                   user = "alice";
                   host = "example.org";
                   pane = Remote_agent { name = "pi"; status = List.hd agents };
                 });
          ]
        @ List.map
            (fun result -> Sidebar.Ended { result; run = Agent })
            [ None; Some Subrun.Completed; Some Failed; Some Died; Some Stopped ]
      in
      let items =
        List.mapi
          (fun i lifecycle ->
            {
              Sidebar.row =
                {
                  pane = Tmux.pane_id_of_string ("%" ^ string_of_int i);
                  window = Tmux.window_id_of_string "@1";
                  title = (if i = 0 then "title" else "");
                  lifecycle =
                    (match lifecycle with
                    | Sidebar.Live l when i < 2 ->
                        Live
                          {
                            l with
                            run = Some { kind = (if i = 0 then Agent else Bash); started = 100. };
                          }
                    | l -> l);
                };
              children = [];
            })
          lifecycles
      in
      let first = List.hd items in
      let nodes =
        [
          Sidebar.Group { name = "window"; first; rest = [ List.nth items 1 ] };
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
              server = Some (1, { Tmux_pane.started_at = 1780000000; pid = 12345 });
            };
          sessions =
            [ { id = Tmux.session_id_of_string "$0"; name = "session"; current = true; nodes } ];
        }
      in
      emit (Option.get_exn_or "snapshot" (snapshot m));
      List.iter (fun (i : Sidebar.item) -> emit (lifecycle i.row.lifecycle)) (List.drop 2 items);
      print_endline
        (Option.map_or ~default:"no snapshot before a server identity" Yojson.Safe.to_string
           (snapshot { m with snap = Sidebar.empty }));
      emit
        (Option.get_exn_or "error snapshot"
           (snapshot { m with snap = { m.snap with err = Some "tmux: gone" }; sessions = [] }));
      [%expect
        {|
        4.0
        {"hello":{"protocol":"4.0"}}
        {"hello":{"protocol":"4.0","server":"other","expected":"0123456789ab"}}
        {"hello":{"protocol":"4.0","server":null,"expected":"0123456789ab"}}
        {"reply":{"id":7,"switched":{"session":"$3","window":"@12"}}}
        {"reply":{"id":7,"switched":null}}
        {"reply":{"id":7,"error":"invalid or unknown request"}}
        {"reply":{"id":52,"reordered":true}}
        {"reply":{"id":52,"error":"no such top-level window in session"}}
        {"v":2,"server_instance":{"started_at":1780000000,"pid":12345},"client":{"session":"$0","window":"@1","pane":"%0"},"asks":[],"error":null,"sessions":[{"id":"$0","name":"session","current":true,"nodes":[{"kind":"window","id":"@1","window":"@1","name":"window","children":[{"kind":"pane","id":"%0","pane":"%0","window":"@1","title":"title","lifecycle":["Live",["Terminal",{"phase":["Unknown"],"report":null}]],"program_status":{"serial":0,"records":[]},"run":"agent","started":100.0,"children":[]},{"kind":"pane","id":"%1","pane":"%1","window":"@1","title":"","lifecycle":["Live",["Terminal",{"phase":["Idle",{"last":null}],"report":null}]],"program_status":{"serial":0,"records":[]},"run":"bash","started":100.0,"children":[]}]},{"kind":"pane","id":"%0","pane":"%0","window":"@1","title":"title","lifecycle":["Live",["Terminal",{"phase":["Unknown"],"report":null}]],"program_status":{"serial":0,"records":[]},"run":"agent","started":100.0,"children":[{"kind":"pane","id":"%0","pane":"%0","window":"@1","title":"title","lifecycle":["Live",["Terminal",{"phase":["Unknown"],"report":null}]],"program_status":{"serial":0,"records":[]},"run":"agent","started":100.0,"children":[]}]}]}]}
        ["Live",["Terminal",{"phase":["Idle",{"last":{"code":1,"command":"false","started_at":100.0,"ended_at":101.0}}],"report":null}]]
        ["Live",["Terminal",{"phase":["Running",{"origin":["Command",{"command":"make","started_at":100.0}],"fullscreen":false}],"report":null}]]
        ["Live",["Terminal",{"phase":["Running",{"origin":["Command",{"command":"vim","started_at":100.0}],"fullscreen":true}],"report":null}]]
        ["Live",["Terminal",{"phase":["Running",{"origin":["Unknown"],"fullscreen":true}],"report":null}]]
        ["Live",["Terminal",{"phase":["Idle",{"last":null}],"report":{"since":100.0,"msg":null,"state":["Running",{"progress":42}]}}]]
        ["Live",["Terminal",{"phase":["Idle",{"last":null}],"report":{"since":100.0,"msg":"Login required","state":["Waiting",{"kind":"auth","progress":null}]}}]]
        ["Live",["Terminal",{"phase":["Idle",{"last":null}],"report":{"since":100.0,"msg":null,"state":["Waiting",{"kind":null,"progress":3}]}}]]
        ["Live",["Terminal",{"phase":["Idle",{"last":null}],"report":{"since":100.0,"msg":null,"state":["Idle",{"outcome":null}]}}]]
        ["Live",["Terminal",{"phase":["Idle",{"last":null}],"report":{"since":100.0,"msg":"Built","state":["Idle",{"outcome":{"serial":17,"result":"success"}}]}}]]
        ["Live",["Terminal",{"phase":["Idle",{"last":null}],"report":{"since":100.0,"msg":"Build failed","state":["Idle",{"outcome":{"serial":18,"result":"failure"}}]}}]]
        ["Live",["Some_agent",{"name":"claude-code","status":{"since":100.0,"msg":null,"state":["Running",{"progress":42}]}}]]
        ["Live",["Some_agent",{"name":"claude-code","status":{"since":100.0,"msg":"Approve deployment","state":["Waiting",{"source":["Blocked",{"kind":"permission"}],"progress":null}]}}]]
        ["Live",["Some_agent",{"name":"claude-code","status":{"since":100.0,"msg":null,"state":["Waiting",{"source":["Blocked",{"kind":"question"}],"progress":null}]}}]]
        ["Live",["Some_agent",{"name":"claude-code","status":{"since":100.0,"msg":null,"state":["Waiting",{"source":["Blocked",{"kind":null}],"progress":5}]}}]]
        ["Live",["Some_agent",{"name":"claude-code","status":{"since":100.0,"msg":null,"state":["Waiting",{"source":["Ask",{"id":"Aa1"}],"progress":null}]}}]]
        ["Live",["Some_agent",{"name":"claude-code","status":{"since":100.0,"msg":null,"state":["Stalled"]}}]]
        ["Live",["Some_agent",{"name":"claude-code","status":{"since":100.0,"msg":null,"state":["Idle",{"outcome":null}]}}]]
        ["Live",["Some_agent",{"name":"claude-code","status":{"since":100.0,"msg":"Finished","state":["Idle",{"outcome":{"serial":17,"result":"success"}}]}}]]
        ["Live",["Some_agent",{"name":"claude-code","status":{"since":100.0,"msg":"Failed","state":["Idle",{"outcome":{"serial":18,"result":"failure"}}]}}]]
        ["Live",["Pi_agent",{"id":"pi-session-id","status":{"since":100.0,"msg":null,"state":["Running",{"progress":42}]}}]]
        ["Live",["Ssh",{"user":"alice","host":"example.org","pane":["Remote_terminal",{"interactive":true,"status":{"phase":["Unknown"],"report":null}}]}]]
        ["Live",["Ssh",{"user":"alice","host":"example.org","pane":["Remote_agent",{"name":"pi","status":{"since":100.0,"msg":null,"state":["Running",{"progress":42}]}}]}]]
        ["Ended",{"result":"unknown"}]
        ["Ended",{"result":"completed"}]
        ["Ended",{"result":"failed"}]
        ["Ended",{"result":"died"}]
        ["Ended",{"result":"stopped"}]
        no snapshot before a server identity
        {"v":2,"server_instance":{"started_at":1780000000,"pid":12345},"client":{"session":"$0","window":"@1","pane":"%0"},"asks":[],"error":"tmux: gone","sessions":[]}
        |}]
  end)
