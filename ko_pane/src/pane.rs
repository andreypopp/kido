use std::os::fd::{AsFd, BorrowedFd, OwnedFd};
use std::time::{Duration, Instant};

use ko_pane_wire::frame::{
    self, Dead, FromPane, History, Init, Kind, Req, Request, ScreenFormat, ScreenRows, Size,
};
use ko_pane_wire::ring::{DEAD_LEN, Marker, RESIZE_LEN, RecordKind, SLICE_HEADER, Slice, Writer};
use ko_sys::clock::Mono;
use ko_sys::event::Interest;
use ko_sys::fd::Queue;
use ko_sys::pid::Exit;
use ko_sys::pty::{self, Program, Winsize};
use ko_sys::signal::{Signal, Signals};
use ko_vt::compress::{Compress, Tick};
use ko_vt::{Format, Terminal};

use crate::io::{Fault, Io, Out, Stop};

const SCREEN_CHUNK: usize = 65536;
const MAX_READS: u8 = 16;
const SHRINK: usize = 1 << 20;
const HANGUP_WAIT: Duration = Duration::from_millis(250);
const HANGUP_STEP: Duration = Duration::from_millis(5);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Launch {
    Spawn,
    Detached,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Life {
    Running,
    Exited(Exit),
    Dead,
}

#[derive(Debug)]
struct Process {
    master: OwnedFd,
    program: Option<Program>,
    life: Life,
    eof: bool,
}

#[derive(Debug)]
struct Live {
    vt: Terminal,
    pty_input: Queue,
    compress: Compress,
    process: Option<Process>,
}

#[derive(Debug)]
pub struct Pane {
    io: Io,
    live: Option<Live>,
    launch: Launch,
    tmpdir: String,
    scratch: Vec<u8>,
}

fn winsize(size: Size) -> Winsize {
    let (width, height) = size.cell_pixels();
    Winsize::new(size.cols.get(), size.rows.get(), width, height)
}

fn vt_fault(error: ko_vt::Error) -> Fault {
    Fault::Setup(format!("terminal: {error}"))
}

fn invalid(_: ko_vt::Error) -> Fault {
    Fault::Invalid
}

fn collect(vt: &mut Terminal, pty_input: &mut Queue) {
    let replies = vt.replies();
    if pty_input.bytes.is_empty() {
        std::mem::swap(&mut pty_input.bytes, replies);
    } else {
        pty_input.bytes.append(replies);
        if replies.capacity() > SHRINK {
            *replies = Vec::new();
        }
    }
}

impl Live {
    fn collect(&mut self) {
        collect(&mut self.vt, &mut self.pty_input);
    }

    fn push(&mut self, bytes: &[u8]) {
        self.pty_input.bytes.extend_from_slice(bytes);
    }
}

struct Screen<'a> {
    out: &'a mut Out,
    req: Req,
    bytes: Vec<u8>,
}

impl Screen<'_> {
    fn chunk(&mut self, last: bool) -> Result<(), Stop> {
        let frame = FromPane::Screen {
            req: self.req,
            last,
            text: &self.bytes,
        };
        self.out.frame(&frame);
        self.bytes.clear();
        self.out.drain_output()
    }

    fn write(&mut self, mut bytes: &[u8]) -> Result<(), Stop> {
        while !bytes.is_empty() {
            let take = SCREEN_CHUNK
                .saturating_sub(self.bytes.len())
                .min(bytes.len());
            let (head, rest) = bytes.split_at(take);
            self.bytes.extend_from_slice(head);
            bytes = rest;
            if self.bytes.len() == SCREEN_CHUNK {
                self.chunk(false)?;
            }
        }
        Ok(())
    }
}

struct Slices<'a> {
    io: &'a mut Io,
    used: usize,
    room: usize,
    first: bool,
    screen: bool,
}

impl Slices<'_> {
    fn commit(&mut self) {
        if self.room == 0 {
            return;
        }
        let flags = Slice {
            first: self.first,
            last: false,
            screen: self.screen,
        }
        .encode();
        if let Some(payload) = self.io.out.writer.payload(RecordKind::Slice, SLICE_HEADER) {
            payload.copy_from_slice(&flags);
        }
        self.first = false;
        self.io
            .out
            .publish(RecordKind::Slice, self.used.saturating_add(SLICE_HEADER));
        self.used = 0;
        self.room = 0;
    }

    fn emit(&mut self, mut bytes: &[u8]) -> Result<(), Stop> {
        while !bytes.is_empty() {
            if self.used == self.room {
                self.commit();
                self.io.wait_space(SLICE_HEADER.saturating_add(1))?;
                self.room = self.io.out.available().saturating_sub(SLICE_HEADER);
            }
            let take = self.room.saturating_sub(self.used).min(bytes.len());
            let (head, rest) = bytes.split_at(take);
            let start = SLICE_HEADER.saturating_add(self.used);
            self.io
                .out
                .writer
                .payload(RecordKind::Slice, self.room.saturating_add(SLICE_HEADER))
                .and_then(|payload| payload.get_mut(start..))
                .and_then(|room| room.get_mut(..take))
                .ok_or(Stop)?
                .copy_from_slice(head);
            self.used = self.used.saturating_add(take);
            bytes = rest;
        }
        Ok(())
    }
}

