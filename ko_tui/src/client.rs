use std::fs::OpenOptions;
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::Child;
use std::time::{Duration, Instant};

use crate::clipboard;
use ko_client::launch::{self, BACKOFF_FIRST, PATIENCE, backoff_after};
use ko_client::model::{Applied, Model, Notice, Rejoin};
use ko_client::remote::{Progress, Remote};
use ko_client::wire::{self, Link, Next, WATCHDOG, silent, text};
use ko_config::values::{AbsPath, RuntimeName};
use ko_pane_wire::frame::{Dim, ScreenFormat, ScreenRows, Size};
use ko_server::api::Route;
use ko_server::ids::PaneId;
use ko_server::protocol::{
    self, ClientKind, ClientRequest, ClipboardContent, ClipboardServed, CreatePane, Cwd, Hello,
    Input as Wire, Key as WireKey, Mouse as WireMouse, Paste, Selection, ViewRequest, json,
};
use ko_sys::event::{Due, Events, Interest, Mode, Poll, Ready, Timer, Token};
use ko_sys::signal::{Signal, Signals};
use ko_vt::render::{Frame, MouseTracking};

use crate::input::{self, Command, Event, Input, KeyEvent, Kind, MouseKind, Name, Reply};
use crate::mirror::Mirror;
use crate::modes::{self, Modes};
use crate::renderer::{Layout, Renderer};
use crate::sidebar;
use crate::tty::{Geometry, Tty};

const PACE: Duration = Duration::from_millis(8);
const PROBE: Duration = Duration::from_millis(500);
const ENTER: &str = "\x1b[?1049h\x1b[?25l";
const LEAVE: &str = "\x1b[?25h\x1b[0m\x1b[?1049l\x1b[?25h";
const WARNING_ROWS: usize = 1;
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
    Choosing(usize),
}

impl Panel {
    fn x(self, cols: usize) -> usize {
        match self {
            Panel::Hidden => 0,
            _ => sidebar::pane_x(cols),
        }
    }
}

#[derive(Debug)]
enum View {
    None,
    Showing {
        pane: PaneId,
        mirror: Box<Mirror>,
        frame: Frame,
        serial: Option<u64>,
    },
}

impl View {
    fn open(pane: PaneId, mirror: Mirror) -> View {
        View::Showing {
            pane,
            mirror: Box::new(mirror),
            frame: Frame::default(),
            serial: None,
        }
    }
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
    kitty: bool,
    events: Vec<Event>,
}

fn environment_kitty(found: bool) -> bool {
    let set = |name: &str| std::env::var_os(name).is_some_and(|value| !value.is_empty());
    let term_kitty = std::env::var("TERM").is_ok_and(|term| term.to_lowercase().contains("kitty"));
    let program_is = |value: &str| {
        std::env::var("TERM_PROGRAM").is_ok_and(|program| program.to_lowercase() == value)
    };
    if set("KITTY_WINDOW_ID") {
        true
    } else if program_is("vscode") || set("VHS_RECORD") {
        false
    } else {
        found || term_kitty || std::env::var_os("KITTY_WINDOW_ID").is_some()
    }
}

