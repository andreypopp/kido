use std::fmt::Display;
use std::io::{self, Read, Write};
use std::os::fd::AsFd;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

use ko_server::api::Route;
use ko_server::http::{self, Response, Upgrade, call};
use ko_server::ids::{ClientId, PaneId, PaneToken};
use ko_server::ws::{accepted, refused, upgrade_request};
use ko_sys::event::{Interest, Poll, PollRead, Reads, Ready, Token, Wake};
use ko_sys::fd::{self, Queue, Waited, Want};
use tungstenite::protocol::{Role, WebSocketConfig, WebSocketContext};
use tungstenite::{Bytes, Error, Message, Utf8Bytes};

use crate::launch::{self, PATIENCE};

const MAX_MESSAGE: usize = 128 << 20;
const RECEIVE_BUFFER: usize = 1 << 20;
const MAX_RESERVE: usize = 64 << 20;
pub const READ_TIMEOUT: Duration = Duration::from_secs(40);
pub const WATCHDOG: Duration = Duration::from_secs(40);

// poll cannot see frames that the upgrade read already buffered in the link,
// so the owner of a new link dispatches one read at once.
pub fn buffered(token: Token) -> Ready {
    Ready {
        token,
        read: true,
        write: false,
    }
}

pub fn text(error: impl Display) -> String {
    error.to_string()
}

pub fn silent(received: Instant, now: Instant, limit: Duration) -> bool {
    now.saturating_duration_since(received) >= limit
}

// Reads that end when the cancel wake is set or `within` passes without data.
struct Interruptible<'a> {
    stream: &'a UnixStream,
    cancel: Option<&'a Wake>,
    within: Duration,
}

impl Read for Interruptible<'_> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        if let Some(cancel) = self.cancel {
            wait_or_cancel(self.stream, Want::Read, cancel, self.within)?;
        }
        fd::read(self.stream.as_fd(), buffer)
    }
}

fn wait_or_cancel(
    stream: &UnixStream,
    want: Want,
    cancel: &Wake,
    within: Duration,
) -> io::Result<()> {
    match fd::wait(stream.as_fd(), want, Some(cancel.fd()), Some(within))? {
        Waited::Ready => Ok(()),
        Waited::Cancelled => Err(launch::cancelled_error()),
        Waited::TimedOut => Err(io::ErrorKind::TimedOut.into()),
    }
}

// A write that ends when the cancel wake is set or `within` passes without room.
fn write_until(
    stream: &mut UnixStream,
    mut bytes: &[u8],
    cancel: Option<&Wake>,
    within: Duration,
) -> io::Result<()> {
    let Some(cancel) = cancel else {
        return stream.write_all(bytes);
    };
    stream.set_nonblocking(true)?;
    while !bytes.is_empty() {
        match fd::write(stream.as_fd(), bytes) {
            Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
            Ok(count) => bytes = bytes.get(count..).unwrap_or_default(),
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                wait_or_cancel(stream, Want::Write, cancel, within)?;
            }
            Err(error) => return Err(error),
        }
    }
    stream.set_nonblocking(false)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Caller {
    pub pane: PaneId,
    pub token: PaneToken,
}

fn identity(caller: Option<&Caller>) -> Vec<(&'static str, String)> {
    match caller {
        None => Vec::new(),
        Some(Caller { pane, token }) => vec![
            ("Ko-Pane", pane.to_string()),
            ("Ko-Pane-Token", token.to_string()),
        ],
    }
}

