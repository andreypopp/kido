pub(crate) mod exchange;
pub(crate) mod stream;

#[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
pub(crate) mod quic;
mod upgrade;
pub use upgrade::{Connecting, UpgradeStep};

use crate::endpoint::Resolved;
use std::fmt::Display;
use std::io::{self, Read, Write};
#[cfg(test)]
use std::os::fd::AsFd;
use std::os::unix::net::UnixStream;
use std::sync::Arc;
use std::time::{Duration, Instant};
use stream::Stream;

use ko_sys::event::{Poll, Read as PollData, Reads, Ready, Token, Wake};
use ko_sys::fd::{self, Queue, Waited, Want};
use ko_wire::api::Route;
use ko_wire::http::{self, Response, Upgrade};
use ko_wire::ids::{ClientId, PaneId, PaneToken};
use ko_wire::protocol;
use ko_wire::ws::{accepted, refused, upgrade_request};
use tungstenite::protocol::{Role, WebSocketConfig, WebSocketContext};
use tungstenite::{Bytes, Error, Message, Utf8Bytes};

use crate::connect;

const MAX_MESSAGE: usize = 128 << 20;
const MAX_PENDING: usize = 1 << 20;
const RECEIVE_BUFFER: usize = 1 << 20;
const MAX_RESERVE: usize = 64 << 20;
pub const READ_TIMEOUT: Duration = Duration::from_secs(40);
pub const WATCHDOG: Duration = Duration::from_secs(60);

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

#[derive(Debug, Clone, Copy)]
pub(crate) enum Limit {
    Idle(Duration),
    Deadline(Instant),
}

impl Limit {
    fn remaining(self) -> io::Result<Duration> {
        match self {
            Limit::Idle(within) => Ok(within),
            Limit::Deadline(deadline) => deadline
                .checked_duration_since(Instant::now())
                .ok_or_else(|| io::ErrorKind::TimedOut.into()),
        }
    }
}

struct Interruptible<'a> {
    stream: &'a mut Stream,
    cancel: Option<&'a Wake>,
    within: Limit,
}

impl Read for Interruptible<'_> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        loop {
            if let Some(result) = self.stream.buffered(buffer) {
                match result {
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                    result => return result,
                }
            }
            self.stream.progress()?;
            let want = self.stream.wait(Want::Read);
            match fd::wait(
                self.stream.fd(),
                want,
                self.cancel.map(Wake::fd),
                Some(self.within.remaining()?),
            )? {
                Waited::Ready if matches!(want, Want::Write) => continue,
                Waited::Ready => match self.stream.read(buffer) {
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                    read => return read,
                },
                Waited::Cancelled => return Err(connect::cancelled_error()),
                Waited::TimedOut => return Err(io::ErrorKind::TimedOut.into()),
            }
        }
    }
}

fn write_until(
    stream: &mut Stream,
    mut bytes: &[u8],
    cancel: Option<&Wake>,
    within: Limit,
) -> io::Result<()> {
    stream.set_nonblocking(true)?;
    while !bytes.is_empty() {
        let _ = within.remaining()?;
        match stream.write(bytes) {
            Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
            Ok(count) => bytes = bytes.get(count..).unwrap_or_default(),
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                let want = stream.wait(Want::Write);
                match fd::wait(
                    stream.fd(),
                    want,
                    cancel.map(Wake::fd),
                    Some(within.remaining()?),
                )? {
                    Waited::Ready => {
                        if matches!(want, Want::Read) {
                            stream.receive()?;
                        }
                    }
                    Waited::Cancelled => return Err(connect::cancelled_error()),
                    Waited::TimedOut => return Err(io::ErrorKind::TimedOut.into()),
                }
            }
            Err(error) => return Err(error),
        }
    }
    while stream.pending_write() {
        stream.progress()?;
        if stream.pending_write() {
            match fd::wait(
                stream.fd(),
                stream.wait(Want::Write),
                cancel.map(Wake::fd),
                Some(within.remaining()?),
            )? {
                Waited::Ready => {}
                Waited::Cancelled => return Err(connect::cancelled_error()),
                Waited::TimedOut => return Err(io::ErrorKind::TimedOut.into()),
            }
        }
    }
    stream.set_nonblocking(matches!(within, Limit::Deadline(_)))
}

fn flush_until(
    stream: &mut Stream,
    out: &mut Queue,
    cancel: Option<&Wake>,
    within: Duration,
) -> io::Result<()> {
    out.compact();
    write_until(stream, &out.bytes, cancel, Limit::Idle(within))?;
    out.clear();
    Ok(())
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
            (protocol::PANE_HEADER, pane.to_string()),
            (protocol::PANE_TOKEN_HEADER, token.to_string()),
        ],
    }
}

