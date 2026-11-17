use super::*;
use crate::endpoint::{self, HostName, Resolved, Tls};
use boring::pkey::PKey;
use boring::ssl::{Ssl, SslAcceptor, SslMethod, SslStream, SslVerifyMode, SslVersion};
use boring::x509::X509;
use std::net::{TcpListener, TcpStream};

#[path = "../tls_certs.rs"]
mod certs;
pub(crate) use certs::Fixtures;

const WITHIN: Duration = Duration::from_secs(5);

pub(crate) fn server(fixtures: &Fixtures) -> Arc<SslAcceptor> {
    let mut config = SslAcceptor::mozilla_intermediate_v5(SslMethod::tls()).unwrap();
    config
        .set_min_proto_version(Some(SslVersion::TLS1_3))
        .unwrap();
    config
        .set_max_proto_version(Some(SslVersion::TLS1_3))
        .unwrap();
    config
        .cert_store_mut()
        .add_cert(X509::from_der(&fixtures.root.der).unwrap())
        .unwrap();
    let leaf = fixtures.client.der.clone();
    config.set_verify_callback(
        SslVerifyMode::PEER | SslVerifyMode::FAIL_IF_NO_PEER_CERT,
        move |valid, context| {
            if valid
                && context.error_depth() == 0
                && !context
                    .current_cert()
                    .is_some_and(|cert| cert.to_der().unwrap() == leaf)
            {
                context.set_error(Err(boring::x509::X509VerifyError::CERT_REJECTED));
                return false;
            }
            valid
        },
    );
    config
        .set_certificate(&X509::from_der(&fixtures.server.der).unwrap())
        .unwrap();
    config
        .set_private_key(&PKey::private_key_from_der(&fixtures.server.key).unwrap())
        .unwrap();
    config.set_options(boring::ssl::SslOptions::NO_TICKET);
    Arc::new(config.build())
}

pub(crate) fn target(fixtures: &Fixtures, address: std::net::SocketAddr) -> Resolved {
    target_with(address, "LOCALHOST", &fixtures.client, &fixtures.root)
}

fn target_with(
    address: std::net::SocketAddr,
    host: &str,
    client: &certs::Certificate,
    root: &certs::Certificate,
) -> Resolved {
    let mut config = endpoint::config(vec![root.der.clone()]).unwrap();
    config
        .set_certificate(&X509::from_der(&client.der).unwrap())
        .unwrap();
    #[derive(Debug)]
    struct Key(PKey<boring::pkey::Private>);
    impl boring::ssl::PrivateKeyMethod for Key {
        fn sign(
            &self,
            ssl: &mut boring::ssl::SslRef,
            input: &[u8],
            algorithm: boring::ssl::SslSignatureAlgorithm,
            out: &mut [u8],
        ) -> Result<usize, boring::ssl::PrivateKeyMethodError> {
            assert_eq!(
                algorithm,
                boring::ssl::SslSignatureAlgorithm::ECDSA_SECP256R1_SHA256
            );
            let mut signer =
                boring::sign::Signer::new(boring::hash::MessageDigest::sha256(), &self.0).unwrap();
            signer.update(input).unwrap();
            let signature = signer.sign_to_vec().unwrap();
            out[..signature.len()].copy_from_slice(&signature);
            endpoint::tls::signing(ssl, endpoint::tls::Signing::Succeeded);
            Ok(signature.len())
        }
        fn decrypt(
            &self,
            _: &mut boring::ssl::SslRef,
            _: &[u8],
            _: &mut [u8],
        ) -> Result<usize, boring::ssl::PrivateKeyMethodError> {
            Err(boring::ssl::PrivateKeyMethodError::FAILURE)
        }
        fn complete(
            &self,
            _: &mut boring::ssl::SslRef,
            _: &mut [u8],
        ) -> Result<usize, boring::ssl::PrivateKeyMethodError> {
            Err(boring::ssl::PrivateKeyMethodError::FAILURE)
        }
    }
    config.set_private_key_method(Key(PKey::private_key_from_der(&client.key).unwrap()));
    Resolved::Tls {
        target: Arc::new(Tls::new(
            HostName::try_from(host.to_owned()).unwrap(),
            address.port(),
            config.build(),
        )),
        addresses: Arc::from([address]),
    }
}

