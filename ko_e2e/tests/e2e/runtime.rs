use std::fs;
use std::ops::Deref;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::Duration;

use ko_sys::pid::Pid;
use serde_json::{Value, json};

use crate::harness::{
    DEADLINE, Dir, Message, PRINT_TOKEN, Server, Ws, base64, poll, quote, run_ko, run_program, sh,
    start_in, start_with, stays, test_env, text_of, wait_gone,
};
use crate::panes::{as_pane, headers, post, raw, raw_on, refuses, token_pane_in_new_session};
use crate::runs::{has_pane, ids};

pub(crate) struct Rt {
    pub(crate) server: Server,
    pub(crate) config: Dir,
}

impl Deref for Rt {
    type Target = Server;

    fn deref(&self) -> &Server {
        &self.server
    }
}

fn serve(runtimes: &Value, env: &[(&str, &str)]) -> Rt {
    serve_in(Dir::new("ko-"), runtimes, env)
}

impl Rt {
    fn rewrite(&self, runtimes: &Value) {
        fs::write(
            self.config.join("runtimes.json"),
            json!({"runtimes": runtimes}).to_string(),
        )
        .unwrap();
    }
}

pub(crate) fn serve_in(dir: Dir, runtimes: &Value, env: &[(&str, &str)]) -> Rt {
    let config = Dir::new("ko-rtc-");
    let file = config.join("runtimes.json");
    fs::write(&file, json!({"runtimes": runtimes}).to_string()).unwrap();
    let mut env = env.to_vec();
    env.push(("KO_RUNTIME_COMMAND_KIND", "1"));
    let server = start_in(
        dir,
        Path::new("/bin/sh"),
        &env,
        &["--runtimes", text_of(&file)],
    );
    Rt { server, config }
}

fn sh_run(scratch: &Path, script: &str) {
    run_program(
        scratch,
        Path::new("/bin/sh"),
        &[],
        &["-c", script],
        "",
        DEADLINE,
    )
    .ok();
}

fn fifos(dir: &Path, names: &[String]) -> Vec<PathBuf> {
    let paths: Vec<PathBuf> = names.iter().map(|name| dir.join(name)).collect();
    let args: Vec<&str> = paths.iter().map(|path| text_of(path)).collect();
    run_program(dir, Path::new("/usr/bin/mkfifo"), &[], &args, "", DEADLINE).ok();
    paths
}

pub(crate) fn fifo(dir: &Path, name: &str) -> PathBuf {
    fifos(dir, &[name.to_owned()]).remove(0)
}

pub(crate) fn release(scratch: &Path, fifo: &Path, text: &str) {
    sh_run(
        scratch,
        &format!("printf '%s\\n' {} > {}", quote(text), quote(text_of(fifo))),
    );
}

pub(crate) fn rt_pane(s: &Server, runtime: &str, script: &str) -> String {
    s.new_pane(sh_in(runtime, script))
}

pub(crate) fn sh_in(runtime: &str, script: &str) -> Value {
    let mut request = sh(script);
    request["runtime"] = json!(runtime);
    request
}

fn rt_token_pane(s: &Server, runtime: &str) -> String {
    s.token_pane_with(json!({"runtime": runtime}), "exec cat")
}

pub(crate) fn info(s: &Server, runtime: &str) -> Value {
    serde_json::from_str(&s.request("GET", &format!("/runtimes/{runtime}"), None, 200)).unwrap()
}

pub(crate) fn state(s: &Server, runtime: &str) -> String {
    info(s, runtime)["state"]["type"]
        .as_str()
        .unwrap()
        .to_owned()
}

pub(crate) fn wait_state(s: &Server, runtime: &str, want: &str) -> Value {
    let mut last = Value::Null;
    poll(&format!("runtime {runtime} to be {want}"), || {
        last = info(s, runtime);
        last["state"]["type"] == want
    });
    last
}

fn via(
    s: &Server,
    runtime: &str,
    route: (&str, &str),
    who: Option<(&str, &str)>,
    body: &Value,
) -> (u16, Value) {
    let socket = s.dir.join("runtimes").join(runtime).join("socket");
    let extra: Vec<(&str, &str)> = who
        .map(|(pane, token)| vec![("Ko-Pane", pane), ("Ko-Pane-Token", token)])
        .unwrap_or_default();
    raw_on(s, &socket, route, &headers(s, &extra), body)
}

pub(crate) fn dead(s: &Server, pane: &str) -> Value {
    s.wait_row(pane, &format!("{pane} to end"), |row| {
        !row["dead"].is_null()
    })
}

pub(crate) fn stop_pane(s: &Server, pane: &str) {
    post(s, None, &format!("/panes/{pane}/stop"), &json!({}));
}

