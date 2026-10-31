type layout = {
  data_offset : int;
  record_header : int;
  bytes_tag : int;
  marker_tag : int;
  slice_tag : int;
  pad_tag : int;
}

external layout : unit -> layout = "ko_ring_layout"
external reader_size : unit -> int = "ko_ring_reader_size"

let layout = layout ()

external attach : Bigstringaf.t -> Bigstringaf.t -> (int[@untagged])
  = "ko_ring_attach_reader_byte" "ko_ring_attach_reader"
[@@noalloc]

external head_of : Bigstringaf.t -> (int[@untagged]) = "ko_ring_head_byte" "ko_ring_head"
[@@noalloc]

external tail_of : Bigstringaf.t -> (int[@untagged]) = "ko_ring_tail_byte" "ko_ring_tail"
[@@noalloc]

external seen_of : Bigstringaf.t -> (int[@untagged]) = "ko_ring_seen_byte" "ko_ring_seen"
[@@noalloc]

external header_of : Bigstringaf.t -> (int[@untagged]) -> Bigstringaf.t -> (int[@untagged])
  = "ko_ring_header_byte" "ko_ring_header"
[@@noalloc]

external advance_of : Bigstringaf.t -> (int[@untagged]) -> (int[@untagged]) -> (int[@untagged])
  = "ko_ring_advance_byte" "ko_ring_advance"
[@@noalloc]

external reachable_of : Bigstringaf.t -> (int[@untagged]) -> (int[@untagged])
  = "ko_ring_reachable_byte" "ko_ring_reachable"
[@@noalloc]

external end_offset_of : Bigstringaf.t -> (int[@untagged])
  = "ko_ring_end_offset_byte" "ko_ring_end_offset"
[@@noalloc]

external resume_of : Bigstringaf.t -> (int[@untagged]) -> (int[@untagged])
  = "ko_ring_resume_byte" "ko_ring_resume"
[@@noalloc]

type kind = Bytes | Marker | Slice | Pad

type t = {
  buffer : Bigstringaf.t;
  reader : Bigstringaf.t;
  capacity : int;
  fields : Bigstringaf.t;
  mutable at : int;
  mutable tag : int;
}

let create buffer =
  let reader = Bigstringaf.create (reader_size ()) in
  Bigarray.Array1.fill reader '\000';
  let capacity = attach buffer reader in
  if capacity < 0 then invalid_arg "invalid ring capacity";
  { buffer; reader; capacity; fields = Bigstringaf.create 16; at = -1; tag = 0 }

let buffer t = t.buffer

let head t =
  let before = if Contract.on () then seen_of t.reader else 0 in
  let head = head_of t.reader in
  if Contract.on () then Contract.check (head >= before && head >= tail_of t.reader) "Ring.head";
  head

let tail t = tail_of t.reader

let header t pos =
  if pos <> t.at then begin
    let tag = header_of t.reader pos t.fields in
    if tag = 0 then invalid_arg "invalid ring record";
    t.at <- pos;
    t.tag <- tag;
    if Contract.on () then
      Contract.check
        (pos >= tail t
        && pos + layout.record_header + Mem.int64 t.fields 0 <= seen_of t.reader
        && Mem.int64 t.fields 8 <= pos)
        "Ring.header"
  end;
  t.tag

let kind t pos =
  let tag = header t pos in
  if tag = layout.bytes_tag then Bytes
  else if tag = layout.marker_tag then Marker
  else if tag = layout.slice_tag then Slice
  else Pad

let length t pos =
  ignore (header t pos : int);
  Mem.int64 t.fields 0

let offset t pos =
  ignore (header t pos : int);
  Mem.int64 t.fields 8

let next t pos = pos + layout.record_header + length t pos
let at t pos = layout.data_offset + (pos mod t.capacity) + layout.record_header

let slice t pos =
  if length t pos < Protocol.Record.slice_size then invalid_arg "invalid ring slice";
  Protocol.Record.slice_of_bigstring t.buffer (at t pos)

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

let advance_unchecked t head keep =
  t.at <- -1;
  if advance_of t.reader head keep = 0 then invalid_arg "invalid ring head"

let advance t ~head ~keep =
  if Contract.on () then begin
    let before = tail t in
    advance_unchecked t head keep;
    let after = tail t and retain = min (head - (t.capacity / 2)) keep in
    Contract.check
      (before <= after && after <= head
      && if retain <= before then after = before else retain <= after)
      "Ring.advance"
  end
  else advance_unchecked t head keep

let reachable t pos =
  match reachable_of t.reader pos with
  | -1 -> None
  | p ->
      if Contract.on () then Contract.check (p = max pos (tail t)) "Ring.reachable";
      Some p

let end_offset t =
  let offset = end_offset_of t.reader in
  if offset < 0 then invalid_arg "invalid ring record";
  offset

let oldest_offset t = if tail t < head t then offset t (tail t) else end_offset t

let resume t target =
  let pos = resume_of t.reader target in
  if pos < 0 then invalid_arg "invalid ring record";
  if Contract.on () then Contract.check (tail t <= pos && pos <= seen_of t.reader) "Ring.resume";
  pos
