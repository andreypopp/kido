use std::path::Path;
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use ko_client::wire::{self, Link, Next, text};
use ko_pane_wire::frame::{History, Limits};
use ko_server::ids::{ClientId, PaneId};
use ko_server::protocol::{self, Images, Marker, Route, ViewEvent, ViewOptions, ViewRequest, json};
use ko_server::ws::{BadRecord, Record, parse_record};
use ko_sys::clock::Mono;
use ko_sys::event::{Poll, Ready, Token};
use ko_vt::compress::{Compress, Tick};
use ko_vt::render::Frame;
use ko_vt::{Extent, ReadyScan, Terminal};
use tungstenite::Bytes;

const BURST: Duration = Duration::from_millis(1);
const YIELD: Duration = Duration::from_micros(500);

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
        let tick = state.surface.screen_mut().map(|screen| {
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
    buffer: Vec<u8>,
    kind: Shape,
    following: Vec<Following>,
}

fn apply(vt: &mut Terminal, marker: &Marker) -> Result<(), ko_vt::Error> {
    match marker {
        Marker::Resize(size) => vt.resize(size.0),
        Marker::Dead(_) => Ok(()),
    }
}

#[derive(Debug)]
pub(crate) struct Mirror {
    link: Link,
    token: Token,
    shared: Arc<Shared>,
    compressor: Option<JoinHandle<()>>,
    limits: Limits,
    assembly: Option<Assembly>,
    dead: Option<protocol::Dead>,
}

impl Mirror {
    pub(crate) fn open(
        socket: &Path,
        client: ClientId,
        pane: PaneId,
        limits: Limits,
        poll: &mut Poll,
    ) -> Result<Mirror, String> {
        let options = ViewOptions {
            history: History::All,
            images: Images::None,
        };
        let link =
            Link::connect(socket, Some(client), &Route::View(pane, options, None)).map_err(text)?;
        Mirror::with(link, limits, poll)
    }

    fn with(mut link: Link, limits: Limits, poll: &mut Poll) -> Result<Mirror, String> {
        let token = link.watch(poll).map_err(text)?;
        let shared = Arc::new(Shared {
            state: Mutex::new(State {
                surface: Surface::Empty,
                generation: 0,
                drawn: Drawn::Fresh,
                closed: false,
                settled: true,
            }),
            wake: Condvar::new(),
        });
        let thread = Arc::clone(&shared);
        let mut mirror = Mirror {
            link,
            token,
            shared,
            compressor: Some(std::thread::spawn(move || compress_loop(&thread))),
            limits,
            assembly: None,
            dead: None,
        };
        mirror.handle(poll, wire::buffered(token), Instant::now())?;
        Ok(mirror)
    }

    pub(crate) fn dead(&self) -> Option<&protocol::Dead> {
        self.dead.as_ref()
    }

    pub(crate) fn token(&self) -> Token {
        self.token
    }

    pub(crate) fn received(&self) -> Instant {
        self.link.received()
    }

    pub(crate) fn begin_turn(&mut self) {
        self.link.begin_turn();
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

    pub(crate) fn send(&mut self, poll: &mut Poll, request: &ViewRequest) -> Result<(), String> {
        self.link.send(json(request)).map_err(text)?;
        self.link.settle(poll).map_err(text)
    }

    pub(crate) fn handle(
        &mut self,
        poll: &mut Poll,
        ready: Ready,
        now: Instant,
    ) -> Result<(), String> {
        if ready.write {
            self.link.settle(poll).map_err(text)?;
        }
        if !ready.read {
            return Ok(());
        }
        let shared = Arc::clone(&self.shared);
        let mut state = shared.lock();
        let mut changed = false;
        loop {
            match self.link.next(poll, now).map_err(text)? {
                Next::Wait => break,
                Next::Closed => return Err("pane view closed".to_owned()),
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
        if let Marker::Dead(dead) = marker {
            self.dead = Some(dead.clone());
        }
    }

    fn marker(&mut self, state: &mut State, event: &str) -> Result<(), String> {
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
        match parse_record(record) {
            Ok((Record::Output, _, data)) => self.output(state, record, data),
            Ok((Record::Snapshot, _, data)) => self.snapshot(state, data),
            Err(BadRecord::Short) => Err("short record".to_owned()),
            Err(BadRecord::Kind(_)) => Err("invalid record kind".to_owned()),
        }
    }

    fn output(&mut self, state: &mut State, record: &Bytes, data: &[u8]) -> Result<(), String> {
        state.scroll_bottom().map_err(text)?;
        if let Some(assembly) = self.assembly.as_mut() {
            let start = record.len().saturating_sub(data.len());
            assembly
                .following
                .push(Following::Bytes(record.slice(start..)));
        } else if let Some(screen) = state.surface.screen_mut() {
            screen.vt.write(data);
        }
        Ok(())
    }

    fn snapshot(&mut self, state: &mut State, data: &[u8]) -> Result<(), String> {
        let (&flags, rest) = data.split_first().ok_or("short snapshot slice")?;
        let (&screen, body) = rest.split_first().ok_or("short snapshot slice")?;
        let (first, last) = (flags & 1 != 0, flags & 2 != 0);
        if first {
            self.assembly = Some(Assembly {
                buffer: Vec::new(),
                kind: if screen == 0 {
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
            let early = Terminal::decode(&mut &assembly.buffer[..], Extent::Screen)
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
        let extent = if full { Extent::Full } else { Extent::Screen };
        let mut vt = Terminal::decode(&mut &assembly.buffer[..], extent).map_err(text)?;
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

    pub(crate) fn bottom(&mut self) -> Result<(), String> {
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
            let options = ViewOptions {
                history: History::All,
                images: Images::None,
            };
            self.send(poll, &ViewRequest::Resync(options))?;
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
        self.link.unwatch(poll);
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
    use ko_server::config::DEFAULT_LIMITS;

    use super::*;

    fn mirror() -> (Mirror, UnixStream, Poll) {
        let (ours, theirs) = UnixStream::pair().unwrap();
        let mut poll = Poll::new();
        let mirror = Mirror::with(Link::of(ours, Vec::new()), DEFAULT_LIMITS, &mut poll).unwrap();
        (mirror, theirs, poll)
    }

    fn server(cols: u16, rows: u16, text: &str) -> Terminal {
        let (cols, rows) = (Dim::new(cols).unwrap(), Dim::new(rows).unwrap());
        let mut vt = Terminal::new(cols, rows, DEFAULT_LIMITS).unwrap();
        vt.write(text.as_bytes());
        vt
    }

    fn slices(bytes: &[u8], size: usize) -> Vec<Vec<u8>> {
        let chunks: Vec<&[u8]> = bytes.chunks(size).collect();
        chunks
            .iter()
            .enumerate()
            .map(|(i, chunk)| {
                let flags = u8::from(i == 0) | u8::from(i + 1 == chunks.len()) << 1;
                [&[2][..], &[0; 8], &[flags, 0], chunk].concat()
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
        let mirror = Mirror::with(Link::of(ours, rest), DEFAULT_LIMITS, &mut poll).unwrap();
        assert_eq!(
            (kind(&mirror), row(&mirror, 0)),
            ("full", "buffered".to_owned())
        );
    }

    #[test]
    fn the_dead_marker_counts_once_the_output_before_it_is_applied() {
        let (mut mirror, _theirs, _poll) = mirror();
        let records = slices(&server(8, 2, "x").snapshot_bytes(false).unwrap(), 10);
        let dead = r#"{"type":"marked","offset":0,"marker":{"type":"dead","at":1,"cause":{"type":"exited","code":3}}}"#;
        feed(&mut mirror, &records[0]).unwrap();
        marked(&mut mirror, dead);
        let queued = mirror.dead().cloned();
        for record in &records[1..] {
            feed(&mut mirror, record).unwrap();
        }
        assert_eq!((queued, mirror.dead().map(|dead| dead.at)), (None, Some(1)));
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
