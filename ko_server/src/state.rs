use std::collections::{BTreeMap, BTreeSet};
use std::time::{Duration, Instant};

use ko_pane_wire::frame::{Dead, History, Req, ScreenFormat, ScreenRows, Size};
use ko_pane_wire::ring::Invalid;
use ko_sys::event::{Events, Mode, Poll, Reads, Ready, Timer, Token};

use crate::client::{self, Change, Client, Current};
use crate::config::Config;
use crate::conn::{Conn, Phase};
use crate::delivery::{Delivery, Handle};
use crate::http::lossy;
use crate::ids::{ClientId, Instance, Name, PaneId, SessionId, VarName, WindowId};
use crate::layout::{Document, PutError, Removal, Resized};
use crate::link::{Role, Wire};
use crate::model::{self, Model};
use crate::pane::Pane;
use crate::pane_kind::{PI_SESSION, RUN};
use crate::pane_proc::{self, Event, Io, Refusal, discard};
use crate::panes::{AddError, Panes};
use crate::protocol::{
    self, CellPixels, ClientEvent, ClientKind, ClientRequest, CreatePane, DeleteVars, Input,
    Layout, Limits, Listing, PaneDead, PasteResult, PutLayout, Pwd, Row, Selection, Snapshot,
    StatusChange, Title, VarCondition, ViewEvent, ViewRequest, Welcome,
};
use crate::router;
use crate::server::Verified;
use crate::vars::{Refusal as VarRefusal, Vars};
use crate::view::View;
use crate::ws::{Next, Ping};

mod prompt;
mod run_ops;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Owner {
    Screen { conn: Token, started: bool },
    HttpPaste(Token, Option<u64>),
    ViewPaste(Token, Option<u64>),
    Snapshot(Token),
    Capture,
    Prompt(Token),
}

#[derive(Debug)]
pub(crate) enum PutFailure {
    Stale(Snapshot),
    Invalid(String),
    Io(String),
}

