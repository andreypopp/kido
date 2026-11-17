use super::*;
use crate::wire::exchange::RequestHead as Request;
use crate::wire::quic::h3::Connection;
use ko_wire::protocol::Method;

struct HttpPeer {
    peer: Peer,
    http: Option<quiche::h3::Connection>,
    sending: Vec<(u64, Vec<u8>, usize)>,
    blocked: bool,
    upload: Option<(u64, Vec<u8>)>,
    read_upload: bool,
}

impl HttpPeer {
    fn new(peer: Peer) -> Self {
        Self {
            peer,
            http: None,
            sending: Vec::new(),
            blocked: false,
            upload: None,
            read_upload: false,
        }
    }
    fn progress(&mut self) {
        self.peer.receive();
        let Some(transport) = &mut self.peer.connection else {
            return;
        };
        if transport.is_established() && self.http.is_none() {
            let mut config = quiche::h3::Config::new().unwrap();
            config.enable_extended_connect(true);
            self.http = Some(quiche::h3::Connection::with_transport(transport, &config).unwrap());
        }
        if let Some(http) = &mut self.http {
            while let Ok((id, event)) = http.poll(transport) {
                if let quiche::h3::Event::Headers { list, .. } = event {
                    use quiche::h3::NameValue;
                    let path = list
                        .iter()
                        .find(|header| header.name() == b":path")
                        .unwrap()
                        .value();
                    if path == b"/upload" || path.starts_with(b"/panes/") {
                        if path.ends_with(b"name=file") {
                            assert_eq!(
                                list.iter()
                                    .find(|header| header.name() == b"content-length")
                                    .unwrap()
                                    .value(),
                                b"150000"
                            );
                        }
                        self.upload = Some((id, Vec::new()));
                        continue;
                    }
                    if path == b"/version" {
                        transport.close(true, 0x100, b"before response").unwrap();
                        continue;
                    }
                    if path == b"/socket" || path == b"/client" {
                        for (name, value) in [
                            (b":method".as_slice(), b"CONNECT".as_slice()),
                            (b":protocol", b"websocket"),
                            (b":scheme", b"https"),
                            (b":authority", b"localhost"),
                            (b"sec-websocket-version", b"13"),
                        ] {
                            assert_eq!(
                                list.iter()
                                    .find(|header| header.name() == name)
                                    .unwrap()
                                    .value(),
                                value
                            );
                        }
                        assert!(!list.iter().any(|header| matches!(
                            header.name(),
                            b"connection" | b"upgrade" | b"sec-websocket-key"
                        )));
                    }
                    if path == b"/page"
                        || (path == b"/socket"
                            && list.iter().any(|header| header.name() == b"ko-client"))
                    {
                        assert_eq!(
                            list.iter()
                                .find(|header| header.name() == b"ko-client")
                                .unwrap()
                                .value(),
                            b"client_7"
                        );
                        assert_eq!(
                            list.iter()
                                .find(|header| header.name() == b"accept-encoding")
                                .unwrap()
                                .value(),
                            b"identity"
                        );
                        assert!(!list.iter().any(|header| matches!(
                            header.name(),
                            b"x-hidden" | b"ko-pane" | b"connection"
                        )));
                    }
                    if path == b"/client" {
                        for (name, value) in ko_wire::protocol::version_headers() {
                            let name = name.to_ascii_lowercase();
                            assert_eq!(
                                list.iter()
                                    .find(|header| header.name() == name.as_bytes())
                                    .unwrap()
                                    .value(),
                                value.as_bytes()
                            );
                        }
                    }
                    let body = match path {
                        b"/large" => vec![b'x'; 2 << 20],
                        b"/socket" | b"/client" => {
                            use tungstenite::protocol::frame::{
                                Frame,
                                coding::{Data, OpCode},
                            };
                            let (payload, opcode) = if path == b"/client" {
                                (vec![b'x'; 32 << 20], Data::Binary)
                            } else {
                                (b"done".to_vec(), Data::Text)
                            };
                            let mut bytes = Vec::new();
                            Frame::message(payload, OpCode::Data(opcode), true)
                                .format(&mut bytes)
                                .unwrap();
                            bytes
                        }
                        _ => b"done".to_vec(),
                    };
                    if path == b"/interim" {
                        http.send_response(
                            transport,
                            id,
                            &[quiche::h3::Header::new(b":status", b"103")],
                            true,
                        )
                        .unwrap();
                        continue;
                    }
                    let mut response = vec![quiche::h3::Header::new(b":status", b"200")];
                    if path == b"/short" {
                        response.push(quiche::h3::Header::new(b"content-length", b"5"));
                    }
                    if path == b"/long" {
                        response.push(quiche::h3::Header::new(b"content-length", b"3"));
                    }
                    if path == b"/conflict" {
                        response.extend([
                            quiche::h3::Header::new(b"content-length", b"3"),
                            quiche::h3::Header::new(b"content-length", b"4"),
                        ]);
                    }
                    if path == b"/no-body" {
                        http.send_response(
                            transport,
                            id,
                            &[
                                quiche::h3::Header::new(b":status", b"304"),
                                quiche::h3::Header::new(b"content-length", b"99"),
                            ],
                            true,
                        )
                        .unwrap();
                        continue;
                    }
                    http.send_response(transport, id, &response, false).unwrap();
                    self.sending.push((id, body, 0));
                }
            }
            if self.read_upload
                && let Some((id, body)) = &mut self.upload
            {
                let mut bytes = [0; 65536];
                loop {
                    match http.recv_body(transport, *id, &mut bytes) {
                        Ok(count) => body.extend_from_slice(&bytes[..count]),
                        Err(quiche::h3::Error::Done) => break,
                        Err(error) => panic!("{error}"),
                    }
                }
                if body.len() == 150000 {
                    assert_eq!(*body, vec![b'u'; 150000]);
                    http.send_response(
                        transport,
                        *id,
                        &[quiche::h3::Header::new(b":status", b"200")],
                        false,
                    )
                    .unwrap();
                    self.sending.push((*id, b"done".to_vec(), 0));
                    self.read_upload = false;
                }
            }
            for (id, bytes, at) in &mut self.sending {
                if *at == bytes.len() {
                    continue;
                }
                match http.send_body(transport, *id, &bytes[*at..], true) {
                    Ok(count) => *at += count,
                    Err(quiche::h3::Error::Done | quiche::h3::Error::StreamBlocked) => {
                        self.blocked = true
                    }
                    Err(error) => panic!("{error}"),
                }
            }
        }
        self.peer.flush();
    }
}

