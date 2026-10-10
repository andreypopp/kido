let id_of_string ~what sigil s =
  if
    String.length s > 1
    && Char.equal s.[0] sigil
    && String.for_all Char.Ascii.is_digit (String.drop 1 s)
  then s
  else invalid_arg (Printf.sprintf "%S is not a %s id (%cN)" s what sigil)

type session_id = string [@@deriving equal, to_string, yojson_of]

let session_id_of_string s = id_of_string ~what:"session" '$' s

type window_id = string [@@deriving equal, to_string, yojson_of]

let window_id_of_string s = id_of_string ~what:"window" '@' s

type pane_id = string [@@deriving equal, to_string, yojson_of]

let pane_id_of_string s = id_of_string ~what:"pane" '%' s

let compare_pane_id a b =
  Int.compare
    (Option.get_or ~default:0 (int_of_string_opt (String.drop 1 a)))
    (Option.get_or ~default:0 (int_of_string_opt (String.drop 1 b)))

module Pane_map = Map.Make (struct
  type t = pane_id

  let compare = String.compare
end)

let pane_id_of_yojson json =
  match json with
  | `String s -> (
      try pane_id_of_string s
      with Invalid_argument _ -> Ppx_yojson_conv_lib.Yojson_conv.of_yojson_error "pane" json)
  | _ -> Ppx_yojson_conv_lib.Yojson_conv.of_yojson_error "pane" json

module Program_status = Program_status

let binary =
  lazy
    (let exe = Lazy.force Fs.self in
     match Sys.getenv_opt "KIDO_TMUX" with
     | Some b when not (String.is_empty b) -> b
     | _ ->
         Fs.candidates exe
         |> List.map (fun c -> Filename.concat (Filename.dirname c) "kido-tmux")
         |> List.find_opt Fs.is_file |> Option.get_or ~default:"tmux")

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

let one_shot_exec ?socket ?(stdin = "") args =
  let failed why = Error (Printf.sprintf "tmux %s: %s" (String.concat " " args) why) in
  match spawn ?socket args with
  | Error e -> failed e
  | Ok p -> (
      (try Fs.write_all p.stdin stdin with Unix.Unix_error (EPIPE, _, _) -> ());
      Unix.close p.stdin;
      let out =
        Fun.protect ~finally:(fun () -> Unix.close p.stdout) (fun () -> read_all p.stdout)
      in
      match snd (Unix.waitpid [] p.pid) with
      | WEXITED 0 -> Ok (String.trim out)
      | WEXITED n -> failed (Printf.sprintf "exit status %d" n)
      | WSIGNALED n | WSTOPPED n -> failed (Printf.sprintf "signal %d" n))

let lines out = String.split_on_char '\n' out
let side_focus_flag = "side-status-focus"

let one_shot_client_session ?socket client =
  Option.flat_map
    (fun out ->
      List.find_map
        (fun line ->
          match String.split_on_char '\x1f' line with
          | [ name; id ] when String.equal name client -> Some (session_id_of_string id)
          | _ -> None)
        (lines out))
    (Result.to_opt
       (one_shot_exec ?socket [ "list-clients"; "-F"; "#{client_name}\x1f#{session_id}" ]))

type event = Block of (string list, string) result | Notification of string
type parser = Outside | Inside of { id : string; lines : string list }

let guard_id rest =
  match String.split_on_char ' ' rest |> List.filter (fun f -> not (String.is_empty f)) with
  | time :: number :: _ -> time ^ " " ^ number
  | _ -> rest

let step parser line =
  match parser with
  | Outside -> (
      match String.chop_prefix ~pre:"%begin " line with
      | Some rest -> (Inside { id = guard_id rest; lines = [] }, None)
      | None when String.prefix ~pre:"%" line -> (Outside, Some (Notification line))
      | None -> (Outside, None))
  | Inside { id; lines } ->
      let closes guard =
        Option.exists
          (fun rest -> String.equal (guard_id rest) id)
          (String.chop_prefix ~pre:guard line)
      in
      let lines' = List.rev lines in
      if closes "%end " then (Outside, Some (Block (Ok lines')))
      else if closes "%error " then (Outside, Some (Block (Error (String.concat "; " lines'))))
      else (Inside { id; lines = line :: lines }, None)

let is_state_change = function
  | "%window-add" | "%window-close" | "%window-renamed" | "%unlinked-window-add"
  | "%unlinked-window-close" | "%unlinked-window-renamed" | "%sessions-changed" | "%session-changed"
  | "%session-renamed" | "%session-window-changed" | "%client-session-changed" | "%client-detached"
  | "%layout-change" | "%window-pane-changed" | "%pane-mode-changed" | "%program-status" ->
      true
  | _ -> false

type t = { socket : string option; channel : client option }

and client = {
  client : string;
  socket : string option;
  mutable link : link;
  mutable backoff : float;
  mutable changed : bool;
}

and child = {
  process : process;
  partial : Buffer.t;
  mutable parser : parser;
  replies : (string list, string) result Queue.t;
  chunk : Bytes.t;
  mutable attached : session_id option;
}

and link = Live of child | Down of { next_dial : float } | Closed

let create ?socket () = { socket; channel = None }

module Client = struct
  type tmux = t
  type t = client

  let debounce = 0.05
  let run_timeout = 2.
  let min_backoff = 0.1
  let max_backoff = 2.

  let kill ch =
    let p = ch.process in
    List.iter Unix.close [ p.stdin; p.stdout ];
    (try Unix.kill p.pid Sys.sigkill with Unix.Unix_error _ -> ());
    ignore (Unix.waitpid [] p.pid)

  let drop t =
    let retry () =
      t.link <- Down { next_dial = Unix.gettimeofday () +. t.backoff };
      t.backoff <- Float.min max_backoff (t.backoff *. 2.)
    in
    match t.link with
    | Live ch ->
        kill ch;
        retry ()
    | Down _ -> retry ()
    | Closed -> ()

  let feed t ch line =
    let parser, event = step ch.parser (String.rdrop_while (Char.equal '\r') line) in
    ch.parser <- parser;
    match event with
    | Some (Block b) -> Queue.push b ch.replies
    | Some (Notification n) ->
        let name = List.hd (String.split_on_char ' ' n) in
        if String.equal name "%exit" then drop t else if is_state_change name then t.changed <- true
    | None -> ()

  let pump t ch ~deadline =
    let left = deadline -. Unix.gettimeofday () in
    match Unix.select [ ch.process.stdout ] [] [] (Float.max 0. left) with
    | [], _, _ -> ()
    | _ -> (
        match Unix.read ch.process.stdout ch.chunk 0 (Bytes.length ch.chunk) with
        | 0 -> drop t
        | n -> (
            Buffer.add_subbytes ch.partial ch.chunk 0 n;
            match List.rev (String.split_on_char '\n' (Buffer.contents ch.partial)) with
            | rest :: complete ->
                Buffer.clear ch.partial;
                Buffer.add_string ch.partial rest;
                List.iter (feed t ch) (List.rev complete)
            | [] -> ())
        | exception Unix.Unix_error ((EINTR | EAGAIN), _, _) -> ())
    | exception Unix.Unix_error (EINTR, _, _) -> ()

  let rec reply t ch ~deadline =
    match (Queue.take_opt ch.replies, t.link) with
    | Some b, _ -> `Reply b
    | None, (Down _ | Closed) -> `Dead
    | None, Live _ when Float.(Unix.gettimeofday () >= deadline) -> `Timeout
    | None, Live _ ->
        pump t ch ~deadline;
        reply t ch ~deadline

  let dial (t : t) =
    let session = one_shot_client_session ?socket:t.socket t.client in
    let args =
      [ "-T"; "hyperlinks"; "-C"; "attach-session"; "-f"; "no-output,ignore-size" ]
      @ Option.map_or ~default:[] (fun s -> [ "-t"; string_of_session_id s ]) session
    in
    match spawn ?socket:t.socket args with
    | Error _ -> drop t
    | Ok process -> (
        let ch =
          {
            process;
            partial = Buffer.create 4096;
            parser = Outside;
            replies = Queue.create ();
            chunk = Bytes.create 65536;
            attached = session;
          }
        in
        t.link <- Live ch;
        match reply t ch ~deadline:(Unix.gettimeofday () +. run_timeout) with
        | `Reply (Ok _) ->
            t.backoff <- min_backoff;
            t.changed <- true
        | `Reply (Error _) | `Timeout -> drop t
        | `Dead -> ())

  let connect (tmux : tmux) ~client =
    {
      client;
      socket = tmux.socket;
      link = Down { next_dial = 0. };
      backoff = min_backoff;
      changed = false;
    }

  let live t =
    match t.link with
    | Live ch -> Some ch
    | Down { next_dial } when Float.(Unix.gettimeofday () < next_dial) -> None
    | Down _ -> (
        dial t;
        match t.link with Live ch -> Some ch | Down _ | Closed -> None)
    | Closed -> None

  let down = Error "tmux: control connection is down"

  let run t ~command:cmd =
    match live t with
    | None -> down
    | Some ch -> (
        Queue.clear ch.replies;
        match Fs.write_all ch.process.stdin (cmd ^ "\n") with
        | exception Unix.Unix_error _ ->
            drop t;
            down
        | () -> (
            match reply t ch ~deadline:(Unix.gettimeofday () +. run_timeout) with
            | `Reply b -> b
            | `Dead -> down
            | `Timeout ->
                drop t;
                Error (Printf.sprintf "tmux -C %s: timed out" cmd)))

  let await_notifications t ~timeout =
    let rec go deadline =
      let now = Unix.gettimeofday () in
      let deadline = if t.changed then Float.min deadline (now +. debounce) else deadline in
      if Float.(now < deadline) then
        match live t with
        | Some ch ->
            let deadline = if t.changed then Float.min deadline (now +. debounce) else deadline in
            pump t ch ~deadline;
            go deadline
        | None ->
            let until =
              match t.link with
              | Down { next_dial } -> Float.min deadline next_dial
              | Live _ | Closed -> deadline
            in
            Unix.sleepf (Float.max 0. (until -. now));
            go deadline
    in
    go (Unix.gettimeofday () +. timeout);
    t.changed <- false

  let close t =
    (match t.link with Live ch -> kill ch | Down _ | Closed -> ());
    t.link <- Closed

  let follow t session =
    match t.link with
    | Live ch when not (Option.equal equal_session_id ch.attached (Some session)) -> (
        match run t ~command:("switch-client -t " ^ string_of_session_id session) with
        | Ok _ -> ch.attached <- Some session
        | Error _ -> ())
    | Live _ | Down _ | Closed -> ()

  let tmux (c : t) : tmux = { socket = c.socket; channel = Some c }
end

let exec (t : t) ?(stdin = "") args =
  match t.channel with
  | None -> one_shot_exec ?socket:t.socket ~stdin args
  | Some _ when not (String.is_empty stdin) -> Error "tmux: control commands cannot read stdin"
  | Some c ->
      let command =
        String.concat " "
          (List.map
             (fun arg ->
               if
                 String.equal arg ";"
                 || (not (String.is_empty arg))
                    && String.for_all
                         (fun c -> Char.Ascii.is_alphanum c || String.contains "_-./" c)
                         arg
               then arg
               else Filename.quote arg)
             args)
      in
      Result.map (fun lines -> String.trim (String.concat "\n" lines)) (Client.run c ~command)

let list_panes (t : t) ~format =
  match
    Option.map
      (fun c -> Client.run c ~command:("list-panes -a -F " ^ Filename.quote format))
      t.channel
  with
  | Some (Ok lines) -> Ok lines
  | None | Some (Error _) ->
      Result.map lines (one_shot_exec ?socket:t.socket [ "list-panes"; "-a"; "-F"; format ])

let run t args = Result.map ignore (exec t args)

let list_clients (t : t) ~format =
  match
    Option.map
      (fun c -> Client.run c ~command:("list-clients -F " ^ Filename.quote format))
      t.channel
  with
  | Some (Ok (_ :: _ as lines)) -> Ok lines
  | None | Some (Ok [] | Error _) ->
      Result.map lines (one_shot_exec ?socket:t.socket [ "list-clients"; "-F"; format ])

let release_args client = [ "refresh-client"; "-t"; client; "-f"; "!" ^ side_focus_flag ]

let jump t ~client ~session ~window pane =
  run t
    ([
       "switch-client";
       "-c";
       client;
       "-t";
       string_of_session_id session ^ ":" ^ string_of_window_id window ^ "."
       ^ string_of_pane_id pane;
       ";";
       "select-window";
       "-t";
       string_of_session_id session ^ ":" ^ string_of_window_id window;
       ";";
       "select-pane";
       "-t";
       string_of_pane_id pane;
       ";";
     ]
    @ release_args client)

let release_side_focus t client = run t (release_args client)

(* On a closed window the fork's display-message exits 0 and prints an empty
   line, so only the echoed id answers. *)
let window_exists t window_id =
  match exec t [ "display-message"; "-p"; "-t"; string_of_window_id window_id; "#{window_id}" ] with
  | Ok out -> String.equal out (string_of_window_id window_id)
  | Error _ -> false

type window = { window_id : window_id; pane_id : pane_id; pane_pid : int }

let new_window t ?(remain_on_exit = true) ~session ~name ~cwd ~env command =
  let open Result.Infix in
  let* out =
    exec t
      ([
         "new-window";
         "-d";
         "-P";
         "-F";
         "#{window_id}:#{pane_id}:#{pane_pid}";
         "-t";
         string_of_session_id session ^ ":";
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
        | Some pane_pid -> (
            try
              Ok
                {
                  window_id = window_id_of_string window_id;
                  pane_id = pane_id_of_string pane_id;
                  pane_pid;
                }
            with Invalid_argument _ ->
              Error (Printf.sprintf "new-window: unexpected output %S" out))
        | None -> Error (Printf.sprintf "new-window: unexpected pane_pid %S" pid))
    | _ -> Error (Printf.sprintf "new-window: unexpected output %S" out)
  in
  (* A command that exits fast enough always beats remain-on-exit; losing that
     race is not a failure to create the window. *)
  if not remain_on_exit then Ok w
  else
    match
      exec t [ "set-option"; "-p"; "-t"; string_of_pane_id w.pane_id; "remain-on-exit"; "on" ]
    with
    | Error e when window_exists t w.window_id -> Error e
    | Ok _ | Error _ -> Ok w

let%test_module "Tests" =
  (module struct
    let%expect_test "tmux ids validate their sigil and digits" =
      let valid parse s = match parse s with _ -> true | exception Invalid_argument _ -> false in
      List.iter
        (fun (parse, values) -> List.iter (fun s -> Printf.printf "%S %b\n" s (parse s)) values)
        [
          (valid pane_id_of_string, [ "%0"; "%123"; "@1"; ""; "%"; "%x"; "%1x" ]);
          (valid window_id_of_string, [ "@0"; "@123"; "$1"; ""; "@"; "@x"; "@1x" ]);
          (valid session_id_of_string, [ "$0"; "$123"; "%1"; ""; "$"; "$x"; "$1x" ]);
        ];
      [%expect
        {|
    "%0" true
    "%123" true
    "@1" false
    "" false
    "%" false
    "%x" false
    "%1x" false
    "@0" true
    "@123" true
    "$1" false
    "" false
    "@" false
    "@x" false
    "@1x" false
    "$0" true
    "$123" true
    "%1" false
    "" false
    "$" false
    "$x" false
    "$1x" false
    |}]

    let feed stream =
      let _, events =
        List.fold_left
          (fun (parser, acc) line ->
            let parser, e = step parser line in
            (parser, Option.to_list e @ acc))
          (Outside, [])
          (String.split_on_char '\n' stream)
      in
      List.iter
        (function
          | Block (Ok lines) -> Printf.printf "block [%s]\n" (String.concat " | " lines)
          | Block (Error e) -> Printf.printf "error %s\n" e
          | Notification n ->
              Printf.printf "notification %s refresh=%b\n" n
                (is_state_change (List.hd (String.split_on_char ' ' n))))
        (List.rev events)

    let%expect_test
        "a control-mode session: blocks, data lines starting with %, notifications, errors" =
      feed
        "%begin 100 1 0\n\
         %end 100 1 0\n\
         %session-changed $1 work\n\
         %begin 100 2 1\n\
         %0\tzsh\n\
         %1\tclaude\n\
         %end 100 2 0\n\
         %window-add @7\n\
         %output %3 junk\n\
         %program-status ignored payload\n\
         %begin 100 3 1\n\
         parse error: unknown command: bogus\n\
         %error 100 3 1\n\
         %exit";
      [%expect
        {|
      block []
      notification %session-changed $1 work refresh=true
      block [%0	zsh | %1	claude]
      notification %window-add @7 refresh=true
      notification %output %3 junk refresh=false
      notification %program-status ignored payload refresh=true
      error parse error: unknown command: bogus
      notification %exit refresh=false
      |}]

    let%expect_test "a truncated block is never handed out; a guard lookalike is data" =
      feed "%begin 1 1 0\nrow";
      print_endline "--";
      feed "%begin 5 9 0\n%end 5 8 0\nrow\n%end 5 9 1";
      [%expect {|
      --
      block [%end 5 8 0 | row]
      |}]
  end)
