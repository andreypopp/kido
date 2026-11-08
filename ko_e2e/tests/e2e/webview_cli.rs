use std::io::{Read, Write};
use std::os::fd::AsFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::mpsc;
use std::time::Instant;

use serde_json::json;
use tungstenite::Message;

use crate::harness::{
    DEADLINE, Run, Server, chunk, dechunk, ko, poll, quote, run_ko, start, test_env, text_of,
    within,
};

fn webview(s: &Server, pane: Option<&str>, args: &[&str], stdin: &str) -> Run {
    let mut env = test_env(&s.dir);
    if let Some(pane) = pane {
        env.push(format!("KO_PANE={pane}").into_bytes());
        env.push(format!("KO_SOCKET={}", s.dir.join("socket").display()).into_bytes());
        if let Some(token) = s.token(pane) {
            env.push(format!("KO_PANE_TOKEN={token}").into_bytes());
        }
    }
    let mut argv = vec!["--server", text_of(&s.dir), "webview"];
    argv.extend_from_slice(args);
    run_ko(&s.scratch, &env, &argv, stdin)
}

fn accept(listener: &UnixListener) -> UnixStream {
    assert_eq!(
        ko_sys::fd::wait(
            listener.as_fd(),
            ko_sys::fd::Want::Read,
            None,
            Some(DEADLINE)
        )
        .unwrap(),
        ko_sys::fd::Waited::Ready
    );
    let (stream, _) = listener.accept().unwrap();
    within(&stream, Instant::now() + DEADLINE);
    stream
}

fn read_head(stream: &mut UnixStream) -> Vec<u8> {
    let deadline = Instant::now() + DEADLINE;
    let mut head = Vec::new();
    while !head.ends_with(b"\r\n\r\n") {
        within(stream, deadline);
        let mut byte = [0];
        stream.read_exact(&mut byte).unwrap();
        head.push(byte[0]);
        assert!(head.len() <= 16384);
    }
    head
}

#[test]
fn webview_cli_streams_irregular_chunks_without_a_later_write() {
    let s = start(&[]);
    let socket = s.scratch.join("events.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let pane = s.token_pane(&format!(
        "{} webview enter; exec {} webview serve --socket {}",
        quote(text_of(&ko())),
        quote(text_of(&ko())),
        quote(text_of(&socket))
    ));
    s.wait_row(&pane, "webview bridge", |row| {
        row["webview"]["serving"] == true
    });
    let (_client, welcome) = s.client(None);
    let headers = s.client_headers(welcome["client"].as_str().unwrap());
    let mut response = s.send_request(
        "GET",
        &format!("/panes/{pane}/webview/events"),
        &headers,
        b"",
    );
    let records: Vec<_> = (0..96)
        .map(|i| {
            format!(
                "{{\"record\":{i},\"pad\":\"{}\"}}\n",
                "x".repeat([0, 71, 4093, 60000][(i + 1) % 4])
            )
        })
        .collect();
    let expected = records.concat();
    let (stop, stopped) = mpsc::channel();
    let writer = std::thread::spawn(move || {
        let mut stream = accept(&listener);
        read_head(&mut stream);
        stream.write_all(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Type: application/x-ndjson\r\n\r\n").unwrap();
        for (i, record) in records.iter().enumerate() {
            assert!(
                stopped
                    .recv_timeout(std::time::Duration::from_micros(
                        [170, 2300, 490, 7100, 40][i % 5]
                    ))
                    .is_err()
            );
            write!(stream, "{:x}\r\n{record}\r\n", record.len()).unwrap();
        }
        stopped.recv_timeout(DEADLINE).unwrap();
    });
    let mut body = Vec::new();
    let mut raw = Vec::new();
    let head = s.read_head(&mut response, &mut raw);
    assert_eq!(head.status, 200);
    raw.drain(..head.size);
    let deadline = Instant::now() + DEADLINE;
    while body.len() < expected.len() {
        while let Some((used, bytes)) = chunk(&raw) {
            assert!(!bytes.is_empty());
            body.extend_from_slice(bytes);
            raw.drain(..used);
        }
        if body.len() == expected.len() {
            break;
        }
        within(&response, deadline);
        let mut bytes = [0; 4096];
        let count = response.read(&mut bytes).unwrap_or_else(|error| {
            panic!(
                "stream stalled: received {} of {} bytes: {error}",
                body.len(),
                expected.len()
            )
        });
        assert_ne!(count, 0);
        raw.extend_from_slice(&bytes[..count]);
    }
    assert_eq!(body, expected.as_bytes());
    stop.send(()).unwrap();
    writer.join().unwrap();
}

