use super::*;
use crate::wire::Limit;
use crate::wire::stream::Direct as Stream;
use crate::wire::tests::tls::{Fixtures, accept, server, target};
use ko_sys::event::{Events, Mode};
use std::io::Write as _;
use std::net::TcpListener;
use std::os::fd::AsRawFd;
use std::sync::{Mutex, mpsc};

#[derive(Debug, Clone, Copy)]
enum Completion {
    Wake,
    Cancel,
    Deadline,
    Drop,
}

#[test]
fn a_link_drains_plaintext_produced_by_settlement_before_waiting_again() {
    let fixtures = Fixtures::new();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let endpoint = target(&fixtures, listener.local_addr().unwrap());
    let config = server(&fixtures);
    let (release, gate) = mpsc::channel();
    let peer = std::thread::spawn(move || {
        let mut socket = accept(&listener, config);
        let mut request = [0; 5];
        socket.read_exact(&mut request).unwrap();
        assert_eq!(&request, b"start");
        socket.write_all(b"\x81\x05hello").unwrap();
        socket.flush().unwrap();
        gate.recv_timeout(Duration::from_secs(5)).unwrap();
    });
    let mut stream = Stream::open(
        (&endpoint).try_into().unwrap(),
        Limit::Idle(Duration::from_secs(5)),
        None,
    )
    .unwrap();
    assert_eq!(stream.write(b"start").unwrap(), 5);
    let Stream::Tls(secured) = &mut stream else {
        panic!("TLS");
    };
    assert_eq!(
        ko_sys::fd::wait(secured.fd(), Want::Read, None, Some(Duration::from_secs(5))).unwrap(),
        ko_sys::fd::Waited::Ready
    );
    secured.receive().unwrap();
    secured.read_retry = Some(Want::Write);
    let mut link = crate::wire::Link::of_stream(
        crate::wire::stream::Stream::Direct(stream),
        Vec::new(),
        ko_wire::protocol::Upgrade::Control,
    );
    let mut poll = Poll::new();
    link.watch(&mut poll).unwrap();
    assert_eq!(
        link.next(&mut poll, Instant::now()).unwrap(),
        crate::wire::Next::Text("hello".into())
    );
    link.unwatch(&mut poll);
    release.send(()).unwrap();
    peer.join().unwrap();
}

#[test]
fn crossed_wait_directions_feed_ciphertext_and_keep_plaintext_until_the_reader_resumes() {
    let fixtures = Fixtures::new();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let endpoint = target(&fixtures, listener.local_addr().unwrap());
    let config = server(&fixtures);
    let (release, gate) = mpsc::channel();
    let (send_more, more) = mpsc::channel();
    let peer = std::thread::spawn(move || {
        let mut socket = accept(&listener, config);
        let mut request = [0; 5];
        socket.read_exact(&mut request).unwrap();
        assert_eq!(&request, b"start");
        socket.write_all(b"reply").unwrap();
        socket.flush().unwrap();
        more.recv_timeout(Duration::from_secs(5)).unwrap();
        socket.write_all(b"again").unwrap();
        socket.flush().unwrap();
        gate.recv_timeout(Duration::from_secs(5)).unwrap();
    });
    let mut stream = Stream::open(
        (&endpoint).try_into().unwrap(),
        Limit::Idle(Duration::from_secs(5)),
        None,
    )
    .unwrap();
    assert_eq!(stream.write(b"start").unwrap(), 5);
    let Stream::Tls(secured) = &mut stream else {
        panic!("TLS");
    };
    let mut poll = Poll::new();
    let token = poll.watch(secured.fd(), Interest::Read);
    assert_eq!(
        ko_sys::fd::wait(secured.fd(), Want::Read, None, Some(Duration::from_secs(5))).unwrap(),
        ko_sys::fd::Waited::Ready
    );
    secured.write_wait = Some((Want::Read, 5));
    assert_eq!(secured.interest(false, true), Interest::Read);
    assert!(
        secured
            .receive_ready(&mut poll, token, &mut Reads::new())
            .unwrap()
    );
    assert!(!secured.stream.get_ref().input.is_empty());
    assert!(secured.plaintext.is_empty());
    assert!(secured.received);
    secured.write_wait = None;
    secured.read_wait = Some(Want::Write);
    assert_eq!(secured.interest(false, false), Interest::Write);
    secured.progress().unwrap();
    assert_eq!(
        secured.plaintext.iter().copied().collect::<Vec<_>>(),
        b"reply"
    );
    let mut reply = [0; 5];
    assert_eq!(secured.buffered(&mut reply).unwrap(), 5);
    assert_eq!(&reply, b"reply");
    assert!(secured.plaintext.is_empty());
    send_more.send(()).unwrap();
    assert_eq!(
        ko_sys::fd::wait(secured.fd(), Want::Read, None, Some(Duration::from_secs(5))).unwrap(),
        ko_sys::fd::Waited::Ready
    );
    secured.write_wait = Some((Want::Write, 5));
    secured.read_wait = Some(Want::Read);
    assert_eq!(secured.interest(true, true), Interest::ReadWrite);
    let mut reads = Reads::new();
    assert_eq!(
        secured
            .read_ready(&mut poll, token, &mut reply, &mut reads)
            .unwrap(),
        Some(Read::Data(5))
    );
    assert_eq!(&reply, b"again");
    poll.unwatch(token);
    release.send(()).unwrap();
    peer.join().unwrap();
}

