use std::io::Read;

use serde_json::json;

use crate::harness::{Dir, Headers, Server, Ws, base64, start};

fn serving(s: &Server) -> (String, Ws, Ws, Headers) {
    let pane = s.token_pane("stty raw -echo; exec cat");
    s.text(&pane, "ready\n");
    s.screen_has(&pane, "ready");
    let (client, welcome) = s.client(None);
    let headers = s.client_headers(welcome["client"].as_str().unwrap());
    let mut stream = s
        .dial_ws(
            &format!("/panes/{pane}/webview/serve"),
            Some(s.as_pane(&pane)),
            101,
        )
        .unwrap();
    assert_eq!(stream.event("supported")["supported"], false);
    s.text(&pane, "\x1b]7502;a=enter\x07");
    s.wait_row(&pane, "webview page", |row| {
        row["webview"]["page"]["path"] == "/"
    });
    (pane, stream, client, headers)
}

#[test]
fn webview_proxy_http_auth_streaming_and_failures() {
    let s = start(&[]);
    let (pane, mut stream, _client, headers) = serving(&s);
    let mut capable = s.ws("/client");
    capable.send(
        &json!({"type":"hello","name":"webview","webview":true,"focused":false,"sizing":{"type":"disabled"}}),
    );
    capable.welcome();
    assert_eq!(stream.event("supported")["supported"], true);
    drop(capable);
    assert_eq!(stream.event("supported")["supported"], false);
    let serve_path = format!("/panes/{pane}/webview/serve");
    assert!(s.dial_ws(&serve_path, None, 409).is_none());
    assert!(
        s.dial_ws(&serve_path, Some(s.as_pane(&pane)), 409)
            .is_none()
    );
    let other = s.token_pane("exec cat");
    assert!(
        s.dial_ws(&serve_path, Some(s.as_pane(&other)), 409)
            .is_none()
    );
    let path = format!("/panes/{pane}/webview/assets/main?plain&x=a=b?c");
    assert_eq!(s.exchange("GET", &path, &s.headers(), b"").0, 409);
    assert_eq!(s.exchange("GET", &path, &s.as_pane(&pane), b"").0, 409);
    let mut sent_headers = headers.clone();
    sent_headers.push(("Origin".into(), "ko://pane".into()));
    let mut response = s.send_request("POST", &path, &sent_headers, b"posted");
    let request = stream.event("request");
    assert_eq!(request["path"], "/assets/main?plain&x=a=b?c");
    assert_eq!(request["method"], "POST");
    let pairs = request["headers"].as_array().unwrap();
    assert!(
        !pairs
            .iter()
            .any(|pair| pair[0].as_str().unwrap().eq_ignore_ascii_case("host"))
    );
    assert!(pairs.iter().any(|pair| pair == &json!(["Ko-Pane", pane])));
    assert!(pairs.iter().any(
        |pair| pair[0].as_str().unwrap().eq_ignore_ascii_case("origin") && pair[1] == "ko://pane"
    ));
    assert_eq!(stream.event("body")["data"], base64(b"posted"));
    let req = request["req"].clone();
    stream.send(&json!({"type":"response","req":req,"status":201,"headers":[["content-type","text/plain"],["content-security-policy","script-src 'none'"]]}));
    stream.send(&json!({"type":"body","req":req,"data":base64(b"first"),"more":true}));
    let mut bytes = Vec::new();
    let head = s.read_head(&mut response, &mut bytes);
    assert_eq!(head.status, 201);
    assert!(
        head.headers
            .iter()
            .any(|(key, value)| key.eq_ignore_ascii_case("cache-control") && value == "no-store")
    );
    let policies: Vec<_> = head
        .headers
        .iter()
        .filter(|(key, _)| key.eq_ignore_ascii_case("content-security-policy"))
        .map(|(_, value)| value.as_str())
        .collect();
    assert_eq!(policies.len(), 2);
    assert!(policies.contains(&"script-src 'none'"));
    assert!(
        policies
            .iter()
            .any(|policy| policy.contains("default-src 'self'")
                && policy.contains("frame-src 'none'"))
    );
    stream.send(&json!({"type":"body","req":req,"data":base64(b"second"),"more":false}));
    while !bytes.ends_with(b"0\r\n\r\n") {
        let mut chunk = [0; 1024];
        let n = response.read(&mut chunk).unwrap();
        assert!(n > 0);
        bytes.extend_from_slice(&chunk[..n]);
    }
    assert_eq!(
        &bytes[head.size..],
        b"5\r\nfirst\r\n6\r\nsecond\r\n0\r\n\r\n"
    );
    let waiting = s.send_request("GET", &path, &headers, b"");
    stream.event("request");
    drop(stream);
    assert_eq!(s.read_reply(waiting).0, 502);
    s.wait_row(&pane, "serve stream closed", |row| {
        row["webview"]["serving"] == false
    });
    assert_eq!(s.exchange("GET", &path, &headers, b"").0, 503);
    let mut stream = s.dial_ws(&serve_path, Some(s.as_pane(&pane)), 101).unwrap();
    stream.event("supported");
    let mut response = s.send_request("GET", &path, &headers, b"");
    let request = stream.event("request");
    stream.send(&json!({"type":"response","req":request["req"],"status":200,"headers":[]}));
    stream.send(&json!({"type":"body","req":request["req"],"data":base64(b"partial"),"more":true}));
    let mut bytes = Vec::new();
    let head = s.read_head(&mut response, &mut bytes);
    assert_eq!(head.status, 200);
    drop(stream);
    response.read_to_end(&mut bytes).unwrap();
    assert_eq!(&bytes[head.size..], b"7\r\npartial\r\n");
    let mut stream = s.dial_ws(&serve_path, Some(s.as_pane(&pane)), 101).unwrap();
    stream.event("supported");
    let response = s.send_request("GET", &path, &headers, b"");
    let request = stream.event("request");
    stream.send(&json!({"type":"response","req":request["req"],"status":200,"headers":[["X-Test","ok\r\nInjected: bad"]]}));
    let (status, bytes) = s.read_reply(response);
    assert_eq!(status, 502);
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&bytes).unwrap()["kind"],
        "io"
    );
}

