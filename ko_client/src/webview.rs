use ko_server::protocol::webview::FrameKind;

use std::io;
use std::ops::Range;
use std::os::fd::{AsFd, BorrowedFd};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::Instant;

use ko_server::api::Route;
use ko_server::http::{self, response};
#[cfg(target_vendor = "apple")]
use ko_server::ids::ClientId;
use ko_server::protocol::Method;
use ko_server::protocol::webview::{
    AbortReason, Data, Headers, MAX_IN_FLIGHT, ServeIn, ServeOut, Status,
};
use ko_server::protocol::{self, CloseCode, CloseReason};
use ko_sys::event::{Events, Interest, Mode, Poll, Read, Reads, Token};
use ko_sys::fd::Queue;
use tungstenite::{Bytes, Message};

use crate::api;
use crate::wire::{Caller, Link, Next, READ_TIMEOUT, ReadError};

#[derive(Debug, Clone, Copy)]
pub(crate) enum Target {
    #[cfg(target_vendor = "apple")]
    Server(ClientId),
    Program,
}

#[derive(Debug, Clone, Copy)]
pub(crate) enum Kind {
    Http(Method),
    Upgrade,
}

#[derive(Debug)]
enum Phase {
    Http {
        stream: UnixStream,
        reader: response::Reader,
        upgrade: Option<String>,
        eof: bool,
    },
    Socket {
        link: Box<Link>,
        phase: SocketPhase,
    },
}
#[derive(Debug)]
enum SocketPhase {
    Open,
    Closing(Instant),
    Finishing(Instant),
}

#[derive(Debug)]
pub(crate) enum Event {
    Response(http::Response),
    Upgraded(http::Response),
    Body(Vec<u8>),
    End,
    Message {
        data: Bytes,
        binary: FrameKind,
    },
    Closed {
        code: CloseCode,
        reason: CloseReason,
        result: io::Result<()>,
    },
}

#[derive(Debug)]
pub(crate) struct Upstream {
    token: Token,
    phase: Phase,
    out: Queue,
    deadline: Instant,
    reads: Reads,
}

fn invalid(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.into())
}

impl Upstream {
    pub(crate) fn open(
        poll: &mut Poll,
        path: &Path,
        kind: Kind,
        target: &ko_server::protocol::RequestTarget,
        headers: &Headers,
        destination: Target,
        body: &[u8],
    ) -> io::Result<Self> {
        let stream = UnixStream::from(ko_sys::sock::connect_nonblocking(path)?);
        let token = poll.watch(stream.as_fd(), Interest::ReadWrite);
        let client = match destination {
            #[cfg(target_vendor = "apple")]
            Target::Server(client) => Some(client),
            Target::Program => None,
        };
        let length = if client.is_some() || matches!(kind, Kind::Upgrade) {
            http::ForwardLength::Replace
        } else {
            http::ForwardLength::Keep
        };
        let identity = if client.is_some() {
            http::ForwardIdentity::Remove
        } else {
            http::ForwardIdentity::Pane
        };
        let fields: Vec<_> = http::forwarded(headers.pairs(), length, identity).collect();
        let (bytes, upgrade) = match kind {
            Kind::Upgrade => {
                let (bytes, key) = ko_server::ws::upgrade_request("GET", target, client, &fields);
                (bytes, Some(key))
            }
            Kind::Http(method) => {
                let bytes = match destination {
                    #[cfg(target_vendor = "apple")]
                    Target::Server(client) => {
                        let mut fields = fields;
                        fields.push(("Connection", "close"));
                        http::call(method.http(), target, Some(client), &fields, body)
                    }
                    Target::Program => http::program_call(method.http(), target, &fields, body),
                };
                (bytes, None)
            }
        };
        Ok(Self {
            token,
            phase: Phase::Http {
                stream,
                reader: response::Reader::default(),
                upgrade,
                eof: false,
            },
            out: Queue::new(bytes),
            deadline: Instant::now() + READ_TIMEOUT,
            reads: Reads::new(),
        })
    }

