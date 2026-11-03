#![deny(clippy::indexing_slicing, clippy::arithmetic_side_effects)]

use std::io::{self, Cursor, Read, Write};
use std::os::fd::AsFd;
use std::time::{Duration, Instant};

use ko_pane_wire::ring::{SLICE_HEADER, SLICE_MAX};
use ko_sys::event::{Poll, PollRead, Reads, Token};
use tungstenite::protocol::frame::coding::{CloseCode, Data, OpCode};
use tungstenite::protocol::frame::{Frame as WireFrame, FrameHeader};
use tungstenite::protocol::{CloseFrame, Role as Side, WebSocketConfig, WebSocketContext};
use tungstenite::{Error, Message, Utf8Bytes};

use crate::conn::{Fit, Life, Output, Queue};
use crate::deflate::{self, Deflate};
use crate::http::{self, Head, MAX_HEAD, Status};
use crate::ids::ClientId;

const RECORD_HEADER: usize = 9;
const MAX_HEADER: usize = 10 + RECORD_HEADER;
const MAX_MESSAGE: usize = 1 << 20;
const MAX_SENT: usize = 32 << 20;
const IDLE: Duration = Duration::from_secs(30);
const PONG: Duration = Duration::from_secs(10);
const STALL: Duration = Duration::from_secs(10);
pub(crate) const OVERFLOW_REASON: &str = "view queue overflow";
pub(crate) const FIRST_PING: Duration = IDLE;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Record {
    Output,
    Snapshot,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BadRecord {
    Short,
    Kind(u8),
    Inflate,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Parsed<'a> {
    Output { offset: u64, data: &'a [u8] },
    Snapshot { offset: u64, slice: Vec<u8> },
}

pub(crate) fn with_packed_slice<R>(
    deflate: &mut Deflate,
    payload: &[u8],
    send: impl FnOnce(&[u8]) -> R,
) -> Option<R> {
    let (header, body) = payload.split_at_checked(SLICE_HEADER)?;
    Some(deflate.with_deflated(header, body, send))
}

pub fn parse_record(payload: &[u8]) -> Result<Parsed<'_>, BadRecord> {
    let (Some(&kind), Some(offset), Some(body)) = (
        payload.first(),
        payload
            .get(1..RECORD_HEADER)
            .and_then(|bytes| bytes.try_into().ok())
            .map(u64::from_le_bytes),
        payload.get(RECORD_HEADER..),
    ) else {
        return Err(BadRecord::Short);
    };
    match kind {
        1 => Ok(Parsed::Output { offset, data: body }),
        2 => {
            let (header, packed) = body
                .split_at_checked(SLICE_HEADER)
                .ok_or(BadRecord::Short)?;
            let slice = deflate::inflate(header, packed, SLICE_MAX).ok_or(BadRecord::Inflate)?;
            Ok(Parsed::Snapshot { offset, slice })
        }
        other => Err(BadRecord::Kind(other)),
    }
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct Header {
    bytes: [u8; MAX_HEADER],
    size: usize,
}

impl Header {
    pub(crate) fn new(record: Record, offset: u64, len: usize) -> Header {
        let mut bytes = [0; MAX_HEADER];
        let size = record_header(&mut bytes, record, offset, len);
        Header { bytes, size }
    }

    pub(crate) fn size(&self) -> usize {
        self.size
    }

    pub(crate) fn bytes(&self) -> &[u8] {
        self.bytes.get(..self.size).unwrap_or_default()
    }
}

fn record_header(out: &mut [u8; MAX_HEADER], record: Record, offset: u64, len: usize) -> usize {
    let header = FrameHeader {
        opcode: OpCode::Data(Data::Binary),
        ..FrameHeader::default()
    };
    let mut cursor = Cursor::new(&mut out[..]);
    let payload = u64::try_from(len).unwrap_or(u64::MAX).saturating_add(9);
    let _ = header.format(payload, &mut cursor);
    let _ = cursor.write_all(&[match record {
        Record::Output => 1,
        Record::Snapshot => 2,
    }]);
    let _ = cursor.write_all(&offset.to_le_bytes());
    usize::try_from(cursor.position()).unwrap_or(MAX_HEADER)
}

pub fn upgrade_request(method: &str, target: &str, client: Option<ClientId>) -> (Vec<u8>, String) {
    let key = tungstenite::handshake::client::generate_key();
    let extra = [
        ("Upgrade", "websocket"),
        ("Connection", "Upgrade"),
        ("Sec-WebSocket-Version", "13"),
        ("Sec-WebSocket-Key", key.as_str()),
    ];
    (http::call(method, target, client, &extra, b""), key)
}

pub fn accepted(response: &http::Response, key: &str) -> io::Result<()> {
    let accept = tungstenite::handshake::derive_accept_key(key.as_bytes());
    if response.status == 101 && response.header("sec-websocket-accept") == Some(&accept) {
        Ok(())
    } else {
        Err(io::Error::other(format!(
            "WebSocket upgrade failed: {} {}",
            response.status, response.reason
        )))
    }
}

pub(crate) fn handshake(head: &Head) -> Option<Vec<u8>> {
    let upgrade = head
        .header("upgrade")
        .is_some_and(|value| value.eq_ignore_ascii_case("websocket"));
    let connection = head.header("connection").is_some_and(|value| {
        value
            .split(',')
            .any(|token| token.trim().eq_ignore_ascii_case("upgrade"))
    });
    let version = head.header("sec-websocket-version") == Some("13");
    let key = head
        .header("sec-websocket-key")
        .filter(|key| !key.is_empty())?;
    (upgrade && connection && version).then(|| {
        let accept = tungstenite::handshake::derive_accept_key(key.as_bytes());
        http::response(
            Status::SwitchingProtocols,
            &[
                ("upgrade", "websocket"),
                ("connection", "upgrade"),
                ("sec-websocket-accept", &accept),
            ],
            b"",
        )
    })
}

#[derive(Debug)]
struct Io<'a> {
    source: Option<PollRead<'a>>,
    queue: &'a mut Queue,
}

impl Read for Io<'_> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        match self.source.as_mut() {
            Some(source) => source.read(buffer),
            None => Err(io::ErrorKind::WouldBlock.into()),
        }
    }
}

