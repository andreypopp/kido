use std::io;
use std::os::fd::AsFd;
use std::path::Path;
use std::time::{Duration, Instant};

use ko_config::values::RuntimeName;
use ko_sys::event::{Events, Interest, Mode, Poll, Timer, Token};
use ko_sys::file::{env_path, program_path};
use ko_sys::pid::{Exit, Pid};
use ko_sys::signal::{Signal, Signals};
use ko_sys::spawn::{self, Env};
use ko_wire::api::Route;
use ko_wire::protocol::{self, VisitClient, VisitRequest, VisitServer};

use crate::api::{self, Failure, ReplyError};
use crate::runtimes::STILL_STARTING;
use crate::wire::{self, Caller, Link, Next};

fn exit_code(exit: Exit) -> i32 {
    match exit {
        Exit::Exited(code) => code,
        Exit::Signaled(signal) => 128 + signal,
    }
}

#[derive(Debug)]
enum End {
    Runtime(String),
    Signal,
}

#[derive(Debug)]
enum Phase {
    Waiting,
    Running,
    Ending(End),
}

#[derive(Debug)]
struct Lease<'a> {
    link: Link,
    poll: Poll,
    network: Token,
    deadline: Timer,
    escalation_timer: Timer,
    escalation: Duration,
    env: &'a [Vec<u8>],
    child: Option<Pid>,
    phase: Phase,
}

impl Lease<'_> {
    fn end(&mut self, reason: End, signal: Signal) -> Result<(), String> {
        if !matches!(self.phase, Phase::Ending(_)) {
            self.phase = Phase::Ending(reason);
            self.link.unwatch(&mut self.poll);
            self.poll.stop(self.deadline);
            if let Some(child) = &self.child {
                let _ = child.signal(signal);
                self.poll
                    .start(self.escalation_timer, self.escalation, None)
                    .map_err(wire::text)?;
            }
        }
        Ok(())
    }

    fn message(&mut self, message: VisitServer, shown: &mut impl FnMut()) -> Result<(), String> {
        match message {
            VisitServer::Starting {} => shown(),
            VisitServer::Up { argv } => {
                if !matches!(self.phase, Phase::Waiting) {
                    return Err("unexpected runtime command".to_owned());
                }
                let Some((program, rest)) = argv.split_first() else {
                    return Err("no runtime command".to_owned());
                };
                let path = program_path(&String::from_utf8_lossy(env_path(self.env)), program)
                    .ok_or_else(|| format!("{program}: not found"))?;
                let args: Vec<_> = rest.iter().map(String::as_str).collect();
                let pid = spawn::program(
                    &path,
                    &args,
                    &[
                        (io::stdin().as_fd(), 0),
                        (io::stdout().as_fd(), 1),
                        (io::stderr().as_fd(), 2),
                    ],
                    Env::Only(self.env),
                    None,
                )
                .map_err(|error| format!("{program}: {error}"))?;
                self.child = Some(pid);
                self.phase = Phase::Running;
                self.poll.stop(self.deadline);
            }
            VisitServer::Failed { message } | VisitServer::Ended { message } => {
                self.end(End::Runtime(message), Signal::Hup)?
            }
        }
        Ok(())
    }

    fn run(&mut self, signals: &Signals, shown: &mut impl FnMut()) -> Result<i32, String> {
        let signal_token = self.poll.watch(signals.fd(), Interest::Read);
        let mut events = Events::default();
        let mut pending = Vec::new();
        loop {
            if let Some(child) = &self.child
                && let Some(exit) = child.peek_exit().map_err(wire::text)?
            {
                let _ = child.wait();
                self.child = None;
                return match &self.phase {
                    Phase::Ending(End::Runtime(message)) => Err(message.clone()),
                    _ => Ok(exit_code(exit)),
                };
            }
            if let Phase::Ending(End::Runtime(message)) = &self.phase
                && self.child.is_none()
            {
                return Err(message.clone());
            }
            if !matches!(self.phase, Phase::Ending(_)) {
                self.link.begin_turn();
                loop {
                    let message = match self.link.next(&mut self.poll, Instant::now()) {
                        Ok(Next::Wait) => break,
                        Ok(Next::Text(text)) => {
                            protocol::decode::<VisitServer>(text.as_bytes()).map_err(wire::text)
                        }
                        Ok(_) => Err("visit connection closed".to_owned()),
                        Err(error) => Err(error.to_string()),
                    };
                    if let Err(message) = message.and_then(|message| self.message(message, shown)) {
                        self.end(End::Runtime(message), Signal::Hup)?;
                    }
                    if matches!(self.phase, Phase::Ending(_)) {
                        break;
                    }
                }
            }
            if matches!(self.phase, Phase::Ending(_)) && self.child.is_none() {
                continue;
            }
            self.poll
                .turn(Mode::Wait, &mut events)
                .map_err(wire::text)?;
            if events.due().iter().any(|due| due.timer == self.deadline) {
                self.end(End::Runtime("still starting".to_owned()), Signal::Hup)?;
            }
            if events
                .due()
                .iter()
                .any(|due| due.timer == self.escalation_timer)
                && let Some(child) = &self.child
            {
                let _ = child.signal(Signal::Kill);
            }
            for ready in events.ready() {
                if ready.token == signal_token {
                    signals.take(&mut pending).map_err(wire::text)?;
                    for signal in pending.drain(..) {
                        if matches!(signal, Signal::Int | Signal::Hup | Signal::Term) {
                            if self.child.is_none() {
                                return Ok(exit_code(Exit::Signaled(signal.number())));
                            }
                            if signal != Signal::Int {
                                self.end(End::Signal, signal)?;
                            }
                        }
                    }
                } else if ready.token == self.network
                    && !matches!(self.phase, Phase::Ending(_))
                    && let Err(error) = self.link.settle(&mut self.poll)
                {
                    self.end(End::Runtime(error.to_string()), Signal::Hup)?;
                }
            }
        }
    }
}

