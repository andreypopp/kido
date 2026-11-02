use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use ko_pane_wire::frame::{CellPx, Dim, History, ScreenFormat, ScreenRows, Size};
use ko_sys::event::{Mode, Token};
use ko_vt::{Extent, Format, Terminal};
use proptest::prelude::*;
use proptest::test_runner::TestCaseError;

use crate::config::DEFAULT_LIMITS;
use crate::conn::Phase;
use crate::fuzz::Rig;
use crate::http::{Response, read_response, request};
use crate::link::Role;
use crate::pane_proc::{Cause, Life};
use crate::protocol::{
    self, Images, Marker, Route, ViewEvent, ViewOptions, ViewRequest, version_headers,
};
use crate::server::Verified;
use crate::ws::{BadRecord, Frame, Record, masked, parse_frame, parse_record};

#[derive(Debug, Clone, Copy)]
enum Source {
    Lines,
    Soup,
    Corpus(usize),
    Osc8,
    Wide,
    Kitty,
    Alt,
    Binary,
}

#[derive(Debug, Clone, Copy)]
enum Reader {
    Fast,
    Slow(usize),
    Stalled,
}

#[derive(Debug, Clone, Copy)]
enum Who {
    Client,
    Server,
}

#[derive(Debug, Clone, Copy)]
enum Op {
    Feed(Source, usize, u64),
    Resize(u16, u16),
    Open(History, Reader, bool, bool),
    Resume(usize, History, Reader),
    Resync(usize, History),
    ClearHistory,
    Reader(usize, Reader),
    Close(usize, Who),
    Eof,
    Crash,
    Settle(usize),
    Check,
}

#[derive(Debug)]
enum Failure {
    Bug(String),
    Libghostty,
}

type Checked<T = ()> = Result<T, Failure>;

fn bug<T>(message: String) -> Checked<T> {
    Err(Failure::Bug(message))
}

fn vt<T>(result: Result<T, ko_vt::Error>) -> Checked<T> {
    result.map_err(|error| Failure::Bug(error.to_string()))
}

struct Rng(u64);

impl Rng {
    fn new(seed: u64) -> Rng {
        Rng(seed.wrapping_add(0x9e37_79b9_7f4a_7c15))
    }

    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        z ^ (z >> 31)
    }

    fn below(&mut self, bound: usize) -> usize {
        usize::try_from(self.next() % bound.max(1) as u64).unwrap_or(0)
    }

    fn pick<'a, T>(&mut self, items: &'a [T]) -> &'a T {
        &items[self.below(items.len())]
    }
}

const WORDS: [&str; 11] = [
    "alpha",
    "beta",
    "gamma",
    "delta",
    "x",
    "日本語",
    "naïve",
    "👩‍👩‍👧",
    "e\u{301}",
    "tab\t",
    "",
];

fn params(rng: &mut Rng) -> String {
    (0..rng.below(4))
        .map(|_| {
            if rng.below(8) == 0 {
                String::new()
            } else {
                rng.below(300).to_string()
            }
        })
        .collect::<Vec<_>>()
        .join(";")
}

fn csi(rng: &mut Rng) -> String {
    let prefix = *rng.pick(&["", "", "", "?", ">", "=", "<", " ", "!"]);
    let finals = [
        "m", "H", "J", "K", "A", "B", "C", "D", "r", "h", "l", "n", "c", "t", "d", "G", "X", "S",
        "T", "P", "L", "M", "@", "u", "s", "q", "g", "f", "E", "F", "b", "Z",
    ];
    let last = *rng.pick(&finals);
    let params = if last == "h" || last == "l" {
        (*rng.pick(&[
            "?1049", "?1047", "?47", "?1000", "?1002", "?1006", "?2004", "?25", "?1", "?7", "?6",
            "?69", "?1004", "?2027", "?1003", "?9",
        ]))
        .to_owned()
    } else {
        params(rng)
    };
    format!("\x1b[{prefix}{params}{last}")
}

fn terminator(rng: &mut Rng) -> &'static str {
    if rng.below(2) == 0 { "\x07" } else { "\x1b\\" }
}

fn osc(rng: &mut Rng) -> String {
    let code = *rng.pick(&[
        "0", "2", "7", "8", "10", "11", "52", "104", "133", "633", "1337", "9", "777", "99",
    ]);
    let body = *rng.pick(&[
        "",
        "title",
        ";https://example.org/a",
        "file://localhost/tmp",
        "A",
        "C;cmdline_url=ls",
        "D;0",
        "id=1;http://x",
        "?",
    ]);
    format!("\x1b]{code};{body}{}", terminator(rng))
}

fn dcs(rng: &mut Rng) -> String {
    let body = *rng.pick(&[
        "$qm",
        "$q\"p",
        "+q544e",
        "1;1|17/ab",
        "q#0;2;0;0;0#0~~~~",
        "=1s",
        "tmux;\x1b\x1b[0m",
    ]);
    format!("\x1bP{body}{}", terminator(rng))
}

fn kitty(rng: &mut Rng) -> String {
    let id = 1 + rng.below(5);
    let x = rng.below(4);
    let control = match rng.below(8) {
        0 => format!("a=T,f=32,s=2,v=2,i={id},c=3,r=1"),
        1 => format!("a=p,i={id},x={x},y=0"),
        2 => format!("a=d,d=i,i={id}"),
        3 => format!("a=t,f=24,s=1,v=1,i={id},q=2"),
        4 => format!("a=f,i={id},r=1,s=1,v=1,f=32"),
        5 => "a=q,i=31,s=1,v=1,t=s".to_owned(),
        6 => "a=T,f=100,i=9".to_owned(),
        _ => "a=d,d=A".to_owned(),
    };
    let long = "A".repeat(40);
    let payload = match rng.below(5) {
        0 => "AQIDBA==",
        1 => "AAAAAAAAAAAAAAAA",
        2 => "",
        3 => "!!!",
        _ => long.as_str(),
    };
    format!("\x1b_G{control};{payload}\x1b\\")
}

