use std::io;
use std::os::fd::AsFd;
use std::path::Path;
use std::time::{Duration, Instant};

use ko_config::values::RuntimeName;
use ko_server::api::Route;
use ko_server::config::{env_path, program_path};
use ko_server::protocol::{self, LeadReport, VisitClient, VisitRequest, VisitServer};
use ko_sys::event::{Events, Interest, Mode, Poll, Timer, Token};
use ko_sys::pid::{Exit, Pid};
use ko_sys::signal::{Signal, Signals};
use ko_sys::spawn::{self, Env};

use crate::api::{self, Failure, ReplyError};
use crate::runtimes::{STILL_STARTING, Shown, drain, exit_code, lead_step};
use crate::wire::{self, Caller, Link, Next};

#[derive(Debug)]
enum Child {
    Lead {
        pid: Pid,
        stderr: io::PipeReader,
        token: Option<Token>,
        tail: Vec<u8>,
    },
    Transport(Pid),
}

impl Child {
    fn pid(&self) -> Pid {
        match self {
            Self::Lead { pid, .. } | Self::Transport(pid) => *pid,
        }
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
    child: Option<Child>,
    phase: Phase,
}

impl Lease<'_> {
    fn send(&mut self, message: VisitClient) -> Result<(), String> {
        self.link
            .send(protocol::json(&message))
            .map_err(wire::text)?;
        self.link.settle(&mut self.poll).map_err(wire::text)
    }

    fn end(&mut self, reason: End, signal: Signal) -> Result<(), String> {
        if !matches!(self.phase, Phase::Ending(_)) {
            self.phase = Phase::Ending(reason);
            self.link.unwatch(&mut self.poll);
            self.poll.stop(self.deadline);
            if let Some(child) = &self.child {
                let _ = child.pid().signal(signal);
                self.poll
                    .start(self.escalation_timer, self.escalation, None)
                    .map_err(wire::text)?;
            }
        }
        Ok(())
    }

    fn message(
        &mut self,
        message: VisitServer,
        shown: &mut impl FnMut(Shown<'_>),
    ) -> Result<(), String> {
        match message {
            VisitServer::Starting {} => shown(Shown::Starting),
            VisitServer::Lead { argv } => {
                if self.child.is_some() || !matches!(self.phase, Phase::Waiting) {
                    return Err("unexpected lead command".to_owned());
                }
                let Some((program, rest)) = argv.split_first() else {
                    return Err("no lead command".to_owned());
                };
                match lead_step(program, rest, self.env) {
                    Ok((pid, stderr)) => {
                        let token = self.poll.watch(stderr.as_fd(), Interest::Read);
                        self.child = Some(Child::Lead {
                            pid,
                            stderr,
                            token: Some(token),
                            tail: Vec::new(),
                        });
                    }
                    Err(error) => self.send(VisitClient::Lead(LeadReport {
                        exit: 1,
                        stderr: error.to_string(),
                    }))?,
                }
            }
            VisitServer::Up { argv } => {
                if self.child.is_some() || !matches!(self.phase, Phase::Waiting) {
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
                self.child = Some(Child::Transport(pid));
                self.phase = Phase::Running;
                self.poll.stop(self.deadline);
            }
            VisitServer::Failed { message } | VisitServer::Ended { message } => {
                self.end(End::Runtime(message), Signal::Hup)?
            }
        }
        Ok(())
    }

    fn reaped(&mut self, exit: Exit) -> Result<Option<i32>, String> {
        let child = self.child.take();
        if let Some(Child::Lead {
            token: Some(token), ..
        }) = &child
        {
            self.poll.unwatch(*token);
        }
        match &self.phase {
            Phase::Ending(End::Runtime(message)) => Err(message.clone()),
            Phase::Ending(End::Signal) | Phase::Running => Ok(Some(exit_code(exit))),
            Phase::Waiting => {
                if let Some(Child::Lead { tail, .. }) = child {
                    self.send(VisitClient::Lead(LeadReport {
                        exit: exit_code(exit),
                        stderr: String::from_utf8_lossy(&tail).into_owned(),
                    }))?;
                }
                Ok(None)
            }
        }
    }

    fn run(&mut self, signals: &Signals, shown: &mut impl FnMut(Shown<'_>)) -> Result<i32, String> {
        let signal_token = self.poll.watch(signals.fd(), Interest::Read);
        let mut events = Events::default();
        let mut pending = Vec::new();
        loop {
            if let Some(child) = &mut self.child {
                if let Child::Lead {
                    stderr,
                    tail,
                    token,
                    ..
                } = child
                    && token.is_some()
                    && !drain(stderr, tail, shown)
                    && let Some(token) = token.take()
                {
                    self.poll.unwatch(token);
                }
                if let Some(exit) = child.pid().peek_exit().map_err(wire::text)? {
                    let _ = child.pid().wait();
                    if let Some(code) = self.reaped(exit)? {
                        return Ok(code);
                    }
                }
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
                let _ = child.pid().signal(Signal::Kill);
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
    shown: &mut impl FnMut(Shown<'_>),
) -> Result<i32, String> {
    let (_, path) = Route::VisitRuntime { name: name.clone() }.to_request();
    let link = match api::stream(dir, Some(caller), &path) {
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
    lease.send(VisitClient::Visit(request))?;
    let result = lease.run(&signals, shown);
    if let Some(child) = lease.child.take() {
        let _ = child.pid().signal(Signal::Kill);
        let _ = child.pid().wait();
    }
    result
}
