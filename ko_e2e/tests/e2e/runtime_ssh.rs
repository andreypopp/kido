use std::fs;
use std::os::unix::fs::{FileTypeExt, PermissionsExt};
use std::path::PathBuf;

use serde_json::{Value, json};

use crate::harness::{
    DEADLINE, Dir, Server, base64, contains, poll, quote, run_ko, run_program, stays, test_env,
    text_of, wait_gone, which,
};
use crate::harness::{enabled, ko};
use crate::panes::{headers, raw};
use crate::runs::has_pane;
use crate::runtime::{
    Rt, closed_with, dead, fifo, read_exec, release, rt_pane, serve_in, start_exec, start_tree,
    state, stop_pane, tree_pids, wait_state,
};
use crate::sshd::{Forwarding, HOST, Options, Remote};

const PASSPHRASE: &str = "ko-pass";

struct Box {
    rt: Rt,
    remote: Remote,
    dir: PathBuf,
}

impl std::ops::Deref for Box {
    type Target = Server;

    fn deref(&self) -> &Server {
        &self.rt
    }
}

fn serve(options: Options, env: &[(&str, &str)]) -> Box {
    let state = Dir::new("ko-");
    let remote = Remote::with_ko_options(&state, options);
    let dir = remote.dir.join("rt");
    let ko_dir = ko().parent().unwrap().to_path_buf();
    let path = format!(
        "{}:{}:{}",
        text_of(&remote.bin),
        text_of(&ko_dir),
        std::env::var("PATH").unwrap_or_default()
    );
    let mut env = env.to_vec();
    env.push(("PATH", &path));
    let runtimes = json!({"box": {"kind": "ssh", "destination": HOST, "dir": text_of(&dir)}});
    let rt = serve_in(state, &runtimes, &env);
    Box { rt, remote, dir }
}

impl Box {
    fn ctl(&self) -> PathBuf {
        self.rt.server.dir.join("runtimes/box/ctl")
    }

    fn ssh(&self, args: &[&str]) -> crate::harness::Run {
        run_program(
            &self.remote.dir,
            &self.remote.bin.join("ssh"),
            &self.remote.client_env(),
            args,
            "",
            DEADLINE,
        )
    }

    fn master(&self, operation: &str) -> bool {
        let ctl = self.ctl();
        let run = self.ssh(&["-S", text_of(&ctl), "-O", operation, HOST]);
        run.exit == ko_sys::pid::Exit::Exited(0)
    }

    fn leads(&self) -> usize {
        self.remote
            .calls()
            .iter()
            .filter(|call| call.starts_with("-M "))
            .count()
    }

    fn ps(&self) -> String {
        let ps = which("ps").expect("ps");
        run_program(
            &self.remote.dir,
            &ps,
            &test_env(&self.remote.dir),
            &["-axww", "-o", "args="],
            "",
            DEADLINE,
        )
        .ok()
    }

    fn no_token_in_argv(&self, tokens: &[String]) {
        let seen = format!("{}\n{}", self.ps(), self.remote.calls().join("\n"));
        for token in tokens {
            assert!(
                !contains(seen.as_bytes(), token.as_bytes()),
                "a token is in an argv of a process or of an ssh call"
            );
        }
    }

    fn down(&self, force: bool) {
        let down = raw(
            self,
            "POST",
            "/runtimes/box/down",
            &headers(self, &[]),
            &json!({"force": force}),
        );
        assert_eq!(down.0, 200, "{}", down.1);
    }
}

fn up_pane(s: &Server, script: &str) -> String {
    rt_pane(s, "box", &format!("stty raw -echo; {script}; exec cat"))
}

fn prompting(s: &Server, panes: &[&str]) -> String {
    let mut found = None;
    poll("a pane that shows ssh's passphrase prompt", || {
        found = panes
            .iter()
            .find(|pane| s.screen(pane).contains("passphrase"))
            .map(|pane| (*pane).to_owned());
        found.is_some()
    });
    found.unwrap()
}