fn borrowed<'a>(headers: &'a [(&'static str, String)]) -> Vec<(&'static str, &'a str)> {
    headers
        .iter()
        .map(|(name, value)| (*name, value.as_str()))
        .collect()
}

fn open(
    socket: &Path,
    (client, caller): Who,
    (method, target): (&str, &str),
    headers: &[(&str, &str)],
    body: &[u8],
    within: Duration,
    cancel: Option<&Wake>,
) -> io::Result<UnixStream> {
    let mut stream = launch::connect(socket, PATIENCE, cancel)?;
    stream.set_read_timeout(Some(within))?;
    stream.set_write_timeout(Some(within))?;
    let identity = identity(caller.as_ref());
    let mut extra = vec![("Connection", "keep-alive")];
    extra.extend_from_slice(headers);
    extra.extend(borrowed(&identity));
    write_until(
        &mut stream,
        &call(method, target, client, &extra, body),
        cancel,
        within,
    )?;
    Ok(stream)
}

pub(crate) fn exchange(
    socket: &Path,
    who: Who,
    target: (&str, &str),
    headers: &[(&str, &str)],
    body: &[u8],
    within: Duration,
    cancel: Option<&Wake>,
) -> io::Result<Response> {
    let stream = open(socket, who, target, headers, body, within, cancel)?;
    let mut answer = Vec::new();
    let mut response = http::read_response_with(
        &mut Interruptible {
            stream: &stream,
            cancel,
            within,
        },
        |head, piece| {
            if answer.is_empty() {
                let length = head
                    .header("content-length")
                    .and_then(|length| length.parse().ok());
                answer.reserve(length.unwrap_or(0).min(MAX_RESERVE));
            }
            answer.extend_from_slice(piece);
            Ok(())
        },
    )?;
    response.body = answer;
    Ok(response)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Rejected {
    Status {
        status: u16,
        reason: String,
        body: Vec<u8>,
    },
    Io(String),
    // The request was written and no answer was read: the server may have acted on it.
    Unanswered(String),
}

impl From<io::Error> for Rejected {
    fn from(error: io::Error) -> Rejected {
        Rejected::Io(text(error))
    }
}

impl Display for Rejected {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Rejected::Status {
                status,
                reason,
                body,
            } => write!(
                formatter,
                "{status} {reason}: {}",
                String::from_utf8_lossy(body)
            ),
            Rejected::Io(message) | Rejected::Unanswered(message) => formatter.write_str(message),
        }
    }
}

impl From<Rejected> for String {
    fn from(rejected: Rejected) -> String {
        rejected.to_string()
    }
}

fn fetch(
    socket: &Path,
    who: Who,
    route: &Route,
    body: &[u8],
    (cancel, within): (Option<&Wake>, Duration),
    mut sink: impl FnMut(&[u8]) -> io::Result<()>,
) -> Result<(), Rejected> {
    let (method, target) = route.to_request();
    let stream = open(socket, who, (method, &target), &[], body, within, cancel)?;
    let mut failure = Vec::new();
    let mut reader = Interruptible {
        stream: &stream,
        cancel,
        within,
    };
    let mut response = http::read_response_with(&mut reader, |head, piece| {
        if head.status == 200 {
            sink(piece)
        } else {
            failure.extend_from_slice(piece);
            Ok(())
        }
    })
    .map_err(|error| Rejected::Unanswered(text(error)))?;
    response.body = failure;
    succeeded(response).map(|_| ())
}

pub(crate) fn succeeded(response: Response) -> Result<Response, Rejected> {
    if response.status == 200 {
        Ok(response)
    } else {
        Err(Rejected::Status {
            status: response.status,
            reason: response.reason,
            body: response.body,
        })
    }
}

pub type Who = (Option<ClientId>, Option<Caller>);

pub fn request(
    socket: &Path,
    who: Who,
    route: &Route,
    body: &[u8],
    cancel: Option<&Wake>,
) -> Result<Vec<u8>, Rejected> {
    request_within(socket, who, route, body, (cancel, READ_TIMEOUT))
}

pub fn request_within(
    socket: &Path,
    who: Who,
    route: &Route,
    body: &[u8],
    limits: (Option<&Wake>, Duration),
) -> Result<Vec<u8>, Rejected> {
    let mut answer = Vec::new();
    fetch(socket, who, route, body, limits, |piece| {
        answer.extend_from_slice(piece);
        Ok(())
    })?;
    Ok(answer)
}