fn borrowed<'a>(headers: &'a [(&'static str, String)]) -> Vec<(&'static str, &'a str)> {
    headers
        .iter()
        .map(|(name, value)| (*name, value.as_str()))
        .collect()
}

pub(crate) fn exchange(
    socket: &Resolved,
    who: Who,
    target: (&str, &protocol::RequestTarget),
    headers: &[(&str, &str)],
    body: &[u8],
    within: Limit,
    cancel: Option<&Wake>,
) -> io::Result<Response> {
    let mut answer = Vec::new();
    let mut response = exchange_with(
        socket,
        who,
        target,
        headers,
        body,
        (within, cancel),
        |head, piece| {
            if answer.is_empty() {
                let length = head
                    .header(http::CONTENT_LENGTH_HEADER)
                    .and_then(|length| length.parse().ok());
                answer.reserve(length.unwrap_or(0).min(MAX_RESERVE));
            }
            answer.extend_from_slice(piece);
            Ok(())
        },
    )
    .map_err(|error| match error {
        ExchangeError::NotSent(error) | ExchangeError::Unanswered(error) => error,
    })?;
    response.body = answer;
    Ok(response)
}

#[derive(Debug)]
enum ExchangeError {
    NotSent(io::Error),
    Unanswered(io::Error),
}

fn exchange_with(
    socket: &Resolved,
    who: Who,
    target: (&str, &protocol::RequestTarget),
    headers: &[(&str, &str)],
    body: &[u8],
    (within, cancel): (Limit, Option<&Wake>),
    mut sink: impl FnMut(&Response, &[u8]) -> io::Result<()>,
) -> Result<Response, ExchangeError> {
    let method = match target.0 {
        "GET" => protocol::Method::Get,
        "PUT" => protocol::Method::Put,
        "POST" => protocol::Method::Post,
        "PATCH" => protocol::Method::Patch,
        "DELETE" => protocol::Method::Delete,
        _ => {
            return Err(ExchangeError::NotSent(io::Error::new(
                io::ErrorKind::InvalidInput,
                "unsupported HTTP method",
            )));
        }
    };
    let request = exchange::Request {
        kind: exchange::RequestKind::Http {
            method,
            target: target.1.clone(),
            headers: headers
                .iter()
                .map(|(name, value)| ((*name).to_owned(), (*value).to_owned()))
                .collect(),
            body: exchange::Body::Complete(body),
        },
        destination: exchange::Destination::Server {
            client: who.0,
            caller: who.1,
        },
    };
    let mut poll = Poll::new();
    if let Some(cancel) = cancel {
        poll.watch(cancel.fd(), ko_sys::event::Interest::Read);
    }
    let mut exchange = exchange::Exchange::start(&mut poll, socket, request, within)
        .map_err(ExchangeError::NotSent)?;
    let result = (|| {
        let timer = poll.timer();
        let mut events = ko_sys::event::Events::default();
        let mut response: Option<Response> = None;
        let mut writable = true;
        loop {
            if cancel.is_some_and(Wake::is_set) {
                return Err(connect::cancelled_error());
            }
            if exchange.expired(&mut poll, Instant::now())? {
                return Err(io::ErrorKind::TimedOut.into());
            }
            exchange.begin_turn();
            if writable {
                exchange.writable(&mut poll)?;
            }
            exchange.flush(&mut poll)?;
            while let Some(event) = exchange.next(&mut poll).map_err(io::Error::from)? {
                match event {
                    http::response::Event::Head(head) => response = Some(head),
                    http::response::Event::Body(bytes) => {
                        if let Some(response) = &mut response {
                            sink(response, &bytes)?;
                        }
                    }
                    http::response::Event::Upgrade(head) => return Ok(head),
                    http::response::Event::End => {
                        return response.ok_or_else(|| {
                            io::Error::new(io::ErrorKind::InvalidData, "missing HTTP response")
                        });
                    }
                }
            }
            exchange.interest(&mut poll, true);
            poll.start(
                timer,
                exchange
                    .deadline()
                    .saturating_duration_since(Instant::now()),
                None,
            )?;
            poll.turn(ko_sys::event::Mode::Wait, &mut events)?;
            writable = events.ready().iter().any(|ready| {
                ready.token == exchange.token()
                    && (poll.wants(*ready).write || poll.wants(*ready).read)
            });
        }
    })();
    result.map_err(|error| {
        if !exchange.submitted() {
            ExchangeError::NotSent(error)
        } else {
            ExchangeError::Unanswered(error)
        }
    })
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Rejected {
    Status {
        status: u16,
        reason: String,
        body: Vec<u8>,
    },
    Io(String),
    Protocol(String),
    Tls(String),
    Identity(String),
    // The request was written and no answer was read: the server may have acted on it.
    Unanswered(String),
}

impl Rejected {
    pub(crate) fn unanswered(error: io::Error) -> Self {
        if stream::terminal(&error) {
            Self::from(error)
        } else {
            Self::Unanswered(text(error))
        }
    }
}

impl From<io::Error> for Rejected {
    fn from(error: io::Error) -> Rejected {
        #[cfg(feature = "tls")]
        match error
            .get_ref()
            .and_then(|error| error.downcast_ref::<crate::endpoint::tls::Failure>())
        {
            Some(crate::endpoint::tls::Failure::Tls(_)) => Rejected::Tls(text(error)),
            Some(crate::endpoint::tls::Failure::Identity(_)) => Rejected::Identity(text(error)),
            None => Rejected::Io(text(error)),
        }
        #[cfg(not(feature = "tls"))]
        {
            Rejected::Io(text(error))
        }
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
            Rejected::Io(message)
            | Rejected::Protocol(message)
            | Rejected::Tls(message)
            | Rejected::Identity(message)
            | Rejected::Unanswered(message) => formatter.write_str(message),
        }
    }
}

impl From<Rejected> for String {
    fn from(rejected: Rejected) -> String {
        rejected.to_string()
    }
}

fn fetch(
    socket: &Resolved,
    who: Who,
    route: &Route,
    body: &[u8],
    (cancel, within): (Option<&Wake>, Duration),
    mut sink: impl FnMut(&[u8]) -> io::Result<()>,
) -> Result<(), Rejected> {
    let (method, target) = route.to_request();
    let mut failure = Vec::new();
    let mut response = exchange_with(
        socket,
        who,
        (method, &target),
        &[],
        body,
        (Limit::Idle(within), cancel),
        |head, piece| {
            if head.status == 200 {
                sink(piece)
            } else {
                failure.extend_from_slice(piece);
                Ok(())
            }
        },
    )
    .map_err(|error| match error {
        ExchangeError::NotSent(error) => Rejected::from(error),
        ExchangeError::Unanswered(error) => Rejected::unanswered(error),
    })?;
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
    socket: &Resolved,
    who: Who,
    route: &Route,
    body: &[u8],
    cancel: Option<&Wake>,
) -> Result<Vec<u8>, Rejected> {
    request_within(socket, who, route, body, (cancel, READ_TIMEOUT))
}

#[cfg(all(target_vendor = "apple", feature = "tls"))]
#[derive(Debug)]
struct Available<'a> {
    stream: &'a mut Stream,
    cancel: &'a Wake,
    budget: usize,
}

