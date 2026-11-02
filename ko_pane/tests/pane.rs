#![cfg(test)]

use std::io::{Read, Write};
use std::os::fd::AsFd;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::{Duration, Instant};

use ko_pane_wire::frame::{
    self, CellPx, Dead, Dim, FromPane, History, Init, Kind, Limits, Medium, Req, ScreenFormat,
    ScreenRows, Scrollback, Size, ToPane,
};
use ko_pane_wire::ring::{Marker, Pos, Reader, RecordKind};
use ko_sys::pid::{Exit, Pid, Waited};
use ko_sys::signal::Signal;
use ko_sys::spawn;
use ko_vt::{Extent, Format, Terminal};

const PANE: &str = env!("CARGO_BIN_EXE_ko-pane");
const DEADLINE: Duration = Duration::from_secs(20);

fn size(cols: u16, rows: u16) -> Size {
    Size {
        cols: Dim::new(cols).unwrap(),
        rows: Dim::new(rows).unwrap(),
        cell_px: Some(CellPx::DEFAULT),
    }
}

fn limits() -> Limits {
    Limits {
        scrollback: Scrollback::Bounded {
            max_bytes: std::num::NonZeroUsize::new(32 * 1024 * 1024),
            max_lines: None,
        },
        apc_max_bytes: 65 * 1024 * 1024,
        kitty_images_max_bytes: 32 * 1024 * 1024,
        continuation_max_bytes: 65 * 1024 * 1024,
    }
}

fn init(argv: &[&str], cwd: &str) -> Vec<u8> {
    let argv: Vec<Vec<u8>> = argv.iter().map(|arg| arg.as_bytes().to_vec()).collect();
    let env = [b"TERM=xterm-ghostty".to_vec()];
    let init = Init {
        size: size(80, 24),
        limits: limits(),
        media: Vec::<Medium>::new().into(),
        cwd: Path::new(cwd).into(),
        argv: argv.into(),
        env: env[..].into(),
        id: "pane_1".into(),
    };
    let mut out = Vec::new();
    frame::encode(&ToPane::Init(&init), &mut out).unwrap();
    out
}

fn encoded(frame: &ToPane<'_>) -> Vec<u8> {
    let mut out = Vec::new();
    frame::encode(frame, &mut out).unwrap();
    out
}

#[derive(Debug, Default)]
struct Seen {
    offset: u64,
    snapshot: Vec<u8>,
    resizes: Vec<Size>,
    deaths: Vec<Dead>,
    output: Vec<u8>,
}

struct Harness {
    control: UnixStream,
    reader: Reader,
    pane: Pid,
    cursor: Pos,
    buffer: Vec<u8>,
    seen: Seen,
}

impl Harness {
    fn start(capacity: u64) -> Harness {
        Harness::start_with(capacity, Path::new(PANE), &[])
    }

    fn start_with(capacity: u64, program: &Path, args: &[&str]) -> Harness {
        let reader = Reader::create(capacity).unwrap();
        let (control, theirs) = UnixStream::pair().unwrap();
        let pane = spawn::program(
            program,
            args,
            &[(theirs.as_fd(), 0), (theirs.as_fd(), 1), (reader.fd(), 3)],
            spawn::Env::Inherit,
        )
        .unwrap();
        control.set_read_timeout(Some(DEADLINE)).unwrap();
        control.set_write_timeout(Some(DEADLINE)).unwrap();
        Harness {
            control,
            cursor: reader.tail(),
            reader,
            pane,
            buffer: Vec::new(),
            seen: Seen::default(),
        }
    }

    fn send(&mut self, bytes: &[u8]) {
        self.control.write_all(bytes).unwrap();
    }

    fn receive(&mut self) -> Vec<u8> {
        let started = Instant::now();
        loop {
            if let Some(size) = frame::frame_size(&self.buffer).unwrap() {
                return self.buffer.drain(..size).collect();
            }
            assert!(started.elapsed() < DEADLINE, "no frame from the pane");
            let mut chunk = [0u8; 65536];
            let count = self.control.read(&mut chunk).unwrap();
            assert!(count > 0, "the pane closed its control socket");
            self.buffer.extend_from_slice(&chunk[..count]);
        }
    }

