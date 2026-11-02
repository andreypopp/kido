use std::io::Write;
use std::time::{Duration, Instant};

use ko_sys::pid::signal_descendant;
use ko_sys::signal::Signal;
use serde_json::{Value, json};
use tungstenite::protocol::frame::coding::{Data, OpCode};
use tungstenite::protocol::frame::{Frame, FrameHeader};

use crate::harness::{
    DEADLINE, End, Message, contains, decode, history_lines, size, start, tagged, wait_gone,
};

fn history_program(record: &str) -> String {
    format!(
        "stty raw -echo; i=0; while [ $i -lt 20000 ]; do printf 'history-%05d: abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz\\r\\n' \"$i\"; i=$((i+1)); done; printf '\x1b]2;history-ready\x07\x1b[?2004hREADY'; tee '{record}'"
    )
}

#[test]
fn full_snapshot_slow_reader() {
    let mut s = start(&[]);
    let (mut c, _) = s.client("");
    let p = s.pane(&history_program("/dev/null"));
    c.event("title");
    let mut v = s.ws(&format!("/panes/{p}/view?offset=1000000000000&history=all"));
    s.request_text("GET", &format!("/panes/{p}/screen"), None, 200);
    let mut snapshot = Vec::new();
    v.within(DEADLINE);
    loop {
        let Message::Binary(data) = v.read() else {
            panic!("snapshot record: text");
        };
        assert!(
            data.len() >= 11 && data[0] == 2,
            "snapshot record: {data:?}"
        );
        assert_eq!(data[10], 0, "full snapshot was downgraded to screen");
        snapshot.extend_from_slice(&data[11..]);
        s.request("GET", "/version", None, 200);
        if data[9] & 2 != 0 {
            break;
        }
    }
    assert!(
        snapshot.len() > 1 << 20,
        "fixture does not exceed socket buffer: {}",
        snapshot.len()
    );
    let terminal = decode(&snapshot, true);
    assert!(
        terminal.rows >= 20000 && terminal.history.contains("history-00000:"),
        "history lost: rows={}",
        terminal.rows
    );
}

#[test]
fn paste_then_enter_during_snapshot() {
    let mut s = start(&[]);
    let (mut c, _) = s.client("");
    let record = s.dir.join("input");
    let p = s.pane(&history_program(record.to_str().unwrap()));
    c.event("title");
    let mut v = s.ws(&format!("/panes/{p}/view?history=none"));
    v.ready("READY");
    let messages = [
        json!(["resync", {"history": "all", "images": "none"}]),
        json!(["input", ["paste", {"id": 77, "text": "PASTE", "check_safe": false}]]),
        json!(["input", ["key", {"action": "press", "key": 58, "mods": 0, "unshifted_codepoint": 0, "text": "", "composing": false}]]),
    ];
    let frames: Vec<Vec<u8>> = messages
        .iter()
        .map(|message| masked_frame(message.to_string().as_bytes()))
        .collect();
    let batch = frames.concat();
    let cut = frames[0].len() + 3;
    v.raw().write_all(&batch[..cut]).unwrap();
    let Message::Binary(first) = v.read() else {
        panic!("snapshot record: text");
    };
    assert_eq!(first[0], 2, "resync did not start a snapshot: {first:?}");
    v.raw().write_all(&batch[cut..]).unwrap();
    v.type_text("BARRIER");
    v.output("BARRIER");
    let input = std::fs::read(&record).unwrap();
    assert_eq!(
        input, b"\x1b[200~PASTE\x1b[201~\rBARRIER",
        "input order: {input:?}"
    );
}