#[cfg(all(target_vendor = "apple", feature = "tls"))]
impl Read for Available<'_> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        if self.cancel.is_set() {
            return Err(connect::cancelled_error());
        }
        if self.budget == 0 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "upload response exceeds read budget",
            ));
        }
        let capacity = buffer.len().min(self.budget);
        let count = self.stream.read(
            buffer
                .get_mut(..capacity)
                .ok_or(io::ErrorKind::InvalidInput)?,
        )?;
        self.budget = self
            .budget
            .checked_sub(count)
            .ok_or(io::ErrorKind::InvalidData)?;
        Ok(count)
    }
}

#[cfg(all(target_vendor = "apple", feature = "tls"))]
fn upload_response(reader: &mut impl Read) -> io::Result<Response> {
    let mut answer = Vec::new();
    let mut response = http::read_response_with(reader, |_, piece| {
        if answer.len().saturating_add(piece.len()) > 16384 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "upload response is too large",
            ));
        }
        answer.extend_from_slice(piece);
        Ok(())
    })?;
    response.body = answer;
    Ok(response)
}

#[cfg(all(target_vendor = "apple", feature = "tls"))]
pub(crate) fn upload(
    socket: stream::DirectEndpoint<'_>,
    client: Option<ClientId>,
    route: &Route,
    size: u64,
    cancel: &Wake,
    read: impl FnMut(&mut [u8]) -> io::Result<usize>,
) -> Result<Vec<u8>, Rejected> {
    let stream = stream::Direct::open(socket, Limit::Idle(READ_TIMEOUT), Some(cancel))?;
    upload_connected(stream, client, route, size, cancel, read)
}

#[cfg(all(target_vendor = "apple", feature = "tls"))]
fn upload_connected(
    stream: stream::Direct,
    client: Option<ClientId>,
    route: &Route,
    size: u64,
    cancel: &Wake,
    mut read: impl FnMut(&mut [u8]) -> io::Result<usize>,
) -> Result<Vec<u8>, Rejected> {
    let mut stream = Stream::Direct(stream);
    let within = Limit::Idle(READ_TIMEOUT);
    let (method, target) = route.to_request();
    let head = http::call_head(
        stream.host(),
        method,
        &target,
        client,
        &[
            ("Connection", "close"),
            ("Content-Type", "application/octet-stream"),
        ],
        size,
    );
    write_until(&mut stream, &head, Some(cancel), within)?;
    let mut remaining = size;
    let mut buffer = [0u8; 65536];
    while remaining > 0 {
        if cancel.is_set() {
            return Err(connect::cancelled_error().into());
        }
        match fd::wait(
            stream.fd(),
            Want::Read,
            Some(cancel.fd()),
            Some(Duration::ZERO),
        )? {
            Waited::Ready => {
                stream.set_nonblocking(true)?;
                let mut first = [0u8; 1];
                match stream.read(&mut first) {
                    Ok(0) => {}
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                    Err(error) => return Err(error.into()),
                    Ok(count) => {
                        let prefix = io::Cursor::new(
                            first
                                .get(..count)
                                .ok_or_else(|| io::Error::from(io::ErrorKind::InvalidData))?,
                        );
                        let mut reader = Interruptible {
                            stream: &mut stream,
                            cancel: Some(cancel),
                            within,
                        };
                        let response = upload_response(&mut prefix.chain(&mut reader))
                            .map_err(Rejected::unanswered)?;
                        return Err(if (200..300).contains(&response.status) {
                            Rejected::Protocol(
                                "server answered before the upload body was sent".to_owned(),
                            )
                        } else {
                            Rejected::Status {
                                status: response.status,
                                reason: response.reason,
                                body: response.body,
                            }
                        });
                    }
                }
            }
            Waited::Cancelled => return Err(connect::cancelled_error().into()),
            Waited::TimedOut => {}
        }
        let capacity = usize::try_from(remaining)
            .unwrap_or(usize::MAX)
            .min(buffer.len());
        let window = buffer
            .get_mut(..capacity)
            .ok_or_else(|| io::Error::from(io::ErrorKind::InvalidInput))?;
        let count = read(window)?;
        if count == 0 || count > capacity {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "upload reader did not provide the declared bytes",
            )
            .into());
        }
        if let Err(error) = write_until(
            &mut stream,
            window
                .get(..count)
                .ok_or_else(|| io::Error::from(io::ErrorKind::InvalidInput))?,
            Some(cancel),
            within,
        ) {
            if matches!(
                error.kind(),
                io::ErrorKind::BrokenPipe | io::ErrorKind::ConnectionReset
            ) && !cancel.is_set()
                && stream.set_nonblocking(true).is_ok()
            {
                let mut reader = Available {
                    stream: &mut stream,
                    cancel,
                    budget: 65536,
                };
                if let Ok(response) = upload_response(&mut reader)
                    && (400..600).contains(&response.status)
                {
                    return Err(Rejected::Status {
                        status: response.status,
                        reason: response.reason,
                        body: response.body,
                    });
                }
            }
            return Err(error.into());
        }
        remaining = remaining.saturating_sub(count as u64);
    }
    let mut reader = Interruptible {
        stream: &mut stream,
        cancel: Some(cancel),
        within,
    };
    succeeded(upload_response(&mut reader).map_err(Rejected::unanswered)?)
        .map(|response| response.body)
}