#[test]
fn webview_cli_closing_socket_drains_a_blocked_program_writer() {
    let s = start(&[]);
    let socket = s.scratch.join("drain.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let first = listener.try_clone().unwrap();
    let toy = std::thread::spawn(move || tungstenite::accept(accept(&first)).unwrap());
    let pane = s.token_pane(&format!(
        "{} webview enter; exec {} webview serve --socket {}",
        quote(text_of(&ko())),
        quote(text_of(&ko())),
        quote(text_of(&socket))
    ));
    s.wait_row(&pane, "webview bridge", |row| {
        row["webview"]["serving"] == true
    });
    let (_client, welcome) = s.client(None);
    let plain = s.client_headers(welcome["client"].as_str().unwrap());
    let mut headers = plain.clone();
    headers.extend([
        ("Upgrade".into(), "websocket".into()),
        ("Connection".into(), "Upgrade".into()),
        ("Sec-WebSocket-Version".into(), "13".into()),
        (
            "Sec-WebSocket-Key".into(),
            "dGhlIHNhbXBsZSBub25jZQ==".into(),
        ),
    ]);
    let mut socket = s.send_request("GET", &format!("/panes/{pane}/webview/ws"), &headers, b"");
    let mut bytes = Vec::new();
    let head = s.read_head(&mut socket, &mut bytes);
    assert_eq!(head.status, 101);
    let mut page = tungstenite::WebSocket::from_partially_read(
        socket,
        bytes.split_off(head.size),
        tungstenite::protocol::Role::Client,
        None,
    );
    let mut program = toy.join().unwrap();
    ko_sys::sock::set_receive_buffer(program.get_ref().as_fd(), 4096).unwrap();
    for _ in 0..8 {
        page.send(Message::binary(vec![7; 65536])).unwrap();
    }
    page.close(Some(tungstenite::protocol::CloseFrame {
        code: tungstenite::protocol::frame::coding::CloseCode::Normal,
        reason: "finished".into(),
    }))
    .unwrap();
    assert!(matches!(page.read().unwrap(), Message::Close(_)));
    let response = s.send_request("GET", &format!("/panes/{pane}/webview/marker"), &plain, b"");
    let mut marker = accept(&listener);
    let request = read_head(&mut marker);
    assert!(request.starts_with(b"GET /marker HTTP/1.1\r\n"));
    marker
        .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
        .unwrap();
    assert_eq!(s.read_reply(response), (200, b"ok".to_vec()));
    for _ in 0..8 {
        assert_eq!(program.read().unwrap(), Message::binary(vec![7; 65536]));
    }
    match program.read().unwrap() {
        Message::Close(Some(close)) => {
            assert_eq!(u16::from(close.code), 1000);
            assert_eq!(close.reason.as_str(), "finished");
        }
        other => panic!("{other:?}"),
    }
    assert_eq!(s.row(&pane)["webview"]["serving"], true);
}

#[test]
fn webview_cli_escapes_and_unix_http_websocket_bridge() {
    let s = start(&[]);
    assert_eq!(
        webview(&s, None, &["enter"], "").ok(),
        "\x1b]7502;a=enter\x07"
    );
    assert_eq!(
        webview(&s, None, &["enter", "--path", "/page?q=1"], "").ok(),
        "\x1b]7502;a=enter:p=L3BhZ2U/cT0x\x07"
    );
    assert_eq!(
        webview(&s, None, &["leave"], "").ok(),
        "\x1b]7502;a=leave\x07"
    );
    assert!(
        webview(&s, None, &["enter", "--path", "relative"], "")
            .error(1)
            .contains("path must start with /")
    );
    let socket = s.scratch.join("webview.sock");
    assert!(
        webview(&s, None, &["serve", "--socket", text_of(&socket)], "")
            .error(6)
            .contains("requires a pane identity")
    );
    let listener = UnixListener::bind(&socket).unwrap();
    let (release, gate) = mpsc::sync_channel(1);
    let (seen, request_seen) = mpsc::sync_channel(1);
    let toy = std::thread::spawn(move || {
        let mut stream = accept(&listener);
        let deadline = Instant::now() + DEADLINE;
        let mut bytes = Vec::new();
        let size = loop {
            within(&stream, deadline);
            let mut chunk = [0; 1024];
            let count = stream.read(&mut chunk).unwrap();
            assert!(count > 0);
            bytes.extend_from_slice(&chunk[..count]);
            let mut headers = [httparse::EMPTY_HEADER; 64];
            let mut request = httparse::Request::new(&mut headers);
            if let httparse::Status::Complete(size) = request.parse(&bytes).unwrap() {
                assert_eq!(request.method, Some("POST"));
                assert_eq!(request.path, Some("/page?q=1"));
                assert!(
                    request
                        .headers
                        .iter()
                        .any(|header| header.name.eq_ignore_ascii_case("host")
                            && header.value == b"localhost")
                );
                assert!(
                    request
                        .headers
                        .iter()
                        .any(|header| header.name.eq_ignore_ascii_case("ko-pane")
                            && header.value.starts_with(b"pane_"))
                );
                assert!(
                    request
                        .headers
                        .iter()
                        .any(|header| header.name.eq_ignore_ascii_case("content-length")
                            && header.value == b"4")
                );
                break size;
            }
            assert!(bytes.len() <= 16384);
        };
        while bytes.len() < size + 4 {
            within(&stream, deadline);
            let mut chunk = [0; 1024];
            let count = stream.read(&mut chunk).unwrap();
            assert!(count > 0);
            bytes.extend_from_slice(&chunk[..count]);
        }
        assert_eq!(&bytes[size..], b"post");
        stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nTransfer-Encoding: chunked\r\n\r\n3\r\n<p>\r\n").unwrap();
        gate.recv_timeout(DEADLINE).unwrap();
        stream.write_all(b"4\r\npage\r\n0\r\n\r\n").unwrap();
        drop(stream);
        let stream = accept(&listener);
        // tungstenite requires an unboxed HTTP response as the callback's error.
        #[allow(clippy::result_large_err)]
        let validate = |wanted: &'static str, extension: Option<&'static str>| {
            move |request: &tungstenite::handshake::server::Request,
                  mut response: tungstenite::handshake::server::Response| {
                assert_eq!(request.uri().to_string(), wanted);
                assert_eq!(request.headers().get("host").unwrap(), "localhost");
                assert!(request.headers().get("sec-websocket-extensions").is_none());
                if let Some(extension) = extension {
                    response
                        .headers_mut()
                        .insert("Sec-WebSocket-Extensions", extension.parse().unwrap());
                }
                Ok(response)
            }
        };
        let mut ws = tungstenite::accept_hdr(stream, validate("/ws?echo", None)).unwrap();
        assert_eq!(ws.read().unwrap(), Message::text("page"));
        ws.send(Message::text("program")).unwrap();
        ws.send(Message::binary(vec![0, 255])).unwrap();
        match ws.read().unwrap() {
            Message::Close(Some(close)) => {
                assert_eq!(u16::from(close.code), 3001);
                assert_eq!(close.reason.as_str(), "finished");
            }
            other => panic!("{other:?}"),
        }
        let _ = ws.flush();
        let mut stream = accept(&listener);
        let deadline = Instant::now() + DEADLINE;
        let mut bytes = Vec::new();
        while !bytes.windows(4).any(|bytes| bytes == b"\r\n\r\n") {
            within(&stream, deadline);
            let mut chunk = [0; 1024];
            let count = stream.read(&mut chunk).unwrap();
            assert!(count > 0);
            bytes.extend_from_slice(&chunk[..count]);
            assert!(bytes.len() <= 16384);
        }
        assert!(bytes.starts_with(b"GET /cancel HTTP/1.1\r\n"));
        seen.send(()).unwrap();
        within(&stream, deadline);
        assert_eq!(stream.read(&mut [0; 1]).unwrap(), 0);
        let mut ws = tungstenite::accept_hdr(accept(&listener), validate("/large", None)).unwrap();
        let mut header = vec![0x82, 0x7f];
        header.extend_from_slice(&65537u64.to_be_bytes());
        ws.get_mut().write_all(&header).unwrap();
        match ws.read().unwrap() {
            Message::Close(Some(close)) => assert_eq!(u16::from(close.code), 1009),
            other => panic!("{other:?}"),
        }
        let mut ws = tungstenite::accept_hdr(
            accept(&listener),
            validate("/extension", Some("permessage-deflate")),
        )
        .unwrap();
        assert!(ws.read().is_err());
    });
    let output = s.scratch.join("supported.jsonl");
    let pane = s.token_pane(&format!(
        "{} webview enter --path /page; exec {} webview serve --socket {} > {}",
        quote(text_of(&ko())),
        quote(text_of(&ko())),
        quote(text_of(&socket)),
        quote(text_of(&output))
    ));
    s.wait_row(&pane, "webview bridge", |row| {
        row["webview"]["serving"] == true
    });
    assert_eq!(s.row(&pane)["webview"]["page"]["path"], "/page");
    let unsupported = "{\"type\":\"supported\",\"supported\":false}\n";
    let supported = "{\"type\":\"supported\",\"supported\":true}\n";
    poll("bridge's initial supported line", || {
        std::fs::read_to_string(&output).unwrap_or_default() == unsupported
    });
    let mut capable = s.ws("/client");
    capable.send(
        &json!({"type":"hello","name":"webview","webview":true,"focused":false,"sizing":{"type":"disabled"}}),
    );
    capable.welcome();
    poll("bridge's supported change", || {
        std::fs::read_to_string(&output).unwrap_or_default() == format!("{unsupported}{supported}")
    });
    drop(capable);
    poll("bridge's unsupported change", || {
        std::fs::read_to_string(&output).unwrap_or_default()
            == format!("{unsupported}{supported}{unsupported}")
    });
    let duplicate = webview(
        &s,
        Some(&pane),
        &["serve", "--socket", text_of(&socket)],
        "",
    );
    assert!(
        duplicate
            .error(1)
            .contains("the pane already has a webview stream")
    );
    let (_client, welcome) = s.client(None);
    let mut headers = s.client_headers(welcome["client"].as_str().unwrap());
    let mut response = s.send_request(
        "POST",
        &format!("/panes/{pane}/webview/page?q=1"),
        &headers,
        b"post",
    );
    let mut bytes = Vec::new();
    let head = s.read_head(&mut response, &mut bytes);
    assert_eq!(head.status, 200);
    while !bytes.windows(3).any(|bytes| bytes == b"<p>") {
        let mut chunk = [0; 1024];
        let n = response.read(&mut chunk).unwrap();
        assert!(n > 0);
        bytes.extend_from_slice(&chunk[..n]);
    }
    release.send(()).unwrap();
    while !bytes.ends_with(b"0\r\n\r\n") {
        let mut chunk = [0; 1024];
        let n = response.read(&mut chunk).unwrap();
        assert!(n > 0);
        bytes.extend_from_slice(&chunk[..n]);
    }
    assert_eq!(dechunk(&bytes[head.size..]).unwrap(), b"<p>page");
    let plain_headers = headers.clone();
    headers.extend([
        ("Upgrade".into(), "websocket".into()),
        ("Connection".into(), "Upgrade".into()),
        ("Sec-WebSocket-Version".into(), "13".into()),
        (
            "Sec-WebSocket-Extensions".into(),
            "permessage-deflate".into(),
        ),
        (
            "Sec-WebSocket-Key".into(),
            "dGhlIHNhbXBsZSBub25jZQ==".into(),
        ),
    ]);
    let mut socket = s.send_request(
        "GET",
        &format!("/panes/{pane}/webview/ws?echo"),
        &headers,
        b"",
    );
    let head = s.read_head(&mut socket, &mut Vec::new());
    assert_eq!(head.status, 101);
    let mut socket =
        tungstenite::WebSocket::from_raw_socket(socket, tungstenite::protocol::Role::Client, None);
    socket.send(Message::text("page")).unwrap();
    assert_eq!(socket.read().unwrap(), Message::text("program"));
    assert_eq!(socket.read().unwrap(), Message::binary(vec![0, 255]));
    socket
        .close(Some(tungstenite::protocol::CloseFrame {
            code: 3001.into(),
            reason: "finished".into(),
        }))
        .unwrap();
    let canceled = s.send_request(
        "GET",
        &format!("/panes/{pane}/webview/cancel"),
        &plain_headers,
        b"",
    );
    request_seen.recv_timeout(DEADLINE).unwrap();
    drop(canceled);
    let mut socket = s.send_request(
        "GET",
        &format!("/panes/{pane}/webview/large"),
        &headers,
        b"",
    );
    let mut bytes = Vec::new();
    let head = s.read_head(&mut socket, &mut bytes);
    assert_eq!(head.status, 101);
    let mut socket = tungstenite::WebSocket::from_partially_read(
        socket,
        bytes.split_off(head.size),
        tungstenite::protocol::Role::Client,
        None,
    );
    match socket.read().unwrap() {
        Message::Close(Some(close)) => assert_eq!(u16::from(close.code), 1009),
        other => panic!("{other:?}"),
    }
    let rejected = s.send_request(
        "GET",
        &format!("/panes/{pane}/webview/extension"),
        &headers,
        b"",
    );
    assert_eq!(s.read_reply(rejected).0, 502);
    toy.join().unwrap();
    assert_eq!(
        s.exchange(
            "GET",
            &format!("/panes/{pane}/webview/missing"),
            &plain_headers,
            b""
        )
        .0,
        502
    );
    assert_eq!(s.row(&pane)["webview"]["serving"], true);
    let caller = s.token_pane("exec cat");
    webview(
        &s,
        Some(&caller),
        &[
            "serve",
            "--socket",
            text_of(&s.scratch.join("missing.sock")),
        ],
        "",
    )
    .ok();
    s.wait_row(&caller, "bridge ends with stdin", |row| {
        row["webview"].is_null()
    });
    s.request(
        "POST",
        &format!("/panes/{pane}/stop"),
        Some(&json!({})),
        200,
    );
}
