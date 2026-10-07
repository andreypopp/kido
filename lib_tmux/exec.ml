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
let global_option name = Result.get_or ~default:"" (exec [ "show-options"; "-gqv"; name ])

let list_panes ?socket () =
  Result.map
    (fun out -> Pane.parse (lines out))
    (exec ?socket [ "list-panes"; "-a"; "-F"; Pane.format ])

let capture_pane ?socket pane = Result.map lines (exec ?socket [ "capture-pane"; "-p"; "-t"; pane ])
let capture_screen ?socket pane = exec ?socket [ "capture-pane"; "-p"; "-t"; pane; "-S"; "-1000" ]

let current_client () =
  Result.get_or ~default:"" (exec [ "display-message"; "-p"; "#{client_name}" ])

type client_state = { session : string; session_id : string; focused : bool }

let side_focus_flag = "side-status-focus"

let client_format =
  String.concat Pane.sep
    [
      "#{client_name}";
      "#{client_session}";
      "#{session_id}";
      "#{client_flags}";
      "#{client_control_mode}";
    ]

let client_fields line =
  match String.split ~by:Pane.sep line with
  | name :: session :: session_id :: flags :: control :: _ ->
      Some (name, session, session_id, flags, control)
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

let real_clients lines =
  List.filter_map
    (fun line ->
      match client_fields line with
      | Some (name, _, _, _, control) when not (String.is_empty name || String.equal control "1") ->
          Some name
      | _ -> None)
    lines

let resolve_client ~pane ~tmux_env =
  let live =
    if String.is_empty pane then None
    else
      match exec [ "display-message"; "-p"; "-t"; pane; "#{session_id}" ] with
      | Ok id when not (String.is_empty id) -> Some id
      | _ -> None
  in
  let target =
    match (live, String.split_on_char ',' tmux_env) with
    | Some id, _ -> Some id
    | None, _ :: _ :: id :: _ when not (String.is_empty id) -> Some ("$" ^ id)
    | None, _ -> None
  in
  match Option.map (fun t -> exec [ "list-clients"; "-t"; t; "-F"; client_format ]) target with
  | Some (Ok out) -> ( match real_clients (lines out) with [ c ] -> Some c | _ -> None)
  | _ -> None

let step ~next i n = (i + (if next then 1 else -1) + n) mod n

let switch_session ~socket ~client ~next =
  Result.flat_map
    (fun panes ->
      let sessions = Array.of_list (Pane.order_sessions panes) in
      if Array.length sessions < 2 then Ok None
      else
        let current = client_state ?socket client in
        match
          Array.find_idx
            (fun (s : Pane.session) ->
              Option.exists (fun c -> String.equal c.session s.name) current)
            sessions
        with
        | Some (i, _) -> (
            let target = sessions.(step ~next i (Array.length sessions)) in
            let active =
              List.find_opt (fun (p : Pane.t) -> p.active) (List.concat target.windows)
            in
            match active with
            | Some p ->
                Result.map
                  (fun () -> Some (target.id, p.window_id))
                  (run ?socket [ "switch-client"; "-c"; client; "-t"; target.id ])
            | None -> Ok None)
        | None -> Ok None)
    (list_panes ?socket ())

let window_target ~next ~window windows =
  let panes = List.concat_map fst windows in
  let windows = Array.of_list windows in
  let first ((w : Pane.t list), _) = List.hd w in
  let n = Array.length windows in
  let unmarked j = List.for_all (fun (p : Pane.t) -> Option.is_none p.run) (fst windows.(j)) in
  let rec find j k =
    if k = 0 then None else if unmarked j then Some j else find (step ~next j n) (k - 1)
  in
  match Array.find_idx (fun w -> String.equal (first w).window_id window) windows with
  | None -> None
  | Some (i, (_, anchor)) -> (
      match
        if next then None
        else
          Option.flat_map
            (fun anchor -> List.find_opt (fun (p : Pane.t) -> String.equal p.pane_id anchor) panes)
            anchor
      with
      | Some parent -> Some parent
      | None -> (
          match find (step ~next i n) n with
          | Some j when j <> i -> Some (first windows.(j))
          | _ -> None))

