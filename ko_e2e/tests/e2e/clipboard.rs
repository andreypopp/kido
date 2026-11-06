use std::path::Path;

use serde_json::{Value, json};

use crate::harness::{
    Message, Server, Ws, base64, poll, quote, start, start_with, tagged, text_of,
};
use crate::outer::{Keys, Outer};
use crate::sshd::{HOST, Remote};

const EMPTY: &str = "\x1b]52;c;\x1b\\";

const OSC_52_ST: &str = "\\033]52;c;?\\033\\\\";

// A pane that sends one read (a printf format) after a newline and records whatever the pty
// gives it.
fn reading_pane(s: &Server, record: &Path, request: &str) -> String {
    let pane = s.pane(&format!(
        "stty raw -echo; printf READY; read line; printf '{request}'; exec cat > {}",
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

fn served(id: &Value, contents: &[(&str, &str)], available: &[&str]) -> Value {
    let contents: Vec<Value> = contents
        .iter()
        .map(|(mime, data)| json!({"mime": mime, "data": base64(data.as_bytes())}))
        .collect();
    json!({"type": "clipboard_answer", "id": id, "contents": contents, "available": available})
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
fn clipboard_through_nested_ssh() {
    if !crate::harness::enabled("KO_E2E_HOST_SSH") {
        return;
    }
    let s = start(&[]);
    let remote = Remote::with_ko(&s.dir);
    let ko = crate::harness::ko();
    let bin = ko.parent().unwrap();
    let ssh_pane = |transport: &str, program: &str| {
        s.pane(&format!(
            "export PATH={}:\"$PATH\"; exec {transport} -F {} -tt {HOST} {}",
            quote(text_of(bin)),
            quote(text_of(&remote.dir.join("ssh_config"))),
            quote(&format!("/bin/sh -c {}", quote(program)))
        ))
    };
    let record = s.dir.join("forwarded-answers");
    let program = format!(
        "stty raw -echo; printf READY; read line; \
         printf '\\033]52;c;b3V0ZXItd3JpdGU=\\033\\\\\\033]52;c;?\\033\\\\'; \
         dd bs=1 count={} > {} 2>/dev/null; \
         printf '\\033]52;c;'; head -c 524000 /dev/zero | base64 | tr -d '\\n'; printf '\\033\\\\'; exec cat",
        reply_of("outer-write").len(),
        quote(text_of(&record))
    );
    let pane = ssh_pane("/usr/bin/ssh", &program);
    let outer = Outer::new(&s.dir, Keys::Extended);
    outer.attach_host(HOST, &remote.bin);
    outer.contains("READY");
    s.text(&pane, "\n");
    poll(
        "the nested ssh read through the forwarded terminal client",
        || recorded(&record) == reply_of("outer-write"),
    );
    outer.wait("the near-limit nested ssh write", || {
        outer.clipboard() == vec![0; 524000]
    });
    let write = reply_of("outer-write");
    assert!(
        outer
            .output()
            .windows(write.len())
            .any(|bytes| bytes == write.as_bytes())
    );
    outer.detach();
    s.delete(&format!("/panes/{pane}"));

    for (index, transport) in [
        "/usr/bin/ssh".to_owned(),
        format!("{} ssh", quote(text_of(&ko))),
        quote(text_of(&bin.join("../share/ko/bin/ssh"))),
    ]
    .iter()
    .enumerate()
    {
        let record = s.dir.join(format!("kitty-answers-{index}"));
        let program = format!(
            "stty raw -echo; printf READY; read line; \
             printf '\\033]5522;type=write:id=w\\033\\\\\\033]5522;type=wdata:mime=dGV4dC9wbGFpbg==;aGk=\\033\\\\\\033]5522;type=wdata\\033\\\\'; \
             printf '\\033]5522;type=read:id=r;LiB0ZXh0L3BsYWlu\\007'; exec cat > {}",
            quote(text_of(&record))
        );
        let pane = ssh_pane(transport, &program);
        s.screen_has(&pane, "READY");
        let (mut client, _) = s.app_client(json!({"pane": pane}), true, (80, 24));
        s.text(&pane, "\n");
        let write = client.event("clipboard_write");
        assert_eq!(write["contents"][0]["data"], "aGk=");
        let read = client.event("clipboard_read");
        assert_eq!(read["list"], true);
        assert_eq!(read["mimes"], json!(["text/plain"]));
        client.send(&served(
            &read["id"],
            &[("text/plain", "héllo\n世界")],
            &["text/plain"],
        ));
        poll("the kitty clipboard read reaches the far host", || {
            recorded(&record).contains("status=DONE:id=r")
        });
        let got = recorded(&record);
        assert!(got.contains("\x1b]5522;type=write:status=DONE:id=w\x1b\\"));
        assert!(got.contains("mime=Lg==;dGV4dC9wbGFpbgo=\x07"));
        assert!(got.contains(&format!(
            "mime=dGV4dC9wbGFpbg==;{}\x07",
            base64("héllo\n世界".as_bytes())
        )));
        s.delete(&format!("/panes/{pane}"));
    }
}

#[test]
fn clipboard_capabilities_and_selection() {
    let s = start(&[]);
    let record = s.dir.join("capabilities");
    let pane = reading_pane(
        &s,
        &record,
        "\\033[c\\033P+q4d73\\033\\\\\\033[?5522$p\\033]52;s;aGk=\\007\\033]52;s;?\\007",
    );
    let (mut client, _) = s.app_client(json!({"pane": pane}), true, (80, 24));
    s.text(&pane, "\n");
    let write = client.event("clipboard_write");
    assert_eq!(write["location"], "selection");
    assert_eq!(write["contents"][0]["data"], "aGk=");
    let read = client.event("clipboard_read");
    assert_eq!(read["location"], "selection");
    client.send(&answer(&read["id"], "selection"));
    poll("the capability and selection replies", || {
        recorded(&record).ends_with("\x1b]52;s;c2VsZWN0aW9u\x07")
    });
    let got = recorded(&record);
    assert!(
        got.contains(";52c"),
        "DA1 advertises clipboard support: {got:?}"
    );
    assert!(
        got.contains("\x1bP1+r4D73=5C455D35323B25703125733B25703225735C303037\x1b\\"),
        "XTGETTCAP Ms encodes OSC 52: {got:?}"
    );
    assert!(
        got.contains("\x1b[?5522;2$y"),
        "kitty clipboard mode is supported: {got:?}"
    );
}

#[test]
fn one_clipboard_read_gets_exactly_one_answer_with_two_clients() {
    let s = start(&[]);
    let record = s.dir.join("answers");
    let pane = reading_pane(&s, &record, OSC_52_ST);
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
fn clipboard_read_survives_a_view_reconnect_but_not_an_unattended_session() {
    let s = start(&[]);
    let record = s.dir.join("reconnected-answer");
    let pane = reading_pane(&s, &record, OSC_52_ST);
    let (mut client, _) = s.app_client(json!({"pane": pane}), true, (80, 24));
    let mut view = s.ws(&format!("/panes/{pane}/view"));
    s.text(&pane, "\n");
    let read = client.event("clipboard_read");
    view.close();
    let _reconnected = s.ws(&format!("/panes/{pane}/view"));
    client.send(&answer(&read["id"], "after reconnect"));
    poll("the pending read is independent of its view", || {
        recorded(&record) == reply_of("after reconnect")
    });

    let record = s.dir.join("unattended-answer");
    let unattended = reading_pane(&s, &record, OSC_52_ST);
    let created = s
        .ko(
            &["api", "-X", "POST", "--input", "-", "/panes"],
            "{\"command\":{\"type\":\"argv\",\"argv\":[\"/bin/cat\"]}}",
        )
        .json();
    client.send(&json!({"type": "select", "pane": created["pane"]}));
    tags_until(&mut client, "selected");
    s.text(&unattended, "\n");
    poll("a different session is not attended", || {
        recorded(&record) == EMPTY
    });
}

#[test]
fn an_unanswered_read_ends_at_the_timer_with_an_empty_clipboard() {
    let s = start_with(
        Path::new("/bin/sh"),
        &[("KO_CLIPBOARD_TIMEOUT_MS", "300")],
        &[],
    );
    let record = s.dir.join("answers");
    let pane = reading_pane(&s, &record, OSC_52_ST);
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
    let pane = reading_pane(&s, &record, OSC_52_ST);
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
    let pane = reading_pane(&s, &record, OSC_52_ST);
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
    let pane = reading_pane(&s, &record, OSC_52_ST);
    let (mut client, _) = s.app_client(json!({"pane": pane}), true, (80, 24));
    s.text(&pane, "\n");
    let read = client.event("clipboard_read");
    client.send(&answer(&read["id"], &"x".repeat(600_000)));
    poll("the refusal in the pane", || recorded(&record) == EMPTY);
}

// Sends one read from a new pane, lets `reply` build the client's answer from the server's event,
// and returns the event and everything the pane then received, up to a barrier. The barrier
// follows a request of the same WebSocket that the server answers in order, so the server has
// dealt with the answer before the barrier reaches the pane.
fn read_through_a_client(
    s: &Server,
    case: &str,
    request: &str,
    reply: impl FnOnce(&Value) -> Value,
) -> (Value, String) {
    let record = s.dir.join(case);
    let pane = reading_pane(s, &record, request);
    let (mut client, _) = s.app_client(json!({"pane": pane}), true, (80, 24));
    s.text(&pane, "\n");
    let read = client.event("clipboard_read");
    client.send(&reply(&read["id"]));
    client.send(&json!({"type": "select", "pane": pane}));
    tags_until(&mut client, "selected");
    s.text(&pane, "BARRIER");
    poll("the barrier in the pane", || {
        recorded(&record).ends_with("BARRIER")
    });
    (
        read,
        recorded(&record).trim_end_matches("BARRIER").to_owned(),
    )
}

#[test]
fn an_osc_52_read_is_answered_with_the_terminator_of_its_request() {
    let s = start(&[]);
    let (_, bel) = read_through_a_client(&s, "bel", "\\033]52;c;?\\007", |id| answer(id, "hi"));
    assert_eq!(bel, "\x1b]52;c;aGk=\x07");
    let (_, st) = read_through_a_client(&s, "st", OSC_52_ST, |id| answer(id, "hi"));
    assert_eq!(st, "\x1b]52;c;aGk=\x1b\\");
}

#[test]
fn osc_5522_reads_get_ok_data_and_done_or_eperm() {
    let s = start(&[]);

    let (read, one) = read_through_a_client(
        &s,
        "one",
        "\\033]5522;type=read:id=r1;dGV4dC9wbGFpbg==\\033\\\\",
        |id| served(id, &[("text/plain", "hi")], &[]),
    );
    assert_eq!(read["mimes"], json!(["text/plain"]));
    assert_eq!(read["list"], Value::Null);
    assert_eq!(
        one,
        "\x1b]5522;type=read:status=OK:id=r1\x1b\\\
         \x1b]5522;type=read:status=DATA:id=r1:mime=dGV4dC9wbGFpbg==;aGk=\x1b\\\
         \x1b]5522;type=read:status=DONE:id=r1\x1b\\"
    );

    // Several types and the list: served in request order, only as requested, and the list
    // first. The terminator of the request ends every packet.
    let (read, several) = read_through_a_client(
        &s,
        "several",
        "\\033]5522;type=read:id=r2;LiB0ZXh0L2h0bWwgdGV4dC9wbGFpbg==\\007",
        |id| {
            served(
                id,
                &[
                    ("image/png", "png"),
                    ("text/plain", "hi"),
                    ("text/html", "<b>hi</b>"),
                ],
                &["text/plain", "text/html"],
            )
        },
    );
    assert_eq!(read["mimes"], json!(["text/html", "text/plain"]));
    assert_eq!(read["list"], json!(true));
    assert_eq!(
        several,
        "\x1b]5522;type=read:status=OK:id=r2\x07\
         \x1b]5522;type=read:status=DATA:id=r2:mime=Lg==;dGV4dC9wbGFpbiB0ZXh0L2h0bWwK\x07\
         \x1b]5522;type=read:status=DATA:id=r2:mime=dGV4dC9odG1s;PGI+aGk8L2I+\x07\
         \x1b]5522;type=read:status=DATA:id=r2:mime=dGV4dC9wbGFpbg==;aGk=\x07\
         \x1b]5522;type=read:status=DONE:id=r2\x07"
    );

    let (_, refused) = read_through_a_client(
        &s,
        "refused",
        "\\033]5522;type=read:id=r3;dGV4dC9wbGFpbg==\\033\\\\",
        |id| json!({"type": "clipboard_answer", "id": id}),
    );
    assert_eq!(refused, "\x1b]5522;type=read:status=EPERM:id=r3\x1b\\");
}

#[test]
fn the_terminal_client_answers_a_text_read_from_the_outer_terminal_and_refuses_a_list_read() {
    let s = start(&[]);
    let record = s.dir.join("answers");
    let pane = s.pane(&format!(
        "stty raw -echo; printf READY; read line; \
         printf '\\033]5522;type=read:id=a;dGV4dC9wbGFpbg==\\033\\\\\\033]5522;type=read:id=b;LiB0ZXh0L3BsYWlu\\033\\\\'; \
         exec cat > {}",
        quote(text_of(&record))
    ));
    let o = Outer::new(&s.dir, Keys::Extended);
    o.set_clipboard(b"outer-text");
    o.attach("");
    o.contains("READY");
    s.text(&pane, "\n");

    // The refusal of the list read does not wait for the outer terminal, so the order of the two
    // answers is not fixed.
    let text = "\x1b]5522;type=read:status=OK:id=a\x1b\\\
                \x1b]5522;type=read:status=DATA:id=a:mime=dGV4dC9wbGFpbg==;b3V0ZXItdGV4dA==\x1b\\\
                \x1b]5522;type=read:status=DONE:id=a\x1b\\";
    let eperm = "\x1b]5522;type=read:status=EPERM:id=b\x1b\\";
    poll("both answers in the pane", || {
        recorded(&record).len() == text.len() + eperm.len()
    });
    let got = recorded(&record);
    assert!(
        got == format!("{text}{eperm}") || got == format!("{eperm}{text}"),
        "{got:?}"
    );
}