fn turn(
    poll: &mut Poll,
    owner: &mut Connection,
    peer: &mut HttpPeer,
    deadline: Instant,
) -> io::Result<()> {
    assert!(Instant::now() < deadline);
    peer.progress();
    let mut events = Events::default();
    poll.turn(Mode::Peek, &mut events).unwrap();
    for ready in events.ready() {
        if ready.token != peer.peer.token {
            owner.ready(poll, poll.wants(*ready))?;
        }
    }
    for due in events.due() {
        owner.due(poll, *due)?;
    }
    owner.finish_turn(poll)?;
    Ok(())
}

fn request(path: &str) -> Request {
    Request::Http {
        method: Method::Get,
        target: path.to_owned().try_into().unwrap(),
        headers: Vec::new(),
        length: 0,
    }
}

#[test]
fn a_large_websocket_and_page_streams_share_one_h3_connection() {
    let (mut poll, driver, peer, signatures) = setup(Scenario::Accepted);
    let (mut owner, access) = Connection::new(driver, &mut poll, "localhost".to_owned()).unwrap();
    let mut peer = HttpPeer::new(peer);
    let (sent, received) = std::sync::mpsc::channel();
    let worker = std::thread::spawn(move || {
        let endpoint = crate::endpoint::Resolved::Quic(access);
        let mut link = crate::wire::Link::connect_within(
            &endpoint,
            None,
            &ko_wire::api::Route::Client {},
            None,
            Duration::from_secs(5),
        )
        .unwrap();
        let crate::wire::Next::Binary(bytes) = link.receive().unwrap() else {
            panic!("binary message missing");
        };
        assert_eq!(bytes.len(), 32 << 20);
        assert!(bytes.iter().all(|byte| *byte == b'x'));
        use crate::webview::{Event, Kind, Upstream};
        use crate::wire::exchange::Destination;
        use ko_wire::protocol::webview::{FrameKind, Headers};
        for (path, kind) in [
            ("/page", Kind::Http(Method::Get)),
            ("/socket", Kind::Upgrade),
        ] {
            let mut poll = Poll::new();
            let timer = poll.timer();
            poll.start(timer, Duration::from_secs(5), None).unwrap();
            let mut events = Events::default();
            let mut upstream = Upstream::open(
                &mut poll,
                &endpoint,
                kind,
                &path.to_owned().try_into().unwrap(),
                &Headers::try_from(vec![
                    ("Connection".to_owned(), "x-hidden".to_owned()),
                    ("X-Hidden".to_owned(), "no".to_owned()),
                    ("Ko-Client".to_owned(), "spoof".to_owned()),
                    ("Ko-Pane".to_owned(), "spoof".to_owned()),
                    ("Accept-Encoding".to_owned(), "gzip".to_owned()),
                ])
                .unwrap(),
                Destination::Server {
                    client: Some("client_7".parse().unwrap()),
                    caller: None,
                },
                b"",
            )
            .unwrap();
            let mut body = Vec::new();
            'reply: loop {
                upstream.begin_turn();
                upstream.flush(&mut poll).unwrap();
                while let Some(event) = upstream.next(&mut poll).unwrap() {
                    match event {
                        Event::Response(head) | Event::Upgraded(head) => {
                            assert_eq!(head.status, 200)
                        }
                        Event::Body(bytes) => body.extend(bytes),
                        Event::End => {
                            assert_eq!(body, b"done");
                            break 'reply;
                        }
                        Event::Message { data, binary } => {
                            assert_eq!(data.as_ref(), b"done");
                            assert_eq!(binary, FrameKind::Text);
                            break 'reply;
                        }
                        event => panic!("unexpected page event: {event:?}"),
                    }
                }
                upstream.interest(&mut poll, true);
                poll.turn(Mode::Wait, &mut events).unwrap();
                assert!(events.due().is_empty(), "page deadline");
            }
            upstream.dispose(&mut poll);
        }
        sent.send(()).unwrap();
    });
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        match received.try_recv() {
            Ok(()) | Err(std::sync::mpsc::TryRecvError::Disconnected) => break,
            Err(std::sync::mpsc::TryRecvError::Empty) => {
                turn(&mut poll, &mut owner, &mut peer, deadline).unwrap()
            }
        }
    }
    worker.join().unwrap();
    assert_eq!(signatures.load(Ordering::SeqCst), 1);
    owner.detach(&mut poll, io::ErrorKind::ConnectionReset.into());
}

