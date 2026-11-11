use std::fs;
use std::path::{Path, PathBuf};

use ko_sys::pid::Exit;

use crate::runtime::exec::Launch;
use crate::runtime::{
    Cleanup, Ctx, Ending, Entry, Next, Outcome, last_line, pane, text, version_next, words,
};
use ko_config::runtime::Ssh;
use ko_config::ssh_args::has_syntax;
use ko_sys::file::{env_path, program_path};
use ko_sys::sock::SUN_PATH_MAX;
use ko_wire::ids::PaneId;
use ko_wire::ssh::{
    MASTER_OPTIONS, MASTER_SUFFIX, QueryFailure, SOCKET, control_args, forwarding_refused,
    no_remote_ko, query_failure, quote, reported_path, token_name,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Stage {
    Check,
    Master,
    Prepare,
    Cancel,
    Forward,
}

/// What the start learns about the remote, and where it is.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Link {
    stage: Stage,
    dir: Option<String>,
    adopted: bool,
}

impl Link {
    pub(crate) fn new() -> Link {
        Link {
            stage: Stage::Check,
            dir: None,
            adopted: false,
        }
    }
}

fn program(env: &[Vec<u8>]) -> Result<PathBuf, String> {
    let path = String::from_utf8_lossy(env_path(env));
    program_path(&path, "ssh").ok_or_else(|| "ssh: command not found".to_owned())
}

fn launch(env: &[Vec<u8>], args: Vec<String>) -> Result<Launch, String> {
    Ok(Launch::new(program(env)?, args, env))
}

// Options of every invocation through the master. With ControlMaster=no, ssh connects directly
// when the control socket does not answer; the proxy command that always fails turns that into
// an error.
fn through(ctl: &Path) -> Vec<String> {
    let mut args = words(&["-S"]);
    args.push(text(ctl));
    args.extend(words(&[
        "-o",
        "ControlMaster=no",
        "-o",
        "BatchMode=yes",
        "-o",
        "ProxyCommand=/usr/bin/false",
        "-o",
        "RemoteCommand=none",
    ]));
    args
}

fn passenger(ssh: &Ssh, cx: &Ctx<'_>, remote: Vec<String>) -> Result<Launch, String> {
    let mut args = words(&["-T"]);
    args.extend(through(&pane::control_path(cx.root, cx.key)));
    args.extend(["--".to_owned(), ssh.destination.as_str().to_owned()]);
    args.extend(remote);
    launch(cx.env, args)
}

fn operation(ssh: &Ssh, cx: &Ctx<'_>, operation: &[&str]) -> Result<Launch, String> {
    launch(
        cx.env,
        control_args(
            &pane::control_path(cx.root, cx.key),
            operation,
            ssh.destination.as_str(),
        ),
    )
}

fn check_paths(cx: &Ctx<'_>) -> Result<(), String> {
    let dir = pane::directory(cx.root, cx.key);
    let shown = text(&dir);
    if dir.as_os_str().len() + MASTER_SUFFIX > SUN_PATH_MAX {
        Err(format!(
            "runtime control path under {shown} exceeds {SUN_PATH_MAX} bytes; set KO_STATE_DIR to a shorter path"
        ))
    } else if has_syntax(&shown) {
        Err(format!(
            "runtime directory {shown} contains a colon or a percent sign, which ssh reads as syntax"
        ))
    } else {
        Ok(())
    }
}

pub(crate) fn first(ssh: &Ssh, cx: &Ctx<'_>) -> Result<Launch, String> {
    check_paths(cx)?;
    check(ssh, cx)
}

pub(crate) fn check(ssh: &Ssh, cx: &Ctx<'_>) -> Result<Launch, String> {
    operation(ssh, cx, &["-O", "check"])
}

