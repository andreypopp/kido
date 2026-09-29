let answer b =
  print_endline (Bool.to_string b);
  0

let usage cmd session =
  if String.is_empty session then failwith (Printf.sprintf "usage: kido %s SESSION" cmd)

let agent_alive ~dir session =
  usage "agent-alive" session;
  answer (List.mem_assoc ~eq:String.equal session (State.load_live ~dir))

let children_alive ~dir session =
  usage "children-alive" session;
  let runs = Filename.concat dir "runs" in
  answer
    (List.exists
       (fun id ->
         match Subrun.read_meta ~dir:runs id with
         | Some m ->
             String.equal m.parent_session session
             && Option.is_none (Subrun.effective_outcome ~dir:runs id ~pid:m.pid)
         | None -> false)
       (Subrun.list ~dir:runs))
