#![deny(clippy::indexing_slicing, clippy::arithmetic_side_effects)]

use std::collections::BTreeMap;
use std::fmt;
use std::io;
use std::os::fd::AsFd;
use std::os::unix::net::UnixStream;
use std::path::Path;

use ko_pane_wire::frame::{
    self, FromPane, History, Init, Key, MAX_FRAME_BYTES, Malformed, Mouse, Oversize, Req,
    ScreenFormat, ScreenRows, Size, ToPane,
};
use ko_pane_wire::ring::Pos;
use ko_sys::clock::Mono;
use ko_sys::event::{Interest, Poll, Read, Reads, Ready, Token};
use ko_sys::fd::Queue;
use ko_sys::pid::{Exit, Group, Pid, Verdict, Waited};
use ko_sys::signal::Signal;

use crate::config::Config;
use crate::delivery::{self, Delivery, Done, Handle, Stamps};
use crate::ids::PaneId;

const RING_CAPACITY: u64 = 1 << 20;
const INPUT: usize = 65536;
const MAX_INPUT: usize = MAX_FRAME_BYTES;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Life {
    Open,
    Closed,
    Reaped,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Cause {
    Exit(Exit),
    Failed(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Death {
    pub(crate) at: Mono,
    pub(crate) cause: Cause,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Event {
    Title,
    Pwd,
    Output,
    Dead(Death),
    Snapshot(Done),
    Screen {
        req: Req,
        chunk: Vec<u8>,
        last: bool,
    },
    Pasted {
        req: Req,
        pasted: bool,
        unsafe_paste: bool,
    },
    Failed {
        req: Req,
        message: String,
    },
}

#[derive(Debug, Clone, Copy)]
pub(crate) enum Input<'a> {
    Key(&'a Key),
    Mouse(Mouse),
    Paste { text: &'a str, check_safe: bool },
    Text(&'a [u8]),
    Focus(bool),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Refusal {
    Ended,
    TooLarge(Oversize),
}

impl fmt::Display for Refusal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Refusal::Ended => f.write_str("pane process ended"),
            Refusal::TooLarge(oversize) => oversize.fmt(f),
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
enum Fault {
    Delivery(delivery::Fault),
    Frame(Malformed),
    Ready,
    Closed,
    TooLarge,
    Pane(String),
    Ended(Exit),
}

impl fmt::Display for Fault {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Fault::Delivery(fault) => fault.fmt(f),
            Fault::Frame(malformed) => malformed.fmt(f),
            Fault::Ready => f.write_str("invalid ready"),
            Fault::Closed => f.write_str("pane control socket closed"),
            Fault::TooLarge => f.write_str("control frame too large"),
            Fault::Pane(message) => f.write_str(message),
            Fault::Ended(Exit::Exited(status)) => {
                write!(f, "pane process exited unexpectedly with status {status}")
            }
            Fault::Ended(Exit::Signaled(signal)) => {
                write!(f, "pane process ended unexpectedly by signal {signal}")
            }
        }
    }
}

impl From<delivery::Fault> for Fault {
    fn from(fault: delivery::Fault) -> Fault {
        Fault::Delivery(fault)
    }
}

impl From<Malformed> for Fault {
    fn from(malformed: Malformed) -> Fault {
        Fault::Frame(malformed)
    }
}

pub(crate) type Sink<'a> = &'a mut dyn FnMut(Handle<'_>);

pub(crate) fn discard(_: Handle<'_>) {}

pub(crate) struct Io<'a> {
    pub(crate) poll: &'a mut Poll,
    pub(crate) events: &'a mut Vec<Event>,
    pub(crate) sink: Sink<'a>,
}

impl fmt::Debug for Io<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Io")
            .field("poll", &self.poll)
            .field("events", &self.events)
            .finish_non_exhaustive()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Claim {
    Awaiting,
    Reported(Option<Group>),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Reply {
    Screen,
    Paste,
}

#[derive(Debug)]
enum Stage {
    Open {
        socket: UnixStream,
        token: Token,
        delivery: Delivery,
    },
    Closed {
        delivery: Delivery,
    },
    Reaped,
}

impl Stage {
    fn delivery_mut(&mut self) -> Option<&mut Delivery> {
        match self {
            Stage::Open { delivery, .. } | Stage::Closed { delivery } => Some(delivery),
            Stage::Reaped => None,
        }
    }
}

#[derive(Debug)]
pub(crate) struct PaneProc {
    stage: Stage,
    out: Queue,
    pid: Pid,
    child: Claim,
    title: Vec<u8>,
    cwd: Vec<u8>,
    dead: Option<Death>,
    input: Vec<u8>,
    filled: usize,
    pending: BTreeMap<Req, Reply>,
    observed: Pos,
    busy: bool,
}

fn store(text: &mut Vec<u8>, value: &[u8]) -> bool {
    let changed = text.as_slice() != value;
    if changed {
        text.clear();
        text.extend_from_slice(value);
    }
    changed
}

impl PaneProc {
    pub(crate) fn spawn(
        config: &Config,
        id: PaneId,
        cwd: &Path,
        argv: &[Vec<u8>],
        env: &[Vec<u8>],
        stamps: &mut Stamps,
        io: &mut Io<'_>,
    ) -> io::Result<PaneProc> {
        let mut out = Vec::new();
        let id = id.to_string();
        let init = Init {
            size: Size::DEFAULT,
            limits: config.limits,
            media: (&config.media[..]).into(),
            cwd: cwd.into(),
            argv: argv.into(),
            env: env.into(),
            id: id.as_str().into(),
        };
        frame::encode(&ToPane::Init(&init), &mut out).map_err(|oversize| {
            io::Error::new(io::ErrorKind::InvalidInput, oversize.to_string())
        })?;
        let delivery = Delivery::create(stamps, RING_CAPACITY)?;
        let (socket, theirs) = UnixStream::pair()?;
        let pid = ko_sys::spawn::pane(&config.pane_exe, theirs.as_fd(), delivery.ring().fd())?;
        drop(theirs);
        socket.set_nonblocking(true)?;
        let token = io.poll.watch(socket.as_fd(), Interest::Read);
        let mut proc = PaneProc::new(socket, token, delivery, pid, cwd);
        proc.out.bytes = out;
        proc.flush(io);
        Ok(proc)
    }

    pub(crate) fn new(
        socket: UnixStream,
        token: Token,
        delivery: Delivery,
        pid: Pid,
        cwd: &Path,
    ) -> PaneProc {
        let start = delivery.ring().tail();
        PaneProc {
            stage: Stage::Open {
                socket,
                token,
                delivery,
            },
            out: Queue::default(),
            pid,
            child: Claim::Awaiting,
            title: Vec::new(),
            cwd: cwd.as_os_str().as_encoded_bytes().to_vec(),
            dead: None,
            input: vec![0; INPUT],
            filled: 0,
            pending: BTreeMap::new(),
            observed: start,
            busy: false,
        }
    }

    pub(crate) fn life(&self) -> Life {
        match self.stage {
            Stage::Open { .. } => Life::Open,
            Stage::Closed { .. } => Life::Closed,
            Stage::Reaped => Life::Reaped,
        }
    }

    fn is_open(&self) -> bool {
        matches!(self.stage, Stage::Open { .. })
    }

    pub(crate) fn token(&self) -> Option<Token> {
        match self.stage {
            Stage::Open { token, .. } => Some(token),
            Stage::Closed { .. } | Stage::Reaped => None,
        }
    }

    pub(crate) fn delivery(&self) -> Option<&Delivery> {
        match &self.stage {
            Stage::Open { delivery, .. } | Stage::Closed { delivery } => Some(delivery),
            Stage::Reaped => None,
        }
    }

    pub(crate) fn delivery_mut(&mut self) -> Option<&mut Delivery> {
        self.stage.delivery_mut()
    }

    pub(crate) fn child_pid(&self) -> Option<Pid> {
        match self.child {
            Claim::Reported(Some(group)) => Some(group.leader()),
            Claim::Awaiting | Claim::Reported(None) => None,
        }
    }

    pub(crate) fn title(&self) -> &[u8] {
        &self.title
    }

    pub(crate) fn cwd(&self) -> &[u8] {
        &self.cwd
    }

    pub(crate) fn dead(&self) -> Option<&Death> {
        self.dead.as_ref()
    }

    pub(crate) fn busy(&self) -> bool {
        self.busy
    }

    fn kill_group(&self) {
        if let Claim::Reported(Some(group)) = self.child {
            let _ = group.signal(Signal::Kill);
        }
    }

    fn die(&mut self, death: Death, io: &mut Io<'_>) {
        if let Cause::Failed(_) = death.cause {
            self.kill_group();
        }
        self.dead = Some(death.clone());
        io.events.push(Event::Dead(death));
    }

    fn close(&mut self, io: &mut Io<'_>) {
        let stage = std::mem::replace(&mut self.stage, Stage::Reaped);
        self.stage = match stage {
            Stage::Open {
                token, delivery, ..
            } => {
                io.poll.unwatch(token);
                Stage::Closed { delivery }
            }
            other => other,
        };
    }

    fn fail_pending(&mut self, message: &str, io: &mut Io<'_>) {
        let snapshots = self
            .stage
            .delivery_mut()
            .map(Delivery::fail_all)
            .unwrap_or_default();
        io.events.extend(snapshots.into_iter().map(Event::Snapshot));
        io.events.extend(
            std::mem::take(&mut self.pending)
                .into_keys()
                .map(|req| Event::Failed {
                    req,
                    message: message.to_owned(),
                }),
        );
    }

    fn failure(&mut self, fault: Fault, io: &mut Io<'_>) {
        if self.is_open() {
            let message = fault.to_string();
            self.close(io);
            self.fail_pending(&message, io);
            let death = Death {
                at: Mono::now(),
                cause: Cause::Failed(message),
            };
            self.die(death, io);
        }
    }

    fn flush(&mut self, io: &mut Io<'_>) {
        let Stage::Open { socket, token, .. } = &self.stage else {
            return;
        };
        let token = *token;
        let failed = self.out.flush(socket.as_fd()).is_err();
        if self.out.sent_past_half() {
            self.out.compact();
        }
        if failed {
            self.failure(Fault::Closed, io);
        } else {
            io.poll
                .interest(token, Interest::of(true, !self.out.is_empty()));
        }
    }

    fn send(&mut self, frame: &ToPane<'_>, io: &mut Io<'_>) -> Result<(), Oversize> {
        if self.is_open() {
            let idle = self.out.is_empty();
            frame::encode(frame, &mut self.out.bytes)?;
            if idle {
                self.flush(io);
            }
        }
        Ok(())
    }

    fn mint(&mut self) -> Option<Req> {
        self.stage.delivery_mut()?.mint_serial().map(|(_, req)| req)
    }

    fn scan_ring(&mut self, io: &mut Io<'_>) -> Result<bool, Fault> {
        let Some(delivery) = self.stage.delivery_mut() else {
            return Ok(false);
        };
        let head = delivery.scan(&mut io.sink)?;
        let changed = head != self.observed;
        self.observed = head;
        self.busy = changed;
        Ok(changed)
    }

    pub(crate) fn scan(&mut self, io: &mut Io<'_>) -> bool {
        if !self.is_open() {
            return false;
        }
        match self.scan_ring(io) {
            Ok(changed) => changed,
            Err(fault) => {
                self.failure(fault, io);
                false
            }
        }
    }

    fn snapshot_done(&mut self, req: Req, io: &mut Io<'_>) {
        let done = self
            .stage
            .delivery_mut()
            .and_then(|delivery| delivery.snapshot_done(req));
        io.events.extend(done.map(Event::Snapshot));
    }

    pub(crate) fn snapshot(&mut self, history: History, io: &mut Io<'_>) -> Option<(u64, Req)> {
        if !self.is_open() {
            return None;
        }
        let (serial, req) = self.stage.delivery_mut()?.request()?;
        let _ = self.send(&ToPane::Snapshot { req, history }, io);
        self.is_open().then_some((serial, req))
    }

    pub(crate) fn screen(
        &mut self,
        format: ScreenFormat,
        rows: ScreenRows,
        io: &mut Io<'_>,
    ) -> Option<Req> {
        let req = self.mint().filter(|_| self.is_open())?;
        self.pending.insert(req, Reply::Screen);
        let _ = self.send(&ToPane::Screen { req, format, rows }, io);
        Some(req)
    }

    pub(crate) fn input(
        &mut self,
        input: Input<'_>,
        io: &mut Io<'_>,
    ) -> Result<Option<Req>, Refusal> {
        if !self.is_open() {
            return Err(Refusal::Ended);
        }
        let (frame, req) = match input {
            Input::Paste { text, check_safe } => {
                let req = self.mint().ok_or(Refusal::Ended)?;
                self.pending.insert(req, Reply::Paste);
                let paste = ToPane::Paste {
                    req,
                    text,
                    check_safe,
                };
                (paste, Some(req))
            }
            Input::Key(key) => (ToPane::Key(key), None),
            Input::Mouse(mouse) => (ToPane::Mouse(mouse), None),
            Input::Text(text) => (ToPane::Text(text), None),
            Input::Focus(focused) => (ToPane::Focus(focused), None),
        };
        self.send(&frame, io).map_err(|oversize| {
            if let Some(req) = req {
                self.pending.remove(&req);
            }
            Refusal::TooLarge(oversize)
        })?;
        Ok(req)
    }

    pub(crate) fn resize(&mut self, size: Size, io: &mut Io<'_>) {
        let _ = self.send(&ToPane::Resize(size), io);
    }

    pub(crate) fn ready(&mut self, ready: Ready, io: &mut Io<'_>) {
        let ready = io.poll.wants(ready);
        if ready.read {
            self.read(io);
        }
        if ready.write {
            self.flush(io);
        }
    }

    fn read(&mut self, io: &mut Io<'_>) {
        let mut reads = Reads::new();
        loop {
            if self.filled == self.input.len() {
                if self.input.len() >= MAX_INPUT {
                    self.failure(Fault::TooLarge, io);
                    return;
                }
                let grown = self.input.len().saturating_mul(2).min(MAX_INPUT);
                self.input.resize(grown, 0);
            }
            let Stage::Open { socket, token, .. } = &self.stage else {
                return;
            };
            let Some(window) = self.input.get_mut(self.filled..) else {
                return;
            };
            match io.poll.read(*token, socket.as_fd(), window, &mut reads) {
                Ok(None) => return,
                Ok(Some(Read::Data(count))) => {
                    self.filled = self.filled.saturating_add(count);
                    self.consume(io);
                }
                Ok(Some(Read::End)) | Err(_) => {
                    self.failure(Fault::Closed, io);
                    return;
                }
            }
        }
    }

    fn consume(&mut self, io: &mut Io<'_>) {
        let input = std::mem::take(&mut self.input);
        let mut pos = 0;
        while self.is_open() {
            let Some(rest) = input.get(pos..self.filled) else {
                break;
            };
            match frame::frame_size(rest) {
                Ok(None) => break,
                Ok(Some(size)) => {
                    let frame = rest.get(..size).unwrap_or_default();
                    pos = pos.saturating_add(size);
                    if let Err(fault) = self.on_frame(frame, io) {
                        self.failure(fault, io);
                    }
                }
                Err(malformed) => self.failure(malformed.into(), io),
            }
        }
        self.input = input;
        if pos > 0 {
            self.input.copy_within(pos..self.filled, 0);
            self.filled = self.filled.saturating_sub(pos);
        }
        if self.input.len() > INPUT && self.filled <= INPUT {
            self.input.truncate(INPUT);
            self.input.shrink_to_fit();
        }
    }

    fn deliver_now(&mut self, io: &mut Io<'_>) -> Result<(), Fault> {
        match self.stage.delivery_mut() {
            Some(delivery) => Ok(delivery.deliver_now(&mut io.sink)?),
            None => Ok(()),
        }
    }

    fn on_frame(&mut self, frame: &[u8], io: &mut Io<'_>) -> Result<(), Fault> {
        let Some(frame) = frame::decode(frame)? else {
            return Ok(());
        };
        match frame {
            FromPane::Ready(raw) => {
                self.child = match (self.child, Group::verify(self.pid, raw)) {
                    (Claim::Awaiting, Verdict::Gone) => Claim::Reported(None),
                    (Claim::Awaiting, Verdict::Child(group)) => Claim::Reported(Some(group)),
                    _ => return Err(Fault::Ready),
                };
            }
            FromPane::Title(title) => {
                if store(&mut self.title, title) {
                    io.events.push(Event::Title);
                }
            }
            FromPane::Pwd(cwd) => {
                if store(&mut self.cwd, cwd) {
                    io.events.push(Event::Pwd);
                }
            }
            FromPane::Head(_) => io.events.push(Event::Output),
            FromPane::Dead(dead) => {
                let death = Death {
                    at: dead.at,
                    cause: Cause::Exit(dead.exit),
                };
                self.die(death, io);
            }
            FromPane::Full(_) => {
                self.scan(io);
                if let Some(tail) = self.delivery().map(|delivery| delivery.ring().tail()) {
                    let _ = self.send(&ToPane::Tail(tail), io);
                }
                io.events.push(Event::Output);
            }
            FromPane::SnapshotDone(req) => {
                self.deliver_now(io)?;
                self.snapshot_done(req, io);
            }
            FromPane::PasteDone {
                req,
                pasted,
                unsafe_paste,
            } => {
                self.deliver_now(io)?;
                if self.pending.get(&req) == Some(&Reply::Paste) {
                    self.pending.remove(&req);
                    io.events.push(Event::Pasted {
                        req,
                        pasted,
                        unsafe_paste,
                    });
                }
            }
            FromPane::Screen { req, last, text } => {
                self.deliver_now(io)?;
                if self.pending.get(&req) == Some(&Reply::Screen) {
                    if last {
                        self.pending.remove(&req);
                    }
                    io.events.push(Event::Screen {
                        req,
                        chunk: text.to_vec(),
                        last,
                    });
                }
            }
            FromPane::Error(message) => {
                return Err(Fault::Pane(String::from_utf8_lossy(message).into_owned()));
            }
        }
        Ok(())
    }

    pub(crate) fn shutdown(&mut self, io: &mut Io<'_>) {
        if self.is_open() {
            let _ = self.send(&ToPane::Exit, io);
            self.close(io);
            self.fail_pending("pane removed", io);
        }
    }

    pub(crate) fn reap(&mut self, io: &mut Io<'_>) -> io::Result<()> {
        if self.life() == Life::Reaped {
            return Ok(());
        }
        match self.pid.try_wait()? {
            Waited::Running => return Ok(()),
            Waited::Ended(exit) => self.failure(Fault::Ended(exit), io),
            Waited::NoChild => {}
        }
        self.close(io);
        self.stage = Stage::Reaped;
        Ok(())
    }

    #[cfg(any(test, feature = "fuzz"))]
    pub(crate) fn feed(&mut self, data: &[u8], io: &mut Io<'_>) {
        let end = self.filled.saturating_add(data.len());
        if self.input.len() < end {
            self.input.resize(end, 0);
        }
        if let Some(room) = self.input.get_mut(self.filled..end) {
            room.copy_from_slice(data);
        }
        self.filled = end;
        self.consume(io);
    }

    pub(crate) fn kill(&self) -> io::Result<()> {
        if self.life() != Life::Reaped {
            self.pid.signal(Signal::Kill)?;
        }
        self.kill_group();
        Ok(())
    }
}

#[cfg(test)]
#[allow(clippy::arithmetic_side_effects)]
mod tests {
    use super::*;
    use ko_pane_wire::frame::Kind;
    use ko_pane_wire::ring::{Commit, RecordKind, Writer};
    use ko_sys::event::{Events, Mode};
    use proptest::prelude::*;
    use std::io::Write;
    use std::sync::OnceLock;

    fn unsignalled_pid() -> Pid {
        static PID: OnceLock<Pid> = OnceLock::new();
        *PID.get_or_init(|| {
            let child = ko_sys::spawn::program(
                Path::new("/usr/bin/true"),
                &[],
                &[],
                ko_sys::spawn::Env::Inherit,
            )
            .unwrap();
            child.wait().unwrap();
            child
        })
    }

    #[derive(Debug)]
    struct Fake {
        proc: PaneProc,
        writer: Writer,
        peer: UnixStream,
        poll: Poll,
        events: Vec<Event>,
        slices: Vec<(u64, u64)>,
    }

    fn fake(capacity: u64) -> Fake {
        let delivery = Delivery::create(&mut delivery::mint_stamps(), capacity).unwrap();
        let writer = delivery.ring().writer().unwrap();
        let (socket, peer) = UnixStream::pair().unwrap();
        socket.set_nonblocking(true).unwrap();
        let mut poll = Poll::new();
        let token = poll.watch(socket.as_fd(), Interest::Read);
        let proc = PaneProc::new(socket, token, delivery, unsignalled_pid(), Path::new(""));
        Fake {
            proc,
            writer,
            peer,
            poll,
            events: Vec::new(),
            slices: Vec::new(),
        }
    }

    impl Fake {
        fn with<R>(&mut self, f: impl FnOnce(&mut PaneProc, &mut Io<'_>) -> R) -> R {
            let slices = &mut self.slices;
            let mut slice = |handle: Handle<'_>| slices.push((handle.serial(), handle.pos().get()));
            let mut io = Io {
                poll: &mut self.poll,
                events: &mut self.events,
                sink: &mut slice,
            };
            f(&mut self.proc, &mut io)
        }

        // macOS posix_spawn in another thread holds every descriptor until it execs, so a
        // closed peer can stay open for a moment.
        fn hang_up(&mut self) {
            drop(std::mem::replace(
                &mut self.peer,
                UnixStream::pair().unwrap().0,
            ));
            let timeout = self.poll.timer();
            self.poll
                .start(timeout, std::time::Duration::from_secs(5), None)
                .unwrap();
            let mut events = Events::default();
            while events.ready().is_empty() {
                assert!(events.due().is_empty(), "the peer never hung up");
                self.poll.turn(Mode::Wait, &mut events).unwrap();
            }
            self.poll.free(timeout);
        }

        fn feed(&mut self, data: &[u8]) {
            self.with(|proc, io| proc.feed(data, io));
        }

        fn scan(&mut self) -> bool {
            self.with(|proc, io| proc.scan(io))
        }

        fn slice(&mut self, first: bool, last: bool) -> u64 {
            let mut body = vec![0; 100];
            body[0] = u8::from(first) | (u8::from(last) << 1);
            self.writer.available();
            assert_ne!(self.writer.put(RecordKind::Slice, &body), Commit::Refused);
            self.proc.delivery_mut().unwrap().head().get()
        }

        fn tail(&self) -> u64 {
            self.proc.delivery().unwrap().ring().tail().get()
        }
    }

    fn frame(kind: Kind, body: &[u8]) -> Vec<u8> {
        frame_code(kind as u8, body)
    }

    fn frame_code(code: u8, body: &[u8]) -> Vec<u8> {
        let mut frame = u32::try_from(body.len() + 1)
            .unwrap()
            .to_le_bytes()
            .to_vec();
        frame.push(code);
        frame.extend_from_slice(body);
        frame
    }

    fn string(text: &[u8]) -> Vec<u8> {
        [&u32::try_from(text.len()).unwrap().to_le_bytes()[..], text].concat()
    }

    fn req(n: u32) -> Vec<u8> {
        n.to_le_bytes().to_vec()
    }

    #[test]
    fn events_fire_once_per_change_of_the_stored_title() {
        let mut fake = fake(64);
        let title = |text: &str| frame(Kind::Title, &string(text.as_bytes()));
        let report = |fake: &mut Fake, data: &[u8]| {
            fake.feed(data);
            let events = fake.events.len();
            fake.events.clear();
            (
                events,
                String::from_utf8(fake.proc.title().to_vec()).unwrap(),
            )
        };
        let aba = [title("A"), title("B"), title("A")].concat();
        assert_eq!(report(&mut fake, &aba), (3, "A".to_owned()));
        let aaa = [title("A"), title("A"), title("A")].concat();
        assert_eq!(report(&mut fake, &aaa), (0, "A".to_owned()));
        let split = title("split title");
        assert_eq!(report(&mut fake, &split[..7]), (0, "A".to_owned()));
        assert_eq!(
            report(&mut fake, &split[7..]),
            (1, "split title".to_owned())
        );
    }

    #[test]
    fn the_tail_never_passes_snapshot_slices_that_were_not_delivered() {
        let mut fake = fake(2048);
        let (asked, _) = fake
            .with(|proc, io| proc.snapshot(History::None, io))
            .unwrap();
        let ends: Vec<u64> = (0..3).map(|i| fake.slice(i == 0, false)).collect();
        let Fake {
            proc,
            writer,
            poll,
            events,
            slices,
            ..
        } = &mut fake;
        let mut slice = |handle: Handle<'_>| {
            if slices.is_empty() {
                for i in 3..15 {
                    let mut body = vec![0; 100];
                    body[0] = u8::from(i == 14) << 1;
                    writer.available();
                    writer.put(RecordKind::Slice, &body);
                }
            }
            slices.push((handle.serial(), handle.pos().get()));
        };
        let mut io = Io {
            poll,
            events,
            sink: &mut slice,
        };
        proc.scan(&mut io);
        let tail = proc.delivery().unwrap().ring().tail().get();
        assert_eq!((slices.len(), tail > ends[2]), (3, false));
        fake.scan();
        let expected: Vec<(u64, u64)> = (0..15).map(|i| (asked, i * 113)).collect();
        assert_eq!(fake.slices, expected);
    }

    #[test]
    fn a_finished_snapshot_keeps_its_cursor_in_the_ring_until_its_snapshot_done() {
        let mut fake = fake(2048);
        let (first, _) = fake
            .with(|proc, io| proc.snapshot(History::None, io))
            .unwrap();
        let (second, _) = fake
            .with(|proc, io| proc.snapshot(History::None, io))
            .unwrap();
        for i in 0..3 {
            fake.slice(i == 0, i == 2);
        }
        fake.writer.available();
        fake.writer.put(RecordKind::Bytes, &[0; 100]);
        for i in 0..14 {
            fake.slice(i == 0, false);
        }
        fake.scan();
        let cursor = fake
            .slices
            .iter()
            .filter(|(req, _)| *req == first)
            .map(|&(_, pos)| pos + 113)
            .max();
        assert_eq!(cursor, Some(339));
        assert!(fake.slices.iter().any(|(req, _)| *req == second));
        fake.feed(&frame(Kind::SnapshotDone, &req(1)));
        let [Event::Snapshot(done)] = &fake.events[..] else {
            panic!("{:?}", fake.events);
        };
        assert_eq!(
            (done.serial(), done.hold().map(Pos::get)),
            (first, Some(339))
        );
        assert_eq!(fake.tail(), 339);
    }

    #[test]
    fn a_snapshot_asked_for_from_a_snapshots_done_event_gets_the_slices_after_it() {
        let mut fake = fake(2048);
        let (first, _) = fake
            .with(|proc, io| proc.snapshot(History::None, io))
            .unwrap();
        let mut log = Vec::new();
        let mut second = None;
        let write =
            |fake: &mut Fake, log: &mut Vec<String>, done: u32, second: &mut Option<u64>| {
                fake.slice(true, false);
                fake.slice(false, true);
                fake.scan();
                fake.feed(&frame(Kind::SnapshotDone, &req(done)));
                for (req, pos) in fake.slices.drain(..) {
                    let name = if req == first { "A" } else { "B" };
                    log.push(format!("{name} slice {pos}"));
                }
                for event in std::mem::take(&mut fake.events) {
                    if let Event::Snapshot(done) = event {
                        let name = if done.serial() == first { "A" } else { "B" };
                        log.push(format!("{name} {}", done.hold().is_some()));
                        if done.serial() == first {
                            *second = fake
                                .with(|proc, io| proc.snapshot(History::None, io))
                                .map(|(serial, _)| serial);
                        }
                    }
                }
            };
        write(&mut fake, &mut log, 1, &mut second);
        write(&mut fake, &mut log, 2, &mut second);
        assert_eq!(
            log,
            [
                "A slice 0",
                "A slice 113",
                "A true",
                "B slice 226",
                "B slice 339",
                "B true"
            ]
        );
    }

    #[test]
    fn a_snapshot_request_that_cannot_be_sent_is_refused_and_fails_its_entry_without_slices() {
        let mut fake = fake(2048);
        fake.hang_up();
        let asked = fake.with(|proc, io| proc.snapshot(History::None, io));
        assert_eq!((asked, fake.proc.life()), (None, Life::Closed));
        let failed: Vec<_> = fake
            .events
            .iter()
            .filter_map(|event| match event {
                Event::Snapshot(done) => Some((done.hold(), done.slices())),
                _ => None,
            })
            .collect();
        assert_eq!(failed, [(None, 0)]);
    }

    #[test]
    fn input_reaches_the_pane_and_a_paste_gets_its_reply() {
        use std::io::Read;
        let mut fake = fake(2048);
        let sent = fake.with(|proc, io| proc.input(Input::Text(b"hi"), io));
        assert_eq!(sent, Ok(None));
        let paste = Input::Paste {
            text: "x",
            check_safe: true,
        };
        let asked = fake
            .with(|proc, io| proc.input(paste, io))
            .unwrap()
            .unwrap();
        let mut frames = [0u8; 7 + 15];
        fake.peer
            .set_read_timeout(Some(std::time::Duration::from_secs(5)))
            .unwrap();
        fake.peer.read_exact(&mut frames).unwrap();
        assert_eq!(frames[..7], frame(Kind::Text, b"hi")[..]);
        assert_eq!(frames[7 + 4], Kind::Paste as u8);
        fake.feed(&frame(Kind::PasteDone, &[req(1), vec![1, 0]].concat()));
        let pasted = Event::Pasted {
            req: asked,
            pasted: true,
            unsafe_paste: false,
        };
        assert_eq!(fake.events, [pasted]);
        fake.hang_up();
        fake.with(|proc, io| proc.input(Input::Focus(true), io))
            .unwrap();
        let ended = fake.with(|proc, io| proc.input(Input::Focus(true), io));
        assert_eq!(ended, Err(Refusal::Ended));
    }

    #[test]
    fn a_snapshot_done_for_another_request_is_ignored() {
        let mut fake = fake(2048);
        let (asked, _) = fake
            .with(|proc, io| proc.snapshot(History::None, io))
            .unwrap();
        fake.feed(&frame(Kind::SnapshotDone, &req(7)));
        assert_eq!((fake.events.len(), fake.proc.life()), (0, Life::Open));
        fake.feed(&frame(Kind::SnapshotDone, &req(1)));
        let [Event::Snapshot(ended)] = &fake.events[..] else {
            panic!("{:?}", fake.events);
        };
        assert_eq!((ended.serial(), ended.hold()), (asked, None));
    }

    #[test]
    fn a_ready_frame_with_a_foreign_pid_fails_the_pane_and_records_no_child() {
        let parent = std::os::unix::process::parent_id();
        for (pid, child) in [
            (1, Claim::Awaiting),
            (parent, Claim::Awaiting),
            (parent, Claim::Reported(None)),
        ] {
            let mut fake = fake(64);
            fake.proc.child = child;
            fake.feed(&frame(Kind::Ready, &pid.to_le_bytes()));
            let death = fake.proc.dead().map(|death| death.cause.clone());
            assert_eq!(death, Some(Cause::Failed("invalid ready".to_owned())));
            assert_eq!(fake.proc.child_pid(), None);
        }
    }

    #[test]
    fn an_error_frame_of_the_pane_is_the_cause_of_the_failed_pane() {
        let message = "openpty: Too many open files (os error 24)";
        let body = [
            &(message.len() as u32).to_le_bytes()[..],
            message.as_bytes(),
        ]
        .concat();
        let mut fake = fake(64);
        fake.feed(&frame(Kind::Error, &body));
        let death = fake.proc.dead().map(|death| death.cause.clone());
        assert_eq!(death, Some(Cause::Failed(message.to_owned())));
    }

    #[test]
    fn a_screen_reply_larger_than_the_read_buffer_arrives_whole() {
        let mut fake = fake(2048);
        let asked = fake
            .with(|proc, io| proc.screen(ScreenFormat::Plain, ScreenRows::Visible, io))
            .unwrap();
        let text = vec![b'x'; 70_000];
        let body = [req(1), vec![1], string(&text)].concat();
        let reply = frame(Kind::Screen, &body);
        let mut events = Events::default();
        let mut writer = fake.peer.try_clone().unwrap();
        let sender = std::thread::spawn(move || writer.write_all(&reply).unwrap());
        while !fake
            .events
            .iter()
            .any(|event| matches!(event, Event::Screen { .. }))
        {
            fake.poll.turn(Mode::Wait, &mut events).unwrap();
            for &ready in events.ready() {
                fake.with(|proc, io| proc.ready(ready, io));
            }
        }
        sender.join().unwrap();
        let reply = Event::Screen {
            req: asked,
            chunk: text,
            last: true,
        };
        assert_eq!(fake.events, [reply]);
        assert_eq!(fake.proc.life(), Life::Open);
    }

    type Outcome = (Vec<Event>, Vec<u8>, Vec<u8>, Option<Cause>, Option<Pid>);

    fn watched() -> Fake {
        let mut fake = fake(64);
        let delivery = fake.proc.stage.delivery_mut().unwrap();
        delivery.request().unwrap();
        let (_, paste) = delivery.mint_serial().unwrap();
        let (_, screen) = delivery.mint_serial().unwrap();
        fake.proc.pending.insert(paste, Reply::Paste);
        fake.proc.pending.insert(screen, Reply::Screen);
        fake
    }

    fn drive(fill: u8, mut fake: Fake, chunks: &[&[u8]]) -> Outcome {
        for chunk in chunks {
            let after = fake.proc.filled + chunk.len();
            if fake.proc.input.len() < after {
                fake.proc.input.resize(after, 0);
            }
            fake.proc.input[after..].fill(fill);
            fake.feed(chunk);
        }
        let events = fake
            .events
            .into_iter()
            .map(|event| match event {
                Event::Dead(Death { cause, .. }) => Event::Dead(Death {
                    at: Mono::from_nanos(0),
                    cause,
                }),
                Event::Snapshot(done) => Event::Failed {
                    req: done.req(),
                    message: format!("{:?} {}", done.hold(), done.slices()),
                },
                event => event,
            })
            .collect();
        (
            events,
            fake.proc.title.clone(),
            fake.proc.cwd.clone(),
            fake.proc.dead.clone().map(|death| death.cause),
            fake.proc.child_pid(),
        )
    }

    fn wire_frame(code: u8, id: usize, body: &[u8]) -> Vec<u8> {
        let ids: [&[u8]; 4] = [b"", b"\x01\0\0\0", b"\x02\0\0\0", b"\x03\0\0\0"];
        let code = if code == Kind::Ready as u8 {
            Kind::Head as u8
        } else {
            code
        };
        frame_code(code, &[ids[id], body].concat())
    }

    proptest! {
        #[test]
        fn a_frame_gives_the_same_effects_split_anywhere_and_reads_only_its_own_bytes(
            code in any::<u8>(),
            id in 0..4usize,
            body in prop::collection::vec(any::<u8>(), 0..40),
            cut in 0..64usize,
        ) {
            let data = wire_frame(code, id, &body);
            let cut = cut.min(data.len());
            let whole = drive(0, watched(), &[&data]);
            let split = drive(0xff, watched(), &[&data[..cut], &data[cut..]]);
            prop_assert_eq!(whole, split);
        }

        #[test]
        fn bytes_after_a_frame_do_not_change_its_effects(
            code in any::<u8>(),
            id in 0..4usize,
            body in prop::collection::vec(any::<u8>(), 0..40),
            a in (any::<[u8; 2]>(), 1..=255u8, prop::collection::vec(any::<u8>(), 0..40)),
            b in (any::<[u8; 2]>(), 1..=255u8, prop::collection::vec(any::<u8>(), 0..40)),
        ) {
            let data = wire_frame(code, id, &body);
            let after = |([x, y], z, rest): ([u8; 2], u8, Vec<u8>)| [&[x, y, z, 0][..], &rest].concat();
            let first = drive(0, watched(), &[&[data.clone(), after(a)].concat()]);
            let second = drive(0, watched(), &[&[data, after(b)].concat()]);
            prop_assert_eq!(first, second);
        }
    }
}