#[test]
fn an_ssh_pane_rides_the_master_and_a_dead_master_ends_its_panes_and_never_reconnects() {
    if !enabled("KO_E2E_HOST_SSH") {
        return;
    }
    let boxed = serve(Options::default(), &[]);
    let s: &Server = &boxed;
    let rt = &boxed.dir;
    fs::create_dir_all(rt).unwrap();
    fs::set_permissions(rt, fs::Permissions::from_mode(0o700)).unwrap();
    fs::write(rt.join("socket"), "stale").unwrap();
    fs::write(rt.join("pane_9.token"), "stale").unwrap();
    fs::write(rt.join("keep.txt"), "mine").unwrap();

    let pane = s.token_pane_with(
        json!({"runtime": "box"}),
        "ko api /version >/dev/null && printf 'API<%s,%s>' \"$KO_RUNTIME\" \"$KO_PANE\"; exec cat",
    );
    s.screen_has(&pane, &format!("API<box,{pane}>"));
    assert_eq!(boxed.leads(), 1, "{:?}", boxed.remote.calls());
    assert_eq!(state(s, "box"), "up");
    let info: Value = serde_json::from_str(&s.request("GET", "/runtimes/box", None, 200)).unwrap();
    assert_eq!(info["kind"], "ssh");
    assert!(
        fs::symlink_metadata(rt.join("socket"))
            .unwrap()
            .file_type()
            .is_socket(),
        "the stale socket file is replaced by the forward"
    );
    assert!(
        !rt.join("pane_9.token").exists(),
        "prepare removes stale token files"
    );
    assert_eq!(fs::read_to_string(rt.join("keep.txt")).unwrap(), "mine");
    assert_eq!(
        fs::metadata(rt).unwrap().permissions().mode() & 0o777,
        0o700
    );
    poll("ko enter to unlink the remote token file", || {
        !rt.join(format!("{pane}.token")).exists()
    });

    let second = s.token_pane_with(json!({"runtime": "box"}), "exec cat");
    let listing = boxed.ps();
    let mut tokens = vec![s.token(&pane).unwrap(), s.token(&second).unwrap()];
    boxed.no_token_in_argv(&tokens);
    assert!(
        listing.contains("-S "),
        "the panes run through the master: {listing}"
    );
    assert_eq!(boxed.leads(), 1, "the second pane led nothing");

    assert!(boxed.master("check"));
    assert!(boxed.master("exit"));
    for pane in [&pane, &second] {
        dead(s, pane);
    }
    let mark = boxed.remote.dir.join("ran");
    let mut ws = start_exec(
        s,
        "box",
        json!({"argv": ["/usr/bin/touch", text_of(&mark)], "stdin": false}),
    );
    let ended = read_exec(&mut ws);
    assert_eq!(ended.end["type"], "error", "{ended:?}");
    closed_with(&mut ws, 1011);
    assert!(!mark.exists(), "ssh reconnected without the master");
    wait_state(s, "box", "starting");

    let again = s.token_pane_with(
        json!({"runtime": "box"}),
        "ko api /version >/dev/null && printf 'AGAIN<%s>' \"$KO_RUNTIME\"; exec cat",
    );
    s.screen_has(&again, "AGAIN<box>");
    assert_eq!(boxed.leads(), 2, "the new pane led the new start");
    wait_state(s, "box", "up");
    tokens.push(s.token(&again).unwrap());
    boxed.no_token_in_argv(&tokens);

    // A farewell that is still running holds a new start and the removal of the directory.
    let hold = boxed.remote.dir.join("hold");
    fifo(&boxed.remote.dir, "hold");
    let calls = |what: &str| {
        boxed
            .remote
            .calls()
            .iter()
            .filter(|call| call.contains(what))
            .count()
    };
    let before = calls("-O exit");
    boxed.down(true);
    poll("the farewell to start", || calls("-O exit") == before + 1);
    assert!(!has_pane(s, &again));
    let deleted = raw(s, "DELETE", "/runtimes/box", &headers(s, &[]), &Value::Null);
    assert_eq!(deleted.0, 200, "{}", deleted.1);
    assert!(
        boxed.ctl().exists(),
        "the directory stays until the farewell ends"
    );
    release(&s.scratch, &hold, "go");
    poll("the directory to go with the farewell", || {
        !s.dir.join("runtimes/box").exists()
    });
    poll("the master to end", || !boxed.master("check"));

    // A pane that comes while a delete waits for the farewell starts after it, in the directory
    // that the delete would have removed.
    let led = boxed.leads();
    let before = calls("-O exit");
    let first = up_pane(s, "printf 'FIRST'");
    s.screen_has(&first, "FIRST");
    assert_eq!(boxed.leads(), led + 1);
    boxed.down(true);
    poll("the second farewell to start", || {
        calls("-O exit") == before + 1
    });
    let deleted = raw(s, "DELETE", "/runtimes/box", &headers(s, &[]), &Value::Null);
    assert_eq!(deleted.0, 200, "{}", deleted.1);
    let last = up_pane(
        s,
        "ko api /version >/dev/null && printf 'LAST<%s>' \"$KO_RUNTIME\"",
    );
    s.screen_has(&last, "starting runtime box");
    let seen = calls("-O check");
    stays(
        "the new start waits for the farewell",
        std::time::Duration::from_millis(300),
        || calls("-O check") == seen && !s.screen(&last).contains("LAST"),
    );
    release(&s.scratch, &hold, "go");
    s.screen_has(&last, "LAST<box>");
    assert_eq!(boxed.leads(), led + 2);
    assert!(
        boxed.ctl().exists(),
        "the delete did not take the new link's directory"
    );

    fs::remove_file(&hold).unwrap();
    boxed.down(true);
    wait_state(s, "box", "down");
    poll("the master to end", || !boxed.master("check"));
    assert!(rt.join("keep.txt").exists());
}

