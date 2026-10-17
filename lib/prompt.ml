open Tmux

let not_accepting ~name ~run =
  name ^ " is not accepting messages"
  ^ Option.map_or ~default:""
      (fun run ->
        Printf.sprintf "; after it exits, resume it with spawn_subagent(resume: %s) and resend"
          (Run.string_of_id run))
      run

let send_prompt pane text =
  let tmux = Tmux.create () in
  let buf = Printf.sprintf "kido-prompt-%d" (Unix.getpid ()) in
  let open Result.Infix in
  let* _ = Tmux.exec tmux ~stdin:text [ "load-buffer"; "-b"; buf; "-" ] in
  let* () =
    Result.map_err
      (fun e ->
        ignore (Tmux.exec tmux [ "delete-buffer"; "-b"; buf ]);
        e)
      (Tmux.run tmux [ "paste-buffer"; "-b"; buf; "-d"; "-t"; string_of_pane_id pane; "-p" ])
  in
  (* A paste-sensitive reader, Claude Code included, takes an Enter sent with
     the paste as part of the pasted text. *)
  Unix.sleepf 0.1;
  Tmux.run tmux [ "send-keys"; "-t"; string_of_pane_id pane; "Enter" ]

let deliver_or_paste ~inbox ~payload ~pane ~name ~run text =
  if String.is_empty inbox then
    match pane with
    | None -> Error "pane \"\" not found"
    | Some pane -> Result.map (fun () -> `Pasted) (send_prompt pane text)
  else
    match Msg.deliver ~path:inbox payload with
    | Ok () -> Ok `Inbox
    | Error (Unavailable _) -> Error (not_accepting ~name ~run)
    | Error (Refused m | Failed m) -> Error m

let in_scope (self : Tmux_pane.t) ~whole_session (p : Tmux_pane.t) =
  String.equal p.session_name self.session_name
  && (whole_session || p.window_index = self.window_index)

type error = No_prompt | Not_found | Several | Failed of string

let prompt ~dir ~self ~window text =
  let open Result.Infix in
  let failed r = Result.map_err (fun m -> Failed m) r in
  if String.is_empty text then Error No_prompt
  else
    let* panes = failed (Tmux_pane.list_panes (Tmux.create ())) in
    let* self = failed (List_runs.caller_pane panes self) in
    let runs = Run.marked ~dir panes in
    let states = Run.agents runs in
    let candidates whole_session =
      List.filter_map
        (fun (p : Tmux_pane.t) ->
          if
            (not (in_scope self ~whole_session p))
            || Option.is_some (Run.window_pane ~runs panes p.window_id)
          then None
          else
            match Pane_kind.classify ~states p with
            | Terminal | Ssh { pane = Remote_terminal; _ } -> None
            | (Some_agent _ | Pi_agent _ | Ssh _) as kind -> Some (p, kind))
        panes
    in
    match match candidates false with [] when not window -> candidates true | found -> found with
    | [] -> Error Not_found
    | [ (p, kind) ] ->
        let inbox, name =
          match kind with
          | Pi_agent { pi; _ } -> (pi.inbox, Run.display_name panes pi)
          | Some_agent _ | Terminal | Ssh _ -> ("", p.title)
        in
        failed
          (Result.map ignore
             (deliver_or_paste ~inbox ~payload:text ~pane:(Some p.pane_id) ~name ~run:None text))
    | _ -> Error Several