impl From<PutFailure> for protocol::Error {
    fn from(failure: PutFailure) -> protocol::Error {
        let (kind, message) = match failure {
            PutFailure::Invalid(message) => (protocol::ErrorKind::Invalid, message),
            PutFailure::Io(message) => (protocol::ErrorKind::Io, message),
            PutFailure::Stale(_) => (protocol::ErrorKind::Io, "layout changed".to_owned()),
        };
        protocol::Error::new(kind, message)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SelectFailure {
    NoClient,
    NoTarget,
}

#[derive(Debug)]
pub(crate) struct State {
    pub(crate) config: Config,
    instance: Instance,
    pub(crate) panes: Panes,
    document: Document,
    sizers: BTreeMap<WindowId, ClientId>,
    pub(crate) conns: Vec<Conn>,
    owners: BTreeMap<(PaneId, Req), Owner>,
    next_client: u64,
    ticker: Timer,
    tick: Duration,
    model: Model,
    runs: run_ops::RunState,
    prompts: prompt::PromptState,
    spare: Vec<Vec<Event>>,
    ticked: Vec<(PaneId, Event)>,
}

#[derive(Debug, Clone, Copy)]
pub(crate) enum Wake {
    Ready(Ready),
    Due(Timer),
}

pub(crate) fn client_of(conn: &Conn) -> Option<&Client> {
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
        let runs = run_ops::RunState::new(&config, poll);
        let document = Document::new(&config.shell);
        State {
            config,
            instance,
            panes: Panes::default(),
            document,
            sizers: BTreeMap::new(),
            conns: Vec::new(),
            owners: BTreeMap::new(),
            next_client: 1,
            ticker: poll.timer(),
            tick,
            model: Model::new(poll),
            runs,
            prompts: prompt::PromptState::default(),
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

    fn add_pane(
        &mut self,
        poll: &mut Poll,
        id: PaneId,
        size: Size,
        request: &CreatePane,
        vars: Vars,
    ) -> Result<(), AddError> {
        let has_vars = !vars.is_empty();
        let mut events = self.spare.pop().unwrap_or_default();
        let added = self.panes.add(
            &self.config,
            id,
            size,
            request,
            vars,
            &mut Io {
                poll,
                events: &mut events,
                sink: &mut discard,
            },
        );
        match added {
            Ok(()) => {
                if has_vars && let Some(pane) = self.panes.find_mut(id) {
                    self.model.mark(poll, pane);
                }
                self.dispatch(poll, id, events);
            }
            Err(_) => self.spare.push(events),
        }
        added
    }

    pub(crate) fn snapshot_layout(&self) -> Snapshot {
        self.document.snapshot()
    }

    pub(crate) fn put_layout(
        &mut self,
        poll: &mut Poll,
        request: PutLayout,
    ) -> Result<Snapshot, PutFailure> {
        let before = self.document.clone();
        let created = self.document.put(request).map_err(|error| match error {
            PutError::Stale => PutFailure::Stale(self.document.snapshot()),
            PutError::Invalid(message) => PutFailure::Invalid(message),
        })?;
        let sizes: BTreeMap<PaneId, Size> =
            self.document.layout().pane_sizes().into_iter().collect();
        let mut started = Vec::new();
        for (id, request, vars) in created {
            let size = sizes.get(&id).copied().unwrap_or(Size::DEFAULT);
            if let Err(error) = self.add_pane(poll, id, size, &request, vars) {
                for id in started {
                    self.remove_pane(poll, id);
                }
                self.document.rollback(before);
                return Err(match error {
                    AddError::Invalid(message) => PutFailure::Invalid(message.to_owned()),
                    AddError::Io(error) => PutFailure::Io(error.to_string()),
                });
            }
            started.push(id);
        }
        if self.document.revision() != before.revision() {
            self.changed(poll, before.layout());
        }
        Ok(self.document.snapshot())
    }

    #[cfg(any(test, feature = "fuzz"))]
    pub(crate) fn new_session(
        &mut self,
        poll: &mut Poll,
        request: &CreatePane,
    ) -> Result<PaneId, PutFailure> {
        use crate::protocol::{DraftLayout, DraftSession};
        let name = Name::try_from("s".to_owned())
            .map_err(|message| PutFailure::Invalid(message.to_owned()))?;
        let mut layout = DraftLayout::from(self.document.layout());
        layout.sessions.push(DraftSession::single(name, request));
        let revision = self.document.revision();
        self.put_layout(poll, PutLayout { revision, layout })?;
        self.document
            .layout()
            .sessions
            .last()
            .and_then(|session| session.windows.first())
            .and_then(|window| window.panes().first().copied())
            .ok_or_else(|| PutFailure::Io("no pane".to_owned()))
    }

    #[cfg(test)]
    pub(crate) fn announce(&mut self, event: &ClientEvent) {
        self.broadcast(event);
    }

    pub(crate) fn delete_pane(&mut self, poll: &mut Poll, id: PaneId) {
        let removal = self.document.remove_pane(id);
        self.delete(poll, removal);
    }

    pub(crate) fn delete_window(&mut self, poll: &mut Poll, id: WindowId) -> bool {
        let removal = self.document.remove_window(id);
        self.delete(poll, removal)
    }

    pub(crate) fn delete_session(&mut self, poll: &mut Poll, id: SessionId) -> bool {
        let removal = self.document.remove_session(id);
        self.delete(poll, removal)
    }

    fn delete(&mut self, poll: &mut Poll, removal: Option<Removal>) -> bool {
        let Some(Removal { panes, before }) = removal else {
            return false;
        };
        for pane in panes {
            self.close_views(pane);
            self.stop_pane(poll, pane);
        }
        self.runs_changed(poll);
        self.changed(poll, &before);
        true
    }

    pub(crate) fn clear_history(&mut self, poll: &mut Poll, id: PaneId) {
        self.run(poll, id, |pane, io| pane.proc_mut().clear_history(io));
    }

    fn changed(&mut self, poll: &mut Poll, before: &Layout) {
        let State {
            document,
            sizers,
            conns,
            ..
        } = self;
        let layout = document.layout();
        sizers.retain(|window, _| layout.window(*window).is_some());
        let mut moved = Vec::new();
        for (index, conn) in conns.iter_mut().enumerate() {
            if let Some((Role::Client(client), _)) = conn.role_mut()
                && client.active.is_some()
            {
                let after = client.reconcile(before, layout);
                if after != client.current() {
                    client.set_current(after);
                    moved.push((index, after));
                }
            }
        }
        let revision = self.document.revision();
        for (index, _) in &moved {
            self.note_focus(*index);
            self.claim(poll, *index);
        }
        self.document.fold_into(revision);
        let sizes = self.document.layout().pane_sizes().into_iter().collect();
        self.resize_panes(poll, &sizes);
        self.broadcast(&ClientEvent::Layout(self.document.snapshot()));
        for (index, current) in moved {
            self.selected(index, current);
        }
        self.refocus(poll);
    }

    fn selected(&mut self, index: usize, current: Option<Current>) {
        if let Some((_, wire)) = self.conns.get_mut(index).and_then(Conn::role_mut) {
            let selection = current.map(Selection::from).unwrap_or_default();
            wire.ws
                .send(wire.out, protocol::json(&ClientEvent::Selected(selection)));
        }
    }

    fn each_pane(&mut self, poll: &mut Poll, mut visit: impl FnMut(&mut Pane, &mut Io<'_>)) {
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
                visit(
                    pane,
                    &mut Io {
                        poll: &mut *poll,
                        events: &mut events,
                        sink: &mut sink,
                    },
                );
                ticked.extend(events.drain(..).map(|event| (id, event)));
            }
            spare.push(events);
        }
        for (id, event) in ticked.drain(..) {
            self.event(poll, id, event);
        }
        self.ticked = ticked;
    }

    fn resize_panes(&mut self, poll: &mut Poll, sizes: &BTreeMap<PaneId, Size>) {
        self.each_pane(poll, |pane, io| {
            if let Some(size) = sizes.get(&pane.id()) {
                pane.resize(*size, io);
            }
        });
    }

    fn size_window(&mut self, poll: &mut Poll, window: WindowId, size: Size) -> bool {
        let cell_px = size.cell_px.map(CellPixels);
        let resized =
            self.document
                .resize_window(window, size.cols.into(), size.rows.into(), cell_px);
        if resized == Resized::Changed {
            let sizes: BTreeMap<PaneId, Size> = self
                .document
                .layout()
                .window(window)
                .into_iter()
                .flat_map(|(_, window)| window.pane_sizes())
                .collect();
            self.resize_panes(poll, &sizes);
        }
        resized == Resized::Changed
    }

    pub(crate) fn focused_panes(&self) -> BTreeSet<PaneId> {
        self.conns
            .iter()
            .filter_map(client_of)
            .filter_map(|client| client.active.filter(|active| active.focused))
            .filter_map(|active| active.current.map(|current| current.pane))
            .collect()
    }

    fn refocus(&mut self, poll: &mut Poll) {
        let shown = self.focused_panes();
        if self.runs.focus_changed(shown.clone()) {
            self.sweep_soon(poll);
        }
        self.each_pane(poll, |pane, io| pane.focus(shown.contains(&pane.id()), io));
    }

    fn note_focus(&mut self, index: usize) -> bool {
        let Some(active) = self
            .conns
            .get(index)
            .and_then(client_of)
            .and_then(|c| c.active)
            .filter(|active| active.focused)
        else {
            return false;
        };
        active
            .current
            .is_some_and(|current| self.document.focus(current.window, current.pane))
    }

    fn arrive(&mut self, poll: &mut Poll, index: usize) {
        let before = self.document.revision();
        self.note_focus(index);
        self.claim(poll, index);
        if self.document.revision() != before {
            self.document.fold_into(before.next());
            self.broadcast(&ClientEvent::Layout(self.document.snapshot()));
        }
    }

    pub(crate) fn select_client(
        &mut self,
        poll: &mut Poll,
        id: ClientId,
        selection: Selection,
    ) -> Result<(), SelectFailure> {
        let index = self
            .conns
            .iter()
            .position(|conn| {
                client_of(conn).is_some_and(|client| client.id == id && client.active.is_some())
            })
            .ok_or(SelectFailure::NoClient)?;
        let current = client_of(&self.conns[index])
            .and_then(|client| client.select(self.document.layout(), selection))
            .ok_or(SelectFailure::NoTarget)?;
        self.enter(poll, index, Some(current), true);
        Ok(())
    }

    fn enter(&mut self, poll: &mut Poll, index: usize, current: Option<Current>, notify: bool) {
        if let Some((Role::Client(client), _)) = self.conns.get_mut(index).and_then(Conn::role_mut)
        {
            client.set_current(current);
        }
        self.arrive(poll, index);
        if notify {
            self.selected(index, current);
        }
        self.refocus(poll);
    }

    pub(crate) fn remove_pane(&mut self, poll: &mut Poll, id: PaneId) {
        self.stop_pane(poll, id);
        self.runs_changed(poll);
    }

    fn stop_pane(&mut self, poll: &mut Poll, id: PaneId) {
        if let Some(timer) = self
            .panes
            .find_mut(id)
            .and_then(|pane| pane.model_mut().take_promotion())
        {
            poll.free(timer);
        }
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
        self.model.stop(poll);
        self.runs.stop(poll);
        self.prompts.stop(poll);
    }

    fn mark(&mut self, poll: &mut Poll, id: PaneId) {
        if let Some(pane) = self.panes.find_mut(id) {
            self.model.mark(poll, pane);
        }
    }

    fn model_tick(&mut self, poll: &mut Poll) {
        let mut changed = Vec::new();
        for pane in self.panes.iter_mut() {
            if pane.model().dirty()
                && let Some(status) = model::observe(pane, poll)
            {
                changed.push((pane.id(), status));
            }
        }
        let now = ko_sys::clock::Mono::now().nanos();
        for (pane, status) in changed {
            self.broadcast(&ClientEvent::Status(StatusChange { pane, status, now }));
        }
        if self.runs.take_due() {
            self.sweep(poll);
        }
    }

    pub(crate) fn set_var(
        &mut self,
        poll: &mut Poll,
        id: PaneId,
        name: VarName,
        value: serde_json::Value,
    ) -> Result<(), VarRefusal> {
        let watched = self.watched();
        let Some(pane) = self.panes.find_mut(id) else {
            return Ok(());
        };
        if pane.vars_mut().set(&name, value)? {
            self.model.mark(poll, pane);
            if name == RUN || name == PI_SESSION {
                self.runs.want_sweep();
            }
            let event = watched
                .then(|| pane.vars().get(&name).cloned())
                .flatten()
                .map(|value| ClientEvent::Var {
                    pane: id,
                    name,
                    value,
                });
            if let Some(event) = event {
                self.broadcast(&event);
            }
        }
        Ok(())
    }

    pub(crate) fn delete_var(&mut self, poll: &mut Poll, id: PaneId, name: VarName) {
        let Some(pane) = self.panes.find_mut(id) else {
            return;
        };
        if pane.vars_mut().remove(&name) {
            self.model.mark(poll, pane);
            if name == RUN || name == PI_SESSION {
                self.runs.want_sweep();
            }
            self.broadcast(&ClientEvent::VarDeleted { pane: id, name });
        }
    }

    pub(crate) fn delete_vars(&mut self, poll: &mut Poll, id: PaneId, request: DeleteVars) -> bool {
        let DeleteVars { names, condition } = request;
        if let Some(VarCondition { name, value }) = condition
            && self.panes.find(id).and_then(|pane| pane.vars().get(&name)) != Some(&value)
        {
            return false;
        }
        for name in names {
            self.delete_var(poll, id, name);
        }
        true
    }

    fn event(&mut self, poll: &mut Poll, id: PaneId, event: Event) {
        match event {
            Event::Title => {
                self.mark(poll, id);
                if self.watched()
                    && let Some(pane) = self.panes.find(id)
                {
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
            Event::Pwd => {}
            Event::Dead(death) => {
                if let Some(pane) = self.panes.find_mut(id) {
                    pane.telemetry_mut().records.clear();
                    self.model.mark(poll, pane);
                }
                self.broadcast(&ClientEvent::Dead(PaneDead {
                    pane: id,
                    dead: (&death).into(),
                }));
                if let pane_proc::Cause::Failed(_) = death.cause {
                    self.delete_pane(poll, id);
                }
                self.runs_changed(poll);
            }
            Event::Prompt(prompt) => {
                if let Some(pane) = self.panes.find_mut(id) {
                    pane.telemetry_mut().prompt(prompt);
                    self.model.mark(poll, pane);
                }
            }
            Event::Record(report) => {
                if let Some(pane) = self.panes.find_mut(id)
                    && pane.telemetry_mut().records.apply(report)
                {
                    self.model.mark(poll, pane);
                    self.runs.want_sweep();
                }
            }
            Event::Foreground(foreground) => {
                if let Some(pane) = self.panes.find_mut(id)
                    && pane.telemetry_mut().foreground(foreground)
                {
                    self.model.mark(poll, pane);
                }
            }
            Event::Alternate(on) => {
                if let Some(pane) = self.panes.find_mut(id)
                    && pane.telemetry_mut().set_alternate(on)
                {
                    self.model.mark(poll, pane);
                }
            }
            Event::Bell => self.broadcast(&ClientEvent::Bell { pane: id }),
            Event::Notify { title, body } => {
                self.broadcast(&ClientEvent::Notify {
                    pane: id,
                    title,
                    body,
                });
            }
            Event::Progress(progress) => {
                if let Some(pane) = self.panes.find_mut(id)
                    && pane.telemetry_mut().set_progress(progress)
                {
                    self.broadcast(&ClientEvent::Progress { pane: id, progress });
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
                if self.owners.get(&key) == Some(&Owner::Capture) {
                    if last {
                        self.owners.remove(&key);
                    }
                    return self.capture_chunk(poll, id, req, &chunk, last);
                }
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
                    Some(Owner::Prompt(conn)) => self.prompt_pasted(poll, id, conn, pasted),
                    Some(Owner::Screen { .. } | Owner::Snapshot(_) | Owner::Capture) | None => {}
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
                Some(Owner::Prompt(conn)) => router::failed(self, poll, conn, false, &message),
                Some(Owner::Capture) => self.capture_failed(poll, id, req),
                Some(Owner::Snapshot(_)) | None => {}
            },
        }
    }

    pub(crate) fn listing(&self) -> Vec<Listing> {
        self.panes
            .iter()
            .map(|pane| {
                let proc = pane.proc();
                let telemetry = pane.telemetry();
                Listing {
                    row: Row {
                        id: pane.id(),
                        pid: proc.child_pid().map_or(0, |pid| pid.get()),
                        command: pane.command().iter().map(|arg| lossy(arg)).collect(),
                        cwd: lossy(proc.cwd()),
                        title: lossy(proc.title()),
                        dead: proc.dead().map(Into::into),
                        foreground: telemetry.foreground.clone(),
                        status: pane.model().status().cloned(),
                        progress: telemetry.progress,
                    },
                    vars: pane.vars().clone(),
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
                if !own(self, poll, Wake::Ready(ready))?
                    && !self.pane_ready(poll, ready)
                    && !self.prompt_ready(poll, ready)
                {
                    self.conn_ready(poll, ready);
                }
            }
            for &due in events.due() {
                if !poll.current(due) || own(self, poll, Wake::Due(due.timer))? {
                } else if due.timer == self.ticker {
                    self.tick(poll);
                } else if self.model.is_tick(due.timer) {
                    self.model_tick(poll);
                } else if self.runs.is_sweep(due.timer) {
                    self.sweep(poll);
                } else if self.runs.is_escalation(due.timer) {
                    self.escalate(poll);
                } else if self.prompt_due(poll, due.timer) || self.wait_due(poll, due.timer) {
                } else if self.conns.iter().any(|conn| conn.timer == due.timer) {
                    self.ping(poll, due.timer);
                } else if let Some(id) = self.panes.by_promotion(due.timer) {
                    self.mark(poll, id);
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
        let State {
            document, conns, ..
        } = self;
        let Some((Role::Client(client), wire)) = conns.get_mut(index).and_then(Conn::role_mut)
        else {
            return;
        };
        let id = client.id;
        let layout = document.layout();
        let change = request
            .map_err(|_| "invalid message")
            .and_then(|request| client.receive(request));
        let Ok(change) = change else {
            return wire.ws.reject(wire.out, "invalid");
        };
        let (current, notify) = match change {
            Change::Hello(selection) => {
                let current = client.select(layout, selection).or_else(|| {
                    client.select(
                        layout,
                        Selection {
                            pane: None,
                            ..selection
                        },
                    )
                });
                let welcome = ClientEvent::Welcome(Welcome {
                    client: id,
                    limits: Limits::of(self.config.limits, &self.config.media),
                    instance: self.instance.clone(),
                    now: ko_sys::clock::Mono::now().nanos(),
                });
                wire.ws.send(wire.out, protocol::json(&welcome));
                let snapshot = ClientEvent::Layout(document.snapshot());
                wire.ws.send(wire.out, protocol::json(&snapshot));
                let notify = current.is_some_and(|current| selection.pane != Some(current.pane));
                (current, notify)
            }
            Change::Select(selection) => match client.select(layout, selection) {
                Some(current) => (Some(current), selection.pane != Some(current.pane)),
                None => return wire.ws.reject(wire.out, "invalid"),
            },
            Change::Switch(switch) => match client.switch(layout, switch) {
                Some(current) => (Some(current), true),
                None => return,
            },
            Change::Claim => {
                self.arrive(poll, index);
                return self.refocus(poll);
            }
            Change::Resize => {
                let Some(active) = client.active else {
                    return;
                };
                if let Some(current) = active.current
                    && self.sizers.get(&current.window) == Some(&id)
                    && self.sizable(active.kind, current.window)
                    && self.size_window(poll, current.window, active.size)
                {
                    self.broadcast(&ClientEvent::Layout(self.document.snapshot()));
                }
                return;
            }
            Change::Nothing => return self.refocus(poll),
        };
        self.enter(poll, index, current, notify);
    }

    fn sizable(&self, kind: ClientKind, window: WindowId) -> bool {
        match kind {
            ClientKind::App => true,
            ClientKind::Terminal => self
                .document
                .layout()
                .window(window)
                .is_some_and(|(_, window)| window.single()),
        }
    }

    fn claim(&mut self, poll: &mut Poll, index: usize) -> bool {
        let Some(client) = self.conns.get(index).and_then(client_of) else {
            return false;
        };
        let id = client.id;
        let Some(active) = client.active else {
            return false;
        };
        let Some(current) = active.current else {
            return false;
        };
        let others = self
            .conns
            .iter()
            .filter_map(client_of)
            .filter_map(|client| client.active.as_ref().map(|peer| (client.id, peer)));
        if self.sizable(active.kind, current.window) && client::claims(id, &active, others) {
            self.sizers.insert(current.window, id);
            return self.size_window(poll, current.window, active.size);
        }
        false
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
        self.each_pane(poll, |pane, io| produced |= pane.proc_mut().scan(io));
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
        let mut client_closed = false;
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
            self.runs.forget(conn.token);
            self.prompts.forget(conn.token);
            if let Phase::Ws(link) = conn.phase
                && let Role::Client(client) = link.role
            {
                client_closed = true;
                self.sizers.retain(|_, sizer| *sizer != client.id);
                for conn in &mut self.conns {
                    if let Some((Role::View(view), wire)) = conn.role_mut()
                        && view.client == Some(client.id)
                    {
                        view.close(wire.out);
                    }
                }
            }
        }
        if client_closed {
            self.refocus(poll);
        }
        for conn in &self.conns {
            poll.interest(conn.token, conn.interest());
        }
    }
}