#[test]
fn a_runtime_pane_runs_through_the_wrapper_and_its_token_file_is_private_and_used_once() {
    let files = Dir::new("ko-rtf-");
    let gate = fifo(&files, "gate");
    let wait = format!("read x < {}; exec \"$@\"", quote(text_of(&gate)));
    let s = serve(
        &json!({"dev": {"kind": "command", "prefix": ["/bin/sh", "-c", wait, "sh"]}}),
        &[],
    );

    let script = format!("stty raw -echo; {PRINT_TOKEN}; exec cat");
    let pane = rt_pane(&s, "dev", &script);
    let file = s
        .dir
        .join("runtimes/dev/panes")
        .join(format!("{pane}.token"));
    poll("the token file", || file.exists());
    let mode = |path: &Path| fs::metadata(path).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode(&file), 0o600);
    assert_eq!(mode(file.parent().unwrap()), 0o700);
    assert_eq!(mode(&s.dir.join("runtimes/dev")), 0o755);
    assert_eq!(mode(&s.dir.join("runtimes/dev/socket")), 0o666);
    let written = fs::read_to_string(&file).unwrap();
    assert_eq!(written.len(), 32);
    let row = s.row(&pane);
    assert_eq!(row["runtime"], "dev");
    assert_eq!(
        row["command"],
        json!(["/bin/sh", "-c", script]),
        "the row records the command that was asked for, not the wrapper"
    );
    assert!(
        !row["command"].to_string().contains(&written),
        "the token is in no argv: {row}"
    );

    release(&s.scratch, &gate, "go");
    s.screen_has(&pane, "TOKEN<");
    assert_eq!(s.token(&pane).as_deref(), Some(written.as_str()));
    poll("ko enter to unlink the token file", || !file.exists());

    let second = rt_pane(&s, "dev", "exec cat");
    let second_file = s
        .dir
        .join("runtimes/dev/panes")
        .join(format!("{second}.token"));
    poll("the second token file", || second_file.exists());
    stop_pane(&s, &second);
    poll("the token file to go with its pane", || {
        !second_file.exists()
    });

    let listing = s.ko(&["panes"], "").ok();
    let header = listing.lines().next().unwrap();
    assert!(header.contains("RUNTIME"), "{listing}");
    let line_of = |pane: &str| {
        listing
            .lines()
            .find(|line| line.starts_with(pane))
            .unwrap()
            .to_owned()
    };
    assert!(line_of(&pane).contains("dev"), "{listing}");
    let host = s.pane("exec cat");
    let again = s.ko(&["panes"], "").ok();
    let host_line = again.lines().find(|line| line.starts_with(&host)).unwrap();
    assert!(
        host_line.split_whitespace().nth(3) == Some("-"),
        "a host pane has no runtime: {again}"
    );
}

