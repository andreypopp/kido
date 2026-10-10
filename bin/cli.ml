let error name msg =
  Printf.eprintf "%s: %s\n%!" (if String.is_empty name then "kido" else "kido " ^ name) msg

let run name body =
  let fail msg =
    error name msg;
    1
  in
  match
    let code = body () in
    flush stdout;
    code
  with
  | code -> code
  (* sigpipe is ignored for the inbox sockets, so a closed stdout arrives as strerror(EPIPE) *)
  | exception Sys_error m when String.equal m (Unix.error_message Unix.EPIPE) ->
      Sys.set_signal Sys.sigpipe Sys.Signal_default;
      Unix.kill (Unix.getpid ()) Sys.sigpipe;
      1
  | exception Failure msg -> fail msg
  | exception Sys_error msg -> fail msg
  | exception Yojson.Json_error msg -> fail msg
  | exception Unix.Unix_error (e, fn, arg) -> fail (Fs.unix_message e fn arg)

let width s = String.fold (fun n c -> if Char.code c land 0xC0 = 0x80 then n else n + 1) 0 s

let table rows =
  let widths =
    List.fold_left
      (fun ws row -> List.map2 (fun w c -> max w (width c + 2)) ws row)
      (List.map (Fun.const 0) (List.hd rows))
      rows
  in
  List.iter
    (fun row ->
      let cells = List.combine widths row in
      List.iteri
        (fun i (w, c) ->
          print_string c;
          if i < List.length cells - 1 then print_string (String.make (w - width c) ' '))
        cells;
      print_newline ())
    rows
