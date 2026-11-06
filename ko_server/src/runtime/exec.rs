use std::collections::VecDeque;
use std::fs::File;
use std::io;
use std::os::fd::{AsFd, OwnedFd};
use std::path::PathBuf;

use ko_sys::event::{Interest, Poll, Timer, Token};
use ko_sys::pid::{Exit, Pid, Waited};
use ko_sys::signal::Signal;
use ko_sys::spawn;

use crate::exec_wire::{Frames, FromKo, Invalid, ToKo};
use crate::protocol::{Ended, ExecClient, ExecRequest, STDERR_TAIL};
use crate::runtime::RuntimeKey;

pub(crate) const MAX_SESSIONS: usize = 32;
const MAX_BACKLOG: usize = 16;
const READS_PER_TURN: usize = 16;
const CAPTURE_LIMIT: usize = 1 << 20;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Admit {
    Run,
    Wait,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Retry {
    Now,
    Later,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Limiter {
    cap: usize,
    running: usize,
    ends: u64,
    waiting: VecDeque<Token>,
    parked: Vec<Token>,
}

impl Limiter {
    pub(crate) fn new(cap: usize) -> Limiter {
        Limiter {
            cap,
            running: 0,
            ends: 0,
            waiting: VecDeque::new(),
            parked: Vec::new(),
        }
    }

    #[cfg(test)]
    pub(crate) fn sessions(&self) -> usize {
        self.running
            .saturating_add(self.waiting.len())
            .saturating_add(self.parked.len())
    }

    pub(crate) fn join(&mut self, ticket: Token) -> Admit {
        if self.running < self.cap && self.waiting.is_empty() {
            self.running = self.running.saturating_add(1);
            Admit::Run
        } else {
            self.waiting.push_back(ticket);
            Admit::Wait
        }
    }

    fn fill(&mut self, parked_first: bool) -> Vec<Token> {
        let mut start = Vec::new();
        while self.running < self.cap {
            let next = if parked_first && !self.parked.is_empty() {
                Some(self.parked.remove(0))
            } else {
                self.waiting.pop_front()
            };
            let Some(ticket) = next else {
                break;
            };
            self.running = self.running.saturating_add(1);
            start.push(ticket);
        }
        start
    }

    // How many sessions have ended: a refused session that started before the latest end can
    // try again at once.
    pub(crate) fn ends(&self) -> u64 {
        self.ends
    }

    pub(crate) fn leave(&mut self) -> Vec<Token> {
        self.ends = self.ends.saturating_add(1);
        self.running = self.running.saturating_sub(1);
        self.fill(true)
    }

    pub(crate) fn retry(&mut self, ticket: Token, started: u64) -> (Retry, Vec<Token>) {
        self.running = self.running.saturating_sub(1);
        if self.running == 0 || self.ends > started {
            self.running = self.running.saturating_add(1);
            let mut start = self.fill(false);
            start.insert(0, ticket);
            return (Retry::Now, start);
        }
        self.parked.push(ticket);
        (Retry::Later, self.fill(false))
    }

    pub(crate) fn forget(&mut self, ticket: Token) {
        self.waiting.retain(|waiting| *waiting != ticket);
        self.parked.retain(|parked| *parked != ticket);
    }
}

#[derive(Debug)]
pub(crate) struct Launch {
    pub(crate) program: PathBuf,
    pub(crate) args: Vec<String>,
    pub(crate) env: Vec<Vec<u8>>,
}

impl Launch {
    pub(crate) fn new(program: PathBuf, args: Vec<String>, env: &[Vec<u8>]) -> Launch {
        Launch {
            program,
            args,
            env: env.to_vec(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Mode {
    Capture {
        stdin: bool,
    },
    /// An exec session's helper: frames on its stdin and stdout, the transport's own words on
    /// its stderr.
    Session,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Stream {
    Stdout,
    Stderr,
}

#[derive(Debug)]
struct Reader {
    fd: OwnedFd,
    token: Token,
    open: bool,
}

#[derive(Debug)]
struct Stdin {
    fd: OwnedFd,
    token: Token,
    pending: Vec<u8>,
    sent: usize,
    closing: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Source {
    Stdin,
    Output,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Chunk {
    Data(usize),
    Wait,
    End,
}

#[derive(Debug)]
struct Framed {
    reader: Reader,
    frames: Frames,
    ended: Option<Ended>,
    broken: Option<Invalid>,
}

#[derive(Debug)]
enum Stdout {
    Raw(Reader),
    Framed(Box<Framed>),
}

impl Stdout {
    fn reader(&self) -> &Reader {
        match self {
            Stdout::Raw(reader) => reader,
            Stdout::Framed(framed) => &framed.reader,
        }
    }
}

#[derive(Debug)]
pub(crate) struct Helper {
    pid: Pid,
    stdin: Option<Stdin>,
    stdout: Stdout,
    stderr: Reader,
    exit: Option<Exit>,
    tail: Vec<u8>,
    out: Vec<u8>,
}

fn reader(poll: &mut Poll, pipe: io::PipeReader) -> io::Result<Reader> {
    let fd = OwnedFd::from(pipe);
    ko_sys::fd::set_nonblocking(fd.as_fd())?;
    Ok(Reader {
        token: poll.watch(fd.as_fd(), Interest::Read),
        fd,
        open: true,
    })
}

pub(crate) fn spawn(poll: &mut Poll, launch: &Launch, mode: Mode) -> io::Result<Helper> {
    let (out_read, out_write) = io::pipe()?;
    let (err_read, err_write) = io::pipe()?;
    let (in_read, in_write) = io::pipe()?;
    let null = File::options().read(true).write(true).open("/dev/null")?;
    let args: Vec<&str> = launch.args.iter().map(String::as_str).collect();
    let stdin = match mode {
        Mode::Capture { stdin } => stdin,
        Mode::Session => true,
    };
    let pid = spawn::program(
        &launch.program,
        &args,
        &[
            (if stdin { in_read.as_fd() } else { null.as_fd() }, 0),
            (out_write.as_fd(), 1),
            (err_write.as_fd(), 2),
        ],
        spawn::Env::Only(&launch.env),
        None,
    )?;
    drop((out_write, err_write, in_read));
    let stdin = if stdin {
        let fd = OwnedFd::from(in_write);
        ko_sys::fd::set_nonblocking(fd.as_fd())?;
        Some(Stdin {
            token: poll.watch(fd.as_fd(), Interest::Idle),
            fd,
            pending: Vec::new(),
            sent: 0,
            closing: false,
        })
    } else {
        None
    };
    let stdout = reader(poll, out_read)?;
    Ok(Helper {
        pid,
        stdin,
        stdout: match mode {
            Mode::Capture { .. } => Stdout::Raw(stdout),
            Mode::Session => Stdout::Framed(Box::new(Framed {
                reader: stdout,
                frames: Frames::default(),
                ended: None,
                broken: None,
            })),
        },
        stderr: reader(poll, err_read)?,
        exit: None,
        tail: Vec::new(),
        out: Vec::new(),
    })
}

pub(crate) fn detached(launch: &Launch) -> io::Result<Pid> {
    let null = File::options().read(true).write(true).open("/dev/null")?;
    let args: Vec<&str> = launch.args.iter().map(String::as_str).collect();
    spawn::program(
        &launch.program,
        &args,
        &[(null.as_fd(), 0), (null.as_fd(), 1), (null.as_fd(), 2)],
        spawn::Env::Only(&launch.env),
        None,
    )
}

fn read_reader(poll: &mut Poll, reader: &mut Reader, buffer: &mut [u8]) -> Chunk {
    if !reader.open {
        return Chunk::End;
    }
    match ko_sys::fd::read(reader.fd.as_fd(), buffer) {
        Ok(count) if count > 0 => Chunk::Data(count),
        Err(error) if error.kind() == io::ErrorKind::WouldBlock => Chunk::Wait,
        _ => {
            reader.open = false;
            poll.unwatch(reader.token);
            Chunk::End
        }
    }
}

impl Helper {
    pub(crate) fn owns(&self, token: Token) -> Option<Source> {
        if self
            .stdin
            .as_ref()
            .is_some_and(|stdin| stdin.token == token)
        {
            Some(Source::Stdin)
        } else if self
            .readers()
            .any(|reader| reader.open && reader.token == token)
        {
            Some(Source::Output)
        } else {
            None
        }
    }

    fn readers(&self) -> impl Iterator<Item = &Reader> {
        [self.stdout.reader(), &self.stderr].into_iter()
    }

    pub(crate) fn backed_up(&self) -> bool {
        self.stdin
            .as_ref()
            .is_some_and(|stdin| stdin.sent < stdin.pending.len())
    }

    pub(crate) fn pid(&self) -> Pid {
        self.pid
    }

    pub(crate) fn write_stdin(&mut self, poll: &mut Poll, bytes: Vec<u8>) {
        let Some(stdin) = &mut self.stdin else {
            return;
        };
        if stdin.sent >= stdin.pending.len() {
            stdin.pending = bytes;
            stdin.sent = 0;
        } else {
            stdin.pending.extend_from_slice(&bytes);
        }
        self.flush_stdin(poll);
    }

    pub(crate) fn send(&mut self, poll: &mut Poll, message: &ToKo<'_>) {
        let Some(stdin) = &mut self.stdin else {
            return;
        };
        if stdin.sent >= stdin.pending.len() {
            stdin.pending.clear();
            stdin.sent = 0;
        }
        message.encode(&mut stdin.pending);
        self.flush_stdin(poll);
    }

    pub(crate) fn flush_stdin(&mut self, poll: &mut Poll) {
        let Some(stdin) = &mut self.stdin else {
            return;
        };
        while let Some(rest) = stdin
            .pending
            .get(stdin.sent..)
            .filter(|rest| !rest.is_empty())
        {
            match ko_sys::fd::write(stdin.fd.as_fd(), rest) {
                Ok(count) if count > 0 => stdin.sent = stdin.sent.saturating_add(count),
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                _ => stdin.sent = stdin.pending.len(),
            }
        }
        if stdin.sent >= stdin.pending.len() {
            stdin.pending.clear();
            stdin.sent = 0;
            if stdin.closing {
                return self.close_stdin(poll);
            }
        }
        let wanted = if stdin.pending.is_empty() {
            Interest::Idle
        } else {
            Interest::Write
        };
        poll.interest(stdin.token, wanted);
    }

    pub(crate) fn close_stdin(&mut self, poll: &mut Poll) {
        let Some(stdin) = &mut self.stdin else {
            return;
        };
        if stdin.pending.is_empty() {
            poll.unwatch(stdin.token);
            self.stdin = None;
        } else {
            stdin.closing = true;
        }
    }

    /// A read of the transport's own words, or of a capture's stdout.
    pub(crate) fn read(
        &mut self,
        poll: &mut Poll,
        stream: Stream,
        scratch: &mut [u8],
        wanted: usize,
    ) -> Chunk {
        let reader = match (stream, &mut self.stdout) {
            (Stream::Stdout, Stdout::Raw(reader)) => reader,
            (Stream::Stdout, Stdout::Framed(_)) => return Chunk::End,
            (Stream::Stderr, _) => &mut self.stderr,
        };
        let wanted = wanted.min(scratch.len());
        let Some(buffer) = scratch.get_mut(..wanted) else {
            return Chunk::End;
        };
        let chunk = read_reader(poll, reader, buffer);
        if let (Chunk::Data(count), Stream::Stderr) = (chunk, stream) {
            self.tail
                .extend_from_slice(scratch.get(..count).unwrap_or_default());
            let excess = self.tail.len().saturating_sub(STDERR_TAIL);
            self.tail.drain(..excess);
        }
        chunk
    }

    pub(crate) fn collect(&mut self, poll: &mut Poll) {
        let mut buffer = [0u8; 4096];
        for stream in [Stream::Stdout, Stream::Stderr] {
            for _ in 0..READS_PER_TURN {
                let Chunk::Data(count) = self.read(poll, stream, &mut buffer, 4096) else {
                    break;
                };
                let data = buffer.get(..count).unwrap_or_default();
                if stream == Stream::Stdout {
                    let room = CAPTURE_LIMIT.saturating_sub(self.out.len());
                    self.out
                        .extend_from_slice(data.get(..room.min(count)).unwrap_or_default());
                }
            }
        }
    }

    /// The next bytes that the command wrote, from the ko's frames, at most `wanted` of them.
    /// A call reads the pipe at most once, and only when no whole frame is buffered.
    pub(crate) fn output(&mut self, poll: &mut Poll, wanted: usize) -> Option<(Stream, Vec<u8>)> {
        let Stdout::Framed(framed) = &mut self.stdout else {
            return None;
        };
        let Framed {
            reader,
            frames,
            ended,
            broken,
        } = &mut **framed;
        if wanted == 0 || broken.is_some() {
            return None;
        }
        let mut read = false;
        loop {
            match frames.from_ko(wanted) {
                Ok(Some(FromKo::Stdout(data))) if !data.is_empty() => {
                    return Some((Stream::Stdout, data.to_vec()));
                }
                Ok(Some(FromKo::Stderr(data))) if !data.is_empty() => {
                    return Some((Stream::Stderr, data.to_vec()));
                }
                Ok(Some(FromKo::Exit(done))) => {
                    ended.get_or_insert(done);
                }
                Ok(Some(_)) => {}
                Ok(None) if !read && reader.open => {
                    read = true;
                    let filled = frames.fill(|buffer| match read_reader(poll, reader, buffer) {
                        Chunk::Data(count) => Ok(count),
                        Chunk::Wait => Err(io::ErrorKind::WouldBlock.into()),
                        Chunk::End => Ok(0),
                    });
                    if matches!(filled, Ok(0)) && !frames.is_empty() {
                        *broken = Some(Invalid::Truncated);
                    }
                }
                Ok(None) => return None,
                Err(invalid) => {
                    *broken = Some(invalid);
                    return None;
                }
            }
        }
    }

    pub(crate) fn ended(&self) -> Option<Ended> {
        match &self.stdout {
            Stdout::Framed(framed) => framed.ended,
            Stdout::Raw(_) => None,
        }
    }

    pub(crate) fn broken(&self) -> Option<Invalid> {
        match &self.stdout {
            Stdout::Framed(framed) => framed.broken,
            Stdout::Raw(_) => None,
        }
    }

    pub(crate) fn stdout(&self) -> &[u8] {
        &self.out
    }

    pub(crate) fn tail(&self) -> &[u8] {
        &self.tail
    }

    pub(crate) fn reading(&self, poll: &mut Poll, on: bool) {
        for reader in self.readers().filter(|reader| reader.open) {
            poll.interest(
                reader.token,
                if on { Interest::Read } else { Interest::Idle },
            );
        }
    }

    pub(crate) fn drained(&self) -> bool {
        self.readers().all(|reader| !reader.open)
            && match &self.stdout {
                Stdout::Raw(_) => true,
                Stdout::Framed(framed) => framed.frames.is_empty(),
            }
    }

    pub(crate) fn signal(&self, signal: Signal) {
        if self.exit.is_none() {
            let _ = self.pid.signal(signal);
        }
    }

    pub(crate) fn reap(&mut self) -> Option<Exit> {
        if self.exit.is_none() {
            self.exit = match self.pid.try_wait() {
                Ok(Waited::Running) | Err(_) => None,
                Ok(Waited::Ended(exit)) => Some(exit),
                Ok(Waited::NoChild) => Some(Exit::Exited(1)),
            };
        }
        self.exit
    }

    pub(crate) fn exit(&self) -> Option<Exit> {
        self.exit
    }

    pub(crate) fn release(&mut self, poll: &mut Poll) {
        let stdout = match &mut self.stdout {
            Stdout::Raw(reader) => reader,
            Stdout::Framed(framed) => &mut framed.reader,
        };
        for reader in [stdout, &mut self.stderr] {
            if reader.open {
                reader.open = false;
                poll.unwatch(reader.token);
            }
        }
        if let Some(stdin) = self.stdin.take() {
            poll.unwatch(stdin.token);
        }
    }
}

#[derive(Debug)]
pub(crate) struct Running {
    pub(crate) helper: Helper,
    pub(crate) request: ExecRequest,
    pub(crate) retried: bool,
    pub(crate) output: bool,
    pub(crate) fed: bool,
    pub(crate) started: u64,
}

#[derive(Debug)]
pub(crate) enum Stage {
    Open,
    Queued {
        request: ExecRequest,
        timer: Option<Timer>,
        retried: bool,
    },
    Running(Box<Running>),
    Ended,
}

#[derive(Debug)]
pub(crate) struct Session {
    pub(crate) runtime: RuntimeKey,
    pub(crate) stage: Stage,
    pub(crate) backlog: VecDeque<ExecClient>,
}

impl Session {
    pub(crate) fn new(runtime: RuntimeKey) -> Session {
        Session {
            runtime,
            stage: Stage::Open,
            backlog: VecDeque::new(),
        }
    }

    pub(crate) fn reads(&self) -> bool {
        match &self.stage {
            Stage::Open => true,
            Stage::Queued { .. } => self.backlog.len() < MAX_BACKLOG,
            Stage::Running(running) => !running.helper.backed_up(),
            Stage::Ended => false,
        }
    }

    pub(crate) fn paused(&self) -> bool {
        matches!(&self.stage, Stage::Running(running) if running.helper.backed_up())
    }

    pub(crate) fn live(&self) -> bool {
        !matches!(self.stage, Stage::Ended)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tickets(count: usize) -> Vec<Token> {
        let mut poll = Poll::new();
        let (a, _b) = std::os::unix::net::UnixStream::pair().unwrap();
        (0..count)
            .map(|_| poll.watch(a.as_fd(), Interest::Idle))
            .collect()
    }

    #[test]
    fn a_session_past_the_cap_waits_in_order_and_starts_when_one_ends() {
        let t = tickets(6);
        let mut limiter = Limiter::new(2);
        assert_eq!(
            [
                limiter.join(t[1]),
                limiter.join(t[2]),
                limiter.join(t[3]),
                limiter.join(t[4])
            ],
            [Admit::Run, Admit::Run, Admit::Wait, Admit::Wait]
        );
        assert_eq!(limiter.leave(), vec![t[3]]);
        assert_eq!(limiter.join(t[5]), Admit::Wait);
        assert_eq!(limiter.leave(), vec![t[4]]);
        assert_eq!(limiter.leave(), vec![t[5]]);
        assert_eq!(limiter.leave(), Vec::<Token>::new());
        assert_eq!(limiter.sessions(), 1);
    }

    #[test]
    fn a_waiting_session_that_gives_up_leaves_the_queue() {
        let t = tickets(4);
        let mut limiter = Limiter::new(1);
        limiter.join(t[1]);
        limiter.join(t[2]);
        limiter.join(t[3]);
        limiter.forget(t[2]);
        assert_eq!(limiter.leave(), vec![t[3]]);
    }

    #[test]
    fn a_refused_helper_retries_after_the_next_end_or_at_once_when_it_is_alone() {
        let t = tickets(8);
        let mut limiter = Limiter::new(2);
        limiter.join(t[1]);
        limiter.join(t[2]);
        limiter.join(t[3]);
        assert_eq!(limiter.retry(t[1], 0), (Retry::Later, vec![t[3]]));
        assert_eq!(limiter.sessions(), 3);
        assert_eq!(limiter.leave(), vec![t[1]]);
        assert_eq!(limiter.leave(), Vec::<Token>::new());
        assert_eq!(limiter.leave(), Vec::<Token>::new());
        let mut alone = Limiter::new(2);
        alone.join(t[7]);
        assert_eq!(alone.retry(t[7], 0), (Retry::Now, vec![t[7]]));
        assert_eq!(alone.sessions(), 1);
    }

    #[test]
    fn a_refused_session_retries_at_once_when_a_session_ended_since_it_started() {
        let t = tickets(4);
        let mut limiter = Limiter::new(3);
        limiter.join(t[1]);
        limiter.join(t[2]);
        limiter.join(t[3]);
        let started = limiter.ends();
        limiter.leave();
        assert_eq!(limiter.retry(t[3], started), (Retry::Now, vec![t[3]]));
        assert_eq!(limiter.sessions(), 2);

        let t = tickets(6);
        let mut capped = Limiter::new(2);
        for ticket in [t[1], t[2], t[3], t[4]] {
            capped.join(ticket);
        }
        let started = capped.ends();
        assert_eq!(capped.leave(), vec![t[3]]);
        assert_eq!(capped.retry(t[2], started), (Retry::Now, vec![t[2]]));
        assert_eq!(capped.running, 2, "t[4] stays queued");
        assert_eq!(capped.sessions(), 3);
    }

    #[test]
    fn a_request_needs_a_program_and_clean_words() {
        let request = |argv: &[&str], env: &[(&str, &str)]| ExecRequest {
            argv: argv.iter().map(|arg| (*arg).to_owned()).collect(),
            cwd: None,
            env: env
                .iter()
                .map(|(name, value)| ((*name).to_owned(), (*value).to_owned()))
                .collect(),
            stdin: false,
        };
        assert_eq!(request(&["sh"], &[("A", "1")]).invalid(), None);
        assert!(request(&[], &[]).invalid().is_some());
        assert!(request(&[""], &[]).invalid().is_some());
        assert!(request(&["a\0b"], &[]).invalid().is_some());
        assert!(request(&["sh"], &[("A=B", "1")]).invalid().is_some());
    }
}