#[test]
fn a_runtime_connection_acts_as_a_pane_of_its_runtime_and_sees_only_its_scope() {
    let maps = Dir::new("ko-rtm-");
    fs::create_dir_all(maps.join("host/sub")).unwrap();
    fs::create_dir_all(maps.join("rt/sub")).unwrap();
    let s = serve(
        &json!({
            "dev": {
                "kind": "command",
                "env": {"RT_VAR": "runtime", "BOTH": "runtime"},
                "cwd": "/",
                "paths": [{"host": text_of(&maps.join("host")), "runtime": text_of(&maps.join("rt"))}],
            },
            "other": {"kind": "command", "pi": "runtime"},
        }),
        &[],
    );
    let (dev, other) = (info(&s, "dev"), info(&s, "other"));
    assert_eq!((&dev["pi"], &dev["cwd"]), (&json!("host"), &json!("/")));
    assert_eq!((&other["pi"], other.get("cwd")), (&json!("runtime"), None));
    let host = s.token_pane("exec cat");
    let elsewhere = token_pane_in_new_session(&s, "elsewhere");
    let r1 = rt_token_pane(&s, "dev");
    let r2 = rt_token_pane(&s, "other");
    let t1 = s.token(&r1).unwrap();
    let who = Some((r1.as_str(), t1.as_str()));
    let cat = json!({"type": "shell", "command": "exec cat"});
    let forged = "0123456789abcdef0123456789abcdef";
    let host_token = s.token(&host).unwrap();
    let other_token = s.token(&r2).unwrap();

    let read = |path: &str, who| via(&s, "dev", ("GET", path), who, &Value::Null);
    refuses(
        read("/panes", None),
        "a runtime connection must act as one of its panes",
    );
    refuses(
        read("/panes", Some((&r1, forged))),
        "Ko-Pane-Token does not match Ko-Pane",
    );
    refuses(
        read("/panes", Some((&host, &host_token))),
        "must act as one of its panes",
    );
    refuses(
        read("/panes", Some((&r2, &other_token))),
        "must act as one of its panes",
    );
    for path in [
        "/client",
        &format!("/panes/{r1}/view"),
        &format!("/panes/{r1}/search?needle=x"),
    ] {
        let socket = s.dir.join("runtimes/dev/socket");
        let mut sent = s.headers();
        sent.push(("Ko-Pane".to_owned(), r1.clone()));
        sent.push(("Ko-Pane-Token".to_owned(), t1.clone()));
        s.dial_ws_on(&socket, path, Some(sent), 409);
    }
    refuses(
        via(
            &s,
            "dev",
            ("PUT", "/layout"),
            who,
            &json!({"revision": 0, "layout": {"sessions": []}}),
        ),
        "not available on a runtime connection",
    );
    for path in ["/runtimes", "/runtimes/dev", "/runtimes/dev/wait"] {
        refuses(read(path, who), "not available on a runtime connection");
    }
    refuses(
        read("/runtimes/dev/exec", who),
        "not available on a runtime connection",
    );

    let made = |reply: (u16, Value)| {
        assert_eq!(reply.0, 200, "{}", reply.1);
        reply.1["pane"].as_str().unwrap().to_owned()
    };
    let inherited = made(via(
        &s,
        "dev",
        ("POST", "/panes"),
        who,
        &json!({"command": cat}),
    ));
    assert_eq!(
        s.row(&inherited)["runtime"],
        "dev",
        "no runtime: the connection's own"
    );
    let named = made(via(
        &s,
        "dev",
        ("POST", "/panes"),
        who,
        &json!({"command": cat, "runtime": "dev", "parent": r1}),
    ));
    assert_eq!(s.row(&named)["parent"], r1.as_str());
    refuses(
        via(
            &s,
            "dev",
            ("POST", "/panes"),
            who,
            &json!({"command": cat, "runtime": "other"}),
        ),
        "creates panes in dev, not in other",
    );
    refuses(
        via(
            &s,
            "dev",
            ("POST", "/panes"),
            who,
            &json!({"command": cat, "parent": host}),
        ),
        "may name only itself",
    );
    let run = via(
        &s,
        "dev",
        ("POST", "/runs"),
        who,
        &json!({"name": "job", "argv": ["/bin/sh", "-c", "exec cat"]}),
    );
    assert_eq!(run.0, 200, "{}", run.1);
    assert_eq!(s.row(run.1["pane"].as_str().unwrap())["runtime"], "dev");
    let own_run = run.1["id"].as_str().unwrap().to_owned();
    let host_run = post(
        &s,
        None,
        "/runs",
        &json!({"name": "hostjob", "argv": ["/bin/sh", "-c", "exec cat"], "session": "test"}),
    )["id"]
        .as_str()
        .unwrap()
        .to_owned();
    for id in [&own_run, &host_run] {
        post(
            &s,
            None,
            &format!("/runs/{id}/stop"),
            &json!({"result": "stopped"}),
        );
    }
    assert_eq!(
        via(
            &s,
            "dev",
            ("GET", &format!("/runs/{own_run}")),
            who,
            &Value::Null
        )
        .0,
        200,
        "the runtime's own finished run stays readable"
    );
    for path in [
        format!("/runs/{host_run}"),
        format!("/runs/{host_run}/screen"),
    ] {
        refuses(
            via(&s, "dev", ("GET", &path), who, &Value::Null),
            "is not visible to",
        );
    }
    let (_, listed) = via(&s, "dev", ("GET", "/runs?show=all"), who, &Value::Null);
    let listed: Vec<&str> = listed
        .as_array()
        .unwrap()
        .iter()
        .map(|info| info["id"].as_str().unwrap())
        .collect();
    assert!(
        listed.contains(&own_run.as_str()) && !listed.contains(&host_run.as_str()),
        "a finished host run is hidden from a runtime caller: {listed:?}"
    );

    let from_user = post(
        &s,
        None,
        "/panes",
        &json!({"command": cat, "runtime": "other"}),
    );
    assert_eq!(
        s.row(from_user["pane"].as_str().unwrap())["runtime"],
        "other"
    );
    let child_command =
        json!({"type": "shell", "command": format!("stty raw -echo; {PRINT_TOKEN}; exec cat")});
    let child = {
        let reply = raw(
            &s,
            "POST",
            "/panes",
            &as_pane(&s, &host),
            &json!({"command": child_command, "runtime": "dev", "parent": host}),
        );
        assert_eq!(reply.0, 200, "{}", reply.1);
        reply.1["pane"].as_str().unwrap().to_owned()
    };
    assert_eq!(s.row(&child)["runtime"], "dev");
    assert_eq!(
        s.row(&child)["parent"],
        host.as_str(),
        "a host pane parents a runtime child"
    );
    s.screen_has(&child, "TOKEN<");
    let child_token = s.token(&child).unwrap();
    let as_child = Some((child.as_str(), child_token.as_str()));

    let (status, listing) = read("/panes", as_child);
    assert_eq!(status, 200);
    let seen = ids(&listing);
    assert!(
        seen.contains(&host.as_str()),
        "the parent is in the scope: {seen:?}"
    );
    assert!(
        seen.contains(&r1.as_str()) && seen.contains(&child.as_str()),
        "the runtime's panes: {seen:?}"
    );
    assert!(
        !seen.contains(&elsewhere.as_str()),
        "a pane of another session is hidden: {seen:?}"
    );
    let (_, layout) = read("/layout", as_child);
    assert_eq!(
        ids(&layout["panes"]),
        seen,
        "the layout names the same rows"
    );
    assert!(
        layout["layout"]["sessions"].as_array().unwrap().len() >= 2,
        "the document is whole: {layout}"
    );
    assert_eq!(read(&format!("/panes/{host}"), as_child).0, 200);
    refuses(
        read(&format!("/panes/{elsewhere}"), as_child),
        "is not visible to",
    );
    assert_eq!(read(&format!("/panes/{r1}/screen"), as_child).0, 200);
    refuses(
        read(&format!("/panes/{host}/screen"), as_child),
        "is not visible to",
    );
    refuses(
        read(&format!("/panes/{elsewhere}/screen"), as_child),
        "is not visible to",
    );
    let typed = json!({"type": "text", "data": base64(b"hi")});
    assert_eq!(
        via(
            &s,
            "dev",
            ("POST", &format!("/panes/{r1}/input")),
            as_child,
            &typed
        )
        .0,
        200
    );
    refuses(
        via(
            &s,
            "dev",
            ("POST", &format!("/panes/{elsewhere}/input")),
            as_child,
            &typed,
        ),
        "is not visible to",
    );

    let mapped = |cwd: Option<&str>, env: Value| {
        let script =
            "pwd -P; echo \"V=$RT_VAR/$BOTH/$REQ/$KO_RUNTIME\"; echo \"S=$KO_SOCKET\"; exec cat";
        let mut request = sh_in("dev", script);
        request["env"] = env;
        if let Some(cwd) = cwd {
            request["cwd"] = json!(cwd);
        }
        let pane = post(&s, None, "/panes", &request)["pane"]
            .as_str()
            .unwrap()
            .to_owned();
        s.screen_has(&pane, "S=");
        s.screen(&pane)
    };
    let canon = |path: PathBuf| {
        fs::canonicalize(path)
            .unwrap()
            .to_string_lossy()
            .into_owned()
    };
    let env = json!([{"name": "BOTH", "value": "request"}, {"name": "REQ", "value": "1"}]);
    let screen = mapped(Some(text_of(&maps.join("host/sub"))), env.clone());
    assert!(
        screen.contains(&canon(maps.join("rt/sub"))),
        "the host cwd maps: {screen}"
    );
    assert!(screen.contains("V=runtime/request/1/dev"), "{screen}");
    let socket = s.dir.join("runtimes/dev/socket");
    assert!(
        screen.contains(&format!("S={}", socket.display())),
        "{screen}"
    );
    let unmapped = mapped(None, json!([]));
    assert!(
        unmapped.lines().next().unwrap().trim() == "/",
        "the runtime's cwd: {unmapped}"
    );
    let passes = made(via(&s, "dev", ("POST", "/panes"), who, &{
        let mut request = sh("pwd -P; exec cat");
        request["cwd"] = json!(text_of(&maps.join("host")));
        request
    }));
    s.screen_has(&passes, &canon(maps.join("host")));

    // A parent in the host and its child in the runtime exchange messages through their own
    // sockets, and the child reads the output of its own child only.
    let child_creds = headers(&s, &[("Ko-Pane", &child), ("Ko-Pane-Token", &child_token)]);
    let runtime_socket = s.dir.join("runtimes/dev/socket");
    let message =
        |text: &str| json!({"id": format!("msg-{text}"), "kind": "message", "text": text});
    let up = via(
        &s,
        "dev",
        ("POST", &format!("/panes/{host}/messages")),
        as_child,
        &message("upward"),
    );
    assert_eq!(
        (up.0, up.1["state"].as_str()),
        (200, Some("queued")),
        "{}",
        up.1
    );
    let down = raw(
        &s,
        "POST",
        &format!("/panes/{child}/messages"),
        &as_pane(&s, &host),
        &message("downward"),
    );
    assert_eq!(
        (down.0, down.1["state"].as_str()),
        (200, Some("queued")),
        "{}",
        down.1
    );
    let mut parent_stream = s
        .dial_ws(
            &format!("/panes/{host}/messages"),
            Some(as_pane(&s, &host)),
            101,
        )
        .unwrap();
    parent_stream.within(DEADLINE);
    let received = |stream: &mut Ws| {
        stream.within(DEADLINE);
        let Message::Text(text) = stream.read() else {
            panic!("a message is text");
        };
        serde_json::from_str::<Value>(&text).unwrap()
    };
    let arrived = received(&mut parent_stream);
    assert_eq!(
        (arrived["text"].as_str(), arrived["from"]["pane"].as_str()),
        (Some("upward"), Some(child.as_str())),
        "the child's message reached its host parent"
    );
    let mut child_stream = s
        .dial_ws_on(
            &runtime_socket,
            &format!("/panes/{child}/messages"),
            Some(child_creds.clone()),
            101,
        )
        .unwrap();
    assert_eq!(
        received(&mut child_stream)["text"],
        "downward",
        "the parent's message reached its child through the runtime socket"
    );
    s.dial_ws_on(
        &runtime_socket,
        &format!("/panes/{host}/messages"),
        Some(child_creds.clone()),
        409,
    );

    let grandchild = made(via(
        &s,
        "dev",
        ("POST", "/panes"),
        as_child,
        &json!({"command": cat, "parent": child}),
    ));
    let creds = || Some(child_creds.clone());
    drop(s.dial_ws_on(
        &runtime_socket,
        &format!("/panes/{grandchild}/output"),
        creds(),
        101,
    ));
    s.dial_ws_on(
        &runtime_socket,
        &format!("/panes/{host}/output"),
        creds(),
        409,
    );

    let agent = s.new_pane(json!({
        "command": {"type": "shell", "command": format!(
            "printf '\\033]7501;state=idle:app=pi\\007'; stty raw -echo; {PRINT_TOKEN}; exec cat"
        )},
    }));
    s.wait_row(&agent, "its pi root", |row| {
        row["status"]["program_status"]["records"]
            .as_array()
            .is_some_and(|records| !records.is_empty())
    });
    let candidates = via(
        &s,
        "dev",
        ("GET", &format!("/prompt/resolve?from={child}")),
        as_child,
        &Value::Null,
    );
    assert_eq!(candidates.0, 200, "{}", candidates.1);
    assert!(
        candidates
            .1
            .as_array()
            .unwrap()
            .iter()
            .any(|c| c["pane"] == agent.as_str()),
        "the host agent is a candidate: {}",
        candidates.1
    );
    refuses(
        via(
            &s,
            "dev",
            ("POST", "/prompt"),
            as_child,
            &json!({"from": child, "id": "prompt-0001", "target": agent, "text": "hello"}),
        ),
        "would get a paste",
    );
}

