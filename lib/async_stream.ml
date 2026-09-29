type knobs = { batch : float; backoff_floor : float; backoff_cap : float }

let knobs getenv =
  let ms = Cli.ms_env getenv in
  {
    batch = ms "KIDO_STREAM_BATCH_MS" 0.25;
    backoff_floor = ms "KIDO_STREAM_BACKOFF_MS" 0.5;
    backoff_cap = ms "KIDO_STREAM_BACKOFF_CAP_MS" 10.;
  }

let batch_bytes = 4 * 1024
let pending_max = 64 * 1024
let run_budget = 256 * 1024

(* An escape's length from s.[i]: CSI up to its final byte in @-~, OSC up to BEL or ST, neither of
   which need be there, else the escape and one byte. *)
let escape_len s i =
  let n = String.length s in
  let rec until j stop =
    if j >= n then n - i else match stop j with Some k -> k - i | None -> until (j + 1) stop
  in
  if n - i < 2 then n - i
  else
    match s.[i + 1] with
    | '[' ->
        until (i + 2) (fun j ->
            if Char.(s.[j] >= '\x40' && s.[j] <= '\x7e') then Some (j + 1) else None)
    | ']' ->
        until (i + 2) (fun j ->
            if Char.equal s.[j] '\x07' then Some (j + 1)
            else if Char.equal s.[j] '\x1b' && j + 1 < n && Char.equal s.[j + 1] '\\' then
              Some (j + 2)
            else None)
    | _ -> 2

let sanitize line =
  let b = Buffer.create (String.length line) in
  let rec go i =
    if i < String.length line then
      match line.[i] with
      | '\x1b' -> go (i + escape_len line i)
      | c when Char.code c < 0x20 && not (Char.equal c '\t') -> go (i + 1)
      | c ->
          Buffer.add_char b c;
          go (i + 1)
  in
  go 0;
  String.rdrop_while (String.contains " \t\r") (Buffer.contents b)

(* The sender thread alone touches [inbox], and [close] once it has stopped: resolved once and
   again only after a failed send, the one event that can mean the address changed. Every other
   mutable field is under [mu]. *)
type stream = {
  dir : string;
  knobs : knobs;
  meta : Subrun.meta;
  mutable inbox : string;
  mu : Mutex.t;
  partial : Buffer.t;
  pending : string Queue.t;
  mutable bytes : int;
  mutable total : int;
  mutable sent : int;
  mutable streamed : int;
  mutable overrun : bool;
  mutable stopping : bool;
  wake_r : Unix.file_descr;
  wake_w : Unix.file_descr;
}

type t = { stream : stream; sender : Thread.t }

let push t line =
  let l = sanitize line in
  t.total <- t.total + 1;
  Queue.push l t.pending;
  t.bytes <- t.bytes + String.length l + 1

let signal t =
  try ignore (Unix.write_substring t.wake_w "x" 0 1)
  with Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> ()

let write { stream = t; _ } s =
  let ready =
    Mutex.protect t.mu (fun () ->
        Buffer.add_string t.partial s;
        if String.contains s '\n' then begin
          let all = Buffer.contents t.partial in
          let rec lines start =
            match String.index_from_opt all start '\n' with
            | Some i ->
                push t (String.sub all start (i - start));
                lines (i + 1)
            | None -> start
          in
          let rest = lines 0 in
          Buffer.clear t.partial;
          Buffer.add_substring t.partial all rest (String.length all - rest)
        end;
        (* After the append, so one enormous burst leaves the newest lines. *)
        while t.bytes > pending_max && not (Queue.is_empty t.pending) do
          t.bytes <- t.bytes - (String.length (Queue.pop t.pending) + 1)
        done;
        t.bytes >= batch_bytes)
  in
  if ready then signal t

let take t =
  Mutex.protect t.mu (fun () ->
      if Queue.is_empty t.pending then None
      else if t.streamed >= run_budget then
        if t.overrun then None
        else begin
          t.overrun <- true;
          Queue.clear t.pending;
          t.bytes <- 0;
          Some
            ( Printf.sprintf "... %d bytes streamed for this run; the rest is only in %s" run_budget
                (Subrun.output_path ~dir:(Filename.concat t.dir "runs") t.meta.id),
              0,
              0 )
        end
      else
        let text = String.concat "\n" (List.of_seq (Queue.to_seq t.pending)) in
        let batch = (text, Queue.length t.pending, t.bytes) in
        Queue.clear t.pending;
        t.bytes <- 0;
        Some batch)

