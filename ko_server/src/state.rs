use std::collections::BTreeMap;
use std::time::{Duration, Instant};

use ko_pane_wire::frame::{Dead, History, Req, ScreenFormat, ScreenRows};
use ko_pane_wire::ring::Invalid;
use ko_sys::event::{Events, Mode, Poll, Reads, Ready, Timer, Token};

use crate::client::{self, Change, Client};
use crate::config::Config;
use crate::conn::{Conn, Phase};
use crate::delivery::{Delivery, Handle};
use crate::http::lossy;
use crate::ids::{ClientId, Instance, PaneId};
use crate::link::{Role, Wire};
use crate::pane::Pane;
use crate::pane_proc::{self, Event, Io, Refusal, discard};
use crate::panes::{AddError, Panes};
use crate::protocol::{
    self, ClientEvent, ClientRequest, CreatePane, Input, Limits, PaneDead, PasteResult, Pwd, Row,
    Title, ViewEvent, ViewRequest, Welcome,
};
use crate::router;
use crate::server::Verified;
use crate::view::View;
use crate::ws::{Next, Ping};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Owner {
    Screen { conn: Token, started: bool },
    HttpPaste(Token, Option<u64>),
    ViewPaste(Token, Option<u64>),
    Snapshot(Token),
}

#[derive(Debug)]
pub(crate) struct State {
    pub(crate) config: Config,
    instance: Instance,
    pub(crate) panes: Panes,
    pub(crate) conns: Vec<Conn>,
    owners: BTreeMap<(PaneId, Req), Owner>,
    next_client: u64,
    ticker: Timer,
    tick: Duration,
    spare: Vec<Vec<Event>>,
    ticked: Vec<(PaneId, Event)>,
}

#[derive(Debug, Clone, Copy)]
pub(crate) enum Wake {
    Ready(Ready),
    Due(Timer),
}

fn client_of(conn: &Conn) -> Option<&Client> {
    match conn.role()? {
        Role::Client(client) => Some(client),
        Role::View(_) => None,
    }
}

fn view_of(conn: &Conn) -> Option<&View> {
    match conn.role()? {
        Role::View(view) => Some(view),
        Role::Client(_) => None,
    }
}

fn find(conns: &mut [Conn], token: Token) -> Option<&mut Conn> {
    conns.iter_mut().find(|conn| conn.token == token)
}

fn deliver(
    conns: &mut [Conn],
    owners: &BTreeMap<(PaneId, Req), Owner>,
    pane: PaneId,
    handle: Handle<'_>,
) {
    if let Some(Owner::Snapshot(token)) = owners.get(&(pane, handle.req()))
        && let Some((Role::View(view), mut wire)) = find(conns, *token).and_then(Conn::role_mut)
        && view.on_slice(wire.out, handle).is_err()
    {
        view.reject(&mut wire);
    }
}

impl State {
    pub(crate) fn new(
        config: Config,
        instance: Instance,
        poll: &mut Poll,
        tick: Duration,
    ) -> State {
        State {
            config,
            instance,
            panes: Panes::default(),
            conns: Vec::new(),
            owners: BTreeMap::new(),
            next_client: 1,
            ticker: poll.timer(),
            tick,
            spare: Vec::new(),
            ticked: Vec::new(),
        }
    }

    fn index(&self, token: Token) -> Option<usize> {
        self.conns.iter().position(|conn| conn.token == token)
    }

    pub(crate) fn token(&self, index: usize) -> Option<Token> {
        self.conns.get(index).map(|conn| conn.token)
    }