#[test]
fn the_first_pane_starts_a_runtime_and_a_failed_start_ends_it_with_its_message_and_retries() {
    let files = Dir::new("ko-rtf-");
    let up = fifo(&files, "up");
    let lead = fifo(&files, "lead");
    let log = files.join("lead.log");
    let s = serve(
        &json!({
            "gate": {"kind": "command", "up": [
                "/bin/sh", "-c",
                format!("read code < {}; echo boom >&2; exit $code", quote(text_of(&up))),
            ]},
            "lead": {"kind": "command", "lead": [
                "/bin/sh", "-c",
                format!(
                    "echo led >> {}; read code < {}; [ $code = 0 ] || echo denied >&2; exit $code",
                    quote(text_of(&log)),
                    quote(text_of(&lead)),
                ),
            ]},
        }),
        &[],
    );
    let lines = || fs::read_to_string(&log).map_or(0, |text| text.lines().count());

    let first = rt_pane(&s, "gate", "echo ran; exec cat");
    s.screen_has(&first, "starting runtime gate");
    assert_eq!(state(&s, "gate"), "starting");
    release(&s.scratch, &up, "3");
    s.screen_has(&first, "runtime gate: boom");
    let row = dead(&s, &first);
    assert_eq!(row["dead"]["cause"]["code"], 1, "{row}");
    assert!(!s.screen(&first).contains("ran"), "{}", s.screen(&first));
    let failed = wait_state(&s, "gate", "failed");
    assert_eq!(failed["state"]["message"], "boom");

    let retry = rt_pane(&s, "gate", "echo ran; exec cat");
    s.screen_has(&retry, "starting runtime gate");
    assert_eq!(
        state(&s, "gate"),
        "starting",
        "the next pane starts the runtime again"
    );
    release(&s.scratch, &up, "0");
    s.screen_has(&retry, "ran");
    wait_state(&s, "gate", "up");

    let (p1, p2) = (
        rt_pane(&s, "lead", "echo up-$KO_RUNTIME; exec cat"),
        rt_pane(&s, "lead", "echo up-$KO_RUNTIME; exec cat"),
    );
    poll("the lead step to start", || lines() == 1);
    s.screen_has(&p1, "starting runtime lead");
    s.screen_has(&p2, "starting runtime lead");
    release(&s.scratch, &lead, "7");
    for pane in [&p1, &p2] {
        s.screen_has(pane, "runtime lead: denied");
        dead(&s, pane);
    }
    assert_eq!(
        wait_state(&s, "lead", "failed")["state"]["message"],
        "denied"
    );
    assert_eq!(lines(), 1, "one leader for two first panes");

    let (p3, p4) = (
        rt_pane(&s, "lead", "echo up-$KO_RUNTIME; exec cat"),
        rt_pane(&s, "lead", "echo up-$KO_RUNTIME; exec cat"),
    );
    poll("the new leader", || lines() == 2);
    release(&s.scratch, &lead, "0");
    s.screen_has(&p3, "up-lead");
    s.screen_has(&p4, "up-lead");
    assert_eq!(lines(), 2, "the retry elected one leader again");
    assert_eq!(info(&s, "lead")["panes"], 4);

    refuses(
        raw(
            &s,
            "POST",
            "/runtimes/lead/down",
            &headers(&s, &[]),
            &json!({}),
        ),
        "has live panes",
    );
    assert_eq!(state(&s, "lead"), "up");
    let forced = raw(
        &s,
        "POST",
        "/runtimes/lead/down",
        &headers(&s, &[]),
        &json!({"force": true}),
    );
    assert_eq!(forced.0, 200, "{}", forced.1);
    let after = wait_state(&s, "lead", "down");
    assert_eq!(after["panes"], 2, "the dead rows stay: {after}");
    assert!(
        !has_pane(&s, &p3) && !has_pane(&s, &p4),
        "the live panes were removed"
    );
    assert!(!s.dir.join("runtimes/lead/socket").exists());

    let leader = rt_pane(&s, "lead", "exec cat");
    poll("a third leader", || lines() == 3);
    stop_pane(&s, &leader);
    let ended = wait_state(&s, "lead", "failed");
    assert!(
        ended["state"]["message"]
            .as_str()
            .unwrap()
            .contains("the leading pane ended before"),
        "{ended}"
    );

    let deleted = raw(
        &s,
        "DELETE",
        "/runtimes/lead",
        &headers(&s, &[]),
        &Value::Null,
    );
    assert_eq!(deleted.0, 200, "{}", deleted.1);
    assert!(!s.dir.join("runtimes/lead").exists());
}