pub fn request_within(
    socket: &Resolved,
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
    socket: &Resolved,
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
    Gone,
    Shutdown,
    Closed,
}

#[derive(Debug)]
pub(crate) enum ReadError {
    Io(io::Error),
    TooLarge,
}

impl From<io::Error> for ReadError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<ReadError> for io::Error {
    fn from(error: ReadError) -> Self {
        match error {
            ReadError::Io(error) => error,
            other => io::Error::other(other.to_string()),
        }
    }
}

impl Display for ReadError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(error) => error.fmt(formatter),
            Self::TooLarge => formatter.write_str("WebSocket message exceeds its limit"),
        }
    }
}

#[derive(Debug)]
pub struct Link {
    stream: Stream,
    ctx: WebSocketContext,
    out: Queue,
    reads: Reads,
    token: Option<Token>,
    received: Instant,
    closing: Option<(protocol::CloseCode, String)>,
    cancel: Option<Arc<Wake>>,
    within: Duration,
}

struct Io<'a> {
    stream: &'a mut Stream,
    source: Option<(&'a mut Poll, Token, &'a mut Reads, Instant)>,
    out: &'a mut Queue,
    cancel: Option<&'a Wake>,
    received: &'a mut Instant,
    within: Duration,
}

impl Read for Io<'_> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        let count = match self.source.as_mut() {
            None => {
                flush_until(self.stream, self.out, self.cancel, self.within)?;
                Interruptible {
                    stream: self.stream,
                    cancel: self.cancel,
                    within: Limit::Idle(WATCHDOG),
                }
                .read(buffer)
            }
            Some((poll, token, reads, _)) => {
                match self.stream.read_ready(poll, *token, buffer, reads)? {
                    Some(PollData::Data(count)) => Ok(count),
                    Some(PollData::End) => Ok(0),
                    None => Err(io::ErrorKind::WouldBlock.into()),
                }
            }
        };
        let read = self.stream.take_read();
        if count.as_ref().is_ok_and(|count| *count > 0) || read {
            *self.received = self
                .source
                .as_ref()
                .map_or_else(Instant::now, |(_, _, _, now)| *now);
        }
        count
    }
}

impl Write for Io<'_> {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.out.extend(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

