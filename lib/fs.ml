let getenv name = Option.get_or ~default:"" (Sys.getenv_opt name)
let is_file p = try Sys.file_exists p && not (Sys.is_directory p) with Sys_error _ -> false

let is_executable p =
  is_file p && match Unix.access p [ X_OK ] with () -> true | exception Unix.Unix_error _ -> false

let clean p =
  let rec go acc = function
    | [] -> List.rev acc
    | ("" | ".") :: rest -> go acc rest
    | ".." :: rest -> go (match acc with [] -> [] | _ :: acc -> acc) rest
    | seg :: rest -> go (seg :: acc) rest
  in
  "/" ^ String.concat "/" (go [] (String.split_on_char '/' p))

let abs p = clean (if Filename.is_relative p then Filename.concat (Sys.getcwd ()) p else p)

let look_path ~path name =
  String.split_on_char ':' path
  |> List.map (fun dir -> Filename.concat (if String.is_empty dir then "." else dir) name)
  |> List.find_opt is_executable

let invoked_path ~path arg0 =
  let found =
    if String.contains arg0 '/' then Some arg0
    else if String.is_empty arg0 then None
    else look_path ~path arg0
  in
  match Option.map abs found with Some p when is_file p -> p | _ -> Sys.executable_name

let candidates exe =
  match Unix.realpath exe with
  | resolved when not (String.equal resolved exe) -> [ exe; resolved ]
  | _ | (exception Unix.Unix_error _) -> [ exe ]

let self = lazy (invoked_path ~path:(getenv "PATH") Sys.argv.(0))

let write_all fd s =
  let rec go off =
    if off < String.length s then go (off + Unix.write_substring fd s off (String.length s - off))
  in
  go 0

let rec mkdir_p ?(perm = 0o755) d =
  if not (Sys.file_exists d) then begin
    mkdir_p (Filename.dirname d);
    try Unix.mkdir d perm with Unix.Unix_error (EEXIST, _, _) -> ()
  end

let read path =
  try Some (In_channel.with_open_bin path In_channel.input_all) with Sys_error _ -> None

let read_json path of_yojson =
  Option.flat_map
    (fun raw ->
      try Some (of_yojson (Yojson.Safe.from_string raw))
      with Yojson.Json_error _ | Ppx_yojson_conv_lib.Yojson_conv.Of_yojson_error _ -> None)
    (read path)

let write ?(perm = 0o644) path s =
  Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_trunc; Open_binary ] perm path
    (fun oc -> Out_channel.output_string oc s)

let remove path = try Unix.unlink path with Unix.Unix_error (ENOENT, _, _) -> ()

let write_temp ?(perm = 0o644) path data place =
  let rec create_unique () =
    let tmp = Printf.sprintf "%s.tmp.%d.%d" path (Unix.getpid ()) (Random.bits ()) in
    match Unix.openfile tmp [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] perm with
    | fd -> (tmp, fd)
    | exception Unix.Unix_error (Unix.EEXIST, _, _) -> create_unique ()
  in
  let tmp, fd = create_unique () in
  Fun.protect
    ~finally:(fun () -> remove tmp)
    (fun () ->
      Fun.protect
        ~finally:(fun () -> Unix.close fd)
        (fun () -> ignore (Unix.write_substring fd data 0 (String.length data)));
      place tmp path)

let write_atomic ?perm path data = write_temp ?perm path data Unix.rename

let unix_message e fn arg =
  String.concat " " (List.filter (fun s -> not (String.is_empty s)) [ fn; arg ])
  ^ ": " ^ Unix.error_message e

let%test_module "Tests" =
  (module struct
    let%expect_test "invoked_path: a bare name is looked up on PATH and left unresolved" =
      let dir = Filename.temp_dir "kido-tmux" "" in
      let show s =
        String.replace ~sub:dir ~by:"$DIR" (String.replace ~sub:(Unix.realpath dir) ~by:"$DIR" s)
      in
      let real = Filename.concat dir "real-kido" in
      Out_channel.with_open_bin real (fun oc -> output_string oc "#!/bin/sh\n");
      Unix.chmod real 0o755;
      Unix.symlink (Filename.concat dir "real-kido") (Filename.concat dir "kido-under-test");
      print_endline (show (invoked_path ~path:("/nonexistent:" ^ dir) "kido-under-test"));
      print_endline (show (invoked_path ~path:dir (Filename.concat dir "sub/../kido-under-test")));
      Printf.printf "empty falls back to the executable: %b\n"
        (String.equal (invoked_path ~path:dir "") Sys.executable_name);
      Printf.printf "a missing file falls back too: %b\n"
        (String.equal (invoked_path ~path:dir "not-there") Sys.executable_name);
      [%expect
        {|
    $DIR/kido-under-test
    $DIR/kido-under-test
    empty falls back to the executable: true
    a missing file falls back too: true
    |}]
  end)
