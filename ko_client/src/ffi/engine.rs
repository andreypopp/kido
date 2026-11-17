#![deny(unsafe_code)]

mod webview;

use std::io;
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

use ko_pane_wire::frame::Limits;
use ko_pane_wire::ring::Slice as Header;
use ko_sys::event::{Due, Events, Interest, Mode, Poll, Ready, Timer, Token};
use ko_wire::api::{Offset, Route};
use ko_wire::ids::ClientId;
use ko_wire::protocol::{
    self, ClientEvent, ClientRequest, Hello, ViewEvent as Wire, ViewRequest, json,
};
use ko_wire::ws::{Parsed, parse_record};
use tungstenite::Bytes;

use super::view::{Feed, Slice, View};
use super::{Code, Command, Posted, Shared, ViewEvent, layout_of, locked, post, string};
use crate::connect::{self, BACKOFF_FIRST, backoff_after};
use crate::endpoint::{Dial, Resolving};
use crate::model::{Applied, Greeting, JoinError, Model, Rejoin};
use crate::wire::quic::h3::{Connection as Quic, StreamFailure};
use crate::wire::{Connecting, Link, Next, READ_TIMEOUT, UpgradeStep, buffered, silent, text};

const WATCH: Duration = Duration::from_secs(2);
const KEEP_ALIVE: Duration = Duration::from_secs(15);
const QUIC_HANDSHAKE_LIMIT: Duration = Duration::from_secs(2);

#[derive(Debug)]
enum Transport {
    Direct,
    QuicDialing {
        owner: Quic,
        target: Arc<crate::endpoint::Remote>,
        addresses: Arc<[std::net::SocketAddr]>,
        remaining: std::collections::VecDeque<std::net::SocketAddr>,
        deadline: Instant,
        attempt_due: Instant,
    },
    Quic {
        owner: Quic,
    },
}
impl Transport {
    fn dispose(self, poll: &mut Poll, error: io::Error) {
        match self {
            Self::Direct => {}
            Self::QuicDialing { owner, .. } | Self::Quic { owner } => owner.detach(poll, error),
        }
    }
}
#[derive(Debug, Clone, Copy)]
enum QuicEvent {
    Ready(Ready),
    Due(Due),
    FinishTurn,
}

#[derive(Debug)]
struct Session {
    link: Link,
    token: Token,
    client: ClientId,
    limits: Limits,
}

#[derive(Debug)]
enum Connection {
    Idle,
    Resolving {
        resolver: Resolving,
        token: Token,
    },
    Upgrading {
        link: Connecting,
    },
    Greeting {
        link: Box<Link>,
        token: Token,
        greeting: Greeting,
    },
    Probing {
        exchange: crate::wire::exchange::Exchange,
        response: Option<ko_wire::http::Response>,
        failed: Failed,
    },
    Established(Session),
}

impl Connection {
    fn session(&self) -> Option<&Session> {
        match self {
            Self::Established(session) => Some(session),
            _ => None,
        }
    }

    fn session_mut(&mut self) -> Option<&mut Session> {
        match self {
            Self::Established(session) => Some(session),
            _ => None,
        }
    }

    fn token(&self) -> Option<Token> {
        match self {
            Self::Idle => None,
            Self::Resolving { token, .. } | Self::Greeting { token, .. } => Some(*token),
            Self::Upgrading { link } => Some(link.token()),
            Self::Probing { exchange, .. } => Some(exchange.token()),
            Self::Established(session) => Some(session.token),
        }
    }

    fn dispose(self, poll: &mut Poll) {
        if let Some(token) = self.token() {
            poll.unwatch(token);
        }
    }
}

struct Conn {
    token: Token,
    state: ViewLink,
}

#[derive(Debug)]
enum ViewLink {
    Connecting { link: Connecting },
    Open { link: Box<Link>, paused: bool },
}

struct Open {
    view: Arc<View>,
    conn: Option<Conn>,
    deadline: Timer,
}

struct Engine<'a> {
    shared: &'a Arc<Shared>,
    poll: Poll,
    events: Events,
    wake: Token,
    retry: Timer,
    watch: Timer,
    webview_deadline: Timer,
    webview_due: Option<Instant>,
    backoff: Duration,
    reported: Option<Code>,
    connection: Connection,
    transport: Transport,
    dial: Timer,
    joining: Timer,
    join_due: Instant,
    views: Vec<Open>,
    webview: Vec<webview::Open>,
}

type Failed = (Code, String);

pub(super) fn failure(error: &io::Error) -> Failed {
    let code = if let Some(failure) = error
        .get_ref()
        .and_then(|error| error.downcast_ref::<crate::endpoint::tls::Failure>())
    {
        match failure {
            crate::endpoint::tls::Failure::Tls(_) => Code::Tls,
            crate::endpoint::tls::Failure::Identity(_) => Code::Identity,
        }
    } else if connect::absent(error)
        || matches!(
            error.kind(),
            io::ErrorKind::TimedOut
                | io::ErrorKind::AddrNotAvailable
                | io::ErrorKind::NetworkUnreachable
                | io::ErrorKind::HostUnreachable
                | io::ErrorKind::NetworkDown
        )
    {
        Code::NoServer
    } else if error.kind() == io::ErrorKind::InvalidData {
        Code::Protocol
    } else if matches!(
        error.kind(),
        io::ErrorKind::BrokenPipe
            | io::ErrorKind::ConnectionReset
            | io::ErrorKind::NotConnected
            | io::ErrorKind::UnexpectedEof
    ) {
        Code::Closed
    } else {
        Code::Io
    };
    (code, error.to_string())
}