pub fn download(
    socket: &Path,
    client: ClientId,
    route: &Route,
    file: &mut impl Write,
) -> Result<(), String> {
    fetch(
        socket,
        (Some(client), None),
        route,
        b"",
        (None, READ_TIMEOUT),
        |piece| file.write_all(piece),
    )
    .map_err(String::from)
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct Resume(Option<u64>);

impl Resume {
    pub fn at(&mut self, offset: u64) {
        self.0 = Some(offset);
    }

    pub fn advance(&mut self, end: u64) {
        if self.0.is_some() {
            self.0 = Some(end);
        }
    }

    pub fn clear(&mut self) {
        self.0 = None;
    }

    pub fn offset(self) -> Option<u64> {
        self.0
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Next {
    Text(Utf8Bytes),
    Binary(Bytes),
    Wait,
    Closed,
}

#[derive(Debug)]
pub struct Link {
    stream: UnixStream,
    ctx: WebSocketContext,
    out: Queue,
    reads: Reads,
    token: Option<Token>,
    received: Instant,
    closing: Option<(u16, String)>,
    cancel: Option<Arc<Wake>>,
}

struct Io<'a> {
    stream: &'a UnixStream,
    source: Option<PollRead<'a>>,
    out: &'a mut Queue,
    cancel: Option<&'a Wake>,
}

impl Read for Io<'_> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        match self.source.as_mut() {
            None => {
                self.out.flush(self.stream.as_fd())?;
                Interruptible {
                    stream: self.stream,
                    cancel: self.cancel,
                    within: READ_TIMEOUT,
                }
                .read(buffer)
            }
            Some(source) => source.read(buffer),
        }
    }
}

impl Write for Io<'_> {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.out.bytes.extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

fn failed(error: Error) -> io::Error {
    match error {
        Error::Io(error) => error,
        other => io::Error::other(other.to_string()),
    }
}

impl Link {
    pub fn upgrade(
        stream: UnixStream,
        client: Option<ClientId>,
        route: &Route,
        cancel: Option<Arc<Wake>>,
    ) -> io::Result<Link> {
        Link::upgrade_within(stream, client, route, cancel, READ_TIMEOUT)
    }

    pub fn upgrade_within(
        stream: UnixStream,
        client: Option<ClientId>,
        route: &Route,
        cancel: Option<Arc<Wake>>,
        within: Duration,
    ) -> io::Result<Link> {
        Link::handshake(stream, (client, None), route, cancel, within)?
            .map_err(|response| refused(&response))
    }

    pub(crate) fn handshake(
        mut stream: UnixStream,
        (client, caller): Who,
        route: &Route,
        cancel: Option<Arc<Wake>>,
        within: Duration,
    ) -> io::Result<Result<Link, Response>> {
        stream.set_read_timeout(Some(within))?;
        ko_sys::sock::set_receive_buffer(stream.as_fd(), RECEIVE_BUFFER)?;
        let (method, target) = route.to_request();
        let identity = identity(caller.as_ref());
        let (request, key) = upgrade_request(method, &target, client, &borrowed(&identity));
        write_until(&mut stream, &request, cancel.as_deref(), within)?;
        let (response, rest) = match http::read_upgrade(&mut Interruptible {
            stream: &stream,
            cancel: cancel.as_deref(),
            within,
        })? {
            Upgrade::Accepted(response, rest) => (response, rest),
            Upgrade::Refused(response) => return Ok(Err(response)),
        };
        accepted(&response, &key)?;
        let mut link = Link::of(stream, rest);
        link.cancel = cancel;
        Ok(Ok(link))
    }

    pub fn of(stream: UnixStream, rest: Vec<u8>) -> Link {
        let config = WebSocketConfig::default()
            .read_buffer_size(1 << 15)
            .write_buffer_size(0)
            .max_message_size(Some(MAX_MESSAGE))
            .max_frame_size(Some(MAX_MESSAGE));
        Link {
            stream,
            ctx: WebSocketContext::from_partially_read(rest, Role::Client, Some(config)),
            out: Queue::default(),
            reads: Reads::new(),
            token: None,
            received: Instant::now(),
            closing: None,
            cancel: None,
        }
    }