fn master(ssh: &Ssh, cx: &Ctx<'_>) -> Result<Launch, String> {
    let mut argv = words(&["-M", "-N", "-f", "-n", "-o", "BatchMode=yes"]);
    argv.extend([
        "-o".to_owned(),
        format!("ControlPath={}", text(&pane::control_path(cx.root, cx.key))),
    ]);
    for option in ["ControlMaster=yes", "ControlPersist=yes"]
        .into_iter()
        .chain(MASTER_OPTIONS)
    {
        argv.extend(["-o".to_owned(), option.to_owned()]);
    }
    argv.extend(ssh.ssh_args.as_slice().iter().cloned());
    argv.push(ssh.destination.as_str().to_owned());
    launch(cx.env, argv)
}

fn prepare(ssh: &Ssh, cx: &Ctx<'_>) -> Result<Launch, String> {
    let mut words = vec!["ko", "enter", "--prepare"];
    let dir = ssh.dir.as_ref().map(|dir| dir.as_str());
    if let Some(dir) = &dir {
        words.extend(["--dir", dir]);
    }
    words.extend(["--runtime", cx.key.name.as_str()]);
    let mut words: Vec<String> = words.into_iter().map(str::to_owned).collect();
    if let Some(tag) = cx.key.tag_arg() {
        words.extend(["--tag".to_owned(), tag.to_string()]);
    }
    passenger(ssh, cx, words.iter().map(|word| quote(word)).collect())
}

fn to_prepare(ssh: &Ssh, link: &mut Link, cx: &Ctx<'_>) -> Result<Launch, String> {
    link.stage = Stage::Prepare;
    prepare(ssh, cx)
}

// The directory on the first line and ko's version on the second.
fn prepared<'a>(destination: &str, out: &'a Outcome<'_>) -> Result<(String, &'a [u8]), String> {
    match query_failure(out.exit, out.tail) {
        None => {}
        Some(QueryFailure::NoKo) => return Err(no_remote_ko(destination)),
        Some(QueryFailure::Ssh(message)) => {
            return Err(if message.is_empty() {
                format!("ssh to {destination} failed")
            } else {
                message
            });
        }
        Some(QueryFailure::Exit { code, message }) => {
            return Err(format!(
                "cannot prepare {destination}: {message} (exit {code})"
            ));
        }
        Some(QueryFailure::Signal(signal)) => {
            return Err(format!("ssh to {destination} died of signal {signal}"));
        }
    }
    let (first, rest) = match out.stdout.iter().position(|byte| *byte == b'\n') {
        Some(at) => (
            &out.stdout[..at],
            out.stdout.get(at + 1..).unwrap_or_default(),
        ),
        None => (out.stdout, &[][..]),
    };
    let first = String::from_utf8_lossy(first);
    let dir = reported_path(&first)
        .ok_or_else(|| format!("{destination} reported an invalid directory {first:?}"))?;
    Ok((dir.to_owned(), rest))
}

fn forward(ssh: &Ssh, link: &Link, cx: &Ctx<'_>, operation_name: &str) -> Result<Launch, String> {
    let dir = link
        .dir
        .as_deref()
        .ok_or_else(|| "the remote directory is not known".to_owned())?;
    let spec = format!("{dir}/{SOCKET}:{}", text(cx.socket));
    operation(ssh, cx, &["-O", operation_name, "-R", &spec])
}

