let one_line s ~max =
  let b = Buffer.create (String.length s) in
  let rec clean i =
    if i < String.length s then begin
      let d = String.get_utf_8_uchar s i in
      let c = Uchar.to_int (Uchar.utf_decode_uchar d) in
      if (not (Uchar.utf_decode_is_valid d)) || c < 0x20 || (c >= 0x7F && c <= 0x9F) || c = 0xFFFD
      then Buffer.add_char b ' '
      else Buffer.add_utf_8_uchar b (Uchar.utf_decode_uchar d);
      clean (i + Uchar.utf_decode_length d)
    end
  in
  clean 0;
  let s = Buffer.contents b in
  String.rdrop_while (Char.equal ' ') (Msg.utf_8_prefix s max)

let option_keys = [ Tmux_vars.session; Tmux_vars.name; Tmux_vars.inbox; Tmux_vars.activity ]

let set_option tmux pane key value =
  ignore
    (Tmux.run tmux
       [
         "set-option";
         "-p";
         "-t";
         Tmux.string_of_pane_id pane;
         key;
         one_line value ~max:(String.length value);
       ])

let options ~id ~name ~inbox ~activity =
  List.map2
    (fun key value -> (key, value))
    option_keys
    [ Run.string_of_id id; name; inbox; activity ]

let agent_status ~dir ~pane ~id ~session_file ~inbox ~activity ~model ~name =
  let pid = Unix.getppid () and now = Timestamp.now () in
  let activity = one_line activity ~max:256 in
  Run.create_meta ~dir
    {
      id;
      name = "";
      kind = Pi;
      parent = None;
      pane = None;
      pid = 0;
      cwd = Sys.getcwd ();
      model = "";
      tools = [];
      started_at = now;
    };
  Run.write_pi ~dir id ~holder:pid
    { pid; pane; ts = now; inbox; activity; model; name; session_file }
  |> Result.map (fun () ->
      Option.iter
        (fun pane ->
          let tmux = Tmux.create () in
          set_option tmux pane Tmux_vars.run (Run.string_of_id id);
          List.iter
            (fun (key, value) -> set_option tmux pane key value)
            (options ~id ~name ~inbox ~activity))
        pane)

let set_activity ~dir (id, (s : Run.pi)) activity =
  let activity = one_line activity ~max:256 in
  Run.write_pi ~dir id ~holder:s.pid { s with activity }
  |> Result.map (fun () ->
      Option.iter (fun pane -> set_option (Tmux.create ()) pane Tmux_vars.activity activity) s.pane)

let unclaim ~pane =
  let tmux = Tmux.create () in
  List.iter
    (fun key ->
      ignore (Tmux.run tmux [ "set-option"; "-u"; "-p"; "-t"; Tmux.string_of_pane_id pane; key ]))
    option_keys

let%test_module "Tests" =
  (module struct
    let%expect_test "one_line blanks control bytes and cuts on a rune boundary" =
      List.iter
        (fun (s, max) -> Printf.printf "[%s]\n" (one_line s ~max))
        [
          ("line one\nline two\tend", 256);
          ("trailing   ", 256);
          ("héllo", 2);
          ("héllo", 3);
          ("bad \xff byte", 256);
          ("\x1b[31mred", 256);
        ];
      [%expect
        {|
    [line one line two end]
    [trailing]
    [h]
    [hé]
    [bad   byte]
    [ [31mred]
    |}]
  end)
