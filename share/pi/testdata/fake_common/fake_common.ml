let wait_gate gate =
  if not (String.is_empty gate) then begin
    let deadline = Unix.gettimeofday () +. 10. in
    while (not (Sys.file_exists gate)) && Float.(Unix.gettimeofday () < deadline) do
      Unix.sleepf 0.005
    done
  end

let read_rows key =
  match Sys.getenv_opt key with
  | None -> []
  | Some path -> (
      match Fs.read path with
      | None -> []
      | Some raw -> (
          match Yojson.Safe.from_string raw with
          | `List rows -> rows
          | _ -> []
          | exception Yojson.Json_error _ -> []))
