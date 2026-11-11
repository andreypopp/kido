#![deny(clippy::indexing_slicing, clippy::arithmetic_side_effects)]

use ko_wire::protocol::webview::FrameKind;

use crate::diagnostics::Cause;
use std::io::{self, Cursor, Read, Write};
use std::os::fd::AsFd;
use std::time::{Duration, Instant};

use ko_pane_wire::ring::SLICE_HEADER;
use ko_sys::event::{Poll, PollRead, Reads, Token};
use tungstenite::protocol::frame::coding::{CloseCode as WireCloseCode, Data, OpCode};
use tungstenite::protocol::frame::{Frame as WireFrame, FrameHeader};
use tungstenite::protocol::{CloseFrame, Role as Side, WebSocketConfig, WebSocketContext};
use tungstenite::{Error, Message, Utf8Bytes};

use crate::conn::{Fit, Life, Output, Queue};
use crate::deflate::Deflate;
use ko_wire::http::{Head, MAX_HEAD};

use ko_wire::protocol::{CloseCode, CloseReason, EXEC_CHUNK};
use ko_wire::ws::{self, RECORD_HEADER};
const MAX_HEADER: usize = 10 + RECORD_HEADER;
const MAX_MESSAGE: usize = 1 << 20;
const MAX_SENT: usize = 32 << 20;
pub(crate) const PING_INTERVAL: Duration = Duration::from_secs(30);
const PONG: Duration = Duration::from_secs(10);
const STALL: Duration = Duration::from_secs(10);
pub(crate) const OVERFLOW_REASON: &str = "view queue overflow";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Rejection {
    Invalid,
    Io,
    Gone,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Record {
    Output,
    Snapshot,
}

pub(crate) fn with_packed_slice<R>(
    deflate: &mut Deflate,
    payload: &[u8],
    send: impl FnOnce(&[u8]) -> R,
) -> Option<R> {
    let (header, body) = payload.split_at_checked(SLICE_HEADER)?;
    Some(deflate.with_deflated(header, body, send))
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
    let payload = u64::try_from(len)
        .unwrap_or(u64::MAX)
        .saturating_add(RECORD_HEADER as u64);
    let _ = header.format(payload, &mut cursor);
    let _ = cursor.write_all(&[match record {
        Record::Output => ws::OUTPUT,
        Record::Snapshot => ws::SNAPSHOT,
    }]);
    let _ = cursor.write_all(&offset.to_le_bytes());
    usize::try_from(cursor.position()).unwrap_or(MAX_HEADER)
}

pub(crate) fn handshake(head: &Head) -> Option<String> {
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
    (upgrade && connection && version)
        .then(|| tungstenite::handshake::derive_accept_key(key.as_bytes()))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Limit {
    Cap,
    Reply,
}

#[derive(Debug)]
struct Io<'a> {
    source: Option<PollRead<'a>>,
    queue: &'a mut Queue,
    limit: Limit,
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
        if self.limit == Limit::Reply {
            self.queue.push_reply(bytes.to_vec());
            Ok(bytes.len())
        } else if self.queue.push(&[bytes], Fit::Cap) {
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
        code: WireCloseCode::Again,
        reason: OVERFLOW_REASON.into(),
    }));
    let mut bytes = Vec::new();
    let _ = frame.format(&mut bytes);
    bytes
}

