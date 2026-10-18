type pane_result = No_pane | Killed | Already_gone | Refused of string
type error = No_run of string | Ended of string
type mode = Record_and_stop | Record_only | Cleanup [@@deriving equal]

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

let close_pane ~dir = function
  | None -> No_pane
  | Some pane_id -> (
      match State.read ~dir (Tmux.create ()) with
      | Error _ -> No_pane
      | Ok state -> (
          match State.find state pane_id with
          | None -> Already_gone
          | Some p -> (
              match Reap.close_of state p.window_id p.pane_id with
              | None ->
                  Refused "it is its session's only pane; killing it would destroy the session"
              | Some close -> (
                  match Reap.release (Tmux.create ()) close with
                  | Ok () -> Killed
                  | Error e -> Refused e))))

let signal pid s =
  match Unix.kill (-pid) s with
  | () -> ()
  | exception Unix.Unix_error _ -> ( try Unix.kill pid s with Unix.Unix_error _ -> ())

let read_run_pane (meta : Run.meta) =
  match meta.pane with None -> Ok State.empty | Some pane -> State.read_pane (Tmux.create ()) pane

let stop ~dir ~wait ~escalation ~result ?(text = "") ~mode id =
  match Run.read_meta ~dir id with
  | None -> Error (No_run (Printf.sprintf "run %s: no such run" (Run.string_of_id id)))
  | Some meta -> (
      match read_run_pane meta with
      | Error e -> Error (No_run e)
      | Ok state -> (
          let ended () =
            match read_run_pane meta with
            | Error _ -> false
            | Ok s -> (
                match State.run_pane s meta with None -> true | Some p -> Option.is_some p.dead_at)
          in
          let finish () =
            let live =
              match State.run_pane state meta with
              | Some p -> Option.is_none p.dead_at
              | None -> false
            in
            let pid = if live then meta.pid else 0 in
            if (not (wait_until ~within:wait ended)) && pid > 0 then signal pid Sys.sigterm;
            if not (wait_until ~within:escalation ended) then begin
              if pid > 0 then signal pid Sys.sigkill;
              ignore (wait_until ~within:0.5 ended)
            end;
            let pane =
              match read_run_pane meta with
              | Ok s -> Option.map (fun (p : State.pane) -> p.pane_id) (State.run_pane s meta)
              | Error _ -> meta.pane
            in
            close_pane ~dir pane
          in
          match mode with
          | Cleanup -> Ok (finish ())
          | Record_only | Record_and_stop -> (
              match State.run_ending ~dir state meta with
              | Some _ ->
                  Error (Ended (Printf.sprintf "run %s has already ended" (Run.string_of_id id)))
              | None -> (
                  if
                    not
                      (Run.record_outcome ~dir meta.id
                         { result; text; at = Some (Timestamp.now ()) })
                  then
                    Error (Ended (Printf.sprintf "run %s has already ended" (Run.string_of_id id)))
                  else
                    match mode with
                    | Record_only -> Ok No_pane
                    | Record_and_stop | Cleanup -> Ok (finish ())))))