fn writer<'a>(
    stream: &'a mut Stream,
    out: &'a mut Queue,
    received: &'a mut Instant,
    within: Duration,
) -> Io<'a> {
    Io {
        stream,
        source: None,
        out,
        cancel: None,
        received,
        within,
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
        Link::upgrade_within(
            Stream::Direct(stream::Direct::Unix(stream)),
            client,
            route,
            cancel,
            READ_TIMEOUT,
        )
    }

    fn upgrade_within(
        stream: Stream,
        client: Option<ClientId>,
        route: &Route,
        cancel: Option<Arc<Wake>>,
        within: Duration,
    ) -> io::Result<Link> {
        Link::handshake(
            stream,
            (client, None),
            route,
            cancel,
            within,
            protocol::Upgrade::Control,
        )?
        .map_err(|response| refused(&response))
    }

    pub(crate) fn handshake(
        mut stream: Stream,
        (client, caller): Who,
        route: &Route,
        cancel: Option<Arc<Wake>>,
        within: Duration,
        limit: protocol::Upgrade,
    ) -> io::Result<Result<Link, Response>> {
        let (method, target) = route.to_request();
        let identity = identity(caller.as_ref());
        let (request, key) =
            upgrade_request(stream.host(), method, &target, client, &borrowed(&identity));
        write_until(
            &mut stream,
            &request,
            cancel.as_deref(),
            Limit::Idle(within),
        )?;
        let upgrade = http::read_upgrade(&mut Interruptible {
            stream: &mut stream,
            cancel: cancel.as_deref(),
            within: Limit::Idle(within),
        })?;
        let mut link = Link::upgraded(stream, upgrade, &key, cancel, None, limit)?;
        if let Ok(link) = &mut link {
            link.within = within;
        }
        Ok(link)
    }

    pub(crate) fn upgraded(
        stream: Stream,
        upgrade: Upgrade,
        key: &str,
        cancel: Option<Arc<Wake>>,
        token: Option<Token>,
        limit: protocol::Upgrade,
    ) -> io::Result<Result<Link, Response>> {
        let (response, rest) = match upgrade {
            Upgrade::Accepted(response, rest) => (response, rest),
            Upgrade::Refused(response) => return Ok(Err(response)),
        };
        accepted(&response, key)?;
        // macOS can return EINVAL for this tuning when the peer has closed.
        let _ = ko_sys::sock::set_receive_buffer(stream.fd(), RECEIVE_BUFFER);
        let mut link = Link::of_stream(stream, rest, limit);
        link.cancel = cancel;
        link.token = token;
        Ok(Ok(link))
    }

    pub fn of(stream: UnixStream, rest: Vec<u8>, limit: protocol::Upgrade) -> Link {
        Self::of_stream(Stream::Direct(stream::Direct::Unix(stream)), rest, limit)
    }

    pub(crate) fn of_stream(stream: Stream, rest: Vec<u8>, limit: protocol::Upgrade) -> Link {
        let max_message = match limit {
            protocol::Upgrade::Control => MAX_MESSAGE,
            protocol::Upgrade::Page => protocol::EXEC_CHUNK,
        };
        let config = WebSocketConfig::default()
            .read_buffer_size(1 << 15)
            .write_buffer_size(0)
            .max_message_size(Some(max_message))
            .max_frame_size(Some(max_message));
        Link {
            stream,
            ctx: WebSocketContext::from_partially_read(rest, Role::Client, Some(config)),
            out: Queue::default(),
            reads: Reads::new(),
            token: None,
            received: Instant::now(),
            closing: None,
            cancel: None,
            within: READ_TIMEOUT,
        }
    }

    pub fn connect_within(
        socket: &Resolved,
        client: Option<ClientId>,
        route: &Route,
        cancel: Option<Arc<Wake>>,
        within: Duration,
    ) -> io::Result<Link> {
        let mut poll = Poll::new();
        if let Some(cancel) = &cancel {
            poll.watch(cancel.fd(), ko_sys::event::Interest::Read);
        }
        let mut connecting =
            Connecting::start(socket, client, route, cancel.clone(), within, &mut poll)?;
        let timer = poll.timer();
        let mut events = ko_sys::event::Events::default();
        let mut ready = buffered(connecting.token());
        loop {
            match connecting.advance(&mut poll, &mut ready)? {
                UpgradeStep::Open(mut link) => {
                    link.unwatch(&mut poll);
                    link.within = within;
                    return Ok(*link);
                }
                UpgradeStep::Refused(response) => return Err(refused(&response)),
                UpgradeStep::Pending(pending) => connecting = pending,
            }
            poll.start(
                timer,
                connecting
                    .deadline()
                    .saturating_duration_since(Instant::now()),
                None,
            )?;
            poll.turn(ko_sys::event::Mode::Wait, &mut events)?;
            ready = Ready {
                token: connecting.token(),
                read: false,
                write: false,
            };
            for event in events.ready() {
                if event.token == ready.token {
                    let event = poll.wants(*event);
                    ready.read |= event.read;
                    ready.write |= event.write;
                }
            }
        }
    }

    pub fn watch(&mut self, poll: &mut Poll) -> io::Result<Token> {
        fd::set_nonblocking(self.stream.fd())?;
        let token = poll.watch(
            self.stream.fd(),
            self.stream.interest(true, !self.out.is_empty()),
        );
        self.token = Some(token);
        Ok(token)
    }

    pub fn token(&self) -> Option<Token> {
        self.token
    }

    pub fn unwatch(&mut self, poll: &mut Poll) {
        if let Some(token) = self.token.take() {
            poll.unwatch(token);
        }
    }

    pub fn close_frame(&self) -> Option<&(protocol::CloseCode, String)> {
        self.closing.as_ref()
    }

    pub fn received(&self) -> Instant {
        self.received
    }

    #[cfg(all(target_vendor = "apple", feature = "tls"))]
    pub(crate) fn reset_received(&mut self, now: Instant) {
        self.received = now;
    }

    pub fn begin_turn(&mut self) {
        self.stream.begin_turn();
        self.reads = Reads::new();
    }

    pub fn next(&mut self, poll: &mut Poll, now: Instant) -> io::Result<Next> {
        self.next_message(poll, now).map_err(Into::into)
    }

    pub(crate) fn next_message(
        &mut self,
        poll: &mut Poll,
        now: Instant,
    ) -> Result<Next, ReadError> {
        let Some(token) = self.token else {
            return Ok(Next::Closed);
        };

        loop {
            let next = Link::pump(
                &mut self.ctx,
                &mut Io {
                    stream: &mut self.stream,
                    source: Some((poll, token, &mut self.reads, now)),
                    out: &mut self.out,
                    cancel: None,
                    received: &mut self.received,
                    within: self.within,
                },
                &mut self.closing,
            )?;
            if matches!(next, Next::Shutdown | Next::Closed | Next::Gone) {
                let _ = self.stream.flush(&mut self.out);
            } else {
                self.settle(poll)?;
            }
            if !matches!(next, Next::Wait) || !self.stream.pending_read() {
                return Ok(next);
            }
        }
    }

    pub fn receive(&mut self) -> io::Result<Next> {
        let next = Link::pump(
            &mut self.ctx,
            &mut Io {
                stream: &mut self.stream,
                source: None,
                out: &mut self.out,
                cancel: self.cancel.as_deref(),
                received: &mut self.received,
                within: self.within,
            },
            &mut self.closing,
        )?;
        if matches!(next, Next::Shutdown | Next::Closed | Next::Gone) {
            let _ = self.flush_blocking();
        } else {
            self.flush_blocking()?;
        }
        Ok(next)
    }

    fn pump(
        ctx: &mut WebSocketContext,
        io: &mut Io<'_>,
        closing: &mut Option<(protocol::CloseCode, String)>,
    ) -> Result<Next, ReadError> {
        let next = loop {
            let message = match ctx.read(io) {
                Ok(message) => message,
                Err(Error::Io(error)) if error.kind() == io::ErrorKind::WouldBlock => {
                    break Next::Wait;
                }
                Err(Error::ConnectionClosed | Error::AlreadyClosed) => break Next::Closed,
                Err(Error::Capacity(_)) => return Err(ReadError::TooLarge),
                Err(error) => return Err(ReadError::Io(failed(error))),
            };
            match message {
                Message::Text(body) => break Next::Text(body),
                Message::Binary(body) => break Next::Binary(body),
                Message::Close(frame) => {
                    let _ = ctx.flush(io);
                    let shutdown = frame.as_ref().is_some_and(|frame| {
                        frame.code == tungstenite::protocol::frame::coding::CloseCode::Away
                    });
                    *closing = frame
                        .map(|frame| {
                            protocol::CloseCode::try_from(u16::from(frame.code))
                                .map(|code| (code, frame.reason.to_string()))
                        })
                        .transpose()
                        .map_err(|message| io::Error::new(io::ErrorKind::InvalidData, message))?;
                    break if shutdown {
                        Next::Shutdown
                    } else if closing.as_ref().is_some_and(|(_, reason)| reason == "gone") {
                        Next::Gone
                    } else {
                        Next::Closed
                    };
                }
                Message::Ping(_) | Message::Pong(_) | Message::Frame(_) => {}
            }
        };
        if !matches!(next, Next::Shutdown | Next::Closed | Next::Gone) {
            ctx.flush(io).map_err(failed)?;
        }
        Ok(next)
    }

    pub fn send(&mut self, body: String) -> io::Result<()> {
        self.message(Message::Text(body.into())).map(|_| ())
    }

    pub(crate) fn message(&mut self, message: Message) -> io::Result<std::ops::Range<u64>> {
        let len = message.len() as u64;
        self.ctx
            .flush(&mut writer(
                &mut self.stream,
                &mut self.out,
                &mut self.received,
                self.within,
            ))
            .map_err(failed)?;
        self.ctx
            .write(
                &mut writer(
                    &mut self.stream,
                    &mut self.out,
                    &mut self.received,
                    self.within,
                ),
                message,
            )
            .map_err(failed)?;
        let end = self.out.position()?;
        Ok(end.saturating_sub(len)..end)
    }

    pub(crate) fn close(
        &mut self,
        code: protocol::CloseCode,
        reason: protocol::CloseReason,
    ) -> io::Result<()> {
        self.ctx
            .close(
                &mut writer(
                    &mut self.stream,
                    &mut self.out,
                    &mut self.received,
                    self.within,
                ),
                Some(tungstenite::protocol::CloseFrame {
                    code: code.into(),
                    reason: String::from(reason).into(),
                }),
            )
            .map_err(failed)
    }

    pub(crate) fn drained(&self) -> bool {
        self.out.is_empty() && !self.stream.pending_write()
    }

    pub(crate) fn backed_up(&self) -> bool {
        self.out.backed_up(MAX_PENDING) || self.stream.pending_write()
    }

    pub(crate) fn interest(&self, poll: &mut Poll, read: bool) {
        if let Some(token) = self.token {
            self.stream
                .watch_interest(poll, token, read, !self.out.is_empty());
        }
    }

    #[cfg(all(target_vendor = "apple", feature = "tls"))]
    pub(crate) fn written(&self) -> u64 {
        self.out.written()
    }

    pub fn flush_blocking(&mut self) -> io::Result<()> {
        flush_until(
            &mut self.stream,
            &mut self.out,
            self.cancel.as_deref(),
            self.within,
        )
    }

    pub fn settle(&mut self, poll: &mut Poll) -> io::Result<()> {
        if let Some(token) = self.token {
            self.stream
                .flush_ready(poll, token, &mut self.reads, &mut self.out)?;
            self.stream
                .watch_interest(poll, token, true, !self.out.is_empty());
        } else {
            self.stream.flush(&mut self.out)?;
        }
        if self.stream.take_read() {
            self.received = Instant::now();
        }
        if self.out.sent_past_half() {
            self.out.compact();
        }
        Ok(())
    }
}

