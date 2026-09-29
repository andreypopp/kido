open Kido
open Fixture

let record ~dir id s = Result.get_exn (State.record ~dir id s)

let attempt f =
  match f () with
  | code -> Printf.printf "-> %d\n" code
  | exception Failure m -> Printf.printf "refused: %s\n" m

type world = { dir : string; panes : Tmux.Pane.t list; kills : string list ref }

let world panes = { dir = Filename.temp_dir "kido-state" ""; panes; kills = ref [] }

let ops w =
  {
    Reap.kill_window = (fun id -> w.kills := ("window " ^ id) :: !(w.kills));
    kill_pane = (fun id -> w.kills := id :: !(w.kills));
  }

let stop ?(escalation = 0.3) ?(force = false) w to_ =
  attempt (fun () ->
      Control.stop ~dir:w.dir ~self:"%1"
        ~list_panes:(fun () -> w.panes)
        ~ops:(ops w) ~escalation ~force to_)

let interrupt w to_ =
  attempt (fun () -> Control.interrupt ~dir:w.dir ~self:"%1" ~panes:(lazy w.panes) to_)

let kills w =
  Printf.printf "killed: [%s]\n" (String.concat " " (List.rev !(w.kills)));
  w.kills := []

let outcome w run =
  match
    Subrun.read_outcome ~dir:(Filename.concat w.dir "runs") (Result.get_exn (Subrun.parse_id run))
  with
  | None -> print_endline "no outcome"
  | Some o -> Printf.printf "outcome %s %S\n" (Reap.string_of_result o.result) o.text

let two_windows =
  [ pane ~session_id:"$1" ~window:"@1" "%1"; pane ~session_id:"$1" ~window:"@2" "%2" ]

let tree =
  [
    pane ~session_id:"$1" ~window:"@1" "%1";
    pane ~session_id:"$1" ~window:"@2" "%2";
    pane ~session_id:"$1" ~window:"@3" "%3";
  ]

(* caller on %1, its child on %2 and an unrelated peer on %3, both children with an inbox. *)
let record_tree w inbox =
  record ~dir:w.dir "caller" (session ~pane:"%1" ~title:"caller" Idle);
  record ~dir:w.dir "child" (session ~pane:"%2" ~title:"child" ~parent:"caller" ~inbox Idle);
  record ~dir:w.dir "peer" (session ~pane:"%3" ~title:"peer" ~inbox Idle)

(* Temp directories are named at random. *)
let mask s =
  let tmp = Filename.get_temp_dir_name () in
  let rec go s =
    match String.find ~sub:tmp s with
    | -1 -> s
    | i ->
        let rest = String.drop (i + String.length tmp + 1) s in
        let rest =
          match String.index_opt rest '/' with Some j -> String.drop j rest | None -> rest
        in
        go (String.take i s ^ "<tmp>" ^ rest)
  in
  go s

let stale_socket () =
  let path = Filename.concat (Filename.temp_dir "kido-inbox" "") "stale.sock" in
  let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.bind fd (Unix.ADDR_UNIX path);
  Unix.close fd;
  path

(* Every refusal comes before the Stopped outcome: an outcome is written once and for all. *)
let%expect_test "stop without an inbox to ask over needs --force, and then kills only the pane" =
  List.iter
    (fun (what, panes, force, inbox) ->
      Printf.printf "# %s\n" what;
      let w = world panes in
      let inbox = Option.map_or ~default:"" (fun f -> f ()) inbox in
      ignore (run ~dir:w.dir "target");
      record ~dir:w.dir "target" (session ~pane:"%2" ~title:"target" ~inbox Idle);
      stop ~force w "target";
      print_string (mask [%expect.output]);
      kills w;
      outcome w "target")
    [
      ("no inbox, no --force", two_windows, false, None);
      ("no inbox, --force", two_windows, true, None);
      ("stale inbox, no --force", two_windows, false, Some stale_socket);
      ("stale inbox, --force", two_windows, true, Some stale_socket);
      ( "the target shares its window with a bystander",
        two_windows @ [ pane ~session_id:"$1" ~window:"@2" "%3" ],
        true,
        None );
      ( "the target is another tmux session's only window",
        [ pane ~session_id:"$2" ~window:"@9" "%1"; pane ~session_id:"$1" ~window:"@1" "%2" ],
        true,
        None );
    ];
  [%expect
    {|
    # no inbox, no --force
    refused: target has no inbox to ask nicely over; pass --force to kill its window instead
    killed: []
    no outcome
    # no inbox, --force
    killed target's pane
    -> 0
    killed: [%2]
    outcome stopped ""
    # stale inbox, no --force
    refused: target could not be asked to stop (target is not listening on its inbox; a stop cannot fall back to a paste: no agent listening on the inbox: <tmp>/stale.sock: Connection refused); pass --force to kill its window instead
    killed: []
    no outcome
    # stale inbox, --force
    killed target's pane
    -> 0
    killed: [%2]
    outcome stopped ""
    # the target shares its window with a bystander
    killed target's pane
    -> 0
    killed: [%2]
    outcome stopped ""
    # the target is another tmux session's only window
    refused: target (target) is in another tmux session, not this one
    killed: []
    no outcome
    |}]

