let can_prime (a : Procs.ssh_args) ~tty =
  tty && List.is_empty a.command && not (String.exists (String.contains "NTWfsnOQVG") a.letters)

let args argv ~tty =
  match Procs.parse_ssh argv with
  | Some a when can_prime a ~tty -> ("ssh" :: a.opts) @ [ "-t"; a.dest; Prime.ssh_bootstrap ]
  | _ -> "ssh" :: argv

let run argv =
  let path = Option.get_or ~default:"" (Sys.getenv_opt "PATH") in
  let ssh =
    match Bin_dir.of_exe (Tmux.Exec.invoked_path ~path Sys.argv.(0)) with
    | Some dir ->
        Bin_dir.look_path_past ~path ~dir "ssh"
        |> Option.get_lazy (fun () -> failwith ("no ssh on PATH past " ^ dir))
    | None ->
        Tmux.Exec.look_path ~path "ssh"
        |> Option.get_lazy (fun () -> failwith {|exec: "ssh": executable file not found in $PATH|})
  in
  let tty =
    match Unix.fstat Unix.stdin with
    | st -> Stdlib.(st.st_kind = S_CHR)
    | exception Unix.Unix_error _ -> false
  in
  Unix.execve ssh (Array.of_list (args argv ~tty)) (Unix.environment ())