#[cfg(test)]
pub(crate) mod tests {
    #[path = "tls.rs"]
    pub(crate) mod tls;
    use super::*;

    #[cfg(all(target_vendor = "apple", feature = "tls"))]
    #[test]
    fn uploads_read_early_answers_between_chunks_without_finishing_the_body() {
        use std::os::unix::net::UnixListener;
        use std::sync::mpsc;
        for status in [http::Status::BadRequest, http::Status::Ok] {
            let dir = std::env::temp_dir().join(format!(
                "ko-early-upload-{}",
                ko_sys::entropy::hex(8).unwrap()
            ));
            std::fs::create_dir(&dir).unwrap();
            let socket = dir.join("socket");
            let listener = UnixListener::bind(&socket).unwrap();
            let body = protocol::json(&protocol::Error::new(
                protocol::ErrorKind::Invalid,
                "early refusal",
            ))
            .into_bytes();
            let reply = http::json_response(
                status,
                std::str::from_utf8(&body).unwrap(),
                http::Policy::Control,
            );
            let (sent, ready) = mpsc::channel();
            let (finish, finished) = mpsc::channel();
            let server = std::thread::spawn(move || {
                assert_eq!(
                    fd::wait(
                        listener.as_fd(),
                        Want::Read,
                        None,
                        Some(Duration::from_secs(5))
                    )
                    .unwrap(),
                    Waited::Ready
                );
                let (mut peer, _) = listener.accept().unwrap();
                peer.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
                peer.set_write_timeout(Some(Duration::from_secs(5)))
                    .unwrap();
                let mut request = Vec::new();
                let mut scanned = 0;
                loop {
                    match http::parse_head(&request, &mut scanned) {
                        http::Parsed::Complete { head, .. } => {
                            assert_eq!(head.method, "POST");
                            assert_eq!(head.target.as_str(), "/panes/pane_1/drops?name=quota");
                            assert_eq!(
                                head.header(http::CONTENT_LENGTH_HEADER),
                                Some("2147483649")
                            );
                            break;
                        }
                        http::Parsed::Partial => {}
                        other => panic!("unexpected request: {other:?}"),
                    }
                    let mut bytes = [0u8; 512];
                    let count = peer.read(&mut bytes).unwrap();
                    assert!(count > 0);
                    request.extend_from_slice(&bytes[..count]);
                }
                peer.write_all(&reply).unwrap();
                sent.send(()).unwrap();
                finished.recv_timeout(Duration::from_secs(5)).unwrap();
            });
            let mut reads = 0;
            let outcome = upload(
                stream::DirectEndpoint::Unix(&socket),
                None,
                &Route::UploadDrop {
                    id: "pane_1".parse().unwrap(),
                    name: "quota".to_owned().try_into().unwrap(),
                },
                2147483649,
                &Wake::new().unwrap(),
                |buffer| {
                    reads += 1;
                    if reads > 1 {
                        return Err(io::Error::other("reader called after the answer"));
                    }
                    ready.recv_timeout(Duration::from_secs(5)).unwrap();
                    buffer[0] = b'x';
                    Ok(1)
                },
            );
            finish.send(()).unwrap();
            server.join().unwrap();
            std::fs::remove_dir_all(dir).unwrap();
            let expected = if status == http::Status::Ok {
                Rejected::Protocol("server answered before the upload body was sent".to_owned())
            } else {
                Rejected::Status {
                    status: 400,
                    reason: "Bad Request".to_owned(),
                    body,
                }
            };
            assert_eq!(outcome, Err(expected));
        }
    }

