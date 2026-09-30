let rec mkdir_p ?(perm = 0o755) d =
  if not (Sys.file_exists d) then begin
    mkdir_p (Filename.dirname d);
    try Unix.mkdir d perm with Unix.Unix_error (EEXIST, _, _) -> ()
  end

let read path =
  try Some (In_channel.with_open_bin path In_channel.input_all) with Sys_error _ -> None

let write ?(perm = 0o644) path s =
  Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_trunc; Open_binary ] perm path
    (fun oc -> Out_channel.output_string oc s)

let remove path = try Unix.unlink path with Unix.Unix_error (ENOENT, _, _) -> ()

let write_temp ?(perm = 0o644) path data place =
  let rec create_unique () =
    let tmp = Printf.sprintf "%s.tmp.%d.%d" path (Unix.getpid ()) (Random.bits ()) in
    match Unix.openfile tmp [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] perm with
    | fd -> (tmp, fd)
    | exception Unix.Unix_error (Unix.EEXIST, _, _) -> create_unique ()
  in
  let tmp, fd = create_unique () in
  Fun.protect
    ~finally:(fun () -> remove tmp)
    (fun () ->
      Fun.protect
        ~finally:(fun () -> Unix.close fd)
        (fun () -> ignore (Unix.write_substring fd data 0 (String.length data)));
      place tmp path)

let write_atomic ?perm path data = write_temp ?perm path data Unix.rename

let unix_message e fn arg =
  String.concat " " (List.filter (fun s -> not (String.is_empty s)) [ fn; arg ])
  ^ ": " ^ Unix.error_message e
