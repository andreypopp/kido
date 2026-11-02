#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::indexing_slicing,
    clippy::arithmetic_side_effects
)]

use std::io;
use std::os::fd::{AsFd, OwnedFd};
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};

use crate::event::{Events, Interest, Mode, Poll, Read, Reads, Timer, Token};
use crate::fd;
use crate::signal::{Signal, Signals};

const MAX_READS: usize = 16;
const CHANNELS: usize = 3;
const TIMERS: usize = 4;
const SLACK: Duration = Duration::from_millis(2);
const MAX_OPS: usize = 80;
const SIGNALS: [Signal; 2] = [Signal::Usr1, Signal::Usr2];

// A spawn in another thread holds a copy of every descriptor until its child execs, so a closed
// peer is not a hangup at once (ko_sys/src/spawn.rs).
fn hung_up(fd: std::os::fd::BorrowedFd<'_>) {
    use std::os::fd::AsRawFd;
    let started = Instant::now();
    loop {
        let mut wait = libc::pollfd {
            fd: fd.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        // SAFETY: wait is one initialized pollfd.
        let found =
            crate::retry::retry(|| crate::retry::check(unsafe { libc::poll(&mut wait, 1, 10) }))
                .unwrap();
        if found > 0 && wait.revents & libc::POLLHUP != 0 {
            return;
        }
        assert!(
            started.elapsed() < Duration::from_secs(5),
            "no hangup: revents {:#x}",
            wait.revents
        );
        if found > 0 {
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}

fn pattern(i: usize) -> u8 {
    ((i * 7 + 3) & 0xff) as u8
}

fn reads(interest: Interest) -> bool {
    matches!(interest, Interest::Read | Interest::ReadWrite)
}

fn writes(interest: Interest) -> bool {
    matches!(interest, Interest::Write | Interest::ReadWrite)
}

#[derive(Debug, Clone, Copy)]
enum Op {
    Interest(usize, Interest),
    Window(usize, usize, usize),
    Send(usize, usize),
    Fill(usize),
    Drain(usize),
    ClosePeer(usize),
    PauseAfter(usize, usize),
    Timer {
        timer: usize,
        after: u64,
        repeat: Option<u64>,
        limit: usize,
        kills: Option<usize>,
    },
    Cancel(usize),
    Signal(usize),
    Step(Mode),
}

struct Bytes<'a>(&'a [u8]);

impl Bytes<'_> {
    fn next(&mut self) -> Option<u8> {
        let (&byte, rest) = self.0.split_first()?;
        self.0 = rest;
        Some(byte)
    }

    fn below(&mut self, bound: usize) -> Option<usize> {
        Some(usize::from(self.next()?) % bound)
    }

    fn word(&mut self) -> Option<usize> {
        Some(usize::from(self.next()?) | usize::from(self.next()?) << 8)
    }
}

fn op(bytes: &mut Bytes<'_>) -> Option<Op> {
    let tag = bytes.next()?;
    Some(match tag % 32 {
        0..=3 => Op::Interest(
            bytes.below(CHANNELS)?,
            [
                Interest::Idle,
                Interest::Read,
                Interest::Read,
                Interest::Write,
                Interest::ReadWrite,
            ][bytes.below(5)?],
        ),
        4..=5 => Op::Window(
            bytes.below(CHANNELS)?,
            bytes.below(33)?,
            1 + bytes.below(96)?,
        ),
        6..=11 => {
            let channel = bytes.below(CHANNELS)?;
            let size = match bytes.below(3)? {
                0 => 1 + bytes.below(40)?,
                1 => 1 + bytes.below(600)?,
                _ => 1 + bytes.word()? % 4000,
            };
            Op::Send(channel, size)
        }
        12 => Op::Send(bytes.below(CHANNELS)?, 300_000),
        13 => Op::Fill(bytes.below(CHANNELS)?),
        14 => Op::Drain(bytes.below(CHANNELS)?),
        15 => Op::ClosePeer(bytes.below(CHANNELS)?),
        16..=17 => Op::PauseAfter(bytes.below(CHANNELS)?, 1 + bytes.below(5)?),
        18..=21 => {
            let timer = bytes.below(TIMERS)?;
            let after = bytes.below(9)? as u64;
            let repeat = match bytes.below(5)? {
                0 => None,
                n => Some(n as u64),
            };
            let limit = 1 + bytes.below(4)?;
            let kills = match bytes.below(TIMERS + 1)? {
                n if n == TIMERS => None,
                n => Some(n),
            };
            Op::Timer {
                timer,
                after,
                repeat,
                limit,
                kills,
            }
        }
        22..=23 => Op::Cancel(bytes.below(TIMERS)?),
        24..=25 => Op::Signal(bytes.below(2)?),
        _ => Op::Step(if bytes.below(3)? == 2 {
            Mode::Wait
        } else {
            Mode::Peek
        }),
    })
}

struct Channel {
    a: OwnedFd,
    b: Option<OwnedFd>,
    socket: bool,
    token: Token,
    window: [u8; 128],
    off: usize,
    len: usize,
    interest: Interest,
    watched: bool,
    accepted: usize,
    received: usize,
    ended: usize,
    calls: usize,
    writable: usize,
    pause_after: Option<usize>,
    full: bool,
}

impl Channel {
    fn peer_closed(&self) -> bool {
        self.b.is_none()
    }

    fn available(&self) -> usize {
        self.accepted - self.received
    }

    fn predicted_calls(&self) -> usize {
        if self.watched && reads(self.interest) && self.available() > 0 {
            let n = MAX_READS.min(self.available().div_ceil(self.len));
            self.pause_after.map_or(n, |k| k.min(n))
        } else {
            0
        }
    }

    fn ends_now(&self) -> bool {
        self.watched && reads(self.interest) && self.peer_closed() && self.available() == 0
    }

    fn writable_now(&self) -> bool {
        self.watched
            && writes(self.interest)
            && !(self.peer_closed() || self.full)
            && !self.ends_now()
    }
}

struct Clock {
    timer: Timer,
    active: bool,
    first_due: Instant,
    fired: usize,
    period: Option<Duration>,
    limit: usize,
    kills: Option<usize>,
}

fn channel(poll: &mut Poll, socket: bool) -> io::Result<Channel> {
    let (a, b) = if socket {
        let (a, b) = UnixStream::pair()?;
        (OwnedFd::from(a), OwnedFd::from(b))
    } else {
        let (reader, writer) = io::pipe()?;
        (OwnedFd::from(reader), OwnedFd::from(writer))
    };
    fd::set_nonblocking(a.as_fd())?;
    fd::set_nonblocking(b.as_fd())?;
    let token = poll.watch(a.as_fd(), Interest::Idle);
    Ok(Channel {
        a,
        b: Some(b),
        socket,
        token,
        window: [0; 128],
        off: 0,
        len: 64,
        interest: Interest::Idle,
        watched: true,
        accepted: 0,
        received: 0,
        ended: 0,
        calls: 0,
        writable: 0,
        pause_after: None,
        full: false,
    })
}

struct Run {
    poll: Poll,
    events: Events,
    signals: Signals,
    signal_token: Token,
    channels: Vec<Channel>,
    clocks: Vec<Clock>,
    guard: Timer,
    guard_fired: bool,
    last_one_shot: Instant,
    fired_total: usize,
    hits: [usize; 2],
    signalled: [bool; 2],
}

impl Run {
    fn new() -> io::Result<Run> {
        let signals = Signals::install(&SIGNALS)?;
        let mut poll = Poll::new();
        let signal_token = poll.watch(signals.fd(), Interest::Read);
        let channels = (0..CHANNELS)
            .map(|i| channel(&mut poll, i != 1))
            .collect::<io::Result<Vec<_>>>()?;
        let clocks = (0..TIMERS)
            .map(|_| Clock {
                timer: poll.timer(),
                active: false,
                first_due: Instant::now(),
                fired: 0,
                period: None,
                limit: 0,
                kills: None,
            })
            .collect();
        let guard = poll.timer();
        Ok(Run {
            poll,
            events: Events::default(),
            signals,
            signal_token,
            channels,
            clocks,
            guard,
            guard_fired: false,
            last_one_shot: Instant::now(),
            fired_total: 0,
            hits: [0; 2],
            signalled: [false; 2],
        })
    }

    fn cancel(&mut self, index: usize) {
        self.clocks[index].active = false;
        self.poll.stop(self.clocks[index].timer);
    }

    fn fire(&mut self, index: usize) {
        let now = Instant::now();
        let clock = &self.clocks[index];
        assert!(clock.active, "timer {index} fired while cancelled");
        let due = clock.first_due
            + clock.period.unwrap_or_default() * u32::try_from(clock.fired).unwrap();
        assert!(now >= due, "timer {index} fired {:?} early", due - now);
        if clock.period.is_none() {
            assert!(
                clock.first_due + SLACK >= self.last_one_shot,
                "one-shot timer {index} fired out of order"
            );
            self.last_one_shot = self.last_one_shot.max(clock.first_due);
        }
        let clock = &mut self.clocks[index];
        if clock.period.is_none() {
            clock.active = false;
        }
        clock.fired += 1;
        self.fired_total += 1;
        let (kills, done) = (clock.kills, clock.fired >= clock.limit && clock.active);
        if let Some(other) = kills {
            self.cancel(other);
        }
        if done {
            self.cancel(index);
        }
    }

    fn read_channel(&mut self, index: usize) {
        let mut budget = Reads::new();
        loop {
            let c = &mut self.channels[index];
            let window = &mut c.window[c.off..c.off + c.len];
            match self.poll.read(c.token, c.a.as_fd(), window, &mut budget) {
                Ok(None) => return,
                Ok(Some(Read::Data(count))) => {
                    assert!(c.watched, "data after unwatch");
                    assert!(reads(c.interest), "data without read interest");
                    assert!(
                        count > 0 && count <= c.len,
                        "read of {count} into {}",
                        c.len
                    );
                    for i in 0..count {
                        assert_eq!(
                            c.window[c.off + i],
                            pattern(c.received + i),
                            "byte {} is wrong",
                            c.received + i
                        );
                    }
                    c.received += count;
                    c.calls += 1;
                    assert!(
                        c.received <= c.accepted,
                        "more bytes delivered than written"
                    );
                    match c.pause_after {
                        Some(1) => {
                            c.pause_after = None;
                            c.interest = match c.interest {
                                Interest::Read | Interest::Idle => Interest::Idle,
                                Interest::Write | Interest::ReadWrite => Interest::Write,
                            };
                            self.poll.interest(c.token, c.interest);
                        }
                        Some(k) => c.pause_after = Some(k - 1),
                        None => {}
                    }
                }
                Ok(Some(Read::End)) => {
                    assert!(c.watched && c.peer_closed(), "end without a closed peer");
                    assert_eq!(c.received, c.accepted, "end before the bytes arrived");
                    c.ended += 1;
                    c.watched = false;
                    self.poll.unwatch(c.token);
                    return;
                }
                Err(error) => panic!("read: {error}"),
            }
        }
    }

    fn step(&mut self, mode: Mode) {
        let now = Instant::now();
        let expected: Vec<usize> = self.channels.iter().map(Channel::predicted_calls).collect();
        let ends_now: Vec<bool> = self.channels.iter().map(Channel::ends_now).collect();
        let writable_now: Vec<bool> = self.channels.iter().map(Channel::writable_now).collect();
        let due_now: Vec<bool> = self
            .clocks
            .iter()
            .map(|t| t.active && t.period.is_none() && now >= t.first_due + SLACK)
            .collect();
        let pending = self.clocks.iter().any(|t| t.active);
        let io = expected.iter().any(|e| *e > 0)
            || ends_now.iter().any(|e| *e)
            || writable_now.iter().any(|w| *w);
        let signals = self.signalled.iter().any(|s| *s);
        let hits_before = self.hits;
        for c in &mut self.channels {
            c.calls = 0;
            c.writable = 0;
        }
        let before = self.fired_total;
        let mode = if mode == Mode::Wait && (pending || io || signals) {
            Mode::Wait
        } else {
            Mode::Peek
        };
        if mode == Mode::Wait {
            self.guard_fired = false;
            self.poll
                .start(self.guard, Duration::from_secs(1), None)
                .unwrap();
        }
        let mut events = std::mem::take(&mut self.events);
        self.poll.turn(mode, &mut events).unwrap();
        for &ready in events.ready() {
            let wants = self.poll.wants(ready);
            if ready.token == self.signal_token {
                if wants.read {
                    let mut taken = Vec::new();
                    self.signals.take(&mut taken).unwrap();
                    for signal in taken {
                        self.hits[SIGNALS.iter().position(|s| *s == signal).unwrap()] += 1;
                    }
                }
            } else if let Some(index) = self.channels.iter().position(|c| c.token == ready.token) {
                if wants.write {
                    let c = &mut self.channels[index];
                    assert!(
                        c.watched && writes(c.interest),
                        "writable without write interest"
                    );
                    assert!(
                        c.peer_closed() || !c.full,
                        "writable while the send buffer is full"
                    );
                    c.writable += 1;
                }
                if wants.read {
                    self.read_channel(index);
                }
            }
        }
        for &due in events.due() {
            if !self.poll.current(due) {
                continue;
            }
            if due.timer == self.guard {
                self.guard_fired = true;
            } else if let Some(index) = self.clocks.iter().position(|t| t.timer == due.timer) {
                self.fire(index);
            }
        }
        self.events = events;
        self.poll.stop(self.guard);
        assert!(
            !self.guard_fired,
            "step Wait blocked for a second with {}",
            if pending {
                "a timer pending"
            } else {
                "events pending"
            }
        );
        for (i, c) in self.channels.iter().enumerate() {
            assert_eq!(c.calls, expected[i], "channel {i}: reads");
            if ends_now[i] {
                assert_eq!(c.ended, 1, "channel {i}: no end at a closed peer");
            }
            if writable_now[i] {
                assert_eq!(
                    c.writable, 1,
                    "channel {i}: not writable though it can write"
                );
            } else {
                assert!(
                    c.writable <= usize::from(c.peer_closed()),
                    "channel {i}: writable while it cannot write"
                );
            }
        }
        for (i, t) in self.clocks.iter().enumerate() {
            if due_now[i] {
                assert!(!t.active, "timer {i} is due and did not fire");
            }
        }
        for (s, raised) in self.signalled.iter_mut().enumerate() {
            assert_eq!(
                self.hits[s],
                hits_before[s] + usize::from(*raised),
                "signal {s}: callbacks for {raised} raised"
            );
            *raised = false;
        }
        let hung_up = self
            .channels
            .iter()
            .any(|c| c.watched && c.peer_closed() && writes(c.interest));
        if mode == Mode::Wait && !io && !signals && !hung_up {
            assert!(
                self.fired_total > before,
                "step Wait returned with nothing to report"
            );
        }
    }

    fn apply(&mut self, op: Op) {
        match op {
            Op::Interest(i, interest) => {
                let c = &mut self.channels[i];
                let interest = match (c.socket, interest) {
                    (false, Interest::Write) => Interest::Read,
                    (false, Interest::ReadWrite) => Interest::Read,
                    (_, other) => other,
                };
                if c.watched {
                    c.interest = interest;
                    self.poll.interest(c.token, interest);
                }
            }
            Op::Window(i, off, len) => {
                let c = &mut self.channels[i];
                c.off = off;
                c.len = len;
            }
            Op::Send(i, n) => {
                let c = &mut self.channels[i];
                if let Some(b) = c.b.as_ref() {
                    let data: Vec<u8> = (0..n).map(|k| pattern(c.accepted + k)).collect();
                    match fd::write(b.as_fd(), &data) {
                        Ok(written) => c.accepted += written,
                        Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                        Err(error) => panic!("send: {error}"),
                    }
                }
            }
            Op::Fill(i) => {
                let c = &mut self.channels[i];
                if c.socket && c.watched && !c.peer_closed() {
                    let chunk = [b'f'; 65536];
                    loop {
                        match fd::write(c.a.as_fd(), &chunk) {
                            Ok(_) => {}
                            Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                            Err(error) => panic!("fill: {error}"),
                        }
                    }
                    c.full = true;
                }
            }
            Op::Drain(i) => {
                let c = &mut self.channels[i];
                if let (true, Some(b)) = (c.socket, c.b.as_ref()) {
                    let mut chunk = [0u8; 65536];
                    while matches!(fd::read(b.as_fd(), &mut chunk), Ok(1..)) {}
                    c.full = false;
                }
            }
            Op::ClosePeer(i) => {
                let c = &mut self.channels[i];
                if c.b.take().is_some() {
                    c.full = false;
                    hung_up(c.a.as_fd());
                }
            }
            Op::PauseAfter(i, k) => self.channels[i].pause_after = Some(k),
            Op::Timer {
                timer,
                after,
                repeat,
                limit,
                kills,
            } => {
                let after = Duration::from_millis(after);
                let repeat = repeat.map(Duration::from_millis);
                let clock = &mut self.clocks[timer];
                clock.active = true;
                clock.first_due = Instant::now() + after;
                clock.fired = 0;
                clock.period = repeat;
                clock.limit = limit;
                clock.kills = kills;
                self.poll.start(clock.timer, after, repeat).unwrap();
            }
            Op::Cancel(i) => self.cancel(i),
            Op::Signal(s) => {
                self.signalled[s] = true;
                crate::signal::simulate(SIGNALS[s]);
            }
            Op::Step(mode) => self.step(mode),
        }
    }

    fn finish(&mut self) {
        for c in &mut self.channels {
            if c.watched {
                c.interest = Interest::Read;
                c.pause_after = None;
                c.off = 0;
                c.len = 64;
                self.poll.interest(c.token, Interest::Read);
            }
        }
        for i in 0..TIMERS {
            if self.clocks[i].active {
                self.cancel(i);
            }
        }
        self.step(Mode::Peek);
        let mut rounds = 0;
        while rounds < 400
            && self
                .channels
                .iter()
                .any(|c| c.watched && (c.available() > 0 || c.peer_closed()))
        {
            rounds += 1;
            self.step(Mode::Peek);
        }
        for (i, c) in self.channels.iter().enumerate() {
            assert!(
                !(c.watched && c.peer_closed()),
                "channel {i}: no end after {rounds} rounds"
            );
            if c.watched || c.ended == 1 {
                assert_eq!(c.received, c.accepted, "channel {i}: bytes");
            }
            assert!(c.ended <= 1, "channel {i}: ended {} times", c.ended);
        }
    }
}

pub fn event(data: &[u8]) {
    #[cfg(test)]
    let _serial = crate::signal::SERIAL
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let Ok(mut run) = Run::new() else {
        return;
    };
    let mut bytes = Bytes(data);
    for _ in 0..MAX_OPS {
        let Some(op) = op(&mut bytes) else {
            break;
        };
        run.apply(op);
    }
    run.finish();
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    #[test]
    fn the_replayed_corpus_runs_to_the_end() {
        let corpus = Path::new(env!("CARGO_MANIFEST_DIR")).join("../fuzz/corpus/loop");
        let mut replayed = 0;
        for entry in std::fs::read_dir(corpus).unwrap() {
            event(&std::fs::read(entry.unwrap().path()).unwrap());
            replayed += 1;
        }
        assert!(replayed >= 4, "{replayed}");
    }
}
