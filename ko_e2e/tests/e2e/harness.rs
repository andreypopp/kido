use std::fs::{DirBuilder, File};
use std::io::{Read, Write};
use std::ops::Deref;
use std::os::fd::AsFd;
use std::os::unix::fs::DirBuilderExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::mpsc::{self, Receiver};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use ko_pane_wire::ring::{SLICE_MAX, Slice};
use ko_sys::pid::{Exit, Pid};
use ko_sys::signal::Signal;
use ko_sys::spawn::{self, Env};
use ko_vt::{Extent, Format, Terminal};
use serde_json::{Value, json};
use tungstenite::http::{HeaderName, HeaderValue};
use tungstenite::{Message as Msg, WebSocket};

pub(crate) const DEADLINE: Duration = Duration::from_secs(5);

pub(crate) const PRINT_TOKEN: &str = "printf 'TOKEN<%s>' \"$KO_PANE_TOKEN\"";

// Parallel heavy panes starve a small macOS runner past the 5 s deadline.
pub(crate) static HEAVY: std::sync::Mutex<()> = std::sync::Mutex::new(());

pub(crate) fn ko() -> PathBuf {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../build/ko/bin/ko");
    assert!(
        path.exists(),
        "{} is missing: run make build first",
        path.display()
    );
    path
}

pub(crate) fn text_of(path: &Path) -> &str {
    path.to_str().expect("a UTF-8 path")
}

pub(crate) fn quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\"'\"'"))
}

pub(crate) fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    needle.is_empty()
        || haystack
            .windows(needle.len())
            .any(|window| window == needle)
}

fn time_left(deadline: Instant) -> Duration {
    deadline
        .checked_duration_since(Instant::now())
        .filter(|left| !left.is_zero())
        .expect("the deadline passed")
}

#[derive(Debug)]
pub(crate) struct Steady(UnixStream);

impl Deref for Steady {
    type Target = UnixStream;

    fn deref(&self) -> &UnixStream {
        &self.0
    }
}

impl Read for Steady {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        ko_sys::retry::retry(|| self.0.read(buffer))
    }
}

impl Write for Steady {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        ko_sys::retry::retry(|| self.0.write(bytes))
    }

    fn flush(&mut self) -> std::io::Result<()> {
        ko_sys::retry::retry(|| self.0.flush())
    }
}

fn read_within(stream: &UnixStream, deadline: Instant) {
    stream.set_read_timeout(Some(time_left(deadline))).unwrap();
}

pub(crate) fn within(stream: &UnixStream, deadline: Instant) {
    read_within(stream, deadline);
    stream.set_write_timeout(Some(time_left(deadline))).unwrap();
}

pub(crate) fn poll(what: &str, check: impl FnMut() -> bool) {
    poll_for(what, (DEADLINE, Duration::from_millis(10)), check);
}

pub(crate) fn poll_for(
    what: &str,
    (limit, tick): (Duration, Duration),
    mut check: impl FnMut() -> bool,
) {
    let deadline = Instant::now() + limit;
    while !check() {
        assert!(Instant::now() < deadline, "wait for {what}");
        // A poll tick for a condition that has no descriptor to wait on: an event-less condition.
        thread::park_timeout(tick);
    }
}

pub(crate) fn stays(what: &str, duration: Duration, mut check: impl FnMut() -> bool) {
    let end = Instant::now() + duration;
    while Instant::now() < end {
        assert!(check(), "{what}");
        thread::park_timeout(Duration::from_millis(50));
    }
}

#[derive(Debug)]
pub(crate) struct Dir(PathBuf);

impl Dir {
    pub(crate) fn new(prefix: &str) -> Dir {
        static COUNTER: AtomicU32 = AtomicU32::new(0);
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |since| since.subsec_nanos());
        let path = PathBuf::from(format!(
            "/tmp/{prefix}{}-{}-{nanos}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        DirBuilder::new().mode(0o700).create(&path).unwrap();
        Dir(path)
    }
}

impl Deref for Dir {
    type Target = Path;

