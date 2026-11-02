use ko_sys::event::{Events, Interest, Mode, Poll, Token};
use ko_vt::compress::Tick;

use crate::io::Stop;
use crate::pane::Pane;

#[derive(Debug)]
pub enum Outcome {
    Stopped,
    Failed(Failure),
}

#[derive(Debug)]
pub enum Failure {
    Call(&'static str, std::io::Error),
    Invalid,
    Setup(String),
    OutputStalled,
    RingFull,
}

impl Failure {
    pub(crate) fn call(call: &'static str) -> impl FnOnce(std::io::Error) -> Failure {
        move |error| Failure::Call(call, error)
    }
}

impl std::fmt::Display for Failure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Failure::Call(call, error) => write!(f, "{call}: {error}"),
            Failure::Invalid => f.write_str("invalid control frame"),
            Failure::Setup(message) => f.write_str(message),
            Failure::OutputStalled => f.write_str("the server did not read the control socket"),
            Failure::RingFull => f.write_str("no room in the ring for a record"),
        }
    }
}

fn ended(pane: &Pane, stop: Stop) -> Outcome {
    match stop {
        Stop::Failed(failure) if !pane.stopping() => Outcome::Failed(failure),
        _ => Outcome::Stopped,
    }
}

pub fn run(pane: &mut Pane) -> Outcome {
    let outcome = turns(pane);
    let _ = pane.flush();
    outcome
}

fn turns(pane: &mut Pane) -> Outcome {
    let mut poll = Poll::new();
    let input = poll.watch(pane.input_fd(), Interest::Read);
    let output = poll.watch(pane.output_fd(), Interest::Idle);
    let signals = pane.signals_fd().map(|fd| poll.watch(fd, Interest::Read));
    let mut master: Option<Token> = None;
    let timer = poll.timer();
    let foreground = poll.timer();
    let mut events = Events::default();
    let mut mode = Mode::Wait;
    loop {
        if pane.stopping() {
            return Outcome::Stopped;
        }
        poll.interest(output, Interest::of(false, pane.output_pending()));
        if let Some((fd, interest)) = pane.pty() {
            let token = *master.get_or_insert_with(|| poll.watch(fd, Interest::Idle));
            poll.interest(token, interest);
        }
        if let Err(error) = poll.turn(mode, &mut events) {
            return Outcome::Failed(Failure::call("poll")(error));
        }
        let ready = |token: Token| {
            events
                .ready()
                .iter()
                .any(|ready| ready.token == token && ready.read)
        };
        let activity = !events.ready().is_empty() || !events.due().is_empty();
        if ready(input)
            && let Err(stop) = pane.control()
        {
            return ended(pane, stop);
        }
        pane.flush_pty();
        if signals.is_some_and(ready)
            && let Err(error) = pane.signaled()
        {
            return Outcome::Failed(Failure::call("read the signal pipe")(error));
        }
        if events.due().iter().any(|due| due.timer == foreground) {
            pane.foreground_due();
        }
        pane.settle_child();
        let committed = (master.is_some_and(ready) || pane.exit_pending()) && pane.read_pty();
        let dead = pane.dead();
        pane.clear_history();
        if let Err(stop) = dead.and_then(|()| pane.flush()) {
            return ended(pane, stop);
        }
        if let Some(after) = pane.foreground_arm()
            && let Err(error) = poll.start(foreground, after, None)
        {
            return Outcome::Failed(Failure::call("arm the foreground timer")(error));
        }
        mode = Mode::Wait;
        if activity || committed || pane.compress_pending() {
            match pane.tick() {
                Tick::Settled => poll.stop(timer),
                Tick::Now => {
                    poll.stop(timer);
                    mode = Mode::Peek;
                }
                Tick::After(after) => {
                    if let Err(error) = poll.start(timer, after, None) {
                        return Outcome::Failed(Failure::call("arm the tick timer")(error));
                    }
                }
            }
        } else {
            poll.stop(timer);
        }
    }
}
