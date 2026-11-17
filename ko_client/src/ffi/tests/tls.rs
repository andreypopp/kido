use super::*;
use crate::endpoint::Resolved;
use crate::wire::tests::tls::{Fixtures, accept, server, target};
use std::net::TcpListener;
use std::os::fd::AsFd;

struct SoftwareSigner {
    key: boring::pkey::PKey<boring::pkey::Private>,
    calls: std::sync::atomic::AtomicUsize,
    fail: bool,
}

unsafe extern "C" fn software_sign(
    user: *mut c_void,
    message: *const u8,
    length: usize,
    out: *mut u8,
    capacity: usize,
) -> usize {
    // SAFETY: tests keep the signer alive until the client closes.
    let signer = unsafe { &*user.cast::<SoftwareSigner>() };
    signer.calls.fetch_add(1, Ordering::SeqCst);
    if signer.fail {
        return 0;
    }
    // SAFETY: External passes a readable message for length bytes.
    let message = unsafe { std::slice::from_raw_parts(message, length) };
    let mut operation =
        boring::sign::Signer::new(boring::hash::MessageDigest::sha256(), &signer.key).unwrap();
    operation.update(message).unwrap();
    let signature = operation.sign_to_vec().unwrap();
    assert!(signature.len() <= capacity);
    // SAFETY: External supplies a writable buffer of capacity bytes.
    unsafe { std::ptr::copy_nonoverlapping(signature.as_ptr(), out, signature.len()) };
    signature.len()
}

fn abi_endpoint(
    certificates: &Fixtures,
    port: u16,
    other: bool,
    trusted: bool,
    fail: bool,
) -> (Endpoint, Box<SoftwareSigner>) {
    let certificate = if other {
        &certificates.other_client
    } else {
        &certificates.client
    };
    let signer = Box::new(SoftwareSigner {
        key: boring::pkey::PKey::private_key_from_der(&certificate.key).unwrap(),
        calls: std::sync::atomic::AtomicUsize::new(0),
        fail,
    });
    let identity = identity::Identity {
        certificate: certificate.der.as_ptr(),
        certificate_len: certificate.der.len(),
        sign: Some(software_sign),
        user: std::ptr::from_ref(signer.as_ref()).cast_mut().cast(),
    };
    let raw = identity::Endpoint {
        kind: 2,
        socket: std::ptr::null(),
        host: c"localhost".as_ptr(),
        port,
        identity: &identity,
    };
    let root = if trusted {
        &certificates.root
    } else {
        &certificates.other_root
    };
    // SAFETY: every active field is readable, and signer outlives the returned endpoint.
    let endpoint = unsafe { identity::endpoint(&raw, vec![root.der.clone()]) }.unwrap();
    (endpoint, signer)
}

fn abi_connect(fixture: &Fixture, endpoint: Endpoint) -> *mut Client {
    let mut client = std::ptr::null_mut();
    assert_eq!(
        // SAFETY: fixture owns the live queue and callback storage until close.
        unsafe {
            connect(
                endpoint,
                fixture.queue.0,
                Some(record),
                std::ptr::from_ref(fixture.probe).cast_mut().cast(),
                std::ptr::null(),
                &mut client,
            )
        },
        Code::Ok
    );
    client
}

#[test]
fn abi_tls_connect_accepts_the_pinned_identity() {
    let certificates = Fixtures::new();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let (endpoint, signer) = abi_endpoint(
        &certificates,
        listener.local_addr().unwrap().port(),
        false,
        true,
        false,
    );
    let config = server(&certificates);
    let peer = std::thread::spawn(move || {
        let mut socket = tungstenite::accept(accept(&listener, config)).unwrap();
        assert!(socket.read().unwrap().is_text());
        for message in [
            welcome(INSTANCE, 1),
            layout(0),
            r#"{"type":"selected"}"#.to_owned(),
        ] {
            socket.send(Message::text(message)).unwrap();
        }
        while socket.read().is_ok() {}
    });
    let fixture = Fixture::new();
    let client = abi_connect(&fixture, endpoint);
    assert!(matches!(fixture.next(), Seen::Welcome(..)));
    close(client);
    assert!(signer.calls.load(Ordering::SeqCst) > 0);
    peer.join().unwrap();
}

