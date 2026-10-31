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

let rec start_snapshot t cursor history =
  let snapshot = { cursor; history } in
  t.state <- Snapshotting snapshot;
  Pane_proc.snapshot (Pane.proc t.pane) ~history
    ~consume:(fun record ->
      match t.state with
      | Snapshotting current when Stdlib.(current == snapshot) -> (
          let cursor = current.cursor in
          match
            Connection.record t.connection ~queue:true ~kind:Snapshot ~offset:record.offset
              (Ring.buffer (ring t))
              ~at:record.at ~len:record.len
          with
          | Closed -> close t
          | Accepted ->
              cursor.pos <- record.next;
              cursor.offset <- record.offset
          | Queued | Blocked ->
              cursor.pos <- record.next;
              cursor.offset <- record.offset;
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
  | Live (cursor, history) ->
      let ring = ring t in
      if cursor.pos <> Ring.position ring && Connection.available t.connection then begin
        let resize = ref false in
        if match history with History_none -> true | History_all -> false then
          Ring.iter_from ring cursor.pos (fun record ->
              match record.data with
              | Resize_marker _ when record.offset >= cursor.offset ->
                  resize := true;
                  false
              | _ -> true);
        match
          decide
            ~behind:(cursor.pos < Ring.tail ring)
            ~offset:cursor.offset ~head:(Ring.offset ring) ~history ~resize:!resize
            ~blocked:cursor.blocked
        with
        | Skip ->
            Connection.json t.connection
              (Protocol.Event.view_to_json
                 (Skipped
                    { offset = Ring.offset ring; from = cursor.offset; to_ = Ring.offset ring }));
            cursor.blocked <- false;
            request_snapshot t Protocol.History_none
        | Snapshot history ->
            cursor.blocked <- false;
            request_snapshot t history
        | Resume ->
            cursor.blocked <- false;
            Ring.iter_from ring cursor.pos (fun record ->
                if not (Connection.available t.connection) then (
                  cursor.blocked <- true;
                  false)
                else
                  match record.data with
                  | Slice _ ->
                      cursor.pos <- record.next;
                      true
                  | Bytes when record.offset + record.len <= cursor.offset ->
                      cursor.pos <- record.next;
                      true
                  | Bytes -> (
                      let skip = max 0 (cursor.offset - record.offset) in
                      match
                        Connection.record t.connection ~queue:false ~kind:Output
                          ~offset:(record.offset + skip) (Ring.buffer ring) ~at:(record.at + skip)
                          ~len:(record.len - skip)
                      with
                      | Closed ->
                          close t;
                          false
                      | Accepted ->
                          cursor.pos <- record.next;
                          cursor.offset <- record.offset + record.len;
                          true
                      | Queued ->
                          cursor.pos <- record.next;
                          cursor.offset <- record.offset + record.len;
                          cursor.blocked <- true;
                          false
                      | Blocked ->
                          cursor.blocked <- true;
                          false)
                  | Resize_marker size ->
                      Connection.json t.connection
                        (Protocol.Event.view_to_json
                           (Marked { offset = record.offset; marker = Resize size }));
                      cursor.pos <- record.next;
                      true
                  | Dead_marker dead ->
                      Connection.json t.connection
                        (Protocol.Event.view_to_json
                           (Marked { offset = record.offset; marker = Dead dead }));
                      cursor.pos <- record.next;
                      true)
      end

and request_snapshot t history =
  t.wanted <- Some history;
  flush_wanted t

let create pane connection ~client ~offset ~history =
  let ring = Pane_proc.ring (Pane.proc pane) in
  let cursor = { pos = 0; offset = Ring.offset ring; blocked = false } in
  let t = { pane; connection; client; state = Live (cursor, history); wanted = None } in
  (match offset with
  | Some value when value >= Ring.oldest ring && value <= Ring.offset ring ->
      cursor.pos <- Ring.resume ring value;
      cursor.offset <- value;
      pump t
  | Some _ | None -> request_snapshot t history);
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