let kinds received =
  List.map
    (fun raw ->
      match Msg.parse raw with Some e -> Msg.string_of_kind e.kind | None -> "not an envelope")
    (received ())
  |> String.concat " " |> Printf.printf "received: [%s]\n"

(* The messages carry no "kido <verb>:" prefix: Cli.run adds it. *)
let%expect_test "interrupt and stop reach only descendants; a human caller reaches anyone" =
  let w = world tree in
  let inbox, received = start_inbox ~reply:"ok\n" in
  record_tree w inbox;
  List.iter (interrupt w) [ "peer"; "caller"; "child" ];
  List.iter (stop w) [ "peer"; "caller" ];
  kinds received;
  let w = world tree in
  let inbox, received = start_inbox ~reply:"ok\n" in
  record ~dir:w.dir "peer" (session ~pane:"%3" ~title:"peer" ~inbox Idle);
  interrupt w "peer";
  kinds received;
  let w = world two_windows in
  record ~dir:w.dir "target" (session ~pane:"%2" ~title:"target" Idle);
  record ~dir:w.dir "me" (session ~pane:"%1" ~title:"Self" Idle);
  interrupt w "Self";
  interrupt w "target";
  kills w;
  [%expect
    {|
    refused: peer is not this agent's descendant
    refused: caller is this agent
    interrupted child
    -> 0
    refused: peer is not this agent's descendant
    refused: caller is this agent
    received: [interrupt]
    interrupted peer
    -> 0
    received: [interrupt]
    refused: Self is this agent
    refused: target is not this agent's descendant
    killed: []
    |}]

(* A target that takes the request but whose record never goes has its pane killed once the
   escalation runs out; one that goes in time never does. *)
let%expect_test "stop escalates to killing the pane, and only when the target stays" =
  List.iter
    (fun (what, reply, goes) ->
      Printf.printf "# %s\n" what;
      let w = world two_windows in
      let inbox, _ = start_inbox ~reply in
      ignore (run ~dir:w.dir "target");
      record ~dir:w.dir "target" (session ~pane:"%2" ~title:"target" ~inbox Idle);
      let remover =
        Thread.create
          (fun () ->
            if goes then begin
              Unix.sleepf 0.05;
              ignore (State.remove ~dir:w.dir "target" ~pid:(Unix.getpid ()))
            end)
          ()
      in
      stop w "target";
      print_string (mask [%expect.output]);
      Thread.join remover;
      kills w;
      outcome w "target")
    [
      ("agrees and goes", "ok\n", true);
      ("agrees and stays", "ok\n", false);
      ("refuses", "refused\n", false);
      ("answers something else", "what?\n", false);
      ("never answers", "", false);
    ];
  [%expect
    {|
    # agrees and goes
    stopped target
    -> 0
    killed: []
    outcome stopped ""
    # agrees and stays
    target did not stop within 300ms; killed its pane
    -> 0
    killed: [%2]
    outcome stopped ""
    # refuses
    target did not accept the stop request (target refused the stop) and was still there after 300ms; killed its pane
    -> 0
    killed: [%2]
    outcome stopped ""
    # answers something else
    target did not accept the stop request (inbox <tmp>/inbox.sock: answered "what?", want "ok") and was still there after 300ms; killed its pane
    -> 0
    killed: [%2]
    outcome stopped ""
    # never answers
    target did not accept the stop request (inbox <tmp>/inbox.sock: timed out) and was still there after 300ms; killed its pane
    -> 0
    killed: [%2]
    outcome stopped ""
    |}]

let bash_run ?(parent = "root-sess") ?(pid = dead_pid ()) w name =
  run ~dir:w.dir ~name ~kind:Bash ~parent ~pane:"%2" ~pid ~command:[ "sleep"; "600" ] name

let notices received =
  List.iter
    (fun raw ->
      match Msg.parse raw with
      | Some e ->
          Printf.printf "%s from %s: %s\n" (Msg.string_of_kind e.kind) e.from.name
            (List.hd (String.lines e.text))
      | None -> Printf.printf "not an envelope: %S\n" raw)
    (received ())

(* A bash run has no inbox: stopping it is always --force. Its wrapper reports the ending when it
   can; the stop speaks only for one that cannot. *)
