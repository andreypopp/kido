use std::io::Write;
use std::time::{Duration, Instant};

use ko_sys::pid::signal_descendant;
use ko_sys::signal::Signal;
use ko_vt::Extent;
use serde_json::{Value, json};
use tungstenite::protocol::frame::coding::{Data, OpCode};
use tungstenite::protocol::frame::{Frame, FrameHeader};

use crate::harness::{
    DEADLINE, HEAVY, Hello, Message, Record, contains, decode, history_lines, size, size_request,
    start, tagged, wait_gone,
};

const SOCKET_BUFFER: usize = 1 << 20;
const FLOOD: usize = 8 * SOCKET_BUFFER;

const KEY_A: u32 = 20;
const KEY_ENTER: u32 = 58;
const MODS_NONE: u32 = 0;
const MODS_CTRL: u32 = 2;

fn key_press(key: u32, mods: u32, text: &str) -> Value {
    let unshifted = text.chars().next().map_or(0, u32::from);
    json!({"type": "input", "input": {"type": "key", "action": "press", "key": key, "mods": mods, "unshifted_codepoint": unshifted, "text": text, "composing": false}})
}

fn resync(history: &str) -> Value {
    json!({"type": "resync", "history": history, "images": "none"})
}

fn paste(id: u32, text: &str, check_safe: bool) -> Value {
    json!({"type": "input", "input": {"type": "paste", "id": id, "text": text, "check_safe": check_safe}})
}

fn history_program(record: &str) -> String {
    format!(
        "stty raw -echo; i=0; while [ $i -lt 20000 ]; do printf 'history-%05d: abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz\\r\\n' \"$i\"; i=$((i+1)); done; printf '\x1b]2;history-ready\x07\x1b[?2004hREADY'; tee '{record}'"
    )
}

