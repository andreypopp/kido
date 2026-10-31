type decision = Resume | Snapshot of Protocol.history | Skip

let decide ~behind ~offset ~head ~history ~resize ~blocked =
  if blocked && head - offset >= 65536 then Skip
  else if behind then Snapshot history
  else if resize && match history with History_none -> true | History_all -> false then
    Snapshot History_none
  else Resume

type cursor = { mutable pos : int; mutable offset : int; mutable blocked : bool }
type snapshot = { cursor : cursor; history : Protocol.history }
type state = Live of cursor * Protocol.history | Snapshotting of snapshot | Closed

type t = {
  pane : Pane.t;
  connection : Connection.t;
  client : Ids.Client_id.t option;
  mutable state : state;
  mutable wanted : Protocol.history option;
  nexts : int array;
  ends : int array;
}

let client t = t.client
let pane t = t.pane
let ring t = Pane_proc.ring (Pane.proc t.pane)

let close t =
  match t.state with
  | Closed -> ()
  | _ ->
      t.state <- Closed;
      Connection.close t.connection

let waiting t =
  match t.state with
  | Closed -> false
  | Snapshotting _ -> true
  | Live _ -> Connection.waiting t.connection

let resize_pending ring cursor =
  let upper = Ring.head ring in
  let pos = ref cursor.pos and found = ref false in
  while (not !found) && !pos < upper do
    (match Ring.kind ring !pos with
    | Marker -> (
        match Ring.marker ring !pos with
        | Resize _ -> if Ring.offset ring !pos >= cursor.offset then found := true
        | Dead _ -> ())
    | Bytes | Slice | Pad -> ());
    pos := Ring.next ring !pos
  done;
  !found

let flush_batch t cursor ring =
  let count = Connection.batch_count t.connection in
  if count = 0 then true
  else
    let accepted = Connection.batch_send t.connection (Ring.buffer ring) in
    if accepted < 0 then (
      close t;
      false)
    else begin
      if accepted > 0 then (
        cursor.pos <- t.nexts.(accepted - 1);
        cursor.offset <- t.ends.(accepted - 1));
      if accepted < count || Connection.waiting t.connection then (
        cursor.blocked <- true;
        false)
      else true
    end

let resume t cursor ring =
  let upper = Ring.head ring in
  let pos = ref cursor.pos and continue = ref true in
  while !continue && !pos < upper do
    let here = !pos in
    let next = Ring.next ring here in
    match Ring.kind ring here with
    | Slice | Pad -> pos := next
    | Bytes ->
        let start = Ring.offset ring here and len = Ring.length ring here in
        if start + len <= cursor.offset && Connection.batch_count t.connection = 0 then pos := next
        else begin
          let skip =
            if Connection.batch_count t.connection = 0 then max 0 (cursor.offset - start) else 0
          in
          let i = Connection.batch_count t.connection in
          Connection.batch_add t.connection ~offset:(start + skip)
            ~at:(Ring.at ring here + skip)
            ~len:(len - skip);
          t.nexts.(i) <- next;
          t.ends.(i) <- start + len;
          pos := next;
          if Connection.batch_full t.connection then continue := flush_batch t cursor ring
        end
    | Marker ->
        if flush_batch t cursor ring then (
          Connection.json t.connection
            (Protocol.Event.view_to_json
               (Marked { offset = Ring.offset ring here; marker = Ring.marker ring here }));
          cursor.pos <- next;
          pos := next)
        else continue := false
  done;
  if !continue && flush_batch t cursor ring && cursor.pos < upper && !pos >= upper then
    cursor.pos <- !pos

let rec start_snapshot t cursor history =
  let snapshot = { cursor; history } in
  t.state <- Snapshotting snapshot;
  Pane_proc.snapshot (Pane.proc t.pane) ~history
    ~consume:(fun pos ->
      match t.state with
      | Snapshotting current when Stdlib.(current == snapshot) -> (
          let cursor = current.cursor and ring = ring t in
          match
            Connection.record t.connection ~queue:true ~kind:Snapshot ~offset:(Ring.offset ring pos)
              (Ring.buffer ring) ~at:(Ring.at ring pos) ~len:(Ring.length ring pos)
          with
          | Closed -> close t
          | Accepted ->
              cursor.pos <- Ring.next ring pos;
              cursor.offset <- Ring.offset ring pos
          | Queued | Blocked ->
              cursor.pos <- Ring.next ring pos;
              cursor.offset <- Ring.offset ring pos;
              cursor.blocked <- true)
      | _ -> ())
    ~done_:(function
      | Error _ ->
          Connection.reject t.connection Io;
          close t
      | Ok () -> (
          match t.state with
          | Snapshotting current when Stdlib.(current == snapshot) ->
              t.state <- Live (current.cursor, current.history);
              pump t
          | _ -> ()))

