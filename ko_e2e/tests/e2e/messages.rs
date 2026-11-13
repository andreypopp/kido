use std::fs::File;
use std::io::Write;
use std::os::fd::AsFd;
use std::path::Path;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::harness::ko_command;
use crate::harness::{
    Child, DEADLINE, Message, PRINT_TOKEN, Server, Steady, Ws, ko, poll, start, start_with,
};
use crate::panes::{Headers, as_pane, post, raw, token_pane_in_new_session};

pub(crate) fn path(pane: &str) -> String {
    format!("/panes/{pane}/messages")
}

fn body(id: &str, text: &str) -> Value {
    json!({"id": id, "kind": "message", "text": text})
}

fn send(s: &Server, who: &Headers, pane: &str, body: &Value) -> (u16, Value) {
    raw(s, "POST", &path(pane), who, body)
}

fn send_later(s: &Server, who: &Headers, pane: &str, body: &Value) -> Steady {
    s.send_request("POST", &path(pane), who, body.to_string().as_bytes())
}

pub(crate) fn answer(s: &Server, stream: Steady) -> (u16, Value) {
    let (status, reply) = s.read_reply(stream);
    (status, serde_json::from_slice(&reply).unwrap())
}

pub(crate) fn open(s: &Server, pane: &str) -> Ws {
    s.dial_ws(&path(pane), Some(as_pane(s, pane)), 101).unwrap()
}

pub(crate) fn received(stream: &mut Ws) -> Value {
    stream.within(DEADLINE);
    match stream.read() {
        Message::Text(text) => serde_json::from_str(&text).unwrap(),
        Message::Binary(_) => panic!("a message is text"),
    }
}

pub(crate) fn ack(stream: &mut Ws, id: &str) {
    stream.send(&json!({"type": "ack", "id": id}));
}

fn row_has_inbox(s: &Server, pane: &str, inbox: bool) {
    s.wait_row(pane, "the inbox flag", |row| {
        row["inbox"].as_bool().unwrap_or(false) == inbox
    });
}

fn agent(s: &Server, session: &str, name: &str) -> String {
    let command = format!(
        "printf '\\033]7501;state=idle:app=pi\\007'; stty raw -echo; {PRINT_TOKEN}; exec cat"
    );
    let pane = s.new_pane(json!({
        "command": {"type": "shell", "command": command},
        "vars": {"pi.session": session, "pi.name": name}
    }));
    s.wait_row(&pane, "its pi root", |row| {
        row["status"]["program_status"]["records"]
            .as_array()
            .is_some_and(|records| !records.is_empty())
    });
    s.screen_has(&pane, "TOKEN<");
    pane
}

fn child(s: &Server, parent: &str) -> String {
    let command = format!("stty raw -echo; {PRINT_TOKEN}; exec cat");
    let made = post(
        s,
        Some(parent),
        "/panes",
        &json!({"parent": parent, "command": {"type": "shell", "command": command}}),
    );
    let pane = made["pane"].as_str().unwrap().to_owned();
    s.screen_has(&pane, "TOKEN<");
    pane
}

#[test]
fn a_select_message_is_delivered_with_its_record_id_untouched() {
    let s = start(&[]);
    let a = s.token_pane("exec cat");
    let id = "agents/a b/agents/\u{fc}";
    let select = json!({"id": "msg-0001", "kind": "select", "text": id});
    assert_eq!(
        send(&s, &s.headers(), &a, &select),
        (200, json!({"state": "queued", "seq": 1}))
    );
    let mut stream = open(&s, &a);
    assert_eq!(
        received(&mut stream),
        json!({"seq": 1, "id": "msg-0001", "from": {"type": "user"}, "kind": "select", "text": id})
    );
}