#[test]
fn h3_progress_runs_once_only_after_an_owned_event() {
    let (mut poll, driver, _peer, _) = setup(Scenario::Accepted);
    let (mut owner, access) = Connection::new(driver, &mut poll, "localhost".to_owned()).unwrap();
    let unrelated = ko_sys::event::Wake::new().unwrap();
    let token = poll.watch(unrelated.fd(), Interest::Read);
    let handle = access.open(request("/small")).unwrap();
    assert!(
        !owner
            .ready(
                &mut poll,
                ko_sys::event::Ready {
                    token,
                    read: true,
                    write: false
                }
            )
            .unwrap()
    );
    assert!(!owner.finish_turn(&mut poll).unwrap());
    let mut events = Events::default();
    poll.turn(Mode::Peek, &mut events).unwrap();
    let mut handled = false;
    for ready in events.ready() {
        handled |= owner.ready(&mut poll, *ready).unwrap();
    }
    assert!(handled);
    assert!(owner.finish_turn(&mut poll).unwrap());
    assert!(!owner.finish_turn(&mut poll).unwrap());
    drop(handle);
    poll.unwatch(token);
    owner.detach(&mut poll, io::ErrorKind::Interrupted.into());
}

#[test]
fn h3_content_length_is_checked_by_the_shared_exchange() {
    let (mut poll, driver, peer, _) = setup(Scenario::Accepted);
    let (mut owner, access) = Connection::new(driver, &mut poll, "localhost".to_owned()).unwrap();
    let mut peer = HttpPeer::new(peer);
    let (sent, received) = std::sync::mpsc::channel();
    let worker = std::thread::spawn(move || {
        use crate::wire::exchange::{Body, Destination, Exchange, Request, RequestKind};
        let endpoint = crate::endpoint::Resolved::Quic(access);
        let mut results = Vec::new();
        for path in ["/short", "/long", "/conflict", "/no-body"] {
            let mut poll = Poll::new();
            let timer = poll.timer();
            poll.start(timer, Duration::from_secs(5), None).unwrap();
            let mut exchange = Exchange::start(
                &mut poll,
                &endpoint,
                Request {
                    kind: RequestKind::Http {
                        method: Method::Get,
                        target: path.to_owned().try_into().unwrap(),
                        headers: Vec::new(),
                        body: Body::Complete(b""),
                    },
                    destination: Destination::Server {
                        client: None,
                        caller: None,
                    },
                },
                crate::wire::Limit::Idle(Duration::from_secs(5)),
            )
            .unwrap();
            let result = (|| -> io::Result<usize> {
                let mut count = 0;
                loop {
                    exchange.begin_turn();
                    exchange.flush(&mut poll)?;
                    while let Some(event) = exchange.next(&mut poll).map_err(io::Error::from)? {
                        match event {
                            ko_wire::http::response::Event::Body(bytes) => count += bytes.len(),
                            ko_wire::http::response::Event::End => return Ok(count),
                            _ => {}
                        }
                    }
                    exchange.interest(&mut poll, true);
                    let mut events = Events::default();
                    poll.turn(Mode::Wait, &mut events)?;
                    if !events.due().is_empty() {
                        return Err(io::ErrorKind::TimedOut.into());
                    }
                }
            })();
            exchange.dispose(&mut poll);
            results.push(result);
        }
        sent.send(results).unwrap();
    });
    let deadline = Instant::now() + Duration::from_secs(5);
    let results = loop {
        match received.try_recv() {
            Ok(results) => break results,
            Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                worker.join().unwrap();
                panic!("exchange worker stopped");
            }
            Err(std::sync::mpsc::TryRecvError::Empty) => {
                turn(&mut poll, &mut owner, &mut peer, deadline).unwrap()
            }
        }
    };
    worker.join().unwrap();
    owner.detach(&mut poll, io::ErrorKind::ConnectionReset.into());
    let mut results = results.into_iter();
    for kind in [
        io::ErrorKind::UnexpectedEof,
        io::ErrorKind::InvalidData,
        io::ErrorKind::InvalidData,
    ] {
        assert_eq!(results.next().unwrap().unwrap_err().kind(), kind);
    }
    assert_eq!(results.next().unwrap().unwrap(), 0);
    assert!(results.next().is_none());
}