    fn deref(&self) -> &Path {
        &self.0
    }
}

impl Drop for Dir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

pub(crate) fn test_env(dir: &Path) -> Vec<Vec<u8>> {
    let mut env: Vec<Vec<u8>> = std::env::vars_os()
        .filter_map(|(name, value)| {
            let name = name.to_string_lossy().into_owned();
            let scrubbed = ["XDG_", "KO_", "BASH_FUNC_"]
                .iter()
                .any(|prefix| name.starts_with(prefix))
                || [
                    "TERM_PROGRAM",
                    "TERM_PROGRAM_VERSION",
                    "HOME",
                    "ZDOTDIR",
                    "ENV",
                    "BASH_ENV",
                    "PROMPT_COMMAND",
                    "SSH_AUTH_SOCK",
                ]
                .contains(&name.as_str());
            (!scrubbed).then(|| format!("{name}={}", value.to_string_lossy()).into_bytes())
        })
        .collect();
    let dir = text_of(dir);
    env.extend([
        format!("HOME={dir}").into_bytes(),
        format!("XDG_CONFIG_HOME={dir}").into_bytes(),
        format!("XDG_STATE_HOME={dir}").into_bytes(),
        b"TERM_PROGRAM=Apple_Terminal".to_vec(),
        b"TERM_PROGRAM_VERSION=999".to_vec(),
    ]);
    env
}

// The reaper waits for the exit without reaping, then reaps under the lock, so a signal that
// holds the lock while `reaped` is false cannot reach a reused pid.
#[derive(Debug)]
pub(crate) struct Child {
    pid: Pid,
    reaped: Arc<Mutex<bool>>,
    exited: Receiver<Exit>,
    ended: Option<Exit>,
}

impl Drop for Child {
    fn drop(&mut self) {
        let _ = self.signal(Signal::Kill);
    }
}

impl Child {
    pub(crate) fn spawn(
        program: &Path,
        args: &[&str],
        env: &[Vec<u8>],
        targets: &[(std::os::fd::BorrowedFd<'_>, u8)],
    ) -> Child {
        let pid = spawn::program(program, args, targets, Env::Only(env), None).unwrap();
        let (sender, exited) = mpsc::channel();
        let reaped = Arc::new(Mutex::new(false));
        let flag = reaped.clone();
        thread::spawn(move || {
            if let Ok(exit) = pid.wait_exit() {
                let mut reaped = flag.lock().unwrap();
                *reaped = true;
                let _ = pid.wait();
                drop(reaped);
                let _ = sender.send(exit);
            }
        });
        Child {
            pid,
            reaped,
            exited,
            ended: None,
        }
    }

    pub(crate) fn pid(&self) -> Pid {
        self.pid
    }

    pub(crate) fn signal(&self, signal: Signal) -> std::io::Result<()> {
        let reaped = self.reaped.lock().unwrap();
        if *reaped {
            Ok(())
        } else {
            self.pid.signal(signal)
        }
    }

    pub(crate) fn wait(&mut self, within: Duration) -> Option<Exit> {
        if self.ended.is_none() {
            self.ended = self.exited.recv_timeout(within).ok();
        }
        self.ended
    }
}

#[derive(Debug)]
pub(crate) struct Run {
    pub(crate) stdout: String,
    pub(crate) stderr: String,
    pub(crate) exit: Exit,
}

impl Run {
    pub(crate) fn ok(self) -> String {
        assert_eq!(self.exit, Exit::Exited(0), "{self:?}");
        assert_eq!(self.stderr, "", "{self:?}");
        self.stdout
    }

    pub(crate) fn json(self) -> Value {
        serde_json::from_str(&self.ok()).unwrap_or_else(|error| panic!("{error}"))
    }

    pub(crate) fn http_error(self, status: u16) -> String {
        assert_eq!(self.exit, Exit::Exited(1), "{self:?}");
        assert_eq!(self.stderr, format!("ko api: HTTP {status}\n"), "{self:?}");
        self.stdout
    }

    pub(crate) fn error(self, code: i32) -> String {
        assert_eq!(self.exit, Exit::Exited(code), "{self:?}");
        assert_eq!(self.stdout, "", "{self:?}");
        self.stderr
    }
}

pub(crate) fn ko_command(
    s: &Server,
    pane: Option<&str>,
    args: &[&str],
) -> (Vec<Vec<u8>>, Vec<String>) {
    let mut env = test_env(&s.dir);
    if let Some(pane) = pane {
        env.push(format!("KO_PANE={pane}").into_bytes());
        env.push(format!("KO_SOCKET={}", s.dir.join("socket").display()).into_bytes());
        if let Some(token) = s.token(pane) {
            env.push(format!("KO_PANE_TOKEN={token}").into_bytes());
        }
    }
    let mut argv = args.to_vec();
    argv.extend(["--server", text_of(&s.dir)]);
    (env, argv.into_iter().map(str::to_owned).collect())
}

pub(crate) fn code(run: &Run) -> i32 {
    match run.exit {
        Exit::Exited(code) => code,
        Exit::Signaled(signal) => panic!("killed by signal {signal}: {run:?}"),
    }
}

pub(crate) fn run_ko(scratch: &Path, env: &[Vec<u8>], args: &[&str], stdin: &str) -> Run {
    run_program(scratch, &ko(), env, args, stdin, DEADLINE)
}

pub(crate) fn run_program(
    scratch: &Path,
    program: &Path,
    env: &[Vec<u8>],
    args: &[&str],
    stdin: &str,
    deadline: Duration,
) -> Run {
    static COUNTER: AtomicU32 = AtomicU32::new(0);
    let id = COUNTER.fetch_add(1, Ordering::Relaxed);
    let file = |name: &str| scratch.join(format!("run-{id}-{name}"));
    let input = file("stdin");
    std::fs::write(&input, stdin).unwrap();
    let (stdin, stdout, stderr) = (
        File::open(&input).unwrap(),
        File::create(file("stdout")).unwrap(),
        File::create(file("stderr")).unwrap(),
    );
    let mut child = Child::spawn(
        program,
        args,
        env,
        &[(stdin.as_fd(), 0), (stdout.as_fd(), 1), (stderr.as_fd(), 2)],
    );
    let started = Instant::now();
    let exit = child.wait(deadline).unwrap_or_else(|| {
        panic!(
            "{} {args:?} did not exit after {:?}; stdout: {:?}; stderr: {:?}",
            program.display(),
            started.elapsed(),
            std::fs::read_to_string(file("stdout")).unwrap_or_default(),
            std::fs::read_to_string(file("stderr")).unwrap_or_default(),
        )
    });
    Run {
        stdout: std::fs::read_to_string(file("stdout")).unwrap(),
        stderr: std::fs::read_to_string(file("stderr")).unwrap(),
        exit,
    }
}

pub(crate) use ko_pane_wire::base64::encode as base64;

pub(crate) fn sh(command: &str) -> Value {
    json!({"command": {"type": "argv", "argv": ["/bin/sh", "-c", command]}, "cwd": "/tmp"})
}

pub(crate) fn history_lines(count: u32) -> String {
    format!("i=0; while [ $i -lt {count} ]; do printf 'history-%s\\r\\n' $i; i=$((i+1)); done")
}

pub(crate) fn size(cols: u16, rows: u16) -> Value {
    json!({"cols": cols, "rows": rows, "cell_px": {"width": 8, "height": 16}})
}

#[derive(Debug)]
pub(crate) struct Hello {
    pub(crate) selection: Value,
    pub(crate) focused: bool,
    pub(crate) size: Value,
}

pub(crate) fn tagged(text: &str) -> Option<(String, Value)> {
    let message: Value = serde_json::from_str(text).ok()?;
    Some((message.get("type")?.as_str()?.to_owned(), message))
}

pub(crate) const PROTOCOL: &str = "1.0";

pub(crate) fn size_request(size: Value) -> Value {
    let mut request = size;
    request["type"] = json!("size");
    request
}

#[derive(Debug)]
pub(crate) enum Message {
    Text(String),
    Binary(Vec<u8>),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum End {
    Timeout,
    Closed,
}

#[derive(Debug)]
pub(crate) enum Record<'a> {
    Output {
        offset: u64,
        data: &'a [u8],
    },
    Snapshot {
        offset: u64,
        first: bool,
        last: bool,
        extent: Extent,
        data: Vec<u8>,
    },
}

impl Record<'_> {
    pub(crate) fn parse(bytes: &[u8]) -> Option<Record<'_>> {
        let offset = u64::from_le_bytes(bytes.get(1..9)?.try_into().ok()?);
        match bytes[0] {
            1 => Some(Record::Output {
                offset,
                data: &bytes[9..],
            }),
            2 => {
                let (slice, packed) = Slice::decode(&bytes[9..])?;
                Some(Record::Snapshot {
                    offset,
                    first: slice.first,
                    last: slice.last,
                    extent: if slice.screen {
                        Extent::Screen
                    } else {
                        Extent::Full
                    },
                    data: miniz_oxide::inflate::decompress_to_vec_with_limit(packed, SLICE_MAX)
                        .ok()?,
                })
            }
            _ => None,
        }
    }
}

#[derive(Debug)]
pub(crate) struct Ws {
    socket: WebSocket<Steady>,
    deadline: Instant,
    began: Instant,
    received: usize,
    bytes: usize,
    last: String,
    close: Option<(u16, String)>,
}

impl Ws {
    pub(crate) fn within(&mut self, limit: Duration) {
        self.began = Instant::now();
        self.deadline = self.began + limit;
    }

