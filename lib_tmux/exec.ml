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

let resolve_binary ~kido_tmux exe =
  match kido_tmux with
  | Some b when not (String.is_empty b) -> b
  | _ ->
      candidates exe
      |> List.map (fun c -> Filename.concat (Filename.dirname c) "kido-tmux")
      |> List.find_opt is_file |> Option.get_or ~default:"tmux"

let binary = lazy (resolve_binary ~kido_tmux:(Sys.getenv_opt "KIDO_TMUX") (Lazy.force self))
let argv bin args = Array.of_list (bin :: "-u" :: args)

let read_all fd =
  let buf = Buffer.create 4096 and chunk = Bytes.create 65536 in
  let rec go () =
    match Unix.read fd chunk 0 (Bytes.length chunk) with
    | 0 -> Buffer.contents buf
    | n ->
        Buffer.add_subbytes buf chunk 0 n;
        go ()
    | exception Unix.Unix_error (EINTR, _, _) -> go ()
  in
  go ()

let write_all fd s =
  let rec go off =
    if off < String.length s then go (off + Unix.write_substring fd s off (String.length s - off))
  in
  go 0

type process = { pid : int; stdin : Unix.file_descr; stdout : Unix.file_descr }

let spawn ?socket args =
  let bin = Lazy.force binary in
  let null = Unix.openfile "/dev/null" [ O_WRONLY; O_CLOEXEC ] 0 in
  let in_r, in_w = Unix.pipe ~cloexec:true () in
  let out_r, out_w = Unix.pipe ~cloexec:true () in
  let spawned =
    try
      Ok
        {
          pid =
            Unix.create_process bin
              (argv bin (Option.map_or ~default:[] (fun s -> [ "-S"; s ]) socket @ args))
              in_r out_w null;
          stdin = in_w;
          stdout = out_r;
        }
    with Unix.Unix_error (e, _, _) ->
      List.iter Unix.close [ in_w; out_r ];
      Error (Unix.error_message e)
  in
  List.iter Unix.close [ in_r; out_w; null ];
  spawned

let exec ?socket ?(stdin = "") args =
  let failed why = Error (Printf.sprintf "tmux %s: %s" (String.concat " " args) why) in
  match spawn ?socket args with
  | Error e -> failed e
  | Ok p -> (
      (try write_all p.stdin stdin with Unix.Unix_error (EPIPE, _, _) -> ());
      Unix.close p.stdin;
      let out =
        Fun.protect ~finally:(fun () -> Unix.close p.stdout) (fun () -> read_all p.stdout)
      in
      match snd (Unix.waitpid [] p.pid) with
      | WEXITED 0 -> Ok (String.trim out)
      | WEXITED n -> failed (Printf.sprintf "exit status %d" n)
      | WSIGNALED n | WSTOPPED n -> failed (Printf.sprintf "signal %d" n))

let run ?socket args = Result.map ignore (exec ?socket args)
let lines out = String.split_on_char '\n' out

let current_client () =
  Result.get_or ~default:"" (exec [ "display-message"; "-p"; "#{client_name}" ])

type client_state = { session : string; session_id : Session.id; focused : bool }

let side_focus_flag = "side-status-focus"
let client_sep = "\x1f"

let client_format =
  String.concat client_sep
    [
      "#{client_name}";
      "#{client_session}";
      "#{session_id}";
      "#{client_flags}";
      "#{client_control_mode}";
    ]

let client_fields line =
  match String.split ~by:client_sep line with
  | name :: session :: session_id :: flags :: control :: _ ->
      Option.map
        (fun session_id -> (name, session, session_id, flags, control))
        (Session.of_string session_id)
  | _ -> None

let parse_client_state lines client =
  List.find_map
    (fun line ->
      match client_fields line with
      | Some (name, session, session_id, flags, _) when String.equal name client ->
          Some { session; session_id; focused = String.mem ~sub:side_focus_flag flags }
      | _ -> None)
    lines

let client_state ?socket client =
  Option.flat_map
    (fun out -> parse_client_state (lines out) client)
    (Result.to_opt (exec ?socket [ "list-clients"; "-F"; client_format ]))

let release_args client = [ "refresh-client"; "-t"; client; "-f"; "!" ^ side_focus_flag ]

let jump ?socket ~client ~session ~window pane =
  run ?socket
    ([
       "switch-client";
       "-c";
       client;
       "-t";
       Session.to_string session ^ ":" ^ Window.to_string window ^ "." ^ Pane.to_string pane;
       ";";
       "select-window";
       "-t";
       Session.to_string session ^ ":" ^ Window.to_string window;
       ";";
       "select-pane";
       "-t";
       Pane.to_string pane;
       ";";
     ]
    @ release_args client)

let release_side_focus ?socket client = run ?socket (release_args client)

(* On a closed window the fork's display-message exits 0 and prints an empty
   line, so only the echoed id answers. *)
let window_exists ?socket window_id =
  match
    exec ?socket [ "display-message"; "-p"; "-t"; Window.to_string window_id; "#{window_id}" ]
  with
  | Ok out -> Option.equal Window.equal (Window.of_string out) (Some window_id)
  | Error _ -> false

type window = { window_id : Window.id; pane_id : Pane.id; pane_pid : int }

let new_window ?socket ?(remain_on_exit = true) ~session ~name ~cwd ~env command =
  let open Result.Infix in
  let* out =
    exec ?socket
      ([
         "new-window";
         "-d";
         "-P";
         "-F";
         "#{window_id}:#{pane_id}:#{pane_pid}";
         "-t";
         Session.to_string session ^ ":";
         "-n";
         name;
         "-c";
         cwd;
       ]
      @ List.concat_map (fun kv -> [ "-e"; kv ]) env
      @ command)
  in
  let* w =
    match String.split ~by:":" out with
    | [ window_id; pane_id; pid ] -> (
        match (Window.of_string window_id, Pane.of_string pane_id, int_of_string_opt pid) with
        | Some window_id, Some pane_id, Some pane_pid -> Ok { window_id; pane_id; pane_pid }
        | _, _, None -> Error (Printf.sprintf "new-window: unexpected pane_pid %S" pid)
        | _ -> Error (Printf.sprintf "new-window: unexpected output %S" out))
    | _ -> Error (Printf.sprintf "new-window: unexpected output %S" out)
  in
  (* A command that exits fast enough always beats remain-on-exit; losing that
     race is not a failure to create the window. *)
  if not remain_on_exit then Ok w
  else
    match
      exec ?socket [ "set-option"; "-p"; "-t"; Pane.to_string w.pane_id; "remain-on-exit"; "on" ]
    with
    | Error e when window_exists ?socket w.window_id -> Error e
    | Ok _ | Error _ -> Ok w

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

    let%expect_test "client state" =
      let clients =
        [
          String.concat client_sep [ "/dev/ttys001"; "other"; "$1"; "attached,UTF-8"; "0" ];
          String.concat client_sep
            [ "/dev/ttys012"; "work"; "$0"; "attached,side-status-focus,UTF-8"; "0" ];
          "junk";
        ]
      in
      List.iter
        (fun c ->
          Printf.printf "%s: %s\n" c
            (Option.map_or ~default:"-"
               (fun (s : client_state) ->
                 Printf.sprintf "%s %s focused=%b" s.session (Session.to_string s.session_id)
                   s.focused)
               (parse_client_state clients c)))
        [ "/dev/ttys012"; "/dev/ttys001"; "/dev/ttys999" ];
      [%expect
        {|
    /dev/ttys012: work $0 focused=true
    /dev/ttys001: other $1 focused=false
    /dev/ttys999: -
    |}]
  end)
