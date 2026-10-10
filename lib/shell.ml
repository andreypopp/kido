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

let%test_module "Tests" =
  (module struct
    (* An unprimed shell gets tmux's own dashed argv[0] rather than -l: a shell kido knows nothing
   about is exactly the shell that might not take -l. *)
    let%expect_test "argv per mode" =
      List.iter
        (fun (path, mode, command) -> print_endline (String.concat " " (argv path mode command)))
        [
          ("/bin/zsh", Prime.Zsh, None);
          ("/bin/bash", Bash, None);
          ("/usr/bin/fish", Plain, None);
          ("/bin/zsh", Zsh, Some "tmux-mem-cpu-load");
          ("/usr/bin/fish", Plain, Some "top");
        ];
      [%expect
        {|
    /bin/zsh -l
    /bin/bash --login --posix
    -fish
    /bin/zsh -l -c tmux-mem-cpu-load
    /usr/bin/fish -c top
    |}]

    let%expect_test "command primes a bare word naming zsh or bash as the shell, and nothing else" =
      let show (path, command) =
        Printf.printf "%s %s\n" (Filename.basename path) (Option.get_or ~default:"-" command)
      in
      let path = Sys.getenv "PATH" in
      List.iter
        (fun c -> show (command ~path ~login:"/bin/zsh" c))
        [
          Some "zsh";
          Some "/bin/zsh";
          Some "bash";
          Some "zsh -l";
          Some "fish";
          Some "reattach-to-user-namespace -l zsh";
          Some "  zsh  ";
          Some "   ";
          None;
        ];
      let real = Sh.write (Filename.concat (Sh.temp ()) "myshell") "#!/bin/sh\n" in
      show (command ~path ~login:real (Some real));
      [%expect
        {|
    zsh -
    zsh -
    bash -
    zsh zsh -l
    zsh fish
    zsh reattach-to-user-namespace -l zsh
    zsh -
    zsh
    zsh -
    myshell -
    |}]

    (* A count: "the new value is in there" holds for an appending version too, and getenv answers
   with the first match. *)
    let%expect_test "with_env replaces rather than appends" =
      with_env
        [| "PATH=/bin"; "ZDOTDIR=/home/me/dots"; "TERM=xterm" |]
        [ ("ZDOTDIR", "/tmp/kido-shell.1"); ("KIDO_ORIG_ZDOTDIR", "/home/me/dots") ]
      |> Array.iter print_endline;
      [%expect
        {|
    PATH=/bin
    TERM=xterm
    ZDOTDIR=/tmp/kido-shell.1
    KIDO_ORIG_ZDOTDIR=/home/me/dots
    |}]

    let ( // ) = Filename.concat
    let path = Sys.getenv "PATH"

    (* The local twin of the pristine-zsh test, and the claim `kido shell` is for. *)
    let%expect_test "a zsh started the way kido shell starts it reports, and cleans up" =
      Option.iter
        (fun zsh ->
          let home = Sh.zsh_home "" in
          let run argv env = Sh.output ~stdin:"true\nexit\n" ~env zsh argv in
          Sh.check "the pristine shell reports nothing without kido"
            (not (Sh.osc133 (run [ zsh; "-l" ] (Sh.base ~path ~home zsh))));
          let mode = Prime.local_mode ~dotdir:home zsh in
          Sh.check "a zsh with dotfiles is primed" (Stdlib.( = ) mode Prime.Zsh);
          let add = Prime.local ~zdotdir:None ~bin_dir:None mode in
          let out =
            run (argv zsh mode None)
              (Sh.base ~path ~home zsh @ List.map (fun (k, v) -> k ^ "=" ^ v) add)
          in
          Sh.reports "the locally primed zsh" out;
          Sh.check "its directory is gone"
            (not (Sys.file_exists (List.assoc ~eq:String.equal "ZDOTDIR" add))))
        (Sh.interactive_zsh ~path ());
      [%expect {| |}]

    (* Why the prepend lives in the integration rather than only in the inherited environment: a login
   file that rewrites PATH (macOS path_helper, from /etc/zprofile) demotes an inherited entry, and
   the integration runs after every login file. *)
    let%expect_test "a primed zsh puts kido's bin directory first on PATH, once" =
      Option.iter
        (fun zsh ->
          let home = Sh.zsh_home "" in
          ignore (Sh.write ~perm:0o644 (home // ".zprofile") "PATH=/usr/bin:/bin:$PATH\n");
          let bin = Sh.temp () // "kido bin" in
          let run argv add =
            let out =
              Sh.output ~stdin:"printf 'PATH<%s>\\n' \"$PATH\"\nexit\n"
                ~env:
                  ([ "PATH=" ^ bin ^ ":/usr/bin:/bin"; "HOME=" ^ home; "SHELL=" ^ zsh; "TERM=dumb" ]
                  @ List.map (fun (k, v) -> k ^ "=" ^ v) add)
                zsh argv
            in
            String.find_all_l ~sub:"PATH<" out
            |> List.filter_map (fun i ->
                let rest = String.drop (i + 5) out in
                Option.map (fun j -> String.sub rest 0 j) (String.index_opt rest '>'))
            |> List.last_opt |> Option.get_or ~default:""
          in
          Sh.check "the .zprofile demotes the inherited entry"
            (not (String.prefix ~pre:(bin ^ ":") (run [ zsh; "-l" ] [])));
          let got = run (argv zsh Zsh None) (Prime.local ~zdotdir:None ~bin_dir:(Some bin) Zsh) in
          Sh.check
            (Printf.sprintf "PATH %S starts with the bin directory, once" got)
            (String.prefix ~pre:(bin ^ ":") got && List.length (String.find_all_l ~sub:bin got) = 1))
        (Sh.interactive_zsh ~path ());
      [%expect {| |}]
  end)
