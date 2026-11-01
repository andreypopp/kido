use ko_sys::event::{Events, Interest, Mode, Poll, Token};
use ko_vt::compress::Tick;

use crate::pane::Pane;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    Stopped,
    Failed(Option<String>),
}

fn ended(pane: &mut Pane) -> Outcome {
    if pane.stopping() {
        Outcome::Stopped
    } else {
        Outcome::Failed(pane.take_failure())
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
        if poll.turn(mode, &mut events).is_err() {
            return Outcome::Failed(None);
        }
        let ready = |token: Token| {
            events
                .ready()
                .iter()
                .any(|ready| ready.token == token && ready.read)
        };
        let activity = !events.ready().is_empty() || !events.due().is_empty();
        if ready(input) && pane.control().is_err() {
            return ended(pane);
        }
        pane.flush_pty();
        if signals.is_some_and(ready) && pane.signaled().is_err() {
            return Outcome::Failed(None);
        }
        pane.settle_child();
        let committed = (master.is_some_and(ready) || pane.exit_pending()) && pane.read_pty();
        if pane.dead().is_err() || pane.flush().is_err() {
            return ended(pane);
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
                    if poll.start(timer, after, None).is_err() {
                        return Outcome::Failed(None);
                    }
                }
            }
        } else {
            poll.stop(timer);
        }
    }
}