#[derive(Debug)]
pub(crate) struct Server<S> {
    stream: SslStream<S>,
    accepted: bool,
}

impl<S: io::Read + io::Write> Server<S> {
    fn new(config: &SslAcceptor, transport: S) -> Self {
        Self {
            stream: SslStream::new(Ssl::new(config.context()).unwrap(), transport).unwrap(),
            accepted: false,
        }
    }

    fn handshake(&mut self) -> io::Result<()> {
        if !self.accepted {
            self.stream.accept().map_err(io::Error::other)?;
            self.accepted = true;
        }
        Ok(())
    }

    #[cfg(target_vendor = "apple")]
    pub(crate) fn get_ref(&self) -> &S {
        self.stream.get_ref()
    }
    pub(crate) fn get_mut(&mut self) -> &mut S {
        self.stream.get_mut()
    }
}

impl<S: io::Read + io::Write> io::Read for Server<S> {
    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        self.handshake()?;
        self.stream.read(bytes)
    }
}
impl<S: io::Read + io::Write> io::Write for Server<S> {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.handshake()?;
        self.stream.write(bytes)
    }
    fn flush(&mut self) -> io::Result<()> {
        self.stream.flush()
    }
}

pub(crate) fn accept(listener: &TcpListener, config: Arc<SslAcceptor>) -> Server<TcpStream> {
    assert_eq!(
        fd::wait(listener.as_fd(), Want::Read, None, Some(WITHIN)).unwrap(),
        Waited::Ready
    );
    let (stream, _) = listener.accept().unwrap();
    stream.set_read_timeout(Some(WITHIN)).unwrap();
    stream.set_write_timeout(Some(WITHIN)).unwrap();
    Server::new(&config, stream)
}

#[test]
fn a_request_and_an_upgrade_cross_tls() {
    let fixtures = Fixtures::new();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let endpoint = target(&fixtures, listener.local_addr().unwrap());
    let config = server(&fixtures);
    let peer = std::thread::spawn(move || {
        let mut stream = accept(&listener, Arc::clone(&config));
        let mut head = Vec::new();
        while !head.ends_with(b"\r\n\r\n") {
            let mut byte = [0];
            stream.read_exact(&mut byte).unwrap();
            head.extend(byte);
        }
        assert!(
            String::from_utf8(head)
                .unwrap()
                .contains("Host: localhost\r\n")
        );
        stream
            .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nyes")
            .unwrap();
        stream.flush().unwrap();
        drop(stream);
        let stream = accept(&listener, config);
        let mut socket = tungstenite::accept(stream).unwrap();
        socket.send(Message::text("secured")).unwrap();
        assert_eq!(socket.read().unwrap(), Message::text("reply"));
    });
    let body = request_within(
        &endpoint,
        (None, None),
        &Route::Version {},
        b"",
        (None, WITHIN),
    )
    .unwrap();
    assert_eq!(body, b"yes");
    let mut link = Link::connect_within(&endpoint, None, &Route::Client {}, None, WITHIN).unwrap();
    assert_eq!(link.receive().unwrap(), Next::Text("secured".into()));
    link.send("reply".to_owned()).unwrap();
    link.flush_blocking().unwrap();
    peer.join().unwrap();
}