#[test]
fn the_leader_pane_shows_the_passphrase_prompt_and_a_closed_leader_fails_the_start() {
    if !enabled("KO_E2E_HOST_SSH") {
        return;
    }
    let boxed = serve(
        Options {
            passphrase: Some(PASSPHRASE),
            ..Options::default()
        },
        &[],
    );
    let s: &Server = &boxed;
    let script = "printf 'UP<%s>' \"$KO_RUNTIME\"";
    let (p1, p2) = (up_pane(s, script), up_pane(s, script));
    let leader = prompting(s, &[&p1, &p2]);
    let other = if leader == p1 { &p2 } else { &p1 };
    s.screen_has(other, "starting runtime box");
    assert!(!s.screen(other).contains("passphrase"));
    s.text(&leader, &format!("{PASSPHRASE}\n"));
    s.screen_has(&p1, "UP<box>");
    s.screen_has(&p2, "UP<box>");
    assert_eq!(boxed.leads(), 1);
    boxed.down(true);
    wait_state(s, "box", "down");

    let (q1, q2) = (up_pane(s, script), up_pane(s, script));
    let leader = prompting(s, &[&q1, &q2]);
    let other = if leader == q1 { &q2 } else { &q1 };
    stop_pane(s, &leader);
    s.screen_has(
        other,
        "runtime box: the leading pane ended before it reported",
    );
    dead(s, other);
    wait_state(s, "box", "failed");

    let r = up_pane(s, script);
    let leader = prompting(s, &[&r]);
    s.text(&leader, &format!("{PASSPHRASE}\n"));
    s.screen_has(&r, "UP<box>");
    assert_eq!(boxed.leads(), 3);
    boxed.down(true);
    poll("the master to end", || !boxed.master("check"));
}

