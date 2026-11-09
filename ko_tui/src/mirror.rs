use std::path::Path;
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use ko_client::wire::{self, Connecting, Link, Next, Resume, UpgradeStep, text};
use ko_pane_wire::frame::{History, Limits};
use ko_pane_wire::ring::Slice;
use ko_server::api::{Offset, Route};
use ko_server::ids::{ClientId, PaneId};
use ko_server::protocol::{self, Images, Marker, ViewEvent, ViewOptions, ViewRequest, json};
use ko_server::ws::{BadRecord, Parsed, parse_record};
use ko_sys::clock::Mono;
use ko_sys::event::{Poll, Ready, Token};
use ko_vt::compress::{Compress, Tick};
use ko_vt::render::Frame;
use ko_vt::search::{Progress, SearchId};
use ko_vt::{Extent, ReadyScan, Shape as SelectionShape, Span, Terminal};
use tungstenite::Bytes;

use crate::copy::{self, Entry, Outcome, Row};
use crate::input::{KeyEvent, MouseKind};
use ko_pane_wire::frame::Cell;

const OPTIONS: ViewOptions = ViewOptions {
    history: History::All,
    images: Images::None,
};
const BURST: Duration = Duration::from_millis(1);
const YIELD: Duration = Duration::from_micros(500);
const SEARCH_SLICE: Duration = Duration::from_millis(2);

#[derive(Debug)]
struct Screen {
    vt: Terminal,
    compress: Compress,
}

impl Screen {
    fn new(mut vt: Terminal) -> Result<Screen, ko_vt::Error> {
        vt.watch()?;
        Ok(Screen {
            vt,
            compress: Compress::new(Mono::now()),
        })
    }
}

#[derive(Debug, Default)]
enum Surface {
    #[default]
    Empty,
    Full(Screen),
    Partial(Screen),
    Loading(Screen, isize),
}

impl Surface {
    fn screen(&self) -> Option<&Screen> {
        match self {
            Surface::Empty => None,
            Surface::Full(screen) | Surface::Partial(screen) | Surface::Loading(screen, _) => {
                Some(screen)
            }
        }
    }

