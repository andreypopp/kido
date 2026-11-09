use super::*;

mod real;

unsafe extern "C" {
    fn dispatch_queue_set_specific(
        queue: *mut c_void,
        key: *const c_void,
        context: *mut c_void,
        destructor: Option<extern "C" fn(*mut c_void)>,
    );
    fn dispatch_get_specific(key: *const c_void) -> *mut c_void;
}
static KEY: u8 = 0;

#[derive(Debug, PartialEq, Eq)]
enum WebviewSeen {
    Response(u16, Vec<(String, String)>),
    Body(Vec<u8>),
    End(Code, String),
    Message(Vec<u8>, bool),
    Close(Code, u16, String),
}
struct WebviewProbe {
    events: Sender<(WebviewSeen, bool)>,
    on_body: Box<dyn Fn() + Send + Sync>,
}

fn webview_record(user: *mut c_void, event: WebviewSeen) {
    // SAFETY: each test retains its probe until cancellation and the queue flush.
    let probe = unsafe { &*user.cast::<WebviewProbe>() };
    // SAFETY: KEY is static and each test sets its own live queue context.
    let on_queue = unsafe { dispatch_get_specific(std::ptr::from_ref(&KEY).cast()) } == user;
    let _ = probe.events.send((event, on_queue));
}
unsafe extern "C" fn response(
    user: *mut c_void,
    status: u16,
    headers: *const WebviewHeader,
    count: usize,
) {
    // SAFETY: the core supplies count readable records for this callback.
    let headers = unsafe { std::slice::from_raw_parts(headers, count) }
        .iter()
        .map(|header| {
            // SAFETY: each header's strings are NUL-terminated during the callback.
            unsafe { (owned(header.name), owned(header.value)) }
        })
        .collect();
    webview_record(user, WebviewSeen::Response(status, headers));
}
unsafe extern "C" fn body(user: *mut c_void, data: *const u8, len: usize) {
    // SAFETY: the core supplies len readable bytes and a live user pointer.
    let (data, probe) = unsafe {
        (
            std::slice::from_raw_parts(data, len).to_vec(),
            &*user.cast::<WebviewProbe>(),
        )
    };
    webview_record(user, WebviewSeen::Body(data));
    (probe.on_body)();
}
unsafe extern "C" fn end(user: *mut c_void, result: Code, message: *const c_char) {
    // SAFETY: the core passes a NUL-terminated message during the callback.
    webview_record(user, WebviewSeen::End(result, unsafe { owned(message) }));
}
unsafe extern "C" fn message(user: *mut c_void, data: *const u8, len: usize, binary: bool) {
    // SAFETY: the core supplies len readable bytes during the callback.
    webview_record(
        user,
        WebviewSeen::Message(
            unsafe { std::slice::from_raw_parts(data, len) }.to_vec(),
            binary,
        ),
    );
}
unsafe extern "C" fn socket_close(
    user: *mut c_void,
    result: Code,
    code: u16,
    reason: *const c_char,
) {
    // SAFETY: the core passes a NUL-terminated reason during the callback.
    webview_record(
        user,
        WebviewSeen::Close(result, code, unsafe { owned(reason) }),
    );
}

