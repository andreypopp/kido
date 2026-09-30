open Kido
open Fixture

let same_session =
  [ pane ~session_id:"$1" "%1"; pane ~session_id:"$1" "%2"; pane ~session_id:"$1" "%3" ]

let record ~dir id s = Result.get_exn (State.record ~dir id s)
let pastes = ref []
let paste pane text = Ok (pastes := (pane ^ ": " ^ text) :: !pastes)

(* Temp paths differ per run. *)
let scrub m =
  String.split_on_char ' ' m
  |> List.map (fun w ->
      if String.prefix ~pre:"/" w then if String.suffix ~suf:":" w then "<path>:" else "<path>"
      else w)
  |> String.concat " "

let outcome f =
  pastes := [];
  (match f () with
  | Ok line -> print_endline line
  | Error Message_agent.No_text -> print_endline "no text"
  | Error (Not_sent m) -> Printf.printf "error: %s\n" (scrub m));
  List.iter (Printf.printf "pasted %s\n") (List.rev !pastes)

let run ?(panes = same_session) ~dir kind recipient ?(reply_to = "") ?(id = "") text =
  outcome (fun () ->
      Message_agent.send ~dir ~self:"%1" ~panes:(Lazy.from_val (Ok panes)) ~paste recipient
        { kind; reply_to; id } text)

let notify ?(panes = same_session) ~dir ~parent ?(run = "") text =
  outcome (fun () ->
      Message_agent.notify_parent ~dir ~self:"%1" ~panes:(Lazy.from_val (Ok panes)) ~paste
        ~warn:(Printf.printf "warning: %s\n") ~parent ~run text)

let show received =
  List.iter
    (fun raw ->
      match Msg.parse raw with
      | None -> Printf.printf "v0 %S\n" raw
      | Some e ->
          Printf.printf "%s id=%s replyTo=%S text=%S from=(%S,%S,%S)\n" (Msg.string_of_kind e.kind)
            (if String.is_empty e.id then "<empty>"
             else if String.length e.id = 32 then "<fresh>"
             else e.id)
            e.reply_to e.text e.from.session e.from.name e.from.pane)
    (received ())

(* The caller on %1 with an inbox of its own, which an ask needs. *)
let asking_caller ~dir =
  let inbox, _ = start_inbox ~reply:"ok\n" in
  record ~dir "caller" (session ~pane:"%1" ~title:"asker" ~inbox Idle)

let%expect_test "a target gets a v1 envelope; --reply-to alone makes it a reply" =
  let dir = Filename.temp_dir "kido-state" "" in
  let inbox, received = start_inbox ~reply:"ok\n" in
  record ~dir "target" (session ~pane:"%2" ~inbox Idle);
  run ~dir Reply (Named "target") ~reply_to:"ask-1" "hi there";
  run ~dir Message (Named "target") "hi there\n";
  show received;
  [%expect
    {|
    delivered to  by inbox
    delivered to  by inbox
    reply id=<fresh> replyTo="ask-1" text="hi there" from=("","","%1")
    message id=<fresh> replyTo="" text="hi there" from=("","","%1")
    |}]

(* The only record is in another tmux session, out of a named lookup's reach, so a delivery can
   only have come from the session id in the environment. *)
let%expect_test "notify_parent sends a notice to the session its environment names" =
  let dir = Filename.temp_dir "kido-state" "" in
  let panes = [ pane ~session_id:"$1" "%1"; pane ~session_id:"$2" "%9" ] in
  let inbox, received = start_inbox ~reply:"ok\n" in
  record ~dir "parent-sess" (session ~pane:"%9" ~inbox Idle);
  notify ~panes ~dir ~parent:"parent-sess" "the answer is 42";
  show received;
  [%expect
    {|
    delivered to  by inbox
    notice id=<fresh> replyTo="" text="the answer is 42" from=("","","%1")
    |}]

let%expect_test "notify_parent without a parent, or to a gone one, sends nothing" =
  let dir = Filename.temp_dir "kido-state" "" in
  let inbox, received = start_inbox ~reply:"ok\n" in
  record ~dir "peer-sess" (session ~pane:"%2" ~inbox ~title:"peer" Idle);
  notify ~dir ~parent:"" "nobody to tell";
  notify ~dir ~parent:"long-gone" "anybody there?";
  show received;
  [%expect
    {|
    error: this session has no parent ($KIDO_AGENT_PARENT_SESSION is not set); nothing sent
    error: no live process holds session "long-gone"; the parent is gone, nothing sent
    |}]