    #[test]
    fn blocking_link_writes_time_out_when_the_peer_does_not_read() {
        for receive in [false, true] {
            let (stream, peer) = UnixStream::pair().unwrap();
            let (send, result) = std::sync::mpsc::channel();
            let worker = std::thread::spawn(move || {
                let mut link = Link::of(stream, Vec::new(), protocol::Upgrade::Control);
                link.within = Duration::from_millis(50);
                link.send("x".repeat(4 << 20)).unwrap();
                let error = if receive {
                    link.receive().unwrap_err()
                } else {
                    link.flush_blocking().unwrap_err()
                };
                let _ = send.send(error.kind());
            });
            assert_eq!(
                result.recv_timeout(Duration::from_secs(5)).unwrap(),
                io::ErrorKind::TimedOut
            );
            worker.join().unwrap();
            drop(peer);
        }
    }

    #[test]
    fn a_handshake_with_a_closed_peer_reports_the_hangup() {
        let closed = |stream: &UnixStream| {
            assert!(matches!(
                fd::wait(
                    stream.as_fd(),
                    Want::Read,
                    None,
                    Some(Duration::from_secs(5))
                )
                .unwrap(),
                Waited::Ready
            ));
            assert_eq!(fd::read(stream.as_fd(), &mut [0]).unwrap(), 0);
        };
        let (stream, peer) = UnixStream::pair().unwrap();
        drop(peer);
        closed(&stream);
        let error = Link::handshake(
            Stream::Direct(stream::Direct::Unix(stream)),
            (None, None),
            &Route::Client {},
            None,
            Duration::from_secs(1),
            protocol::Upgrade::Control,
        )
        .unwrap_err();
        assert!(
            matches!(
                error.kind(),
                io::ErrorKind::BrokenPipe | io::ErrorKind::NotConnected
            ),
            "{error:?}"
        );

        let (stream, mut peer) = UnixStream::pair().unwrap();
        let key = "test-key";
        let accept = tungstenite::handshake::derive_accept_key(key.as_bytes());
        write!(
            peer,
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n"
        )
        .unwrap();
        drop(peer);
        let mut transport = Stream::Direct(stream::Direct::Unix(stream));
        let upgrade = http::read_upgrade(&mut Interruptible {
            stream: &mut transport,
            cancel: None,
            within: Limit::Idle(Duration::from_secs(5)),
        })
        .unwrap();
        let Stream::Direct(stream::Direct::Unix(stream)) = transport else {
            panic!("expected Unix stream");
        };
        closed(&stream);
        assert!(
            Link::upgraded(
                Stream::Direct(stream::Direct::Unix(stream)),
                upgrade,
                key,
                None,
                None,
                protocol::Upgrade::Control
            )
            .unwrap()
            .is_ok()
        );
    }

