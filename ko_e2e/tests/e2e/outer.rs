use std::num::NonZeroUsize;
use std::os::fd::{AsFd, OwnedFd};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::thread;
use std::time::{Duration, Instant};

use ko_pane_wire::frame::{CellPx, Dim, Limits, Scrollback, ServedBuf, Size};
use ko_sys::fd;
use ko_sys::pid::Pid;
use ko_sys::pid::Program;
use ko_sys::pty::{self, Winsize};
use ko_sys::signal::Signal;
use ko_vt::render::{Cell, Frame};
use ko_vt::{Format, Report, Terminal};

use crate::harness::{DEADLINE, Dir, quote, test_env, text_of};

const OUTPUT_TAIL: usize = 12000;

const KITTY_QUERY: &[u8] = b"\x1b[?u";

pub(crate) const UP: &str = "\x1b[A";
pub(crate) const DOWN_PRESS_RELEASE: &str = "\x1b[1;1:1B\x1b[1;1:3B";
pub(crate) const FOCUS_IN: &str = "\x1b[I";
pub(crate) const FOCUS_OUT: &str = "\x1b[O";

// The DEC private modes that `modes` reports.
const MODES: [u16; 14] = [
    1, 7, 25, 1000, 1002, 1003, 1004, 1005, 1006, 1015, 1016, 1049, 2004, 2026,
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Keys {
    Extended,
    Unconfirmed,
}

#[derive(Debug)]
struct Shown {
    text: String,
    cursor: (bool, usize, usize),
    modes: Vec<u16>,
}

// A terminal paints between the start and the end of synchronized output only at the end; the
// tests read `shown`, which follows the terminal outside synchronized output.
#[derive(Debug)]
struct Screen {
    terminal: Terminal,
    raw: Vec<u8>,
    clipboard: Vec<u8>,
    rows: u16,
    shown: Shown,
    covered: usize,
    generation: u64,
}

impl Screen {
    fn refresh(&mut self) {
        self.generation += 1;
        if self.terminal.mode(2026).unwrap_or(false) {
            return;
        }
        self.covered = self.raw.len();
        let dump = self.terminal.dump(Format::Plain).unwrap();
        let dump = String::from_utf8_lossy(&dump);
        let mut text = String::new();
        let mut rows = 0;
        if !dump.is_empty() {
            for line in dump.trim_end_matches('\n').split('\n') {
                text.push_str(line.trim_end());
                text.push('\n');
                rows += 1;
            }
        }
        for _ in rows..self.rows {
            text.push('\n');
        }
        let cursor = self.terminal.cursor().unwrap();
        self.shown = Shown {
            text,
            cursor: (cursor.visible, usize::from(cursor.x), usize::from(cursor.y)),
            modes: MODES
                .iter()
                .copied()
                .filter(|number| self.terminal.mode(*number).unwrap_or(false))
                .collect(),
        };
    }
}

#[derive(Debug)]
struct Shared {
    screen: Mutex<Screen>,
    changed: Condvar,
}

#[derive(Debug)]
pub(crate) struct Outer {
    shared: Arc<Shared>,
    master: Arc<OwnedFd>,
    shell: Option<Program>,
    shell_pid: Pid,
    pub(crate) dir: Dir,
    pub(crate) executable: PathBuf,
    pub(crate) arguments: Vec<String>,
    pub(crate) env: Vec<Vec<u8>>,
    state: PathBuf,
    pidfile: PathBuf,
    attaches: AtomicUsize,
}

fn winsize(cols: u16, rows: u16) -> Winsize {
    Winsize::new(cols, rows, 8, 16)
}

fn dims(cols: u16, rows: u16) -> (Dim, Dim) {
    (Dim::new(cols).unwrap(), Dim::new(rows).unwrap())
}

fn write_all(master: &OwnedFd, mut bytes: &[u8]) -> std::io::Result<()> {
    let deadline = Instant::now() + DEADLINE;
    while !bytes.is_empty() {
        match fd::write(master.as_fd(), bytes) {
            Ok(count) => bytes = &bytes[count..],
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                let left = deadline.saturating_duration_since(Instant::now());
                if !fd::wait_writable_within(master.as_fd(), left)? {
                    return Err(std::io::ErrorKind::TimedOut.into());
                }
            }
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

// An outer terminal that does not confirm extended keys ignores the kitty keyboard query.
fn without_kitty_query(carry: &mut Vec<u8>, chunk: &[u8]) -> Vec<u8> {
    let mut input = std::mem::take(carry);
    input.extend_from_slice(chunk);
    let mut kept = Vec::with_capacity(input.len());
    let mut at = 0;
    while at < input.len() {
        if input[at..].starts_with(KITTY_QUERY) {
            at += KITTY_QUERY.len();
        } else if KITTY_QUERY.starts_with(&input[at..]) {
            carry.extend_from_slice(&input[at..]);
            break;
        } else {
            kept.push(input[at]);
            at += 1;
        }
    }
    kept
}

// Ends when the pty reports EOF: the shell and the client are gone.
fn pump(shared: &Shared, master: &OwnedFd, keys: Keys) {
    let mut carry = Vec::new();
    let mut buffer = vec![0u8; 65536];
    while fd::wait_readable(master.as_fd()).is_ok() {
        for _ in 0..64 {
            let count = match pty::read(master.as_fd(), &mut buffer) {
                Ok(0) => return,
                Ok(count) => count,
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
                Err(_) => return,
            };
            let replies = {
                let mut screen = shared.screen.lock().unwrap();
                screen.raw.extend_from_slice(&buffer[..count]);
                match keys {
                    Keys::Extended => screen.terminal.write(&buffer[..count]),
                    Keys::Unconfirmed => {
                        let input = without_kitty_query(&mut carry, &buffer[..count]);
                        screen.terminal.write(&input);
                    }
                }
                for report in std::mem::take(screen.terminal.reports()) {
                    match report {
                        Report::ClipboardRead { read, .. } => {
                            let served = ServedBuf::new(
                                [(&b"text/plain"[..], screen.clipboard.as_slice())].into_iter(),
                                [&b"text/plain"[..]].into_iter(),
                            )
                            .unwrap();
                            screen
                                .terminal
                                .complete_clipboard_read(read, Some(served.view()));
                        }
                        Report::ClipboardWrite { contents, .. } => {
                            if let Some((_, data)) = contents.into_iter().next() {
                                screen.clipboard = data;
                            }
                        }
                        _ => {}
                    }
                }
                std::mem::take(screen.terminal.replies())
            };
            if write_all(master, &replies).is_err() {
                return;
            }
        }
        shared.screen.lock().unwrap().refresh();
        shared.changed.notify_all();
    }
}

impl Outer {
    pub(crate) fn new(state: &Path, keys: Keys) -> Outer {
        let dir = Dir::new("ko-tui-");
        let mut env = test_env(&dir);
        env.extend([b"SHELL=/bin/sh".to_vec(), b"TERM=xterm-256color".to_vec()]);
        let pty = pty::spawn(winsize(120, 30), &dir, &[b"/bin/sh".to_vec()], &env)
            .unwrap_or_else(|error| panic!("outer shell: {error}"));
        let shell = pty
            .program
            .unwrap_or_else(|error| panic!("outer shell: {error}"));
        let shell_pid = shell.pid();
        let (cols, rows) = dims(120, 30);
        let mut terminal = Terminal::new(
            cols,
            rows,
            Limits {
                scrollback: Scrollback::Bounded {
                    max_bytes: NonZeroUsize::new(1 << 20),
                    max_lines: None,
                },
                apc_max_bytes: 1 << 20,
                kitty_images_max_bytes: 0,
                continuation_max_bytes: 1 << 20,
            },
        )
        .unwrap();
        terminal.serve(&[], "/tmp").unwrap();
        terminal.watch().unwrap();
        let mut screen = Screen {
            terminal,
            raw: Vec::new(),
            clipboard: Vec::new(),
            rows: 30,
            shown: Shown {
                text: String::new(),
                cursor: (true, 0, 0),
                modes: Vec::new(),
            },
            covered: 0,
            generation: 0,
        };
        screen.refresh();
        let shared = Arc::new(Shared {
            screen: Mutex::new(screen),
            changed: Condvar::new(),
        });
        let master = Arc::new(pty.master);
        {
            let (shared, master) = (shared.clone(), master.clone());
            thread::spawn(move || pump(&shared, &master, keys));
        }
        write_all(&master, b"set +m\rprintf 'OUTER%sSYNC\\n' -\r").unwrap();
        let outer = Outer {
            shared,
            master,
            shell: Some(shell),
            shell_pid,
            pidfile: dir.join("pid"),
            dir,
            executable: crate::harness::ko(),
            arguments: Vec::new(),
            env,
            state: state.to_path_buf(),
            attaches: AtomicUsize::new(0),
        };
        outer.wait("the outer shell to be ready", || {
            outer.screen().contains("OUTER-SYNC")
        });
        outer
    }

    fn lock(&self) -> MutexGuard<'_, Screen> {
        self.shared.screen.lock().unwrap()
    }

    pub(crate) fn shell_pid(&self) -> Pid {
        self.shell_pid
    }

    fn signal_shell(&self, signal: Signal) {
        if let Some(shell) = &self.shell {
            shell.signal(signal).unwrap();
        }
    }

    pub(crate) fn stop_shell(&self) {
        self.signal_shell(Signal::Stop);
    }

    pub(crate) fn resume_shell(&self) {
        self.signal_shell(Signal::Cont);
    }

    pub(crate) fn output(&self) -> Vec<u8> {
        self.lock().raw.clone()
    }

    pub(crate) fn clipboard(&self) -> Vec<u8> {
        self.lock().clipboard.clone()
    }

    pub(crate) fn set_clipboard(&self, text: &[u8]) {
        self.lock().clipboard = text.to_vec();
    }

    pub(crate) fn screen(&self) -> String {
        self.lock().shown.text.clone()
    }

    pub(crate) fn cell(&self, col: usize, row: usize) -> Cell {
        let mut frame = Frame::default();
        self.lock().terminal.render_into(&mut frame).unwrap();
        frame
            .cells
            .get(row * usize::from(frame.cols) + col)
            .cloned()
            .unwrap_or_default()
    }

    pub(crate) fn lines(&self) -> Vec<String> {
        self.screen().split('\n').map(str::to_owned).collect()
    }

    pub(crate) fn modes(&self) -> String {
        let set: Vec<String> = self.lock().shown.modes.iter().map(u16::to_string).collect();
        set.join(",")
    }

    pub(crate) fn mouse_reporting(&self) -> bool {
        let screen = self.lock();
        [1000, 1002, 1003]
            .iter()
            .any(|mode| screen.shown.modes.contains(mode))
            && screen.shown.modes.contains(&1006)
    }

    pub(crate) fn cursor(&self) -> (bool, usize, usize) {
        self.lock().shown.cursor
    }

    pub(crate) fn resize(&self, cols: u16, rows: u16) {
        let (width, height) = dims(cols, rows);
        let mut screen = self.lock();
        screen
            .terminal
            .resize(Size {
                cols: width,
                rows: height,
                cell_px: Some(CellPx::DEFAULT),
            })
            .unwrap();
        screen.rows = rows;
        screen.refresh();
        pty::set_size(&self.master, winsize(cols, rows)).unwrap();
    }

    pub(crate) fn within(&self, limit: Duration, mut check: impl FnMut() -> bool) -> bool {
        let deadline = Instant::now() + limit;
        loop {
            let seen = self.lock().generation;
            if check() {
                return true;
            }
            let Some(left) = deadline.checked_duration_since(Instant::now()) else {
                return false;
            };
            let _ = self.shared.changed.wait_timeout_while(
                self.lock(),
                left.min(Duration::from_millis(10)),
                |screen| screen.generation == seen,
            );
        }
    }

    pub(crate) fn wait(&self, what: &str, check: impl FnMut() -> bool) {
        assert!(
            self.within(DEADLINE, check),
            "wait for {what}; screen:\n{}",
            self.screen()
        );
    }

    pub(crate) fn contains(&self, text: &str) {
        self.wait(text, || self.screen().contains(text));
    }

    pub(crate) fn gone(&self, text: &str) {
        self.wait(&format!("{text} gone"), || !self.screen().contains(text));
    }

    pub(crate) fn raw(&self, text: &str) {
        write_all(&self.master, text.as_bytes())
            .unwrap_or_else(|error| panic!("write to the outer terminal: {error}"));
    }

    pub(crate) fn enter(&self) {
        self.raw("\r");
    }

    pub(crate) fn line(&self, text: &str) {
        self.raw(text);
        self.enter();
    }

    pub(crate) fn prefix(&self, key: &str) {
        self.raw(&format!("\x01{key}"));
    }

    pub(crate) fn ctrl(&self, key: char) {
        self.raw(&format!("\x1b[{};5u", u32::from(key)));
    }

    pub(crate) fn press(&self, col: usize, row: usize) {
        self.raw(&format!("\x1b[<0;{col};{row}M"));
    }

    pub(crate) fn click(&self, col: usize, row: usize) {
        self.press(col, row);
        self.raw(&format!("\x1b[<0;{col};{row}m"));
    }

    pub(crate) fn wheel_up(&self, col: usize, row: usize) {
        self.raw(&format!("\x1b[<64;{col};{row}M"));
    }

    pub(crate) fn attach(&self, pager: &str) {
        let state = format!("--server {}", quote(text_of(&self.state)));
        self.start(pager, "", &state);
    }

    pub(crate) fn attach_host(&self, host: &str, path_prefix: &Path) {
        let path = format!("PATH={}:\"$PATH\"", quote(text_of(path_prefix)));
        self.start("", &path, &quote(host));
    }

    fn start(&self, pager: &str, extra_env: &str, tail: &str) {
        let pager_env = if pager.is_empty() {
            "-u PAGER LESS=-RiF".to_owned()
        } else {
            format!("PAGER={}", quote(pager))
        };
        let mut program = quote(text_of(&self.executable));
        for argument in &self.arguments {
            program.push(' ');
            program.push_str(&quote(argument));
        }
        let command = format!(
            "/bin/sh -c {}; printf '\\nKO-DETACHED\\n'",
            quote(&format!(
                "echo $$ > {}; exec env {pager_env} {extra_env} {program} {tail}",
                quote(text_of(&self.pidfile)),
            ))
        );
        self.attaches.fetch_add(1, Ordering::Relaxed);
        self.line(&command);
    }

    pub(crate) fn client_pid(&self) -> Pid {
        let data = std::fs::read_to_string(&self.pidfile).unwrap();
        Pid::new(data.trim().parse().unwrap()).expect("a client pid")
    }

    pub(crate) fn shown_marks(&self, marker: &[u8]) -> usize {
        let screen = self.lock();
        screen.raw[..screen.covered]
            .windows(marker.len())
            .filter(|window| *window == marker)
            .count()
    }

    pub(crate) fn detached(&self) {
        self.wait("KO-DETACHED after each attach", || {
            self.shown_marks(b"\r\nKO-DETACHED\r\n") >= self.attaches.load(Ordering::Relaxed)
        });
    }

    pub(crate) fn detach(&self) {
        self.prefix("d");
        self.detached();
    }

    pub(crate) fn quiet(&self) {
        let mut size = usize::MAX;
        let mut changed = Instant::now();
        self.wait("terminal output becomes quiet", || {
            let length = self.lock().raw.len();
            if length != size {
                size = length;
                changed = Instant::now();
            }
            changed.elapsed() >= Duration::from_millis(200)
        });
    }
}

// Killing the shell hangs up the tty for the client, so the pump reads EOF and ends.
impl Drop for Outer {
    fn drop(&mut self) {
        if thread::panicking() {
            let raw = self.output();
            let tail = &raw[raw.len().saturating_sub(OUTPUT_TAIL)..];
            eprintln!("outer output: {:?}", String::from_utf8_lossy(tail));
            eprintln!("outer screen:\n{}", self.screen());
        }
        if let Some(shell) = self.shell.take() {
            let _ = shell.signal(Signal::Kill);
            thread::spawn(move || {
                let _ = shell.reap();
            });
        }
    }
}
