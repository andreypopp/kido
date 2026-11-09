use std::collections::BTreeMap;
use std::fs::OpenOptions;
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::Child;
use std::time::{Duration, Instant};

use crate::clipboard;
use ko_client::edit::{Edge, Edit};
use ko_client::launch::{self, BACKOFF_FIRST, PATIENCE, backoff_after};
use ko_client::layout::{EditError, Edited};
use ko_client::model::{Applied, Item, JoinError, Model, NavigationIds, Notice, Rejoin, cycle};
use ko_client::remote::{Progress, Remote};
use ko_client::wire::{self, Link, Next, WATCHDOG, silent, text};
use ko_config::values::{AbsPath, RuntimeName};
use ko_pane_wire::frame::{Dim, ScreenFormat, ScreenRows, Size};
use ko_server::api::Route;
use ko_server::ids::{Name, PaneId, SessionId, WindowId};
use ko_server::protocol::{
    self, ClientRequest, ClipboardContent, ClipboardServed, CreatePane, Cwd, Direction, Hello,
    Input as Wire, Key as WireKey, Mouse as WireMouse, Paste, Selection, Switch, json,
};
use ko_sys::event::{Due, Events, Interest, Mode, Poll, Ready, Timer, Token};
use ko_sys::signal::{Signal, Signals};
use ko_vt::render::{Frame, MouseTracking};

use crate::copy::Outcome;
use crate::geometry;
use crate::input::{self, Event, Input, KeyEvent, MouseKind, Reply};
use crate::keys::{
    Action, Context, Keys, Kill, Mode as KeyMode, PaneCommand, PaneEdit, PaneSelect, Rename, State,
    Step,
};
use crate::mirror::Mirror;
use crate::modes::{self, Modes};
use crate::renderer::{Layout, PaneFrame, Renderer, status};
use crate::sidebar;
use crate::tty::{Geometry, Tty};

const PACE: Duration = Duration::from_millis(8);
const PROBE: Duration = Duration::from_millis(500);
const ENTER: &str = "\x1b[?1049h\x1b[?25l";
const LEAVE: &str = "\x1b[?25h\x1b[0m\x1b[?1049l\x1b[?25h";
const STATUS_ROWS: usize = 1;
const GIVE_UP: Duration = Duration::from_secs(60);
const PAUSED: Duration = Duration::from_millis(100);
const PROBE_TRANSPORT: Duration = Duration::from_secs(3);
const SIGNALS: [Signal; 6] = [
    Signal::Hup,
    Signal::Term,
    Signal::Int,
    Signal::Quit,
    Signal::Winch,
    Signal::Child,
];

fn direction_steps(direction: Direction) -> isize {
    match direction {
        Direction::Next => 1,
        Direction::Previous => -1,
    }
}