let%expect_test "resolution: by name case-insensitively, by the pane title, by id and unique prefix"
    =
  let dir = Filename.temp_dir "kido-state" "" in
  let panes =
    [ pane ~session_id:"$1" "%1" ]
    @ List.map (fun id -> pane ~session_id:"$1" id) [ "%2"; "%3"; "%4"; "%5" ]
    @ [ pane ~session_id:"$1" ~title:"worker-6" "%6" ]
  in
  let inbox, received = start_inbox ~reply:"ok\n" in
  record ~dir "abc123" (session ~pane:"%2" ~inbox ~title:"Worker-2" Idle);
  record ~dir "abd456" (session ~pane:"%3" ~inbox Idle);
  record ~dir "worker-x" (session ~pane:"%4" ~title:"scout" Idle);
  record ~dir "worker-y" (session ~pane:"%5" ~title:"scout" Idle);
  record ~dir "untitled" (session ~pane:"%6" ~inbox Idle);
  List.iter
    (fun to_ -> run ~panes ~dir Message (Named to_) "x")
    [ "worker-2"; "worker-6"; "abc123"; "abd"; "ab"; "nope"; "scout" ];
  Printf.printf "%d delivered\n" (List.length (received ()));
  [%expect
    {|
    delivered to Worker-2 by inbox
    delivered to worker-6 by inbox
    delivered to Worker-2 by inbox
    delivered to  by inbox
    error: "ab" matches several agents by id: abc123 (Worker-2), abd456 ()
    error: no agent session matches "nope"
    error: "scout" matches several agents by name: worker-x (scout), worker-y (scout)
    4 delivered
    |}]

let%expect_test "a target in another tmux session is not addressable" =
  let dir = Filename.temp_dir "kido-state" "" in
  let panes = [ pane ~session_id:"$1" "%1"; pane ~session_id:"$2" "%9" ] in
  let inbox, received = start_inbox ~reply:"ok\n" in
  record ~dir "elsewhere" (session ~pane:"%9" ~inbox ~title:"far-away" Idle);
  run ~panes ~dir Message (Named "elsewhere") "x";
  show received;
  [%expect {| error: elsewhere (elsewhere) is in another tmux session, not this one |}]

(* The ambiguity found outside the caller's session carries no single session, so the error must
   not name an empty id. *)
let%expect_test "an ambiguity elsewhere names every candidate" =
  let panes =
    [ pane ~session_id:"$1" "%1"; pane ~session_id:"$2" "%8"; pane ~session_id:"$2" "%9" ]
  in
  let states =
    [
      ("twin-a", session ~pane:"%8" ~title:"Twin" Idle);
      ("twin-b", session ~pane:"%9" ~title:"Twin" Idle);
    ]
  in
  (match Message_agent.resolve_target states panes ~self:"%1" "Twin" with
  | Ok (id, _) -> Printf.printf "WRONG: resolved %s\n" id
  | Error m -> print_endline m);
  [%expect
    {| "Twin" matches several agents by name: twin-a (Twin), twin-b (Twin), none in this tmux session |}]

let%expect_test "no inbox, or a dead one, pastes a plain message; a hard inbox error never does" =
  let dir = Filename.temp_dir "kido-state" "" in
  record ~dir "target" (session ~pane:"%2" Idle);
  run ~dir Message (Named "target") "hi claude";
  let gone = Filename.concat (Filename.temp_dir "kido-inbox" "") "gone.sock" in
  record ~dir "target" (session ~pane:"%2" ~inbox:gone Idle);
  run ~dir Message (Named "target") "hello";
  let inbox, _ = start_inbox ~reply:"nope\n" in
  record ~dir "target" (session ~pane:"%2" ~inbox Idle);
  run ~dir Message (Named "target") "x";
  [%expect
    {|
    pasted into 's pane
    pasted %2: hi claude
    pasted into 's pane
    pasted %2: hello
    error: inbox <path>: answered "nope", want "ok"
    |}]