#[test]
fn a_host_that_refuses_forwarding_fails_the_start_with_the_clients_text() {
    if !enabled("KO_E2E_HOST_SSH") {
        return;
    }
    let boxed = serve(
        Options {
            forwarding: Forwarding::Refused,
            ..Options::default()
        },
        &[],
    );
    let s: &Server = &boxed;
    let pane = up_pane(s, "printf 'NOT-REACHED'");
    let text = format!(
        "runtime box: {HOST} refuses unix-socket forwarding, and ko needs it (sshd AllowStreamLocalForwarding)"
    );
    dead(s, &pane);
    assert!(
        s.screen(&pane)
            .replace("\n", "")
            .contains("refuses unix-socket forwarding"),
        "{}\n{:?}",
        s.screen(&pane),
        boxed.remote.calls()
    );
    let failed = wait_state(s, "box", "failed");
    assert_eq!(
        failed["state"]["message"],
        text.strip_prefix("runtime box: ").unwrap()
    );
    assert!(!s.screen(&pane).contains("NOT-REACHED"));
    boxed.master("exit");
}

#[test]
fn an_exec_session_runs_through_a_live_master_that_the_server_adopts_and_retries_a_refused_channel()
{
    if !enabled("KO_E2E_HOST_SSH") {
        return;
    }
    let boxed = serve(
        Options {
            max_sessions: Some(2),
            send_env: true,
            ..Options::default()
        },
        &[
            ("KO_RUNTIME_IDLE_SECONDS", "0.5"),
            ("KO_RUNTIME_EXEC_WAIT_MS", "20000"),
            ("KO_STOP_ESCALATION_MS", "300"),
            ("KO_E2E_MARK", "leaked"),
        ],
    );
    let s: &Server = &boxed;
    let work = Dir::new("ko-rtw-");
    let fifos = [fifo(&work, "a"), fifo(&work, "b")];
    let request = |script: &str| json!({"argv": ["/bin/sh", "-c", script], "stdin": false});

    let mut ws = start_exec(s, "box", request("echo nope"));
    let ended = read_exec(&mut ws);
    assert_eq!(
        ended.end,
        json!({"type": "error", "message": "runtime box needs a pane to log in"})
    );
    closed_with(&mut ws, 1011);
    boxed.down(false);

    fs::create_dir_all(s.dir.join("runtimes/box")).unwrap();
    let ctl = boxed.ctl();
    let master = boxed.ssh(&[
        "-M",
        "-N",
        "-f",
        "-o",
        &format!("ControlPath={}", text_of(&ctl)),
        "-o",
        "ControlMaster=yes",
        "-o",
        "ControlPersist=yes",
        HOST,
    ]);
    assert_eq!(master.exit, ko_sys::pid::Exit::Exited(0), "{master:?}");
    let leads = boxed.leads();

    let mut ws = start_exec(
        s,
        "box",
        json!({"argv": ["/bin/sh", "-c", "cat; printf err >&2; echo \"$0|$1|$K|$KO_RUNTIME|$(pwd -P)|[$KO_E2E_MARK]\"; exit 3", "it's", "$(touch HACK)"],
               "cwd": text_of(&work), "env": {"K": "a b'c"}, "stdin": true}),
    );
    ws.send(&json!({"type": "stdin", "data": base64(b"hello")}));
    ws.send(&json!({"type": "eof"}));
    let done = read_exec(&mut ws);
    assert_eq!(done.end, json!({"type": "exit", "status": 3}), "{done:?}");
    assert_eq!(done.stderr, b"err");
    let out = String::from_utf8(done.stdout).unwrap();
    let cwd = fs::canonicalize(&*work).unwrap();
    assert_eq!(
        out,
        format!("helloit's|$(touch HACK)|a b'c|box|{}|[]\n", cwd.display()),
        "stdin, quoting, env, cwd and the status"
    );
    assert!(!work.join("HACK").exists());
    // The user's configuration sends PATH and HOME and the sshd accepts them, but the command
    // has the remote login environment.
    let mut ws = start_exec(s, "box", request("printf '%s|%s' \"$PATH\" \"$HOME\""));
    let login = read_exec(&mut ws);
    assert_eq!(login.end, json!({"type": "exit", "status": 0}), "{login:?}");
    let login = String::from_utf8(login.stdout).unwrap();
    let (path, home) = login.split_once('|').unwrap();
    assert!(
        !path.contains(text_of(&boxed.remote.bin)),
        "the server's PATH reached the command: {path}"
    );
    assert!(
        !home.is_empty() && !home.starts_with(text_of(&s.dir)),
        "the server's HOME reached the command: {home}"
    );
    assert_eq!(
        boxed.leads(),
        leads,
        "the live master was adopted: no lead step"
    );
    assert_eq!(state(s, "box"), "up");

    let mut ws = start_exec(s, "box", request("kill -USR1 $$"));
    assert_eq!(
        read_exec(&mut ws).end,
        json!({"type": "exit", "signal": "USR1"}),
        "a remote signal exit keeps its name"
    );
    let files = Dir::new("ko-rtf-");
    let ws = start_tree(s, "box", (&files, text_of(&files)));
    let group = tree_pids(&files);
    drop(ws);
    for pid in group {
        wait_gone(
            pid,
            "the session closed on a remote command that ignores HUP and TERM",
        );
    }

    let holding = |name: &str| {
        let started = work.join(format!("{name}.started"));
        let gate = work.join(name);
        request(&format!(
            "touch {}; read x < {}; echo held-{name}",
            quote(text_of(&started)),
            quote(text_of(&gate))
        ))
    };
    let mut first = start_exec(s, "box", holding("a"));
    let mut second = start_exec(s, "box", holding("b"));
    poll("two sessions on the master", || {
        work.join("a.started").exists() && work.join("b.started").exists()
    });
    let mut third = start_exec(s, "box", request("echo third"));
    let crate::harness::Message::Text(refusal) = third.read() else {
        panic!("a binary message in an exec session");
    };
    let refusal: Value = serde_json::from_str(&refusal).unwrap();
    assert_eq!(
        refusal["type"], "stderr",
        "the channel was refused before a session ended: {refusal}"
    );
    release(&s.scratch, &fifos[0], "go");
    assert_eq!(read_exec(&mut first).stdout, b"held-a\n");
    let third_done = read_exec(&mut third);
    assert_eq!(
        third_done.end,
        json!({"type": "exit", "status": 0}),
        "{third_done:?}"
    );
    assert_eq!(third_done.stdout, b"third\n");
    assert!(
        boxed
            .remote
            .calls()
            .iter()
            .filter(|call| call.contains("'enter' '--exec'"))
            .count()
            == 8,
        "seven sessions and the refused one tried again make eight exec channels: {:?}",
        boxed.remote.calls()
    );
    release(&s.scratch, &fifos[1], "go");
    assert_eq!(read_exec(&mut second).stdout, b"held-b\n");

    poll("the idle runtime to go down and end the master", || {
        state(s, "box") == "down" && !boxed.master("check")
    });
}

