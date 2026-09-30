open Kido
open Fixture

let record ~dir id s = Result.get_exn (State.record ~dir id s)

let build ?(runs = "/nonexistent") states panes ~session ~self =
  List_agents.build ~runs ~threshold:60. ~wake:None ~now:1_700_000_100. states panes ~session ~self

let show agents =
  List.iter
    (fun (a : List_agents.agent_info) ->
      Printf.printf "%s parent=%S self=%b window=%S cwd=%S canMessage=%b canReply=%b\n" a.id
        a.parent a.self a.window a.cwd a.can_message a.can_reply)
    agents

let%expect_test "display_name falls back to the pane title, stripped of pi's marker" =
  let panes =
    [
      pane ~title:"π - kido" "%1"; pane ~title:"π - review - kido" "%2"; pane ~title:"π - kido" "%3";
    ]
  in
  List.iter
    (fun s -> print_endline (List_agents.display_name panes s))
    [ session ~pane:"%1" Idle; session ~pane:"%2" Idle; session ~pane:"%3" ~title:"π - kido" Idle ];
  [%expect {|
    kido
    review - kido
    π - kido
    |}]

let%expect_test "the JSON shape pi reads" =
  let panes = [ pane ~session_id:"$1" ~window:"@1" ~cwd:"/work" "%1" ] in
  build
    [ ("a", session ~pane:"%1" ~inbox:"sock" ~title:"alpha" Running) ]
    panes ~session:"$1" ~self:"%1"
  |> List.iter (fun a -> print_endline (Yojson.Safe.to_string (List_agents.agent_info_to_yojson a)));
  [%expect
    {| {"id":"a","name":"alpha","agent":"pi","pane":"%1","window":"@1","status":"running","activity":"","parent":"","depth":0,"self":true,"cwd":"/work","canMessage":true,"canReply":true,"model":"","sinceReport":100,"stalled":true} |}]

let%expect_test "build scopes to one session and decorates from its panes" =
  let states =
    [ ("a", session ~pane:"%1" Running); ("b", session ~agent:Claude ~pane:"%2" Idle) ]
  in
  let panes =
    [
      pane ~session_id:"$1" ~window:"@1" ~cwd:"/work" "%1";
      pane ~session_id:"$2" ~window:"@2" ~cwd:"/other" "%2";
    ]
  in
  show (build states panes ~session:"$1" ~self:"%1");
  show (build states panes ~session:"$2" ~self:"%1");
  [%expect
    {|
    a parent="" self=true window="@1" cwd="/work" canMessage=false canReply=false
    b parent="" self=false window="@2" cwd="/other" canMessage=false canReply=false
    |}]

(* A ring of bogus parent edges is reachable from no root, and list_agents is the only way to
   discover an agent at all: each comes out once, as a root. *)
let%expect_test "build lists every agent in a cycle once, and a self-parent is a root" =
  let panes = List.map (fun id -> pane ~session_id:"$1" id) [ "%1"; "%2"; "%3" ] in
  show
    (build
       [
         ("a", session ~pane:"%1" ~parent:"b" Idle);
         ("b", session ~pane:"%2" ~parent:"a" Idle);
         ("root", session ~pane:"%3" Idle);
       ]
       panes ~session:"$1" ~self:"%3");
  show (build [ ("a", session ~pane:"%1" ~parent:"a" Idle) ] panes ~session:"$1" ~self:"%1");
  [%expect
    {|
    root parent="" self=true window="@1" cwd="" canMessage=false canReply=false
    a parent="b" self=false window="@1" cwd="" canMessage=false canReply=false
    b parent="a" self=false window="@1" cwd="" canMessage=false canReply=false
    a parent="" self=true window="@1" cwd="" canMessage=false canReply=false
    |}]

(* The session id breaks a tie in ts, so identical state always lists in one order. *)
let%expect_test "build orders parent first, then siblings oldest first, ids breaking a tie" =
  let panes = List.map (fun id -> pane ~session_id:"$1" id) [ "%1"; "%2"; "%3"; "%4"; "%5" ] in
  show
    (build
       [
         ("child2", session ~pane:"%2" ~parent:"root" ~depth:1 ~ts:1002. Running);
         ("root", session ~pane:"%1" ~ts:1000. Running);
         ("child1", session ~pane:"%3" ~parent:"root" ~depth:1 ~ts:1001. Running);
         ("ccc", session ~pane:"%4" ~ts:999. Idle);
         ("bbb", session ~pane:"%5" ~ts:999. Idle);
       ]
       panes ~session:"$1" ~self:"%1");
  [%expect
    {|
    bbb parent="" self=false window="@1" cwd="" canMessage=false canReply=false
    ccc parent="" self=false window="@1" cwd="" canMessage=false canReply=false
    root parent="" self=true window="@1" cwd="" canMessage=false canReply=false
    child1 parent="root" self=false window="@1" cwd="" canMessage=false canReply=false
    child2 parent="root" self=false window="@1" cwd="" canMessage=false canReply=false
    |}]