    pub(crate) fn next(&mut self) -> Result<Message, End> {
        loop {
            let left = self
                .deadline
                .checked_duration_since(Instant::now())
                .filter(|left| !left.is_zero())
                .ok_or(End::Timeout)?;
            // macOS refuses the option (EINVAL) on a socket whose peer has shut down. Such a read
            // never waits: it returns the unread data or the end.
            if let Err(error) = self.socket.get_ref().set_read_timeout(Some(left))
                && error.kind() != std::io::ErrorKind::InvalidInput
            {
                return Err(End::Closed);
            }
            match self.socket.read() {
                Ok(Msg::Text(text)) => {
                    self.received += 1;
                    self.bytes += text.len();
                    self.last = format!("text {:.120}", text.as_str());
                    return Ok(Message::Text(text.to_string()));
                }
                Ok(Msg::Binary(bytes)) => {
                    self.received += 1;
                    self.bytes += bytes.len();
                    self.last = format!("binary kind {:?}, {} bytes", bytes.first(), bytes.len());
                    return Ok(Message::Binary(bytes.to_vec()));
                }
                Ok(Msg::Close(frame)) => {
                    self.close =
                        frame.map(|frame| (u16::from(frame.code), frame.reason.to_string()));
                    return Err(End::Closed);
                }
                Ok(_) => {}
                Err(tungstenite::Error::Io(error))
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) =>
                {
                    return Err(End::Timeout);
                }
                Err(error) => {
                    self.last = format!("error {error}");
                    return Err(End::Closed);
                }
            }
        }
    }

    pub(crate) fn read(&mut self) -> Message {
        match self.next() {
            Ok(message) => message,
            Err(end) => panic!(
                "read: {end:?} after {:?}; {} messages, the last: {}",
                self.began.elapsed(),
                self.received,
                self.last
            ),
        }
    }