#[cfg(target_vendor = "apple")]
#[test]
fn webview_http_and_upgrade_drive_tls_only_from_socket_readiness() {
    use crate::webview::{Event, Kind, Target, Upstream};
    use ko_wire::protocol::webview::Headers;
    let fixtures = Fixtures::new();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let endpoint = target(&fixtures, listener.local_addr().unwrap());
    let config = server(&fixtures);
    let (check, check_gate) = std::sync::mpsc::channel();
    let (checked, checks) = std::sync::mpsc::channel();
    let peer = std::thread::spawn(move || {
        for upgrade in [false, true] {
            assert_eq!(
                fd::wait(listener.as_fd(), Want::Read, None, Some(WITHIN)).unwrap(),
                Waited::Ready
            );
            let (socket, _) = listener.accept().unwrap();
            check_gate.recv_timeout(WITHIN).unwrap();
            socket.set_nonblocking(true).unwrap();
            assert_eq!(
                socket.peek(&mut [0]).unwrap_err().kind(),
                io::ErrorKind::WouldBlock
            );
            socket.set_nonblocking(false).unwrap();
            socket.set_read_timeout(Some(WITHIN)).unwrap();
            socket.set_write_timeout(Some(WITHIN)).unwrap();
            checked.send(()).unwrap();
            let mut stream = Server::new(&config, socket);
            if upgrade {
                let mut socket = tungstenite::accept(stream).unwrap();
                socket.send(Message::text("buffered")).unwrap();
                assert_eq!(socket.read().unwrap(), Message::text("reply"));
            } else {
                let mut head = Vec::new();
                while !head.ends_with(b"\r\n\r\n") {
                    let mut byte = [0];
                    stream.read_exact(&mut byte).unwrap();
                    head.extend(byte);
                }
                let head = String::from_utf8(head).unwrap();
                assert!(head.starts_with("GET /version HTTP/1.1\r\n"));
                assert!(head.contains("Host: localhost\r\n"));
                assert!(head.contains("Ko-Client: client_7\r\n"));
                stream
                    .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nyes")
                    .unwrap();
                stream.flush().unwrap();
            }
        }
    });
    for upgrade in [false, true] {
        let mut poll = Poll::new();
        let mut events = ko_sys::event::Events::default();
        let kind = if upgrade {
            Kind::Upgrade
        } else {
            Kind::Http(protocol::Method::Get)
        };
        let mut upstream = Upstream::open(
            &mut poll,
            &endpoint,
            kind,
            &"/version".to_owned().try_into().unwrap(),
            &Headers::try_from(Vec::new()).unwrap(),
            Target::Server("client_7".parse().unwrap()),
            b"",
        )
        .unwrap();
        assert!(upstream.next(&mut poll).unwrap().is_none());
        upstream.flush(&mut poll).unwrap();
        assert_eq!(upstream.written(), 0);
        check.send(()).unwrap();
        checks.recv_timeout(WITHIN).unwrap();
        let deadline = Instant::now() + WITHIN;
        let timer = poll.timer();
        poll.start(timer, WITHIN, None).unwrap();
        let mut body = Vec::new();
        let mut sent = None;
        let mut ended = false;
        loop {
            if ended || sent.is_some_and(|end| upstream.drained() && upstream.written() == end) {
                break;
            }
            upstream.interest(&mut poll, true);
            poll.turn(ko_sys::event::Mode::Wait, &mut events).unwrap();
            assert!(Instant::now() < deadline);
            for ready in events.ready() {
                let ready = poll.wants(*ready);
                if ready.token != upstream.token() {
                    continue;
                }
                if ready.write {
                    upstream.writable(&mut poll).unwrap();
                    upstream.flush(&mut poll).unwrap();
                }
                if ready.read {
                    upstream.begin_turn();
                    while let Some(event) = upstream.next(&mut poll).unwrap() {
                        match event {
                            Event::Response(head) => assert_eq!(head.status, 200),
                            Event::Body(bytes) => body.extend(bytes),
                            Event::End => {
                                ended = true;
                                break;
                            }
                            Event::Upgraded(head) => assert_eq!(head.status, 101),
                            Event::Message { data, binary } => {
                                assert_eq!(binary, ko_wire::protocol::webview::FrameKind::Text);
                                assert_eq!(data.as_ref(), b"buffered");
                                sent = Some(
                                    upstream.send(Message::text("reply")).unwrap().unwrap().end,
                                );
                                upstream.flush(&mut poll).unwrap();
                                break;
                            }
                            other => panic!("unexpected {other:?}"),
                        }
                    }
                }
            }
        }
        if !upgrade {
            assert_eq!(body, b"yes");
        }
        upstream.dispose(&mut poll);
    }
    peer.join().unwrap();
}