#[test]
fn trust_workers_wake_without_socket_input_and_do_not_hold_other_dials_or_close() {
    let fixtures = Fixtures::new();
    for completion in [
        Completion::Wake,
        Completion::Cancel,
        Completion::Deadline,
        Completion::Drop,
    ] {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = target(&fixtures, listener.local_addr().unwrap());
        let config = server(&fixtures);
        let peer = std::thread::spawn(move || {
            let mut socket = accept(&listener, config);
            let result = socket.read(&mut [0]);
            if matches!(completion, Completion::Wake) {
                assert_eq!(result.unwrap(), 1);
            } else {
                assert!(result.is_err() || result.unwrap() == 0);
            }
        });
        let (started, waiting) = mpsc::channel();
        let (release, gate) = mpsc::channel();
        let (done, finished) = mpsc::channel();
        let mut stream = Stream::start(&endpoint).unwrap();
        let Stream::Tls(secured) = &mut stream else {
            panic!("TLS");
        };
        secured
            .stream
            .ssl_mut()
            .ex_data_mut(tls::index().unwrap())
            .unwrap()
            .gate(Arc::new(tls::Gate {
                started,
                release: Mutex::new(gate),
                done,
            }));
        let wake = Arc::clone(&secured.wake);
        let mut poll = Poll::new();
        let token = poll.watch(stream.fd(), stream.interest(true, true));
        let timer = poll.timer();
        poll.start(timer, Duration::from_secs(5), None).unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut events = Events::default();
        while !matches!(&stream, Stream::Tls(secured) if matches!(secured.dial, Dial::Handshake(Wait::Trust)))
        {
            poll.turn(Mode::Wait, &mut events).unwrap();
            assert!(Instant::now() < deadline);
            for ready in events.ready() {
                if ready.token != token {
                    continue;
                }
                if ready.write {
                    stream.writable().unwrap();
                }
                if ready.read {
                    stream
                        .read_ready(&mut poll, token, &mut [0], &mut Reads::new())
                        .unwrap();
                }
            }
            poll.retarget(token, stream.fd(), stream.interest(true, true));
        }
        waiting.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_eq!(stream.fd().as_raw_fd(), wake.fd().as_raw_fd());
        assert_eq!(poll.interest_of(token), Interest::Read);

        if matches!(completion, Completion::Wake) {
            let other_listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let other_endpoint = target(&fixtures, other_listener.local_addr().unwrap());
            let other_config = server(&fixtures);
            let other_peer = std::thread::spawn(move || {
                assert_eq!(
                    accept(&other_listener, other_config)
                        .read(&mut [0])
                        .unwrap(),
                    1
                );
            });
            let mut other = Stream::start(&other_endpoint).unwrap();
            let other_token = poll.watch(other.fd(), other.interest(true, true));
            while !other.ready() {
                poll.turn(Mode::Wait, &mut events).unwrap();
                assert!(Instant::now() < deadline);
                for ready in events.ready() {
                    if ready.token != other_token {
                        continue;
                    }
                    if ready.write {
                        other.writable().unwrap();
                    }
                    if ready.read {
                        other
                            .read_ready(&mut poll, other_token, &mut [0], &mut Reads::new())
                            .unwrap();
                    }
                }
                poll.retarget(other_token, other.fd(), other.interest(true, true));
            }
            poll.unwatch(other_token);
            assert_eq!(other.write(&[7]).unwrap(), 1);
            drop(other);
            other_peer.join().unwrap();
            release.send(()).unwrap();
            finished.recv_timeout(Duration::from_secs(5)).unwrap();
            poll.turn(Mode::Wait, &mut events).unwrap();
            assert!(
                events
                    .ready()
                    .iter()
                    .any(|ready| ready.token == token && ready.read)
            );
            assert_eq!(stream.fd().as_raw_fd(), wake.fd().as_raw_fd());
            stream
                .read_ready(&mut poll, token, &mut [0], &mut Reads::new())
                .unwrap();
            assert!(
                !matches!(&stream, Stream::Tls(secured) if matches!(secured.dial, Dial::Handshake(Wait::Trust)))
            );
            stream.finish_open(Limit::Deadline(deadline), None).unwrap();
            assert_eq!(stream.write(&[7]).unwrap(), 1);
            drop(stream);
        } else {
            match completion {
                Completion::Cancel => {
                    let cancel = Wake::new().unwrap();
                    cancel.wake();
                    let error = stream
                        .finish_open(Limit::Deadline(deadline), Some(&cancel))
                        .unwrap_err();
                    assert_eq!(error.kind(), crate::connect::cancelled_error().kind());
                }
                Completion::Deadline => {
                    let error = stream
                        .finish_open(Limit::Deadline(Instant::now()), None)
                        .unwrap_err();
                    assert_eq!(error.kind(), io::ErrorKind::TimedOut);
                }
                Completion::Drop => {}
                Completion::Wake => unreachable!(),
            }
            poll.unwatch(token);
            drop(stream);
            release.send(()).unwrap();
            finished.recv_timeout(Duration::from_secs(5)).unwrap();
        }
        peer.join().unwrap();
    }
}
