use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use serde_json::json;

use crate::harness::{
    DEADLINE, Dir, Server, enabled, ko, quote, run_ko, run_program, sh, start_with, test_env,
    text_of, which,
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

#[test]
fn ko_ssh_installs_remote_terminfo() {
    use crate::sshd::{HOST, Remote};

    if !enabled("KO_E2E_HOST_SSH") {
        return;
    }
    let s = start_with(Path::new("/bin/sh"), &[], &[]);
    let remote = Remote::with_ko(&s.dir);
    let bin = s.dir.join("remote-bin");
    fs::create_dir(&bin).unwrap();
    script(
        &bin,
        "infocmp",
        "#!/bin/sh\nexec /usr/bin/infocmp -A \"$HOME/.terminfo\" \"$@\"\n",
    );
    let prefix = s.dir.join("remote-prefix");
    fs::rename(remote.bin.join("ssh"), remote.bin.join("ssh-real")).unwrap();
    script(
        &remote.bin,
        "ssh",
        &format!(
            "#!/bin/sh\nfor arg do\n shift\n case \"$arg\" in *ko_zsh_b64=*) arg=\"$(cat {}); $arg\";; esac\n set -- \"$@\" \"$arg\"\ndone\nexec {} \"$@\"\n",
            quote(text_of(&prefix)),
            quote(text_of(&remote.bin.join("ssh-real"))),
        ),
    );
    let entry = fs::read(
        ko().parent()
            .unwrap()
            .join("../share/ko/terminfo/x/xterm-ghostty"),
    )
    .unwrap();
    for case in ["missing", "readonly"] {
        let home = s.dir.join(case);
        fs::create_dir_all(home.join(".terminfo")).unwrap();
        if case == "readonly" {
            fs::set_permissions(home.join(".terminfo"), fs::Permissions::from_mode(0o555)).unwrap();
        }
        fs::write(
            &prefix,
            format!(
                "export HOME={} PATH={}:/usr/bin:/bin SHELL=/bin/sh; printf 'REMOTE_READY\\n'",
                quote(text_of(&home)),
                quote(text_of(&bin)),
            ),
        )
        .unwrap();
        let mut request = sh(&format!(
            "PATH={}:{}:/usr/bin:/bin TERM=xterm-ghostty exec {} ssh {HOST}",
            quote(text_of(&ko().parent().unwrap().join("../share/ko/bin"))),
            quote(text_of(&remote.bin)),
            quote(text_of(&ko())),
        ));
        request["close"] = json!("keep");
        let pane = s.new_pane(request);
        s.screen_has(&pane, "REMOTE_READY");
        s.text(&pane, "printf 'TERM_RESULT=%s\\n' \"$TERM\"; infocmp -x xterm-ghostty | grep -qF 'Ms=\\E]52;%p1%s;%p2%s\\007' && printf 'ENTRY_%s\\n' OK\r");
        s.screen_has(
            &pane,
            if case == "readonly" {
                "TERM_RESULT=xterm-256color"
            } else {
                "TERM_RESULT=xterm-ghostty"
            },
        );
        if case != "readonly" {
            s.screen_has(&pane, "ENTRY_OK");
            for form in ["x", "78"] {
                assert_eq!(
                    fs::read(home.join(".terminfo").join(form).join("xterm-ghostty")).unwrap(),
                    entry,
                );
            }
        }
        s.text(&pane, "exit\r");
        if case == "readonly" {
            fs::set_permissions(home.join(".terminfo"), fs::Permissions::from_mode(0o755)).unwrap();
        }
    }
}

#[test]
fn panes_inherit_current_directories() {
    let s = start_with(Path::new("/bin/sh"), &[], &[]);
    let work = fs::canonicalize(&*s.dir).unwrap().join("sp ace-é%#\t");
    fs::create_dir(&work).unwrap();
    let work = text_of(&work);
    let inherit = |source: &str| {
        let mut request = sh("pwd -P; echo DONE; exec cat");
        request["cwd"] = json!({"pane": source});
        let pane = s.new_pane(request);
        s.screen_has(&pane, "DONE");
        let row = s.ko(&["api", &format!("/panes/{pane}")], "").json();
        assert_eq!(row["cwd"], work);
    };
    for flavour in [Flavour::Zsh, Flavour::Bash] {
        let Some(shell) = shell_of(&flavour) else {
            eprintln!("skipped: shell not available");
            continue;
        };
        dotfiles(&flavour, &s.dir, "");
        let pane = s.pane(&format!(
            "KO_SHELL={} exec {} shell",
            quote(text_of(&shell)),
            quote(text_of(&ko()))
        ));
        s.wait_row(&pane, "the first directory report", |row| {
            row["cwd"]
                .as_str()
                .is_some_and(|cwd| cwd.starts_with("file://") && cwd.ends_with("/tmp"))
        });
        s.text(
            &pane,
            &format!("cd {}$'\\t'\r", quote(work.trim_end_matches('\t'))),
        );
        s.wait_row(&pane, "the changed directory report", |row| {
            row["cwd"]
                .as_str()
                .is_some_and(|cwd| cwd.ends_with("/sp%20ace-%C3%A9%25%23%09"))
        });
        inherit(&pane);
    }
    let pane = s.pane(&format!("cd {}; printf READY; exec cat", quote(work)));
    s.screen_has(&pane, "READY");
    s.wait_row(&pane, "the foreground process", |row| {
        row["foreground"]["name"] == "cat"
    });
    inherit(&pane);

    let missing = fs::canonicalize(&*s.dir).unwrap().join("removed");
    fs::create_dir(&missing).unwrap();
    let source = s.pane(&format!(
        "cd {}; printf '\\033]7;file://localhost{}\\007'; printf READY; exec cat",
        quote(text_of(&missing)),
        text_of(&missing),
    ));
    s.screen_has(&source, "READY");
    s.wait_row(
        &source,
        "the reported directory and foreground process",
        |row| {
            row["cwd"]
                .as_str()
                .is_some_and(|cwd| cwd.ends_with("/removed"))
                && row["foreground"]["name"] == "cat"
        },
    );
    let os_source = s.pane(&format!(
        "cd {}; printf '\\033]7;file://localhost{}\\007'; printf READY; exec cat",
        quote(work),
        text_of(&missing),
    ));
    s.screen_has(&os_source, "READY");
    s.wait_row(
        &os_source,
        "the unusable report and live foreground",
        |row| {
            row["cwd"]
                .as_str()
                .is_some_and(|cwd| cwd.ends_with("/removed"))
                && row["foreground"]["name"] == "cat"
        },
    );
    fs::remove_dir(&missing).unwrap();
    let mut request = sh("pwd -P; echo DONE; exec cat");
    request["cwd"] = json!({"pane": os_source});
    let os_inherited = s.new_pane(request);
    s.screen_has(&os_inherited, work.trim_end_matches('\t'));
    s.screen_has(&os_inherited, "DONE");
    assert_eq!(s.row(&os_inherited)["cwd"], work);

    let mut request = sh("pwd -P; echo DONE; exec cat");
    request["cwd"] = json!({"pane": source});
    let inherited = s.new_pane(request);
    s.screen_has(&inherited, "DONE");
    assert_eq!(s.row(&inherited)["cwd"], "/tmp");

    let mut request = sh("exec cat");
    request["cwd"] = json!(text_of(&missing));
    let error = s
        .ko(
            &["api", "-X", "POST", "--input", "-", "/panes"],
            &request.to_string(),
        )
        .http_error(400);
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(&error).unwrap()["message"],
        "cwd must be a directory"
    );
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
        row["status"]["kind"]["type"] == "host"
            && row["status"]["kind"]["pane"]["type"] == "terminal"
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
        row["status"]["kind"]["pane"]["phase"]["type"] == "idle"
    });
    let out = s.dir.join("shims.txt");
    s.text(
        &pane,
        &format!(
            "{{ command -v ko; command -v ssh; ko version; }} > {}; printf 'M%s\\n' ok\r",
            out.display()
        ),
    );
    s.screen_has(&pane, "Mok");
    let written = fs::read_to_string(&out).unwrap();
    let mut lines = written.lines();
    let found: Vec<PathBuf> = lines
        .by_ref()
        .take(2)
        .map(|path| fs::canonicalize(path).unwrap())
        .collect();
    assert_eq!(
        found,
        [shims.join("ko"), shims.join("ssh")],
        "the shims come first after a login file demoted them: {written}"
    );
    let version = run_ko(&s.scratch, &test_env(&s.dir), &["version"], "").ok();
    assert_eq!(
        lines.collect::<Vec<_>>().join("\n"),
        version.trim(),
        "ko version through the shim is the prefix binary's"
    );
}