#[test]
fn a_nonblocking_tls_upgrade_tries_the_next_resolved_address() {
    let fixtures = Fixtures::new();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let refused = TcpListener::bind("127.0.0.1:0").unwrap();
    let refused_address = refused.local_addr().unwrap();
    drop(refused);
    let Resolved::Tls { target, .. } = target(&fixtures, address) else {
        panic!("TLS target");
    };
    let endpoint = Resolved::Tls {
        target,
        addresses: Arc::from([refused_address, address]),
    };
    let config = server(&fixtures);
    let (release, gate) = std::sync::mpsc::channel();
    let peer = std::thread::spawn(move || {
        let mut socket = tungstenite::accept(accept(&listener, config)).unwrap();
        socket.send(Message::text("next address")).unwrap();
        gate.recv_timeout(WITHIN).unwrap();
    });
    let mut poll = Poll::new();
    let mut events = ko_sys::event::Events::default();
    let mut connecting = Connecting::start(
        &endpoint,
        "client_7".parse().unwrap(),
        &Route::Client {},
        None,
    )
    .unwrap();
    let mut token = connecting.watch(&mut poll);
    let timer = poll.timer();
    poll.start(timer, WITHIN, None).unwrap();
    let deadline = Instant::now() + WITHIN;
    let mut link = 'dial: loop {
        poll.turn(ko_sys::event::Mode::Wait, &mut events).unwrap();
        assert!(Instant::now() < deadline);
        for ready in events.ready() {
            let mut ready = poll.wants(*ready);
            if ready.token != token {
                continue;
            }
            match connecting.advance(&mut poll, &mut ready).unwrap() {
                UpgradeStep::Pending(pending) => {
                    connecting = pending;
                    token = ready.token;
                }
                UpgradeStep::Open(link) => break 'dial link,
                UpgradeStep::Refused(response) => panic!("{response:?}"),
            }
        }
    };
    loop {
        link.begin_turn();
        match link.next(&mut poll, Instant::now()).unwrap() {
            Next::Text(text) => {
                assert_eq!(text, "next address");
                break;
            }
            Next::Wait => {
                poll.turn(ko_sys::event::Mode::Wait, &mut events).unwrap();
                assert!(Instant::now() < deadline);
            }
            next => panic!("unexpected {next:?}"),
        }
    }
    release.send(()).unwrap();
    peer.join().unwrap();
}

#[test]
fn certificate_and_identity_failures_keep_their_kind() {
    let fixtures = Fixtures::new();
    for (host, root, client, identity) in [
        ("localhost", &fixtures.other_root, &fixtures.client, false),
        ("wrong.example", &fixtures.root, &fixtures.client, false),
        ("localhost", &fixtures.root, &fixtures.other_client, true),
    ] {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = target_with(listener.local_addr().unwrap(), host, client, root);
        let config = server(&fixtures);
        let peer = std::thread::spawn(move || {
            let mut stream = accept(&listener, config);
            assert!(stream.read(&mut [0]).is_err());
        });
        let error = request_within(
            &endpoint,
            (None, None),
            &Route::Version {},
            b"",
            (None, WITHIN),
        )
        .unwrap_err();
        assert_eq!(
            matches!(error, Rejected::Identity(_)),
            identity,
            "{error:?}"
        );
        assert_eq!(matches!(error, Rejected::Tls(_)), !identity, "{error:?}");
        peer.join().unwrap();
    }
}