#[test]
fn a_message_is_queued_written_acked_and_remembered_by_its_id() {
    let s = start_with(Path::new("/bin/sh"), &[("KO_MESSAGE_ACK_MS", "500")], &[]);
    let user = s.headers();
    let a = s.token_pane("exec cat");
    let b = s.token_pane("exec cat");
    let by_b = as_pane(&s, &b);
    let (mut events, _) = s.client(None);

    assert_eq!(
        send(&s, &user, &a, &body("msg-0001", "one")),
        (200, json!({"state": "queued", "seq": 1}))
    );
    assert_eq!(
        send(&s, &user, &a, &body("msg-0001", "another text")),
        (200, json!({"state": "queued", "seq": 1, "duplicate": true})),
        "the id decides, not the body"
    );
    let steer = json!({"id": "msg-0002", "kind": "steer", "text": "two", "data": {"mark": 1}});
    assert_eq!(
        send(&s, &by_b, &a, &steer),
        (200, json!({"state": "queued", "seq": 2}))
    );
    assert_eq!(s.row(&a).get("inbox"), None);

    let mut stream = open(&s, &a);
    let event = events.event("inbox");
    assert_eq!(
        (event["pane"].as_str(), event["inbox"].as_bool()),
        (Some(a.as_str()), Some(true))
    );
    row_has_inbox(&s, &a, true);
    assert_eq!(
        received(&mut stream),
        json!({"seq": 1, "id": "msg-0001", "from": {"type": "user"}, "kind": "message", "text": "one"})
    );
    assert_eq!(
        received(&mut stream),
        json!({"seq": 2, "id": "msg-0002", "from": {"type": "pane", "pane": b}, "relation": "sibling",
            "kind": "steer", "text": "two", "data": {"mark": 1}})
    );
    s.dial_ws(&path(&a), Some(as_pane(&s, &a)), 409);

    let waiting = send_later(&s, &user, &a, &body("msg-0003", "three"));
    assert_eq!(received(&mut stream)["seq"], 3);
    ack(&mut stream, "unknown-id");
    ack(&mut stream, "msg-0003");
    assert_eq!(
        answer(&s, waiting),
        (200, json!({"state": "acked", "seq": 3}))
    );
    assert_eq!(
        send(&s, &user, &a, &body("msg-0003", "x")),
        (200, json!({"state": "acked", "seq": 3, "duplicate": true}))
    );

    let lost = send_later(&s, &user, &a, &body("msg-0004", "four"));
    assert_eq!(received(&mut stream)["id"], "msg-0004");
    drop(lost);
    let retried = send_later(&s, &user, &a, &body("msg-0004", "four"));
    ack(&mut stream, "msg-0004");
    assert_eq!(
        answer(&s, retried),
        (200, json!({"state": "acked", "seq": 4, "duplicate": true})),
        "a retry after a lost reply gets the truth"
    );

    let refused = send_later(&s, &user, &a, &body("msg-0005", "five"));
    assert_eq!(received(&mut stream)["id"], "msg-0005");
    stream.send(&json!({"type": "refuse", "id": "msg-0005"}));
    let (status, reply) = answer(&s, refused);
    assert_eq!(
        (status, reply["kind"].as_str()),
        (409, Some("refused")),
        "{reply}"
    );
    assert_eq!(
        send(&s, &user, &a, &body("msg-0005", "five")).0,
        409,
        "a repeat of a refused id is refused"
    );

    drop(stream);
    let event = events.event("inbox");
    assert_eq!(event["inbox"], false);
    row_has_inbox(&s, &a, false);
    assert_eq!(
        send(&s, &user, &a, &body("msg-0001", "")),
        (200, json!({"state": "queued", "seq": 1, "duplicate": true})),
        "a written message that no ack settled is queued again"
    );
    let mut stream = open(&s, &a);
    let again = [received(&mut stream), received(&mut stream)];
    assert_eq!(
        again.map(|message| message["id"].as_str().unwrap().to_owned()),
        ["msg-0001", "msg-0002"],
        "the next stream gets the unacked messages again, in seq order"
    );
    ack(&mut stream, "msg-0001");

    let lost = send_later(&s, &user, &a, &body("msg-0006", "six"));
    assert_eq!(received(&mut stream)["id"], "msg-0006");
    drop(stream);
    assert_eq!(
        answer(&s, lost),
        (200, json!({"state": "queued", "seq": 6})),
        "the stream closed while the request waited"
    );

    let mut stream = open(&s, &a);
    assert_eq!(received(&mut stream)["id"], "msg-0002");
    assert_eq!(received(&mut stream)["id"], "msg-0006");
    let began = Instant::now();
    assert_eq!(
        send(&s, &user, &a, &body("msg-0007", "seven")),
        (200, json!({"state": "delivered", "seq": 7})),
        "no ack within the wait"
    );
    assert!(began.elapsed() >= Duration::from_millis(450));
    assert_eq!(received(&mut stream)["id"], "msg-0007");
}

