use ko_sys::pid::signal_descendant;
use ko_sys::signal::Signal;
use serde_json::json;

use crate::harness::{DEADLINE, End, decode, start, wait_gone};

#[test]
fn live_synchronized_snapshot_and_history() {
    let s = start(&[]);
    let p = s.pane("i=0; while [ $i -lt 100 ]; do printf 'history-%s\\r\\n' $i; i=$((i+1)); done; printf '\x1b[?2026hSYNCREADY'; IFS= read -r done");
    let mut v = s.ws(&format!("/panes/{p}/view?history=all"));
    let (data, _) = v.snapshot();
    let mut terminal = decode(&data, false);
    if !terminal.screen.contains("SYNCREADY") {
        v.output("SYNCREADY");
        v.send(&json!(["resync", {"history": "all", "images": "none"}]));
        let (data, _) = v.snapshot();
        terminal = decode(&data, false);
    }
    assert!(!terminal.sync, "snapshot retains mode 2026");
    let history = s.request_text("GET", &format!("/panes/{p}/screen?history=all"), None, 200);
    let screen = s.request_text("GET", &format!("/panes/{p}/screen?history=none"), None, 200);
    assert!(
        history.contains("history-0\r") || history.contains("history-0\n"),
        "history missing: {history:?}"
    );
    assert!(
        !screen.contains("history-0\n") && screen.contains("SYNCREADY"),
        "screen selection: {screen:?}"
    );
}

#[test]
fn unsafe_paste_is_not_written() {
    let s = start(&[]);
    let record = s.dir.join("input");
    let p = s.pane(&format!(
        "stty raw -echo; printf READY; tee '{}'",
        record.display()
    ));
    let mut v = s.ws(&format!("/panes/{p}/view"));
    v.ready("READY");
    let response = s.request(
        "POST",
        &format!("/panes/{p}/input"),
        Some(&json!(["paste", {"id": 41, "text": "unsafe\n", "check_safe": true}])),
        200,
    );
    assert!(
        response["pasted"] != json!(true) && response["unsafe"] == json!(true),
        "unsafe response: {response}"
    );
    v.type_text("BARRIER");
    v.output("BARRIER");
    let input = std::fs::read(&record).unwrap();
    assert_eq!(input, b"BARRIER", "unsafe input written: {input:?}");
}

#[test]
fn sigterm_kills_programs() {
    let mut s = start(&[]);
    let p = s.pane("trap '' HUP; printf READY; while read x; do :; done");
    let mut v = s.ws(&format!("/panes/{p}/view"));
    v.ready("READY");
    let program = s.program_pid();
    s.stop();
    wait_gone(program, "shutdown");
}

#[test]
fn client_close_closes_its_views() {
    let mut s = start(&[]);
    let p = s.pane("printf READY; cat");
    let (c, id) = s.client(&p);
    let view = format!("/panes/{p}/view");
    let mut v = s.dial_ws(&view, Some(s.client_headers(&id)), 101).unwrap();
    v.snapshot();
    drop(c);
    v.within(DEADLINE);
    loop {
        match v.next() {
            Err(End::Timeout) => panic!("view survived client close"),
            Err(End::Closed) => break,
            Ok(_) => {}
        }
    }
    s.dial_ws(&view, Some(s.client_headers(&id)), 410);
}

#[test]
fn scrollback_lines_limit() {
    let s = start(&["--scrollback-lines", "100"]);
    let p = s.pane("i=0; while [ $i -lt 3000 ]; do printf 'history-%s\\r\\n' $i; i=$((i+1)); done; printf 'LIMITREADY'; IFS= read -r done");
    let mut v = s.ws(&format!("/panes/{p}/view"));
    v.ready("LIMITREADY");
    let history = s.request_text("GET", &format!("/panes/{p}/screen?history=all"), None, 200);
    assert!(
        history.contains("history-2999")
            && !history.contains("history-0\n")
            && !history.contains("history-0\r"),
        "lines limit kept {} bytes of history",
        history.len()
    );
}

#[test]
fn pane_process_crash_kills_program() {
    let s = start(&[]);
    let p = s.pane("trap '' HUP; printf READY; exec sleep 3000");
    let mut v = s.ws(&format!("/panes/{p}/view"));
    v.ready("READY");
    let program = s.program_pid();
    let pane = program.parent().expect("a pane process");
    signal_descendant(s.child.pid(), pane, Signal::Kill).unwrap();
    wait_gone(program, "its pane process");
}