pub fn visit(
    dir: &Path,
    caller: Caller,
    name: &RuntimeName,
    request: VisitRequest,
    escalation: Duration,
    env: &[Vec<u8>],
    shown: &mut impl FnMut(),
) -> Result<i32, String> {
    let (_, path) = Route::VisitRuntime { name: name.clone() }.to_request();
    let link = match api::stream(dir, Some(caller), path.as_str()) {
        Ok(Ok(link)) => link,
        Ok(Err(response)) => return Err(api::describe(dir, api::response_error(&response))),
        Err(api::Error::Server(failure)) => {
            return Err(api::describe(dir, ReplyError::Server(failure)));
        }
        Err(api::Error::Websocket | api::Error::NotWebsocket) => {
            return Err(api::describe(
                dir,
                ReplyError::Server(Failure::Failed("not a WebSocket route".to_owned())),
            ));
        }
    };
    let signals = Signals::install(&[Signal::Child, Signal::Hup, Signal::Term, Signal::Int])
        .map_err(wire::text)?;
    let mut poll = Poll::new();
    let mut link = link;
    let network = link.watch(&mut poll).map_err(wire::text)?;
    let deadline = poll.timer();
    let escalation_timer = poll.timer();
    poll.start(deadline, STILL_STARTING, None)
        .map_err(wire::text)?;
    let mut lease = Lease {
        link,
        poll,
        network,
        deadline,
        escalation_timer,
        escalation,
        env,
        child: None,
        phase: Phase::Waiting,
    };
    lease
        .link
        .send(protocol::json(&VisitClient::Visit(request)))
        .map_err(wire::text)?;
    lease.link.settle(&mut lease.poll).map_err(wire::text)?;
    let result = lease.run(&signals, shown);
    if let Some(child) = lease.child.take() {
        let _ = child.signal(Signal::Kill);
        let _ = child.wait();
    }
    result
}