    pub fn connect(
        socket: &Path,
        client: Option<ClientId>,
        route: &Route,
        cancel: Option<Arc<Wake>>,
    ) -> io::Result<Link> {
        Link::connect_within(socket, client, route, cancel, READ_TIMEOUT)
    }

    pub fn connect_within(
        socket: &Path,
        client: Option<ClientId>,
        route: &Route,
        cancel: Option<Arc<Wake>>,
        within: Duration,
    ) -> io::Result<Link> {
        let stream = launch::connect(socket, PATIENCE, cancel.as_deref())?;
        Link::upgrade_within(stream, client, route, cancel, within)
    }

    pub fn watch(&mut self, poll: &mut Poll) -> io::Result<Token> {
        fd::set_nonblocking(self.stream.as_fd())?;
        let token = poll.watch(
            self.stream.as_fd(),
            Interest::of(true, !self.out.is_empty()),
        );
        self.token = Some(token);
        Ok(token)
    }

    pub fn unwatch(&mut self, poll: &mut Poll) {
        if let Some(token) = self.token.take() {
            poll.unwatch(token);
        }
    }

    pub fn close_frame(&self) -> Option<&(u16, String)> {
        self.closing.as_ref()
    }

    pub fn received(&self) -> Instant {
        self.received
    }

    pub fn begin_turn(&mut self) {
        self.reads = Reads::new();
    }

    pub fn next(&mut self, poll: &mut Poll, now: Instant) -> io::Result<Next> {
        let Some(token) = self.token else {
            return Ok(Next::Closed);
        };
        let source = PollRead::new(poll, token, self.stream.as_fd(), &mut self.reads);
        let next = Link::pump(
            &mut self.ctx,
            &mut Io {
                stream: &self.stream,
                source: Some(source),
                out: &mut self.out,
                cancel: None,
            },
            &mut self.received,
            &mut self.closing,
            now,
        )?;
        self.settle(poll)?;
        Ok(next)
    }

    pub fn receive(&mut self) -> io::Result<Next> {
        let next = Link::pump(
            &mut self.ctx,
            &mut Io {
                stream: &self.stream,
                source: None,
                out: &mut self.out,
                cancel: self.cancel.as_deref(),
            },
            &mut self.received,
            &mut self.closing,
            Instant::now(),
        )?;
        self.flush_blocking()?;
        Ok(next)
    }

    fn pump(
        ctx: &mut WebSocketContext,
        io: &mut Io<'_>,
        received: &mut Instant,
        closing: &mut Option<(u16, String)>,
        now: Instant,
    ) -> io::Result<Next> {
        let next = loop {
            let message = match ctx.read(io) {
                Ok(message) => message,
                Err(Error::Io(error)) if error.kind() == io::ErrorKind::WouldBlock => {
                    break Next::Wait;
                }
                Err(Error::ConnectionClosed | Error::AlreadyClosed) => break Next::Closed,
                Err(error) => return Err(failed(error)),
            };
            *received = now;
            match message {
                Message::Text(body) => break Next::Text(body),
                Message::Binary(body) => break Next::Binary(body),
                Message::Close(frame) => {
                    *closing = frame.map(|frame| (u16::from(frame.code), frame.reason.to_string()));
                    break Next::Closed;
                }
                Message::Ping(_) | Message::Pong(_) | Message::Frame(_) => {}
            }
        };
        ctx.flush(io).map_err(failed)?;
        Ok(next)
    }

    pub fn send(&mut self, body: String) -> io::Result<()> {
        let mut io = Io {
            stream: &self.stream,
            source: None,
            out: &mut self.out,
            cancel: None,
        };
        self.ctx
            .write(&mut io, Message::Text(body.into()))
            .map_err(failed)
    }

    pub fn flush_blocking(&mut self) -> io::Result<()> {
        self.out.flush(self.stream.as_fd())
    }

