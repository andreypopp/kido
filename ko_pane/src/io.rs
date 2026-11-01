#![deny(clippy::indexing_slicing, clippy::arithmetic_side_effects)]

use std::io;
use std::ops::Range;
use std::os::fd::{AsFd, BorrowedFd, OwnedFd};
use std::time::Duration;

use ko_pane_wire::frame::{self, FromPane, Kind, MAX_FRAME_BYTES, Malformed, Request};
use ko_pane_wire::ring::{Commit, Marker, RecordKind, Slice, Writer};
use ko_sys::event::{Events, Interest, Mode, Poll, Timer, Token};
use ko_sys::fd::Queue;
use ko_sys::signal::{Signal, Signals};

const CHUNK: usize = 65536;
const SHRINK: usize = 1 << 20;
const WRITE_WAIT: Duration = Duration::from_secs(5);
const INVALID: &[u8] = b"invalid control frame";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Stop;

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Fault {
    Invalid,
    Setup(String),
    Stop,
}

impl From<Stop> for Fault {
    fn from(Stop: Stop) -> Fault {
        Fault::Stop
    }
}

#[derive(Debug, Default)]
pub(crate) struct Frames {
    buf: Vec<u8>,
    start: usize,
    end: usize,
}

impl Frames {
    pub(crate) fn is_empty(&self) -> bool {
        self.start >= self.end
    }

    pub(crate) fn push(&mut self, frame: &[u8]) {
        let end = self.end.saturating_add(frame.len());
        if self.buf.len() < end {
            self.buf.resize(end, 0);
        }
        if let Some(room) = self.buf.get_mut(self.end..end) {
            room.copy_from_slice(frame);
        }
        self.end = end;
    }

    pub(crate) fn fill(&mut self, fd: BorrowedFd<'_>) -> io::Result<bool> {
        loop {
            if self.end.saturating_sub(self.start) >= MAX_FRAME_BYTES {
                return Err(io::ErrorKind::InvalidData.into());
            }
            if self.buf.len().saturating_sub(self.end) < CHUNK {
                self.compact();
                let grown = self
                    .buf
                    .len()
                    .saturating_mul(2)
                    .max(self.end.saturating_add(CHUNK));
                self.buf.resize(grown, 0);
            }
            let Some(room) = self.buf.get_mut(self.end..) else {
                return Err(io::ErrorKind::InvalidData.into());
            };
            match ko_sys::fd::read(fd, room) {
                Ok(0) => return Ok(true),
                Ok(count) => self.end = self.end.saturating_add(count),
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => return Ok(false),
                Err(error) => return Err(error),
            }
        }
    }

    pub(crate) fn next(&mut self) -> Result<Option<Range<usize>>, Malformed> {
        let rest = self.buf.get(self.start..self.end).unwrap_or_default();
        Ok(frame::frame_size(rest)?.map(|size| {
            let start = self.start;
            self.start = self.start.saturating_add(size);
            start..self.start
        }))
    }

    pub(crate) fn frame(&self, range: Range<usize>) -> &[u8] {
        self.buf.get(range).unwrap_or_default()
    }

    pub(crate) fn compact(&mut self) {
        if self.start == self.end && self.buf.len() > SHRINK {
            self.buf = Vec::new();
        } else {
            self.buf.copy_within(self.start..self.end, 0);
        }
        self.end = self.end.saturating_sub(self.start);
        self.start = 0;
    }
}

#[derive(Debug, Clone, Copy)]
struct Tokens {
    input: Token,
    output: Token,
    signals: Option<Token>,
}

#[derive(Debug, Clone, Copy)]
struct Polled {
    input: bool,
    timed_out: bool,
}

