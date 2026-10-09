open Tmux

let not_accepting ~name ~run =
  name ^ " is not accepting messages"
  ^ Option.map_or ~default:""
      (fun run ->
        Printf.sprintf "; after it exits, resume it with spawn_subagent(resume: %s) and resend" run)
      run

let deliver_or_paste ~inbox ~payload ~pane ~name ~run text =
  if String.is_empty inbox then
    match pane with
    | None -> Error "pane \"\" not found"
    | Some pane -> Result.map (fun () -> `Pasted) (Exec.send_prompt pane text)
  else
    match Msg.deliver ~path:inbox payload with
    | Ok () -> Ok `Inbox
    | Error (Unavailable _) -> Error (not_accepting ~name ~run)
    | Error (Refused m | Failed m) -> Error m

let in_scope (self : Pane.t) ~whole_session (p : Pane.t) =
  String.equal p.session_name self.session_name
  && (whole_session || p.window_index = self.window_index)

let needs_sweep panes states self ~whole_session =
  List.exists
    (fun (p : Pane.t) ->
      in_scope self ~whole_session p
      && (not (Tmux.Pane.Map.mem p.pane_id states))
      && Procs.maybe_pi p.current_command)
    panes

type error = No_prompt | Not_found | Several | Failed of string

let prompt ~dir ~self ~window text =
  let open Result.Infix in
  let failed r = Result.map_err (fun m -> Failed m) r in
  if String.is_empty text then Error No_prompt
  else
    let* panes = failed (Exec.list_panes ()) in
    let* self = failed (List_runs.caller_pane panes self) in
    let states = State.by_pane (State.load_live ~dir) in
    let sweep = lazy (Procs.sweep ()).pi in
    let candidates whole_session =
      let pi =
        if needs_sweep panes states self ~whole_session then Lazy.force sweep
        else Procs.Int_set.empty
      in
      List.filter
        (fun (p : Pane.t) ->
          in_scope self ~whole_session p
          && Option.is_none (Pane.run_pane panes p.window_id)
          && State.is_agent_pane states ~pi p)
        panes
    in
    match match candidates false with [] when not window -> candidates true | found -> found with
    | [] -> Error Not_found
    | [ p ] ->
        let inbox, name =
          Option.map_or ~default:("", p.title)
            (fun (_, (s : State.session)) -> (s.inbox, State.display_name panes s))
            (Tmux.Pane.Map.find_opt p.pane_id states)
        in
        failed
          (Result.map ignore
             (deliver_or_paste ~inbox ~payload:text ~pane:(Some p.pane_id) ~name ~run:p.run text))
    | _ -> Error Several