fn webview_probe(
    fixture: &Fixture,
    on_body: impl Fn() + Send + Sync + 'static,
) -> (Box<WebviewProbe>, Receiver<(WebviewSeen, bool)>) {
    let (events, receiver) = channel();
    let mut probe = Box::new(WebviewProbe {
        events,
        on_body: Box::new(on_body),
    });
    // SAFETY: fixture owns a serial queue and probe outlives all callbacks.
    unsafe {
        dispatch_queue_set_specific(
            fixture.queue.0,
            std::ptr::from_ref(&KEY).cast(),
            std::ptr::from_mut(probe.as_mut()).cast(),
            None,
        );
    }
    (probe, receiver)
}
fn next(events: &Receiver<(WebviewSeen, bool)>) -> WebviewSeen {
    let (event, on_queue) = events.recv_timeout(WAIT).unwrap();
    assert!(on_queue);
    event
}
fn fetch(client: *mut Client, probe: &WebviewProbe, path: &CStr) -> *mut WebviewHandle {
    let callbacks = WebviewFetchCallbacks {
        response: Some(response),
        body: Some(body),
        end: Some(end),
        user: std::ptr::from_ref(probe).cast_mut().cast(),
    };
    let mut handle = std::ptr::null_mut();
    assert_eq!(
        // SAFETY: inputs are live and the probe outlives the request and callback queue.
        unsafe {
            ko_client_webview_fetch(
                client,
                c"pane_1".as_ptr(),
                c"GET".as_ptr(),
                path.as_ptr(),
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                &callbacks,
                &mut handle,
            )
        },
        Code::Ok
    );
    handle
}
fn socket(client: *mut Client, probe: &WebviewProbe, path: &CStr) -> *mut WebviewHandle {
    let callbacks = WebviewSocketCallbacks {
        open: Some(response),
        message: Some(message),
        close: Some(socket_close),
        user: std::ptr::from_ref(probe).cast_mut().cast(),
    };
    let mut handle = std::ptr::null_mut();
    assert_eq!(
        // SAFETY: all inputs are live and callbacks retain their probe until cancellation.
        unsafe {
            ko_client_webview_ws_open(
                client,
                c"pane_1".as_ptr(),
                path.as_ptr(),
                std::ptr::null(),
                0,
                &callbacks,
                &mut handle,
            )
        },
        Code::Ok
    );
    handle
}
fn cancel_fetch(handle: *mut WebviewHandle) {
    // SAFETY: each handle is live and consumed once here.
    assert_eq!(unsafe { ko_webview_fetch_cancel(handle) }, Code::Ok);
}
fn cancel_socket(handle: *mut WebviewHandle) {
    // SAFETY: each handle is live and consumed once here.
    assert_eq!(unsafe { ko_webview_ws_cancel(handle) }, Code::Ok);
}
fn idle(socket: &mut Ws, _: String) {
    welcomed(socket);
    wait_for_hangup(socket);
}