fn abi_handshake_failure(other: bool, trusted: bool, fail: bool, expected: Code) {
    let certificates = Fixtures::new();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let (endpoint, signer) = abi_endpoint(
        &certificates,
        listener.local_addr().unwrap().port(),
        other,
        trusted,
        fail,
    );
    let config = server(&certificates);
    let peer = std::thread::spawn(move || {
        let mut socket = accept(&listener, config);
        assert!(socket.read(&mut [0]).is_err());
        drop(socket);
        assert_eq!(
            ko_sys::fd::wait(listener.as_fd(), ko_sys::fd::Want::Read, None, Some(QUIET)).unwrap(),
            ko_sys::fd::Waited::TimedOut
        );
    });
    let fixture = Fixture::new();
    let client = abi_connect(&fixture, endpoint);
    assert!(matches!(fixture.next(), Seen::Failed(code, _) if code == expected));
    peer.join().unwrap();
    assert!(signer.calls.load(Ordering::SeqCst) > 0 || !trusted);
    close(client);
}

#[test]
fn abi_tls_connect_reports_identity_refusal() {
    abi_handshake_failure(true, true, false, Code::Identity);
}

#[test]
fn abi_tls_connect_reports_server_certificate_failure() {
    abi_handshake_failure(false, false, false, Code::Tls);
}

#[test]
fn abi_tls_sign_failure_stops_the_handshake() {
    abi_handshake_failure(false, true, true, Code::Identity);
}

#[test]
fn abi_tls_probe_returns_the_server_version() {
    let certificates = Fixtures::new();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let (endpoint, signer) = abi_endpoint(
        &certificates,
        listener.local_addr().unwrap().port(),
        false,
        true,
        false,
    );
    let config = server(&certificates);
    let peer = std::thread::spawn(move || {
        let mut socket = accept(&listener, config);
        let mut head = Vec::new();
        while !head.ends_with(b"\r\n\r\n") {
            let mut byte = [0];
            socket.read_exact(&mut byte).unwrap();
            head.extend(byte);
        }
        assert!(head.starts_with(b"GET /version HTTP/1.1\r\n"));
        let body = protocol::json(&protocol::version());
        write!(
            socket,
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n{}",
            body.len(),
            body
        )
        .unwrap();
        socket.flush().unwrap();
    });
    let mut out = empty_buffer();
    // SAFETY: out is writable and the signer stays alive through the call.
    assert_eq!(unsafe { calls::probe(endpoint, 5000, &mut out) }, Code::Ok);
    assert_eq!(
        // SAFETY: out owns the buffer returned by probe.
        unsafe { contents(&out) },
        protocol::json(&protocol::version())
    );
    // SAFETY: this allocation has not been freed.
    unsafe { freed_once(&mut out) };
    assert!(signer.calls.load(Ordering::SeqCst) > 0);
    peer.join().unwrap();
}

fn tls_client(fixture: &Fixture, target: Arc<crate::endpoint::Tls>) -> *mut Client {
    let client = start(
        Endpoint::Tls(target),
        Greeting {
            name: "tls".to_owned(),
            webview: false,
            focused: false,
            sizing: protocol::Sizing::Disabled,
        },
        Arc::clone(&fixture.queue),
        record,
        User(std::ptr::from_ref(fixture.probe).cast_mut().cast()),
        crate::wire::WATCHDOG,
    )
    .unwrap();
    fixture.probe.client.store(client, Ordering::SeqCst);
    client
}

