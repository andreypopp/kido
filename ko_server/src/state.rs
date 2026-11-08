use std::cell::OnceCell;
use std::collections::{BTreeMap, BTreeSet};
use std::os::fd::AsFd;
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

use ko_config::runtime::Runtime;
use ko_config::values::RuntimeName;
use ko_pane_wire::frame::{History, ImageKey, Req, ScreenFormat, ScreenRows, Size};
use ko_pane_wire::ring::Invalid;
use ko_sys::event::{Events, Mode, Poll, Reads, Ready, Timer, Token};
use tungstenite::Utf8Bytes;

use crate::api::routes;
use crate::client::{self, Change, Client, Current};
use crate::clipboard;
use crate::config::{Config, Read, Settings};
use crate::conn::{Conn, Phase};
use crate::deflate::Deflate;
use crate::delivery::{Delivery, Handle};
use crate::diagnostics::{self, Cause, InputSource};
use crate::http::lossy;
use crate::ids::{ClientId, Instance, Name, PaneId, SessionId, VarName, WindowId};
use crate::layout::{self, Document, PutError, Removal, Resized};
use crate::link::{Role, Wire};
use crate::model::{self, Model};
use crate::pane::{Birth, Pane};
use crate::pane_proc::{self, Event, Io, Refusal, discard};
use crate::panes::{AddError, Panes};
use crate::protocol::{
    self, CellPixels, ClientEvent, ClientRequest, CreatePane, DeleteVars, End, Input, Layout,
    LayoutPanes, Limits, Listing, PaneDead, PasteResult, PutLayout, Pwd, Row, Selection, Snapshot,
    StatusChange, Title, VarCondition, ViewEvent, ViewRequest, Welcome,
};
use crate::router;
use crate::runtime::Registry;
use crate::runtime::leaving::Leaving;
use crate::runtime::pane::Dir;
use crate::server::{Origin, Verified};
use crate::shm::Leaks;
use crate::vars::{Refusal as VarRefusal, SERVER_MAX_TOTAL};
use crate::view::View;
use crate::ws::{Next, Ping};

mod exec_ops;
mod media;
mod messages;
mod pane_ops;
mod prompt;
mod runtime_ops;
mod sweep;
pub(crate) mod visit_ops;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Owner {
    Screen {
        conn: Token,
        started: bool,
    },
    HttpPaste(Token, Option<u64>),
    ViewPaste(Token, Option<u64>),
    Snapshot(Token),
    Prompt(Token),
    Image {
        conn: Option<Token>,
        shm: bool,
        key: ImageKey,
        minted: ko_sys::mapping::Name,
    },
    Search(Token),
}

#[derive(Debug)]
pub(crate) enum PutFailure {
    Stale(Snapshot),
    Invalid(String),
    Io(String),
    Rejected(protocol::Error),
}

impl From<PutFailure> for protocol::Error {
    fn from(failure: PutFailure) -> protocol::Error {
        let (kind, message) = match failure {
            PutFailure::Rejected(error) => return error,
            PutFailure::Invalid(message) => (protocol::ErrorKind::Invalid, message),
            PutFailure::Io(message) => (protocol::ErrorKind::Io, message),
            PutFailure::Stale(_) => (protocol::ErrorKind::Io, "layout changed".to_owned()),
        };
        protocol::Error::new(kind, message)
    }
}

#[derive(Debug)]
pub(crate) struct State {
    pub(crate) config: Config,
    pub(crate) spill_dir: Arc<Path>,
    instance: Instance,
    pub(crate) panes: Panes,
    document: Document,
    sizers: BTreeMap<WindowId, ClientId>,
    pub(crate) conns: Vec<Conn>,
    owners: BTreeMap<(PaneId, Req), Owner>,
    deflate: Deflate,
    next_client: u64,
    ticker: Timer,
    tick: Duration,
    model: Model,
    sweep: sweep::Sweep,
    runtimes: Registry,
    execs: exec_ops::Execs,
    leaving: Leaving,
    stops: pane_ops::Stops,
    messages: messages::Waits,
    leaks: Leaks,
    next_object: u32,
    clipboard: clipboard::Reads,
    spare: Vec<Vec<Event>>,
    ticked: Vec<(PaneId, Event)>,
    withheld: BTreeSet<PaneId>,
    held: Vec<(PaneId, Event)>,
    diagnostics: Vec<diagnostics::Event>,
}

#[derive(Debug, Clone, Copy)]
pub(crate) enum Wake {
    Ready(Ready),
    Due(Timer),
}

pub(crate) fn client_of(conn: &Conn) -> Option<&Client> {
    match conn.role()? {
        Role::Client(client) => Some(client),
        Role::View(_) | Role::Search(_) | Role::Messages(_) | Role::Exec(_) | Role::Visit(_) => {
            None
        }
    }
}

fn view_of(conn: &Conn) -> Option<&View> {
    match conn.role()? {
        Role::View(view) => Some(view),
        Role::Client(_) | Role::Search(_) | Role::Messages(_) | Role::Exec(_) | Role::Visit(_) => {
            None
        }
    }
}