    fn pair() -> (Link, UnixStream, Poll) {
        let (ours, theirs) = UnixStream::pair().unwrap();
        let mut link = Link::of(ours, Vec::new(), protocol::Upgrade::Control);
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
            let done = matches!(
                next,
                Next::Wait | Next::Shutdown | Next::Closed | Next::Gone
            );
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
    fn an_application_payload_follows_pending_control_frames() {
        let (mut link, mut server, _poll) = pair();
        server.write_all(&frame(9, b"p")).unwrap();
        assert_eq!(
            link.ctx
                .read(&mut writer(
                    &mut link.stream,
                    &mut link.out,
                    &mut link.received,
                    link.within
                ))
                .unwrap(),
            Message::Ping(Bytes::from_static(b"p"))
        );
        let range = link.message(Message::binary(vec![1; 65536])).unwrap();
        assert_eq!(link.out.bytes[0], 0x8a);
        assert_eq!(link.out.bytes[7], 0x82);
        assert_eq!(range, 21..65557);
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
    fn a_close_reply_to_a_peer_that_does_not_read_times_out() {
        let (stream, mut server) = UnixStream::pair().unwrap();
        stream.set_nonblocking(true).unwrap();
        let mut full = false;
        for _ in 0..1024 {
            match fd::write(stream.as_fd(), &[0; 65536]) {
                Ok(_) => {}
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    full = true;
                    break;
                }
                Err(error) => panic!("fill the send buffer: {error}"),
            }
        }
        assert!(full);
        stream.set_nonblocking(false).unwrap();
        server.write_all(&frame(8, &[])).unwrap();
        let (send, result) = std::sync::mpsc::channel();
        let worker = std::thread::spawn(move || {
            let mut link = Link::of(stream, Vec::new(), protocol::Upgrade::Control);
            link.within = Duration::from_millis(30);
            send.send(link.receive()).unwrap();
        });
        let received = result.recv_timeout(Duration::from_secs(1));
        drop(server);
        worker.join().unwrap();
        assert_eq!(received.unwrap().unwrap(), Next::Closed);
    }

    #[test]
    fn a_received_close_gets_a_masked_reply() {
        for blocking in [false, true] {
            for body in [
                Vec::new(),
                [4000_u16.to_be_bytes().as_slice(), b"finished"].concat(),
            ] {
                let (mut link, mut server, mut poll) = pair();
                server
                    .set_read_timeout(Some(Duration::from_secs(5)))
                    .unwrap();
                server.write_all(&frame(8, &body)).unwrap();
                if blocking {
                    assert_eq!(link.receive().unwrap(), Next::Closed);
                } else {
                    assert_eq!(settled(&mut link, &mut poll), [Next::Closed]);
                }
                let mut reply = vec![0; 6 + body.len()];
                server.read_exact(&mut reply).unwrap();
                assert_eq!(unmasked(&reply), (8, body));
            }
        }
    }

    #[test]
    fn a_close_is_typed_and_does_not_flush_to_a_closed_peer() {
        for (code, reason, expected) in [
            (1008_u16, "gone", Next::Gone),
            (1008, "io", Next::Closed),
            (1001, "shutdown", Next::Shutdown),
            (1001, "another reason", Next::Shutdown),
            (1008, "shutdown", Next::Closed),
        ] {
            let (mut link, mut server, mut poll) = pair();
            link.send("pending".to_owned()).unwrap();
            let mut body = code.to_be_bytes().to_vec();
            body.extend_from_slice(reason.as_bytes());
            server.write_all(&frame(8, &body)).unwrap();
            server.shutdown(std::net::Shutdown::Both).unwrap();
            assert_eq!(settled(&mut link, &mut poll), [expected]);
        }
    }

    #[test]
    fn partial_frames_feed_the_watchdog_but_outbound_messages_do_not() {
        let (mut link, mut server, mut poll) = pair();
        let start = link.received();
        let now = start + Duration::from_secs(20);
        server.write_all(&[0x82, 100, 1]).unwrap();
        assert_eq!(settled_at(&mut link, &mut poll, now), [Next::Wait]);
        assert_eq!(link.received(), now);
        link.send("input".to_owned()).unwrap();
        link.settle(&mut poll).unwrap();
        assert_eq!(link.received(), now);
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