#[test]
fn h3_fin_before_final_headers_is_a_stream_error_and_a_sibling_completes() {
    let (mut poll, driver, peer, _) = setup(Scenario::Accepted);
    let (mut owner, access) = Connection::new(driver, &mut poll, "localhost".to_owned()).unwrap();
    let mut peer = HttpPeer::new(peer);
    let mut interim = access.open(request("/interim")).unwrap();
    let mut sibling = access.open(request("/small")).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        turn(&mut poll, &mut owner, &mut peer, deadline).unwrap();
        match interim.read(&mut [0; 1]) {
            Ok(0) => break,
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
            result => panic!("unexpected interim body: {result:?}"),
        }
    }
    let error = interim.response().unwrap_err();
    assert!(matches!(
        error
            .get_ref()
            .and_then(|error| error.downcast_ref::<crate::wire::quic::h3::StreamFailure>()),
        Some(crate::wire::quic::h3::StreamFailure::Protocol(_))
    ));
    while sibling.response().unwrap().is_none() {
        turn(&mut poll, &mut owner, &mut peer, deadline).unwrap();
    }
    let mut bytes = [0; 4];
    loop {
        match sibling.read(&mut bytes) {
            Ok(4) => break,
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                turn(&mut poll, &mut owner, &mut peer, deadline).unwrap()
            }
            result => panic!("unexpected sibling body: {result:?}"),
        }
    }
    assert_eq!(&bytes, b"done");
    owner.detach(&mut poll, io::ErrorKind::ConnectionReset.into());
}

