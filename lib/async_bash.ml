let derived_name command =
  let first =
    match Procs.split_fields command with (w :: _) :: _ -> Filename.basename w | _ -> ""
  in
  let name = String.filter (fun c -> Char.Ascii.is_alphanum c || String.contains "-_." c) first in
  if String.is_empty name then "bash"
  else String.sub name 0 (min (String.length name) Spawn_subagent.max_window_name_len)

let async_bash ~dir ~self ~exe ~name ~stream (command, rest) =
  let open Result.Infix in
  let args = command :: rest in
  (* One word is a shell command line ("make -j8 && ./run"); several are an argv. *)
  let argv = if List.is_empty rest then [ "bash"; "-c"; command ] else args in
  let name = if String.is_empty name then derived_name command else name in
  let* () = Spawn_subagent.check_window_name name in
  let* pane, parent, depth = Spawn_subagent.caller ~dir ~self Adopt in
  let id = Subrun.new_id () in
  Subrun.create ~dir id (String.concat " " args);
  Subrun.write_command ~dir id argv;
  let meta : Subrun.meta =
    {
      id;
      name;
      kind = (if stream then Stream else Bash);
      parent_session = Option.map_or ~default:"" (fun (p : State.parent) -> p.session) parent;
      depth;
      pane = None;
      pid = 0;
      cwd = pane.current_path;
      model = "";
      tools = [];
      keep_alive = false;
      started_at = Timestamp.now ();
    }
  in
  Subrun.write_meta ~dir meta;
  let env = Spawn_subagent.run_env ~dir id parent depth in
  Spawn_subagent.create_run_window ~dir meta ~session:pane.session_id ~env
    [ exe; "async-run"; "--run-id"; Subrun.string_of_id id ]

let%test_module "Tests" =
  (module struct
    (* Nothing a name is derived to may be a path, empty, or what tmux's parser cannot carry. *)
    let%expect_test "a window name derived from the command" =
      List.iter
        (fun c ->
          let name = derived_name c in
          Printf.printf "%S -> %s%s\n" c name
            (match Launch.tmux_safe "name" name with Ok () -> "" | Error _ -> " UNSAFE"))
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