fn dim(value: usize) -> Dim {
    u16::try_from(value.max(1))
        .ok()
        .and_then(Dim::new)
        .unwrap_or(Size::DEFAULT.cols)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Panel {
    Hidden,
    Visible,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Drag {
    button: ko_pane_wire::frame::MouseButton,
    target: Target,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Target {
    Divider(geometry::Grip, protocol::Cells),
    Sidebar,
}

impl Panel {
    fn x(self, cols: usize, width: usize) -> usize {
        match self {
            Panel::Hidden => 0,
            Panel::Visible => sidebar::pane_x(width, cols),
        }
    }
}

#[derive(Debug, Default)]
struct Last {
    session: Option<SessionId>,
    window: Option<WindowId>,
    at: Option<(SessionId, WindowId, PaneId)>,
    panes: BTreeMap<WindowId, PaneId>,
}

#[derive(Debug)]
struct ShownPane {
    pane: PaneId,
    mirror: Mirror,
    frame: Frame,
    serial: Option<u64>,
    death: Option<(protocol::Dead, String)>,
}

#[derive(Debug)]
struct Shown {
    window: WindowId,
    panes: Vec<ShownPane>,
    geometry: std::rc::Rc<geometry::Geometry>,
}

impl Shown {
    fn pane_mut(&mut self, pane: PaneId) -> Option<&mut ShownPane> {
        self.panes.iter_mut().find(|shown| shown.pane == pane)
    }

    fn retain(&mut self, geometry: &geometry::Geometry, poll: &mut Poll) -> bool {
        let before = self.panes.len();
        self.panes.retain_mut(|pane| {
            if geometry
                .panes
                .iter()
                .any(|visible| visible.pane == pane.pane)
            {
                true
            } else {
                pane.mirror.unwatch(poll);
                false
            }
        });
        before != self.panes.len()
    }
}

fn panes(view: &Option<Shown>) -> impl Iterator<Item = &ShownPane> {
    view.iter().flat_map(|shown| &shown.panes)
}
fn panes_mut(view: &mut Option<Shown>) -> impl Iterator<Item = &mut ShownPane> {
    view.iter_mut().flat_map(|shown| &mut shown.panes)
}

#[derive(Debug)]
struct Running {
    child: Child,
    path: PathBuf,
}

impl Drop for Running {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

#[derive(Debug)]
struct Deadline {
    timer: Timer,
    at: Option<Instant>,
}

impl Deadline {
    fn new(poll: &mut Poll) -> Deadline {
        Deadline {
            timer: poll.timer(),
            at: None,
        }
    }

    fn set(&mut self, poll: &mut Poll, at: Option<Instant>) -> Result<(), String> {
        if self.at == at {
            return Ok(());
        }
        match at {
            None => poll.stop(self.timer),
            Some(at) => poll
                .start(
                    self.timer,
                    at.saturating_duration_since(Instant::now()),
                    None,
                )
                .map_err(text)?,
        }
        self.at = at;
        Ok(())
    }

    fn fired(&mut self, poll: &Poll, due: &[Due]) -> bool {
        let fired = due
            .iter()
            .any(|due| due.timer == self.timer && poll.current(*due));
        if fired {
            self.at = None;
        }
        fired
    }
}

#[derive(Debug)]
struct Session {
    tty: Tty,
    modes: Modes,
}

impl Session {
    fn write(&self, output: &str) -> Result<(), String> {
        if output.is_empty() {
            Ok(())
        } else {
            self.tty.write(output).map_err(text)
        }
    }

    fn reset_modes(&mut self) -> String {
        let mut output = String::new();
        self.modes.reset(&mut output);
        output
    }

    fn reset(&mut self) -> Result<(), String> {
        let output = self.reset_modes();
        self.write(&output)
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        let mut output = self.reset_modes();
        output.push_str(LEAVE);
        let _ = self.tty.write(&output);
        self.tty.release();
        self.tty.flush_input();
        let mut restore = String::new();
        self.modes.restore(&mut restore);
        let _ = self.tty.write(&restore);
    }
}

struct Probed {
    modes: Modes,
    events: Vec<Event>,
}

fn probe(
    session: &Session,
    poll: &mut Poll,
    stdin: Token,
    input: &mut Input,
) -> Result<Probed, String> {
    let queries = format!("{}\x1b[c", modes::query());
    session.write(&queries)?;
    let deadline = Instant::now() + PROBE;
    let timer = poll.timer();
    let mut events = Events::default();
    let (mut reports, mut answered) = (Vec::new(), false);
    let mut kept = Vec::new();
    let mut buffer = [0u8; 4096];
    loop {
        let now = Instant::now();
        if answered || now >= deadline {
            break;
        }
        poll.start(timer, deadline - now, None).map_err(text)?;
        poll.turn(Mode::Wait, &mut events).map_err(text)?;
        if !events
            .ready()
            .iter()
            .any(|ready| ready.token == stdin && ready.read)
        {
            continue;
        }
        let count = match session.tty.read(&mut buffer).map_err(text)? {
            Some(0) => break,
            Some(count) => count,
            None => continue,
        };
        let mut parsed = Vec::new();
        input.feed(
            buffer.get(..count).unwrap_or_default(),
            Instant::now(),
            &mut parsed,
        );
        for event in parsed {
            match event {
                Event::Reply(Reply::Modes(modes)) => reports.extend(modes),
                Event::Reply(Reply::Da1) => answered = true,
                Event::Mouse(_) => {}
                other => kept.push(other),
            }
        }
    }
    poll.stop(timer);
    poll.free(timer);
    input.expire(Instant::now() + Duration::from_secs(1), &mut kept);
    Ok(Probed {
        modes: Modes::saved(&reports),
        events: kept,
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Restore {
    Reopen,
    Show,
}

#[derive(Debug)]
struct Reconnecting {
    since: Instant,
    backoff: Duration,
    cause: String,
    restore: Restore,
}

#[derive(Debug, Clone, Copy)]
struct Click {
    pane: PaneId,
    x: usize,
    y: usize,
    at: Instant,
    count: u8,
}

impl Click {
    fn count(previous: Option<Click>, pane: PaneId, event: &input::MouseEvent) -> Click {
        let at = Instant::now();
        let count = previous
            .filter(|last| {
                last.pane == pane
                    && last.x == event.x
                    && last.y == event.y
                    && at.duration_since(last.at) <= Duration::from_millis(500)
            })
            .map_or(1, |last| last.count % 3 + 1);
        Click {
            pane,
            x: event.x,
            y: event.y,
            at,
            count,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct PendingSelection {
    request: protocol::NavigationId,
    pane: Option<PaneId>,
}

#[derive(Debug)]
struct Client {
    view: Option<Shown>,
    session: Session,
    poll: Poll,
    signals: Signals,
    stdin: Token,
    signal_token: Token,
    link: Link,
    link_token: Token,
    model: Model,
    socket: PathBuf,
    pager_command: String,
    pager: Option<Running>,
    output: String,
    input: Input,
    renderer: Renderer,
    panel: Panel,
    sidebar_width: usize,
    keys: Keys,
    last: Last,
    pending_selection: Option<PendingSelection>,
    navigation: NavigationIds,
    mouse_down: Option<PaneId>,
    drag: Option<Drag>,
    geometry: Geometry,
    focused: bool,
    immediate: bool,
    last_paint: Option<Instant>,
    serial: u64,
    quit: bool,
    pending: Vec<Event>,
    clipboard_reads: clipboard::Pending,
    paste_buffer: String,
    copy_click: Option<Click>,
    wake: Deadline,
    escape: Deadline,
    repeat: Deadline,
    watchdog: Deadline,
    retry: Deadline,
    remote: Option<Remote>,
    reconnecting: Option<Reconnecting>,
}

impl Client {
    fn start(
        socket: PathBuf,
        mut link: Link,
        pager: String,
        signals: Signals,
        remote: Option<Remote>,
    ) -> Result<Client, String> {
        let mut session = Session {
            tty: Tty::raw().map_err(text)?,
            modes: Modes::default(),
        };
        let mut poll = Poll::new();
        let stdin = poll.watch(session.tty.input(), Interest::Read);
        let signal_token = poll.watch(signals.fd(), Interest::Read);
        let mut input = Input::default();
        let probed = probe(&session, &mut poll, stdin, &mut input)?;
        session.modes = probed.modes;
        session.write(ENTER)?;
        let geometry = session.tty.size();
        let panel = if sidebar::visible(geometry.cols) {
            Panel::Visible
        } else {
            Panel::Hidden
        };
        let sidebar_width = sidebar::width(sidebar::DEFAULT_WIDTH, geometry.cols);
        let hello = hello(geometry, panel, sidebar_width, true);
        let model = Model::join(&mut link, hello).map_err(|error| match error {
            JoinError::Refused(message) | JoinError::Protocol(message) => message,
        })?;
        let link_token = link.watch(&mut poll).map_err(text)?;
        let (wake, escape, repeat, watchdog, retry) = (
            Deadline::new(&mut poll),
            Deadline::new(&mut poll),
            Deadline::new(&mut poll),
            Deadline::new(&mut poll),
            Deadline::new(&mut poll),
        );
        let mut client = Client {
            view: None,
            session,
            poll,
            signals,
            stdin,
            signal_token,
            link,
            link_token,
            model,
            socket,
            pager_command: pager,
            pager: None,
            output: String::new(),
            input,
            renderer: Renderer::default(),
            panel,
            sidebar_width,
            keys: Keys::new(),
            last: Last::default(),
            pending_selection: None,
            navigation: NavigationIds::default(),
            mouse_down: None,
            drag: None,
            geometry,
            focused: true,
            immediate: true,
            last_paint: None,
            serial: 0,
            quit: false,
            pending: probed.events,
            clipboard_reads: clipboard::Pending::default(),
            paste_buffer: String::new(),
            copy_click: None,
            wake,
            escape,
            repeat,
            watchdog,
            retry,
            remote,
            reconnecting: None,
        };
        client.client(wire::buffered(client.link_token), Instant::now())?;
        client.show_first()?;
        client.resize()?;
        Ok(client)
    }

    fn pane(&self) -> Option<PaneId> {
        self.pending_selection
            .and_then(|pending| pending.pane)
            .or(self.model.selection.pane)
    }

    fn active(&mut self) -> Option<&mut ShownPane> {
        let pane = self.pane()?;
        self.view.as_mut()?.pane_mut(pane)
    }

    fn row(&self, pane: PaneId) -> Option<&protocol::Row> {
        self.model
            .panes
            .iter()
            .find(|found| found.row.id == pane)
            .map(|found| &found.row)
    }

    fn dead(&self) -> Option<protocol::Dead> {
        let pane = self.pane()?;
        self.row(pane).and_then(|row| row.dead.clone())
    }

    fn shown(&self) -> Option<(&protocol::Session, &protocol::Window)> {
        let (session, window) = self.model.locate(self.pane()?)?;
        Some((
            self.model.layout.layout.session(session)?,
            self.model.layout.layout.window(window)?.1,
        ))
    }

    fn layout(&self) -> Layout {
        let Geometry { cols, rows, .. } = self.geometry;
        let outline = match self.panel {
            Panel::Hidden => Vec::new(),
            _ => self.model.outline(),
        };
        Layout {
            cols,
            rows,
            pane_x: self.panel.x(cols, self.sidebar_width),
            pane_rows: rows.saturating_sub(STATUS_ROWS),
            status: status(
                self.shown(),
                self.last.window,
                self.keys.state(),
                self.keys.mode(),
                self.remote
                    .as_ref()
                    .filter(|_| self.reconnecting.is_some())
                    .map(Remote::host),
            ),
            help: *self.keys.state() == State::Help,
            resizing: match self.keys.mode() {
                KeyMode::Resize => Some(crate::renderer::Resizing::Panes),
                KeyMode::SidebarResize(_) => Some(crate::renderer::Resizing::Sidebar),
                _ => None,
            },
            copy: panes(&self.view)
                .find_map(|pane| pane.mirror.copy().map(|copy| (pane.pane, copy.clone()))),
            geometry: self
                .view
                .as_ref()
                .map(|shown| shown.geometry.clone())
                .unwrap_or_default(),
            active: self.pane(),
            choosing: self.keys.cursor().and_then(|chosen| {
                outline
                    .iter()
                    .position(|item| matches!(item, Item::Pane { id, .. } if *id == chosen))
            }),
            runtimes: if matches!(self.panel, Panel::Hidden) {
                Vec::new()
            } else {
                sidebar::runtime_lines(&self.model)
            },
            sidebar: sidebar::lines(
                self.pane(),
                &outline,
                &self.model.panes,
                |pane| self.model.mark(pane),
                (&self.model.runtimes, |pane| self.model.place(pane)),
            ),
        }
    }

    fn client_send(&mut self, request: &ClientRequest) -> Result<(), String> {
        if self.reconnecting.is_some() {
            return Ok(());
        }
        self.link.send(json(request)).map_err(text)?;
        self.link.settle(&mut self.poll).map_err(text)
    }

    fn input_send(&mut self, pane: PaneId, input: Wire) -> Result<(), String> {
        let input = match self.view.as_mut().and_then(|shown| shown.pane_mut(pane)) {
            Some(shown) => match shown.mirror.input(&mut self.poll, input)? {
                Some(input) => input,
                None => return Ok(()),
            },
            None => input,
        };
        wire::request(
            &self.socket,
            (Some(self.model.client), None),
            &Route::Input { id: pane },
            json(&input).as_bytes(),
            None,
        )
        .map(drop)
        .map_err(String::from)
    }

    fn set_sidebar_width(&mut self, requested: usize) -> Result<(), String> {
        let width = sidebar::width(requested, self.geometry.cols);
        if width != self.sidebar_width {
            self.sidebar_width = width;
            self.resize()?;
            self.immediate = true;
        }
        Ok(())
    }

    fn resize(&mut self) -> Result<(), String> {
        let size = pane_size(self.geometry, self.panel, self.sidebar_width);
        let windows = self
            .model
            .selection
            .window
            .map(|window| protocol::WindowSize {
                window,
                size: protocol::Size(size),
            });
        self.client_send(&ClientRequest::Size {
            sizing: protocol::Sizing::Windows {
                viewport: protocol::Size(size),
                windows: windows.into(),
            },
        })
    }

    fn request(&self, route: &Route) -> Result<Vec<u8>, String> {
        wire::request(
            &self.socket,
            (Some(self.model.client), None),
            route,
            b"",
            None,
        )
        .map_err(String::from)
    }

    fn redraw(&mut self) -> Result<(), String> {
        self.session.reset()?;
        self.renderer.invalidate();
        self.immediate = true;
        Ok(())
    }

    fn edit(&mut self, edit: Edit) -> Result<Option<Edited>, String> {
        match ko_client::layout::edit(&self.socket, (Some(self.model.client), None), &edit) {
            Ok(edited) => Ok(Some(edited)),
            Err(EditError::Refused(_)) => Ok(None),
            Err(error) => Err(error.to_string()),
        }
    }

    fn switch(&mut self, pane: PaneId) -> Result<(), String> {
        self.keys.leave();
        if let Some((_, window)) = self
            .model
            .locate(pane)
            .and_then(|(_, window)| self.model.layout.layout.window(window))
            && window.zoom.is_some_and(|zoom| zoom != pane)
            && self
                .edit(Edit::Zoom {
                    window: window.id,
                    pane: None,
                })?
                .is_none()
        {
            return Ok(());
        }
        self.select(pane)?;
        self.sync_views()
    }

    fn select(&mut self, pane: PaneId) -> Result<(), String> {
        if self.pane() != Some(pane) {
            self.leave_copy()?;
        }
        self.navigate(Some(pane), |request| ClientRequest::Select {
            request,
            selection: Selection {
                pane: Some(pane),
                ..Selection::default()
            },
        })
    }

    fn navigate(
        &mut self,
        pane: Option<PaneId>,
        make: impl FnOnce(protocol::NavigationId) -> ClientRequest,
    ) -> Result<(), String> {
        let request = self.navigation.next_request().map_err(str::to_owned)?;
        self.client_send(&make(request))?;
        self.pending_selection = Some(PendingSelection { request, pane });
        Ok(())
    }

    fn sync_views(&mut self) -> Result<(), String> {
        let active = self.pane();
        if panes(&self.view).any(|pane| pane.mirror.copy().is_some() && Some(pane.pane) != active) {
            self.leave_copy()?;
        }
        let Some((_, window)) = self.shown() else {
            self.close_view();
            return Ok(());
        };
        let window_id = window.id;
        let zoom = window.zoom;
        let geometry = geometry::window(window);
        if let Some(Drag {
            button,
            target: Target::Divider(grip, _),
        }) = self.drag
        {
            self.drag = geometry
                .dividers
                .iter()
                .find(|line| line.grip.first == grip.first && line.grip.second == grip.second)
                .and_then(|line| {
                    line.grip
                        .first_size(line.rect.x, line.rect.y)
                        .map(|size| Drag {
                            button,
                            target: Target::Divider(line.grip, size),
                        })
                });
        }
        let resized = self.view.as_ref().is_some_and(|shown| {
            shown.panes.iter().any(|pane| {
                pane.mirror.copy().is_some() && {
                    let size = |geometry: &geometry::Geometry| {
                        geometry
                            .panes
                            .iter()
                            .find(|placement| placement.pane == pane.pane)
                            .map(|placement| (placement.rect.cols, placement.rect.rows))
                    };
                    size(&shown.geometry) != size(&geometry)
                }
            })
        });
        if resized {
            self.leave_copy()?;
        }
        if let Some(zoom) = zoom
            && self.reconnecting.is_none()
            && self.pending_selection.is_none()
            && self.pane() != Some(zoom)
        {
            self.select(zoom)?;
        }
        let mut changed = false;
        if self
            .view
            .as_ref()
            .is_some_and(|shown| shown.window != window_id)
        {
            self.close_view();
            changed = true;
        }
        let shown = self.view.get_or_insert_with(|| {
            changed = true;
            Shown {
                window: window_id,
                panes: Vec::new(),
                geometry: Default::default(),
            }
        });
        changed |= shown.retain(&geometry, &mut self.poll);
        for placement in &geometry.panes {
            if shown.pane_mut(placement.pane).is_none() {
                let mirror = Mirror::open(
                    &self.socket,
                    self.model.client,
                    placement.pane,
                    self.model.limits,
                    &mut self.poll,
                )?;
                shown.panes.push(ShownPane {
                    pane: placement.pane,
                    mirror,
                    frame: Frame::default(),
                    serial: None,
                    death: None,
                });
                changed = true;
            }
        }
        if *shown.geometry != geometry {
            shown.geometry = std::rc::Rc::new(geometry);
        }
        self.model.observe(
            &shown
                .geometry
                .panes
                .iter()
                .map(|pane| pane.pane)
                .collect::<Vec<_>>(),
            true,
        );
        self.immediate |= changed;
        Ok(())
    }

    fn track(&mut self) {
        self.last
            .panes
            .retain(|window, _| self.model.layout.layout.window(*window).is_some());
        let Some(pane) = self.pane() else {
            return;
        };
        let Some((session, window)) = self.model.locate(pane) else {
            return;
        };
        if let Some((was_session, was_window, was_pane)) = self.last.at {
            if was_session != session {
                self.last.session = Some(was_session);
                self.last.window = None;
            } else if was_window != window {
                self.last.window = Some(was_window);
            }
            if was_window == window && was_pane != pane {
                self.last.panes.insert(window, was_pane);
            }
        }
        self.last.at = Some((session, window, pane));
    }

    fn create_pane(&mut self) -> Result<(), String> {
        let pane = ko_client::layout::add_session(
            &self.socket,
            (Some(self.model.client), None),
            &new_pane(here(self.remote.is_some()), None),
        )?;
        self.switch(pane)
    }

    fn show_first(&mut self) -> Result<(), String> {
        if self.pane().is_some() {
            return self.sync_views();
        }
        match self.model.order().first().copied() {
            None => self.create_pane(),
            Some(pane) => self.switch(pane),
        }
    }

    fn new_window(&mut self) -> Result<(), String> {
        let Some((source, place)) = self
            .pane()
            .and_then(|pane| Some((pane, self.model.locate(pane)?)))
        else {
            return self.create_pane();
        };
        let runtime = self.row(source).and_then(|row| row.runtime.clone());
        let pane = ko_client::layout::add_window(
            &self.socket,
            (Some(self.model.client), None),
            place,
            &new_pane(Some(Cwd::Pane { pane: source }), runtime),
        )?;
        self.switch(pane)
    }

    fn close_view(&mut self) {
        self.drag = None;
        if matches!(self.keys.mode(), KeyMode::Resize) {
            self.keys.leave();
        }
        if let Some(shown) = self.view.take() {
            for pane in shown.panes {
                pane.mirror.close(&mut self.poll);
            }
        }
    }

    fn kill(&mut self, kill: Kill) -> Result<(), String> {
        let Some(pane) = self.pane() else {
            return Ok(());
        };
        let route = match (kill, self.shown()) {
            (Kill::Pane, _) => Route::DeletePane { id: pane },
            (Kill::Window, Some((_, window))) => Route::DeleteWindow { id: window.id },
            (Kill::Window, None) => return Ok(()),
        };
        self.close_view();
        self.request(&route).map(drop)
    }

    fn rename(&mut self, of: Rename, text: String) -> Result<(), String> {
        let (Ok(name), Some((session, window))) = (Name::try_from(text), self.shown()) else {
            return Ok(());
        };
        let edit = match of {
            Rename::Session => Edit::RenameSession {
                session: session.id,
                name,
            },
            Rename::Window => Edit::RenameWindow {
                window: window.id,
                name,
            },
        };
        self.edit(edit).map(drop)
    }

    fn pager(&mut self) -> Result<(), String> {
        let Some(pane) = self.pane().filter(|_| self.pager.is_none()) else {
            return Ok(());
        };
        let dir = std::env::var_os("TMPDIR")
            .filter(|dir| !dir.is_empty())
            .map_or_else(|| PathBuf::from("/tmp"), PathBuf::from);
        let mut stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.subsec_nanos() ^ std::process::id());
        let mut attempts = 0;
        let (path, mut file) = loop {
            let path = dir.join(format!("ko-scrollback-{:06x}.txt", stamp & 0xff_ffff));
            match OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&path)
            {
                Ok(file) => break (path, file),
                Err(error)
                    if error.kind() == std::io::ErrorKind::AlreadyExists && attempts < 1000 =>
                {
                    attempts += 1;
                    stamp = stamp.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                }
                Err(error) => return Err(text(error)),
            }
        };
        let route = Route::Screen {
            id: pane,
            format: ScreenFormat::Ansi,
            history: ScreenRows::Full,
        };
        let started = wire::download(&self.socket, self.model.client, &route, &mut file)
            .and_then(|()| file.flush().map_err(text))
            .and_then(|()| self.launch(&path));
        match started {
            Ok(child) => {
                self.pager = Some(Running { child, path });
                Ok(())
            }
            Err(error) => {
                let _ = std::fs::remove_file(&path);
                Err(error)
            }
        }
    }

    fn launch(&mut self, path: &std::path::Path) -> Result<Child, String> {
        self.session.reset()?;
        self.session.write("\x1b[?1049l")?;
        self.session.tty.release();
        self.session.tty.flush_input();
        self.poll.interest(self.stdin, Interest::Idle);
        let spawned = std::process::Command::new("/bin/sh")
            .arg("-c")
            .arg(format!("exec {} \"$1\"", self.pager_command))
            .arg("ko-pager")
            .arg(path)
            .spawn();
        match spawned {
            Ok(child) => Ok(child),
            Err(error) => {
                self.resume()?;
                Err(text(error))
            }
        }
    }

    fn resume(&mut self) -> Result<(), String> {
        self.session.tty.acquire().map_err(text)?;
        self.session.tty.flush_input();
        self.session.write(ENTER)?;
        self.poll.interest(self.stdin, Interest::Read);
        self.renderer.invalidate();
        self.immediate = true;
        if let Some(pane) = self.active() {
            pane.mirror.bottom()?;
        }
        Ok(())
    }

    fn pager_ended(&mut self) -> Result<(), String> {
        let ended = match self.pager.as_mut() {
            Some(running) => running.child.try_wait().map_err(text)?.is_some(),
            None => false,
        };
        if ended {
            self.pager = None;
            self.resume()?;
            if let Some(outage) = self.reconnecting.as_mut() {
                outage.since = Instant::now();
                self.retry.set(&mut self.poll, Some(Instant::now()))?;
            }
        }
        Ok(())
    }

    fn leave_copy(&mut self) -> Result<(), String> {
        for pane in panes_mut(&mut self.view) {
            pane.mirror.thaw(&mut self.poll)?;
        }
        self.copy_click = None;
        if self.key_context() == Context::Copying {
            self.keys.leave();
        }
        self.immediate = true;
        Ok(())
    }

    fn copy_key(&mut self, key: &KeyEvent) -> Result<(), String> {
        let outcome = match self.active() {
            Some(pane) if pane.mirror.copy().is_some() => pane.mirror.copy_key(key)?,
            _ => return Ok(()),
        };
        if outcome == Outcome::Copy {
            let bytes = self
                .active()
                .map(|pane| pane.mirror.copy_text())
                .transpose()?
                .flatten();
            if let Some(bytes) = bytes {
                self.paste_buffer = String::from_utf8_lossy(&bytes).into_owned();
                self.session
                    .write(&ko_pane_wire::frame::ClipboardLocation::Standard.osc52(&bytes))?;
            }
        }
        if outcome != Outcome::Stay {
            self.leave_copy()?;
        }
        Ok(())
    }

    fn key_context(&self) -> Context {
        if panes(&self.view)
            .any(|pane| Some(pane.pane) == self.pane() && pane.mirror.copy().is_some())
        {
            Context::Copying
        } else if self.dead().is_some() {
            Context::Dead
        } else {
            Context::Live
        }
    }

    fn paste(&mut self, text: String) -> Result<(), String> {
        let Some(pane) = self.pane() else {
            return Ok(());
        };
        self.input_send(
            pane,
            Wire::Paste(Paste {
                text,
                check_safe: false,
                id: None,
            }),
        )
    }

    fn key(&mut self, key: KeyEvent) -> Result<(), String> {
        self.immediate = true;
        if let Some(pane) = self.active() {
            pane.mirror.bottom()?;
        }
        match self.keys.feed(&key, self.key_context(), Instant::now()) {
            Step::Pane(key) => match input::key(&key) {
                Some(key) => match self.pane() {
                    Some(pane) => self.input_send(pane, Wire::Key(WireKey(key))),
                    None => Ok(()),
                },
                None => Ok(()),
            },
            Step::Act(action) => self.act(action),
            Step::Swallow => Ok(()),
        }
    }

    fn act(&mut self, action: Action) -> Result<(), String> {
        let selection = match action {
            Action::LastWindow => self
                .last
                .window
                .filter(|window| self.model.layout.layout.window(*window).is_some())
                .map(|window| Selection {
                    window: Some(window),
                    ..Selection::default()
                }),
            Action::LastSession => self
                .last
                .session
                .filter(|session| self.model.layout.layout.session(*session).is_some())
                .map(|session| Selection {
                    session: Some(session),
                    ..Selection::default()
                }),
            Action::Window(at) => usize::try_from(at)
                .ok()
                .zip(self.shown())
                .and_then(|(at, (session, _))| session.windows.get(at))
                .map(|window| Selection {
                    window: Some(window.id),
                    ..Selection::default()
                }),
            other => return self.command(other),
        };
        match selection {
            Some(selection) => {
                self.navigate(None, |request| ClientRequest::Select { request, selection })
            }
            None => Ok(()),
        }
    }

    fn command(&mut self, action: Action) -> Result<(), String> {
        match action {
            Action::Detach => self.quit = true,
            Action::Redraw => self.redraw()?,
            Action::ToggleSidebar => {
                self.panel = match self.panel {
                    Panel::Hidden => Panel::Visible,
                    Panel::Visible => Panel::Hidden,
                };
                if self.panel == Panel::Hidden
                    && matches!(
                        self.keys.mode(),
                        KeyMode::Sidebar(_) | KeyMode::SidebarResize(_)
                    )
                {
                    self.keys.leave();
                }
                self.resize()?;
            }
            Action::ResizeSidebar(edge, amount) => {
                let amount = amount.cells();
                let width = if edge == Edge::Left {
                    self.sidebar_width.saturating_sub(amount)
                } else {
                    self.sidebar_width.saturating_add(amount)
                };
                self.set_sidebar_width(width)?;
            }
            Action::LeaveSidebar => self.keys.leave(),
            Action::Chooser => {
                if let Some(pane) = self.pane() {
                    self.leave_copy()?;
                    self.keys.leave();
                    self.keys.choose(pane);
                    if self.panel == Panel::Hidden {
                        self.panel = Panel::Visible;
                        self.resize()?;
                    }
                }
            }
            Action::Choose(direction) => {
                if let Some(chosen) = self.keys.cursor() {
                    let steps = direction_steps(direction);
                    if let Some(next) = self.model.step(Some(chosen), steps) {
                        self.keys.choose(next);
                    }
                }
            }
            Action::Select(pane) => {
                if self.model.order().contains(&pane) {
                    self.switch(pane)?;
                }
            }
            Action::EnterCopy(entry) => {
                self.keys.leave();
                if let Some(pane) = self.active() {
                    pane.mirror.freeze(entry)?;
                }
            }
            Action::CopyKey(key) => self.copy_key(&key)?,
            Action::LeaveCopy => self.leave_copy()?,
            Action::PasteBuffer => {
                if !self.paste_buffer.is_empty() {
                    self.paste(self.paste_buffer.clone())?;
                }
            }
            Action::Pager => self.pager()?,
            Action::NewWindow => self.new_window()?,
            Action::Kill(kill) => self.kill(kill)?,
            Action::Rename(of, text) => self.rename(of, text)?,
            Action::Switch(over, direction) => {
                self.navigate(None, |request| ClientRequest::Switch {
                    request,
                    switch: Switch { over, direction },
                })?;
            }
            Action::Pane(command) => self.pane_command(command)?,
            Action::LastSession | Action::LastWindow | Action::Window(_) => {}
        }
        Ok(())
    }

    fn pane_command(&mut self, command: PaneCommand) -> Result<(), String> {
        match command {
            PaneCommand::Select(command) => self.pane_select(command),
            PaneCommand::Edit(command) => self.pane_edit(command),
        }
    }

    fn pane_select(&mut self, command: PaneSelect) -> Result<(), String> {
        let Some(pane) = self.pane() else {
            return Ok(());
        };
        let cursor = self
            .active()
            .and_then(|active| active.frame.cursor)
            .map(|cursor| (usize::from(cursor.x), usize::from(cursor.y)))
            .unwrap_or((0, 0));
        let Some((_, window)) = self.shown() else {
            return Ok(());
        };
        if command == PaneSelect::Edge(Edge::Left)
            && self.panel == Panel::Visible
            && geometry::left_edge(window, pane)
        {
            self.leave_copy()?;
            self.keys.focus_sidebar(pane);
            return Ok(());
        }
        let target = match command {
            PaneSelect::Next => cycle(
                &window.panes(),
                Some(pane),
                direction_steps(Direction::Next),
            ),
            PaneSelect::Last => self.last.panes.get(&window.id).copied().filter(|id| {
                self.model
                    .locate(*id)
                    .is_some_and(|(_, id)| id == window.id)
            }),
            PaneSelect::Edge(edge) => geometry::neighbour(window, pane, edge, cursor),
        };
        if let Some(target) = target {
            if window.zoom.is_some_and(|zoom| zoom != target)
                && self
                    .edit(Edit::Zoom {
                        window: window.id,
                        pane: None,
                    })?
                    .is_none()
            {
                return Ok(());
            }
            self.select(target)?;
        }
        Ok(())
    }

    fn pane_edit(&mut self, command: PaneEdit) -> Result<(), String> {
        let Some(pane) = self.pane() else {
            return Ok(());
        };
        let Some((_, window)) = self.shown() else {
            return Ok(());
        };
        let edit = match command {
            PaneEdit::Split(axis) => {
                if window.zoom.is_some()
                    && self
                        .edit(Edit::Zoom {
                            window: window.id,
                            pane: None,
                        })?
                        .is_none()
                {
                    return Ok(());
                }
                let runtime = self.row(pane).and_then(|row| row.runtime.clone());
                Edit::Split {
                    pane,
                    axis,
                    before: false,
                    new: new_pane(Some(Cwd::Pane { pane }), runtime),
                }
            }
            PaneEdit::Zoom => Edit::ToggleZoom { pane },
            PaneEdit::Resize(edge, amount) => Edit::ResizeBy {
                pane,
                edge,
                delta: dim(amount.cells()).into(),
            },
            PaneEdit::Swap(direction) => {
                let Some(other) = cycle(&window.panes(), Some(pane), direction_steps(direction))
                    .filter(|other| *other != pane)
                else {
                    return Ok(());
                };
                Edit::Swap { pane, other }
            }
            PaneEdit::Equalize => Edit::Equalize { pane },
            PaneEdit::Break => Edit::BreakPane { pane },
            PaneEdit::Float => {
                if window.tree.contains(pane) {
                    Edit::Float {
                        pane,
                        x: None,
                        y: None,
                        cols: None,
                        rows: None,
                        z: None,
                        border: Some(true),
                        title: None,
                    }
                } else {
                    let Some(target) =
                        [Some(window.focus), self.last.panes.get(&window.id).copied()]
                            .into_iter()
                            .flatten()
                            .chain(window.panes())
                            .find(|id| window.tree.contains(*id))
                    else {
                        return Ok(());
                    };
                    Edit::Unfloat {
                        pane,
                        target,
                        edge: Edge::Right,
                    }
                }
            }
        };
        if let Some(edited) = self.edit(edit)? {
            match (command, edited.created) {
                (PaneEdit::Break, _) => self.select(pane)?,
                (_, Some(ko_client::layout::Created::Pane { pane })) => self.select(pane)?,
                _ => {}
            }
        }
        Ok(())
    }

    fn grab(&mut self, geometry: &geometry::Geometry, event: &input::MouseEvent, x: usize) -> bool {
        if let MouseKind::Down(button) = event.kind
            && let Some(grip) = geometry.divider(x, event.y)
            && let Some(size) = grip.first_size(x, event.y)
        {
            self.drag = Some(Drag {
                button,
                target: Target::Divider(grip, size),
            });
            self.mouse_down = None;
            return true;
        }
        false
    }

    fn drag(&mut self, event: &input::MouseEvent) -> Result<bool, String> {
        let Some(drag) = self.drag else {
            return Ok(false);
        };
        let button = drag.button;
        match event.kind {
            MouseKind::Down(_) => {
                self.drag = None;
                return Ok(false);
            }
            MouseKind::Up(_) | MouseKind::Move => self.drag = None,
            MouseKind::Drag(held) if held == button => match drag.target {
                Target::Sidebar => {
                    self.set_sidebar_width(event.x)?;
                }
                Target::Divider(grip, last) => {
                    let x = event
                        .x
                        .saturating_sub(self.panel.x(self.geometry.cols, self.sidebar_width));
                    if let Some(size) = grip.first_size(x, event.y)
                        && size != last
                    {
                        self.drag = Some(Drag {
                            button,
                            target: Target::Divider(grip, size),
                        });
                        self.edit(Edit::ResizePair {
                            first: grip.first,
                            second: grip.second,
                            first_size: size,
                        })?;
                    }
                }
            },
            MouseKind::Drag(_) => self.drag = None,
            MouseKind::Scroll { .. } => {}
        }
        Ok(true)
    }

    fn mouse(&mut self, mut event: input::MouseEvent) -> Result<(), String> {
        if self.drag(&event)? {
            return Ok(());
        }
        let layout = self.layout();
        let captured = match event.kind {
            MouseKind::Scroll { .. } | MouseKind::Down(_) => None,
            _ => self.mouse_down,
        };
        let placement = if let Some(pane) = captured {
            layout
                .geometry
                .panes
                .iter()
                .find(|placement| placement.pane == pane)
        } else {
            if event.x >= layout.cols || event.y >= layout.pane_rows {
                return Ok(());
            }
            if event.x < layout.pane_x {
                if event.x + 1 == layout.pane_x
                    && let MouseKind::Down(button) = event.kind
                {
                    self.drag = Some(Drag {
                        button,
                        target: Target::Sidebar,
                    });
                    self.mouse_down = None;
                    return Ok(());
                }
                if matches!(event.kind, MouseKind::Down(_))
                    && event.y < layout.tree_rows()
                    && event.x + 1 < layout.pane_x
                    && let Some(pane) = layout.sidebar.get(event.y).and_then(|line| line.pane)
                {
                    self.switch(pane)?;
                }
                return Ok(());
            }
            if self.grab(&layout.geometry, &event, event.x - layout.pane_x) {
                return Ok(());
            }
            layout
                .geometry
                .top(event.x - layout.pane_x, event.y)
                .filter(|placement| placement.rect.contains(event.x - layout.pane_x, event.y))
        };
        let Some(placement) = placement else {
            if captured.is_some() {
                self.mouse_down = None;
            }
            return Ok(());
        };
        let pane = placement.pane;
        let rect = placement.rect;
        let origin = (layout.pane_x + rect.x, rect.y);
        if matches!(event.kind, MouseKind::Down(_)) {
            if matches!(
                self.keys.mode(),
                KeyMode::Sidebar(_) | KeyMode::SidebarResize(_)
            ) {
                self.keys.leave();
            }
            self.mouse_down = Some(pane);
            if Some(pane) != self.pane() {
                self.switch(pane)?;
            }
        } else if matches!(event.kind, MouseKind::Up(_)) {
            self.mouse_down = None;
        }
        event.x = event
            .x
            .clamp(origin.0, origin.0 + rect.cols.saturating_sub(1));
        event.y = event
            .y
            .clamp(origin.1, origin.1 + rect.rows.saturating_sub(1));
        let clicks = if matches!(event.kind, MouseKind::Down(_)) {
            let click = Click::count(self.copy_click, pane, &event);
            self.copy_click = Some(click);
            click.count
        } else {
            1
        };
        let Some(shown) = self.view.as_mut().and_then(|shown| shown.pane_mut(pane)) else {
            return Ok(());
        };
        if shown.mirror.copy().is_some() {
            self.immediate = true;
            return shown.mirror.copy_mouse(
                event.kind,
                u16::try_from(event.x - origin.0).unwrap_or(u16::MAX),
                u32::try_from(event.y - origin.1).unwrap_or(u32::MAX),
                clicks,
            );
        }
        if shown.serial.is_some() && shown.frame.mouse != MouseTracking::Off {
            return self.input_send(pane, Wire::Mouse(WireMouse(input::mouse(origin, &event))));
        }
        if let MouseKind::Scroll { up } = event.kind {
            self.immediate = true;
            shown
                .mirror
                .scroll(&mut self.poll, if up { -3 } else { 3 })?;
        }
        Ok(())
    }

    fn event(&mut self, event: Event) -> Result<(), String> {
        if self.reconnecting.is_some() {
            match event {
                Event::Key(key) => {
                    let step = self.keys.feed(&key, self.key_context(), Instant::now());
                    if !matches!(self.keys.state(), State::Normal | State::Prefix) {
                        self.keys.end();
                    }
                    self.quit |= step == Step::Act(Action::Detach);
                }
                Event::Focus(focused) => self.focused = focused,
                _ => {}
            }
            return Ok(());
        }
        match event {
            Event::Key(key) => self.key(key),
            Event::Mouse(mouse) => self.mouse(mouse),
            Event::Paste(body) => {
                if self.key_context() == Context::Copying {
                    if let Some(pane) = self.active() {
                        pane.mirror.copy_paste(&body);
                    }
                    self.immediate = true;
                    return Ok(());
                }
                self.immediate = true;
                match self.keys.paste(body) {
                    Some(text) => self.paste(text),
                    None => Ok(()),
                }
            }
            Event::Focus(focused) => {
                if !focused {
                    self.drag = None;
                }
                self.focused = focused;
                self.client_send(&ClientRequest::Focused { focused })
            }
            Event::Reply(Reply::Clipboard(location, text)) => {
                match self.clipboard_reads.answered(location.into(), text) {
                    Some((id, contents)) => self.clipboard_answer(id, contents),
                    None => Ok(()),
                }
            }
            Event::Reply(_) => Ok(()),
        }
    }

    fn notice(&mut self, notice: Notice) -> Result<(), String> {
        match notice {
            Notice::ClipboardWrite {
                location, contents, ..
            } => match clipboard::write(location, &contents) {
                Some(sequence) if self.pager.is_none() => self.session.write(&sequence),
                _ => Ok(()),
            },
            Notice::ClipboardRead {
                id,
                location,
                mimes,
                list,
                ..
            } if self.pager.is_none() => {
                if clipboard::answerable(&mimes, list) {
                    let query = self.clipboard_reads.ask(id, location);
                    self.session.write(&query)
                } else {
                    self.clipboard_answer(id, None)
                }
            }
            Notice::ClipboardRead { .. } | Notice::Bell(_) | Notice::Notify { .. } => Ok(()),
        }
    }

    fn clipboard_answer(
        &mut self,
        id: u64,
        contents: Option<Vec<ClipboardContent>>,
    ) -> Result<(), String> {
        let served = contents.map(|contents| ClipboardServed {
            contents,
            available: Vec::new(),
        });
        self.client_send(&ClientRequest::ClipboardAnswer { id, served })
    }

    fn tick(&mut self) -> Result<(), String> {
        self.track();
        let now = Instant::now();
        let hold = panes(&self.view)
            .filter_map(|pane| pane.mirror.hold_expiry())
            .min();
        let repaint = self
            .last_paint
            .map(|at| at + PACE)
            .filter(|at| !self.immediate && *at > now);
        let at = [repaint, hold].into_iter().flatten().min();
        self.wake.set(&mut self.poll, at)
    }

    fn paint(&mut self) -> Result<(), String> {
        let now = Instant::now();
        if self.pager.is_some()
            || (!self.immediate && self.last_paint.is_some_and(|at| now < at + PACE))
        {
            return Ok(());
        }
        let mut fresh = false;
        for pane in panes_mut(&mut self.view) {
            let death = pane.mirror.dead().and_then(|_| {
                self.model
                    .panes
                    .iter()
                    .find(|row| row.row.id == pane.pane)
                    .and_then(|pane| pane.row.dead.as_ref())
            });
            if pane.death.as_ref().map(|(dead, _)| dead) != death {
                pane.death = death.map(|dead| (dead.clone(), sidebar::dead_line(dead)));
            }
            if pane.mirror.frame(&mut pane.frame)? {
                self.serial += 1;
                pane.serial = Some(self.serial);
                fresh = true;
            }
        }
        let layout = self.layout();
        let shown: Vec<_> = panes(&self.view)
            .filter_map(|pane| {
                Some(PaneFrame {
                    pane: pane.pane,
                    serial: pane.serial?,
                    frame: &pane.frame,
                    dead: pane
                        .death
                        .as_ref()
                        .filter(|_| pane.mirror.copy().is_none())
                        .map(|(_, line)| line.as_str()),
                })
            })
            .collect();
        self.output.clear();
        if self
            .renderer
            .paint(&mut self.session.modes, &layout, &shown, &mut self.output)
        {
            self.last_paint = Some(now);
        }
        self.session.write(&self.output)?;
        if fresh {
            self.immediate = false;
        }
        Ok(())
    }

    fn winch(&mut self) -> Result<(), String> {
        let size = self.session.tty.size();
        if size != self.geometry {
            self.leave_copy()?;
            self.geometry = size;
            self.sidebar_width = sidebar::width(self.sidebar_width, size.cols);
            self.resize()?;
            self.immediate = true;
        }
        Ok(())
    }

    fn turn(&mut self, events: &mut Events) -> Result<(), String> {
        self.escape.set(&mut self.poll, self.input.deadline())?;
        self.repeat.set(&mut self.poll, self.keys.deadline())?;
        if self.reconnecting.is_none() {
            let at = panes(&self.view)
                .filter_map(|pane| pane.mirror.deadline(WATCHDOG))
                .fold(self.link.received() + WATCHDOG, Instant::min);
            self.watchdog.set(&mut self.poll, Some(at))?;
        }
        let mode = if panes(&self.view).any(|pane| pane.mirror.searching()) {
            Mode::Peek
        } else {
            Mode::Wait
        };
        self.poll.turn(mode, events).map_err(text)?;
        let now = Instant::now();
        self.link.begin_turn();
        for pane in panes_mut(&mut self.view) {
            pane.mirror.begin_turn();
        }
        let ready: Vec<Ready> = events
            .ready()
            .iter()
            .map(|ready| self.poll.wants(*ready))
            .collect();
        let mut incoming = Vec::new();
        let mut resized = false;
        let mut cause = None;
        for ready in ready {
            if ready.token == self.signal_token && ready.read {
                resized |= self.signal()?;
            } else if ready.token == self.stdin && ready.read {
                self.read(&mut incoming, now)?;
            } else if ready.token == self.link_token {
                if self.reconnecting.is_none()
                    && let Err(error) = self.client(ready, now)
                {
                    cause = Some(error);
                }
            } else if self.reconnecting.is_none() {
                for pane in panes_mut(&mut self.view) {
                    if Some(ready.token) == pane.mirror.token()
                        && let Err(error) = pane.mirror.handle(&mut self.poll, ready, now)
                        && let Err(error) = pane.mirror.reopen(
                            error,
                            &self.socket,
                            self.model.client,
                            pane.pane,
                            &mut self.poll,
                        )
                    {
                        cause = Some(error);
                    }
                }
            }
        }
        let due = events.due();
        if self.repeat.fired(&self.poll, due) {
            self.keys.expire(now);
        }
        if self.escape.fired(&self.poll, due) {
            self.input.expire(now, &mut incoming);
        }
        if self.watchdog.fired(&self.poll, due) && self.reconnecting.is_none() {
            if silent(self.link.received(), now, WATCHDOG) {
                cause = Some("ko socket timed out".to_owned());
            }
            for pane in panes_mut(&mut self.view) {
                if pane.mirror.deadline(WATCHDOG).is_some_and(|at| at <= now)
                    && let Err(error) = pane.mirror.reopen(
                        "pane view timed out".to_owned(),
                        &self.socket,
                        self.model.client,
                        pane.pane,
                        &mut self.poll,
                    )
                {
                    cause = Some(error);
                }
            }
        }
        self.wake.fired(&self.poll, due);
        let retry = self.retry.fired(&self.poll, due);
        if self.quit {
            return Ok(());
        }
        if let Some(cause) = cause {
            self.lost(cause)?;
        }
        if retry {
            self.attempt()?;
        }
        for event in coalesce_drag(incoming) {
            if self.quit {
                break;
            }
            self.event(event)?;
        }
        for pane in panes_mut(&mut self.view) {
            self.immediate |= pane.mirror.search_step()?;
        }
        if resized {
            self.winch()?;
        }
        Ok(())
    }

    fn signal(&mut self) -> Result<bool, String> {
        let mut pending = Vec::new();
        self.signals.take(&mut pending).map_err(text)?;
        let mut resized = false;
        for signal in pending {
            match signal {
                Signal::Winch => resized = true,
                Signal::Child => {
                    self.pager_ended()?;
                    if self.remote.as_mut().is_some_and(Remote::lost) {
                        self.lost("ssh ended".to_owned())?;
                    }
                    if self.reconnecting.is_some() {
                        self.retry.set(&mut self.poll, Some(Instant::now()))?;
                    }
                }
                _ => self.quit = true,
            }
        }
        Ok(resized)
    }

    fn recover(&mut self, error: String) -> Result<(), String> {
        if self.reconnecting.is_some() {
            return Err(error);
        }
        let probe = wire::request_within(
            &self.socket,
            (None, None),
            &Route::Version {},
            b"",
            (None, PROBE_TRANSPORT),
        );
        if probe.is_ok() {
            return Err(error);
        }
        self.lost(error)
    }

    fn lost(&mut self, cause: String) -> Result<(), String> {
        if self.reconnecting.is_some() {
            return Ok(());
        }
        if let Some(remote) = self.remote.as_mut() {
            remote.reconnect();
        }
        self.keys.leave();
        self.pending_selection = None;
        self.link.unwatch(&mut self.poll);
        for pane in panes_mut(&mut self.view) {
            pane.mirror.unwatch(&mut self.poll);
        }
        self.watchdog.set(&mut self.poll, None)?;
        self.reconnecting = Some(Reconnecting {
            since: Instant::now(),
            backoff: BACKOFF_FIRST,
            cause,
            restore: Restore::Reopen,
        });
        self.immediate = true;
        self.retry.set(&mut self.poll, Some(Instant::now()))
    }

    fn attempt(&mut self) -> Result<(), String> {
        let Some(outage) = self.reconnecting.as_ref() else {
            return Ok(());
        };
        let (restore, cause) = (outage.restore, outage.cause.clone());
        let deadline = outage.since + GIVE_UP;
        let left = GIVE_UP.saturating_sub(outage.since.elapsed());
        if left.is_zero() {
            let target = self.remote.as_ref().map_or("connection", Remote::host);
            return Err(format!("lost {target}: {cause}"));
        }
        if self.pager.is_some() {
            return self.retry.set(
                &mut self.poll,
                Some((Instant::now() + PAUSED).min(deadline)),
            );
        }
        let progress = match self.remote.as_mut() {
            Some(remote) => remote.advance(),
            None => Ok(Progress::Up),
        };
        let failure = match progress {
            Ok(Progress::Pending(until)) => {
                return self.retry.set(&mut self.poll, Some(until.min(deadline)));
            }
            Ok(Progress::Up) => match self.reconnect(left, restore) {
                Ok(()) => return Ok(()),
                Err(JoinError::Refused(message)) => return Err(message),
                Err(JoinError::Protocol(message)) => message,
            },
            Err(error) => error.to_string(),
        };
        let Some(outage) = self.reconnecting.as_mut() else {
            return Ok(());
        };
        let wait = outage.backoff;
        outage.backoff = backoff_after(wait);
        outage.cause = failure;
        self.retry
            .set(&mut self.poll, Some((Instant::now() + wait).min(deadline)))
    }

    fn reconnect(&mut self, left: Duration, mut restore: Restore) -> Result<(), JoinError> {
        let mut link = Link::connect_within(&self.socket, None, &Route::Client {}, None, left)
            .map_err(|error| JoinError::Protocol(text(error)))?;
        let mut hello = hello(self.geometry, self.panel, self.sidebar_width, self.focused);
        hello.selection = self.model.selection;
        let rejoin = self.model.rejoin(&mut link, hello)?;
        let token = link
            .watch(&mut self.poll)
            .map_err(|error| JoinError::Protocol(text(error)))?;
        self.link.unwatch(&mut self.poll);
        self.link = link;
        self.link_token = token;
        self.clipboard_reads.clear();
        match rejoin {
            Rejoin::Resume(joined) => self.model = joined,
            Rejoin::Fresh(joined) => {
                self.model = joined;
                restore = Restore::Show;
            }
        }
        if let Some(outage) = self.reconnecting.as_mut() {
            outage.restore = restore;
        }
        self.client(wire::buffered(token), Instant::now())
            .map_err(JoinError::Protocol)?;
        let outage = self.reconnecting.take();
        if let Err(error) = self.restore(restore).and_then(|()| self.resize()) {
            self.reconnecting = outage;
            return Err(JoinError::Protocol(error));
        }
        self.immediate = true;
        self.retry
            .set(&mut self.poll, None)
            .map_err(JoinError::Protocol)
    }

    fn restore(&mut self, restore: Restore) -> Result<(), String> {
        if restore == Restore::Show {
            self.close_view();
            return self.show_first();
        }
        let geometry = self
            .shown()
            .map(|(_, window)| (window.id, geometry::window(window)));
        match (&mut self.view, geometry) {
            (Some(shown), Some((window, geometry))) if shown.window == window => {
                shown.retain(&geometry, &mut self.poll);
            }
            _ => self.close_view(),
        }
        for pane in panes_mut(&mut self.view) {
            pane.mirror
                .relink(&self.socket, self.model.client, pane.pane, &mut self.poll)?;
        }
        self.sync_views()
    }

    fn read(&mut self, incoming: &mut Vec<Event>, now: Instant) -> Result<(), String> {
        let mut buffer = [0u8; 65536];
        match self.session.tty.read(&mut buffer).map_err(text)? {
            Some(0) => self.quit = true,
            Some(count) => self
                .input
                .feed(buffer.get(..count).unwrap_or_default(), now, incoming),
            None => {}
        }
        Ok(())
    }

    fn apply(&mut self, event: protocol::ClientEvent) -> Applied {
        let cursor = match self.keys.mode() {
            KeyMode::Sidebar(pane) | KeyMode::SidebarResize(pane) => Some((
                pane,
                self.model
                    .order()
                    .iter()
                    .position(|id| *id == pane)
                    .unwrap_or(0),
            )),
            _ => None,
        };
        let pending_pane = self
            .pending_selection
            .and_then(|pending| pending.pane)
            .filter(|pane| self.model.locate(*pane).is_some());
        let applied = self.model.apply(event);
        if pending_pane.is_some_and(|pane| self.model.locate(pane).is_none()) {
            self.pending_selection = None;
        }
        if let Some((pane, at)) = cursor
            && self.model.locate(pane).is_none()
        {
            let order = self.model.order();
            match order.get(at.min(order.len().saturating_sub(1))) {
                Some(pane) => self.keys.focus_sidebar(*pane),
                None => self.keys.leave(),
            }
        }
        applied
    }

    fn client(&mut self, ready: Ready, now: Instant) -> Result<(), String> {
        if ready.read {
            loop {
                match self.link.next(&mut self.poll, now).map_err(text)? {
                    Next::Wait => break,
                    Next::Shutdown => {
                        self.quit = true;
                        return Ok(());
                    }
                    Next::Closed | Next::Gone | Next::Binary(_) => {
                        return Err("server closed the client".to_owned());
                    }
                    Next::Text(event) => {
                        let event = protocol::decode(event.as_bytes()).map_err(text)?;
                        let resizing = (self.keys.mode() == KeyMode::Resize)
                            .then(|| {
                                self.pane().and_then(|pane| {
                                    self.model.locate(pane).map(|(_, window)| (pane, window))
                                })
                            })
                            .flatten();
                        let applied = self.apply(event);
                        if let Some((pane, window)) = resizing
                            && (self.model.locate(pane).map(|(_, id)| id) != Some(window)
                                || self.shown().map(|(_, shown)| shown.id) != Some(window))
                        {
                            self.keys.leave();
                        }
                        match applied {
                            Applied::Nothing | Applied::State => {}
                            Applied::Layout if self.reconnecting.is_none() => self.sync_views()?,
                            Applied::Layout => {}
                            Applied::Notice(notice) => self.notice(notice)?,
                            Applied::Selected(request) => {
                                self.resize()?;
                                if self
                                    .pending_selection
                                    .is_some_and(|pending| Some(pending.request) == request)
                                {
                                    self.pending_selection = None;
                                }
                                if !matches!(
                                    self.keys.state(),
                                    State::Normal | State::Prefix | State::Repeat { .. }
                                ) {
                                    self.keys.end();
                                }
                                if self.reconnecting.is_none() {
                                    self.sync_views()?;
                                }
                                if self.pane().is_none() && self.model.order().is_empty() {
                                    self.create_pane()?;
                                }
                            }
                        }
                    }
                }
            }
        }
        if ready.write {
            self.link.settle(&mut self.poll).map_err(text)?;
        }
        Ok(())
    }

    fn begin(&mut self) -> Result<(), String> {
        for event in coalesce_drag(std::mem::take(&mut self.pending)) {
            self.event(event)?;
        }
        Ok(())
    }

    fn run(&mut self) -> Result<(), String> {
        let mut events = Events::default();
        let mut first = true;
        while first || !self.quit {
            let stepped = if first {
                self.begin()
            } else {
                self.turn(&mut events)
            }
            .and_then(|()| self.tick())
            .and_then(|()| self.paint());
            first = false;
            if let Err(error) = stepped {
                self.recover(error)?;
            }
        }
        Ok(())
    }
}

fn coalesce_drag(events: Vec<Event>) -> Vec<Event> {
    let mut out = Vec::new();
    for event in events {
        if let Event::Mouse(input::MouseEvent {
            kind: MouseKind::Drag(button),
            ..
        }) = &event
            && let Some(Event::Mouse(input::MouseEvent {
                kind: MouseKind::Drag(previous),
                ..
            })) = out.last()
            && button == previous
        {
            out.pop();
        }
        out.push(event);
    }
    out
}

fn hello(geometry: Geometry, panel: Panel, width: usize, focused: bool) -> Hello {
    Hello {
        name: "ko".to_owned(),
        selection: Selection::default(),
        focused,
        sizing: protocol::Sizing::Windows {
            viewport: protocol::Size(pane_size(geometry, panel, width)),
            windows: protocol::WindowSizes::default(),
        },
    }
}

fn here(remote: bool) -> Option<Cwd> {
    if remote {
        return None;
    }
    let dir = std::env::current_dir().ok()?;
    AbsPath::try_from(dir.to_string_lossy().into_owned())
        .ok()
        .map(Cwd::Path)
}

fn new_pane(cwd: Option<Cwd>, runtime: Option<RuntimeName>) -> CreatePane {
    CreatePane {
        cwd,
        command: None,
        env: Vec::new(),
        vars: Default::default(),
        parent: None,
        close: Default::default(),
        runtime,
    }
}

fn pane_size(geometry: Geometry, panel: Panel, width: usize) -> Size {
    let Geometry {
        cols,
        rows,
        cell_px,
    } = geometry;
    Size {
        cols: dim(cols.saturating_sub(panel.x(cols, width))),
        rows: dim(rows.saturating_sub(STATUS_ROWS)),
        cell_px,
    }
}

fn serve(mut client: Client) -> Result<(), String> {
    let result = client.run();
    if let Some(mut running) = client.pager.take() {
        let _ = running.child.kill();
        let _ = running.child.wait();
    }
    result
}

fn mismatch(dir: &std::path::Path, host: Option<&str>) -> Option<String> {
    let (mismatch, server) =
        ko_client::api::version(&dir.join("socket"), wire::READ_TIMEOUT, None).ok()?;
    mismatch?;
    let own = protocol::version();
    let command = match host {
        Some(host) => format!("On {host}, run ko kill-server, then ko server"),
        None => format!(
            "Run ko kill-server --server '{}', then start again",
            dir.to_string_lossy().replace('\'', "'\"'\"'")
        ),
    };
    Some(format!(
        "The running server is a different version and must be restarted to upgrade. Server: protocol {}, terminal {}, build {}. Client: protocol {}, terminal {}, build {}. {command}. All sessions and panes will end.",
        server.protocol, server.vt, server.build, own.protocol, own.vt, own.build
    ))
}

pub fn run(dir: &std::path::Path, executable: &std::path::Path, pager: &str) -> Result<(), String> {
    let (socket, stream) = launch::attach(dir, executable, None, PATIENCE)?;
    let link = Link::upgrade(stream, None, &Route::Client {}, None)
        .map_err(|error| mismatch(dir, None).unwrap_or_else(|| error.to_string()))?;
    let signals = Signals::install(&SIGNALS).map_err(text)?;
    serve(Client::start(
        socket,
        link,
        pager.to_owned(),
        signals,
        None,
    )?)
}

pub fn run_remote(
    host: &str,
    ssh: &std::path::Path,
    state: &std::path::Path,
    pager: &str,
) -> Result<(), String> {
    let signals = Signals::install(&SIGNALS).map_err(text)?;
    let remote = Remote::open(host, ssh, state, &signals).map_err(text)?;
    let socket = remote.socket();
    let link = UnixStream::connect(&socket)
        .and_then(|stream| Link::upgrade(stream, None, &Route::Client {}, None))
        .map_err(|_| {
            mismatch(remote.dir(), Some(host)).unwrap_or_else(|| remote.unreachable().to_string())
        })?;
    serve(Client::start(
        socket,
        link,
        pager.to_owned(),
        signals,
        Some(remote),
    )?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn consecutive_drag_motions_keep_only_the_last_before_other_events() {
        let mut events = Vec::new();
        Input::default().feed(
            b"\x1b[<0;10;3M\x1b[<32;11;3M\x1b[<32;12;3Mx\x1b[<32;13;3M\x1b[<32;14;3M\x1b[<0;14;3m",
            Instant::now(),
            &mut events,
        );
        let expected = [0, 2, 3, 5, 6].map(|at| events[at].clone());
        assert_eq!(coalesce_drag(events), expected);
    }

    #[test]
    fn a_remote_attach_sends_no_cwd_because_the_local_one_may_not_exist_there() {
        assert_eq!(here(true), None);
        assert!(matches!(here(false), Some(Cwd::Path(_))));
    }
}