and flush_wanted t =
  match (t.state, t.wanted) with
  | Live (cursor, _), Some history when not (Connection.waiting t.connection) ->
      t.wanted <- None;
      start_snapshot t cursor history
  | _ -> ()

and pump t =
  flush_wanted t;
  match t.state with
  | Closed | Snapshotting _ -> ()
  | Live (cursor, history) -> (
      let ring = ring t in
      try
        if cursor.pos < Ring.head ring && Connection.available t.connection then begin
          let behind =
            match Ring.reachable ring cursor.pos with
            | None -> true
            | Some pos ->
                cursor.pos <- pos;
                false
          in
          let resize =
            (not behind)
            && (match history with History_none -> true | History_all -> false)
            && resize_pending ring cursor
          in
          match
            decide ~behind ~offset:cursor.offset ~head:(Ring.end_offset ring) ~history ~resize
              ~blocked:cursor.blocked
          with
          | Skip ->
              let head = Ring.end_offset ring in
              Connection.json t.connection
                (Protocol.Event.view_to_json
                   (Skipped { offset = head; from = cursor.offset; to_ = head }));
              cursor.blocked <- false;
              request_snapshot t Protocol.History_none
          | Snapshot history ->
              cursor.blocked <- false;
              request_snapshot t history
          | Resume ->
              cursor.blocked <- false;
              resume t cursor ring
        end
      with Invalid_argument _ ->
        Connection.reject t.connection Io;
        close t)

and request_snapshot t history =
  t.wanted <- Some history;
  flush_wanted t

let create pane connection ~client ~offset ~history =
  let ring = Pane_proc.ring (Pane.proc pane) in
  let cursor = { pos = 0; offset = 0; blocked = false } in
  let t =
    {
      pane;
      connection;
      client;
      state = Live (cursor, history);
      wanted = None;
      nexts = Array.make Connection.batch_capacity 0;
      ends = Array.make Connection.batch_capacity 0;
    }
  in
  (try
     cursor.offset <- Ring.end_offset ring;
     match offset with
     | Some value when value >= Ring.oldest_offset ring && value <= cursor.offset ->
         cursor.pos <- Ring.resume ring value;
         cursor.offset <- value;
         pump t
     | Some _ | None -> request_snapshot t history
   with Invalid_argument _ -> request_snapshot t history);
  t

let receive t text =
  try
    match Protocol.Request.view_of_json (Yojson.Basic.from_string text) with
    | Resync options -> request_snapshot t options.history
    | Input input -> (
        match
          Pane_proc.input (Pane.proc t.pane) input (function
            | Error _ -> Connection.reject t.connection Io
            | Ok None -> ()
            | Ok (Some reply) ->
                Connection.json t.connection (Protocol.Event.view_to_json (Pasted reply)))
        with
        | Ok () -> ()
        | Error _ -> Connection.reject t.connection Invalid)
  with Yojson.Json_error _ | Invalid_argument _ | Jsonkit.Of_json_error _ ->
    Connection.reject t.connection Invalid

let%test_module "Tests" =
  (module struct
    let%expect_test "resume, resize, threshold only after block" =
      List.iter
        (fun (offset, behind, full, resize, blocked) ->
          print_endline
            (match
               decide ~behind ~offset ~head:100000
                 ~history:(if full then History_all else History_none)
                 ~resize ~blocked
             with
            | Resume -> "resume"
            | Snapshot History_all -> "full"
            | Snapshot History_none -> "screen"
            | Skip -> "skip"))
        [
          (10, false, true, false, false);
          (9, true, true, false, false);
          (10, false, false, true, false);
          (10, false, true, true, false);
          (10, false, true, false, true);
          (99999, false, false, false, true);
        ];
      [%expect {|
 resume
 full
 screen
 resume
 skip
 resume
 |}]
  end)
