use std::io::{Read, Write};
use std::net::Shutdown;
use std::time::{Duration, Instant};

use serde_json::json;

use crate::harness::{DEADLINE, Hello, size_request, start, within};
use crate::messages::{open, path, received};
use crate::panes::raw;

#[test]
fn hostile_clients_do_not_affect_others() {
    let mut s = start(&[]);
    let p = s.pane("stty -echo -icanon min 1 time 0; printf READY; exec cat -v");
    let mut good = s.ws(&format!("/panes/{p}/view?history=all"));
    good.ready("READY");
    let head: String = s
        .headers()
        .iter()
        .map(|(name, value)| format!("{name}: {value}\r\n"))
        .collect();
    let upgrade = format!("GET /panes/{p}/view?history=all HTTP/1.1\r\nHost: ko\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n{head}\r\n").into_bytes();
    let after = |tail: &[u8]| [upgrade.as_slice(), tail].concat();
    let upgrade_output = format!("GET /panes/{p}/output HTTP/1.1\r\nHost: ko\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n{head}\r\n").into_bytes();
    let after_output = |tail: &[u8]| [upgrade_output.as_slice(), tail].concat();
    let hostile: Vec<Vec<u8>> = vec![
        format!(
            "GET /version HTTP/1.1\r\nHost: ko\r\n{}\r\n",
            "A: b\r\n".repeat(20000)
        )
        .into_bytes(),
        format!("PUT /layout HTTP/1.1\r\nHost: ko\r\n{head}Content-Length: 99999999999\r\n\r\n{{")
            .into_bytes(),
        format!("PUT /layout HTTP/1.1\r\nHost: ko\r\n{head}Transfer-Encoding: chunked\r\n\r\n{{}}")
            .into_bytes(),
        b"\x16\x03\x01\x02\x00\x01\x00\x01\xfc\x03\x03".to_vec(),
        after(&[
            0x81, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0,
        ]),
        after(&[0x01, 0x80, 0, 0, 0, 0, 0x80, 0x80, 0, 0, 0, 0]),
        after(&[0x89, 0x80, 0, 0, 0, 0].repeat(5000)),
        after_output(&[
            0x81, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0,
        ]),
        after_output(&[0x81, 0x81, 0, 0, 0, 0, b'x']),
        after_output(&[0x82, 0x80, 0, 0, 0, 0]),
        after_output(&[0x89, 0x80, 0, 0, 0, 0].repeat(5000)),
    ];
    for (i, hostile) in hostile.iter().enumerate() {
        let mut conn = s.dial().unwrap();
        let deadline = Instant::now() + DEADLINE;
        within(&conn, deadline);
        let _ = conn.write_all(hostile);
        let _ = conn.shutdown(Shutdown::Write);
        // Linux resets a unix socket whose peer closed with unread input; macOS reports EOF.
        let mut seen = 0usize;
        let mut chunk = [0u8; 65536];
        while seen < 8 << 20 {
            let left = deadline.saturating_duration_since(Instant::now());
            assert!(
                !left.is_zero(),
                "hostile input {i} kept the connection open"
            );
            // macOS refuses a new timeout on a socket whose write side is shut down; the one from
            // `within` stays then.
            let _ = conn.set_read_timeout(Some(left));
            match conn.read(&mut chunk) {
                Ok(0) => break,
                Ok(count) => seen += count,
                Err(error) if error.kind() == std::io::ErrorKind::ConnectionReset => break,
                Err(error) => panic!("hostile input {i} kept the connection open: {error}"),
            }
        }
        drop(conn);
        assert!(
            s.child.wait(Duration::ZERO).is_none(),
            "server exited after hostile input {i}: {}",
            s.log()
        );
        s.request("GET", "/version", None, 200);
        good.type_text(&format!("alive{i}"));
        good.output(&format!("alive{i}"));
    }

    // A client that closes with a response unread makes Linux answer the server's next read of
    // that connection with ECONNRESET, which is the end of the connection like EOF.
    let mut conn = s.dial().unwrap();
    within(&conn, Instant::now() + DEADLINE);
    conn.write_all(format!("GET /version HTTP/1.1\r\nHost: ko\r\n{head}\r\n").as_bytes())
        .unwrap();
    assert_eq!(conn.read(&mut [0u8; 1]).unwrap(), 1);
    drop(conn);
    assert!(
        s.child.wait(Duration::ZERO).is_none(),
        "server exited after a client reset: {}",
        s.log()
    );
    s.request("GET", "/version", None, 200);
    good.type_text("alive-reset");
    good.output("alive-reset");

    let grid = |cols: u32, rows: u32| json!({"cols": cols, "rows": rows, "cell_px": {"width": 65535, "height": 65535}});
    let hello = |cols: u32, rows: u32| {
        s.hello(Hello {
            selection: serde_json::json!({}),
            focused: true,
            size: grid(cols, rows),
        })
    };
    let mut c = hello(4096, 4096);
    c.welcome();
    c.send(&size_request(grid(4097, 24)));
    c.closed("size 4097 accepted");
    let mut c = hello(4097, 24);
    c.closed("hello 4097 accepted");
    s.request("GET", "/version", None, 200);
}

#[test]
fn hostile_message_input_is_refused_and_leaves_other_streams_alone() {
    let s = start(&[]);
    let user = s.headers();
    let a = s.token_pane("exec cat");
    let b = s.token_pane("exec cat");
    let mut good = open(&s, &b);

    let fits = "d".repeat(4094);
    let large = "d".repeat(4095);
    let sent = raw(
        &s,
        "POST",
        &path(&a),
        &user,
        &json!({"id": "abcdefgh", "kind": "message", "text": "x", "data": fits}),
    );
    assert_eq!(sent.0, 200, "{sent:?}");
    for body in [
        json!({"id": "short", "kind": "message", "text": "x"}),
        json!({"id": "has space!", "kind": "message", "text": "x"}),
        json!({"id": "a".repeat(65), "kind": "message", "text": "x"}),
        json!({"id": "abcdefgh", "kind": "user", "text": "x"}),
        json!({"id": "abcdefgh", "kind": "message"}),
        json!({"id": "bcdefghi", "kind": "message", "text": "x", "data": large}),
        json!(["abcdefgh", "message", "x"]),
    ] {
        let (status, reply) = raw(&s, "POST", &path(&a), &user, &body);
        assert_eq!(
            (status, reply["kind"].as_str()),
            (400, Some("invalid")),
            "{body}"
        );
    }
    let (status, _) = s.exchange("POST", &path(&a), &user, b"not json");
    assert_eq!(status, 400);

    for text in [
        json!("not an object"),
        json!([]),
        json!({"type": "nope"}),
        json!({"type": "ack"}),
        json!({"type": "ack", "id": "x"}),
        json!({"type": "refuse", "id": ["abcdefgh"]}),
    ] {
        let mut stream = open(&s, &a);
        assert_eq!(received(&mut stream)["id"], "abcdefgh");
        stream.send(&text);
        stream.closed(&format!("the stream to close on {text}"));
        assert_eq!(
            stream.close_frame(),
            Some(&(1008, "invalid".to_owned())),
            "{text}"
        );
        s.request("GET", "/version", None, 200);
    }
    let sent = raw(
        &s,
        "POST",
        &path(&b),
        &user,
        &json!({"id": "bcdefghi", "kind": "message", "text": "alive"}),
    );
    assert_eq!(sent.0, 200, "{sent:?}");
    assert_eq!(received(&mut good)["id"], "bcdefghi");
}