let%expect_test "refused before anything is sent: empty, invalid UTF-8, this agent" =
  let dir = Filename.temp_dir "kido-state" "" in
  record ~dir "me" (session ~pane:"%1" ~title:"Self" Idle);
  record ~dir "target" (session ~pane:"%2" ~title:"Alpha" Idle);
  run ~dir Message (Named "whoever") "";
  run ~dir Message (Named "whoever") "\n";
  run ~dir Message (Named "Alpha") "bad:\xff\xfe:end";
  run ~dir Message (Named "Self") "talking to myself";
  [%expect
    {|
    no text
    no text
    error: message is not valid UTF-8
    error: Self is this agent
    |}]

let%expect_test "ask_agent sends an ask with the caller's --id and no replyTo" =
  let dir = Filename.temp_dir "kido-state" "" in
  asking_caller ~dir;
  let inbox, received = start_inbox ~reply:"ok\n" in
  record ~dir "target" (session ~pane:"%2" ~inbox ~title:"peer" Idle);
  run ~dir Ask (Named "peer") ~id:"ask-7" "are you done?";
  show received;
  [%expect
    {|
    delivered to peer by inbox
    ask id=ask-7 replyTo="" text="are you done?" from=("caller","asker","%1")
    |}]

(* An answer arrives on the asker's own inbox or not at all; the target's inbox getting nothing
   is the point. *)
let%expect_test "ask_agent refuses a caller with no reply path" =
  let dir = Filename.temp_dir "kido-state" "" in
  let inbox, received = start_inbox ~reply:"ok\n" in
  record ~dir "target" (session ~pane:"%2" ~inbox ~title:"victim" Idle);
  run ~dir Ask (Named "victim") ~id:"t1" "are you done?";
  record ~dir "caller" (session ~agent:Claude ~pane:"%1" Idle);
  run ~dir Ask (Named "victim") ~id:"t1" "are you done?";
  Printf.printf "%d delivered\n" (List.length (received ()));
  [%expect
    {|
    error: no live agent session on this pane (%1), so an answer could not be addressed back here; nothing sent - use kido message_agent instead, which is one-way and needs no reply
    error:  has no inbox for an answer to arrive on, and only a long-lived process has one; nothing sent - use kido message_agent instead, which is one-way and needs no reply
    0 delivered
    |}]

