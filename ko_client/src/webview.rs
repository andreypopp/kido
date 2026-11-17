use ko_wire::protocol::webview::FrameKind;

use crate::endpoint::Resolved;
use crate::wire::exchange::{Body, Destination, Request as ExchangeRequest, RequestKind};
use std::io;
use std::ops::Range;
use std::os::fd::BorrowedFd;

use std::path::Path;
use std::time::Instant;

use crate::wire::exchange::Exchange;
use ko_sys::event::{Events, Interest, Mode, Poll, Token};
use ko_wire::api::Route;
use ko_wire::http::{self, response};
use ko_wire::protocol::Method;
use ko_wire::protocol::webview::{
    AbortReason, Data, Headers, MAX_IN_FLIGHT, ServeIn, ServeOut, Status,
};
use ko_wire::protocol::{self, CloseCode, CloseReason};
use tungstenite::{Bytes, Message};

use crate::api;
use crate::wire::{Caller, Link, Next, READ_TIMEOUT, ReadError};

#[derive(Debug, Clone, Copy)]
pub(crate) enum Kind {
    Http(Method),
    Upgrade,
}

#[derive(Debug)]
enum Phase {
    Closed {
        token: Token,
    },
    Http {
        exchange: Exchange,
    },
    Socket {
        link: Box<Link>,
        token: Token,
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
    phase: Phase,
}

fn invalid(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.into())
}

impl Upstream {
    pub(crate) fn open(
        poll: &mut Poll,
        endpoint: &Resolved,
        kind: Kind,
        target: &ko_wire::protocol::RequestTarget,
        headers: &Headers,
        destination: Destination,
        body: &[u8],
    ) -> io::Result<Self> {
        let (length, identity) = match destination {
            Destination::Server { .. } => {
                (http::ForwardLength::Replace, http::ForwardIdentity::Remove)
            }
            Destination::Program => (
                if matches!(kind, Kind::Upgrade) {
                    http::ForwardLength::Replace
                } else {
                    http::ForwardLength::Keep
                },
                http::ForwardIdentity::Pane,
            ),
        };
        let mut headers: Vec<_> = http::forwarded(headers.pairs(), length, identity)
            .map(|(name, value)| (name.to_owned(), value.to_owned()))
            .collect();
        if matches!(destination, Destination::Server { .. }) {
            headers.push(("Connection".to_owned(), "close".to_owned()));
        }
        let kind = match kind {
            Kind::Upgrade => RequestKind::WebSocket {
                target: target.clone(),
                headers,
            },
            Kind::Http(method) => RequestKind::Http {
                method,
                target: target.clone(),
                headers,
                body: match destination {
                    Destination::Server { .. } => Body::Complete(body),
                    Destination::Program => Body::Streaming(body),
                },
            },
        };
        let request = ExchangeRequest { kind, destination };
        let exchange = Exchange::start(
            poll,
            endpoint,
            request,
            crate::wire::Limit::Deadline(Instant::now() + READ_TIMEOUT),
        )?;
        Ok(Self {
            phase: Phase::Http { exchange },
        })
    }