#[test]
fn pane_process_failure() {
    let mut s = start(&[]);
    let (mut c, _) = s.client("");
    let p = s.pane("trap '' HUP; printf READY; exec sleep 3000");
    let mut v = s.ws(&format!("/panes/{p}/view"));
    v.ready("READY");
    let program = s.program_pid();
    let parent = program.parent().expect("a pane process");
    v.send(&json!(["resync", {"history": "all", "images": "none"}]));
    signal_descendant(s.child.pid(), parent, Signal::Kill).unwrap();
    let dead = c.event("dead").to_string();
    assert!(
        dead.contains(r#""cause":["failed","#),
        "failed pane: {dead}"
    );
    s.request_text("GET", &format!("/panes/{p}/screen"), None, 500);
    s.request(
        "POST",
        &format!("/panes/{p}/input"),
        Some(&json!(["paste", {"text": "x", "check_safe": false}])),
        500,
    );
    v.within(DEADLINE);
    loop {
        match v.next() {
            Err(End::Timeout) => panic!("failed pane view did not close"),
            Err(End::Closed) => break,
            Ok(_) => {}
        }
    }
    wait_gone(program, "its pane process");
}

#[test]
fn unfocused_first_client_sizes_pane() {
    let mut s = start(&[]);
    let p = s.pane("printf READY; cat");
    let mut c = s.ws("/client");
    c.send(&json!(["hello", {"kind": "terminal", "name": "unfocused", "focused": false, "pane": p, "size": size(51, 13)}]));
    c.event("welcome");
    c.event("topology");
    let mut v = s.ws(&format!("/panes/{p}/view?history=none"));
    let (data, _) = v.snapshot();
    let terminal = decode(&data, false);
    assert_eq!(terminal.rows, 13, "unfocused sizing");
    let (mut focused, _) = s.client(&p);
    focused.send(&json!(["size", size(51, 9)]));
    let deadline = Instant::now() + DEADLINE;
    while decode(&v.snapshot().0, false).rows != 9 {
        assert!(Instant::now() < deadline, "no snapshot with 9 rows");
    }
}

// A view with a snapshot still queued cannot read the resize marker that arrives after it. Another
// view's snapshot then pushes that marker out of the ring. The stalled view must still learn the new size.
#[test]
fn stalled_view_learns_resize_after_ring_retention() {
    let mut s = start(&[]);
    let (mut c, _) = s.client("");
    let p = s.pane(&history_program("/dev/null"));
    c.event("title");
    let (mut sizer, _) = s.client(&p);
    let view = format!("/panes/{p}/view?history=all");
    let mut stalled = s.ws(&view);
    let mut reader = s.ws(&view);
    reader.snapshot();
    sizer.send(&json!(["size", size(61, 21)]));
    reader.event("marked");
    let mut flood = s.ws(&view);
    flood.snapshot();
    stalled.snapshot();
    stalled.within(Duration::from_secs(2));
    loop {
        match stalled.read() {
            Message::Binary(data) if data.len() >= 11 && data[0] == 2 && data[9] & 1 != 0 => {
                return;
            }
            Message::Text(text) => {
                if let Some((tag, payload)) = tagged(&text)
                    && tag == "marked"
                    && payload.to_string().contains(r#""cols":61"#)
                {
                    return;
                }
            }
            Message::Binary(_) => {}
        }
    }
}

fn masked_frame(payload: &[u8]) -> Vec<u8> {
    let header = FrameHeader {
        opcode: OpCode::Data(Data::Text),
        mask: Some([1, 2, 3, 4]),
        ..FrameHeader::default()
    };
    let mut out = Vec::new();
    Frame::from_payload(header, payload.to_vec().into())
        .format(&mut out)
        .unwrap();
    out
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
fn stalled_view_skips() {
    let mut s = start(&[]);
    let (mut c, _) = s.client("");
    let p = s.pane(
        "printf READY; IFS= read -r start; head -c 8388608 /dev/zero | tr '\\000' x; printf LAST",
    );
    let mut v = s.ws(&format!("/panes/{p}/view"));
    v.ready("READY");
    s.text(&p, "\n");
    c.event("dead");
    v.event("skipped");
    let (data, _) = v.snapshot();
    assert!(
        decode(&data, false).screen.contains("LAST"),
        "skip snapshot is not current"
    );
}

#[test]
fn pane_dead_snapshot() {
    let mut s = start(&[]);
    let (mut c, _) = s.client("");
    let p = s.pane(&format!(
        "{}; printf READY; IFS= read -r go; printf '\x1b]2;dead title\x07\x1b]7;file://localhost/tmp\x07\x1b[?2026hretained'; exit 7",
        history_lines(100)
    ));
    let mut live = s.ws(&format!("/panes/{p}/view?history=all"));
    live.ready("READY");
    s.text(&p, "\n");
    let (mut seen_title, mut seen_pwd) = (false, false);
    let notice = loop {
        let Message::Text(data) = c.read() else {
            panic!("event: binary");
        };
        let Some((tag, value)) = tagged(&data) else {
            panic!("event: {data}");
        };
        let text = value.to_string();
        match tag.as_str() {
            "title" => seen_title = text.contains(r#""title":"dead title""#),
            "pwd" => seen_pwd = text.contains(r#""pwd":"file://localhost/tmp""#),
            "dead" => {
                assert!(text.contains(r#""cause":["exited",7]"#), "dead: {text}");
                break value;
            }
            _ => {}
        }
    };
    assert!(
        seen_title && seen_pwd,
        "missing title or pwd event: {seen_title} {seen_pwd}"
    );
    let marked = live.event("marked");
    let rows = s.request("GET", "/panes", None, 200);
    let at = |value: &Value| value.as_i64().unwrap_or_default();
    let (notice, marker, row) = (
        at(&notice["dead"]["at"]),
        at(&marked["marker"][1]["at"]),
        at(&rows[0]["dead"]["at"]),
    );
    assert!(
        notice != 0 && notice == marker && notice == row,
        "death times differ: event {notice}, view marker {marker}, row {row}"
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
    assert!(
        screen.contains("retained")
            && (screen.contains("history-0\r") || screen.contains("history-0\n")),
        "screen: {screen:?}"
    );
    let screen = s.request_text("GET", &format!("/panes/{p}/screen?history=none"), None, 200);
    assert!(
        !screen.contains("history-0\n")
            && !screen.contains("history-0\r")
            && screen.contains("retained"),
        "screen selection: {screen:?}"
    );
    s.request("DELETE", &format!("/panes/{p}"), None, 200);
    s.request("GET", &format!("/panes/{p}/screen"), None, 404);
}

#[test]
fn view_resume_resize_and_input() {
    let mut s = start(&[]);
    let record = s.dir.join("input");
    let p = s.pane(&format!(
        "stty raw -echo; printf '\x1b[?2004h\x1b[=3;1uREADY'; tee '{}'",
        record.display()
    ));
    let (c, _) = s.client(&p);
    let view = format!("/panes/{p}/view?history=all");
    let mut v = s.ws(&view);
    v.ready("READY");
    let key = json!(["input", ["key", {"action": "press", "key": 20, "mods": 2, "unshifted_codepoint": 97, "text": "a", "composing": false}]]);
    v.send(&key);
    v.type_text("FIRST");
    v.output("FIRST");
    drop(c);
    drop(v);
    let (mut c, _) = s.client(&p);
    let mut v = s.ws(&view);
    v.snapshot();
    v.send(&key);
    v.type_text("BARRIER");
    v.output("BARRIER");
    c.send(&json!(["size", size(62, 22)]));
    let marker = v.event("marked").to_string();
    assert!(marker.contains(r#""cols":62"#), "marker: {marker}");
    v.send(&json!(["input", ["paste", {"id": 23, "text": "hello\n", "check_safe": false}]]));
    let reply = v.event("pasted").to_string();
    assert!(reply.contains(r#""pasted":true"#), "paste: {reply}");
    v.output("\x1b[201~");
    v.type_text("\x1b[?2004l");
    let offset = v.output("\x1b[?2004l");
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
    let input = std::fs::read(&record).unwrap();
    assert_eq!(
        input, b"\x1b[97;5uFIRST\x1b[97;5uBARRIER\x1b[200~hello\n\x1b[201~\x1b[?2004lresumed\n",
        "pty input: {input:?}"
    );
    c.send(&json!(["size", size(60, 20)]));
    let marker = v.event("marked").to_string();
    assert!(marker.contains(r#""cols":60"#), "marker: {marker}");
    v.send(&json!(["resync", {"history": "none", "images": "none"}]));
    let (data, _) = v.snapshot();
    assert!(!decode(&data, false).sync, "sync set");
}