fn pane_listing(pane: &Pane) -> Listing {
    let proc = pane.proc();
    let telemetry = pane.telemetry();
    Listing {
        row: Row {
            id: pane.id(),
            started: pane.started().nanos(),
            pid: proc.child_pid().map(|pid| pid.get()),
            command: pane.command().iter().map(|arg| lossy(arg)).collect(),
            cwd: lossy(proc.cwd()),
            title: lossy(proc.title()),
            dead: proc.dead().map(Into::into),
            foreground: telemetry.foreground.clone(),
            status: pane.model().status().cloned(),
            progress: telemetry.progress,
            parent: pane.parent(),
            close: pane.close(),
            inbox: pane.inbox().stream().is_some(),
            runtime: pane.runtime().map(|key| key.name.clone()),
        },
        vars: pane.vars().clone(),
    }
}

fn layout_panes(document: &Document, panes: &Panes, keep: impl Fn(PaneId) -> bool) -> LayoutPanes {
    LayoutPanes {
        snapshot: document.snapshot(),
        panes: panes
            .iter()
            .filter(|pane| keep(pane.id()))
            .map(pane_listing)
            .collect(),
    }
}

fn find(conns: &mut [Conn], token: Token) -> Option<&mut Conn> {
    conns.iter_mut().find(|conn| conn.token == token)
}

