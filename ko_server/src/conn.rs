use std::collections::VecDeque;
use std::io::{self, IoSlice, Write};
use std::net::Shutdown;
use std::os::fd::AsFd;
use std::os::unix::net::UnixStream;

use ko_pane_wire::ring::{Pos, Reader};
use ko_sys::event::{Interest, Poll, Read, Reads, Timer, Token};

use crate::http::{self, Framing, Head, MAX_HEAD, Parsed, Status};
use crate::link::{Link, Role, Wire};
use crate::server::Verified;
use crate::ws::{self, MAX_HEADER, Record};

const MAX_QUEUED: usize = 64 << 20;
const BATCH: usize = 64;
const SLICES: usize = 64;

#[derive(Debug, Default)]
pub(crate) struct Queue {
    chunks: VecDeque<Vec<u8>>,
    sent: usize,
    bytes: usize,
}

impl Queue {
    pub(crate) fn push(&mut self, bytes: Vec<u8>) -> bool {
        let total = self.bytes.saturating_add(bytes.len());
        if total > MAX_QUEUED {
            return false;
        }
        if !bytes.is_empty() {
            self.bytes = total;
            self.chunks.push_back(bytes);
        }
        true
    }

    fn is_empty(&self) -> bool {
        self.chunks.is_empty()
    }

    fn written(&mut self, mut count: usize) {
        self.bytes = self.bytes.saturating_sub(count);
        while let Some(front) = self.chunks.front() {
            let left = front.len().saturating_sub(self.sent);
            if count < left {
                self.sent = self.sent.saturating_add(count);
                return;
            }
            count = count.saturating_sub(left);
            self.sent = 0;
            self.chunks.pop_front();
        }
    }