fn corpus() -> &'static [Vec<u8>] {
    static CORPUS: std::sync::OnceLock<Vec<Vec<u8>>> = std::sync::OnceLock::new();
    CORPUS.get_or_init(|| {
        let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../bench/streams");
        let mut names: Vec<_> = std::fs::read_dir(dir)
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .filter(|path| path.extension().is_some_and(|ext| ext == "vt"))
            .collect();
        names.sort();
        names
            .iter()
            .map(|path| std::fs::read(path).unwrap())
            .collect()
    })
}

fn piece(rng: &mut Rng, source: Source) -> Vec<u8> {
    match source {
        Source::Lines => {
            let words: Vec<&str> = (0..1 + rng.below(10)).map(|_| *rng.pick(&WORDS)).collect();
            let end = *rng.pick(&[
                "\r\n",
                "\r\n",
                "\n",
                "\r",
                "\x1b[0m\r\n",
                "\x1b[1;31mred\x1b[0m\r\n",
            ]);
            format!("{}{end}", words.join(" ")).into_bytes()
        }
        Source::Soup => match rng.below(12) {
            0..=3 => csi(rng).into_bytes(),
            4 => osc(rng).into_bytes(),
            5 => dcs(rng).into_bytes(),
            6 => kitty(rng).into_bytes(),
            7 => rng
                .pick(&[
                    "\x1bc", "\x1b7", "\x1b8", "\x1bM", "\x1bD", "\x1bE", "\x1b=", "\x1b>",
                    "\x1b(0", "\x1b(B", "\x1b#8", "\x1b\\", "\x1b",
                ])
                .as_bytes()
                .to_vec(),
            8 => vec![u8::try_from(rng.below(32)).unwrap_or(0)],
            9 => rng.pick(&WORDS).as_bytes().to_vec(),
            10 => (0..1 + rng.below(4))
                .map(|_| u8::try_from(0x80 + rng.below(128)).unwrap_or(0x80))
                .collect(),
            _ => b"\r\n".to_vec(),
        },
        Source::Corpus(index) => {
            let stream = &corpus()[index % corpus().len()];
            let start = rng.below(stream.len());
            let len = (1 + rng.below(4096)).min(stream.len() - start);
            stream[start..start + len].to_vec()
        }
        Source::Osc8 => {
            let n = rng.below(1000);
            let id = *rng.pick(&["", "id=a", "id=b:c"]);
            format!("\x1b]8;{id};https://example.org/{n}\x1b\\link {n}\x1b]8;;\x1b\\\r\n")
                .into_bytes()
        }
        Source::Wide => {
            let text = *rng.pick(&[
                "日本語のテキスト",
                "😀😃😄",
                "👩‍👩‍👧",
                "e\u{301}\u{302}",
                "ｱｲｳ",
                "\u{3000}",
                "a\u{200b}b",
                "🇯🇵🇺🇸",
            ]);
            let end = *rng.pick(&["\r\n", "", "\x1b[3G"]);
            format!("{text}{end}").into_bytes()
        }
        Source::Kitty => {
            let end = *rng.pick(&["", "\r\n", "text"]);
            format!("{}{end}", kitty(rng)).into_bytes()
        }
        Source::Alt => {
            let mode = *rng.pick(&[
                "\x1b[?1049h",
                "\x1b[?1049l",
                "\x1b[?47h",
                "\x1b[?47l",
                "\x1b[?1047h",
                "\x1b[?1047l",
            ]);
            let words: String = (0..rng.below(5))
                .map(|_| format!("{}\r\n", rng.pick(&WORDS)))
                .collect();
            format!("{mode}{words}").into_bytes()
        }
        Source::Binary => (0..1 + rng.below(64))
            .map(|_| u8::try_from(rng.below(256)).unwrap_or(0))
            .collect(),
    }
}

fn chunk(seed: u64, source: Source, size: usize) -> Vec<u8> {
    let mut rng = Rng::new(seed);
    let mut data = Vec::with_capacity(size + 256);
    while data.len() < size {
        data.extend(piece(&mut rng, source));
    }
    data.truncate(size);
    data
}

#[derive(Debug, Default)]
struct Mirror {
    term: Option<Terminal>,
    offset: Option<u64>,
    full: bool,
    skipped: bool,
    snapshot: Option<Snapshot>,
    snapshots: usize,
    deaths: usize,
}

#[derive(Debug)]
struct Snapshot {
    data: Vec<u8>,
    offset: u64,
    screen: bool,
}

impl Mirror {
    fn fresh() -> Mirror {
        Mirror {
            full: true,
            ..Mirror::default()
        }
    }

    fn describe(&self) -> String {
        format!(
            "offset {:?} full {} skipped {} snapshotting {}",
            self.offset,
            self.full,
            self.skipped,
            self.snapshot.is_some()
        )
    }

    fn event(&mut self, event: ViewEvent) -> Checked {
        match event {
            ViewEvent::Marked(marked) => {
                if self.snapshot.is_some() {
                    return bug("marker inside a snapshot".to_owned());
                }
                if self.offset != Some(marked.offset) {
                    return bug(format!(
                        "marker at offset {} for a mirror at {}",
                        marked.offset,
                        self.describe()
                    ));
                }
                match (marked.marker, self.term.as_mut()) {
                    (Marker::Resize(size), Some(term)) => vt(term.resize(size.0)),
                    (Marker::Dead(_), _) => {
                        self.deaths += 1;
                        Ok(())
                    }
                    (Marker::Resize(_), None) => bug("marker before any terminal".to_owned()),
                }
            }
            ViewEvent::Skipped(skipped) => {
                let ok = self.offset == Some(skipped.from)
                    && skipped.offset == skipped.to
                    && skipped.to >= skipped.from;
                if !ok {
                    return bug(format!(
                        "skip {}..{} ({}) for a mirror at {}",
                        skipped.from,
                        skipped.to,
                        skipped.offset,
                        self.describe()
                    ));
                }
                self.skipped = true;
                self.offset = None;
                Ok(())
            }
            ViewEvent::Pasted(_) => Ok(()),
        }
    }

