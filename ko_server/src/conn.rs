use std::collections::VecDeque;
use std::fmt;
use std::io::{self, IoSlice, Write};
use std::net::Shutdown;
use std::os::fd::AsFd;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::sync::Arc;

use ko_pane_wire::ring::{Pos, Reader};
use ko_sys::event::{Interest, Poll, Read, Reads, Timer, Token};
use ko_sys::mapping::Named;
use vstd::prelude::*;

use crate::http::{self, Framing, Head, MAX_HEAD, Parsed, Status};
use crate::link::{Link, Role, Wire};
use crate::server::Verified;
use crate::spill::Spill;
use crate::ws::{Header, Record};

const SLICES: usize = 64;
const PIECE: usize = 1 << 20;
const PIXEL_PIECES_PER_FLUSH: usize = 4;
const FLUSH_BYTES: usize = 4 << 20;

#[derive(Debug)]
struct Chunk {
    bytes: Vec<u8>,
    tail: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Fit {
    Cap,
    Spill,
}

#[derive(Debug)]
struct Overflow {
    dir: Arc<Path>,
    limit: u64,
    farewell: Vec<u8>,
    spill: Option<Spill>,
}

impl Overflow {
    fn store(&mut self, parts: &[&[u8]]) -> io::Result<()> {
        if self.spill.is_none() {
            self.spill = Some(Spill::create(&self.dir, self.limit)?);
        }
        match self.spill.as_mut() {
            Some(spill) => spill.push(parts),
            None => Err(io::ErrorKind::Unsupported.into()),
        }
    }
}

#[derive(Debug)]
enum Policy {
    Plain,
    View(Overflow),
    Sealed,
}

// A chunk is one whole message, or the tail of a message that began in the socket. The messages
// of the spill come back one chunk each, so the wire stays at a message boundary behind the
// chunk that is being sent.
#[derive(Debug)]
pub(crate) struct Queue {
    chunks: VecDeque<Chunk>,
    sent: usize,
    bytes: usize,
    cap: usize,
    policy: Policy,
}

impl Queue {
    pub(crate) fn new(cap: usize) -> Queue {
        Queue {
            chunks: VecDeque::new(),
            sent: 0,
            bytes: 0,
            cap,
            policy: Policy::Plain,
        }
    }

    fn spilling(&self) -> bool {
        matches!(&self.policy, Policy::View(Overflow { spill: Some(_), .. }))
    }

    fn fits(&self, len: usize) -> bool {
        !self.spilling() && self.bytes.saturating_add(len) <= self.cap
    }

    fn sealed(&self) -> bool {
        matches!(self.policy, Policy::Sealed)
    }

    fn is_empty(&self) -> bool {
        self.chunks.is_empty() && !self.spilling()
    }

    fn push_vec(&mut self, bytes: Vec<u8>) -> bool {
        if self.sealed() || bytes.is_empty() {
            return !self.sealed();
        }
        if self.fits(bytes.len()) {
            self.bytes = self.bytes.saturating_add(bytes.len());
            self.chunks.push_back(Chunk { bytes, tail: false });
            true
        } else {
            self.push(&[&bytes], Fit::Cap)
        }
    }

    fn push_reply(&mut self, bytes: Vec<u8>) {
        if !self.sealed() && !bytes.is_empty() {
            self.bytes = self.bytes.saturating_add(bytes.len());
            self.chunks.push_back(Chunk { bytes, tail: false });
        }
    }

    pub(crate) fn push(&mut self, parts: &[&[u8]], fit: Fit) -> bool {
        let len = parts.iter().map(|part| part.len()).sum();
        if self.sealed() || len == 0 {
            return !self.sealed();
        }
        if self.fits(len) {
            self.bytes = self.bytes.saturating_add(len);
            self.chunks.push_back(Chunk {
                bytes: parts.concat(),
                tail: false,
            });
            return true;
        }
        if (self.spilling() || fit == Fit::Spill)
            && let Policy::View(overflow) = &mut self.policy
            && overflow.store(parts).is_ok()
        {
            return true;
        }
        self.overflow();
        false
    }

    fn push_tail(&mut self, parts: &[&[u8]]) {
        let bytes = parts.concat();
        self.bytes = self.bytes.saturating_add(bytes.len());
        self.chunks.push_back(Chunk { bytes, tail: true });
    }

    // A queue with a farewell keeps the chunk in flight, so the wire ends at a message boundary,
    // and ends with the farewell, which no limit refuses. Any other queue drops everything.
    fn overflow(&mut self) {
        let farewell = match std::mem::replace(&mut self.policy, Policy::Sealed) {
            Policy::View(overflow) => Some(overflow.farewell),
            Policy::Plain | Policy::Sealed => None,
        };
        let keep = farewell.is_some()
            && self
                .chunks
                .front()
                .is_some_and(|front| self.sent > 0 || front.tail);
        self.chunks.truncate(usize::from(keep));
        self.bytes = self
            .chunks
            .front()
            .map_or(0, |front| front.bytes.len().saturating_sub(self.sent));
        if let Some(bytes) = farewell {
            self.bytes = self.bytes.saturating_add(bytes.len());
            self.chunks.push_back(Chunk { bytes, tail: false });
        }
    }

    fn written(&mut self, mut count: usize) {
        self.bytes = self.bytes.saturating_sub(count);
        while let Some(front) = self.chunks.front() {
            let left = front.bytes.len().saturating_sub(self.sent);
            if count < left {
                self.sent = self.sent.saturating_add(count);
                return;
            }
            count = count.saturating_sub(left);
            self.sent = 0;
            self.chunks.pop_front();
        }
    }