fn deliver(
    conns: &mut [Conn],
    owners: &BTreeMap<(PaneId, Req), Owner>,
    deflate: &mut Deflate,
    pane: PaneId,
    handle: Handle<'_>,
) {
    if let Some(Owner::Snapshot(token)) = owners.get(&(pane, handle.req()))
        && let Some((Role::View(view), mut wire)) = find(conns, *token).and_then(Conn::role_mut)
        && view.on_slice(wire.out, deflate, handle).is_err()
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
        let sweep = sweep::Sweep::new(poll);
        let runtimes = Registry::new(&config);
        let execs = exec_ops::Execs::new();
        let leaving = Leaving::new(poll);
        let stops = pane_ops::Stops::new(poll);
        let document = Document::new();
        let leaks = Leaks::new(&config.dir);
        leaks.release_all();
        State {
            spill_dir: Arc::from(config.dir.as_path()),
            config,
            instance,
            panes: Panes::default(),
            document,
            sizers: BTreeMap::new(),
            conns: Vec::new(),
            owners: BTreeMap::new(),
            deflate: Deflate::new(),
            next_client: 1,
            ticker: poll.timer(),
            tick,
            model: Model::new(poll),
            sweep,
            runtimes,
            execs,
            leaving,
            stops,
            messages: messages::Waits::default(),
            leaks,
            next_object: 0,
            clipboard: clipboard::Reads::default(),
            spare: Vec::new(),
            ticked: Vec::new(),
            withheld: BTreeSet::new(),
            held: Vec::new(),
            diagnostics: Vec::new(),
        }
    }

    pub(crate) fn take_diagnostics(&mut self) -> Vec<diagnostics::Event> {
        std::mem::take(&mut self.diagnostics)
    }

    fn record(&mut self, event: diagnostics::Event) {
        if !matches!(
            self.config.diagnostics,
            crate::config::Diagnostics::Disabled
        ) {
            self.diagnostics.push(event);
        }
    }

    pub(crate) fn record_input(&mut self, pane: PaneId, source: InputSource, input: &Input) {
        if matches!(
            self.config.diagnostics,
            crate::config::Diagnostics::EventsAndInput { .. }
        ) {
            let bytes = match pane_proc::Input::from(input) {
                pane_proc::Input::Text(bytes) => bytes.len(),
                pane_proc::Input::Paste { text, .. } => text.len(),
                pane_proc::Input::Key(key) => key.text.len(),
                pane_proc::Input::Mouse(_) | pane_proc::Input::Focus(_) => 0,
            };
            self.record(diagnostics::Event::Input {
                pane,
                source,
                bytes,
            });
        }
    }

    pub(super) fn token_of_timer(&self, timer: Timer) -> Option<Token> {
        self.conns
            .iter()
            .find(|conn| conn.timer == timer)
            .map(|conn| conn.token)
    }

    pub(super) fn hold(&mut self, poll: &mut Poll, index: usize, within: Duration) -> Token {
        let conn = &mut self.conns[index];
        conn.phase = Phase::Handling;
        let _ = poll.start(conn.timer, within, None);
        conn.token
    }

    pub(crate) fn instance(&self) -> &Instance {
        &self.instance
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
            deflate,
            spare,
            ..
        } = self;
        let mut events = spare.pop().unwrap_or_default();
        let Some(pane) = panes.find_mut(id) else {
            spare.push(events);
            return None;
        };
        let mut sink = |handle: Handle<'_>| deliver(conns, owners, deflate, id, handle);
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
        settings: &Settings,
        id: PaneId,
        size: Size,
        birth: Birth,
    ) -> Result<(), AddError> {
        let has_vars = !birth.vars.is_empty();
        let mut events = self.spare.pop().unwrap_or_default();
        let added = self.panes.add(
            &self.config,
            settings,
            id,
            size,
            birth,
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

    pub(crate) fn layout_panes(&self) -> LayoutPanes {
        layout_panes(&self.document, &self.panes, |_| true)
    }

    pub(crate) fn visible_layout(&self, visible: &BTreeSet<PaneId>) -> LayoutPanes {
        layout_panes(&self.document, &self.panes, |pane| visible.contains(&pane))
    }

    pub(crate) fn pane_listing(&self, id: PaneId) -> Option<Listing> {
        let pane = self.panes.find(id)?;
        Some(pane_listing(pane))
    }

    fn vars_used(&self) -> usize {
        let in_layout: usize = self
            .document
            .layout()
            .sessions
            .iter()
            .map(|session| {
                session.vars.bytes()
                    + session
                        .windows
                        .iter()
                        .map(|window| window.vars.bytes())
                        .sum::<usize>()
            })
            .sum();
        in_layout
            + self
                .panes
                .iter()
                .map(|pane| pane.vars().bytes())
                .sum::<usize>()
    }

    pub(crate) fn put_layout(
        &mut self,
        poll: &mut Poll,
        request: PutLayout,
        caller: Option<PaneId>,
    ) -> Result<Snapshot, PutFailure> {
        let read = Read::new(&self.config.file);
        self.put_layout_in(poll, request, caller, &Origin::Host, &read)
    }

    fn put_layout_in(
        &mut self,
        poll: &mut Poll,
        request: PutLayout,
        caller: Option<PaneId>,
        origin: &Origin,
        read: &Read,
    ) -> Result<Snapshot, PutFailure> {
        let before = self.document.clone();
        let new_window = client::new_window_sizer(
            self.conns
                .iter()
                .filter_map(client_of)
                .filter_map(|client| client.active.as_ref()),
        );
        let shell = || layout::shell_name(&self.config.settings(&read.server()).shell);
        let created = self
            .document
            .put_with_shell(request, new_window, &shell, &|pane| self.panes.parent(pane))
            .map_err(|error| match error {
                PutError::Stale => PutFailure::Stale(self.document.snapshot()),
                PutError::Invalid(message) => PutFailure::Invalid(message),
            })?;
        if let Err(error) = self.validate_runtime_layout(before.layout(), read) {
            self.document.rollback(before);
            return Err(PutFailure::Rejected(error));
        }
        let admitted = created
            .iter()
            .filter_map(|(_, request, _)| request.parent)
            .try_for_each(|parent| self.admit_parent(caller, parent))
            .and_then(|()| {
                created.iter().try_for_each(|(_, request, _)| {
                    self.admit_cwd(caller, &Origin::Host, request.cwd.as_ref())
                })
            });
        let chosen = admitted
            .and_then(|()| self.choose_runtimes(created.iter().map(|c| (c.0, &c.1)), origin, read));
        let runtime_ops::ChosenRuntimes {
            settings: chosen,
            keys,
        } = match chosen {
            Ok(chosen) => chosen,
            Err(error) => {
                self.document.rollback(before);
                return Err(PutFailure::Rejected(error));
            }
        };
        let dirs: Vec<Dir> = created
            .iter()
            .map(|(id, request, _)| self.start_dir(keys.get(id), request, caller, read))
            .collect();
        let added: usize = created.iter().map(|(_, _, vars)| vars.bytes()).sum();
        if self.vars_used().saturating_add(added) > SERVER_MAX_TOTAL {
            self.document.rollback(before);
            return Err(PutFailure::Invalid(
                VarRefusal::ServerTotalTooLarge.to_string(),
            ));
        }
        let sizes: BTreeMap<PaneId, Size> =
            self.document.layout().pane_sizes().into_iter().collect();
        let settings = OnceCell::new();
        let mut started = Vec::new();
        self.withheld.extend(created.iter().map(|(id, _, _)| *id));
        for ((id, request, vars), dir) in created.into_iter().zip(dirs) {
            let size = sizes.get(&id).copied().unwrap_or(Size::DEFAULT);
            let settings = settings.get_or_init(|| self.config.settings(&read.server()));
            let added = self
                .birth(
                    id,
                    &settings.shell,
                    &request,
                    vars,
                    (&chosen, &dir, keys.get(&id)),
                )
                .and_then(|birth| self.add_pane(poll, settings, id, size, birth));
            match added {
                Ok(()) => started.push(id),
                Err(error) => {
                    for id in started {
                        self.remove_pane(poll, id);
                    }
                    self.withheld.clear();
                    self.held.clear();
                    self.document.rollback(before);
                    return Err(match error {
                        AddError::Invalid(message) => PutFailure::Invalid(message.to_owned()),
                        AddError::Io(error) => PutFailure::Io(error.to_string()),
                    });
                }
            }
        }
        if self.document.unpublished() {
            self.changed(poll, before.layout(), &[]);
        }
        self.release(poll);
        for (name, settings) in chosen {
            self.runtimes.begin(poll, &name, settings);
            self.touch_runtime(poll, &name);
        }
        self.runtimes_changed(poll);
        Ok(self.document.snapshot())
    }

    fn release(&mut self, poll: &mut Poll) {
        self.withheld.clear();
        for (pane, event) in std::mem::take(&mut self.held) {
            self.event(poll, pane, event);
        }
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
        self.put_layout(poll, PutLayout { revision, layout }, None)?;
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

    pub(crate) fn delete(&mut self, poll: &mut Poll, target: layout::Remove) -> bool {
        let Some(Removal { panes, before }) = self
            .document
            .remove(target, &|pane| self.panes.parent(pane))
        else {
            return false;
        };
        let parents: Vec<_> = panes
            .iter()
            .filter_map(|id| Some((*id, self.panes.parent(*id)?)))
            .collect();
        for pane in panes {
            self.close_views(pane);
            self.tell_parent_gone(pane);
            self.stop_pane(poll, pane);
        }
        self.sweep_soon(poll);
        self.settle_stops(poll);
        self.changed(poll, &before, &parents);
        true
    }

    pub(crate) fn clear_history(&mut self, poll: &mut Poll, id: PaneId) {
        self.run(poll, id, |pane, io| pane.proc_mut().clear_history(io));
    }

    fn changed(&mut self, poll: &mut Poll, before: &Layout, parents: &[(PaneId, PaneId)]) {
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
                client.forget(layout);
                let after = client.reconcile(before, layout, parents);
                if after != client.current() {
                    client.set_current(after);
                    moved.push((index, after));
                }
            }
        }
        for (index, _) in &moved {
            self.note_focus(*index);
            self.claim(poll, *index);
        }
        self.document.publish();
        let added: BTreeSet<PaneId> = self
            .document
            .layout()
            .panes()
            .difference(&before.panes())
            .copied()
            .collect();
        let announced = layout_panes(&self.document, &self.panes, |pane| added.contains(&pane));
        self.broadcast(&ClientEvent::Layout(announced));
        let sizes = self.document.layout().pane_sizes().into_iter().collect();
        self.resize_panes(poll, &sizes);
        for (index, current) in moved {
            self.selected(index, current);
        }
        self.refocus(poll);
        self.remove_session_runtimes(poll, before);
    }

    fn selected(&mut self, index: usize, current: Option<Current>) {
        if let Some((Role::Client(client), wire)) =
            self.conns.get_mut(index).and_then(Conn::role_mut)
        {
            let selection = current.map(Selection::from).unwrap_or_default();
            let id = client.id;
            wire.ws
                .send(wire.out, protocol::json(&ClientEvent::Selected(selection)));
            self.record(diagnostics::Event::Selected {
                client: id,
                selection,
            });
        }
    }

    fn each_pane(&mut self, poll: &mut Poll, mut visit: impl FnMut(&mut Pane, &mut Io<'_>)) {
        let mut ticked = std::mem::take(&mut self.ticked);
        {
            let State {
                panes,
                conns,
                owners,
                deflate,
                spare,
                ..
            } = self;
            let mut events = spare.pop().unwrap_or_default();
            for pane in panes.iter_mut() {
                let id = pane.id();
                let mut sink = |handle: Handle<'_>| deliver(conns, owners, deflate, id, handle);
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
            .filter_map(|client| client.active.as_ref().filter(|active| active.focused))
            .filter_map(|active| active.current.map(|current| current.pane))
            .collect()
    }

    fn refocus(&mut self, poll: &mut Poll) {
        let shown = self.focused_panes();
        if self.sweep.shown_changed(&shown) {
            self.sweep_soon(poll);
        }
        self.each_pane(poll, |pane, io| pane.focus(shown.contains(&pane.id()), io));
    }

    fn note_focus(&mut self, index: usize) -> bool {
        let Some(active) = self
            .conns
            .get(index)
            .and_then(client_of)
            .and_then(|c| c.active.as_ref())
            .filter(|active| active.focused)
        else {
            return false;
        };
        active
            .current
            .is_some_and(|current| self.document.focus(current.window, current.pane))
    }

    fn arrive(&mut self, poll: &mut Poll, index: usize) {
        let focused = self.note_focus(index);
        self.claim(poll, index);
        if self.document.unpublished() {
            self.publish();
        } else if focused
            && let Some(current) = self
                .conns
                .get(index)
                .and_then(client_of)
                .and_then(|client| client.active.as_ref())
                .and_then(|active| active.current)
        {
            self.broadcast(&ClientEvent::Focus {
                window: current.window,
                pane: current.pane,
            });
        }
    }

    fn publish(&mut self) {
        self.document.publish();
        let announced = layout_panes(&self.document, &self.panes, |_| false);
        self.broadcast(&ClientEvent::Layout(announced));
    }

    fn enter(&mut self, poll: &mut Poll, index: usize, current: Option<Current>) {
        if let Some((Role::Client(client), _)) = self.conns.get_mut(index).and_then(Conn::role_mut)
        {
            client.set_current(current);
        }
        self.selected(index, current);
        self.arrive(poll, index);
        self.refocus(poll);
    }

    pub(crate) fn remove_pane(&mut self, poll: &mut Poll, id: PaneId) {
        self.stop_pane(poll, id);
        self.sweep_soon(poll);
        self.settle_stops(poll);
    }

    fn stop_pane(&mut self, poll: &mut Poll, id: PaneId) {
        self.end_visit(poll, id, Some("pane removed".to_owned()));
        let runtime = self.panes.find(id).and_then(|pane| pane.runtime().cloned());
        self.pane_ended(poll, id);
        self.clipboard.drop_where(poll, |read| read.pane == id);
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
        self.leaks.release_pane(id);
        if let Some(runtime) = &runtime {
            self.runtimes.remove_token(runtime, id);
            self.touch_runtime(poll, runtime);
        }
        self.runtimes_changed(poll);
    }

    pub(crate) fn reap(&mut self, poll: &mut Poll) -> std::io::Result<()> {
        for name in self.runtimes.reap(poll) {
            let _ = self.down_runtime(poll, &name, true);
        }
        self.runtimes_changed(poll);
        self.exec_reap(poll);
        self.leaving.reap();
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
        let panes: Vec<_> = self.panes.iter().map(Pane::id).collect();
        for id in panes {
            self.end_visit(poll, id, Some("server ended".to_owned()));
        }
        for conn in &mut self.conns {
            conn.out.shut();
        }
        self.panes.shutdown(&mut Io {
            poll,
            events: &mut Vec::new(),
            sink: &mut discard,
        });
        self.leaks.release_all();
        self.exec_shutdown();
        self.runtimes.shutdown(poll);
        self.runtimes_changed(poll);
        poll.stop(self.ticker);
        self.model.stop(poll);
        self.sweep.stop(poll);
        self.stops.stop(poll);
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
        if self.sweep.take_due() {
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
        let spare = SERVER_MAX_TOTAL.saturating_sub(self.vars_used());
        let Some(pane) = self.panes.find_mut(id) else {
            return Ok(());
        };
        if pane.vars_mut().set_within(&name, value, spare)? {
            self.model.mark(poll, pane);
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
        if self.withheld.contains(&id) {
            self.held.push((id, event));
            return;
        }
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
            Event::Ready => {
                if let Some(pid) = self.panes.find(id).and_then(|pane| pane.proc().child_pid()) {
                    self.broadcast(&ClientEvent::Pid {
                        pane: id,
                        pid: pid.get(),
                    });
                }
            }
            Event::Dead(death) => {
                self.end_visit(poll, id, Some("pane ended".to_owned()));
                self.pump_views(poll, id);
                self.tell_parent(id, End::Dead((&death).into()));
                self.pane_ended(poll, id);
                if let Some(pane) = self.panes.find_mut(id) {
                    pane.telemetry_mut().records.clear();
                    self.model.mark(poll, pane);
                }
                self.broadcast(&ClientEvent::Dead(PaneDead {
                    pane: id,
                    dead: (&death).into(),
                }));
                if let pane_proc::Cause::Failed(_) = death.cause {
                    self.delete(poll, crate::layout::Remove::Pane(id));
                }
                self.runtimes_changed(poll);
                self.sweep_soon(poll);
                self.settle_stops(poll);
            }
            Event::Prompt(prompt) => {
                if let Some(pane) = self.panes.find_mut(id) {
                    pane.telemetry_mut().prompt(prompt);
                    self.model.mark(poll, pane);
                }
            }
            Event::Record(report) => {
                let now = ko_sys::clock::Mono::now();
                if let Some(pane) = self.panes.find_mut(id)
                    && pane.telemetry_mut().records.apply(report, now)
                {
                    self.model.mark(poll, pane);
                }
            }
            Event::Foreground(foreground) => {
                if let Some(pane) = self.panes.find_mut(id)
                    && pane.telemetry_mut().foreground(foreground.clone())
                {
                    self.model.mark(poll, pane);
                    self.broadcast(&ClientEvent::Foreground {
                        pane: id,
                        foreground,
                    });
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
            Event::Image { req, object } => self.image_reply(poll, id, req, object),
            Event::ImageGone(name) => self.leaks.gone(&name),
            Event::ClipboardWrite { location, contents } => {
                self.clipboard_write(id, location, contents);
            }
            Event::ClipboardRead {
                req,
                location,
                mimes,
                list,
            } => self.clipboard_read(poll, id, req, location, mimes, list),
            Event::Matches { req, matches } => self.search_matches(id, req, matches),
            Event::SearchDone { req } => self.search_done(id, req),
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
                        .and_then(|pane| pane.proc().dead())
                        .map(Into::into);
                    if let Some((Role::View(view), mut wire)) = self.conns[index].role_mut() {
                        view.on_done(&mut wire, &done, dead);
                    }
                    self.pump_view(poll, index);
                }
            }
            Event::Screen { req, chunk, last } => {
                let key = (id, req);
                let Some(Owner::Screen { conn, started }) = self.owners.get(&key).cloned() else {
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
                router::screen::<routes::Screen>(self, poll, conn, started, &chunk, last);
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
                        router::pasted(self, poll, conn, result(paste));
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
                    Some(
                        Owner::Screen { .. }
                        | Owner::Snapshot(_)
                        | Owner::Image { .. }
                        | Owner::Search(_),
                    )
                    | None => {}
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
                Some(Owner::Image { conn, minted, .. }) => {
                    self.leaks.gone(&minted);
                    if let Some(conn) = conn {
                        router::failed(self, poll, conn, false, &message);
                    }
                }
                Some(Owner::Search(conn)) => self.search_failed(conn),
                Some(Owner::Snapshot(_)) | None => {}
            },
        }
    }

    fn leaving_due(&mut self, poll: &mut Poll, timer: Timer) -> bool {
        let ours = self.leaving.is_timer(timer);
        if ours {
            self.leaving.escalate(poll);
        }
        ours
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
        let text: Utf8Bytes = protocol::json(event).into();
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
            match conn.role_mut() {
                Some((Role::View(view), wire)) if view.pane == pane => {
                    wire.ws.reject(wire.out, crate::ws::Rejection::Gone);
                    view.close(wire.out);
                }
                _ => {}
            }
        }
    }

    fn pump_views(&mut self, poll: &mut Poll, pane: PaneId) {
        for index in 0..self.conns.len() {
            if self
                .conns
                .get(index)
                .and_then(view_of)
                .map(|view| view.pane)
                == Some(pane)
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
        if let Some(view) = self.conns.get(index).and_then(view_of) {
            self.record(diagnostics::Event::ViewOpened {
                pane: view.pane,
                client: view.client,
            });
        }
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
        self.conns
            .push(Conn::new(stream, poll, self.config.view_queue.cap_bytes));
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
                    && !self.runtime_ready(poll, ready)
                    && !self.exec_ready(poll, ready)
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
                } else if self.sweep.is_timer(due.timer) {
                    self.sweep(poll);
                } else if self.stops.is_escalation(due.timer) {
                    self.escalate(poll);
                } else if self.runtime_due(poll, due.timer)
                    || self.leaving_due(poll, due.timer)
                    || self.exec_due(poll, due.timer)
                    || self.stop_due(poll, due.timer)
                    || self.message_due(poll, due.timer)
                    || self.image_due(poll, due.timer)
                    || self.clipboard_due(poll, due.timer)
                {
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
                if matches!(conn.phase, Phase::Streaming) {
                    conn.phase = Phase::Head;
                    self.serve(poll, index);
                }
                self.pump_view(poll, index);
            }
            self.pump_exec(poll, index);
        }
        if ready.read {
            match self.conns[index].phase {
                Phase::Ws(_) => self.read_ws(poll, index),
                Phase::Handling => {
                    self.conns[index].read(poll, &mut Reads::new());
                }
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
            if !link.role.reads() {
                return;
            }
            let text = match link.ws.next(out, poll, token, &mut reads) {
                Next::Text(text) => text,
                Next::Wait | Next::Close => return,
            };
            match link.role {
                Role::Client(_) => self.client_text(poll, index, text.as_bytes()),
                Role::View(_) => self.view_text(poll, index, text.as_bytes()),
                Role::Search(_) => link.ws.reject(out, crate::ws::Rejection::Invalid),
                Role::Messages(pane) => self.stream_text(poll, index, pane, text.as_bytes()),
                Role::Exec(_) => self.exec_text(poll, index, text.as_bytes()),
                Role::Visit(_) => {
                    self.visit_text(poll, index, text.as_bytes());
                    self.runtimes_changed(poll);
                }
            }
        }
    }

    fn client_text(&mut self, poll: &mut Poll, index: usize, text: &[u8]) {
        let request = protocol::decode::<ClientRequest>(text);
        let read = Read::new(&self.config.file);
        let runtimes = if matches!(request, Ok(ClientRequest::Hello(_))) {
            self.client_runtimes(&read)
        } else {
            Vec::new()
        };
        if matches!(request, Ok(ClientRequest::Hello(_)))
            && let Some(client) = self.conns.get(index).and_then(client_of)
        {
            self.record(diagnostics::Event::Hello { client: client.id });
        }
        let runtimes_error = self.runtimes.config_error().map(str::to_owned);
        let State {
            document,
            conns,
            panes,
            ..
        } = self;
        let Some((Role::Client(client), wire)) = conns.get_mut(index).and_then(Conn::role_mut)
        else {
            return;
        };
        let id = client.id;
        let layout = document.layout();
        let change = request
            .map_err(|error| error.to_string())
            .and_then(|request| client.receive(request).map_err(str::to_owned));
        let change = match change {
            Ok(change) => change,
            Err(message) => {
                wire.ws
                    .send(wire.out, protocol::json(&ClientEvent::Refused { message }));
                return wire.ws.reject(wire.out, crate::ws::Rejection::Invalid);
            }
        };
        let current = match change {
            Change::Hello(selection) => {
                client.forget(layout);
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
                    limits: Limits::of(
                        self.config.settings(&read.server()).limits,
                        &self.config.media,
                    ),
                    instance: self.instance.clone(),
                    now: ko_sys::clock::Mono::now().nanos(),
                    runtimes,
                    runtimes_error,
                });
                wire.ws.send(wire.out, protocol::json(&welcome));
                let announced = ClientEvent::Layout(layout_panes(document, panes, |_| true));
                wire.ws.send(wire.out, protocol::json(&announced));
                self.claim_sizes(poll, index, &protocol::Sizing::Disabled);
                current
            }
            Change::Select(selection) => match client.select(layout, selection) {
                Some(current) => Some(current),
                None => return wire.ws.reject(wire.out, crate::ws::Rejection::Invalid),
            },
            Change::Switch(switch) => {
                client.switch(layout, switch, &|pane| self.panes.parent(pane))
            }
            Change::Claim => {
                self.claim_sizes(poll, index, &protocol::Sizing::Disabled);
                self.arrive(poll, index);
                return self.refocus(poll);
            }
            Change::Resize { previous } => {
                client.forget(layout);
                self.claim_sizes(poll, index, &previous);
                if self.document.unpublished() {
                    self.publish();
                }
                return;
            }
            Change::Nothing => return self.refocus(poll),
            Change::Answer { id: read, served } => {
                return self.clipboard_answered(poll, id, read, served);
            }
        };
        self.enter(poll, index, current);
    }

    fn claim(&mut self, poll: &mut Poll, index: usize) -> bool {
        let Some(current) = self
            .conns
            .get(index)
            .and_then(client_of)
            .and_then(Client::current)
        else {
            return false;
        };
        self.claim_window(poll, index, current.window)
    }

    fn claim_window(&mut self, poll: &mut Poll, index: usize, window: WindowId) -> bool {
        let Some(client) = self.conns.get(index).and_then(client_of) else {
            return false;
        };
        let id = client.id;
        let Some(active) = client.active.as_ref() else {
            return false;
        };
        let others = self
            .conns
            .iter()
            .filter_map(client_of)
            .filter_map(|client| client.active.as_ref().map(|peer| (client.id, peer)));
        if client::claims(id, active, window, others)
            && let Some(size) = active.sizing.size(window)
        {
            self.sizers.insert(window, id);
            return self.size_window(poll, window, size);
        }
        false
    }

    fn claim_sizes(&mut self, poll: &mut Poll, index: usize, previous: &protocol::Sizing) {
        let Some(client) = self.conns.get(index).and_then(client_of) else {
            return;
        };
        let id = client.id;
        let Some(active) = client.active.as_ref() else {
            return;
        };
        self.sizers
            .retain(|window, owner| *owner != id || active.sizing.size(*window).is_some());
        let sizes: Vec<_> = match &active.sizing {
            protocol::Sizing::Disabled => Vec::new(),
            protocol::Sizing::Windows { windows, .. } => windows.iter().copied().collect(),
        };
        for entry in sizes {
            if previous.size(entry.window).is_some() {
                if self.sizers.get(&entry.window) == Some(&id) {
                    self.size_window(poll, entry.window, entry.size.0);
                }
            } else {
                self.claim_window(poll, index, entry.window);
            }
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
                wire.ws.reject(wire.out, crate::ws::Rejection::Invalid);
                view.close(wire.out);
            }
            Ok(ViewRequest::Resync(options)) => {
                if let Some(history) = view.request(wire.out, options.history) {
                    self.snapshot(poll, index, history);
                }
            }
            Ok(ViewRequest::Input { input }) => {
                self.record_input(pane, InputSource::View, &input);
                let (sent, events) =
                    self.input(poll, pane, &input, |paste| Owner::ViewPaste(token, paste));
                if let Some((Role::View(view), mut wire)) = self.conns[index].role_mut() {
                    match sent {
                        Ok(_) => {}
                        Err(Refusal::Ended) => view.reject(&mut wire),
                        Err(Refusal::TooLarge(_)) => {
                            wire.ws.reject(wire.out, crate::ws::Rejection::Invalid);
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
        {
            let now = Instant::now();
            let reads = link.role.reads();
            if !reads && ko_sys::sock::peer_closed(out.parts().0.as_fd()) {
                out.shut();
                return;
            }
            let left = link.ws.ping(out, now, reads);
            if let Ping::After(left) = left {
                let _ = poll.start(timer, left, None);
            }
        }
    }

    fn settle(&mut self, poll: &mut Poll) {
        self.announce_runtimes();
        let mut client_closed = false;
        loop {
            for conn in &mut self.conns {
                conn.settle();
            }
            let Some(index) = self.conns.iter().position(|conn| conn.out.is_shut()) else {
                break;
            };
            let conn = self.conns.remove(index);
            poll.unwatch(conn.token);
            poll.free(conn.timer);
            self.runtimes.forget_wait(poll, conn.token);
            self.forget_stops(poll, conn.token);
            self.messages.forget(conn.token);
            if let Phase::Ws(link) = conn.phase {
                let cause = conn.out.cause();
                match link.role {
                    Role::Client(client) => {
                        self.record(diagnostics::Event::ClientClosed {
                            client: client.id,
                            cause,
                        });
                        client_closed = true;
                        self.sizers.retain(|_, sizer| *sizer != client.id);
                        for conn in &mut self.conns {
                            if let Some((Role::View(view), wire)) = conn.role_mut()
                                && view.client == Some(client.id)
                            {
                                wire.out.closing(Cause::ClientClosed);
                                view.close(wire.out);
                            }
                        }
                        self.clipboard_forget(poll, |read| read.client == client.id);
                    }
                    Role::Search(search) => self.cancel_search(poll, search),
                    Role::Messages(pane) => self.stream_closed(poll, pane, conn.token),
                    Role::Exec(session) => self.exec_gone(poll, conn.token, session),
                    Role::Visit(visit) => {
                        if self.panes.find(visit.pane).and_then(Pane::visit_conn)
                            == Some(conn.token)
                        {
                            self.end_visit(poll, visit.pane, None);
                            self.runtimes_changed(poll);
                        }
                    }
                    Role::View(view) => self.record(diagnostics::Event::ViewClosed {
                        pane: view.pane,
                        client: view.client,
                        cause,
                    }),
                }
            }
        }
        if client_closed {
            self.refocus(poll);
        }
        for conn in &mut self.conns {
            let interest = conn.interest();
            if interest.reads() != poll.interest_of(conn.token).reads()
                && let Phase::Ws(link) = &mut conn.phase
            {
                let now = Instant::now();
                link.ws.reads_changed(interest.reads(), now);
                if let Ping::After(left) = link.ws.ping(&mut conn.out, now, link.role.reads()) {
                    let _ = poll.start(conn.timer, left, None);
                }
            }
            poll.interest(conn.token, conn.interest());
        }
    }
}

#[cfg(test)]
mod tests {
    use crate::fuzz::Rig;
    use crate::ids::{MessageId, PaneId};
    use crate::protocol::{Command, CreatePane, NewWindow};
    use crate::server::tests::scratch;
    use ko_sys::event::Mode;
    use std::path::PathBuf;
    use std::time::{Duration, Instant};

    #[test]
    fn a_pane_row_has_no_pid_until_the_pane_is_ready() {
        let exe = PathBuf::from(
            std::env::var_os("KO_PANE_EXE")
                .expect("KO_PANE_EXE names ko-pane; make test builds it and sets it"),
        );
        let mut rig = Rig::new(scratch("state-pid"), exe, "exec cat");
        let request = CreatePane {
            cwd: None,
            command: Some(Command::Argv {
                argv: ["/bin/sh", "-c", "exec cat"].map(str::to_owned).to_vec(),
            }),
            env: Vec::new(),
            vars: Default::default(),
            parent: None,
            close: Default::default(),
            runtime: None,
        };
        let pane = rig.state.new_session(&mut rig.poll, &request).unwrap();
        assert_eq!(rig.state.pane_listing(pane).unwrap().row.pid, None);

        let deadline = Instant::now() + Duration::from_secs(5);
        while rig.state.pane_listing(pane).unwrap().row.pid.is_none() {
            assert!(Instant::now() < deadline, "the pane never became ready");
            rig.step(Mode::Wait);
        }
    }

    #[test]
    fn a_removed_pane_tells_its_parent_it_is_gone_only_when_it_was_alive() {
        let exe = PathBuf::from(
            std::env::var_os("KO_PANE_EXE")
                .expect("KO_PANE_EXE names ko-pane; make test builds it and sets it"),
        );
        let mut rig = Rig::new(scratch("state-gone"), exe, "exec cat");
        let request = |command: &str, parent: Option<PaneId>| CreatePane {
            cwd: None,
            command: Some(Command::Argv {
                argv: ["/bin/sh", "-c", command].map(str::to_owned).to_vec(),
            }),
            env: Vec::new(),
            vars: Default::default(),
            parent,
            close: Default::default(),
            runtime: None,
        };
        let parent = rig
            .state
            .new_session(&mut rig.poll, &request("exec cat", None))
            .unwrap();
        let mut child = |command: &str| {
            let window = NewWindow {
                session: None,
                name: None,
                pane: request(command, Some(parent)),
            };
            rig.state
                .new_pane(&mut rig.poll, None, &crate::server::Origin::Host, window)
                .unwrap()
                .pane
        };
        let died = child("exit 0");
        let lives = child("exec cat");

        let deadline = Instant::now() + Duration::from_secs(5);
        while rig.state.pane_listing(died).unwrap().row.dead.is_none() {
            assert!(Instant::now() < deadline, "the child never died");
            rig.step(Mode::Wait);
        }
        let told = |rig: &Rig, child| {
            rig.state
                .panes
                .find(parent)
                .unwrap()
                .inbox()
                .seen(&MessageId::ended(child))
                .is_some()
        };
        assert!(told(&rig, died), "the death was told");
        rig.state
            .panes
            .find_mut(parent)
            .unwrap()
            .inbox_mut()
            .clear();
        assert!(!told(&rig, died), "the id left the ring");
        rig.state
            .delete(&mut rig.poll, crate::layout::Remove::Pane(died));
        assert!(
            !told(&rig, died),
            "a pane that died is not told again as gone"
        );
        rig.state
            .delete(&mut rig.poll, crate::layout::Remove::Pane(lives));
        assert!(told(&rig, lives), "a pane removed alive is told as gone");
    }
}
