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

let panes_and_programs ?socket () =
  Result.map
    (fun out ->
      let panes, programs =
        List.fold_left
          (fun (panes, programs) line ->
            match String.index_opt line '\030' with
            | Some i ->
                ( String.sub line (i + 1) (String.length line - i - 1) :: panes,
                  String.sub line 0 i :: programs )
            | None -> (panes, programs))
          ([], []) (lines out)
      in
      (Pane.parse (List.rev panes), Program_status.parse_lines programs))
    (exec ?socket [ "list-panes"; "-a"; "-F"; Program_status.format ^ "\030" ^ Pane.format ])

let capture_screen ?socket pane =
  exec ?socket [ "capture-pane"; "-p"; "-t"; Pane.to_string pane; "-S"; "-1000" ]

let current_client () =
  Result.get_or ~default:"" (exec [ "display-message"; "-p"; "#{client_name}" ])

type client_state = { session : string; session_id : Session.id; focused : bool }

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
    match pane with
    | None -> None
    | Some pane -> (
        match exec [ "display-message"; "-p"; "-t"; Pane.to_string pane; "#{session_id}" ] with
        | Ok id -> Session.of_string id
        | _ -> None)
  in
  let target =
    match (live, String.split_on_char ',' tmux_env) with
    | Some id, _ -> Some id
    | None, _ :: _ :: id :: _ when not (String.is_empty id) -> Session.of_string ("$" ^ id)
    | None, _ -> None
  in
  match
    Option.map
      (fun t -> exec [ "list-clients"; "-t"; Session.to_string t; "-F"; client_format ])
      target
  with
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
                  (run ?socket [ "switch-client"; "-c"; client; "-t"; Session.to_string target.id ])
            | None -> Ok None)
        | None -> Ok None)
    (list_panes ?socket ())

let window_target ~next ~session ~window windows =
  let first ((panes : Pane.t list), _) = List.hd panes in
  let parent ((_, anchor) as w) =
    Option.flat_map
      (fun anchor ->
        List.find_opt
          (fun candidate ->
            Session.equal (first candidate).session_id (first w).session_id
            && List.exists (fun (p : Pane.t) -> Pane.equal p.pane_id anchor) (fst candidate))
          windows)
      anchor
  in
  match
    List.find_opt
      (fun w ->
        Session.equal (first w).session_id session && Window.equal (first w).window_id window)
      windows
  with
  | None -> None
  | Some current -> (
      let rec root w = match parent w with Some p -> root p | None -> w in
      let adjacent =
        Option.flat_map
          (fun p ->
            let siblings =
              List.concat_map
                (fun (pane : Pane.t) ->
                  List.filter
                    (fun ((_, anchor) as w) ->
                      Session.equal (first w).session_id session
                      && Option.equal Pane.equal anchor (Some pane.pane_id))
                    windows)
                (fst p)
              |> Array.of_list
            in
            Option.flat_map
              (fun (i, _) ->
                let j = i + if next then 1 else -1 in
                if j >= 0 && j < Array.length siblings then Some (first siblings.(j))
                else if next then None
                else Some (first p))
              (Array.find_idx (fun w -> Window.equal (first w).window_id window) siblings))
          (parent current)
      in
      match adjacent with
      | Some _ -> adjacent
      | None ->
          let roots = List.filter (fun w -> Option.is_none (parent w)) windows |> Array.of_list in
          let active = first (root current) in
          let n = Array.length roots in
          let rec find j k =
            if k = 0 then None
            else if List.for_all (fun (p : Pane.t) -> Option.is_none p.run) (fst roots.(j)) then
              Some (first roots.(j))
            else find (step ~next j n) (k - 1)
          in
          Option.flat_map
            (fun (i, _) -> find (step ~next i n) n)
            (Array.find_idx
               (fun w ->
                 Session.equal (first w).session_id active.session_id
                 && Window.equal (first w).window_id active.window_id)
               roots))

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
    Option.flat_map
      (fun (a : Pane.t) -> window_target ~next ~session:a.session_id ~window:a.window_id windows)
      active
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
             Session.to_string target.session_id;
             ";";
             "select-window";
             "-t";
             Window.to_string target.window_id;
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

let send_prompt pane text =
  let buf = Printf.sprintf "kido-prompt-%d" (Unix.getpid ()) in
  let open Result.Infix in
  let* _ = exec ~stdin:text [ "load-buffer"; "-b"; buf; "-" ] in
  let* () =
    Result.map_err
      (fun e ->
        ignore (exec [ "delete-buffer"; "-b"; buf ]);
        e)
      (run [ "paste-buffer"; "-b"; buf; "-d"; "-t"; Pane.to_string pane; "-p" ])
  in
  (* A paste-sensitive reader, Claude Code included, takes an Enter sent with
     the paste as part of the pasted text. *)
  Unix.sleepf 0.1;
  run [ "send-keys"; "-t"; Pane.to_string pane; "Enter" ]

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

let new_shell ~socket target =
  let open Result.Infix in
  let from, command, missing =
    match target with
    | `Window window ->
        let id = Window.to_string window in
        (id, [ "new-window"; "-a"; "-t"; id ], "no such window")
    | `Session session -> (Session.to_string session ^ ":", [ "new-session" ], "no such session")
  in
  let* cwd = exec ?socket [ "display-message"; "-p"; "-t"; from; "#{pane_current_path}" ] in
  if String.is_empty cwd then Error missing
  else
    let* out =
      exec ?socket
        (command @ [ "-d"; "-P"; "-F"; "#{session_id}:#{window_id}:#{pane_id}"; "-c"; cwd ])
    in
    match String.split ~by:":" out with
    | [ session; window; pane ] -> (
        match (Session.of_string session, Window.of_string window, Pane.of_string pane) with
        | Some session, Some window, Some pane -> Ok (session, window, pane)
        | _ -> Error (Printf.sprintf "created shell but could not read its location: %S" out))
    | _ -> Error (Printf.sprintf "created shell but could not read its location: %S" out)

let kill_window ?socket window_id = run ?socket [ "kill-window"; "-t"; Window.to_string window_id ]
let kill_pane ?socket pane_id = run ?socket [ "kill-pane"; "-t"; Pane.to_string pane_id ]

let mark_run pane_id run_id =
  run [ "set-option"; "-p"; "-t"; Pane.to_string pane_id; Pane.run_option; run_id ]
