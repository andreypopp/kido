(* A fake tmux for the kido-pi TypeScript suite. It records the argv of every
   command it receives and answers list-panes and display-message from a pane
   table that the test writes. *)

let getenv key = Option.value ~default:"" (Sys.getenv_opt key)
let json_of_strings strings = `List (List.map (fun s -> `String s) strings)

let append path text =
  if not (String.is_empty path) then
    Out_channel.with_open_gen [ Open_append; Open_creat ] 0o644 path (fun channel ->
        Out_channel.output_string channel text)

let log_json argv =
  append (getenv "KIDO_FAKE_TMUX_LOG") (Yojson.Safe.to_string (json_of_strings argv) ^ "\n")

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

let arg_after flag args =
  let rec find = function
    | [] -> None
    | key :: value :: _ when String.equal key flag -> Some value
    | _ :: rest -> find rest
  in
  find args

let has flag args = List.exists (String.equal flag) args

let rows_for_target rows target =
  match target with
  | None -> rows
  | Some target -> List.filter (fun row -> String.equal (value row "pane_id") target) rows

let run () =
  let argv = Array.to_list Sys.argv |> List.tl in
  let argv = match argv with "-u" :: rest -> rest | argv -> argv in
  log_json argv;
  let rows = read_table () in
  match argv with
  | "set-option" :: _ | "set" :: _ -> ()
  | "list-panes" :: _ ->
      if String.equal (getenv "KIDO_FAKE_TMUX_FAIL") "1" then exit 1;
      Fake_common.wait_gate (getenv "KIDO_FAKE_TMUX_GATE");
      let format = Option.value ~default:"" (arg_after "-F" argv) in
      let rows = if has "-a" argv then rows else rows_for_target rows (arg_after "-t" argv) in
      List.iter (fun row -> print_endline (render row format)) rows
  | "display-message" :: _ -> (
      match arg_after "-F" argv with
      | None -> exit 1
      | Some format ->
          List.iter
            (fun row -> print_endline (render row format))
            (rows_for_target rows (arg_after "-t" argv)))
  | [] -> exit 1
  | command :: _ ->
      prerr_endline ("fake tmux: unsupported command " ^ command);
      exit 1

let () = run ()
