use std::fs;
use std::io;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;

use ko_pane_wire::base64::encode as base64_encode;

use crate::bin_dir::path_prepend_script;

const ZSH_COMPLETION: &str = include_str!("../../share/ko/zsh/_ko");
const ZSH_INTEGRATION: &str = include_str!("../../share/ko/zsh/integration.zsh");
const BASH_INTEGRATION: &str = include_str!("../../share/ko/bash/integration.bash");

const ZSHENV: &str = r#"# Written by ko into a throwaway ZDOTDIR.
if [[ -n ${KO_ORIG_ZDOTDIR+X} ]]; then
  export ZDOTDIR=$KO_ORIG_ZDOTDIR
else
  unset ZDOTDIR
fi
unset KO_ORIG_ZDOTDIR
_ko_cleanup() {
  fpath=("${(@)fpath:#$_ko_dir}")
  command rm -rf -- "$_ko_dir"
  unset _ko_dir _ko_src
  zshexit_functions=("${(@)zshexit_functions:#_ko_cleanup}")
  unfunction _ko_cleanup
}
typeset -ag zshexit_functions
zshexit_functions+=(_ko_cleanup)
# Every expansion is quoted: /etc/zshenv runs before this file and may
# have set SH_WORD_SPLIT, under which an unquoted eval would rejoin the
# integration's lines with spaces.
{
  _ko_dir="${${(%):-%x}:A:h}"
  _ko_src="$(<"$_ko_dir/integration.zsh")"
  fpath=("$_ko_dir" "${(@)fpath:#$_ko_dir}")
  _ko_zshenv="${ZDOTDIR-$HOME}/.zshenv"
  [[ ! -r $_ko_zshenv ]] || source -- "$_ko_zshenv"
  unset _ko_zshenv
  fpath=("$_ko_dir" "${(@)fpath:#$_ko_dir}")
} always {
  if [[ -o interactive && -n $_ko_src ]]; then
    typeset -ag precmd_functions
    precmd_functions+=(_ko_ssh_init)
  else
    _ko_cleanup
  fi
}
_ko_ssh_init() {
  precmd_functions=(${precmd_functions:#_ko_ssh_init})
  local src="$_ko_src"
  {
    (( $+functions[_ko] )) || autoload -Uz _ko
    autoload +X _ko 2>/dev/null
    if (( $+functions[compdef] )) && [[ -z ${_comps[ko]-} ]]; then
      compdef _ko ko
    fi
  } always {
    _ko_cleanup
    unfunction _ko_ssh_init
  }
  eval "$src"
  (( $+functions[ko_osc133_precmd] )) && ko_osc133_precmd
}
"#;

const BASH_ENV: &str = r#"# Written by ko into a throwaway $ENV file.
# It removes itself; nothing ko writes here is meant to outlive the session.
unset ENV
set +o posix
# Resetting posix mode does not clear this on its own - kitty's bash
# integration carries the same comment, against the same bash behaviour.
shopt -u inherit_errexit 2>/dev/null
_ko_dir="${BASH_SOURCE%/*}"
[ ! -r /etc/profile ] || . /etc/profile
for _ko_f in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
  if [ -r "$_ko_f" ]; then . "$_ko_f"; break; fi
done
unset _ko_f
[ ! -f "$_ko_dir/integration.bash" ] || . "$_ko_dir/integration.bash"
rm -rf -- "$_ko_dir"
unset _ko_dir
"#;

const BASH_VERSION_PROBE: &str = r#"echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}""#;
const PS0_MAJOR: u32 = 4;
const PS0_MINOR: u32 = 4;

const BOOTSTRAP: &str = r#"ko_zsh_b64='@ZSH_B64@'
ko_bash_b64='@BASH_B64@'
ko_completion_b64='@COMPLETION_B64@'
ko_terminfo_b64='@TERMINFO_B64@'
ko_dir=''
ko_shell=${SHELL:-/bin/sh}
[ -x "$ko_shell" ] || ko_shell=/bin/sh
ko_name=${ko_shell##*/}
ko_plain() {
  [ -n "$ko_dir" ] && rm -rf "$ko_dir"
  "$ko_shell" @PLAIN_ARGS@ -c : >/dev/null 2>&1 && exec "$ko_shell" @PLAIN_ARGS@
  exec "$ko_shell"
}
ko_decode() {
  printf %s "$1" | base64 -d > "$2" 2>/dev/null ||
    printf %s "$1" | base64 -D > "$2" 2>/dev/null
}
ko_terminfo() {
  infocmp xterm-ghostty >/dev/null 2>&1 && return 0
  [ -n "$ko_terminfo_b64" ] || return 1
  for ko_form in x 78; do
    ko_target="$HOME/.terminfo/$ko_form/xterm-ghostty"
    [ ! -e "$ko_target" ] || continue
    mkdir -p "$HOME/.terminfo/$ko_form" 2>/dev/null || return 1
    ko_tmp=$(mktemp "$HOME/.terminfo/$ko_form/.ko.XXXXXXXX" 2>/dev/null) || return 1
    ko_decode "$ko_terminfo_b64" "$ko_tmp" &&
      chmod 644 "$ko_tmp" 2>/dev/null && mv -n "$ko_tmp" "$ko_target" 2>/dev/null
    rm -f "$ko_tmp"
  done
  if command -v infocmp >/dev/null 2>&1; then
    infocmp xterm-ghostty >/dev/null 2>&1
  else
    [ -s "$HOME/.terminfo/x/xterm-ghostty" ] && [ -s "$HOME/.terminfo/78/xterm-ghostty" ]
  fi
}
ko_terminfo || export TERM=xterm-256color
ko_bash_has_ps0() {
  ko_v=$("$ko_shell" -c '@PROBE@' 2>/dev/null)
  ko_maj=${ko_v%%.*}
  ko_min=${ko_v#*.}
  case "$ko_maj$ko_min" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$ko_maj" -gt @MAJOR@ ] || { [ "$ko_maj" -eq @MAJOR@ ] && [ "$ko_min" -ge @MINOR@ ]; }
}
case "$ko_name" in
  zsh) ;;
  # PS0 arrived in bash 4.4. An older bash is left alone here rather than
  # inside the $ENV file, which it may never read: it gets its own login
  # files and no markers, the "unprimed but not broken" outcome ko_plain
  # gives a remote with no zsh, no mktemp or no base64.
  bash) ko_bash_has_ps0 || ko_plain ;;
  *) ko_plain ;;
esac
command -v mktemp >/dev/null 2>&1 && command -v base64 >/dev/null 2>&1 || ko_plain
ko_dir=$(mktemp -d "${TMPDIR:-/tmp}/ko-ssh.XXXXXXXX" 2>/dev/null) && [ -d "$ko_dir" ] || ko_plain
trap 'rm -rf "$ko_dir"' EXIT HUP INT TERM
if [ "$ko_name" = zsh ]; then
  ko_decode "$ko_zsh_b64" "$ko_dir/integration.zsh" || ko_plain
  ko_decode "$ko_completion_b64" "$ko_dir/_ko" || ko_plain
  ko_zdotdir=${ZDOTDIR:-$HOME}
  [ -f "$ko_zdotdir/.zshrc" ] || [ -f "$ko_zdotdir/.zshenv" ] ||
    [ -f "$ko_zdotdir/.zprofile" ] || [ -f "$ko_zdotdir/.zlogin" ] || ko_plain
  cat > "$ko_dir/.zshenv" <<'KO_ZSHENV' || ko_plain
@ZSHENV@KO_ZSHENV
  [ -n "$ZDOTDIR" ] && export KO_ORIG_ZDOTDIR="$ZDOTDIR"
  export ZDOTDIR="$ko_dir"
  exec "$ko_shell" @ZSH_ARGS@
fi
# No dotfile guard here, unlike the zsh branch above: kitty's
# exec_bash_with_integration has none either, and the guard it does have
# in exec_zsh_with_integration is commented "dont prevent
# zsh-newuser-install from running". bash has no first-login installer to
# suppress, and a remote with no login files at all is one the $ENV file
# below sources nothing from, which is what bash would have done anyway.
ko_decode "$ko_bash_b64" "$ko_dir/integration.bash" || ko_plain
cat > "$ko_dir/env.bash" <<'KO_BASHENV' || ko_plain
@BASHENV@KO_BASHENV
export ENV="$ko_dir/env.bash"
exec "$ko_shell" @BASH_ARGS@
"#;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Mode {
    Plain,
    Zsh,
    Bash,
}