#[test]
fn a_large_tls_message_drains_without_another_socket_read() {
    let fixtures = Fixtures::new();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let endpoint = target(&fixtures, listener.local_addr().unwrap());
    let config = server(&fixtures);
    let (release, released) = std::sync::mpsc::channel();
    let peer = std::thread::spawn(move || {
        let mut socket = tungstenite::accept(accept(&listener, config)).unwrap();
        socket.send(Message::binary(vec![0x5a; 32 << 20])).unwrap();
        released.recv_timeout(WITHIN).unwrap();
    });
    let mut link = Link::connect_within(&endpoint, None, &Route::Client {}, None, WITHIN).unwrap();
    let mut poll = Poll::new();
    let token = link.watch(&mut poll).unwrap();
    let mut events = ko_sys::event::Events::default();
    let deadline = Instant::now() + WITHIN;
    let timer = poll.timer();
    poll.start(timer, WITHIN, None).unwrap();
    let message = loop {
        link.begin_turn();
        match link.next(&mut poll, Instant::now()).unwrap() {
            Next::Binary(bytes) => break bytes,
            Next::Wait => {
                poll.turn(ko_sys::event::Mode::Wait, &mut events).unwrap();
                assert!(Instant::now() < deadline);
            }
            other => panic!("unexpected {other:?}"),
        }
    };
    assert_eq!(message.len(), 32 << 20);
    assert!(message.iter().all(|byte| *byte == 0x5a));
    link.unwatch(&mut poll);
    let _ = token;
    release.send(()).unwrap();
    peer.join().unwrap();
}

#[derive(Debug)]
struct Fragmented {
    socket: TcpStream,
    split: Option<(std::sync::mpsc::Sender<()>, std::sync::mpsc::Receiver<()>)>,
}
impl io::Read for Fragmented {
    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        self.socket.read(bytes)
    }
}
impl io::Write for Fragmented {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if let Some((sent, release)) = self.split.take() {
            let count = bytes.len().min(3);
            self.socket.write_all(&bytes[..count])?;
            sent.send(()).map_err(io::Error::other)?;
            release.recv_timeout(WITHIN).map_err(io::Error::other)?;
            self.socket.write_all(&bytes[count..])?;
            Ok(bytes.len())
        } else {
            self.socket.write(bytes)
        }
    }
    fn flush(&mut self) -> io::Result<()> {
        self.socket.flush()
    }
}

#[test]
fn a_partial_tls_record_feeds_the_watchdog_without_plaintext() {
    let fixtures = Fixtures::new();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let endpoint = target(&fixtures, listener.local_addr().unwrap());
    let config = server(&fixtures);
    let (sent, partial) = std::sync::mpsc::channel();
    let (release, released) = std::sync::mpsc::channel();
    let peer = std::thread::spawn(move || {
        assert_eq!(
            fd::wait(listener.as_fd(), Want::Read, None, Some(WITHIN)).unwrap(),
            Waited::Ready
        );
        let (transport, _) = listener.accept().unwrap();
        transport.set_read_timeout(Some(WITHIN)).unwrap();
        transport.set_write_timeout(Some(WITHIN)).unwrap();
        let stream = Server::new(
            &config,
            Fragmented {
                socket: transport,
                split: None,
            },
        );
        let mut socket = tungstenite::accept(stream).unwrap();
        socket.get_mut().get_mut().split = Some((sent, released));
        socket.send(Message::text("slow")).unwrap();
        assert_eq!(socket.read().unwrap(), Message::text("done"));
    });
    let mut link = Link::connect_within(&endpoint, None, &Route::Client {}, None, WITHIN).unwrap();
    let mut poll = Poll::new();
    link.watch(&mut poll).unwrap();
    partial.recv_timeout(WITHIN).unwrap();
    let now = link.received() + Duration::from_secs(20);
    assert_eq!(link.next(&mut poll, now).unwrap(), Next::Wait);
    assert_eq!(link.received(), now);
    assert!(!silent(
        link.received(),
        now + Duration::from_secs(4),
        Duration::from_secs(5)
    ));
    release.send(()).unwrap();
    let mut events = ko_sys::event::Events::default();
    let timer = poll.timer();
    poll.start(timer, WITHIN, None).unwrap();
    let deadline = Instant::now() + WITHIN;
    loop {
        poll.turn(ko_sys::event::Mode::Wait, &mut events).unwrap();
        assert!(Instant::now() < deadline);
        link.begin_turn();
        match link.next(&mut poll, now).unwrap() {
            Next::Text(text) => {
                assert_eq!(text, "slow");
                break;
            }
            Next::Wait => {}
            next => panic!("unexpected {next:?}"),
        }
    }
    link.send("done".to_owned()).unwrap();
    link.flush_blocking().unwrap();
    peer.join().unwrap();
}

