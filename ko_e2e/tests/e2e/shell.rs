use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use serde_json::json;

use crate::harness::{
    Dir, Server, host_ssh_enabled, ko, run_ko, run_program, start_with, test_env, which,
};
use crate::status::{Flavour, dotfiles, shell_of};

pub(crate) fn script(dir: &Path, name: &str, body: &str) -> PathBuf {
    let path = dir.join(name);
    fs::write(&path, body).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    path
}

pub(crate) fn fake(dir: &Path, name: &str) -> PathBuf {
    let path = dir.join(name);
    fs::copy(env!("CARGO_BIN_EXE_ko-fake"), &path).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    path
}

fn path_with(dir: &Path) -> String {
    format!(
        "{}:{}",
        dir.display(),
        std::env::var("PATH").unwrap_or_default()
    )
}

fn zsh_server(path: &str) -> Option<Server> {
    let shell = shell_of(&Flavour::Zsh)?;
    let s = start_with(&shell, &[("PATH", path)], &[]);
    dotfiles(&Flavour::Zsh, &s.dir, "");
    Some(s)
}

#[test]
fn ssh_mark() {
    let fakes = Dir::new("ko-fake-ssh-");
    fake(&fakes, "ssh");
    let s = start_with(Path::new("/bin/sh"), &[("PATH", &path_with(&fakes))], &[]);
    let session = |arguments: &str| {
        s.pane(&format!(
            "set -m; printf '\\033]133;C;cmdline_url=ssh alias\\007'; ko ssh {arguments}; \
             printf '\\033]133;D;0\\007\\033]133;A\\007'; exec cat"
        ))
    };

    let pane = session("alias uptime");
    s.wait_row(&pane, "the ssh marks", |row| {
        row["vars"]["ssh.dest"] == "alias" && row["vars"]["ssh.args"] == json!(["alias"])
    });
    s.screen_has(&pane, "SSH-ARGS:alias uptime");

    s.text(&pane, "prompt\n");
    let row = s.wait_row(&pane, "an interactive ssh row", |row| {
        row["status"]["kind"]["pane"]["interactive"] == true
    });
    assert_eq!(row["status"]["kind"]["type"], "ssh");
    assert_eq!(row["status"]["kind"]["destination"], "alias");
    assert_eq!(row["status"]["title"], "ssh alias");
    assert_eq!(
        row["status"]["kind"]["pane"]["status"]["phase"]["type"],
        "idle"
    );

    s.text(&pane, "run\n");
    let row = s.wait_row(&pane, "a remote command", |row| {
        row["status"]["kind"]["pane"]["status"]["phase"]["type"] == "running"
    });
    assert_eq!(row["status"]["title"], "ssh alias: sleep 45");

    s.text(&pane, "agent\n");
    let row = s.wait_row(&pane, "a remote agent", |row| {
        row["status"]["kind"]["pane"]["type"] == "agent"
    });
    assert_eq!(row["status"]["kind"]["pane"]["name"], "claude-code");
    assert_eq!(row["status"]["title"], "Remote Claude");

    s.text(&pane, "exit\n");
    let row = s.wait_row(&pane, "the shell back in the foreground", |row| {
        row["status"]["kind"]["type"] == "terminal"
    });
    assert_eq!(row["vars"]["ssh.dest"], "alias");
    assert_eq!(row["vars"]["ssh.args"], json!(["alias"]));

    let realm = session("-l deploy@realm realm uptime");
    s.wait_row(&realm, "the realm marks", |row| {
        row["vars"]["ssh.dest"] == "realm"
            && row["vars"]["ssh.args"] == json!(["-l", "deploy@realm", "realm"])
    });
    s.text(&realm, "prompt\n");
    let row = s.wait_row(&realm, "the destination as typed", |row| {
        row["status"]["kind"]["type"] == "ssh"
    });
    assert_eq!(row["status"]["kind"]["destination"], "realm");

    let user = session("bob@alias uptime");
    s.wait_row(&user, "the user kept in the destination", |row| {
        row["vars"]["ssh.dest"] == "bob@alias"
    });

    for unparsable in ["-p", "-v"] {
        let pane = session(unparsable);
        s.screen_has(&pane, &format!("SSH-ARGS:{unparsable}"));
        let row = s.row(&pane);
        assert_eq!(
            row["vars"],
            json!({}),
            "ssh {unparsable} sets nothing: {row}"
        );
    }

    let stale = s.pane("set -m; ko ssh alias; ko ssh -p; exec cat");
    s.wait_row(&stale, "the first mark", |row| {
        row["vars"]["ssh.dest"] == "alias"
    });
    s.text(&stale, "exit\n");
    s.screen_has(&stale, "SSH-ARGS:-p");
    let row = s.row(&stale);
    assert_eq!(
        row["vars"],
        json!({}),
        "an unparsable ssh clears both marks: {row}"
    );
}