#[test]
fn the_server_stamps_the_sender_and_what_it_is_to_the_receiver_and_keeps_the_scope() {
    let s = start(&[]);
    let user = s.headers();
    let p = s.token_pane("exec cat");
    let q = s.token_pane("exec cat");
    let r = token_pane_in_new_session(&s, "elsewhere");
    let c1 = child(&s, &p);
    let c2 = child(&s, &p);
    let g = child(&s, &c1);
    let w = agent(&s, "sess-w", "worker");
    let t = s.new_pane(json!({
        "command": {"type": "shell", "command": format!("stty raw -echo; {PRINT_TOKEN}; exec cat")},
        "vars": {"pi.session": "no-root", "pi.name": "ghost"}
    }));
    s.screen_has(&t, "TOKEN<");

    let from = |pane: &str, to: &str, id: &str| {
        let sent = send(&s, &as_pane(&s, pane), to, &body(id, "hi"));
        assert_eq!(sent.0, 200, "{pane} to {to}: {sent:?}");
    };
    from(&c1, &p, "scope-0001");
    from(&g, &p, "scope-0002");
    from(&q, &p, "scope-0003");
    from(&w, &p, "scope-0004");
    from(&t, &p, "scope-0005");
    from(&p, &c2, "scope-0006");
    from(&g, &c2, "scope-0007");
    from(&c1, &c2, "scope-0008");

    for (sender, target) in [(&p, &g), (&q, &c1), (&r, &p), (&g, &r)] {
        let (status, reply) = send(&s, &as_pane(&s, sender), target, &body("scope-0009", "no"));
        assert_eq!(
            (status, reply["kind"].as_str()),
            (409, Some("refused")),
            "{sender} to {target}"
        );
        assert!(
            reply["message"]
                .as_str()
                .unwrap()
                .contains("not a child, sibling or ancestor"),
            "{reply}"
        );
    }
    assert_eq!(
        send(&s, &user, &g, &body("scope-0009", "yes")).0,
        200,
        "the user may write to any pane"
    );
    assert_eq!(
        send(&s, &as_pane(&s, &c1), "pane_999", &body("scope-0010", "x")).0,
        404
    );

    let mut stream = open(&s, &p);
    let seen = |message: Value| {
        (
            message["from"].clone(),
            message["relation"].as_str().map(str::to_owned),
        )
    };
    let pane = |pane: &str| json!({"type": "pane", "pane": pane});
    let relation = |name: &str| Some(name.to_owned());
    assert_eq!(seen(received(&mut stream)), (pane(&c1), relation("child")));
    assert_eq!(
        seen(received(&mut stream)),
        (pane(&g), relation("descendant"))
    );
    assert_eq!(seen(received(&mut stream)), (pane(&q), relation("sibling")));
    assert_eq!(
        seen(received(&mut stream)),
        (
            json!({"type": "pane", "pane": w, "session": "sess-w", "name": "worker"}),
            relation("sibling")
        ),
        "a pi root vouches for the session and the name"
    );
    assert_eq!(
        seen(received(&mut stream)),
        (pane(&t), relation("sibling")),
        "variables without a pi root vouch for nothing"
    );

    let mut stream = open(&s, &c2);
    assert_eq!(seen(received(&mut stream)), (pane(&p), relation("parent")));
    assert_eq!(
        seen(received(&mut stream)),
        (pane(&g), relation("sibling_descendant"))
    );
    assert_eq!(
        seen(received(&mut stream)),
        (pane(&c1), relation("sibling"))
    );

    let mut stream = open(&s, &g);
    let message = received(&mut stream);
    assert_eq!(
        (message["from"].clone(), message.get("relation")),
        (json!({"type": "user"}), None),
        "the user has no relation"
    );
}

#[test]
fn a_pane_that_dies_or_leaves_drops_its_queue_and_tells_its_parent() {
    let s = start(&[]);
    let user = s.headers();
    let dies_on_input = "read x; exit 3";

    let d = s.token_pane_with(json!({"close": "keep"}), dies_on_input);
    let mut stream = open(&s, &d);
    let waiting = send_later(&s, &user, &d, &body("dead-0001", "x"));
    assert_eq!(received(&mut stream)["id"], "dead-0001");
    s.text(&d, "go\n");
    let (status, reply) = answer(&s, waiting);
    assert_eq!(
        (status, reply["kind"].as_str()),
        (410, Some("gone")),
        "{reply}"
    );
    assert!(
        reply["message"].as_str().unwrap().ends_with("is dead"),
        "{reply}"
    );
    stream.closed("the stream of a dead pane to close");
    assert_eq!(send(&s, &user, &d, &body("dead-0002", "x")).0, 410);
    assert_eq!(s.row(&d).get("inbox"), None);
    s.dial_ws(&path(&d), None, 410);

    let parent = s.token_pane("exec cat");
    let new = |command: &str| {
        let made = post(
            &s,
            Some(&parent),
            "/panes",
            &json!({"parent": parent, "close": "keep", "command": {"type": "shell", "command": command}}),
        );
        made["pane"].as_str().unwrap().to_owned()
    };
    let died = new(dies_on_input);
    let died_then_removed = new(dies_on_input);
    let removed_live = new("exec cat");
    s.text(&died, "go\n");
    s.wait_row(&died, "its death", |row| row["dead"].is_object());
    s.text(&died_then_removed, "go\n");
    s.wait_row(&died_then_removed, "its death", |row| {
        row["dead"].is_object()
    });
    s.delete(&format!("/panes/{died_then_removed}")).ok();
    s.delete(&format!("/panes/{removed_live}")).ok();

    let mut stream = open(&s, &parent);
    for (pane, end) in [
        (&died, "dead"),
        (&died_then_removed, "dead"),
        (&removed_live, "gone"),
    ] {
        let message = received(&mut stream);
        assert_eq!(message["id"], format!("ended-{pane}"));
        assert_eq!(message["from"], json!({"type": "pane", "pane": pane}));
        assert_eq!(message["relation"], "child");
        assert_eq!(message["kind"], "ended");
        assert_eq!(message.get("text"), None);
        assert_eq!(message["end"]["type"], end);
        if end == "dead" {
            assert_eq!(
                message["end"]["cause"],
                json!({"type": "exited", "code": 3})
            );
            assert!(message["end"]["at"].is_u64(), "{message}");
        }
    }
    let next = send_later(&s, &user, &parent, &body("after-0001", "x"));
    let message = received(&mut stream);
    assert_eq!(
        message["seq"], 4,
        "a pane that died and was removed sent one ending, not two"
    );
    ack(&mut stream, "after-0001");
    assert_eq!(answer(&s, next), (200, json!({"state": "acked", "seq": 4})));
}