#[test]
fn webview_proxy_framing_errors_have_security_headers() {
    let s = start(&[]);
    let (pane, _stream, _client, headers) = serving(&s);
    for (name, value, status) in [
        ("Transfer-Encoding", "chunked", 411),
        ("Content-Length", "1", 400),
    ] {
        let mut fields = headers.clone();
        fields.push((name.into(), value.into()));
        let mut response = s.send_request("POST", &format!("/panes/{pane}/webview/"), &fields, b"");
        let head = s.read_head(&mut response, &mut Vec::new());
        assert_eq!(head.status, status);
        assert!(
            head.headers
                .iter()
                .any(|(name, value)| name.eq_ignore_ascii_case("cache-control")
                    && value == "no-store")
        );
        assert!(head.headers.iter().any(|(name, value)| {
            name.eq_ignore_ascii_case("content-security-policy")
                && value.contains("default-src 'self'")
        }));
    }
}

#[test]
fn webview_proxy_inflight_limit_cancel_and_body_limit() {
    let s = start(&[]);
    let (pane, mut stream, _client, headers) = serving(&s);
    let path = format!("/panes/{pane}/webview/");
    let mut requests = Vec::new();
    let mut ids = Vec::new();
    for _ in 0..16 {
        requests.push(s.send_request("GET", &path, &headers, b""));
        ids.push(stream.event("request")["req"].clone());
    }
    assert_eq!(s.exchange("GET", &path, &headers, b"").0, 429);
    drop(requests.remove(0));
    assert_eq!(stream.event("cancel")["req"], ids[0]);
    let replacement = s.send_request("PUT", &path, &headers, b"put");
    assert_eq!(stream.event("request")["method"], "PUT");
    drop(replacement);
    stream.event("cancel");
    assert_eq!(
        s.exchange("POST", &path, &headers, &vec![b'x'; (1 << 20) + 1])
            .0,
        400
    );
    drop(stream);
    for request in requests {
        assert_eq!(s.read_reply(request).0, 502);
    }
    s.text(&pane, "\x1b]7502;a=leave\x07");
    s.wait_row(&pane, "webview page left", |row| row["webview"].is_null());
    assert_eq!(s.exchange("GET", &path, &headers, b"").0, 404);
}