fn simple(live: &mut Option<Live>, out: &mut Out, request: Request<'_>) -> Result<(), Fault> {
    let Some(live) = live else {
        return Err(Fault::Invalid);
    };
    match request {
        Request::Tail => out.full = false,
        Request::Text(bytes) => live.push(bytes),
        Request::Key(key) => {
            let bytes = live.vt.encode_key(&key).map_err(invalid)?;
            live.push(&bytes);
        }
        Request::Mouse(mouse) => {
            let bytes = live.vt.encode_mouse(&mouse).map_err(invalid)?;
            live.push(&bytes);
        }
        Request::Focus(gained) => {
            let bytes = live.vt.encode_focus(gained).map_err(invalid)?;
            live.push(&bytes);
        }
        Request::Paste {
            req,
            text,
            check_safe,
        } => {
            let pasted = live.vt.paste(text, check_safe).map_err(invalid)?;
            live.collect();
            out.frame(&FromPane::PasteDone {
                req,
                pasted: pasted.written,
                unsafe_paste: pasted.rejected,
            });
        }
        Request::Screen { req, format, rows } => {
            let history = match rows {
                ScreenRows::Visible => 0,
                ScreenRows::Full => u32::MAX,
                ScreenRows::Last(rows) => rows,
            };
            let format = match format {
                ScreenFormat::Plain => Format::Plain,
                ScreenFormat::Ansi => Format::Vt,
            };
            let mut screen = Screen {
                out,
                req,
                bytes: Vec::with_capacity(SCREEN_CHUNK),
            };
            live.vt
                .screen(format, history, |bytes| screen.write(bytes).is_ok())
                .map_err(invalid)?;
            screen.chunk(true)?;
        }
        Request::Exit => out.stopping = true,
        Request::Init(_) | Request::Resize(_) | Request::Snapshot { .. } => {
            return Err(Fault::Invalid);
        }
    }
    Ok(())
}

impl Pane {
    pub fn new(
        writer: Writer,
        input: OwnedFd,
        output: OwnedFd,
        signals: Option<Signals>,
        tmpdir: String,
    ) -> Pane {
        Pane::with(writer, input, output, signals, Launch::Spawn, tmpdir)
    }

    pub(crate) fn detached(writer: Writer, input: OwnedFd, output: OwnedFd) -> Pane {
        Pane::with(
            writer,
            input,
            output,
            None,
            Launch::Detached,
            "/tmp".to_owned(),
        )
    }

    fn with(
        writer: Writer,
        input: OwnedFd,
        output: OwnedFd,
        signals: Option<Signals>,
        launch: Launch,
        tmpdir: String,
    ) -> Pane {
        Pane {
            io: Io::new(writer, input, output, signals),
            live: None,
            launch,
            tmpdir,
            scratch: Vec::new(),
        }
    }

    pub(crate) fn init(&mut self, init: &Init<'_>) -> Result<(), Fault> {
        let size = init.size;
        let mut vt = Terminal::new(size.cols, size.rows, init.limits).map_err(vt_fault)?;
        vt.resize(size).map_err(vt_fault)?;
        vt.serve(&init.media, &self.tmpdir).map_err(vt_fault)?;
        let process = match self.launch {
            Launch::Detached => None,
            Launch::Spawn => {
                let pty = pty::spawn(winsize(size), &init.cwd, &init.argv, &init.env)
                    .map_err(|setup| Fault::Setup(setup.to_string()))?;
                let (program, life) = match pty.program {
                    Ok(program) => {
                        let life = match program.peek_exit() {
                            Ok(Some(exit)) => Life::Exited(exit),
                            _ => {
                                self.io
                                    .out
                                    .frame(&FromPane::Ready(i64::from(program.pid().get())));
                                Life::Running
                            }
                        };
                        (Some(program), life)
                    }
                    Err(failed) => (None, Life::Exited(failed.exit)),
                };
                Some(Process {
                    master: pty.master,
                    program,
                    life,
                    eof: false,
                })
            }
        };
        self.live = Some(Live {
            vt,
            pty_input: Queue::default(),
            compress: Compress::new(Mono::now()),
            process,
        });
        Ok(())
    }