impl Write for Io<'_> {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if self.queue.push(&[bytes], Fit::Cap) {
            Ok(bytes.len())
        } else {
            Err(io::Error::other("connection queue full"))
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

pub(crate) fn overflow_close() -> Vec<u8> {
    let frame = WireFrame::close(Some(CloseFrame {
        code: CloseCode::Again,
        reason: OVERFLOW_REASON.into(),
    }));
    let mut bytes = Vec::new();
    let _ = frame.format(&mut bytes);
    bytes
}

fn writer(out: &mut Output) -> Io<'_> {
    Io {
        source: None,
        queue: out.parts().1,
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Next {
    Text(String),
    Wait,
    Close,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Ping {
    After(Duration),
    Expired,
}

#[derive(Debug)]
pub(crate) struct Ws {
    ctx: WebSocketContext,
    last: Instant,
    ping: Option<Instant>,
    accepted: u64,
    blocked: Option<Instant>,
}

impl Ws {
    pub(crate) fn new(part: Vec<u8>) -> Ws {
        let config = WebSocketConfig::default()
            .read_buffer_size(MAX_HEAD)
            .write_buffer_size(0)
            .max_message_size(Some(MAX_MESSAGE))
            .max_frame_size(Some(MAX_MESSAGE));
        Ws {
            ctx: WebSocketContext::from_partially_read(part, Side::Server, Some(config)),
            last: Instant::now(),
            ping: None,
            accepted: 0,
            blocked: None,
        }
    }

    pub(crate) fn next(
        &mut self,
        out: &mut Output,
        poll: &mut Poll,
        token: Token,
        reads: &mut Reads,
    ) -> Next {
        if !out.is_open() {
            return Next::Close;
        }
        let (stream, queue) = out.parts();
        let mut io = Io {
            source: Some(PollRead::new(poll, token, stream.as_fd(), reads)),
            queue,
        };
        let next = loop {
            match self.ctx.read(&mut io) {
                Ok(message) => {
                    self.last = Instant::now();
                    match message {
                        Message::Text(text) => break Next::Text(text.as_str().to_owned()),
                        Message::Pong(_) => self.ping = None,
                        Message::Ping(_) | Message::Frame(_) => {}
                        Message::Binary(_) | Message::Close(_) => break Next::Close,
                    }
                }
                Err(Error::Io(error)) if error.kind() == io::ErrorKind::WouldBlock => {
                    break Next::Wait;
                }
                Err(_) => break Next::Close,
            }
        };
        out.flush();
        if next == Next::Close {
            out.close();
        }
        next
    }

    pub(crate) fn send(&mut self, out: &mut Output, text: impl Into<Utf8Bytes>) {
        let text: Utf8Bytes = text.into();
        if !out.is_open() {
            return;
        }
        if text.as_str().len() > MAX_SENT
            || self
                .ctx
                .write(&mut writer(out), Message::Text(text))
                .is_err()
        {
            out.close();
            return;
        }
        out.flush();
    }

    pub(crate) fn reject(&mut self, out: &mut Output, kind: &'static str) {
        let send = out.available();
        self.close_with(out, CloseCode::Policy, kind, send);
        out.close();
    }

    pub(crate) fn finish(&mut self, out: &mut Output) {
        let send = out.is_open();
        self.close_with(out, CloseCode::Normal, "done", send);
    }

    fn close_with(&mut self, out: &mut Output, code: CloseCode, reason: &'static str, send: bool) {
        if send {
            let frame = CloseFrame {
                code,
                reason: reason.into(),
            };
            let _ = self.ctx.close(&mut writer(out), Some(frame));
            out.flush();
        }
    }

    // The time left before an output that makes no progress counts as stalled. The pong deadline
    // restarts while the output progresses, because a ping waits behind the queued messages.
    fn stall(&mut self, out: &Output, now: Instant) -> Option<Duration> {
        let moved = out.accepted() != self.accepted;
        self.accepted = out.accepted();
        if moved && self.ping.is_some() {
            self.ping = Some(now);
        }
        if moved || !out.waiting() {
            self.blocked = None;
            return None;
        }
        let since = *self.blocked.get_or_insert(now);
        Some(
            since
                .checked_add(STALL)
                .map_or(Duration::ZERO, |due| due.saturating_duration_since(now)),
        )
    }

    pub(crate) fn ping(&mut self, out: &mut Output, now: Instant) -> Ping {
        let stall = self.stall(out, now);
        if stall.is_some_and(|left| left.is_zero()) {
            out.shut();
            return Ping::Expired;
        }
        match out.life() {
            Life::Shut => return Ping::Expired,
            Life::Draining => return Ping::After(stall.unwrap_or(STALL)),
            Life::Open => {}
        }
        let due = match self.ping {
            Some(sent) => sent.checked_add(PONG),
            None => self.last.checked_add(IDLE),
        };
        if let Some(left) = due
            .and_then(|due| due.checked_duration_since(now))
            .filter(|left| !left.is_zero())
        {
            return Ping::After(stall.map_or(left, |stall| left.min(stall)));
        }
        if self.ping.is_some() {
            let send = out.available();
            self.close_with(out, CloseCode::Policy, "gone", send);
            out.shut();
            return Ping::Expired;
        }
        self.ping = Some(now);
        let _ = self
            .ctx
            .write(&mut writer(out), Message::Ping(Default::default()));
        out.flush();
        self.accepted = out.accepted();
        if out.is_shut() {
            Ping::Expired
        } else {
            Ping::After(PONG)
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Frame {
    pub opcode: u8,
    pub header: usize,
    pub length: usize,
}

pub fn parse_frame(buffer: &[u8]) -> Option<Frame> {
    let mut cursor = Cursor::new(buffer);
    let (header, length) = FrameHeader::parse(&mut cursor).ok()??;
    Some(Frame {
        opcode: u8::from(header.opcode),
        header: usize::try_from(cursor.position()).ok()?,
        length: usize::try_from(length).ok()?,
    })
}

pub fn masked(opcode: u8, fin: bool, payload: &[u8], key: [u8; 4], lie: i64) -> Vec<u8> {
    let declared = i64::try_from(payload.len())
        .unwrap_or(0)
        .saturating_add(lie);
    let header = FrameHeader {
        is_final: fin,
        opcode: OpCode::from(opcode),
        mask: Some(key),
        ..FrameHeader::default()
    };
    let mut frame = Vec::new();
    let _ = header.format(u64::try_from(declared).unwrap_or(0), &mut frame);
    frame.extend(
        payload
            .iter()
            .zip(key.iter().cycle())
            .map(|(byte, mask)| byte ^ mask),
    );
    frame
}

#[cfg(test)]
#[allow(clippy::indexing_slicing, clippy::arithmetic_side_effects)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixStream;

    use crate::conn::Conn;
    use crate::server::Verified;
    use std::io::Write;

    fn text(text: &str) -> Vec<u8> {
        masked(1, true, text.as_bytes(), [1, 2, 3, 4], 0)
    }

    fn snapshot_record(packed: &[u8]) -> Vec<u8> {
        [&[2][..], &7u64.to_le_bytes(), packed].concat()
    }

    fn packed(slice: &[u8]) -> Vec<u8> {
        with_packed_slice(&mut Deflate::new(), slice, |packed| packed.to_vec()).unwrap()
    }

    #[test]
    fn a_snapshot_slice_keeps_its_header_raw_and_inflates_to_the_ring_payload() {
        let slice = [&[3, 1][..], &b"\x1b[31mred\x1b[m ".repeat(500)].concat();
        let record = snapshot_record(&packed(&slice));
        assert_eq!(record.get(9..11), Some(&[3, 1][..]));
        assert!(record.len() < slice.len() / 4);
        assert_eq!(
            parse_record(&record).unwrap(),
            Parsed::Snapshot { offset: 7, slice }
        );
    }

    #[test]
    fn a_slice_that_inflates_past_the_ring_is_refused() {
        let at_limit = [&[0, 0][..], &vec![0; SLICE_MAX]].concat();
        assert!(parse_record(&snapshot_record(&packed(&at_limit))).is_ok());
        let over = [&[0, 0][..], &vec![0; SLICE_MAX + 1]].concat();
        assert_eq!(
            parse_record(&snapshot_record(&packed(&over))).unwrap_err(),
            BadRecord::Inflate
        );
    }

    #[test]
    fn a_truncated_or_corrupt_or_padded_slice_is_refused() {
        let whole = packed(&[&[0, 0][..], &b"abcdefgh".repeat(1000)].concat());
        let truncated = snapshot_record(&whole[..whole.len() - 3]);
        let padded = snapshot_record(&[&whole[..], b"x"].concat());
        let mut corrupt = whole.clone();
        corrupt[2] = 0xff;
        let corrupt = snapshot_record(&corrupt);
        let bare_header = snapshot_record(&whole[..2]);
        for record in [truncated, padded, corrupt, bare_header] {
            assert_eq!(parse_record(&record).unwrap_err(), BadRecord::Inflate);
        }
        assert_eq!(
            parse_record(&snapshot_record(&[0])).unwrap_err(),
            BadRecord::Short
        );
    }

    #[test]
    fn a_slice_cannot_copy_from_its_own_header() {
        let copies_the_extent_byte = snapshot_record(&[0, 0, 0x03, 0x02, 0x00]);
        assert_eq!(
            parse_record(&copies_the_extent_byte).unwrap_err(),
            BadRecord::Inflate
        );
    }

    #[test]
    fn a_finished_stream_queues_its_close_behind_the_messages_that_wait() {
        let (mut out, mut reader) = crate::conn::tests::full_output();
        let mut ws = Ws::new(Vec::new());
        ws.send(&mut out, "last-message".to_owned());
        ws.finish(&mut out);
        assert!(out.is_open() && out.waiting());
        let seen = crate::conn::tests::drain(&mut out, &mut reader);
        let mut tail = vec![0x81, 12];
        tail.extend_from_slice(b"last-message");
        tail.extend_from_slice(&[0x88, 6, 0x03, 0xe8]);
        tail.extend_from_slice(b"done");
        assert!(seen.ends_with(&tail), "the tail of {} bytes", seen.len());
        assert!(out.is_open());
    }

    fn texts(ws: &mut Ws, conn: &mut Conn, poll: &mut Poll) -> Vec<Next> {
        let mut reads = Reads::new();
        let mut seen = Vec::new();
        loop {
            let next = ws.next(&mut conn.out, poll, conn.token, &mut reads);
            let done = !matches!(next, Next::Text(_));
            seen.push(next);
            if done {
                return seen;
            }
        }
    }

    #[test]
    fn websocket_and_binary_record_headers() {
        let hex = |bytes: &[u8]| {
            bytes
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect::<Vec<_>>()
                .join(" ")
        };
        let mut out = [0; MAX_HEADER];
        let shown: Vec<String> = [0, 117, 65527]
            .into_iter()
            .map(|len| {
                let size = record_header(&mut out, Record::Output, 0, len);
                hex(&out[..size - RECORD_HEADER])
            })
            .collect();
        assert_eq!(
            shown,
            ["82 09", "82 7e 00 7e", "82 7f 00 00 00 00 00 01 00 00"]
        );
        let size = record_header(&mut out, Record::Output, 0x0102030405060708, 3);
        assert_eq!(
            (
                size,
                out[2],
                u64::from_le_bytes(out[3..11].try_into().unwrap())
            ),
            (11, 1, 0x0102030405060708)
        );
    }

    #[test]
    fn frames_in_one_write_and_a_frame_across_two_writes_each_give_their_message() {
        let (mut client, server) = UnixStream::pair().unwrap();
        let mut poll = Poll::new();
        let mut conn = Conn::new(
            Verified::admit(server).unwrap(),
            &mut poll,
            crate::config::QUEUE_BYTES,
        );
        let mut ws = Ws::new(Vec::new());
        client
            .write_all(&[text("one"), text("two")].concat())
            .unwrap();
        let both = texts(&mut ws, &mut conn, &mut poll);
        let split = text("three");
        client.write_all(&split[..4]).unwrap();
        let first = texts(&mut ws, &mut conn, &mut poll);
        client.write_all(&split[4..]).unwrap();
        let second = texts(&mut ws, &mut conn, &mut poll);
        let text = |text: &str| Next::Text(text.to_owned());
        assert_eq!(
            (both, first, second),
            (
                vec![text("one"), text("two"), Next::Wait],
                vec![Next::Wait],
                vec![text("three"), Next::Wait]
            )
        );
    }

    #[test]
    fn an_idle_link_pings_after_30_seconds_and_closes_10_seconds_later_without_a_pong() {
        let (mut client, server) = UnixStream::pair().unwrap();
        client.set_nonblocking(true).unwrap();
        let mut poll = Poll::new();
        let mut conn = Conn::new(
            Verified::admit(server).unwrap(),
            &mut poll,
            crate::config::QUEUE_BYTES,
        );
        let mut ws = Ws::new(Vec::new());
        let start = ws.last;
        let at = |seconds| start + Duration::from_secs(seconds);
        let early = ws.ping(&mut conn.out, at(20));
        let pinged = ws.ping(&mut conn.out, at(30));
        let mut sent = vec![0; 16];
        let count = std::io::Read::read(&mut client, &mut sent).unwrap();
        let waiting = ws.ping(&mut conn.out, at(35));
        let expired = ws.ping(&mut conn.out, at(40));
        assert_eq!(
            (
                early,
                pinged,
                &sent[..count],
                waiting,
                expired,
                conn.out.is_open()
            ),
            (
                Ping::After(Duration::from_secs(10)),
                Ping::After(PONG),
                &[0x89, 0][..],
                Ping::After(Duration::from_secs(5)),
                Ping::Expired,
                false
            )
        );
    }

    fn at(start: Instant, seconds: u64) -> Instant {
        start + Duration::from_secs(seconds)
    }

    #[test]
    fn a_pong_deadline_restarts_while_the_output_progresses_and_a_stalled_output_ends_after_10_seconds()
     {
        let (mut out, mut reader) = crate::conn::tests::full_output();
        let mut ws = Ws::new(Vec::new());
        let start = ws.last;
        assert_eq!(
            ws.ping(&mut out, at(start, 30)),
            Ping::After(PONG),
            "the ping waits behind the full socket"
        );
        out.send(vec![0; 1 << 20]);
        let mut chunk = [0u8; 4096];
        for second in [36, 42, 48, 54, 60] {
            assert!(reader.read(&mut chunk).is_ok());
            out.writable();
            assert!(
                matches!(ws.ping(&mut out, at(start, second)), Ping::After(_)),
                "the link ended at {second} s while its output progressed"
            );
            assert!(out.is_open());
        }
        assert_eq!(
            ws.ping(&mut out, at(start, 61)),
            Ping::After(Duration::from_secs(9)),
            "a stall begins at the first look without progress"
        );
        assert_eq!(ws.ping(&mut out, at(start, 71)), Ping::Expired);
        assert!(out.is_shut());
    }

    #[test]
    fn a_draining_output_that_makes_no_progress_ends_after_10_seconds() {
        let (mut out, _reader) = crate::conn::tests::full_output();
        out.view(
            std::sync::Arc::from(std::path::Path::new("/nonexistent")),
            0,
            b"BYE".to_vec(),
        );
        out.send(vec![0; crate::config::QUEUE_BYTES + 1]);
        assert_eq!(out.life(), Life::Draining);
        let mut ws = Ws::new(Vec::new());
        let start = ws.last;
        assert_eq!(ws.ping(&mut out, at(start, 1)), Ping::After(STALL));
        assert_eq!(
            ws.ping(&mut out, at(start, 5)),
            Ping::After(Duration::from_secs(6))
        );
        assert_eq!(out.life(), Life::Draining);
        assert_eq!(ws.ping(&mut out, at(start, 11)), Ping::Expired);
        assert!(out.is_shut());
    }
}