    fn record(&mut self, recorder: Option<&mut Mirror>, payload: &[u8]) -> Checked {
        let (kind, offset, body) = match parse_record(payload) {
            Ok(parsed) => parsed,
            Err(BadRecord::Short) => return bug("record shorter than its header".to_owned()),
            Err(BadRecord::Kind(kind)) => return bug(format!("record kind {kind}")),
        };
        match kind {
            Record::Output => {
                if self.skipped || self.snapshot.is_some() {
                    return bug("output between a skip and its snapshot".to_owned());
                }
                match (self.offset, self.term.as_mut()) {
                    (Some(expected), Some(term)) => {
                        if expected != offset {
                            return bug(format!(
                                "output at offset {offset} where {expected} was due (gap or stale data)"
                            ));
                        }
                        term.write(body);
                        self.offset = Some(expected + body.len() as u64);
                        Ok(())
                    }
                    _ => bug("output before a snapshot".to_owned()),
                }
            }
            Record::Snapshot => self.slice(recorder, offset, body),
        }
    }
    fn slice(&mut self, recorder: Option<&mut Mirror>, offset: u64, body: &[u8]) -> Checked {
        let [flags, screen, data @ ..] = body else {
            return bug("snapshot slice shorter than its header".to_owned());
        };
        let (first, last, screen) = (flags & 1 != 0, flags & 2 != 0, *screen != 0);
        match (first, self.snapshot.as_mut()) {
            (true, None) => {
                self.snapshots += 1;
                self.snapshot = Some(Snapshot {
                    data: data.to_vec(),
                    offset,
                    screen,
                });
            }
            (false, Some(snapshot)) => {
                if snapshot.offset != offset || snapshot.screen != screen {
                    return bug("snapshot slices disagree".to_owned());
                }
                snapshot.data.extend_from_slice(data);
            }
            (true, Some(_)) => return bug("snapshot restarted inside a snapshot".to_owned()),
            (false, None) => return bug("snapshot slice without its first".to_owned()),
        }
        if !last {
            return Ok(());
        }
        let Some(snapshot) = self.snapshot.take() else {
            return Ok(());
        };
        let extent = if screen { Extent::Screen } else { Extent::Full };
        let decoded = match Terminal::decode(&mut snapshot.data.as_slice(), extent) {
            Ok(decoded) => decoded,
            Err(error) => {
                let message = error.to_string();
                if let (true, Some(recorder)) = (message.ends_with("(-2)"), recorder)
                    && let Some(term) = recorder.term.as_mut()
                {
                    let mut own = Vec::new();
                    vt(term.snapshot(screen, |bytes| {
                        own.extend_from_slice(bytes);
                        true
                    }))?;
                    return match Terminal::decode(&mut own.as_slice(), extent) {
                        Ok(_) => bug(format!(
                            "snapshot at {offset} does not decode, the recorder's own does: {message}"
                        )),
                        Err(again) if again.to_string() == message => Err(Failure::Libghostty),
                        Err(_) => bug(format!("snapshot at {offset} does not decode: {message}")),
                    };
                }
                return bug(format!("snapshot at {offset} does not decode: {message}"));
            }
        };
        self.term = Some(decoded);
        self.offset = Some(offset);
        self.skipped = false;
        self.full = !screen;
        Ok(())
    }
}

#[derive(Debug)]
struct ViewClient {
    stream: Option<UnixStream>,
    token: Token,
    speed: Reader,
    pending: Vec<u8>,
    upgraded: bool,
    server_closed: bool,
    reason: String,
    expected_close: bool,
    mirror: Mirror,
}

impl ViewClient {
    fn alive(&self) -> bool {
        self.stream.is_some()
    }

    fn converged(&self, fed: u64, waiting: bool) -> bool {
        self.mirror.offset == Some(fed)
            && self.mirror.snapshot.is_none()
            && !self.mirror.skipped
            && !waiting
    }
}

fn rows(text: &[u8]) -> Vec<String> {
    let ascii: String = text
        .iter()
        .filter(|byte| **byte < 128)
        .map(|byte| char::from(*byte))
        .collect();
    let mut rows: Vec<String> = ascii
        .split('\n')
        .map(|row| row.trim_end().to_owned())
        .collect();
    while rows.last().is_some_and(String::is_empty) {
        rows.pop();
    }
    rows
}

fn without_hyperlinks(dump: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(dump.len());
    let mut at = 0;
    while at < dump.len() {
        if dump[at..].starts_with(b"\x1b]8;") {
            let mut end = at + 4;
            while end < dump.len()
                && dump[end] != 7
                && !(dump[end] == 0x1b && dump.get(end + 1) == Some(&b'\\'))
            {
                end += 1;
            }
            at = if dump.get(end) == Some(&0x1b) {
                end + 2
            } else {
                end + 1
            };
        } else {
            out.push(dump[at]);
            at += 1;
        }
    }
    out
}

fn first_difference(a: &[u8], b: &[u8]) -> String {
    let at = a.iter().zip(b).take_while(|(x, y)| x == y).count();
    let around = |s: &[u8]| {
        let from = at.saturating_sub(60);
        String::from_utf8_lossy(&s[from..s.len().min(from + 160)])
            .escape_debug()
            .to_string()
    };
    format!(
        "at {at}:\n  recorder {}\n  other    {}",
        around(a),
        around(b)
    )
}

fn differences(history: bool, a: &Terminal, b: &Terminal) -> Checked<Vec<String>> {
    vt(ko_vt::differences(a, b, history, without_hyperlinks))
}

fn compare_with(reference: &Mirror, name: &str, other: &Mirror) -> Checked {
    let (Some(a), Some(b)) = (reference.term.as_ref(), other.term.as_ref()) else {
        return bug(format!("{name} has no terminal"));
    };
    let found = differences(reference.full && other.full, a, b)?;
    if found.is_empty() {
        return Ok(());
    }
    let detail = if found.iter().any(|d| d == "plain text") {
        format!(
            " {}",
            first_difference(&vt(a.dump(Format::Plain))?, &vt(b.dump(Format::Plain))?)
        )
    } else {
        String::new()
    };
    bug(format!(
        "{name} differs from the recorder in {}{detail}",
        found.join(", ")
    ))
}