    fn flush(&mut self, stream: &UnixStream) -> io::Result<()> {
        while !self.is_empty() {
            let mut slices = [IoSlice::new(&[]); SLICES];
            let mut used = 0;
            for (slot, (index, chunk)) in slices.iter_mut().zip(self.chunks.iter().enumerate()) {
                let skip = if index == 0 { self.sent } else { 0 };
                *slot = IoSlice::new(chunk.get(skip..).unwrap_or_default());
                used = index.saturating_add(1);
            }
            match write_slices(stream, slices.get(..used).unwrap_or_default())? {
                0 => return Ok(()),
                count => self.written(count),
            }
        }
        Ok(())
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
pub(crate) struct Output {
    stream: UnixStream,
    queue: Queue,
    open: bool,
}

fn write_slices(stream: &UnixStream, slices: &[IoSlice<'_>]) -> io::Result<usize> {
    match ko_sys::retry::retry(|| (&*stream).write_vectored(slices)) {
        Err(error) if error.kind() == io::ErrorKind::WouldBlock => Ok(0),
        written => written,
    }
}

impl Output {
    pub(crate) fn is_open(&self) -> bool {
        self.open
    }

    pub(crate) fn waiting(&self) -> bool {
        !self.queue.is_empty()
    }

    pub(crate) fn available(&self) -> bool {
        self.open && self.queue.is_empty()
    }

    pub(crate) fn parts(&mut self) -> (&UnixStream, &mut Queue) {
        (&self.stream, &mut self.queue)
    }

    pub(crate) fn close(&mut self) {
        if self.open {
            self.open = false;
            let _ = self.stream.shutdown(Shutdown::Both);
        }
    }

    pub(crate) fn flush(&mut self) {
        if self.open && self.queue.flush(&self.stream).is_err() {
            self.close();
        }
    }

    pub(crate) fn send(&mut self, bytes: Vec<u8>) {
        if self.open {
            if self.queue.push(bytes) {
                self.flush();
            } else {
                self.close();
            }
        }
    }

    fn queue_rest(&mut self, header: &[u8], written: usize, payload: &[u8]) -> bool {
        let skip = written.saturating_sub(header.len());
        let queued = self
            .queue
            .push(header.get(written..).unwrap_or_default().to_vec())
            && self
                .queue
                .push(payload.get(skip..).unwrap_or_default().to_vec());
        if !queued {
            self.close();
        }
        queued
    }

    pub(crate) fn record(
        &mut self,
        queue: bool,
        record: Record,
        offset: u64,
        payload: &[u8],
    ) -> Written {
        if !self.open {
            return Written::Closed;
        }
        let mut header = [0; MAX_HEADER];
        let size = ws::record_header(&mut header, record, offset, payload.len());
        let header = header.get(..size).unwrap_or_default();
        let written = if self.available() {
            match write_slices(&self.stream, &[IoSlice::new(header), IoSlice::new(payload)]) {
                Ok(count) => count,
                Err(_) => {
                    self.close();
                    return Written::Closed;
                }
            }
        } else {
            0
        };
        if written == size.saturating_add(payload.len()) {
            Written::Accepted
        } else if written == 0 && !queue {
            Written::Blocked
        } else if self.queue_rest(header, written, payload) {
            Written::Queued
        } else {
            Written::Closed
        }
    }

    pub(crate) fn send_batch(&mut self, batch: &Batch, ring: &Reader) -> Option<usize> {
        if !self.open {
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
                *header = IoSlice::new(entry.header());
                *body = IoSlice::new(payload);
            }
        }
        let count = batch.entries.len();
        let mut remaining = if self.available() {
            match write_slices(&self.stream, slices.get(..2 * count).unwrap_or_default()) {
                Ok(written) => written,
                Err(_) => {
                    self.close();
                    return None;
                }
            }
        } else {
            0
        };
        let mut accepted = 0;
        for (entry, payload) in batch.entries.iter().zip(payloads) {
            let total = entry.size.saturating_add(payload.len());
            if remaining >= total {
                remaining = remaining.saturating_sub(total);
                accepted += 1;
                continue;
            }
            if remaining > 0 {
                if !self.queue_rest(entry.header(), remaining, payload) {
                    return None;
                }
                accepted += 1;
            }
            break;
        }
        Some(accepted)
    }
}

#[derive(Debug, Clone, Copy)]
struct Entry {
    header: [u8; MAX_HEADER],
    size: usize,
    pos: Pos,
    skip: usize,
    len: usize,
    next: Pos,
    end: u64,
}

impl Entry {
    fn header(&self) -> &[u8] {
        self.header.get(..self.size).unwrap_or_default()
    }
}

#[derive(Debug, Default)]
pub(crate) struct Batch {
    entries: Vec<Entry>,
}

impl Batch {
    pub(crate) fn len(&self) -> usize {
        self.entries.len()
    }

    pub(crate) fn full(&self) -> bool {
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
    ) {
        let mut header = [0; MAX_HEADER];
        let size = ws::record_header(&mut header, Record::Output, offset, len);
        self.entries.push(Entry {
            header,
            size,
            pos,
            skip,
            len,
            next,
            end,
        });
    }

    pub(crate) fn sent(&mut self, accepted: usize) -> Option<(Pos, u64)> {
        let last = accepted
            .checked_sub(1)
            .and_then(|last| self.entries.get(last))
            .map(|entry| (entry.next, entry.end));
        self.entries.clear();
        last
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
    pub(crate) fn new(stream: Verified, poll: &mut Poll) -> Conn {
        let stream = stream.into_stream();
        let token = poll.watch(stream.as_fd(), Interest::Read);
        Conn {
            token,
            timer: poll.timer(),
            out: Output {
                stream,
                queue: Queue::default(),
                open: true,
            },
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
        let write = self.out.waiting();
        let read = match self.phase {
            Phase::Head | Phase::Body { .. } | Phase::Oversized { .. } | Phase::Ws(_) => !self.eof,
            Phase::Handling | Phase::Closing => false,
        };
        if self.out.is_open() {
            Interest::of(read, write)
        } else {
            Interest::Idle
        }
    }

    pub(crate) fn reading_http(&self) -> bool {
        self.out.is_open()
            && !self.eof
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
                Phase::Handling | Phase::Ws(_) | Phase::Closing => return None,
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
mod tests {
    use super::*;
    use ko_sys::event::{Events, Mode};
    use std::io::Read as _;

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
        if !conn.out.is_open() {
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
        let conn = Conn::new(Verified::admit(server).unwrap(), &mut poll);
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
            closed: !conn.out.is_open(),
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

    fn output() -> (Output, UnixStream) {
        let (writer, reader) = UnixStream::pair().unwrap();
        writer.set_nonblocking(true).unwrap();
        reader.set_nonblocking(true).unwrap();
        let out = Output {
            stream: writer,
            queue: Queue::default(),
            open: true,
        };
        (out, reader)
    }

    #[test]
    fn a_view_that_never_reads_is_closed_before_its_queue_grows_without_bound() {
        let (mut out, reader) = output();
        let payload = vec![0; 1 << 20];
        let closed_at =
            (1..=80).find(|_| out.record(true, Record::Snapshot, 0, &payload) == Written::Closed);
        assert!(closed_at.is_some());
        drop(reader);
    }

    #[test]
    fn a_partial_write_inside_the_last_batch_record_is_flushed_once_the_reader_drains() {
        let (mut out, mut reader) = output();
        ko_sys::sock::set_send_buffer(out.stream.as_fd(), 4096).unwrap();
        let mut ring = Reader::create(1 << 20).unwrap();
        let mut writer = ring.writer().unwrap();
        let mut batch = Batch::default();
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
            expected += batch.entries.last().unwrap().size + len;
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