    fn drain(&mut self) {
        loop {
            let head = self.reader.head();
            while self.cursor < head {
                let record = self.reader.record(self.cursor).unwrap();
                match record.kind {
                    RecordKind::Bytes => {
                        assert_eq!(record.offset.get(), self.seen.offset);
                        self.seen.offset += record.len;
                        self.seen
                            .output
                            .extend_from_slice(self.reader.payload(self.cursor).unwrap());
                    }
                    RecordKind::Marker => {
                        assert_eq!(record.offset.get(), self.seen.offset);
                        match self.reader.marker(self.cursor).unwrap() {
                            Marker::Resize(size) => self.seen.resizes.push(size),
                            Marker::Dead(dead) => self.seen.deaths.push(dead),
                        }
                    }
                    RecordKind::Slice => {
                        assert_eq!(record.offset.get(), self.seen.offset);
                        let payload = self.reader.payload(self.cursor).unwrap();
                        self.seen.snapshot.extend_from_slice(&payload[2..]);
                    }
                    RecordKind::Pad => {}
                }
                self.cursor = record.next;
            }
            self.reader.advance(head, self.cursor).unwrap();
            if self.reader.head() == head {
                return;
            }
        }
    }

    fn finish(mut self) -> Waited {
        self.send(&encoded(&ToPane::Exit));
        let started = Instant::now();
        loop {
            match self.pane.try_wait().unwrap() {
                Waited::Running => {
                    assert!(started.elapsed() < DEADLINE, "the pane did not exit");
                    std::thread::sleep(Duration::from_millis(2));
                }
                waited => return waited,
            }
        }
    }
}

#[test]
fn a_recorded_stream_arrives_as_frames_records_and_a_snapshot_across_a_full_ring() {
    let script = "printf '\\033]2;ko test\\007\\033]7;file://localhost/tmp\\007\\033]133;A\\007\
        \\033]133;C;cmdline_url=echo\\007\\033]133;D;7\\007\\033]7501;state=working:app=ko\\007\
        \\033[?2026h'; i=0; while [ $i -lt 200 ]; do \
        printf '\\033]8;;https://example.org\\033\\\\line %s\\033]8;;\\033\\\\\\r\\n' $i; \
        i=$((i+1)); done";
    let mut pane = Harness::start(4096);
    pane.send(&init(&["/bin/sh", "-c", script], "/"));
    let (mut ready, mut titles, mut pwds, mut fulls, mut done) = (None, 0, 0, 0, false);
    let mut death = None;
    while !done {
        let bytes = pane.receive();
        pane.drain();
        match frame::decode(&bytes).unwrap().unwrap() {
            FromPane::Ready(child) => ready = Some(Pid::new(child).unwrap()),
            FromPane::Head(_) => {}
            FromPane::Full(_) => {
                fulls += 1;
                let tail = pane.cursor;
                pane.send(&encoded(&ToPane::Tail(tail)));
            }
            FromPane::Title(title) => {
                titles += 1;
                assert_eq!(title, b"ko test");
            }
            FromPane::Pwd(cwd) => {
                pwds += 1;
                assert_eq!(cwd, b"file://localhost/tmp");
            }
            FromPane::Dead(dead) => {
                death = Some(dead);
                assert_eq!(dead.exit, Exit::Exited(0));
                assert!(dead.at.nanos() > 0);
                assert!(ready.unwrap().alive(), "the held zombie keeps its pid");
                pane.send(&encoded(&ToPane::Resize(size(40, 20))));
                pane.send(&encoded(&ToPane::Snapshot {
                    req: Req::of_serial(1),
                    history: History::None,
                }));
            }
            FromPane::SnapshotDone(req) => {
                assert_eq!(req, Req::of_serial(1));
                done = true;
            }
            other => panic!("unexpected frame {other:?}"),
        }
    }
    pane.drain();
    assert!(ready.is_some() && fulls > 0, "{ready:?} {fulls}");
    assert_eq!((titles, pwds), (1, 1));
    assert!(pane.seen.offset > 8000, "{}", pane.seen.offset);
    assert_eq!(pane.seen.resizes, [size(40, 20)]);
    assert_eq!(pane.seen.deaths, [death.unwrap(); 2]);
    for mark in [
        &b"\x1b]7501;state=working:app=ko\x07"[..],
        b"\x1b]133;D;7\x07",
        b"\x1b]133;C;cmdline_url=echo\x07",
    ] {
        assert!(
            pane.seen
                .output
                .windows(mark.len())
                .any(|window| window == mark),
            "{}",
            String::from_utf8_lossy(mark)
        );
    }
    let snapshot = Terminal::decode(&mut &pane.seen.snapshot[..], Extent::Screen).unwrap();
    assert!(!snapshot.mode(2026).unwrap());
    let text = String::from_utf8(snapshot.dump(Format::Plain).unwrap()).unwrap();
    let rows: Vec<&str> = text.lines().map(str::trim_end).collect();
    let expected: Vec<String> = (181..200).map(|line| format!("line {line}")).collect();
    assert_eq!(rows, expected);

    for serial in 2..=10 {
        let request = Req::of_serial(serial);
        pane.send(&encoded(&ToPane::Screen {
            req: request,
            format: ScreenFormat::Ansi,
            rows: ScreenRows::Full,
        }));
    }
    for _ in 0..20 {
        pane.pane.signal(Signal::Child).unwrap();
        std::thread::sleep(Duration::from_micros(500));
    }
    let (mut screens, mut screen_bytes) = (0, 0);
    while screens < 9 {
        let bytes = pane.receive();
        match frame::decode(&bytes).unwrap().unwrap() {
            FromPane::Screen { last, text, .. } => {
                screen_bytes += text.len();
                screens += usize::from(last);
            }
            FromPane::Head(_) | FromPane::Full(_) => {}
            other => panic!("unexpected frame {other:?}"),
        }
    }
    assert!(screen_bytes > 50000, "{screen_bytes}");
    let child = ready.unwrap();
    assert_eq!(pane.finish(), Waited::Ended(Exit::Exited(0)));
    assert!(!child.alive(), "the pane reaps the program at exit");
}

