#![deny(unsafe_code)]

use std::io;
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use ko_pane_wire::frame::Limits;
use ko_pane_wire::ring::Slice as Header;
use ko_server::api::{Offset, Route};
use ko_server::ids::ClientId;
use ko_server::protocol::{
    self, ClientEvent, ClientRequest, Error, ErrorKind, Version, ViewEvent as Wire, ViewRequest,
    check_version, json,
};
use ko_server::ws::{Record, parse_record};
use ko_sys::event::{Events, Interest, Mode, Poll, Ready, Timer, Token};
use tungstenite::Bytes;

use super::view::{Feed, Slice, View};
use super::{Code, Command, Posted, Shared, ViewEvent, layout_of, locked, post, string};
use crate::launch::{self, BACKOFF_FIRST, backoff_after};
use crate::model::{Applied, Model, Rejoin};
use crate::wire::{self, Link, Next, WATCHDOG, buffered, request, silent, text};

const WATCH: Duration = Duration::from_secs(2);

struct Session {
    link: Link,
    token: Token,
    client: ClientId,
    limits: Limits,
    epoch: u64,
}

struct Conn {
    link: Link,
    token: Token,
    paused: bool,
}

struct Open {
    view: Arc<View>,
    conn: Option<Conn>,
}

struct Engine<'a> {
    shared: &'a Arc<Shared>,
    poll: Poll,
    events: Events,
    wake: Token,
    retry: Timer,
    watch: Timer,
    backoff: Duration,
    reported: bool,
    session: Option<Session>,
    epoch: u64,
    fetching: Option<JoinHandle<()>>,
    refetch: bool,
    views: Vec<Open>,
}

type Failed = (Code, String);