    pub(crate) fn send(&mut self, value: &Value) {
        self.socket
            .send(Msg::text(value.to_string()))
            .unwrap_or_else(|error| panic!("send {value}: {error}"));
    }

    pub(crate) fn bytes(&self) -> usize {
        self.bytes
    }

    pub(crate) fn last(&self) -> &str {
        &self.last
    }

    pub(crate) fn close_frame(&self) -> Option<&(u16, String)> {
        self.close.as_ref()
    }

    pub(crate) fn raw(&mut self) -> &mut Steady {
        self.socket.get_mut()
    }

    pub(crate) fn event(&mut self, key: &str) -> Value {
        self.within(DEADLINE);
        for _ in 0..10000 {
            if let Message::Text(text) = self.read()
                && let Some((tag, payload)) = tagged(&text)
                && tag == key
            {
                return payload;
            }
        }
        panic!("no {key}");
    }

    pub(crate) fn closed(&mut self, what: &str) {
        self.within(DEADLINE);
        loop {
            match self.next() {
                Err(End::Timeout) => panic!("{what}"),
                Err(End::Closed) => return,
                Ok(_) => {}
            }
        }
    }

    pub(crate) fn welcome(&mut self) -> Value {
        let mut identity = Value::Null;
        for key in ["welcome", "layout"] {
            let Message::Text(text) = self.read() else {
                panic!("expected {key}, got a binary message");
            };
            let Some((tag, payload)) = tagged(&text) else {
                panic!("expected {key}, got {text}");
            };
            assert_eq!(tag, key, "expected {key}, got {text}");
            if key == "welcome" {
                identity = payload;
            }
        }
        identity
    }

    pub(crate) fn snapshot(&mut self) -> (Vec<u8>, u64) {
        self.within(DEADLINE);
        let mut result = Vec::new();
        for _ in 0..10000 {
            let Message::Binary(bytes) = self.read() else {
                continue;
            };
            let Some(Record::Snapshot {
                offset,
                first,
                last,
                data,
                ..
            }) = Record::parse(&bytes)
            else {
                continue;
            };
            if first {
                result.clear();
            }
            result.extend_from_slice(&data);
            if last {
                return (result, offset);
            }
        }
        panic!("snapshot never completed");
    }

    pub(crate) fn output(&mut self, needle: &str) -> u64 {
        self.within(DEADLINE);
        let mut text = Vec::new();
        for _ in 0..10000 {
            let Message::Binary(bytes) = self.read() else {
                continue;
            };
            if let Some(Record::Output { offset, data }) = Record::parse(&bytes) {
                text.extend_from_slice(data);
                if contains(&text, needle.as_bytes()) {
                    return offset + data.len() as u64;
                }
            }
        }
        panic!("no output {needle:?}");
    }

    pub(crate) fn type_text(&mut self, text: &str) {
        self.send(
            &json!({"type": "input", "input": {"type": "text", "data": base64(text.as_bytes())}}),
        );
    }

    pub(crate) fn ready(&mut self, needle: &str) {
        let (data, _) = self.snapshot();
        if !decode(&data, false).screen.contains(needle) {
            self.output(needle);
        }
    }
}

#[derive(Debug)]
pub(crate) struct Decoded {
    pub(crate) sync: bool,
    pub(crate) rows: usize,
    pub(crate) screen: String,
    pub(crate) history: String,
}

pub(crate) fn decode(data: &[u8], full: bool) -> Decoded {
    let extent = if full { Extent::Full } else { Extent::Screen };
    let terminal = Terminal::decode(&mut &data[..], extent).unwrap();
    let history = if full {
        terminal.dump_history(Format::Plain).unwrap()
    } else {
        Vec::new()
    };
    Decoded {
        sync: terminal.mode(2026).unwrap(),
        rows: terminal.total_rows().unwrap(),
        screen: String::from_utf8_lossy(&terminal.dump(Format::Plain).unwrap()).into_owned(),
        history: String::from_utf8_lossy(&history).into_owned(),
    }
}

#[derive(Debug)]
pub(crate) struct Head {
    pub(crate) status: u16,
    pub(crate) headers: Vec<(String, String)>,
    pub(crate) framing: Framing,
    pub(crate) size: usize,
}

impl Head {
    pub(crate) fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(found, _)| found.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_str())
    }
}

#[derive(Debug, Clone, Copy)]
pub(crate) enum Framing {
    Length(usize),
    Chunked,
    Close,
}

fn dechunk(mut data: &[u8]) -> Option<Vec<u8>> {
    let mut body = Vec::new();
    loop {
        let httparse::Status::Complete((used, size)) = httparse::parse_chunk_size(data).ok()?
        else {
            return None;
        };
        let size = usize::try_from(size).ok()?;
        data = &data[used..];
        if size == 0 {
            return Some(body);
        }
        if data.len() < size + 2 {
            return None;
        }
        body.extend_from_slice(&data[..size]);
        data = &data[size + 2..];
    }
}

type Headers = Vec<(String, String)>;

#[derive(Debug)]
pub(crate) struct Server {
    pub(crate) dir: Dir,
    pub(crate) scratch: Dir,
    pub(crate) child: Child,
    pub(crate) vt: Option<String>,
    log: PathBuf,
    stopped: bool,
}