fn probe(
    session: &Session,
    poll: &mut Poll,
    stdin: Token,
    input: &mut Input,
) -> Result<Probed, String> {
    let queries = format!("{}\x1b[?u\x1b[>0q\x1b[c", modes::query());
    session.write(&queries)?;
    let deadline = Instant::now() + PROBE;
    let timer = poll.timer();
    let mut events = Events::default();
    let (mut reports, mut kitty, mut answered) = (Vec::new(), false, false);
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
                Event::Reply(Reply::Kitty) => kitty = true,
                Event::Reply(Reply::Xtversion(version)) => {
                    kitty |= version.to_lowercase().contains("kitty");
                }
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
        kitty: environment_kitty(kitty),
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

#[derive(Debug)]
struct Client {
    view: View,
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
    warning: bool,
    kitty: bool,
    geometry: Geometry,
    focused: bool,
    immediate: bool,
    last_paint: Option<Instant>,
    serial: u64,
    quit: bool,
    pending: Vec<Event>,
    clipboard_reads: clipboard::Pending,
    wake: Deadline,
    escape: Deadline,
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
        let warning = !probed.kitty;
        let panel = if warning || sidebar::visible(geometry.cols) {
            Panel::Visible
        } else {
            Panel::Hidden
        };
        let hello = hello(geometry, panel, warning, true);
        let model = Model::join(&mut link, hello)?;
        let link_token = link.watch(&mut poll).map_err(text)?;
        let (wake, escape, watchdog, retry) = (
            Deadline::new(&mut poll),
            Deadline::new(&mut poll),
            Deadline::new(&mut poll),
            Deadline::new(&mut poll),
        );
        let mut client = Client {
            view: View::None,
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
            warning,
            kitty: probed.kitty,
            geometry,
            focused: true,
            immediate: true,
            last_paint: None,
            serial: 0,
            quit: false,
            pending: probed.events,
            clipboard_reads: clipboard::Pending::default(),
            wake,
            escape,
            watchdog,
            retry,
            remote,
            reconnecting: None,
        };
        client.client(wire::buffered(client.link_token), Instant::now())?;
        client.show_first()?;
        Ok(client)
    }

    fn pane(&self) -> Option<PaneId> {
        match &self.view {
            View::None => None,
            View::Showing { pane, .. } => Some(*pane),
        }
    }

    fn dead(&self) -> Option<protocol::Dead> {
        let pane = self.pane()?;
        self.model
            .panes
            .iter()
            .find(|found| found.row.id == pane)
            .and_then(|found| found.row.dead.clone())
    }

    fn received(&self) -> Instant {
        match &self.view {
            View::Showing { mirror, .. } => mirror.received().max(self.link.received()),
            View::None => self.link.received(),
        }
    }

    fn leave_choosing(&mut self) {
        if let Panel::Choosing(_) = self.panel {
            self.panel = Panel::Visible;
        }
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
            pane_x: self.panel.x(cols),
            pane_rows: rows.saturating_sub(usize::from(self.warning) * WARNING_ROWS),
            warning: self.warning,
            dead: match (&self.view, &self.remote) {
                (_, Some(remote)) if self.reconnecting.is_some() => Some(format!(
                    "[reconnecting to {} \u{2014} Ctrl+Shift+Q to detach]",
                    remote.host()
                )),
                (
                    View::Showing {
                        mirror,
                        serial: Some(_),
                        ..
                    },
                    _,
                ) => mirror.dead().map(sidebar::dead_line),
                _ => None,
            },
            choosing: match self.panel {
                Panel::Choosing(chosen) => outline
                    .iter()
                    .enumerate()
                    .filter(|(_, item)| matches!(item, ko_client::model::Item::Pane { .. }))
                    .nth(chosen)
                    .map(|(row, _)| row),
                _ => None,
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

    fn view_send(&mut self, request: &ViewRequest) -> Result<(), String> {
        match &mut self.view {
            View::None => Ok(()),
            View::Showing { mirror, .. } => mirror.send(&mut self.poll, request),
        }
    }

    fn input_send(&mut self, input: Wire) -> Result<(), String> {
        self.view_send(&ViewRequest::Input { input })
    }

    fn resize(&mut self) -> Result<(), String> {
        let size = pane_size(self.geometry, self.panel, self.warning);
        self.client_send(&ClientRequest::Size(protocol::Size(size)))
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

    fn switch(&mut self, pane: PaneId) -> Result<(), String> {
        self.close_view();
        self.leave_choosing();
        self.session.reset()?;
        self.renderer.invalidate();
        self.client_send(&ClientRequest::Select(Selection {
            pane: Some(pane),
            ..Selection::default()
        }))?;
        let mirror = Mirror::open(
            &self.socket,
            self.model.client,
            pane,
            self.model.limits,
            &mut self.poll,
        )?;
        self.view = View::open(pane, mirror);
        self.model.observe(&[pane], true);
        self.immediate = true;
        Ok(())
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
        match self.model.order().first().copied() {
            None => self.create_pane(),
            Some(pane) => self.switch(pane),
        }
    }

    fn selected(&self) -> usize {
        self.model
            .order()
            .iter()
            .position(|id| Some(*id) == self.pane())
            .unwrap_or(0)
    }

    fn choose(&mut self, step: isize) -> Result<(), String> {
        match self.model.step(self.pane(), step) {
            Some(pane) => self.switch(pane),
            None => Ok(()),
        }
    }

    fn new_window(&mut self) -> Result<(), String> {
        let Some((source, place)) = self
            .pane()
            .and_then(|pane| Some((pane, self.model.locate(pane)?)))
        else {
            return self.create_pane();
        };
        let runtime = self
            .model
            .panes
            .iter()
            .find(|shown| shown.row.id == source)
            .and_then(|shown| shown.row.runtime.clone());
        let pane = ko_client::layout::add_window(
            &self.socket,
            (Some(self.model.client), None),
            place,
            &new_pane(Some(Cwd::Pane { pane: source }), runtime),
        )?;
        self.switch(pane)
    }

    fn close_view(&mut self) {
        if let View::Showing { mirror, .. } = std::mem::replace(&mut self.view, View::None) {
            mirror.close(&mut self.poll);
        }
    }

    fn remove(&mut self) -> Result<(), String> {
        let Some(pane) = self.pane() else {
            return Ok(());
        };
        self.close_view();
        self.request(&Route::DeletePane { id: pane }).map(drop)
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
        if let View::Showing { mirror, .. } = &mut self.view {
            mirror.bottom()?;
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

    fn key(&mut self, key: KeyEvent) -> Result<(), String> {
        self.immediate = true;
        if let View::Showing { mirror, .. } = &mut self.view {
            mirror.bottom()?;
        }
        let dead = self.dead().is_some();
        let effective = |event: &KeyEvent| match input::command(event) {
            Some(Command::Remove) if !dead => None,
            command => command,
        };
        let action = effective(&key);
        if self.warning && key.mods.ctrl() && key.mods.shift() {
            self.warning = false;
            if !matches!(action, Some(Command::ToggleSidebar | Command::Detach)) {
                self.resize()?;
            }
        }
        if key.kind == Kind::Release
            && (effective(&key.pressed()).is_some() || matches!(self.panel, Panel::Choosing(_)))
        {
            return Ok(());
        }
        match action {
            Some(Command::Detach) => self.quit = true,
            Some(Command::ToggleSidebar) => {
                self.panel = match self.panel {
                    Panel::Hidden => Panel::Choosing(self.selected()),
                    _ => Panel::Hidden,
                };
                self.resize()?;
            }
            Some(Command::Pager) => self.pager()?,
            Some(Command::New) => self.new_window()?,
            Some(Command::Remove) => self.remove()?,
            Some(Command::Previous) => self.choose(-1)?,
            Some(Command::Next) => self.choose(1)?,
            None => self.plain(&key)?,
        }
        Ok(())
    }

    fn plain(&mut self, key: &KeyEvent) -> Result<(), String> {
        match (self.panel, key.name) {
            (Panel::Choosing(chosen), Name::Up | Name::Down) => {
                let count = self.model.order().len();
                if count > 0 {
                    let step = if key.name == Name::Up { count - 1 } else { 1 };
                    self.panel = Panel::Choosing((chosen + step) % count);
                }
                Ok(())
            }
            (Panel::Choosing(chosen), Name::Enter) => match self.model.order().get(chosen).copied()
            {
                Some(pane) => self.switch(pane),
                None => Ok(()),
            },
            (Panel::Choosing(_), Name::Escape) => {
                self.panel = Panel::Visible;
                Ok(())
            }
            _ => {
                self.leave_choosing();
                match input::key(key) {
                    Some(key) => self.input_send(Wire::Key(WireKey(key))),
                    None => Ok(()),
                }
            }
        }
    }

    fn mouse(&mut self, event: input::MouseEvent) -> Result<(), String> {
        let layout = self.layout();
        if event.x >= layout.cols || event.y >= layout.pane_rows {
            return Ok(());
        }
        if event.x < layout.pane_x {
            if matches!(event.kind, MouseKind::Down(_))
                && event.x + 1 < layout.pane_x
                && let Some(pane) = layout.sidebar.get(event.y).and_then(|line| line.pane)
            {
                self.switch(pane)?;
            }
            return Ok(());
        }
        let tracking = match &self.view {
            View::Showing {
                frame,
                serial: Some(_),
                ..
            } => frame.mouse,
            _ => return Ok(()),
        };
        if tracking != MouseTracking::Off {
            let mouse = WireMouse(input::mouse(layout.pane_x, &event));
            return self.input_send(Wire::Mouse(mouse));
        }
        if let MouseKind::Scroll { up } = event.kind {
            self.immediate = true;
            if let View::Showing { mirror, .. } = &mut self.view {
                mirror.scroll(&mut self.poll, if up { -3 } else { 3 })?;
            }
        }
        Ok(())
    }

    fn event(&mut self, event: Event) -> Result<(), String> {
        if self.reconnecting.is_some() {
            match event {
                Event::Key(key)
                    if key.kind != Kind::Release
                        && matches!(input::command(&key), Some(Command::Detach)) =>
                {
                    self.quit = true;
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
                self.immediate = true;
                self.input_send(Wire::Paste(Paste {
                    text: body,
                    check_safe: false,
                    id: None,
                }))
            }
            Event::Focus(focused) => {
                self.focused = focused;
                self.client_send(&ClientRequest::Focused { focused })
            }
            Event::Reply(Reply::Kitty) => {
                self.kitty = true;
                Ok(())
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
        if self.warning && self.kitty {
            self.warning = false;
            self.panel = if sidebar::visible(self.geometry.cols) {
                Panel::Visible
            } else {
                Panel::Hidden
            };
            self.resize()?;
        }
        let now = Instant::now();
        let hold = match &self.view {
            View::None => None,
            View::Showing { mirror, .. } => mirror.hold_expiry(),
        };
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
        if let View::Showing {
            mirror,
            frame,
            serial,
            ..
        } = &mut self.view
            && mirror.frame(frame)?
        {
            self.serial += 1;
            *serial = Some(self.serial);
            fresh = true;
        }
        let layout = self.layout();
        let shown = match &self.view {
            View::Showing {
                frame,
                serial: Some(serial),
                ..
            } => Some((*serial, frame)),
            _ => None,
        };
        self.output.clear();
        if self
            .renderer
            .paint(&mut self.session.modes, &layout, shown, &mut self.output)
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
            self.geometry = size;
            self.resize()?;
            self.immediate = true;
        }
        Ok(())
    }

    fn turn(&mut self, events: &mut Events) -> Result<(), String> {
        self.escape.set(&mut self.poll, self.input.deadline())?;
        if self.reconnecting.is_none() && self.watchdog.at.is_none() {
            let at = self.received() + WATCHDOG;
            self.watchdog.set(&mut self.poll, Some(at))?;
        }
        self.poll.turn(Mode::Wait, events).map_err(text)?;
        let now = Instant::now();
        self.link.begin_turn();
        if let View::Showing { mirror, .. } = &mut self.view {
            mirror.begin_turn();
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
                    cause = Some(self.recoverable(error)?);
                }
            } else if let View::Showing { mirror, .. } = &mut self.view
                && ready.token == mirror.token()
                && self.reconnecting.is_none()
                && let Err(error) = mirror.handle(&mut self.poll, ready, now)
            {
                cause = Some(self.recoverable(error)?);
            }
        }
        let due = events.due();
        if self.escape.fired(&self.poll, due) {
            self.input.expire(now, &mut incoming);
        }
        if self.watchdog.fired(&self.poll, due)
            && self.reconnecting.is_none()
            && silent(self.received(), now, WATCHDOG)
        {
            cause = Some(self.recoverable("ko socket timed out".to_owned())?);
        }
        self.wake.fired(&self.poll, due);
        let retry = self.retry.fired(&self.poll, due);
        if let Some(cause) = cause {
            self.lost(cause)?;
        }
        if retry {
            self.attempt()?;
        }
        for event in incoming {
            if self.quit {
                break;
            }
            self.event(event)?;
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

    fn recoverable(&self, error: String) -> Result<String, String> {
        if self.remote.is_some() {
            Ok(error)
        } else {
            Err(error)
        }
    }

    fn recover(&mut self, error: String) -> Result<(), String> {
        if self.remote.is_none() || self.reconnecting.is_some() {
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
        if self.remote.is_none() {
            return Err(cause);
        }
        if self.reconnecting.is_some() {
            return Ok(());
        }
        self.link.unwatch(&mut self.poll);
        if let View::Showing { mirror, .. } = &mut self.view {
            mirror.unwatch(&mut self.poll);
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
        if self.pager.is_some() {
            return self
                .retry
                .set(&mut self.poll, Some(Instant::now() + PAUSED));
        }
        let (restore, cause) = (outage.restore, outage.cause.clone());
        let left = GIVE_UP.saturating_sub(outage.since.elapsed());
        let Some(remote) = self.remote.as_mut() else {
            return Ok(());
        };
        if left.is_zero() {
            return Err(format!("lost {}: {cause}", remote.host()));
        }
        let failure = match remote.advance() {
            Ok(Progress::Pending(until)) => {
                return self.retry.set(&mut self.poll, Some(until));
            }
            Ok(Progress::Up) => match self.reconnect(left, restore) {
                Ok(()) => return Ok(()),
                Err(error) => error,
            },
            Err(error) => error.to_string(),
        };
        let Some(outage) = self.reconnecting.as_mut() else {
            return Ok(());
        };
        let wait = outage.backoff;
        outage.backoff = backoff_after(wait);
        outage.cause = failure;
        self.retry.set(&mut self.poll, Some(Instant::now() + wait))
    }

    fn reconnect(&mut self, left: Duration, mut restore: Restore) -> Result<(), String> {
        let mut link = Link::connect_within(&self.socket, None, &Route::Client {}, None, left)
            .map_err(text)?;
        let hello = hello(self.geometry, self.panel, self.warning, self.focused);
        let rejoin = self.model.rejoin(&mut link, hello)?;
        let token = link.watch(&mut self.poll).map_err(text)?;
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
        self.client(wire::buffered(token), Instant::now())?;
        let outage = self.reconnecting.take();
        if let Err(error) = self.restore(restore) {
            self.reconnecting = outage;
            return Err(error);
        }
        self.immediate = true;
        self.retry.set(&mut self.poll, None)
    }

    fn restore(&mut self, restore: Restore) -> Result<(), String> {
        let Some(pane) = self.pane().filter(|_| restore == Restore::Reopen) else {
            return self.show_first();
        };
        if !self.model.order().contains(&pane) {
            return self.show_first();
        }
        self.client_send(&ClientRequest::Select(Selection {
            pane: Some(pane),
            ..Selection::default()
        }))?;
        match &mut self.view {
            View::Showing { mirror, .. } if mirror.resume().is_some() => {
                mirror.relink(&self.socket, self.model.client, pane, &mut self.poll)?;
                self.model.observe(&[pane], true);
                Ok(())
            }
            _ => self.switch(pane),
        }
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

    fn client(&mut self, ready: Ready, now: Instant) -> Result<(), String> {
        if ready.write {
            self.link.settle(&mut self.poll).map_err(text)?;
        }
        if ready.read {
            loop {
                match self.link.next(&mut self.poll, now).map_err(text)? {
                    Next::Wait => break,
                    Next::Closed | Next::Binary(_) => {
                        return Err("server closed the client".to_owned());
                    }
                    Next::Text(event) => {
                        let event = protocol::decode(event.as_bytes()).map_err(text)?;
                        let applied = self.model.apply(event);
                        self.model.observe(self.pane().as_slice(), true);
                        match applied {
                            Applied::Nothing | Applied::State | Applied::Layout => {}
                            Applied::Notice(notice) => self.notice(notice)?,
                            Applied::Selected => match self.model.selection.pane {
                                Some(pane) if Some(pane) != self.pane() => self.switch(pane)?,
                                Some(_) => {}
                                None => {
                                    self.close_view();
                                    if self.model.order().is_empty() {
                                        self.create_pane()?;
                                    }
                                }
                            },
                        }
                    }
                }
            }
        }
        Ok(())
    }

    fn begin(&mut self) -> Result<(), String> {
        for event in std::mem::take(&mut self.pending) {
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

fn hello(geometry: Geometry, panel: Panel, warning: bool, focused: bool) -> Hello {
    Hello {
        kind: ClientKind::Terminal,
        name: "ko".to_owned(),
        selection: Selection::default(),
        focused,
        size: protocol::Size(pane_size(geometry, panel, warning)),
        ignore_size: false,
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

fn pane_size(geometry: Geometry, panel: Panel, warning: bool) -> Size {
    let Geometry {
        cols,
        rows,
        cell_px,
    } = geometry;
    Size {
        cols: dim(cols.saturating_sub(panel.x(cols))),
        rows: dim(rows.saturating_sub(usize::from(warning) * WARNING_ROWS)),
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

pub fn run(dir: &std::path::Path, executable: &std::path::Path, pager: &str) -> Result<(), String> {
    let (socket, stream) = launch::attach(dir, executable, PATIENCE)?;
    let link = Link::upgrade(stream, None, &Route::Client {}, None).map_err(text)?;
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
        .map_err(|_| remote.unreachable().to_string())?;
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
    fn a_remote_attach_sends_no_cwd_because_the_local_one_may_not_exist_there() {
        assert_eq!(here(true), None);
        assert!(matches!(here(false), Some(Cwd::Path(_))));
    }
}
