type t =
  | Terminal
  | Some_agent of { name : string }
  | Pi_agent of { id : string; pi : Run.pi }
  | Ssh of { user : string; host : string; pane : ssh_kind }

and ssh_kind = Remote_terminal | Remote_agent of { name : string }

let classify ~states (p : Tmux_pane.t) =
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
      match Tmux.Pane_map.find_opt p.pane_id states with
      | Some (id, pi) -> Pi_agent { id; pi }
      | None -> Some_agent { name = "pi" })
  | _, _, Some "claude-code" -> Some_agent { name = "claude-code" }
  | _ -> Terminal

let title (p : Tmux_pane.t) = function
  | Ssh { pane = Remote_terminal; _ } -> None
  | Ssh { pane = Remote_agent { name }; _ } ->
      Some (if String.is_empty p.title then name else p.title)
  | Terminal -> None
  | Pi_agent { pi; _ } -> Some (Run.display_name [ p ] pi)
  | Some_agent { name } -> Some (if String.is_empty p.title then name else p.title)

let%test_module "Tests" =
  (module struct
    open Tmux_pane_fixture

    let%expect_test "only a root app identifies a pane" =
      let p = pane ~cmd:"pi" "%1" in
      let states = Tmux.Pane_map.singleton p.pane_id ("local", Test_fixture.pi ()) in
      List.iter
        (fun (body, local) ->
          let status = Result.get_exn (Tmux.Program_status.parse body) in
          let p = { p with program_status = status } in
          let states = if local then states else Tmux.Pane_map.empty in
          let kind = classify ~states p in
          print_endline
            (match kind with
            | Terminal -> "terminal"
            | Some_agent { name } -> "native " ^ name
            | Pi_agent { id; _ } -> "local " ^ id
            | Ssh { user; host; _ } -> "ssh " ^ user ^ "@" ^ host))
        [
          ({|{"serial":1,"records":[]}|}, true);
          ({|{"serial":1,"records":[{"id":"child","app":"pi","state":"idle"}]}|}, true);
          ({|{"serial":1,"records":[{"id":"","app":"pi","state":"idle"}]}|}, true);
          ({|{"serial":1,"records":[{"id":"","app":"pi","state":"idle"}]}|}, false);
          ({|{"serial":1,"records":[{"id":"","app":"claude-code","state":"idle"}]}|}, true);
          ({|{"serial":1,"records":[{"id":"","app":"builder","state":"idle"}]}|}, true);
        ];
      [%expect
        {|
    terminal
    terminal
    local local
    native pi
    native claude-code
    terminal
    |}]
  end)
