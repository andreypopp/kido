let sun_path_max = 103

let inbox_path ~dir name =
  if String.is_empty name then failwith "empty name";
  if String.contains name '/' then
    failwith (Printf.sprintf "name %S contains a path separator" name);
  if String.mem ~sub:".." name then failwith (Printf.sprintf "name %S contains %S" name "..");
  let dir =
    Filename.concat
      (if Filename.is_relative dir then Filename.concat (Sys.getcwd ()) dir else dir)
      "inbox"
  in
  let path = Filename.concat dir (name ^ ".sock") in
  if String.length path > sun_path_max then
    failwith
      (Printf.sprintf "socket path is %d bytes, over the %d-byte limit: %s" (String.length path)
         sun_path_max path);
  Fs.mkdir_p (Filename.dirname dir);
  Fs.mkdir_p ~perm:0o700 dir;
  path
