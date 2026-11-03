use ko_pane_wire::base64;
use serde_json::{Value, json};

use crate::harness::{
    Child, DEADLINE, End, Message, PRINT_TOKEN, Server, Ws, poll, start, test_env,
};
use crate::runs::ko_as;

const FLOOD: usize = 8 << 20;
const START: u64 = 5;
const TOTAL: u64 = START + FLOOD as u64 + 3;
const FLOODING: &str = "stty raw -echo; printf START; read x; head -c 8388608 /dev/zero | tr '\\0' a; printf END; read y; exit 0";

#[derive(Debug, PartialEq)]
enum Piece {
    Bytes { offset: u64, data: Vec<u8> },
    Skip { from: u64, to: u64 },
    Dead(Value),
}

fn piece(line: &str) -> Piece {
    let message: Value = serde_json::from_str(line).unwrap();
    match message["type"].as_str() {
        Some("bytes") => Piece::Bytes {
            offset: message["offset"].as_u64().unwrap(),
            data: base64::decode(message["data"].as_str().unwrap()).unwrap(),
        },
        Some("skip") => Piece::Skip {
            from: message["from"].as_u64().unwrap(),
            to: message["to"].as_u64().unwrap(),
        },
        Some("dead") => Piece::Dead(message),
        other => panic!("unexpected {other:?}: {line}"),
    }
}

fn next(ws: &mut Ws) -> Option<Piece> {
    ws.within(DEADLINE);
    match ws.next() {
        Ok(Message::Text(text)) => Some(piece(&text)),
        Ok(Message::Binary(_)) => panic!("a binary message on an output stream"),
        Err(End::Closed) => None,
        Err(End::Timeout) => panic!("no message: {}", ws.last()),
    }
}

fn read_until(ws: &mut Ws, mut at: u64, end: u64) -> (Vec<u8>, Vec<(u64, u64)>) {
    let (mut data, mut skips) = (Vec::new(), Vec::new());
    while at < end {
        match next(ws).expect("the stream closed before the end") {
            Piece::Bytes { offset, data: more } => {
                assert_eq!(offset, at);
                at += more.len() as u64;
                data.extend_from_slice(&more);
            }
            Piece::Skip { from, to } => {
                assert_eq!(from, at);
                assert!(to > from, "an empty skip: {from} to {to}");
                skips.push((from, to));
                at = to;
                data.clear();
            }
            Piece::Dead(dead) => panic!("dead before the end: {dead}"),
        }
    }
    assert_eq!(at, end, "the bytes overshoot the end");
    (data, skips)
}

fn dead_then_close(ws: &mut Ws, code: i32) {
    let Some(Piece::Dead(dead)) = next(ws) else {
        panic!("no dead record");
    };
    assert_eq!(dead["cause"], json!({"type": "exited", "code": code}));
    assert!(dead["at"].is_u64(), "{dead}");
    assert!(next(ws).is_none(), "the stream goes on after dead");
    assert_eq!(ws.close_frame(), Some(&(1000, "done".to_owned())));
}

fn resumes_and_ends_with_dead(s: &Server) {
    let pane = s.pane("stty raw -echo; printf 0123456789abcdefghij; read line; exit 3");
    s.screen_has(&pane, "ghij");
    let path = format!("/panes/{pane}/output");

    let mut inside = s.ws(&format!("{path}?offset=5"));
    let mut ending = s.ws(&path);
    let mut mid = s.ws(&format!("{path}?offset=12"));
    assert_eq!(
        read_until(&mut inside, 5, 20),
        (b"56789abcdefghij".to_vec(), vec![])
    );
    assert_eq!(read_until(&mut mid, 12, 20), (b"cdefghij".to_vec(), vec![]));

    s.text(&pane, "\n");
    dead_then_close(&mut inside, 3);
    dead_then_close(&mut ending, 3);
    dead_then_close(&mut mid, 3);

    let lines = s
        .ko(&["api", "--stream", &format!("{path}?offset=7")], "")
        .ok();
    let pieces: Vec<Piece> = lines.lines().map(piece).collect();
    assert_eq!(
        pieces[..pieces.len() - 1],
        [Piece::Bytes {
            offset: 7,
            data: b"789abcdefghij".to_vec()
        }],
        "{lines}"
    );
    assert!(matches!(pieces.last(), Some(Piece::Dead(_))), "{lines}");

    for end in [path.clone(), format!("{path}?offset=20")] {
        let lines = s.ko(&["api", "--stream", &end], "").ok();
        let pieces: Vec<Piece> = lines.lines().map(piece).collect();
        assert!(
            matches!(pieces.as_slice(), [Piece::Dead(_)]),
            "a dead pane at its end has only dead: {lines}"
        );
    }

    let refused: Value = serde_json::from_str(
        &s.ko(&["api", "--stream", &format!("{path}?offset=21")], "")
            .http_error(400),
    )
    .unwrap();
    assert_eq!(refused["kind"], "invalid", "{refused}");
    let message = refused["message"].as_str().unwrap();
    assert!(message.contains("past the end"), "{message}");

    let error = s.ko(&["api", "--stream", "/version"], "").error(1);
    assert!(error.contains("not a WebSocket endpoint"), "{error}");
}