pub(crate) fn shell_args(mode: Mode) -> &'static [&'static str] {
    match mode {
        Mode::Bash => &["--login", "--posix"],
        Mode::Plain | Mode::Zsh => &["-l"],
    }
}

fn bash_has_ps0(output: &str) -> bool {
    let Some((major, minor)) = output.trim().split_once('.') else {
        return false;
    };
    match (major.parse::<u32>(), minor.parse::<u32>()) {
        (Ok(major), Ok(minor)) => major > PS0_MAJOR || (major == PS0_MAJOR && minor >= PS0_MINOR),
        _ => false,
    }
}

fn throwaway_dir() -> io::Result<PathBuf> {
    let base = std::env::temp_dir();
    loop {
        let suffix = ko_sys::entropy::hex(3)?;
        let dir = base.join(format!("ko-shell.{suffix}"));
        match fs::DirBuilder::new().mode(0o700).create(&dir) {
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
            created => return created.map(|()| dir),
        }
    }
}

fn write_private(path: &Path, body: &str) -> io::Result<()> {
    use std::io::Write;
    fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)?
        .write_all(body.as_bytes())
}

pub(crate) fn local(
    zdotdir: Option<&str>,
    bin_dir: Option<&Path>,
    mode: Mode,
) -> io::Result<Vec<(String, String)>> {
    let with_path = |integration: &str| {
        format!(
            "{integration}{}",
            bin_dir.map_or(String::new(), path_prepend_script)
        )
    };
    let files: Vec<(&str, String)> = match mode {
        Mode::Plain => return Ok(Vec::new()),
        Mode::Zsh => vec![
            (".zshenv", ZSHENV.to_owned()),
            ("_ko", ZSH_COMPLETION.to_owned()),
            ("integration.zsh", with_path(ZSH_INTEGRATION)),
        ],
        Mode::Bash => vec![
            ("env.bash", BASH_ENV.to_owned()),
            ("integration.bash", with_path(BASH_INTEGRATION)),
        ],
    };
    let dir = throwaway_dir()?;
    let written = files
        .iter()
        .try_for_each(|(name, body)| write_private(&dir.join(name), body));
    if let Err(error) = written {
        let _ = fs::remove_dir_all(&dir);
        return Err(error);
    }
    let dir = dir.to_string_lossy().into_owned();
    Ok(match mode {
        Mode::Zsh => [("ZDOTDIR".to_owned(), dir)]
            .into_iter()
            .chain(zdotdir.map(|old| ("KO_ORIG_ZDOTDIR".to_owned(), old.to_owned())))
            .collect(),
        Mode::Bash => vec![("ENV".to_owned(), format!("{dir}/env.bash"))],
        Mode::Plain => Vec::new(),
    })
}