    pub(crate) fn dispatch(&mut self, frame: &[u8]) -> Result<(), Fault> {
        let request = frame::decode_request(frame).map_err(|_| Fault::Invalid)?;
        match request {
            Request::Init(init) if self.live.is_none() => self.init(&init),
            Request::Init(_) => Err(Fault::Invalid),
            Request::Resize(size) => self.resize(size),
            Request::Snapshot { req, history } => self.snapshot(req, history),
            request => simple(&mut self.live, &mut self.io.out, request),
        }
    }

    fn resize(&mut self, size: Size) -> Result<(), Fault> {
        let Some(live) = &mut self.live else {
            return Err(Fault::Invalid);
        };
        self.io.wait_space(RESIZE_LEN)?;
        live.vt.resize(size).map_err(invalid)?;
        if let Some(process) = &live.process {
            let _ = pty::set_size(&process.master, winsize(size));
        }
        self.io.out.put_marker(Marker::Resize(size));
        Ok(())
    }

    fn snapshot(&mut self, req: Req, history: History) -> Result<(), Fault> {
        let Some(live) = &mut self.live else {
            return Err(Fault::Invalid);
        };
        let screen = history == History::None;
        let mut slices = Slices {
            io: &mut self.io,
            used: 0,
            room: 0,
            first: true,
            screen,
        };
        live.vt
            .snapshot(screen, |bytes| slices.emit(bytes).is_ok())
            .map_err(|_| Fault::Stop)?;
        slices.commit();
        self.io.wait_space(SLICE_HEADER)?;
        self.io.out.put_slice(Slice {
            first: false,
            last: true,
            screen,
        });
        self.io.out.frame(&FromPane::SnapshotDone(req));
        Ok(())
    }

    fn run_deferred(&mut self) -> Result<(), Stop> {
        let mut pending = std::mem::take(&mut self.io.deferred);
        loop {
            let range = match pending.next() {
                Ok(Some(range)) => range,
                Ok(None) => return Ok(()),
                Err(_) => {
                    self.io.out.report(&Fault::Invalid);
                    return Err(Stop);
                }
            };
            if let Err(fault) = self.dispatch(pending.frame(range)) {
                self.io.out.report(&fault);
                return Err(Stop);
            }
        }
    }

    fn route(&mut self) -> Result<bool, Stop> {
        let range = match self.io.input.next() {
            Ok(Some(range)) => range,
            Ok(None) => return Ok(false),
            Err(_) => {
                self.io.out.report(&Fault::Invalid);
                return Err(Stop);
            }
        };
        let bytes = self.io.input.frame(range);
        let fault = if matches!(
            frame::kind(bytes),
            Some(Kind::Init | Kind::Resize | Kind::Snapshot)
        ) {
            let mut frame = std::mem::take(&mut self.scratch);
            frame.clear();
            frame.extend_from_slice(bytes);
            let result = self.dispatch(&frame);
            self.scratch = frame;
            result
        } else {
            frame::decode_request(bytes)
                .map_err(|_| Fault::Invalid)
                .and_then(|request| simple(&mut self.live, &mut self.io.out, request))
        };
        if let Err(fault) = fault {
            self.io.out.report(&fault);
            return Err(Stop);
        }
        Ok(true)
    }

    pub(crate) fn control(&mut self) -> Result<(), Stop> {
        let eof = self.io.fill()?;
        let mut result = Ok(());
        while result.is_ok() {
            match self.route() {
                Ok(true) => {}
                Ok(false) => break,
                Err(stop) => result = Err(stop),
            }
        }
        self.io.input.compact();
        while result.is_ok() && !self.io.deferred.is_empty() {
            result = self.run_deferred();
        }
        result?;
        if eof {
            self.io.out.stopping = true;
        }
        Ok(())
    }

