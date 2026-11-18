use std::fs::{self, DirBuilder, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::AsFd;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use ko_config::ssh_args::{connection_args, parse};
use ko_pane_wire::base64::encode as base64_encode;
use ko_sys::pid::{Exit, Waited};
use ko_sys::spawn::{self, Env};
use ko_wire::api::DropName;
use ko_wire::protocol::Dropped;
use ko_wire::ssh::quote;

use crate::prime::base64_decode;

const MAX_BYTES: u64 = 2 << 30;
const MAX_AGE: Duration = Duration::from_secs(7 * 24 * 60 * 60);
const PARTIAL_AGE: Duration = Duration::from_secs(10 * 60);
const REMOTE: &str = r#"refuse() { printf 'ko drop: %s\n' "$1" >&2; exit 1; }
drop_id=$1 name=$2 size=$3
case $drop_id in *[!0-9a-f]*) refuse "invalid drop id" ;; esac
[ ${#drop_id} -eq 32 ] || refuse "invalid drop id"
case $name in ''|.*|*/*|*[[:cntrl:]]*) refuse "invalid drop name" ;; esac
[ $(($(printf %s "$name" | wc -c))) -le @NAME_BYTES@ ] || refuse "invalid drop name"
case $size in ''|*[!0-9]*) refuse "invalid size" ;; esac
[ -n "${XDG_STATE_HOME:-$HOME}" ] || refuse "base needs XDG_STATE_HOME or HOME"
base=${XDG_STATE_HOME:-$HOME/.local/state}/ko
case $base in /*) ;; *) refuse "base must be absolute" ;; esac
drops=$base/drops
umask 077
mkdir -p "$drops" || refuse "cannot create $drops"
case $(uname -s) in
  Darwin|*BSD) mode=$(stat -f '%u:%Lp' "$drops") ;;
  *) mode=$(stat -c '%u:%a' "$drops") ;;
esac
[ -d "$drops" ] && [ ! -L "$drops" ] && [ "$mode" = "$(id -u):700" ] || refuse "$drops is not a private directory"
h=[0-9a-f]; h=$h$h; h=$h$h; h=$h$h; h=$h$h; h=$h$h
sweep() {
  find "$drops" -mindepth 2 -maxdepth 2 -path "$drops/$1/*" -mmin +"$2" | while IFS= read -r file; do rm -rf "${file%/*}"; done
}
sweep "$h" @MAX_AGE_MINUTES@
sweep ".$h" @PARTIAL_AGE_MINUTES@
find "$drops" -mindepth 1 -maxdepth 1 -type d -name ".$h" -empty -mmin +@PARTIAL_AGE_MINUTES@ -exec rm -rf {} +
kept=$(find "$drops" -mindepth 1 -maxdepth 1 -type d \( -name "$h" -o -name ".$h" \) -exec du -sk {} + | awk '{ kept += $1 } END { print kept + 0 }')
[ $((kept + (size + 1023) / 1024)) -le @MAX_KIB@ ] || refuse "drops exceed 2 GiB"
stage=$drops/.$drop_id
trap 'rm -rf "$stage"' EXIT
trap 'exit 1' HUP INT TERM PIPE
mkdir "$stage" || refuse "cannot create $stage"
cat > "$stage/$name" || refuse "cannot write $name"
got=$(($(wc -c < "$stage/$name")))
[ "$got" -eq "$size" ] || refuse "input is $got bytes, not $size"
[ ! -e "$drops/$drop_id" ] && mv "$stage" "$drops/$drop_id" || refuse "cannot publish $drop_id"
trap - EXIT
printf '%s\n' "$drops/$drop_id/$name"
"#;

fn remote_script() -> String {
    REMOTE
        .replace("@NAME_BYTES@", &DropName::MAX_BYTES.to_string())
        .replace("@MAX_AGE_MINUTES@", &(MAX_AGE.as_secs() / 60).to_string())
        .replace(
            "@PARTIAL_AGE_MINUTES@",
            &(PARTIAL_AGE.as_secs() / 60).to_string(),
        )
        .replace("@MAX_KIB@", &(MAX_BYTES / 1024).to_string())
}

fn remote_command(id: &str, name: &DropName, size: u64) -> String {
    let words = [id, name.as_str(), &size.to_string()].map(quote);
    let payload = format!("set -- {}\n{}", words.join(" "), remote_script());
    let run = format!(
        "eval \"$({})\"",
        base64_decode(&base64_encode(payload.as_bytes()))
    );
    format!("exec /bin/sh -c {}", quote(&run))
}

fn ssh_argv(args: &[String], command: String) -> io::Result<Vec<String>> {
    let (destination, options) = parse(args)
        .filter(|parsed| {
            parsed.command.is_empty() && connection_args(parsed).as_deref() == Some(args)
        })
        .and(args.split_last())
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "the ssh arguments are not a connection",
            )
        })?;
    Ok([
        "BatchMode=yes",
        "ClearAllForwardings=yes",
        "ForwardAgent=no",
        "RemoteCommand=none",
        "RequestTTY=no",
        "PermitLocalCommand=no",
        "ControlMaster=no",
        "ConnectTimeout=15",
        "ServerAliveInterval=15",
        "ServerAliveCountMax=3",
    ]
    .into_iter()
    .flat_map(|option| ["-o".to_owned(), option.to_owned()])
    .chain(["-T".to_owned()])
    .chain(options.iter().cloned())
    .chain(["--".to_owned(), destination.clone(), command])
    .collect())
}

pub fn forward(args: &[String], name: &DropName, size: u64) -> io::Result<Dropped> {
    let id = ko_sys::entropy::hex(16)?;
    let argv = ssh_argv(args, remote_command(&id, name, size))?;
    let argv: Vec<&str> = argv.iter().map(String::as_str).collect();
    let (mut output, sink) = io::pipe()?;
    let pid = spawn::program(
        Path::new("/usr/bin/ssh"),
        &argv,
        &[
            (io::stdin().as_fd(), 0),
            (sink.as_fd(), 1),
            (io::stderr().as_fd(), 2),
        ],
        Env::Inherit,
        None,
    )?;
    drop(sink);
    let mut reply = Vec::new();
    let read = (&mut output).take(16 << 10).read_to_end(&mut reply);
    drop(output);
    let waited = pid.wait()?;
    read?;
    match waited {
        Waited::Ended(Exit::Exited(0)) => {}
        Waited::Ended(Exit::Exited(status)) => {
            return Err(io::Error::other(format!("ssh exited {status}")));
        }
        Waited::Ended(Exit::Signaled(signal)) => {
            return Err(io::Error::other(format!("ssh ended by signal {signal}")));
        }
        Waited::Running | Waited::NoChild => {
            return Err(io::Error::other("ssh was not waited for"));
        }
    }
    let suffix = format!("/drops/{id}/{}", name.as_str());
    String::from_utf8(reply)
        .ok()
        .and_then(|reply| reply.strip_suffix('\n').map(str::to_owned))
        .filter(|path| path.starts_with('/') && path.ends_with(&suffix))
        .and_then(|path| path.try_into().ok())
        .map(|path| Dropped { path })
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "the target sent no drop path"))
}

#[derive(Debug)]
struct Partial(PathBuf);

impl Drop for Partial {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn sweep(root: &Path, now: SystemTime, mut before: impl FnMut(&Path)) -> io::Result<u64> {
    let entries = match fs::read_dir(root) {
        Ok(entries) => entries,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(0),
        Err(error) => return Err(error),
    };
    let mut kept = 0u64;
    for entry in entries {
        let scanned = (|| -> io::Result<u64> {
            let entry = entry?;
            let name = entry.file_name();
            let Some(name) = name.to_str() else {
                return Ok(0);
            };
            let (id, partial) = name
                .strip_prefix('.')
                .map_or((name, false), |id| (id, true));
            if id.len() != 32
                || !id
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
                || !entry.file_type()?.is_dir()
            {
                return Ok(0);
            }
            before(&entry.path());
            let mut files = fs::read_dir(entry.path())?;
            let file = files.next().transpose()?;
            if files.next().transpose()?.is_some() {
                return Ok(0);
            }
            let metadata = match file {
                Some(file) => {
                    let metadata = fs::symlink_metadata(file.path())?;
                    if !metadata.is_file() {
                        return Ok(0);
                    }
                    metadata
                }
                None if partial => entry.metadata()?,
                None => return Ok(0),
            };
            let age = now.duration_since(metadata.modified()?).unwrap_or_default();
            if age > if partial { PARTIAL_AGE } else { MAX_AGE } {
                fs::remove_dir_all(entry.path())?;
                Ok(0)
            } else {
                Ok(if metadata.is_file() {
                    metadata.len()
                } else {
                    0
                })
            }
        })();
        match scanned {
            Ok(bytes) => kept = kept.checked_add(bytes).ok_or(io::ErrorKind::InvalidData)?,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
    }
    Ok(kept)
}

pub fn receive(
    base: &Path,
    name: DropName,
    size: u64,
    mut read: impl FnMut(&mut [u8]) -> io::Result<usize>,
) -> io::Result<Dropped> {
    if !base.is_absolute() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "base must be absolute",
        ));
    }
    let root = base.join("drops");
    DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&root)?;
    if !fs::symlink_metadata(&root)?.is_dir() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "drops is not a directory",
        ));
    }
    let kept = sweep(&root, SystemTime::now(), |_| {})?;
    if kept.checked_add(size).is_none_or(|total| total > MAX_BYTES) {
        return Err(io::Error::new(
            io::ErrorKind::StorageFull,
            "drops exceed 2 GiB",
        ));
    }
    let id = ko_sys::entropy::hex(16)?;
    let partial = Partial(root.join(format!(".{id}")));
    DirBuilder::new().mode(0o700).create(&partial.0)?;
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(partial.0.join(name.as_str()))?;
    let mut remaining = size;
    let mut buffer = [0u8; 65536];
    while remaining > 0 {
        let wanted = usize::try_from(remaining)
            .unwrap_or(usize::MAX)
            .min(buffer.len());
        let count = read(
            buffer
                .get_mut(..wanted)
                .ok_or(io::ErrorKind::InvalidInput)?,
        )?;
        if count == 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "input is shorter than size",
            ));
        }
        file.write_all(buffer.get(..count).ok_or(io::ErrorKind::InvalidData)?)?;
        remaining = remaining
            .checked_sub(count as u64)
            .ok_or(io::ErrorKind::InvalidData)?;
    }
    if read(&mut buffer[..1])? != 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "input is longer than size",
        ));
    }
    let complete = root.join(id);
    let path = complete
        .join(name.as_str())
        .to_str()
        .ok_or(io::ErrorKind::InvalidData)?
        .to_owned()
        .try_into()
        .map_err(|_| io::Error::from(io::ErrorKind::InvalidData))?;
    fs::rename(&partial.0, complete)?;
    Ok(Dropped { path })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;
    use std::os::unix::fs::{PermissionsExt, symlink};

    use crate::test_support::{run, scratch};

    #[test]
    fn the_remote_command_publishes_under_the_state_home_and_sweeps_by_file_age() {
        let name = DropName::try_from("plain.txt".to_owned()).unwrap();
        let home = scratch("remote-home");
        let xdg = home.join("xdg");
        for (env, root) in [
            (vec![], home.join(".local/state/ko/drops")),
            (
                vec![("XDG_STATE_HOME", xdg.to_str().unwrap())],
                xdg.join("ko/drops"),
            ),
        ] {
            let env: Vec<(&str, &str)> =
                [("HOME", home.to_str().unwrap()), ("PATH", "/usr/bin:/bin")]
                    .into_iter()
                    .chain(env)
                    .collect();
            let stale = SystemTime::now() - PARTIAL_AGE - Duration::from_secs(60);
            let old = SystemTime::now() - MAX_AGE - Duration::from_secs(60);
            let seeded = [
                (".0123456789abcdef0123456789abcdef", stale, false),
                (".1123456789abcdef0123456789abcdef", SystemTime::now(), true),
                ("2123456789abcdef0123456789abcdef", old, false),
                ("3123456789abcdef0123456789abcdef", stale, true),
            ];
            for (id, modified, _) in seeded {
                fs::create_dir_all(root.join(id)).unwrap();
                fs::File::create(root.join(id).join("f"))
                    .unwrap()
                    .set_modified(modified)
                    .unwrap();
            }
            fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
            let id = ko_sys::entropy::hex(16).unwrap();
            let out = run(
                Path::new("/bin/sh"),
                &["-c", &remote_command(&id, &name, 5)],
                "hello",
                &env,
            );
            let expected = root.join(&id).join(name.as_str());
            assert_eq!(out, format!("{}\n", expected.display()));
            assert_eq!(fs::read(&expected).unwrap(), b"hello");
            for (seed, _, kept) in seeded {
                assert_eq!(root.join(seed).exists(), kept, "{seed}");
            }
        }
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn a_hostile_name_reaches_the_target_through_each_login_shell() {
        let name = DropName::try_from(r#"it's a \ "file" $x.txt"#.to_owned()).unwrap();
        let shells = [
            "/bin/bash",
            "/bin/zsh",
            "/bin/tcsh",
            "/usr/bin/fish",
            "/opt/homebrew/bin/fish",
        ];
        for (index, shell) in shells
            .iter()
            .map(Path::new)
            .filter(|shell| shell.exists())
            .enumerate()
        {
            let home = scratch(&format!("remote-shell-{index}"));
            let id = ko_sys::entropy::hex(16).unwrap();
            let command = remote_command(&id, &name, 2);
            assert!(!command.contains('\n'));
            let out = run(
                shell,
                &["-c", &command],
                "ok",
                &[("HOME", home.to_str().unwrap()), ("PATH", "/usr/bin:/bin")],
            );
            let expected = home
                .join(".local/state/ko/drops")
                .join(&id)
                .join(name.as_str());
            assert_eq!(out, format!("{}\n", expected.display()), "{shell:?}");
            assert_eq!(fs::read(&expected).unwrap(), b"ok");
            fs::remove_dir_all(home).unwrap();
        }
    }

    #[test]
    fn the_remote_script_refuses_bad_names_and_sizes_and_leaves_no_partial() {
        let long = "n".repeat(DropName::MAX_BYTES + 1);
        let home = scratch("remote-refusals");
        let env = [("HOME", home.to_str().unwrap()), ("PATH", "/usr/bin:/bin")];
        let id = "0123456789abcdef0123456789abcdef";
        let script = remote_script();
        let run_script = |args: &[&str], stdin: &str| {
            let mut argv = vec!["-c", script.as_str(), "ko-drop"];
            argv.extend(args);
            run(Path::new("/bin/sh"), &argv, stdin, &env)
        };
        for name in [
            "",
            ".hidden",
            "..",
            "a/b",
            "a\nb",
            "a\u{7f}b",
            long.as_str(),
        ] {
            assert_eq!(
                run_script(&[id, name, "1"], "x"),
                "ko drop: invalid drop name\n",
                "{name:?}"
            );
        }
        assert_eq!(
            run_script(&["../0123456789abcdef0123456789ab", "f", "1"], "x"),
            "ko drop: invalid drop id\n"
        );
        assert_eq!(run_script(&[id, "f", "1x"], "x"), "ko drop: invalid size\n");
        for (size, stdin) in [("2", "abc"), ("4", "abc")] {
            assert_eq!(
                run_script(&[id, "f", size], stdin),
                format!("ko drop: input is 3 bytes, not {size}\n"),
            );
        }
        let drops = home.join(".local/state/ko/drops");
        assert_eq!(fs::read_dir(&drops).unwrap().count(), 0);
        fs::set_permissions(&drops, fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(
            run_script(&[id, "f", "1"], "x"),
            format!("ko drop: {} is not a private directory\n", drops.display())
        );
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn the_ssh_command_puts_its_options_first_and_takes_only_a_connection() {
        let args = ["-F", "/c", "-l", "u", "host"].map(str::to_owned);
        let argv = ssh_argv(&args, "run".to_owned()).unwrap();
        assert_eq!(argv.first().map(String::as_str), Some("-o"));
        assert_eq!(
            argv[argv.len() - 8..],
            ["-T", "-F", "/c", "-l", "u", "--", "host", "run"].map(str::to_owned)
        );
        assert!(argv.windows(2).any(|pair| pair == ["-o", "BatchMode=yes"]));
        for refused in [
            &["-N", "host"][..],
            &["host", "uptime"],
            &["-oBatchMode=no", "host"],
            &[],
        ] {
            let refused: Vec<String> = refused.iter().map(|&arg| arg.to_owned()).collect();
            assert!(ssh_argv(&refused, "run".to_owned()).is_err(), "{refused:?}");
        }
    }

    #[test]
    fn concurrent_sweep_tolerates_an_entry_removed_after_listing() {
        let base =
            std::env::temp_dir().join(format!("ko-drop-race-{}", ko_sys::entropy::hex(8).unwrap()));
        fs::create_dir_all(base.join(".0123456789abcdef0123456789abcdef")).unwrap();
        assert_eq!(
            sweep(&base, SystemTime::now(), |path| fs::remove_dir_all(path)
                .unwrap())
            .unwrap(),
            0
        );
        fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn foreign_entries_do_not_block_or_change_during_an_upload() {
        let base = std::env::temp_dir().join(format!(
            "ko-drop-foreign-{}",
            ko_sys::entropy::hex(8).unwrap()
        ));
        let root = base.join("drops");
        fs::create_dir_all(root.join("odd")).unwrap();
        fs::write(root.join("unrelated"), b"keep").unwrap();
        symlink("/dev/null", root.join("link")).unwrap();
        let name = DropName::try_from("file".to_owned()).unwrap();
        let result = receive(&base, name, 0, |_| Ok(0)).unwrap();
        assert!(Path::new(result.path.as_str()).exists());
        assert_eq!(fs::read(root.join("unrelated")).unwrap(), b"keep");
        assert!(
            fs::symlink_metadata(root.join("link"))
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert!(root.join("odd").is_dir());
        fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn drops_require_exact_input_and_private_regular_files_and_enforce_quota() {
        let base =
            std::env::temp_dir().join(format!("ko-drop-{}", ko_sys::entropy::hex(8).unwrap()));
        let name = || DropName::try_from("file".to_owned()).unwrap();
        for (size, bytes) in [(3, b"ab".as_slice()), (1, b"ab".as_slice())] {
            let mut reader = Cursor::new(bytes);
            let failure = receive(&base, name(), size, |buffer| reader.read(buffer)).unwrap_err();
            assert_eq!(
                failure.kind(),
                if size == 3 {
                    io::ErrorKind::UnexpectedEof
                } else {
                    io::ErrorKind::InvalidData
                }
            );
            assert_eq!(fs::read_dir(base.join("drops")).unwrap().count(), 0);
        }
        for bytes in [b"".as_slice(), b"abcdef".as_slice()] {
            let mut reader = Cursor::new(bytes);
            let result = receive(&base, name(), bytes.len() as u64, |buffer| {
                reader.read(buffer)
            })
            .unwrap();
            let path = Path::new(result.path.as_str());
            assert_eq!(fs::read(path).unwrap(), bytes);
            assert_eq!(
                fs::metadata(path).unwrap().permissions().mode() & 0o777,
                0o600
            );
            assert_eq!(
                fs::metadata(path.parent().unwrap())
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o700
            );
        }
        assert!(receive(&base, name(), MAX_BYTES - 5, |_| Ok(0)).is_err());
        let stale = base.join("drops/.0123456789abcdef0123456789abcdef");
        fs::create_dir(&stale).unwrap();
        fs::write(stale.join("file"), b"stale").unwrap();
        let now = SystemTime::now();
        assert_eq!(
            sweep(
                &base.join("drops"),
                now + PARTIAL_AGE + Duration::from_secs(1),
                |_| {},
            )
            .unwrap(),
            6
        );
        assert!(!stale.exists());
        assert_eq!(
            sweep(
                &base.join("drops"),
                now + MAX_AGE + Duration::from_secs(1),
                |_| {}
            )
            .unwrap(),
            0
        );
        let bad = base.join("drops/0123456789abcdef0123456789abcdef");
        fs::create_dir(&bad).unwrap();
        symlink("/dev/null", bad.join("file")).unwrap();
        assert!(receive(&base, name(), 0, |_| Ok(0)).is_ok());
        assert!(
            fs::symlink_metadata(bad.join("file"))
                .unwrap()
                .file_type()
                .is_symlink()
        );
        fs::remove_dir_all(&base).unwrap();
        fs::create_dir(&base).unwrap();
        symlink(&base, base.join("drops")).unwrap();
        assert!(receive(&base, name(), 0, |_| Ok(0)).is_err());
        fs::remove_dir_all(base).unwrap();
    }
}