static NEXT_DIR: AtomicU32 = AtomicU32::new(0);

struct Harness {
    rig: Rig,
    chunk: Vec<u8>,
    feed: Option<File>,
    queued: Vec<u8>,
    sent: usize,
    fed: u64,
    eof: bool,
    crashed: bool,
    views: Vec<ViewClient>,
    retired: Vec<Mirror>,
    frames: u64,
    stable: u32,
    seen: u64,
}

impl Drop for Harness {
    fn drop(&mut self) {
        self.views.clear();
        self.rig.state.shutdown(&mut self.rig.poll);
        let deadline = Instant::now() + Duration::from_secs(2);
        let finished = |h: &Harness| {
            h.rig
                .state
                .panes
                .iter()
                .all(|p| p.proc().life() == Life::Reaped)
        };
        while !finished(self) && Instant::now() < deadline {
            let _ = self.rig.state.panes.kill();
            self.rig.step(Mode::Peek);
            std::thread::sleep(Duration::from_millis(2));
        }
    }
}

fn ko_pane() -> PathBuf {
    PathBuf::from(
        std::env::var_os("KO_PANE_EXE")
            .expect("KO_PANE_EXE names the Rust ko-pane; make test-ko builds it and sets it"),
    )
}

fn headers(extra: &[(&str, &str)]) -> Vec<(String, String)> {
    let mut headers: Vec<(String, String)> = version_headers()
        .into_iter()
        .map(|(name, value)| (name.to_owned(), value))
        .collect();
    headers.push(("host".to_owned(), "ko".to_owned()));
    headers.extend(
        extra
            .iter()
            .map(|(name, value)| ((*name).to_owned(), (*value).to_owned())),
    );
    headers
}

fn send_request(stream: &mut UnixStream, route: &Route, extra: &[(&str, &str)]) {
    let (method, target) = route.to_request();
    let headers = headers(extra);
    let headers: Vec<(&str, &str)> = headers
        .iter()
        .map(|(name, value)| (name.as_str(), value.as_str()))
        .collect();
    stream
        .write_all(&request(method, &target, &headers, b""))
        .unwrap();
}

