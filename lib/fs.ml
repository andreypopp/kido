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
