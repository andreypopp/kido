type decision = Resume | Snapshot of Protocol.history | Skip

let decide ~oldest ~offset ~head ~history ~resize ~blocked =
  if blocked && head - offset >= 65536 then Skip
  else if offset < oldest || offset > head then Snapshot history
  else if resize && match history with History_none -> true | History_all -> false then
    Snapshot History_none
  else Resume

type cursor = { mutable pos : int; mutable offset : int; mutable blocked : bool }

type snapshot = {
  cursor : cursor;
  history : Protocol.history;
  mutable resync : Protocol.history option;
}

type state = Live of cursor * Protocol.history | Snapshotting of snapshot | Closed

type t = {
  pane : Pane.t;
  connection : Connection.t;
  client : Ids.Client_id.t option;
  mutable state : state;
}

let client t = t.client
let pane t = t.pane

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

let rec request_snapshot t history =
  match t.state with
  | Closed -> ()
  | Snapshotting snapshot -> snapshot.resync <- Some history
  | Live (cursor, _) ->
      let snapshot = { cursor; history; resync = None } in
      t.state <- Snapshotting snapshot;
      Pane_proc.snapshot (Pane.proc t.pane) ~history
        ~consume:(fun record ->
          match t.state with
          | Snapshotting current when Stdlib.(current == snapshot) -> (
              let cursor = current.cursor in
              match
                Connection.record t.connection ~queue:true ~kind:Snapshot ~offset:record.offset
                  (Pane_proc.buffer (Pane.proc t.pane))
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
              | Snapshotting current when Stdlib.(current == snapshot) -> (
                  t.state <- Live (current.cursor, current.history);
                  match snapshot.resync with
                  | Some history -> request_snapshot t history
                  | None -> pump t)
              | _ -> ()))

and pump t =
  match t.state with
  | Closed | Snapshotting _ -> ()
  | Live (cursor, history) ->
      let proc = Pane.proc t.pane in
      if cursor.pos <> Pane_proc.position proc && Connection.available t.connection then begin
        let oldest = Pane.oldest t.pane in
        let resize = ref false in
        if match history with History_none -> true | History_all -> false then
          Pane_proc.iter_from proc cursor.pos (fun record ->
              match record.data with
              | Resize_marker _ when record.offset >= cursor.offset ->
                  resize := true;
                  false
              | _ -> true);
        match
          decide ~oldest ~offset:cursor.offset ~head:(Pane.offset t.pane) ~history ~resize:!resize
            ~blocked:cursor.blocked
        with
        | Skip ->
            Connection.json t.connection
              (Protocol.Event.view_to_json
                 (Skipped
                    { offset = Pane.offset t.pane; from = cursor.offset; to_ = Pane.offset t.pane }));
            cursor.blocked <- false;
            request_snapshot t History_none
        | Snapshot history ->
            cursor.blocked <- false;
            request_snapshot t history
        | Resume ->
            cursor.blocked <- false;
            Pane_proc.iter_from proc cursor.pos (fun record ->
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
                          ~offset:(record.offset + skip) (Pane_proc.buffer proc)
                          ~at:(record.at + skip) ~len:(record.len - skip)
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

let create pane connection ~client ~offset ~history =
  let cursor =
    { pos = 0; offset = Option.value ~default:(Pane.offset pane) offset; blocked = false }
  in
  let t = { pane; connection; client; state = Live (cursor, history) } in
  (match offset with
  | None -> request_snapshot t history
  | Some value -> (
      let oldest = Pane.oldest pane in
      match
        decide ~oldest ~offset:value ~head:(Pane.offset pane) ~history ~resize:false ~blocked:false
      with
      | Snapshot history -> request_snapshot t history
      | Resume | Skip -> pump t));
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
        (fun (offset, full, resize, blocked) ->
          print_endline
            (match
               decide ~oldest:10 ~offset ~head:100000
                 ~history:(if full then History_all else History_none)
                 ~resize ~blocked
             with
            | Resume -> "resume"
            | Snapshot History_all -> "full"
            | Snapshot History_none -> "screen"
            | Skip -> "skip"))
        [
          (10, true, false, false);
          (9, true, false, false);
          (10, false, true, false);
          (10, true, true, false);
          (10, true, false, true);
          (99999, false, false, true);
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
