type layout = {
  data_offset : int;
  record_header : int;
  bytes_tag : int;
  marker_tag : int;
  slice_tag : int;
  pad_tag : int;
}

external layout : unit -> layout = "ko_ring_layout"

let layout = layout ()

external head_of : Bigstringaf.t -> int = "ko_pane_ring_head" [@@noalloc]
external set_tail : Bigstringaf.t -> int -> unit = "ko_pane_ring_set_tail" [@@noalloc]
external set_read : Bigstringaf.t -> int -> unit = "ko_pane_ring_set_read" [@@noalloc]

type kind = Bytes | Marker | Slice | Pad

type t = {
  buffer : Bigstringaf.t;
  capacity : int;
  mutable tail : int;
  mutable evicted_data : int;
  mutable settled : int;
  mutable settled_offset : int;
}

let create buffer =
  {
    buffer;
    capacity = Mem.int64 buffer 0;
    tail = 0;
    evicted_data = 0;
    settled = 0;
    settled_offset = 0;
  }

let buffer t = t.buffer
let head t = head_of t.buffer
let tail t = t.tail
let base t pos = layout.data_offset + (pos mod t.capacity)

let length t pos =
  let len = Mem.int32 t.buffer (base t pos + 1) in
  if len < 0 || len + layout.record_header > t.capacity - (pos mod t.capacity) then
    invalid_arg "invalid ring record length";
  len

let next t pos = pos + layout.record_header + length t pos

let kind t pos =
  let tag = Char.code t.buffer.{base t pos} in
  if tag = layout.bytes_tag then Bytes
  else if tag = layout.marker_tag then Marker
  else if tag = layout.slice_tag then Slice
  else if tag = layout.pad_tag then Pad
  else invalid_arg "invalid ring record kind"

let offset t pos = Mem.int64 t.buffer (base t pos + 5)
let at t pos = base t pos + layout.record_header

let slice t pos =
  if length t pos < Protocol.Record.slice_size then invalid_arg "invalid ring slice";
  Protocol.Record.slice_of_string
    (Bigstringaf.substring t.buffer ~off:(at t pos) ~len:Protocol.Record.slice_size)
    0

let u16 t at = Mem.uint16 t.buffer at

let marker t pos : Protocol.marker =
  let len = length t pos and at = at t pos in
  if len = 9 && Char.code t.buffer.{at} = 1 then
    Resize
      {
        Protocol.cols = u16 t (at + 1);
        rows = u16 t (at + 3);
        cell_px =
          (match (u16 t (at + 5), u16 t (at + 7)) with
          | 0, 0 -> None
          | width, height -> Some { width; height });
      }
  else if len = 17 && Char.code t.buffer.{at} = 2 then
    Dead
      {
        Protocol.at = Mem.int64 t.buffer (at + 9);
        cause =
          (match Mem.int32 t.buffer (at + 5) with
          | 0 -> Exited (Mem.int32 t.buffer (at + 1))
          | signal -> Signaled signal);
      }
  else invalid_arg "invalid ring marker"

let advance t ~head:upper ~keep =
  try
    if upper < t.tail || upper - t.tail > t.capacity then invalid_arg "invalid ring head";
    let retain = min (upper - (t.capacity / 2)) keep in
    let tail = ref t.tail and last_end = ref 0 and evicted_data = ref t.evicted_data in
    while !tail < retain do
      (match kind t !tail with
      | Bytes ->
          last_end := offset t !tail + length t !tail;
          evicted_data := next t !tail
      | Marker ->
          last_end := offset t !tail;
          evicted_data := next t !tail
      | Slice -> last_end := offset t !tail
      | Pad -> ());
      tail := next t !tail
    done;
    if !tail > t.tail then (
      t.tail <- !tail;
      t.evicted_data <- !evicted_data;
      set_tail t.buffer !tail;
      if t.settled < !tail then
        if !tail < upper then (
          t.settled <- !tail;
          t.settled_offset <- offset t !tail)
        else (
          t.settled <- upper;
          t.settled_offset <- !last_end));
    set_read t.buffer upper;
    Ok ()
  with Invalid_argument message -> Error message

let reachable t pos = if pos < t.evicted_data then None else Some (max pos t.tail)

let end_offset t =
  let upper = head t in
  while t.settled < upper do
    (match kind t t.settled with
    | Bytes -> t.settled_offset <- offset t t.settled + length t t.settled
    | Marker | Slice -> t.settled_offset <- offset t t.settled
    | Pad -> ());
    t.settled <- next t t.settled
  done;
  t.settled_offset

let oldest_offset t = if t.tail < head t then offset t t.tail else end_offset t

let resume t target =
  let upper = head t in
  let rec go pos =
    if pos >= upper then upper
    else
      match kind t pos with
      | Bytes -> if offset t pos + length t pos > target then pos else go (next t pos)
      | Marker | Slice -> if offset t pos >= target then pos else go (next t pos)
      | Pad -> go (next t pos)
  in
  go t.tail