let switch_window ?socket ~client ~next windows =
  let active =
    Option.flat_map
      (fun c ->
        List.find_opt
          (fun (p : Pane.t) -> String.equal p.session_name c.session && p.active)
          (List.concat_map fst windows))
      (client_state ?socket client)
  in
  match
    Option.flat_map (fun (a : Pane.t) -> window_target ~next ~window:a.window_id windows) active
  with
  | Some target ->
      Result.map
        (fun () -> Some (target.session_id, target.window_id))
        (run ?socket
           [
             "switch-client";
             "-c";
             client;
             "-t";
             target.session_id;
             ";";
             "select-window";
             "-t";
             target.window_id;
           ])
  | None -> Ok None

let release_args client = [ "refresh-client"; "-t"; client; "-f"; "!" ^ side_focus_flag ]

let jump ?socket ~client ~session ~window pane =
  run ?socket
    ([
       "switch-client";
       "-c";
       client;
       "-t";
       session ^ ":" ^ window ^ "." ^ pane;
       ";";
       "select-window";
       "-t";
       session ^ ":" ^ window;
       ";";
       "select-pane";
       "-t";
       pane;
       ";";
     ]
    @ release_args client)

let release_side_focus ?socket client = run ?socket (release_args client)

let send_prompt pane text =
  let buf = Printf.sprintf "kido-prompt-%d" (Unix.getpid ()) in
  let open Result.Infix in
  let* _ = exec ~stdin:text [ "load-buffer"; "-b"; buf; "-" ] in
  let* () =
    Result.map_err
      (fun e ->
        ignore (exec [ "delete-buffer"; "-b"; buf ]);
        e)
      (run [ "paste-buffer"; "-b"; buf; "-d"; "-t"; pane; "-p" ])
  in
  (* A paste-sensitive reader, Claude Code included, takes an Enter sent with
     the paste as part of the pasted text. *)
  Unix.sleepf 0.1;
  run [ "send-keys"; "-t"; pane; "Enter" ]

(* On a closed window the fork's display-message exits 0 and prints an empty
   line, so only the echoed id answers. *)
let window_exists ?socket window_id =
  match exec ?socket [ "display-message"; "-p"; "-t"; window_id; "#{window_id}" ] with
  | Ok out -> String.equal out window_id
  | Error _ -> false

type window = { window_id : string; pane_id : string; pane_pid : int }

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
         session ^ ":";
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
        match int_of_string_opt pid with
        | Some pane_pid -> Ok { window_id; pane_id; pane_pid }
        | None -> Error (Printf.sprintf "new-window: unexpected pane_pid %S" pid))
    | _ -> Error (Printf.sprintf "new-window: unexpected output %S" out)
  in
  (* A command that exits fast enough always beats remain-on-exit; losing that
     race is not a failure to create the window. *)
  if not remain_on_exit then Ok w
  else
    match exec ?socket [ "set-option"; "-p"; "-t"; w.pane_id; "remain-on-exit"; "on" ] with
    | Error e when window_exists ?socket w.window_id -> Error e
    | Ok _ | Error _ -> Ok w

let new_shell ~socket ~session ~cwd =
  let open Result.Infix in
  if String.is_empty cwd then Error "no current pane directory"
  else
    let* out =
      exec ?socket
        ((match session with
           | Some session -> [ "new-window"; "-t"; session ^ ":" ]
           | None -> [ "new-session" ])
        @ [ "-d"; "-P"; "-F"; "#{session_id}:#{window_id}:#{pane_id}"; "-c"; cwd ])
    in
    match String.split ~by:":" out with
    | [ session; window; pane ] -> Ok (session, window, pane)
    | _ -> Error (Printf.sprintf "created shell but could not read its location: %S" out)

let kill_window ?socket window_id = run ?socket [ "kill-window"; "-t"; window_id ]
let kill_pane ?socket pane_id = run ?socket [ "kill-pane"; "-t"; pane_id ]
let mark_run pane_id run_id = run [ "set-option"; "-p"; "-t"; pane_id; Pane.run_option; run_id ]