#[test]
fn webview_proxy_websocket_frames_close_and_size_limit() {
    let s = start(&[]);
    let (pane, mut stream, _client, mut headers) = serving(&s);
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
    let denied = s.send_request(
        "GET",
        &format!("/panes/{pane}/webview/denied"),
        &headers,
        b"",
    );
    let request = stream.event("upgrade");
    stream.send(&json!({"type":"response","req":request["req"],"status":403,"headers":[]}));
    stream.send(&json!({"type":"body","req":request["req"],"data":"","more":false}));
    assert_eq!(s.read_reply(denied).0, 403);
    let rejected = s.send_request(
        "GET",
        &format!("/panes/{pane}/webview/extensions"),
        &headers,
        b"",
    );
    let request = stream.event("upgrade");
    assert!(!request["headers"].as_array().unwrap().iter().any(|pair| {
        pair[0]
            .as_str()
            .unwrap()
            .eq_ignore_ascii_case("sec-websocket-extensions")
    }));
    stream.send(&json!({"type":"response","req":request["req"],"status":101,"headers":[["Sec-WebSocket-Extensions","permessage-deflate"]]}));
    assert_eq!(s.read_reply(rejected).0, 502);
    assert_eq!(stream.event("close")["code"], 1002);
    let mut socket = s.send_request("GET", &format!("/panes/{pane}/webview/ws?q"), &headers, b"");
    let request = stream.event("upgrade");
    assert_eq!(request["path"], "/ws?q");
    let req = request["req"].clone();
    stream.send(&json!({"type":"response","req":req,"status":101,"headers":[]}));
    let mut bytes = Vec::new();
    let head = s.read_head(&mut socket, &mut bytes);
    assert_eq!(head.status, 101);
    assert_eq!(bytes.len(), head.size);
    let mut socket =
        tungstenite::WebSocket::from_raw_socket(socket, tungstenite::protocol::Role::Client, None);
    socket.send(tungstenite::Message::text("page")).unwrap();
    let frame = stream.event("frame");
    assert_eq!(frame["req"], req);
    assert_eq!(frame["data"], base64(b"page"));
    assert_eq!(frame["binary"], false);
    stream.send(&json!({"type":"frame","req":req,"data":base64(&[0,255]),"binary":true}));
    assert_eq!(
        socket.read().unwrap(),
        tungstenite::Message::binary(vec![0, 255])
    );
    let mut waiting = Vec::new();
    for _ in 0..15 {
        waiting.push(s.send_request(
            "GET",
            &format!("/panes/{pane}/webview/held"),
            &plain_headers,
            b"",
        ));
        stream.event("request");
    }
    assert_eq!(
        s.exchange(
            "GET",
            &format!("/panes/{pane}/webview/held"),
            &plain_headers,
            b""
        )
        .0,
        429
    );
    drop(waiting);
    for _ in 0..15 {
        stream.event("cancel");
    }
    let _ = socket.send(tungstenite::Message::binary(vec![0; 65537]));
    let close = stream.event("close");
    assert_eq!(close["code"], 1009);
    match socket.read().unwrap() {
        tungstenite::Message::Close(Some(close)) => assert_eq!(u16::from(close.code), 1009),
        other => panic!("{other:?}"),
    }
    let mut socket = s.send_request("GET", &format!("/panes/{pane}/webview/ws"), &headers, b"");
    let request = stream.event("upgrade");
    stream.send(&json!({"type":"response","req":request["req"],"status":101,"headers":[]}));
    s.read_head(&mut socket, &mut Vec::new());
    let mut socket =
        tungstenite::WebSocket::from_raw_socket(socket, tungstenite::protocol::Role::Client, None);
    stream.send(
        &json!({"type":"frame","req":request["req"],"data":base64(&vec![0;65537]),"binary":true}),
    );
    match socket.read().unwrap() {
        tungstenite::Message::Close(Some(close)) => assert_eq!(u16::from(close.code), 1009),
        other => panic!("{other:?}"),
    }
    assert_eq!(stream.event("close")["code"], 1009);
    let mut socket = s.send_request("GET", &format!("/panes/{pane}/webview/ws"), &headers, b"");
    let request = stream.event("upgrade");
    stream.send(&json!({"type":"response","req":request["req"],"status":101,"headers":[]}));
    s.read_head(&mut socket, &mut Vec::new());
    let mut socket =
        tungstenite::WebSocket::from_raw_socket(socket, tungstenite::protocol::Role::Client, None);
    stream.send(&json!({"type":"close","req":request["req"],"code":3002,"reason":"program done"}));
    match socket.read().unwrap() {
        tungstenite::Message::Close(Some(close)) => {
            assert_eq!(u16::from(close.code), 3002);
            assert_eq!(close.reason.as_str(), "program done");
        }
        other => panic!("{other:?}"),
    }
    let mut socket = s.send_request("GET", &format!("/panes/{pane}/webview/ws"), &headers, b"");
    let request = stream.event("upgrade");
    stream.send(&json!({"type":"response","req":request["req"],"status":101,"headers":[]}));
    s.read_head(&mut socket, &mut Vec::new());
    let mut socket =
        tungstenite::WebSocket::from_raw_socket(socket, tungstenite::protocol::Role::Client, None);
    drop(stream);
    match socket.read().unwrap() {
        tungstenite::Message::Close(Some(close)) => assert_eq!(u16::from(close.code), 1011),
        other => panic!("{other:?}"),
    }
}

#[test]
fn webview_proxy_runtime_gate_and_serve_identity() {
    let s = crate::runtime::serve_in(
        Dir::new("ko-webviewrt-"),
        r#"
runtimes:
  dev:
    command:
      prefix: ["/bin/sh", "-c", 'exec "$@"', "sh"]
"#,
        &[],
    );
    let pane = s.token_pane_with(json!({"runtime":"dev"}), "stty raw -echo; exec cat");
    s.text(&pane, "ready\n");
    s.screen_has(&pane, "ready");
    let socket = s.dir.join("runtimes/dev/io/socket");
    let serve_path = format!("/panes/{pane}/webview/serve");
    s.dial_ws_on(&socket, &serve_path, None, 409);
    let mut stream = s
        .dial_ws_on(&socket, &serve_path, Some(s.as_pane(&pane)), 101)
        .unwrap();
    assert_eq!(stream.event("supported")["supported"], false);
    let (client, welcome) = s.client(None);
    let mut headers = s.as_pane(&pane);
    headers.push((
        "Ko-Client".into(),
        welcome["client"].as_str().unwrap().into(),
    ));
    assert_eq!(
        s.exchange_on(
            &socket,
            "GET",
            &format!("/panes/{pane}/webview/"),
            &headers,
            b""
        )
        .0,
        409
    );
    drop(client);
}