#[test]
fn webview_fetch_streams_headers_query_body_and_client_identity() {
    let (release, gate) = channel();
    let gate = Mutex::new(gate);
    let server=serve("webview-stream",client_script(|socket,hello| {
        assert_eq!(serde_json::from_str::<Value>(&hello).unwrap()["webview"],true);
        welcomed(socket);wait_for_hangup(socket);
    }).raw(move |request,stream| {
        if !request.target.contains("/webview") {return false;}
        if request.target.ends_with("/encoded") {
            stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 3\r\n\r\nabc").unwrap();return true;
        }
        if request.target.ends_with("/bytes") {
            stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Encoding: identity\r\nContent-Length: 4\r\n\r\n\x00\x80\xffx").unwrap();return true;
        }
        if request.target.ends_with("/broken") {
            stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 20\r\n\r\nshort").unwrap();return true;
        }
        assert_eq!((request.method.as_str(),request.target.as_str(),request.body.as_slice()),("POST","/panes/pane_1/webview/api?q=a%20b",b"input".as_slice()));
        assert_eq!(header(&request.head,"Ko-Client"),Some("client_7"));
        assert_eq!(header(&request.head,"X-Input"),Some("value"));
        assert_eq!(header(&request.head,"Ko-Pane"),None);
        stream.set_write_timeout(Some(WAIT)).unwrap();
        stream.write_all(b"HTTP/1.1 201 Created\r\nContent-Type: text/html\r\nTransfer-Encoding: chunked\r\nConnection: X-Private\r\nX-Private: hidden\r\nProxy-Custom: hidden\r\nX-Reply: yes\r\n\r\n3\r\none\r\n").unwrap();
        locked(&gate).recv_timeout(WAIT).unwrap();
        stream.write_all(b"3\r\ntwo\r\n0\r\n\r\n").unwrap();true
    }));
    let fixture = Fixture::new();
    let client = fixture.connect_as(
        &server,
        Some(Greeting {
            name: "app".to_owned(),
            webview: true,
            focused: false,
            sizing: protocol::Sizing::Disabled,
        }),
        crate::wire::WATCHDOG,
    );
    assert!(matches!(fixture.next(), Seen::Welcome(..)));
    assert!(matches!(fixture.next(), Seen::Layout(..)));
    let (probe, events) = webview_probe(&fixture, || {});
    let callbacks = WebviewFetchCallbacks {
        response: Some(response),
        body: Some(body),
        end: Some(end),
        user: std::ptr::from_ref(probe.as_ref()).cast_mut().cast(),
    };
    let headers = [WebviewHeader {
        name: c"X-Input".as_ptr(),
        value: c"value".as_ptr(),
    }];
    let mut handle = std::ptr::null_mut();
    assert_eq!(
        // SAFETY: client and inputs are live; out is writable and the probe stays alive.
        unsafe {
            ko_client_webview_fetch(
                client,
                c"pane_1".as_ptr(),
                c"POST".as_ptr(),
                c"/api?q=a%20b".as_ptr(),
                headers.as_ptr(),
                headers.len(),
                b"input".as_ptr(),
                5,
                &callbacks,
                &mut handle,
            )
        },
        Code::Ok
    );
    let WebviewSeen::Response(status, headers) = next(&events) else {
        panic!("missing response");
    };
    assert_eq!(status, 201);
    assert!(
        headers
            .iter()
            .any(|(name, value)| name.eq_ignore_ascii_case("x-reply") && value == "yes")
    );
    assert!(!headers.iter().any(|(name, _)| {
        [
            "transfer-encoding",
            "content-length",
            "connection",
            "x-private",
            "proxy-custom",
        ]
        .contains(&name.as_str())
    }));
    assert_eq!(next(&events), WebviewSeen::Body(b"one".to_vec()));
    release.send(()).unwrap();
    assert_eq!(next(&events), WebviewSeen::Body(b"two".to_vec()));
    assert_eq!(next(&events), WebviewSeen::End(Code::Ok, String::new()));
    cancel_fetch(handle);
    let encoded = fetch(client, &probe, c"/encoded");
    let WebviewSeen::End(code, message) = next(&events) else {
        panic!("encoded head reached callback")
    };
    assert_ne!(code, Code::Ok);
    assert!(message.contains("gzip"));
    cancel_fetch(encoded);
    let bytes = fetch(client, &probe, c"/bytes");
    assert!(matches!(next(&events), WebviewSeen::Response(200, _)));
    assert_eq!(next(&events), WebviewSeen::Body(b"\x00\x80\xffx".to_vec()));
    assert_eq!(next(&events), WebviewSeen::End(Code::Ok, String::new()));
    cancel_fetch(bytes);
    let broken = fetch(client, &probe, c"/broken");
    assert!(matches!(next(&events), WebviewSeen::Response(200, _)));
    assert_eq!(next(&events), WebviewSeen::Body(b"short".to_vec()));
    assert!(matches!(next(&events), WebviewSeen::End(Code::Closed, _)));
    cancel_fetch(broken);
    close(client);
    fixture.flush();
    assert!(events.try_recv().is_err());
}