#[derive(Debug)]
pub(crate) struct Out {
    pub(crate) writer: Writer,
    input_fd: OwnedFd,
    output_fd: OwnedFd,
    pub(crate) output: Queue,
    events: Vec<u8>,
    pub(crate) full: bool,
    pub(crate) stopping: bool,
    signals: Option<Signals>,
    pub(crate) child_signal: bool,
    pub(crate) failure: Option<String>,
    nested: Poll,
    tokens: Tokens,
    deadline: Timer,
    polled: Events,
}

impl Out {
    fn new(writer: Writer, input_fd: OwnedFd, output_fd: OwnedFd, signals: Option<Signals>) -> Out {
        let mut nested = Poll::new();
        let tokens = Tokens {
            input: nested.watch(input_fd.as_fd(), Interest::Idle),
            output: nested.watch(output_fd.as_fd(), Interest::Idle),
            signals: signals
                .as_ref()
                .map(|signals| nested.watch(signals.fd(), Interest::Read)),
        };
        let deadline = nested.timer();
        Out {
            writer,
            input_fd,
            output_fd,
            output: Queue::default(),
            events: Vec::new(),
            full: false,
            stopping: false,
            signals,
            child_signal: false,
            failure: None,
            nested,
            tokens,
            deadline,
            polled: Events::default(),
        }
    }

    pub(crate) fn input_fd(&self) -> BorrowedFd<'_> {
        self.input_fd.as_fd()
    }

    pub(crate) fn output_fd(&self) -> BorrowedFd<'_> {
        self.output_fd.as_fd()
    }

    pub(crate) fn signals_fd(&self) -> Option<BorrowedFd<'_>> {
        self.signals.as_ref().map(Signals::fd)
    }

    pub(crate) fn signaled(&mut self) -> io::Result<()> {
        let Some(signals) = &self.signals else {
            return Ok(());
        };
        let mut pending = Vec::new();
        signals.take(&mut pending)?;
        for signal in pending {
            match signal {
                Signal::Child => self.child_signal = true,
                Signal::Hup | Signal::Term => self.stopping = true,
                _ => {}
            }
        }
        Ok(())
    }

    pub(crate) fn frame(&mut self, frame: &FromPane<'_>) {
        if frame::encode_from(frame, &mut self.output.bytes).is_err() {
            self.stopping = true;
        }
    }

    pub(crate) fn event(&mut self, frame: &FromPane<'_>) {
        if frame::encode_from(frame, &mut self.events).is_err() {
            self.stopping = true;
        }
    }

    pub(crate) fn report(&mut self, fault: &Fault) {
        let message = match fault {
            Fault::Invalid => INVALID,
            Fault::Setup(message) => message.as_bytes(),
            Fault::Stop => return,
        };
        self.frame(&FromPane::Error(message));
        self.failure = Some(String::from_utf8_lossy(message).into_owned());
    }

    pub(crate) fn flush(&mut self) -> Result<(), Stop> {
        self.output
            .flush(self.output_fd.as_fd())
            .map_err(|_| Stop)?;
        if self.output.is_empty() && self.output.bytes.capacity() > SHRINK {
            self.output.bytes = Vec::new();
        }
        Ok(())
    }

    fn announce_head(&mut self) {
        let head = self.writer.head();
        self.frame(&FromPane::Head(head));
    }

    pub(crate) fn announce_full(&mut self) {
        if !self.full {
            self.full = true;
            let tail = self.writer.tail();
            self.frame(&FromPane::Full(tail));
        }
    }

    pub(crate) fn available(&mut self) -> usize {
        let available = self.writer.available();
        if available.idle {
            self.announce_head();
        }
        usize::try_from(available.room).unwrap_or(0)
    }

    fn published(&mut self, commit: Commit) {
        match commit {
            Commit::Refused => {
                self.stopping = true;
                return;
            }
            Commit::Idle => self.announce_head(),
            Commit::Published => {}
        }
        self.output.bytes.append(&mut self.events);
    }

    pub(crate) fn publish(&mut self, kind: RecordKind, len: usize) {
        let commit = self.writer.publish(kind, len);
        self.published(commit);
    }

    pub(crate) fn put_marker(&mut self, marker: Marker) {
        let commit = self.writer.put_marker(marker);
        self.published(commit);
    }

    pub(crate) fn put_slice(&mut self, slice: Slice) {
        let commit = self.writer.put_slice(slice);
        self.published(commit);
    }

    pub(crate) fn drain_output(&mut self) -> Result<(), Stop> {
        while !self.output.is_empty() && !self.stopping {
            self.flush()?;
            if !self.output.is_empty() && self.poll_once(false, Some(WRITE_WAIT))?.timed_out {
                return Err(Stop);
            }
        }
        if self.stopping { Err(Stop) } else { Ok(()) }
    }

    fn poll_once(&mut self, reading: bool, wait: Option<Duration>) -> Result<Polled, Stop> {
        self.nested
            .interest(self.tokens.input, Interest::of(reading, false));
        self.nested.interest(
            self.tokens.output,
            Interest::of(false, !self.output.is_empty()),
        );
        match wait {
            Some(wait) => self
                .nested
                .start(self.deadline, wait, None)
                .map_err(|_| Stop)?,
            None => self.nested.stop(self.deadline),
        }
        self.nested
            .turn(Mode::Wait, &mut self.polled)
            .map_err(|_| Stop)?;
        let mut polled = Polled {
            input: false,
            timed_out: self
                .polled
                .due()
                .iter()
                .any(|due| due.timer == self.deadline),
        };
        let mut signaled = false;
        for ready in self.polled.ready() {
            polled.input |= ready.token == self.tokens.input && ready.read && reading;
            signaled |= Some(ready.token) == self.tokens.signals && ready.read;
        }
        if signaled {
            self.signaled().map_err(|_| Stop)?;
        }
        self.flush()?;
        Ok(polled)
    }
}

