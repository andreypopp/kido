type kind =
  | Init
  | Tail
  | Resize
  | Text
  | Snapshot
  | Exit
  | Ready
  | Head
  | Title
  | Pwd
  | Dead
  | Snapshot_done
  | Error
  | Full
  | Key
  | Paste
  | Paste_done
  | Mouse
  | Focus
  | Screen
  | Signal
[@@deriving equal]

type layout = {
  data_offset : int;
  record_header : int;
  max_frame : int;
  max_key : int;
  kinds : int array;
  tags : int array;
}

external layout : unit -> layout = "ko_pane_layout"

let layout = layout ()
let max_key = layout.max_key

let kinds =
  [|
    Init;
    Tail;
    Resize;
    Text;
    Snapshot;
    Exit;
    Ready;
    Head;
    Title;
    Pwd;
    Dead;
    Snapshot_done;
    Error;
    Full;
    Key;
    Paste;
    Paste_done;
    Mouse;
    Focus;
    Screen;
    Signal;
  |]

let wire = Array.to_list (Array.mapi (fun i code -> (kinds.(i), code)) layout.kinds)
let to_int kind = List.assoc ~eq:equal_kind kind wire

let of_int code =
  match List.find_opt (fun (_, n) -> n = code) wire with
  | Some (kind, _) -> kind
  | None -> invalid_arg "unknown pane frame"

external spawn : string -> bool -> Luv.Buffer.t * Unix.file_descr * int = "ko_pane_start"
external unmap : Luv.Buffer.t -> unit = "ko_pane_unmap"
external head : Luv.Buffer.t -> int = "ko_pane_ring_head" [@@noalloc]
external set_tail : Luv.Buffer.t -> int -> unit = "ko_pane_ring_set_tail" [@@noalloc]
external set_read : Luv.Buffer.t -> int -> unit = "ko_pane_ring_set_read" [@@noalloc]

let number buffer value = function
  | 1 -> Buffer.add_char buffer (Char.chr value)
  | 2 -> Buffer.add_uint16_le buffer value
  | 4 -> Buffer.add_int32_le buffer (Int32.of_int value)
  | 8 -> Buffer.add_int64_le buffer (Int64.of_int value)
  | _ -> invalid_arg "integer width"

let string b s =
  Buffer.add_int32_le b (Int32.of_int (String.length s));
  Buffer.add_string b s

let size b (s : Protocol.size) =
  let cell = Option.value ~default:{ Protocol.width = 0; height = 0 } s.cell_px in
  List.iter (Buffer.add_uint16_le b) [ s.cols; s.rows; cell.width; cell.height ]

let frame kind body =
  let b = Buffer.create (String.length body + 5) in
  Buffer.add_int32_le b (Int32.of_int (String.length body + 1));
  Buffer.add_char b (Char.chr (to_int kind));
  Buffer.add_string b body;
  Buffer.contents b

let init (config : Config.t) ~id ~cwd ~argv ~env ~size:dimensions =
  let b = Buffer.create 512 in
  Buffer.add_uint16_le b 3;
  size b dimensions;
  let limits = config.limits in
  let max_bytes, max_lines =
    match limits.scrollback with
    | Scrollback_disabled -> (Some 0, None)
    | Scrollback { max_bytes; max_lines } -> (max_bytes, max_lines)
  in
  List.iter
    (fun limit ->
      Buffer.add_uint8 b (if Option.is_some limit then 1 else 0);
      Buffer.add_int64_le b (Int64.of_int (Option.value ~default:0 limit)))
    [ max_bytes; max_lines ];
  List.iter
    (fun n -> Buffer.add_int64_le b (Int64.of_int n))
    [ limits.apc_max_bytes; limits.kitty_images_max_bytes ];
  let media =
    List.fold_left
      (fun bits medium ->
        bits lor match medium with Config.File -> 1 | Temp_file -> 2 | Shared_mem -> 4)
      0 limits.media
  in
  Buffer.add_char b (Char.chr media);
  Buffer.add_int64_le b (Int64.of_int limits.continuation_max_bytes);
  string b cwd;
  List.iter
    (fun values ->
      Buffer.add_int32_le b (Int32.of_int (List.length values));
      List.iter (string b) values)
    [ argv; env ];
  string b (Ids.Pane_id.to_string id);
  Buffer.contents b