#[test]
fn an_empty_request_lost_after_h3_headers_is_unanswered() {
    let (mut poll, driver, peer, _) = setup(Scenario::Accepted);
    let (mut owner, access) = Connection::new(driver, &mut poll, "localhost".to_owned()).unwrap();
    let mut peer = HttpPeer::new(peer);
    let (sent, received) = std::sync::mpsc::channel();
    let worker = std::thread::spawn(move || {
        let endpoint = crate::endpoint::Resolved::Quic(access);
        sent.send(crate::wire::request_within(
            &endpoint,
            (None, None),
            &ko_wire::api::Route::Version {},
            b"",
            (None, Duration::from_secs(5)),
        ))
        .unwrap();
    });
    let deadline = Instant::now() + Duration::from_secs(5);
    let error = loop {
        if let Err(error) = turn(&mut poll, &mut owner, &mut peer, deadline) {
            break error;
        }
    };
    owner.detach(&mut poll, error);
    let result = received.recv_timeout(Duration::from_secs(5)).unwrap();
    worker.join().unwrap();
    assert!(
        matches!(result, Err(crate::wire::Rejected::Unanswered(_))),
        "{result:?}"
    );
}

#[test]
fn a_full_h3_receive_mailbox_does_not_stop_another_stream_and_resumes_exactly() {
    let (mut poll, driver, peer, _) = setup(Scenario::Accepted);
    let (mut owner, access) = Connection::new(driver, &mut poll, "localhost".to_owned()).unwrap();
    let mut peer = HttpPeer::new(peer);
    let mut large = access.open(request("/large")).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while !peer.blocked {
        turn(&mut poll, &mut owner, &mut peer, deadline).unwrap();
    }
    let mut small = access.open(request("/small")).unwrap();
    let mut received = Vec::new();
    while received.len() != 4 {
        turn(&mut poll, &mut owner, &mut peer, deadline).unwrap();
        let mut bytes = [0; 4096];
        match small.read(&mut bytes) {
            Ok(count) => received.extend_from_slice(&bytes[..count]),
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
            Err(error) => panic!("{error}"),
        }
    }
    assert_eq!(received, b"done");
    assert_eq!(small.response().unwrap().unwrap().status, 200);
    let mut received = Vec::new();
    while received.len() != 2 << 20 {
        turn(&mut poll, &mut owner, &mut peer, deadline).unwrap();
        let mut bytes = [0; 65536];
        match large.read(&mut bytes) {
            Ok(count) => received.extend_from_slice(&bytes[..count]),
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
            Err(error) => panic!("{error}"),
        }
    }
    assert_eq!(received, vec![b'x'; 2 << 20]);
    owner.detach(&mut poll, io::ErrorKind::ConnectionReset.into());
}