impl Harness {
    fn new() -> Harness {
        let dir = PathBuf::from(format!(
            "/tmp/ko-view-{}-{}",
            std::process::id(),
            NEXT_DIR.fetch_add(1, Ordering::SeqCst)
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let fifo = dir.join("in");
        let made = ko_sys::spawn::program(
            std::path::Path::new("/usr/bin/mkfifo"),
            &[fifo.to_str().unwrap()],
            &[],
            ko_sys::spawn::Env::Inherit,
        )
        .unwrap()
        .wait()
        .unwrap();
        assert_eq!(
            made,
            ko_sys::pid::Waited::Ended(ko_sys::pid::Exit::Exited(0))
        );
        let limits = ko_pane_wire::frame::Limits {
            scrollback: ko_pane_wire::frame::Scrollback::Bounded {
                max_bytes: std::num::NonZeroUsize::new(1 << 30),
                max_lines: None,
            },
            ..DEFAULT_LIMITS
        };
        let command = format!("stty raw -echo; exec cat {}/in", dir.display());
        let rig = Rig::new(dir, ko_pane(), limits, &command);
        Harness {
            rig,
            chunk: vec![0; 65536],
            feed: None,
            queued: Vec::new(),
            sent: 0,
            fed: 0,
            eof: false,
            crashed: false,
            views: Vec::new(),
            retired: Vec::new(),
            frames: 0,
            stable: 0,
            seen: 0,
        }
    }

    fn unsent(&self) -> usize {
        self.queued.len() - self.sent
    }

    fn flush_feed(&mut self) {
        if self.feed.is_none() && (!self.eof || self.unsent() > 0) {
            self.feed = OpenOptions::new()
                .write(true)
                .custom_flags(libc::O_NONBLOCK)
                .open(self.rig.dir().join("in"))
                .ok();
        }
        let Some(file) = self.feed.as_mut() else {
            return;
        };
        if self.sent < self.queued.len() {
            match file.write(&self.queued[self.sent..]) {
                Ok(count) => self.sent += count,
                Err(error) if error.kind() == std::io::ErrorKind::BrokenPipe => {
                    self.sent = self.queued.len();
                }
                Err(_) => {}
            }
        }
        if self.eof && self.sent == self.queued.len() {
            self.feed = None;
        }
    }

    fn waiting(&self, token: Token) -> bool {
        self.rig
            .state
            .conns
            .iter()
            .find(|conn| conn.token == token)
            .is_some_and(|conn| match conn.role() {
                Some(Role::View(view)) => view.waiting(&conn.out),
                _ => false,
            })
    }

    fn converged(&self, view: &ViewClient) -> bool {
        view.converged(self.fed, self.waiting(view.token))
    }

    fn pane_state(&self) -> String {
        match self
            .rig
            .state
            .panes
            .find(self.rig.pane)
            .and_then(|p| p.proc().dead())
        {
            Some(death) => match &death.cause {
                Cause::Failed(message) => format!("failed: {message}"),
                Cause::Exit(_) => "exited".to_owned(),
            },
            None => "running".to_owned(),
        }
    }

    fn pane_open(&self) -> bool {
        self.rig
            .state
            .panes
            .find(self.rig.pane)
            .is_some_and(|pane| pane.proc().life() == Life::Open)
    }

    fn read_view(&mut self, index: usize) -> Checked {
        let mut left = match self.views[index].speed {
            Reader::Fast => 1 << 20,
            Reader::Slow(count) => count,
            Reader::Stalled => 0,
        };
        let mut chunk = std::mem::take(&mut self.chunk);
        let read = loop {
            if left == 0 {
                break Ok(());
            }
            let view = &mut self.views[index];
            let Some(stream) = view.stream.as_mut() else {
                break Ok(());
            };
            let want = left.min(chunk.len());
            match stream.read(&mut chunk[..want]) {
                Ok(0) => {
                    view.server_closed = true;
                    view.stream = None;
                }
                Ok(count) => {
                    left -= count;
                    view.pending.extend_from_slice(&chunk[..count]);
                    if let Err(failure) = self.parse(index) {
                        break Err(failure);
                    }
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => left = 0,
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::ConnectionReset | std::io::ErrorKind::BrokenPipe
                    ) =>
                {
                    view.server_closed = true;
                    view.stream = None;
                }
                Err(error) => break bug(format!("view read: {error}")),
            }
        };
        self.chunk = chunk;
        read
    }

    fn parse(&mut self, index: usize) -> Checked {
        let mut at = 0;
        let mut pending = std::mem::take(&mut self.views[index].pending);
        if !self.views[index].upgraded {
            let Some(end) = pending.windows(4).position(|w| w == b"\r\n\r\n") else {
                self.views[index].pending = pending;
                return Ok(());
            };
            if !pending.starts_with(b"HTTP/1.1 101") && self.views[index].expected_close {
                self.views[index].server_closed = true;
                self.views[index].stream = None;
                return Ok(());
            }
            if !pending.starts_with(b"HTTP/1.1 101") {
                return bug(format!(
                    "view upgrade refused: {}",
                    String::from_utf8_lossy(&pending[..end])
                ));
            }
            self.views[index].upgraded = true;
            at = end + 4;
        }
        while let Some(Frame {
            opcode,
            header,
            length,
        }) = parse_frame(&pending[at..])
        {
            if pending.len() - at < header + length {
                break;
            }
            let payload = &pending[at + header..at + header + length];
            self.frames += 1;
            let (first, rest) = self.views.split_at_mut(1);
            let (view, recorder) = match index {
                0 => (&mut first[0], None),
                _ => (&mut rest[index - 1], Some(&mut first[0].mirror)),
            };
            match opcode {
                1 => {
                    let event = protocol::decode::<ViewEvent>(payload)
                        .map_err(|error| Failure::Bug(format!("view event: {error}")))?;
                    view.mirror.event(event)?;
                }
                2 => view.mirror.record(recorder, payload)?,
                8 => {
                    view.server_closed = true;
                    view.reason =
                        String::from_utf8_lossy(payload.get(2..).unwrap_or_default()).into_owned();
                }
                _ => {}
            }
            at += header + length;
        }
        pending.drain(..at);
        self.views[index].pending = pending;
        Ok(())
    }

    fn tick(&mut self) -> Checked {
        self.rig.step(Mode::Peek);
        self.flush_feed();
        for index in 0..self.views.len() {
            self.read_view(index)?;
        }
        let progress = match self.rig.state.panes.find_mut(self.rig.pane) {
            Some(pane) if pane.proc().life() != Life::Reaped => self.frames.wrapping_add(
                pane.proc_mut()
                    .delivery_mut()
                    .map_or(0, |delivery| delivery.head().get()),
            ),
            _ => self.frames,
        };
        if progress == self.seen {
            self.stable += 1;
            std::thread::sleep(Duration::from_micros(200));
        } else {
            self.seen = progress;
            self.stable = 0;
        }
        Ok(())
    }

    fn until(&mut self, what: &str, mut done: impl FnMut(&mut Harness) -> bool) -> Checked {
        let deadline = Instant::now() + Duration::from_secs(10);
        while !done(self) {
            if Instant::now() > deadline {
                let views: Vec<String> = self
                    .views
                    .iter()
                    .map(|v| {
                        format!(
                            "[{} alive {} closed {} reason {:?}]",
                            v.mirror.describe(),
                            v.alive(),
                            v.server_closed,
                            v.reason
                        )
                    })
                    .collect();
                return bug(format!(
                    "timed out waiting for {what} (fed {}, queued {}, pane {}, views: {})",
                    self.fed,
                    self.unsent(),
                    self.pane_state(),
                    views.join("; ")
                ));
            }
            self.tick()?;
        }
        Ok(())
    }

    fn open_view(
        &mut self,
        history: History,
        speed: Reader,
        small: bool,
        offset: Option<u64>,
        mirror: Mirror,
    ) {
        let (ours, mut theirs) = UnixStream::pair().unwrap();
        let admitted =
            Verified::admit(ours)
                .unwrap()
                .with_send_buffer(if small { 4096 } else { 262_144 });
        self.rig.state.accept(&mut self.rig.poll, admitted);
        let token = self.rig.state.conns.last().unwrap().token;
        send_request(
            &mut theirs,
            &Route::View(
                self.rig.pane,
                ViewOptions {
                    history,
                    images: Images::None,
                },
                offset,
            ),
            &[
                ("upgrade", "websocket"),
                ("connection", "Upgrade"),
                ("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ=="),
                ("sec-websocket-version", "13"),
            ],
        );
        theirs.set_nonblocking(true).unwrap();
        self.views.push(ViewClient {
            stream: Some(theirs),
            token,
            speed,
            pending: Vec::new(),
            upgraded: false,
            server_closed: false,
            reason: String::new(),
            expected_close: self.crashed,
            mirror,
        });
    }

    fn drop_view(&mut self, index: usize) -> ViewClient {
        let mut view = self.views.remove(index);
        view.stream = None;
        view
    }

    fn close_server_side(&mut self, token: Token) {
        if let Some((Role::View(view), wire)) = self
            .rig
            .state
            .conns
            .iter_mut()
            .find(|conn| conn.token == token)
            .and_then(|conn| conn.role_mut())
        {
            view.close(wire.out);
        }
    }

    fn request_screen(&mut self, rows: ScreenRows) -> mpsc::Receiver<std::io::Result<Response>> {
        let (ours, mut theirs) = UnixStream::pair().unwrap();
        self.rig
            .state
            .accept(&mut self.rig.poll, Verified::admit(ours).unwrap());
        let route = Route::Screen(self.rig.pane, ScreenFormat::Plain, rows);
        let (sender, receiver) = mpsc::channel();
        std::thread::spawn(move || {
            theirs
                .set_read_timeout(Some(Duration::from_secs(20)))
                .unwrap();
            send_request(&mut theirs, &route, &[]);
            let _ = sender.send(read_response(&mut theirs));
        });
        receiver
    }

    fn screen(&mut self, rows: ScreenRows) -> Checked<Response> {
        let receiver = self.request_screen(rows);
        let mut response = None;
        self.until("the pane to answer", |_| {
            if response.is_none() {
                response = receiver.try_recv().ok();
            }
            response.is_some()
        })?;
        self.stable = 0;
        match response {
            Some(Ok(response)) => Ok(response),
            Some(Err(error)) => bug(format!("screen: {error}")),
            None => bug("no screen answer".to_owned()),
        }
    }

    fn check(&mut self) -> Checked {
        if self.crashed {
            for view in &mut self.views {
                view.speed = Reader::Fast;
            }
            return self.until("views closed after a crash", |h| {
                h.views.iter().all(|v| v.server_closed || !v.alive())
            });
        }
        self.until(
            "the recorder to see every byte while other views stall",
            |h| h.unsent() == 0 && h.converged(&h.views[0]),
        )?;
        let pane_screen = self.screen(ScreenRows::Visible)?.body;
        for view in &mut self.views {
            view.speed = Reader::Fast;
        }
        self.until("every view to catch up", |h| {
            h.stable >= 30 && h.views.iter().all(|v| v.server_closed || h.converged(v))
        })?;
        if self.pane_state() == "exited" {
            self.until("every view to see the death", |h| {
                h.views
                    .iter()
                    .all(|v| v.server_closed || v.mirror.deaths > 0)
            })?;
        }
        if let Some(reason) = self
            .views
            .iter()
            .find(|view| view.server_closed && !view.expected_close)
            .map(|view| view.reason.clone())
        {
            if self.recorder_cannot_snapshot() {
                return Err(Failure::Libghostty);
            }
            return bug(format!(
                "the server closed a healthy view: {reason:?}, pane {}",
                self.pane_state()
            ));
        }
        for view in self.views.iter().skip(1).filter(|view| !view.server_closed) {
            compare_with(&self.views[0].mirror, "view", &view.mirror)?;
        }
        let Some(term) = self.views[0].mirror.term.as_ref() else {
            return bug("the recorder has no terminal".to_owned());
        };
        let mirror_screen = rows(&vt(term.dump(Format::Plain))?);
        if rows(&pane_screen) != mirror_screen {
            return bug(format!(
                "the pane's own screen differs from its mirror: {}",
                first_difference(&pane_screen, mirror_screen.join("\n").as_bytes())
            ));
        }
        let snapshots: Vec<usize> = self.views.iter().map(|v| v.mirror.snapshots).collect();
        self.open_view(History::All, Reader::Fast, true, None, Mirror::fresh());
        let probe = self.views.len() - 1;
        self.until("a fresh snapshot", |h| {
            h.stable >= 30 && h.converged(&h.views[probe])
        })?;
        let after: Vec<usize> = self.views[..probe]
            .iter()
            .map(|v| v.mirror.snapshots)
            .collect();
        if snapshots != after {
            return bug("an idle view took a snapshot because another view took one".to_owned());
        }
        compare_with(
            &self.views[0].mirror,
            "fresh snapshot",
            &self.views[probe].mirror,
        )?;
        let token = self.views[probe].token;
        self.close_server_side(token);
        self.drop_view(probe);
        Ok(())
    }

    fn recorder_cannot_snapshot(&mut self) -> bool {
        self.views[0].mirror.term.as_mut().is_some_and(|term| {
            [true, false]
                .into_iter()
                .any(|screen| term.snapshot(screen, |_| true).is_err())
        })
    }

    fn live(&self, index: usize) -> Option<usize> {
        let others = self.views.len().checked_sub(1).filter(|n| *n > 0)?;
        Some(1 + index % others)
    }

    fn step_op(&mut self, op: Op) -> Checked {
        match op {
            Op::Feed(source, size, seed) => {
                if !self.eof {
                    let data = chunk(seed, source, size);
                    self.queued.drain(..self.sent);
                    self.sent = 0;
                    self.fed += data.len() as u64;
                    self.queued.extend(data);
                }
            }
            Op::Resize(cols, rows) => {
                if !self.crashed {
                    let size = Size {
                        cols: Dim::new(cols).unwrap(),
                        rows: Dim::new(rows).unwrap(),
                        cell_px: Some(CellPx::DEFAULT),
                    };
                    let id = self.rig.pane;
                    if let Some(((), events)) =
                        self.rig
                            .state
                            .call(&mut self.rig.poll, id, |pane, io| pane.resize(size, io))
                    {
                        self.rig.state.dispatch(&mut self.rig.poll, id, events);
                    }
                }
            }
            Op::Open(history, speed, small, bogus) => {
                if self.pane_open() {
                    self.open_view(
                        history,
                        speed,
                        small,
                        bogus.then_some(1 << 40),
                        Mirror::fresh(),
                    );
                }
            }
            Op::Resume(index, history, speed) => {
                if !self.retired.is_empty() && self.pane_open() {
                    let at = index % self.retired.len();
                    let mirror = self.retired.remove(at);
                    let offset = mirror.offset;
                    self.open_view(history, speed, true, offset, mirror);
                }
            }
            Op::Resync(index, history) => {
                if let Some(at) = self.live(index)
                    && !self.views[at].server_closed
                    && let Some(stream) = self.views[at].stream.as_mut()
                {
                    let text = protocol::json(&ViewRequest::Resync(ViewOptions {
                        history,
                        images: Images::None,
                    }));
                    let _ = stream.write_all(&masked(1, true, text.as_bytes(), [1, 2, 3, 4], 0));
                }
            }
            Op::ClearHistory => {
                if !self.crashed && self.pane_open() {
                    let id = self.rig.pane;
                    self.rig.state.clear_history(&mut self.rig.poll, id);
                }
            }
            Op::Reader(index, speed) => {
                if let Some(at) = self.live(index) {
                    self.views[at].speed = speed;
                }
            }
            Op::Close(index, who) => {
                if let Some(at) = self.live(index) {
                    self.views[at].expected_close = true;
                    if let Who::Server = who {
                        let token = self.views[at].token;
                        self.close_server_side(token);
                    }
                    let view = self.drop_view(at);
                    if view.mirror.term.is_some()
                        && view.mirror.offset.is_some()
                        && view.mirror.snapshot.is_none()
                    {
                        self.retired.push(view.mirror);
                    }
                }
            }
            Op::Eof => self.eof = true,
            Op::Crash => {
                if !self.crashed {
                    self.crashed = true;
                    for view in &mut self.views {
                        view.expected_close = true;
                    }
                    self.rig
                        .state
                        .panes
                        .find(self.rig.pane)
                        .map(|pane| pane.proc().kill())
                        .transpose()
                        .map_err(|error| Failure::Bug(format!("kill: {error}")))?;
                }
            }
            Op::Settle(count) => {
                for _ in 0..count {
                    self.tick()?;
                }
            }
            Op::Check => self.check()?,
        }
        Ok(())
    }
}

fn run(ops: &[Op]) -> Checked {
    let mut harness = Harness::new();
    harness.open_view(History::All, Reader::Fast, false, None, Mirror::fresh());
    for op in ops {
        harness.step_op(*op)?;
    }
    harness.step_op(Op::Check)
}

fn source() -> impl Strategy<Value = Source> {
    prop_oneof![
        3 => Just(Source::Lines),
        4 => Just(Source::Soup),
        3 => (0..7usize).prop_map(Source::Corpus),
        2 => Just(Source::Osc8),
        1 => Just(Source::Wide),
        1 => Just(Source::Kitty),
        1 => Just(Source::Alt),
        1 => Just(Source::Binary),
    ]
}

fn reader() -> impl Strategy<Value = Reader> {
    prop_oneof![
        4 => Just(Reader::Fast),
        2 => (0..=100usize).prop_map(|n| Reader::Slow(512 + n * 512)),
        2 => Just(Reader::Stalled),
    ]
}

fn history() -> impl Strategy<Value = History> {
    prop_oneof![Just(History::None), Just(History::All)]
}

fn op() -> impl Strategy<Value = Op> {
    let size = prop_oneof![6 => 1..2000usize, 3 => 2000..60000usize, 1 => 200_000..700_000usize];
    prop_oneof![
        10 => (source(), size, any::<u32>()).prop_map(|(s, n, seed)| Op::Feed(s, n, u64::from(seed))),
        3 => (1..=200u16, 1..=80u16).prop_map(|(c, r)| if c == 1 && r == 1 { Op::Resize(2, 1) } else { Op::Resize(c, r) }),
        3 => (history(), reader(), any::<bool>(), any::<bool>()).prop_map(|(h, s, small, bogus)| Op::Open(h, s, small, bogus)),
        2 => (any::<usize>(), history(), reader()).prop_map(|(i, h, s)| Op::Resume(i, h, s)),
        3 => (any::<usize>(), history()).prop_map(|(i, h)| Op::Resync(i, h)),
        2 => Just(Op::ClearHistory),
        3 => (any::<usize>(), reader()).prop_map(|(i, s)| Op::Reader(i, s)),
        2 => (any::<usize>(), prop_oneof![Just(Who::Client), Just(Who::Server)]).prop_map(|(i, w)| Op::Close(i, w)),
        1 => Just(Op::Eof),
        1 => Just(Op::Crash),
        3 => (1..=50usize).prop_map(Op::Settle),
        3 => Just(Op::Check),
    ]
}

fn cases() -> u32 {
    std::env::var("PROPTEST_CASES")
        .ok()
        .and_then(|cases| cases.parse().ok())
        .unwrap_or(20)
}

proptest! {
    #![proptest_config(ProptestConfig { cases: cases(), ..ProptestConfig::default() })]

    #[test]
    fn views_and_mirrors_stay_equal_to_the_pane_under_random_operations(
        ops in prop::collection::vec(op(), 3..25),
    ) {
        match run(&ops) {
            Ok(()) => {}
            Err(Failure::Libghostty) => {
                return Err(TestCaseError::reject("libghostty-vt cannot decode it"));
            }
            Err(Failure::Bug(message)) => return Err(TestCaseError::fail(message)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ko_pane_wire::frame::Limits;

    #[test]
    fn two_views_with_a_large_history_do_not_snapshot_each_other_forever() {
        let ops = [
            Op::Open(History::None, Reader::Slow(12800), false, false),
            Op::Open(History::All, Reader::Fast, false, true),
            Op::Feed(Source::Corpus(3), 419_233, 9265),
            Op::Feed(Source::Soup, 469, 7),
            Op::Resize(68, 36),
            Op::Feed(Source::Osc8, 517_456, 8),
        ];
        run(&ops).unwrap_or_else(|failure| panic!("{failure:?}"));
    }

    #[test]
    fn views_catch_up_after_a_resync_on_a_pane_that_ended() {
        let ops = [
            Op::Feed(Source::Lines, 200_000, 0),
            Op::Check,
            Op::Open(History::None, Reader::Fast, true, false),
            Op::Open(History::All, Reader::Stalled, true, true),
            Op::Resize(47, 18),
            Op::Eof,
            Op::Resync(11_701_215_242_529_412_516, History::All),
        ];
        run(&ops).unwrap_or_else(|failure| panic!("{failure:?}"));
    }

    #[test]
    fn clearing_the_history_leaves_every_mirror_equal_to_the_pane_and_without_history() {
        let mut h = Harness::new();
        h.open_view(History::All, Reader::Fast, false, None, Mirror::fresh());
        h.open_view(History::None, Reader::Fast, false, None, Mirror::fresh());
        h.step_op(Op::Feed(Source::Lines, 200_000, 3)).unwrap();
        h.step_op(Op::Check).unwrap();
        let history = |h: &Harness, view: usize| {
            let term = h.views[view].mirror.term.as_ref().unwrap();
            term.dump_history(Format::Plain).unwrap().len()
        };
        let before = history(&h, 0);
        assert!(before > 100_000, "{before}");
        h.step_op(Op::ClearHistory).unwrap();
        h.step_op(Op::Feed(Source::Lines, 2000, 4)).unwrap();
        h.step_op(Op::Check).unwrap();
        assert!(
            history(&h, 0) < before / 20,
            "{} of {before}",
            history(&h, 0)
        );
        assert!(
            history(&h, 1) < before / 20,
            "{} of {before}",
            history(&h, 1)
        );
    }

    #[test]
    fn a_live_view_and_a_view_opened_after_the_death_each_get_the_death_once() {
        let mut h = Harness::new();
        h.open_view(History::All, Reader::Fast, false, None, Mirror::fresh());
        h.step_op(Op::Feed(Source::Lines, 2000, 1)).unwrap();
        h.step_op(Op::Eof).unwrap();
        h.until("the pane to die", |h| h.pane_state() == "exited")
            .unwrap();
        h.open_view(History::All, Reader::Fast, false, None, Mirror::fresh());
        h.until("both views to see the death", |h| {
            h.stable >= 30
                && h.views
                    .iter()
                    .all(|v| v.mirror.deaths > 0 && h.converged(v))
        })
        .unwrap();
        let deaths: Vec<usize> = h.views.iter().map(|v| v.mirror.deaths).collect();
        assert_eq!(deaths, [1, 1]);
    }

    #[test]
    fn a_signal_while_a_screen_reply_waits_for_its_pipe_does_not_fail_the_pane() {
        let mut h = Harness::new();
        h.step_op(Op::Feed(Source::Lines, 300_000, 1)).unwrap();
        h.until("the pane to consume the feed", |h| {
            let fed = h.fed;
            h.unsent() == 0
                && h.rig
                    .state
                    .panes
                    .find_mut(h.rig.pane)
                    .and_then(|pane| pane.proc_mut().delivery_mut())
                    .and_then(|delivery| delivery.end_offset().ok())
                    .is_some_and(|end| end.get() == fed)
        })
        .unwrap();
        let receiver = h.request_screen(ScreenRows::Full);
        h.until("the screen request", |h| {
            h.rig
                .state
                .conns
                .iter()
                .any(|conn| matches!(conn.phase, Phase::Handling))
        })
        .unwrap();
        // ko-pane does not report that it is blocked writing the reply, and nothing reads the pipe now.
        std::thread::sleep(Duration::from_millis(100));
        h.eof = true;
        h.flush_feed();
        let mut response = None;
        h.until("the screen reply", |_| {
            if response.is_none() {
                response = receiver.try_recv().ok();
            }
            response.is_some()
        })
        .unwrap();
        let response = response.unwrap().unwrap();
        assert!(
            response.status == 200
                && response.body.len() > 200_000
                && !h.pane_state().starts_with("failed"),
            "screen {} with {} bytes, pane {}",
            response.status,
            response.body.len(),
            h.pane_state()
        );
    }

    fn limits() -> Limits {
        Limits {
            scrollback: ko_pane_wire::frame::Scrollback::Bounded {
                max_bytes: std::num::NonZeroUsize::new(1 << 30),
                max_lines: None,
            },
            ..DEFAULT_LIMITS
        }
    }

    fn terminal(cols: u16, rows: u16) -> Terminal {
        Terminal::new(Dim::new(cols).unwrap(), Dim::new(rows).unwrap(), limits()).unwrap()
    }

    fn resized(term: &mut Terminal, cols: u16, rows: u16) {
        let size = Size {
            cols: Dim::new(cols).unwrap(),
            rows: Dim::new(rows).unwrap(),
            cell_px: None,
        };
        term.resize(size).unwrap();
    }

    fn snapshot(term: &mut Terminal, screen: bool) -> Vec<u8> {
        let mut bytes = Vec::new();
        term.snapshot(screen, |piece| {
            bytes.extend_from_slice(piece);
            true
        })
        .unwrap();
        bytes
    }

    fn fixture(name: &str) -> Vec<u8> {
        std::fs::read(
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("testdata")
                .join(name),
        )
        .unwrap()
    }

    // This pins a libghostty-vt bug; it fails once the bug is fixed, and then the `Libghostty`
    // rejection in `Mirror::slice` can go.
    #[test]
    fn libghostty_vt_still_cannot_decode_a_snapshot_of_this_stream() {
        let stream = fixture("libghostty_decode.bin");
        let mut parts = [620, 45116, 463, 1860, 16010]
            .into_iter()
            .scan(0, |at, len| {
                let part = &stream[*at..*at + len];
                *at += len;
                Some(part)
            });
        let mut blank = terminal(68, 36);
        let first = snapshot(&mut blank, false);
        let mut term = Terminal::decode(&mut first.as_slice(), Extent::Full).unwrap();
        resized(&mut term, 167, 3);
        for _ in 0..3 {
            term.write(parts.next().unwrap());
        }
        resized(&mut term, 32, 66);
        resized(&mut term, 11, 47);
        for _ in 0..2 {
            term.write(parts.next().unwrap());
        }
        let mut screen = Vec::new();
        let outcome = term
            .snapshot(true, |piece| {
                screen.extend_from_slice(piece);
                true
            })
            .and_then(|()| Terminal::decode(&mut screen.as_slice(), Extent::Screen).map(drop));
        let error = outcome.unwrap_err();
        assert!(error.to_string().ends_with("(-2)"), "{error}");
    }

    // This pins a libghostty-vt bug as well.
    #[test]
    fn libghostty_vt_still_diverges_after_a_full_snapshot_of_a_1x1_terminal() {
        let stream = fixture("libghostty_diverge.bin");
        let (before, after) = stream.split_at(55893);
        let diverges = |cols, rows| {
            let mut live = terminal(80, 24);
            live.write(before);
            resized(&mut live, cols, rows);
            let first = snapshot(&mut live, false);
            let mut restored = Terminal::decode(&mut first.as_slice(), Extent::Full).unwrap();
            for term in [&mut live, &mut restored] {
                term.write(after);
                resized(term, 39, 9);
            }
            live.dump(Format::Plain).unwrap() != restored.dump(Format::Plain).unwrap()
        };
        assert!(diverges(1, 1));
        for (cols, rows) in [(2, 2), (1, 24), (80, 1), (1, 2)] {
            assert!(!diverges(cols, rows), "{cols}x{rows}");
        }
    }
}