    pub(crate) fn socket(poll: &mut Poll, mut link: Link) -> io::Result<Self> {
        let token = link.watch(poll)?;
        Ok(Self {
            token,
            phase: Phase::Socket {
                link: Box::new(link),
                phase: SocketPhase::Open,
            },
            out: Queue::default(),
            deadline: Instant::now() + READ_TIMEOUT,
            reads: Reads::new(),
        })
    }
    #[cfg(target_vendor = "apple")]
    pub(crate) fn token(&self) -> Token {
        self.token
    }
    pub(crate) fn dispose(self, poll: &mut Poll) {
        poll.unwatch(self.token);
    }
    pub(crate) fn begin_turn(&mut self) {
        self.reads = Reads::new();
        if let Phase::Socket { link, .. } = &mut self.phase {
            link.begin_turn();
        }
    }
    pub(crate) fn backed_up(&self) -> bool {
        self.out.backed_up(http::MAX_BODY)
            || matches!(&self.phase,Phase::Socket {link,..} if link.backed_up())
    }
    fn is_socket(&self) -> bool {
        matches!(self.phase, Phase::Socket { .. })
    }
    pub(crate) fn closing(&self) -> bool {
        matches!(
            &self.phase,
            Phase::Socket {
                phase: SocketPhase::Closing(_) | SocketPhase::Finishing(_),
                ..
            }
        )
    }
    pub(crate) fn reported(&self) -> bool {
        matches!(
            &self.phase,
            Phase::Socket {
                phase: SocketPhase::Finishing(_),
                ..
            }
        )
    }
    pub(crate) fn drained(&self) -> bool {
        match &self.phase {
            Phase::Http { .. } => self.out.is_empty(),
            Phase::Socket { link, .. } => link.drained(),
        }
    }
    #[cfg(target_vendor = "apple")]
    pub(crate) fn written(&self) -> u64 {
        match &self.phase {
            Phase::Http { .. } => self.out.written(),
            Phase::Socket { link, .. } => link.output().written(),
        }
    }
    pub(crate) fn deadline(&self) -> Option<Instant> {
        match &self.phase {
            Phase::Http { reader, .. } => (!reader.started()).then_some(self.deadline),
            Phase::Socket {
                phase: SocketPhase::Closing(deadline) | SocketPhase::Finishing(deadline),
                ..
            } => Some(*deadline),
            Phase::Socket {
                phase: SocketPhase::Open,
                ..
            } => None,
        }
    }
    pub(crate) fn interest(&self, poll: &mut Poll, read: bool) {
        match &self.phase {
            Phase::Http { eof, .. } => poll.interest(
                self.token,
                Interest::of(read && !*eof, !self.out.is_empty()),
            ),
            Phase::Socket { link, phase } => {
                link.interest(poll, read && !matches!(phase, SocketPhase::Finishing(_)))
            }
        }
    }
    pub(crate) fn flush(&mut self, poll: &mut Poll) -> io::Result<()> {
        match &mut self.phase {
            Phase::Http { stream, .. } => {
                if let Some(error) = stream.take_error()? {
                    return Err(error);
                }
                self.out.flush(stream.as_fd())
            }
            Phase::Socket { link, .. } => link.settle(poll),
        }
    }
    fn body(&mut self, bytes: &[u8]) -> io::Result<()> {
        if !matches!(self.phase, Phase::Http { upgrade: None, .. }) {
            return Err(invalid("body for a WebSocket"));
        }
        self.out.extend(bytes);
        Ok(())
    }
    pub(crate) fn send(&mut self, message: Message) -> io::Result<Option<Range<u64>>> {
        let Phase::Socket { link, phase } = &mut self.phase else {
            return Err(invalid("frame before WebSocket upgrade"));
        };
        if !matches!(phase, SocketPhase::Open) {
            return Ok(None);
        }
        link.message(message).map(Some)
    }
    pub(crate) fn close(&mut self, code: CloseCode, reason: CloseReason) -> io::Result<()> {
        if let Phase::Socket {
            link,
            phase: phase @ SocketPhase::Open,
        } = &mut self.phase
        {
            link.close(code, reason)?;
            *phase = SocketPhase::Closing(Instant::now() + READ_TIMEOUT);
        }
        Ok(())
    }
    pub(crate) fn next(&mut self, poll: &mut Poll) -> Result<Option<Event>, response::Error> {
        loop {
            match &mut self.phase {
                Phase::Http {
                    stream,
                    reader,
                    upgrade,
                    eof,
                } => {
                    if let Some(event) = reader.next(*eof)? {
                        return Ok(Some(match event {
                            response::Event::Upgrade(head) => {
                                let key = upgrade
                                    .as_ref()
                                    .ok_or_else(|| invalid("unexpected WebSocket upgrade"))?;
                                ko_server::ws::accepted(&head, key)?;
                                let link = Link::of(
                                    stream.try_clone()?,
                                    reader.take_rest(),
                                    protocol::Upgrade::Page,
                                );
                                poll.unwatch(self.token);
                                *self = Self::socket(poll, link)?;
                                Event::Upgraded(response::metadata(head))
                            }
                            response::Event::Head(head) => {
                                response::identity(&head)?;
                                Event::Response(head)
                            }
                            response::Event::Body(bytes) => Event::Body(bytes),
                            response::Event::End => Event::End,
                        }));
                    }
                    let result = poll.read(
                        self.token,
                        stream.as_fd(),
                        reader.read_buffer(),
                        &mut self.reads,
                    );
                    let count = match &result {
                        Ok(Some(Read::Data(count))) => *count,
                        _ => 0,
                    };
                    reader.commit_read(count);
                    match result? {
                        Some(Read::Data(_)) => {}
                        Some(Read::End) => *eof = true,
                        None => return Ok(None),
                    }
                }
                Phase::Socket { link, phase } => {
                    if matches!(phase, SocketPhase::Finishing(_)) {
                        return Ok(None);
                    }
                    let (code, reason, result) = match link.next_message(poll, Instant::now()) {
                        Ok(Next::Wait) => return Ok(None),
                        Ok(Next::Text(text)) => {
                            return Ok(Some(Event::Message {
                                data: text.into(),
                                binary: FrameKind::Text,
                            }));
                        }
                        Ok(Next::Binary(data)) => {
                            return Ok(Some(Event::Message {
                                data,
                                binary: FrameKind::Binary,
                            }));
                        }
                        Ok(Next::Shutdown | Next::Closed | Next::Gone) => {
                            let (code, reason) = link
                                .close_frame()
                                .map(|(code, reason)| {
                                    CloseReason::try_from(reason.clone())
                                        .map(|reason| (*code, reason))
                                })
                                .transpose()
                                .map_err(invalid)?
                                .unwrap_or((CloseCode::NORMAL, CloseReason::EMPTY));
                            (code, reason, Ok(()))
                        }
                        Err(error) => {
                            let (code, reason) = link
                                .close_frame()
                                .map(|(code, reason)| {
                                    CloseReason::try_from(reason.clone())
                                        .map(|reason| (*code, reason))
                                })
                                .transpose()
                                .map_err(invalid)?
                                .unwrap_or({
                                    if matches!(error, ReadError::TooLarge) {
                                        (CloseCode::SIZE, CloseReason::SIZE)
                                    } else {
                                        (CloseCode::INTERNAL, CloseReason::PROGRAM_CLOSED)
                                    }
                                });
                            let _ = link.close(code, reason.clone());
                            (code, reason, Err(error.into()))
                        }
                    };
                    *phase = SocketPhase::Finishing(Instant::now() + READ_TIMEOUT);
                    return Ok(Some(Event::Closed {
                        code,
                        reason,
                        result,
                    }));
                }
            }
        }
    }
}