    pub fn settle(&mut self, poll: &mut Poll) -> io::Result<()> {
        self.out.flush(self.stream.as_fd())?;
        if let Some(token) = self.token {
            poll.interest(token, Interest::of(true, !self.out.is_empty()));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pair() -> (Link, UnixStream, Poll) {
        let (ours, theirs) = UnixStream::pair().unwrap();
        let mut link = Link::of(ours, Vec::new());
        let mut poll = Poll::new();
        link.watch(&mut poll).unwrap();
        (link, theirs, poll)
    }

    fn frame(opcode: u8, payload: &[u8]) -> Vec<u8> {
        [
            &[0x80 | opcode, u8::try_from(payload.len()).unwrap()],
            payload,
        ]
        .concat()
    }

    fn settled(link: &mut Link, poll: &mut Poll) -> Vec<Next> {
        settled_at(link, poll, Instant::now())
    }

    fn settled_at(link: &mut Link, poll: &mut Poll, now: Instant) -> Vec<Next> {
        link.begin_turn();
        let mut seen = Vec::new();
        loop {
            let next = link.next(poll, now).unwrap();
            let done = matches!(next, Next::Wait | Next::Closed);
            seen.push(next);
            if done {
                return seen;
            }
        }
    }

    fn unmasked(bytes: &[u8]) -> (u8, Vec<u8>) {
        let (key, body) = (&bytes[2..6], &bytes[6..]);
        assert_eq!(bytes[1] & 0x80, 0x80, "a client frame is masked");
        (
            bytes[0] & 0x0f,
            body.iter()
                .zip(key.iter().cycle())
                .map(|(b, k)| b ^ k)
                .collect(),
        )
    }

    #[test]
    fn frames_in_one_write_and_a_frame_across_two_writes_each_give_their_message() {
        let (mut link, mut server, mut poll) = pair();
        server
            .write_all(&[frame(1, b"one"), frame(2, b"two")].concat())
            .unwrap();
        let both = settled(&mut link, &mut poll);
        let split = frame(1, b"three");
        server.write_all(&split[..3]).unwrap();
        let first = settled(&mut link, &mut poll);
        server.write_all(&split[3..]).unwrap();
        let second = settled(&mut link, &mut poll);
        assert_eq!(
            (both, first, second),
            (
                vec![
                    Next::Text("one".into()),
                    Next::Binary(Bytes::from_static(b"two")),
                    Next::Wait
                ],
                vec![Next::Wait],
                vec![Next::Text("three".into()), Next::Wait]
            )
        );
    }

    #[test]
    fn a_ping_gets_a_masked_pong_a_send_is_masked_and_a_close_ends_the_link() {
        let (mut link, mut server, mut poll) = pair();
        server.write_all(&frame(9, b"abcd")).unwrap();
        assert_eq!(settled(&mut link, &mut poll), [Next::Wait]);
        let mut reply = [0; 10];
        server.read_exact(&mut reply).unwrap();
        assert_eq!(unmasked(&reply), (10, b"abcd".to_vec()));
        link.send(r#"{"type":"focused","focused":true}"#.to_owned())
            .unwrap();
        link.settle(&mut poll).unwrap();
        let mut sent = [0; 6 + 33];
        server.read_exact(&mut sent).unwrap();
        assert_eq!(
            unmasked(&sent),
            (1, br#"{"type":"focused","focused":true}"#.to_vec())
        );
        server.write_all(&frame(8, b"")).unwrap();
        assert_eq!(settled(&mut link, &mut poll), [Next::Closed]);
    }

    #[test]
    fn pings_alone_keep_a_link_from_going_silent() {
        let (mut link, mut server, mut poll) = pair();
        let (start, limit) = (link.received(), Duration::from_secs(5));
        let mut silent_at = Vec::new();
        for seconds in [4, 8, 12] {
            let now = start + Duration::from_secs(seconds);
            server.write_all(&frame(9, b"")).unwrap();
            settled_at(&mut link, &mut poll, now);
            let mut pong = [0; 6];
            server.read_exact(&mut pong).unwrap();
            silent_at.push(silent(link.received(), now + Duration::from_secs(4), limit));
        }
        let quiet = silent(link.received(), start + Duration::from_secs(12 + 5), limit);
        assert_eq!((silent_at, quiet), (vec![false; 3], true));
    }
}
