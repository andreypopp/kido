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

use ko_sys::pid::{Exit, Pid};
use ko_sys::signal::Signal;
use ko_sys::spawn::{self, Env};
use ko_vt::{Extent, Format, Terminal};
use serde_json::{Value, json};
use tungstenite::http::{HeaderName, HeaderValue};
use tungstenite::{Message as Msg, WebSocket};

pub(crate) const DEADLINE: Duration = Duration::from_secs(5);

pub(crate) fn ko() -> PathBuf {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../build/ko/bin/ko");
    assert!(
        path.exists(),
        "{} is missing: run make build-ko first",
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

// A poll tick for a condition that has no descriptor to wait on: the Go suite's ticker.
fn time_left(deadline: Instant) -> Duration {
    deadline
        .checked_duration_since(Instant::now())
        .filter(|left| !left.is_zero())
        .expect("the deadline passed")
}

fn read_within(stream: &UnixStream, deadline: Instant) {
    stream.set_read_timeout(Some(time_left(deadline))).unwrap();
}

pub(crate) fn within(stream: &UnixStream, deadline: Instant) {
    read_within(stream, deadline);
    stream.set_write_timeout(Some(time_left(deadline))).unwrap();
}

pub(crate) fn poll(what: &str, mut check: impl FnMut() -> bool) {
    let deadline = Instant::now() + DEADLINE;
    while !check() {
        assert!(Instant::now() < deadline, "wait for {what}");
        thread::park_timeout(Duration::from_millis(10));
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
            let scrubbed = ["XDG_", "KO_", "KIDO_", "TMUX", "BASH_FUNC_"]
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
        let pid = spawn::program(program, args, targets, Env::Only(env)).unwrap();
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
    pub(crate) code: i32,
}

pub(crate) fn run_ko(scratch: &Path, env: &[Vec<u8>], args: &[&str], stdin: &str) -> Run {
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
        &ko(),
        args,
        env,
        &[(stdin.as_fd(), 0), (stdout.as_fd(), 1), (stderr.as_fd(), 2)],
    );
    let exit = child
        .wait(DEADLINE)
        .unwrap_or_else(|| panic!("ko {args:?} did not exit"));
    Run {
        stdout: std::fs::read_to_string(file("stdout")).unwrap(),
        stderr: std::fs::read_to_string(file("stderr")).unwrap(),
        code: match exit {
            Exit::Exited(code) => code,
            Exit::Signaled(_) => -1,
        },
    }
}

fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let word = chunk.iter().enumerate().fold(0u32, |word, (at, byte)| {
            word | u32::from(*byte) << (16 - 8 * at)
        });
        for at in 0..4 {
            if at <= chunk.len() {
                out.push(char::from(ALPHABET[(word >> (18 - 6 * at) & 63) as usize]));
            } else {
                out.push('=');
            }
        }
    }
    out
}

pub(crate) fn history_lines(count: u32) -> String {
    format!("i=0; while [ $i -lt {count} ]; do printf 'history-%s\\r\\n' $i; i=$((i+1)); done")
}

pub(crate) fn size(cols: u16, rows: u16) -> Value {
    json!({"cols": cols, "rows": rows, "cell_px": {"width": 8, "height": 16}})
}

