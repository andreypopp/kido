use std::io;
use std::os::fd::AsFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::time::Duration;

use ko_config::values::RuntimeName;
use ko_sys::event::{Events, Interest, Mode, Poll, Timer, Token};
use ko_sys::signal::{Signal, Signals};

use crate::config::Config;
use crate::ids::Instance;
use crate::state::{State, Wake};

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

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Origin {
    Host,
    Runtime(RuntimeName),
}

#[derive(Debug)]
pub(crate) struct Verified(UnixStream, Origin);

impl Verified {
    #[cfg(any(test, feature = "fuzz"))]
    pub(crate) fn admit(stream: UnixStream) -> Option<Verified> {
        Verified::admit_from(stream, Origin::Host)
    }

    pub(crate) fn admit_from(stream: UnixStream, origin: Origin) -> Option<Verified> {
        let allowed = match origin {
            Origin::Host => ko_sys::sock::peer_uid(stream.as_fd()).ok()? == ko_sys::sock::uid(),
            Origin::Runtime(_) => true,
        };
        let ready = allowed
            && ko_sys::sock::set_send_buffer(stream.as_fd(), SEND_BUFFER).is_ok()
            && stream.set_nonblocking(true).is_ok();
        ready.then_some(Verified(stream, origin))
    }

    #[cfg(test)]
    pub(crate) fn with_send_buffer(self, size: usize) -> Verified {
        assert!(ko_sys::sock::set_send_buffer(self.0.as_fd(), size).is_ok());
        self
    }

    pub(crate) fn into_parts(self) -> (UnixStream, Origin) {
        (self.0, self.1)
    }
}

#[derive(Debug)]
pub(crate) struct Listener {
    socket: UnixListener,
    token: Token,
    resume: Timer,
    retry: Duration,
    origin: Origin,
}

impl Listener {
    pub(crate) fn new(
        socket: UnixListener,
        poll: &mut Poll,
        retry: Duration,
        origin: Origin,
    ) -> io::Result<Listener> {
        socket.set_nonblocking(true)?;
        Ok(Listener {
            token: poll.watch(socket.as_fd(), Interest::Read),
            socket,
            resume: poll.timer(),
            retry,
            origin,
        })
    }

