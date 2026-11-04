use std::time::{Duration, Instant};

use ko_sys::event::{Events, Interest, Mode, Poll, Token};
use ko_vt::compress::Tick;

use crate::io::Stop;
use crate::pane::Pane;

const SMALL_READ_BYTES: usize = 128;
const SMALL_READ_GAP: Duration = Duration::from_millis(1);
const SMALL_READS: u8 = 3;
const DELAY: Duration = Duration::from_micros(50);

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

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
enum Pace {
    #[default]
    Immediate,
    Small {
        at: Instant,
        count: u8,
    },
    Delayed,
}

impl Pace {
    fn observe(&mut self, bytes: usize, now: Instant) {
        if bytes == 0 || bytes >= SMALL_READ_BYTES {
            *self = Self::Immediate;
            return;
        }
        *self = match *self {
            Self::Delayed => Self::Delayed,
            Self::Small { at, count } if now.saturating_duration_since(at) < SMALL_READ_GAP => {
                let count = count.saturating_add(1);
                if count >= SMALL_READS {
                    Self::Delayed
                } else {
                    Self::Small { at: now, count }
                }
            }
            _ => Self::Small { at: now, count: 1 },
        };
    }
}

fn turns(pane: &mut Pane) -> Outcome {
    let mut poll = Poll::new();
    let input = poll.watch(pane.input_fd(), Interest::Read);
    let output = poll.watch(pane.output_fd(), Interest::Idle);
    let signals = pane.signals_fd().map(|fd| poll.watch(fd, Interest::Read));
    let mut master: Option<Token> = None;
    let timer = poll.timer();
    let foreground = poll.timer();
    let coalesce = poll.timer();
    let mut pace = Pace::default();
    let mut events = Events::default();
    let mut mode = Mode::Wait;
    loop {
        if pane.stopping() {
            return Outcome::Stopped;
        }
        poll.interest(output, Interest::of(false, pane.output_pending()));
        if let Some((fd, interest)) = pane.pty() {
            let delayed = poll.is_active(coalesce);
            let token = *master.get_or_insert_with(|| poll.watch(fd, Interest::Idle));
            poll.interest(
                token,
                Interest::of(interest.reads() && !delayed, interest.writes()),
            );
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
        let due = |timer| events.due().iter().any(|due| due.timer == timer);
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
        if due(foreground) {
            pane.foreground_due();
        }
        pane.settle_child();
        let urgent = ready(input) || signals.is_some_and(ready) || pane.exit_pending();
        if urgent {
            pace = Pace::Immediate;
        }
        let committed = if master.is_some_and(ready) || urgent || due(coalesce) {
            let bytes = pane.read_pty();
            pace.observe(bytes, Instant::now());
            if pace == Pace::Delayed {
                if let Err(error) = poll.start(coalesce, DELAY, None) {
                    return Outcome::Failed(Failure::call("arm the coalescing timer")(error));
                }
            } else {
                poll.stop(coalesce);
            }
            bytes > 0
        } else {
            false
        };
        let dead = pane.dead();
        pane.clear_history();
        pane.search_step();
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
        if pane.searching() {
            mode = Mode::Peek;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn isolated_output_never_arms_a_delay() {
        let start = Instant::now();
        let mut pace = Pace::default();
        for millis in [0, 10, 20, 30] {
            let at = start + Duration::from_millis(millis);
            pace.observe(3, at);
            assert_eq!(pace, Pace::Small { at, count: 1 });
        }
    }

    #[test]
    fn only_sustained_small_output_is_coalesced() {
        let start = Instant::now();
        let mut pace = Pace::default();
        pace.observe(3, start);
        pace.observe(6, start + Duration::from_micros(10));
        assert_eq!(
            pace,
            Pace::Small {
                at: start + Duration::from_micros(10),
                count: 2
            }
        );
        pace.observe(3, start + Duration::from_micros(20));
        assert_eq!(pace, Pace::Delayed);
        pace.observe(1024, start + Duration::from_micros(70));
        assert_eq!(pace, Pace::Immediate);
        pace.observe(3, start + Duration::from_micros(80));
        assert_eq!(
            pace,
            Pace::Small {
                at: start + Duration::from_micros(80),
                count: 1
            }
        );
    }

    #[test]
    fn drained_output_returns_to_immediate_reads() {
        let start = Instant::now();
        let mut pace = Pace::Delayed;
        pace.observe(0, start);
        assert_eq!(pace, Pace::Immediate);
        pace.observe(3, start);
        assert_eq!(
            pace,
            Pace::Small {
                at: start,
                count: 1
            }
        );
    }
}
