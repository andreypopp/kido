use super::*;
use crate::endpoint::{Dial, HostName, quic::Quic};
use crate::wire::tests::tls::{Fixtures, Key};
use boring::pkey::PKey;
use boring::ssl::{SslContextBuilder, SslMethod};
use boring::x509::X509;
use ko_sys::pid::{Exit, Waited};
use ko_sys::spawn::{self, Env};
use ko_wire::api::Route;
use std::cell::Cell;
use std::fs::File;
use std::io;
use std::net::{IpAddr, SocketAddr};
use std::os::fd::AsFd;
use std::os::unix::ffi::OsStrExt;
use std::sync::atomic::AtomicUsize;

const DEADLINE: Duration = Duration::from_secs(5);
const IMAGE: &str = "ko-quic-test:debian13";

#[derive(Debug)]
struct Run {
    exit: Exit,
    stdout: String,
    stderr: String,
}
#[derive(Debug)]
struct Container {
    cli: PathBuf,
    dir: PathBuf,
    name: String,
    env: Vec<Vec<u8>>,
    command: Cell<u64>,
}
impl Container {
    fn run(&self, args: &[&str]) -> io::Result<Run> {
        let number = self.command.get();
        self.command.set(number + 1);
        let output = self.dir.join(format!("command-{number}.out"));
        let errors = self.dir.join(format!("command-{number}.err"));
        let input = File::open("/dev/null")?;
        let stdout = File::create(&output)?;
        let stderr = File::create(&errors)?;
        let pid = spawn::program(
            &self.cli,
            args,
            &[(input.as_fd(), 0), (stdout.as_fd(), 1), (stderr.as_fd(), 2)],
            Env::Only(&self.env),
            None,
        )?;
        let (send, receive) = channel();
        std::thread::spawn(move || {
            let _ = send.send(pid.wait());
        });
        let status = receive.recv_timeout(DEADLINE).map_err(io::Error::other)??;
        let Waited::Ended(exit) = status else {
            return Err(io::Error::other("container command was not reaped"));
        };
        Ok(Run {
            exit,
            stdout: std::fs::read_to_string(output)?,
            stderr: std::fs::read_to_string(errors)?,
        })
    }
    fn ok(&self, args: &[&str]) -> String {
        let run = self.run(args).unwrap();
        assert_eq!(
            run.exit,
            Exit::Exited(0),
            "{args:?}: stdout={} stderr={}",
            run.stdout,
            run.stderr
        );
        run.stdout
    }
    fn control(&self, verb: &str, program: &str) {
        self.ok(&[
            "exec",
            &self.name,
            "supervisorctl",
            "-c",
            "/fixtures/supervisord.conf",
            verb,
            program,
        ]);
    }
    fn start(cli: PathBuf, path: Vec<u8>, certs: &Fixtures) -> (Self, SocketAddr) {
        let nonce = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let name = format!("ko-quic-test-{}-{nonce}", std::process::id());
        let dir = PathBuf::from("/tmp").join(&name);
        std::fs::create_dir(&dir).unwrap();
        let home = dir.join("home");
        std::fs::create_dir(&home).unwrap();
        let env = vec![
            [b"PATH=".as_slice(), path.as_slice()].concat(),
            [b"HOME=".as_slice(), home.as_os_str().as_bytes()].concat(),
        ];
        let container = Self {
            cli,
            dir,
            name,
            env,
            command: Cell::new(0),
        };
        container.ok(&["image", "inspect", IMAGE]);
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
        let layout = root
            .join("build/ko/share/ko/linux/aarch64")
            .canonicalize()
            .expect("KO_E2E_CONTAINER needs make build-linux");
        for binary in ["ko", "ko-pane"] {
            assert!(
                layout.join("bin").join(binary).is_file(),
                "missing static {binary}"
            );
        }
        let pem = |der: &[u8]| X509::from_der(der).unwrap().to_pem().unwrap();
        std::fs::write(container.dir.join("server.pem"), pem(&certs.server.der)).unwrap();
        std::fs::write(
            container.dir.join("server.key"),
            PKey::private_key_from_der(&certs.server.key)
                .unwrap()
                .private_key_to_pem_pkcs8()
                .unwrap(),
        )
        .unwrap();
        let devices = container.dir.join("devices");
        std::fs::create_dir(&devices).unwrap();
        std::fs::write(devices.join("paired.pem"), pem(&certs.client.der)).unwrap();
        let template = include_str!("../../../../deploy/files/Caddyfile");
        let global = template.split("@ENROLL@").next().unwrap();
        let host = template.split("@HOST@").nth(1).unwrap();
        let config = format!("{global}localhost{host}").replace(
            "\ttls {",
            "\ttls /fixtures/server.pem /fixtures/server.key {",
        );
        std::fs::write(container.dir.join("Caddyfile"), config).unwrap();
        std::fs::write(container.dir.join("supervisord.conf"),"[unix_http_server]\nfile=/run/supervisor.sock\n[supervisord]\nnodaemon=true\nlogfile=/fixtures/supervisor.log\npidfile=/run/supervisord.pid\n[rpcinterface:supervisor]\nsupervisor.rpcinterface_factory=supervisor.rpcinterface:make_main_rpcinterface\n[supervisorctl]\nserverurl=unix:///run/supervisor.sock\n[program:ko]\ncommand=/opt/ko/bin/ko --server /var/lib/ko server\nenvironment=HOME=\"/tmp\"\nstartsecs=0\nstopwaitsecs=1\nautorestart=false\nstdout_logfile=/fixtures/ko.log\nstdout_logfile_maxbytes=0\nredirect_stderr=true\n[program:caddy]\ncommand=/usr/bin/caddy run --config /fixtures/Caddyfile --adapter caddyfile\nstartsecs=0\nstopwaitsecs=4\nautorestart=false\nstdout_logfile=/fixtures/caddy.log\nstdout_logfile_maxbytes=0\nredirect_stderr=true\n").unwrap();
        let mounted_layout = format!("{}:/opt/ko:ro", layout.display());
        let mounted_fixture = format!("{}:/fixtures", container.dir.display());
        let mounted_devices = format!("{}:/var/lib/ko-devices:ro", devices.display());
        container.ok(&[
            "run",
            "--detach",
            "--name",
            &container.name,
            "--cpus",
            "1",
            "--memory",
            "256M",
            "--volume",
            &mounted_layout,
            "--volume",
            &mounted_fixture,
            "--volume",
            &mounted_devices,
            IMAGE,
        ]);
        let ready = Instant::now() + DEADLINE;
        loop {
            let run = container
                .run(&[
                    "exec",
                    &container.name,
                    "/bin/sh",
                    "-c",
                    "test -S /var/lib/ko/socket && test -S /run/caddy/admin.sock",
                ])
                .unwrap();
            if run.exit == Exit::Exited(0) {
                break;
            }
            assert!(
                Instant::now() < ready,
                "ko and Caddy did not start: {run:?}"
            );
        }
        #[derive(Debug, serde::Deserialize)]
        struct Info {
            status: Status,
        }
        #[derive(Debug, serde::Deserialize)]
        struct Status {
            networks: Vec<Network>,
        }
        #[derive(Debug, serde::Deserialize)]
        struct Network {
            #[serde(rename = "ipv4Address")]
            address: String,
        }
        let text = container.ok(&["inspect", &container.name]);
        let inspected: Vec<Info> =
            serde_json::from_str(&text).unwrap_or_else(|error| panic!("{error}: {text}"));
        let address = inspected
            .first()
            .and_then(|info| info.status.networks.first())
            .expect("container has no network")
            .address
            .split('/')
            .next()
            .unwrap()
            .parse::<IpAddr>()
            .unwrap();
        (container, SocketAddr::new(address, 443))
    }
}
impl Drop for Container {
    fn drop(&mut self) {
        if std::thread::panicking() {
            for file in ["supervisor.log", "caddy.log", "ko.log"] {
                let text = std::fs::read_to_string(self.dir.join(file)).unwrap_or_default();
                let _ = writeln!(std::io::stderr().lock(), "{} {file}:\n{text}", self.name);
            }
        }
        let result = self.run(&["delete", "--force", &self.name]);
        if !std::thread::panicking() {
            assert!(
                result.as_ref().is_ok_and(|run| run.exit == Exit::Exited(0)),
                "container cleanup failed: {result:?}"
            );
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}
#[derive(Debug)]
struct ClientGuard(*mut Client);
impl Drop for ClientGuard {
    fn drop(&mut self) {
        close(self.0);
    }
}
#[derive(Debug)]
struct ViewGuard(*mut ViewHandle);
impl Drop for ViewGuard {
    fn drop(&mut self) {
        close_view(self.0);
    }
}

#[derive(Debug, Clone, Copy)]
enum Case {
    Accepted,
    UnknownIdentity,
    NoIdentity,
    WrongRoot,
    WrongName,
}
fn endpoint(
    certs: &Fixtures,
    peer: SocketAddr,
    case: Case,
    signatures: Arc<AtomicUsize>,
) -> Endpoint {
    let mut context = SslContextBuilder::new(SslMethod::tls()).unwrap();
    crate::endpoint::tls::configure(
        &mut context,
        vec![if matches!(case, Case::WrongRoot) {
            certs.other_root.der.clone()
        } else {
            certs.root.der.clone()
        }],
    )
    .unwrap();
    if !matches!(case, Case::NoIdentity) {
        let identity = if matches!(case, Case::UnknownIdentity) {
            &certs.other_client
        } else {
            &certs.client
        };
        context
            .set_certificate(&X509::from_der(&identity.der).unwrap())
            .unwrap();
        context.set_private_key_method(Key {
            key: PKey::private_key_from_der(&identity.key).unwrap(),
            signatures,
        });
    }
    let host = HostName::try_from(
        if matches!(case, Case::WrongName) {
            "wrong.example"
        } else {
            "localhost"
        }
        .to_owned(),
    )
    .unwrap();
    let mut tcp = crate::endpoint::config(vec![if matches!(case, Case::WrongRoot) {
        certs.other_root.der.clone()
    } else {
        certs.root.der.clone()
    }])
    .unwrap();
    if !matches!(case, Case::NoIdentity) {
        let identity = if matches!(case, Case::UnknownIdentity) {
            &certs.other_client
        } else {
            &certs.client
        };
        tcp.set_certificate(&X509::from_der(&identity.der).unwrap())
            .unwrap();
        tcp.set_private_key_method(Key {
            key: PKey::private_key_from_der(&identity.key).unwrap(),
            signatures: Arc::new(AtomicUsize::new(0)),
        });
    }
    let target = Arc::new(crate::endpoint::Remote::new(
        Arc::new(crate::endpoint::Tls::new(host, peer.port(), tcp.build())),
        Quic::new(context).unwrap(),
    ));
    Endpoint::Fixed(Dial::Remote {
        target,
        addresses: Arc::from([peer]),
    })
}
fn connect(fixture: &Fixture, endpoint: Endpoint) -> ClientGuard {
    let handle = start(
        endpoint,
        Greeting {
            name: "quic-test".to_owned(),
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
    fixture.probe.client.store(handle, Ordering::SeqCst);
    ClientGuard(handle)
}
fn seen(fixture: &Fixture, predicate: impl Fn(&Seen) -> bool) -> Seen {
    let deadline = Instant::now() + DEADLINE;
    loop {
        let event = fixture
            .events
            .recv_timeout(deadline.saturating_duration_since(Instant::now()))
            .unwrap()
            .seen;
        if predicate(&event) {
            return event;
        }
        assert!(Instant::now() < deadline, "missing event; last: {event:?}");
    }
}
fn access(guard: &ClientGuard) -> Arc<crate::endpoint::Resolved> {
    locked(&client(guard.0).unwrap().shared.resolved)
        .clone()
        .unwrap()
}
fn bytes(decoder: &Decoder, want: &[u8]) -> u64 {
    let deadline = Instant::now() + DEADLINE;
    let mut received = Vec::new();
    let mut first = None;
    while received.len() < want.len() {
        match locked(&decoder.feeds)
            .recv_timeout(deadline.saturating_duration_since(Instant::now()))
            .unwrap()
        {
            Fed::Bytes(offset, bytes) => {
                let start = *first.get_or_insert(offset);
                assert_eq!(offset, start + received.len() as u64);
                received.extend(bytes);
            }
            Fed::Resize(..) => {}
            event => panic!("unexpected feed: {event:?}"),
        }
    }
    assert_eq!(received, want);
    first.unwrap()
}

#[test]
fn dropped_quic_udp_falls_back_to_tcp_within_one_budget() {
    use std::net::{TcpListener, UdpSocket};
    let certs = Fixtures::new();
    let tcp = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = tcp.local_addr().unwrap();
    let _dropped = UdpSocket::bind(address).unwrap();
    let fixture = Fixture::new();
    let target = endpoint(
        &certs,
        address,
        Case::Accepted,
        Arc::new(AtomicUsize::new(0)),
    );
    let Endpoint::Fixed(Dial::Remote { target: remote, .. }) = &target else {
        panic!("remote")
    };
    let remote = Arc::clone(remote);
    let client = connect(&fixture, target);
    _dropped.set_read_timeout(Some(DEADLINE)).unwrap();
    let (_, first) = _dropped.recv_from(&mut [0; 2048]).unwrap();
    assert_eq!(ko_client_path_changed(client.0), Code::Ok);
    let began = Instant::now();
    let deadline = began + DEADLINE;
    while _dropped.recv_from(&mut [0; 2048]).unwrap().1 == first {
        assert!(Instant::now() < deadline);
    }
    assert_eq!(
        ko_sys::fd::wait(
            tcp.as_fd(),
            ko_sys::fd::Want::Read,
            None,
            Some(Duration::from_secs(3))
        )
        .unwrap(),
        ko_sys::fd::Waited::Ready
    );
    assert!(began.elapsed() < Duration::from_secs(3));
    let config = crate::wire::tests::tls::server(&certs);
    let mut socket =
        tungstenite::accept(crate::wire::tests::tls::accept(&tcp, Arc::clone(&config))).unwrap();
    assert!(socket.read().unwrap().is_text());
    for message in [
        welcome(INSTANCE, 1),
        layout(0),
        r#"{"type":"selected"}"#.to_owned(),
    ] {
        socket.send(Message::text(message)).unwrap();
    }
    seen(&fixture, |event| matches!(event, Seen::Welcome(..)));
    assert_eq!(remote.choice(), crate::endpoint::Choice::Tcp);
    _dropped.set_nonblocking(true).unwrap();
    let drained = Instant::now() + DEADLINE;
    while _dropped.recv(&mut [0; 2048]).is_ok() {
        assert!(Instant::now() < drained);
    }
    assert_eq!(ko_client_path_changed(client.0), Code::Ok);
    socket.close(None).unwrap();
    drop(socket);
    assert_eq!(
        seen(&fixture, |event| matches!(event, Seen::Failed(..))),
        Seen::Failed(Code::Closed, "server closed".to_owned())
    );
    drop(tcp);
    assert!(matches!(
        seen(&fixture, |event| matches!(event, Seen::Failed(..))),
        Seen::Failed(Code::NoServer, _)
    ));
    std::thread::sleep(Duration::from_millis(1500));
    let tcp = TcpListener::bind(address).unwrap();
    let hinted = Instant::now();
    assert_eq!(ko_client_path_changed(client.0), Code::Ok);
    assert_eq!(
        ko_sys::fd::wait(
            tcp.as_fd(),
            ko_sys::fd::Want::Read,
            None,
            Some(Duration::from_millis(500))
        )
        .unwrap(),
        ko_sys::fd::Waited::Ready,
        "the retry after the grown backoff is due about 1.5 s later; only the hint connects now"
    );
    writeln!(
        std::io::stderr().lock(),
        "a hint during a retry wait connected after {:?}",
        hinted.elapsed()
    )
    .unwrap();
    let mut socket = tungstenite::accept(crate::wire::tests::tls::accept(&tcp, config)).unwrap();
    assert!(socket.read().unwrap().is_text());
    for message in [
        welcome(INSTANCE, 1),
        layout(0),
        r#"{"type":"selected"}"#.to_owned(),
    ] {
        socket.send(Message::text(message)).unwrap();
    }
    seen(&fixture, |event| matches!(event, Seen::Welcome(..)));
    assert_eq!(remote.choice(), crate::endpoint::Choice::Tcp);
    assert_eq!(
        _dropped.recv(&mut [0; 2048]).unwrap_err().kind(),
        io::ErrorKind::WouldBlock
    );
    drop(client);
}

#[test]
fn quic_authentication_failures_do_not_try_tcp() {
    for (case, expected) in [
        (Case::WrongRoot, Code::Tls),
        (Case::UnknownIdentity, Code::Identity),
    ] {
        let certs = Fixtures::new();
        let mut server = SslContextBuilder::new(SslMethod::tls()).unwrap();
        crate::wire::tests::tls::configure_server(&mut server, &certs);
        let mut poll = ko_sys::event::Poll::new();
        let mut peer = crate::wire::quic::tests::Peer::new(server, &mut poll);
        let address = peer.socket.local_addr().unwrap();
        let tcp = std::net::TcpListener::bind(address).unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let stopping = Arc::clone(&stop);
        let worker = std::thread::spawn(move || {
            let deadline = Instant::now() + DEADLINE;
            while !stopping.load(Ordering::SeqCst) {
                assert!(Instant::now() < deadline);
                peer.receive();
                peer.flush();
                std::thread::yield_now();
            }
        });
        let fixture = Fixture::new();
        let target = endpoint(&certs, address, case, Arc::new(AtomicUsize::new(0)));
        let Endpoint::Fixed(Dial::Remote { target: remote, .. }) = &target else {
            panic!("remote")
        };
        let remote = Arc::clone(remote);
        let client = connect(&fixture, target);
        let event = seen(&fixture, |event| matches!(event, Seen::Failed(..)));
        assert!(
            matches!(event, Seen::Failed(code, _) if code == expected),
            "{event:?}"
        );
        assert_ne!(remote.choice(), crate::endpoint::Choice::Tcp);
        assert_eq!(ko_client_path_changed(client.0), Code::Ok);
        if matches!(case, Case::WrongRoot) {
            assert_eq!(fixture.quiet_for(Duration::from_millis(500)), []);
        }
        assert_eq!(
            ko_sys::fd::wait(
                tcp.as_fd(),
                ko_sys::fd::Want::Read,
                None,
                Some(Duration::ZERO)
            )
            .unwrap(),
            ko_sys::fd::Waited::TimedOut
        );
        drop(client);
        stop.store(true, Ordering::SeqCst);
        worker.join().unwrap();
    }
}

#[derive(Debug, Default)]
struct BytesIo {
    input: VecDeque<u8>,
    output: VecDeque<u8>,
}
impl Read for BytesIo {
    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        let count = bytes.len().min(self.input.len());
        if count == 0 {
            return Err(io::ErrorKind::WouldBlock.into());
        }
        for byte in bytes.iter_mut().take(count) {
            *byte = self.input.pop_front().unwrap();
        }
        Ok(count)
    }
}
impl Write for BytesIo {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.output.extend(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}
#[derive(Debug, Clone, Copy)]
enum Side {
    Client,
    View,
}
#[derive(Debug)]
struct Served {
    id: u64,
    side: Side,
    context: tungstenite::protocol::WebSocketContext,
    bytes: BytesIo,
}
impl Served {
    fn send(&mut self, message: Message) {
        self.context.write(&mut self.bytes, message).unwrap();
        self.context.flush(&mut self.bytes).unwrap();
    }
}
struct Scripted {
    peer: crate::wire::quic::tests::Peer,
    http: Option<quiche::h3::Connection>,
    served: Vec<Served>,
    hellos: usize,
    views: usize,
    reset: Option<PaneId>,
    pending: Vec<(u64, &'static [u8])>,
    trace: Option<String>,
    timeout: ko_sys::event::Timer,
}
impl std::fmt::Debug for Scripted {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("Scripted")
            .field("peer", &self.peer)
            .field("served", &self.served)
            .finish_non_exhaustive()
    }
}
impl Scripted {
    fn new(certs: &Fixtures, poll: &mut ko_sys::event::Poll) -> Self {
        let mut server = SslContextBuilder::new(SslMethod::tls()).unwrap();
        crate::wire::tests::tls::configure_server(&mut server, certs);
        Self {
            peer: crate::wire::quic::tests::Peer::new(server, poll),
            http: None,
            served: Vec::new(),
            hellos: 0,
            views: 0,
            reset: None,
            pending: Vec::new(),
            trace: None,
            timeout: poll.timer(),
        }
    }
    fn client(&self) -> Option<SocketAddr> {
        self.peer
            .connection
            .as_ref()?
            .path_stats()
            .find(|path| path.active)
            .map(|path| path.peer_addr)
    }
    fn wait(&mut self, poll: &mut ko_sys::event::Poll, nudge: &Wake, deadline: Instant) {
        self.peer.flush();
        let left = deadline.saturating_duration_since(Instant::now());
        let due = self
            .peer
            .connection
            .as_ref()
            .and_then(quiche::Connection::timeout)
            .map_or(left, |timeout| timeout.min(left));
        poll.start(self.timeout, due, None).unwrap();
        let mut events = ko_sys::event::Events::default();
        poll.turn(ko_sys::event::Mode::Wait, &mut events).unwrap();
        nudge.drain();
    }
    fn turn(&mut self) {
        use quiche::h3::NameValue;
        self.peer.receive();
        let trace = self
            .peer
            .connection
            .as_ref()
            .map(quiche::Connection::trace_id);
        if trace != self.trace.as_deref() {
            self.trace = trace.map(str::to_owned);
            self.http = None;
            self.served.clear();
        }
        let Some(transport) = &mut self.peer.connection else {
            return;
        };
        if transport.is_established() && self.http.is_none() {
            let mut config = quiche::h3::Config::new().unwrap();
            config.enable_extended_connect(true);
            self.http = Some(quiche::h3::Connection::with_transport(transport, &config).unwrap());
        }
        let Some(http) = &mut self.http else {
            return;
        };
        while let Ok((id, event)) = http.poll(transport) {
            let quiche::h3::Event::Headers { list, .. } = event else {
                continue;
            };
            for (name, value) in [
                (b":method".as_slice(), b"CONNECT".as_slice()),
                (b":protocol", b"websocket"),
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
            let path = std::str::from_utf8(
                list.iter()
                    .find(|header| header.name() == b":path")
                    .unwrap()
                    .value(),
            )
            .unwrap();
            let (side, data) = match Route::of_request("GET", path).unwrap() {
                Route::Client {} => (Side::Client, None),
                Route::View {
                    id: pane, offset, ..
                } => {
                    assert_eq!(
                        list.iter()
                            .find(|header| header.name() == b"ko-client")
                            .unwrap()
                            .value(),
                        b"client_7"
                    );
                    self.views += 1;
                    if self.reset == Some(pane) {
                        self.reset = None;
                        transport
                            .stream_shutdown(id, quiche::Shutdown::Write, 0x10c)
                            .unwrap();
                        continue;
                    }
                    (
                        Side::View,
                        offset
                            .is_none()
                            .then_some(if pane == "pane_1".parse().unwrap() {
                                b"A".as_slice()
                            } else {
                                b"B".as_slice()
                            }),
                    )
                }
                route => panic!("unexpected route: {route:?}"),
            };
            http.send_response(
                transport,
                id,
                &[quiche::h3::Header::new(b":status", b"200")],
                false,
            )
            .unwrap();
            let mut stream = Served {
                id,
                side,
                context: tungstenite::protocol::WebSocketContext::new(
                    Role::Server,
                    Some(tungstenite::protocol::WebSocketConfig::default().write_buffer_size(0)),
                ),
                bytes: BytesIo::default(),
            };
            if let Some(data) = data {
                stream.send(Message::Binary(
                    slice_record(10, true, true, true, b"s").into(),
                ));
                stream.send(Message::Binary(output_record(10, data).into()));
            }
            self.served.push(stream);
        }
        if self
            .served
            .iter()
            .any(|stream| matches!(stream.side, Side::View))
        {
            for (offset, data) in std::mem::take(&mut self.pending) {
                for stream in &mut self.served {
                    if matches!(stream.side, Side::View) {
                        stream.send(Message::Binary(output_record(offset, data).into()));
                    }
                }
            }
        }
        for stream in &mut self.served {
            let mut bytes = [0; 65536];
            loop {
                match http.recv_body(transport, stream.id, &mut bytes) {
                    Ok(count) => stream.bytes.input.extend(&bytes[..count]),
                    Err(quiche::h3::Error::Done) => break,
                    Err(error) => panic!("{error}"),
                }
            }
            loop {
                match stream.context.read(&mut stream.bytes) {
                    Ok(Message::Text(text)) => match stream.side {
                        Side::Client => {
                            assert!(matches!(
                                protocol::decode::<protocol::ClientRequest>(text.as_bytes())
                                    .unwrap(),
                                protocol::ClientRequest::Hello(_)
                            ));
                            self.hellos += 1;
                            for text in [
                                welcome(INSTANCE, 1),
                                layout(0),
                                "{\"type\":\"selected\"}".to_owned(),
                            ] {
                                stream.send(Message::text(text));
                            }
                        }
                        Side::View => panic!("unexpected view request: {text}"),
                    },
                    Ok(_) => {}
                    Err(tungstenite::Error::Io(error))
                        if error.kind() == io::ErrorKind::WouldBlock =>
                    {
                        break;
                    }
                    Err(error) => panic!("{error}"),
                }
            }
            if !stream.bytes.output.is_empty() {
                match http.send_body(
                    transport,
                    stream.id,
                    stream.bytes.output.make_contiguous(),
                    false,
                ) {
                    Ok(count) => {
                        stream.bytes.output.drain(..count);
                    }
                    Err(quiche::h3::Error::Done | quiche::h3::Error::StreamBlocked) => {}
                    Err(error) => panic!("{error}"),
                }
            }
        }
    }
}

#[test]
fn quic_address_selection_view_reset_and_cached_tcp_reconnect() {
    use ko_sys::event::{Mode, Poll};
    let certs = Fixtures::new();
    let mut poll = Poll::new();
    let mut scripted = Scripted::new(&certs, &mut poll);
    scripted.reset = Some("pane_1".parse().unwrap());
    let address = scripted.peer.socket.local_addr().unwrap();
    let tcp = std::net::TcpListener::bind(address).unwrap();
    let silent = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
    let (drop_udp, commands) = channel();
    let dropped = Arc::new(AtomicUsize::new(0));
    let datagrams = Arc::clone(&dropped);
    let stop = Arc::new(AtomicBool::new(false));
    let stopping = Arc::clone(&stop);
    let worker = std::thread::spawn(move || {
        let deadline = Instant::now() + DEADLINE;
        while !stopping.load(Ordering::SeqCst) {
            assert!(Instant::now() < deadline, "scripted HTTP/3 server deadline");
            if commands.try_recv().is_ok() {
                let peer = &mut scripted.peer;
                peer.connection
                    .as_mut()
                    .unwrap()
                    .close(true, 0x100, b"reconnect with UDP dropped")
                    .unwrap();
                peer.flush();
                while !stopping.load(Ordering::SeqCst) {
                    assert!(Instant::now() < deadline, "dropped UDP server deadline");
                    match peer.socket.recv_from(&mut [0; 2048]) {
                        Ok(_) => {
                            datagrams.fetch_add(1, Ordering::SeqCst);
                        }
                        Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                            std::thread::yield_now()
                        }
                        Err(error) => panic!("{error}"),
                    }
                }
                break;
            }
            scripted.turn();
            scripted.peer.flush();
            let mut events = ko_sys::event::Events::default();
            poll.turn(Mode::Peek, &mut events).unwrap();
        }
        (scripted.hellos, scripted.views)
    });
    let fixture = Fixture::new();
    let signatures = Arc::new(AtomicUsize::new(0));
    let mut target = endpoint(&certs, address, Case::Accepted, Arc::clone(&signatures));
    let Endpoint::Fixed(Dial::Remote {
        target: remote,
        addresses,
    }) = &mut target
    else {
        panic!("remote")
    };
    *addresses = Arc::from([silent.local_addr().unwrap(), address]);
    let remote = Arc::clone(remote);
    let main = connect(&fixture, target);
    seen(&fixture, |event| matches!(event, Seen::Welcome(..)));
    seen(&fixture, |event| matches!(event, Seen::Layout(..)));
    assert_eq!(remote.choice(), crate::endpoint::Choice::Quic);
    assert_eq!(
        ko_sys::fd::wait(
            tcp.as_fd(),
            ko_sys::fd::Want::Read,
            None,
            Some(Duration::ZERO)
        )
        .unwrap(),
        ko_sys::fd::Waited::TimedOut
    );
    let decoder = || {
        Decoder::new(|snapshot| {
            pull(snapshot, usize::MAX, 64).unwrap();
            Restored::Ok
        })
    };
    let first = decoder();
    let second = decoder();
    let a = ViewGuard(open_view_of(c"pane_1", main.0, first, true));
    let b = ViewGuard(open_view_of(c"pane_2", main.0, second, true));
    assert_eq!(bytes(first, b"A"), 10);
    assert_eq!(bytes(second, b"B"), 10);
    assert_eq!(signatures.load(Ordering::SeqCst), 1);
    drop(a);
    drop(b);
    drop_udp.send(()).unwrap();
    seen(&fixture, |event| matches!(event, Seen::Failed(..)));
    let began = Instant::now();
    assert_eq!(
        ko_sys::fd::wait(
            tcp.as_fd(),
            ko_sys::fd::Want::Read,
            None,
            Some(Duration::from_secs(3))
        )
        .unwrap(),
        ko_sys::fd::Waited::Ready
    );
    assert!(began.elapsed() < Duration::from_secs(3));
    let config = crate::wire::tests::tls::server(&certs);
    let mut socket =
        tungstenite::accept(crate::wire::tests::tls::accept(&tcp, Arc::clone(&config))).unwrap();
    assert!(socket.read().unwrap().is_text());
    for text in [
        welcome(INSTANCE, 1),
        layout(0),
        "{\"type\":\"selected\"}".to_owned(),
    ] {
        socket.send(Message::text(text)).unwrap();
    }
    seen(&fixture, |event| matches!(event, Seen::Welcome(..)));
    assert_eq!(remote.choice(), crate::endpoint::Choice::Tcp);
    let count = dropped.load(Ordering::SeqCst);
    assert!(count > 0);
    socket.close(None).unwrap();
    drop(socket);
    seen(&fixture, |event| matches!(event, Seen::Failed(..)));
    assert_eq!(
        ko_sys::fd::wait(
            tcp.as_fd(),
            ko_sys::fd::Want::Read,
            None,
            Some(Duration::from_secs(1))
        )
        .unwrap(),
        ko_sys::fd::Waited::Ready
    );
    let mut socket = tungstenite::accept(crate::wire::tests::tls::accept(&tcp, config)).unwrap();
    assert!(socket.read().unwrap().is_text());
    for text in [
        welcome(INSTANCE, 1),
        layout(0),
        "{\"type\":\"selected\"}".to_owned(),
    ] {
        socket.send(Message::text(text)).unwrap();
    }
    seen(&fixture, |event| matches!(event, Seen::Welcome(..)));
    assert_eq!(remote.choice(), crate::endpoint::Choice::Tcp);
    assert_eq!(dropped.load(Ordering::SeqCst), count);
    drop(main);
    stop.store(true, Ordering::SeqCst);
    assert_eq!(worker.join().unwrap(), (1, 3));
}

#[test]
fn a_path_change_migrates_quic_under_an_open_view() {
    use ko_sys::event::Poll;
    let certs = Fixtures::new();
    let mut poll = Poll::new();
    let mut scripted = Scripted::new(&certs, &mut poll);
    let address = scripted.peer.socket.local_addr().unwrap();
    let (output, outputs) = channel::<(u64, &'static [u8])>();
    let (moved, paths) = channel();
    let stop = Arc::new(AtomicBool::new(false));
    let stopping = Arc::clone(&stop);
    let nudge = Arc::new(Wake::new().unwrap());
    let nudged = Arc::clone(&nudge);
    poll.watch(nudge.fd(), ko_sys::event::Interest::Read);
    let worker = std::thread::spawn(move || {
        let deadline = Instant::now() + DEADLINE;
        let mut client = None;
        while !stopping.load(Ordering::SeqCst) {
            assert!(Instant::now() < deadline, "scripted HTTP/3 server deadline");
            scripted.pending.extend(outputs.try_iter());
            scripted.turn();
            let current = scripted.client();
            if current != client {
                client = current;
                moved.send(client.unwrap()).unwrap();
            }
            scripted.wait(&mut poll, &nudged, deadline);
        }
        (scripted.hellos, scripted.views)
    });
    let fixture = Fixture::new();
    let signatures = Arc::new(AtomicUsize::new(0));
    let main = connect(
        &fixture,
        endpoint(&certs, address, Case::Accepted, Arc::clone(&signatures)),
    );
    seen(&fixture, |event| matches!(event, Seen::Welcome(..)));
    let mut client = paths.recv_timeout(DEADLINE).unwrap();
    let decoder = Decoder::new(|snapshot| {
        pull(snapshot, usize::MAX, 64).unwrap();
        Restored::Ok
    });
    let view = ViewGuard(open_view_of(c"pane_2", main.0, decoder, true));
    assert_eq!(bytes(decoder, b"B"), 10);
    for (offset, data) in [(11, b"C"), (12, b"D"), (13, b"E")] {
        assert_eq!(ko_client_path_changed(main.0), Code::Ok);
        let moved = paths.recv_timeout(DEADLINE).unwrap();
        assert_ne!(moved, client);
        assert_eq!(moved.ip(), client.ip());
        client = moved;
        output.send((offset, data)).unwrap();
        nudge.wake();
        assert_eq!(bytes(decoder, data), offset);
    }
    assert!(!fixture.quiet().iter().any(|event| matches!(
        event,
        Seen::Welcome(..) | Seen::Failed(..) | Seen::Closed(..)
    )));
    assert_eq!(signatures.load(Ordering::SeqCst), 1);
    let began = Instant::now();
    assert_eq!(ko_client_path_changed(main.0), Code::Ok);
    assert!(matches!(
        seen(&fixture, |event| matches!(
            event,
            Seen::Welcome(..) | Seen::Failed(..)
        )),
        Seen::Welcome(_, _, false)
    ));
    output.send((14, b"F")).unwrap();
    nudge.wake();
    assert_eq!(bytes(decoder, b"F"), 14);
    writeln!(
        std::io::stderr().lock(),
        "a refused fourth migration resumed the view in {:?}",
        began.elapsed()
    )
    .unwrap();
    assert!(
        !fixture
            .quiet()
            .iter()
            .any(|event| matches!(event, Seen::Failed(..) | Seen::Closed(..)))
    );
    assert_eq!(signatures.load(Ordering::SeqCst), 2);
    drop(view);
    drop(main);
    stop.store(true, Ordering::SeqCst);
    nudge.wake();
    assert_eq!(worker.join().unwrap(), (2, 2));
}

#[test]
fn an_idle_expiry_during_a_stall_rejoins_at_once_and_resumes_the_view() {
    use ko_sys::event::Poll;
    const IDLE: Duration = Duration::from_millis(500);
    let certs = Fixtures::new();
    let mut poll = Poll::new();
    let mut scripted = Scripted::new(&certs, &mut poll);
    scripted
        .peer
        .config
        .set_max_idle_timeout(u64::try_from(IDLE.as_millis()).unwrap());
    let address = scripted.peer.socket.local_addr().unwrap();
    let (output, outputs) = channel::<(u64, &'static [u8])>();
    let stop = Arc::new(AtomicBool::new(false));
    let stopping = Arc::clone(&stop);
    let nudge = Arc::new(Wake::new().unwrap());
    let nudged = Arc::clone(&nudge);
    poll.watch(nudge.fd(), ko_sys::event::Interest::Read);
    let worker = std::thread::spawn(move || {
        let deadline = Instant::now() + DEADLINE * 2;
        while !stopping.load(Ordering::SeqCst) {
            assert!(Instant::now() < deadline, "scripted HTTP/3 server deadline");
            scripted.pending.extend(outputs.try_iter());
            scripted.turn();
            scripted.wait(&mut poll, &nudged, deadline);
        }
        (scripted.hellos, scripted.views)
    });
    let fixture = Fixture::new();
    let main = connect(
        &fixture,
        endpoint(
            &certs,
            address,
            Case::Accepted,
            Arc::new(AtomicUsize::new(0)),
        ),
    );
    seen(&fixture, |event| matches!(event, Seen::Welcome(..)));
    let decoder = Decoder::new(|snapshot| {
        pull(snapshot, usize::MAX, 64).unwrap();
        Restored::Ok
    });
    let view = ViewGuard(open_view_of(c"pane_2", main.0, decoder, true));
    assert_eq!(bytes(decoder, b"B"), 10);
    let shared = Arc::clone(&client(main.0).unwrap().shared);
    for (hint, offset, data) in [(true, 11, b"C"), (false, 12, b"D")] {
        let mut commands = locked(&shared.commands);
        shared.wake.wake();
        std::thread::sleep(IDLE * 2);
        if hint {
            commands.push_back(Command::PathChanged);
        }
        drop(commands);
        let resumed = Instant::now();
        assert!(matches!(
            seen(&fixture, |event| matches!(
                event,
                Seen::Welcome(..) | Seen::Failed(..)
            )),
            Seen::Welcome(_, _, false)
        ));
        output.send((offset, data)).unwrap();
        nudge.wake();
        assert_eq!(bytes(decoder, data), offset);
        writeln!(
            std::io::stderr().lock(),
            "a stall past the idle timeout (hint: {hint}) resumed the view in {:?}",
            resumed.elapsed()
        )
        .unwrap();
        assert!(resumed.elapsed() < IDLE);
    }
    assert!(
        !fixture
            .quiet()
            .iter()
            .any(|event| matches!(event, Seen::Failed(..) | Seen::Closed(..)))
    );
    drop(view);
    drop(main);
    stop.store(true, Ordering::SeqCst);
    nudge.wake();
    assert_eq!(worker.join().unwrap(), (3, 3));
}

#[test]
fn caddy_http3_authentication_refusals_and_exact_view_resume() {
    if std::env::var_os("KO_E2E_CONTAINER").as_deref() != Some(std::ffi::OsStr::new("1")) {
        return;
    }
    let path = std::env::var_os("PATH").unwrap();
    let cli = std::env::split_paths(&path)
        .map(|path| path.join("container"))
        .find(|path| path.is_file())
        .expect("KO_E2E_CONTAINER needs the container CLI");
    let certs = Fixtures::new();
    let (container, peer) = Container::start(cli, path.as_bytes().to_vec(), &certs);
    let caddy = container.ok(&["exec", &container.name, "caddy", "version"]);
    assert!(caddy.starts_with("v2.11.9"), "{caddy}");
    let fixture = Fixture::new();
    let signatures = Arc::new(AtomicUsize::new(0));
    let main = connect(
        &fixture,
        endpoint(&certs, peer, Case::Accepted, Arc::clone(&signatures)),
    );
    let initial = seen(&fixture, |event| matches!(event, Seen::Welcome(..)));
    let Seen::Welcome(_, instance, true) = initial else {
        panic!("{initial:?}");
    };
    seen(&fixture, |event| matches!(event, Seen::Layout(..)));
    let resolved = access(&main);
    let (mismatch, _) = crate::api::version(&resolved, DEADLINE, None).unwrap();
    assert_eq!(mismatch, None);
    let crate::endpoint::Resolved::Quic(handles) = resolved.as_ref() else {
        panic!("not QUIC");
    };
    let mut missing = handles
        .open(crate::wire::exchange::RequestHead::WebSocket {
            target: "/client".to_owned().try_into().unwrap(),
            headers: vec![("sec-websocket-version".to_owned(), "13".to_owned())],
        })
        .unwrap();
    let deadline = Instant::now() + DEADLINE;
    let refusal = loop {
        if let Some(head) = missing.response().unwrap() {
            break head;
        }
        ko_sys::fd::wait(
            missing.fd(),
            ko_sys::fd::Want::Read,
            None,
            Some(deadline.saturating_duration_since(Instant::now())),
        )
        .unwrap();
        assert!(Instant::now() < deadline);
    };
    assert_eq!(refusal.status, 426);
    drop(missing);
    let pane:protocol::NewWindow=protocol::decode(br#"{"command":{"type":"argv","argv":["/bin/sh","-c","stty -echo; printf READY; while IFS= read -r line; do printf '%s' \"$line\"; done"]},"cwd":"/tmp","close":"on_exit"}"#).unwrap();
    let reply = crate::wire::request_within(
        &resolved,
        (None, None),
        &ko_wire::api::Route::NewPane {},
        protocol::json(&pane).as_bytes(),
        (None, DEADLINE),
    )
    .unwrap();
    let placement: protocol::Placement = protocol::decode(&reply).unwrap();
    let cancel = Wake::new().unwrap();
    let upload_route = Route::UploadDrop {
        id: placement.pane,
        name: "h3-file".to_owned().try_into().unwrap(),
    };
    let payload = vec![b'u'; 150000];
    let mut reader = io::Cursor::new(payload.clone());
    let uploaded = crate::wire::upload(
        &resolved,
        None,
        &upload_route,
        payload.len() as u64,
        &cancel,
        |buffer| reader.read(buffer),
    )
    .unwrap();
    let dropped: protocol::Dropped = protocol::decode(&uploaded).unwrap();
    assert_eq!(
        container
            .ok(&["exec", &container.name, "cat", dropped.path.as_str()])
            .as_bytes(),
        payload
    );
    let mut pulls = 0;
    let refused_route = Route::UploadDrop {
        id: "pane_999999".parse().unwrap(),
        name: "refused".to_owned().try_into().unwrap(),
    };
    let refused = crate::wire::upload(
        &resolved,
        None,
        &refused_route,
        8 << 20,
        &cancel,
        |buffer| {
            pulls += 1;
            buffer.fill(b'x');
            Ok(buffer.len())
        },
    )
    .unwrap_err();
    let crate::wire::Rejected::Status { status, body, .. } = refused else {
        panic!("{refused}")
    };
    assert_eq!(status, 404);
    let refusal: protocol::Error = protocol::decode(&body).unwrap();
    assert_eq!(refusal.message, "pane not found");
    assert!(pulls < 128);
    let mut reads = 0;
    let cancelled =
        crate::wire::upload(&resolved, None, &upload_route, 8 << 20, &cancel, |buffer| {
            reads += 1;
            if reads == 1 {
                return Ok(4096);
            }
            cancel.wake();
            Ok(buffer.len())
        })
        .unwrap_err();
    assert!(cancelled.to_string().contains("cancel"), "{cancelled}");
    assert_eq!(reads, 2);
    let mut refused = handles
        .open(crate::wire::exchange::RequestHead::Http {
            method: protocol::Method::Post,
            target: refused_route.to_request().1,
            headers: protocol::version_headers()
                .into_iter()
                .map(|(name, value)| (name.to_owned(), value))
                .collect(),
            length: 8 << 20,
        })
        .unwrap();
    assert_eq!(refused.write(&[b'x'; 65536]).unwrap(), 65536);
    let deadline = Instant::now() + DEADLINE;
    let mut status = None;
    let mut answer = Vec::new();
    loop {
        assert!(
            Instant::now() < deadline,
            "Caddy upload refusal did not finish"
        );
        if let Some(head) = refused.response().unwrap() {
            status = Some(head.status);
        }
        let mut bytes = [0; 1024];
        match refused.read(&mut bytes) {
            Ok(0) => break,
            Ok(count) => answer.extend_from_slice(&bytes[..count]),
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                std::thread::yield_now();
            }
            Err(error) => panic!("Caddy reset the response direction: {error}"),
        }
    }
    assert_eq!(status, Some(404));
    let refusal: protocol::Error = protocol::decode(&answer).unwrap();
    assert_eq!(refusal.message, "pane not found");
    let outcome = loop {
        assert!(
            Instant::now() < deadline,
            "Caddy request direction did not settle"
        );
        match refused.write(&[b'x'; 65536]) {
            Err(error) if error.kind() != io::ErrorKind::WouldBlock => break error.to_string(),
            _ => std::thread::yield_now(),
        }
    };
    writeln!(
        std::io::stderr().lock(),
        "Caddy {} early upload refusal: {outcome}",
        caddy.trim()
    )
    .unwrap();
    assert!(outcome.contains("request stopped"), "{outcome}");
    drop(refused);
    assert_eq!(
        crate::api::version(&resolved, DEADLINE, None).unwrap().0,
        None
    );
    let started = Instant::now() + DEADLINE;
    loop {
        assert!(Instant::now() < started, "the pane did not print READY");
        let screen = crate::wire::request_within(
            &resolved,
            (None, None),
            &ko_wire::api::Route::Screen {
                id: placement.pane,
                format: ko_pane_wire::frame::ScreenFormat::Plain,
                history: ko_pane_wire::frame::ScreenRows::Visible,
            },
            b"",
            (None, started.saturating_duration_since(Instant::now())),
        )
        .unwrap();
        if String::from_utf8(screen).unwrap().contains("READY") {
            break;
        }
    }
    let restores = Arc::new(AtomicU64::new(0));
    let restored = Arc::clone(&restores);
    let (ready, restoration) = channel();
    let decoder = Decoder::new(move |snapshot| {
        pull(snapshot, usize::MAX, 65536).unwrap();
        restored.fetch_add(1, Ordering::SeqCst);
        ready.send(()).unwrap();
        Restored::Ok
    });
    let pane_name = CString::new(placement.pane.to_string()).unwrap();
    let view = ViewGuard(open_view_of(&pane_name, main.0, decoder, true));
    restoration.recv_timeout(DEADLINE).unwrap();
    let second = Decoder::new(|snapshot| {
        pull(snapshot, usize::MAX, 65536).unwrap();
        Restored::Ok
    });
    let second_view = ViewGuard(open_view_of(&pane_name, main.0, second, true));
    let input = |text: &[u8]| {
        let body = protocol::Input::Text {
            data: protocol::Text(text.to_vec()),
        };
        crate::wire::request_within(
            &access(&main),
            (None, None),
            &ko_wire::api::Route::Input { id: placement.pane },
            protocol::json(&body).as_bytes(),
            (None, DEADLINE),
        )
        .unwrap();
    };
    input(b"one\n");
    let first_offset = bytes(decoder, b"one") + 3;
    assert_eq!(bytes(second, b"one") + 3, first_offset);
    assert_eq!(signatures.load(Ordering::SeqCst), 1);
    let mut held = Vec::new();
    for _ in 0..256 {
        match handles.open(crate::wire::exchange::RequestHead::Http {
            method: protocol::Method::Get,
            target: "/version".to_owned().try_into().unwrap(),
            headers: Vec::new(),
            length: 0,
        }) {
            Ok(handle) => held.push(handle),
            Err(error) => {
                assert!(matches!(
                    error.get_ref().and_then(
                        |error| error.downcast_ref::<crate::wire::quic::h3::StreamFailure>()
                    ),
                    Some(crate::wire::quic::h3::StreamFailure::Admission)
                ));
                break;
            }
        }
    }
    let full = Instant::now() + DEADLINE;
    loop {
        if held.iter_mut().any(|handle| {
            handle.response().is_err_and(|error| {
                matches!(
                    error.get_ref().and_then(
                        |error| error.downcast_ref::<crate::wire::quic::h3::StreamFailure>()
                    ),
                    Some(crate::wire::quic::h3::StreamFailure::Admission)
                )
            })
        }) {
            break;
        }
        assert!(
            Instant::now() < full,
            "stream admission did not report its bound"
        );
        std::thread::yield_now();
    }
    let rejected = ViewGuard(open_view_of(
        &pane_name,
        main.0,
        Decoder::new(|_| Restored::Rejected),
        true,
    ));
    assert!(matches!(
        seen(&fixture, |event| matches!(event, Seen::Closed(..))),
        Seen::Closed(Code::Io, _)
    ));
    drop(rejected);
    let live = handle_of(view.0);
    live.shared.command(Command::Input(
        live.view.id,
        protocol::Input::Text {
            data: protocol::Text(b"cap\n".to_vec()),
        },
    ));
    let offset = bytes(decoder, b"cap") + 3;
    assert_eq!(bytes(second, b"cap") + 3, offset);
    assert_eq!(offset, first_offset + 3);
    assert_eq!(signatures.load(Ordering::SeqCst), 1);
    drop(live);
    drop(held);
    assert_eq!(ko_client_path_changed(main.0), Code::Ok);
    let began = Instant::now();
    input(b"moved\n");
    let moved = std::panic::catch_unwind(|| bytes(decoder, b"moved"));
    let mut events = fixture.quiet();
    let offset = moved.unwrap_or_else(|_| panic!("no bytes after the migration: {events:?}")) + 5;
    writeln!(
        std::io::stderr().lock(),
        "Caddy kept the view across a migration; bytes after {:?}",
        began.elapsed()
    )
    .unwrap();
    assert_eq!(bytes(second, b"moved") + 5, offset);
    assert_eq!(signatures.load(Ordering::SeqCst), 1);
    events.extend(fixture.quiet());
    assert!(
        !events
            .iter()
            .any(|event| matches!(event, Seen::Welcome(..) | Seen::Failed(..))),
        "{events:?}"
    );
    container.control("restart", "caddy");
    seen(&fixture, |event| {
        matches!(event, Seen::Failed(Code::Closed, ..))
    });
    let resumed = seen(&fixture, |event| matches!(event, Seen::Welcome(..)));
    assert!(matches!(resumed,Seen::Welcome(_,ref current,false) if current==&instance));
    input(b"two\n");
    assert_eq!(bytes(decoder, b"two"), offset);
    assert_eq!(bytes(second, b"two"), offset);
    assert_eq!(restores.load(Ordering::SeqCst), 1);
    assert_eq!(signatures.load(Ordering::SeqCst), 2);
    drop(second_view);
    drop(view);
    for (case, expected) in [
        (Case::UnknownIdentity, Code::Identity),
        (Case::WrongRoot, Code::Tls),
        (Case::WrongName, Code::Tls),
    ] {
        let failed = Fixture::new();
        let _client = connect(
            &failed,
            endpoint(&certs, peer, case, Arc::new(AtomicUsize::new(0))),
        );
        let event = seen(&failed, |event| matches!(event, Seen::Failed(..)));
        assert!(
            matches!(event,Seen::Failed(code,_) if code==expected),
            "{case:?}: {event:?}"
        );
    }
    let absent = Fixture::new();
    let without = connect(
        &absent,
        endpoint(
            &certs,
            peer,
            Case::NoIdentity,
            Arc::new(AtomicUsize::new(0)),
        ),
    );
    assert!(matches!(
        seen(&absent, |event| matches!(event, Seen::Failed(..))),
        Seen::Failed(Code::Tls | Code::Identity, _)
    ));
    drop(without);
    drop(main);
    container.control("stop", "ko");
    let down = Fixture::new();
    let no_server = connect(
        &down,
        endpoint(&certs, peer, Case::Accepted, Arc::new(AtomicUsize::new(0))),
    );
    assert!(matches!(
        seen(&down, |event| matches!(event, Seen::Failed(..))),
        Seen::Failed(Code::NoServer, _)
    ));
    drop(no_server);
    std::fs::remove_file(container.dir.join("devices/paired.pem")).unwrap();
    container.control("restart", "caddy");
    let revoked = Fixture::new();
    let _revoked = connect(
        &revoked,
        endpoint(&certs, peer, Case::Accepted, Arc::new(AtomicUsize::new(0))),
    );
    assert!(matches!(
        seen(&revoked, |event| matches!(event, Seen::Failed(..))),
        Seen::Failed(Code::Identity, _)
    ));
}