fn writer(out: &mut Output, limit: Limit) -> Io<'_> {
    Io {
        source: None,
        queue: out.parts().1,
        limit,
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Awaiting {
    Pong(Instant),
    Reads,
}

#[derive(Debug)]
pub(crate) struct Ws {
    ctx: WebSocketContext,
    limit: Limit,
    next_ping: Instant,
    ping: Option<Awaiting>,
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
        let now = Instant::now();
        Ws {
            limit: Limit::Cap,
            ctx: WebSocketContext::from_partially_read(part, Side::Server, Some(config)),
            next_ping: now.checked_add(PING_INTERVAL).unwrap_or(now),
            ping: None,
            accepted: 0,
            blocked: None,
        }
    }

    pub(crate) fn flow(part: Vec<u8>) -> Ws {
        let mut ws = Ws::new(part);
        ws.limit = Limit::Reply;
        ws
    }

    pub(crate) fn proxy(part: Vec<u8>) -> Ws {
        let mut ws = Ws::flow(part);
        ws.ctx.set_config(|config| {
            config.max_message_size = Some(EXEC_CHUNK);
            config.max_frame_size = Some(EXEC_CHUNK);
        });
        ws
    }

    pub(crate) fn message(
        &mut self,
        out: &mut Output,
        poll: &mut Poll,
        token: Token,
        reads: &mut Reads,
    ) -> Result<Option<Message>, Cause> {
        if !out.is_open() {
            return Err(Cause::Io);
        }
        let (stream, queue) = out.parts();
        let mut io = Io {
            source: Some(PollRead::new(poll, token, stream.as_fd(), reads)),
            queue,
            limit: self.limit,
        };
        let result = loop {
            match self.ctx.read(&mut io) {
                Ok(message) => match message {
                    Message::Pong(_) => self.ping = None,
                    Message::Ping(_) | Message::Frame(_) => {}
                    other => break Ok(Some(other)),
                },
                Err(Error::Io(error)) if error.kind() == io::ErrorKind::WouldBlock => {
                    break Ok(None);
                }
                Err(Error::Capacity(_)) => {
                    out.closing(Cause::MessageTooLarge);
                    break Ok(Some(Message::Close(Some(CloseFrame {
                        code: WireCloseCode::Size,
                        reason: CloseCode::SIZE_REASON.into(),
                    }))));
                }
                Err(
                    Error::ConnectionClosed
                    | Error::AlreadyClosed
                    | Error::Protocol(
                        tungstenite::error::ProtocolError::ResetWithoutClosingHandshake,
                    ),
                ) => break Err(Cause::Eof),
                Err(_) => break Err(Cause::Io),
            }
        };
        out.flush();
        result
    }

    pub(crate) fn next(
        &mut self,
        out: &mut Output,
        poll: &mut Poll,
        token: Token,
        reads: &mut Reads,
    ) -> Next {
        let cause = match self.message(out, poll, token, reads) {
            Ok(Some(Message::Text(text))) => return Next::Text(text.as_str().to_owned()),
            Ok(None) => return Next::Wait,
            Ok(Some(Message::Close(_))) => Cause::PeerClosed,
            Ok(Some(_)) => Cause::Refused,
            Err(cause) => cause,
        };
        out.closing(cause);
        if matches!(cause, Cause::PeerClosed) {
            let mut bytes = std::io::Cursor::new(Vec::new());
            let _ = self.ctx.flush(&mut bytes);
            out.finish(bytes.into_inner());
        } else {
            out.close();
        }
        Next::Close
    }

    pub(crate) fn proxy_send(
        &mut self,
        out: &mut Output,
        data: Vec<u8>,
        binary: FrameKind,
    ) -> Result<(), std::string::FromUtf8Error> {
        let message = binary.into_message(data)?;
        if self
            .ctx
            .write(
                &mut Io {
                    source: None,
                    queue: out.parts().1,
                    limit: Limit::Reply,
                },
                message,
            )
            .is_err()
        {
            out.close();
        }
        out.flush();
        Ok(())
    }

    pub(crate) fn proxy_close(&mut self, out: &mut Output, code: CloseCode, reason: CloseReason) {
        let _ = self.ctx.close(
            &mut Io {
                source: None,
                queue: out.parts().1,
                limit: Limit::Reply,
            },
            Some(CloseFrame {
                code: code.into(),
                reason: String::from(reason).into(),
            }),
        );
        out.drain();
    }

    pub(crate) fn send(&mut self, out: &mut Output, text: impl Into<Utf8Bytes>) {
        let text: Utf8Bytes = text.into();
        if !out.is_open() {
            return;
        }
        if text.as_str().len() > MAX_SENT {
            out.closing(Cause::MessageTooLarge);
            out.close();
            return;
        }
        if self
            .ctx
            .write(&mut writer(out, self.limit), Message::Text(text))
            .is_err()
        {
            out.closing(Cause::Io);
            out.close();
            return;
        }
        out.flush();
    }

    pub(crate) fn reject(&mut self, out: &mut Output, kind: Rejection) {
        out.closing(match kind {
            Rejection::Invalid => Cause::Refused,
            Rejection::Io => Cause::Io,
            Rejection::Gone => Cause::Gone,
        });
        let reason = match kind {
            Rejection::Invalid => "invalid",
            Rejection::Io => "io",
            Rejection::Gone => "gone",
        };
        self.close_with(out, WireCloseCode::Policy, reason);
        out.close();
    }

    pub(crate) fn abort(&mut self, out: &mut Output, reason: &'static str) {
        self.close_with(out, WireCloseCode::Error, reason);
    }

    pub(crate) fn shutdown(&mut self, out: &mut Output) {
        self.close_with(out, WireCloseCode::Away, "shutdown");
    }

    pub(crate) fn finish(&mut self, out: &mut Output) {
        out.closing(Cause::Finished);
        self.close_with(out, WireCloseCode::Normal, "done");
    }

    fn close_with(&mut self, out: &mut Output, code: WireCloseCode, reason: &'static str) {
        if out.is_open() {
            let frame = CloseFrame {
                code,
                reason: reason.into(),
            };
            let mut bytes = std::io::Cursor::new(Vec::new());
            let _ = self.ctx.close(&mut bytes, Some(frame));
            out.finish(bytes.into_inner());
        }
    }

    // The time left before an output that makes no progress counts as stalled. The pong deadline
    // restarts while the output progresses, because a ping waits behind the queued messages.
    fn stall(&mut self, out: &Output, now: Instant) -> Option<Duration> {
        let moved = out.accepted() != self.accepted;
        self.accepted = out.accepted();
        if moved && matches!(self.ping, Some(Awaiting::Pong(_))) {
            self.ping = Some(Awaiting::Pong(now));
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

    pub(crate) fn reads_changed(&mut self, reads: bool, now: Instant) {
        self.ping = match (self.ping, reads) {
            (Some(_), false) => Some(Awaiting::Reads),
            (Some(Awaiting::Reads), true) => Some(Awaiting::Pong(now)),
            (pending, true) | (pending @ None, false) => pending,
        };
    }

    pub(crate) fn ping(&mut self, out: &mut Output, now: Instant, reads: bool) -> Ping {
        let stall = self.stall(out, now);
        if stall.is_some_and(|left| left.is_zero()) {
            out.closing(Cause::Stalled);
            out.shut();
            return Ping::Expired;
        }
        match out.life() {
            Life::Shut => return Ping::Expired,
            Life::Draining => return Ping::After(stall.unwrap_or(STALL)),
            Life::Open => {}
        }
        if reads
            && matches!(self.ping, Some(Awaiting::Pong(sent)) if now.saturating_duration_since(sent) >= PONG)
        {
            out.closing(Cause::PingTimeout);
            self.close_with(out, WireCloseCode::Policy, "io");
            out.shut();
            return Ping::Expired;
        }
        if now >= self.next_ping {
            if self
                .ctx
                .write(
                    &mut writer(out, self.limit),
                    Message::Ping(Default::default()),
                )
                .is_err()
            {
                if out.life() == Life::Draining {
                    return Ping::After(stall.unwrap_or(STALL));
                }
                out.closing(Cause::Io);
                out.shut();
                return Ping::Expired;
            }
            self.next_ping = now.checked_add(PING_INTERVAL).unwrap_or(now);
            if self.ping.is_none() {
                self.ping = Some(if !reads {
                    Awaiting::Reads
                } else {
                    Awaiting::Pong(now)
                });
            }
            out.flush();
            self.accepted = out.accepted();
        }
        if out.is_shut() {
            return Ping::Expired;
        }
        let mut left = self.next_ping.saturating_duration_since(now);
        if reads && let Some(Awaiting::Pong(sent)) = self.ping {
            left = left.min(PONG.saturating_sub(now.saturating_duration_since(sent)));
        }
        Ping::After(stall.map_or(left, |stall| left.min(stall)))
    }
}

#[cfg(test)]
#[allow(clippy::indexing_slicing, clippy::arithmetic_side_effects)]
mod tests {
    use super::*;
    use ko_pane_wire::ring::SLICE_MAX;
    use ko_wire::ws::{BadRecord, Parsed, masked, parse_record};
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
        assert_eq!(out.life(), Life::Draining);
        assert!(out.waiting());
        let seen = crate::conn::tests::drain(&mut out, &mut reader);
        let mut tail = vec![0x81, 12];
        tail.extend_from_slice(b"last-message");
        tail.extend_from_slice(&[0x88, 6, 0x03, 0xe8]);
        tail.extend_from_slice(b"done");
        assert!(seen.ends_with(&tail), "the tail of {} bytes", seen.len());
        assert_eq!(out.life(), Life::Shut);
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
    fn client_traffic_does_not_postpone_the_servers_ping() {
        let crate::conn::tests::Pair {
            mut poll,
            mut conn,
            mut client,
        } = crate::conn::tests::pair();
        client.set_nonblocking(false).unwrap();
        client
            .set_read_timeout(Some(Duration::from_secs(1)))
            .unwrap();
        let mut ws = Ws::new(Vec::new());
        let start = Instant::now() - Duration::from_secs(20);
        ws.next_ping = at(start, 30);
        for second in [10, 20, 30] {
            client.write_all(&text("input")).unwrap();
            assert_eq!(
                ws.next(&mut conn.out, &mut poll, conn.token, &mut Reads::new()),
                Next::Text("input".to_owned())
            );
            if second < 30 {
                let _ = ws.ping(&mut conn.out, at(start, second), true);
            }
        }
        assert_eq!(
            ws.ping(&mut conn.out, at(start, 30), true),
            Ping::After(PONG)
        );
        let mut bytes = [0; 2];
        client.read_exact(&mut bytes).unwrap();
        assert_eq!(bytes, [0x89, 0]);
        client
            .write_all(&masked(10, true, b"", [1, 2, 3, 4], 0))
            .unwrap();
        assert_eq!(
            ws.next(&mut conn.out, &mut poll, conn.token, &mut Reads::new()),
            Next::Wait
        );
        assert_eq!(
            ws.ping(&mut conn.out, at(start, 60), true),
            Ping::After(PONG)
        );
        client.read_exact(&mut bytes).unwrap();
        assert_eq!(bytes, [0x89, 0]);
        client.write_all(&text("not a pong")).unwrap();
        assert_eq!(
            ws.next(&mut conn.out, &mut poll, conn.token, &mut Reads::new()),
            Next::Text("not a pong".to_owned())
        );
        assert_eq!(ws.ping(&mut conn.out, at(start, 70), true), Ping::Expired);
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
        let start = ws.next_ping - PING_INTERVAL;
        let early = ws.ping(&mut conn.out, at(start, 20), true);
        let pinged = ws.ping(&mut conn.out, at(start, 30), true);
        let mut sent = vec![0; 16];
        let count = std::io::Read::read(&mut client, &mut sent).unwrap();
        let waiting = ws.ping(&mut conn.out, at(start, 35), true);
        let expired = ws.ping(&mut conn.out, at(start, 40), true);
        let mut closed = [0; 6];
        std::io::Read::read_exact(&mut client, &mut closed).unwrap();
        assert_eq!(closed, [0x88, 4, 3, 0xf0, b'i', b'o']);
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

    #[test]
    fn reads_resumed_between_ticks_start_the_pong_allowance_at_resume() {
        let crate::conn::tests::Pair {
            mut conn,
            client: _client,
            ..
        } = crate::conn::tests::pair();
        let mut ws = Ws::new(Vec::new());
        let start = ws.next_ping - PING_INTERVAL;
        assert_eq!(
            ws.ping(&mut conn.out, at(start, 30), true),
            Ping::After(PONG)
        );
        ws.reads_changed(false, at(start, 31));
        ws.reads_changed(true, at(start, 35));
        assert_eq!(
            ws.ping(&mut conn.out, at(start, 44), true),
            Ping::After(Duration::from_secs(1))
        );
        assert_eq!(ws.ping(&mut conn.out, at(start, 45), true), Ping::Expired);
    }

    #[test]
    fn a_ping_that_overflows_a_view_keeps_the_overflow_close() {
        let (mut out, mut reader) = crate::conn::tests::full_output();
        let close = overflow_close();
        out.view(
            std::path::Path::new("/nonexistent").into(),
            0,
            close.clone(),
        );
        out.send(vec![0; crate::config::QUEUE_BYTES]);
        let mut ws = Ws::new(Vec::new());
        assert_eq!(ws.ping(&mut out, ws.next_ping, true), Ping::After(STALL));
        assert_eq!(out.life(), Life::Draining);
        let bytes = crate::conn::tests::drain(&mut out, &mut reader);
        assert!(bytes.ends_with(&close));
    }

    #[test]
    fn paused_reads_keep_pinging_and_resume_with_a_fresh_pong_allowance() {
        let crate::conn::tests::Pair {
            poll: _poll,
            mut conn,
            mut client,
        } = crate::conn::tests::pair();
        client.set_nonblocking(false).unwrap();
        client
            .set_read_timeout(Some(Duration::from_secs(1)))
            .unwrap();
        let mut ws = Ws::new(Vec::new());
        let start = ws.next_ping - PING_INTERVAL;
        let mut bytes = [0; 2];
        for second in [30, 60, 90] {
            assert_eq!(
                ws.ping(&mut conn.out, at(start, second), false),
                Ping::After(PING_INTERVAL)
            );
            client.read_exact(&mut bytes).unwrap();
            assert_eq!(bytes, [0x89, 0]);
        }
        ws.reads_changed(true, at(start, 100));
        assert_eq!(
            ws.ping(&mut conn.out, at(start, 100), true),
            Ping::After(PONG)
        );
        assert_eq!(
            ws.ping(&mut conn.out, at(start, 109), true),
            Ping::After(Duration::from_secs(1))
        );
        assert_eq!(ws.ping(&mut conn.out, at(start, 110), true), Ping::Expired);
    }

    fn at(start: Instant, seconds: u64) -> Instant {
        start + Duration::from_secs(seconds)
    }

    #[test]
    fn a_pong_deadline_restarts_while_the_output_progresses_and_a_stalled_output_ends_after_10_seconds()
     {
        let (mut out, mut reader) = crate::conn::tests::full_output();
        let mut ws = Ws::new(Vec::new());
        let start = ws.next_ping - PING_INTERVAL;
        assert_eq!(
            ws.ping(&mut out, at(start, 30), true),
            Ping::After(PONG),
            "the ping waits behind the full socket"
        );
        out.send(vec![0; 1 << 20]);
        let mut chunk = [0u8; 4096];
        for second in [36, 42, 48, 54, 60] {
            let before = out.accepted();
            // Linux frees a unix socket's send room in whole skbs, not for each byte read.
            for _ in 0..(1 << 20) / chunk.len() {
                assert!(reader.read(&mut chunk).unwrap() > 0);
                out.writable();
                if out.accepted() != before {
                    break;
                }
            }
            assert_ne!(out.accepted(), before, "the reads freed no room");
            assert!(
                matches!(ws.ping(&mut out, at(start, second), true), Ping::After(_)),
                "the link ended at {second} s while its output progressed"
            );
            assert!(out.is_open());
        }
        assert_eq!(
            ws.ping(&mut out, at(start, 61), true),
            Ping::After(Duration::from_secs(9)),
            "a stall begins at the first look without progress"
        );
        assert_eq!(ws.ping(&mut out, at(start, 71), true), Ping::Expired);
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
        let start = ws.next_ping - PING_INTERVAL;
        assert_eq!(ws.ping(&mut out, at(start, 1), true), Ping::After(STALL));
        assert_eq!(
            ws.ping(&mut out, at(start, 5), true),
            Ping::After(Duration::from_secs(6))
        );
        assert_eq!(out.life(), Life::Draining);
        assert_eq!(ws.ping(&mut out, at(start, 11), true), Ping::Expired);
        assert!(out.is_shut());
    }
}