#[test]
fn a_flow_blocked_h3_upload_does_not_stop_another_stream_and_resumes_exactly() {
    let (mut poll, driver, peer, _) = setup(Scenario::Accepted);
    let (mut owner, access) = Connection::new(driver, &mut poll, "localhost".to_owned()).unwrap();
    let mut peer = HttpPeer::new(peer);
    let body = vec![b'u'; 2 << 20];
    let mut upload = access
        .open(Request::Http {
            method: Method::Post,
            target: "/upload".to_owned().try_into().unwrap(),
            headers: Vec::new(),
            length: body.len(),
        })
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut written = 0;
    while written < 2 * 65536 {
        turn(&mut poll, &mut owner, &mut peer, deadline).unwrap();
        match upload.write(&body[written..]) {
            Ok(count) => written += count,
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
            Err(error) => panic!("{error}"),
        }
    }
    let mut small = access.open(request("/small")).unwrap();
    loop {
        turn(&mut poll, &mut owner, &mut peer, deadline).unwrap();
        match small.read(&mut [0; 4]) {
            Ok(count) => {
                assert_eq!(count, 4);
                break;
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
            Err(error) => panic!("{error}"),
        }
    }
    assert!(upload.pending_write());
    assert!(written < body.len());
    peer.read_upload = true;
    while peer.upload.as_ref().map_or(0, |(_, bytes)| bytes.len()) != body.len() {
        turn(&mut poll, &mut owner, &mut peer, deadline).unwrap();
        if written < body.len() {
            match upload.write(&body[written..]) {
                Ok(count) => written += count,
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                Err(error) => panic!("{error}"),
            }
        }
    }
    assert_eq!(peer.upload.unwrap().1, body);
    owner.detach(&mut poll, io::ErrorKind::ConnectionReset.into());
}

#[cfg(all(target_vendor = "apple", feature = "tls"))]
#[test]
fn an_h3_upload_uses_the_declared_length_and_callback_bytes() {
    let (mut poll, driver, peer, _) = setup(Scenario::Accepted);
    let (mut owner, access) = Connection::new(driver, &mut poll, "localhost".to_owned()).unwrap();
    let mut peer = HttpPeer::new(peer);
    peer.read_upload = true;
    let (send, receive) = std::sync::mpsc::channel();
    let worker = std::thread::spawn(move || {
        let endpoint = crate::endpoint::Resolved::Quic(access);
        let cancel = Wake::new().unwrap();
        let mut body = std::io::Cursor::new(vec![b'u'; 150000]);
        let result = crate::wire::upload(
            &endpoint,
            None,
            &ko_wire::api::Route::UploadDrop {
                id: "pane_1".parse().unwrap(),
                name: "file".to_owned().try_into().unwrap(),
            },
            150000,
            &cancel,
            |buffer| std::io::Read::read(&mut body, buffer),
        );
        assert_eq!(result.unwrap(), b"done");
        for oversized in [false, true] {
            let error = crate::wire::upload(
                &endpoint,
                None,
                &ko_wire::api::Route::UploadDrop {
                    id: "pane_1".parse().unwrap(),
                    name: "short".to_owned().try_into().unwrap(),
                },
                4,
                &cancel,
                |buffer| Ok(if oversized { buffer.len() + 1 } else { 0 }),
            )
            .unwrap_err();
            assert!(error.to_string().contains("declared bytes"), "{error}");
        }
        let mut reads = 0;
        let error = crate::wire::upload(
            &endpoint,
            None,
            &ko_wire::api::Route::UploadDrop {
                id: "pane_1".parse().unwrap(),
                name: "cancel".to_owned().try_into().unwrap(),
            },
            8 << 20,
            &cancel,
            |buffer| {
                reads += 1;
                if reads == 1 {
                    return Ok(4096);
                }
                cancel.wake();
                Ok(buffer.len())
            },
        )
        .unwrap_err();
        assert!(error.to_string().contains("cancel"), "{error}");
        assert_eq!(reads, 2);
        send.send(()).unwrap();
    });
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        turn(&mut poll, &mut owner, &mut peer, deadline).unwrap();
        if receive.try_recv().is_ok() {
            break;
        }
    }
    worker.join().unwrap();
    owner.detach(&mut poll, io::ErrorKind::ConnectionReset.into());
}

#[test]
fn an_h3_send_stop_preserves_a_later_refusal_and_sibling() {
    let (mut poll, driver, peer, _) = setup(Scenario::Accepted);
    let (mut owner, access) = Connection::new(driver, &mut poll, "localhost".to_owned()).unwrap();
    let mut peer = HttpPeer::new(peer);
    let mut upload = access
        .open(Request::Http {
            method: Method::Post,
            target: "/upload".to_owned().try_into().unwrap(),
            headers: Vec::new(),
            length: 8 << 20,
        })
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while peer.upload.is_none() {
        turn(&mut poll, &mut owner, &mut peer, deadline).unwrap();
    }
    let mut written = 0;
    loop {
        turn(&mut poll, &mut owner, &mut peer, deadline).unwrap();
        match upload.write(&[b'u'; 65536]) {
            Ok(count) => written += count,
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                if written > 65536 {
                    break;
                }
            }
            Err(error) => panic!("{error}"),
        }
    }
    assert!(upload.pending_write());
    let id = peer.upload.as_ref().unwrap().0;
    peer.peer
        .connection
        .as_mut()
        .unwrap()
        .stream_shutdown(id, quiche::Shutdown::Read, 0x10c)
        .unwrap();
    peer.peer.flush();
    loop {
        turn(&mut poll, &mut owner, &mut peer, deadline).unwrap();
        match upload.write(&[b'u'; 65536]) {
            Ok(_) => {}
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
            Err(error) => {
                assert_eq!(error.kind(), io::ErrorKind::BrokenPipe);
                break;
            }
        }
    }
    upload.progress().unwrap();
    assert!(!upload.drained());
    assert!(upload.response().unwrap().is_none());
    peer.http
        .as_mut()
        .unwrap()
        .send_response(
            peer.peer.connection.as_mut().unwrap(),
            id,
            &[quiche::h3::Header::new(b":status", b"403")],
            false,
        )
        .unwrap();
    peer.sending.push((id, b"upload refused".to_vec(), 0));
    let mut sibling = access.open(request("/small")).unwrap();
    let mut answer = Vec::new();
    let mut status = None;
    let mut small = Vec::new();
    while answer.len() < 14 || small.len() < 4 {
        turn(&mut poll, &mut owner, &mut peer, deadline).unwrap();
        if let Some(head) = upload.response().unwrap() {
            status = Some(head.status);
        }
        for (stream, body) in [(&mut upload, &mut answer), (&mut sibling, &mut small)] {
            let mut bytes = [0; 64];
            match stream.read(&mut bytes) {
                Ok(count) => body.extend_from_slice(&bytes[..count]),
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                Err(error) => panic!("{error}"),
            }
        }
    }
    assert_eq!(status, Some(403));
    assert_eq!(answer, b"upload refused");
    assert_eq!(small, b"done");
    owner.detach(&mut poll, io::ErrorKind::ConnectionReset.into());
}

