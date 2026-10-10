type mode = Plain | Zsh | Bash

let zshenv =
  {|# Written by kido into a throwaway ZDOTDIR.
# It removes itself; nothing kido writes here is meant to outlive the session.
if [[ -n ${KIDO_ORIG_ZDOTDIR+X} ]]; then
  export ZDOTDIR=$KIDO_ORIG_ZDOTDIR
else
  unset ZDOTDIR
fi
unset KIDO_ORIG_ZDOTDIR
# Every expansion is quoted: /etc/zshenv runs before this file and may
# have set SH_WORD_SPLIT, under which an unquoted eval would rejoin the
# integration's lines with spaces.
{
  _kido_dir="${${(%):-%x}:A:h}"
  _kido_src="$(<"$_kido_dir/integration.zsh")"
  command rm -rf -- "$_kido_dir"
  unset _kido_dir
  _kido_zshenv="${ZDOTDIR-~}/.zshenv"
  [[ ! -r $_kido_zshenv ]] || source -- "$_kido_zshenv"
  unset _kido_zshenv
} always {
  if [[ -o interactive && -n $_kido_src ]]; then
    typeset -ag precmd_functions
    precmd_functions+=(_kido_ssh_init)
  else
    unset _kido_src
  fi
}
_kido_ssh_init() {
  precmd_functions=(${precmd_functions:#_kido_ssh_init})
  eval "$_kido_src"
  unset _kido_src
  unfunction _kido_ssh_init
  (( $+functions[kido_osc133_precmd] )) && kido_osc133_precmd
}
|}

let bash_env =
  {|# Written by kido into a throwaway $ENV file.
# It removes itself; nothing kido writes here is meant to outlive the session.
unset ENV
set +o posix
# Resetting posix mode does not clear this on its own - kitty's bash
# integration carries the same comment, against the same bash behaviour.
shopt -u inherit_errexit 2>/dev/null
_kido_dir="${BASH_SOURCE%/*}"
[ ! -r /etc/profile ] || . /etc/profile
for _kido_f in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
  if [ -r "$_kido_f" ]; then . "$_kido_f"; break; fi
done
unset _kido_f
[ ! -f "$_kido_dir/integration.bash" ] || . "$_kido_dir/integration.bash"
rm -rf -- "$_kido_dir"
unset _kido_dir
|}

let files ~bin_dir mode =
  let with_path integration =
    integration ^ Option.map_or ~default:"" Bin_dir.path_prepend_script bin_dir
  in
  match mode with
  | Plain -> []
  | Zsh -> [ (".zshenv", zshenv); ("integration.zsh", with_path Embedded.zsh_integration) ]
  | Bash -> [ ("env.bash", bash_env); ("integration.bash", with_path Embedded.bash_integration) ]

let shell_args = function Bash -> [ "--login"; "--posix" ] | Plain | Zsh -> [ "-l" ]
let bash_version_probe = {|echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"|}
let ps0_major = 4
let ps0_minor = 4

let bash_has_ps0 out =
  match String.split_on_char '.' (String.trim out) with
  | [ major; minor ] -> (
      match (Int.of_string major, Int.of_string minor) with
      | Some maj, Some min -> maj > ps0_major || (maj = ps0_major && min >= ps0_minor)
      | _ -> false)
  | _ -> false

let local ~zdotdir ~bin_dir mode =
  let prime env =
    let dir = Filename.temp_dir "kido-shell." "" in
    let files = files ~bin_dir mode in
    match
      List.iter (fun (name, body) -> Fs.write ~perm:0o600 (Filename.concat dir name) body) files
    with
    | () -> env dir
    | exception e ->
        List.iter (fun (name, _) -> Fs.remove (Filename.concat dir name)) files;
        Unix.rmdir dir;
        raise e
  in
  match mode with
  | Plain -> []
  | Zsh ->
      prime (fun dir ->
          ("ZDOTDIR", dir)
          :: Option.map_or ~default:[] (fun old -> [ ("KIDO_ORIG_ZDOTDIR", old) ]) zdotdir)
  | Bash -> prime (fun dir -> [ ("ENV", Filename.concat dir "env.bash") ])

let bash_version path =
  match
    Unix.open_process_args_full path [| path; "-c"; bash_version_probe |] (Unix.environment ())
  with
  | exception Unix.Unix_error _ -> ""
  | (out, _, _) as p -> (
      let v = In_channel.input_all out in
      match Unix.close_process_full p with WEXITED 0 -> v | _ -> "")

let local_mode ~dotdir path =
  match Filename.basename path with
  | "zsh"
    when List.exists
           (fun name -> Fs.is_file (Filename.concat dotdir name))
           [ ".zshrc"; ".zshenv"; ".zprofile"; ".zlogin" ] ->
      Zsh
  | "bash" when bash_has_ps0 (bash_version path) -> Bash
  | _ -> Plain

let base64 s =
  let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/" in
  let n = String.length s in
  let byte i = if i < n then Char.code s.[i] else 0 in
  String.concat ""
    (List.init
       ((n + 2) / 3)
       (fun k ->
         let i = 3 * k in
         let v = (byte i lsl 16) lor (byte (i + 1) lsl 8) lor byte (i + 2) in
         String.init 4 (fun j ->
             if j > n - i then '=' else alphabet.[(v lsr (18 - (6 * j))) land 63])))

let ssh_bootstrap =
  let args mode = String.concat " " (shell_args mode) in
  Printf.sprintf
    {|kido_zsh_b64='%s'
kido_bash_b64='%s'
kido_dir=''
kido_shell=${SHELL:-/bin/sh}
[ -x "$kido_shell" ] || kido_shell=/bin/sh
kido_name=${kido_shell##*/}
kido_plain() {
  [ -n "$kido_dir" ] && rm -rf "$kido_dir"
  "$kido_shell" %s -c : >/dev/null 2>&1 && exec "$kido_shell" %s
  exec "$kido_shell"
}
kido_decode() {
  printf %%s "$1" | base64 -d > "$2" 2>/dev/null
  [ -s "$2" ] || printf %%s "$1" | base64 -D > "$2" 2>/dev/null
  [ -s "$2" ]
}
kido_bash_has_ps0() {
  kido_v=$("$kido_shell" -c '%s' 2>/dev/null)
  kido_maj=${kido_v%%%%.*}
  kido_min=${kido_v#*.}
  case "$kido_maj$kido_min" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$kido_maj" -gt %d ] || { [ "$kido_maj" -eq %d ] && [ "$kido_min" -ge %d ]; }
}
case "$kido_name" in
  zsh) ;;
  # PS0 arrived in bash 4.4. An older bash is left alone here rather than
  # inside the $ENV file, which it may never read: it gets its own login
  # files and no markers, the "unprimed but not broken" outcome kido_plain
  # gives a remote with no zsh, no mktemp or no base64.
  bash) kido_bash_has_ps0 || kido_plain ;;
  *) kido_plain ;;
esac
command -v mktemp >/dev/null 2>&1 && command -v base64 >/dev/null 2>&1 || kido_plain
kido_dir=$(mktemp -d "${TMPDIR:-/tmp}/kido-ssh.XXXXXXXX" 2>/dev/null) && [ -d "$kido_dir" ] || kido_plain
trap 'rm -rf "$kido_dir"' EXIT HUP INT TERM
if [ "$kido_name" = zsh ]; then
  kido_decode "$kido_zsh_b64" "$kido_dir/integration.zsh" || kido_plain
  kido_zdotdir=${ZDOTDIR:-$HOME}
  [ -f "$kido_zdotdir/.zshrc" ] || [ -f "$kido_zdotdir/.zshenv" ] ||
    [ -f "$kido_zdotdir/.zprofile" ] || [ -f "$kido_zdotdir/.zlogin" ] || kido_plain
  cat > "$kido_dir/.zshenv" <<'KIDO_ZSHENV' || kido_plain
%sKIDO_ZSHENV
  [ -n "$ZDOTDIR" ] && export KIDO_ORIG_ZDOTDIR="$ZDOTDIR"
  export ZDOTDIR="$kido_dir"
  exec "$kido_shell" %s
fi
# No dotfile guard here, unlike the zsh branch above: kitty's
# exec_bash_with_integration has none either, and the guard it does have
# in exec_zsh_with_integration is commented "dont prevent
# zsh-newuser-install from running". bash has no first-login installer to
# suppress, and a remote with no login files at all is one the $ENV file
# below sources nothing from, which is what bash would have done anyway.
kido_decode "$kido_bash_b64" "$kido_dir/integration.bash" || kido_plain
cat > "$kido_dir/env.bash" <<'KIDO_BASHENV' || kido_plain
%sKIDO_BASHENV
export ENV="$kido_dir/env.bash"
exec "$kido_shell" %s
|}
    (base64 Embedded.zsh_integration)
    (base64 Embedded.bash_integration)
    (args Plain) (args Plain) bash_version_probe ps0_major ps0_major ps0_minor zshenv (args Zsh)
    bash_env (args Bash)

let%test_module "Tests" =
  (module struct
    let ( // ) = Filename.concat

    (* The far side of `kido ssh` has no kido and no shims. *)
    let%expect_test "only a local prime moves PATH" =
      let marker = Bin_dir.path_prepend_script "/k/bin" in
      List.iter
        (fun mode ->
          let bodies bin_dir =
            List.concat_map
              (fun (_, v) ->
                let dir = if Sys.is_directory v then v else Filename.dirname v in
                List.map
                  (fun f -> Option.get_or ~default:"" (Fs.read (dir // f)))
                  (Array.to_list (Sys.readdir dir)))
              (local ~zdotdir:None ~bin_dir mode)
          in
          let moves bin_dir = List.exists (String.mem ~sub:"_kido_bin") (bodies bin_dir) in
          Printf.printf "given a bin dir %b, carries the script %b, without one %b\n"
            (moves (Some "/k/bin"))
            (List.exists (String.mem ~sub:marker) (bodies (Some "/k/bin")))
            (moves None))
        [ Zsh; Bash ];
      Printf.printf "ssh: %b\n"
        (List.exists (String.mem ~sub:"_kido_bin")
           [ ssh_bootstrap; Embedded.zsh_integration; Embedded.bash_integration ]);
      [%expect
        {|
    given a bin dir true, carries the script true, without one false
    given a bin dir true, carries the script true, without one false
    ssh: false
    |}]

    let path = Sys.getenv "PATH"
    let show_mode = function Plain -> "plain" | Zsh -> "zsh" | Bash -> "bash"

    (* 4.4 is where PS0 arrived, and Apple ships 3.2. What does not parse is not primed: a bash left
   in posix mode for the life of the session is worse than no markers. *)
    let%expect_test
        "local_mode: unknown shells are plain; zsh needs dotfiles; bash is asked its version" =
      let home = Sh.temp () in
      List.iter
        (fun p -> print_endline (show_mode (local_mode ~dotdir:home p)))
        [ "/bin/sh"; "/usr/bin/fish"; "/bin/ksh" ];
      let zsh = Sh.write (Sh.temp () // "zsh") "#!/bin/sh\n" in
      print_endline (show_mode (local_mode ~dotdir:home zsh));
      ignore (Sh.write ~perm:0o644 (home // ".zshrc") "\n");
      print_endline (show_mode (local_mode ~dotdir:home zsh));
      List.iter
        (fun v ->
          let bash = Sh.write (Sh.temp () // "bash") ("#!/bin/sh\nprintf '" ^ v ^ "'\n") in
          Printf.printf "%S %s\n" v (show_mode (local_mode ~dotdir:home bash)))
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
      show (local ~zdotdir:None ~bin_dir:None Zsh);
      show (local ~zdotdir:(Some "/home/me/dots") ~bin_dir:None Zsh);
      show (local ~zdotdir:None ~bin_dir:None Bash);
      show (local ~zdotdir:None ~bin_dir:None Plain);
      [%expect
        {|
    ZDOTDIR: .zshenv integration.zsh
    ZDOTDIR: .zshenv integration.zsh
    KIDO_ORIG_ZDOTDIR: /home/me/dots
    ENV: env.bash, beside env.bash integration.bash
    |}]

    let%expect_test "the bootstrap parses under sh" =
      print_string (Sh.output ~stdin:ssh_bootstrap ~env:[] "/bin/sh" [ "sh"; "-n" ]);
      [%expect {| |}]

    let%expect_test "the bootstrap carries each integration as single-quoted base64" =
      List.iter
        (fun (name, src) ->
          match String.split_on_char '\'' ssh_bootstrap with
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
            ([ "PATH=" ^ path; "HOME=" ^ home; "SHELL=" ^ shell; "TMPDIR=" ^ tmpdir; "TERM=dumb" ]
            @ env)
          "/bin/sh"
          [ "/bin/sh"; "-c"; ssh_bootstrap ]
      in
      (out, Array.length (Sys.readdir tmpdir))

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
      let home = Sh.zsh_home "" in
      let out, left = bootstrap ~home (fake_shell "zsh") in
      show (out, left);
      Sh.check "ZDOTDIR is not the remote home" (not (String.equal (field "ZDOTDIR" out) home));
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
      let dots = Sh.zsh_home "" in
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
      show "ksh" (bootstrap ~home:(Sh.zsh_home "") (fake_shell "ksh"));
      show "zsh with no dotfiles" (bootstrap ~home:(Sh.temp ()) (fake_shell "zsh"));
      let zsh = fake_shell "zsh" in
      show "no base64" (bootstrap ~path:(Filename.dirname zsh) ~home:(Sh.zsh_home "") zsh);
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
      let out, _ = bootstrap ~path:(shim ^ ":" ^ path) ~home:(Sh.zsh_home "") (fake_shell "zsh") in
      Printf.printf "primed %b, decoded %b\n"
        (not (String.equal (field "ZDOTDIR" out) "<unset>"))
        (String.mem ~sub:"integration.zsh" out);
      [%expect {| primed true, decoded true |}]

    (* Real shells forced interactive with -i, standing in for the pty ssh -t would provide. zsh takes
   it first; bash after "$@", since bash's parser rejects a long option after a short one. *)
    let has_ps0 bash =
      match
        Sh.run ~env:[] bash
          [
            bash;
            "-c";
            "((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4)))";
          ]
      with
      | WEXITED 0, _ -> true
      | _ -> false

    let interactive_bash () =
      Fs.look_path ~path "bash" |> Option.filter has_ps0
      |> Option.map (fun real ->
          Sh.write (Sh.temp () // "bash") ("#!/bin/sh\nexec " ^ real ^ " \"$@\" -i\n"))

    let script = "true\nexit\n"

    (* The claim `kido ssh` is for, with its negative control: run against a fresh $HOME, since a
   remote that already sourced kido's integration could not tell the two halves apart. *)
    let%expect_test "the bootstrap primes a pristine zsh" =
      Option.iter
        (fun zsh ->
          let home = Sh.zsh_home "" in
          let control = Sh.output ~stdin:script ~env:(Sh.base ~path ~home zsh) zsh [ zsh; "-l" ] in
          Sh.check "the pristine shell reports nothing without kido" (not (Sh.osc133 control));
          let out, left = bootstrap ~stdin:script ~home zsh in
          Sh.reports "the primed zsh" out;
          Sh.check "nothing left behind" (left = 0);
          Sh.check "the pristine .zshrc ran" (String.mem ~sub:"remote%" out))
        (Sh.interactive_zsh ~path ());
      [%expect {| |}]

    (* The integration is eval'd after the remote's rc files; under SH_WORD_SPLIT an unquoted eval
   rejoins its lines with spaces. *)
    let%expect_test "the bootstrap primes a zsh that splits words" =
      Option.iter
        (fun zsh ->
          let out, _ = bootstrap ~stdin:script ~home:(Sh.zsh_home "setopt SH_WORD_SPLIT\n") zsh in
          Sh.check "primed under SH_WORD_SPLIT" (String.mem ~sub:"\027]133;C;cmdline=true" out))
        (Sh.interactive_zsh ~path ());
      [%expect {| |}]

    let%expect_test "the bootstrap hands a zsh its own ZDOTDIR back before .zshrc" =
      Option.iter
        (fun zsh ->
          let dots = Sh.zsh_home "" in
          let out, left =
            bootstrap ~stdin:script ~home:(Sh.temp ()) ~env:[ "ZDOTDIR=" ^ dots ] zsh
          in
          Sh.check "primed" (Sh.osc133 out);
          Sh.check "its own .zshrc ran" (String.mem ~sub:"remote%" out);
          Sh.check "nothing left behind" (left = 0))
        (Sh.interactive_zsh ~path ());
      [%expect {| |}]

    let%expect_test "the bootstrap primes a pristine bash" =
      Option.iter
        (fun bash ->
          let home = Sh.temp () in
          ignore (Sh.write ~perm:0o644 (home // ".bash_profile") "PS1='remote$ '\n");
          let control =
            Sh.output ~stdin:script ~env:(Sh.base ~path ~home bash) bash [ bash; "--login" ]
          in
          Sh.check "the pristine shell reports nothing without kido" (not (Sh.osc133 control));
          let out, left = bootstrap ~stdin:script ~home bash in
          Sh.reports "the primed bash" out;
          Sh.check "nothing left behind" (left = 0);
          Sh.check "the pristine .bash_profile ran" (String.mem ~sub:"remote$" out))
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
          Sh.check "profile and rc ran"
            (String.mem ~sub:"KIDO_BASH_PROFILE_RAN" out && String.mem ~sub:"KIDO_BASH_RC_RAN" out);
          Sh.check "nothing left behind" (left = 0);
          let home = Sh.temp () in
          ignore (Sh.write ~perm:0o644 (home // ".profile") "echo KIDO_DOT_PROFILE_RAN\n");
          let out, left = bootstrap ~stdin:script ~home bash in
          Sh.check ".profile ran" (String.mem ~sub:"KIDO_DOT_PROFILE_RAN" out);
          Sh.check "primed" (Sh.osc133 out);
          Sh.check "nothing left behind" (left = 0))
        (interactive_bash ());
      [%expect {| |}]

    (* Apple's 3.2 does not read $ENV under --posix at all, so the floor is checked in the bootstrap
   itself: an old bash gets its login files, no markers, and never posix mode. *)
    let%expect_test "the bootstrap leaves a bash too old for PS0 alone" =
      if Sys.file_exists "/bin/bash" && not (has_ps0 "/bin/bash") then begin
        let bash = Sh.write (Sh.temp () // "bash") "#!/bin/sh\nexec /bin/bash \"$@\" -i\n" in
        let home = Sh.temp () in
        ignore (Sh.write ~perm:0o644 (home // ".bash_profile") "echo KIDO_OLD_BASH_PROFILE_RAN\n");
        let out, left =
          bootstrap ~stdin:"shopt -qo posix; echo KIDO_POSIX_SET=$?\nexit\n" ~home bash
        in
        Sh.check "no markers" (not (Sh.osc133 out));
        Sh.check "the login files ran" (String.mem ~sub:"KIDO_OLD_BASH_PROFILE_RAN" out);
        Sh.check "not in posix mode" (String.mem ~sub:"KIDO_POSIX_SET=1" out);
        Sh.check "nothing left behind" (left = 0)
      end;
      [%expect {| |}]
  end)
