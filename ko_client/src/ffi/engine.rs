#![deny(unsafe_code)]

mod webview;

use std::io;
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

use ko_pane_wire::frame::Limits;
use ko_pane_wire::ring::Slice as Header;
use ko_server::api::{Offset, Route};
use ko_server::ids::ClientId;
use ko_server::protocol::{
    self, ClientEvent, ClientRequest, Hello, Version, ViewEvent as Wire, ViewRequest, json,
};
use ko_server::ws::{Parsed, parse_record};
use ko_sys::event::{Events, Interest, Mode, Poll, Ready, Timer, Token};
use tungstenite::Bytes;

use super::view::{Feed, Slice, View};
use super::{Code, Command, Posted, Shared, ViewEvent, layout_of, locked, post, string};
use crate::launch::{self, BACKOFF_FIRST, backoff_after};
use crate::model::{Applied, JoinError, Model, Rejoin};
use crate::wire::{Connecting, Link, Next, READ_TIMEOUT, UpgradeStep, buffered, silent, text};

const WATCH: Duration = Duration::from_secs(2);

struct Session {
    link: Link,
    token: Token,
    client: ClientId,
    limits: Limits,
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
    backoff: Duration,
    reported: Option<Code>,
    session: Option<Session>,
    views: Vec<Open>,
    webview: Vec<webview::Open>,
}

type Failed = (Code, String);