#[test]
fn an_idle_runtime_goes_down_unless_a_pane_or_an_exec_session_holds_it() {
    let s = serve(
        &json!({"kept": {"kind": "command"}, "idle": {"kind": "command"}, "busy": {"kind": "command"}}),
        &[("KO_RUNTIME_IDLE_SECONDS", "0.3")],
    );
    let files = Dir::new("ko-rtf-");
    let gate = fifo(&files, "gate");
    let mut ws = s.ws("/runtimes/busy/exec");
    ws.send(&json!({
        "type": "exec", "stdin": false,
        "argv": ["/bin/sh", "-c", format!("read x < {}", quote(text_of(&gate)))],
    }));
    wait_state(&s, "busy", "up");
    let dying = rt_pane(&s, "kept", "exit 0");
    dead(&s, &dying);
    let pane = rt_pane(&s, "idle", "exec cat");
    wait_state(&s, "idle", "up");
    stop_pane(&s, &pane);
    wait_state(&s, "idle", "down");
    assert!(!s.dir.join("runtimes/idle/socket").exists());
    assert_eq!(
        state(&s, "kept"),
        "up",
        "a dead row still counts as a pane of the runtime"
    );
    assert_eq!(
        state(&s, "busy"),
        "up",
        "an exec session holds its runtime like a pane"
    );
    release(&s.scratch, &gate, "go");
    ws.within(DEADLINE);
    assert_eq!(read_exec(&mut ws).end, json!({"type": "exit", "status": 0}));
    wait_state(&s, "busy", "down");
}

#[test]
fn a_retry_after_a_failed_start_reads_the_configuration_again() {
    let s = serve(
        &json!({"fix": {"kind": "command", "up": ["/bin/sh", "-c", "echo broken >&2; exit 3"]}}),
        &[],
    );
    let first = rt_pane(&s, "fix", "exec cat");
    s.screen_has(&first, "runtime fix: broken");
    wait_state(&s, "fix", "failed");

    s.rewrite(&json!({"fix": {"kind": "command", "up": ["/bin/sh", "-c", "exit 0"]}}));
    let second = rt_pane(&s, "fix", "echo fixed; exec cat");
    s.screen_has(&second, "fixed");
    wait_state(&s, "fix", "up");
}

