#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::indexing_slicing,
    clippy::arithmetic_side_effects
)]

use std::cell::RefCell;
use std::fmt::Debug;
use std::io::{Read, Write};
use std::os::fd::AsFd;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use ko_pane_wire::frame::Limits;
use ko_pane_wire::ring::Reader;
use ko_sys::event::{Events, Interest, Mode, Poll, Timer};
use ko_sys::pid::Pid;
use serde::Serialize;
use serde::de::DeserializeOwned;

use crate::config::DEFAULT_LIMITS;
use crate::http::{MAX_HEAD, Parsed, parse_head, request};
#[cfg(test)]
use crate::ids::PaneId;
use crate::pane_proc::{Cause, Event, Io, Life, PaneProc, discard};
use crate::protocol::{
    self, ClientRequest, Command, CreatePane, Input, Route, ViewRequest, version_headers,
};
use crate::server::Verified;
use crate::state::{State, Wake};

fn roundtrip<T: DeserializeOwned + Serialize + PartialEq + Debug>(data: &[u8]) {
    if let Ok(value) = protocol::decode::<T>(data) {
        let text = protocol::json(&value);
        let again = protocol::decode::<T>(text.as_bytes()).expect("an encoded value decodes");
        assert_eq!(value, again, "{text}");
    }
}

pub fn decode(data: &[u8]) {
    roundtrip::<CreatePane>(data);
    roundtrip::<ClientRequest>(data);
    roundtrip::<ViewRequest>(data);
    roundtrip::<Input>(data);
    let text = String::from_utf8_lossy(data);
    let (method, target) = text.split_once(' ').unwrap_or((&text, &text));
    if let Ok(Some(route)) = Route::of_request(method, target) {
        let (method, target) = route.to_request();
        assert_eq!(Route::of_request(method, &target), Ok(Some(route)));
    }
}

fn pieces<'a>(data: &'a [u8], cuts: &[usize]) -> Vec<&'a [u8]> {
    let mut pieces = Vec::new();
    let mut from = 0;
    for &cut in cuts {
        let cut = cut.clamp(from, data.len());
        pieces.push(&data[from..cut]);
        from = cut;
    }
    pieces.push(&data[from..]);
    pieces
}

fn settle(pieces: &[&[u8]]) -> Parsed {
    let mut buffer = Vec::new();
    let mut scanned = 0;
    let mut last = Parsed::Partial;
    for piece in pieces {
        buffer.extend_from_slice(piece);
        last = parse_head(&buffer, &mut scanned);
        if last != Parsed::Partial {
            if let Parsed::Complete { size, .. } = last {
                assert!(size <= MAX_HEAD && size <= buffer.len(), "head size {size}");
            }
            break;
        }
        assert!(
            buffer.len() < MAX_HEAD,
            "a partial head of {} bytes",
            buffer.len()
        );
    }
    last
}

fn same_head(a: &Parsed, b: &Parsed, len: usize) -> bool {
    match (a, b) {
        (Parsed::Complete { .. } | Parsed::Partial, _)
        | (_, Parsed::Complete { .. } | Parsed::Partial) => a == b,
        _ => len >= MAX_HEAD || a == b,
    }
}

pub fn head(data: &[u8]) {
    let Some((&count, rest)) = data.split_first() else {
        return;
    };
    let count = usize::from(count % 8);
    if rest.len() < count {
        return;
    }
    let (fractions, bytes) = rest.split_at(count);
    let mut cuts: Vec<usize> = fractions
        .iter()
        .map(|&fraction| usize::from(fraction) * bytes.len() / 256)
        .collect();
    cuts.sort_unstable();
    let whole = settle(&[bytes]);
    let cut = settle(&pieces(bytes, &cuts));
    assert!(
        same_head(&whole, &cut, bytes.len()),
        "{whole:?} against {cut:?}"
    );
    if let Parsed::Complete { head, .. } = &whole {
        let _ = head.framing();
    }
    if bytes.len() <= 20000 {
        let every: Vec<usize> = (1..bytes.len()).collect();
        let single = settle(&pieces(bytes, &every));
        assert!(
            same_head(&whole, &single, bytes.len()),
            "{whole:?} against {single:?}"
        );
    }
}

fn dead_pid() -> Option<Pid> {
    static PID: OnceLock<Option<Pid>> = OnceLock::new();
    *PID.get_or_init(|| {
        let child = ko_sys::spawn::program(Path::new("/usr/bin/true"), &[], &[]).ok()?;
        child.wait().ok()?;
        Some(child)
    })
}

#[derive(Debug, PartialEq, Eq)]
struct Effects {
    events: Vec<Event>,
    title: Vec<u8>,
    cwd: Vec<u8>,
    life: Life,
    cause: Option<Cause>,
    child: Option<Pid>,
    tail: Option<u64>,
}