    fn screen_mut(&mut self) -> Option<&mut Screen> {
        match self {
            Surface::Empty => None,
            Surface::Full(screen) | Surface::Partial(screen) | Surface::Loading(screen, _) => {
                Some(screen)
            }
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Drawn {
    Fresh,
    Output(u64),
    Held(u64),
}

#[derive(Debug)]
struct State {
    surface: Surface,
    generation: u64,
    drawn: Drawn,
    closed: bool,
    settled: bool,
    searching: bool,
}

impl State {
    fn scroll_bottom(&mut self) -> Result<bool, ko_vt::Error> {
        let moved = match self.surface.screen_mut() {
            Some(screen) => screen.vt.bottom()?,
            None => false,
        };
        Ok(match &mut self.surface {
            Surface::Loading(_, delta) => std::mem::take(delta) != 0 || moved,
            _ => moved,
        })
    }
}

#[derive(Debug)]
struct Shared {
    state: Mutex<State>,
    wake: Condvar,
}

impl Shared {
    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

fn compress_loop(shared: &Shared) {
    let mut state = shared.lock();
    while !state.closed {
        let searching = state.searching;
        let tick = state
            .surface
            .screen_mut()
            .filter(|_| !searching)
            .map(|screen| {
                let began = Instant::now();
                loop {
                    let tick = screen.compress.tick(&mut screen.vt, Mono::now());
                    if tick != Tick::Now || began.elapsed() >= BURST {
                        break tick;
                    }
                }
            });
        let wait = match tick {
            None | Some(Tick::Settled) => None,
            Some(Tick::Now) => Some(YIELD),
            Some(Tick::After(wait)) => Some(wait),
        };
        state.settled = wait.is_none();
        state = match wait {
            None => shared
                .wake
                .wait(state)
                .unwrap_or_else(PoisonError::into_inner),
            Some(wait) => {
                shared
                    .wake
                    .wait_timeout(state, wait)
                    .unwrap_or_else(PoisonError::into_inner)
                    .0
            }
        };
        state.settled = false;
    }
}

#[derive(Debug)]
enum Following {
    Bytes(Bytes),
    Marker(Marker),
}

#[derive(Debug)]
enum Shape {
    Screen,
    Full { ready: Option<ReadyScan> },
}

#[derive(Debug)]
struct Assembly {
    end: u64,
    buffer: Vec<u8>,
    kind: Shape,
    following: Vec<Following>,
}

fn apply(vt: &mut Terminal, marker: &Marker) -> Result<(), ko_vt::Error> {
    match marker {
        Marker::Resize(size) => vt.resize(size.0),
        Marker::Dead { .. } => Ok(()),
    }
}

#[derive(Debug)]
struct Frozen {
    copy: copy::Mode,
    dirty: bool,
    search: Option<SearchId>,
}

fn copy_row(vt: &Terminal, cols: u16, row: u32) -> Result<Row, String> {
    let bytes = vt
        .text_between(Span {
            start: Cell { col: 0, row },
            end: Cell {
                col: cols.saturating_sub(1),
                row,
            },
            shape: SelectionShape::Rectangle,
        })
        .map_err(text)?;
    let wraps = vt.row_wraps(row).map_err(text)?;
    Ok(Row {
        text: String::from_utf8_lossy(&bytes).into_owned(),
        wraps,
    })
}

#[derive(Debug)]
enum Connection {
    Connecting {
        link: Connecting,
        token: Token,
        started: Instant,
    },
    Open {
        link: Box<Link>,
    },
    Closed,
}

#[derive(Debug)]
pub(crate) struct Mirror {
    connection: Connection,
    shared: Arc<Shared>,
    compressor: Option<JoinHandle<()>>,
    limits: Limits,
    assembly: Option<Assembly>,
    dead: Option<u64>,
    resume: Resume,
    frozen: Option<Frozen>,
    awaiting_snapshot: bool,
}

impl Mirror {
    fn connect(
        socket: &Path,
        client: ClientId,
        pane: PaneId,
        resume: Option<u64>,
        poll: &mut Poll,
    ) -> Result<Connection, String> {
        let route = Route::View {
            id: pane,
            history: OPTIONS.history,
            images: OPTIONS.images,
            offset: resume.and_then(Offset::new),
        };
        let link = Connecting::start(socket, client, &route, None).map_err(text)?;
        let token = link.watch(poll);
        Ok(Connection::Connecting {
            link,
            token,
            started: Instant::now(),
        })
    }

    pub(crate) fn open(
        socket: &Path,
        client: ClientId,
        pane: PaneId,
        limits: Limits,
        poll: &mut Poll,
    ) -> Result<Mirror, String> {
        let connection = Mirror::connect(socket, client, pane, None, poll)?;
        Ok(Mirror::with_connection(connection, limits))
    }

    fn with_connection(connection: Connection, limits: Limits) -> Mirror {
        let shared = Arc::new(Shared {
            state: Mutex::new(State {
                surface: Surface::Empty,
                generation: 0,
                drawn: Drawn::Fresh,
                closed: false,
                settled: true,
                searching: false,
            }),
            wake: Condvar::new(),
        });
        let thread = Arc::clone(&shared);
        Mirror {
            connection,
            shared,
            compressor: Some(std::thread::spawn(move || compress_loop(&thread))),
            limits,
            assembly: None,
            dead: None,
            resume: Resume::default(),
            frozen: None,
            awaiting_snapshot: false,
        }
    }

    pub(crate) fn dead(&self) -> Option<u64> {
        self.dead
    }

    pub(crate) fn token(&self) -> Option<Token> {
        match &self.connection {
            Connection::Connecting { token, .. } => Some(*token),
            Connection::Open { link } => link.token(),
            Connection::Closed => None,
        }
    }

    pub(crate) fn deadline(&self, silence: Duration) -> Option<Instant> {
        match &self.connection {
            Connection::Connecting { started, .. } => Some(*started + wire::READ_TIMEOUT),
            Connection::Open { link, .. } => Some(link.received() + silence),
            Connection::Closed => None,
        }
    }

    pub(crate) fn begin_turn(&mut self) {
        if let Connection::Open { link, .. } = &mut self.connection {
            link.begin_turn();
        }
    }

    fn wake(&self, state: MutexGuard<'_, State>) {
        let mut state = state;
        let notify = std::mem::take(&mut state.settled);
        drop(state);
        if notify {
            self.shared.wake.notify_one();
        }
    }

    fn update<T>(&self, change: impl FnOnce(&mut State) -> T) -> T {
        let mut state = self.shared.lock();
        let result = change(&mut state);
        state.generation += 1;
        self.wake(state);
        result
    }

    pub(crate) fn input(
        &mut self,
        poll: &mut Poll,
        input: protocol::Input,
    ) -> Result<Option<protocol::Input>, String> {
        let Connection::Open { link } = &mut self.connection else {
            return Ok(Some(input));
        };
        link.send(json(&ViewRequest::Input { input }))
            .map_err(text)?;
        link.settle(poll).map_err(text)?;
        Ok(None)
    }

    pub(crate) fn handle(
        &mut self,
        poll: &mut Poll,
        mut ready: Ready,
        now: Instant,
    ) -> Result<(), String> {
        let connection = std::mem::replace(&mut self.connection, Connection::Closed);
        self.connection = match connection {
            Connection::Connecting {
                link,
                token,
                started,
            } => match link.advance(poll, ready) {
                Ok(UpgradeStep::Pending(link)) => {
                    self.connection = Connection::Connecting {
                        link,
                        token,
                        started,
                    };
                    return Ok(());
                }
                Ok(UpgradeStep::Open(mut link)) => {
                    if self.awaiting_snapshot
                        && let Err(error) = link
                            .send(json(&ViewRequest::Resync(OPTIONS)))
                            .and_then(|()| link.settle(poll))
                    {
                        poll.unwatch(token);
                        return Err(text(error));
                    }
                    ready = wire::buffered(token);
                    Connection::Open { link }
                }
                Ok(UpgradeStep::Refused(response)) => {
                    poll.unwatch(token);
                    if response.status == 404 {
                        return Ok(());
                    }
                    return Err(text(ko_server::ws::refused(&response)));
                }
                Err(error) => {
                    poll.unwatch(token);
                    return Err(text(error));
                }
            },
            other => other,
        };
        if let Connection::Open { link } = &mut self.connection
            && ready.write
        {
            link.settle(poll).map_err(text)?;
        }
        if !ready.read {
            return Ok(());
        }
        let shared = Arc::clone(&self.shared);
        let mut state = shared.lock();
        let mut changed = false;
        while let Connection::Open { link } = &mut self.connection {
            let next = link.next(poll, now).map_err(text)?;
            match next {
                Next::Gone => {
                    if let Connection::Open { link } = &mut self.connection {
                        link.unwatch(poll);
                    }
                    self.connection = Connection::Closed;
                    break;
                }
                Next::Wait => break,
                Next::Shutdown | Next::Closed => return Err("pane view closed".to_owned()),
                Next::Text(event) => self.marker(&mut state, &event)?,
                Next::Binary(record) => self.record(&mut state, &record)?,
            }
            changed = true;
        }
        if changed {
            state.generation += 1;
        }
        self.wake(state);
        Ok(())
    }

    fn note(&mut self, marker: &Marker) {
        if let Marker::Dead { at } = marker {
            self.dead = Some(*at);
        }
    }

    fn marker(&mut self, state: &mut State, event: &str) -> Result<(), String> {
        if let Some(frozen) = &mut self.frozen {
            frozen.dirty = true;
            return Ok(());
        }
        if self.awaiting_snapshot {
            return Ok(());
        }
        let ViewEvent::Marked(marked) = protocol::decode(event.as_bytes()).map_err(text)? else {
            return Ok(());
        };
        if let Some(assembly) = self.assembly.as_mut() {
            assembly.following.push(Following::Marker(marked.marker));
            return Ok(());
        }
        self.note(&marked.marker);
        match &mut state.surface {
            Surface::Full(screen) => apply(&mut screen.vt, &marked.marker).map_err(text),
            _ => Ok(()),
        }
    }

    fn record(&mut self, state: &mut State, record: &Bytes) -> Result<(), String> {
        if let Some(frozen) = &mut self.frozen {
            frozen.dirty = true;
            return Ok(());
        }
        let parsed = parse_record(record);
        if self.awaiting_snapshot {
            match &parsed {
                Ok(Parsed::Snapshot { slice, .. })
                    if Slice::decode(slice).is_some_and(|(slice, _)| slice.first) =>
                {
                    self.awaiting_snapshot = false
                }
                Ok(_) => return Ok(()),
                Err(_) => {}
            }
        }
        match parsed {
            Ok(Parsed::Output { offset, data }) => self.output(state, record, offset, data),
            Ok(Parsed::Snapshot { offset, slice }) => self.snapshot(state, offset, &slice),
            Err(BadRecord::Short) => Err("short record".to_owned()),
            Err(BadRecord::Kind(_)) => Err("invalid record kind".to_owned()),
            Err(BadRecord::Inflate) => Err("corrupt snapshot slice".to_owned()),
        }
    }

    fn output(
        &mut self,
        state: &mut State,
        record: &Bytes,
        offset: u64,
        data: &[u8],
    ) -> Result<(), String> {
        state.scroll_bottom().map_err(text)?;
        let end = offset.saturating_add(data.len() as u64);
        if let Some(assembly) = self.assembly.as_mut() {
            let start = record.len().saturating_sub(data.len());
            assembly
                .following
                .push(Following::Bytes(record.slice(start..)));
            assembly.end = end;
        } else if let Some(screen) = state.surface.screen_mut() {
            screen.vt.write(data);
            self.resume.advance(end);
        }
        Ok(())
    }

    fn snapshot(&mut self, state: &mut State, offset: u64, data: &[u8]) -> Result<(), String> {
        let (slice, body) = Slice::decode(data).ok_or("short snapshot slice")?;
        let (first, last) = (slice.first, slice.last);
        let images = self.limits.kitty_images_max_bytes;
        if first {
            self.resume.clear();
            self.assembly = Some(Assembly {
                end: offset,
                buffer: Vec::new(),
                kind: if !slice.screen {
                    Shape::Full {
                        ready: Some(ReadyScan::new()),
                    }
                } else {
                    Shape::Screen
                },
                following: Vec::new(),
            });
        }
        let assembly = self
            .assembly
            .as_mut()
            .ok_or("snapshot missing first slice")?;
        assembly.buffer.extend_from_slice(body);
        if let Shape::Full { ready } = &mut assembly.kind
            && ready.as_mut().is_some_and(|scan| scan.feed(body))
        {
            *ready = None;
            let early = Terminal::decode_limited(&mut &assembly.buffer[..], Extent::Screen, images)
                .and_then(Screen::new)
                .map_err(text)?;
            let pending = match &state.surface {
                Surface::Loading(_, delta) => *delta,
                _ => 0,
            };
            state.surface = Surface::Loading(early, pending);
            state.drawn = Drawn::Fresh;
        }
        if last {
            self.finish(state)?;
        }
        Ok(())
    }

    fn finish(&mut self, state: &mut State) -> Result<(), String> {
        let Some(assembly) = self.assembly.take() else {
            return Ok(());
        };
        let full = matches!(assembly.kind, Shape::Full { .. });
        if full {
            self.resume.at(assembly.end);
        }
        let extent = if full { Extent::Full } else { Extent::Screen };
        let mut vt = Terminal::decode_limited(
            &mut &assembly.buffer[..],
            extent,
            self.limits.kitty_images_max_bytes,
        )
        .map_err(text)?;
        vt.configure(self.limits).map_err(text)?;
        let mut screen = Screen::new(vt).map_err(text)?;
        for next in assembly.following {
            if let Following::Marker(marker) = &next {
                self.note(marker);
            }
            match next {
                Following::Marker(marker) if full => {
                    apply(&mut screen.vt, &marker).map_err(text)?;
                }
                Following::Marker(_) => {}
                Following::Bytes(bytes) => {
                    screen.vt.bottom().map_err(text)?;
                    screen.vt.write(&bytes);
                }
            }
        }
        let loading = match &state.surface {
            Surface::Loading(_, delta) => Some(*delta),
            _ => None,
        };
        state.surface = match (full, loading) {
            (true, Some(delta)) => {
                screen.vt.scroll(delta);
                Surface::Full(screen)
            }
            (true, None) => Surface::Full(screen),
            (false, Some(delta)) => Surface::Loading(screen, delta),
            (false, None) => Surface::Partial(screen),
        };
        state.drawn = Drawn::Fresh;
        Ok(())
    }

    pub(crate) fn copy(&self) -> Option<&copy::Mode> {
        self.frozen.as_ref().map(|frozen| &frozen.copy)
    }

    pub(crate) fn freeze(&mut self, entry: Entry) -> Result<bool, String> {
        if self.assembly.is_some() || self.awaiting_snapshot {
            return Ok(false);
        }
        let mut state = self.shared.lock();
        let Surface::Full(screen) = &mut state.surface else {
            return Ok(false);
        };
        if screen.vt.hold().is_some() {
            return Ok(false);
        }
        let size = screen.vt.size();
        let size = (size.cols.get(), size.rows.get());
        let total = u32::try_from(screen.vt.total_rows().map_err(text)?).map_err(text)?;
        let offset = u32::try_from(screen.vt.viewport_offset().map_err(text)?).map_err(text)?;
        let copy = copy::Mode::open(
            screen.vt.cursor().map_err(text)?,
            total,
            offset,
            size,
            entry,
            |row| copy_row(&screen.vt, size.0, row),
        )?;
        if copy.offset() != offset {
            screen.vt.scroll_to(copy.offset()).map_err(text)?;
            state.generation += 1;
            state.drawn = Drawn::Fresh;
        }
        self.frozen = Some(Frozen {
            copy,
            dirty: false,
            search: None,
        });
        Ok(true)
    }

    pub(crate) fn copy_key(&mut self, key: &KeyEvent) -> Result<Outcome, String> {
        self.copy_change(|copy, vt, cols| {
            copy.feed(
                key,
                |row| copy_row(vt, cols, row),
                |row| vt.row_wraps(row).map_err(text),
            )
        })
    }

    pub(crate) fn copy_paste(&mut self, text: &str) {
        if let Some(frozen) = &mut self.frozen {
            frozen.copy.paste(text);
        }
    }

    pub(crate) fn searching(&self) -> bool {
        self.frozen
            .as_ref()
            .is_some_and(|frozen| frozen.search.is_some())
    }

    pub(crate) fn search_step(&mut self) -> Result<bool, String> {
        let Some(frozen) = &mut self.frozen else {
            return Ok(false);
        };
        let Some(search) = frozen.search else {
            return Ok(false);
        };
        let mut state = self.shared.lock();
        let screen = state
            .surface
            .screen_mut()
            .ok_or("copy screen is not ready")?;
        let began = Instant::now();
        let matches = loop {
            match screen.vt.search_step(search, 64) {
                Ok(Progress::Complete) => break screen.vt.search_matches(search).map_err(text),
                Ok(_) => {}
                Err(error) => break Err(text(error)),
            }
            if began.elapsed() >= SEARCH_SLICE {
                return Ok(false);
            }
        };
        screen.vt.search_end(search);
        frozen.search = None;
        drop(state);
        let matches = matches?;
        self.copy_change(|copy, vt, _| {
            copy.search_done(matches, |row| vt.row_wraps(row).map_err(text))
        })?;
        Ok(true)
    }

    pub(crate) fn copy_mouse(
        &mut self,
        kind: MouseKind,
        col: u16,
        row: u32,
        clicks: u8,
    ) -> Result<(), String> {
        if matches!(kind, MouseKind::Up(_) | MouseKind::Move) {
            return Ok(());
        }
        self.copy_change(|copy, vt, cols| {
            copy.mouse(
                kind,
                Cell { col, row },
                clicks,
                |row| copy_row(vt, cols, row),
                |row| vt.row_wraps(row).map_err(text),
            )
        })
    }

    fn copy_change<T>(
        &mut self,
        change: impl FnOnce(&mut copy::Mode, &Terminal, u16) -> Result<T, String>,
    ) -> Result<T, String> {
        let frozen = self.frozen.as_mut().ok_or("copy mode is not active")?;
        let mut state = self.shared.lock();
        let screen = state
            .surface
            .screen_mut()
            .ok_or("copy screen is not ready")?;
        let offset = frozen.copy.offset();
        let cols = frozen.copy.size().0;
        let result = change(&mut frozen.copy, &screen.vt, cols)?;
        match (frozen.copy.search_state(), frozen.search.is_some()) {
            (copy::SearchState::Searching(_, needle), false) => {
                match screen.vt.search(needle.as_bytes()) {
                    Ok(search) => frozen.search = Some(search),
                    Err(error) => {
                        frozen.copy.search_failed();
                        return Err(text(error));
                    }
                }
            }
            (copy::SearchState::Searching(..), true) => {}
            (_, true) => {
                if let Some(search) = frozen.search.take() {
                    screen.vt.search_end(search);
                }
            }
            (_, false) => {}
        }
        if frozen.copy.offset() != offset {
            screen.vt.scroll_to(frozen.copy.offset()).map_err(text)?;
            state.generation += 1;
            state.drawn = Drawn::Fresh;
        }
        let searching = frozen.search.is_some();
        if state.searching && !searching {
            self.shared.wake.notify_one();
        }
        state.searching = searching;
        Ok(result)
    }

    pub(crate) fn copy_text(&self) -> Result<Option<Vec<u8>>, String> {
        let Some(span) = self.copy().and_then(copy::Mode::range) else {
            return Ok(None);
        };
        let state = self.shared.lock();
        let screen = state.surface.screen().ok_or("copy screen is not ready")?;
        screen.vt.text_between(span).map(Some).map_err(text)
    }

    fn unfreeze(&mut self) -> Option<Frozen> {
        let mut frozen = self.frozen.take();
        let mut state = self.shared.lock();
        if let Some(search) = frozen.as_mut().and_then(|frozen| frozen.search.take())
            && let Some(screen) = state.surface.screen_mut()
        {
            screen.vt.search_end(search);
        }
        state.searching = false;
        drop(state);
        self.shared.wake.notify_one();
        frozen
    }

    pub(crate) fn thaw(&mut self, poll: &mut Poll) -> Result<(), String> {
        if let Some(frozen) = self.unfreeze() {
            self.bottom()?;
            if frozen.dirty {
                self.resync(poll)?;
            }
        }
        Ok(())
    }

    fn resync(&mut self, poll: &mut Poll) -> Result<(), String> {
        self.resume.clear();
        self.assembly = None;
        self.awaiting_snapshot = true;
        if let Connection::Open { link } = &mut self.connection {
            link.send(json(&ViewRequest::Resync(OPTIONS)))
                .map_err(text)?;
            link.settle(poll).map_err(text)?;
        }
        Ok(())
    }

    pub(crate) fn bottom(&mut self) -> Result<(), String> {
        if self.frozen.is_some() {
            return Ok(());
        }
        let mut state = self.shared.lock();
        if state.scroll_bottom().map_err(text)? {
            state.generation += 1;
        }
        Ok(())
    }

    pub(crate) fn scroll(&mut self, poll: &mut Poll, delta: isize) -> Result<(), String> {
        let resync = self.update(|state| match std::mem::take(&mut state.surface) {
            Surface::Empty => false,
            Surface::Full(mut screen) => {
                screen.vt.scroll(delta);
                state.surface = Surface::Full(screen);
                false
            }
            Surface::Partial(screen) => {
                state.surface = Surface::Loading(screen, delta);
                true
            }
            Surface::Loading(screen, pending) => {
                state.surface = Surface::Loading(screen, pending + delta);
                false
            }
        });
        if resync {
            self.resync(poll)?;
        }
        Ok(())
    }

    pub(crate) fn hold_expiry(&self) -> Option<Instant> {
        let state = self.shared.lock();
        let (_, expires) = state.surface.screen()?.vt.hold()?;
        Some(expires)
    }

    pub(crate) fn frame(&self, into: &mut Frame) -> Result<bool, String> {
        let mut state = self.shared.lock();
        let (generation, drawn) = (state.generation, state.drawn);
        let Some(screen) = state.surface.screen_mut() else {
            return Ok(false);
        };
        let next = match screen.vt.hold() {
            Some((id, _)) => Drawn::Held(id),
            None => Drawn::Output(generation),
        };
        if drawn == next {
            return Ok(false);
        }
        screen.vt.render_into(into).map_err(text)?;
        state.drawn = next;
        Ok(true)
    }

    pub(crate) fn close(mut self, poll: &mut Poll) {
        self.unwatch(poll);
    }

    pub(crate) fn unwatch(&mut self, poll: &mut Poll) {
        if self.unfreeze().is_some() {
            self.resume.clear();
        }
        match &mut self.connection {
            Connection::Open { link, .. } => link.unwatch(poll),
            Connection::Connecting { token, .. } => poll.unwatch(*token),
            Connection::Closed => {}
        }
        self.connection = Connection::Closed;
    }

    pub(crate) fn reopen(
        &mut self,
        cause: String,
        socket: &Path,
        client: ClientId,
        pane: PaneId,
        poll: &mut Poll,
    ) -> Result<(), String> {
        match self.connection {
            Connection::Open { .. } => self.relink(socket, client, pane, poll),
            Connection::Connecting { .. } | Connection::Closed => Err(cause),
        }
    }

    pub(crate) fn relink(
        &mut self,
        socket: &Path,
        client: ClientId,
        pane: PaneId,
        poll: &mut Poll,
    ) -> Result<(), String> {
        self.unwatch(poll);
        self.assembly = None;
        self.connection = Mirror::connect(socket, client, pane, self.resume.offset(), poll)?;
        Ok(())
    }
}

impl Drop for Mirror {
    fn drop(&mut self) {
        self.shared.lock().closed = true;
        self.shared.wake.notify_all();
        if let Some(thread) = self.compressor.take() {
            let _ = thread.join();
        }
    }
}

#[cfg(test)]
mod tests {
    use std::os::unix::net::UnixStream;

    use ko_pane_wire::frame::Dim;
    use ko_server::config::default_limits;

    use super::*;

    fn with(mut link: Link, limits: Limits, poll: &mut Poll) -> Result<Mirror, String> {
        let token = link.watch(poll).map_err(text)?;
        let mut mirror = Mirror::with_connection(
            Connection::Open {
                link: Box::new(link),
            },
            limits,
        );
        mirror.handle(poll, wire::buffered(token), Instant::now())?;
        Ok(mirror)
    }

    fn mirror() -> (Mirror, UnixStream, Poll) {
        let (ours, theirs) = UnixStream::pair().unwrap();
        let mut poll = Poll::new();
        let mirror = with(Link::of(ours, Vec::new()), default_limits(), &mut poll).unwrap();
        (mirror, theirs, poll)
    }

    #[test]
    fn a_pending_view_upgrade_does_not_block_client_pongs() {
        use std::io::Write;
        use std::os::unix::net::UnixListener;
        use tungstenite::protocol::Role;
        let path = std::env::temp_dir().join(format!(
            "ko-upgrade-{}-{}",
            std::process::id(),
            Mono::now().nanos()
        ));
        let listener = UnixListener::bind(&path).unwrap();
        let mut poll = Poll::new();
        let client = "client_1".parse().unwrap();
        let pane = "pane_1".parse().unwrap();
        let mut mirror = Mirror::open(&path, client, pane, default_limits(), &mut poll).unwrap();
        let (mut held, _) = listener.accept().unwrap();
        std::fs::remove_file(&path).unwrap();
        let token = mirror.token().unwrap();
        mirror
            .handle(
                &mut poll,
                Ready {
                    token,
                    read: true,
                    write: true,
                },
                Instant::now(),
            )
            .unwrap();
        assert!(matches!(mirror.connection, Connection::Connecting { .. }));
        let (ours, mut server) = UnixStream::pair().unwrap();
        server
            .set_read_timeout(Some(Duration::from_secs(1)))
            .unwrap();
        let mut link = Link::of(ours, Vec::new());
        link.watch(&mut poll).unwrap();
        server.write_all(b"\x89\x04ping").unwrap();
        assert_eq!(link.next(&mut poll, Instant::now()).unwrap(), Next::Wait);
        let mut peer = tungstenite::WebSocket::from_raw_socket(server, Role::Server, None);
        assert_eq!(
            peer.read().unwrap(),
            tungstenite::Message::Pong(b"ping".to_vec().into())
        );
        held.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
            .unwrap();
        mirror
            .handle(&mut poll, wire::buffered(token), Instant::now())
            .unwrap();
        assert_eq!(mirror.token(), None);
        assert_eq!(mirror.deadline(Duration::from_secs(60)), None);
        mirror.close(&mut poll);
        drop(held);
    }

    #[test]
    fn a_recoverable_view_close_can_resume_and_render_new_output() {
        use std::os::unix::net::UnixListener;
        let (mut mirror, mut peer, mut poll) = mirror();
        let snapshot = slices(
            &server(16, 2, "before").snapshot_bytes(false).unwrap(),
            4096,
        );
        for mut record in snapshot {
            record[1..9].copy_from_slice(&40_u64.to_le_bytes());
            feed(&mut mirror, &record).unwrap();
        }
        peer.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
        use std::io::Write;
        peer.write_all(b"\x88\x04\x03\xf0io").unwrap();
        mirror.begin_turn();
        let token = mirror.token().unwrap();
        assert_eq!(
            mirror
                .handle(&mut poll, wire::buffered(token), Instant::now())
                .unwrap_err(),
            "pane view closed"
        );
        let path = std::env::temp_dir().join(format!(
            "ko-reopen-{}-{}",
            std::process::id(),
            Mono::now().nanos()
        ));
        let listener = UnixListener::bind(&path).unwrap();
        mirror
            .relink(
                &path,
                "client_1".parse().unwrap(),
                "pane_1".parse().unwrap(),
                &mut poll,
            )
            .unwrap();
        let (mut stream, _) = listener.accept().unwrap();
        std::fs::remove_file(&path).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(1)))
            .unwrap();
        let token = mirror.token().unwrap();
        mirror
            .handle(
                &mut poll,
                Ready {
                    token,
                    read: true,
                    write: true,
                },
                Instant::now(),
            )
            .unwrap();
        use std::io::Read;
        let mut head = Vec::new();
        while !head.ends_with(b"\r\n\r\n") {
            assert!(head.len() < 16384);
            let mut byte = [0];
            stream.read_exact(&mut byte).unwrap();
            head.push(byte[0]);
        }
        let head = String::from_utf8(head).unwrap();
        assert_eq!(
            head.lines().next(),
            Some("GET /panes/pane_1/view?history=all&offset=40 HTTP/1.1")
        );
        let key = head
            .lines()
            .filter_map(|line| line.split_once(':'))
            .find(|(name, _)| name.eq_ignore_ascii_case("sec-websocket-key"))
            .unwrap()
            .1
            .trim();
        let accept = tungstenite::handshake::derive_accept_key(key.as_bytes());
        write!(stream, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n").unwrap();
        let mut peer = tungstenite::WebSocket::from_raw_socket(
            stream,
            tungstenite::protocol::Role::Server,
            None,
        );
        let mut bytes = output(b"-after");
        bytes[1..9].copy_from_slice(&40_u64.to_le_bytes());
        peer.send(tungstenite::Message::Binary(bytes.into()))
            .unwrap();
        mirror
            .handle(&mut poll, wire::buffered(token), Instant::now())
            .unwrap();
        assert_eq!(row(&mirror, 0), "before-after");
        mirror.close(&mut poll);
    }

    #[test]
    fn a_gone_view_keeps_its_display_but_has_no_watchdog_deadline() {
        use std::io::Write;
        let (mut mirror, mut server, mut poll) = mirror();
        assert!(mirror.deadline(Duration::from_secs(40)).is_some());
        server
            .write_all(&[0x88, 6, 3, 0xf0, b'g', b'o', b'n', b'e'])
            .unwrap();
        mirror.begin_turn();
        mirror
            .handle(
                &mut poll,
                wire::buffered(mirror.token().unwrap()),
                Instant::now(),
            )
            .unwrap();
        assert_eq!(mirror.deadline(Duration::from_secs(40)), None);
    }

    fn server(cols: u16, rows: u16, text: &str) -> Terminal {
        let (cols, rows) = (Dim::new(cols).unwrap(), Dim::new(rows).unwrap());
        let mut vt = Terminal::new(cols, rows, default_limits()).unwrap();
        vt.write(text.as_bytes());
        vt
    }

    fn slices(bytes: &[u8], size: usize) -> Vec<Vec<u8>> {
        let chunks: Vec<&[u8]> = bytes.chunks(size).collect();
        chunks
            .iter()
            .enumerate()
            .map(|(i, chunk)| {
                let header = ko_pane_wire::ring::Slice {
                    first: i == 0,
                    last: i + 1 == chunks.len(),
                    screen: false,
                }
                .encode();
                [
                    &[2][..],
                    &[0; 8],
                    &header,
                    &miniz_oxide::deflate::compress_to_vec(chunk, 1),
                ]
                .concat()
            })
            .collect()
    }

    fn output(bytes: &[u8]) -> Vec<u8> {
        [&[1][..], &[0; 8], bytes].concat()
    }

    fn feed(mirror: &mut Mirror, record: &[u8]) -> Result<(), String> {
        let shared = Arc::clone(&mirror.shared);
        let mut state = shared.lock();
        mirror.record(&mut state, &Bytes::copy_from_slice(record))
    }

    fn marked(mirror: &mut Mirror, event: &str) {
        let shared = Arc::clone(&mirror.shared);
        mirror.marker(&mut shared.lock(), event).unwrap();
    }

    fn row(mirror: &Mirror, row: usize) -> String {
        let mut frame = Frame::default();
        mirror.shared.lock().drawn = Drawn::Fresh;
        assert!(mirror.frame(&mut frame).unwrap());
        let cols = usize::from(frame.cols);
        frame.cells[row * cols..(row + 1) * cols]
            .iter()
            .map(|cell| {
                if cell.text.is_empty() {
                    " "
                } else {
                    &cell.text
                }
            })
            .collect::<String>()
            .trim_end()
            .to_owned()
    }

    fn kind(mirror: &Mirror) -> &'static str {
        match mirror.shared.lock().surface {
            Surface::Empty => "empty",
            Surface::Full(_) => "full",
            Surface::Partial(_) => "partial",
            Surface::Loading(..) => "loading",
        }
    }

    #[test]
    fn copy_row_stops_before_a_wrapped_wide_character() {
        let vt = server(8, 3, "1234567界tail");
        assert_eq!(copy_row(&vt, 8, 0).unwrap().text, "1234567");
        let mut mode = copy::Mode::open(
            ko_vt::Cursor {
                x: 7,
                y: 0,
                visible: true,
                pending_wrap: false,
            },
            3,
            0,
            (8, 3),
            Entry::Here,
            |row| copy_row(&vt, 8, row),
        )
        .unwrap();
        let mut events = Vec::new();
        crate::input::Input::default().feed(b"l", Instant::now(), &mut events);
        for event in events {
            if let crate::input::Event::Key(key) = event {
                mode.feed(
                    &key,
                    |row| copy_row(&vt, 8, row),
                    |row| vt.row_wraps(row).map_err(text),
                )
                .unwrap();
            }
        }
        assert_eq!(mode.highlight(None, 6, 0, 1), copy::Highlight::Selected);
        assert_eq!(mode.highlight(None, 7, 0, 1), copy::Highlight::None);
    }

    #[test]
    fn copy_freezes_output_and_resyncs_after_a_dirty_exit() {
        let (mut mirror, theirs, mut poll) = mirror();
        theirs
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let mut server = tungstenite::WebSocket::from_raw_socket(
            theirs,
            tungstenite::protocol::Role::Server,
            None,
        );
        assert!(!mirror.freeze(Entry::Here).unwrap());
        let snapshot = slices(
            &self::server(8, 2, "old").snapshot_bytes(false).unwrap(),
            4096,
        );
        feed(&mut mirror, &snapshot[0]).unwrap();
        assert!(mirror.freeze(Entry::Here).unwrap());
        let frozen = mirror.copy().unwrap().clone();
        feed(&mut mirror, &output(b"\r\nnew\r\nlatest")).unwrap();
        let in_transit = slices(
            &self::server(8, 2, "stale").snapshot_bytes(false).unwrap(),
            40,
        );
        feed(&mut mirror, &in_transit[0]).unwrap();
        assert_eq!(row(&mirror, 0), "old");
        assert_eq!(*mirror.copy().unwrap(), frozen);
        mirror.thaw(&mut poll).unwrap();
        let request = server.read().unwrap().into_text().unwrap();
        assert_eq!(
            protocol::decode::<ViewRequest>(request.as_bytes()).unwrap(),
            ViewRequest::Resync(OPTIONS)
        );
        assert!(!mirror.freeze(Entry::Here).unwrap());
        for continuation in &in_transit[1..] {
            feed(&mut mirror, continuation).unwrap();
        }
        feed(&mut mirror, &output(b"must be discarded")).unwrap();
        assert_eq!(row(&mirror, 0), "old");
        let fresh = slices(
            &self::server(8, 2, "new\r\nlatest")
                .snapshot_bytes(false)
                .unwrap(),
            4096,
        );
        feed(&mut mirror, &fresh[0]).unwrap();
        assert_eq!(row(&mirror, 1), "latest");
        assert!(mirror.copy().is_none());
    }

    #[test]
    fn copy_search_completes_and_cancels_without_compression() {
        let (mut mirror, _theirs, mut poll) = mirror();
        let records = slices(
            &server(20, 3, "needle\r\nother\r\nneedle\r\nlast")
                .snapshot_bytes(false)
                .unwrap(),
            4096,
        );
        for record in records {
            feed(&mut mirror, &record).unwrap();
        }
        assert!(mirror.freeze(Entry::Here).unwrap());
        let keys = |mirror: &mut Mirror, bytes: &[u8]| {
            let mut events = Vec::new();
            crate::input::Input::default().feed(bytes, Instant::now(), &mut events);
            for event in events {
                if let crate::input::Event::Key(key) = event {
                    mirror.copy_key(&key).unwrap();
                }
            }
        };
        keys(&mut mirror, b"?needle\r");
        assert!(mirror.searching());
        assert!(mirror.shared.lock().searching);
        for _ in 0..100 {
            if mirror.search_step().unwrap() {
                break;
            }
        }
        assert!(!mirror.searching());
        assert!(!mirror.shared.lock().searching);
        assert_eq!(
            mirror.copy().unwrap().search_state(),
            &copy::SearchState::Normal
        );
        keys(&mut mirror, b"?needle\r");
        assert!(mirror.searching());
        keys(&mut mirror, b"\x1b[27u");
        assert!(!mirror.searching());
        assert!(!mirror.shared.lock().searching);
        assert!(mirror.copy().is_some());
        keys(&mut mirror, b"?needle\r");
        assert!(mirror.searching());
        mirror.thaw(&mut poll).unwrap();
        assert!(!mirror.shared.lock().searching);
        assert!(mirror.copy().is_none());
        assert!(mirror.freeze(Entry::Here).unwrap());
        keys(&mut mirror, b"?needle\r");
        assert!(mirror.shared.lock().searching);
        mirror.unwatch(&mut poll);
        assert!(!mirror.shared.lock().searching);
        assert!(mirror.copy().is_none());
    }

    #[test]
    fn ready_shows_a_screen_before_the_last_slice_and_the_last_slice_swaps_in_the_history() {
        let (mut mirror, _theirs, _poll) = mirror();
        let history: String = (0..5000).map(|i| format!("line{i:05}\r\n")).collect();
        let records = slices(
            &server(16, 2, &history).snapshot_bytes(false).unwrap(),
            8192,
        );
        let (last, early) = records.split_last().unwrap();
        for record in early {
            feed(&mut mirror, record).unwrap();
        }
        let before = (kind(&mirror), row(&mirror, 0));
        feed(&mut mirror, last).unwrap();
        let after = (kind(&mirror), row(&mirror, 0), mirror.assembly.is_none());
        assert_eq!(
            (before, after),
            (
                ("loading", "line04999".to_owned()),
                ("full", "line04999".to_owned(), true)
            )
        );
    }

    #[test]
    fn a_second_first_slice_restarts_and_markers_and_output_queue_behind_a_snapshot() {
        let (mut mirror, _theirs, _poll) = mirror();
        let old = slices(&server(20, 3, "stale").snapshot_bytes(false).unwrap(), 40);
        let fresh = slices(&server(20, 3, "fresh").snapshot_bytes(false).unwrap(), 4096);
        feed(&mut mirror, &old[0]).unwrap();
        feed(&mut mirror, &fresh[0]).unwrap();
        assert_eq!(fresh.len(), 1);
        assert_eq!(
            (kind(&mirror), row(&mirror, 0)),
            ("full", "fresh".to_owned())
        );
        let wide = slices(&server(20, 3, "wide").snapshot_bytes(false).unwrap(), 40);
        let (first, rest) = wide.split_first().unwrap();
        feed(&mut mirror, first).unwrap();
        marked(
            &mut mirror,
            r#"{"type":"marked","offset":0,"marker":{"type":"resize","cols":8,"rows":2}}"#,
        );
        feed(&mut mirror, &output(b"\x1b[1;50HR")).unwrap();
        for record in rest {
            feed(&mut mirror, record).unwrap();
        }
        let mut frame = Frame::default();
        mirror.frame(&mut frame).unwrap();
        let cursor = frame.cursor.map(|cursor| cursor.x);
        assert_eq!((frame.cols, frame.rows, cursor), (8, 2, Some(7)));
    }

    #[test]
    fn a_full_mirror_resumes_after_its_last_bytes_and_a_snapshot_in_progress_or_a_screen_does_not()
    {
        let (mut mirror, _theirs, _poll) = mirror();
        let at = |offset: u64, mut record: Vec<u8>| {
            record[1..9].copy_from_slice(&offset.to_le_bytes());
            record
        };
        let snapshot = slices(&server(8, 2, "x").snapshot_bytes(false).unwrap(), 4096);
        feed(&mut mirror, &at(40, snapshot[0].clone())).unwrap();
        let loaded = mirror.resume.offset();
        feed(&mut mirror, &at(40, output(b"abc"))).unwrap();
        feed(&mut mirror, &at(43, output(b"de"))).unwrap();
        let after = mirror.resume.offset();
        let long = slices(&server(8, 2, "x").snapshot_bytes(false).unwrap(), 40);
        feed(&mut mirror, &at(90, long[0].clone())).unwrap();
        feed(&mut mirror, &at(90, output(b"f"))).unwrap();
        let during = mirror.resume.offset();
        for record in &long[1..] {
            feed(&mut mirror, &at(90, record.clone())).unwrap();
        }
        let finished = mirror.resume.offset();
        let mut screen = snapshot[0].clone();
        screen[10] = 1;
        feed(&mut mirror, &at(120, screen)).unwrap();
        assert_eq!(
            (loaded, after, during, finished, mirror.resume.offset()),
            (Some(40), Some(45), None, Some(91), None)
        );
    }

    #[test]
    fn records_buffered_with_the_upgrade_response_are_read_without_new_socket_data() {
        let (ours, _theirs) = UnixStream::pair().unwrap();
        let record = slices(
            &server(16, 2, "buffered").snapshot_bytes(false).unwrap(),
            4096,
        )
        .remove(0);
        let length = u16::try_from(record.len()).unwrap().to_be_bytes();
        let rest = [&[0x82, 126][..], &length, &record].concat();
        let mut poll = Poll::new();
        let mirror = with(Link::of(ours, rest), default_limits(), &mut poll).unwrap();
        assert_eq!(
            (kind(&mirror), row(&mirror, 0)),
            ("full", "buffered".to_owned())
        );
    }

    #[test]
    fn the_dead_marker_counts_once_the_output_before_it_is_applied() {
        let (mut mirror, _theirs, _poll) = mirror();
        let records = slices(&server(8, 2, "x").snapshot_bytes(false).unwrap(), 10);
        let dead = r#"{"type":"marked","offset":0,"marker":{"type":"dead","at":1}}"#;
        feed(&mut mirror, &records[0]).unwrap();
        marked(&mut mirror, dead);
        let queued = mirror.dead();
        for record in &records[1..] {
            feed(&mut mirror, record).unwrap();
        }
        assert_eq!((queued, mirror.dead()), (None, Some(1)));
    }

    #[test]
    fn a_continuation_without_a_first_slice_and_an_unknown_record_are_errors() {
        let (mut mirror, _theirs, _poll) = mirror();
        let records = slices(&server(8, 2, "x").snapshot_bytes(false).unwrap(), 10);
        assert_eq!(
            feed(&mut mirror, &records[1]).unwrap_err(),
            "snapshot missing first slice"
        );
        assert_eq!(
            feed(&mut mirror, &[9; 12]).unwrap_err(),
            "invalid record kind"
        );
        assert_eq!(feed(&mut mirror, &[1, 0]).unwrap_err(), "short record");
    }
}