#[test]
fn a_setup_failure_names_the_failing_call_and_its_error() {
    let script = "ulimit -n 7 && exec \"$0\"";
    let mut pane = Harness::start_with(4096, Path::new("/bin/sh"), &["-c", script, PANE]);
    pane.send(&init(&["/bin/sh"], "/"));
    let bytes = pane.receive();
    let FromPane::Error(message) = frame::decode(&bytes).unwrap().unwrap() else {
        panic!("not an error frame");
    };
    assert_eq!(
        String::from_utf8_lossy(message),
        "openpty: Too many open files (os error 24)"
    );
    drop(pane.control);
    let started = Instant::now();
    while pane.pane.try_wait().unwrap() == Waited::Running {
        assert!(started.elapsed() < DEADLINE, "the pane did not exit");
        std::thread::sleep(Duration::from_millis(2));
    }
}

#[test]
fn a_program_that_cannot_start_is_a_dead_pane_with_the_exit_status_of_a_shell() {
    let mut pane = Harness::start(4096);
    pane.send(&init(&["/no/such/program"], "/"));
    let dead = loop {
        let bytes = pane.receive();
        match frame::decode(&bytes).unwrap().unwrap() {
            FromPane::Dead(dead) => break dead,
            FromPane::Head(_) => {}
            other => panic!("unexpected frame {other:?}"),
        }
    };
    assert_eq!(dead.exit, Exit::Exited(127));
    pane.drain();
    assert_eq!(pane.seen.deaths, [dead]);
    assert_eq!(pane.finish(), Waited::Ended(Exit::Exited(0)));
}

fn raw(kind: Kind, body: &[u8]) -> Vec<u8> {
    let mut out = u32::try_from(body.len() + 1)
        .unwrap()
        .to_le_bytes()
        .to_vec();
    out.push(kind as u8);
    out.extend_from_slice(body);
    out
}

#[test]
fn a_grid_over_the_dimension_limit_is_refused_and_the_limit_itself_is_accepted() {
    let mut pane = Harness::start(4096);
    pane.send(&init(&["/bin/sh", "-c", "sleep 30"], "/"));
    let ready = pane.receive();
    assert!(matches!(
        frame::decode(&ready).unwrap(),
        Some(FromPane::Ready(_))
    ));
    pane.send(&encoded(&ToPane::Resize(size(4096, 24))));
    pane.send(&raw(Kind::Resize, &[0x01, 0x10, 24, 0, 8, 0, 16, 0]));
    let error = loop {
        let bytes = pane.receive();
        match frame::decode(&bytes).unwrap().unwrap() {
            FromPane::Error(message) => break String::from_utf8_lossy(message).into_owned(),
            FromPane::Head(_) => {}
            other => panic!("unexpected frame {other:?}"),
        }
    };
    assert_eq!(error, "invalid control frame");
    pane.drain();
    assert_eq!(pane.seen.resizes, [size(4096, 24)]);
}

impl Harness {
    fn pump_until(&mut self, done: impl Fn(&Seen) -> bool) {
        while !done(&self.seen) {
            let bytes = self.receive();
            self.drain();
            if let Some(FromPane::Full(_)) = frame::decode(&bytes).unwrap() {
                let tail = self.cursor;
                self.send(&encoded(&ToPane::Tail(tail)));
            }
        }
    }
}

#[test]
fn a_control_frame_is_handled_while_the_program_keeps_the_pty_readable() {
    let mut pane = Harness::start(1 << 16);
    pane.send(&init(&["/usr/bin/yes"], "/"));
    pane.pump_until(|seen| seen.offset > 1 << 20);
    pane.send(&encoded(&ToPane::Resize(size(40, 20))));
    pane.pump_until(|seen| !seen.resizes.is_empty());
    assert_eq!(pane.seen.resizes, [size(40, 20)]);
    pane.pump_until(|seen| seen.offset > 2 << 20);
    assert_eq!(pane.finish(), Waited::Ended(Exit::Exited(0)));
}