#[test]
fn a_held_tls_handshake_waits_for_reads_instead_of_spinning() {
    let fixtures = Fixtures::new();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let endpoint = target(&fixtures, listener.local_addr().unwrap());
    let (hello, received) = std::sync::mpsc::channel();
    let (release, gate) = std::sync::mpsc::channel();
    let peer = std::thread::spawn(move || {
        assert_eq!(
            fd::wait(listener.as_fd(), Want::Read, None, Some(WITHIN)).unwrap(),
            Waited::Ready
        );
        let (mut socket, _) = listener.accept().unwrap();
        socket.set_read_timeout(Some(WITHIN)).unwrap();
        let mut header = [0; 5];
        socket.read_exact(&mut header).unwrap();
        assert_eq!(header[0], 22);
        let mut body = vec![0; usize::from(u16::from_be_bytes([header[3], header[4]]))];
        socket.read_exact(&mut body).unwrap();
        hello.send(()).unwrap();
        gate.recv_timeout(WITHIN).unwrap();
    });
    let mut poll = Poll::new();
    let mut events = ko_sys::event::Events::default();
    let mut connecting = Connecting::start(
        &endpoint,
        "client_7".parse().unwrap(),
        &Route::Client {},
        None,
    )
    .unwrap();
    let token = connecting.watch(&mut poll);
    let deadline = poll.timer();
    poll.start(deadline, WITHIN, None).unwrap();
    poll.turn(ko_sys::event::Mode::Wait, &mut events).unwrap();
    let mut ready = *events
        .ready()
        .iter()
        .find(|ready| ready.token == token)
        .unwrap();
    let UpgradeStep::Pending(pending) = connecting.advance(&mut poll, &mut ready).unwrap() else {
        panic!("held handshake");
    };
    connecting = pending;
    received.recv_timeout(WITHIN).unwrap();
    assert_eq!(poll.interest_of(token), ko_sys::event::Interest::Read);
    for _ in 0..8 {
        poll.turn(ko_sys::event::Mode::Peek, &mut events).unwrap();
        assert!(
            !events
                .ready()
                .iter()
                .any(|ready| ready.token == token && ready.write)
        );
    }
    drop(connecting);
    release.send(()).unwrap();
    peer.join().unwrap();
}

#[test]
fn cancellation_interrupts_a_tls_handshake() {
    let fixtures = Fixtures::new();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let endpoint = target(&fixtures, listener.local_addr().unwrap());
    let cancel = Arc::new(Wake::new().unwrap());
    let worker_cancel = Arc::clone(&cancel);
    let (send, receive) = std::sync::mpsc::channel();
    let worker = std::thread::spawn(move || {
        send.send(
            Link::connect_within(
                &endpoint,
                None,
                &Route::Client {},
                Some(worker_cancel),
                WITHIN,
            )
            .unwrap_err(),
        )
        .unwrap();
    });
    assert_eq!(
        fd::wait(listener.as_fd(), Want::Read, None, Some(WITHIN)).unwrap(),
        Waited::Ready
    );
    let (mut peer, _) = listener.accept().unwrap();
    peer.set_read_timeout(Some(WITHIN)).unwrap();
    let mut hello = [0; 5];
    peer.read_exact(&mut hello).unwrap();
    cancel.wake();
    let error = receive.recv_timeout(Duration::from_secs(1)).unwrap();
    assert_eq!(error.to_string(), "cancelled");
    worker.join().unwrap();
}
