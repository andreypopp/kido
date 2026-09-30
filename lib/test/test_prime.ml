open Kido

let ( // ) = Filename.concat
let path = Sys.getenv "PATH"
let check what ok = if not ok then print_endline ("FAILED: " ^ what)
let osc133 out = List.exists (fun c -> String.mem ~sub:("\027]133;" ^ c) out) [ "A"; "C"; "D" ]

let reports what out =
  List.iter
    (fun m -> check (Printf.sprintf "%s reports %S in %S" what m out) (String.mem ~sub:m out))
    [ "\027]133;A"; "\027]133;C;cmdline=true"; "\027]133;D;0" ]

let show_mode = function Prime.Plain -> "plain" | Zsh -> "zsh" | Bash -> "bash"

(* 4.4 is where PS0 arrived, and Apple ships 3.2. What does not parse is not primed: a bash left
   in posix mode for the life of the session is worse than no markers. *)
let%expect_test
    "local_mode: unknown shells are plain; zsh needs dotfiles; bash is asked its version" =
  let home = Sh.temp () in
  List.iter
    (fun p -> print_endline (show_mode (Prime.local_mode ~dotdir:home p)))
    [ "/bin/sh"; "/usr/bin/fish"; "/bin/ksh" ];
  let zsh = Sh.write (Sh.temp () // "zsh") "#!/bin/sh\n" in
  print_endline (show_mode (Prime.local_mode ~dotdir:home zsh));
  ignore (Sh.write ~perm:0o644 (home // ".zshrc") "\n");
  print_endline (show_mode (Prime.local_mode ~dotdir:home zsh));
  List.iter
    (fun v ->
      let bash = Sh.write (Sh.temp () // "bash") ("#!/bin/sh\nprintf '" ^ v ^ "'\n") in
      Printf.printf "%S %s\n" v (show_mode (Prime.local_mode ~dotdir:home bash)))
    [ "5.2\\n"; "4.4\\n"; "4.4"; "10.0\\n"; "4.3\\n"; "3.2\\n"; "\\n"; ".\\n"; "x.y\\n"; "" ];
  [%expect
    {|
    plain
    plain
    plain
    plain
    zsh
    "5.2\\n" bash
    "4.4\\n" bash
    "4.4" bash
    "10.0\\n" bash
    "4.3\\n" plain
    "3.2\\n" plain
    "\\n" plain
    ".\\n" plain
    "x.y\\n" plain
    "" plain
    |}]

let%expect_test
    "local priming writes a throwaway directory named by the one variable the shell reads" =
  let show env =
    List.iter
      (fun (k, v) ->
        let listing dir =
          String.concat " " (List.sort String.compare (Array.to_list (Sys.readdir dir)))
        in
        match k with
        | "ZDOTDIR" -> Printf.printf "ZDOTDIR: %s\n" (listing v)
        | "ENV" ->
            Printf.printf "ENV: %s, beside %s\n" (Filename.basename v)
              (listing (Filename.dirname v))
        | _ -> Printf.printf "%s: %s\n" k v)
      env
  in
  show (Prime.local ~zdotdir:None ~bin_dir:None Zsh);
  show (Prime.local ~zdotdir:(Some "/home/me/dots") ~bin_dir:None Zsh);
  show (Prime.local ~zdotdir:None ~bin_dir:None Bash);
  show (Prime.local ~zdotdir:None ~bin_dir:None Plain);
  [%expect
    {|
    ZDOTDIR: .zshenv integration.zsh
    ZDOTDIR: .zshenv integration.zsh
    KIDO_ORIG_ZDOTDIR: /home/me/dots
    ENV: env.bash, beside env.bash integration.bash
    |}]

let%expect_test "the bootstrap parses under sh" =
  print_string (Sh.output ~stdin:Prime.ssh_bootstrap ~env:[] "/bin/sh" [ "sh"; "-n" ]);
  [%expect {| |}]

let%expect_test "the bootstrap carries each integration as single-quoted base64" =
  List.iter
    (fun (name, src) ->
      match String.split_on_char '\'' Prime.ssh_bootstrap with
      | _ :: zsh :: _ :: bash :: _ ->
          let payload = if String.equal name "zsh" then zsh else bash in
          let decoded = Sh.output ~stdin:payload ~env:[] "/usr/bin/base64" [ "base64"; "-d" ] in
          Printf.printf "%s: decodes back %b, is kido's %b\n" name (String.equal decoded src)
            (String.mem ~sub:"kido_osc133_preexec" src)
      | _ -> print_endline "no payloads")
    [ ("zsh", Embedded.zsh_integration); ("bash", Embedded.bash_integration) ];
  [%expect
    {|
    zsh: decodes back true, is kido's true
    bash: decodes back true, is kido's true
    |}]

(* A stand-in for a remote login shell, reporting its arguments, the ZDOTDIR or ENV it was handed
   and what is in that directory. The bootstrap probes it with `$shell -c` (bash version) and
   `$shell -l -c :` (does -l work); a stand-in answering neither reads as unprimable. *)
let fake_shell name =
  Sh.write
    (Sh.temp () // name)
    {|#!/bin/sh
[ "$1" = "-c" ] && { echo 5.2; exit 0; }
[ "$2" = "-c" ] && exit 0
echo "args=$*"
echo "ZDOTDIR=${ZDOTDIR-<unset>}"
[ -n "$ZDOTDIR" ] && ls -a "$ZDOTDIR"
echo "ENV=${ENV-<unset>}"
[ -n "$ENV" ] && ls -a "$(dirname "$ENV")"
exit 0
|}

(* Under a real /bin/sh, as the remote's login shell would run it; TERM is dumb, for which readline
   adds no escapes of its own. Returns the output and what is left in its TMPDIR. *)
let bootstrap ?(path = path) ?stdin ?(env = []) ~home shell =
  let tmpdir = Sh.temp () in
  let out =
    Sh.output ?stdin
      ~env:
        ([ "PATH=" ^ path; "HOME=" ^ home; "SHELL=" ^ shell; "TMPDIR=" ^ tmpdir; "TERM=dumb" ] @ env)
      "/bin/sh"
      [ "/bin/sh"; "-c"; Prime.ssh_bootstrap ]
  in
  (out, Array.length (Sys.readdir tmpdir))

let zsh_home rc =
  let home = Sh.temp () in
  ignore (Sh.write ~perm:0o644 (home // ".zshrc") ("PS1='remote%% '\n" ^ rc));
  home

let field name out =
  List.find_map (String.chop_prefix ~pre:(name ^ "=")) (String.lines out)
  |> Option.get_or ~default:"<missing>"

let%expect_test "the bootstrap primes bash and zsh through a throwaway directory" =
  let show (out, left) =
    Printf.printf "%s ZDOTDIR=%s ENV=%s left=%d\n" (field "args" out)
      (if String.equal (field "ZDOTDIR" out) "<unset>" then "unset" else "set")
      (if String.equal (field "ENV" out) "<unset>" then "unset" else "set")
      left;
    List.iter
      (fun f -> if String.mem ~sub:("\n" ^ f ^ "\n") out then print_endline ("  holds " ^ f))
      [ ".zshenv"; "integration.zsh"; "env.bash"; "integration.bash" ]
  in
  show (bootstrap ~home:(Sh.temp ()) (fake_shell "bash"));
  let home = zsh_home "" in
  let out, left = bootstrap ~home (fake_shell "zsh") in
  show (out, left);
  check "ZDOTDIR is not the remote home" (not (String.equal (field "ZDOTDIR" out) home));
  [%expect
    {|
    --login --posix ZDOTDIR=unset ENV=set left=1
      holds env.bash
      holds integration.bash
    -l ZDOTDIR=set ENV=unset left=1
      holds .zshenv
      holds integration.zsh
    |}]

let%expect_test "the bootstrap redirects an existing ZDOTDIR, keeping it to restore" =
  let dots = zsh_home "" in
  let out, _ = bootstrap ~home:(Sh.temp ()) ~env:[ "ZDOTDIR=" ^ dots ] (fake_shell "zsh") in
  print_endline
    (match field "ZDOTDIR" out with
    | z when String.equal z dots -> "left pointing at the user's dotfiles"
    | "<unset>" -> "cleared"
    | _ -> "redirected");
  [%expect {| redirected |}]

(* Each exec's the login shell with nothing changed and leaves nothing behind. *)
let%expect_test "the bootstrap falls back to a plain shell" =
  let show what (out, left) =
    Printf.printf "%s: ZDOTDIR=%s left=%d\n" what (field "ZDOTDIR" out) left
  in
  show "ksh" (bootstrap ~home:(zsh_home "") (fake_shell "ksh"));
  show "zsh with no dotfiles" (bootstrap ~home:(Sh.temp ()) (fake_shell "zsh"));
  let zsh = fake_shell "zsh" in
  show "no base64" (bootstrap ~path:(Filename.dirname zsh) ~home:(zsh_home "") zsh);
  [%expect
    {|
    ksh: ZDOTDIR=<unset> left=0
    zsh with no dotfiles: ZDOTDIR=<unset> left=0
    no base64: ZDOTDIR=<unset> left=0
    |}]

let%expect_test "the bootstrap decodes with a BSD base64 that only takes -D" =
  let real = "/usr/bin/base64" in
  let shim = Sh.temp () in
  ignore
    (Sh.write (shim // "base64")
       (Printf.sprintf
          "#!/bin/sh\n\
           [ \"$1\" = \"-d\" ] && { echo 'invalid option -- d' >&2; exit 1; }\n\
           [ \"$1\" = \"-D\" ] && exec %s -d\n\
           exec %s \"$@\"\n"
          real real));
  let out, _ = bootstrap ~path:(shim ^ ":" ^ path) ~home:(zsh_home "") (fake_shell "zsh") in
  Printf.printf "primed %b, decoded %b\n"
    (not (String.equal (field "ZDOTDIR" out) "<unset>"))
    (String.mem ~sub:"integration.zsh" out);
  [%expect {| primed true, decoded true |}]

(* Real shells forced interactive with -i, standing in for the pty ssh -t would provide. zsh takes
   it first; bash after "$@", since bash's parser rejects a long option after a short one. *)
let interactive_zsh () =
  Tmux.Exec.look_path ~path "zsh"
  |> Option.map (fun real ->
      Sh.write
        (Sh.temp () // "zsh")
        ("#!/bin/sh\n[ \"$2\" = \"-c\" ] && exit 0\nexec " ^ real ^ " -i \"$@\"\n"))

let has_ps0 bash =
  match
    Sh.run ~env:[] bash
      [ bash; "-c"; "((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4)))" ]
  with
  | WEXITED 0, _ -> true
  | _ -> false

let interactive_bash () =
  Tmux.Exec.look_path ~path "bash" |> Option.filter has_ps0
  |> Option.map (fun real ->
      Sh.write (Sh.temp () // "bash") ("#!/bin/sh\nexec " ^ real ^ " \"$@\" -i\n"))

let script = "true\nexit\n"
let base ~home shell = [ "PATH=" ^ path; "HOME=" ^ home; "SHELL=" ^ shell; "TERM=dumb" ]

(* The claim `kido ssh` is for, with its negative control: run against a fresh $HOME, since a
   remote that already sourced kido's integration could not tell the two halves apart. *)
let%expect_test "the bootstrap primes a pristine zsh" =
  Option.iter
    (fun zsh ->
      let home = zsh_home "" in
      let control = Sh.output ~stdin:script ~env:(base ~home zsh) zsh [ zsh; "-l" ] in
      check "the pristine shell reports nothing without kido" (not (osc133 control));
      let out, left = bootstrap ~stdin:script ~home zsh in
      reports "the primed zsh" out;
      check "nothing left behind" (left = 0);
      check "the pristine .zshrc ran" (String.mem ~sub:"remote%" out))
    (interactive_zsh ());
  [%expect {| |}]

(* The integration is eval'd after the remote's rc files; under SH_WORD_SPLIT an unquoted eval
   rejoins its lines with spaces. *)
let%expect_test "the bootstrap primes a zsh that splits words" =
  Option.iter
    (fun zsh ->
      let out, _ = bootstrap ~stdin:script ~home:(zsh_home "setopt SH_WORD_SPLIT\n") zsh in
      check "primed under SH_WORD_SPLIT" (String.mem ~sub:"\027]133;C;cmdline=true" out))
    (interactive_zsh ());
  [%expect {| |}]

let%expect_test "the bootstrap hands a zsh its own ZDOTDIR back before .zshrc" =
  Option.iter
    (fun zsh ->
      let dots = zsh_home "" in
      let out, left = bootstrap ~stdin:script ~home:(Sh.temp ()) ~env:[ "ZDOTDIR=" ^ dots ] zsh in
      check "primed" (osc133 out);
      check "its own .zshrc ran" (String.mem ~sub:"remote%" out);
      check "nothing left behind" (left = 0))
    (interactive_zsh ());
  [%expect {| |}]

let%expect_test "the bootstrap primes a pristine bash" =
  Option.iter
    (fun bash ->
      let home = Sh.temp () in
      ignore (Sh.write ~perm:0o644 (home // ".bash_profile") "PS1='remote$ '\n");
      let control = Sh.output ~stdin:script ~env:(base ~home bash) bash [ bash; "--login" ] in
      check "the pristine shell reports nothing without kido" (not (osc133 control));
      let out, left = bootstrap ~stdin:script ~home bash in
      reports "the primed bash" out;
      check "nothing left behind" (left = 0);
      check "the pristine .bash_profile ran" (String.mem ~sub:"remote$" out))
    (interactive_bash ());
  [%expect {| |}]

(* Only /etc/profile and the first of .bash_profile, .bash_login, .profile, as a login bash would:
   a .bashrc runs only if the user's own .bash_profile sources it. *)
let%expect_test "the bootstrap's bash sources the login files a login bash would" =
  Option.iter
    (fun bash ->
      let home = Sh.temp () in
      ignore
        (Sh.write ~perm:0o644 (home // ".bash_profile")
           "echo KIDO_BASH_PROFILE_RAN\nsource ~/.bashrc\n");
      ignore (Sh.write ~perm:0o644 (home // ".bashrc") "echo KIDO_BASH_RC_RAN\n");
      let out, left = bootstrap ~stdin:script ~home bash in
      check "profile and rc ran"
        (String.mem ~sub:"KIDO_BASH_PROFILE_RAN" out && String.mem ~sub:"KIDO_BASH_RC_RAN" out);
      check "nothing left behind" (left = 0);
      let home = Sh.temp () in
      ignore (Sh.write ~perm:0o644 (home // ".profile") "echo KIDO_DOT_PROFILE_RAN\n");
      let out, left = bootstrap ~stdin:script ~home bash in
      check ".profile ran" (String.mem ~sub:"KIDO_DOT_PROFILE_RAN" out);
      check "primed" (osc133 out);
      check "nothing left behind" (left = 0))
    (interactive_bash ());
  [%expect {| |}]

(* Apple's 3.2 does not read $ENV under --posix at all, so the floor is checked in the bootstrap
   itself: an old bash gets its login files, no markers, and never posix mode. *)
let%expect_test "the bootstrap leaves a bash too old for PS0 alone" =
  if Sys.file_exists "/bin/bash" && not (has_ps0 "/bin/bash") then begin
    let bash = Sh.write (Sh.temp () // "bash") "#!/bin/sh\nexec /bin/bash \"$@\" -i\n" in
    let home = Sh.temp () in
    ignore (Sh.write ~perm:0o644 (home // ".bash_profile") "echo KIDO_OLD_BASH_PROFILE_RAN\n");
    let out, left = bootstrap ~stdin:"shopt -qo posix; echo KIDO_POSIX_SET=$?\nexit\n" ~home bash in
    check "no markers" (not (osc133 out));
    check "the login files ran" (String.mem ~sub:"KIDO_OLD_BASH_PROFILE_RAN" out);
    check "not in posix mode" (String.mem ~sub:"KIDO_POSIX_SET=1" out);
    check "nothing left behind" (left = 0)
  end;
  [%expect {| |}]

(* The local twin of the pristine-zsh test, and the claim `kido shell` is for. *)
let%expect_test "a zsh started the way kido shell starts it reports, and cleans up" =
  Option.iter
    (fun zsh ->
      let home = zsh_home "" in
      let run argv env = Sh.output ~stdin:script ~env zsh argv in
      check "the pristine shell reports nothing without kido"
        (not (osc133 (run [ zsh; "-l" ] (base ~home zsh))));
      let mode = Prime.local_mode ~dotdir:home zsh in
      check "a zsh with dotfiles is primed" (Stdlib.( = ) mode Prime.Zsh);
      let add = Prime.local ~zdotdir:None ~bin_dir:None mode in
      let out =
        run (Shell.argv zsh mode None) (base ~home zsh @ List.map (fun (k, v) -> k ^ "=" ^ v) add)
      in
      reports "the locally primed zsh" out;
      check "its directory is gone"
        (not (Sys.file_exists (List.assoc ~eq:String.equal "ZDOTDIR" add))))
    (interactive_zsh ());
  [%expect {| |}]

(* Why the prepend lives in the integration rather than only in the inherited environment: a login
   file that rewrites PATH (macOS path_helper, from /etc/zprofile) demotes an inherited entry, and
   the integration runs after every login file. *)
let%expect_test "a primed zsh puts kido's bin directory first on PATH, once" =
  Option.iter
    (fun zsh ->
      let home = zsh_home "" in
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
      check "the .zprofile demotes the inherited entry"
        (not (String.prefix ~pre:(bin ^ ":") (run [ zsh; "-l" ] [])));
      let got = run (Shell.argv zsh Zsh None) (Prime.local ~zdotdir:None ~bin_dir:(Some bin) Zsh) in
      check
        (Printf.sprintf "PATH %S starts with the bin directory, once" got)
        (String.prefix ~pre:(bin ^ ":") got && List.length (String.find_all_l ~sub:bin got) = 1))
    (interactive_zsh ());
  [%expect {| |}]
