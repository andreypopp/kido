let find ~exe rel =
  Tmux.Exec.candidates exe
  |> List.map (fun c ->
      Filename.concat (Filename.dirname (Filename.dirname c)) (Filename.concat "share/kido" rel))
  |> List.find_opt (fun p -> Sys.file_exists p && not (Sys.is_directory p))