    pub(crate) fn socket(poll: &mut Poll, mut link: Link) -> io::Result<Self> {
        let token = link.watch(poll)?;
        Ok(Self {
            phase: Phase::Socket {
                link: Box::new(link),
                token,
                phase: SocketPhase::Open,
            },
        })
    }
    #[cfg(all(target_vendor = "apple", feature = "tls"))]
    pub(crate) fn token(&self) -> Token {
        match &self.phase {
            Phase::Http { exchange, .. } => exchange.token(),
            Phase::Socket { token, .. } | Phase::Closed { token } => *token,
        }
    }
    pub(crate) fn dispose(self, poll: &mut Poll) {
        match self.phase {
            Phase::Http { exchange, .. } => exchange.dispose(poll),
            Phase::Socket { token, .. } | Phase::Closed { token } => poll.unwatch(token),
        }
    }
    pub(crate) fn begin_turn(&mut self) {
        match &mut self.phase {
            Phase::Http { exchange, .. } => exchange.begin_turn(),
            Phase::Socket { link, .. } => link.begin_turn(),
            Phase::Closed { .. } => {}
        }
    }
    pub(crate) fn backed_up(&self) -> bool {
        match &self.phase {
            Phase::Http { exchange, .. } => exchange.backed_up(),
            Phase::Socket { link, .. } => link.backed_up(),
            Phase::Closed { .. } => false,
        }
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
            Phase::Closed { .. } => true,
            Phase::Http { exchange, .. } => exchange.drained(),
            Phase::Socket { link, .. } => link.drained(),
        }
    }
    #[cfg(all(target_vendor = "apple", feature = "tls"))]
    pub(crate) fn written(&self) -> u64 {
        match &self.phase {
            Phase::Closed { .. } => 0,
            Phase::Http { exchange, .. } => exchange.written(),
            Phase::Socket { link, .. } => link.written(),
        }
    }
    pub(crate) fn deadline(&self) -> Option<Instant> {
        match &self.phase {
            Phase::Closed { .. } => None,
            Phase::Http { exchange, .. } => (!exchange.started()).then(|| exchange.deadline()),
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
    pub(crate) fn expired(&mut self, poll: &mut Poll, now: Instant) -> io::Result<bool> {
        if let Phase::Http { exchange, .. } = &mut self.phase {
            return if exchange.started() {
                Ok(false)
            } else {
                exchange.expired(poll, now)
            };
        }
        Ok(self.deadline().is_some_and(|deadline| now >= deadline))
    }

    pub(crate) fn interest(&self, poll: &mut Poll, read: bool) {
        match &self.phase {
            Phase::Closed { .. } => {}
            Phase::Http { exchange, .. } => exchange.interest(poll, read),
            Phase::Socket { link, phase, .. } => {
                link.interest(poll, read && !matches!(phase, SocketPhase::Finishing(_)))
            }
        }
    }
    #[cfg(all(target_vendor = "apple", feature = "tls"))]
    pub(crate) fn writable(&mut self, poll: &mut Poll) -> io::Result<()> {
        match &mut self.phase {
            Phase::Http { exchange, .. } => exchange.writable(poll),
            _ => Ok(()),
        }
    }

    pub(crate) fn flush(&mut self, poll: &mut Poll) -> io::Result<()> {
        match &mut self.phase {
            Phase::Closed { .. } => Ok(()),
            Phase::Http { exchange, .. } => exchange.flush(poll),
            Phase::Socket { link, .. } => link.settle(poll),
        }
    }
    fn body(&mut self, bytes: &[u8]) -> io::Result<()> {
        let Phase::Http { exchange } = &mut self.phase else {
            return Err(invalid("body for a WebSocket"));
        };
        exchange.body(bytes)
    }
    pub(crate) fn send(&mut self, message: Message) -> io::Result<Option<Range<u64>>> {
        let Phase::Socket { link, phase, .. } = &mut self.phase else {
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
            ..
        } = &mut self.phase
        {
            link.close(code, reason)?;
            *phase = SocketPhase::Closing(Instant::now() + READ_TIMEOUT);
        }
        Ok(())
    }
    pub(crate) fn next(&mut self, poll: &mut Poll) -> Result<Option<Event>, response::Error> {
        match &mut self.phase {
            Phase::Closed { .. } => Ok(None),
            Phase::Http { exchange } => {
                if let Some(event) = exchange.next(poll)? {
                    return Ok(Some(match event {
                        response::Event::Upgrade(head) => {
                            exchange.accepted(&head)?;
                            let token = exchange.token();
                            let Phase::Http { exchange, .. } =
                                std::mem::replace(&mut self.phase, Phase::Closed { token })
                            else {
                                return Err(invalid("upgrade outside HTTP").into());
                            };
                            let (stream, rest, token) = exchange.into_stream();
                            poll.unwatch(token);
                            let link = Link::of_stream(stream, rest, protocol::Upgrade::Page);
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
                Ok(None)
            }
            Phase::Socket { link, phase, .. } => {
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
                                CloseReason::try_from(reason.clone()).map(|reason| (*code, reason))
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
                                CloseReason::try_from(reason.clone()).map(|reason| (*code, reason))
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
                Ok(Some(Event::Closed {
                    code,
                    reason,
                    result,
                }))
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
        Phase::Closed { .. } | Phase::Http { .. } => ServeIn::Abort { req, reason },
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
    match Upstream::open(
        poll,
        &Resolved::Unix(path.to_owned()),
        kind,
        &target,
        &headers,
        Destination::Program,
        b"",
    ) {
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
                .expired(&mut poll, now)
                .unwrap_or(true)
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
