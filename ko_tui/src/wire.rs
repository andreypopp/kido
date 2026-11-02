use std::fmt::Display;
use std::io::{self, Read, Write};
use std::os::fd::AsFd;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::{Duration, Instant};

use ko_server::http::{self, Response, call};
use ko_server::ids::ClientId;
use ko_server::protocol::Route;
use ko_server::ws::{accepted, upgrade_request};
use ko_sys::event::{Interest, Poll, PollRead, Reads, Ready, Token};
use ko_sys::fd::{self, Queue};
use tungstenite::protocol::{Role, WebSocketConfig, WebSocketContext};
use tungstenite::{Bytes, Error, Message, Utf8Bytes};

use crate::launch::{self, PATIENCE};

const MAX_MESSAGE: usize = 128 << 20;
const RECEIVE_BUFFER: usize = 1 << 20;
const READ_TIMEOUT: Duration = Duration::from_secs(40);
pub(crate) const WATCHDOG: Duration = Duration::from_secs(40);

// poll cannot see frames that the upgrade read already buffered in the link,
// so the owner of a new link dispatches one read at once.
pub(crate) fn buffered(token: Token) -> Ready {
    Ready {
        token,
        read: true,
        write: false,
    }
}

pub(crate) fn text(error: impl Display) -> String {
    error.to_string()
}

pub(crate) fn silent(received: Instant, now: Instant, limit: Duration) -> bool {
    now.saturating_duration_since(received) >= limit
}

fn open(
    socket: &Path,
    client: Option<ClientId>,
    (method, target): (&str, &str),
    body: &[u8],
) -> io::Result<UnixStream> {
    let mut stream = launch::connect(socket, PATIENCE)?;
    stream.set_read_timeout(Some(READ_TIMEOUT))?;
    let extra = [("Connection", "keep-alive")];
    stream.write_all(&call(method, target, client, &extra, body))?;
    Ok(stream)
}

pub(crate) fn exchange(
    socket: &Path,
    client: Option<ClientId>,
    target: (&str, &str),
    body: &[u8],
) -> io::Result<Response> {
    http::read_response(&mut open(socket, client, target, body)?)
}

fn fetch(
    socket: &Path,
    client: ClientId,
    route: &Route,
    body: &[u8],
    mut sink: impl FnMut(&[u8]) -> io::Result<()>,
) -> Result<(), String> {
    let (method, target) = route.to_request();
    let mut stream = open(socket, Some(client), (method, &target), body).map_err(text)?;
    let mut failure = Vec::new();
    let response = http::read_response_with(&mut stream, |head, piece| {
        if head.status == 200 {
            sink(piece)
        } else {
            failure.extend_from_slice(piece);
            Ok(())
        }
    })
    .map_err(text)?;
    if response.status == 200 {
        Ok(())
    } else {
        Err(format!(
            "{} {}: {}",
            response.status,
            response.reason,
            String::from_utf8_lossy(&failure)
        ))
    }
}

pub(crate) fn request(
    socket: &Path,
    client: ClientId,
    route: &Route,
    body: &[u8],
) -> Result<Vec<u8>, String> {
    let mut answer = Vec::new();
    fetch(socket, client, route, body, |piece| {
        answer.extend_from_slice(piece);
        Ok(())
    })?;
    Ok(answer)
}

pub(crate) fn download(
    socket: &Path,
    client: ClientId,
    route: &Route,
    file: &mut impl Write,
) -> Result<(), String> {
    fetch(socket, client, route, b"", |piece| file.write_all(piece))
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Next {
    Text(Utf8Bytes),
    Binary(Bytes),
    Wait,
    Closed,
}

#[derive(Debug)]
pub(crate) struct Link {
    stream: UnixStream,
    ctx: WebSocketContext,
    out: Queue,
    reads: Reads,
    token: Option<Token>,
    received: Instant,
}

struct Io<'a> {
    stream: &'a UnixStream,
    source: Option<PollRead<'a>>,
    out: &'a mut Queue,
}

impl Read for Io<'_> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        match self.source.as_mut() {
            None => fd::read(self.stream.as_fd(), buffer),
            Some(source) => match source.read(buffer) {
                Err(error) if error.kind() == io::ErrorKind::ConnectionReset => Ok(0),
                read => read,
            },
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
    pub(crate) fn upgrade(
        mut stream: UnixStream,
        client: Option<ClientId>,
        route: &Route,
    ) -> io::Result<Link> {
        stream.set_read_timeout(Some(READ_TIMEOUT))?;
        ko_sys::sock::set_receive_buffer(stream.as_fd(), RECEIVE_BUFFER)?;
        let (method, target) = route.to_request();
        let (request, key) = upgrade_request(method, &target, client);
        stream.write_all(&request)?;
        let (response, rest) = http::read_upgrade(&mut stream)?;
        accepted(&response, &key)?;
        Ok(Link::of(stream, rest))
    }

    pub(crate) fn of(stream: UnixStream, rest: Vec<u8>) -> Link {
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
        }
    }

    pub(crate) fn connect(
        socket: &Path,
        client: Option<ClientId>,
        route: &Route,
    ) -> io::Result<Link> {
        Link::upgrade(launch::connect(socket, PATIENCE)?, client, route)
    }

    pub(crate) fn watch(&mut self, poll: &mut Poll) -> io::Result<Token> {
        fd::set_nonblocking(self.stream.as_fd())?;
        let token = poll.watch(
            self.stream.as_fd(),
            Interest::of(true, !self.out.is_empty()),
        );
        self.token = Some(token);
        Ok(token)
    }

    pub(crate) fn unwatch(&mut self, poll: &mut Poll) {
        if let Some(token) = self.token.take() {
            poll.unwatch(token);
        }
    }

    pub(crate) fn received(&self) -> Instant {
        self.received
    }

    pub(crate) fn begin_turn(&mut self) {
        self.reads = Reads::new();
    }

    pub(crate) fn next(&mut self, poll: &mut Poll, now: Instant) -> io::Result<Next> {
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
            },
            &mut self.received,
            now,
        )?;
        self.settle(poll)?;
        Ok(next)
    }

    pub(crate) fn receive(&mut self) -> io::Result<Next> {
        let next = Link::pump(
            &mut self.ctx,
            &mut Io {
                stream: &self.stream,
                source: None,
                out: &mut self.out,
            },
            &mut self.received,
            Instant::now(),
        )?;
        self.flush_blocking()?;
        Ok(next)
    }

    fn pump(
        ctx: &mut WebSocketContext,
        io: &mut Io<'_>,
        received: &mut Instant,
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
                Message::Close(_) => break Next::Closed,
                Message::Ping(_) | Message::Pong(_) | Message::Frame(_) => {}
            }
        };
        ctx.flush(io).map_err(failed)?;
        Ok(next)
    }

    pub(crate) fn send(&mut self, body: String) -> io::Result<()> {
        let mut io = Io {
            stream: &self.stream,
            source: None,
            out: &mut self.out,
        };
        self.ctx
            .write(&mut io, Message::Text(body.into()))
            .map_err(failed)
    }

    pub(crate) fn flush_blocking(&mut self) -> io::Result<()> {
        self.out.flush(self.stream.as_fd())
    }

    pub(crate) fn settle(&mut self, poll: &mut Poll) -> io::Result<()> {
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