fn failure(error: &io::Error) -> Failed {
    let code = if launch::absent(error) {
        Code::NoServer
    } else if matches!(
        error.kind(),
        io::ErrorKind::BrokenPipe | io::ErrorKind::ConnectionReset | io::ErrorKind::UnexpectedEof
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
        reported: false,
        session: None,
        epoch: 0,
        fetching: None,
        refetch: false,
        views: Vec::new(),
    };
    engine.serve();
    shared.up.store(false, Ordering::SeqCst);
    if let Some(fetching) = engine.fetching.take() {
        let _ = fetching.join();
    }
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
                } else {
                    self.watchdog();
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
        if code != Code::NoServer
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
        let route = Route::Version {};
        let body = request(
            shared.socket.as_path(),
            (None, None),
            &route,
            b"",
            Some(&shared.cancel),
        )
        .ok()?;
        let server = protocol::decode::<Version>(&body).ok()?;
        match check_version(Some(&server.protocol), Some(&server.vt)) {
            Err(Error {
                kind: ErrorKind::ProtocolMismatch(_),
                ..
            }) => Some((Code::ProtocolMismatch, server)),
            Err(Error {
                kind: ErrorKind::VtMismatch(_),
                ..
            }) => Some((Code::VtMismatch, server)),
            _ => None,
        }
    }

    fn join(&mut self) -> Result<(), Failed> {
        let shared = self.shared;
        let socket = shared.socket.as_path();
        let mut link = Link::connect(
            socket,
            None,
            &Route::Client {},
            Some(Arc::clone(&shared.cancel)),
        )
        .map_err(|error| failure(&error))?;
        let hello = locked(&shared.hello).clone();
        let joined =
            Model::join(&mut link, hello, socket, Some(&shared.cancel)).map_err(protocol_error)?;
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
        self.epoch += 1;
        let session = Session {
            link,
            token,
            client: model.client,
            limits: model.limits,
            epoch: self.epoch,
        };
        *locked(&shared.client) = Some(model.client);
        post(
            shared,
            Posted::Welcome {
                client: string(&model.client.to_string()),
                instance: string(&model.instance.to_string()),
                now: model.server_now(),
                fresh,
            },
        );
        post(shared, Posted::Layout(layout_of(&model)));
        *locked(&shared.model) = Some(model);
        self.session = Some(session);
        shared.up.store(true, Ordering::SeqCst);
        self.backoff = BACKOFF_FIRST;
        self.reported = false;
        let _ = self.poll.start(self.watch, WATCH, Some(WATCH));
        if fresh {
            for open in std::mem::take(&mut self.views) {
                self.close_view(open, Code::Closed, "the server restarted");
            }
        } else {
            let ids: Vec<u64> = self.views.iter().map(|open| open.view.id).collect();
            for id in ids {
                self.open_link(id);
            }
        }
        self.client_ready(buffered(token))
    }

    fn lose(&mut self, code: Code, message: &str) {
        if !self.reported {
            self.reported = true;
            post(self.shared, Posted::Failed(code, string(message)));
        }
        if let Some(mut session) = self.session.take() {
            session.link.unwatch(&mut self.poll);
        }
        self.refetch = false;
        self.shared.up.store(false, Ordering::SeqCst);
        self.poll.stop(self.watch);
        for open in &mut self.views {
            open.drop_conn(&mut self.poll);
        }
        let _ = self.poll.start(self.retry, self.backoff, None);
        self.backoff = backoff_after(self.backoff);
    }

    fn watchdog(&mut self) {
        let now = Instant::now();
        let silent_client = self
            .session
            .as_ref()
            .is_some_and(|session| silent(session.link.received(), now, WATCHDOG));
        if silent_client {
            self.lose(Code::Closed, "the server went silent");
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
            if let Err((code, message)) = self.fetched() {
                self.lose(code, &message);
            }
        } else if self
            .session
            .as_ref()
            .is_some_and(|session| session.token == ready.token)
        {
            if let Err((code, message)) = self.client_ready(ready) {
                self.lose(code, &message);
            }
        } else if let Some(id) = self
            .views
            .iter()
            .find(|open| {
                open.conn
                    .as_ref()
                    .is_some_and(|conn| conn.token == ready.token)
            })
            .map(|open| open.view.id)
        {
            self.view_ready(id, ready);
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
                Next::Closed => return Err((Code::Closed, "server closed".to_owned())),
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
        let (applied, fetch) = match locked(&self.shared.model).as_mut() {
            Some(model) => model.apply_event(event),
            None => return,
        };
        if fetch {
            self.start_fetch();
        } else {
            self.announce(&applied);
        }
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
            Applied::Selected => match locked(&shared.model).as_ref() {
                Some(model) => Posted::Selected(model.selection),
                None => return,
            },
            Applied::Notice(notice) => Posted::Alert(notice.clone()),
        };
        post(shared, posted);
    }

    // The rows come from two requests that would stall every view on this thread.
    fn start_fetch(&mut self) {
        let Some(session) = self.session.as_ref() else {
            return;
        };
        if self.fetching.is_some() {
            self.refetch = true;
            return;
        }
        let (shared, client, epoch) = (Arc::clone(self.shared), session.client, session.epoch);
        self.fetching = Some(std::thread::spawn(move || {
            let rows = Model::fetch(
                &shared.socket,
                client,
                (Some(&shared.cancel), wire::READ_TIMEOUT),
            );
            *locked(&shared.fetched) = Some((epoch, rows));
            shared.wake.wake();
        }));
    }

    fn fetched(&mut self) -> Result<(), Failed> {
        let Some((epoch, rows)) = locked(&self.shared.fetched).take() else {
            return Ok(());
        };
        if let Some(fetching) = self.fetching.take() {
            let _ = fetching.join();
        }
        if self.session.as_ref().map(|session| session.epoch) == Some(epoch) {
            let rows = rows.map_err(protocol_error)?;
            if let Some(model) = locked(&self.shared.model).as_mut() {
                model.install(rows);
            }
            self.announce(&Applied::Layout);
        }
        if std::mem::take(&mut self.refetch) {
            self.start_fetch();
        }
        Ok(())
    }

    fn commands(&mut self) {
        let batch = std::mem::take(&mut *locked(&self.shared.commands));
        for command in batch {
            match command {
                Command::Request(request) => self.request(&request),
                Command::Open(view) => {
                    let id = view.id;
                    self.views.push(Open { view, conn: None });
                    if self.session.is_some() {
                        self.open_link(id);
                    }
                }
                Command::Close(id) => {
                    if let Some(at) = self.views.iter().position(|open| open.view.id == id) {
                        let mut open = self.views.remove(at);
                        open.drop_conn(&mut self.poll);
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
        let sent = conn
            .link
            .send(json(request))
            .and_then(|()| conn.link.settle(&mut self.poll));
        match sent {
            Err(error) => {
                let (code, message) = failure(&error);
                self.end_view(id, code, &message);
            }
            Ok(()) if conn.paused => self.poll.interest(conn.token, Interest::Idle),
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
        let options = *locked(&open.view.options);
        let route = Route::View {
            id: open.view.pane,
            history: options.history,
            images: options.images,
            offset: open.view.resume_offset().and_then(Offset::new),
        };
        let linked = Link::connect(
            shared.socket.as_path(),
            Some(client),
            &route,
            Some(Arc::clone(&shared.cancel)),
        )
        .and_then(|mut link| {
            let token = link.watch(&mut self.poll)?;
            Ok(Conn {
                link,
                token,
                paused: false,
            })
        });
        match linked {
            Ok(conn) => {
                let token = conn.token;
                open.conn = Some(conn);
                open.view.up.store(true, Ordering::SeqCst);
                self.view_ready(id, buffered(token));
            }
            Err(error) => {
                let (code, message) = failure(&error);
                self.end_view(id, code, &message);
            }
        }
    }

    fn close_view(&mut self, mut open: Open, code: Code, message: &str) {
        open.drop_conn(&mut self.poll);
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
            .filter(|open| {
                open.conn.as_ref().is_some_and(|conn| conn.paused)
                    && !open.view.pause.load(Ordering::SeqCst)
            })
            .map(|open| open.view.id)
            .collect();
        for id in ids {
            let Some(conn) = self
                .views
                .iter_mut()
                .find(|open| open.view.id == id)
                .and_then(|open| open.conn.as_mut())
            else {
                continue;
            };
            conn.paused = false;
            let token = conn.token;
            if conn.link.settle(&mut self.poll).is_ok() {
                self.view_ready(id, buffered(token));
            }
        }
    }

    fn view_ready(&mut self, id: u64, ready: Ready) {
        let continuation = self
            .session
            .as_ref()
            .map_or(0, |session| session.limits.continuation_max_bytes);
        let Some(open) = self.views.iter_mut().find(|open| open.view.id == id) else {
            return;
        };
        let Some(conn) = open.conn.as_mut() else {
            return;
        };
        let pause = &open.view.pause;
        let mut outcome = Ok(());
        if ready.write {
            outcome = conn
                .link
                .settle(&mut self.poll)
                .map_err(|error| failure(&error));
        }
        if outcome.is_ok() && ready.read {
            conn.link.begin_turn();
            let now = Instant::now();
            while !pause.load(Ordering::SeqCst) {
                match conn.link.next(&mut self.poll, now) {
                    Ok(Next::Wait) => break,
                    Ok(Next::Closed) => {
                        outcome = Err((Code::Closed, "pane view closed".to_owned()));
                        break;
                    }
                    Ok(Next::Text(event)) => feed_text(&open.view, &event),
                    Ok(Next::Binary(record)) => {
                        if let Err(message) = feed_record(&open.view, continuation, &record) {
                            outcome = Err(protocol_error(message.to_owned()));
                            break;
                        }
                    }
                    Err(error) => {
                        outcome = Err(failure(&error));
                        break;
                    }
                }
            }
        }
        match outcome {
            Err((code, message)) => self.end_view(id, code, &message),
            Ok(()) if pause.load(Ordering::SeqCst) => {
                conn.paused = true;
                self.poll.interest(conn.token, Interest::Idle);
            }
            Ok(()) => {}
        }
    }
}

impl Open {
    fn drop_conn(&mut self, poll: &mut Poll) {
        if let Some(mut conn) = self.conn.take() {
            conn.link.unwatch(poll);
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
    let (kind, offset, data) = parse_record(record).map_err(|_| "invalid record")?;
    match kind {
        Record::Output => view.feed(Feed::Bytes {
            offset,
            data: record.slice_ref(data),
        }),
        Record::Snapshot => {
            let (header, body) = Header::decode(data).ok_or("short snapshot slice")?;
            view.slice(
                &Slice {
                    first: header.first,
                    last: header.last,
                    history: !header.screen,
                    offset,
                    continuation,
                },
                record.slice_ref(body),
            )?;
        }
    }
    Ok(())
}
