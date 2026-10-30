let () =
  let terminal =
    Ko_vt.decode
      (fun n ->
        let bytes = Bytes.create n in
        let n = input stdin bytes 0 n in
        Bytes.sub_string bytes 0 n)
      ~full:(Array.length Sys.argv > 1)
  in
  Printf.printf "{\"sync\":%b,\"rows\":%d,\"screen\":%s,\"history\":%s}\n"
    (Ko_vt.mode terminal 2026) (Ko_vt.total_rows terminal)
    (Yojson.Safe.to_string (`String (Ko_vt.dump terminal Ko_vt.Plain)))
    (Yojson.Safe.to_string
       (`String (if Array.length Sys.argv > 1 then Ko_vt.dump_history terminal Ko_vt.Plain else "")))
