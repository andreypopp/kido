type data =
  | Bytes
  | Resize_marker of Protocol.size
  | Dead_marker of Protocol.dead
  | Slice of Protocol.Record.slice

type record = { pos : int; next : int; offset : int; at : int; len : int; data : data }
type node = { start : int; record : record option }

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

external head : Luv.Buffer.t -> int = "ko_pane_ring_head" [@@noalloc]
external set_tail : Luv.Buffer.t -> int -> unit = "ko_pane_ring_set_tail" [@@noalloc]
external set_read : Luv.Buffer.t -> int -> unit = "ko_pane_ring_set_read" [@@noalloc]

type t = {
  buffer : Luv.Buffer.t;
  capacity : int;
  mutable nodes : node array;
  mutable first : int;
  mutable count : int;
  mutable scanned : int;
  mutable tail : int;
  mutable offset : int;
  mutable dead : Protocol.dead option;
}

let empty = { start = 0; record = None }

let create buffer =
  {
    buffer;
    capacity = Int64.to_int (Bigstringaf.get_int64_le buffer 0);
    nodes = Array.make 64 empty;
    first = 0;
    count = 0;
    scanned = 0;
    tail = 0;
    offset = 0;
    dead = None;
  }

let buffer t = t.buffer
let position t = t.scanned
let tail t = t.tail
let offset t = t.offset
let dead t = t.dead
let pending t = head t.buffer > t.scanned
let nth t i = t.nodes.((t.first + i) mod Array.length t.nodes)

let push t node =
  if t.count = Array.length t.nodes then begin
    let grown = Array.make (2 * t.count) empty in
    for i = 0 to t.count - 1 do
      grown.(i) <- nth t i
    done;
    t.nodes <- grown;
    t.first <- 0
  end;
  t.nodes.((t.first + t.count) mod Array.length t.nodes) <- node;
  t.count <- t.count + 1

let drop t =
  t.nodes.(t.first) <- empty;
  t.first <- (t.first + 1) mod Array.length t.nodes;
  t.count <- t.count - 1

let u16 buffer at = Bigstringaf.get_int16_le buffer at land 0xffff

let read_record t pos =
  let base = layout.data_offset + (pos mod t.capacity) in
  let kind = Char.code t.buffer.{base}
  and len = Int32.to_int (Bigstringaf.get_int32_le t.buffer (base + 1)) in
  if len < 0 || len + layout.record_header > t.capacity - (pos mod t.capacity) then
    invalid_arg "invalid ring record length";
  let at = base + layout.record_header in
  let offset = Int64.to_int (Bigstringaf.get_int64_le t.buffer (base + 5)) in
  let next = pos + layout.record_header + len in
  if kind = layout.pad_tag then (None, next)
  else
    let data =
      if kind = layout.bytes_tag then Bytes
      else if kind = layout.marker_tag then
        begin if len = 9 && Char.code t.buffer.{at} = 1 then
          Resize_marker
            {
              Protocol.cols = u16 t.buffer (at + 1);
              rows = u16 t.buffer (at + 3);
              cell_px =
                (match (u16 t.buffer (at + 5), u16 t.buffer (at + 7)) with
                | 0, 0 -> None
                | width, height -> Some { width; height });
            }
        else if len = 17 && Char.code t.buffer.{at} = 2 then
          Dead_marker
            {
              Protocol.at = Int64.to_int (Bigstringaf.get_int64_le t.buffer (at + 9));
              cause =
                (match Int32.to_int (Bigstringaf.get_int32_le t.buffer (at + 5)) with
                | 0 -> Exited (Int32.to_int (Bigstringaf.get_int32_le t.buffer (at + 1)))
                | signal -> Signaled signal);
            }
        else invalid_arg "invalid ring marker"
        end
      else if kind = layout.slice_tag && len >= Protocol.Record.slice_size then
        Slice
          (Protocol.Record.slice_of_string
             (Bigstringaf.substring t.buffer ~off:at ~len:Protocol.Record.slice_size)
             0)
      else invalid_arg "invalid ring record kind"
    in
    (Some { pos; next; offset; at; len; data }, next)

let scan t f =
  try
    let upper = head t.buffer in
    if upper < t.scanned || upper - t.tail > t.capacity then invalid_arg "invalid ring head";
    let changed = upper > t.scanned in
    while t.scanned < upper do
      let record, next = read_record t t.scanned in
      push t { start = t.scanned; record };
      t.scanned <- next;
      Option.iter
        (fun record ->
          (match record.data with
          | Bytes -> t.offset <- record.offset + record.len
          | Dead_marker dead -> t.dead <- Some dead
          | Resize_marker _ | Slice _ -> ());
          f record)
        record
    done;
    set_read t.buffer t.scanned;
    let retain = upper - (t.capacity / 2) in
    while t.count > 0 && (nth t 0).start < retain do
      drop t
    done;
    let tail = if t.count > 0 then (nth t 0).start else upper in
    if tail > t.tail then (
      t.tail <- tail;
      set_tail t.buffer tail);
    Ok (changed || pending t)
  with Invalid_argument message -> Error message

let first_record t =
  let rec go i =
    if i = t.count then None
    else match (nth t i).record with Some record -> Some record | None -> go (i + 1)
  in
  go 0

let oldest t = match first_record t with Some record -> record.offset | None -> t.offset

let from t pos =
  let low = ref 0 and high = ref t.count in
  while !low < !high do
    let mid = (!low + !high) / 2 in
    if (nth t mid).start < pos then low := mid + 1 else high := mid
  done;
  !low

let iter_from t pos f =
  let rec loop i =
    if i < t.count then
      match (nth t i).record with
      | None -> loop (i + 1)
      | Some record -> if f record then loop (i + 1)
  in
  loop (from t pos)

let resume t offset =
  let rec go i =
    if i = t.count then t.scanned
    else
      let node = nth t i in
      match node.record with
      | Some { data = Bytes; offset = start; len; _ } when start + len > offset -> node.start
      | Some { data = Bytes; _ } | None -> go (i + 1)
      | Some record -> if record.offset >= offset then node.start else go (i + 1)
  in
  go 0

let%test_module "Tests" =
  (module struct
    let%expect_test "ring layout and offsets" =
      let buffer = Luv.Buffer.create (layout.data_offset + 64) in
      Bigarray.Array1.fill buffer '\000';
      Bigstringaf.set_int64_le buffer 0 64L;
      let t = create buffer in
      let base = layout.data_offset in
      buffer.{base} <- Char.chr layout.bytes_tag;
      Bigstringaf.set_int32_le buffer (base + 1) 3l;
      Bigstringaf.set_int64_le buffer (base + 5) 42L;
      let record, _ = read_record t 0 in
      Option.iter (fun r -> Printf.printf "%d %d %d\n" r.len r.offset r.at) record;
      Bigstringaf.set_int32_le buffer (base + 1) 127l;
      (try ignore (read_record t 0) with Invalid_argument message -> print_endline message);
      [%expect {|
 3 42 45
 invalid ring record length
 |}]
  end)