const PROBE_SHELLS: [&str; 3] = ["bash", "zsh", "sh"];
const PROBE_ARGS: [&[&str]; 3] = [&["-l", "-i", "-c", ":"], &["-i", "-c", ":"], &["-c", ":"]];

// The test runs itself again with decoy dotfiles in the inherited HOME, ZDOTDIR, ENV and BASH_ENV.
// The child, with the harness's private environment, runs login and interactive shells and
// `ko shell -- CMD` panes; a decoy that is read leaves a marker.
fn dotfile_probe() {
    let scratch = Dir::new("ko-probe-run-");
    let home = Dir::new("ko-probe-home-");
    for name in PROBE_SHELLS {
        let Some(shell) = which(name) else { continue };
        for args in PROBE_ARGS {
            let run = run_program(&scratch, &shell, &test_env(&home), args, "", DEADLINE);
            assert_eq!(
                run.exit,
                ko_sys::pid::Exit::Exited(0),
                "{name} {args:?}: {run:?}"
            );
        }
        let s = start_with(&shell, &[], &[]);
        let pane = s.new_pane(json!({"close": "keep", "command": {"type": "shell", "command": "ko shell -- sh -c 'exit 0'"}}));
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
    let shells = PROBE_SHELLS.iter().filter(|name| which(name).is_some());
    let probe_steps = u32::try_from(shells.count() * (PROBE_ARGS.len() + 2)).unwrap();
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
        DEADLINE * probe_steps,
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
            DEADLINE,
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
    if !enabled("KO_E2E_HOST_SSH") {
        return None;
    }
    let ssh = which("ssh").expect("ssh is not on PATH");
    let probe = Dir::new("ko-host-ssh-");
    let agent = std::env::var("SSH_AUTH_SOCK").unwrap_or_default();
    let mut env = test_env(&probe);
    env.push(format!("SSH_AUTH_SOCK={agent}").into_bytes());
    let run = run_program(
        &probe,
        &ssh,
        &env,
        &["-o", "BatchMode=yes", "localhost", "true"],
        "",
        DEADLINE,
    );
    assert_eq!(
        run.exit,
        ko_sys::pid::Exit::Exited(0),
        "ssh to localhost: {run:?}"
    );
    let shell = shell_of(&Flavour::Zsh).expect("KO_E2E_HOST_SSH needs a local zsh");
    let path = std::env::var("PATH").unwrap_or_default();
    let s = start_with(&shell, &[("PATH", &path), ("SSH_AUTH_SOCK", &agent)], &[]);
    dotfiles(&Flavour::Zsh, &s.dir, "");
    Some(s)
}

#[test]
fn ko_ssh_primes_a_remote_shell() {
    let Some(s) = host_ssh() else { return };
    let plain = s.shell_pane();
    s.wait_row(&plain, "the first prompt", |row| {
        row["status"]["kind"]["pane"]["phase"]["type"] == "idle"
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
        row["status"]["kind"]["pane"]["phase"]["type"] == "idle"
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
        row["status"]["kind"]["pane"]["phase"]["type"] == "idle"
    });
    s.text(
        &pane,
        "ssh -o BatchMode=yes localhost 'echo ordinary-$((20+1))'\r",
    );
    s.screen_has(&pane, "ordinary-21");
    let row = s.wait_row(&pane, "the session to end", |row| {
        row["status"]["kind"]["pane"]["type"] == "terminal"
            && !row["status"]["kind"]["pane"]["phase"]["last"].is_null()
    });
    assert_eq!(
        row["status"]["kind"]["pane"]["phase"]["last"]["code"], 0,
        "a command ssh runs normally: {row}"
    );
}

#[test]
fn ssh_remote_shell_status() {
    let Some(s) = host_ssh() else { return };
    let pane = s.shell_pane();
    s.wait_row(&pane, "the first prompt", |row| {
        row["status"]["kind"]["pane"]["phase"]["type"] == "idle"
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
