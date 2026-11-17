use super::*;
use crate::endpoint::Resolved;
use crate::wire::tests::tls::{Fixtures, accept, server, target};
use std::net::TcpListener;
use std::os::fd::AsFd;

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
    assert!(matches!(fixture.next(), Seen::Failed(Code::Refused, _)));
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
            .sock
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
    assert!(matches!(fixture.next(), Seen::Failed(Code::Refused, _)));
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
        ko_sys::sock::set_receive_buffer(stream.sock.as_fd(), 64 << 10).unwrap();
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