#[test]
fn a_configuration_that_cannot_be_used_fails_the_runtime_requests_and_not_the_server() {
    let dir = Dir::new("ko-rtc-");
    let file = dir.join("runtimes.json");
    let s = start_with(Path::new("/bin/sh"), &[], &["--runtimes", text_of(&file)]);
    let get = |path: &str| raw(&s, "GET", path, &headers(&s, &[]), &Value::Null);
    let created = |runtime: &str| {
        raw(
            &s,
            "POST",
            "/panes",
            &headers(&s, &[]),
            &json!({"runtime": runtime, "command": {"type": "shell", "command": "exec cat"}}),
        )
    };
    assert_eq!(
        get("/runtimes"),
        (200, json!([])),
        "a missing file is an empty configuration"
    );
    let (status, body) = get("/runtimes/dev");
    assert_eq!((status, body["kind"].as_str()), (404, Some("not_found")));
    assert!(
        body["message"]
            .as_str()
            .unwrap()
            .contains(&format!("no runtime dev in {}", file.display())),
        "{body}"
    );

    fs::write(&file, r#"{"runtimes":{"dev":{"kind":"command"}}}"#).unwrap();
    let (status, body) = get("/runtimes");
    assert_eq!((status, body["kind"].as_str()), (400, Some("invalid")));
    assert!(
        body["message"]
            .as_str()
            .unwrap()
            .contains("runtime dev: kind: command is a test kind"),
        "without the knob a command runtime is an error that names the runtime and the field: {body}"
    );
    assert_eq!(created("dev").0, 400);
    assert!(s.rows().is_empty(), "the request that failed made no pane");

    fs::write(&file, "{\"runtimes\": {\n  \"dev\": [").unwrap();
    let (status, body) = get("/runtimes");
    assert_eq!((status, body["kind"].as_str()), (400, Some("invalid")));
    let message = body["message"].as_str().unwrap();
    assert!(
        message.contains("line 2 column"),
        "the serde position: {message}"
    );
    s.request("GET", "/version", None, 200);
}

#[test]
fn a_runtime_socket_path_over_the_limit_fails_the_start_with_advice() {
    let long = Dir::new(&"x".repeat(64));
    let socket = long.join("socket").as_os_str().len();
    let runtime = long.join("runtimes/dev/socket").as_os_str().len();
    assert!(socket <= 103 && runtime > 103, "{socket} {runtime}");
    let s = serve_in(long, &json!({"dev": {"kind": "command"}}), &[]);
    let pane = rt_pane(&s, "dev", "exec cat");
    let message = "runtime socket path exceeds 103 bytes; set KO_STATE_DIR to a shorter path";
    s.screen_has(&pane, "runtime dev: runtime socket path exceeds 103 bytes;");
    let failed = wait_state(&s, "dev", "failed");
    assert_eq!(failed["state"]["message"], message);
}

#[test]
fn ko_enter_needs_a_private_token_and_a_directory_and_a_runtime_refuses_the_terminal_client() {
    let scratch = Dir::new("ko-rte-");
    let env = test_env(&scratch);
    let enter = |extra: &[&str]| {
        let mut args = vec![
            "enter",
            "--socket",
            "/nonexistent/socket",
            "--pane",
            "pane_1",
            "--runtime",
            "dev",
        ];
        args.extend_from_slice(extra);
        run_ko(&scratch, &env, &args, "")
    };
    let token = "0123456789abcdef0123456789abcdef";
    let private = scratch.join("private");
    fs::write(&private, token).unwrap();
    fs::set_permissions(&private, fs::Permissions::from_mode(0o600)).unwrap();
    let open = scratch.join("open");
    fs::write(&open, token).unwrap();
    fs::set_permissions(&open, fs::Permissions::from_mode(0o644)).unwrap();

    assert_eq!(
        enter(&["--token-file", text_of(&scratch.join("missing"))]).error(1),
        "ko enter: no token\n"
    );
    assert_eq!(
        enter(&["--token-file", text_of(&open)]).error(1),
        "ko enter: no token\n"
    );
    assert!(!open.exists(), "even a refused token file is removed");
    assert_eq!(
        enter(&[]).error(1),
        "ko enter: no token\n",
        "without a file the token is in the environment"
    );
    let message = enter(&[
        "--token-file",
        text_of(&private),
        "--cwd",
        "/nonexistent/dir",
    ])
    .error(1);
    assert_eq!(
        message,
        "ko enter: cwd /nonexistent/dir: No such file or directory\n"
    );
    assert!(
        !private.exists(),
        "ko enter unlinks the token file when it reads it"
    );

    let mut inside = env.clone();
    inside.push(b"KO_RUNTIME=dev".to_vec());
    let refused = run_ko(&scratch, &inside, &[], "").error(1);
    assert_eq!(refused, "ko: inside runtime dev; attach from the host\n");
}

#[derive(Debug, Default)]
pub(crate) struct Exec {
    pub(crate) stdout: Vec<u8>,
    pub(crate) stderr: Vec<u8>,
    pub(crate) end: Value,
}

pub(crate) fn decode(value: &Value) -> Vec<u8> {
    ko_pane_wire::base64::decode(value["data"].as_str().unwrap()).unwrap()
}

pub(crate) fn read_exec(ws: &mut crate::harness::Ws) -> Exec {
    let mut exec = Exec::default();
    loop {
        let crate::harness::Message::Text(text) = ws.read() else {
            panic!("a binary message in an exec session");
        };
        let message: Value = serde_json::from_str(&text).unwrap();
        match message["type"].as_str().unwrap() {
            "stdout" => exec.stdout.extend(decode(&message)),
            "stderr" => exec.stderr.extend(decode(&message)),
            _ => {
                exec.end = message;
                return exec;
            }
        }
    }
}

pub(crate) fn start_exec(s: &Server, runtime: &str, request: Value) -> crate::harness::Ws {
    let mut ws = s.ws(&format!("/runtimes/{runtime}/exec"));
    let mut message = request;
    message["type"] = json!("exec");
    ws.send(&message);
    ws
}

pub(crate) fn closed_with(ws: &mut crate::harness::Ws, code: u16) {
    ws.closed("the session to close");
    assert_eq!(ws.close_frame().map(|frame| frame.0), Some(code));
}

fn pid_of(file: &Path) -> Pid {
    poll("the pid file", || {
        fs::read_to_string(file).is_ok_and(|text| text.trim().parse::<i64>().is_ok())
    });
    Pid::new(fs::read_to_string(file).unwrap().trim().parse().unwrap()).unwrap()
}

#[test]
fn an_exec_session_runs_a_command_with_split_output_stdin_signals_and_an_exit() {
    let files = Dir::new("ko-rtf-");
    let work = Dir::new("ko-rtw-");
    let s = serve(
        &json!({
            "dev": {"kind": "command", "env": {"RT_VAR": "runtime", "BOTH": "runtime", "PATH": "/usr/bin:/bin"}, "cwd": text_of(&work)},
            "login": {"kind": "command", "lead": ["/bin/sh", "-c", "exit 0"]},
            "broken": {"kind": "command", "up": ["/bin/sh", "-c", "echo nope >&2; exit 4"]},
        }),
        &[
            ("KO_VIEW_QUEUE_BYTES", "262144"),
            ("KO_STOP_ESCALATION_MS", "300"),
        ],
    );
    let script = |script: &str| json!({"argv": ["/bin/sh", "-c", script], "stdin": false});

    let mut ws = start_exec(&s, "dev", script("printf out; printf err >&2; exit 3"));
    let done = read_exec(&mut ws);
    assert_eq!(
        (done.stdout, done.stderr, done.end),
        (
            b"out".to_vec(),
            b"err".to_vec(),
            json!({"type": "exit", "status": 3})
        )
    );
    closed_with(&mut ws, 1000);

    let mut ws = start_exec(&s, "dev", json!({"argv": ["/bin/cat"], "stdin": true}));
    ws.send(&json!({"type": "stdin", "data": base64(b"hello ")}));
    ws.send(&json!({"type": "stdin", "data": base64(b"world")}));
    ws.send(&json!({"type": "eof"}));
    let done = read_exec(&mut ws);
    assert_eq!(
        (done.stdout, done.end),
        (
            b"hello world".to_vec(),
            json!({"type": "exit", "status": 0})
        )
    );

    let mut ws = start_exec(
        &s,
        "dev",
        json!({
            "argv": ["/usr/bin/env"], "stdin": false,
            "cwd": text_of(&files),
            "env": {"BOTH": "request", "REQ": "1"},
        }),
    );
    let done = read_exec(&mut ws);
    let mut lines: Vec<String> = String::from_utf8(done.stdout)
        .unwrap()
        .lines()
        .map(str::to_owned)
        .collect();
    lines.sort();
    assert_eq!(
        lines,
        [
            "BOTH=request",
            "KO_RUNTIME=dev",
            "PATH=/usr/bin:/bin",
            "REQ=1",
            "RT_VAR=runtime"
        ],
        "the runtime's env, then the request's, then KO_RUNTIME; nothing of the server's"
    );
    let mut ws = start_exec(&s, "dev", script("pwd -P"));
    let here = String::from_utf8(read_exec(&mut ws).stdout).unwrap();
    assert_eq!(
        here.trim(),
        fs::canonicalize(&*work).unwrap().to_str().unwrap(),
        "the runtime's cwd"
    );
    let mut ws = start_exec(
        &s,
        "dev",
        json!({"argv": ["/bin/sh", "-c", "pwd -P"], "stdin": false, "cwd": text_of(&files)}),
    );
    let there = String::from_utf8(read_exec(&mut ws).stdout).unwrap();
    assert_eq!(
        there.trim(),
        fs::canonicalize(&*files).unwrap().to_str().unwrap(),
        "the request's cwd"
    );
    let mut ws = start_exec(&s, "dev", script("exit 9"));
    assert_eq!(read_exec(&mut ws).end, json!({"type": "exit", "status": 9}));

    let pid_file = files.join("signal.pid");
    let mut ws = start_exec(
        &s,
        "dev",
        script(&format!(
            "echo $$ > {}; exec sleep 60",
            quote(text_of(&pid_file))
        )),
    );
    pid_of(&pid_file);
    ws.send(&json!({"type": "signal", "signal": "term"}));
    assert_eq!(
        read_exec(&mut ws).end,
        json!({"type": "exit", "signal": "TERM"})
    );

    let bad = [
        (
            json!({"type": "stdin", "data": ""}),
            "the first message must be exec",
        ),
        (
            json!({"type": "exec", "argv": [], "stdin": false}),
            "argv needs a program",
        ),
    ];
    for (message, why) in bad {
        let mut ws = s.ws("/runtimes/dev/exec");
        ws.send(&message);
        let end = read_exec(&mut ws).end;
        assert_eq!(end["type"], "error");
        assert!(end["message"].as_str().unwrap().contains(why), "{end}");
        closed_with(&mut ws, 1011);
    }
    let mut ws = start_exec(
        &s,
        "dev",
        json!({"argv": ["no-such-program-ko"], "stdin": false}),
    );
    let end = read_exec(&mut ws).end;
    assert!(
        end["message"]
            .as_str()
            .unwrap()
            .contains("command not found"),
        "{end}"
    );

    let mut ws = start_exec(&s, "login", script("true"));
    let end = read_exec(&mut ws).end;
    assert_eq!(
        end,
        json!({"type": "error", "message": "runtime login needs a pane to log in"})
    );
    closed_with(&mut ws, 1011);
    let mut ws = start_exec(&s, "broken", script("true"));
    assert_eq!(
        read_exec(&mut ws).end,
        json!({"type": "error", "message": "nope"})
    );
    refused_exec(&s, &work);

    let ignoring = files.join("ignore.pid");
    let ending = files.join("end.pid");
    let ws = start_exec(
        &s,
        "dev",
        script(&format!(
            "echo $$ > {}; exec sleep 60",
            quote(text_of(&ending))
        )),
    );
    let cut = pid_of(&ending);
    drop(ws);
    wait_gone(cut, "the socket closed");
    let ws = start_exec(
        &s,
        "dev",
        script(&format!(
            "trap '' TERM; echo $$ > {}; while :; do sleep 0.1; done",
            quote(text_of(&ignoring))
        )),
    );
    let stubborn = pid_of(&ignoring);
    drop(ws);
    wait_gone(stubborn, "the escalation to SIGKILL");
}

fn refused_exec(s: &Server, _work: &Path) {
    let r = rt_token_pane(s, "dev");
    let token = s.token(&r).unwrap();
    refuses(
        via(
            s,
            "dev",
            ("GET", "/runtimes/dev/exec"),
            Some((&r, &token)),
            &Value::Null,
        ),
        "not available on a runtime connection",
    );
}

#[test]
fn an_exec_session_reads_its_output_in_order_and_stops_the_command_while_the_reader_is_slow() {
    let files = Dir::new("ko-rtf-");
    let mark = files.join("done");
    let s = serve(
        &json!({"dev": {"kind": "command"}}),
        &[("KO_VIEW_QUEUE_BYTES", "262144")],
    );
    let lines = 600_000;
    let script = format!(
        "awk 'BEGIN {{ for (i = 0; i < {lines}; i++) printf \"%010d\\n\", i }}'; : > {}",
        quote(text_of(&mark))
    );
    let mut ws = start_exec(
        &s,
        "dev",
        json!({"argv": ["/bin/sh", "-c", script], "stdin": false}),
    );
    stays(
        "the command blocks while nothing reads",
        Duration::from_millis(400),
        || !mark.exists(),
    );
    ws.within(Duration::from_secs(20));
    let done = read_exec(&mut ws);
    assert_eq!(done.end, json!({"type": "exit", "status": 0}));
    let expected: String = (0..lines).map(|i| format!("{i:010}\n")).collect();
    assert!(
        done.stdout == expected.as_bytes(),
        "nothing is lost or reordered"
    );
    assert!(mark.exists());
}

#[test]
fn at_most_32_exec_sessions_of_a_runtime_run_and_the_others_wait_in_order_then_give_up() {
    let files = Dir::new("ko-rtf-");
    let names: Vec<String> = (0..=34).map(|i| format!("gate-{i}")).collect();
    let gates = fifos(&files, &names);
    let started = files.join("started");
    fs::create_dir(&started).unwrap();
    let s = serve(
        &json!({"dev": {"kind": "command"}}),
        &[("KO_RUNTIME_EXEC_WAIT_MS", "1500")],
    );
    let session = |index: usize| {
        let script = format!(
            "echo up > {}; read x < {}",
            quote(text_of(&started.join(index.to_string()))),
            quote(text_of(&gates[index]))
        );
        start_exec(
            &s,
            "dev",
            json!({"argv": ["/bin/sh", "-c", script], "stdin": false}),
        )
    };
    let mut sessions: Vec<_> = (0..32).map(session).collect();
    poll("32 sessions to run", || {
        (0..32).all(|index| started.join(index.to_string()).exists())
    });
    let mut waiting = session(32);
    stays("the 33rd session waits", Duration::from_millis(250), || {
        !started.join("32").exists()
    });
    release(&s.scratch, &gates[0], "go");
    let first = sessions.remove(0);
    let mut first = first;
    first.within(DEADLINE);
    assert_eq!(
        read_exec(&mut first).end,
        json!({"type": "exit", "status": 0})
    );
    poll("the 33rd session to start when one ends", || {
        started.join("32").exists()
    });

    let mut late = session(0);
    late.within(Duration::from_secs(5));
    let end = read_exec(&mut late).end;
    assert_eq!(end["type"], "error");
    assert!(
        end["message"]
            .as_str()
            .unwrap()
            .contains("no exec slot of runtime dev within 1500 ms"),
        "{end}"
    );
    closed_with(&mut late, 1011);
    release(&s.scratch, &gates[32], "go");
    waiting.within(DEADLINE);
    assert_eq!(
        read_exec(&mut waiting).end,
        json!({"type": "exit", "status": 0})
    );

    let filler = session(34);
    poll("the filler to run", || started.join("34").exists());
    let mut queued = session(33);
    let down = raw(
        &s,
        "POST",
        "/runtimes/dev/down",
        &headers(&s, &[]),
        &json!({"force": true}),
    );
    assert_eq!(down.0, 200, "{}", down.1);
    queued.within(DEADLINE);
    let end = read_exec(&mut queued).end;
    assert_eq!(end["type"], "error");
    assert!(
        end["message"].as_str().unwrap().contains("went down"),
        "{end}"
    );
    assert!(
        !started.join("33").exists(),
        "a forced down starts none of the queued sessions"
    );
    drop(filler);
}

#[test]
fn a_start_step_that_ignores_sigterm_is_killed_when_the_server_exits() {
    let files = Dir::new("ko-rtf-");
    let pidfile = files.join("pid");
    let script = format!(
        "echo $$ > {}; trap '' TERM; exec sleep 60",
        quote(text_of(&pidfile))
    );
    let mut s = serve(
        &json!({"dev": {"kind": "command", "up": ["/bin/sh", "-c", script]}}),
        &[],
    );
    rt_pane(&s, "dev", "exec cat");
    let step = pid_of(&pidfile);
    s.server.stop();
    wait_gone(step, "the start step that ignores SIGTERM");
}
