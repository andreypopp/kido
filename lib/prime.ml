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
    List.iter
      (fun (name, body) -> Fs.write ~perm:0o600 (Filename.concat dir name) body)
      (files ~bin_dir mode);
    env dir
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
           (fun name ->
             let p = Filename.concat dotdir name in
             Sys.file_exists p && not (Sys.is_directory p))
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
