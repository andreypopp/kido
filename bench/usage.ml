let mib n = float_of_int n /. 1048576.

let history_line i =
  Printf.sprintf "line %06d the quick brown fox jumps over the lazy dog 0123456789\r\n" i

let report label vt =
  let m = Ko_vt.memory vt in
  Printf.printf "%s: %d pages, %d compressed, resident %.1f MiB\n%!" label m.pages
    m.compressed_pages (mib m.resident_bytes)

let () =
  match Sys.argv with
  | [| _; lines; cols; rows |] ->
      let lines = int_of_string lines in
      let vt =
        Bench_terminal.create ~scrollback_max_bytes:200_000_000 ~cols:(int_of_string cols)
          ~rows:(int_of_string rows) ()
      in
      Ko_vt.write vt (String.concat "" (List.init lines (fun i -> history_line (i + 1))));
      report "ko-pane terminal, history written" vt;
      let steps = ref 0 and slowest = ref 0. and total = ref 0. in
      let now = Ko_vt.now_ns () + 1_000_000_000 in
      while
        let began = Unix.gettimeofday () in
        let next = Ko_vt.compress_tick vt ~now_ns:now in
        let took = Unix.gettimeofday () -. began in
        incr steps;
        total := !total +. took;
        slowest := Float.max !slowest took;
        next = 0
      do
        ()
      done;
      Printf.printf "incremental compression: %d ticks, %.1f ms total, slowest %.2f ms\n" !steps
        (!total *. 1000.) (!slowest *. 1000.);
      report "ko-pane terminal, compressed" vt;
      let snapshot = Ko_vt.snapshot vt ~screen:false ~images:false in
      Printf.printf "snapshot: %.1f MiB\n" (mib (String.length snapshot));
      let began = Unix.gettimeofday () in
      let mirror = Ko_vt.decode_string ~full:true snapshot in
      Printf.printf "decode: %.1f ms\n" ((Unix.gettimeofday () -. began) *. 1000.);
      report "client mirror, decoded" mirror
  | _ ->
      prerr_endline "usage: usage LINES COLS ROWS";
      exit 2
