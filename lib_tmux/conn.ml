type block = (string list, string) result
type event = Block of block | Notification of string
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
      | None when String.prefix ~pre:"%" line ->
          (Outside, Some (Notification (List.hd (String.split_on_char ' ' line))))
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

let notifications =
  [
    "%window-add";
    "%window-close";
    "%window-renamed";
    "%unlinked-window-add";
    "%unlinked-window-close";
    "%unlinked-window-renamed";
    "%sessions-changed";
    "%session-changed";
    "%session-renamed";
    "%session-window-changed";
    "%client-session-changed";
    "%client-detached";
    "%layout-change";
    "%window-pane-changed";
    "%pane-mode-changed";
  ]

let debounce = 0.05
let run_timeout = 2.
let min_backoff = 0.1
let max_backoff = 2.

type child = {
  process : Exec.process;
  partial : Buffer.t;
  mutable parser : parser;
  replies : block Queue.t;
  mutable attached : string;
}

type t = {
  client : string;
  mutable child : child option;
  mutable backoff : float;
  mutable next_dial : float;
  mutable changed : bool;
  mutable closed : bool;
}

let kill t =
  Option.iter
    (fun ch ->
      let p = ch.process in
      List.iter Unix.close [ p.stdin; p.stdout ];
      (try Unix.kill p.pid Sys.sigkill with Unix.Unix_error _ -> ());
      ignore (Unix.waitpid [] p.pid))
    t.child;
  t.child <- None

let drop t =
  kill t;
  t.next_dial <- Unix.gettimeofday () +. t.backoff;
  t.backoff <- Float.min max_backoff (t.backoff *. 2.)

let feed t ch line =
  let parser, event = step ch.parser (String.rdrop_while (Char.equal '\r') line) in
  ch.parser <- parser;
  match event with
  | Some (Block b) -> Queue.push b ch.replies
  | Some (Notification "%exit") -> drop t
  | Some (Notification n) when List.mem ~eq:String.equal n notifications -> t.changed <- true
  | Some (Notification _) | None -> ()

let pump t ch ~deadline =
  let left = deadline -. Unix.gettimeofday () in
  match Unix.select [ ch.process.stdout ] [] [] (Float.max 0. left) with
  | [], _, _ -> ()
  | _ -> (
      let chunk = Bytes.create 65536 in
      match Unix.read ch.process.stdout chunk 0 (Bytes.length chunk) with
      | 0 -> drop t
      | n -> (
          Buffer.add_subbytes ch.partial chunk 0 n;
          match List.rev (String.split_on_char '\n' (Buffer.contents ch.partial)) with
          | rest :: complete ->
              Buffer.clear ch.partial;
              Buffer.add_string ch.partial rest;
              List.iter (feed t ch) (List.rev complete)
          | [] -> ())
      | exception Unix.Unix_error ((EINTR | EAGAIN), _, _) -> ())
  | exception Unix.Unix_error (EINTR, _, _) -> ()

let rec reply t ch ~deadline =
  match Queue.take_opt ch.replies with
  | Some b -> `Reply b
  | None when Option.is_none t.child -> `Dead
  | None when Float.(Unix.gettimeofday () >= deadline) -> `Timeout
  | None ->
      pump t ch ~deadline;
      reply t ch ~deadline

let dial t =
  let session =
    Option.map (fun (c : Exec.client_state) -> c.session) (Exec.client_state t.client)
  in
  let args =
    [ "-C"; "attach-session"; "-f"; "no-output,ignore-size" ]
    @ Option.map_or ~default:[] (fun s -> [ "-t"; s ]) session
  in
  match Exec.spawn args with
  | Error _ -> drop t
  | Ok process -> (
      let ch =
        {
          process;
          partial = Buffer.create 4096;
          parser = Outside;
          replies = Queue.create ();
          attached = Option.get_or ~default:"" session;
        }
      in
      t.child <- Some ch;
      match reply t ch ~deadline:(Unix.gettimeofday () +. run_timeout) with
      | `Reply (Ok _) ->
          t.backoff <- min_backoff;
          t.changed <- true
      | `Reply (Error _) | `Timeout -> drop t
      | `Dead -> ())

let connect client =
  { client; child = None; backoff = min_backoff; next_dial = 0.; changed = false; closed = false }

let live t =
  match t.child with
  | Some ch -> Some ch
  | None when t.closed || Float.(Unix.gettimeofday () < t.next_dial) -> None
  | None ->
      dial t;
      t.child

let down = Error "tmux: control connection is down"

let run t cmd =
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

let wait t timeout =
  let rec go deadline =
    let now = Unix.gettimeofday () in
    let deadline = if t.changed then Float.min deadline (now +. debounce) else deadline in
    if Float.(now < deadline) then
      match live t with
      | Some ch ->
          (* A redial inside live is itself a change: pump to the debounce, not the interval. *)
          let deadline = if t.changed then Float.min deadline (now +. debounce) else deadline in
          pump t ch ~deadline;
          go deadline
      | None ->
          let until = if t.closed then deadline else Float.min deadline t.next_dial in
          Unix.sleepf (Float.max 0. (until -. now));
          go deadline
  in
  go (Unix.gettimeofday () +. timeout);
  t.changed <- false

let close t =
  t.closed <- true;
  kill t

let quote s = "'" ^ String.replace ~sub:"'" ~by:{|'\''|} s ^ "'"

let follow t session =
  match t.child with
  | Some ch when not (String.equal ch.attached session) -> (
      match run t ("switch-client -t " ^ quote session) with
      | Ok _ -> ch.attached <- session
      | Error _ -> ())
  | Some _ | None -> ()

let list_panes t =
  match run t ("list-panes -a -F " ^ quote Pane.format) with
  | Ok lines -> Ok (Pane.parse lines)
  | Error _ -> Exec.list_panes ()

let capture_pane t pane =
  match run t ("capture-pane -p -t " ^ quote pane) with
  | Ok lines -> Ok lines
  | Error _ -> Exec.capture_pane pane

let client_state t client =
  match run t ("list-clients -F " ^ quote Exec.client_format) with
  | Ok (_ :: _ as lines) -> Exec.parse_client_state lines client
  | Ok [] | Error _ -> Exec.client_state client
