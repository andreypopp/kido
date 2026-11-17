use super::*;
mod h3;
use boring::pkey::PKey;
use boring::ssl::{SslContextBuilder, SslMethod};
use boring::x509::X509;
use ko_sys::event::{Events, Mode};
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};

use crate::wire::tests::tls::{Fixtures, Key};

pub(crate) struct Peer {
    pub(crate) socket: UdpSocket,
    config: quiche::Config,
    pub(crate) connection: Option<quiche::Connection>,
    token: Token,
}
impl std::fmt::Debug for Peer {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("Peer")
            .field("socket", &self.socket)
            .field("connected", &self.connection.is_some())
            .finish_non_exhaustive()
    }
}
impl Peer {
    pub(crate) fn new(server: SslContextBuilder, poll: &mut Poll) -> Self {
        let mut config =
            quiche::Config::with_boring_ssl_ctx_builder(quiche::PROTOCOL_VERSION, server).unwrap();
        config
            .set_application_protos(quiche::h3::APPLICATION_PROTOCOL)
            .unwrap();
        config.set_initial_max_data(4 << 20);
        config.set_initial_max_stream_data_bidi_local(65536);
        config.set_initial_max_stream_data_bidi_remote(65536);
        config.set_initial_max_streams_bidi(16);
        config.set_initial_max_streams_uni(16);
        config.set_initial_max_stream_data_uni(65536);
        config.set_active_connection_id_limit(4);
        config.enable_pacing(false);
        let socket = UdpSocket::bind("127.0.0.1:0").unwrap();
        socket.set_nonblocking(true).unwrap();
        let token = poll.watch(socket.as_fd(), Interest::Read);
        Peer {
            socket,
            config,
            connection: None,
            token,
        }
    }
    pub(crate) fn receive(&mut self) {
        let mut bytes = [0; 65535];
        for _ in 0..32 {
            let (count, from) = match self.socket.recv_from(&mut bytes) {
                Ok(value) => value,
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                Err(error) => panic!("{error}"),
            };
            if self.connection.is_none() {
                let header =
                    quiche::Header::from_slice(&mut bytes[..count], quiche::MAX_CONN_ID_LEN)
                        .unwrap();
                self.connection = Some(
                    quiche::accept(
                        &header.dcid,
                        None,
                        self.socket.local_addr().unwrap(),
                        from,
                        &mut self.config,
                    )
                    .unwrap(),
                );
            }
            let _ = self.connection.as_mut().unwrap().recv(
                &mut bytes[..count],
                quiche::RecvInfo {
                    from,
                    to: self.socket.local_addr().unwrap(),
                },
            );
        }
    }
    pub(crate) fn flush(&mut self) {
        let Some(connection) = &mut self.connection else {
            return;
        };
        if connection.timeout().is_some_and(|left| left.is_zero()) {
            connection.on_timeout();
        }
        let mut bytes = [0; 1350];
        for _ in 0..64 {
            match connection.send(&mut bytes) {
                Ok((count, info)) => {
                    assert_eq!(
                        self.socket.send_to(&bytes[..count], info.to).unwrap(),
                        count
                    );
                }
                Err(quiche::Error::Done) => break,
                Err(_) => break,
            }
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Scenario {
    Accepted,
    Refused,
    WrongRoot,
    WrongName,
    SniRefused,
}

fn setup(scenario: Scenario) -> (Poll, Driver, Peer, Arc<AtomicUsize>) {
    let fixtures = Fixtures::new();
    let mut server = SslContextBuilder::new(SslMethod::tls()).unwrap();
    crate::wire::tests::tls::configure_server(&mut server, &fixtures);
    if scenario == Scenario::SniRefused {
        server.set_servername_callback(|_, alert| {
            *alert = boring::ssl::SslAlert::UNRECOGNIZED_NAME;
            Err(boring::ssl::SniError::ALERT_FATAL)
        });
    }
    let mut poll = Poll::new();
    let peer = Peer::new(server, &mut poll);
    let mut context = SslContextBuilder::new(SslMethod::tls()).unwrap();
    tls::configure(
        &mut context,
        vec![if scenario == Scenario::WrongRoot {
            fixtures.other_root.der
        } else {
            fixtures.root.der
        }],
    )
    .unwrap();
    let client = if scenario == Scenario::Refused {
        fixtures.other_client
    } else {
        fixtures.client
    };
    context
        .set_certificate(&X509::from_der(&client.der).unwrap())
        .unwrap();
    let signatures = Arc::new(AtomicUsize::new(0));
    context.set_private_key_method(Key {
        key: PKey::private_key_from_der(&client.key).unwrap(),
        signatures: Arc::clone(&signatures),
    });
    let target = crate::endpoint::quic::Quic::new(
        HostName::try_from(
            if scenario == Scenario::WrongName {
                "wrong.example"
            } else {
                "localhost"
            }
            .to_owned(),
        )
        .unwrap(),
        peer.socket.local_addr().unwrap().port(),
        context,
    )
    .unwrap();
    let driver = Driver::start(
        &target.host,
        peer.socket.local_addr().unwrap(),
        &target.config,
        &mut poll,
        Duration::from_secs(15),
    )
    .unwrap();
    (poll, driver, peer, signatures)
}

fn until(
    poll: &mut Poll,
    driver: &mut Driver,
    peer: &mut Peer,
    mut done: impl FnMut(&mut Driver, &mut Peer) -> bool,
) -> io::Result<()> {
    let deadline = poll.timer();
    poll.start(deadline, Duration::from_secs(5), None).unwrap();
    let mut events = Events::default();
    let result = (|| {
        loop {
            if done(driver, peer) {
                return Ok(());
            }
            peer.flush();
            poll.turn(Mode::Wait, &mut events)?;
            for ready in events.ready() {
                if ready.token == peer.token {
                    peer.receive();
                } else {
                    driver.ready(poll, *ready)?;
                }
            }
            for due in events.due() {
                assert_ne!(due.timer, deadline, "QUIC test deadline");
                driver.due(poll, *due)?;
            }
        }
    })();
    poll.free(deadline);
    result
}

#[test]
fn quic_client_certificate_signs_once_and_streams_have_separate_credit() {
    let (mut poll, mut driver, mut peer, signatures) = setup(Scenario::Accepted);
    until(&mut poll, &mut driver, &mut peer, |driver, peer| {
        driver.connection().is_established()
            && peer
                .connection
                .as_ref()
                .is_some_and(quiche::Connection::is_established)
    })
    .unwrap();
    let data = vec![7; 65536];
    let mut accepted = 0;
    let mut queued = false;
    let deadline = poll.timer();
    poll.start(deadline, Duration::from_secs(5), None).unwrap();
    let mut events = Events::default();
    loop {
        if accepted < data.len() {
            match driver.connection().stream_send(0, &data[accepted..], false) {
                Ok(count) => accepted += count,
                Err(quiche::Error::Done) => {}
                Err(error) => panic!("{error}"),
            }
        } else if !queued {
            assert_eq!(
                driver.connection().stream_send(0, b"blocked", false),
                Err(quiche::Error::Done)
            );
            match driver.connection().stream_send(4, b"independent", true) {
                Ok(11) => queued = true,
                Err(quiche::Error::Done) => {}
                other => panic!("{other:?}"),
            }
        }
        driver.flush(&mut poll).unwrap();
        peer.flush();
        let mut received = [0; 32];
        if let Some(connection) = &mut peer.connection
            && let Ok((count, fin)) = connection.stream_recv(4, &mut received)
        {
            assert_eq!(&received[..count], b"independent");
            assert!(fin);
            break;
        }
        poll.turn(Mode::Wait, &mut events).unwrap();
        for ready in events.ready() {
            if ready.token == peer.token {
                peer.receive();
            } else {
                driver.ready(&mut poll, *ready).unwrap();
            }
        }
        for due in events.due() {
            assert_ne!(due.timer, deadline, "stream flow-control deadline");
            driver.due(&mut poll, *due).unwrap();
        }
    }
    assert_eq!(accepted, data.len());
    assert!(queued);
    poll.free(deadline);
    assert_eq!(signatures.load(Ordering::SeqCst), 1);
    driver.detach(&mut poll);
}

#[test]
fn quic_would_block_retains_the_exact_datagram() {
    let (mut poll, mut driver, mut peer, _) = setup(Scenario::Accepted);
    until(&mut poll, &mut driver, &mut peer, |driver, peer| {
        driver.connection().is_established()
            && peer
                .connection
                .as_ref()
                .is_some_and(quiche::Connection::is_established)
    })
    .unwrap();
    driver.block_send = true;
    driver
        .connection()
        .stream_send(0, b"retained", true)
        .unwrap();
    driver.flush(&mut poll).unwrap();
    until(&mut poll, &mut driver, &mut peer, |driver, _| {
        driver
            .pending
            .as_ref()
            .is_some_and(|packet| packet.info.at <= Instant::now())
    })
    .unwrap();
    driver.flush(&mut poll).unwrap();
    let packet = driver.pending.as_ref().unwrap();
    let expected = (
        driver.output[..packet.count].to_vec(),
        packet.info.from,
        packet.info.to,
        packet.info.at,
    );
    assert_eq!(poll.interest_of(driver.token), Interest::ReadWrite);
    driver.flush(&mut poll).unwrap();
    let packet = driver.pending.as_ref().unwrap();
    assert_eq!(
        (
            &driver.output[..packet.count],
            packet.info.from,
            packet.info.to,
            packet.info.at
        ),
        (&expected.0[..], expected.1, expected.2, expected.3)
    );
    driver.block_send = false;
    until(&mut poll, &mut driver, &mut peer, |_, peer| {
        let mut bytes = [0; 16];
        if let Some(connection) = &mut peer.connection
            && let Ok((count, fin)) = connection.stream_recv(0, &mut bytes)
        {
            assert_eq!(&bytes[..count], b"retained");
            assert!(fin);
            return true;
        }
        false
    })
    .unwrap();
    assert_eq!(poll.interest_of(driver.token), Interest::Read);
    driver.detach(&mut poll);
}

#[test]
fn quic_empty_datagram_and_expired_timers_share_a_ready_batch() {
    let (mut poll, mut driver, mut peer, _) = setup(Scenario::Accepted);
    let sent = driver.connection().stats().sent;
    let mut wait = Poll::new();
    let deadline = wait.timer();
    wait.start(deadline, driver.connection().timeout().unwrap(), None)
        .unwrap();
    let mut events = Events::default();
    wait.turn(Mode::Wait, &mut events).unwrap();
    let stray = UdpSocket::bind("127.0.0.1:0").unwrap();
    stray.send_to(&[], driver.local).unwrap();
    let readable = wait.watch(driver.socket.as_fd(), Interest::Read);
    wait.start(deadline, Duration::from_secs(5), None).unwrap();
    wait.turn(Mode::Wait, &mut events).unwrap();
    assert!(events.ready().iter().any(|ready| ready.token == readable));
    poll.turn(Mode::Peek, &mut events).unwrap();
    assert!(events.due().iter().any(|due| due.timer == driver.timeout));
    let ready = *events
        .ready()
        .iter()
        .find(|ready| ready.token == driver.token)
        .unwrap();
    driver.ready(&mut poll, ready).unwrap();
    assert!(
        driver.connection().stats().sent > sent,
        "expired loss timer must send a probe before stale due dispatch"
    );
    for due in events.due() {
        driver.due(&mut poll, *due).unwrap();
    }
    until(&mut poll, &mut driver, &mut peer, |driver, peer| {
        driver.connection().is_established()
            && peer
                .connection
                .as_ref()
                .is_some_and(quiche::Connection::is_established)
    })
    .unwrap();
    driver.keep_due = Some(Instant::now());
    poll.start(driver.keep, Duration::ZERO, None).unwrap();
    stray.send_to(&[], driver.local).unwrap();
    wait.start(deadline, Duration::from_secs(5), None).unwrap();
    wait.turn(Mode::Wait, &mut events).unwrap();
    assert!(events.ready().iter().any(|ready| ready.token == readable));
    poll.turn(Mode::Peek, &mut events).unwrap();
    assert!(events.due().iter().any(|due| due.timer == driver.keep));
    let sent = driver.connection().stats().sent;
    let ready = *events
        .ready()
        .iter()
        .find(|ready| ready.token == driver.token)
        .unwrap();
    driver.ready(&mut poll, ready).unwrap();
    assert!(driver.keep_due.unwrap() > Instant::now());
    assert!(driver.connection().stats().sent > sent);
    for due in events.due() {
        driver.due(&mut poll, *due).unwrap();
    }
    assert!(!driver.connection().is_closed());
    driver.detach(&mut poll);
}

#[test]
fn quic_draining_discards_a_retained_datagram() {
    let (mut poll, mut driver, mut peer, _) = setup(Scenario::Accepted);
    until(&mut poll, &mut driver, &mut peer, |driver, peer| {
        driver.connection().is_established()
            && peer
                .connection
                .as_ref()
                .is_some_and(quiche::Connection::is_established)
    })
    .unwrap();
    driver.block_send = true;
    driver
        .connection()
        .stream_send(0, b"must not send", true)
        .unwrap();
    driver.flush(&mut poll).unwrap();
    assert!(driver.pending.is_some());
    peer.connection
        .as_mut()
        .unwrap()
        .close(true, 0, b"")
        .unwrap();
    peer.flush();
    let mut events = Events::default();
    let deadline = poll.timer();
    poll.start(deadline, Duration::from_secs(5), None).unwrap();
    loop {
        poll.turn(Mode::Wait, &mut events).unwrap();
        if let Some(ready) = events
            .ready()
            .iter()
            .find(|ready| ready.token == driver.token && ready.read)
        {
            assert_eq!(
                driver.ready(&mut poll, *ready).unwrap_err().kind(),
                io::ErrorKind::ConnectionReset
            );
            break;
        }
        assert!(!events.due().iter().any(|due| due.timer == deadline));
    }
    assert!(driver.connection().is_draining());
    assert!(driver.pending.is_none());
    poll.free(deadline);
    driver.detach(&mut poll);
}

#[test]
fn quic_refused_certificate_is_identity_and_wrong_trust_is_tls() {
    for scenario in [Scenario::Refused, Scenario::WrongRoot, Scenario::WrongName] {
        let (mut poll, mut driver, mut peer, _) = setup(scenario);
        let error = until(&mut poll, &mut driver, &mut peer, |_, _| false).unwrap_err();
        let failure = error
            .get_ref()
            .and_then(|error| error.downcast_ref::<tls::Failure>())
            .unwrap_or_else(|| {
                panic!(
                    "scenario={scenario:?}: {error:?}; peer={:?}",
                    driver.connection().peer_error()
                )
            });
        assert_eq!(
            matches!(failure, tls::Failure::Tls(_)),
            scenario != Scenario::Refused,
            "{failure}"
        );
        driver.detach(&mut poll);
    }
}

#[test]
fn quic_sni_refusal_before_client_signing_is_tls() {
    let (mut poll, mut driver, mut peer, signatures) = setup(Scenario::SniRefused);
    let error = until(&mut poll, &mut driver, &mut peer, |_, _| false).unwrap_err();
    assert!(
        matches!(
            error
                .get_ref()
                .and_then(|error| error.downcast_ref::<tls::Failure>()),
            Some(tls::Failure::Tls(_))
        ),
        "{error:?}"
    );
    assert_eq!(signatures.load(Ordering::SeqCst), 0);
    driver.detach(&mut poll);
}

#[cfg(target_vendor = "apple")]
#[test]
fn quic_async_trust_retry_resumes_from_wake() {
    let (mut poll, mut driver, mut peer, signatures) = setup(Scenario::Accepted);
    let (started, start) = std::sync::mpsc::channel();
    let (release, released) = std::sync::mpsc::channel();
    let (done, completed) = std::sync::mpsc::channel();
    let ssl: &mut SslRef = driver.connection().as_mut();
    ssl.ex_data_mut(tls::index().unwrap())
        .unwrap()
        .gate(Arc::new(tls::Gate {
            started,
            release: std::sync::Mutex::new(released),
            done,
        }));
    let notification = Arc::new(Wake::new().unwrap());
    let token = poll.watch(notification.fd(), Interest::Read);
    let notify = Arc::clone(&notification);
    let worker = std::thread::spawn(move || {
        start.recv_timeout(Duration::from_secs(5)).unwrap();
        notify.wake();
    });
    let deadline = poll.timer();
    poll.start(deadline, Duration::from_secs(5), None).unwrap();
    let mut events = Events::default();
    let mut gated = false;
    let mut progressed = false;
    while !progressed {
        peer.flush();
        poll.turn(Mode::Wait, &mut events).unwrap();
        for ready in events.ready() {
            if ready.token == token {
                notification.drain();
                gated = true;
                poll.start(driver.keep, Duration::ZERO, None).unwrap();
            } else if ready.token == peer.token {
                peer.receive();
            } else {
                driver.ready(&mut poll, *ready).unwrap();
            }
        }
        for due in events.due() {
            assert_ne!(due.timer, deadline, "QUIC trust gate deadline");
            let keep = gated && due.timer == driver.keep && poll.current(*due);
            driver.due(&mut poll, *due).unwrap();
            if keep {
                assert!(!driver.connection().is_established());
                assert!(!driver.connection().is_closed());
                assert_eq!(signatures.load(Ordering::SeqCst), 0);
                assert!(poll.interest_of(driver.token).reads());
                assert!(poll.is_active(driver.timeout));
                progressed = true;
            }
        }
    }
    release.send(()).unwrap();
    poll.unwatch(token);
    poll.free(deadline);
    worker.join().unwrap();
    completed.recv_timeout(Duration::from_secs(5)).unwrap();
    assert!(!driver.connection().is_established());
    let deadline = poll.timer();
    poll.start(deadline, Duration::from_secs(5), None).unwrap();
    poll.turn(Mode::Wait, &mut events).unwrap();
    let ready = *events
        .ready()
        .iter()
        .find(|ready| ready.token == driver.trust)
        .expect("trust completion must wake the driver");
    driver.ready(&mut poll, ready).unwrap();
    assert!(driver.connection().is_established());
    poll.free(deadline);
    assert_eq!(signatures.load(Ordering::SeqCst), 1);
    driver.detach(&mut poll);
}