fn protocol_error(message: String) -> Failed {
    (Code::Protocol, message)
}

pub(super) fn run(shared: &Arc<Shared>) {
    let mut poll = Poll::new();
    let wake = poll.watch(shared.wake.fd(), Interest::Read);
    poll.watch(shared.cancel.fd(), Interest::Read);
    let (retry, watch, webview_deadline) = (poll.timer(), poll.timer(), poll.timer());
    let mut engine = Engine {
        shared,
        events: Events::default(),
        wake,
        retry,
        watch,
        webview_deadline,
        webview_due: None,
        backoff: BACKOFF_FIRST,
        reported: None,
        connection: Connection::Idle,
        transport: Transport::Direct,
        dial: poll.timer(),
        joining: poll.timer(),
        join_due: Instant::now(),
        views: Vec::new(),
        webview: Vec::new(),
        poll,
    };
    engine.serve();
    shared.up.store(false, Ordering::SeqCst);
    engine.webview_shutdown();
    std::mem::replace(&mut engine.connection, Connection::Idle).dispose(&mut engine.poll);
    std::mem::replace(&mut engine.transport, Transport::Direct)
        .dispose(&mut engine.poll, io::ErrorKind::Interrupted.into());
}

impl Engine<'_> {
    fn serve(&mut self) {
        self.connect();
        while !self.shared.cancel.is_set() {
            self.arm_webview_deadline();
            if self.poll.turn(Mode::Wait, &mut self.events).is_err() {
                return;
            }
            for at in 0..self.events.ready().len() {
                if let Some(ready) = self.events.ready().get(at).copied() {
                    self.ready(self.poll.wants(ready));
                }
            }
            for at in 0..self.events.due().len() {
                let Some(due) = self.events.due().get(at).copied() else {
                    continue;
                };
                if !self.poll.current(due) {
                    continue;
                }
                if self.drive_quic(QuicEvent::Due(due)) {
                    continue;
                }
                if due.timer == self.retry {
                    self.connect();
                } else if due.timer == self.joining {
                    self.join_ready(buffered(self.connection.token().unwrap_or(self.wake)));
                } else if due.timer == self.watch {
                    self.watchdog();
                } else if due.timer == self.webview_deadline {
                    self.webview_due = None;
                    self.webview_expired(Instant::now());
                } else if let Some(at) = self
                    .views
                    .iter()
                    .position(|open| open.deadline == due.timer)
                    && let Some(conn) = self.views[at].conn.as_ref()
                {
                    self.view_ready(
                        at,
                        Ready {
                            token: conn.token,
                            read: false,
                            write: false,
                        },
                    );
                }
            }
            self.drive_quic(QuicEvent::FinishTurn);
        }
    }

    fn connect(&mut self) {
        if !matches!(self.connection, Connection::Idle) {
            return;
        }
        let started = Resolving::start(&self.shared.endpoint);
        self.join_due = Instant::now() + READ_TIMEOUT;
        let _ = self.poll.start(self.joining, READ_TIMEOUT, None);
        let result = started.and_then(|resolver| match resolver.take()? {
            Some(endpoint) => self.dial(endpoint),
            None => {
                let descriptor = resolver
                    .fd()
                    .ok_or_else(|| io::Error::other("resolver wake missing"))?;
                let token = self.poll.watch(descriptor, Interest::Read);
                self.connection = Connection::Resolving { resolver, token };
                Ok(())
            }
        });
        if let Err(error) = result {
            self.join_failed(failure(&error));
        }
    }

    fn join_failed(&mut self, (code, message): Failed) {
        std::mem::replace(&mut self.connection, Connection::Idle).dispose(&mut self.poll);
        self.poll.stop(self.joining);
        if self.shared.cancel.is_set() {
            return;
        }
        if code.terminal() || code == Code::NoServer {
            self.lose(code, &message);
        } else {
            let endpoint = locked(&self.shared.resolved).clone();
            let started = endpoint
                .ok_or_else(|| io::Error::from(io::ErrorKind::NotConnected))
                .and_then(|endpoint| {
                    let (_, target) = Route::Version {}.to_request();
                    let request = crate::wire::exchange::Request {
                        kind: crate::wire::exchange::RequestKind::Http {
                            method: protocol::Method::Get,
                            target,
                            headers: vec![("Connection".to_owned(), "close".to_owned())],
                            body: crate::wire::exchange::Body::Complete(b""),
                        },
                        destination: crate::wire::exchange::Destination::Server {
                            client: None,
                            caller: None,
                        },
                    };
                    crate::wire::exchange::Exchange::start(
                        &mut self.poll,
                        &endpoint,
                        request,
                        crate::wire::Limit::Deadline(Instant::now() + READ_TIMEOUT),
                    )
                });
            match started {
                Ok(exchange) => {
                    let _ = self.poll.start(
                        self.joining,
                        exchange
                            .deadline()
                            .saturating_duration_since(Instant::now()),
                        None,
                    );
                    self.connection = Connection::Probing {
                        exchange,
                        response: None,
                        failed: (code, message),
                    };
                }
                Err(_) => self.lose(code, &message),
            }
        }
    }

    fn probe_ready(&mut self, ready: Ready) {
        let Connection::Probing {
            mut exchange,
            mut response,
            failed,
        } = std::mem::replace(&mut self.connection, Connection::Idle)
        else {
            return;
        };
        let result: io::Result<bool> = (|| {
            if exchange.expired(&mut self.poll, Instant::now())? {
                return Err(io::ErrorKind::TimedOut.into());
            }
            exchange.begin_turn();
            if ready.write {
                exchange.writable(&mut self.poll)?;
            }
            exchange.flush(&mut self.poll)?;
            while let Some(event) = exchange.next(&mut self.poll).map_err(io::Error::from)? {
                match event {
                    ko_wire::http::response::Event::Head(head) => response = Some(head),
                    ko_wire::http::response::Event::Body(bytes) => {
                        if let Some(response) = &mut response {
                            response.body.extend(bytes);
                        }
                    }
                    ko_wire::http::response::Event::End
                    | ko_wire::http::response::Event::Upgrade(_) => return Ok(true),
                }
            }
            exchange.interest(&mut self.poll, true);
            Ok(false)
        })();
        match result {
            Ok(false) => {
                let _ = self.poll.start(
                    self.joining,
                    exchange
                        .deadline()
                        .saturating_duration_since(Instant::now()),
                    None,
                );
                self.connection = Connection::Probing {
                    exchange,
                    response,
                    failed,
                };
            }
            _ => {
                exchange.dispose(&mut self.poll);
                self.poll.stop(self.joining);
                let mismatch = result
                    .ok()
                    .and(response.as_ref())
                    .and_then(|response| crate::api::version_response(response).ok())
                    .and_then(|(kind, version)| kind.map(|kind| (Code::of(&kind), version)));
                if let Some((code, server)) = mismatch {
                    self.poll.stop(self.retry);
                    self.poll.stop(self.dial);
                    std::mem::replace(&mut self.transport, Transport::Direct).dispose(
                        &mut self.poll,
                        io::Error::new(io::ErrorKind::InvalidData, "server version mismatch"),
                    );
                    self.shared.up.store(false, Ordering::SeqCst);
                    post(self.shared, Posted::Mismatch(code, server));
                } else {
                    self.lose(failed.0, &failed.1);
                }
            }
        }
    }

    fn dial(&mut self, dial: Dial) -> io::Result<()> {
        match dial {
            Dial::Unix(path) => self.upgrade(Arc::new(crate::endpoint::Resolved::Unix(path))),
            Dial::Remote { target, addresses } => {
                if target.choice() == crate::endpoint::Choice::Tcp {
                    self.upgrade(Arc::new(crate::endpoint::Resolved::Tls {
                        target: Arc::clone(&target.tcp),
                        addresses,
                    }))
                } else {
                    let remaining = addresses.iter().copied().collect();
                    self.start_quic(
                        target,
                        addresses,
                        remaining,
                        (Instant::now() + QUIC_HANDSHAKE_LIMIT).min(self.join_due),
                    )
                }
            }
        }
    }

    fn start_quic(
        &mut self,
        target: Arc<crate::endpoint::Remote>,
        addresses: Arc<[std::net::SocketAddr]>,
        mut remaining: std::collections::VecDeque<std::net::SocketAddr>,
        deadline: Instant,
    ) -> io::Result<()> {
        while Instant::now() < deadline {
            let now = Instant::now();
            let share = deadline.saturating_duration_since(now)
                / u32::try_from(remaining.len()).unwrap_or(u32::MAX).max(1);
            let attempt_due = now + share;
            let Some(peer) = remaining.pop_front() else {
                break;
            };
            match Quic::start(&target, peer, &mut self.poll, KEEP_ALIVE) {
                Ok((owner, access)) => {
                    if let Err(error) = self.poll.start(
                        self.dial,
                        attempt_due.saturating_duration_since(Instant::now()),
                        None,
                    ) {
                        owner.detach(
                            &mut self.poll,
                            io::Error::new(error.kind(), error.to_string()),
                        );
                        return Err(error);
                    }
                    self.transport = Transport::QuicDialing {
                        owner,
                        target,
                        addresses,
                        remaining,
                        deadline,
                        attempt_due,
                    };
                    return self.upgrade(Arc::new(crate::endpoint::Resolved::Quic(access)));
                }
                Err(failed) => {
                    if crate::wire::stream::terminal(&failed) {
                        return Err(failed);
                    }
                }
            }
        }
        *locked(&self.shared.resolved) = None;
        target.choose(crate::endpoint::Choice::Tcp);
        self.upgrade(Arc::new(crate::endpoint::Resolved::Tls {
            target: Arc::clone(&target.tcp),
            addresses,
        }))
    }

    fn drive_quic(&mut self, event: QuicEvent) -> bool {
        let transport = std::mem::replace(&mut self.transport, Transport::Direct);
        let (mut owner, dial) = match transport {
            Transport::Direct => return false,
            Transport::Quic { owner } => (owner, None),
            Transport::QuicDialing {
                owner,
                target,
                addresses,
                remaining,
                deadline,
                attempt_due,
            } => (
                owner,
                Some((target, addresses, remaining, deadline, attempt_due)),
            ),
        };
        let result = match event {
            QuicEvent::Ready(ready) => owner.ready(&mut self.poll, ready),
            QuicEvent::Due(due) if due.timer == self.dial => Ok(true),
            QuicEvent::Due(due) => owner.due(&mut self.poll, due),
            QuicEvent::FinishTurn => owner.finish_turn(&mut self.poll),
        };
        let established = owner.established();
        if established && let Some((target, ..)) = &dial {
            target.choose(crate::endpoint::Choice::Quic);
            self.poll.stop(self.dial);
        }
        let result = result.and_then(|handled| {
            if !established
                && dial
                    .as_ref()
                    .is_some_and(|(_, _, _, _, attempt_due)| Instant::now() >= *attempt_due)
            {
                Err(io::ErrorKind::TimedOut.into())
            } else {
                Ok(handled)
            }
        });
        match result {
            Ok(handled) => {
                self.transport = match dial {
                    Some((target, addresses, remaining, deadline, attempt_due)) if !established => {
                        Transport::QuicDialing {
                            owner,
                            target,
                            addresses,
                            remaining,
                            deadline,
                            attempt_due,
                        }
                    }
                    _ => {
                        self.poll.stop(self.dial);
                        Transport::Quic { owner }
                    }
                };
                handled
            }
            Err(error) => {
                let failed = failure(&error);
                std::mem::replace(&mut self.connection, Connection::Idle).dispose(&mut self.poll);
                owner.detach(&mut self.poll, error);
                self.poll.stop(self.dial);
                *locked(&self.shared.resolved) = None;
                if let Some((target, addresses, remaining, deadline, _)) = dial
                    && !established
                    && !failed.0.terminal()
                {
                    if let Err(error) = self.start_quic(target, addresses, remaining, deadline) {
                        self.join_failed(failure(&error));
                    }
                } else {
                    self.lose(failed.0, &failed.1);
                }
                true
            }
        }
    }

    fn upgrade(&mut self, endpoint: Arc<crate::endpoint::Resolved>) -> io::Result<()> {
        *locked(&self.shared.resolved) = Some(Arc::clone(&endpoint));
        let link = Connecting::start(
            &endpoint,
            None,
            &Route::Client {},
            Some(Arc::clone(&self.shared.cancel)),
            self.join_due.saturating_duration_since(Instant::now()),
            &mut self.poll,
        )?;
        let _ = self.poll.start(
            self.joining,
            link.deadline()
                .min(self.join_due)
                .saturating_duration_since(Instant::now()),
            None,
        );
        self.connection = Connection::Upgrading { link };
        Ok(())
    }

    fn hello(&self) -> Hello {
        let shared = self.shared;
        {
            let greeting = locked(&shared.hello);
            Hello {
                name: greeting.name.clone(),
                webview: greeting.webview,
                focused: greeting.focused,
                sizing: greeting.sizing.clone(),
                selection: locked(&shared.model)
                    .as_ref()
                    .map(|model| model.selection)
                    .unwrap_or_default(),
            }
        }
    }

    fn join_ready(&mut self, mut ready: Ready) {
        if matches!(self.connection, Connection::Probing { .. }) {
            self.probe_ready(ready);
            return;
        }
        let token = ready.token;
        let result = self.advance_join(&mut ready);
        if let Err(error) = result {
            self.poll.unwatch(token);
            self.join_failed(error);
        }
    }

    fn advance_join(&mut self, ready: &mut Ready) -> Result<(), Failed> {
        if Instant::now() >= self.join_due {
            return Err(failure(&io::ErrorKind::TimedOut.into()));
        }
        let state = std::mem::replace(&mut self.connection, Connection::Idle);
        match state {
            Connection::Resolving { resolver, token } => {
                match resolver.take().map_err(|error| failure(&error))? {
                    Some(endpoint) => {
                        self.poll.unwatch(token);
                        self.dial(endpoint).map_err(|error| failure(&error))?;
                    }
                    None => self.connection = Connection::Resolving { resolver, token },
                }
                Ok(())
            }
            Connection::Upgrading { link } => {
                match link.advance(&mut self.poll, ready).map_err(|error| {
                    let (code, message) = failure(&error);
                    (
                        if code == Code::Closed {
                            Code::NoServer
                        } else {
                            code
                        },
                        message,
                    )
                })? {
                    UpgradeStep::Pending(link) => {
                        let _ = self.poll.start(
                            self.joining,
                            link.deadline()
                                .min(self.join_due)
                                .saturating_duration_since(Instant::now()),
                            None,
                        );
                        self.connection = Connection::Upgrading { link };
                        Ok(())
                    }
                    UpgradeStep::Refused(response) => Err(if response.status == 502 {
                        (Code::NoServer, "proxy cannot reach server".to_owned())
                    } else {
                        protocol_error(format!("HTTP {} {}", response.status, response.reason))
                    }),
                    UpgradeStep::Open(mut link) => {
                        let token = ready.token;
                        link.send(json(&ClientRequest::Hello(self.hello())))
                            .and_then(|()| link.settle(&mut self.poll))
                            .map_err(|error| failure(&error))?;
                        let _ = self.poll.start(
                            self.joining,
                            self.join_due.saturating_duration_since(Instant::now()),
                            None,
                        );
                        self.connection = Connection::Greeting {
                            link,
                            token,
                            greeting: Greeting::Welcome,
                        };
                        self.advance_join(&mut buffered(token))
                    }
                }
            }
            Connection::Greeting {
                mut link,
                token,
                mut greeting,
            } => {
                link.begin_turn();
                if ready.write || (ready.read && !link.drained()) {
                    link.settle(&mut self.poll)
                        .map_err(|error| failure(&error))?;
                }
                loop {
                    match link
                        .next(&mut self.poll, Instant::now())
                        .map_err(|error| failure(&error))?
                    {
                        Next::Wait => {
                            self.connection = Connection::Greeting {
                                link,
                                token,
                                greeting,
                            };
                            return Ok(());
                        }
                        Next::Text(event) => {
                            let event = protocol::decode::<ClientEvent>(event.as_bytes())
                                .map_err(|error| protocol_error(text(error)))?;
                            if let Some(model) =
                                greeting.advance(event).map_err(|error| match error {
                                    JoinError::Refused(message) => (Code::Refused, message),
                                    JoinError::Protocol(message) => protocol_error(message),
                                    JoinError::Io(error) => failure(&error),
                                })?
                            {
                                return self.joined(link, token, model);
                            }
                        }
                        _ => return Err(protocol_error("client event missing".to_owned())),
                    }
                    if Instant::now() >= self.join_due {
                        return Err(failure(&io::ErrorKind::TimedOut.into()));
                    }
                }
            }
            state => {
                self.connection = state;
                Ok(())
            }
        }
    }

    fn joined(&mut self, link: Box<Link>, token: Token, joined: Model) -> Result<(), Failed> {
        let shared = self.shared;
        self.poll.stop(self.joining);
        let (rejoin, first) = match locked(&shared.model).as_mut() {
            Some(earlier) => (earlier.gate(joined), false),
            None => (Rejoin::Fresh(joined), true),
        };
        let (model, fresh) = match rejoin {
            Rejoin::Resume(model) => (model, false),
            Rejoin::Fresh(model) => (model, true),
        };
        let session = Session {
            link: *link,
            token,
            client: model.client,
            limits: model.limits,
        };
        *locked(&shared.client) = Some(model.client);
        let welcome = Posted::Welcome {
            client: string(&model.client.to_string()),
            instance: string(&model.instance.to_string()),
            fresh,
        };
        let layout = Posted::Layout(layout_of(&model));
        *locked(&shared.model) = Some(model);
        self.connection = Connection::Established(session);
        shared.up.store(true, Ordering::SeqCst);
        post(shared, welcome);
        post(shared, layout);
        self.backoff = BACKOFF_FIRST;
        self.reported = None;
        let watch = WATCH.min(shared.watchdog);
        let _ = self.poll.start(self.watch, watch, Some(watch));
        if fresh && !first {
            for open in std::mem::take(&mut self.views) {
                self.close_view(open, Code::Closed, "the server restarted");
            }
        } else {
            let ids: Vec<u64> = self.views.iter().map(|open| open.view.id).collect();
            for id in ids {
                let present = self
                    .views
                    .iter()
                    .find(|open| open.view.id == id)
                    .is_some_and(|open| {
                        locked(&shared.model)
                            .as_ref()
                            .is_some_and(|model| model.locate(open.view.pane).is_some())
                    });
                if first || present {
                    self.open_link(id);
                } else {
                    self.end_view(id, Code::Closed, "the pane is gone");
                }
            }
        }
        self.client_ready(buffered(token))
    }

    fn lose(&mut self, code: Code, message: &str) {
        while !self.webview.is_empty() {
            self.end_webview(0, code, message);
        }
        if code.terminal()
            || self.reported.is_none()
            || (code == Code::NoServer && self.reported != Some(Code::NoServer))
        {
            self.reported = Some(code);
            post(self.shared, Posted::Failed(code, string(message)));
        }
        std::mem::replace(&mut self.connection, Connection::Idle).dispose(&mut self.poll);
        std::mem::replace(&mut self.transport, Transport::Direct).dispose(
            &mut self.poll,
            io::Error::new(io::ErrorKind::ConnectionReset, message.to_owned()),
        );
        self.poll.stop(self.dial);
        self.poll.stop(self.joining);
        self.shared.up.store(false, Ordering::SeqCst);
        locked(&self.shared.commands).retain(|command| !matches!(command, Command::Size(_)));
        self.poll.stop(self.watch);
        if code.terminal() {
            self.poll.stop(self.retry);
            for open in std::mem::take(&mut self.views) {
                self.close_view(open, code, message);
            }
            return;
        }
        for open in &mut self.views {
            if open.conn.is_some() {
                post_link(self.shared, &open.view, code, message);
            }
            open.drop_conn(&mut self.poll);
        }
        let _ = self.poll.start(self.retry, self.backoff, None);
        self.backoff = backoff_after(self.backoff);
    }

    fn watchdog(&mut self) {
        let now = Instant::now();

        let silent_client = self
            .connection
            .session()
            .is_some_and(|session| silent(session.link.received(), now, self.shared.watchdog));
        if silent_client {
            self.lose(Code::Closed, "the server went silent");
            return;
        }
        let ids: Vec<u64> = self
            .views
            .iter()
            .filter(|open| {
                open.unpaused().is_some_and(|(link, paused)| {
                    !paused && silent(link.received(), now, self.shared.watchdog)
                })
            })
            .map(|open| open.view.id)
            .collect();
        for id in ids {
            self.reopen_view(id, Code::Closed, "the pane view went silent");
        }
    }

    fn ready(&mut self, ready: Ready) {
        if self.drive_quic(QuicEvent::Ready(ready)) {
            return;
        }
        if !(ready.read || ready.write) {
            return;
        }
        if ready.token == self.wake {
            self.shared.wake.drain();
            self.commands();
            self.resume();
        } else if self.connection.token() == Some(ready.token) {
            if !matches!(self.connection, Connection::Established(_)) {
                self.join_ready(ready);
                return;
            }
            if let Err((code, message)) = self.client_ready(ready) {
                self.lose(code, &message);
            }
        } else if let Some(at) = self.views.iter().position(|open| {
            open.conn
                .as_ref()
                .is_some_and(|conn| conn.token == ready.token)
        }) {
            self.view_ready(at, ready);
        } else if let Some(at) = self
            .webview
            .iter()
            .position(|open| open.token() == ready.token)
        {
            self.webview_ready(at, ready);
        }
    }

    fn client_ready(&mut self, ready: Ready) -> Result<(), Failed> {
        let Some(session) = self.connection.session_mut() else {
            return Ok(());
        };
        session.link.begin_turn();
        if ready.write || (ready.read && !session.link.drained()) {
            session
                .link
                .settle(&mut self.poll)
                .map_err(|error| failure(&error))?;
        }
        let now = Instant::now();
        loop {
            let Some(session) = self.connection.session_mut() else {
                return Ok(());
            };
            match session
                .link
                .next(&mut self.poll, now)
                .map_err(|error| failure(&error))?
            {
                Next::Wait => return Ok(()),
                Next::Shutdown | Next::Closed | Next::Gone => {
                    return Err((Code::Closed, "server closed".to_owned()));
                }
                Next::Binary(_) => return Err(protocol_error("binary client message".to_owned())),
                Next::Text(event) => {
                    let event = protocol::decode::<ClientEvent>(event.as_bytes())
                        .map_err(|error| protocol_error(text(error)))?;
                    self.apply(event);
                }
            }
        }
    }

    fn apply(&mut self, event: ClientEvent) {
        let applied = match locked(&self.shared.model).as_mut() {
            Some(model) => model.apply(event),
            None => return,
        };
        self.announce(&applied);
    }

    fn announce(&self, applied: &Applied) {
        let shared = self.shared;
        let posted = match applied {
            Applied::Nothing => return,
            Applied::State if shared.model_pending.swap(true, Ordering::SeqCst) => return,
            Applied::State => Posted::Model,
            Applied::Layout => match locked(&shared.model).as_ref() {
                Some(model) => Posted::Layout(layout_of(model)),
                None => return,
            },
            Applied::Selected(request) => match locked(&shared.model).as_ref() {
                Some(model) => Posted::Selected(*request, model.selection),
                None => return,
            },
            Applied::Notice(notice) => Posted::Alert(notice.clone()),
        };
        post(shared, posted);
    }

    fn commands(&mut self) {
        let batch = std::mem::take(&mut *locked(&self.shared.commands));
        for command in batch {
            match command {
                Command::WebviewStart(task, request) => self.webview_start(task, request),
                Command::WebviewStop(id) => {
                    if let Some(at) = self.webview_index(id) {
                        self.webview.remove(at).dispose(&mut self.poll);
                    }
                }
                Command::WebviewResume(id) => {
                    if let Some(at) = self.webview_index(id) {
                        let token = self.webview[at].token();
                        self.webview_ready(at, buffered(token));
                    }
                }
                Command::WebviewWrite(id, write) => self.webview_write(id, write),
                Command::Request(request) => self.request(&request),
                Command::Size(sizing) => self.request(&ClientRequest::Size { sizing }),
                Command::Open(view) => {
                    let id = view.id;
                    self.views.push(Open {
                        view,
                        conn: None,
                        deadline: self.poll.timer(),
                    });
                    if self.connection.session().is_some() {
                        self.open_link(id);
                    }
                }
                Command::Close(id) => {
                    if let Some(at) = self.views.iter().position(|open| open.view.id == id) {
                        let mut open = self.views.remove(at);
                        open.drop_conn(&mut self.poll);
                        self.poll.free(open.deadline);
                    }
                }
                Command::Resync(id, options) => {
                    self.send_view(id, &ViewRequest::Resync(options));
                }
                Command::Input(id, input) => self.send_view(id, &ViewRequest::Input { input }),
            }
        }
    }

    fn request(&mut self, request: &ClientRequest) {
        let Some(session) = self.connection.session_mut() else {
            return;
        };
        let sent = session
            .link
            .send(json(request))
            .and_then(|()| session.link.settle(&mut self.poll));
        if let Err(error) = sent {
            let (code, message) = failure(&error);
            self.lose(code, &message);
        }
    }

    fn send_view(&mut self, id: u64, request: &ViewRequest) {
        let Some(open) = self.views.iter_mut().find(|open| open.view.id == id) else {
            return;
        };
        let Some(conn) = open.conn.as_mut() else {
            return;
        };
        let ViewLink::Open { link, paused } = &mut conn.state else {
            return;
        };
        let sent = link
            .send(json(request))
            .and_then(|()| link.settle(&mut self.poll));
        match sent {
            Err(error) => {
                let (code, message) = failure(&error);
                self.reopen_view(id, code, &message);
            }
            Ok(()) if *paused => link.interest(&mut self.poll, false),
            Ok(()) => {}
        }
    }

    fn open_link(&mut self, id: u64) {
        let Some(session) = self.connection.session() else {
            return;
        };
        let (client, shared) = (session.client, self.shared);
        let Some(open) = self.views.iter_mut().find(|open| open.view.id == id) else {
            return;
        };
        if open.conn.is_some() {
            return;
        }
        let options = *locked(&open.view.options);
        let route = Route::View {
            id: open.view.pane,
            history: options.history,
            images: options.images,
            offset: open.view.resume_offset().and_then(Offset::new),
        };
        let Some(endpoint) = locked(&shared.resolved).clone() else {
            return;
        };
        let linked = Connecting::start(
            &endpoint,
            Some(client),
            &route,
            Some(Arc::clone(&shared.cancel)),
            READ_TIMEOUT,
            &mut self.poll,
        );
        match linked {
            Ok(link) => {
                let token = link.token();
                let _ = self.poll.start(
                    open.deadline,
                    link.deadline().saturating_duration_since(Instant::now()),
                    None,
                );
                open.conn = Some(Conn {
                    token,
                    state: ViewLink::Connecting { link },
                });
            }
            Err(error) => self.view_connect_failed(id, error),
        }
    }

    fn view_connect_failed(&mut self, id: u64, error: io::Error) {
        let (code, message) = failure(&error);
        match error
            .get_ref()
            .and_then(|error| error.downcast_ref::<StreamFailure>())
        {
            Some(StreamFailure::Admission) => self.end_view(id, code, &message),
            Some(
                StreamFailure::Reset { .. } | StreamFailure::Protocol(_) | StreamFailure::Io(_),
            ) => self.reopen_view(id, code, &message),
            None => self.lose(code, &message),
        }
    }

    fn reopen_view(&mut self, id: u64, code: Code, message: &str) {
        if let Some(open) = self.views.iter_mut().find(|open| open.view.id == id) {
            if open.conn.is_some() {
                post_link(self.shared, &open.view, code, message);
            }
            open.drop_conn(&mut self.poll);
        }
        self.open_link(id);
    }

    fn close_view(&mut self, mut open: Open, code: Code, message: &str) {
        open.drop_conn(&mut self.poll);
        self.poll.free(open.deadline);
        post(
            self.shared,
            Posted::View(open.view, ViewEvent::Closed(code, string(message))),
        );
    }

    fn end_view(&mut self, id: u64, code: Code, message: &str) {
        if let Some(at) = self.views.iter().position(|open| open.view.id == id) {
            let open = self.views.remove(at);
            self.close_view(open, code, message);
        }
    }

    fn resume(&mut self) {
        let ids: Vec<u64> = self
            .views
            .iter()
            .filter(|open| open.unpaused().is_some_and(|(_, paused)| paused))
            .map(|open| open.view.id)
            .collect();
        for id in ids {
            let Some(at) = self.views.iter().position(|open| open.view.id == id) else {
                continue;
            };
            let Some(conn) = self.views.get_mut(at).and_then(|open| open.conn.as_mut()) else {
                continue;
            };
            let ViewLink::Open { link, paused } = &mut conn.state else {
                continue;
            };
            *paused = false;
            link.reset_received(Instant::now());
            let token = conn.token;
            match link.settle(&mut self.poll) {
                Ok(()) => self.view_ready(at, buffered(token)),
                Err(error) => {
                    let (code, message) = failure(&error);
                    self.reopen_view(id, code, &message);
                }
            }
        }
    }

    fn view_ready(&mut self, at: usize, mut ready: Ready) {
        let continuation = self
            .connection
            .session()
            .map_or(0, |session| session.limits.continuation_max_bytes);
        let Some(open) = self.views.get_mut(at) else {
            return;
        };
        let id = open.view.id;
        let Some(conn) = open.conn.take() else {
            return;
        };
        match conn.state {
            ViewLink::Connecting { link } => match link.advance(&mut self.poll, &mut ready) {
                Ok(UpgradeStep::Pending(link)) => {
                    let _ = self.poll.start(
                        open.deadline,
                        link.deadline().saturating_duration_since(Instant::now()),
                        None,
                    );
                    open.conn = Some(Conn {
                        token: ready.token,
                        state: ViewLink::Connecting { link },
                    });
                    return;
                }
                Ok(UpgradeStep::Open(link)) => {
                    self.poll.stop(open.deadline);
                    open.conn = Some(Conn {
                        token: conn.token,
                        state: ViewLink::Open {
                            link,
                            paused: false,
                        },
                    });
                    open.view.up.store(true, Ordering::SeqCst);
                    post_link(self.shared, &open.view, Code::Ok, "view link up");
                    ready = buffered(conn.token);
                }
                Ok(UpgradeStep::Refused(response)) => {
                    self.poll.stop(open.deadline);
                    self.poll.unwatch(conn.token);
                    let (code, message) = failure(&ko_wire::ws::refused(&response));
                    self.lose(code, &message);
                    return;
                }
                Err(error) => {
                    self.poll.stop(open.deadline);
                    self.poll.unwatch(conn.token);
                    self.view_connect_failed(id, error);
                    return;
                }
            },
            ViewLink::Open { .. } => open.conn = Some(conn),
        }
        let Some(conn) = open.conn.as_mut() else {
            return;
        };
        let ViewLink::Open { link, paused } = &mut conn.state else {
            return;
        };
        #[derive(Debug)]
        enum End {
            Gone,
            Outage(Failed),
        }

        let pause = &open.view.pause;
        let mut outcome = Ok(());
        link.begin_turn();
        if ready.write || (ready.read && !link.drained()) {
            outcome = link
                .settle(&mut self.poll)
                .map_err(|error| End::Outage(failure(&error)));
        }
        if outcome.is_ok() && (ready.read || ready.write) {
            let now = Instant::now();
            while !pause.load(Ordering::SeqCst) {
                match link.next(&mut self.poll, now) {
                    Ok(Next::Wait) => break,
                    Ok(Next::Gone) => {
                        outcome = Err(End::Gone);
                        break;
                    }
                    Ok(Next::Shutdown | Next::Closed) => {
                        let message = link.close_frame().map_or_else(
                            || "pane view closed".to_owned(),
                            |(code, reason)| format!("close {}: {reason}", u16::from(*code)),
                        );
                        outcome = Err(End::Outage((Code::Closed, message)));
                        break;
                    }
                    Ok(Next::Text(event)) => feed_text(&open.view, &event),
                    Ok(Next::Binary(record)) => {
                        if let Err(message) = feed_record(&open.view, continuation, &record) {
                            outcome = Err(End::Outage(protocol_error(message.to_owned())));
                            break;
                        }
                    }
                    Err(error) => {
                        outcome = Err(End::Outage(failure(&error)));
                        break;
                    }
                }
            }
        }
        match outcome {
            Err(End::Gone) => self.end_view(id, Code::Closed, "pane view closed"),
            Err(End::Outage((code, message))) if code.terminal() => self.lose(code, &message),
            Err(End::Outage((code, message))) => self.reopen_view(id, code, &message),
            Ok(()) if pause.load(Ordering::SeqCst) => {
                *paused = true;
                link.interest(&mut self.poll, false);
            }
            Ok(()) => {}
        }
    }
}