#[test]
fn h3_connection_loss_fails_every_handle_and_queued_open() {
    let (mut poll, driver, peer, _) = setup(Scenario::Accepted);
    let (mut owner, access) = Connection::new(driver, &mut poll, "localhost".to_owned()).unwrap();
    let mut peer = HttpPeer::new(peer);
    let mut paused = access.open(request("/large")).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while !peer.blocked {
        turn(&mut poll, &mut owner, &mut peer, deadline).unwrap();
    }
    paused.interest(crate::wire::quic::h3::Demand::Idle);
    let paused_token = poll.watch(paused.fd(), Interest::Read);
    let mut queued = access
        .open(Request::Http {
            method: Method::Post,
            target: "/queued".to_owned().try_into().unwrap(),
            headers: Vec::new(),
            length: 1,
        })
        .unwrap();
    assert_eq!(queued.write(b"x").unwrap(), 1);
    assert!(queued.pending_write());
    peer.peer
        .connection
        .as_mut()
        .unwrap()
        .close(true, 0x100, b"")
        .unwrap();
    peer.peer.flush();
    let error = loop {
        assert!(Instant::now() < deadline);
        let mut events = Events::default();
        poll.turn(Mode::Peek, &mut events).unwrap();
        let mut failed = None;
        for ready in events.ready() {
            if let Err(error) = owner.ready(&mut poll, *ready) {
                failed = Some(error);
                break;
            }
        }
        if let Some(error) = failed {
            break error;
        }
    };
    owner.detach(&mut poll, error);
    let mut events = Events::default();
    poll.turn(Mode::Peek, &mut events).unwrap();
    assert!(
        events
            .ready()
            .iter()
            .any(|ready| ready.token == paused_token && ready.read)
    );
    poll.unwatch(paused_token);
    for handle in [&mut paused, &mut queued] {
        assert_eq!(
            handle.read(&mut [0; 1]).unwrap_err().kind(),
            io::ErrorKind::ConnectionReset
        );
        assert_eq!(
            handle.write(b"x").unwrap_err().kind(),
            io::ErrorKind::ConnectionReset
        );
    }
    assert_eq!(
        access.open(request("/later")).unwrap_err().kind(),
        io::ErrorKind::ConnectionReset
    );
}

#[test]
fn cancelling_an_h3_open_while_joining_does_not_block_the_next_request() {
    let (mut poll, driver, peer, _) = setup(Scenario::Accepted);
    let (mut owner, access) = Connection::new(driver, &mut poll, "localhost".to_owned()).unwrap();
    drop(access.open(request("/cancelled")).unwrap());
    let mut live = access
        .open(Request::WebSocket {
            target: "/socket".to_owned().try_into().unwrap(),
            headers: vec![("Sec-WebSocket-Version".to_owned(), "13".to_owned())],
        })
        .unwrap();
    let mut peer = HttpPeer::new(peer);
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        turn(&mut poll, &mut owner, &mut peer, deadline).unwrap();
        match live.read(&mut [0; 6]) {
            Ok(count) => {
                assert_eq!(count, 6);
                break;
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
            Err(error) => panic!("{error}"),
        }
    }
    assert_eq!(peer.sending.len(), 1);
    owner.detach(&mut poll, io::ErrorKind::ConnectionReset.into());
}