pub(crate) fn tagged(text: &str) -> Option<(String, Value)> {
    let Value::Array(mut parts) = serde_json::from_str(text).ok()? else {
        return None;
    };
    if parts.len() != 2 {
        return None;
    }
    let payload = parts.pop()?;
    Some((parts.pop()?.as_str()?.to_owned(), payload))
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
pub(crate) struct Ws {
    socket: WebSocket<UnixStream>,
    deadline: Instant,
}

impl Ws {
    pub(crate) fn within(&mut self, limit: Duration) {
        self.deadline = Instant::now() + limit;
    }

    pub(crate) fn next(&mut self) -> Result<Message, End> {
        loop {
            let left = self
                .deadline
                .checked_duration_since(Instant::now())
                .filter(|left| !left.is_zero())
                .ok_or(End::Timeout)?;
            self.socket
                .get_ref()
                .set_read_timeout(Some(left))
                .map_err(|_| End::Closed)?;
            match self.socket.read() {
                Ok(Msg::Text(text)) => return Ok(Message::Text(text.to_string())),
                Ok(Msg::Binary(bytes)) => return Ok(Message::Binary(bytes.to_vec())),
                Ok(Msg::Close(_)) => return Err(End::Closed),
                Ok(_) => {}
                Err(tungstenite::Error::Io(error))
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) =>
                {
                    return Err(End::Timeout);
                }
                Err(_) => return Err(End::Closed),
            }
        }
    }

    pub(crate) fn read(&mut self) -> Message {
        match self.next() {
            Ok(message) => message,
            Err(end) => panic!("read: {end:?}"),
        }
    }

    pub(crate) fn send(&mut self, value: &Value) {
        self.socket
            .send(Msg::text(value.to_string()))
            .unwrap_or_else(|error| panic!("send {value}: {error}"));
    }

    pub(crate) fn raw(&mut self) -> &mut UnixStream {
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

    pub(crate) fn snapshot(&mut self) -> (Vec<u8>, u64) {
        self.within(DEADLINE);
        let mut result = Vec::new();
        for _ in 0..10000 {
            let Message::Binary(bytes) = self.read() else {
                continue;
            };
            if bytes.len() < 11 || bytes[0] != 2 {
                continue;
            }
            let offset = u64::from_le_bytes(bytes[1..9].try_into().unwrap());
            if bytes[9] & 1 != 0 {
                result.clear();
            }
            result.extend_from_slice(&bytes[11..]);
            if bytes[9] & 2 != 0 {
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
            if bytes.len() >= 9 && bytes[0] == 1 {
                text.extend_from_slice(&bytes[9..]);
                if contains(&text, needle.as_bytes()) {
                    return u64::from_le_bytes(bytes[1..9].try_into().unwrap())
                        + (bytes.len() - 9) as u64;
                }
            }
        }
        panic!("no output {needle:?}");
    }

    pub(crate) fn type_text(&mut self, text: &str) {
        self.send(&json!(["input", ["text", base64(text.as_bytes())]]));
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

#[derive(Debug, Clone, Copy)]
enum Framing {
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
    pub(crate) vt: String,
    pub(crate) limits: Value,
    log: PathBuf,
    stopped: bool,
}

pub(crate) fn start(args: &[&str]) -> Server {
    let dir = Dir::new("ko-");
    let log = PathBuf::from(format!("{}.log", dir.display()));
    let (null, output) = (
        File::open("/dev/null").unwrap(),
        File::create(&log).unwrap(),
    );
    let mut argv = vec!["server", "--server", text_of(&dir), "--shell", "/bin/sh"];
    argv.extend_from_slice(args);
    let child = Child::spawn(
        &ko(),
        &argv,
        &test_env(&dir),
        &[(null.as_fd(), 0), (output.as_fd(), 1), (output.as_fd(), 2)],
    );
    let mut server = Server {
        dir,
        scratch: Dir::new("ko-run-"),
        child,
        vt: String::new(),
        limits: Value::Null,
        log,
        stopped: false,
    };
    poll("the server socket", || {
        assert!(
            server.child.wait(Duration::ZERO).is_none(),
            "server exited: {}",
            server.log()
        );
        server.dial().is_ok()
    });
    let version = server.request("GET", "/version", None, 200);
    server.vt = version["vt"].as_str().unwrap_or_default().to_owned();
    server
}

impl Server {
    pub(crate) fn log(&self) -> String {
        std::fs::read_to_string(&self.log).unwrap_or_default()
    }

    pub(crate) fn dial(&self) -> std::io::Result<UnixStream> {
        UnixStream::connect(self.dir.join("socket"))
    }

    pub(crate) fn headers(&self) -> Headers {
        let mut headers = vec![("Ko-Protocol".to_owned(), "1.0".to_owned())];
        if !self.vt.is_empty() {
            headers.push(("Ko-Vt".to_owned(), self.vt.clone()));
        }
        headers
    }

    pub(crate) fn client_headers(&self, client: &str) -> Headers {
        let mut headers = self.headers();
        headers.push(("Ko-Client".to_owned(), client.to_owned()));
        headers
    }

    pub(crate) fn exchange(
        &self,
        method: &str,
        path: &str,
        headers: &Headers,
        body: &[u8],
    ) -> (u16, Vec<u8>) {
        let mut stream = self.dial().unwrap();
        let deadline = Instant::now() + DEADLINE;
        within(&stream, deadline);
        let mut head = format!("{method} {path} HTTP/1.1\r\nHost: ko\r\n");
        for (name, value) in headers {
            head.push_str(&format!("{name}: {value}\r\n"));
        }
        head.push_str(&format!("Content-Length: {}\r\n\r\n", body.len()));
        stream.write_all(head.as_bytes()).unwrap();
        stream.write_all(body).unwrap();
        let mut buffer = Vec::new();
        let (status, framing, head_len) = loop {
            let mut chunk = [0u8; 65536];
            read_within(&stream, deadline);
            let count = stream
                .read(&mut chunk)
                .unwrap_or_else(|error| panic!("{method} {path}: {error} ({})", self.log()));
            assert!(count > 0, "{method} {path}: closed ({})", self.log());
            buffer.extend_from_slice(&chunk[..count]);
            let mut slots = [httparse::EMPTY_HEADER; 64];
            let mut response = httparse::Response::new(&mut slots);
            if let httparse::Status::Complete(head_len) = response.parse(&buffer).unwrap() {
                let header = |name: &str| {
                    response
                        .headers
                        .iter()
                        .find(|header| header.name.eq_ignore_ascii_case(name))
                        .map(|header| std::str::from_utf8(header.value).unwrap().to_owned())
                };
                let framing = match (header("content-length"), header("transfer-encoding")) {
                    (_, Some(coding)) if coding.eq_ignore_ascii_case("chunked") => Framing::Chunked,
                    (Some(length), _) => Framing::Length(length.parse().unwrap()),
                    _ => Framing::Close,
                };
                break (response.code.unwrap(), framing, head_len);
            }
        };
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
                assert!(
                    matches!(framing, Framing::Close),
                    "{method} {path}: body cut short"
                );
                break;
            }
            body.extend_from_slice(&chunk[..count]);
        }
        (status, body)
    }

    pub(crate) fn request_text(
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

    pub(crate) fn request(
        &self,
        method: &str,
        path: &str,
        body: Option<&Value>,
        status: u16,
    ) -> Value {
        let data = self.request_text(method, path, body, status);
        serde_json::from_str(&data).unwrap_or(Value::Null)
    }

    pub(crate) fn dial_ws(&self, path: &str, headers: Option<Headers>, status: u16) -> Option<Ws> {
        let headers = headers.unwrap_or_else(|| self.headers());
        let stream = self.dial().unwrap();
        stream.set_read_timeout(Some(DEADLINE)).unwrap();
        stream.set_write_timeout(Some(DEADLINE)).unwrap();
        let mut request =
            tungstenite::client::IntoClientRequest::into_client_request(format!("ws://ko{path}"))
                .unwrap();
        for (name, value) in &headers {
            request.headers_mut().insert(
                HeaderName::from_bytes(name.as_bytes()).unwrap(),
                HeaderValue::from_str(value).unwrap(),
            );
        }
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
            }),
            Err(error) => panic!("upgrade {path}: {error} ({})", self.log()),
        }
    }

    pub(crate) fn ws(&self, path: &str) -> Ws {
        self.dial_ws(path, None, 101).unwrap()
    }

    pub(crate) fn client(&mut self, pane: &str) -> (Ws, String) {
        let mut ws = self.ws("/client");
        let mut hello =
            json!({"kind": "terminal", "name": "test", "focused": true, "size": size(80, 24)});
        if !pane.is_empty() {
            hello["pane"] = json!(pane);
        }
        ws.send(&json!(["hello", hello]));
        let mut identity = Value::Null;
        for key in ["welcome", "topology"] {
            let Message::Text(text) = ws.read() else {
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
        self.limits = identity["limits"].clone();
        let id = identity["client"].as_str().unwrap_or_default().to_owned();
        (ws, id)
    }

    pub(crate) fn pane(&self, command: &str) -> String {
        let body = json!({"command": ["argv", ["/bin/sh", "-c", command]], "cwd": "/tmp"});
        self.request("POST", "/panes", Some(&body), 200)["pane"]
            .as_str()
            .unwrap_or_default()
            .to_owned()
    }

    pub(crate) fn text(&self, pane: &str, text: &str) {
        self.request(
            "POST",
            &format!("/panes/{pane}/input"),
            Some(&json!(["text", base64(text.as_bytes())])),
            200,
        );
    }

    pub(crate) fn pane_pids(&self) -> Vec<(String, i64)> {
        let Value::Array(rows) = self.request("GET", "/panes", None, 200) else {
            panic!("/panes is not a list");
        };
        rows.iter()
            .map(|row| {
                (
                    row["id"].as_str().unwrap_or_default().to_owned(),
                    row["pid"].as_i64().unwrap_or_default(),
                )
            })
            .collect()
    }

    pub(crate) fn program_pid(&self) -> Pid {
        let panes = self.pane_pids();
        assert!(panes.len() == 1 && panes[0].1 > 1, "program pid: {panes:?}");
        Pid::new(panes[0].1).unwrap()
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