#[test]
fn full_snapshot_slow_reader() {
    let _heavy = HEAVY.lock().unwrap_or_else(|e| e.into_inner());
    let s = start(&[]);
    let (mut c, _) = s.client(None);
    let p = s.pane(&history_program("/dev/null"));
    c.event("title");
    let mut v = s.ws(&format!("/panes/{p}/view?offset=1000000000000&history=all"));
    s.ko(&["api", &format!("/panes/{p}/screen")], "").ok();
    let mut snapshot = Vec::new();
    v.within(DEADLINE);
    loop {
        let Message::Binary(bytes) = v.read() else {
            panic!("snapshot record: text");
        };
        let Some(Record::Snapshot {
            last, extent, data, ..
        }) = Record::parse(&bytes)
        else {
            panic!("snapshot record: {bytes:?}");
        };
        assert_eq!(
            extent,
            Extent::Full,
            "full snapshot was downgraded to screen"
        );
        snapshot.extend_from_slice(&data);
        s.request("GET", "/version", None, 200);
        if last {
            break;
        }
    }
    assert!(
        snapshot.len() > SOCKET_BUFFER,
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
    let _heavy = HEAVY.lock().unwrap_or_else(|e| e.into_inner());
    let s = start(&[]);
    let (mut c, _) = s.client(None);
    let record = s.dir.join("input");
    let p = s.pane(&history_program(record.to_str().unwrap()));
    c.event("title");
    let mut v = s.ws(&format!("/panes/{p}/view?history=none"));
    v.ready("READY");
    let messages = [
        resync("all"),
        paste(77, "PASTE", false),
        key_press(KEY_ENTER, MODS_NONE, ""),
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
    assert!(
        matches!(Record::parse(&first), Some(Record::Snapshot { .. })),
        "resync did not start a snapshot: {first:?}"
    );
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
    let s = start(&[]);
    let (mut c, _) = s.client(None);
    let p = s.pane("trap '' HUP; printf READY; exec sleep 3000");
    let mut v = s.ws(&format!("/panes/{p}/view"));
    v.ready("READY");
    let program = s.program_pid();
    let parent = program.parent().expect("a pane process");
    v.send(&resync("all"));
    signal_descendant(s.child.pid(), parent, Signal::Kill).unwrap();
    let dead = c.event("dead");
    assert_eq!(
        dead["dead"]["cause"]["type"],
        json!("failed"),
        "failed pane: {dead}"
    );
    let removed = c.event("layout");
    assert_eq!(
        removed["layout"]["sessions"],
        json!([]),
        "the failed pane leaves the layout: {removed}"
    );
    s.ko(&["api", &format!("/panes/{p}/screen")], "")
        .http_error(404);
    s.ko(
        &["api", "--input", "-", &format!("/panes/{p}/input")],
        r#"{"type": "paste", "text": "x", "check_safe": false}"#,
    )
    .http_error(404);
    v.closed("failed pane view did not close");
    wait_gone(program, "its pane process");
}

#[test]
fn unfocused_first_client_sizes_pane() {
    let s = start(&[]);
    let p = s.pane("printf READY; cat");
    let mut unfocused = s.hello(Hello {
        kind: "terminal",
        selection: json!({"pane": p}),
        focused: false,
        size: size(51, 13),
    });
    unfocused.welcome();
    let mut v = s.ws(&format!("/panes/{p}/view?history=none"));
    let (data, _) = v.snapshot();
    let terminal = decode(&data, false);
    assert_eq!(
        terminal.rows, 13,
        "rows of a pane sized by its unfocused first client"
    );
    let (mut focused, _) = s.client(Some(&p));
    focused.send(&size_request(size(51, 9)));
    let deadline = Instant::now() + DEADLINE;
    while decode(&v.snapshot().0, false).rows != 9 {
        assert!(Instant::now() < deadline, "no snapshot with 9 rows");
    }
    drop(unfocused);
}

// A view with a snapshot still queued cannot read the resize marker that arrives after it. Another
// view's snapshot then pushes that marker out of the ring. The stalled view must still learn the new size.
#[test]
fn stalled_view_learns_resize_after_ring_retention() {
    let _heavy = HEAVY.lock().unwrap_or_else(|e| e.into_inner());
    let s = start(&[]);
    let (mut c, _) = s.client(None);
    let p = s.pane(&history_program("/dev/null"));
    c.event("title");
    let (mut sizer, _) = s.client(Some(&p));
    let mut stalled = s.ws(&format!("/panes/{p}/view?history=all"));
    let mut reader = s.ws(&format!("/panes/{p}/view?history=all"));
    reader.snapshot();
    sizer.send(&size_request(size(61, 21)));
    reader.event("marked");
    let mut flood = s.ws(&format!("/panes/{p}/view?history=all"));
    flood.snapshot();
    stalled.snapshot();
    stalled.within(Duration::from_secs(2));
    loop {
        match stalled.read() {
            Message::Binary(data) => {
                if matches!(
                    Record::parse(&data),
                    Some(Record::Snapshot { first: true, .. })
                ) {
                    return;
                }
            }
            Message::Text(text) => {
                if let Some((tag, payload)) = tagged(&text)
                    && tag == "marked"
                    && payload.to_string().contains(r#""cols":61"#)
                {
                    return;
                }
            }
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
    let s = start(&[]);
    let p = s.pane("printf READY; cat");
    let (c, welcome) = s.client(Some(&p));
    let id = welcome["client"].as_str().unwrap();
    let mut v = s
        .dial_ws(&format!("/panes/{p}/view"), Some(s.client_headers(id)), 101)
        .unwrap();
    v.snapshot();
    drop(c);
    v.closed("view survived client close");
    s.dial_ws(&format!("/panes/{p}/view"), Some(s.client_headers(id)), 410);
}

#[test]
fn stalled_view_skips() {
    let _heavy = HEAVY.lock().unwrap_or_else(|e| e.into_inner());
    let s = start(&[]);
    let (mut c, _) = s.client(None);
    let p = s.pane(&format!(
        "printf READY; IFS= read -r start; head -c {FLOOD} /dev/zero | tr '\\000' x; printf LAST"
    ));
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
    let s = start(&[]);
    let (mut c, _) = s.client(None);
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
                assert_eq!(
                    value["dead"]["cause"],
                    json!({"type": "exited", "code": 7}),
                    "dead: {text}"
                );
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
    let rows = s.ko(&["api", "/panes"], "").json();
    let at = |value: &Value| value.as_i64().unwrap_or_default();
    let (notice, marker, row) = (
        at(&notice["dead"]["at"]),
        at(&marked["marker"]["at"]),
        at(&rows[0]["dead"]["at"]),
    );
    assert_ne!(notice, 0, "death time of the event");
    assert_eq!(marker, notice, "death time of the view marker");
    assert_eq!(row, notice, "death time of the pane row");

    let mut v = s.ws(&format!("/panes/{p}/view?history=all"));
    let (data, _) = v.snapshot();
    let terminal = decode(&data, false);
    assert!(
        !terminal.sync,
        "snapshot of a dead pane has synchronized output on"
    );
    assert!(
        terminal.screen.contains("retained"),
        "snapshot: {}",
        terminal.screen
    );

    let screen = s
        .ko(&["api", &format!("/panes/{p}/screen?history=all")], "")
        .ok();
    assert!(screen.contains("retained"), "screen: {screen:?}");
    assert!(
        screen.contains("history-0\r") || screen.contains("history-0\n"),
        "screen: {screen:?}"
    );
    let screen = s
        .ko(&["api", &format!("/panes/{p}/screen?history=none")], "")
        .ok();
    assert!(screen.contains("retained"), "screen selection: {screen:?}");
    assert!(
        !screen.contains("history-0\n") && !screen.contains("history-0\r"),
        "screen selection: {screen:?}"
    );

    s.ko(&["api", "-X", "DELETE", &format!("/panes/{p}")], "")
        .ok();
    s.ko(&["api", &format!("/panes/{p}/screen")], "")
        .http_error(404);
}

#[test]
fn view_resume_resize_and_input() {
    let s = start(&[]);
    let record = s.dir.join("input");
    let p = s.pane(&format!(
        "stty raw -echo; printf '\x1b[?2004h\x1b[=3;1uREADY'; tee '{}'",
        record.display()
    ));
    let (c, _) = s.client(Some(&p));
    let mut v = s.ws(&format!("/panes/{p}/view?history=all"));
    v.ready("READY");
    v.send(&key_press(KEY_A, MODS_CTRL, "a"));
    v.type_text("FIRST");
    v.output("FIRST");
    drop(c);
    drop(v);

    let (mut c, _) = s.client(Some(&p));
    let mut v = s.ws(&format!("/panes/{p}/view?history=all"));
    v.snapshot();
    v.send(&key_press(KEY_A, MODS_CTRL, "a"));
    v.type_text("BARRIER");
    v.output("BARRIER");

    c.send(&size_request(size(62, 22)));
    let marker = v.event("marked").to_string();
    assert!(marker.contains(r#""cols":62"#), "marker: {marker}");

    v.send(&paste(23, "hello\n", false));
    v.within(DEADLINE);
    let (mut echo, mut reply) = (Vec::new(), None);
    while reply.is_none() || !contains(&echo, b"\x1b[201~") {
        match v.read() {
            Message::Binary(bytes) => {
                if let Some(Record::Output { data, .. }) = Record::parse(&bytes) {
                    echo.extend_from_slice(data);
                }
            }
            Message::Text(text) => {
                if tagged(&text).is_some_and(|(tag, _)| tag == "pasted") {
                    reply = Some(text);
                }
            }
        }
    }
    let reply = reply.expect("pasted reply");
    assert!(reply.contains(r#""pasted":true"#), "paste: {reply}");
    v.type_text("\x1b[?2004l");
    let offset = v.output("\x1b[?2004l");

    let response = s
        .ko(
            &["api", "--input", "-", &format!("/panes/{p}/input")],
            r#"{"type": "paste", "id": 41, "text": "unsafe\n", "check_safe": true}"#,
        )
        .json();
    assert_ne!(response["pasted"], json!(true), "unsafe paste: {response}");
    assert_eq!(response["unsafe"], json!(true), "unsafe paste: {response}");
    drop(v);

    let mut v = s.ws(&format!("/panes/{p}/view?history=all&offset={offset}"));
    v.type_text("resumed\n");
    let mut resumed = Vec::new();
    while !contains(&resumed, b"resumed") {
        match v.read() {
            Message::Binary(bytes) => match Record::parse(&bytes) {
                Some(Record::Output { data, .. }) => resumed.extend_from_slice(data),
                _ => panic!("resume sent a snapshot or marker: {bytes:?}"),
            },
            Message::Text(text) => panic!("resume sent a snapshot or marker: {text:?}"),
        }
    }
    let input = std::fs::read(&record).unwrap();
    assert_eq!(
        input, b"\x1b[97;5uFIRST\x1b[97;5uBARRIER\x1b[200~hello\n\x1b[201~\x1b[?2004lresumed\n",
        "pty input: {input:?}"
    );

    c.send(&size_request(size(60, 20)));
    let marker = v.event("marked").to_string();
    assert!(marker.contains(r#""cols":60"#), "marker: {marker}");
    v.send(&resync("none"));
    let (data, _) = v.snapshot();
    assert!(
        !decode(&data, false).sync,
        "snapshot after resync has synchronized output on"
    );
}