pub(crate) fn next(ssh: &Ssh, link: &mut Link, cx: &Ctx<'_>, out: &Outcome<'_>) -> Next {
    let launched = |launch: Result<Launch, String>| match launch {
        Ok(launch) => Next::Run(launch),
        Err(message) => Next::Fail(message),
    };
    match link.stage {
        Stage::Check if out.ok() => {
            link.adopted = true;
            launched(to_prepare(ssh, link, cx))
        }
        Stage::Check => {
            link.adopted = false;
            let _ = fs::remove_file(pane::control_path(cx.root, cx.key));
            link.stage = Stage::Master;
            launched(master(ssh, cx))
        }
        Stage::Master if out.ok() => launched(to_prepare(ssh, link, cx)),
        Stage::Master => Next::Fail(out.failure("ssh master")),
        Stage::Prepare => {
            let (dir, version) = match prepared(ssh.destination.as_str(), out) {
                Ok(found) => found,
                Err(message) => return Next::Fail(message),
            };
            let inner = Outcome {
                exit: out.exit,
                stdout: version,
                tail: out.tail,
            };
            if let Next::Fail(message) = version_next(&cx.key.name, &inner) {
                return Next::Fail(message);
            }
            link.dir = Some(dir);
            // An adopted master may still hold this forward, and ssh skips an identical one
            // while prepare has just removed its socket file.
            let (stage, operation_name) = if link.adopted {
                (Stage::Cancel, "cancel")
            } else {
                (Stage::Forward, "forward")
            };
            link.stage = stage;
            launched(forward(ssh, link, cx, operation_name))
        }
        Stage::Cancel => {
            link.stage = Stage::Forward;
            launched(forward(ssh, link, cx, "forward"))
        }
        Stage::Forward if out.ok() => Next::Up,
        Stage::Forward => {
            let message = String::from_utf8_lossy(out.tail).trim().to_owned();
            Next::Fail(if message.contains("forwarding") {
                forwarding_refused(ssh.destination.as_str())
            } else {
                format!("ssh cannot forward the socket: {message}")
            })
        }
    }
}

pub(crate) fn token(ssh: &Ssh, link: &Link, cx: &Ctx<'_>, pane: PaneId) -> Result<Launch, String> {
    let dir = link
        .dir
        .as_deref()
        .ok_or_else(|| "the remote directory is not known".to_owned())?;
    let file = quote(&format!("{dir}/{}", token_name(pane)));
    passenger(ssh, cx, vec![format!("umask 077 && cat > {file}")])
}

/// The master is nobody's child: down asks it to exit, and the next `ko enter --prepare`
/// clears what it leaves on the remote.
pub(crate) fn cleanup(ssh: &Ssh, cx: &Ctx<'_>, what: Cleanup) -> Option<Launch> {
    match what {
        Cleanup::Stop => operation(ssh, cx, &["-O", "exit"]).ok(),
        Cleanup::Delete => None,
    }
}

pub(crate) fn exec_launch(ssh: &Ssh, cx: &Ctx<'_>) -> Result<Launch, String> {
    let command = format!("exec {}", ["ko", "enter", "--exec"].map(quote).join(" "));
    // Nothing of the server's environment is for the remote command: ssh would send what a
    // SendEnv of the user's configuration names (the locale that the system's configuration
    // sends, PATH or HOME), and the command would keep it. ssh finds the program by the
    // server's PATH, here, and runs without an environment; the remote login environment is
    // the command's.
    let mut launch = passenger(ssh, cx, vec![command])?;
    launch.env.clear();
    Ok(launch)
}

pub(crate) fn ending(exit: Exit, stderr: &[u8]) -> Ending {
    if exit != Exit::Exited(255) {
        return Ending::Exit;
    }
    let text = String::from_utf8_lossy(stderr);
    let refusal = text.lines().map(str::trim).find(|line| {
        line.starts_with("mux_client_request_session: session request failed:")
            || (line.starts_with("channel ") && line.contains(": open failed:"))
    });
    match refusal {
        Some(line) => Ending::Refused(line.to_owned()),
        None => Ending::Error(last_line(stderr).unwrap_or_else(|| "ssh failed".to_owned())),
    }
}

pub(crate) fn entry(ssh: &Ssh, cx: &Ctx<'_>) -> Entry {
    let ctl = pane::control_path(cx.root, cx.key);
    let prefix: Vec<Vec<u8>> = words(&["ssh", "-t"])
        .into_iter()
        .chain(through(&ctl))
        .chain(["--".to_owned(), ssh.destination.as_str().to_owned()])
        .map(String::into_bytes)
        .collect();
    let location = ssh
        .dir
        .as_ref()
        .map(|dir| vec![b"--dir".to_vec(), dir.as_str().as_bytes().to_vec()])
        .unwrap_or_default();
    Entry {
        prefix,
        ko: vec![b"exec".to_vec(), b"ko".to_vec()],
        location,
        token: Vec::new(),
        quoted: true,
    }
}