pub(crate) fn local_mode(dotdir: &Path, path: &Path) -> Mode {
    match path.file_name().and_then(|name| name.to_str()) {
        Some("zsh")
            if [".zshrc", ".zshenv", ".zprofile", ".zlogin"]
                .iter()
                .any(|name| dotdir.join(name).is_file()) =>
        {
            Mode::Zsh
        }
        Some("bash")
            if Command::new(path)
                .args(["-c", BASH_VERSION_PROBE])
                .output()
                .is_ok_and(|probe| {
                    probe.status.success() && bash_has_ps0(&String::from_utf8_lossy(&probe.stdout))
                }) =>
        {
            Mode::Bash
        }
        _ => Mode::Plain,
    }
}

pub(crate) fn ssh_bootstrap(terminfo: Option<&[u8]>) -> String {
    let args = |mode| shell_args(mode).join(" ");
    BOOTSTRAP
        .replace(
            "@TERMINFO_B64@",
            &base64_encode(terminfo.unwrap_or_default()),
        )
        .replace("@ZSH_B64@", &base64_encode(ZSH_INTEGRATION.as_bytes()))
        .replace(
            "@COMPLETION_B64@",
            &base64_encode(ZSH_COMPLETION.as_bytes()),
        )
        .replace("@BASH_B64@", &base64_encode(BASH_INTEGRATION.as_bytes()))
        .replace("@PLAIN_ARGS@", &args(Mode::Plain))
        .replace("@PROBE@", BASH_VERSION_PROBE)
        .replace("@MAJOR@", &PS0_MAJOR.to_string())
        .replace("@MINOR@", &PS0_MINOR.to_string())
        .replace("@ZSHENV@", ZSHENV)
        .replace("@ZSH_ARGS@", &args(Mode::Zsh))
        .replace("@BASHENV@", BASH_ENV)
        .replace("@BASH_ARGS@", &args(Mode::Bash))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{run, scratch, write};

    fn field(name: &str, out: &str) -> String {
        out.lines()
            .find_map(|line| line.strip_prefix(&format!("{name}=")))
            .unwrap_or("<missing>")
            .to_owned()
    }

    fn fake_shell(name: &str) -> PathBuf {
        static SHELLS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let number = SHELLS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        write(
            &scratch(&format!("fake-{name}-{number}")).join(name),
            r#"#!/bin/sh
[ "$1" = "-c" ] && { echo 5.2; exit 0; }
[ "$2" = "-c" ] && exit 0
echo "args=$*"
echo "ZDOTDIR=${ZDOTDIR-<unset>}"
[ -n "$ZDOTDIR" ] && ls -a "$ZDOTDIR"
echo "ENV=${ENV-<unset>}"
[ -n "$ENV" ] && ls -a "$(dirname "$ENV")"
exit 0
"#,
            0o755,
        )
    }

    fn bootstrap(home: &Path, shell: &Path, env: &[(&str, &str)]) -> (String, usize) {
        static RUNS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let run_number = RUNS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let tmpdir = scratch(&format!("bootstrap-tmp-{run_number}"));
        let (home, shell, tmp) = (
            home.display().to_string(),
            shell.display().to_string(),
            tmpdir.display().to_string(),
        );
        let mut vars = vec![
            ("PATH", "/usr/bin:/bin"),
            ("HOME", home.as_str()),
            ("SHELL", shell.as_str()),
            ("TMPDIR", tmp.as_str()),
            ("TERM", "dumb"),
        ];
        vars.extend_from_slice(env);
        let out = run(
            Path::new("/bin/sh"),
            &["-c", &ssh_bootstrap(None)],
            "",
            &vars,
        );
        (out, fs::read_dir(&tmpdir).unwrap().count())
    }

    fn zsh_home(name: &str) -> PathBuf {
        let home = scratch(name);
        write(&home.join(".zshrc"), "\n", 0o644);
        home
    }

    fn holds(out: &str, file: &str) -> bool {
        out.contains(&format!("\n{file}\n"))
    }

    #[test]
    fn the_bootstrap_installs_terminfo_without_infocmp_and_preserves_existing_entries() {
        use std::os::unix::fs::{PermissionsExt, symlink};

        let bin = scratch("terminfo-tools");
        for name in ["base64", "mkdir", "mktemp", "mv", "rm", "chmod"] {
            let command = ["/usr/bin", "/bin"]
                .into_iter()
                .map(|dir| Path::new(dir).join(name))
                .find(|path| path.is_file())
                .unwrap();
            symlink(command, bin.join(name)).unwrap();
        }
        let shell = write(
            &bin.join("shell"),
            "#!/bin/sh\nprintf 'TERM=%s\\n' \"$TERM\"\n",
            0o755,
        );
        let payload = b"compiled terminfo";
        for case in ["missing", "existing", "empty"] {
            let home = scratch(&format!("terminfo-{case}"));
            if case != "missing" {
                for form in ["x", "78"] {
                    write(
                        &home.join(".terminfo").join(form).join("xterm-ghostty"),
                        if case == "existing" {
                            "keep these bytes"
                        } else {
                            ""
                        },
                        0o644,
                    );
                }
            }
            if case == "empty" {
                write(&bin.join("infocmp"), "#!/bin/sh\nexit 1\n", 0o755);
            }
            let out = run(
                Path::new("/bin/sh"),
                &["-c", &ssh_bootstrap(Some(payload))],
                "",
                &[
                    ("HOME", home.to_str().unwrap()),
                    ("PATH", bin.to_str().unwrap()),
                    ("SHELL", shell.to_str().unwrap()),
                    ("TERM", "xterm-ghostty"),
                ],
            );
            assert_eq!(
                field("TERM", &out),
                if case == "empty" {
                    "xterm-256color"
                } else {
                    "xterm-ghostty"
                }
            );
            for form in ["x", "78"] {
                let target = home.join(".terminfo").join(form).join("xterm-ghostty");
                assert_eq!(
                    fs::read(&target).unwrap(),
                    match case {
                        "missing" => payload.as_slice(),
                        "existing" => b"keep these bytes",
                        _ => b"",
                    }
                );
                assert_eq!(
                    fs::metadata(target).unwrap().permissions().mode() & 0o777,
                    0o644
                );
            }
        }
    }

    #[test]
    fn only_a_local_prime_moves_path() {
        let bin = Path::new("/k/bin");
        let bodies = |bin_dir: Option<&Path>, mode| {
            let env = local(None, bin_dir, mode).unwrap();
            let (_, set) = env.first().unwrap();
            let dir = if mode == Mode::Bash {
                Path::new(set).parent().unwrap()
            } else {
                Path::new(set)
            };
            let all: String = fs::read_dir(dir)
                .unwrap()
                .map(|entry| fs::read_to_string(entry.unwrap().path()).unwrap())
                .collect();
            let _ = fs::remove_dir_all(dir);
            all
        };
        for mode in [Mode::Zsh, Mode::Bash] {
            assert!(
                bodies(Some(bin), mode).contains(&path_prepend_script(bin)),
                "{mode:?}"
            );
            assert!(!bodies(None, mode).contains("_ko_bin"), "{mode:?}");
        }
        for text in [
            ssh_bootstrap(None),
            ZSH_INTEGRATION.to_owned(),
            BASH_INTEGRATION.to_owned(),
        ] {
            assert!(!text.contains("_ko_bin"));
        }
    }

    #[test]
    fn bash_must_answer_4_4_or_newer() {
        let cases = [
            ("5.2\n", true),
            ("4.4\n", true),
            ("4.4", true),
            ("10.0\n", true),
            ("4.3\n", false),
            ("3.2\n", false),
            ("\n", false),
            (".\n", false),
            ("x.y\n", false),
            ("", false),
        ];
        for (output, expected) in cases {
            assert_eq!(bash_has_ps0(output), expected, "{output:?}");
        }
    }

    #[test]
    fn local_mode_unknown_shells_are_plain_zsh_needs_dotfiles_bash_is_asked_its_version() {
        let home = scratch("mode-home");
        for shell in ["/bin/sh", "/usr/bin/fish", "/bin/ksh"] {
            assert_eq!(local_mode(&home, Path::new(shell)), Mode::Plain);
        }
        let zsh = write(&scratch("mode-zsh").join("zsh"), "#!/bin/sh\n", 0o755);
        assert_eq!(local_mode(&home, &zsh), Mode::Plain);
        write(&home.join(".zshrc"), "\n", 0o644);
        assert_eq!(local_mode(&home, &zsh), Mode::Zsh);
        for (version, mode) in [
            ("5.2\\n", Mode::Bash),
            ("4.3\\n", Mode::Plain),
            ("3.2\\n", Mode::Plain),
            ("x.y\\n", Mode::Plain),
            ("", Mode::Plain),
        ] {
            let bash = write(
                &scratch("mode-bash").join("bash"),
                &format!("#!/bin/sh\nprintf '{version}'\n"),
                0o755,
            );
            assert_eq!(local_mode(&home, &bash), mode, "{version:?}");
        }
    }

    #[test]
    fn local_priming_writes_a_throwaway_directory_named_by_the_one_variable_the_shell_reads() {
        let listing = |dir: &Path| {
            let mut names: Vec<String> = fs::read_dir(dir)
                .unwrap()
                .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
                .collect();
            names.sort();
            let _ = fs::remove_dir_all(dir);
            names.join(" ")
        };
        let zsh = local(None, None, Mode::Zsh).unwrap();
        assert_eq!(zsh.len(), 1);
        assert_eq!(zsh[0].0, "ZDOTDIR");
        assert!(zsh[0].1.contains("/ko-shell."));
        assert_eq!(listing(Path::new(&zsh[0].1)), ".zshenv _ko integration.zsh");
        let zsh = local(Some("/home/me/dots"), None, Mode::Zsh).unwrap();
        assert_eq!(
            zsh[1],
            ("KO_ORIG_ZDOTDIR".to_owned(), "/home/me/dots".to_owned())
        );
        listing(Path::new(&zsh[0].1));
        let bash = local(None, None, Mode::Bash).unwrap();
        assert_eq!(bash[0].0, "ENV");
        let env = Path::new(&bash[0].1);
        assert_eq!(env.file_name().unwrap(), "env.bash");
        assert_eq!(listing(env.parent().unwrap()), "env.bash integration.bash");
        assert!(local(None, None, Mode::Plain).unwrap().is_empty());
    }

    #[test]
    fn the_bootstrap_parses_under_sh_and_carries_each_integration_as_single_quoted_base64() {
        assert_eq!(
            run(Path::new("/bin/sh"), &["-n"], &ssh_bootstrap(None), &[]),
            ""
        );
        let bootstrap = ssh_bootstrap(None);
        let parts: Vec<&str> = bootstrap.split('\'').collect();
        for (payload, source) in [(parts[1], ZSH_INTEGRATION), (parts[3], BASH_INTEGRATION)] {
            let decoded = run(Path::new("/usr/bin/base64"), &["-d"], payload, &[]);
            assert_eq!(decoded, source);
            assert!(source.contains("ko_osc133_preexec"));
        }
    }

    #[test]
    fn the_bootstrap_primes_bash_and_zsh_through_a_throwaway_directory() {
        let (out, left) = bootstrap(&scratch("boot-home"), &fake_shell("bash"), &[]);
        assert_eq!(field("args", &out), "--login --posix");
        assert_eq!(field("ZDOTDIR", &out), "<unset>");
        assert_ne!(field("ENV", &out), "<unset>");
        assert!(holds(&out, "env.bash") && holds(&out, "integration.bash"));
        assert_eq!(left, 1);
        let home = zsh_home("boot-zsh-home");
        let (out, left) = bootstrap(&home, &fake_shell("zsh"), &[]);
        assert_eq!(field("args", &out), "-l");
        assert_eq!(field("ENV", &out), "<unset>");
        assert!(holds(&out, ".zshenv") && holds(&out, "integration.zsh"));
        assert_ne!(field("ZDOTDIR", &out), home.display().to_string());
        assert_eq!(left, 1);
    }

    #[test]
    fn the_bootstrap_redirects_an_existing_zdotdir_keeping_it_to_restore() {
        let dots = zsh_home("boot-dots");
        let dots_text = dots.display().to_string();
        let (out, _) = bootstrap(
            &scratch("boot-home-2"),
            &fake_shell("zsh"),
            &[("ZDOTDIR", dots_text.as_str())],
        );
        let redirected = field("ZDOTDIR", &out);
        assert!(redirected != dots_text && redirected != "<unset>", "{out}");
    }

    #[test]
    fn the_bootstrap_falls_back_to_a_plain_shell_and_leaves_nothing_behind() {
        let cases = [
            ("ksh", zsh_home("boot-ksh-home")),
            ("zsh with no dotfiles", scratch("boot-no-dots")),
        ];
        for (what, home) in cases {
            let shell = fake_shell(if what == "ksh" { "ksh" } else { "zsh" });
            let (out, left) = bootstrap(&home, &shell, &[]);
            assert_eq!(
                (field("ZDOTDIR", &out).as_str(), left),
                ("<unset>", 0),
                "{what}"
            );
        }
    }
}
