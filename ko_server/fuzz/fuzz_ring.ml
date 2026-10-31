let%test_module "Tests" =
  (module struct
    open Ko_server.Ring

    let data_offset = 32
    and record_header = 13

    type op =
      | Write of kind * int
      | Advance of [ `Head | `Tail | `Boundary of int ]
      | Resume of int

    type model = {
      buffer : Luv.Buffer.t;
      ring : t;
      capacity : int;
      mutable head : int;
      mutable offset : int;
      mutable records : (int * kind * int * string) list;
    }

    let make capacity =
      let buffer = Luv.Buffer.create (data_offset + capacity) in
      Bigarray.Array1.fill buffer '\000';
      Bigstringaf.set_int64_le buffer 0 (Int64.of_int capacity);
      { buffer; ring = create buffer; capacity; head = 0; offset = 0; records = [] }

    let put m kind ~offset payload =
      let base = data_offset + (m.head mod m.capacity) in
      m.buffer.{base} <-
        Char.chr (match kind with Bytes -> 1 | Marker -> 2 | Slice -> 3 | Pad -> 4);
      Bigstringaf.set_int32_le m.buffer (base + 1) (Int32.of_int (String.length payload));
      Bigstringaf.set_int64_le m.buffer (base + 5) (Int64.of_int offset);
      Bigstringaf.blit_from_string payload ~src_off:0 m.buffer ~dst_off:(base + record_header)
        ~len:(String.length payload);
      m.records <- (m.head, kind, offset, payload) :: m.records;
      m.head <- m.head + record_header + String.length payload;
      Bigstringaf.set_int64_le m.buffer 8 (Int64.of_int m.head)

    let available m =
      let free = m.capacity - (m.head - tail m.ring)
      and room = m.capacity - (m.head mod m.capacity) in
      let free, room =
        if room <= 2 * record_header then
          if free < room then (0, 0)
          else (
            put m Pad ~offset:m.offset (String.make (room - record_header) '\000');
            (free - room, m.capacity))
        else (free, room)
      in
      let n = min free room in
      if n <= 2 * record_header then 0 else n - (2 * record_header)

    let write m kind len =
      let payload =
        match kind with
        | Bytes -> String.init len (fun i -> Char.chr ((m.offset + i) land 0xff))
        | Marker ->
            if len land 1 = 0 then "\001\050\000\020\000\008\000\016\000"
            else "\002" ^ String.make 16 '\000'
        | Slice | Pad -> String.make (max 2 len) '\000'
      in
      if String.length payload <= available m then (
        put m kind ~offset:m.offset payload;
        match kind with Bytes -> m.offset <- m.offset + len | Marker | Slice | Pad -> ())

    let boundaries m = List.rev_map (fun (pos, _, _, _) -> pos) m.records

    let replay m target =
      let upper = head m.ring in
      let rec go pos acc =
        if pos >= upper then List.rev acc
        else
          go (next m.ring pos) ((pos, kind m.ring pos, offset m.ring pos, length m.ring pos) :: acc)
      in
      let from = resume m.ring target in
      let bytes = Buffer.create 64 and marks = ref [] in
      List.iter
        (fun (pos, k, off, len) ->
          match k with
          | Bytes ->
              let skip = max 0 (target - off) in
              Buffer.add_string bytes
                (Bigstringaf.substring m.buffer ~off:(at m.ring pos + skip) ~len:(len - skip))
          | Marker | Slice -> marks := off :: !marks
          | Pad -> ())
        (go from []);
      (Buffer.contents bytes, List.rev !marks)

    let step m op =
      match op with
      | Write (kind, len) -> write m kind len
      | Advance keep ->
          let upper = head m.ring and old = tail m.ring in
          let keep =
            match keep with
            | `Head -> upper
            | `Tail -> old
            | `Boundary i ->
                let live = List.filter (fun p -> p >= old) (boundaries m) in
                if List.is_empty live then upper else List.nth live (i mod List.length live)
          in
          assert (Result.is_ok (advance m.ring ~head:upper ~keep));
          let now = tail m.ring in
          assert (now >= old && List.mem ~eq:Int.equal now (upper :: boundaries m));
          assert (now <= max old keep);
          if keep = upper then assert (upper - now <= m.capacity / 2)
      | Resume target ->
          let oldest = oldest_offset m.ring and stop = end_offset m.ring in
          let target = oldest + (target mod (stop - oldest + 1)) in
          let bytes, marks = replay m target in
          let expected = String.init (stop - target) (fun i -> Char.chr ((target + i) land 0xff)) in
          assert (String.equal bytes expected);
          let retained =
            List.filter_map
              (fun (pos, k, off, _) ->
                match k with
                | (Marker | Slice) when pos >= tail m.ring && off >= target -> Some off
                | Marker | Slice | Bytes | Pad -> None)
              (List.rev m.records)
          in
          assert (List.equal Int.equal marks retained)

    let invariants m =
      assert (end_offset m.ring = m.offset);
      let live = List.filter (fun (p, _, _, _) -> p >= tail m.ring) (List.rev m.records) in
      assert (oldest_offset m.ring = match live with (_, _, off, _) :: _ -> off | [] -> m.offset);
      let lost =
        List.filter_map
          (fun (p, k, _, payload) ->
            match k with
            | (Bytes | Marker) when p < tail m.ring ->
                Some (p + record_header + String.length payload)
            | Bytes | Marker | Slice | Pad -> None)
          m.records
      in
      List.iter
        (fun pos ->
          let expected =
            if List.exists (fun finish -> finish > pos) lost then None
            else Some (max pos (tail m.ring))
          in
          assert (Option.equal Int.equal (reachable m.ring pos) expected))
        (m.head :: boundaries m)

    let op_gen capacity =
      let open QCheck.Gen in
      oneof_weighted
        [
          (6, map (fun n -> Write (Bytes, n)) (1 -- (capacity / 3)));
          (1, map (fun n -> Write (Marker, n)) (0 -- 1));
          (1, map (fun n -> Write (Slice, n)) (0 -- (capacity / 3)));
          (2, map (fun i -> Advance (`Boundary i)) nat);
          (1, return (Advance `Head));
          (1, return (Advance `Tail));
          (2, map (fun n -> Resume n) nat);
        ]

    let seed, seconds = Fuzz_check.budget ()

    let%test "the ring keeps its contract under random writes, advances and resumes" =
      let arb =
        QCheck.make
          ~shrink:(fun (capacity, ops) ->
            QCheck.Iter.map (fun ops -> (capacity, ops)) (QCheck.Shrink.list ops))
          ~print:(fun (capacity, ops) ->
            let op = function
              | Write (Bytes, n) -> Printf.sprintf "bytes %d" n
              | Write (Marker, n) -> Printf.sprintf "marker %d" n
              | Write (Slice, n) -> Printf.sprintf "slice %d" n
              | Write (Pad, n) -> Printf.sprintf "pad %d" n
              | Advance `Head -> "advance head"
              | Advance `Tail -> "advance tail"
              | Advance (`Boundary i) -> Printf.sprintf "advance boundary %d" i
              | Resume n -> Printf.sprintf "resume %d" n
            in
            Printf.sprintf "capacity %d: %s" capacity (String.concat "; " (List.map op ops)))
          QCheck.Gen.(
            let* capacity = 64 -- 600 in
            let+ ops = list_size (1 -- 80) (op_gen capacity) in
            (capacity, ops))
      in
      Fuzz_check.check ?seed ?seconds ~count:100 ~name:"ring" arb (fun (capacity, ops) ->
          let m = make capacity in
          List.iter
            (fun op ->
              step m op;
              invariants m)
            ops;
          true);
      true
  end)