    pub(crate) fn call<R>(
        &mut self,
        poll: &mut Poll,
        id: PaneId,
        f: impl FnOnce(&mut Pane, &mut Io<'_>) -> R,
    ) -> Option<(R, Vec<Event>)> {
        let State {
            panes,
            conns,
            owners,
            spare,
            ..
        } = self;
        let mut events = spare.pop().unwrap_or_default();
        let Some(pane) = panes.find_mut(id) else {
            spare.push(events);
            return None;
        };
        let mut sink = |handle: Handle<'_>| deliver(conns, owners, id, handle);
        let result = f(
            pane,
            &mut Io {
                poll,
                events: &mut events,
                sink: &mut sink,
            },
        );
        Some((result, events))
    }

    fn run<R>(
        &mut self,
        poll: &mut Poll,
        id: PaneId,
        f: impl FnOnce(&mut Pane, &mut Io<'_>) -> R,
    ) -> Option<R> {
        let (result, events) = self.call(poll, id, f)?;
        self.dispatch(poll, id, events);
        Some(result)
    }

    pub(crate) fn dispatch(&mut self, poll: &mut Poll, id: PaneId, mut events: Vec<Event>) {
        for event in events.drain(..) {
            self.event(poll, id, event);
        }
        self.spare.push(events);
    }

    pub(crate) fn add_pane(
        &mut self,
        poll: &mut Poll,
        request: &CreatePane,
    ) -> Result<PaneId, AddError> {
        let mut events = self.spare.pop().unwrap_or_default();
        let added = self.panes.add(
            &self.config,
            request,
            &mut Io {
                poll,
                events: &mut events,
                sink: &mut discard,
            },
        );
        match added {
            Ok(id) => self.dispatch(poll, id, events),
            Err(_) => self.spare.push(events),
        }
        added
    }

    pub(crate) fn remove_pane(&mut self, poll: &mut Poll, id: PaneId) {
        let mut events = self.spare.pop().unwrap_or_default();
        self.panes.remove(
            id,
            &mut Io {
                poll,
                events: &mut events,
                sink: &mut discard,
            },
        );
        self.dispatch(poll, id, events);
    }

    pub(crate) fn reap(&mut self, poll: &mut Poll) -> std::io::Result<()> {
        for index in 0..self.panes.len() {
            let Some(id) = self.panes.iter().nth(index).map(Pane::id) else {
                break;
            };
            self.run(poll, id, |pane, io| pane.proc_mut().reap(io))
                .transpose()?;
        }
        self.panes.reap(&mut Io {
            poll,
            events: &mut Vec::new(),
            sink: &mut discard,
        })
    }

    pub(crate) fn shutdown(&mut self, poll: &mut Poll) {
        for conn in &mut self.conns {
            conn.out.close();
        }
        self.panes.shutdown(&mut Io {
            poll,
            events: &mut Vec::new(),
            sink: &mut discard,
        });
        poll.stop(self.ticker);
    }

    fn event(&mut self, poll: &mut Poll, id: PaneId, event: Event) {
        match event {
            Event::Title if self.watched() => {
                if let Some(pane) = self.panes.find(id) {
                    let title = lossy(pane.proc().title());
                    self.broadcast(&ClientEvent::Title(Title { pane: id, title }));
                }
            }
            Event::Pwd if self.watched() => {
                if let Some(pane) = self.panes.find(id) {
                    let pwd = lossy(pane.proc().cwd());
                    self.broadcast(&ClientEvent::Pwd(Pwd { pane: id, pwd }));
                }
            }
            Event::Title | Event::Pwd => {}
            Event::Dead(death) => {
                self.broadcast(&ClientEvent::Dead(PaneDead {
                    pane: id,
                    dead: (&death).into(),
                }));
                if let pane_proc::Cause::Failed(_) = death.cause {
                    self.close_views(id);
                }
            }
            Event::Output => {
                let leading = !poll.is_active(self.ticker);
                if leading {
                    let _ = poll.start(self.ticker, self.tick, Some(self.tick));
                }
                let busy = self.panes.find(id).is_some_and(|pane| pane.proc().busy());
                if leading || !busy {
                    self.run(poll, id, |pane, io| pane.proc_mut().scan(io));
                    self.pump_views(poll, id);
                }
            }
            Event::Snapshot(done) => {
                if let Some(Owner::Snapshot(token)) = self.owners.remove(&(id, done.req()))
                    && let Some(index) = self.index(token)
                {
                    let dead = self
                        .panes
                        .find(id)
                        .and_then(|pane| match pane.proc().dead() {
                            Some(pane_proc::Death {
                                at,
                                cause: pane_proc::Cause::Exit(exit),
                            }) => Some(Dead {
                                at: *at,
                                exit: *exit,
                            }),
                            _ => None,
                        });
                    if let Some((Role::View(view), mut wire)) = self.conns[index].role_mut() {
                        view.on_done(&mut wire, &done, dead);
                    }
                    self.pump_view(poll, index);
                }
            }
            Event::Screen { req, chunk, last } => {
                let key = (id, req);
                let Some(Owner::Screen { conn, started }) = self.owners.get(&key).copied() else {
                    return;
                };
                if last {
                    self.owners.remove(&key);
                } else {
                    self.owners.insert(
                        key,
                        Owner::Screen {
                            conn,
                            started: true,
                        },
                    );
                }
                router::screen(self, poll, conn, started, &chunk, last);
            }
            Event::Pasted {
                req,
                pasted,
                unsafe_paste,
            } => {
                let result = |id| PasteResult {
                    id,
                    pasted,
                    unsafe_paste,
                };
                match self.owners.remove(&(id, req)) {
                    Some(Owner::HttpPaste(conn, paste)) => {
                        router::pasted(self, poll, conn, &result(paste));
                    }
                    Some(Owner::ViewPaste(conn, paste)) => {
                        if let Some((Role::View(_), wire)) =
                            find(&mut self.conns, conn).and_then(Conn::role_mut)
                        {
                            let event = ViewEvent::Pasted(result(paste));
                            wire.ws.send(wire.out, protocol::json(&event));
                        }
                    }
                    Some(Owner::Screen { .. } | Owner::Snapshot(_)) | None => {}
                }
            }
            Event::Failed { req, message } => match self.owners.remove(&(id, req)) {
                Some(Owner::Screen { conn, started }) => {
                    router::failed(self, poll, conn, started, &message);
                }
                Some(Owner::HttpPaste(conn, _)) => {
                    router::failed(self, poll, conn, false, &message)
                }
                Some(Owner::ViewPaste(conn, _)) => {
                    if let Some((Role::View(view), mut wire)) =
                        find(&mut self.conns, conn).and_then(Conn::role_mut)
                    {
                        view.reject(&mut wire);
                    }
                }
                Some(Owner::Snapshot(_)) | None => {}
            },
        }
    }

    pub(crate) fn rows(&self) -> Vec<Row> {
        self.panes
            .iter()
            .map(|pane| {
                let proc = pane.proc();
                Row {
                    id: pane.id(),
                    pid: proc.child_pid().map_or(0, |pid| pid.get()),
                    command: pane.command().iter().map(|arg| lossy(arg)).collect(),
                    cwd: lossy(proc.cwd()),
                    title: lossy(proc.title()),
                    dead: proc.dead().map(Into::into),
                }
            })
            .collect()
    }

    fn watched(&self) -> bool {
        self.conns
            .iter()
            .any(|conn| client_of(conn).is_some_and(|client| client.active.is_some()))
    }

    fn broadcast(&mut self, event: &ClientEvent) {
        if !self.watched() {
            return;
        }
        let text = protocol::json(event);
        for conn in &mut self.conns {
            if let Some((Role::Client(client), wire)) = conn.role_mut()
                && client.active.is_some()
            {
                wire.ws.send(wire.out, text.clone());
            }
        }
    }

    pub(crate) fn topology(&mut self) {
        let rows = self.rows();
        self.broadcast(&ClientEvent::Topology { panes: rows });
    }

    pub(crate) fn registered(&self, id: ClientId) -> bool {
        self.conns
            .iter()
            .filter_map(client_of)
            .any(|client| client.id == id && client.active.is_some())
    }

    pub(crate) fn client_id(&mut self) -> ClientId {
        let id = ClientId::new(self.next_client);
        self.next_client = self.next_client.saturating_add(1);
        id
    }

    pub(crate) fn close_views(&mut self, pane: PaneId) {
        for conn in &mut self.conns {
            if let Some((Role::View(view), wire)) = conn.role_mut()
                && view.pane == pane
            {
                view.close(wire.out);
            }
        }
    }

    fn pump_views(&mut self, poll: &mut Poll, pane: PaneId) {
        for index in 0..self.conns.len() {
            if self
                .conns
                .get(index)
                .and_then(view_of)
                .is_some_and(|view| view.pane == pane)
            {
                self.pump_view(poll, index);
            }
        }
    }

    fn drive(
        &mut self,
        poll: &mut Poll,
        index: usize,
        step: impl FnOnce(&mut View, &mut Wire<'_>, &mut Delivery) -> Result<Option<History>, Invalid>,
    ) {
        let State { panes, conns, .. } = self;
        let Some((Role::View(view), mut wire)) = conns.get_mut(index).and_then(Conn::role_mut)
        else {
            return;
        };
        let Some(delivery) = panes
            .find_mut(view.pane)
            .and_then(|pane| pane.proc_mut().delivery_mut())
        else {
            return view.reject(&mut wire);
        };
        match step(view, &mut wire, delivery) {
            Ok(None) => {}
            Ok(Some(history)) => self.snapshot(poll, index, history),
            Err(_) => view.reject(&mut wire),
        }
    }

    fn pump_view(&mut self, poll: &mut Poll, index: usize) {
        self.drive(poll, index, |view, wire, delivery| {
            view.pump(wire, delivery)
        });
    }

    pub(crate) fn open_view(&mut self, poll: &mut Poll, index: usize, offset: Option<u64>) {
        self.drive(poll, index, |view, wire, delivery| {
            view.open(wire, delivery, offset)
        });
    }

    fn snapshot(&mut self, poll: &mut Poll, index: usize, history: History) {
        let Some(conn) = self.conns.get(index) else {
            return;
        };
        let token = conn.token;
        let Some(pane) = view_of(conn).map(|view| view.pane) else {
            return;
        };
        let requested = self.call(poll, pane, |pane, io| pane.proc_mut().snapshot(history, io));
        let (ticket, events) = requested.unwrap_or((None, Vec::new()));
        if let Some((_, req)) = ticket {
            self.owners.insert((pane, req), Owner::Snapshot(token));
        }
        if let Some((Role::View(view), mut wire)) = self.conns[index].role_mut() {
            match ticket {
                Some((serial, _)) => view.started(serial, history),
                None => view.reject(&mut wire),
            }
        }
        self.dispatch(poll, pane, events);
    }

    pub(crate) fn input(
        &mut self,
        poll: &mut Poll,
        pane: PaneId,
        input: &Input,
        owner: impl FnOnce(Option<u64>) -> Owner,
    ) -> (Result<Option<Req>, Refusal>, Vec<Event>) {
        let paste = match input {
            Input::Paste(paste) => paste.id,
            _ => None,
        };
        let sent = self.call(poll, pane, |pane, io| {
            pane.proc_mut().input(input.into(), io)
        });
        let (sent, events) = sent.unwrap_or((Err(Refusal::Ended), Vec::new()));
        if let Ok(Some(req)) = sent {
            self.owners.insert((pane, req), owner(paste));
        }
        (sent, events)
    }

    pub(crate) fn screen(
        &mut self,
        poll: &mut Poll,
        index: usize,
        pane: PaneId,
        format: ScreenFormat,
        rows: ScreenRows,
    ) {
        let Some(conn) = self.token(index) else {
            return;
        };
        let Some((req, events)) = self.call(poll, pane, |pane, io| {
            pane.proc_mut().screen(format, rows, io)
        }) else {
            return;
        };
        self.conns[index].phase = Phase::Handling;
        match req {
            Some(req) => {
                self.owners.insert(
                    (pane, req),
                    Owner::Screen {
                        conn,
                        started: false,
                    },
                );
            }
            None => router::failed(self, poll, conn, false, &Refusal::Ended.to_string()),
        }
        self.dispatch(poll, pane, events);
    }

    pub(crate) fn accept(&mut self, poll: &mut Poll, stream: Verified) {
        self.conns.push(Conn::new(stream, poll));
    }

    pub(crate) fn turn(
        &mut self,
        poll: &mut Poll,
        mode: Mode,
        events: &mut Events,
        mut own: impl FnMut(&mut State, &mut Poll, Wake) -> std::io::Result<bool>,
    ) -> std::io::Result<()> {
        let turned = poll.turn(mode, events).and_then(|()| {
            for &ready in events.ready() {
                if !own(self, poll, Wake::Ready(ready))? && !self.pane_ready(poll, ready) {
                    self.conn_ready(poll, ready);
                }
            }
            for &due in events.due() {
                if !poll.current(due) || own(self, poll, Wake::Due(due.timer))? {
                } else if due.timer == self.ticker {
                    self.tick(poll);
                } else {
                    self.ping(poll, due.timer);
                }
            }
            Ok(())
        });
        self.settle(poll);
        turned
    }

    fn pane_ready(&mut self, poll: &mut Poll, ready: Ready) -> bool {
        let Some(id) = self.panes.by_token(ready.token).map(|pane| pane.id()) else {
            return false;
        };
        self.run(poll, id, |pane, io| pane.proc_mut().ready(ready, io));
        true
    }

    fn conn_ready(&mut self, poll: &mut Poll, ready: Ready) {
        let Some(index) = self.index(ready.token) else {
            return;
        };
        let ready = poll.wants(ready);
        if ready.write {
            let conn = &mut self.conns[index];
            conn.out.writable();
            if !conn.out.waiting() {
                self.pump_view(poll, index);
            }
        }
        if ready.read {
            match self.conns[index].phase {
                Phase::Ws(_) => self.read_ws(poll, index),
                _ => self.read_http(poll, index),
            }
        }
    }

    fn read_http(&mut self, poll: &mut Poll, index: usize) {
        let mut reads = Reads::new();
        while let Some(conn) = self.conns.get_mut(index) {
            if !conn.reading_http() || !conn.read(poll, &mut reads) {
                break;
            }
            self.serve(poll, index);
        }
    }

    pub(crate) fn serve(&mut self, poll: &mut Poll, index: usize) {
        while let Some(request) = self.conns.get_mut(index).and_then(Conn::next_request) {
            router::handle(self, poll, index, request);
        }
    }

    pub(crate) fn read_ws(&mut self, poll: &mut Poll, index: usize) {
        let mut reads = Reads::new();
        loop {
            let Some(conn) = self.conns.get_mut(index) else {
                return;
            };
            let token = conn.token;
            let Conn {
                out,
                phase: Phase::Ws(link),
                ..
            } = conn
            else {
                return;
            };
            let client = matches!(link.role, Role::Client(_));
            let text = match link.ws.next(out, poll, token, &mut reads) {
                Next::Text(text) => text,
                Next::Wait | Next::Close => return,
            };
            if client {
                self.client_text(poll, index, text.as_bytes());
            } else {
                self.view_text(poll, index, text.as_bytes());
            }
        }
    }

    fn client_text(&mut self, poll: &mut Poll, index: usize, text: &[u8]) {
        let request = protocol::decode::<ClientRequest>(text);
        let State { panes, conns, .. } = self;
        let Some((Role::Client(client), wire)) = conns.get_mut(index).and_then(Conn::role_mut)
        else {
            return;
        };
        let id = client.id;
        let change = request
            .map_err(|_| "invalid message")
            .and_then(|request| client.receive(request, |pane| panes.find(pane).is_some()));
        match change {
            Err(_) => wire.ws.reject(wire.out, "invalid"),
            Ok(Change::Hello) => {
                self.claim(poll, index);
                let welcome = ClientEvent::Welcome(Welcome {
                    client: id,
                    limits: Limits::of(self.config.limits, &self.config.media),
                    instance: self.instance.clone(),
                });
                let topology = ClientEvent::Topology { panes: self.rows() };
                if let Some((_, wire)) = self.conns.get_mut(index).and_then(Conn::role_mut) {
                    wire.ws.send(wire.out, protocol::json(&welcome));
                    wire.ws.send(wire.out, protocol::json(&topology));
                }
            }
            Ok(Change::Claim) => self.claim(poll, index),
            Ok(Change::Resize) => {
                let Some(active) = self
                    .conns
                    .get(index)
                    .and_then(client_of)
                    .and_then(|client| client.active)
                else {
                    return;
                };
                if let Some(pane) = active.pane {
                    self.run(poll, pane, |pane, io| {
                        if pane.sizer() == Some(id) {
                            pane.resize(active.size, io);
                        }
                    });
                }
            }
            Ok(Change::Nothing) => {}
        }
    }

    fn claim(&mut self, poll: &mut Poll, index: usize) {
        let Some(client) = self.conns.get(index).and_then(client_of) else {
            return;
        };
        let id = client.id;
        let Some(active) = client.active else {
            return;
        };
        let others = self
            .conns
            .iter()
            .filter_map(client_of)
            .filter_map(|client| client.active.as_ref().map(|peer| (client.id, peer)));
        if client::claims(id, &active, others)
            && let Some(pane) = active.pane
        {
            self.run(poll, pane, |pane, io| pane.claim(id, active.size, io));
        }
    }

    fn view_text(&mut self, poll: &mut Poll, index: usize, text: &[u8]) {
        let request = protocol::decode::<ViewRequest>(text);
        let Some(token) = self.token(index) else {
            return;
        };
        let Some((Role::View(view), wire)) = self.conns[index].role_mut() else {
            return;
        };
        let pane = view.pane;
        match request {
            Err(_) => {
                wire.ws.reject(wire.out, "invalid");
                view.close(wire.out);
            }
            Ok(ViewRequest::Resync(options)) => {
                if let Some(history) = view.request(wire.out, options.history) {
                    self.snapshot(poll, index, history);
                }
            }
            Ok(ViewRequest::Input { input }) => {
                let (sent, events) =
                    self.input(poll, pane, &input, |paste| Owner::ViewPaste(token, paste));
                if let Some((Role::View(view), mut wire)) = self.conns[index].role_mut() {
                    match sent {
                        Ok(_) => {}
                        Err(Refusal::Ended) => view.reject(&mut wire),
                        Err(Refusal::TooLarge(_)) => {
                            wire.ws.reject(wire.out, "invalid");
                            view.close(wire.out);
                        }
                    }
                }
                self.dispatch(poll, pane, events);
            }
        }
    }

    fn tick(&mut self, poll: &mut Poll) {
        let mut produced = false;
        let mut ticked = std::mem::take(&mut self.ticked);
        {
            let State {
                panes,
                conns,
                owners,
                spare,
                ..
            } = self;
            let mut events = spare.pop().unwrap_or_default();
            for pane in panes.iter_mut() {
                let id = pane.id();
                let mut sink = |handle: Handle<'_>| deliver(conns, owners, id, handle);
                produced |= pane.proc_mut().scan(&mut Io {
                    poll,
                    events: &mut events,
                    sink: &mut sink,
                });
                ticked.extend(events.drain(..).map(|event| (id, event)));
            }
            spare.push(events);
        }
        for (id, event) in ticked.drain(..) {
            self.event(poll, id, event);
        }
        self.ticked = ticked;
        for index in 0..self.conns.len() {
            self.pump_view(poll, index);
        }
        let waiting = self
            .conns
            .iter()
            .any(|conn| view_of(conn).is_some_and(|view| view.waiting(&conn.out)));
        if !produced && !waiting {
            poll.stop(self.ticker);
        }
    }

    fn ping(&mut self, poll: &mut Poll, timer: Timer) {
        if let Some(Conn {
            out,
            phase: Phase::Ws(link),
            ..
        }) = self.conns.iter_mut().find(|conn| conn.timer == timer)
            && let Ping::After(left) = link.ws.ping(out, Instant::now())
        {
            let _ = poll.start(timer, left, None);
        }
    }

    fn settle(&mut self, poll: &mut Poll) {
        loop {
            for conn in &mut self.conns {
                conn.settle();
            }
            let Some(index) = self.conns.iter().position(|conn| !conn.out.is_open()) else {
                break;
            };
            let conn = self.conns.remove(index);
            poll.unwatch(conn.token);
            poll.free(conn.timer);
            if let Phase::Ws(link) = conn.phase
                && let Role::Client(client) = link.role
            {
                for conn in &mut self.conns {
                    if let Some((Role::View(view), wire)) = conn.role_mut()
                        && view.client == Some(client.id)
                    {
                        view.close(wire.out);
                    }
                }
            }
        }
        for conn in &self.conns {
            poll.interest(conn.token, conn.interest());
        }
    }
}