fn run_frames(parts: &[&[u8]]) -> Option<Effects> {
    let ring = Reader::create(1 << 12).ok()?;
    let (socket, _peer) = UnixStream::pair().ok()?;
    socket.set_nonblocking(true).ok()?;
    let mut poll = Poll::new();
    let token = poll.watch(socket.as_fd(), Interest::Read);
    let mut proc = PaneProc::new(socket, token, ring, dead_pid()?, Path::new(""));
    let mut events = Vec::new();
    for part in parts {
        proc.feed(
            part,
            &mut Io {
                poll: &mut poll,
                events: &mut events,
                sink: &mut discard,
            },
        );
    }
    let events = events
        .into_iter()
        .map(|event| match event {
            Event::Dead(mut death) => {
                if matches!(death.cause, Cause::Failed(_)) {
                    death.at = ko_sys::clock::Mono::from_nanos(0);
                }
                Event::Dead(death)
            }
            other => other,
        })
        .collect();
    Some(Effects {
        events,
        title: proc.title().to_vec(),
        cwd: proc.cwd().to_vec(),
        life: proc.life(),
        cause: proc.dead().map(|death| death.cause.clone()),
        child: proc.child_pid(),
        tail: proc.ring().map(|ring| ring.tail().get()),
    })
}

pub fn frames(data: &[u8]) {
    let (Some(&high), Some(&low)) = (data.first(), data.get(1)) else {
        return;
    };
    let frames = &data[2..];
    let cut = (usize::from(high) << 8 | usize::from(low)) % (frames.len() + 1);
    let whole = run_frames(&[frames]);
    let split = run_frames(&[&frames[..cut], &frames[cut..]]);
    assert_eq!(whole, split, "cut at {cut}");
}

pub(crate) struct Rig {
    pub(crate) poll: Poll,
    pub(crate) state: State,
    #[cfg(test)]
    pub(crate) pane: PaneId,
    wake: Timer,
    events: Events,
    dir: PathBuf,
    reply: Vec<u8>,
    chunk: Vec<u8>,
}