pub(crate) fn which(name: &str) -> Option<PathBuf> {
    std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default())
        .map(|dir| dir.join(name))
        .find(|path| path.is_file())
}

pub(crate) fn start(args: &[&str]) -> Server {
    start_with(Path::new("/bin/sh"), &[], args)
}

fn spawn_server(
    dir: &Path,
    log: &Path,
    shell: &Path,
    env: &[(&str, &str)],
    args: &[&str],
) -> Child {
    let (null, output) = (File::open("/dev/null").unwrap(), File::create(log).unwrap());
    let mut argv = vec!["server", "--server", text_of(dir)];
    argv.extend_from_slice(args);
    let mut server_env = test_env(dir);
    let shell = text_of(shell);
    for (name, value) in [("SHELL", shell)].iter().chain(env) {
        server_env.retain(|entry| !entry.starts_with(format!("{name}=").as_bytes()));
        server_env.push(format!("{name}={value}").into_bytes());
    }
    Child::spawn(
        &ko(),
        &argv,
        &server_env,
        &[(null.as_fd(), 0), (output.as_fd(), 1), (output.as_fd(), 2)],
    )
}

pub(crate) fn start_with(shell: &Path, env: &[(&str, &str)], args: &[&str]) -> Server {
    start_in(Dir::new("ko-"), shell, env, args)
}

pub(crate) fn config_path(dir: &Path) -> PathBuf {
    dir.join("ko/config.yaml")
}

pub(crate) fn write_config(dir: &Path, text: &str) {
    let file = config_path(dir);
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    std::fs::write(file, text).unwrap();
}

pub(crate) fn start_serving(settings: &str) -> Server {
    let dir = Dir::new("ko-");
    write_config(&dir, &format!("server:\n{settings}"));
    start_in(dir, Path::new("/bin/sh"), &[], &[])
}

pub(crate) fn start_in(dir: Dir, shell: &Path, env: &[(&str, &str)], args: &[&str]) -> Server {
    std::fs::write(dir.join(".zshrc"), "").unwrap();
    let log = PathBuf::from(format!("{}.log", dir.display()));
    let child = spawn_server(&dir, &log, shell, env, args);
    let mut server = Server {
        dir,
        scratch: Dir::new("ko-run-"),
        child,
        vt: None,
        log,
        stopped: false,
    };
    server.wait_listening();
    let version: Value =
        serde_json::from_str(&server.request("GET", "/version", None, 200)).unwrap();
    server.vt = version["vt"].as_str().map(str::to_owned);
    server
}

pub(crate) fn enabled(variable: &str) -> bool {
    if std::env::var(variable).as_deref() == Ok("1") {
        true
    } else {
        eprintln!("skipped: {variable} is not 1");
        false
    }
}

impl Server {
    fn wait_listening(&mut self) {
        poll("the server socket", || {
            assert!(
                self.child.wait(Duration::ZERO).is_none(),
                "server exited: {}",
                self.log()
            );
            self.dial().is_ok()
        });
    }

    pub(crate) fn stop(&mut self) {
        self.child.signal(Signal::Term).unwrap();
        assert_eq!(
            self.child.wait(Duration::from_secs(3)),
            Some(Exit::Exited(0))
        );
    }

    pub(crate) fn restart(&mut self, env: &[(&str, &str)]) {
        self.stop();
        self.start_again(env);
    }

    pub(crate) fn start_again(&mut self, env: &[(&str, &str)]) {
        assert!(
            self.child.wait(Duration::from_secs(3)).is_some(),
            "the old server is still running"
        );
        self.child = spawn_server(&self.dir, &self.log, Path::new("/bin/sh"), env, &[]);
        self.wait_listening();
    }

    pub(crate) fn log(&self) -> String {
        std::fs::read_to_string(&self.log).unwrap_or_default()
    }

    pub(crate) fn dial(&self) -> std::io::Result<Steady> {
        UnixStream::connect(self.dir.join("socket")).map(Steady)
    }

    pub(crate) fn headers(&self) -> Headers {
        let mut headers = vec![("Ko-Protocol".to_owned(), PROTOCOL.to_owned())];
        if let Some(vt) = &self.vt {
            headers.push(("Ko-Vt".to_owned(), vt.clone()));
        }
        headers
    }

    pub(crate) fn headers_with(&self, extra: &[(&str, &str)]) -> Headers {
        let mut headers = self.headers();
        headers.extend(
            extra
                .iter()
                .map(|(name, value)| ((*name).to_owned(), (*value).to_owned())),
        );
        headers
    }

    pub(crate) fn as_pane(&self, pane: &str) -> Headers {
        let token = self.token(pane).expect("the pane printed its token");
        self.headers_with(&[("Ko-Pane", pane), ("Ko-Pane-Token", &token)])
    }

    pub(crate) fn client_headers(&self, client: &str) -> Headers {
        let mut headers = self.headers();
        headers.push(("Ko-Client".to_owned(), client.to_owned()));
        headers
    }

