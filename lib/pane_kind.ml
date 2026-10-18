type t =
  | Terminal
  | Some_agent of { name : string }
  | Pi_agent of { session : string; name : string; inbox : string; activity : string }
  | Ssh of { user : string; host : string; pane : ssh_kind }

and ssh_kind = Remote_terminal | Remote_agent of { name : string }

let option = Option.value ~default:""

let classify (p : State.pane) =
  let app =
    Tmux.Program_status.root p.program_status
    |> Option.flat_map (fun (r : Tmux.Program_status.record) -> r.app)
  in
  match (p.ssh, p.current_command, app) with
  | Some (user, host), "ssh", app ->
      let pane =
        match app with
        | Some (("pi" | "claude-code") as name) -> Remote_agent { name }
        | _ -> Remote_terminal
      in
      Ssh { user; host; pane }
  | _, _, Some "pi" -> (
      match p.session with
      | Some session ->
          Pi_agent
            { session; name = option p.name; inbox = option p.inbox; activity = option p.activity }
      | None -> Some_agent { name = "pi" })
  | _, _, Some "claude-code" -> Some_agent { name = "claude-code" }
  | _ -> Terminal

let title (p : State.pane) = function
  | Ssh { pane = Remote_terminal; _ } -> None
  | Some_agent { name } | Ssh { pane = Remote_agent { name }; _ } ->
      Some (if String.is_empty p.title then name else p.title)
  | Terminal -> None
  | Pi_agent { name; _ } -> Some (if String.is_empty name then p.title else name)

let display_name state (s : Run.pi) =
  if not (String.is_empty s.name) then s.name
  else
    Option.bind (Option.bind s.pane (State.find state)) (fun p -> title p (classify p))
    |> Option.value ~default:""