type slice = { first : bool; last : bool; screen : bool }
type data = Bytes | Resize_marker of Protocol.size | Dead_marker of Protocol.dead | Slice of slice
type record = { pos : int; next : int; offset : int; at : int; len : int; data : data }

type event =
  | Ready_pid of int
  | Title_changed of string
  | Pwd_changed of string
  | Record of record
  | Published
  | Exited
  | Failed of Protocol.dead

type node = { pos : int; record : record option; mutable next_node : node option }

type reply =
  | Snapshot_reply of (record -> unit) * ((unit, string) result -> unit)
  | Screen_reply of (string -> last:bool -> unit) * ((unit, string) result -> unit)
  | Paste_reply of ((bool * bool, string) result -> unit)

type t = {
  ring : Luv.Buffer.t;
  control : Luv.Pipe.t;
  pid : int;
  capacity : int;
  mutable scanned : int;
  mutable tail : int;
  records : node Queue.t;
  index : (int, node) Hashtbl.t;
  mutable last : node option;
  mutable input : Bigstringaf.t;
  mutable filled : int;
  mutable closed : bool;
  mutable reaped : bool;
  mutable mapped : bool;
  mutable failure : bool;
  mutable next_req : int;
  pending : (int, reply) Hashtbl.t;
  snapshots : int Queue.t;
  mutable notify : event -> unit;
}

let child_pid t = t.pid
let buffer t = t.ring
let position t = t.scanned
let alive t = not t.closed

let send t kind body =
  if not t.closed then
    Luv.Stream.write t.control [ Luv.Buffer.from_string (frame kind body) ] (fun _ _ -> ())

let fail_pending t message =
  let pending = Hashtbl.to_seq_values t.pending |> List.of_seq in
  Hashtbl.clear t.pending;
  Queue.clear t.snapshots;
  List.iter
    (function
      | Snapshot_reply (_, done_) | Screen_reply (_, done_) -> done_ (Error message)
      | Paste_reply done_ -> done_ (Error message))
    pending

let failure t message =
  if not t.failure then begin
    t.failure <- true;
    if not t.closed then Luv.Handle.close t.control ignore;
    t.closed <- true;
    fail_pending t message;
    t.notify (Failed { Protocol.at = Uv.now (); cause = Failed message })
  end

let u16 ring at = Bigstringaf.get_int16_le ring at land 0xffff

let read_record ring capacity pos =
  let base = layout.data_offset + (pos mod capacity) in
  let kind = Char.code ring.{base}
  and len = Int32.to_int (Bigstringaf.get_int32_le ring (base + 1)) in
  if len < 0 || len + layout.record_header > capacity - (pos mod capacity) then
    invalid_arg "invalid ring record length";
  let at = base + layout.record_header in
  let offset = Int64.to_int (Bigstringaf.get_int64_le ring (base + 5)) in
  let next = pos + layout.record_header + len in
  if kind = layout.tags.(3) then (None, next)
  else
    let data =
      if kind = layout.tags.(0) then Bytes
      else if kind = layout.tags.(1) then
        begin if len = 9 && Char.code ring.{at} = 1 then
          Resize_marker
            {
              Protocol.cols = u16 ring (at + 1);
              rows = u16 ring (at + 3);
              cell_px =
                (match (u16 ring (at + 5), u16 ring (at + 7)) with
                | 0, 0 -> None
                | width, height -> Some { width; height });
            }
        else if len = 17 && Char.code ring.{at} = 2 then
          Dead_marker
            {
              Protocol.at = Int64.to_int (Bigstringaf.get_int64_le ring (at + 9));
              cause =
                (match Int32.to_int (Bigstringaf.get_int32_le ring (at + 5)) with
                | 0 -> Exited (Int32.to_int (Bigstringaf.get_int32_le ring (at + 1)))
                | signal -> Signaled signal);
            }
        else invalid_arg "invalid ring marker"
        end
      else if kind = layout.tags.(2) && len >= 2 then
        Slice
          {
            first = Char.code ring.{at} land 1 <> 0;
            last = Char.code ring.{at} land 2 <> 0;
            screen = Char.code ring.{at + 1} = 1;
          }
      else invalid_arg "invalid ring record kind"
    in
    (Some { pos; next; offset; at; len; data }, next)