#[test]
fn webview_fetch_cancel_joins_io_and_running_callbacks_and_can_run_in_a_callback() {
    let (lost, hangups) = channel();
    let (started, connections) = channel();
    let server = serve(
        "webview-cancel",
        client_script(idle).raw(move |request, stream| {
            if !request.target.contains("/webview") {
                return false;
            }
            stream.set_write_timeout(Some(WAIT)).unwrap();
            stream
                .write_all(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\none\r\n")
                .unwrap();
            started.send(()).unwrap();
            let mut byte = [0];
            assert_eq!(stream.read(&mut byte).unwrap(), 0);
            lost.send(()).unwrap();
            true
        }),
    );
    let fixture = Fixture::new();
    let client = fixture.connect(&server);
    assert!(matches!(fixture.next(), Seen::Welcome(..)));
    assert!(matches!(fixture.next(), Seen::Layout(..)));
    let (release, gate) = channel();
    let gate = Mutex::new(gate);
    let (probe, events) = webview_probe(&fixture, move || {
        let _ = locked(&gate).recv_timeout(WAIT);
    });
    let handle = fetch(client, &probe, c"/cancel");
    connections.recv_timeout(WAIT).unwrap();
    assert!(matches!(next(&events), WebviewSeen::Response(200, _)));
    assert!(matches!(next(&events), WebviewSeen::Body(_)));
    let (done, finished) = channel();
    let handle = handle as usize;
    let cancel = std::thread::spawn(move || {
        // SAFETY: this thread owns the only live handle and cancels it once.
        let result = unsafe { ko_webview_fetch_cancel(handle as *mut WebviewHandle) };
        done.send(result).unwrap();
    });
    hangups.recv_timeout(WAIT).unwrap();
    assert!(finished.try_recv().is_err());
    release.send(()).unwrap();
    assert_eq!(finished.recv_timeout(WAIT).unwrap(), Code::Ok);
    cancel.join().unwrap();
    fixture.flush();
    assert!(events.try_recv().is_err());

    let handle = Arc::new(AtomicPtr::<WebviewHandle>::new(std::ptr::null_mut()));
    let saved = Arc::clone(&handle);
    let (done, finished) = channel();
    let (self_probe, self_events) = webview_probe(&fixture, move || {
        let handle = saved.swap(std::ptr::null_mut(), Ordering::SeqCst);
        // SAFETY: the test sets this live handle before it resumes the callback queue.
        let result = unsafe { ko_webview_fetch_cancel(handle) };
        let _ = done.send(result);
    });
    // SAFETY: fixture owns the live queue; it resumes below.
    unsafe {
        dispatch_suspend(fixture.queue.0);
    }
    handle.store(
        fetch(client, &self_probe, c"/self-cancel"),
        Ordering::SeqCst,
    );
    connections.recv_timeout(WAIT).unwrap();
    // SAFETY: the queue was suspended once above.
    unsafe {
        dispatch_resume(fixture.queue.0);
    }
    assert!(matches!(next(&self_events), WebviewSeen::Response(..)));
    assert!(matches!(next(&self_events), WebviewSeen::Body(_)));
    assert_eq!(finished.recv_timeout(WAIT).unwrap(), Code::Ok);
    hangups.recv_timeout(WAIT).unwrap();
    fixture.flush();
    assert!(self_events.try_recv().is_err());
    // SAFETY: the queue is live; it resumes after client close.
    unsafe {
        dispatch_suspend(fixture.queue.0);
    }
    let pending = fetch(client, &self_probe, c"/close-client");
    connections.recv_timeout(WAIT).unwrap();
    close(client);
    cancel_fetch(pending);
    hangups.recv_timeout(WAIT).unwrap();
    // SAFETY: the queue was suspended once above.
    unsafe {
        dispatch_resume(fixture.queue.0);
    }
    fixture.flush();
    assert!(self_events.try_recv().is_err());
}

#[test]
fn webview_websocket_types_buffered_amount_close_and_cancel() {
    let (release, gate) = channel();
    let (lost, hangups) = channel();
    let lost2 = lost.clone();
    let (accepted, upgrades) = channel();
    let accepted2 = accepted.clone();
    let server = serve(
        "webview-sockets",
        client_script(idle)
            .view(move |socket, _| {
                send(socket, "first");
                send_binary(socket, vec![0, 255]);
                assert_eq!(socket.read().unwrap(), Message::text("text"));
                send(socket, "echo");
                gate.recv_timeout(WAIT).unwrap();
                for _ in 0..16 {
                    assert_eq!(
                        socket.read().unwrap().into_data().len(),
                        protocol::EXEC_CHUNK
                    );
                }
                send(socket, "drained");
                let Message::Close(Some(frame)) = socket.read().unwrap() else {
                    panic!("missing close");
                };
                assert_eq!(
                    (u16::from(frame.code), frame.reason.as_str()),
                    (1000, "bye")
                );
                socket.flush().unwrap();
            })
            .view(move |socket, _| {
                send(socket, "queued");
                accepted.send(()).unwrap();
                wait_for_hangup(socket);
                lost.send(()).unwrap();
            })
            .view(move |socket, _| {
                send(socket, "queued-close");
                accepted2.send(()).unwrap();
                wait_for_hangup(socket);
                lost2.send(()).unwrap();
            }),
    );
    let fixture = Fixture::new();
    let client = fixture.connect(&server);
    assert!(matches!(fixture.next(), Seen::Welcome(..)));
    assert!(matches!(fixture.next(), Seen::Layout(..)));
    let (probe, events) = webview_probe(&fixture, || {});
    let handle = socket(client, &probe, c"/ws?q=1");
    assert!(matches!(next(&events), WebviewSeen::Response(101, _)));
    assert_eq!(
        next(&events),
        WebviewSeen::Message(b"first".to_vec(), false)
    );
    assert_eq!(next(&events), WebviewSeen::Message(vec![0, 255], true));
    assert_eq!(
        // SAFETY: handle and text bytes are live.
        unsafe { ko_webview_ws_send(handle, b"text".as_ptr(), 4, false) },
        Code::Ok
    );
    assert_eq!(next(&events), WebviewSeen::Message(b"echo".to_vec(), false));
    let data = vec![7; protocol::EXEC_CHUNK];
    for _ in 0..16 {
        assert_eq!(
            // SAFETY: the socket and payload stay live for the call.
            unsafe { ko_webview_ws_send(handle, data.as_ptr(), data.len(), true) },
            Code::Ok
        );
    }
    // SAFETY: the socket handle is live.
    assert!(unsafe { ko_webview_ws_buffered_amount(handle) } > 0);
    release.send(()).unwrap();
    assert_eq!(
        next(&events),
        WebviewSeen::Message(b"drained".to_vec(), false)
    );
    // SAFETY: the socket is open and all payload bytes reached its peer.
    assert_eq!(unsafe { ko_webview_ws_buffered_amount(handle) }, 0);
    assert_eq!(
        // SAFETY: the socket and NUL-terminated reason are live.
        unsafe { ko_webview_ws_close(handle, 1000, c"bye".as_ptr()) },
        Code::Ok
    );
    assert_eq!(
        next(&events),
        WebviewSeen::Close(Code::Ok, 1000, "bye".into())
    );
    cancel_socket(handle);
    let heads = server.heads("GET", "/panes/pane_1/webview/ws?q=1");
    assert_eq!(heads.len(), 1);
    assert_eq!(header(&heads[0], "Ko-Client"), Some("client_7"));
    // SAFETY: the serial queue is live and resumes below.
    unsafe {
        dispatch_suspend(fixture.queue.0);
    }
    let pending = socket(client, &probe, c"/cancel-ws");
    upgrades.recv_timeout(WAIT).unwrap();
    cancel_socket(pending);
    hangups.recv_timeout(WAIT).unwrap();
    // SAFETY: the queue was suspended once above.
    unsafe {
        dispatch_resume(fixture.queue.0);
    }
    fixture.flush();
    assert!(events.try_recv().is_err());
    // SAFETY: the queue remains live and resumes after client close.
    unsafe {
        dispatch_suspend(fixture.queue.0);
    }
    let pending = socket(client, &probe, c"/close-client");
    upgrades.recv_timeout(WAIT).unwrap();
    close(client);
    cancel_socket(pending);
    hangups.recv_timeout(WAIT).unwrap();
    // SAFETY: the queue was suspended once above.
    unsafe {
        dispatch_resume(fixture.queue.0);
    }
    fixture.flush();
    assert!(events.try_recv().is_err());
}