fn recorded(file: &Path) -> Vec<Vec<String>> {
    let data = fs::read(file).unwrap_or_default();
    data.split(|byte| *byte == 0 && false)
        .flat_map(|chunk| {
            chunk
                .split(|byte| *byte == 2)
                .filter(|run| !run.is_empty())
                .map(|run| {
                    run.split(|byte| *byte == 0)
                        .filter(|arg| !arg.is_empty())
                        .map(|arg| String::from_utf8_lossy(arg).into_owned())
                        .collect()
                })
                .collect::<Vec<_>>()
        })
        .collect()
}

#[test]
fn ko_ssh_arguments() {
    let fakes = Dir::new("ko-fake-ssh-");
    let record = fakes.join("record");
    script(
        &fakes,
        "ssh",
        &format!(
            r#"#!/bin/sh
{{ for arg in "$@"; do printf '%s\0' "$arg"; done; printf '\002'; }} >> {}
"#,
            record.display()
        ),
    );
    let s = start_with(Path::new("/bin/sh"), &[("PATH", &path_with(&fakes))], &[]);
    let run = |command: &str| {
        let pane = s.pane(&format!("{command}; printf DONE; exec cat"));
        s.screen_has(&pane, "DONE");
        let calls = recorded(&record);
        fs::remove_file(&record).unwrap();
        calls
    };
    let tty = run("ssh -oBatchMode=yes alias");
    assert_eq!(tty.len(), 1, "{tty:?}");
    assert!(tty[0].len() == 5, "{:?}", tty[0]);
    assert_eq!(tty[0][..4], ["-oBatchMode=yes", "-t", "--", "alias"]);
    assert!(
        tty[0][4].starts_with("ko_zsh_b64='"),
        "the bootstrap: {:?}",
        tty[0]
    );
    assert_eq!(
        run("ssh alias uptime -p 2"),
        [["alias", "uptime", "-p", "2"]],
        "a remote command passes through as typed"
    );
    assert_eq!(
        run("printf '' | ssh -oBatchMode=yes alias"),
        [["-oBatchMode=yes", "alias"]],
        "without a tty ssh runs as typed"
    );
    assert_eq!(run("ssh -N alias"), [["-N", "alias"]]);
}

#[test]
fn pane_runs_the_shims() {
    let Some(shell) = shell_of(&Flavour::Zsh) else {
        eprintln!("skipped: no zsh on PATH");
        return;
    };
    let s = start_with(&shell, &[], &[]);
    dotfiles(&Flavour::Zsh, &s.dir, "");
    fs::write(s.dir.join(".zprofile"), "PATH=/usr/bin:/bin:$PATH\n").unwrap();
    let shims = fs::canonicalize(ko().parent().unwrap().join("../share/ko/bin")).unwrap();
    let pane = s.shell_pane();
    s.wait_row(&pane, "the first prompt", |row| {
        row["status"]["kind"]["phase"]["type"] == "idle"
    });
    s.text(
        &pane,
        "printf 'K<%s>\\n' \"$(command -v ko)\" \"$(command -v ssh)\"; ko version\r",
    );
    s.screen_has(&pane, "\"protocol\"");
    let screen = s.screen(&pane);
    let found: Vec<PathBuf> = screen
        .lines()
        .filter_map(|line| line.strip_prefix("K<")?.strip_suffix('>'))
        .map(|path| fs::canonicalize(path).unwrap())
        .collect();
    assert_eq!(
        found,
        [shims.join("ko"), shims.join("ssh")],
        "the shims come first after a login file demoted them: {screen}"
    );
    let version = run_ko(&s.scratch, &test_env(&s.dir), &["version"], "").ok();
    assert!(
        screen.replace('\n', "").contains(version.trim()),
        "ko version through the shim is the prefix binary's: {screen}"
    );
}