impl Drop for Rig {
    fn drop(&mut self) {
        self.state.shutdown(&mut self.poll);
        let _ = self.state.panes.kill();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

impl Rig {
    pub(crate) fn new(dir: PathBuf, pane_exe: PathBuf, limits: Limits, command: &str) -> Rig {
        std::fs::create_dir_all(&dir).expect("the scratch directory");
        let mut poll = Poll::new();
        let mut state = State::new(
            crate::config::scratch(&dir, pane_exe, limits),
            &mut poll,
            Duration::from_millis(2),
        );
        let request = CreatePane {
            cwd: None,
            command: Some(Command::Argv(
                ["/bin/sh", "-c", command].map(str::to_owned).to_vec(),
            )),
            env: Vec::new(),
        };
        let pane = state
            .add_pane(&mut poll, &request)
            .unwrap_or_else(|error| panic!("the first pane did not start: {error}"));
        let wake = poll.timer();
        poll.start(
            wake,
            Duration::from_millis(20),
            Some(Duration::from_millis(20)),
        )
        .expect("the wake timer");
        let mut rig = Rig {
            poll,
            state,
            #[cfg(test)]
            pane,
            wake,
            events: Events::default(),
            dir,
            reply: Vec::new(),
            chunk: vec![0; 65536],
        };
        let deadline = Instant::now() + Duration::from_secs(5);
        while rig
            .state
            .panes
            .find(pane)
            .is_none_or(|pane| pane.proc().child_pid().is_none())
        {
            assert!(
                Instant::now() < deadline,
                "the first pane never became ready"
            );
            rig.step(Mode::Wait);
        }
        rig
    }

    #[cfg(test)]
    pub(crate) fn dir(&self) -> &Path {
        &self.dir
    }

    pub(crate) fn step(&mut self, mode: Mode) {
        let wake = self.wake;
        let mut events = std::mem::take(&mut self.events);
        self.state
            .turn(&mut self.poll, mode, &mut events, |_, _, own| {
                Ok(matches!(own, Wake::Due(timer) if timer == wake))
            })
            .expect("a loop turn");
        self.events = events;
        self.state.reap(&mut self.poll).expect("the reap");
    }

    pub(crate) fn exchange(&mut self, data: &[u8]) -> &[u8] {
        let (ours, mut theirs) = UnixStream::pair().unwrap();
        theirs.set_nonblocking(true).unwrap();
        let admitted = Verified::admit(ours).expect("an admitted stream");
        self.state.accept(&mut self.poll, admitted);
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut sent = 0;
        let mut shut = false;
        self.reply.clear();
        loop {
            assert!(
                Instant::now() < deadline,
                "no close within 5 s after {:?}",
                String::from_utf8_lossy(data)
            );
            let mut progress = false;
            if !shut {
                match theirs.write(&data[sent..]) {
                    Ok(count) => {
                        progress = count > 0;
                        sent += count;
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
                    Err(_) => shut = true,
                }
                if sent == data.len() {
                    let _ = theirs.shutdown(std::net::Shutdown::Write);
                    shut = true;
                }
            }
            match theirs.read(&mut self.chunk) {
                Ok(0) => break,
                Ok(count) => {
                    progress = true;
                    self.reply.extend_from_slice(&self.chunk[..count]);
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
                Err(_) => break,
            }
            self.step(if progress { Mode::Peek } else { Mode::Wait });
        }
        self.step(Mode::Peek);
        &self.reply
    }

    pub(crate) fn version_probe(&mut self) -> Vec<u16> {
        let mut headers: Vec<(&str, String)> = version_headers().to_vec();
        headers.push(("host", "ko".to_owned()));
        let headers: Vec<(&str, &str)> = headers
            .iter()
            .map(|(name, value)| (*name, value.as_str()))
            .collect();
        let probe = request("GET", "/version", &headers, b"");
        statuses(self.exchange(&probe))
    }
}

fn statuses(mut reply: &[u8]) -> Vec<u16> {
    let mut found = Vec::new();
    while let Some(line) = reply.strip_prefix(b"HTTP/1.1 ") {
        let Some(status) = line
            .get(..3)
            .and_then(|code| std::str::from_utf8(code).ok())
        else {
            break;
        };
        let Ok(status) = status.parse::<u16>() else {
            break;
        };
        found.push(status);
        let Some(end) = reply.windows(4).position(|window| window == b"\r\n\r\n") else {
            break;
        };
        let head = String::from_utf8_lossy(&reply[..end]).to_ascii_lowercase();
        let body = &reply[end + 4..];
        if status == 101 {
            break;
        }
        let skip = if head.contains("transfer-encoding: chunked") {
            match body.windows(5).position(|window| window == b"0\r\n\r\n") {
                Some(last) => last + 5,
                None => break,
            }
        } else {
            head.split("content-length: ")
                .nth(1)
                .and_then(|rest| rest.split("\r\n").next()?.trim().parse().ok())
                .unwrap_or(0)
        };
        let Some(rest) = body.get(skip..) else {
            break;
        };
        reply = rest;
    }
    found
}

thread_local! {
    static RIG: RefCell<Option<Rig>> = const { RefCell::new(None) };
}

fn with_rig<T>(f: impl FnOnce(&mut Rig) -> T) -> T {
    RIG.with_borrow_mut(|slot| {
        f(slot.get_or_insert_with(|| {
            let exe = std::env::var_os("KO_PANE_EXE")
                .expect("KO_PANE_EXE names the Rust ko-pane; fuzz.sh and make test-ko set it");
            let dir = PathBuf::from(format!("/tmp/ko-fuzz-http-{}", std::process::id()));
            let mut rig = Rig::new(
                dir,
                PathBuf::from(exe),
                DEFAULT_LIMITS,
                "stty raw -echo; exec cat",
            );
            // A later pane is never a real program: a fuzzed request must not run a command.
            rig.state.config.pane_exe = PathBuf::from("/usr/bin/true");
            rig
        }))
    })
}

pub fn http(data: &[u8]) {
    with_rig(|rig| {
        let reply = rig.exchange(data);
        assert!(
            statuses(reply).iter().all(|status| *status < 500),
            "server error for {:?}: {:?}",
            String::from_utf8_lossy(data),
            String::from_utf8_lossy(reply)
        );
        assert_eq!(rig.version_probe(), [200], "the server is unhealthy");
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn replay(target: &str, run: fn(&[u8])) -> usize {
        let corpus = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../fuzz/corpus")
            .join(target);
        let mut replayed = 0;
        for entry in std::fs::read_dir(corpus).unwrap() {
            run(&std::fs::read(entry.unwrap().path()).unwrap());
            replayed += 1;
        }
        replayed
    }

    #[test]
    fn pipelined_requests_are_answered_in_order_and_a_long_head_gets_431_after_them() {
        let mut headers: Vec<(&str, String)> = version_headers().to_vec();
        headers.push(("host", "ko".to_owned()));
        headers.push(("x", "a".repeat(MAX_HEAD)));
        let headers: Vec<(&str, &str)> = headers.iter().map(|(n, v)| (*n, v.as_str())).collect();
        let short = &headers[..3];
        let input = [
            request("GET", "/version", short, b""),
            request("GET", "/nothing", short, b""),
            request("GET", "/version", &headers, b""),
        ]
        .concat();
        let found = with_rig(|rig| statuses(rig.exchange(&input)));
        assert_eq!(found, [200, 404, 431]);
    }

    #[test]
    fn the_replayed_corpora_run_to_the_end() {
        assert!(
            std::env::var_os("KO_PANE_EXE").is_some(),
            "make test-ko sets KO_PANE_EXE"
        );
        let replayed = [
            replay("decode", decode),
            replay("head", head),
            replay("frames", frames),
            replay("http", http),
        ];
        assert!(replayed.iter().all(|&count| count >= 4), "{replayed:?}");
    }
}
