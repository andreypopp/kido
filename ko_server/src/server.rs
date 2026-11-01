use std::io;
use std::os::fd::AsFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::time::Duration;

use ko_pane_wire::ring::Reader;
use ko_sys::event::{Events, Interest, Mode, Poll, Ready, Timer, Token};
use ko_sys::signal::{Signal, Signals};

use crate::config::Config;
use crate::ids::PaneId;
use crate::pane::Pane;
use crate::pane_proc::{Delivery, Event, Io};
use crate::panes::{AddError, Create, Panes};

const ACCEPT_BURST: usize = 16;
const SEND_BUFFER: usize = 1 << 20;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Timing {
    pub accept_retry: Duration,
    pub output_tick: Duration,
    pub shutdown_grace: Duration,
}

impl Timing {
    pub const DEFAULT: Timing = Timing {
        accept_retry: Duration::from_millis(100),
        output_tick: Duration::from_millis(2),
        shutdown_grace: Duration::from_millis(500),
    };
}

#[derive(Debug)]
pub struct Verified(UnixStream);

impl Verified {
    pub fn into_stream(self) -> UnixStream {
        self.0
    }
}

fn admit(stream: UnixStream) -> Option<Verified> {
    let same = ko_sys::sock::peer_uid(stream.as_fd()).ok()? == ko_sys::sock::uid();
    let ready = same
        && ko_sys::sock::set_send_buffer(stream.as_fd(), SEND_BUFFER).is_ok()
        && stream.set_nonblocking(true).is_ok();
    ready.then_some(Verified(stream))
}

#[derive(Debug)]
struct Listener {
    socket: UnixListener,
    token: Token,
    resume: Timer,
    retry: Duration,
}

impl Listener {
    fn new(socket: UnixListener, poll: &mut Poll, retry: Duration) -> io::Result<Listener> {
        socket.set_nonblocking(true)?;
        Ok(Listener {
            token: poll.watch(socket.as_fd(), Interest::Read),
            socket,
            resume: poll.timer(),
            retry,
        })
    }

    fn accept(&self, poll: &mut Poll, accepted: &mut Vec<Verified>) -> io::Result<()> {
        for _ in 0..ACCEPT_BURST {
            match ko_sys::retry::retry(|| self.socket.accept()) {
                Ok((stream, _)) => accepted.extend(admit(stream)),
                Err(error) if error.raw_os_error() == Some(libc::ECONNABORTED) => {}
                Err(error)
                    if matches!(
                        error.raw_os_error(),
                        Some(libc::EMFILE | libc::ENFILE | libc::ENOBUFS | libc::ENOMEM)
                    ) =>
                {
                    poll.interest(self.token, Interest::Idle);
                    return poll.start(self.resume, self.retry, None);
                }
                Err(_) => break,
            }
        }
        Ok(())
    }

    fn resume(&self, poll: &mut Poll) {
        poll.interest(self.token, Interest::Read);
    }

    fn close(self, poll: &mut Poll) {
        poll.unwatch(self.token);
        poll.free(self.resume);
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Running,
    Stopped,
}

#[derive(Debug)]
pub struct Server {
    config: Config,
    timing: Timing,
    poll: Poll,
    events: Events,
    signals: Signals,
    signal_token: Token,
    listener: Option<Listener>,
    panes: Panes,
    ticker: Timer,
    stopping: Option<Timer>,
    produced: Vec<Event>,
}

pub type PaneSink<'a> = &'a mut dyn FnMut(PaneId, &Reader, Delivery);

fn io<'a>(
    poll: &'a mut Poll,
    events: &'a mut Vec<Event>,
    sink: Option<crate::pane_proc::Sink<'a>>,
) -> Io<'a> {
    Io { poll, events, sink }
}

