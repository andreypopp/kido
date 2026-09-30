let user_command_option = "@kido-user-command"

let bare_shell_word command =
  match String.trim command with
  | "" -> None
  | word when String.exists (String.contains " \t\n\"'$`\\;|&<>(){}[]*?~!#") word -> None
  | word -> Some word

let command ~path ~login user =
  match Option.flat_map bare_shell_word user with
  | None -> (login, user)
  | Some word -> (
      let resolved =
        if String.contains word '/' then word
        else Option.get_or ~default:word (Tmux.Exec.look_path ~path word)
      in
      match Filename.basename resolved with
      | "zsh" | "bash" -> (resolved, None)
      | _ when Bin_dir.same_file resolved login -> (login, None)
      | _ -> (login, user))

let with_env base add =
  let replaced kv =
    match String.index_opt kv '=' with
    | Some i -> List.mem_assoc ~eq:String.equal (String.sub kv 0 i) add
    | None -> false
  in
  Array.append
    (Array.filter (fun kv -> not (replaced kv)) base)
    (Array.of_list (List.map (fun (k, v) -> k ^ "=" ^ v) add))

let resolve_login_shell candidates =
  List.find_opt Tmux.Exec.is_executable candidates |> Option.get_or ~default:"/bin/sh"

let argv path mode command =
  let head =
    match (mode, command) with
    | Prime.Plain, None -> [ "-" ^ Filename.basename path ]
    | Plain, Some _ -> [ path ]
    | (Zsh | Bash), _ -> path :: Prime.shell_args mode
  in
  head @ Option.map_or ~default:[] (fun c -> [ "-c"; c ]) command

let run () =
  let path, command =
    command ~path:(Tmux.Exec.getenv "PATH")
      ~login:
        (resolve_login_shell [ Tmux.Exec.global_option "default-shell"; Tmux.Exec.getenv "SHELL" ])
      (match Tmux.Exec.global_option user_command_option with "" -> None | c -> Some c)
  in
  let zdotdir = Sys.getenv_opt "ZDOTDIR" in
  let mode =
    Prime.local_mode
      ~dotdir:(match zdotdir with None | Some "" -> Tmux.Exec.getenv "HOME" | Some d -> d)
      path
  in
  let mode, add =
    match Prime.local ~zdotdir ~bin_dir:(Bin_dir.own ()) mode with
    | add -> (mode, add)
    | exception (Sys_error _ | Unix.Unix_error _) -> (Prime.Plain, [])
  in
  Unix.execve path (Array.of_list (argv path mode command)) (with_env (Unix.environment ()) add)
