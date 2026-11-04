use std::time::{Duration, Instant};

use ko_sys::event::{Poll, Timer};
use ko_sys::pid::{Pid, Waited};
use ko_sys::signal::Signal;

#[derive(Debug)]
struct Doomed {
    pid: Pid,
    due: Instant,
    killed: bool,
}

#[derive(Debug)]
pub(crate) struct Leaving {
    doomed: Vec<Doomed>,
    timer: Timer,
}

impl Leaving {
    pub(crate) fn new(poll: &mut Poll) -> Leaving {
        Leaving {
            doomed: Vec::new(),
            timer: poll.timer(),
        }
    }

    pub(crate) fn hand_over(&mut self, poll: &mut Poll, pid: Pid, after: Duration) {
        let _ = pid.signal(Signal::Term);
        self.doomed.push(Doomed {
            pid,
            due: Instant::now() + after,
            killed: false,
        });
        self.arm(poll);
    }

    pub(crate) fn is_timer(&self, timer: Timer) -> bool {
        self.timer == timer
    }

    fn arm(&self, poll: &mut Poll) {
        let now = Instant::now();
        let next = self
            .doomed
            .iter()
            .filter(|doomed| !doomed.killed)
            .map(|doomed| doomed.due.saturating_duration_since(now))
            .min();
        match next {
            Some(next) => {
                let _ = poll.start(self.timer, next, None);
            }
            None => poll.stop(self.timer),
        }
    }

    pub(crate) fn escalate(&mut self, poll: &mut Poll) {
        let now = Instant::now();
        for doomed in &mut self.doomed {
            if !doomed.killed && doomed.due <= now {
                let _ = doomed.pid.signal(Signal::Kill);
                doomed.killed = true;
            }
        }
        self.arm(poll);
    }

    pub(crate) fn reap(&mut self) {
        self.doomed
            .retain(|doomed| matches!(doomed.pid.try_wait(), Ok(Waited::Running)));
    }

    pub(crate) fn kill_all(&mut self) {
        for doomed in &mut self.doomed {
            if !doomed.killed {
                let _ = doomed.pid.signal(Signal::Kill);
                doomed.killed = true;
            }
        }
        self.reap();
    }
}
