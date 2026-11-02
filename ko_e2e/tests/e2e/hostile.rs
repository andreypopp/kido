use std::io::{Read, Write};
use std::net::Shutdown;
use std::time::{Duration, Instant};

use serde_json::json;

use crate::harness::{DEADLINE, Hello, start, within};

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
    let hostile: Vec<Vec<u8>> = vec![
        format!(
            "GET /version HTTP/1.1\r\nHost: ko\r\n{}\r\n",
            "A: b\r\n".repeat(20000)
        )
        .into_bytes(),
        format!("POST /panes HTTP/1.1\r\nHost: ko\r\n{head}Content-Length: 99999999999\r\n\r\n{{")
            .into_bytes(),
        format!("POST /panes HTTP/1.1\r\nHost: ko\r\n{head}Transfer-Encoding: chunked\r\n\r\n{{}}")
            .into_bytes(),
        b"\x16\x03\x01\x02\x00\x01\x00\x01\xfc\x03\x03".to_vec(),
        after(&[
            0x81, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0,
        ]),
        after(&[0x01, 0x80, 0, 0, 0, 0, 0x80, 0x80, 0, 0, 0, 0]),
        after(&[0x89, 0x80, 0, 0, 0, 0].repeat(5000)),
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

    let grid = |cols: u32, rows: u32| json!({"cols": cols, "rows": rows, "cell_px": {"width": 65535, "height": 65535}});
    let hello = |cols: u32, rows: u32| {
        s.hello(Hello {
            pane: None,
            focused: true,
            size: grid(cols, rows),
        })
    };
    let mut c = hello(4096, 4096);
    c.welcome();
    c.send(&json!(["size", grid(4097, 24)]));
    c.closed("size 4097 accepted");
    let mut c = hello(4097, 24);
    c.closed("hello 4097 accepted");
    s.request("GET", "/version", None, 200);
}