let scan t =
  if t.closed then false
  else
    try
      let upper = head t.ring in
      if upper < t.scanned || upper - t.tail > t.capacity then invalid_arg "invalid ring head";
      let changed = upper > t.scanned in
      while t.scanned < upper do
        let record, next_pos = read_record t.ring t.capacity t.scanned in
        let node = { pos = t.scanned; record; next_node = None } in
        Option.iter (fun last -> last.next_node <- Some node) t.last;
        t.last <- Some node;
        Queue.add node t.records;
        Hashtbl.add t.index node.pos node;
        t.scanned <- next_pos;
        Option.iter
          (fun record ->
            match record.data with
            | Slice slice -> (
                match Queue.peek_opt t.snapshots with
                | None -> ()
                | Some req ->
                    (match Hashtbl.find_opt t.pending req with
                    | Some (Snapshot_reply (consume, _)) -> consume record
                    | _ -> ());
                    if slice.last then ignore (Queue.take t.snapshots : int))
            | _ -> t.notify (Record record))
          record
      done;
      set_read t.ring t.scanned;
      let retain = upper - (t.capacity / 2) in
      while match Queue.peek_opt t.records with Some n -> n.pos < retain | None -> false do
        let node = Queue.take t.records in
        Hashtbl.remove t.index node.pos
      done;
      let tail = match Queue.peek_opt t.records with Some node -> node.pos | None -> upper in
      if tail > t.tail then (
        t.tail <- tail;
        set_tail t.ring tail);
      let more = head t.ring > t.scanned in
      if more then t.notify Published;
      changed || more
    with Invalid_argument message ->
      failure t message;
      false

let oldest t =
  let rec first = function
    | None -> None
    | Some node -> (
        match node.record with Some record -> Some record.offset | None -> first node.next_node)
  in
  first (Queue.peek_opt t.records)

let iter_from t pos f =
  let start =
    match Hashtbl.find_opt t.index pos with
    | Some node -> Some node
    | None when pos < t.scanned -> Queue.peek_opt t.records
    | None -> None
  in
  let rec loop = function
    | None -> ()
    | Some node ->
        if node.pos < pos then loop node.next_node
        else
          let continue = match node.record with None -> true | Some record -> f record in
          if continue then loop node.next_node
  in
  loop start

let request t kind body reply =
  if t.closed then
    match reply with
    | Snapshot_reply (_, done_) | Screen_reply (_, done_) -> done_ (Error "pane process ended")
    | Paste_reply done_ -> done_ (Error "pane process ended")
  else begin
    let req = t.next_req in
    t.next_req <- req + 1;
    Hashtbl.add t.pending req reply;
    if equal_kind kind Snapshot then Queue.add req t.snapshots;
    let b = Buffer.create (String.length body + 4) in
    Buffer.add_int32_le b (Int32.of_int req);
    Buffer.add_string b body;
    send t kind (Buffer.contents b)
  end

let snapshot t ~full ~consume ~done_ =
  request t Snapshot
    ((if full then "\000" else "\001") ^ "\000\000\000\000\000")
    (Snapshot_reply (consume, done_))