#[test]
fn ko_enter_prepare_makes_a_private_directory_clears_a_stale_link_and_prints_the_version() {
    let scratch = Dir::new("ko-prep-");
    let runtime_dir = scratch.join("run");
    fs::create_dir(&runtime_dir).unwrap();
    let mut env = test_env(&scratch);
    env.push(format!("XDG_RUNTIME_DIR={}", text_of(&runtime_dir)).into_bytes());
    let out = run_ko(
        &scratch,
        &env,
        &["enter", "--prepare", "--runtime", "dev"],
        "",
    )
    .ok();
    let mut lines = out.lines();
    let dir = runtime_dir.join("ko-rt/dev");
    assert_eq!(lines.next(), Some(text_of(&dir)));
    let version: Value = serde_json::from_str(lines.next().unwrap()).unwrap();
    assert_eq!(version["protocol"], "1.0");
    assert_eq!(lines.next(), None);
    assert_eq!(
        fs::metadata(&dir).unwrap().permissions().mode() & 0o777,
        0o700
    );

    fs::write(dir.join("socket"), "").unwrap();
    fs::write(dir.join("pane_1.token"), "").unwrap();
    run_ko(
        &scratch,
        &env,
        &["enter", "--prepare", "--runtime", "dev"],
        "",
    )
    .ok();
    assert_eq!(fs::read_dir(&dir).unwrap().count(), 0);

    fs::set_permissions(&dir, fs::Permissions::from_mode(0o755)).unwrap();
    let refused = run_ko(
        &scratch,
        &env,
        &["enter", "--prepare", "--runtime", "dev"],
        "",
    )
    .error(1);
    assert!(
        refused.contains("is not a private directory of this user"),
        "{refused}"
    );
    let explicit = scratch.join("chosen");
    let out = run_ko(
        &scratch,
        &env,
        &[
            "enter",
            "--prepare",
            "--runtime",
            "dev",
            "--dir",
            text_of(&explicit),
        ],
        "",
    )
    .ok();
    assert_eq!(out.lines().next(), Some(text_of(&explicit)));
}