fn slow_and_stalled_readers(s: &Server) {
    let pane = s.pane(FLOODING);
    s.screen_has(&pane, "START");
    let path = format!("/panes/{pane}/output");
    for offset in [
        "",
        "x",
        "-1",
        "1.5",
        "99999999999999999999",
        "4611686018427387905",
        "6",
    ] {
        s.dial_ws(&format!("{path}?offset={offset}"), None, 400);
    }

    let mut slow = s.ws(&path);
    let _stalled = s.ws(&path);
    s.text(&pane, "\n");
    s.screen_has(&pane, "END");
    s.request("GET", "/version", None, 200);
    let (data, skips) = read_until(&mut slow, START, TOTAL);
    assert!(!skips.is_empty(), "the ring is smaller than the flood");
    assert!(data.ends_with(b"END"));
    assert_eq!(
        data.len() as u64,
        TOTAL - skips.last().map_or(START, |(_, to)| *to)
    );
    s.request("GET", "/version", None, 200);

    let mut stale = s.ws(&format!("{path}?offset=0"));
    let Some(Piece::Skip { from: 0, to }) = next(&mut stale) else {
        panic!("a stale offset starts with a skip");
    };
    assert!(to > 0 && to < TOTAL);
    let (data, skips) = read_until(&mut stale, to, TOTAL);
    assert_eq!(skips, vec![]);
    assert!(data.ends_with(b"END"));

    s.text(&pane, "\n");
    dead_then_close(&mut stale, 0);
}

fn removal_closes_with_an_error(s: &Server) {
    let pane = s.pane(FLOODING);
    s.screen_has(&pane, "START");
    let path = format!("/panes/{pane}/output");
    let mut blocked = s.ws(&path);
    s.text(&pane, "\n");
    s.screen_has(&pane, "END");
    s.delete(&format!("/panes/{pane}")).ok();
    loop {
        match next(&mut blocked) {
            Some(Piece::Bytes { .. } | Piece::Skip { .. }) => {}
            Some(Piece::Dead(dead)) => panic!("dead on a removed pane: {dead}"),
            None => break,
        }
    }
    assert_eq!(
        blocked.close_frame(),
        Some(&(1011, "pane removed".to_owned()))
    );

    let pane = s.echo_pane();
    let (stdout, stderr) = (s.scratch.join("stream-out"), s.scratch.join("stream-err"));
    let (out, err) = (
        std::fs::File::create(&stdout).unwrap(),
        std::fs::File::create(&stderr).unwrap(),
    );
    let none = std::fs::File::open("/dev/null").unwrap();
    let dir = crate::harness::text_of(&s.dir);
    let target = format!("/panes/{pane}/output?offset=0");
    let mut cli = {
        use std::os::fd::AsFd;
        Child::spawn(
            &crate::harness::ko(),
            &["api", "--stream", &target, "--server", dir],
            &test_env(&s.dir),
            &[(none.as_fd(), 0), (out.as_fd(), 1), (err.as_fd(), 2)],
        )
    };
    poll("the stream to print the first bytes", || {
        std::fs::read_to_string(&stdout).is_ok_and(|text| text.contains("\"bytes\""))
    });
    s.delete(&format!("/panes/{pane}")).ok();
    assert_eq!(
        cli.wait(DEADLINE),
        Some(ko_sys::pid::Exit::Exited(1)),
        "{}",
        std::fs::read_to_string(&stderr).unwrap_or_default()
    );
    assert_eq!(
        std::fs::read_to_string(&stderr).unwrap(),
        "ko api: closed: 1011 pane removed\n"
    );
}

fn identity(s: &Server) {
    let parent = s.token_pane("exec cat");
    let other = s.token_pane("exec cat");
    let made = ko_as(
        s,
        Some(&parent),
        &["api", "-X", "POST", "--input", "-", "/panes"],
        &json!({
            "parent": parent,
            "command": {"type": "shell", "command": format!("stty raw -echo; {PRINT_TOKEN}; exec cat")},
        })
        .to_string(),
    )
    .json();
    let child = made["pane"].as_str().unwrap().to_owned();
    s.screen_has(&child, "TOKEN<");
    let path = |pane: &str| format!("/panes/{pane}/output?offset=0");

    for (reader, target, status) in [
        (None, &parent, 101),
        (None, &child, 101),
        (Some(&parent), &parent, 101),
        (Some(&parent), &child, 101),
        (Some(&child), &child, 101),
        (Some(&other), &parent, 409),
        (Some(&other), &child, 409),
        (Some(&child), &parent, 409),
        (Some(&parent), &other, 409),
    ] {
        let headers = reader.map(|reader| s.as_pane(reader));
        let mut ws = s.dial_ws(&path(target), headers, status);
        if let Some(ws) = ws.as_mut() {
            assert!(
                matches!(next(ws), Some(Piece::Bytes { offset: 0, .. })),
                "{reader:?} reads {target}"
            );
        }
    }

    let body: Value = serde_json::from_str(
        &ko_as(s, Some(&other), &["api", "--stream", &path(&parent)], "").http_error(409),
    )
    .unwrap();
    assert_eq!(body["kind"], "refused", "{body}");
    let message = body["message"].as_str().unwrap();
    assert!(
        message.contains("may read the output of itself and its children"),
        "{message}"
    );
}

#[test]
fn the_output_stream() {
    let s = start(&[]);
    identity(&s);
    resumes_and_ends_with_dead(&s);
    slow_and_stalled_readers(&s);
    removal_closes_with_an_error(&s);
}
