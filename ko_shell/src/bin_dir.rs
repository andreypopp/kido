use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

use ko_server::config::{TERM_NAME, installed, is_executable, terminfo_of};

fn is_file(path: &Path) -> bool {
    fs::metadata(path).is_ok_and(|meta| meta.is_file())
}

fn same_file(a: &Path, b: &Path) -> bool {
    match (fs::metadata(a), fs::metadata(b)) {
        (Ok(a), Ok(b)) => a.dev() == b.dev() && a.ino() == b.ino(),
        _ => false,
    }
}

pub fn of_exe(exe: &Path) -> Option<PathBuf> {
    installed(exe, "share/ko/bin")
        .into_iter()
        .find(|dir| is_file(&dir.join("ko")))
        .filter(|dir| !dir.as_os_str().as_encoded_bytes().contains(&b':'))
}

pub fn terminfo_entry(exe: &Path) -> Option<Vec<u8>> {
    fs::read(terminfo_of(exe)?.join("x").join(TERM_NAME))
        .ok()
        .filter(|bytes| !bytes.is_empty())
}

pub fn look_path_past(path: &str, dir: &Path, name: &str) -> Option<PathBuf> {
    let shim = dir.join(name);
    let entries: Vec<&Path> = path
        .split(':')
        .map(|entry| Path::new(if entry.is_empty() { "." } else { entry }))
        .collect();
    let search = match entries.iter().position(|entry| same_file(entry, dir)) {
        Some(at) => entries.get(at + 1..).unwrap_or_default(),
        None => &entries,
    };
    search
        .iter()
        .filter(|entry| !same_file(entry, dir))
        .map(|entry| entry.join(name))
        .find(|candidate| is_executable(candidate) && !same_file(candidate, &shim))
}

pub(crate) fn path_prepend_script(dir: &Path) -> String {
    format!(
        r#"
# Written by ko shell: its bin directory goes first on PATH, after the
# login files that may have rewritten PATH, and only once.
_ko_bin={}
_ko_rest=":$PATH:"
while :; do
  case $_ko_rest in
  *":$_ko_bin:"*) _ko_rest="${{_ko_rest%%":$_ko_bin:"*}}:${{_ko_rest#*":$_ko_bin:"}}" ;;
  *) break ;;
  esac
done
_ko_rest=${{_ko_rest#:}}
_ko_rest=${{_ko_rest%:}}
PATH="$_ko_bin${{_ko_rest:+:$_ko_rest}}"
export PATH
unset _ko_bin _ko_rest
"#,
        ko_server::ssh::quote(&dir.to_string_lossy())
    )
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::symlink;

    use super::*;
    use crate::test_support::{run, scratch, write};

    #[test]
    fn share_ko_bin_beside_bin_ko_directly_through_a_symlink_or_nothing() {
        let prefix = scratch("of-exe-prefix");
        write(&prefix.join("share/ko/bin/ko"), "#!/bin/sh\n", 0o755);
        let exe = write(&prefix.join("bin/ko"), "", 0o755);
        let other = scratch("of-exe-link");
        let link = other.join("ko");
        symlink(&exe, &link).unwrap();
        assert_eq!(of_exe(&exe), Some(prefix.join("share/ko/bin")));
        assert_eq!(
            of_exe(&link),
            Some(fs::canonicalize(prefix.join("share/ko/bin")).unwrap())
        );
        assert_eq!(of_exe(&scratch("of-exe-empty").join("bin/ko")), None);
    }

    #[test]
    fn the_unresolved_version_stable_spelling_wins_over_the_cellar_path() {
        let root = scratch("of-exe-cellar");
        let versioned = root.join("Cellar/ko/1.0.0");
        let real = write(&versioned.join("bin/ko"), "#!/bin/sh\n", 0o755);
        write(&versioned.join("share/ko/bin/ko"), "#!/bin/sh\n", 0o755);
        fs::create_dir_all(root.join("bin")).unwrap();
        fs::create_dir_all(root.join("share")).unwrap();
        symlink(real, root.join("bin/ko")).unwrap();
        symlink(versioned.join("share/ko"), root.join("share/ko")).unwrap();
        assert_eq!(
            of_exe(&root.join("bin/ko")),
            Some(root.join("share/ko/bin"))
        );
    }

    fn install(root: &Path) -> PathBuf {
        let shims = root.join("my prefix/share/ko/bin");
        write(&shims.join("ssh"), "#!/bin/sh\n", 0o755);
        write(&shims.join("ko"), "#!/bin/sh\n", 0o755);
        shims
    }

    #[test]
    fn look_path_past_skips_the_shim_directory_and_the_shim_itself() {
        let root = scratch("past");
        let shims = install(&root);
        let other = install(&root.join("other"));
        let before = write(&root.join("before/ssh"), "#!/bin/sh\n", 0o755);
        let after = write(&root.join("after/ssh"), "#!/bin/sh\n", 0o755);
        let dir = |path: &Path| path.parent().unwrap().display().to_string();
        let path = |dirs: &[String]| dirs.join(":");
        let found = |path: String| look_path_past(&path, &shims, "ssh");
        assert_eq!(
            found(path(&[
                dir(&before),
                shims.display().to_string(),
                dir(&after)
            ])),
            Some(after.clone())
        );
        assert_eq!(
            found(path(&[
                shims.display().to_string(),
                other.display().to_string(),
                dir(&after)
            ])),
            Some(other.join("ssh"))
        );
        assert_eq!(found(path(&[dir(&before)])), Some(before));
        assert_eq!(
            found(path(&[format!("{}/", shims.display()), dir(&after)])),
            Some(after)
        );
        assert_eq!(found(shims.display().to_string()), None);
    }

    #[test]
    fn the_prepend_script_moves_the_directory_first_once_in_sh_bash_and_zsh() {
        let dir = Path::new("/opt/it's a [ko]*/bin");
        let script = format!(
            "{}{}printf '%s' \"$PATH\"",
            path_prepend_script(dir),
            path_prepend_script(dir)
        );
        for shell in ["/bin/sh", "/bin/bash", "/bin/zsh", "/usr/bin/zsh"] {
            if !Path::new(shell).exists() {
                continue;
            }
            let out = run(
                Path::new(shell),
                &["-c", &script],
                "",
                &[("PATH", "/usr/bin:/opt/it's a [ko]*/bin:/bin")],
            );
            assert_eq!(out, "/opt/it's a [ko]*/bin:/usr/bin:/bin", "{shell}");
        }
    }
}
