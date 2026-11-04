use std::fmt;
use std::io::{self, Read};
use std::os::fd::{AsFd, OwnedFd};
use std::time::Duration;

use ko_server::config::{env_path, overlay, program_path};
use ko_server::exec_wire::{Frames, FromKo, Start, ToKo};
use ko_server::protocol::{Ended, KillSignal};
use ko_sys::event::{Events, Interest, Mode, Poll, Timer, Token};
use ko_sys::fd::{self, Queue};
use ko_sys::pid::{Exit, Program};
use ko_sys::signal::{Signal, Signals};
use ko_sys::spawn::{self, Env};

use crate::enter::{Cwd, check_cwd};

const CHUNK: usize = 16 << 10;
const OUT_CAP: usize = 256 << 10;
const IN_CAP: usize = 128 << 10;

#[derive(Debug)]
pub enum Failure {
    Cwd(Cwd),
    NotFound(String),
    Spawn(String, io::Error),
    Io(io::Error),
}

impl Failure {
    pub fn status(&self) -> u8 {
        match self {
            Failure::NotFound(_) => 127,
            Failure::Spawn(_, error) if error.kind() == io::ErrorKind::NotFound => 127,
            Failure::Spawn(_, error) if error.kind() == io::ErrorKind::PermissionDenied => 126,
            _ => 1,
        }
    }
}

impl fmt::Display for Failure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Failure::Cwd(cwd) => cwd.fmt(f),
            Failure::NotFound(program) => write!(f, "{program}: command not found"),
            Failure::Spawn(program, error) => write!(f, "{program}: {error}"),
            Failure::Io(error) => error.fmt(f),
        }
    }
}