fn handle(
    pane: &mut Pane,
    poll: &mut Poll,
    ticker: Timer,
    timing: Timing,
    produced: &mut Vec<Event>,
    sink: PaneSink<'_>,
) -> io::Result<()> {
    let id = pane.id();
    let mut events = std::mem::take(produced);
    for event in events.drain(..) {
        if event == Event::Output {
            let leading = !poll.is_active(ticker);
            if leading {
                poll.start(ticker, timing.output_tick, Some(timing.output_tick))?;
            }
            if leading || !pane.proc().busy() {
                let mut inner = |ring: &Reader, delivery| sink(id, ring, delivery);
                pane.proc_mut()
                    .scan(&mut io(poll, produced, Some(&mut inner)));
            }
        }
    }
    produced.clear();
    *produced = events;
    Ok(())
}

impl Server {
    pub fn new(config: Config, socket: UnixListener, timing: Timing) -> io::Result<Server> {
        let signals = Signals::install(&[Signal::Child, Signal::Term])?;
        let mut poll = Poll::new();
        let signal_token = poll.watch(signals.fd(), Interest::Read);
        let listener = Listener::new(socket, &mut poll, timing.accept_retry)?;
        let ticker = poll.timer();
        Ok(Server {
            config,
            timing,
            poll,
            events: Events::default(),
            signals,
            signal_token,
            listener: Some(listener),
            panes: Panes::default(),
            ticker,
            stopping: None,
            produced: Vec::new(),
        })
    }

    pub fn panes(&self) -> &Panes {
        &self.panes
    }

    pub fn add_pane(&mut self, request: &Create) -> Result<PaneId, AddError> {
        let added = self.panes.add(
            &self.config,
            request,
            &mut io(&mut self.poll, &mut self.produced, None),
        );
        self.produced.clear();
        added
    }

    pub fn turn(&mut self, accepted: &mut Vec<Verified>, sink: PaneSink<'_>) -> io::Result<Status> {
        let mut events = std::mem::take(&mut self.events);
        let turned = self.poll.turn(Mode::Wait, &mut events).and_then(|()| {
            for &ready in events.ready() {
                self.ready(ready, accepted, &mut *sink)?;
            }
            for &due in events.due() {
                if self.poll.current(due) && self.due(due.timer, &mut *sink)? == Status::Stopped {
                    return Ok(Status::Stopped);
                }
            }
            Ok(Status::Running)
        });
        self.events = events;
        turned
    }

    fn ready(
        &mut self,
        ready: Ready,
        accepted: &mut Vec<Verified>,
        sink: PaneSink<'_>,
    ) -> io::Result<()> {
        if ready.token == self.signal_token {
            if self.poll.wants(ready).read {
                let mut pending = Vec::new();
                self.signals.take(&mut pending)?;
                for signal in pending {
                    match signal {
                        Signal::Child => {
                            self.panes
                                .reap(&mut io(&mut self.poll, &mut self.produced, None))?;
                            self.produced.clear();
                        }
                        Signal::Term => self.stop()?,
                        _ => {}
                    }
                }
            }
        } else if let Some(listener) = self.listener.as_ref().filter(|l| l.token == ready.token) {
            if self.poll.wants(ready).read {
                listener.accept(&mut self.poll, accepted)?;
            }
        } else if let Some(pane) = self.panes.by_token(ready.token) {
            let id = pane.id();
            let mut inner = |ring: &Reader, delivery| sink(id, ring, delivery);
            pane.proc_mut().ready(
                ready,
                &mut io(&mut self.poll, &mut self.produced, Some(&mut inner)),
            );
            handle(
                pane,
                &mut self.poll,
                self.ticker,
                self.timing,
                &mut self.produced,
                sink,
            )?;
        }
        Ok(())
    }

    pub fn stop(&mut self) -> io::Result<()> {
        if self.stopping.is_some() {
            return Ok(());
        }
        if let Some(listener) = self.listener.take() {
            listener.close(&mut self.poll);
        }
        self.panes
            .shutdown(&mut io(&mut self.poll, &mut self.produced, None));
        self.produced.clear();
        self.poll.stop(self.ticker);
        let stopping = self.poll.timer();
        self.poll
            .start(stopping, self.timing.shutdown_grace, None)?;
        self.stopping = Some(stopping);
        Ok(())
    }

