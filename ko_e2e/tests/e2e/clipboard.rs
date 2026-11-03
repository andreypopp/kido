use std::path::Path;

use serde_json::{Value, json};

use crate::harness::{
    Message, Server, Ws, base64, poll, quote, start, start_with, tagged, text_of,
};
use crate::outer::{Keys, Outer};

const EMPTY: &str = "\x1b]52;c;\x1b\\";

// A pane that sends one OSC 52 read after a newline and records whatever the pty gives it.
fn reading_pane(s: &Server, record: &Path) -> String {
    let pane = s.pane(&format!(
        "stty raw -echo; printf READY; read line; printf '\\033]52;c;?\\007'; exec cat > {}",
        quote(text_of(record))
    ));
    s.screen_has(&pane, "READY");
    pane
}

fn recorded(record: &Path) -> String {
    String::from_utf8_lossy(&std::fs::read(record).unwrap_or_default()).into_owned()
}

fn reply_of(text: &str) -> String {
    format!("\x1b]52;c;{}\x1b\\", base64(text.as_bytes()))
}

fn answer(id: &Value, text: &str) -> Value {
    json!({"type": "clipboard_answer", "id": id, "contents": [{"mime": "text/plain", "data": base64(text.as_bytes())}]})
}

// Everything the server sent before its reply to a request that it answers in order.
fn tags_until(ws: &mut Ws, last: &str) -> Vec<String> {
    ws.within(crate::harness::DEADLINE);
    let mut tags = Vec::new();
    loop {
        let Message::Text(text) = ws.read() else {
            continue;
        };
        let Some((tag, _)) = tagged(&text) else {
            continue;
        };
        tags.push(tag.clone());
        if tag == last {
            return tags;
        }
    }
}

#[test]
fn one_clipboard_read_gets_exactly_one_answer_with_two_clients() {
    let s = start(&[]);
    let record = s.dir.join("answers");
    let pane = reading_pane(&s, &record);
    let (mut focused, _) = s.app_client(json!({"pane": pane}), true, (80, 24));
    let (mut other, _) = s.app_client(json!({"pane": pane}), false, (80, 24));
    s.text(&pane, "\n");

    let read = focused.event("clipboard_read");
    assert_eq!(read["pane"], json!(pane));
    assert_eq!(read["location"], "standard");
    assert_eq!(read["mimes"], json!(["text/plain"]));

    // The client without the focus answers first, and the server has dealt with that answer
    // when it replies to the next request of the same client.
    other.send(&answer(&read["id"], "from-the-other"));
    other.send(&json!({"type": "select", "pane": pane}));
    let seen = tags_until(&mut other, "selected");
    assert!(
        !seen.iter().any(|tag| tag == "clipboard_read"),
        "the other client was asked: {seen:?}"
    );
    focused.send(&answer(&read["id"], "from-the-focus"));
    focused.send(&answer(&read["id"], "from-the-focus-again"));

    s.text(&pane, "BARRIER");
    poll("the barrier in the pane", || {
        recorded(&record).ends_with("BARRIER")
    });
    assert_eq!(
        recorded(&record),
        format!("{}BARRIER", reply_of("from-the-focus"))
    );
}

#[test]
fn an_unanswered_read_ends_at_the_timer_with_an_empty_clipboard() {
    let s = start_with(
        Path::new("/bin/sh"),
        &[("KO_CLIPBOARD_TIMEOUT_MS", "300")],
        &[],
    );
    let record = s.dir.join("answers");
    let pane = reading_pane(&s, &record);
    let (mut silent, _) = s.app_client(json!({"pane": pane}), true, (80, 24));
    s.text(&pane, "\n");
    silent.event("clipboard_read");
    poll("the timer to end the read", || recorded(&record) == EMPTY);
    s.text(&pane, "BARRIER");
    poll("the barrier in the pane", || {
        recorded(&record).ends_with("BARRIER")
    });
    assert_eq!(recorded(&record), format!("{EMPTY}BARRIER"));
}

#[test]
fn a_read_for_a_pane_that_no_client_shows_is_refused_at_once() {
    let s = start(&[]);
    let record = s.dir.join("answers");
    let pane = reading_pane(&s, &record);
    s.text(&pane, "\n");
    poll("the refusal, long before the 8 s timer", || {
        recorded(&record) == EMPTY
    });
}

#[test]
fn an_osc_52_write_of_a_pane_reaches_the_outer_terminal() {
    let s = start(&[]);
    let pane = s.pane(
        "stty raw -echo; printf READY; read line; printf '\\033]52;c;aGVsbG8=\\007'; exec cat",
    );
    let o = Outer::new(&s.dir, Keys::Extended);
    o.attach("");
    o.contains("READY");
    s.text(&pane, "\n");
    o.wait("the OSC 52 write on the outer terminal", || {
        o.clipboard() == b"hello"
    });
    let raw = o.output();
    let sent = b"\x1b]52;c;aGVsbG8=\x1b\\";
    assert!(
        raw.windows(sent.len()).any(|window| window == sent),
        "the write the client forwarded"
    );
}

#[test]
fn a_clipboard_read_of_a_pane_is_answered_from_the_outer_terminal() {
    let s = start(&[]);
    let record = s.dir.join("answers");
    let pane = reading_pane(&s, &record);
    let o = Outer::new(&s.dir, Keys::Extended);
    o.set_clipboard(b"outer-text");
    o.attach("");
    o.contains("READY");
    s.text(&pane, "\n");
    poll("the answer of the outer terminal in the pane", || {
        recorded(&record) == reply_of("outer-text")
    });
}

#[test]
fn a_clipboard_payload_over_the_limit_is_dropped_and_never_closes_the_client() {
    let s = start(&[]);
    let big = |bytes: u32| {
        format!(
            "printf '\\033]52;c;'; head -c {bytes} /dev/zero | base64 | tr -d '\\n'; printf '\\007'"
        )
    };
    let pane = s.pane(&format!(
        "stty raw -echo; printf READY; read line; {}; {}; printf '\\033]52;p;c21hbGw=\\007'; exec cat",
        big(600_000),
        big(400_000),
    ));
    s.screen_has(&pane, "READY");
    let (mut client, _) = s.app_client(json!({"pane": pane}), true, (80, 24));
    s.text(&pane, "\n");

    let large = client.event("clipboard_write");
    assert_eq!(large["location"], "standard");
    assert_eq!(
        large["contents"][0]["data"].as_str().unwrap().len(),
        533_336
    );
    let small = client.event("clipboard_write");
    assert_eq!(small["location"], "primary");
    assert_eq!(small["contents"][0]["data"], "c21hbGw=");
}

#[test]
fn an_answer_over_the_limit_is_a_refusal() {
    let s = start(&[]);
    let record = s.dir.join("answers");
    let pane = reading_pane(&s, &record);
    let (mut client, _) = s.app_client(json!({"pane": pane}), true, (80, 24));
    s.text(&pane, "\n");
    let read = client.event("clipboard_read");
    client.send(&answer(&read["id"], &"x".repeat(600_000)));
    poll("the refusal in the pane", || recorded(&record) == EMPTY);
}
