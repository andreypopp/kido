use super::*;

fn event(program: &mut Ws, kind: &str) -> Value {
    for _ in 0..128 {
        if let Message::Text(text) = program
            .read()
            .unwrap_or_else(|error| panic!("waiting for {kind}: {error}"))
        {
            let event: Value = serde_json::from_str(text.as_str()).unwrap();
            if event["type"] == kind {
                return event;
            }
        }
        program.flush().unwrap();
    }
    panic!("missing {kind}");
}

#[test]
fn webview_ffi_uses_the_real_proxy_and_cancels_the_program_request() {
    let dir = PathBuf::from(format!("/tmp/ko-ffi-{}-webview-real", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let listener = UnixListener::bind(dir.join("socket")).unwrap();
    let pane_exe = std::env::var_os("KO_PANE_EXE").expect("KO_PANE_EXE names the built ko-pane");
    let mut config = ko_server::config::scratch(&dir, pane_exe.into());
    config.stop_escalation = Duration::from_millis(20);
    let stop = Arc::new(AtomicBool::new(false));
    let stopping = Arc::clone(&stop);
    let (ready, started) = channel();
    let accept = std::thread::spawn(move || {
        let timing = ko_server::server::Timing {
            shutdown_grace: Duration::from_millis(20),
            ..ko_server::server::Timing::DEFAULT
        };
        let mut server = ko_server::server::Server::new(config, listener, timing).unwrap();
        ready.send(()).unwrap();
        while !stopping.load(Ordering::SeqCst) {
            server.turn().unwrap();
        }
        server.stop().unwrap();
        let until = std::time::Instant::now() + WAIT;
        while server.turn().unwrap() != ko_server::server::Status::Stopped {
            assert!(std::time::Instant::now() < until);
        }
    });
    let server = Server {
        dir,
        stop,
        accept: Some(accept),
        requests: Arc::new(Mutex::new(Vec::new())),
    };
    started.recv_timeout(WAIT).unwrap();
    let call = |method: &str, target: &str, body: &[u8]| {
        crate::wire::exchange(
            &server.dir.join("socket"),
            (None, None),
            (method, target),
            &[],
            body,
            crate::wire::Limit::Idle(WAIT),
            None,
        )
        .unwrap()
    };
    let new = serde_json::json!({"cwd":"/tmp","command":{"type":"argv","argv":["/bin/sh","-c","/bin/stty raw -echo; printf 'TOKEN<%s>\\n' \"$KO_PANE_TOKEN\"; printf '\\033]7502;a=enter\\007'; exec /bin/cat"]}});
    let created = call("POST", "/panes", &serde_json::to_vec(&new).unwrap());
    assert_eq!(created.status, 200);
    let created: Value = serde_json::from_slice(&created.body).unwrap();
    let pane = created["pane"].as_str().unwrap();
    assert_eq!(pane, "pane_1");
    let until = std::time::Instant::now() + WAIT;
    let token = loop {
        let screen = call("GET", &format!("/panes/{pane}/screen"), b"");
        assert_eq!(screen.status, 200);
        let screen = String::from_utf8(screen.body).unwrap();
        if let Some((_, tail)) = screen.split_once("TOKEN<")
            && let Some((token, _)) = tail.split_once('>')
        {
            break token.to_owned();
        }
        assert!(
            std::time::Instant::now() < until,
            "pane did not print its token"
        );
    };
    let mut stream = UnixStream::connect(server.dir.join("socket")).unwrap();
    stream.set_read_timeout(Some(WAIT)).unwrap();
    stream.set_write_timeout(Some(WAIT)).unwrap();
    let (request, key) = ko_server::ws::upgrade_request(
        "GET",
        &format!("/panes/{pane}/webview/serve"),
        None,
        &[("Ko-Pane", pane), ("Ko-Pane-Token", &token)],
    );
    stream.write_all(&request).unwrap();
    let ko_server::http::Upgrade::Accepted(response, rest) =
        ko_server::http::read_upgrade(&mut stream).unwrap()
    else {
        panic!("serve refused");
    };
    ko_server::ws::accepted(&response, &key).unwrap();
    let mut program = WebSocket::from_partially_read(stream, rest, Role::Client, None);
    assert_eq!(event(&mut program, "supported")["supported"], false);
    let fixture = Fixture::new();
    let client = fixture.connect(&server);
    assert!(matches!(fixture.next(), Seen::Welcome(..)));
    assert!(matches!(fixture.next(), Seen::Layout(..)));
    assert_eq!(model_of(client)["panes"][0]["webview"]["page"]["path"], "/");
    let (probe, events) = webview_probe(&fixture, || {});
    let callbacks = WebviewFetchCallbacks {
        response: Some(super::response),
        body: Some(super::body),
        end: Some(super::end),
        user: std::ptr::from_ref(probe.as_ref()).cast_mut().cast(),
    };
    let mut handle = std::ptr::null_mut();
    assert_eq!(
        // SAFETY: the client and callback probe are live; all inputs and out are valid.
        unsafe {
            ko_client_webview_fetch(
                client,
                c"pane_1".as_ptr(),
                c"POST".as_ptr(),
                c"/api?q=1".as_ptr(),
                std::ptr::null(),
                0,
                b"posted".as_ptr(),
                6,
                &callbacks,
                &mut handle,
            )
        },
        Code::Ok
    );
    let request = event(&mut program, "request");
    assert_eq!(request["method"], "POST");
    assert_eq!(request["path"], "/api?q=1");
    assert_eq!(event(&mut program, "body")["data"], "cG9zdGVk");
    let req = request["req"].clone();
    send(&mut program,&serde_json::json!({"type":"response","req":req,"status":201,"headers":[["content-type","text/html"]]}).to_string());
    send(
        &mut program,
        &serde_json::json!({"type":"body","req":req,"data":"b25l","more":true}).to_string(),
    );
    assert!(matches!(next(&events), WebviewSeen::Response(201, _)));
    assert_eq!(next(&events), WebviewSeen::Body(b"one".to_vec()));
    send(
        &mut program,
        &serde_json::json!({"type":"body","req":req,"data":"dHdv","more":false}).to_string(),
    );
    assert_eq!(next(&events), WebviewSeen::Body(b"two".to_vec()));
    assert_eq!(next(&events), WebviewSeen::End(Code::Ok, String::new()));
    cancel_fetch(handle);
    let handle = fetch(client, &probe, c"/events");
    let req = event(&mut program, "request")["req"].clone();
    send(
        &mut program,
        &serde_json::json!({"type":"response","req":req,"status":200,"headers":[["content-type","application/x-ndjson"]]}).to_string(),
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
    let (stop, stopped) = channel();
    let writer = std::thread::spawn(move || {
        for (i, record) in records.into_iter().enumerate() {
            assert!(
                stopped
                    .recv_timeout(Duration::from_micros([170, 2300, 490, 7100, 40][i % 5]))
                    .is_err()
            );
            let data = ko_server::protocol::webview::Data::new(record.into_bytes()).unwrap();
            send(
                &mut program,
                &serde_json::json!({"type":"body","req":req,"data":data,"more":true}).to_string(),
            );
        }
        stopped.recv_timeout(WAIT).unwrap();
        program
    });
    assert!(matches!(next(&events), WebviewSeen::Response(200, _)));
    let mut received = Vec::new();
    let deadline = std::time::Instant::now() + WAIT;
    while received.len() < expected.len() {
        match events
            .recv_timeout(deadline.saturating_duration_since(std::time::Instant::now()))
            .unwrap_or_else(|error| {
                panic!(
                    "FFI stream stalled: received {} of {} bytes: {error}",
                    received.len(),
                    expected.len()
                )
            }) {
            (WebviewSeen::Body(bytes), true) => received.extend(bytes),
            other => panic!("unexpected {other:?}"),
        }
    }
    assert_eq!(received, expected.as_bytes());
    stop.send(()).unwrap();
    let mut program = writer.join().unwrap();
    cancel_fetch(handle);
    event(&mut program, "cancel");
    let handle = fetch(client, &probe, c"/missing");
    let req = event(&mut program, "request")["req"].clone();
    send(
        &mut program,
        &serde_json::json!({"type":"response","req":req,"status":404,"headers":[]}).to_string(),
    );
    send(
        &mut program,
        &serde_json::json!({"type":"body","req":req,"data":"bm8=","more":false}).to_string(),
    );
    assert!(matches!(next(&events), WebviewSeen::Response(404, _)));
    assert_eq!(next(&events), WebviewSeen::Body(b"no".to_vec()));
    assert_eq!(next(&events), WebviewSeen::End(Code::Ok, String::new()));
    cancel_fetch(handle);
    let handle = fetch(client, &probe, c"/cancel");
    let req = event(&mut program, "request")["req"].clone();
    send(
        &mut program,
        &serde_json::json!({"type":"response","req":req,"status":200,"headers":[]}).to_string(),
    );
    send(
        &mut program,
        &serde_json::json!({"type":"body","req":req,"data":"b25l","more":true}).to_string(),
    );
    assert!(matches!(next(&events), WebviewSeen::Response(200, _)));
    assert!(matches!(next(&events), WebviewSeen::Body(_)));
    cancel_fetch(handle);
    assert_eq!(event(&mut program, "cancel")["req"], req);
    fixture.flush();
    assert!(events.try_recv().is_err());
    let handle = socket(client, &probe, c"/ws?q=1");
    let request = event(&mut program, "upgrade");
    assert_eq!(request["path"], "/ws?q=1");
    let req = request["req"].clone();
    send(
        &mut program,
        &serde_json::json!({"type":"response","req":req,"status":101,"headers":[]}).to_string(),
    );
    assert!(matches!(next(&events), WebviewSeen::Response(101, _)));
    for (data, binary, encoded) in [
        (b"hi".as_slice(), false, "aGk="),
        ([0, 255].as_slice(), true, "AP8="),
    ] {
        assert_eq!(
            // SAFETY: the open socket and message bytes are live for this call.
            unsafe { ko_webview_ws_send(handle, data.as_ptr(), data.len(), binary) },
            Code::Ok
        );
        let frame = event(&mut program, "frame");
        assert_eq!(frame["binary"], binary);
        assert_eq!(frame["data"], encoded);
        send(
            &mut program,
            &serde_json::json!({"type":"frame","req":req,"data":encoded,"binary":binary})
                .to_string(),
        );
        assert_eq!(next(&events), WebviewSeen::Message(data.to_vec(), binary));
    }
    assert_eq!(
        // SAFETY: the socket and reason are live.
        unsafe { ko_webview_ws_close(handle, 1000, c"bye".as_ptr()) },
        Code::Ok
    );
    let closed = event(&mut program, "close");
    assert_eq!(closed["code"], 1000);
    assert_eq!(closed["reason"], "bye");
    assert_eq!(
        next(&events),
        WebviewSeen::Close(Code::Ok, 1000, "bye".into())
    );
    cancel_socket(handle);
    let handle = fetch(client, &probe, c"/client-close");
    let req = event(&mut program, "request")["req"].clone();
    send(
        &mut program,
        &serde_json::json!({"type":"response","req":req,"status":200,"headers":[]}).to_string(),
    );
    send(
        &mut program,
        &serde_json::json!({"type":"body","req":req,"data":"b25l","more":true}).to_string(),
    );
    assert!(matches!(next(&events), WebviewSeen::Response(200, _)));
    assert!(matches!(next(&events), WebviewSeen::Body(_)));
    close(client);
    cancel_fetch(handle);
    assert_eq!(event(&mut program, "cancel")["req"], req);
    fixture.flush();
    assert!(events.try_recv().is_err());
}