let screen t ~format ~history ~chunk ~done_ =
  let b = Buffer.create 5 in
  Buffer.add_char b (match format with Protocol.Plain -> '\000' | Ansi -> '\001');
  Buffer.add_int32_le b
    (Int32.of_int
       (match history with
       | Protocol.Visible_only -> 0
       | Full_history -> 0xffffffff
       | Last_rows n -> n));
  request t Screen (Buffer.contents b) (Screen_reply (chunk, done_))

let paste t body done_ = request t Paste body (Paste_reply done_)

let string_at buffer at =
  let len = Int32.to_int (Bigstringaf.get_int32_le buffer at) in
  if len < 0 || at + 4 + len > Bigstringaf.length buffer then invalid_arg "invalid pane string";
  Bigstringaf.substring buffer ~off:(at + 4) ~len

let on_frame t kind body =
  ignore (scan t : bool);
  match kind with
  | Ready ->
      if Bigstringaf.length body <> 4 then invalid_arg "invalid ready"
      else t.notify (Ready_pid (Int32.to_int (Bigstringaf.get_int32_le body 0)))
  | Title -> t.notify (Title_changed (string_at body 0))
  | Pwd -> t.notify (Pwd_changed (string_at body 0))
  | Head -> t.notify Published
  | Dead -> t.notify Exited
  | Full ->
      let b = Buffer.create 8 in
      Buffer.add_int64_le b (Int64.of_int t.tail);
      send t Tail (Buffer.contents b);
      t.notify Published
  | Snapshot_done | Paste_done | Screen -> (
      let req = Int32.to_int (Bigstringaf.get_int32_le body 0) in
      match Hashtbl.find_opt t.pending req with
      | Some (Snapshot_reply (_, done_)) when equal_kind kind Snapshot_done ->
          Hashtbl.remove t.pending req;
          done_ (Ok ())
      | Some (Paste_reply done_) when equal_kind kind Paste_done ->
          Hashtbl.remove t.pending req;
          done_ (Ok (Char.code body.{4} = 1, Char.code body.{5} = 1))
      | Some (Screen_reply (chunk, done_)) when equal_kind kind Screen ->
          let last = Char.code body.{4} = 1 in
          chunk (string_at body 5) ~last;
          if last then (
            Hashtbl.remove t.pending req;
            done_ (Ok ()))
      | _ -> ())
  | Error -> failure t (string_at body 0)
  | _ -> ()

let frame_at input ~filled pos =
  if filled - pos < 4 then None
  else
    let len = Int32.to_int (Bigstringaf.get_int32_le input pos) in
    if len < 1 || len > layout.max_frame then invalid_arg "invalid control frame length";
    if len + 4 > filled - pos then None
    else
      let kind = of_int (Char.code input.{pos + 4}) in
      Some (kind, Bigstringaf.sub input ~off:(pos + 5) ~len:(len - 1), pos + 4 + len)

let create ?(callbacks = true) config ~id ~cwd ~argv ~env =
  let ring, fd, pid = spawn config.Config.pane_exe callbacks in
  let control = Uv.ok (Luv.Pipe.init ()) in
  Uv.ok (Luv.Pipe.open_ control (Uv.file fd));
  let t =
    {
      ring;
      control;
      pid;
      capacity = Int64.to_int (Bigstringaf.get_int64_le ring 0);
      scanned = 0;
      tail = 0;
      records = Queue.create ();
      index = Hashtbl.create 256;
      last = None;
      input = Bigstringaf.create 65536;
      filled = 0;
      closed = false;
      reaped = false;
      mapped = true;
      failure = false;
      next_req = 1;
      pending = Hashtbl.create 8;
      snapshots = Queue.create ();
      notify = ignore;
    }
  in
  let allocate _ =
    if t.filled = Bigstringaf.length t.input then begin
      if t.filled >= layout.max_frame + 4 then invalid_arg "control frame too large";
      let input = Bigstringaf.create (min (layout.max_frame + 4) (2 * t.filled)) in
      Bigstringaf.blit t.input ~src_off:0 input ~dst_off:0 ~len:t.filled;
      t.input <- input
    end;
    Bigstringaf.sub t.input ~off:t.filled ~len:(Bigstringaf.length t.input - t.filled)
  in
  Luv.Stream.read_start ~allocate control (function
    | Ok chunk -> (
        t.filled <- t.filled + Bigstringaf.length chunk;
        try
          let pos = ref 0 in
          let running = ref true in
          while !running do
            match frame_at t.input ~filled:t.filled !pos with
            | None -> running := false
            | Some (kind, body, next) ->
                pos := next;
                on_frame t kind body
          done;
          Bigstringaf.blit t.input ~src_off:!pos t.input ~dst_off:0 ~len:(t.filled - !pos);
          t.filled <- t.filled - !pos
        with Invalid_argument message -> failure t message)
    | Error _ -> if not t.closed then failure t "pane control socket closed");
  send t Init (init config ~id ~cwd ~argv ~env ~size:Protocol.default_size);
  t