// The test runs itself again with decoy dotfiles in the inherited HOME, ZDOTDIR, ENV and BASH_ENV.
// The child, with the harness's private environment, runs login and interactive shells and
// `ko shell -- CMD` panes; a decoy that is read leaves a marker.
fn dotfile_probe() {
    let scratch = Dir::new("ko-probe-run-");
    let home = Dir::new("ko-probe-home-");
    for name in ["bash", "zsh", "sh"] {
        let Some(shell) = which(name) else { continue };
        for args in [
            &["-l", "-i", "-c", ":"][..],
            &["-i", "-c", ":"],
            &["-c", ":"],
        ] {
            let run = run_program(&scratch, &shell, &test_env(&home), args, "");
            assert_eq!(
                run.exit,
                ko_sys::pid::Exit::Exited(0),
                "{name} {args:?}: {run:?}"
            );
        }
        let s = start_with(&shell, &[], &[]);
        let pane = s.pane("ko shell -- sh -c 'exit 0'");
        s.wait_row(&pane, "the login command to end", |row| {
            !row["dead"].is_null()
        });
    }
}

#[test]
fn shell_dotfile_isolation() {
    if std::env::var("KO_E2E_DOTFILE_PROBE").as_deref() == Ok("1") {
        dotfile_probe();
        return;
    }
    let decoys = Dir::new("ko-decoys-");
    let marker = decoys.join("reads");
    for file in [
        ".profile",
        ".bash_profile",
        ".bash_login",
        ".bashrc",
        ".zshenv",
        ".zprofile",
        ".zshrc",
        ".zlogin",
        "startup",
    ] {
        fs::write(
            decoys.join(file),
            format!("printf '%s\\n' '{file}' >> '{}'\n", marker.display()),
        )
        .unwrap();
    }
    let mut env: Vec<Vec<u8>> = std::env::vars_os()
        .filter(|(name, _)| {
            !["HOME", "ZDOTDIR", "ENV", "BASH_ENV"].contains(&name.to_str().unwrap_or(""))
        })
        .map(|(name, value)| {
            format!("{}={}", name.to_string_lossy(), value.to_string_lossy()).into_bytes()
        })
        .collect();
    let startup = decoys.join("startup");
    env.extend([
        format!("HOME={}", decoys.display()).into_bytes(),
        format!("ZDOTDIR={}", decoys.display()).into_bytes(),
        format!("ENV={}", startup.display()).into_bytes(),
        format!("BASH_ENV={}", startup.display()).into_bytes(),
        b"KO_E2E_DOTFILE_PROBE=1".to_vec(),
    ]);
    let out = Dir::new("ko-probe-out-");
    let run = run_program(
        &out,
        &std::env::current_exe().unwrap(),
        &env,
        &[
            "--exact",
            "shell::shell_dotfile_isolation",
            "--test-threads=1",
        ],
        "",
    );
    assert_eq!(run.exit, ko_sys::pid::Exit::Exited(0), "the probe: {run:?}");
    let reads = fs::read_to_string(&marker).unwrap_or_default();
    assert_eq!(reads, "", "shells read inherited dotfiles");
}

#[test]
fn login_command() {
    let scratch = Dir::new("ko-login-");
    let bin_dir = fs::canonicalize(ko().parent().unwrap().join("../share/ko/bin")).unwrap();
    for flavour in [Flavour::Zsh, Flavour::Bash] {
        let Some(shell) = shell_of(&flavour) else {
            continue;
        };
        let home = Dir::new("ko-home-");
        match flavour {
            Flavour::Zsh => fs::write(home.join(".zshenv"), "export FOO=from-zshenv\n").unwrap(),
            Flavour::Bash => {
                fs::write(home.join(".bash_profile"), "export FOO=from-bash-profile\n").unwrap();
            }
        }
        let mut env = test_env(&home);
        env.push(format!("KO_SHELL={}", shell.display()).into_bytes());
        let run = run_program(
            &scratch,
            &ko(),
            &env,
            &[
                "shell",
                "--",
                "sh",
                "-c",
                "echo \"FOO=$FOO ARG0=$0\"; echo \"PATH=$PATH\"; exit 23",
                "literal arg",
            ],
            "",
        );
        assert_eq!(run.exit, ko_sys::pid::Exit::Exited(23), "{run:?}");
        let foo = if matches!(flavour, Flavour::Zsh) {
            "from-zshenv"
        } else {
            "from-bash-profile"
        };
        assert!(
            run.stdout.contains(&format!("FOO={foo} ARG0=literal arg")),
            "{run:?}"
        );
        let path = run
            .stdout
            .lines()
            .find_map(|line| line.strip_prefix("PATH="))
            .unwrap_or_default();
        assert_eq!(
            fs::canonicalize(path.split(':').next().unwrap_or_default()).ok(),
            Some(bin_dir.clone()),
            "the ko bin directory is first on PATH: {path}"
        );
        assert!(
            !run.stdout.contains("\x1b]133"),
            "no prompt mark: {:?}",
            run.stdout
        );
    }
}