    fn due(&mut self, timer: Timer, sink: PaneSink<'_>) -> io::Result<Status> {
        if let Some(listener) = self.listener.as_ref().filter(|l| l.resume == timer) {
            listener.resume(&mut self.poll);
        } else if timer == self.ticker {
            let mut produced = false;
            for pane in self.panes.iter_mut() {
                let id = pane.id();
                let mut inner = |ring: &Reader, delivery| sink(id, ring, delivery);
                produced |= pane.proc_mut().scan(&mut io(
                    &mut self.poll,
                    &mut self.produced,
                    Some(&mut inner),
                ));
            }
            if !produced {
                self.poll.stop(self.ticker);
            }
            self.produced.clear();
        } else if Some(timer) == self.stopping {
            self.panes.kill()?;
            self.panes
                .reap(&mut io(&mut self.poll, &mut self.produced, None))?;
            self.produced.clear();
            match std::fs::remove_file(&self.config.socket) {
                Err(error) if error.kind() != io::ErrorKind::NotFound => return Err(error),
                _ => {}
            }
            return Ok(Status::Stopped);
        }
        Ok(Status::Running)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::process::Command;

    fn scratch(name: &str) -> PathBuf {
        let dir = PathBuf::from(format!("/tmp/ko-{name}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn turn(poll: &mut Poll, listener: &Listener, accepted: &mut Vec<Verified>) {
        let mut events = Events::default();
        poll.turn(Mode::Peek, &mut events).unwrap();
        for &ready in events.ready() {
            if poll.wants(ready).read && ready.token == listener.token {
                listener.accept(poll, accepted).unwrap();
            }
        }
    }

    #[test]
    fn the_listener_accepts_at_most_sixteen_per_turn() {
        let dir = scratch("burst");
        let path = dir.join("socket");
        let mut poll = Poll::new();
        let listener = Listener::new(
            UnixListener::bind(&path).unwrap(),
            &mut poll,
            Duration::from_millis(1),
        )
        .unwrap();
        let clients: Vec<_> = (0..20)
            .map(|_| UnixStream::connect(&path).unwrap())
            .collect();
        let mut accepted = Vec::new();
        turn(&mut poll, &listener, &mut accepted);
        assert_eq!(accepted.len(), 16);
        turn(&mut poll, &listener, &mut accepted);
        assert_eq!(accepted.len(), 20);
        drop(clients);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn the_listener_parks_under_descriptor_shortage_and_accepts_again() {
        let exe = std::env::current_exe().unwrap();
        let status = Command::new("/bin/sh")
            .args(["-c", "ulimit -n 64 && exec \"$0\" \"$@\""])
            .arg(exe)
            .args(["--ignored", "--exact", "server::tests::descriptor_shortage"])
            .status()
            .unwrap();
        assert!(status.success());
    }

    #[test]
    #[ignore = "run with a lowered descriptor limit by the test above"]
    fn descriptor_shortage() {
        let dir = scratch("shortage");
        let path = dir.join("socket");
        let mut poll = Poll::new();
        let listener = Listener::new(
            UnixListener::bind(&path).unwrap(),
            &mut poll,
            Duration::from_millis(1),
        )
        .unwrap();
        let null = std::fs::File::open("/dev/null").unwrap();
        let mut filler = Vec::new();
        while let Ok(copy) = null.try_clone() {
            filler.push(copy);
        }
        filler.truncate(filler.len() - 3);
        let first = UnixStream::connect(&path).unwrap();
        let second = UnixStream::connect(&path).unwrap();
        let mut accepted = Vec::new();
        turn(&mut poll, &listener, &mut accepted);
        assert_eq!(accepted.len(), 1);
        assert_eq!(poll.interest_of(listener.token), Interest::Idle);
        assert!(poll.is_active(listener.resume));
        // macOS drops the connection that accept refused for want of a descriptor.
        filler.truncate(filler.len() - 2);
        let third = UnixStream::connect(&path).unwrap();
        let mut events = Events::default();
        let deadline = poll.timer();
        poll.start(deadline, Duration::from_secs(5), None).unwrap();
        while accepted.len() < 2 && poll.is_active(deadline) {
            poll.turn(Mode::Wait, &mut events).unwrap();
            for &due in events.due() {
                if due.timer == listener.resume {
                    listener.resume(&mut poll);
                }
            }
            for &ready in events.ready() {
                if poll.wants(ready).read {
                    listener.accept(&mut poll, &mut accepted).unwrap();
                }
            }
        }
        assert_eq!(accepted.len(), 2);
        drop((first, second, third, filler));
        std::fs::remove_dir_all(dir).unwrap();
    }

    fn ko_pane() -> PathBuf {
        PathBuf::from(
            std::env::var_os("KO_PANE_EXE")
                .expect("KO_PANE_EXE names the C ko-pane; make test-ko builds it and sets it"),
        )
    }

    fn within(deadline: Duration, mut done: impl FnMut() -> bool) -> bool {
        let end = std::time::Instant::now() + deadline;
        while !done() {
            if std::time::Instant::now() > end {
                return false;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        true
    }

    #[test]
    fn sigterm_stops_the_server_and_ends_its_programs() {
        use ko_sys::pid::Pid;
        use std::io::BufRead;
        let mut child = Command::new(std::env::current_exe().unwrap())
            .args([
                "--ignored",
                "--exact",
                "server::tests::sigterm",
                "--nocapture",
            ])
            .env("KO_PANE_EXE", ko_pane())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        let mut lines = std::io::BufReader::new(child.stdout.take().unwrap()).lines();
        let program = lines
            .by_ref()
            .map_while(Result::ok)
            .find_map(|line| line.strip_prefix("program ").map(str::to_owned))
            .unwrap();
        Pid::new(i64::from(child.id()))
            .unwrap()
            .signal(Signal::Term)
            .unwrap();
        assert!(within(Duration::from_secs(10), || child
            .try_wait()
            .unwrap()
            .is_some()));
        assert!(child.wait().unwrap().success());
        drop(lines);
        let gone = || {
            !Command::new("/bin/ps")
                .args(["-p", &program])
                .stdout(std::process::Stdio::null())
                .status()
                .unwrap()
                .success()
        };
        assert!(within(Duration::from_secs(5), gone));
    }

    #[test]
    #[ignore = "run in its own process, which the test above signals"]
    fn sigterm() {
        std::thread::spawn(|| {
            std::thread::sleep(Duration::from_secs(10));
            std::process::exit(1);
        });
        let dir = scratch("sigterm");
        let socket = dir.join("socket");
        let config = Config {
            dir: dir.clone(),
            socket: socket.clone(),
            pane_exe: ko_pane(),
            terminfo: dir.clone(),
            shell: PathBuf::from("/bin/sh"),
            limits: crate::config::DEFAULT_LIMITS,
            media: Vec::new(),
            env: Vec::new(),
            cwd: PathBuf::from("/"),
        };
        let timing = Timing {
            shutdown_grace: Duration::from_millis(100),
            ..Timing::DEFAULT
        };
        let mut server = Server::new(config, UnixListener::bind(&socket).unwrap(), timing).unwrap();
        let request = Create {
            cwd: None,
            command: Some(crate::panes::Command::Argv(vec![
                "/bin/sleep".to_owned(),
                "30".to_owned(),
            ])),
            env: Vec::new(),
        };
        let id = server.add_pane(&request).unwrap();
        let mut accepted = Vec::new();
        let program = loop {
            server.turn(&mut accepted, &mut |_, _, _| {}).unwrap();
            let pane = server.panes().find(id).unwrap();
            if let Some(pid) = pane.proc().child_pid() {
                break pid;
            }
        };
        println!("program {program}");
        while server.turn(&mut accepted, &mut |_, _, _| {}).unwrap() == Status::Running {}
        assert!(
            server
                .panes()
                .iter()
                .all(|pane| pane.proc().life() == crate::pane_proc::Life::Reaped)
        );
        assert!(!socket.exists());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
