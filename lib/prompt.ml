open Tmux

let deliver_or_paste ~paste ~inbox ~payload ~pane text =
  match
    if String.is_empty inbox then Error (Msg.Unavailable "") else Msg.deliver ~path:inbox payload
  with
  | Ok () -> `Inbox
  | Error (Unavailable _) ->
      paste pane text;
      `Pasted
  | Error (Refused m | Failed m) -> failwith m

let in_scope (self : Pane.t) ~whole_session (p : Pane.t) =
  String.equal p.session_name self.session_name
  && (whole_session || p.window_index = self.window_index)

let agent_panes_in panes states ~pi self ~whole_session =
  List.filter
    (fun (p : Pane.t) ->
      in_scope self ~whole_session p
      && Option.is_none (Pane.run_pane panes p.window_id)
      && State.is_agent_pane states ~pi p)
    panes

let needs_sweep panes states self ~whole_session =
  List.exists
    (fun (p : Pane.t) ->
      in_scope self ~whole_session p
      && (not (State.Panes.mem p.pane_id states))
      && Procs.maybe_pi p.current_command)
    panes

let prompt ~dir ~self ~window text =
  let text = String.chop_suffix ~suf:"\n" text |> Option.get_or ~default:text in
  if String.is_empty text then begin
    prerr_endline "no prompt given";
    1
  end
  else
    let panes = Exec.list_panes () in
    let self =
      match List_agents.find_pane panes self with
      | Some p -> p
      | None -> failwith (Printf.sprintf "pane %S not found" self)
    in
    let states = State.by_pane (State.load_live ~dir) in
    let sweep = lazy (Procs.sweep ()).pi in
    let candidates whole_session =
      let pi =
        if needs_sweep panes states self ~whole_session then Lazy.force sweep
        else Procs.Int_set.empty
      in
      agent_panes_in panes states ~pi self ~whole_session
    in
    match match candidates false with [] when not window -> candidates true | found -> found with
    | [] ->
        prerr_endline "agent not found";
        4
    | [ p ] ->
        let inbox =
          Option.map_or ~default:""
            (fun (_, (s : State.session)) -> s.inbox)
            (State.Panes.find_opt p.pane_id states)
        in
        ignore (deliver_or_paste ~paste:Exec.send_prompt ~inbox ~payload:text ~pane:p.pane_id text);
        0
    | _ ->
        prerr_endline "multiple agents found";
        5