#[cfg(test)]
mod tests {
    use crate::runtime::RuntimeKey;
    use ko_config::runtime::{Kind, Runtime};

    use super::*;
    use ko_wire::protocol::{Version, json, version};

    fn ssh_runtime(extra: &str) -> Runtime {
        serde_json::from_str(&format!(r#"{{"ssh":{{"destination":"box"{extra}}}}}"#)).unwrap()
    }

    fn context<'a>(key: &'a RuntimeKey, env: &'a [Vec<u8>], socket: &'a Path) -> Ctx<'a> {
        Ctx {
            root: Path::new("/r"),
            key,
            env,
            socket,
            exe: Path::new("/ko"),
        }
    }

    #[test]
    fn session_tags_reach_prepare() {
        let runtime = ssh_runtime("");
        let Kind::Ssh(ssh) = &runtime.kind else {
            panic!("ssh");
        };
        let env = vec![b"PATH=/usr/bin:/bin".to_vec()];
        for session in ["session_3", "session_4"] {
            let key = RuntimeKey::session("dev".parse().unwrap(), session.parse().unwrap());
            let cx = context(&key, &env, Path::new("/socket"));
            let tag = format!("{session}-dev");
            assert!(prepare(ssh, &cx).unwrap().args.ends_with(&[
                "'ko'".to_owned(),
                "'enter'".to_owned(),
                "'--prepare'".to_owned(),
                "'--runtime'".to_owned(),
                "'dev'".to_owned(),
                "'--tag'".to_owned(),
                format!("'{tag}'"),
            ]));
        }
    }

    #[test]
    fn a_refused_channel_is_retryable_and_any_other_255_is_an_error() {
        assert_eq!(ending(Exit::Exited(0), b""), Ending::Exit);
        assert_eq!(ending(Exit::Exited(3), b"open failed"), Ending::Exit);
        assert_eq!(
            ending(Exit::Exited(255), b"open failed\nsession refused by peer\n"),
            Ending::Error("session refused by peer".to_owned())
        );
        assert_eq!(
            ending(
                Exit::Exited(255),
                b"channel 2: open failed: administratively prohibited: open failed\n"
            ),
            Ending::Refused(
                "channel 2: open failed: administratively prohibited: open failed".to_owned()
            )
        );
        let refused =
            "mux_client_request_session: session request failed: Session open refused by peer";
        assert_eq!(
            ending(
                Exit::Exited(255),
                format!("x\n{refused}\nConnection closed by UNKNOWN port 65535\n").as_bytes()
            ),
            Ending::Refused(refused.to_owned())
        );
        assert_eq!(
            ending(
                Exit::Exited(255),
                b"Connection closed by UNKNOWN port 65535\n"
            ),
            Ending::Error("Connection closed by UNKNOWN port 65535".to_owned())
        );
        assert_eq!(
            ending(Exit::Exited(255), b""),
            Ending::Error("ssh failed".to_owned())
        );
    }