    fn fill(&mut self) -> io::Result<()> {
        let piece = self.cap.min(PIECE);
        let Policy::View(overflow) = &mut self.policy else {
            return Ok(());
        };
        let Some(file) = overflow.spill.as_mut() else {
            return Ok(());
        };
        for bytes in file.take(piece)? {
            self.bytes = self.bytes.saturating_add(bytes.len());
            self.chunks.push_back(Chunk { bytes, tail: false });
        }
        if file.is_empty() {
            overflow.spill = None;
        }
        Ok(())
    }

    // The bytes that the socket took, at most FLUSH_BYTES: the loop comes back for the rest when the
    // socket is writable again, and the other connections get their turn.
    fn flush(&mut self, stream: &UnixStream) -> io::Result<usize> {
        let mut total = 0;
        while total < FLUSH_BYTES {
            if self.chunks.is_empty() && self.fill().is_err() {
                self.overflow();
            }
            if self.chunks.is_empty() {
                break;
            }
            let mut slices = [IoSlice::new(&[]); SLICES];
            let mut used = 0;
            for (slot, (index, chunk)) in slices.iter_mut().zip(self.chunks.iter().enumerate()) {
                let skip = if index == 0 { self.sent } else { 0 };
                *slot = IoSlice::new(chunk.bytes.get(skip..).unwrap_or_default());
                used = index.saturating_add(1);
            }
            match write_slices(stream, slices.get(..used).unwrap_or_default())? {
                0 => break,
                count => {
                    total = total.saturating_add(count);
                    self.written(count);
                }
            }
        }
        Ok(total)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Written {
    Accepted,
    Queued,
    Blocked,
    Closed,
}

#[derive(Debug)]
struct Pixels {
    object: Named,
    sent: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Life {
    Open,
    Draining,
    Shut,
}

#[derive(Debug)]
pub(crate) struct Output {
    stream: UnixStream,
    queue: Queue,
    pixels: Option<Pixels>,
    shut: bool,
    refused: bool,
    accepted: u64,
}

fn write_slices(stream: &UnixStream, slices: &[IoSlice<'_>]) -> io::Result<usize> {
    match ko_sys::retry::retry(|| (&*stream).write_vectored(slices)) {
        Err(error) if error.kind() == io::ErrorKind::WouldBlock => Ok(0),
        written => written,
    }
}

impl Output {
    pub(crate) fn new(stream: UnixStream, cap: usize) -> Output {
        Output {
            stream,
            queue: Queue::new(cap),
            pixels: None,
            shut: false,
            refused: false,
            accepted: 0,
        }
    }

    // Past its cap a view spills, and past its spill limit it ends with the farewell.
    pub(crate) fn view(&mut self, dir: Arc<Path>, limit: u64, farewell: Vec<u8>) {
        if matches!(self.queue.policy, Policy::Plain) {
            self.queue.policy = Policy::View(Overflow {
                dir,
                limit,
                farewell,
                spill: None,
            });
        }
    }

    pub(crate) fn life(&self) -> Life {
        if self.shut {
            Life::Shut
        } else if self.queue.sealed() {
            Life::Draining
        } else {
            Life::Open
        }
    }

    pub(crate) fn is_open(&self) -> bool {
        self.life() == Life::Open
    }

    pub(crate) fn is_shut(&self) -> bool {
        self.shut
    }

    pub(crate) fn accepted(&self) -> u64 {
        self.accepted
    }

    pub(crate) fn backed_up(&self) -> bool {
        self.queue.bytes >= self.queue.cap
    }

    pub(crate) fn waiting(&self) -> bool {
        self.refused || !self.queue.is_empty() || self.pixels.is_some()
    }

    pub(crate) fn available(&self) -> bool {
        self.is_open() && !self.waiting()
    }

    pub(crate) fn writable(&mut self) {
        self.refused = false;
        self.flush();
    }

    pub(crate) fn parts(&mut self) -> (&UnixStream, &mut Queue) {
        (&self.stream, &mut self.queue)
    }

    // An open output shuts at once. A draining one finishes sending its close frame first.
    pub(crate) fn close(&mut self) {
        if !self.queue.sealed() || self.queue.is_empty() {
            self.shut();
        }
    }

    pub(crate) fn shut(&mut self) {
        if !self.shut {
            self.shut = true;
            let _ = self.stream.shutdown(Shutdown::Both);
        }
    }

    pub(crate) fn flush(&mut self) {
        if self.shut {
            return;
        }
        if self.queue.sealed() {
            self.pixels = None;
        }
        let sent = self.queue.flush(&self.stream).and_then(|count| {
            self.accepted = self.accepted.saturating_add(count as u64);
            self.pull()
        });
        if sent.is_err() || (self.queue.sealed() && self.queue.is_empty()) {
            self.shut();
        }
    }

    fn pull(&mut self) -> io::Result<()> {
        for _ in 0..PIXEL_PIECES_PER_FLUSH {
            let Some(Pixels { object, sent }) = &mut self.pixels else {
                break;
            };
            if !self.queue.is_empty() {
                break;
            }
            let rest = object.bytes().get(*sent..).unwrap_or_default();
            if rest.is_empty() {
                self.pixels = None;
                break;
            }
            let piece = rest.get(..PIECE).unwrap_or(rest);
            match write_slices(&self.stream, &[IoSlice::new(piece)])? {
                0 => break,
                count => {
                    *sent = sent.saturating_add(count);
                    self.accepted = self.accepted.saturating_add(count as u64);
                }
            }
        }
        if self
            .pixels
            .as_ref()
            .is_some_and(|pixels| pixels.sent >= pixels.object.bytes().len())
        {
            self.pixels = None;
        }
        Ok(())
    }

    pub(crate) fn streaming(&self) -> bool {
        self.pixels.is_some()
    }

    pub(crate) fn send_pixels(&mut self, head: Vec<u8>, object: Named) {
        self.send(head);
        if self.is_open() {
            self.pixels = Some(Pixels { object, sent: 0 });
            self.flush();
        }
    }

    pub(crate) fn send_reply(&mut self, bytes: Vec<u8>) {
        if self.is_open() {
            self.queue.push_reply(bytes);
            self.flush();
        }
    }

    pub(crate) fn send(&mut self, bytes: Vec<u8>) {
        if self.is_open() {
            self.queue.push_vec(bytes);
            self.flush();
        }
    }

    fn queue_tail(&mut self, header: &[u8], written: usize, payload: &[u8]) {
        let skip = written.saturating_sub(header.len());
        self.queue.push_tail(&[
            header.get(written..).unwrap_or_default(),
            payload.get(skip..).unwrap_or_default(),
        ]);
    }

    pub(crate) fn record(
        &mut self,
        fit: Fit,
        record: Record,
        offset: u64,
        payload: &[u8],
    ) -> Written {
        if !self.is_open() {
            return Written::Closed;
        }
        let header = Header::new(record, offset, payload.len());
        let written = if self.available() {
            match write_slices(
                &self.stream,
                &[IoSlice::new(header.bytes()), IoSlice::new(payload)],
            ) {
                Ok(count) => {
                    self.refused = count == 0;
                    self.accepted = self.accepted.saturating_add(count as u64);
                    count
                }
                Err(_) => {
                    self.shut();
                    return Written::Closed;
                }
            }
        } else {
            0
        };
        if written == header.size().saturating_add(payload.len()) {
            Written::Accepted
        } else if written > 0 {
            self.queue_tail(header.bytes(), written, payload);
            Written::Queued
        } else if fit == Fit::Cap {
            Written::Blocked
        } else if self.queue.push(&[header.bytes(), payload], fit) {
            Written::Queued
        } else {
            self.flush();
            Written::Closed
        }
    }

    pub(crate) fn send_batch(&mut self, batch: &Batch, ring: &Reader) -> Option<usize> {
        if !self.is_open() {
            return None;
        }
        let mut payloads: [&[u8]; BATCH] = [&[]; BATCH];
        for (slot, entry) in payloads.iter_mut().zip(&batch.entries) {
            let skipped = ring
                .payload(entry.pos)
                .ok()
                .and_then(|payload| payload.get(entry.skip..))
                .and_then(|payload| payload.get(..entry.len));
            let Some(payload) = skipped else {
                self.close();
                return None;
            };
            *slot = payload;
        }
        let mut slices = [IoSlice::new(&[]); 2 * BATCH];
        for (pair, (entry, payload)) in slices.chunks_mut(2).zip(batch.entries.iter().zip(payloads))
        {
            if let [header, body] = pair {
                *header = IoSlice::new(entry.header.bytes());
                *body = IoSlice::new(payload);
            }
        }
        let count = batch.entries.len();
        let mut remaining = if self.available() {
            match write_slices(&self.stream, slices.get(..2 * count).unwrap_or_default()) {
                Ok(written) => {
                    self.refused = written == 0;
                    self.accepted = self.accepted.saturating_add(written as u64);
                    written
                }
                Err(_) => {
                    self.shut();
                    return None;
                }
            }
        } else {
            0
        };
        let mut accepted = 0;
        for (entry, payload) in batch.entries.iter().zip(payloads) {
            let total = entry.header.size().saturating_add(payload.len());
            if remaining >= total {
                remaining = remaining.saturating_sub(total);
                accepted += 1;
                continue;
            }
            if remaining > 0 {
                self.queue_tail(entry.header.bytes(), remaining, payload);
                accepted += 1;
            }
            break;
        }
        Some(accepted)
    }
}

verus! {

pub(crate) const BATCH: usize = 64;

#[derive(Clone, Copy)]
struct Entry {
    header: Header,
    pos: Pos,
    skip: usize,
    len: usize,
    next: Pos,
    end: u64,
}

#[verifier::external_type_specification]
#[verifier::external_body]
#[allow(dead_code, unreachable_pub)]
pub struct ExHeader(Header);

#[verifier::external_type_specification]
#[allow(dead_code, unreachable_pub)]
pub struct ExRecord(Record);

// Assumes: it builds the websocket header of a record, as the wire format requires.
#[verifier::external_fn_specification]
#[allow(dead_code, unreachable_pub)]
pub fn ex_header_new(record: Record, offset: u64, len: usize) -> (header: Header) {
    Header::new(record, offset, len)
}

pub(crate) struct Batch {
    entries: Vec<Entry>,
}

impl View for Batch {
    type V = Seq<(Pos, u64)>;

    closed spec fn view(&self) -> Seq<(Pos, u64)> {
        self.entries@.map_values(|e: Entry| (e.next, e.end))
    }
}

impl Batch {
    pub(crate) fn new() -> (b: Batch)
        ensures
            b@.len() == 0,
    {
        Batch { entries: Vec::new() }
    }

    pub(crate) fn len(&self) -> (n: usize)
        ensures
            n == self@.len(),
    {
        self.entries.len()
    }

    pub(crate) fn full(&self) -> (b: bool)
        ensures
            b == (self@.len() == BATCH),
    {
        self.entries.len() == BATCH
    }

    pub(crate) fn add(
        &mut self,
        offset: u64,
        pos: Pos,
        skip: usize,
        len: usize,
        next: Pos,
        end: u64,
    )
        ensures
            final(self)@ == old(self)@.push((next, end)),
    {
        let header = Header::new(Record::Output, offset, len);
        self.entries.push(Entry { header, pos, skip, len, next, end });
    }

    pub(crate) fn sent(&mut self, accepted: usize) -> (r: Option<(Pos, u64)>)
        ensures
            final(self)@.len() == 0,
            match r {
                Some(last) => 0 < accepted <= old(self)@.len() && last == old(self)@[accepted - 1],
                None => accepted == 0 || accepted > old(self)@.len(),
            },
    {
        let last = if accepted == 0 || accepted > self.entries.len() {
            None
        } else {
            Some((self.entries[accepted - 1].next, self.entries[accepted - 1].end))
        };
        self.entries.clear();
        last
    }
}

#[verifier::external_type_specification]
#[verifier::external_body]
#[allow(dead_code, unreachable_pub)]
pub struct ExOutput(Output);

#[verifier::external_type_specification]
#[allow(dead_code, unreachable_pub)]
pub struct ExWritten(Written);

impl Output {
    pub(crate) uninterp spec fn closed(&self) -> bool;

    pub(crate) uninterp spec fn waits(&self) -> bool;
}

// Assumes: waits() holds when the socket refused a write, or bytes (queued or spilled) or a pixel body wait to be sent.
#[verifier::external_fn_specification]
#[allow(dead_code, unreachable_pub)]
pub fn ex_waiting(output: &Output) -> (b: bool)
    ensures
        b == output.waits(),
{
    output.waiting()
}

// Assumes: available() is Open and not waiting. closed() holds when the output is not Open: it is shut, or it drains a queued close frame and takes no more writes.
#[verifier::external_fn_specification]
#[allow(dead_code, unreachable_pub)]
pub fn ex_available(output: &Output) -> (b: bool)
    ensures
        b ==> !output.closed() && !output.waits(),
{
    output.available()
}

// Assumes: close() leaves the output not Open. closed() holds when the output is not Open: it is shut, or it drains a queued close frame and takes no more writes.
#[verifier::external_fn_specification]
#[allow(dead_code, unreachable_pub)]
pub fn ex_close(output: &mut Output)
    ensures
        final(output).closed(),
{
    output.close()
}

// Assumes: send_batch() leaves the output not Open when it returns None, returns at most the batch length, and
// never reopens an output that is not Open. closed() holds when the output is not Open: it is shut, or it drains a queued close frame and takes no more writes.
#[verifier::external_fn_specification]
#[allow(dead_code, unreachable_pub)]
pub fn ex_send_batch(output: &mut Output, batch: &Batch, ring: &Reader) -> (r: Option<usize>)
    ensures
        old(output).closed() ==> final(output).closed(),
        r is None ==> final(output).closed(),
        r is Some ==> r->Some_0 <= batch@.len(),
{
    output.send_batch(batch, ring)
}

} // verus!

impl fmt::Debug for Batch {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Batch")
            .field("entries", &self.entries.len())
            .finish()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Payload {
    Bytes(Vec<u8>),
    Oversized,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Request {
    pub(crate) head: Head,
    pub(crate) body: Payload,
}

#[derive(Debug)]
pub(crate) enum Phase {
    Head,
    Body {
        head: Head,
        body: Vec<u8>,
        length: usize,
    },
    Oversized {
        head: Option<Head>,
        seen: usize,
        length: usize,
    },
    Handling,
    Streaming,
    Ws(Box<Link>),
    Closing,
}

#[derive(Debug)]
pub(crate) struct Conn {
    pub(crate) token: Token,
    pub(crate) timer: Timer,
    pub(crate) out: Output,
    input: Box<[u8]>,
    start: usize,
    end: usize,
    scanned: usize,
    eof: bool,
    pub(crate) phase: Phase,
}

impl Conn {
    pub(crate) fn new(stream: Verified, poll: &mut Poll, cap: usize) -> Conn {
        let stream = stream.into_stream();
        let token = poll.watch(stream.as_fd(), Interest::Read);
        Conn {
            token,
            timer: poll.timer(),
            out: Output::new(stream, cap),
            input: vec![0; MAX_HEAD].into_boxed_slice(),
            start: 0,
            end: 0,
            scanned: 0,
            eof: false,
            phase: Phase::Head,
        }
    }

    pub(crate) fn role(&self) -> Option<&Role> {
        match &self.phase {
            Phase::Ws(link) => Some(&link.role),
            _ => None,
        }
    }

    pub(crate) fn role_mut(&mut self) -> Option<(&mut Role, Wire<'_>)> {
        let Conn { out, phase, .. } = self;
        let Phase::Ws(link) = phase else {
            return None;
        };
        let Link { ws, role } = &mut **link;
        Some((role, Wire { ws, out }))
    }

    pub(crate) fn interest(&self) -> Interest {
        let read = match self.phase {
            Phase::Head | Phase::Body { .. } | Phase::Oversized { .. } => {
                !self.eof && !self.out.backed_up()
            }
            Phase::Ws(_) => !self.eof,
            Phase::Handling | Phase::Streaming | Phase::Closing => false,
        };
        match self.out.life() {
            Life::Open => Interest::of(read, self.out.waiting()),
            Life::Draining => Interest::Write,
            Life::Shut => Interest::Idle,
        }
    }

    pub(crate) fn reading_http(&self) -> bool {
        self.out.is_open()
            && !self.eof
            && !self.out.backed_up()
            && matches!(
                self.phase,
                Phase::Head | Phase::Body { .. } | Phase::Oversized { .. }
            )
    }

    pub(crate) fn read(&mut self, poll: &mut Poll, reads: &mut Reads) -> bool {
        if self.start > 0 {
            self.input.copy_within(self.start..self.end, 0);
            self.end = self.end.saturating_sub(self.start);
            self.start = 0;
        }
        let Some(window) = self.input.get_mut(self.end..) else {
            return false;
        };
        match poll.read(self.token, self.out.stream.as_fd(), window, reads) {
            Ok(Some(Read::Data(count))) => {
                self.end = self.end.saturating_add(count);
                true
            }
            Ok(Some(Read::End)) => {
                self.eof = true;
                true
            }
            Ok(None) => false,
            Err(_) => {
                self.out.close();
                false
            }
        }
    }

    fn close_with(&mut self, bytes: Vec<u8>) {
        self.phase = Phase::Closing;
        self.out.send(bytes);
    }

    fn refuse(&mut self, status: Status) {
        self.close_with(http::response(
            status,
            &[("connection", "close"), ("content-length", "0")],
            b"",
        ));
    }

    pub(crate) fn next_request(&mut self) -> Option<Request> {
        while self.out.is_open() {
            let buffered = self.input.get(self.start..self.end).unwrap_or_default();
            match &mut self.phase {
                Phase::Head if buffered.is_empty() => {
                    if self.eof {
                        self.phase = Phase::Closing;
                    }
                    return None;
                }
                Phase::Head => match http::parse_head(buffered, &mut self.scanned) {
                    Parsed::Partial => {
                        if self.eof {
                            self.out.close();
                        }
                        return None;
                    }
                    Parsed::BadLine => self.out.close(),
                    Parsed::Invalid => self.close_with(http::BAD_REQUEST.to_vec()),
                    Parsed::TooLarge => self.refuse(Status::HeadTooLarge),
                    Parsed::Complete { head, size } => {
                        self.start = self.start.saturating_add(size);
                        self.scanned = 0;
                        match head.framing() {
                            Framing::Chunked => self.refuse(Status::LengthRequired),
                            Framing::Invalid => self.close_with(http::BAD_REQUEST.to_vec()),
                            Framing::Length(0) => {
                                return Some(Request {
                                    head,
                                    body: Payload::Bytes(Vec::new()),
                                });
                            }
                            Framing::Length(length) => {
                                self.phase = Phase::Body {
                                    head,
                                    body: Vec::with_capacity(length),
                                    length,
                                }
                            }
                            Framing::Oversized(length) => {
                                self.phase = Phase::Oversized {
                                    head: Some(head),
                                    seen: 0,
                                    length,
                                }
                            }
                        }
                    }
                },
                Phase::Body { body, length, .. } => {
                    let wanted = length.saturating_sub(body.len()).min(buffered.len());
                    body.extend_from_slice(buffered.get(..wanted).unwrap_or_default());
                    self.start = self.start.saturating_add(wanted);
                    if body.len() < *length {
                        if self.eof {
                            self.out.close();
                        }
                        return None;
                    }
                    let Phase::Body { head, body, .. } =
                        std::mem::replace(&mut self.phase, Phase::Head)
                    else {
                        return None;
                    };
                    return Some(Request {
                        head,
                        body: Payload::Bytes(body),
                    });
                }
                Phase::Oversized { head, seen, length } => {
                    let skipped = length.saturating_sub(*seen).min(buffered.len());
                    *seen = seen.saturating_add(skipped);
                    self.start = self.start.saturating_add(skipped);
                    let ready = http::oversized(*seen).then(|| head.take()).flatten();
                    if seen == length {
                        self.phase = Phase::Head;
                    } else if self.eof {
                        self.out.close();
                    }
                    if let Some(head) = ready {
                        return Some(Request {
                            head,
                            body: Payload::Oversized,
                        });
                    }
                    if !matches!(self.phase, Phase::Head) {
                        return None;
                    }
                }
                Phase::Handling | Phase::Streaming | Phase::Ws(_) | Phase::Closing => return None,
            }
        }
        None
    }

    pub(crate) fn rest(&mut self) -> Vec<u8> {
        let rest = self
            .input
            .get(self.start..self.end)
            .unwrap_or_default()
            .to_vec();
        self.input = Box::default();
        self.start = 0;
        self.end = 0;
        rest
    }

    pub(crate) fn settle(&mut self) {
        if matches!(self.phase, Phase::Closing) && !self.out.waiting() {
            self.out.close();
        }
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::config::QUEUE_BYTES as CAP;
    use ko_sys::event::{Events, Mode};
    use std::io::Read as _;
    use std::path::PathBuf;

    fn respond_ok(conn: &mut Conn) {
        conn.out.send(http::response(
            Status::Ok,
            &[("content-length", "2")],
            b"ok",
        ));
    }

    fn step(poll: &mut Poll, conn: &mut Conn, handler: &mut dyn FnMut(&mut Conn, Request)) {
        let mut events = Events::default();
        poll.turn(Mode::Peek, &mut events).unwrap();
        for &ready in events.ready() {
            let ready = poll.wants(ready);
            if ready.write {
                conn.out.flush();
            }
            if ready.read {
                let mut reads = Reads::new();
                while conn.reading_http() && conn.read(poll, &mut reads) {
                    while let Some(request) = conn.next_request() {
                        handler(conn, request);
                    }
                }
            }
        }
        while let Some(request) = conn.next_request() {
            handler(conn, request);
        }
        conn.settle();
        poll.interest(conn.token, conn.interest());
        if conn.out.is_shut() {
            let (closed, _) = UnixStream::pair().unwrap();
            drop(std::mem::replace(&mut conn.out.stream, closed));
        }
    }

    struct Pair {
        poll: Poll,
        conn: Conn,
        client: UnixStream,
    }

    fn pair() -> Pair {
        let (client, server) = UnixStream::pair().unwrap();
        client.set_nonblocking(true).unwrap();
        let mut poll = Poll::new();
        let conn = Conn::new(Verified::admit(server).unwrap(), &mut poll, CAP);
        Pair { poll, conn, client }
    }

    fn line(prefix: &str, size: usize) -> String {
        format!("{prefix}{}\r\n\r\n", "a".repeat(size - prefix.len() - 4))
    }

    #[derive(Debug, PartialEq, Eq)]
    struct Exchanged {
        statuses: Vec<String>,
        closed: bool,
        bounded: bool,
    }

    fn exchange(writes: &[&[u8]], handler: &mut dyn FnMut(&mut Conn, Request)) -> Exchanged {
        let Pair {
            mut poll,
            mut conn,
            mut client,
        } = pair();
        for chunk in writes {
            let mut sent = 0;
            let mut rounds = 0;
            while sent < chunk.len() && rounds < 2000 {
                rounds += 1;
                match client.write(&chunk[sent..]) {
                    Ok(count) => sent += count,
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                    Err(_) => break,
                }
                step(&mut poll, &mut conn, handler);
            }
            step(&mut poll, &mut conn, handler);
        }
        let mut reply = Vec::new();
        let mut buffer = [0; 4096];
        let mut eof = false;
        for _ in 0..50 {
            step(&mut poll, &mut conn, handler);
            while !eof {
                match client.read(&mut buffer) {
                    Ok(0) => eof = true,
                    Ok(count) => reply.extend_from_slice(&buffer[..count]),
                    Err(_) => break,
                }
            }
        }
        let reply = String::from_utf8_lossy(&reply).into_owned();
        Exchanged {
            statuses: reply
                .split("HTTP/1.1 ")
                .skip(1)
                .map(|reply| reply[..3].to_owned())
                .collect(),
            closed: conn.out.is_shut(),
            bounded: conn.end - conn.start <= MAX_HEAD,
        }
    }

    fn show(name: &str, exchanged: Exchanged) -> String {
        format!(
            "{name}: {} closed {} bounded {}",
            exchanged.statuses.join(","),
            exchanged.closed,
            exchanged.bounded
        )
    }

    #[test]
    fn a_request_head_is_limited_as_a_whole_however_it_arrives() {
        let mut ok = |conn: &mut Conn, _| respond_ok(conn);
        let prefix = "GET / HTTP/1.1\r\nHost: ko\r\nX: ";
        let mut shown = Vec::new();
        for size in [MAX_HEAD - 1, MAX_HEAD, MAX_HEAD + 1] {
            let head = line(prefix, size);
            shown.push(show(
                &size.to_string(),
                exchange(&[head.as_bytes()], &mut ok),
            ));
        }
        let split = line(prefix, MAX_HEAD + 1);
        let pieces: Vec<&[u8]> = split.as_bytes().chunks(7).collect();
        shown.push(show("split limit", exchange(&pieces, &mut ok)));
        for size in [
            MAX_HEAD - 1,
            MAX_HEAD,
            MAX_HEAD + 1,
            MAX_HEAD + 2,
            MAX_HEAD + 100,
            MAX_HEAD + 4000,
            4 * MAX_HEAD,
        ] {
            let request = format!("GET /{} HTTP/1.1\r\n\r\n", "a".repeat(size - 18));
            shown.push(show(
                &format!("line {size}"),
                exchange(&[request.as_bytes()], &mut ok),
            ));
        }
        let many = format!(
            "GET / HTTP/1.1\r\nHost: ko\r\n{}\r\n",
            "A: b\r\n".repeat(4000)
        );
        shown.push(show("many headers", exchange(&[many.as_bytes()], &mut ok)));
        let small = format!(
            "GET / HTTP/1.1\r\nHost: ko\r\nX: {}\r\n\r\n",
            "a".repeat(9000)
        );
        let two = format!("{small}{small}");
        shown.push(show("two pipelined", exchange(&[two.as_bytes()], &mut ok)));
        let upgrade = "GET /client HTTP/1.1\r\nHost: ko\r\nUpgrade: websocket\r\n\
                       Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\
                       Sec-WebSocket-Version: 13\r\nX: ";
        let mut reached = false;
        let oversized = line(upgrade, MAX_HEAD + 1);
        shown.push(show(
            "oversized upgrade",
            exchange(&[oversized.as_bytes()], &mut |_, _| reached = true),
        ));
        shown.push(format!("upgrade handler reached: {reached}"));
        let body = "b".repeat(40_000);
        let posted = format!(
            "POST / HTTP/1.1\r\nHost: ko\r\nContent-Length: {}\r\n\r\n{body}{small}",
            body.len()
        );
        shown.push(show(
            "head then 40000 body bytes then head",
            exchange(&[posted.as_bytes()], &mut ok),
        ));
        assert_eq!(
            shown,
            [
                "16383: 200 closed false bounded true",
                "16384: 200 closed false bounded true",
                "16385: 431 closed true bounded true",
                "split limit: 431 closed true bounded true",
                "line 16383: 200 closed false bounded true",
                "line 16384: 200 closed false bounded true",
                "line 16385: 431 closed true bounded true",
                "line 16386: 431 closed true bounded true",
                "line 16484: 431 closed true bounded true",
                "line 20384: 431 closed true bounded true",
                "line 65536: 431 closed true bounded true",
                "many headers: 431 closed true bounded true",
                "two pipelined: 200,200 closed false bounded true",
                "oversized upgrade: 431 closed true bounded true",
                "upgrade handler reached: false",
                "head then 40000 body bytes then head: 200,200 closed false bounded true",
            ]
        );
    }

    #[test]
    fn a_request_head_that_never_ends_does_not_grow_the_heap() {
        let Pair {
            mut poll,
            mut conn,
            mut client,
        } = pair();
        let data = format!(
            "GET / HTTP/1.1\r\nHost: ko\r\n{}",
            "A: b\r\n".repeat(700_000)
        );
        let mut sent = 0;
        let mut held = 0;
        while sent < data.len() && conn.out.is_open() {
            let end = data.len().min(sent + 65536);
            if let Ok(count) = client.write(&data.as_bytes()[sent..end]) {
                sent += count;
            }
            step(&mut poll, &mut conn, &mut |conn, _| respond_ok(conn));
            held = held.max(conn.input.len() + conn.out.queue.bytes);
        }
        assert_eq!(
            (
                conn.out.is_open(),
                sent < data.len(),
                held <= MAX_HEAD + 1024
            ),
            (false, true, true)
        );
    }

    #[test]
    fn an_oversized_head_after_a_pipelined_request_is_answered_after_the_full_first_response() {
        let size = 3_000_000;
        let Pair {
            mut poll,
            mut conn,
            mut client,
        } = pair();
        let mut big = |conn: &mut Conn, _| {
            let length = size.to_string();
            conn.out.send(http::response(
                Status::Ok,
                &[("content-length", &length)],
                &vec![b'x'; size],
            ));
        };
        let data = format!(
            "GET / HTTP/1.1\r\nHost: ko\r\n\r\n{}",
            line("GET / HTTP/1.1\r\nX: ", MAX_HEAD + 1)
        );
        let mut sent = 0;
        for _ in 0..200 {
            if let Ok(count) = client.write(&data.as_bytes()[sent..]) {
                sent += count;
            }
            step(&mut poll, &mut conn, &mut big);
        }
        let mut reply = Vec::new();
        let mut buffer = vec![0; 65536];
        let mut eof = false;
        let mut rounds = 0;
        while !eof && rounds < 20000 {
            rounds += 1;
            step(&mut poll, &mut conn, &mut big);
            match client.read(&mut buffer) {
                Ok(0) => eof = true,
                Ok(count) => reply.extend_from_slice(&buffer[..count]),
                Err(_) => {}
            }
        }
        let refusal = http::response(
            Status::HeadTooLarge,
            &[("connection", "close"), ("content-length", "0")],
            b"",
        );
        let xs = reply.iter().filter(|&&byte| byte == b'x').count();
        assert_eq!(
            (
                eof,
                reply.starts_with(b"HTTP/1.1 200 OK"),
                xs,
                reply.ends_with(&refusal)
            ),
            (true, true, size, true)
        );
    }

    #[test]
    fn bytes_that_arrive_while_a_request_waits_for_its_handler_are_kept_until_it_is_answered() {
        let Pair {
            mut poll,
            mut conn,
            mut client,
        } = pair();
        let body = "x".repeat(100_000);
        let data = format!(
            "POST / HTTP/1.1\r\nHost: ko\r\nContent-Length: {}\r\n\r\n{body}GET / HTTP/1.1\r\n\r\n",
            body.len()
        );
        let bodies = std::cell::RefCell::new(Vec::new());
        let mut wait = |conn: &mut Conn, request: Request| {
            bodies.borrow_mut().push(match request.body {
                Payload::Bytes(body) => body.len(),
                Payload::Oversized => usize::MAX,
            });
            conn.phase = Phase::Handling;
        };
        let mut sent = 0;
        for _ in 0..200 {
            if let Ok(count) = client.write(&data.as_bytes()[sent..]) {
                sent += count;
            }
            step(&mut poll, &mut conn, &mut wait);
        }
        let waiting = (
            bodies.borrow().clone(),
            sent,
            conn.out.is_open(),
            conn.interest(),
            conn.out.waiting(),
        );
        respond_ok(&mut conn);
        conn.phase = Phase::Head;
        for _ in 0..20 {
            step(&mut poll, &mut conn, &mut wait);
        }
        let mut reply = vec![0; 4096];
        let count = client.read(&mut reply).unwrap();
        let statuses = String::from_utf8_lossy(&reply[..count])
            .matches("HTTP/1.1 200")
            .count();
        assert_eq!(
            (waiting, bodies.into_inner(), statuses),
            (
                (vec![100_000], data.len(), true, Interest::Idle, false),
                vec![100_000, 0],
                1
            )
        );
    }

    pub(crate) fn output() -> (Output, UnixStream) {
        output_with(CAP)
    }

    fn output_with(cap: usize) -> (Output, UnixStream) {
        let (writer, reader) = UnixStream::pair().unwrap();
        writer.set_nonblocking(true).unwrap();
        reader.set_nonblocking(true).unwrap();
        (Output::new(writer, cap), reader)
    }

    pub(crate) fn full_output() -> (Output, UnixStream) {
        let (out, reader) = output();
        while (&out.stream).write(&[0; 4096]).is_ok() {}
        (out, reader)
    }

    pub(crate) fn drain(out: &mut Output, reader: &mut UnixStream) -> Vec<u8> {
        let mut seen = Vec::new();
        let mut buffer = vec![0; 65536];
        for _ in 0..100_000 {
            match reader.read(&mut buffer) {
                Ok(0) => break,
                Ok(count) => seen.extend_from_slice(&buffer[..count]),
                Err(_) => {
                    out.writable();
                    if !out.waiting() {
                        break;
                    }
                }
            }
        }
        while let Ok(count) = reader.read(&mut buffer) {
            if count == 0 {
                break;
            }
            seen.extend_from_slice(&buffer[..count]);
        }
        seen
    }

    #[test]
    fn a_view_that_never_reads_is_closed_before_its_queue_grows_without_bound() {
        let (mut out, reader) = output();
        let payload = vec![0; 1 << 20];
        let closed_at = (1..=80)
            .find(|_| out.record(Fit::Spill, Record::Snapshot, 0, &payload) == Written::Closed);
        assert!(closed_at.is_some());
        drop(reader);
    }

    const MESSAGE: usize = 30_000;

    fn spilling_output(name: &str, cap: usize, limit: u64) -> (Output, UnixStream, PathBuf) {
        let dir = crate::server::tests::scratch(name);
        let (mut out, reader) = output_with(cap);
        ko_sys::sock::set_send_buffer(out.stream.as_fd(), 4096).unwrap();
        out.view(dir.as_path().into(), limit, b"BYE".to_vec());
        (out, reader, dir)
    }

    fn message(index: u64) -> Vec<u8> {
        let payload = vec![index as u8; MESSAGE];
        let header = Header::new(Record::Snapshot, index, MESSAGE);
        [header.bytes(), &payload].concat()
    }

    #[test]
    fn a_snapshot_over_the_queue_cap_spills_and_drains_in_order_before_later_writes() {
        let cap = 20_000;
        let (mut out, mut reader, dir) = spilling_output("order", cap, 1 << 30);
        let mut expected = Vec::new();
        for index in 0..40 {
            let payload = vec![index as u8; MESSAGE];
            assert_ne!(
                out.record(Fit::Spill, Record::Snapshot, index, &payload),
                Written::Closed
            );
            expected.extend(message(index));
        }
        assert!(out.queue.spilling(), "the snapshot did not spill");
        assert!(
            out.queue.bytes <= cap + MESSAGE + 16,
            "{} bytes wait in memory",
            out.queue.bytes
        );
        out.send(b"tail".to_vec());
        expected.extend_from_slice(b"tail");
        assert!(out.waiting() && !out.available());
        let seen = drain(&mut out, &mut reader);
        assert!(
            seen == expected,
            "{} bytes, {} expected",
            seen.len(),
            expected.len()
        );
        assert!(!out.queue.spilling() && !out.waiting() && out.is_open());
        std::fs::remove_dir(&dir).unwrap();
    }

    #[test]
    fn a_flush_sends_at_most_its_budget_and_the_spill_keeps_the_write_interest() {
        let (mut out, mut reader, dir) = spilling_output("budget", 20_000, 1 << 30);
        let total = (FLUSH_BYTES / MESSAGE + 20) as u64;
        for index in 0..total {
            let payload = vec![index as u8; MESSAGE];
            out.record(Fit::Spill, Record::Snapshot, index, &payload);
        }
        ko_sys::sock::set_send_buffer(out.stream.as_fd(), 8 << 20).unwrap();
        let before = out.accepted();
        out.flush();
        let sent = (out.accepted() - before) as usize;
        assert!(
            sent <= FLUSH_BYTES + 64 * (MESSAGE + 16) && out.waiting(),
            "{sent} bytes in one flush"
        );
        let mut poll = Poll::new();
        let token = poll.watch(out.stream.as_fd(), Interest::Idle);
        poll.interest(token, Interest::of(false, out.waiting()));
        assert_eq!(poll.interest_of(token), Interest::Write);
        let all = drain(&mut out, &mut reader).len();
        assert_eq!(all, total as usize * message(0).len());
        std::fs::remove_dir(&dir).unwrap();
    }

    #[test]
    fn a_spill_over_its_limit_ends_the_stream_at_a_message_with_the_farewell() {
        let (mut out, mut reader, dir) = spilling_output("limit", 20_000, 100_000);
        let mut closed = false;
        for index in 0..40 {
            let payload = vec![index as u8; MESSAGE];
            closed |= out.record(Fit::Spill, Record::Snapshot, index, &payload) == Written::Closed;
        }
        assert!(closed, "the spill limit did not apply");
        out.close();
        assert_eq!(out.life(), Life::Draining, "a close dropped the farewell");
        let seen = drain(&mut out, &mut reader);
        let body = seen
            .strip_suffix(b"BYE")
            .expect("the farewell ends the stream");
        let whole = message(0).len();
        assert!(
            !body.is_empty() && body.len().is_multiple_of(whole),
            "{} bytes",
            body.len()
        );
        let all: Vec<u8> = (0..40).flat_map(message).collect();
        assert!(body == &all[..body.len()]);
        assert_eq!(out.life(), Life::Shut);
        std::fs::remove_dir(&dir).unwrap();
    }

    #[test]
    fn a_partial_write_inside_the_last_batch_record_is_flushed_once_the_reader_drains() {
        let (mut out, mut reader) = output();
        ko_sys::sock::set_send_buffer(out.stream.as_fd(), 4096).unwrap();
        let mut ring = Reader::create(1 << 20).unwrap();
        let mut writer = ring.writer().unwrap();
        let mut batch = Batch::new();
        let mut at = ring.tail();
        let mut expected = 0;
        for len in [100, 150_000] {
            writer.available();
            writer.put(ko_pane_wire::ring::RecordKind::Bytes, &vec![7; len]);
            ring.head();
            let record = ring.record(at).unwrap();
            batch.add(
                record.offset.get(),
                at,
                0,
                len,
                record.next,
                record.offset.get() + record.len,
            );
            expected += batch.entries.last().unwrap().header.size() + len;
            at = record.next;
        }
        let accepted = out.send_batch(&batch, &ring);
        let mut received = 0;
        let mut buffer = vec![0; 65536];
        for _ in 0..1000 {
            if received == expected {
                break;
            }
            if let Ok(count) = reader.read(&mut buffer) {
                received += count;
            }
            out.flush();
        }
        assert_eq!((accepted, received), (Some(2), expected));
    }

    proptest::proptest! {
        #[test]
        fn a_head_of_n_bytes_is_answered_up_to_the_limit_and_refused_above_also_after_a_pipelined_request(
            size in 40usize..20_000,
            pipelined in proptest::bool::ANY,
        ) {
            let head = line("GET / HTTP/1.1\r\nX: ", size);
            let data = if pipelined {
                format!("GET / HTTP/1.1\r\nHost: ko\r\n\r\n{head}")
            } else {
                head
            };
            let exchanged = exchange(&[data.as_bytes()], &mut |conn, _| respond_ok(conn));
            let last = if size <= MAX_HEAD { "200" } else { "431" };
            let mut statuses = if pipelined { vec!["200".to_owned()] } else { Vec::new() };
            statuses.push(last.to_owned());
            proptest::prop_assert_eq!(exchanged.statuses, statuses);
            proptest::prop_assert_eq!(exchanged.closed, size > MAX_HEAD);
        }
    }
}
