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

let debounce = 0.05
let run_timeout = 2.
let min_backoff = 0.1
let max_backoff = 2.

type child = {
  process : Exec.process;
  partial : Buffer.t;
  mutable parser : parser;
  replies : (string list, string) result Queue.t;
  chunk : Bytes.t;
  mutable attached : Session.id option;
}

type link = Live of child | Down of { next_dial : float } | Closed

type t = {
  client : string;
  socket : string option;
  mutable link : link;
  mutable backoff : float;
  mutable changed : bool;
}

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

let dial t =
  let session =
    Option.map
      (fun (c : Exec.client_state) -> c.session_id)
      (Exec.client_state ?socket:t.socket t.client)
  in
  let args =
    [ "-T"; "hyperlinks"; "-C"; "attach-session"; "-f"; "no-output,ignore-size" ]
    @ Option.map_or ~default:[] (fun s -> [ "-t"; Session.to_string s ]) session
  in
  match Exec.spawn ?socket:t.socket args with
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

let create ?socket ~client () =
  { client; socket; link = Down { next_dial = 0. }; backoff = min_backoff; changed = false }

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
      match Exec.write_all ch.process.stdin (cmd ^ "\n") with
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
  | Live ch when not (Option.equal Session.equal ch.attached (Some session)) -> (
      match run t ~command:("switch-client -t " ^ Session.to_string session) with
      | Ok _ -> ch.attached <- Some session
      | Error _ -> ())
  | Live _ | Down _ | Closed -> ()

let list_panes t =
  match run t ~command:("list-panes -a -F " ^ Filename.quote Pane.format) with
  | Ok lines -> Ok (Pane.parse lines)
  | Error _ -> Exec.list_panes ?socket:t.socket ()

let client_state t =
  match run t ~command:("list-clients -F " ^ Filename.quote Exec.client_format) with
  | Ok (_ :: _ as lines) -> Exec.parse_client_state lines t.client
  | Ok [] | Error _ -> Exec.client_state ?socket:t.socket t.client

let%test_module "Tests" =
  (module struct
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
