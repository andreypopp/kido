type pane_result = No_pane | Killed | Already_gone | Refused of string
type error = No_run of string | Ended of string

let wait_until ~within cond =
  let deadline = Unix.gettimeofday () +. within in
  let rec go () =
    cond ()
    || Float.(Unix.gettimeofday () < deadline)
       && begin
         Unix.sleepf 0.1;
         go ()
       end
  in
  go ()

let close_pane ~tmux ~dir = function
  | None -> No_pane
  | Some pane_id -> (
      match State.read ~dir tmux with
      | Error _ -> No_pane
      | Ok state -> (
          match State.find state pane_id with
          | None -> Already_gone
          | Some p -> (
              match Reap.close_of state p.window_id p.pane_id with
              | None ->
                  Refused "it is its session's only pane; killing it would destroy the session"
              | Some close -> (
                  match Reap.release tmux close with Ok () -> Killed | Error e -> Refused e))))

let signal pid s =
  match Unix.kill (-pid) s with
  | () -> ()
  | exception Unix.Unix_error _ -> ( try Unix.kill pid s with Unix.Unix_error _ -> ())

let stop ~dir ~wait ~escalation ~result id =
  let open Result.Infix in
  let* meta =
    Option.to_result
      (No_run (Printf.sprintf "run %s: no such run" (Run.string_of_id id)))
      (Run.read_meta ~dir id)
  in
  let* tmux = Result.map_err (fun m -> No_run m) (Server_dir.tmux ~dir) in
  let* state = Result.map_err (fun e -> No_run e) (State.read_run tmux meta) in
  let live =
    match State.run_pane state meta with Some p -> Option.is_none p.dead_at | None -> false
  in
  ignore (Run.record_outcome ~dir meta.id { result; text = ""; at = Some (Timestamp.now ()) });
  let ended () =
    match State.read_run tmux meta with
    | Error _ -> false
    | Ok s -> (
        match State.run_pane s meta with None -> true | Some p -> Option.is_some p.dead_at)
  in
  let finish () =
    let pid = if live then meta.pid else 0 in
    if (not (wait_until ~within:wait ended)) && pid > 0 then signal pid Sys.sigterm;
    if not (wait_until ~within:escalation ended) then begin
      if pid > 0 then signal pid Sys.sigkill;
      ignore (wait_until ~within:0.5 ended)
    end;
    let pane =
      match State.read_run tmux meta with
      | Ok s -> Option.map (fun (p : State.pane) -> p.pane_id) (State.run_pane s meta)
      | Error _ -> meta.pane
    in
    close_pane ~tmux ~dir pane
  in
  if live then Ok (finish ())
  else Error (Ended (Printf.sprintf "run %s has already ended" (Run.string_of_id id)))