    pub(crate) fn input_fd(&self) -> BorrowedFd<'_> {
        self.io.out.input_fd()
    }

    pub(crate) fn output_fd(&self) -> BorrowedFd<'_> {
        self.io.out.output_fd()
    }

    pub(crate) fn signals_fd(&self) -> Option<BorrowedFd<'_>> {
        self.io.out.signals_fd()
    }

    pub(crate) fn output_pending(&self) -> bool {
        !self.io.out.output.is_empty()
    }

    pub(crate) fn pty(&self) -> Option<(BorrowedFd<'_>, Interest)> {
        let Live {
            pty_input,
            process: Some(process),
            ..
        } = self.live.as_ref()?
        else {
            return None;
        };
        let reading = !process.eof && !self.io.out.full;
        Some((
            process.master.as_fd(),
            Interest::of(reading, !pty_input.is_empty()),
        ))
    }

    pub(crate) fn stopping(&self) -> bool {
        self.io.out.stopping
    }

    pub(crate) fn take_failure(&mut self) -> Option<String> {
        self.io.out.failure.take()
    }

    pub(crate) fn signaled(&mut self) -> std::io::Result<()> {
        self.io.out.signaled()
    }

    pub(crate) fn flush(&mut self) -> Result<(), Stop> {
        self.io.out.flush()
    }

    pub(crate) fn flush_pty(&mut self) {
        if let Some(Live {
            pty_input,
            process: Some(process),
            ..
        }) = &mut self.live
            && pty_input.flush(process.master.as_fd()).is_err()
        {
            pty_input.clear();
        }
    }

    pub(crate) fn settle_child(&mut self) {
        if !std::mem::take(&mut self.io.out.child_signal) {
            return;
        }
        if let Some(Process {
            program: Some(program),
            life: life @ Life::Running,
            ..
        }) = self.live.as_mut().and_then(|live| live.process.as_mut())
            && let Ok(Some(exit)) = program.peek_exit()
        {
            *life = Life::Exited(exit);
        }
    }

    pub(crate) fn exit_pending(&self) -> bool {
        matches!(
            self.live.as_ref().and_then(|live| live.process.as_ref()),
            Some(Process {
                life: Life::Exited(_),
                eof: false,
                ..
            })
        )
    }

    pub(crate) fn read_pty(&mut self) -> bool {
        let out = &mut self.io.out;
        let Some(Live {
            vt,
            pty_input,
            process: Some(process),
            ..
        }) = &mut self.live
        else {
            return false;
        };
        let room = out.available();
        if room == 0 {
            out.announce_full();
            return false;
        }
        let Some(dst) = out.writer.payload(RecordKind::Bytes, room) else {
            return false;
        };
        let (mut used, mut reads) = (0, 0);
        while used < room && reads < MAX_READS {
            reads += 1;
            let Some(window) = dst.get_mut(used..) else {
                break;
            };
            match pty::read(process.master.as_fd(), window) {
                Ok(0) => {
                    process.eof = true;
                    break;
                }
                Ok(count) => used = used.saturating_add(count),
                Err(_) => break,
            }
        }
        if used == 0 {
            return false;
        }
        if let Some(bytes) = dst.get(..used) {
            vt.write(bytes);
        }
        let changes = vt.take_changes();
        if changes.title
            && let Ok(title) = vt.title()
        {
            out.event(&FromPane::Title(title));
        }
        if changes.pwd
            && let Ok(pwd) = vt.pwd()
        {
            out.event(&FromPane::Pwd(pwd));
        }
        collect(vt, pty_input);
        out.publish(RecordKind::Bytes, used);
        true
    }

    pub(crate) fn dead(&mut self) -> Result<(), Stop> {
        let Some(Live {
            process: Some(process),
            ..
        }) = &mut self.live
        else {
            return Ok(());
        };
        let (Life::Exited(exit), true) = (process.life, process.eof) else {
            return Ok(());
        };
        let dead = Dead {
            at: Mono::now(),
            exit,
        };
        self.io.wait_space(DEAD_LEN)?;
        self.io.out.put_marker(Marker::Dead(dead));
        process.life = Life::Dead;
        self.io.out.frame(&FromPane::Dead(dead));
        Ok(())
    }

    pub(crate) fn tick(&mut self) -> Tick {
        match &mut self.live {
            Some(live) => live.compress.tick(&mut live.vt, Mono::now()),
            None => Tick::Settled,
        }
    }

    pub(crate) fn compress_pending(&self) -> bool {
        self.live
            .as_ref()
            .is_some_and(|live| live.compress.pending())
    }

    pub fn finish(self) {
        let Some(Live {
            process:
                Some(Process {
                    program: Some(program),
                    life,
                    ..
                }),
            ..
        }) = self.live
        else {
            return;
        };
        if life == Life::Running {
            let _ = program.signal(Signal::Hup);
            let deadline = Instant::now() + HANGUP_WAIT;
            while !matches!(program.peek_exit(), Ok(Some(_))) {
                let left = deadline.saturating_duration_since(Instant::now());
                if left.is_zero() {
                    break;
                }
                std::thread::sleep(HANGUP_STEP.min(left));
            }
        }
        let _ = program.signal(Signal::Kill);
        let _ = program.reap();
    }
}
