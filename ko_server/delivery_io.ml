type token = { req : int; consume : int -> unit; finish : bool -> unit }
type entry = { token : token; at : int }
type pane_io = { requests : entry Queue.t; finished : entry Queue.t }
type view_io = { request : Protocol.history -> int -> bool }

let req token = token.req
let pane_io_create () = { requests = Queue.create (); finished = Queue.create () }
let queue_empty io = Queue.is_empty io.requests
let queue_front io = (Queue.peek io.requests).token
let queue_floor io = (Queue.peek io.requests).at
let queue_push io token floor = Queue.add { token; at = floor } io.requests
let queue_pop io = ignore (Queue.take io.requests : entry)

let queue_to_fin io hold =
  let { token; at = _ } = Queue.take io.requests in
  Queue.add { token; at = hold } io.finished

let fin_empty io = Queue.is_empty io.finished
let fin_front io = (Queue.peek io.finished).token
let fin_hold io = (Queue.peek io.finished).at
let fin_pop io = ignore (Queue.take io.finished : entry)
let slice token pos = token.consume pos
let finish token ok = token.finish ok
let slice_last ring pos = (Ring.slice ring pos).last

let is_resize ring pos =
  match Ring.marker ring pos with Protocol.Resize _ -> true | Protocol.Dead _ -> false

let request io history gen = io.request history gen

let reject_io connection =
  Connection.reject connection Protocol.Io;
  if Contract.on () then Contract.check (Connection.is_closed connection) "Delivery_io.reject_io"

let batch_add connection offset at len =
  if Contract.on () then begin
    let count = Connection.batch_count connection in
    Connection.batch_add connection ~offset ~at ~len;
    Contract.check (Connection.batch_count connection = count + 1) "Delivery_io.batch_add"
  end
  else Connection.batch_add connection ~offset ~at ~len

let kept connection closed what =
  Contract.check
    (Connection.batch_count connection = 0 && ((not closed) || Connection.is_closed connection))
    what

let json connection event what =
  if Contract.on () then begin
    let closed = Connection.is_closed connection in
    Connection.json connection (Protocol.Event.view_to_json event);
    kept connection closed what
  end
  else Connection.json connection (Protocol.Event.view_to_json event)

let json_marked connection ring pos offset =
  json connection (Marked { offset; marker = Ring.marker ring pos }) "Delivery_io.json_marked"

let json_skipped connection head from =
  json connection (Skipped { offset = head; from; to_ = head }) "Delivery_io.json_skipped"

let record_unchecked connection buffer offset at len =
  Connection.record connection ~queue:true ~kind:Protocol.Record.Snapshot ~offset buffer ~at ~len

let record connection buffer offset at len =
  if Contract.on () then begin
    let closed = Connection.is_closed connection in
    let written = record_unchecked connection buffer offset at len in
    kept connection closed "Delivery_io.record";
    Contract.check
      (match written with Closed -> Connection.is_closed connection | _ -> true)
      "Delivery_io.record";
    written
  end
  else record_unchecked connection buffer offset at len