#[derive(Debug)]
struct Request {
    req: u64,
    upstream: Upstream,
}

fn failed(server: &mut Link, request: &Request, reason: AbortReason) -> io::Result<()> {
    let req = request.req;
    let message = match &request.upstream.phase {
        Phase::Http { .. } => ServeIn::Abort { req, reason },
        Phase::Socket {
            phase: SocketPhase::Finishing(_),
            ..
        } => return Ok(()),
        Phase::Socket { .. } => ServeIn::Close {
            req,
            code: CloseCode::INTERNAL,
            reason: CloseReason::PROGRAM_CLOSED,
        },
    };
    server.send(protocol::json(&message))
}
fn remove(poll: &mut Poll, requests: &mut Vec<Request>, index: usize) {
    requests.remove(index).upstream.dispose(poll);
}
fn command(
    poll: &mut Poll,
    server: &mut Link,
    requests: &mut Vec<Request>,
    path: &Path,
    message: ServeOut,
    supported: fn(bool) -> io::Result<()>,
) -> io::Result<()> {
    let (req, kind, target, headers) = match message {
        ServeOut::Request {
            req,
            method,
            path,
            headers,
        } => (req, Kind::Http(method), path, headers),
        ServeOut::Upgrade { req, path, headers } => (req, Kind::Upgrade, path, headers),
        ServeOut::Supported { supported: value } => return supported(value),
        ServeOut::Body { req, data, .. } => {
            if let Some(at) = requests.iter().position(|request| request.req == req)
                && requests[at].upstream.body(&data.into_bytes()).is_err()
            {
                failed(server, &requests[at], AbortReason::Program)?;
                remove(poll, requests, at);
            }
            return Ok(());
        }
        ServeOut::Frame { req, data, binary } => {
            if let Some(at) = requests.iter().position(|request| request.req == req) {
                let bytes = data.into_bytes();
                let message = binary
                    .into_message(bytes)
                    .map_err(|error| invalid(error.to_string()))?;
                if requests[at].upstream.send(message).is_err() {
                    failed(server, &requests[at], AbortReason::Program)?;
                    remove(poll, requests, at);
                }
            }
            return Ok(());
        }
        ServeOut::Cancel { req } => {
            if let Some(at) = requests.iter().position(|request| request.req == req) {
                remove(poll, requests, at);
            }
            return Ok(());
        }
        ServeOut::Close { req, code, reason } => {
            if let Some(at) = requests.iter().position(|request| request.req == req) {
                if requests[at].upstream.is_socket() {
                    if requests[at].upstream.close(code, reason).is_err() {
                        failed(server, &requests[at], AbortReason::Program)?;
                        remove(poll, requests, at);
                    }
                } else {
                    remove(poll, requests, at);
                }
            }
            return Ok(());
        }
    };
    if requests.iter().any(|request| request.req == req) {
        return Err(invalid("duplicate webview request"));
    }
    if requests.len() >= MAX_IN_FLIGHT {
        return server.send(protocol::json(&ServeIn::Abort {
            req,
            reason: AbortReason::Program,
        }));
    }
    match Upstream::open(poll, path, kind, &target, &headers, Target::Program, b"") {
        Ok(upstream) => requests.push(Request { req, upstream }),
        Err(_) => server.send(protocol::json(&ServeIn::Abort {
            req,
            reason: AbortReason::Program,
        }))?,
    }
    Ok(())
}
fn receive(poll: &mut Poll, server: &mut Link, request: &mut Request) -> io::Result<bool> {
    while !server.backed_up() {
        let event = match request.upstream.next(poll) {
            Ok(Some(event)) => event,
            Ok(None) => break,
            Err(error) => {
                let reason = match error {
                    response::Error::Encoded { coding } => AbortReason::Encoded { coding },
                    response::Error::Io(_) => AbortReason::Program,
                };
                failed(server, request, reason)?;
                return Ok(true);
            }
        };
        let req = request.req;
        server.send(protocol::json(&match event {
            Event::Response(head) | Event::Upgraded(head) => {
                let (Ok(status), Ok(headers)) = (
                    Status::try_from(head.status),
                    Headers::try_from(head.headers),
                ) else {
                    failed(server, request, AbortReason::Program)?;
                    return Ok(true);
                };
                ServeIn::Response {
                    req,
                    status,
                    headers,
                }
            }
            Event::Body(bytes) => {
                let Ok(data) = Data::new(bytes) else {
                    failed(server, request, AbortReason::Program)?;
                    return Ok(true);
                };
                ServeIn::Body {
                    req,
                    data,
                    more: true,
                }
            }
            Event::End => {
                server.send(protocol::json(&ServeIn::Body {
                    req,
                    data: Data::empty(),
                    more: false,
                }))?;
                return Ok(true);
            }
            Event::Message { data, binary } => ServeIn::Frame {
                req,
                data: protocol::Text(Vec::from(data)),
                binary,
            },
            Event::Closed {
                code,
                reason,
                result,
            } => {
                let _ = result;
                ServeIn::Close { req, code, reason }
            }
        }))?;
    }
    Ok(request.upstream.closing() && request.upstream.drained())
}

