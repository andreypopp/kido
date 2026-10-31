let%test_module "Tests" =
  (module struct
    open Ko_server.Ring

    let { data_offset; record_header; bytes_tag; marker_tag; slice_tag; pad_tag } = layout

    let payload kind ~offset len =
      match kind with
      | Bytes -> String.init len (fun i -> Char.chr ((offset + i) land 0xff))
      | Marker ->
          if len land 1 = 0 then "\001\050\000\020\000\008\000\016\000"
          else "\002" ^ String.make 16 '\000'
      | Slice | Pad -> String.make (max 2 len) '\000'

    let advances_offset kind len = match kind with Bytes -> len | Marker | Slice | Pad -> 0

    (* ko-pane's room rule: a record never wraps, so the writer pads the rest of the buffer
       first; [fits] is the largest payload that is left once the pad is written *)
    let plan ~capacity ~head ~tail =
      let free = capacity - (head - tail) and room = capacity - (head mod capacity) in
      let pad, free, room =
        if room <= 2 * record_header then
          if free < room then (None, 0, 0) else (Some (room - record_header), free - room, capacity)
        else (None, free, room)
      in
      let n = min free room in
      (pad, if n <= 2 * record_header then 0 else n - (2 * record_header))

    module Reference = struct
      type record = { pos : int; kind : kind; offset : int; length : int }
      type state = { capacity : int; head : int; tail : int; offset : int; records : record list }
      type t = { mutable state : state }

      let finish r = r.pos + record_header + r.length

      let push s kind length =
        {
          s with
          head = s.head + record_header + length;
          offset = s.offset + advances_offset kind length;
          records = { pos = s.head; kind; offset = s.offset; length } :: s.records;
        }

      let create capacity = { state = { capacity; head = 0; tail = 0; offset = 0; records = [] } }
      let capacity t = t.state.capacity

      let write t kind len =
        let s = t.state in
        let pad, fits = plan ~capacity:s.capacity ~head:s.head ~tail:s.tail in
        let s = match pad with Some n -> push s Pad n | None -> s in
        let length = String.length (payload kind ~offset:s.offset len) in
        let ok = length <= fits in
        t.state <- (if ok then push s kind length else s);
        ok

      let live s = List.rev (List.filter (fun r -> r.pos >= s.tail) s.records)
      let boundaries t = List.map (fun r -> r.pos) (live t.state) @ [ t.state.head ]
      let positions t = List.rev_map (fun r -> r.pos) t.state.records @ [ t.state.head ]

      let advance t keep =
        let s = t.state in
        let retain = max s.tail (min (s.head - (s.capacity / 2)) keep) in
        t.state <- { s with tail = List.find (fun p -> p >= retain) (boundaries t) }

      let advance_boundary t i = advance t (List.nth (boundaries t) i)
      let tail t = t.state.tail
      let oldest_offset t = match live t.state with r :: _ -> r.offset | [] -> t.state.offset
      let end_offset t = t.state.offset

      let reachable t pos =
        let s = t.state in
        let lost =
          List.exists
            (fun r ->
              r.pos < s.tail
              && match r.kind with Bytes | Marker -> finish r > pos | Slice | Pad -> false)
            s.records
        in
        if lost then None else Some (max pos s.tail)

      let digest bytes = Int64.to_int (String.get_int64_le (Digest.string bytes) 0)

      let resume t target =
        let s = t.state in
        ( digest (payload Bytes ~offset:target (s.offset - target)),
          List.filter_map
            (fun r ->
              match r.kind with
              | (Marker | Slice) when r.offset >= target -> Some r.offset
              | Marker | Slice | Bytes | Pad -> None)
            (live s) )
    end

    module Candidate = struct
      type t = { buffer : Bigstringaf.t; ring : Ko_server.Ring.t; mutable offset : int }

      let create capacity =
        let buffer = Bigstringaf.create (data_offset + capacity) in
        Bigarray.Array1.fill buffer '\000';
        Bigstringaf.set_int64_le buffer 0 (Int64.of_int capacity);
        { buffer; ring = Ko_server.Ring.create buffer; offset = 0 }

      let capacity t = Bigstringaf.get_int64_le t.buffer 0 |> Int64.to_int

      let put t kind ~offset body =
        let head = head t.ring in
        let base = data_offset + (head mod capacity t) in
        t.buffer.{base} <-
          Char.chr
            (match kind with
            | Bytes -> bytes_tag
            | Marker -> marker_tag
            | Slice -> slice_tag
            | Pad -> pad_tag);
        Bigstringaf.set_int32_le t.buffer (base + 1) (Int32.of_int (String.length body));
        Bigstringaf.set_int64_le t.buffer (base + 5) (Int64.of_int offset);
        Bigstringaf.blit_from_string body ~src_off:0 t.buffer ~dst_off:(base + record_header)
          ~len:(String.length body);
        Bigstringaf.set_int64_le t.buffer 8
          (Int64.of_int (head + record_header + String.length body))

      let write t kind len =
        let pad, fits = plan ~capacity:(capacity t) ~head:(head t.ring) ~tail:(tail t.ring) in
        Option.iter (fun n -> put t Pad ~offset:t.offset (String.make n '\000')) pad;
        let body = payload kind ~offset:t.offset len in
        let ok = String.length body <= fits in
        if ok then (
          put t kind ~offset:t.offset body;
          t.offset <- t.offset + advances_offset kind len);
        ok

      let positions t from =
        let rec go pos = if pos >= head t.ring then [] else pos :: go (next t.ring pos) in
        go from

      let boundaries t = positions t (tail t.ring) @ [ head t.ring ]
      let advance t keep = advance t.ring ~head:(head t.ring) ~keep
      let advance_boundary t i = advance t (List.nth (boundaries t) i)

      let resume t target =
        let bytes = Buffer.create 64 and marks = ref [] in
        List.iter
          (fun pos ->
            match kind t.ring pos with
            | Bytes ->
                let skip = max 0 (target - offset t.ring pos) in
                Buffer.add_string bytes
                  (Bigstringaf.substring t.buffer
                     ~off:(at t.ring pos + skip)
                     ~len:(length t.ring pos - skip))
            | Marker | Slice -> marks := offset t.ring pos :: !marks
            | Pad -> ())
          (positions t (resume t.ring target));
        (Reference.digest (Buffer.contents bytes), List.rev !marks)

      let check (model : Reference.t) t =
        assert (head t.ring = model.state.head);
        assert (tail t.ring = Reference.tail model);
        assert (end_offset t.ring = Reference.end_offset model);
        assert (oldest_offset t.ring = Reference.oldest_offset model);
        List.iter
          (fun pos ->
            assert (Option.equal Int.equal (reachable t.ring pos) (Reference.reachable model pos)))
          (Reference.positions model)
    end

    let%test "a marker and bytes that end before the resume target are not replayed" =
      let model = Reference.create 553 and ring = Candidate.create 553 in
      assert (Reference.write model Marker 0 && Candidate.write ring Marker 0);
      assert (Reference.write model Bytes 180 && Candidate.write ring Bytes 180);
      let _, marks = Candidate.resume ring 76 in
      List.is_empty marks && Stdlib.( = ) (Reference.resume model 76) (Candidate.resume ring 76)

    let%test "the ring agrees with a list of records under random writes, advances and resumes" =
      let open Monolith in
      let ring =
        declare_abstract_type ~check:(fun model -> (Candidate.check model, constant "check")) ()
      in
      let write_length (t : Reference.t) = closed_interval 1 (Reference.capacity t / 3) in
      let boundary (t : Reference.t) = lt (List.length (Reference.boundaries t)) in
      declare "create" (closed_interval 64 600 ^> ring) Reference.create Candidate.create;
      declare "write_bytes"
        (ring ^>> fun t -> write_length t ^> bool)
        (fun t n -> Reference.write t Bytes n)
        (fun t n -> Candidate.write t Bytes n);
      declare "write_slice"
        (ring ^>> fun t -> write_length t ^> bool)
        (fun t n -> Reference.write t Slice n)
        (fun t n -> Candidate.write t Slice n);
      declare "write_marker"
        (ring ^> closed_interval 0 1 ^> bool)
        (fun t n -> Reference.write t Marker n)
        (fun t n -> Candidate.write t Marker n);
      declare "advance_to_head" (ring ^> unit)
        (fun t -> Reference.advance t t.state.head)
        (fun t -> Candidate.advance t (head t.ring));
      declare "advance_to_tail" (ring ^> unit)
        (fun t -> Reference.advance t t.state.tail)
        (fun t -> Candidate.advance t (tail t.ring));
      declare "advance_to_boundary"
        (ring ^>> fun t -> boundary t ^> unit)
        Reference.advance_boundary Candidate.advance_boundary;
      declare "resume"
        ( ring ^>> fun t ->
          closed_interval (Reference.oldest_offset t) (Reference.end_offset t)
          ^> pair int (list int) )
        Reference.resume Candidate.resume;
      Ko_server.Fuzz_run.monolith ~fuel:40 ()
  end)
