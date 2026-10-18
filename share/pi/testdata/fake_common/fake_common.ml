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

let append path text =
  if not (String.is_empty path) then
    Out_channel.with_open_gen [ Open_append; Open_creat ] 0o644 path (fun channel ->
        Out_channel.output_string channel text)

let log path json = append (Fs.getenv path) (Yojson.Safe.to_string json ^ "\n")

let arg_after flag args =
  let rec find = function
    | [] -> None
    | key :: value :: _ when String.equal key flag -> Some value
    | _ :: rest -> find rest
  in
  find args