    pub(crate) fn write_request(
        &self,
        stream: &mut Steady,
        method: &str,
        path: &str,
        headers: &Headers,
        body: &[u8],
    ) {
        let mut head = format!("{method} {path} HTTP/1.1\r\nHost: ko\r\n");
        for (name, value) in headers {
            head.push_str(&format!("{name}: {value}\r\n"));
        }
        head.push_str(&format!("Content-Length: {}\r\n\r\n", body.len()));
        stream.write_all(head.as_bytes()).unwrap();
        stream.write_all(body).unwrap();
    }

    // Reads up to the end of a response head. The bytes of the body that came with it stay in
    // `buffer` after the head's length.
    pub(crate) fn read_head(&self, stream: &mut Steady, buffer: &mut Vec<u8>) -> Head {
        loop {
            let mut chunk = [0u8; 65536];
            let count = stream
                .read(&mut chunk)
                .unwrap_or_else(|error| panic!("{error} ({})", self.log()));
            assert!(count > 0, "closed ({})", self.log());
            buffer.extend_from_slice(&chunk[..count]);
            let mut slots = [httparse::EMPTY_HEADER; 64];
            let mut response = httparse::Response::new(&mut slots);
            if let httparse::Status::Complete(size) = response.parse(buffer).unwrap() {
                let headers: Vec<(String, String)> = response
                    .headers
                    .iter()
                    .map(|header| {
                        (
                            header.name.to_owned(),
                            String::from_utf8_lossy(header.value).into_owned(),
                        )
                    })
                    .collect();
                let header = |name: &str| {
                    headers
                        .iter()
                        .find(|(found, _)| found.eq_ignore_ascii_case(name))
                        .map(|(_, value)| value.clone())
                };
                let framing = match (header("content-length"), header("transfer-encoding")) {
                    (_, Some(coding)) if coding.eq_ignore_ascii_case("chunked") => Framing::Chunked,
                    (Some(length), _) => Framing::Length(length.parse().unwrap()),
                    _ => Framing::Close,
                };
                return Head {
                    status: response.code.unwrap(),
                    headers,
                    framing,
                    size,
                };
            }
        }
    }

    pub(crate) fn exchange(
        &self,
        method: &str,
        path: &str,
        headers: &Headers,
        body: &[u8],
    ) -> (u16, Vec<u8>) {
        self.exchange_on(&self.dir.join("socket"), method, path, headers, body)
    }

    pub(crate) fn exchange_on(
        &self,
        socket: &Path,
        method: &str,
        path: &str,
        headers: &Headers,
        body: &[u8],
    ) -> (u16, Vec<u8>) {
        self.read_reply(self.send_request_on(socket, method, path, headers, body))
    }

    // The send half of `exchange`: the reply stays unread, so a test can act while the server
    // holds the request, or drop the stream.
    pub(crate) fn send_request(
        &self,
        method: &str,
        path: &str,
        headers: &Headers,
        body: &[u8],
    ) -> Steady {
        self.send_request_on(&self.dir.join("socket"), method, path, headers, body)
    }

    fn send_request_on(
        &self,
        socket: &Path,
        method: &str,
        path: &str,
        headers: &Headers,
        body: &[u8],
    ) -> Steady {
        let mut stream = UnixStream::connect(socket).map(Steady).unwrap();
        within(&stream, Instant::now() + DEADLINE);
        self.write_request(&mut stream, method, path, headers, body);
        stream
    }

    pub(crate) fn read_reply(&self, mut stream: Steady) -> (u16, Vec<u8>) {
        let deadline = Instant::now() + DEADLINE;
        within(&stream, deadline);
        let mut buffer = Vec::new();
        let Head {
            status,
            framing,
            size: head_len,
            ..
        } = self.read_head(&mut stream, &mut buffer);
        let mut body = buffer.split_off(head_len);
        loop {
            let done = match framing {
                Framing::Length(length) => {
                    body.truncate(length);
                    body.len() == length
                }
                Framing::Chunked => match dechunk(&body) {
                    Some(decoded) => {
                        body = decoded;
                        true
                    }
                    None => false,
                },
                Framing::Close => false,
            };
            if done {
                break;
            }
            let mut chunk = [0u8; 65536];
            read_within(&stream, deadline);
            let count = stream.read(&mut chunk).unwrap();
            if count == 0 {
                assert!(matches!(framing, Framing::Close), "reply: body cut short");
                break;
            }
            body.extend_from_slice(&chunk[..count]);
        }
        (status, body)
    }

    pub(crate) fn request(
        &self,
        method: &str,
        path: &str,
        body: Option<&Value>,
        status: u16,
    ) -> String {
        let body = body.map(Value::to_string).unwrap_or_default();
        let (code, data) = self.exchange(method, path, &self.headers(), body.as_bytes());
        let data = String::from_utf8_lossy(&data).into_owned();
        assert_eq!(
            code,
            status,
            "{method} {path}: {code} {data} ({})",
            self.log()
        );
        data
    }

    pub(crate) fn ko(&self, args: &[&str], stdin: &str) -> Run {
        self.ko_as(None, args, stdin)
    }

    pub(crate) fn ko_as(&self, pane: Option<&str>, args: &[&str], stdin: &str) -> Run {
        let (env, argv) = ko_command(self, pane, args);
        let argv: Vec<&str> = argv.iter().map(String::as_str).collect();
        run_ko(&self.scratch, &env, &argv, stdin)
    }

