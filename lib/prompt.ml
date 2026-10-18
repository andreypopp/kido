open Tmux

let not_accepting ~name ~run =
  name ^ " is not accepting messages"
  ^
  match run with
  | Some run ->
      Printf.sprintf "; after it exits, resume it with spawn_subagent(resume: %s) and resend"
        (Run.string_of_id run)
  | None -> ""

let send_prompt ~tmux pane text =
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

type via = Inbox | Paste
type send = { pane : pane_id; target : pane_id; text : string }
type error_kind = Refused | Unknown | Invalid
type error = { kind : error_kind; message : string }

let deliver ~tmux ~inbox ~payload ~pane ~name ~run text =
  if String.is_empty inbox then
    match pane with
    | None -> Error { kind = Invalid; message = "pane \"\" not found" }
    | Some pane ->
        Result.map
          (fun () -> Paste)
          (Result.map_err
             (fun message -> { kind = Unknown; message })
             (send_prompt ~tmux pane text))
  else
    match Msg.deliver ~path:inbox payload with
    | Ok () -> Ok Inbox
    | Error (Unavailable _) -> Error { kind = Refused; message = not_accepting ~name ~run }
    | Error (Refused message) -> Error { kind = Refused; message }
    | Error (Failed message) -> Error { kind = Unknown; message }

type candidate = { pane : pane_id; session : session_id; window : window_id; title : string }
[@@deriving yojson_of]

type reachable = { candidate : candidate; inbox : string; name : string }

let reachable (state : State.t) (self : State.pane) =
  let own, rest =
    List.partition
      (fun (r : reachable) -> equal_window_id r.candidate.window self.window_id)
      (List.filter_map
         (fun (p : State.pane) ->
           if
             (not (String.equal p.session_name self.session_name))
             || Option.is_some (State.find_window_run state p.window_id)
           then None
           else
             let candidate kind =
               {
                 pane = p.pane_id;
                 session = p.session_id;
                 window = p.window_id;
                 title = Option.value ~default:"" (Pane_kind.title p kind);
               }
             in
             match Pane_kind.classify ~states:state.agents p with
             | Terminal | Ssh { pane = Remote_terminal; _ } -> None
             | Pi_agent { pi; _ } as kind ->
                 Some
                   {
                     candidate = candidate kind;
                     inbox = pi.inbox;
                     name = State.run_display_name state pi;
                   }
             | (Some_agent _ | Ssh _) as kind ->
                 Some { candidate = candidate kind; inbox = ""; name = p.title })
         state.panes)
  in
  own @ rest

let resolve ~tmux ~dir pane =
  let open Result.Infix in
  let* state = Result.map_err (fun message -> { kind = Refused; message }) (State.read ~dir tmux) in
  let* self =
    Result.map_err
      (fun message -> { kind = Invalid; message })
      (State.caller_pane state (Some pane))
  in
  Ok (List.map (fun (r : reachable) -> r.candidate) (reachable state self))

let send ~tmux ~dir { pane; target; text } =
  if String.is_empty text then Error { kind = Invalid; message = "no prompt given" }
  else
    let open Result.Infix in
    let* state =
      Result.map_err (fun message -> { kind = Refused; message }) (State.read ~dir tmux)
    in
    let* self =
      Result.map_err
        (fun message -> { kind = Invalid; message })
        (State.caller_pane state (Some pane))
    in
    match
      List.find_opt
        (fun (r : reachable) -> equal_pane_id r.candidate.pane target)
        (reachable state self)
    with
    | None ->
        Error
          {
            kind = Invalid;
            message =
              Printf.sprintf "pane %S is not a candidate of pane %S" (string_of_pane_id target)
                (string_of_pane_id pane);
          }
    | Some r ->
        deliver ~tmux ~inbox:r.inbox ~payload:text ~pane:(Some r.candidate.pane) ~name:r.name
          ~run:None text

type failure = No_prompt | Not_found | Several | Failed of string

let prompt ~dir ~self ~window text =
  let open Result.Infix in
  let failed r = Result.map_err (fun m -> Failed m) r in
  if String.is_empty text then Error No_prompt
  else
    let tmux = Tmux.create () in
    let* state = failed (State.read ~dir tmux) in
    let* self = failed (State.caller_pane state self) in
    let all = reachable state self in
    let in_window (r : reachable) = equal_window_id r.candidate.window self.window_id in
    let found = match List.filter in_window all with [] when not window -> all | found -> found in
    match found with
    | [] -> Error Not_found
    | [ r ] ->
        Result.map_err
          (fun (e : error) -> Failed e.message)
          (Result.map ignore
             (deliver ~tmux ~inbox:r.inbox ~payload:text ~pane:(Some r.candidate.pane) ~name:r.name
                ~run:None text))
    | _ -> Error Several