pub fn serve(
    dir: &Path,
    caller: Caller,
    path: &Path,
    stdin: BorrowedFd<'_>,
    supported: fn(bool) -> io::Result<()>,
) -> io::Result<()> {
    let pane = caller.pane;
    let (_, route) = Route::WebviewServe { id: pane }.to_request();
    let mut server = match api::stream(dir, Some(caller), route.as_str()) {
        Ok(Ok(link)) => link,
        Ok(Err(response)) => {
            return Err(io::Error::other(api::describe(
                dir,
                api::response_error(&response),
            )));
        }
        Err(api::Error::Server(failure)) => {
            return Err(io::Error::other(api::describe(
                dir,
                api::ReplyError::Server(failure),
            )));
        }
        Err(api::Error::Websocket | api::Error::NotWebsocket) => {
            return Err(invalid("not a WebSocket route"));
        }
    };
    let mut poll = Poll::new();
    let source = server.watch(&mut poll)?;
    let input = poll.watch(stdin, Interest::Read);
    let timer = poll.timer();
    let mut events = Events::default();
    let mut requests: Vec<Request> = Vec::new();
    loop {
        server.begin_turn();
        for request in &mut requests {
            request.upstream.begin_turn();
        }
        if !requests.iter().any(|request| request.upstream.backed_up()) {
            loop {
                match server.next(&mut poll, Instant::now())? {
                    Next::Text(text) => command(
                        &mut poll,
                        &mut server,
                        &mut requests,
                        path,
                        protocol::decode(text.as_bytes())
                            .map_err(|error| invalid(error.to_string()))?,
                        supported,
                    )?,
                    Next::Wait => break,
                    Next::Shutdown | Next::Closed | Next::Gone => return Ok(()),
                    Next::Binary(_) => return Err(invalid("binary webview serve message")),
                }
                if requests.iter().any(|request| request.upstream.backed_up()) {
                    break;
                }
            }
        }
        let mut at = 0;
        while at < requests.len() {
            if requests[at].upstream.flush(&mut poll).is_err() {
                if !requests[at].upstream.reported() {
                    failed(&mut server, &requests[at], AbortReason::Program)?;
                }
                remove(&mut poll, &mut requests, at);
                continue;
            }
            if receive(&mut poll, &mut server, &mut requests[at])? {
                remove(&mut poll, &mut requests, at);
            } else {
                at = at.saturating_add(1);
            }
        }
        server.settle(&mut poll)?;
        server.interest(
            &mut poll,
            !requests.iter().any(|request| request.upstream.backed_up()),
        );
        let mut deadline = None;
        for request in &requests {
            request.upstream.interest(&mut poll, !server.backed_up());
            if let Some(next) = request.upstream.deadline() {
                deadline = Some(deadline.map_or(next, |old: Instant| old.min(next)));
            }
        }
        if let Some(deadline) = deadline {
            poll.start(
                timer,
                deadline.saturating_duration_since(Instant::now()),
                None,
            )?;
        } else {
            poll.stop(timer);
        }
        poll.turn(Mode::Wait, &mut events)?;
        for ready in events.ready() {
            let ready = poll.wants(*ready);
            if ready.token == input && ready.read {
                let mut bytes = [0; 4096];
                if ko_sys::fd::read(stdin, &mut bytes)? == 0 {
                    return Ok(());
                }
            }
            if ready.token == source {
                server.settle(&mut poll)?;
            }
        }
        let now = Instant::now();
        let mut at = 0;
        while at < requests.len() {
            if requests[at]
                .upstream
                .deadline()
                .is_some_and(|deadline| deadline <= now)
            {
                if !requests[at].upstream.closing() {
                    failed(&mut server, &requests[at], AbortReason::Program)?;
                }
                remove(&mut poll, &mut requests, at);
            } else {
                at = at.saturating_add(1);
            }
        }
    }
}