    #[test]
    fn another_ko_build_on_the_remote_fails_the_start_and_names_both_builds() {
        let runtime = ssh_runtime("");
        let Kind::Ssh(ssh) = &runtime.kind else {
            panic!("not ssh");
        };
        let key = RuntimeKey::config("box".parse().unwrap());
        let socket = PathBuf::from("/r/box/io/socket");
        let env = [b"PATH=/usr/bin:/bin".to_vec()];
        let own = version();
        let prepared = |protocol: &str, vt: &str| {
            let remote = Version {
                protocol: protocol.to_owned(),
                vt: vt.to_owned(),
                build: "remote-build".to_owned(),
            };
            let stdout = format!("/run/ko\n{}\n", json(&remote));
            let mut link = Link::new();
            link.stage = Stage::Prepare;
            let out = Outcome {
                exit: Exit::Exited(0),
                stdout: stdout.as_bytes(),
                tail: b"",
            };
            next(ssh, &mut link, &context(&key, &env, &socket), &out)
        };
        assert!(matches!(prepared("1.7", &own.vt), Next::Run(_)));
        for (protocol, vt) in [("2.0", own.vt.as_str()), ("1.0", "vt-other")] {
            let Next::Fail(message) = prepared(protocol, vt) else {
                panic!("the build was accepted");
            };
            assert!(
                message.contains("remote-build")
                    && message.contains(&own.build)
                    && message.contains("runtime box"),
                "{message}"
            );
        }
    }

    #[test]
    fn a_failed_prepare_says_why() {
        let failed = |exit, stderr: &[u8]| {
            prepared(
                "box",
                &Outcome {
                    exit,
                    stdout: b"",
                    tail: stderr,
                },
            )
            .unwrap_err()
        };
        assert!(
            failed(Exit::Exited(127), b"")
                .starts_with("ko is not on the PATH of non-interactive ssh commands on box")
        );
        assert_eq!(
            failed(Exit::Exited(255), b"Permission denied\n"),
            "Permission denied"
        );
        assert_eq!(
            failed(Exit::Exited(2), b"boom\n"),
            "cannot prepare box: boom (exit 2)"
        );
    }

    #[test]
    fn the_exec_and_token_commands_quote_every_word() {
        let runtime = ssh_runtime("");
        let Kind::Ssh(ssh) = &runtime.kind else {
            panic!("not ssh");
        };
        let key = RuntimeKey::config("box".parse().unwrap());
        let env = [b"PATH=/usr/bin:/bin".to_vec()];
        let socket = PathBuf::from("/r/box/io/socket");
        let cx = context(&key, &env, &socket);
        let launch = exec_launch(ssh, &cx).unwrap_or_else(|why| panic!("{why}"));
        assert_eq!(launch.args.last().unwrap(), "exec 'ko' 'enter' '--exec'");
        assert!(launch.args.iter().any(|arg| arg == "/r/box/ctl"));
        assert!(!launch.args.iter().any(|arg| arg == "/r/box/io/ctl"));
        assert!(
            launch
                .args
                .iter()
                .any(|arg| arg == "ProxyCommand=/usr/bin/false")
        );
        assert!(launch.env.is_empty(), "the passenger has no environment");
        assert!(launch.program.is_absolute());
        let link = Link {
            stage: Stage::Forward,
            dir: Some("/run/ko".to_owned()),
            adopted: false,
        };
        let token = token(
            ssh,
            &link,
            &context(&key, &env, Path::new("/r/box/io/socket")),
            "pane_3".parse().unwrap(),
        )
        .unwrap();
        assert_eq!(
            token.args.last().unwrap(),
            "umask 077 && cat > '/run/ko/pane_3.token'"
        );
    }

    #[test]
    fn a_pane_runs_ko_enter_through_the_master_with_the_directory() {
        let runtime = ssh_runtime(r#","dir":"/srv/ko""#);
        let Kind::Ssh(ssh) = &runtime.kind else {
            panic!("not ssh");
        };
        let key = RuntimeKey::config("box".parse().unwrap());
        let env = [];
        let socket = PathBuf::from("/r/box/io/socket");
        let entry = entry(ssh, &context(&key, &env, &socket));
        assert_eq!(entry.prefix.last().unwrap(), b"box");
        assert_eq!(entry.ko, [b"exec".to_vec(), b"ko".to_vec()]);
        assert_eq!(entry.location, [b"--dir".to_vec(), b"/srv/ko".to_vec()]);
        assert!(entry.quoted);
    }
}