    pub(crate) fn has_pane(&self, pane: &str) -> bool {
        self.rows().iter().any(|row| row["id"] == pane)
    }

    pub(crate) fn dial_ws(&self, path: &str, headers: Option<Headers>, status: u16) -> Option<Ws> {
        self.dial_ws_on(&self.dir.join("socket"), path, headers, status)
    }

    pub(crate) fn dial_ws_on(
        &self,
        socket: &Path,
        path: &str,
        headers: Option<Headers>,
        status: u16,
    ) -> Option<Ws> {
        let headers = headers.unwrap_or_else(|| self.headers());
        let mut request =
            tungstenite::client::IntoClientRequest::into_client_request(format!("ws://ko{path}"))
                .unwrap();
        for (name, value) in &headers {
            request.headers_mut().insert(
                HeaderName::from_bytes(name.as_bytes()).unwrap(),
                HeaderValue::from_str(value).unwrap(),
            );
        }
        let stream = UnixStream::connect(socket).map(Steady).unwrap();
        stream.set_read_timeout(Some(DEADLINE)).unwrap();
        stream.set_write_timeout(Some(DEADLINE)).unwrap();
        let shaken = tungstenite::client::client(request, stream);
        if status != 101 {
            match shaken {
                Err(tungstenite::HandshakeError::Failure(tungstenite::Error::Http(response))) => {
                    assert_eq!(response.status().as_u16(), status, "upgrade {path}");
                }
                other => panic!(
                    "upgrade {path}: expected {status}, got {:?}",
                    other.map(|_| ())
                ),
            }
            return None;
        }
        match shaken {
            Ok((socket, _)) => Some(Ws {
                socket,
                deadline: Instant::now() + DEADLINE,
                began: Instant::now(),
                received: 0,
                bytes: 0,
                last: String::new(),
                close: None,
            }),
            Err(error) => panic!("upgrade {path}: {error} ({})", self.log()),
        }
    }

    pub(crate) fn ws(&self, path: &str) -> Ws {
        self.dial_ws(path, None, 101).unwrap()
    }

    pub(crate) fn hello(&self, hello: Hello) -> Ws {
        let mut ws = self.ws("/client");
        let mut body = json!({
            "type": "hello",
            "name": "test",
            "focused": hello.focused,
            "size": hello.size,
        });
        if let Value::Object(fields) = hello.selection {
            for (name, value) in fields {
                body[name] = value;
            }
        }
        ws.send(&body);
        ws
    }

    pub(crate) fn client(&self, pane: Option<&str>) -> (Ws, Value) {
        let selection = pane.map_or(json!({}), |pane| json!({"pane": pane}));
        self.joined(Hello {
            selection,
            focused: true,
            size: size(80, 24),
        })
    }

    pub(crate) fn app_client(
        &self,
        selection: Value,
        focused: bool,
        (cols, rows): (u16, u16),
    ) -> (Ws, Value) {
        self.joined(Hello {
            selection,
            focused,
            size: size(cols, rows),
        })
    }

    fn joined(&self, hello: Hello) -> (Ws, Value) {
        let mut ws = self.hello(hello);
        let welcome = ws.welcome();
        (ws, welcome)
    }

    pub(crate) fn pane(&self, command: &str) -> String {
        self.new_pane(sh(command))
    }

    pub(crate) fn new_pane(&self, new: Value) -> String {
        let window = json!({"name": "test", "tree": {"pane": {"new": new}}});
        let put = self.edit(|layout| {
            let sessions = layout["sessions"].as_array_mut().expect("sessions");
            match sessions.first_mut() {
                Some(first) => first["windows"]
                    .as_array_mut()
                    .expect("a list of windows")
                    .push(window),
                None => sessions.push(json!({"name": "test", "windows": [window]})),
            }
        });
        let windows = put["layout"]["sessions"][0]["windows"]
            .as_array()
            .expect("windows");
        windows[windows.len() - 1]["tree"]["pane"]
            .as_str()
            .unwrap_or_default()
            .to_owned()
    }

    pub(crate) fn shell_pane(&self) -> String {
        self.new_pane(json!({"cwd": "/tmp"}))
    }

    pub(crate) fn echo_pane(&self) -> String {
        let pane = self.pane("stty raw -echo; printf READY; exec cat");
        self.screen_has(&pane, "READY");
        pane
    }

    pub(crate) fn screen(&self, pane: &str) -> String {
        self.ko(&["api", &format!("/panes/{pane}/screen")], "").ok()
    }

    // A pane whose program printed its token with PRINT_TOKEN before it ran `command`.
    pub(crate) fn token_pane(&self, command: &str) -> String {
        self.token_pane_with(json!({}), command)
    }

    pub(crate) fn token_pane_with(&self, extra: Value, command: &str) -> String {
        let mut new = sh(&format!("stty raw -echo; {PRINT_TOKEN}; {command}"));
        if let (Value::Object(fields), Value::Object(extra)) = (&mut new, extra) {
            fields.extend(extra);
        }
        let pane = self.new_pane(new);
        self.screen_has(&pane, "TOKEN<");
        pane
    }