impl From<io::Error> for Failure {
    fn from(error: io::Error) -> Failure {
        Failure::Io(error)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum End {
    Reported,
    Cancelled,
}

#[derive(Debug)]
struct Link {
    fd: OwnedFd,
    token: Token,
}

#[derive(Debug)]
struct Feed {
    link: Link,
    queue: Queue,
    closing: bool,
}

#[derive(Debug, Clone, Copy)]
enum Stream {
    Stdout,
    Stderr,
}

// The leader's zombie stays until the session ends, so its group is never signalled after a
// reap.
#[derive(Debug)]
enum Command {
    Waiting,
    Alive(Program),
    Ended(Program, Exit),
    Reporting(Program),
}

#[derive(Debug)]
struct Inside {
    poll: Poll,
    inherited: Vec<Vec<u8>>,
    host_in: Link,
    frames: Frames,
    host_out: Link,
    out: Queue,
    feed: Option<Feed>,
    stdout: Option<Link>,
    stderr: Option<Link>,
    command: Command,
    grace: Timer,
    escalation: Duration,
    cancelled: bool,
}

#[derive(Debug)]
enum Step {
    Start(Start),
    Stdin,
    Eof,
    Signal(KillSignal),
    Idle,
    Bad,
}

fn link(poll: &mut Poll, fd: OwnedFd, interest: Interest) -> io::Result<Link> {
    fd::set_nonblocking(fd.as_fd())?;
    Ok(Link {
        token: poll.watch(fd.as_fd(), interest),
        fd,
    })
}

/// The command of an exec session, which the server's first frame names, in its own process
/// group, with frames on stdin and stdout. `inherited` is the environment that the command
/// starts from.
pub fn run(inherited: Vec<Vec<u8>>) -> Result<End, Failure> {
    let signals = Signals::install(&[Signal::Term, Signal::Hup, Signal::Int, Signal::Child])?;
    let mut poll = Poll::new();
    let signal_token = poll.watch(signals.fd(), Interest::Read);
    let mut inside = Inside {
        host_in: link(&mut poll, fd::inherited(0)?, Interest::Read)?,
        host_out: link(&mut poll, fd::inherited(1)?, Interest::Hangup)?,
        grace: poll.timer(),
        poll,
        inherited,
        frames: Frames::default(),
        out: Queue::default(),
        feed: None,
        stdout: None,
        stderr: None,
        command: Command::Waiting,
        escalation: Duration::ZERO,
        cancelled: false,
    };
    inside.serve(&signals, signal_token)
}

impl Inside {
    fn serve(&mut self, signals: &Signals, signal_token: Token) -> Result<End, Failure> {
        let mut events = Events::default();
        loop {
            if let Some(end) = self.settle() {
                return Ok(end);
            }
            self.poll.turn(Mode::Wait, &mut events)?;
            for ready in events.ready() {
                let token = ready.token;
                let hangup = self.poll.interest_of(token) == Interest::Hangup;
                if token == signal_token {
                    let mut pending = Vec::new();
                    signals.take(&mut pending)?;
                    if pending.iter().any(|signal| *signal != Signal::Child) {
                        self.cancel();
                    }
                } else if hangup && (token == self.host_in.token || token == self.host_out.token) {
                    self.cancel();
                } else if token == self.host_in.token {
                    self.read_host()?;
                } else if token == self.host_out.token {
                    self.flush_out();
                } else if self.feed.as_ref().is_some_and(|f| f.link.token == token) {
                    self.flush_feed();
                } else if self.stdout.as_ref().is_some_and(|l| l.token == token) {
                    self.forward(Stream::Stdout);
                } else if self.stderr.as_ref().is_some_and(|l| l.token == token) {
                    self.forward(Stream::Stderr);
                }
            }
            for due in events.due() {
                if self.poll.current(*due) && due.timer == self.grace {
                    return Ok(self.kill());
                }
            }
        }
    }

    // The leader's end, seen without reaping it. It reports whether the end came after a cancel.
    fn observe(&mut self) -> bool {
        match std::mem::replace(&mut self.command, Command::Waiting) {
            Command::Alive(program) => match program.peek_exit() {
                Ok(Some(exit)) => {
                    self.command = Command::Ended(program, exit);
                    self.cancelled
                }
                _ => {
                    self.command = Command::Alive(program);
                    false
                }
            },
            other => {
                self.command = other;
                false
            }
        }
    }

    fn take_ended(&mut self) -> Option<(Program, Exit)> {
        match std::mem::replace(&mut self.command, Command::Waiting) {
            Command::Ended(program, exit) => Some((program, exit)),
            other => {
                self.command = other;
                None
            }
        }
    }

    fn cancel(&mut self) {
        if self.cancelled {
            return;
        }
        self.cancelled = true;
        if let Command::Alive(program) | Command::Ended(program, _) = &self.command {
            let _ = program.signal(Signal::Term);
            let _ = self.poll.start(self.grace, self.escalation, None);
        }
    }

    fn kill(&mut self) -> End {
        if let Command::Alive(program) | Command::Ended(program, _) | Command::Reporting(program) =
            std::mem::replace(&mut self.command, Command::Waiting)
        {
            let _ = program.signal(Signal::Kill);
            let _ = program.reap();
        }
        End::Cancelled
    }

    fn settle(&mut self) -> Option<End> {
        let ended_after_cancel = self.observe();
        if !self.cancelled
            && self.stdout.is_none()
            && self.stderr.is_none()
            && let Some((program, exit)) = self.take_ended()
        {
            FromKo::Exit(Ended::from(exit)).encode(&mut self.out.bytes);
            self.command = Command::Reporting(program);
        }
        self.flush_out();
        self.flush_feed();
        self.interests();
        if self.cancelled {
            return match self.command {
                Command::Waiting | Command::Reporting(_) => Some(End::Cancelled),
                _ if ended_after_cancel => Some(self.kill()),
                _ => None,
            };
        }
        (matches!(self.command, Command::Reporting(_)) && self.out.is_empty())
            .then_some(End::Reported)
    }

    fn interests(&mut self) {
        let quiet = self.cancelled;
        let pending = self.feed.as_ref().map_or(0, |feed| feed.queue.bytes.len());
        let idle_or = |wanted: Interest| if quiet { Interest::Idle } else { wanted };
        self.poll.interest(
            self.host_in.token,
            idle_or(if pending < IN_CAP {
                Interest::Read
            } else {
                Interest::Hangup
            }),
        );
        self.poll.interest(
            self.host_out.token,
            idle_or(if self.out.is_empty() {
                Interest::Hangup
            } else {
                Interest::Write
            }),
        );
        if let Some(feed) = &self.feed {
            self.poll.interest(
                feed.link.token,
                if quiet || feed.queue.is_empty() {
                    Interest::Idle
                } else {
                    Interest::Write
                },
            );
        }
        let room = !quiet && self.out.bytes.len() < OUT_CAP;
        for reader in [&self.stdout, &self.stderr].into_iter().flatten() {
            self.poll.interest(
                reader.token,
                if room { Interest::Read } else { Interest::Idle },
            );
        }
    }

    fn flush_out(&mut self) {
        if self.cancelled || self.out.is_empty() {
            return;
        }
        if self.out.flush(self.host_out.fd.as_fd()).is_err() {
            self.cancel();
        } else if self.out.sent_past_half() {
            self.out.compact();
        }
    }

    fn flush_feed(&mut self) {
        let Some(feed) = &mut self.feed else {
            return;
        };
        if !self.cancelled
            && !feed.queue.is_empty()
            && feed.queue.flush(feed.link.fd.as_fd()).is_err()
        {
            feed.queue.clear();
            feed.closing = true;
        }
        if feed.closing
            && feed.queue.is_empty()
            && let Some(feed) = self.feed.take()
        {
            self.poll.unwatch(feed.link.token);
        }
    }

    fn read_host(&mut self) -> Result<(), Failure> {
        let host = self.host_in.fd.as_fd();
        match self.frames.fill(|buffer| fd::read(host, buffer)) {
            Ok(count) if count > 0 => {}
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => return Ok(()),
            _ => {
                self.cancel();
                return Ok(());
            }
        }
        loop {
            let waiting = matches!(self.command, Command::Waiting);
            let step = match self.frames.to_ko(usize::MAX) {
                Ok(Some(ToKo::Start(start))) if waiting => Step::Start(start),
                Ok(Some(ToKo::Stdin(bytes))) if !waiting => {
                    if let Some(feed) = &mut self.feed {
                        feed.queue.bytes.extend_from_slice(bytes);
                    }
                    Step::Stdin
                }
                Ok(Some(ToKo::Eof)) if !waiting => Step::Eof,
                Ok(Some(ToKo::Signal(signal))) if !waiting => Step::Signal(signal),
                Ok(None) => Step::Idle,
                Ok(Some(_)) | Err(_) => Step::Bad,
            };
            match step {
                Step::Start(start) => self.start(start)?,
                Step::Stdin => {}
                Step::Eof => {
                    if let Some(feed) = &mut self.feed {
                        feed.closing = true;
                    }
                }
                Step::Signal(signal) => {
                    if let Command::Alive(program) = &self.command {
                        let _ = program.signal(match signal {
                            KillSignal::Term => Signal::Term,
                            KillSignal::Kill => Signal::Kill,
                            KillSignal::Int => Signal::Int,
                        });
                    }
                }
                Step::Idle => return Ok(()),
                Step::Bad => {
                    self.cancel();
                    return Ok(());
                }
            }
        }
    }

    fn start(&mut self, start: Start) -> Result<(), Failure> {
        let program = start.argv.first().cloned().unwrap_or_default();
        let given: Vec<(&[u8], &[u8])> = start
            .env
            .iter()
            .map(|variable| (variable.name.as_bytes(), variable.value.as_bytes()))
            .collect();
        let env = overlay(&given, &self.inherited);
        let path = program_path(&String::from_utf8_lossy(env_path(&env)), &program)
            .ok_or_else(|| Failure::NotFound(program.clone()))?;
        let cwd = start
            .cwd
            .as_ref()
            .map(|cwd| std::path::Path::new(cwd.as_str()));
        if let Some(cwd) = cwd {
            check_cwd(cwd).map_err(Failure::Cwd)?;
        }
        let (in_read, in_write) = io::pipe()?;
        let (out_read, out_write) = io::pipe()?;
        let (err_read, err_write) = io::pipe()?;
        let args: Vec<&str> = start.argv.iter().skip(1).map(String::as_str).collect();
        let leader = spawn::grouped(
            &path,
            &args,
            &[
                (in_read.as_fd(), 0),
                (out_write.as_fd(), 1),
                (err_write.as_fd(), 2),
            ],
            Env::Only(&env),
            cwd,
        )
        .map_err(|error| Failure::Spawn(program, error))?;
        drop((in_read, out_write, err_write));
        self.command = Command::Alive(leader);
        self.escalation = Duration::from_millis(start.escalation_ms);
        self.feed = Some(Feed {
            link: link(&mut self.poll, OwnedFd::from(in_write), Interest::Idle)?,
            queue: Queue::default(),
            closing: false,
        });
        self.stdout = Some(link(
            &mut self.poll,
            OwnedFd::from(out_read),
            Interest::Read,
        )?);
        self.stderr = Some(link(
            &mut self.poll,
            OwnedFd::from(err_read),
            Interest::Read,
        )?);
        Ok(())
    }

    fn forward(&mut self, stream: Stream) {
        let slot = match stream {
            Stream::Stdout => &mut self.stdout,
            Stream::Stderr => &mut self.stderr,
        };
        let Some(source) = slot else {
            return;
        };
        let mut chunk = [0u8; CHUNK];
        match fd::read(source.fd.as_fd(), &mut chunk) {
            Ok(count) if count > 0 => {
                let data = chunk.get(..count).unwrap_or_default();
                match stream {
                    Stream::Stdout => FromKo::Stdout(data),
                    Stream::Stderr => FromKo::Stderr(data),
                }
                .encode(&mut self.out.bytes);
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
            _ => {
                self.poll.unwatch(source.token);
                *slot = None;
            }
        }
    }
}

/// Blocks until the input ends: the ko that a container's link holds to learn that the
/// container stopped.
pub fn watch() {
    let mut buffer = [0u8; 64];
    let mut stdin = io::stdin().lock();
    loop {
        match stdin.read(&mut buffer) {
            Ok(0) => return,
            Err(error) if error.kind() != io::ErrorKind::Interrupted => return,
            _ => {}
        }
    }
}