#[derive(Debug)]
pub(crate) struct Io {
    pub(crate) input: Frames,
    pub(crate) deferred: Frames,
    pub(crate) out: Out,
}

impl Io {
    pub(crate) fn new(
        writer: Writer,
        input_fd: OwnedFd,
        output_fd: OwnedFd,
        signals: Option<Signals>,
    ) -> Io {
        Io {
            input: Frames::default(),
            deferred: Frames::default(),
            out: Out::new(writer, input_fd, output_fd, signals),
        }
    }

    pub(crate) fn fill(&mut self) -> Result<bool, Stop> {
        match self.input.fill(self.out.input_fd.as_fd()) {
            Ok(eof) => Ok(eof),
            Err(error) => {
                if error.kind() == io::ErrorKind::InvalidData {
                    self.out.report(&Fault::Invalid);
                }
                Err(Stop)
            }
        }
    }

    pub(crate) fn wait_space(&mut self, minimum: usize) -> Result<(), Stop> {
        while self.out.available() < minimum && !self.out.stopping {
            self.out.announce_full();
            if self.out.poll_once(true, None)?.input {
                self.nested_control()?;
            }
        }
        if self.out.stopping { Err(Stop) } else { Ok(()) }
    }

    fn nested_control(&mut self) -> Result<(), Stop> {
        let eof = self.fill()?;
        loop {
            let range = match self.input.next() {
                Ok(Some(range)) => range,
                Ok(None) => break,
                Err(_) => {
                    self.out.report(&Fault::Invalid);
                    return Err(Stop);
                }
            };
            let frame = self.input.frame(range);
            match frame::kind(frame) {
                Some(Kind::Exit) => self.out.stopping = true,
                Some(Kind::Tail) => {
                    if matches!(frame::decode_request(frame), Ok(Request::Tail)) {
                        self.out.full = false;
                    } else {
                        self.out.report(&Fault::Invalid);
                        return Err(Stop);
                    }
                }
                _ => self.deferred.push(frame),
            }
        }
        self.input.compact();
        if eof {
            self.out.stopping = true;
        }
        Ok(())
    }
}