    pub(crate) fn token(&self, pane: &str) -> Option<String> {
        let screen = self.screen(pane);
        let (_, rest) = screen.split_once("TOKEN<")?;
        Some(rest.split_once('>')?.0.to_owned())
    }

    pub(crate) fn screen_has(&self, pane: &str, needle: &str) {
        poll(&format!("{needle} on the screen of {pane}"), || {
            self.screen(pane).contains(needle)
        });
    }

    pub(crate) fn rows(&self) -> Vec<Value> {
        match serde_json::from_str(&self.request("GET", "/panes", None, 200)) {
            Ok(Value::Array(rows)) => rows,
            other => panic!("/panes is not a list: {other:?}"),
        }
    }

    pub(crate) fn row(&self, pane: &str) -> Value {
        self.rows()
            .into_iter()
            .find(|row| row["id"] == pane)
            .unwrap_or_else(|| panic!("no row for {pane}"))
    }

    pub(crate) fn wait_row(
        &self,
        pane: &str,
        what: &str,
        mut check: impl FnMut(&Value) -> bool,
    ) -> Value {
        let mut last = Value::Null;
        poll(what, || {
            last = self.row(pane);
            check(&last)
        });
        last
    }

    pub(crate) fn doc(&self) -> Value {
        self.ko(&["layout"], "").json()
    }

    pub(crate) fn put(&self, document: &Value) -> Value {
        self.ko(&["layout", "put", "-"], &document.to_string())
            .json()
    }

    pub(crate) fn edit(&self, change: impl FnOnce(&mut Value)) -> Value {
        let mut document = self.doc();
        change(&mut document["layout"]);
        self.put(&document)
    }

    pub(crate) fn delete(&self, path: &str) -> Run {
        self.ko(&["api", "-X", "DELETE", path], "")
    }

    pub(crate) fn sttys(&self, panes: &[&str]) -> Vec<(u32, u32)> {
        static TAG: AtomicU32 = AtomicU32::new(0);
        let files: Vec<PathBuf> = panes
            .iter()
            .map(|pane| {
                let file = self
                    .scratch
                    .join(format!("stty-{}", TAG.fetch_add(1, Ordering::Relaxed)));
                self.text(pane, &format!("stty size > {}\n", quote(text_of(&file))));
                file
            })
            .collect();
        let mut sizes = vec![None; files.len()];
        poll("stty size in every pane", || {
            for (size, file) in sizes.iter_mut().zip(&files) {
                if size.is_none() {
                    *size = std::fs::read_to_string(file).ok().and_then(|text| {
                        let (rows, cols) = text.trim_end().split_once(' ')?;
                        Some((rows.parse().ok()?, cols.parse().ok()?))
                    });
                }
            }
            sizes.iter().all(Option::is_some)
        });
        sizes.into_iter().flatten().collect()
    }

    pub(crate) fn stty(&self, pane: &str) -> (u32, u32) {
        self.sttys(&[pane])[0]
    }

    pub(crate) fn set_var(&self, pane: &str, name: &str, value: &Value) {
        self.request(
            "PUT",
            &format!("/panes/{pane}/vars/{name}"),
            Some(value),
            200,
        );
    }

    pub(crate) fn text(&self, pane: &str, text: &str) {
        let body = json!({"type": "text", "data": base64(text.as_bytes())});
        self.ko(
            &["api", "--input", "-", &format!("/panes/{pane}/input")],
            &body.to_string(),
        )
        .ok();
    }

    pub(crate) fn pane_pids(&self) -> Vec<(String, Option<Pid>)> {
        self.rows()
            .iter()
            .map(|row| {
                (
                    row["id"].as_str().unwrap_or_default().to_owned(),
                    row["pid"].as_i64().and_then(Pid::new),
                )
            })
            .collect()
    }

    pub(crate) fn pane_program(&self, pane: &str) -> Pid {
        let row = self.wait_row(pane, &format!("the program of {pane}"), |row| {
            row["pid"].as_i64().is_some()
        });
        Pid::new(row["pid"].as_i64().unwrap()).unwrap()
    }

    pub(crate) fn program_pid(&self) -> Pid {
        let panes = self.pane_pids();
        let [(_, Some(pid))] = panes[..] else {
            panic!("program pid: {panes:?}");
        };
        pid
    }

    fn shutdown(&mut self) -> Result<(), String> {
        if std::mem::replace(&mut self.stopped, true) {
            return Ok(());
        }
        let _ = self.child.signal(Signal::Term);
        match self.child.wait(Duration::from_secs(3)) {
            Some(Exit::Exited(0)) => Ok(()),
            Some(exit) => Err(format!("server: {exit:?}: {}", self.log())),
            None => {
                let _ = self.child.signal(Signal::Kill);
                Err(format!("shutdown timed out: {}", self.log()))
            }
        }
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        let stopped = self.shutdown();
        if thread::panicking() {
            eprintln!("server log: {}", self.log());
        } else if let Err(message) = stopped {
            let _ = std::fs::remove_file(&self.log);
            panic!("{message}");
        }
        let _ = std::fs::remove_file(&self.log);
    }
}

pub(crate) fn wait_gone(pid: Pid, what: &str) {
    poll(&format!("program {pid} to be gone after {what}"), || {
        pid.has_ended()
    });
}