(* A non-message kind must never fall back to a paste: a notice's text is model-authored, and
   pasted it would run as a command line in the parent's pane. *)
let%expect_test "an ask, reply or notice to no inbox, a dead one, or a refusal never pastes" =
  let dir = Filename.temp_dir "kido-state" "" in
  asking_caller ~dir;
  record ~dir "target" (session ~pane:"%2" Idle);
  run ~dir Ask (Named "target") "x";
  let gone = Filename.concat (Filename.temp_dir "kido-inbox" "") "gone.sock" in
  record ~dir "target" (session ~pane:"%2" ~inbox:gone Idle);
  run ~dir Ask (Named "target") "touch /tmp/pwned";
  run ~dir Reply (Named "target") ~reply_to:"ask-1" "touch /tmp/pwned";
  notify ~dir ~parent:"target" "touch /tmp/pwned";
  let inbox, _ = start_inbox ~reply:"refused\n" in
  record ~dir "target" (session ~pane:"%2" ~inbox Idle);
  run ~dir Ask (Named "target") ~id:"ask-9" "are you done?";
  [%expect
    {|
    error:  has no inbox to send a ask to; only a plain message can be sent as v0 text
    error:  is not listening on its inbox; a ask cannot fall back to a paste: no agent listening on the inbox: <path>: No such file or directory
    error:  is not listening on its inbox; a reply cannot fall back to a paste: no agent listening on the inbox: <path>: No such file or directory
    error:  is not listening on its inbox; a notice cannot fall back to a paste: no agent listening on the inbox: <path>: No such file or directory
    error:  refused the ask
    |}]

let%expect_test "a descendant must be reached through the caller's parent edges" =
  let dir = Filename.temp_dir "kido-state" "" in
  record ~dir "me" (session ~pane:"%1" Idle);
  record ~dir "kid" (session ~pane:"%2" ~parent:"me" Idle);
  record ~dir "peer" (session ~pane:"%3" ~title:"Peer" Idle);
  let live = State.load_live ~dir in
  List.iter
    (fun to_ ->
      match Message_agent.resolve ~live ~panes:same_session ~self:"%1" (Descendant to_) with
      | Ok (id, _) -> Printf.printf "%s: %s\n" to_ id
      | Error m -> Printf.printf "%s: %s\n" to_ m)
    [ "kid"; "Peer"; "me" ];
  [%expect
    {|
    kid: kid
    Peer: Peer is not this agent's descendant
    me:  is this agent
    |}]

let parent_inbox () =
  let dir = Filename.temp_dir "kido-state" "" in
  let inbox, received = start_inbox ~reply:"ok\n" in
  record ~dir "parent-sess" (session ~pane:"%9" ~inbox Idle);
  let run_id = Subrun.new_id () in
  Subrun.create ~dir:(Filename.concat dir "runs") run_id "task";
  (dir, Subrun.string_of_id run_id, received)

let panes_with_parent = [ pane ~session_id:"$1" "%1"; pane ~session_id:"$1" "%9" ]

let notice received =
  match received () with
  | [ raw ] -> (Option.get_exn_or "envelope" (Msg.parse raw)).text
  | got -> failwith (Printf.sprintf "%d payloads, want one" (List.length got))

let%expect_test "a report under the cap arrives byte for byte, with no file left behind" =
  let dir, run, received = parent_inbox () in
  let report = "the merge is done; two conflicts, both in README.md" in
  notify ~panes:panes_with_parent ~dir ~parent:"parent-sess" ~run report;
  Printf.printf "same: %b, file: %b\n"
    (String.equal (notice received) report)
    (Subrun.has_report ~dir:(Filename.concat dir "runs") (Result.get_exn (Subrun.parse_id run)));
  [%expect {|
    delivered to  by inbox
    same: true, file: false
    |}]

let%expect_test "a report over the cap is kept whole, named, and the notice stays in the cap" =
  let dir, run, received = parent_inbox () in
  let report = String.repeat "findings and more findings. " 200 ^ "CONCLUSION: ship it" in
  notify ~panes:panes_with_parent ~dir ~parent:"parent-sess" ~run report;
  let path =
    Subrun.report_path ~dir:(Filename.concat dir "runs") (Result.get_exn (Subrun.parse_id run))
  in
  let n = notice received in
  Printf.printf "kept whole: %b\nwithin cap: %b\nnames the file: %b\nstarts with the report: %b\n"
    (Option.equal String.equal (Fs.read path) (Some report))
    (String.length n <= Message_agent.max_report_bytes)
    (String.suffix ~suf:("full report: " ^ path) n)
    (String.prefix ~pre:(String.sub report 0 100) n);
  [%expect
    {|
    delivered to  by inbox
    kept whole: true
    within cap: true
    names the file: true
    starts with the report: true
    |}]

let%expect_test "the head of a multi-byte report is cut on a rune boundary" =
  let dir, run, received = parent_inbox () in
  notify ~panes:panes_with_parent ~dir ~parent:"parent-sess" ~run (String.repeat "日" 3000);
  let n = notice received in
  Printf.printf "valid: %b, replacement: %b\n" (String.is_valid_utf_8 n)
    (String.mem ~sub:"\u{FFFD}" n);
  [%expect {|
    delivered to  by inbox
    valid: true, replacement: false
    |}]

let%expect_test "a sender with no run directory has its report truncated, naming no file" =
  let dir, _, received = parent_inbox () in
  notify ~panes:panes_with_parent ~dir ~parent:"parent-sess" (String.repeat "x" 4500);
  let n = notice received in
  Printf.printf "%d bytes, names a file: %b\n" (String.length n) (String.mem ~sub:"full report:" n);
  [%expect {|
    delivered to  by inbox
    4000 bytes, names a file: false
    |}]

let%expect_test "head_within drops a partial rune wherever the cut falls inside it" =
  let s = "ab\u{1F389}cd" in
  List.iter
    (fun cut -> Printf.printf "%d: %S\n" cut (Message_agent.head_within s cut))
    [ 3; 4; 5; 6 ];
  [%expect {|
    3: "ab"
    4: "ab"
    5: "ab"
    6: "ab\240\159\142\137"
    |}]
