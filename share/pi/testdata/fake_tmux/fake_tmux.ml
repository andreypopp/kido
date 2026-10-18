(* A fake tmux for the kido-pi TypeScript suite. It records the argv of every
   command it receives and answers list-panes and display-message from a pane
   table that the test writes. *)

let read_table () = Fake_common.read_rows "KIDO_FAKE_TMUX_PANES"

let key_of_token token =
  let fields =
    [
      "pane_id"; "session_id"; "window_id"; "pane_current_path"; "pane_program_status"; "pane_title";
    ]
  in
  if List.mem ~eq:String.equal token fields then token
  else if String.prefix ~pre:"@kido_" token then String.drop 1 token
  else ""

let value row key =
  if String.is_empty key then ""
  else
    match Yojson.Safe.Util.member key row with
    | `String s -> s
    | `Int i -> string_of_int i
    | `Bool true -> "1"
    | `Bool false -> ""
    | _ -> ""

let render row format =
  let buffer = Buffer.create (String.length format) in
  let length = String.length format in
  let rec go index =
    if index < length then
      if Char.equal format.[index] '#' && index + 1 < length && Char.equal format.[index + 1] '{'
      then (
        match String.index_from_opt format (index + 2) '}' with
        | Some close ->
            Buffer.add_string buffer
              (value row (key_of_token (String.sub format (index + 2) (close - index - 2))));
            go (close + 1)
        | None ->
            Buffer.add_char buffer format.[index];
            go (index + 1))
      else begin
        Buffer.add_char buffer format.[index];
        go (index + 1)
      end
  in
  go 0;
  Buffer.contents buffer

let rows_for_target rows target =
  match target with
  | None -> rows
  | Some target -> List.filter (fun row -> String.equal (value row "pane_id") target) rows

let run () =
  let argv = Array.to_list Sys.argv |> List.tl in
  let argv = match argv with "-u" :: rest -> rest | argv -> argv in
  Fake_common.log "KIDO_FAKE_TMUX_LOG" (`List (List.map (fun s -> `String s) argv));
  let rows = read_table () in
  match argv with
  | "set-option" :: _ -> ()
  | "list-panes" :: _ ->
      if String.equal (Fs.getenv "KIDO_FAKE_TMUX_FAIL") "1" then exit 1;
      Fake_common.wait_gate (Fs.getenv "KIDO_FAKE_TMUX_GATE");
      let format = Option.value ~default:"" (Fake_common.arg_after "-F" argv) in
      List.iter (fun row -> print_endline (render row format)) rows
  | "display-message" :: _ -> (
      match Fake_common.arg_after "-F" argv with
      | None -> exit 1
      | Some format ->
          List.iter
            (fun row -> print_endline (render row format))
            (rows_for_target rows (Fake_common.arg_after "-t" argv)))
  | [] -> exit 1
  | command :: _ ->
      prerr_endline ("fake tmux: unsupported command " ^ command);
      exit 1

let () = run ()