let credit t lines n =
  Mutex.protect t.mu (fun () ->
      t.sent <- t.sent + lines;
      t.streamed <- t.streamed + n)

let send t text =
  let resolved =
    if (not (String.is_empty t.inbox)) || String.is_empty t.meta.parent_session then t.inbox
    else
      match List.assoc_opt ~eq:String.equal t.meta.parent_session (State.load_live ~dir:t.dir) with
      | Some p -> p.inbox
      | None -> ""
  in
  (not (String.is_empty resolved))
  &&
  let env : Msg.envelope =
    {
      v = Msg.v1;
      kind = Stream;
      id = Msg.new_id ();
      from = { session = ""; name = t.meta.name; pane = "" };
      reply_to = "";
      text;
      run = Subrun.string_of_id t.meta.id;
      output = Subrun.output_path ~dir:(Filename.concat t.dir "runs") t.meta.id;
    }
  in
  match Msg.deliver ~path:resolved (Yojson.Safe.to_string (Msg.envelope_to_yojson env)) with
  | Ok () ->
      t.inbox <- resolved;
      true
  | Error _ ->
      t.inbox <- "";
      false

let deliver t =
  match take t with
  | None -> None
  | Some (text, lines, n) ->
      let ok = try send t text with Sys_error _ | Unix.Unix_error _ | Failure _ -> false in
      if ok then credit t lines n;
      Some ok

let drain fd =
  let buf = Bytes.create 64 in
  try
    while Unix.read fd buf 0 64 > 0 do
      ()
    done
  with Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> ()

let run t =
  let rec loop ~tick ~backoff ~retry_at =
    let now = Unix.gettimeofday () in
    (match Unix.select [ t.wake_r ] [] [] (Float.max 0. (tick -. now)) with
    | [], _, _ -> ()
    | _ -> drain t.wake_r
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> ());
    let now = Unix.gettimeofday () in
    let tick = if Float.(now >= tick) then now +. t.knobs.batch else tick in
    if not (Mutex.protect t.mu (fun () -> t.stopping)) then
      if Float.(now < retry_at) then loop ~tick ~backoff ~retry_at
      else
        match deliver t with
        | None -> loop ~tick ~backoff ~retry_at
        | Some true -> loop ~tick ~backoff:0. ~retry_at:0.
        | Some false ->
            let backoff =
              if Float.(backoff = 0.) then t.knobs.backoff_floor
              else Float.min t.knobs.backoff_cap (2. *. backoff)
            in
            loop ~tick ~backoff ~retry_at:(Unix.gettimeofday () +. backoff)
  in
  loop ~tick:(Unix.gettimeofday () +. t.knobs.batch) ~backoff:0. ~retry_at:0.

let start ~dir knobs meta =
  let wake_r, wake_w = Unix.pipe ~cloexec:true () in
  Unix.set_nonblock wake_r;
  Unix.set_nonblock wake_w;
  let t =
    {
      dir;
      knobs;
      meta;
      inbox = "";
      mu = Mutex.create ();
      partial = Buffer.create 256;
      pending = Queue.create ();
      bytes = 0;
      total = 0;
      sent = 0;
      streamed = 0;
      overrun = false;
      stopping = false;
      wake_r;
      wake_w;
    }
  in
  { stream = t; sender = Thread.create run t }

let close { stream = t; sender } =
  Mutex.protect t.mu (fun () -> t.stopping <- true);
  signal t;
  Thread.join sender;
  Unix.close t.wake_r;
  Unix.close t.wake_w;
  Mutex.protect t.mu (fun () ->
      if Buffer.length t.partial > 0 then begin
        push t (Buffer.contents t.partial);
        Buffer.clear t.partial
      end);
  ignore (deliver t);
  Mutex.protect t.mu (fun () -> t.total - t.sent)
