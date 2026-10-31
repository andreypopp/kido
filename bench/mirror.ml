let reader bytes =
  let offset = ref 0 in
  fun capacity ->
    let len = min capacity (String.length bytes - !offset) in
    let chunk = String.sub bytes !offset len in
    offset := !offset + len;
    chunk

let create ~cols ~rows = Bench_terminal.create ~cols ~rows ()

type mirror = { name : string; mutable terminal : Ko_vt.t; divergences : (string, int) Hashtbl.t }

let screen_snapshot server =
  Ko_vt.decode (reader (Ko_vt.snapshot server ~screen:true ~images:false)) ~full:false

let determinism ~iterations ~streams =
  let corpus =
    String.concat "" (List.map (fun f -> In_channel.with_open_bin f In_channel.input_all) streams)
  in
  let random = Random.State.make [| 182; 215 |] in
  let server = create ~cols:80 ~rows:24 in
  let mirror name = { name; terminal = create ~cols:80 ~rows:24; divergences = Hashtbl.create 8 } in
  let full = mirror "full, applies resize"
  and partial = mirror "partial, screen snapshot after resize"
  and self = mirror "partial, applies resize itself" in
  let mirrors = [ full; partial; self ] in
  let check ~marker ~moment m =
    List.iter
      (fun kind ->
        let key = moment ^ ": " ^ kind in
        let count = Option.value ~default:0 (Hashtbl.find_opt m.divergences key) in
        if count = 0 then
          Printf.printf "first divergence marker=%d mirror=%s %s\n%!" marker m.name key;
        Hashtbl.replace m.divergences key (count + 1))
      (Ko_vt.differences server m.terminal)
  in
  let offset = ref 0 in
  for marker = 1 to iterations do
    let start = !offset mod String.length corpus in
    let len = min (1 + Random.State.int random 65536) (String.length corpus - start) in
    let chunk = String.sub corpus start len in
    offset := !offset + len;
    List.iter
      (fun t -> Ko_vt.write t chunk)
      [ server; full.terminal; partial.terminal; self.terminal ];
    List.iter (check ~marker ~moment:"after bytes") mirrors;
    self.terminal <- screen_snapshot server;
    let cols = 2 + Random.State.int random 200 and rows = 2 + Random.State.int random 70 in
    List.iter (fun t -> Ko_vt.resize t ~cols ~rows) [ server; full.terminal; self.terminal ];
    partial.terminal <- screen_snapshot server;
    List.iter (check ~marker ~moment:"after resize") mirrors
  done;
  Printf.printf "determinism markers=%d bytes=%d\n" iterations !offset;
  List.iter
    (fun m ->
      Printf.printf "  mirror=%s:%s\n" m.name
        (if Hashtbl.length m.divergences = 0 then " none"
         else
           String.concat ""
             (List.map
                (fun (k, n) -> Printf.sprintf " [%s x%d]" k n)
                (List.sort Stdlib.compare (List.of_seq (Hashtbl.to_seq m.divergences))))))
    mirrors

let snapshots () =
  List.iter
    (fun lines ->
      let terminal = create ~cols:80 ~rows:24 in
      for line = 1 to lines do
        Ko_vt.write terminal
          (Printf.sprintf "%06d: \027[32mok\027[0m build step completed\r\n" line)
      done;
      List.iter
        (fun screen ->
          let start = Unix.gettimeofday () in
          let bytes = Ko_vt.snapshot terminal ~screen ~images:false in
          let encode = Unix.gettimeofday () -. start in
          let start = Unix.gettimeofday () in
          let restored = Ko_vt.decode (reader bytes) ~full:(not screen) in
          let decode = Unix.gettimeofday () -. start in
          Printf.printf
            "snapshot lines=%d rows_kept=%d kind=%s bytes=%d encode_ms=%.2f decode_ms=%.2f \
             rows_restored=%d screen_equal=%b\n\
             %!"
            lines (Ko_vt.total_rows terminal)
            (if screen then "screen" else "full")
            (String.length bytes) (encode *. 1e3) (decode *. 1e3) (Ko_vt.total_rows restored)
            (String.equal (Ko_vt.dump terminal Vt) (Ko_vt.dump restored Vt)))
        [ false; true ])
    [ 10_000; 100_000 ]

let () =
  match Array.to_list Sys.argv |> List.tl with
  | iterations :: streams ->
      determinism ~iterations:(int_of_string iterations) ~streams;
      snapshots ()
  | [] ->
      prerr_endline "usage: mirror ITERATIONS STREAM...";
      exit 2