#[test]
fn an_identity_failure_on_a_view_stops_reconnect() {
    let mut certificates = Fixtures::new();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let Resolved::Tls { target, .. } = target(&certificates, listener.local_addr().unwrap()) else {
        panic!("TLS target");
    };
    let good = server(&certificates);
    std::mem::swap(&mut certificates.client, &mut certificates.other_client);
    let bad = server(&certificates);
    let (checked, check) = channel();
    let peer = std::thread::spawn(move || {
        let mut client = tungstenite::accept(accept(&listener, good)).unwrap();
        assert!(client.read().unwrap().is_text());
        for message in [
            welcome(INSTANCE, 1),
            layout(0),
            r#"{"type":"selected"}"#.to_owned(),
        ] {
            client.send(Message::text(message)).unwrap();
        }
        let client = std::thread::spawn(move || while client.read().is_ok() {});
        let mut view = accept(&listener, bad);
        assert!(view.read(&mut [0]).is_err());
        drop(view);
        client.join().unwrap();
        assert_eq!(
            ko_sys::fd::wait(listener.as_fd(), ko_sys::fd::Want::Read, None, Some(QUIET)).unwrap(),
            ko_sys::fd::Waited::TimedOut
        );
        checked.send(()).unwrap();
    });
    let fixture = Fixture::new();
    let client = tls_client(&fixture, target);
    assert!(matches!(fixture.next(), Seen::Welcome(..)));
    assert!(matches!(fixture.next(), Seen::Layout(..)));
    let view = open_view(
        client,
        Decoder::new(|_| panic!("a refused TLS view restored")),
        true,
    );
    assert!(matches!(fixture.next(), Seen::Failed(Code::Identity, _)));
    check.recv_timeout(WAIT).unwrap();
    close_view(view);
    close(client);
    peer.join().unwrap();
}