(* The edge is matched on the parent's session, never its pid: a pid can be recycled. *)
let%expect_test "a parent edge naming a session not in scope is no edge" =
  let panes = List.map (fun id -> pane ~session_id:"$1" id) [ "%1"; "%2" ] in
  show
    (build
       [
         ("root", session ~pane:"%1" ~pid:100 Idle);
         ("child", session ~pane:"%2" ~parent:"someone-else" Idle);
       ]
       panes ~session:"$1" ~self:"%1");
  [%expect
    {|
    child parent="" self=false window="@1" cwd="" canMessage=false canReply=false
    root parent="" self=true window="@1" cwd="" canMessage=false canReply=false
    |}]

let%expect_test "canReply: a run record whose tools leave out message_agent cannot answer an ask" =
  let runs = Filename.temp_dir "kido-runs" "" in
  List.iter
    (fun (id, tools) ->
      let id = Result.get_exn (Subrun.parse_id id) in
      Subrun.create ~dir:runs id "task";
      Subrun.write_meta ~dir:runs
        {
          id;
          name = "";
          kind = None;
          parent_session = "";
          depth = 0;
          pane = "";
          pid = 0;
          cwd = "";
          model = "";
          tools;
          keep_alive = false;
          started_at = 0.;
        })
    [
      ("empty-tools", []);
      ("no-message-tool", [ "read"; "bash" ]);
      ("has-message-tool", [ "read"; "message_agent" ]);
    ];
  let ids = [ "no-record"; "empty-tools"; "no-message-tool"; "has-message-tool" ] in
  let panes = List.mapi (fun i _ -> pane ~session_id:"$1" (Printf.sprintf "%%%d" i)) ids in
  show
    (build ~runs
       (List.mapi
          (fun i id -> (id, session ~pane:(Printf.sprintf "%%%d" i) ~inbox:"sock" Idle))
          ids)
       panes ~session:"$1" ~self:"%0");
  [%expect
    {|
    empty-tools parent="" self=false window="@1" cwd="" canMessage=true canReply=true
    has-message-tool parent="" self=false window="@1" cwd="" canMessage=true canReply=true
    no-message-tool parent="" self=false window="@1" cwd="" canMessage=true canReply=false
    no-record parent="" self=true window="@1" cwd="" canMessage=true canReply=true
    |}]

let%expect_test "is_ancestor refuses a self-edge" =
  Printf.printf "%b %b\n"
    (List_agents.is_ancestor [ ("x", "x") ] ~ancestor:"x" "x")
    (List_agents.is_ancestor [ ("c", "b"); ("b", "a") ] ~ancestor:"a" "c");
  [%expect {| false true |}]

let list_agents ~dir ~self panes ~session =
  match
    List_agents.list_agents ~dir ~threshold:60. ~self ~panes:(Lazy.from_val (Ok panes)) ~session
  with
  | Ok agents ->
      print_endline
        (Yojson.Safe.to_string (`List (List.map List_agents.agent_info_to_yojson agents)))
  | Error m -> print_endline m

let%expect_test "list_agents defaults to the caller's session; --session answers without a pane" =
  let dir = Filename.temp_dir "kido-state" "" in
  let panes =
    [ pane ~session_id:"$1" ~window:"@1" "%1"; pane ~session_id:"$2" ~window:"@9" "%9" ]
  in
  record ~dir "here" (session ~pane:"%1" ~ts:(Timestamp.now ()) Idle);
  record ~dir "elsewhere" (session ~pane:"%9" ~ts:(Timestamp.now ()) Idle);
  list_agents ~dir ~self:"%1" panes ~session:"";
  list_agents ~dir ~self:"%1" panes ~session:"$2";
  list_agents ~dir ~self:"" panes ~session:"";
  list_agents ~dir ~self:"" panes ~session:"$1";
  [%expect
    {|
    [{"id":"here","name":"","agent":"pi","pane":"%1","window":"@1","status":"idle","activity":"","parent":"","depth":0,"self":true,"cwd":"","canMessage":false,"canReply":false,"model":"","sinceReport":0,"stalled":false}]
    [{"id":"elsewhere","name":"","agent":"pi","pane":"%9","window":"@9","status":"idle","activity":"","parent":"","depth":0,"self":false,"cwd":"","canMessage":false,"canReply":false,"model":"","sinceReport":0,"stalled":false}]
    no tmux session for pane ""; pass --session
    usage: kido list_agents [--session ID] [--json]
    [{"id":"here","name":"","agent":"pi","pane":"%1","window":"@1","status":"idle","activity":"","parent":"","depth":0,"self":false,"cwd":"","canMessage":false,"canReply":false,"model":"","sinceReport":0,"stalled":false}]
    |}]
