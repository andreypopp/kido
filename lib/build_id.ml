let value =
  match Build_info.V1.version () with
  | Some x -> Build_info.V1.Version.to_string x
  | None -> "unknown"
