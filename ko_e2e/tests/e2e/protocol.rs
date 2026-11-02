use std::os::unix::net::UnixStream;

use serde_json::json;

use crate::harness::{
    Child, DEADLINE, Dir, PROTOCOL, poll, run_ko, start, test_env, text_of, wait_gone, which,
};

#[test]
fn kill_server() {
    let s = start(&[]);
    let p = s.pane("trap '' HUP; printf READY; while read x; do :; done");
    let mut v = s.ws(&format!("/panes/{p}/view"));
    v.ready("READY");
    let program = s.program_pid();
    assert_eq!(s.ko(&["kill-server"], "").ok(), "");
    assert!(!s.dir.join("socket").exists(), "socket after kill-server");
    wait_gone(program, "kill-server");
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
    assert_eq!(run.ok(), "");
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
    let (_client, welcome) = s.client(None);
    let scrollback = &welcome["limits"]["terminal"]["scrollback"];
    assert_eq!(
        scrollback["type"],
        json!("scrollback"),
        "limits: {}",
        welcome["limits"]
    );
    assert_eq!(
        scrollback,
        &json!({"type": "scrollback", "max_bytes": 50000000})
    );
    let vt = s.vt.replace("wrong".to_owned()).unwrap();
    s.request("GET", "/panes", None, 409);
    let (status, body) = s.exchange(
        "GET",
        "/panes",
        &vec![("Ko-Protocol".to_owned(), "0.9".to_owned())],
        b"",
    );
    assert_eq!(status, 426, "unsupported protocol version");
    let refusal: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(
        refusal["kind"],
        json!("protocol_mismatch"),
        "refusal: {refusal}"
    );
    let headers = vec![
        ("Ko-Protocol".to_owned(), PROTOCOL.to_owned()),
        ("Origin".to_owned(), "https://evil.example".to_owned()),
        ("Ko-Vt".to_owned(), vt),
    ];
    s.dial_ws("/client", Some(headers), 409);
}

#[test]
fn api() {
    let s = start(&[]);

    let version = s.ko(&["api", "/version"], "").json();
    assert!(
        version["protocol"].as_str().is_some_and(|p| !p.is_empty()),
        "/version: {version}"
    );
    let included = s.ko(&["api", "-i", "/version"], "").ok();
    assert!(
        included.starts_with("HTTP/1.1 200 OK\r\n"),
        "--include: {included:?}"
    );

    let layout = |revision: u64, session: &str| {
        json!({"revision": revision, "layout": {"sessions": [{"name": session, "windows": [
            {"name": "w", "tree": {"pane": {"new": {"command":
                {"type": "shell", "command": "exec cat"}}}}}]}]}})
        .to_string()
    };
    let put = s
        .ko(
            &["api", "-X", "PUT", "--input", "-", "/layout"],
            &layout(0, "one"),
        )
        .json();
    let created = put["layout"]["sessions"][0]["windows"][0]["tree"]["pane"]
        .as_str()
        .unwrap_or_default()
        .to_owned();
    assert_eq!(created, "pane_1", "PUT via stdin: {put}");
    let file = s.dir.join("body.json");
    let mut document = s.ko(&["api", "/layout"], "").json();
    document["layout"]["sessions"][0]["windows"][0]["tree"] = json!({"split": "h", "children": [
        {"pane": created}, {"pane": {"new": {"command": {"type": "shell", "command": "exec cat"}}}}]});
    std::fs::write(&file, document.to_string()).unwrap();
    s.ko(
        &["api", "-X", "put", "--input", text_of(&file), "/layout"],
        "",
    )
    .ok();
    std::fs::write(&file, r#"{"type":"text","data":"aGk="}"#).unwrap();
    s.ko(
        &[
            "api",
            "--input",
            text_of(&file),
            &format!("/panes/{created}/input"),
        ],
        "",
    )
    .ok();
    let rows = s.ko(&["api", "/panes"], "").json();
    assert_eq!(rows.as_array().map(Vec::len), Some(2), "/panes: {rows}");
    assert_eq!(rows[0]["id"].as_str(), Some(created.as_str()));

    assert_eq!(
        s.ko(&["api", "/nope"], "").http_error(404),
        r#"{"kind":"not_found","message":"resource not found"}"#
    );

    for path in [
        "/client".to_owned(),
        format!("/panes/{created}/view?history=all"),
    ] {
        let error = s.ko(&["api", &path], "").error(2);
        assert!(
            error.contains("is a WebSocket endpoint"),
            "{path}: {error:?}"
        );
    }

    let empty = Dir::new("ko-api-");
    for dir in [empty.to_path_buf(), empty.join("absent")] {
        let run = run_ko(
            &s.scratch,
            &test_env(&dir),
            &["api", "/version", "--server", text_of(&dir)],
            "",
        );
        assert_eq!(
            run.error(1),
            format!("ko api: no server at {}\n", dir.display())
        );
    }
    let entries: Vec<_> = std::fs::read_dir(&*empty).unwrap().collect();
    assert!(entries.is_empty(), "ko api created {entries:?}");
}
