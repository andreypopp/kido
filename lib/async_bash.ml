let derived_name command =
  let first = match Text.fields command with w :: _ -> Filename.basename w | [] -> "" in
  let name = String.filter (fun c -> Char.Ascii.is_alphanum c || String.contains "-_." c) first in
  if String.is_empty name then "bash"
  else String.sub name 0 (min (String.length name) Run_window.max_name_len)

let stream_env tmux =
  match Tmux.exec tmux [ "show-environment"; "-g" ] with
  | Error _ -> []
  | Ok out ->
      String.lines out
      |> List.filter (fun line ->
          List.exists (fun name -> String.prefix ~pre:(name ^ "=") line) Async_stream.env_names)

let start_notifier ~exe ~dir id =
  let tmux = Tmux.create () in
  let env =
    Array.of_list
      (List.filter
         (fun kv ->
           not
             (String.prefix ~pre:"KIDO_STATE_DIR=" kv
             || List.exists (fun name -> String.prefix ~pre:(name ^ "=") kv) Async_stream.env_names
             ))
         (Array.to_list (Unix.environment ()))
      @ [ "KIDO_STATE_DIR=" ^ dir ]
      @ stream_env tmux)
  in
  match Unix.fork () with
  | 0 -> (
      (try ignore (Unix.setsid ()) with Unix.Unix_error _ -> ());
      let null = Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0 in
      List.iter (fun fd -> Unix.dup2 null fd) [ Unix.stdin; Unix.stdout; Unix.stderr ];
      let argv = [| exe; "run-wait"; "--notify"; Run.string_of_id id |] in
      try Unix.execve exe argv env with Unix.Unix_error _ -> exit 127)
  | _ -> ()

let async_bash ~dir ~self ~caller ~exe ~name ~stream (command, rest) =
  let open Result.Infix in
  let args = command :: rest in
  let line =
    if List.is_empty rest then command else String.concat " " (List.map Filename.quote args)
  in
  let name = if String.is_empty name then derived_name command else name in
  let* state = State.read ~dir (Tmux.create ()) in
  let* pane = State.caller_pane state self in
  let argv = [ "bash"; "-o"; "pipefail"; "-c"; line ^ " 2>&1 | tee \"$KIDO_RUN_OUTPUT\"" ] in
  let* created =
    Run_window.start
      ?parent:(Option.map (fun id -> Run.Run id) caller)
      ~kind:(if stream then Stream else Bash)
      ~dir ~name ~cwd:pane.current_path ~session:pane.session_id ~env:[] argv
    |> Result.map_err (function Run_window.Refused_name m | Run_window.Failed m -> m)
  in
  Run.create ~dir created.meta.id (String.concat " " args);
  start_notifier ~exe ~dir created.meta.id;
  Ok created

let%test_module "Tests" =
  (module struct
    (* Nothing a name is derived to may be a path, empty, or what tmux's parser cannot carry. *)
    let%expect_test "a window name derived from the command" =
      List.iter
        (fun c ->
          let name = derived_name c in
          Printf.printf "%S -> %s%s\n" c name
            (match Tmux.safe "name" name with Ok () -> "" | Error _ -> " UNSAFE"))
        [ "make -j8"; "/usr/bin/env python"; ""; "'"; "./x$y"; String.make 70 'a' ];
      [%expect
        {|
    "make -j8" -> make
    "/usr/bin/env python" -> env
    "" -> bash
    "'" -> bash
    "./x$y" -> xy
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" -> aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    |}]
  end)
