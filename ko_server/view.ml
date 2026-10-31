type decision = Resume | Snapshot of bool | Skip

let decide ~oldest ~offset ~head ~full ~resize ~blocked =
  if blocked && head - offset >= 65536 then Skip
  else if offset < oldest || offset > head then Snapshot full
  else if resize && not full then Snapshot false
  else Resume

type cursor = { mutable pos : int; mutable offset : int; mutable blocked : bool }
type snapshot = { cursor : cursor; full : bool; mutable resync : bool option }
type state = Live of cursor * bool | Snapshotting of snapshot | Closed

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

let rec request_snapshot t full =
  match t.state with
  | Closed -> ()
  | Snapshotting snapshot -> snapshot.resync <- Some full
  | Live (cursor, _) ->
      let snapshot = { cursor; full; resync = None } in
      t.state <- Snapshotting snapshot;
      Pane_proc.snapshot (Pane.proc t.pane) ~full
        ~consume:(fun record ->
          match t.state with
          | Snapshotting current when Stdlib.(current == snapshot) -> (
              let cursor = current.cursor in
              match
                Connection.record t.connection ~queue:true ~kind:2 ~offset:record.offset
                  (Pane_proc.buffer (Pane.proc t.pane))
                  ~at:record.at ~len:record.len
              with
              | Closed -> close t
              | Accepted ->
                  cursor.pos <- record.next;
                  cursor.offset <- record.offset
              | Blocked _ ->
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
                  t.state <- Live (current.cursor, current.full);
                  match snapshot.resync with Some full -> request_snapshot t full | None -> pump t)
              | _ -> ()))

and pump t =
  match t.state with
  | Closed | Snapshotting _ -> ()
  | Live (cursor, full) ->
      let proc = Pane.proc t.pane in
      if cursor.pos <> Pane_proc.position proc && Connection.available t.connection then begin
        let oldest = match Pane_proc.oldest proc with Some n -> n | None -> Pane.offset t.pane in
        let resize = ref false in
        if not full then
          Pane_proc.iter_from proc cursor.pos (fun record ->
              match record.data with
              | Resize_marker _ when record.offset >= cursor.offset ->
                  resize := true;
                  false
              | _ -> true);
        match
          decide ~oldest ~offset:cursor.offset ~head:(Pane.offset t.pane) ~full ~resize:!resize
            ~blocked:cursor.blocked
        with
        | Skip ->
            Connection.json t.connection
              (Protocol.view_event_to_json
                 (Skipped
                    { offset = Pane.offset t.pane; from = cursor.offset; to_ = Pane.offset t.pane }));
            cursor.blocked <- false;
            request_snapshot t false
        | Snapshot full ->
            cursor.blocked <- false;
            request_snapshot t full
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
                        Connection.record t.connection ~queue:false ~kind:1
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
                      | Blocked accepted ->
                          if accepted then (
                            cursor.pos <- record.next;
                            cursor.offset <- record.offset + record.len);
                          cursor.blocked <- true;
                          false)
                  | Resize_marker size ->
                      Connection.json t.connection
                        (Protocol.view_event_to_json
                           (Marked { offset = record.offset; marker = Resize size }));
                      cursor.pos <- record.next;
                      true
                  | Dead_marker dead ->
                      Connection.json t.connection
                        (Protocol.view_event_to_json
                           (Marked { offset = record.offset; marker = Dead dead }));
                      cursor.pos <- record.next;
                      true)
      end

let create pane connection ~client ~offset ~full =
  let cursor =
    { pos = 0; offset = Option.value ~default:(Pane.offset pane) offset; blocked = false }
  in
  let t = { pane; connection; client; state = Live (cursor, full) } in
  (match offset with
  | None -> request_snapshot t full
  | Some value -> (
      let oldest = Option.value ~default:(Pane.offset pane) (Pane_proc.oldest (Pane.proc pane)) in
      match
        decide ~oldest ~offset:value ~head:(Pane.offset pane) ~full ~resize:false ~blocked:false
      with
      | Snapshot full -> request_snapshot t full
      | Resume | Skip -> pump t));
  t

let receive t text =
  try
    match Protocol.view_message_of_json (Yojson.Basic.from_string text) with
    | Resync options -> request_snapshot t (Protocol.full options)
    | Input input -> (
        match
          Input.send t.pane input (function
            | Error _ -> Connection.reject t.connection Io
            | Ok None -> ()
            | Ok (Some reply) ->
                Connection.json t.connection (Protocol.view_event_to_json (Pasted reply)))
        with
        | Ok () -> ()
        | Error _ -> Connection.reject t.connection Invalid)
  with
  | Yojson.Json_error _ | Invalid_argument _ | Jsonkit.Of_json_error _ ->
    Connection.reject t.connection Invalid

let%test_module "Tests" =
  (module struct
    let%expect_test "resume, resize, threshold only after block" =
      List.iter
        (fun (offset, full, resize, blocked) ->
          print_endline
            (match decide ~oldest:10 ~offset ~head:100000 ~full ~resize ~blocked with
            | Resume -> "resume"
            | Snapshot true -> "full"
            | Snapshot false -> "screen"
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