let listen t callback = t.notify <- callback

let shutdown t =
  if not t.closed then (
    send t Exit "";
    t.closed <- true;
    fail_pending t "pane removed";
    Luv.Handle.close t.control ignore)

let reap t =
  if not t.reaped then
    match Unix.waitpid [ Unix.WNOHANG ] t.pid with
    | 0, _ -> ()
    | _, status ->
        t.reaped <- true;
        if not t.closed then
          failure t
            (match status with
            | Unix.WEXITED n -> Printf.sprintf "pane process exited unexpectedly with status %d" n
            | Unix.WSIGNALED n | Unix.WSTOPPED n ->
                Printf.sprintf "pane process ended unexpectedly by signal %d" (Uv.native_signal n));
        if t.mapped then (
          unmap t.ring;
          t.mapped <- false)
    | exception Unix.Unix_error (Unix.ECHILD, _, _) -> t.reaped <- true

let finished t = t.reaped

let kill t =
  if not t.reaped then
    try Unix.kill t.pid Sys.sigkill with Unix.Unix_error (Unix.ESRCH, _, _) -> ()

let%test_module "Tests" =
  (module struct
    let%expect_test "fragmented and multiple control frames" =
      let f = frame Text "abc" in
      let partial = String.sub f 0 6 in
      let input = Luv.Buffer.from_string partial in
      Printf.printf "%d %d\n"
        (match frame_at input ~filled:6 0 with None -> 0 | Some _ -> 1)
        (String.length partial);
      let input = Luv.Buffer.from_string (f ^ frame Exit "") in
      let pos = ref 0 and frames = ref [] in
      while !pos < Luv.Buffer.size input do
        match frame_at input ~filled:(Luv.Buffer.size input) !pos with
        | Some (kind, body, next) ->
            frames := Printf.sprintf "%d:%s" (to_int kind) (Bigstringaf.to_string body) :: !frames;
            pos := next
        | None -> pos := Luv.Buffer.size input
      done;
      Printf.printf "%s 0\n" (String.concat "," (List.rev !frames));
      (try ignore (frame_at (Luv.Buffer.from_string "\000\000\000\000") ~filled:4 0)
       with Invalid_argument message -> print_endline message);
      [%expect {|
 0 6
 4:abc,6: 0
 invalid control frame length
 |}]

    let%expect_test "ring layout and offsets" =
      let ring = Luv.Buffer.create (layout.data_offset + 64) in
      Bigarray.Array1.fill ring '\000';
      let base = layout.data_offset in
      ring.{base} <- Char.chr layout.tags.(0);
      Bigstringaf.set_int32_le ring (base + 1) 3l;
      Bigstringaf.set_int64_le ring (base + 5) 42L;
      let record, _ = read_record ring 64 0 in
      Option.iter (fun r -> Printf.printf "%d %d %d\n" r.len r.offset r.at) record;
      Bigstringaf.set_int32_le ring (base + 1) 127l;
      (try ignore (read_record ring 64 0) with Invalid_argument message -> print_endline message);
      [%expect {|
 3 42 45
 invalid ring record length
 |}]
  end)
