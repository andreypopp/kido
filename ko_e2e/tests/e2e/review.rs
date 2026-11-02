use std::io::Write;
use std::time::Duration;

use ko_sys::pid::signal_descendant;
use ko_sys::signal::Signal;
use serde_json::{Value, json};

use crate::harness::{
    DEADLINE, End, Message, base64, contains, decode, masked_frame, size, start, tagged,
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
    let batch: Vec<u8> = messages
        .iter()
        .flat_map(|message| masked_frame(message.to_string().as_bytes()))
        .collect();
    v.raw().write_all(&batch).unwrap();
    v.type_text("BARRIER");
    v.ready("BARRIER");
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
    let p = s.pane("printf READY; cat");
    let mut v = s.ws(&format!("/panes/{p}/view"));
    v.ready("READY");
    let pid = s
        .pane_pids()
        .into_iter()
        .find(|(id, _)| *id == p)
        .map(|(_, pid)| pid)
        .unwrap_or_default();
    let program = ko_sys::pid::Pid::new(pid).expect("a program pid");
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
}

#[test]
fn unfocused_first_client_sizes_pane() {
    let s = start(&[]);
    let p = s.pane("printf READY; cat");
    let mut c = s.ws("/client");
    c.send(&json!(["hello", {"kind": "terminal", "name": "unfocused", "focused": false, "pane": p, "size": size(51, 13)}]));
    c.event("welcome");
    c.event("topology");
    let mut v = s.ws(&format!("/panes/{p}/view"));
    let (data, _) = v.snapshot();
    let terminal = decode(&data, false);
    assert_eq!(terminal.rows, 13, "unfocused sizing");
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

#[test]
fn resume_skips_resize_markers_before_the_offset() {
    let mut s = start(&[]);
    let p = s.pane("stty -echo -icanon min 1 time 0; printf READY; cat -v");
    let (mut c, _) = s.client(&p);
    let mut v = s.ws(&format!("/panes/{p}/view?history=all"));
    v.ready("READY");
    c.send(&json!(["size", size(62, 22)]));
    v.event("marked");
    v.type_text("later\n");
    let offset = v.output("later");
    drop(v);
    let mut v = s.ws(&format!("/panes/{p}/view?history=all&offset={offset}"));
    v.type_text("after\n");
    let mut text = Vec::new();
    while !contains(&text, b"after") {
        match v.read() {
            Message::Binary(data) if data.len() >= 9 && data[0] == 1 => {
                text.extend_from_slice(&data[9..]);
            }
            Message::Text(data) => {
                panic!("resume replayed a message from before its offset: {data}")
            }
            Message::Binary(data) => panic!("unexpected record on resume: {data:?}"),
        }
    }
}

#[test]
fn death_has_one_timestamp() {
    let mut s = start(&[]);
    let (mut c, _) = s.client("");
    let p = s.pane("printf READY; IFS= read -r go; exit 7");
    let mut v = s.ws(&format!("/panes/{p}/view?history=all"));
    v.ready("READY");
    s.request(
        "POST",
        &format!("/panes/{p}/input"),
        Some(&json!(["text", base64(b"\n")])),
        200,
    );
    let notice = c.event("dead");
    let marked = v.event("marked");
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
}
