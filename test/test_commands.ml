open Kido
open Fixture

(* A pane in a window with a run pane is a subagent's, never a prompt target; with the run mark
   gone, the same pane is one. *)
let%expect_test "prompt never targets a subagent's window" =
  let self = pane ~session:"alpha" ~window:"@0" "%1" in
  let panes run =
    [
      self;
      pane ~session:"alpha" ~window:"@1" ~index:1 ~cmd:"claude" "%2";
      pane ~session:"alpha" ~window:"@2" ~index:2 ~cmd:"claude" ?run "%3";
    ]
  in
  List.iter
    (fun run ->
      Prompt.agent_panes_in (panes run) State.String_map.empty ~pi:Procs.Int_set.empty self
        ~whole_session:true
      |> List.map (fun (p : Tmux.Pane.t) -> p.pane_id)
      |> String.concat " " |> print_endline)
    [ Some "run-abc"; None ];
  [%expect {|
    %2
    %2 %3
    |}]

let%expect_test "prompt refuses an empty prompt before asking tmux" =
  List.iter
    (fun text ->
      print_endline
        (match Prompt.prompt ~dir:"/nonexistent" ~self:"%1" ~window:false text with
        | Error No_prompt -> "no prompt"
        | Ok () | Error (Not_found | Several | Failed _) -> "WRONG"))
    [ ""; "\n" ];
  [%expect {|
    no prompt
    no prompt
    |}]
