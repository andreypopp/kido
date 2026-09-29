let set_status ~dir ~self activity =
  match State.Panes.find_opt self (State.by_pane (State.load_live ~dir)) with
  | None ->
      failwith
        (Printf.sprintf
           "no agent session has reported pane %S; there is nothing to set an activity on" self)
  | Some (id, s) -> (
      match State.record ~dir id { s with activity = Reporting.one_line activity ~max:256 } with
      | Ok () -> 0
      | Error holder -> failwith (State.held_message id holder))
