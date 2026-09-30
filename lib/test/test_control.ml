open Kido
open Fixture

let record ~dir id s = Result.get_exn (State.record ~dir id s)
let attempt = function Ok line -> print_endline line | Error m -> Printf.printf "refused: %s\n" m

(* A steer is an envelope of its own kind, which pi steers rather than queues, to a descendant
   however deep; nothing reaches a peer, an ancestor or the caller, not even by paste. *)
let%expect_test "steer reaches descendants only" =
  let dir = Filename.temp_dir "kido-state" "" in
  let panes =
    List.map
      (fun i -> pane ~session_id:"$1" ~window:(Printf.sprintf "@%d" i) (Printf.sprintf "%%%d" i))
      [ 1; 2; 3; 4; 5 ]
  in
  let inbox, received = start_inbox ~reply:"ok\n" in
  List.iter
    (fun (id, p, parent) -> record ~dir id (session ~pane:p ~title:id ?parent ~inbox Idle))
    [
      ("root", "%4", None);
      ("caller", "%1", Some "root");
      ("child", "%2", Some "caller");
      ("grandchild", "%5", Some "child");
      ("peer", "%3", None);
    ];
  List.iter
    (fun to_ ->
      Message_agent.send ~dir ~self:"%1"
        ~panes:(lazy (Ok panes))
        ~paste:(fun pane _ -> Ok (Printf.printf "pasted into %s\n" pane))
        (Descendant to_)
        { kind = Steer; reply_to = ""; id = "" }
        "stop and do X instead"
      |> Result.map_err (function Message_agent.No_text -> "no text" | Not_sent m -> m)
      |> attempt)
    [ "child"; "grandchild"; "peer"; "root"; "caller" ];
  List.iter
    (fun raw ->
      match Fixture.envelope raw with
      | Some e -> Printf.printf "%s %S\n" (e "kind") (e "text")
      | None -> Printf.printf "not an envelope: %S\n" raw)
    (received ());
  [%expect
    {|
    delivered to child by inbox
    delivered to grandchild by inbox
    refused: peer is not this agent's descendant
    refused: root is not this agent's descendant
    refused: caller is this agent
    steer "stop and do X instead"
    steer "stop and do X instead"
    |}]
