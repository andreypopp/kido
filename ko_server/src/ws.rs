#![deny(clippy::indexing_slicing, clippy::arithmetic_side_effects)]

use std::io::{self, Cursor, Read, Write};
use std::os::fd::AsFd;
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};

use ko_sys::event::{Poll, Read as Readiness, Reads, Token};
use tungstenite::protocol::frame::FrameHeader;
use tungstenite::protocol::frame::coding::{CloseCode, Data, OpCode};
use tungstenite::protocol::{CloseFrame, Role as Side, WebSocketConfig, WebSocketContext};
use tungstenite::{Error, Message};

use crate::conn::{Output, Queue};
use crate::http::{self, Head, MAX_HEAD, Status};

const RECORD_HEADER: usize = 9;
pub(crate) const MAX_HEADER: usize = 10 + RECORD_HEADER;
const MAX_MESSAGE: usize = 1 << 20;
const IDLE: Duration = Duration::from_secs(30);
const PONG: Duration = Duration::from_secs(10);
pub(crate) const FIRST_PING: Duration = IDLE;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Record {
    Output,
    Snapshot,
}

pub(crate) fn record_header(
    out: &mut [u8; MAX_HEADER],
    record: Record,
    offset: u64,
    len: usize,
) -> usize {
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
struct Source<'a> {
    poll: &'a mut Poll,
    token: Token,
    stream: &'a UnixStream,
    reads: &'a mut Reads,
}

#[derive(Debug)]
struct Io<'a> {
    source: Option<Source<'a>>,
    queue: &'a mut Queue,
}

impl Read for Io<'_> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        let Some(source) = self.source.as_mut() else {
            return Err(io::ErrorKind::WouldBlock.into());
        };
        match source
            .poll
            .read(source.token, source.stream.as_fd(), buffer, source.reads)?
        {
            None => Err(io::ErrorKind::WouldBlock.into()),
            Some(Readiness::Data(count)) => Ok(count),
            Some(Readiness::End) => Ok(0),
        }
    }
}

impl Write for Io<'_> {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if self.queue.push(bytes.to_vec()) {
            Ok(bytes.len())
        } else {
            Err(io::Error::other("connection queue full"))
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
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
            source: Some(Source {
                poll,
                token,
                stream,
                reads,
            }),
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

    pub(crate) fn send(&mut self, out: &mut Output, text: String) {
        if !out.is_open() {
            return;
        }
        if text.len() > MAX_MESSAGE
            || self
                .ctx
                .write(&mut writer(out), Message::Text(text.into()))
                .is_err()
        {
            out.close();
            return;
        }
        out.flush();
    }

    pub(crate) fn reject(&mut self, out: &mut Output, kind: &'static str) {
        if out.available() {
            let frame = CloseFrame {
                code: CloseCode::Policy,
                reason: kind.into(),
            };
            let _ = self.ctx.close(&mut writer(out), Some(frame));
            out.flush();
        }
        out.close();
    }

    pub(crate) fn ping(&mut self, out: &mut Output, now: Instant) -> Ping {
        let due = match self.ping {
            Some(sent) => sent.checked_add(PONG),
            None => self.last.checked_add(IDLE),
        };
        if let Some(left) = due
            .and_then(|due| due.checked_duration_since(now))
            .filter(|left| !left.is_zero())
        {
            return Ping::After(left);
        }
        if self.ping.is_some() {
            self.reject(out, "gone");
            return Ping::Expired;
        }
        self.ping = Some(now);
        if self
            .ctx
            .write(&mut writer(out), Message::Ping(Default::default()))
            .is_err()
        {
            out.close();
            return Ping::Expired;
        }
        out.flush();
        Ping::After(PONG)
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
    use crate::conn::Conn;
    use crate::server::Verified;
    use std::io::Write;

    fn text(text: &str) -> Vec<u8> {
        masked(1, true, text.as_bytes(), [1, 2, 3, 4], 0)
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
        let mut conn = Conn::new(Verified::admit(server).unwrap(), &mut poll);
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
        let mut conn = Conn::new(Verified::admit(server).unwrap(), &mut poll);
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
}
