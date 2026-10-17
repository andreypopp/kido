let derived_name command =
  let first = match Text.fields command with w :: _ -> Filename.basename w | [] -> "" in
  let name = String.filter (fun c -> Char.Ascii.is_alphanum c || String.contains "-_." c) first in
  if String.is_empty name then "bash"
  else String.sub name 0 (min (String.length name) Run_window.max_name_len)

let async_bash ~dir ~self ~caller ~exe ~name ~stream (command, rest) =
  let open Result.Infix in
  let args = command :: rest in
  (* One word is a shell command line ("make -j8 && ./run"); several are an argv. *)
  let argv = if List.is_empty rest then [ "bash"; "-c"; command ] else args in
  let name = if String.is_empty name then derived_name command else name in
  let* () = Run_window.check_name name in
  let* state = State.read ~dir (Tmux.create ()) in
  let* pane = State.caller_pane state self in
  let id = Run.new_id () in
  Run.create ~dir id (String.concat " " args);
  Run.write_command ~dir id argv;
  let meta : Run.meta =
    {
      id;
      name;
      kind = (if stream then Stream else Bash);
      parent = caller;
      pane = None;
      pid = 0;
      cwd = pane.current_path;
      model = "";
      tools = [];
      keep_alive = false;
      started_at = Timestamp.now ();
    }
  in
  Run.write_meta ~dir meta;
  Run_window.create ~dir meta ~session:pane.session_id
    [ exe; "async-run"; "--run-id"; Run.string_of_id id ]

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