#[test]
fn ko_api_stream_sends_each_line_of_stdin_so_a_receiver_acks_and_refuses_through_it() {
    let s = start(&[]);
    let user = s.headers();
    let a = s.token_pane("exec cat");
    let (env, argv) = ko_command(&s, Some(&a), &["api", "--stream", &path(&a)]);
    let argv: Vec<&str> = argv.iter().map(String::as_str).collect();
    let (input, mut lines) = std::io::pipe().unwrap();
    let (stdout, stderr) = (
        s.scratch.join("receiver-out"),
        s.scratch.join("receiver-err"),
    );
    let (out, err) = (
        File::create(&stdout).unwrap(),
        File::create(&stderr).unwrap(),
    );
    let _cli = Child::spawn(
        &ko(),
        &argv,
        &env,
        &[(input.as_fd(), 0), (out.as_fd(), 1), (err.as_fd(), 2)],
    );
    row_has_inbox(&s, &a, true);
    let printed = |id: &str| {
        std::fs::read_to_string(&stdout).is_ok_and(|text| {
            text.lines()
                .any(|line| serde_json::from_str::<Value>(line).is_ok_and(|m| m["id"] == id))
        })
    };

    let acked = send_later(&s, &user, &a, &body("cli-0001", "one"));
    poll("the first message on stdout", || printed("cli-0001"));
    writeln!(lines, r#"{{"type":"ack","id":"cli-0001"}}"#).unwrap();
    assert_eq!(
        answer(&s, acked),
        (200, json!({"state": "acked", "seq": 1}))
    );

    let refused = send_later(&s, &user, &a, &body("cli-0002", "two"));
    poll("the second message on stdout", || printed("cli-0002"));
    writeln!(lines, "\n{}", json!({"type": "refuse", "id": "cli-0002"})).unwrap();
    let (status, reply) = answer(&s, refused);
    assert_eq!(
        (status, reply["kind"].as_str()),
        (409, Some("refused")),
        "{reply}"
    );

    drop(lines);
    let _later = send_later(&s, &user, &a, &body("cli-0003", "three"));
    poll("a message after the end of stdin", || printed("cli-0003"));
    assert_eq!(std::fs::read_to_string(&stderr).unwrap(), "");
}

#[test]
fn ko_api_stream_prints_what_was_queued_at_once_and_refuses_a_line_that_is_too_long() {
    let s = start(&[]);
    let user = s.headers();
    let a = s.token_pane("exec cat");
    assert_eq!(
        send(&s, &user, &a, &body("queued-0001", "waiting")).1["state"],
        "queued"
    );
    let (env, argv) = ko_command(&s, Some(&a), &["api", "--stream", &path(&a)]);
    let argv: Vec<&str> = argv.iter().map(String::as_str).collect();
    let none = File::open("/dev/null").unwrap();
    let stdout = s.scratch.join("queued-out");
    let out = File::create(&stdout).unwrap();
    let _cli = Child::spawn(&ko(), &argv, &env, &[(none.as_fd(), 0), (out.as_fd(), 1)]);
    poll("the queued message on stdout", || {
        std::fs::read_to_string(&stdout).is_ok_and(|text| text.contains("queued-0001"))
    });

    let b = s.token_pane("exec cat");
    let (env, argv) = ko_command(&s, Some(&b), &["api", "--stream", &path(&b)]);
    let argv: Vec<&str> = argv.iter().map(String::as_str).collect();
    let long = "x".repeat(1 << 20) + "y\n";
    let run = crate::harness::run_ko(&s.scratch, &env, &argv, &long);
    assert_eq!(crate::harness::code(&run), 1);
    assert_eq!(run.stderr, "ko api: a line of standard input is too long\n");
}