#[test]
fn a_master_that_still_holds_the_forward_is_adopted_with_the_forward_made_again() {
    if !enabled("KO_E2E_HOST_SSH") {
        return;
    }
    let boxed = serve(Options::default(), &[]);
    let s: &Server = &boxed;
    fs::create_dir_all(&boxed.dir).unwrap();
    fs::set_permissions(&boxed.dir, fs::Permissions::from_mode(0o700)).unwrap();
    fs::create_dir_all(s.dir.join("runtimes/box")).unwrap();
    let ctl = boxed.ctl();
    let started = boxed.ssh(&[
        "-M",
        "-N",
        "-f",
        "-o",
        &format!("ControlPath={}", text_of(&ctl)),
        "-o",
        "ControlMaster=yes",
        "-o",
        "ControlPersist=yes",
        HOST,
    ]);
    assert_eq!(started.exit, ko_sys::pid::Exit::Exited(0), "{started:?}");
    let spec = format!(
        "{}:{}",
        text_of(&boxed.dir.join("socket")),
        text_of(&s.dir.join("runtimes/box/socket"))
    );
    let forwarded = boxed.ssh(&["-S", text_of(&ctl), "-O", "forward", "-R", &spec, HOST]);
    assert_eq!(
        forwarded.exit,
        ko_sys::pid::Exit::Exited(0),
        "{forwarded:?}"
    );

    let pane = s.token_pane_with(
        json!({"runtime": "box"}),
        "ko api /version >/dev/null && printf 'ADOPTED<%s>' \"$KO_RUNTIME\"; exec cat",
    );
    s.screen_has(&pane, "ADOPTED<box>");
    assert_eq!(
        boxed.leads(),
        1,
        "only the test led: {:?}",
        boxed.remote.calls()
    );
    boxed.down(true);
    poll("the master to end", || !boxed.master("check"));
}

#[test]
fn a_farewell_that_is_still_held_when_the_server_exits_still_ends_the_master() {
    if !enabled("KO_E2E_HOST_SSH") {
        return;
    }
    let mut boxed = serve(Options::default(), &[]);
    let pane = up_pane(&boxed, "printf 'UP<%s>' \"$KO_RUNTIME\"");
    boxed.screen_has(&pane, "UP<box>");
    let hold = boxed.remote.dir.join("hold");
    fifo(&boxed.remote.dir, "hold");
    boxed.down(true);
    poll("the farewell to start", || {
        boxed
            .remote
            .calls()
            .iter()
            .any(|call| call.contains("-O exit"))
    });
    assert!(boxed.master("check"), "the farewell is held");
    boxed.rt.server.stop();
    release(&boxed.rt.server.scratch, &hold, "go");
    poll("the master to end after the server", || {
        !boxed.master("check")
    });
}