let%expect_test "stopping a bash run" =
  let parent w =
    let inbox, received = start_inbox ~reply:"ok\n" in
    record ~dir:w.dir "root-sess" (session ~pane:"%3" ~title:"orchestrator" ~inbox Idle);
    received
  in
  print_endline "# without --force";
  let w = world tree in
  let received = parent w in
  ignore (bash_run w "doomed");
  stop w "doomed";
  kills w;
  outcome w "doomed";
  notices received;
  print_endline "# a wrapper that cannot report";
  stop ~force:true w "doomed";
  kills w;
  outcome w "doomed";
  notices received;
  print_endline "# a wrapper that reports";
  let w = world tree in
  let received = parent w in
  let sleep = Unix.create_process "sleep" [| "sleep"; "30" |] Unix.stdin Unix.stdout Unix.stderr in
  let meta = bash_run ~pid:sleep w "polite" in
  let wrapper =
    Thread.create
      (fun () ->
        Unix.sleepf 0.15;
        ignore
          (Subrun.record_outcome ~dir:(Filename.concat w.dir "runs") meta.id
             { result = Failed; text = "killed by terminated"; at = None }))
      ()
  in
  stop ~escalation:2. ~force:true w "polite";
  Thread.join wrapper;
  ignore (Unix.waitpid [] sleep);
  kills w;
  outcome w "polite";
  notices received;
  print_endline "# the run's pane is its session's only one";
  let w =
    world [ pane ~session_id:"$2" ~window:"@9" "%1"; pane ~session_id:"$1" ~window:"@1" "%2" ]
  in
  let received = parent w in
  ignore (bash_run w "alone");
  stop ~force:true w "alone";
  kills w;
  outcome w "alone";
  notices received;
  [%expect
    {|
    # without --force
    refused: async run "doomed" has no inbox to ask nicely over; pass --force to kill its window instead
    killed: []
    no outcome
    # a wrapper that cannot report
    stopped async run "doomed"; killed its pane
    -> 0
    killed: [%2]
    outcome stopped "stopped by kido stop_subagent; its wrapper did not report"
    notice from doomed: async run "doomed" stopped: stopped by kido stop_subagent; its wrapper did not report
    # a wrapper that reports
    stopped async run "polite"; its wrapper reported the ending
    -> 0
    killed: []
    outcome failed "killed by terminated"
    # the run's pane is its session's only one
    refused: async run "alone" was recorded stopped, but its pane could not be killed: it is its session's only pane; killing it would destroy the session
    killed: []
    outcome stopped "stopped by kido stop_subagent; its wrapper did not report"
    notice from alone: async run "alone" stopped: stopped by kido stop_subagent; its wrapper did not report
    |}]

let%expect_test "a bash run is reached through the parent in its meta; a finished one is no match" =
  let w = world tree in
  let inbox, received = start_inbox ~reply:"ok\n" in
  record_tree w inbox;
  ignore (bash_run ~parent:"peer" w "stranger");
  stop ~force:true w "stranger";
  outcome w "stranger";
  ignore (bash_run ~parent:"child" w "mine");
  stop ~force:true w "mine";
  outcome w "mine";
  kills w;
  kinds received;
  let finished = bash_run ~parent:"caller" w "child" in
  ignore
    (Subrun.record_outcome ~dir:(Filename.concat w.dir "runs") finished.id
       { result = Completed; text = ""; at = None });
  stop ~escalation:0.1 w "child";
  kinds received;
  ignore (bash_run ~parent:"caller" w "twin");
  ignore (run ~dir:w.dir ~name:"Twin" ~kind:Bash ~parent:"caller" "twin-2");
  stop ~force:true w "twin";
  kills w;
  [%expect
    {|
    refused: async run "stranger" is not this agent's descendant
    no outcome
    stopped async run "mine"; killed its pane
    -> 0
    outcome stopped "stopped by kido stop_subagent; its wrapper did not report"
    killed: [%2]
    received: [notice]
    child did not stop within 100ms; killed its pane
    -> 0
    received: [notice stop]
    refused: "twin" matches several running async runs: twin, twin-2
    killed: [%2]
    |}]

(* A steer is an envelope of its own kind, which pi steers rather than queues, to a descendant
   however deep; nothing reaches a peer, an ancestor or the caller, not even by paste. *)
let%expect_test "steer reaches descendants only" =
  let w =
    world
      (List.map
         (fun i -> pane ~session_id:"$1" ~window:(Printf.sprintf "@%d" i) (Printf.sprintf "%%%d" i))
         [ 1; 2; 3; 4; 5 ])
  in
  let inbox, received = start_inbox ~reply:"ok\n" in
  List.iter
    (fun (id, p, parent) -> record ~dir:w.dir id (session ~pane:p ~title:id ?parent ~inbox Idle))
    [
      ("root", "%4", None);
      ("caller", "%1", Some "root");
      ("child", "%2", Some "caller");
      ("grandchild", "%5", Some "child");
      ("peer", "%3", None);
    ];
  List.iter
    (fun to_ ->
      attempt (fun () ->
          Message_agent.send ~dir:w.dir ~self:"%1"
            ~panes:(lazy w.panes)
            ~paste:(fun pane _ -> Printf.printf "pasted into %s\n" pane)
            { kind = Steer; recipient = Descendant to_; reply_to = ""; id = "" }
            "stop and do X instead"))
    [ "child"; "grandchild"; "peer"; "root"; "caller" ];
  List.iter
    (fun raw ->
      match Msg.parse raw with
      | Some e -> Printf.printf "%s %S\n" (Msg.string_of_kind e.kind) e.text
      | None -> Printf.printf "not an envelope: %S\n" raw)
    (received ());
  [%expect
    {|
    delivered to child by inbox
    -> 0
    delivered to grandchild by inbox
    -> 0
    refused: peer is not this agent's descendant
    refused: root is not this agent's descendant
    refused: caller is this agent
    steer "stop and do X instead"
    steer "stop and do X instead"
    |}]