    pub(crate) fn accept(&self, poll: &mut Poll, accepted: &mut Vec<Verified>) -> io::Result<()> {
        for _ in 0..ACCEPT_BURST {
            match ko_sys::retry::retry(|| self.socket.accept()) {
                Ok((stream, _)) => {
                    accepted.extend(Verified::admit_from(stream, self.origin.clone()));
                }
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

    pub(crate) fn token(&self) -> Token {
        self.token
    }

    pub(crate) fn resume_timer(&self) -> Timer {
        self.resume
    }

    pub(crate) fn resume(&self, poll: &mut Poll) {
        poll.interest(self.token, Interest::Read);
    }

    pub(crate) fn close(self, poll: &mut Poll) {
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
    timing: Timing,
    poll: Poll,
    events: Events,
    signals: Signals,
    signal_token: Token,
    listener: Option<Listener>,
    accepted: Vec<Verified>,
    state: State,
    stopping: Option<Timer>,
}

impl Server {
    pub fn new(config: Config, socket: UnixListener, timing: Timing) -> io::Result<Server> {
        let signals = Signals::install(&[Signal::Child, Signal::Term, Signal::Int, Signal::Hup])?;
        let mut poll = Poll::new();
        let signal_token = poll.watch(signals.fd(), Interest::Read);
        let listener = Listener::new(socket, &mut poll, timing.accept_retry, Origin::Host)?;
        let state = State::new(config, Instance::mint()?, &mut poll, timing.output_tick);
        Ok(Server {
            timing,
            poll,
            events: Events::default(),
            signals,
            signal_token,
            listener: Some(listener),
            accepted: Vec::new(),
            state,
            stopping: None,
        })
    }

    pub fn turn(&mut self) -> io::Result<Status> {
        let Server {
            poll,
            events,
            signals,
            signal_token,
            listener,
            accepted,
            state,
            stopping,
            timing,
        } = self;
        let mut taken = std::mem::take(events);
        let mut stopped = false;
        let turned = state.turn(
            poll,
            Mode::Wait,
            &mut taken,
            |state, poll, wake| match wake {
                Wake::Ready(ready) if ready.token == *signal_token => {
                    if poll.wants(ready).read {
                        let mut pending = Vec::new();
                        signals.take(&mut pending)?;
                        for signal in pending {
                            match signal {
                                Signal::Child => state.reap(poll)?,
                                Signal::Term | Signal::Int | Signal::Hup => {
                                    halt(listener, stopping, state, poll, *timing)?
                                }
                                _ => {}
                            }
                        }
                    }
                    Ok(true)
                }
                Wake::Ready(ready) => match listener.as_ref().filter(|l| l.token == ready.token) {
                    Some(listener) => {
                        if poll.wants(ready).read {
                            listener.accept(poll, accepted)?;
                            for stream in accepted.drain(..) {
                                state.accept(poll, stream);
                            }
                        }
                        Ok(true)
                    }
                    None => Ok(false),
                },
                Wake::Due(timer) => {
                    if let Some(listener) = listener.as_ref().filter(|l| l.resume == timer) {
                        listener.resume(poll);
                    } else if Some(timer) == *stopping {
                        state.panes.kill()?;
                        state.kill_helpers();
                        state.reap(poll)?;
                        match std::fs::remove_file(&state.config.socket) {
                            Err(error) if error.kind() != io::ErrorKind::NotFound => {
                                return Err(error);
                            }
                            _ => {}
                        }
                        stopped = true;
                    } else {
                        return Ok(false);
                    }
                    Ok(true)
                }
            },
        );
        *events = taken;
        turned?;
        Ok(if stopped {
            Status::Stopped
        } else {
            Status::Running
        })
    }

    pub fn stop(&mut self) -> io::Result<()> {
        halt(
            &mut self.listener,
            &mut self.stopping,
            &mut self.state,
            &mut self.poll,
            self.timing,
        )
    }
}

fn halt(
    listener: &mut Option<Listener>,
    stopping: &mut Option<Timer>,
    state: &mut State,
    poll: &mut Poll,
    timing: Timing,
) -> io::Result<()> {
    if stopping.is_some() {
        return Ok(());
    }
    if let Some(listener) = listener.take() {
        listener.close(poll);
    }
    state.shutdown(poll);
    let timer = poll.timer();
    poll.start(timer, timing.shutdown_grace, None)?;
    *stopping = Some(timer);
    Ok(())
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use ko_sys::pid::{Exit, Pid, Waited};
    use std::os::fd::AsFd;
    use std::path::PathBuf;

    pub(crate) fn scratch(name: &str) -> PathBuf {
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
            Origin::Host,
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
        let stdout = std::io::stdout();
        let child = ko_sys::spawn::program(
            std::path::Path::new("/bin/sh"),
            &[
                "-c",
                "ulimit -n 64 && exec \"$0\" \"$@\"",
                exe.to_str().unwrap(),
                "--ignored",
                "--exact",
                "server::tests::descriptor_shortage",
            ],
            &[(stdout.as_fd(), 1)],
            ko_sys::spawn::Env::Inherit,
            None,
        )
        .unwrap();
        assert_eq!(child.wait().unwrap(), Waited::Ended(Exit::Exited(0)));
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
            Origin::Host,
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
                .expect("KO_PANE_EXE names the Rust ko-pane; make test-ko builds it and sets it"),
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
    fn sigterm_sigint_and_sighup_stop_the_server_and_end_its_programs() {
        use std::io::BufRead;
        for signal in [Signal::Term, Signal::Int, Signal::Hup] {
            let (reader, writer) = std::io::pipe().unwrap();
            let exe = std::env::current_exe().unwrap();
            let child = ko_sys::spawn::program(
                &exe,
                &[
                    "--ignored",
                    "--exact",
                    "server::tests::sigterm",
                    "--nocapture",
                ],
                &[(writer.as_fd(), 1)],
                ko_sys::spawn::Env::Inherit,
                None,
            )
            .unwrap();
            drop(writer);
            let mut lines = std::io::BufReader::new(reader).lines();
            let program = lines
                .by_ref()
                .map_while(Result::ok)
                .find_map(|line| line.strip_prefix("program ").map(str::to_owned))
                .unwrap();
            child.signal(signal).unwrap();
            assert_eq!(
                (signal, child.wait().unwrap()),
                (signal, Waited::Ended(Exit::Exited(0)))
            );
            drop(lines);
            let program = Pid::new(program.parse().unwrap()).unwrap();
            assert!(
                within(Duration::from_secs(5), || !program.alive()),
                "{signal:?}"
            );
        }
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
            exe: PathBuf::from("/nonexistent/ko"),
            bin_dir: None,
            limits: crate::config::DEFAULT_LIMITS,
            media: Vec::new(),
            env: Vec::new(),
            cwd: PathBuf::from("/"),
            hostname: String::new(),
            linger: crate::config::LINGER,
            stop_escalation: crate::config::STOP_ESCALATION,
            run_screen_bytes: crate::config::RUN_SCREEN_BYTES,
            clipboard_wait: crate::config::CLIPBOARD_WAIT,
            message_ack: crate::config::MESSAGE_ACK,
            view_queue: crate::config::ViewQueue::default(),
            runtimes: crate::config::RuntimesConfig {
                idle: crate::config::RuntimeIdle::Never,
                exec_wait: crate::config::RUNTIME_EXEC_WAIT,
                command_kind: false,
            },
            file: dir.join("config.yaml"),
        };
        let timing = Timing {
            shutdown_grace: Duration::from_millis(100),
            ..Timing::DEFAULT
        };
        let mut server = Server::new(config, UnixListener::bind(&socket).unwrap(), timing).unwrap();
        let request = crate::protocol::CreatePane {
            cwd: None,
            command: Some(crate::protocol::Command::Argv {
                argv: vec!["/bin/sleep".to_owned(), "30".to_owned()],
            }),
            env: Vec::new(),
            vars: Default::default(),
            parent: None,
            close: Default::default(),
            runtime: None,
        };
        let id = server
            .state
            .new_session(&mut server.poll, &request)
            .unwrap();
        let program = loop {
            server.turn().unwrap();
            let pane = server.state.panes.find(id).unwrap();
            if let Some(pid) = pane.proc().child_pid() {
                break pid;
            }
        };
        println!("program {program}");
        while server.turn().unwrap() == Status::Running {}
        assert!(
            server
                .state
                .panes
                .iter()
                .all(|pane| pane.proc().life() == crate::pane_proc::Life::Reaped)
        );
        assert!(!socket.exists());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