pub(super) fn failure(error: &io::Error) -> Failed {
    let code = if launch::absent(error) {
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
    let (retry, watch) = (poll.timer(), poll.timer());
    let mut engine = Engine {
        shared,
        poll,
        events: Events::default(),
        wake,
        retry,
        watch,
        backoff: BACKOFF_FIRST,
        reported: None,
        session: None,
        views: Vec::new(),
        webview: Vec::new(),
    };
    engine.serve();
    shared.up.store(false, Ordering::SeqCst);
    engine.webview_shutdown();
}

impl Engine<'_> {
    fn serve(&mut self) {
        self.connect();
        while !self.shared.cancel.is_set() {
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
                if due.timer == self.retry {
                    self.connect();
                } else if due.timer == self.watch {
                    self.watchdog();
                } else if self.views.iter().any(|open| open.deadline == due.timer) {
                    self.lose(Code::Io, "the pane view upgrade timed out");
                }
            }
        }
    }

    fn connect(&mut self) {
        let Err((code, message)) = self.join() else {
            return;
        };
        if self.shared.cancel.is_set() {
            return;
        }
        if code == Code::Refused {
            if let Some(mut session) = self.session.take() {
                session.link.unwatch(&mut self.poll);
            }
            self.shared.up.store(false, Ordering::SeqCst);
            self.poll.stop(self.watch);
            self.poll.stop(self.retry);
            for open in std::mem::take(&mut self.views) {
                self.close_view(open, code, &message);
            }
            post(self.shared, Posted::Failed(code, string(&message)));
        } else if code != Code::NoServer
            && let Some((code, server)) = self.mismatch()
        {
            self.shared.up.store(false, Ordering::SeqCst);
            post(self.shared, Posted::Mismatch(code, server));
        } else {
            self.lose(code, &message);
        }
    }

    fn mismatch(&self) -> Option<(Code, Version)> {
        let shared = self.shared;
        let (mismatch, server) =
            crate::api::version(shared.socket.as_path(), READ_TIMEOUT, Some(&shared.cancel))
                .ok()?;
        mismatch.map(|kind| (Code::of(&kind), server))
    }

    fn join(&mut self) -> Result<(), Failed> {
        let shared = self.shared;
        let socket = shared.socket.as_path();
        let mut link = Link::connect_within(
            socket,
            None,
            &Route::Client {},
            Some(Arc::clone(&shared.cancel)),
            READ_TIMEOUT,
        )
        .map_err(|error| {
            let (code, message) = failure(&error);
            (
                if code == Code::Closed {
                    Code::NoServer
                } else {
                    code
                },
                message,
            )
        })?;
        let hello = {
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
        };
        let joined = Model::join(&mut link, hello).map_err(|error| match error {
            JoinError::Refused(message) => (Code::Refused, message),
            JoinError::Protocol(message) => protocol_error(message),
        })?;
        let rejoin = match locked(&shared.model).as_mut() {
            Some(earlier) => earlier.gate(joined),
            None => Rejoin::Fresh(joined),
        };
        let (model, fresh) = match rejoin {
            Rejoin::Resume(model) => (model, false),
            Rejoin::Fresh(model) => (model, true),
        };
        let token = link
            .watch(&mut self.poll)
            .map_err(|error| failure(&error))?;
        let session = Session {
            link,
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
        self.session = Some(session);
        shared.up.store(true, Ordering::SeqCst);
        post(shared, welcome);
        post(shared, layout);
        self.backoff = BACKOFF_FIRST;
        self.reported = None;
        let watch = WATCH.min(shared.watchdog);
        let _ = self.poll.start(self.watch, watch, Some(watch));
        if fresh {
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
                if present {
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
        if self.reported.is_none()
            || (code == Code::NoServer && self.reported != Some(Code::NoServer))
        {
            self.reported = Some(code);
            post(self.shared, Posted::Failed(code, string(message)));
        }
        if let Some(mut session) = self.session.take() {
            session.link.unwatch(&mut self.poll);
        }
        self.shared.up.store(false, Ordering::SeqCst);
        locked(&self.shared.commands).retain(|command| !matches!(command, Command::Size(_)));
        self.poll.stop(self.watch);
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
        let mut at = 0;
        while at < self.webview.len() {
            if self.webview[at].expired(now) {
                self.end_webview(at, Code::Io, "webview request timed out");
            } else {
                at += 1;
            }
        }
        let silent_client = self
            .session
            .as_ref()
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
        if !(ready.read || ready.write) {
            return;
        }
        if ready.token == self.wake {
            self.shared.wake.drain();
            self.commands();
            self.resume();
        } else if self
            .session
            .as_ref()
            .is_some_and(|session| session.token == ready.token)
        {
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
        let Some(session) = self.session.as_mut() else {
            return Ok(());
        };
        if ready.write {
            session
                .link
                .settle(&mut self.poll)
                .map_err(|error| failure(&error))?;
        }
        if !ready.read {
            return Ok(());
        }
        session.link.begin_turn();
        let now = Instant::now();
        loop {
            let Some(session) = self.session.as_mut() else {
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
                    if self.session.is_some() {
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
        let Some(session) = self.session.as_mut() else {
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
            Ok(()) if *paused => self.poll.interest(conn.token, Interest::Idle),
            Ok(()) => {}
        }
    }

    fn open_link(&mut self, id: u64) {
        let Some(session) = self.session.as_ref() else {
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
        let linked = Connecting::start(
            shared.socket.as_path(),
            client,
            &route,
            Some(Arc::clone(&shared.cancel)),
        );
        match linked {
            Ok(link) => {
                let token = link.watch(&mut self.poll);
                let _ = self.poll.start(open.deadline, READ_TIMEOUT, None);
                open.conn = Some(Conn {
                    token,
                    state: ViewLink::Connecting { link },
                });
            }
            Err(error) => {
                let (code, message) = failure(&error);
                self.lose(code, &message);
            }
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
            .session
            .as_ref()
            .map_or(0, |session| session.limits.continuation_max_bytes);
        let Some(open) = self.views.get_mut(at) else {
            return;
        };
        let id = open.view.id;
        let Some(conn) = open.conn.take() else {
            return;
        };
        match conn.state {
            ViewLink::Connecting { link } => match link.advance(&mut self.poll, ready) {
                Ok(UpgradeStep::Pending(link)) => {
                    open.conn = Some(Conn {
                        token: conn.token,
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
                    let (code, message) = failure(&ko_server::ws::refused(&response));
                    self.lose(code, &message);
                    return;
                }
                Err(error) => {
                    self.poll.stop(open.deadline);
                    self.poll.unwatch(conn.token);
                    let (code, message) = failure(&error);
                    self.lose(code, &message);
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
        if ready.write {
            outcome = link
                .settle(&mut self.poll)
                .map_err(|error| End::Outage(failure(&error)));
        }
        if outcome.is_ok() && ready.read {
            link.begin_turn();
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
            Err(End::Outage((code, message))) => self.reopen_view(id, code, &message),
            Ok(()) if pause.load(Ordering::SeqCst) => {
                *paused = true;
                self.poll.interest(conn.token, Interest::Idle);
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
