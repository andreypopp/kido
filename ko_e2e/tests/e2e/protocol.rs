use std::os::unix::net::UnixStream;

use serde_json::{Value, json};

use crate::harness::{
    Child, DEADLINE, Dir, Message, contains, decode, poll, run_ko, size, start, tagged, test_env,
    text_of, wait_gone, which,
};

#[test]
fn pane_dead_snapshot() {
    let mut s = start(&[]);
    let (mut c, _) = s.client("");
    let p = s.pane(
        "printf '\x1b]2;dead title\x07\x1b]7;file://localhost/tmp\x07\x1b[?2026hretained'; exit 7",
    );
    let (mut seen_title, mut seen_pwd) = (false, false);
    loop {
        let Message::Text(data) = c.read() else {
            panic!("event: binary");
        };
        let Some((tag, value)) = tagged(&data) else {
            panic!("event: {data}");
        };
        let value = value.to_string();
        match tag.as_str() {
            "title" => seen_title = value.contains(r#""title":"dead title""#),
            "pwd" => seen_pwd = value.contains(r#""pwd":"file://localhost/tmp""#),
            "dead" => {
                assert!(value.contains(r#""cause":["exited",7]"#), "dead: {value}");
                break;
            }
            _ => {}
        }
    }
    assert!(
        seen_title && seen_pwd,
        "missing title or pwd event: {seen_title} {seen_pwd}"
    );
    let mut v = s.ws(&format!("/panes/{p}/view?history=all"));
    let (data, _) = v.snapshot();
    let terminal = decode(&data, false);
    assert!(
        !terminal.sync && terminal.screen.contains("retained"),
        "snapshot: {}",
        terminal.screen
    );
    let screen = s.request_text("GET", &format!("/panes/{p}/screen?history=all"), None, 200);
    assert!(screen.contains("retained"), "screen: {screen:?}");
    s.request("DELETE", &format!("/panes/{p}"), None, 200);
    s.request("GET", &format!("/panes/{p}/screen"), None, 404);
}

#[test]
fn view_resume_resize_and_input() {
    let mut s = start(&[]);
    let p = s.pane("stty -echo -icanon min 1 time 0; printf '\x1b[?2004h\x1b[=3;1uREADY'; cat -v");
    let (mut c, _) = s.client(&p);
    let mut v = s.ws(&format!("/panes/{p}/view?history=all"));
    let (data, _) = v.snapshot();
    if !decode(&data, false).screen.contains("READY") {
        v.output("READY");
    }
    v.send(&json!(["input", ["paste", {"id": 23, "text": "hello\n", "check_safe": false}]]));
    let reply = v.event("pasted").to_string();
    assert!(reply.contains(r#""pasted":true"#), "paste: {reply}");
    let offset = v.output("^[[201~");
    drop(v);
    let mut v = s.ws(&format!("/panes/{p}/view?history=all&offset={offset}"));
    v.type_text("resumed\n");
    let mut resumed = Vec::new();
    while !contains(&resumed, b"resumed") {
        match v.read() {
            Message::Binary(data) if data.len() >= 9 && data[0] == 1 => {
                resumed.extend_from_slice(&data[9..]);
            }
            Message::Binary(data) => panic!("resume sent a snapshot or marker: {data:?}"),
            Message::Text(text) => panic!("resume sent a snapshot or marker: {text:?}"),
        }
    }
    c.send(&json!(["size", size(60, 20)]));
    let marker = v.event("marked").to_string();
    assert!(marker.contains(r#""cols":60"#), "marker: {marker}");
    v.send(&json!(["resync", {"history": "none", "images": "none"}]));
    let (data, _) = v.snapshot();
    assert!(!decode(&data, false).sync, "sync set");
}

#[test]
fn kill_server() {
    let mut s = start(&[]);
    let p = s.pane("trap '' HUP; printf READY; while read x; do :; done");
    let mut v = s.ws(&format!("/panes/{p}/view"));
    v.ready("READY");
    let program = s.program_pid();
    let run = s.run(&["kill-server", "--server", text_of(&s.dir)]);
    assert_eq!(run.code, 0, "kill: {} {}", run.stdout, run.stderr);
    assert!(!s.dir.join("socket").exists(), "socket after kill-server");
    wait_gone(program, "kill-server");
    s.stop();
}

#[test]
fn kill_server_signals_by_peer_pid() {
    let dir = Dir::new("ko-");
    let scratch = Dir::new("ko-run-");
    let socket = dir.join("socket");
    let script = "import os,signal,socket,sys
s=socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
s.listen()
def stop(*a):
    os.unlink(sys.argv[1])
    os._exit(0)
signal.signal(signal.SIGTERM,stop)
held=[]
while True:
    held.append(s.accept()[0])
";
    let mut child = Child::spawn(
        &which("python3").expect("python3 is not on PATH"),
        &["-I", "-c", script, text_of(&socket)],
        &test_env(&dir),
        &[],
    );
    poll("the stand-in server to listen", || {
        UnixStream::connect(&socket).is_ok()
    });
    let run = run_ko(
        &scratch,
        &test_env(&dir),
        &["kill-server", "--server", text_of(&dir)],
        "",
    );
    assert_eq!(run.code, 0, "kill: {} {}", run.stdout, run.stderr);
    // kill-server returns once kill(pid, 0) finds no process, which on macOS is after the
    // child was reaped; the reaper thread reports the exit just after.
    assert!(
        child.wait(DEADLINE).is_some(),
        "stand-in server survived kill-server"
    );
    assert!(!socket.exists(), "socket after kill-server");
}

#[test]
fn version_and_origin() {
    let mut s = start(&[]);
    let _client = s.client("");
    let scrollback = &s.limits["terminal"]["scrollback"];
    assert!(
        scrollback[0] == json!("scrollback") && scrollback[1] == json!({"max_bytes": 50000000}),
        "default scrollback limits: {}",
        s.limits
    );
    let vt = s.vt.clone();
    s.vt = "wrong".to_owned();
    s.request("GET", "/panes", None, 409);
    let (status, _) = s.exchange(
        "GET",
        "/panes",
        &vec![("Ko-Protocol".to_owned(), "2.0".to_owned())],
        b"",
    );
    assert_eq!(status, 426, "version");
    let headers = vec![
        ("Ko-Protocol".to_owned(), "1.0".to_owned()),
        ("Origin".to_owned(), "https://evil.example".to_owned()),
        ("Ko-Vt".to_owned(), vt),
    ];
    s.dial_ws("/client", Some(headers), 409);
}

#[test]
fn api() {
    let s = start(&[]);
    let ko = |dir: &std::path::Path, stdin: &str, args: &[&str]| {
        let mut argv = vec!["api", "--server", text_of(dir)];
        argv.extend_from_slice(args);
        let run = run_ko(&s.scratch, &test_env(dir), &argv, stdin);
        (run.stdout, run.stderr, run.code)
    };
    let (out, _, code) = ko(&s.dir, "", &["/version"]);
    let version: Value = serde_json::from_str(&out).unwrap_or(Value::Null);
    assert!(
        code == 0 && version["protocol"].as_str().is_some_and(|p| !p.is_empty()),
        "/version: {code} {out:?}"
    );
    let (out, _, code) = ko(&s.dir, "", &["-i", "/version"]);
    assert!(
        code == 0 && out.starts_with("HTTP/1.1 200 OK\r\n"),
        "--include: {code} {out:?}"
    );
    let (out, _, code) = ko(
        &s.dir,
        r#"{"command":["shell","exec cat"]}"#,
        &["--input", "-", "/panes"],
    );
    let created: Value = serde_json::from_str(&out).unwrap_or(Value::Null);
    let created = created["pane"].as_str().unwrap_or_default().to_owned();
    assert!(
        code == 0 && !created.is_empty(),
        "POST via stdin: {code} {out:?}"
    );
    let file = s.dir.join("body.json");
    std::fs::write(&file, r#"{"command":["shell","exec cat"]}"#).unwrap();
    let (_, _, code) = ko(
        &s.dir,
        "",
        &["-X", "POST", "--input", text_of(&file), "/panes"],
    );
    assert_eq!(code, 0, "POST via file");
    let (out, _, code) = ko(&s.dir, "", &["/panes"]);
    let rows: Value = serde_json::from_str(&out).unwrap_or(Value::Null);
    assert!(
        code == 0
            && rows.as_array().is_some_and(|rows| rows.len() == 2)
            && rows[0]["id"].as_str() == Some(created.as_str()),
        "/panes: {code} {out:?}"
    );
    let (out, errs, code) = ko(&s.dir, "", &["/nope"]);
    assert!(
        code == 1 && errs == "ko api: HTTP 404\n" && out.contains("not_found"),
        "404: {code} {out:?} {errs:?}"
    );
    for path in [
        "/client".to_owned(),
        format!("/panes/{created}/view?history=all"),
    ] {
        let (out, errs, code) = ko(&s.dir, "", &[&path]);
        assert!(
            code == 2 && out.is_empty() && errs.contains("is a WebSocket endpoint"),
            "{path}: {code} {out:?} {errs:?}"
        );
    }
    let empty = Dir::new("ko-api-");
    for dir in [empty.to_path_buf(), empty.join("absent")] {
        let (out, errs, code) = ko(&dir, "", &["/version"]);
        assert!(
            code == 1
                && out.is_empty()
                && errs == format!("ko api: no server at {}\n", dir.display()),
            "no server: {code} {out:?} {errs:?}"
        );
    }
    let entries: Vec<_> = std::fs::read_dir(&*empty).unwrap().collect();
    assert!(entries.is_empty(), "ko api created {entries:?}");
}