// These tests use the host's sshd, which starts the real user's login shell with the real
// dotfiles, whatever HOME the test sets. They run only with KO_E2E_HOST_SSH=1; then a failed ssh
// probe or a missing zsh is a failure, not a skip.
fn host_ssh() -> Option<Server> {
    if !host_ssh_enabled() {
        return None;
    }
    let ssh = which("ssh").expect("ssh is not on PATH");
    let probe = Dir::new("ko-host-ssh-");
    let run = run_program(
        &probe,
        &ssh,
        &test_env(&probe),
        &["-o", "BatchMode=yes", "localhost", "true"],
        "",
    );
    assert_eq!(
        run.exit,
        ko_sys::pid::Exit::Exited(0),
        "ssh to localhost: {run:?}"
    );
    let s = zsh_server(&std::env::var("PATH").unwrap_or_default())
        .expect("KO_E2E_HOST_SSH needs a local zsh");
    // Panes get SSH_AUTH_SOCK=<dir>/agent.sock; publish the developer's agent there, as the app does.
    if let Some(agent) = std::env::var_os("SSH_AUTH_SOCK") {
        std::os::unix::fs::symlink(agent, s.dir.join("agent.sock")).unwrap();
    }
    Some(s)
}

#[test]
fn ko_ssh_primes_a_remote_shell() {
    let Some(s) = host_ssh() else { return };
    let plain = s.shell_pane();
    s.wait_row(&plain, "the first prompt", |row| {
        row["status"]["kind"]["phase"]["type"] == "idle"
    });
    s.text(&plain, "ssh -tt localhost 'exec $SHELL -i'\r");
    s.wait_row(&plain, "an unprimed ssh", |row| {
        row["status"]["kind"]["type"] == "ssh"
    });
    s.text(&plain, "echo remote-$((1+1))\r");
    s.screen_has(&plain, "remote-2");
    let row = s.row(&plain);
    assert_eq!(
        row["status"]["kind"]["pane"]["interactive"], false,
        "an unprimed remote shell reports nothing: {row}"
    );

    let primed = s.shell_pane();
    s.wait_row(&primed, "the first prompt", |row| {
        row["status"]["kind"]["phase"]["type"] == "idle"
    });
    s.text(&primed, "ssh localhost\r");
    let row = s.wait_row(&primed, "a primed remote prompt", |row| {
        row["status"]["kind"]["pane"]["interactive"] == true
    });
    assert!(
        row["status"]["title"]
            .as_str()
            .is_some_and(|title| title == "ssh localhost"),
        "the row names the destination: {row}"
    );
    s.text(&primed, "sleep 1\r");
    let row = s.wait_row(&primed, "the remote command to finish", |row| {
        row["status"]["kind"]["pane"]["status"]["phase"]["last"]["command"] == "sleep 1"
    });
    assert_eq!(
        row["status"]["kind"]["pane"]["status"]["phase"]["last"]["code"],
        0
    );
}

#[test]
fn ko_ssh_opens_an_ordinary_session() {
    let Some(s) = host_ssh() else { return };
    let pane = s.shell_pane();
    s.wait_row(&pane, "the first prompt", |row| {
        row["status"]["kind"]["phase"]["type"] == "idle"
    });
    s.text(
        &pane,
        "ssh -o BatchMode=yes localhost 'echo ordinary-$((20+1))'\r",
    );
    s.screen_has(&pane, "ordinary-21");
    let row = s.wait_row(&pane, "the session to end", |row| {
        row["status"]["kind"]["type"] == "terminal"
            && !row["status"]["kind"]["phase"]["last"].is_null()
    });
    assert_eq!(
        row["status"]["kind"]["phase"]["last"]["code"], 0,
        "a command ssh runs normally: {row}"
    );
}

#[test]
fn ssh_remote_shell_status() {
    let Some(s) = host_ssh() else { return };
    let pane = s.shell_pane();
    s.wait_row(&pane, "the first prompt", |row| {
        row["status"]["kind"]["phase"]["type"] == "idle"
    });
    s.text(&pane, "ssh localhost\r");
    s.wait_row(&pane, "a primed remote prompt", |row| {
        row["status"]["kind"]["pane"]["interactive"] == true
    });
    s.text(&pane, "sleep 3\r");
    let row = s.wait_row(&pane, "the remote command", |row| {
        row["status"]["kind"]["pane"]["status"]["phase"]["type"] == "running"
    });
    let title = row["status"]["title"].as_str().unwrap_or_default();
    assert_eq!(title, "ssh localhost: sleep 3", "{row}");
    assert_eq!(row["foreground"]["name"], "ssh", "{row}");
}