#[test]
fn a_proxy_502_retries_as_no_server() {
    let certificates = Fixtures::new();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let Resolved::Tls { target, .. } = target(&certificates, listener.local_addr().unwrap()) else {
        panic!("TLS target");
    };
    let config = server(&certificates);
    let peer = std::thread::spawn(move || {
        let mut unavailable = accept(&listener, Arc::clone(&config));
        let mut head = Vec::new();
        while !head.ends_with(b"\r\n\r\n") {
            let mut byte = [0];
            unavailable.read_exact(&mut byte).unwrap();
            head.extend(byte);
        }
        assert!(head.starts_with(b"GET /client HTTP/1.1\r\n"));
        unavailable
            .write_all(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
            .unwrap();
        unavailable.flush().unwrap();
        drop(unavailable);
        let mut client = tungstenite::accept(accept(&listener, config)).unwrap();
        assert!(client.read().unwrap().is_text());
        for message in [
            welcome(INSTANCE, 1),
            layout(0),
            r#"{"type":"selected"}"#.to_owned(),
        ] {
            client.send(Message::text(message)).unwrap();
        }
        while client.read().is_ok() {}
    });
    let fixture = Fixture::new();
    let client = tls_client(&fixture, target);
    assert!(matches!(fixture.next(), Seen::Failed(Code::NoServer, _)));
    assert!(matches!(fixture.next(), Seen::Welcome(_, _, true)));
    assert!(matches!(fixture.next(), Seen::Layout(..)));
    close(client);
    peer.join().unwrap();
}

#[test]
fn a_tls_view_resumes_its_offset_after_a_partial_frame() {
    let certificates = Fixtures::new();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let Resolved::Tls { target, .. } = target(&certificates, listener.local_addr().unwrap()) else {
        panic!("TLS target");
    };
    let config = server(&certificates);
    let (restored, restore_gate) = channel();
    let (resumed, resumed_rx) = channel();
    let (applied, apply_gate) = channel();
    let peer = std::thread::spawn(move || {
        let mut client = tungstenite::accept(accept(&listener, Arc::clone(&config))).unwrap();
        assert!(client.read().unwrap().is_text());
        for message in [
            welcome(INSTANCE, 1),
            layout(0),
            r#"{"type":"selected"}"#.to_owned(),
        ] {
            client.send(Message::text(message)).unwrap();
        }
        let client = std::thread::spawn(move || while client.read().is_ok() {});
        for reconnect in [false, true] {
            let mut route = String::new();
            #[allow(clippy::result_large_err)]
            let mut view = tungstenite::accept_hdr(
                accept(&listener, Arc::clone(&config)),
                |request: &tungstenite::handshake::server::Request, response| {
                    route = request.uri().to_string();
                    Ok(response)
                },
            )
            .unwrap();
            if !reconnect {
                assert!(!route.contains("offset="));
                view.send(Message::binary(slice_record(10, true, true, true, b"old")))
                    .unwrap();
                restore_gate.recv_timeout(WAIT).unwrap();
                view.send(Message::binary(output_record(10, b"abc")))
                    .unwrap();
                apply_gate.recv_timeout(WAIT).unwrap();
                view.get_mut().write_all(b"\x82\x05x").unwrap();
                view.get_mut().flush().unwrap();
            } else {
                assert!(route.contains("offset=13"), "{route}");
                view.send(Message::binary(output_record(13, b"new")))
                    .unwrap();
                resumed.send(route).unwrap();
                while view.read().is_ok() {}
            }
            drop(view);
        }
        client.join().unwrap();
    });
    let fixture = Fixture::new();
    let client = tls_client(&fixture, target);
    assert!(matches!(fixture.next(), Seen::Welcome(_, _, true)));
    assert!(matches!(fixture.next(), Seen::Layout(..)));
    let (snapshots, snapshot_rx) = channel();
    let decoder = Decoder::new(move |snapshot| {
        snapshots
            .send(pull(snapshot, usize::MAX, 64).unwrap().0)
            .unwrap();
        restored.send(()).unwrap();
        Restored::Ok
    });
    let view = open_view(client, decoder, true);
    assert_eq!(snapshot_rx.recv_timeout(WAIT).unwrap(), b"old");
    decoder.expect_bytes(10, b"abc");
    until("the output offset is committed", || {
        handle_of(view).view.resume_offset() == Some(13)
    });
    applied.send(()).unwrap();
    assert!(resumed_rx.recv_timeout(WAIT).unwrap().contains("offset=13"));
    assert_eq!(model_of(client)["instance"], INSTANCE);
    close_view(view);
    close(client);
    peer.join().unwrap();
}

#[test]
fn a_proxy_going_away_reconnects_to_the_same_instance() {
    let certificates = Fixtures::new();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let Resolved::Tls { target, .. } = target(&certificates, listener.local_addr().unwrap()) else {
        panic!("TLS target");
    };
    let config = server(&certificates);
    let (release, gate) = channel();
    let peer = std::thread::spawn(move || {
        for reconnect in [false, true] {
            let mut socket = tungstenite::accept(accept(&listener, Arc::clone(&config))).unwrap();
            assert!(socket.read().unwrap().is_text());
            socket.send(Message::text(welcome(INSTANCE, 1))).unwrap();
            socket.send(Message::text(layout(0))).unwrap();
            socket
                .send(Message::text(r#"{"type":"selected"}"#))
                .unwrap();
            if !reconnect {
                gate.recv_timeout(WAIT).unwrap();
                socket
                    .close(Some(tungstenite::protocol::CloseFrame {
                        code: tungstenite::protocol::frame::coding::CloseCode::Away,
                        reason: "proxy restart".into(),
                    }))
                    .unwrap();
            } else {
                while socket.read().is_ok() {}
            }
        }
    });
    let fixture = Fixture::new();
    let client = tls_client(&fixture, target);
    assert!(matches!(fixture.next(), Seen::Welcome(_, instance, true) if instance == INSTANCE));
    assert!(matches!(fixture.next(), Seen::Layout(..)));
    release.send(()).unwrap();
    assert!(matches!(fixture.next(), Seen::Failed(Code::Closed, _)));
    assert!(matches!(fixture.next(), Seen::Welcome(_, instance, false) if instance == INSTANCE));
    assert!(matches!(fixture.next(), Seen::Layout(..)));
    close(client);
    peer.join().unwrap();
}

#[test]
fn a_tls_record_failure_after_upgrade_before_welcome_is_final() {
    let certificates = Fixtures::new();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let Resolved::Tls { target, .. } = target(&certificates, listener.local_addr().unwrap()) else {
        panic!("TLS");
    };
    let config = server(&certificates);
    let peer = std::thread::spawn(move || {
        let mut socket = tungstenite::accept(accept(&listener, config)).unwrap();
        assert!(socket.read().unwrap().is_text());
        socket
            .get_mut()
            .get_mut()
            .write_all(&[
                23, 3, 3, 0, 16, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            ])
            .unwrap();
        drop(socket);
        assert_eq!(
            ko_sys::fd::wait(listener.as_fd(), ko_sys::fd::Want::Read, None, Some(QUIET)).unwrap(),
            ko_sys::fd::Waited::TimedOut
        );
    });
    let fixture = Fixture::new();
    let client = tls_client(&fixture, target);
    assert!(matches!(fixture.next(), Seen::Failed(Code::Tls, _)));
    close(client);
    peer.join().unwrap();
}

#[test]
fn a_paused_tls_view_still_drains_a_blocked_send() {
    let certificates = Fixtures::new();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let Resolved::Tls { target, .. } = target(&certificates, listener.local_addr().unwrap()) else {
        panic!("TLS");
    };
    let config = server(&certificates);
    let (resume, pause_gate) = channel();
    let (read, read_gate) = channel();
    let (sent, was_sent) = channel();
    let (barrier, barrier_seen) = channel();
    let peer = std::thread::spawn(move || {
        let mut client = tungstenite::accept(accept(&listener, Arc::clone(&config))).unwrap();
        assert!(client.read().unwrap().is_text());
        for message in [
            welcome(INSTANCE, 1),
            layout(0),
            r#"{"type":"selected"}"#.to_owned(),
        ] {
            client.send(Message::text(message)).unwrap();
        }
        let client = std::thread::spawn(move || {
            let message = client.read().unwrap().into_text().unwrap();
            assert_eq!(
                protocol::decode::<protocol::ClientRequest>(message.as_bytes()).unwrap(),
                protocol::ClientRequest::Focused { focused: true }
            );
            barrier.send(()).unwrap();
            while client.read().is_ok() {}
        });
        let stream = accept(&listener, config);
        ko_sys::sock::set_receive_buffer(stream.get_ref().as_fd(), 64 << 10).unwrap();
        pause_gate.recv_timeout(WAIT).unwrap();
        let mut view = tungstenite::accept(stream).unwrap();
        read_gate.recv_timeout(WAIT).unwrap();
        let message = view.read().unwrap().into_text().unwrap();
        assert_eq!(
            protocol::decode::<protocol::ViewRequest>(message.as_bytes()).unwrap(),
            protocol::ViewRequest::Input {
                input: Input::Text {
                    data: Text(vec![b'x'; 8 << 20])
                }
            }
        );
        sent.send(()).unwrap();
        while view.read().is_ok() {}
        client.join().unwrap();
    });
    let fixture = Fixture::new();
    let client = tls_client(&fixture, target);
    assert!(matches!(fixture.next(), Seen::Welcome(..)));
    assert!(matches!(fixture.next(), Seen::Layout(..)));
    let view = open_view(
        client,
        Decoder::new(|_| panic!("paused view decoded")),
        true,
    );
    let handle = handle_of(view);
    handle.view.pause.store(true, Ordering::SeqCst);
    resume.send(()).unwrap();
    assert!(matches!(
        fixture.links.recv_timeout(WAIT).unwrap(),
        Seen::Link(Code::Ok, _)
    ));
    handle.shared.command(Command::Input(
        handle.view.id,
        Input::Text {
            data: Text(vec![b'x'; 8 << 20]),
        },
    ));
    handle
        .shared
        .command(Command::Request(protocol::ClientRequest::Focused {
            focused: true,
        }));
    barrier_seen.recv_timeout(WAIT).unwrap();
    read.send(()).unwrap();
    was_sent.recv_timeout(WAIT).unwrap();
    close_view(view);
    close(client);
    peer.join().unwrap();
}