fn post_link(shared: &Arc<Shared>, view: &Arc<View>, code: Code, message: &str) {
    post(
        shared,
        Posted::View(Arc::clone(view), ViewEvent::Link(code, string(message))),
    );
}

impl Open {
    fn unpaused(&self) -> Option<(&Link, bool)> {
        if self.view.pause.load(Ordering::SeqCst) {
            return None;
        }
        match &self.conn.as_ref()?.state {
            ViewLink::Open { link, paused } => Some((link, *paused)),
            ViewLink::Connecting { .. } => None,
        }
    }

    fn drop_conn(&mut self, poll: &mut Poll) {
        poll.stop(self.deadline);
        if let Some(conn) = self.conn.take() {
            poll.unwatch(conn.token);
        }
        self.view.up.store(false, Ordering::SeqCst);
        self.view.abandon();
    }
}

fn feed_text(view: &Arc<View>, event: &str) {
    if let Ok(Wire::Marked(marked)) = protocol::decode(event.as_bytes()) {
        view.feed(Feed::Marker {
            offset: marked.offset,
            marker: marked.marker,
        });
    }
}

fn feed_record(view: &Arc<View>, continuation: usize, record: &Bytes) -> Result<(), &'static str> {
    match parse_record(record).map_err(|_| "invalid record")? {
        Parsed::Output { offset, data } => view.feed(Feed::Bytes {
            offset,
            data: record.slice_ref(data),
        }),
        Parsed::Snapshot { offset, slice } => {
            let data = Bytes::from(slice);
            let (header, body) = Header::decode(&data).ok_or("short snapshot slice")?;
            view.slice(
                &Slice {
                    first: header.first,
                    last: header.last,
                    history: !header.screen,
                    offset,
                    continuation,
                },
                data.slice_ref(body),
            )?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn unavailable_networks_are_no_server() {
        for kind in [
            io::ErrorKind::NetworkUnreachable,
            io::ErrorKind::HostUnreachable,
            io::ErrorKind::NetworkDown,
            io::ErrorKind::AddrNotAvailable,
            io::ErrorKind::ConnectionRefused,
            io::ErrorKind::TimedOut,
        ] {
            assert_eq!(failure(&kind.into()).0, Code::NoServer);
        }
    }
}
