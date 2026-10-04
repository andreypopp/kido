let value =
  Option.map_or ~default:"unknown" Build_info.V1.Version.to_string (Build_info.V1.version ())
