use std::os::fd::BorrowedFd;
use std::time::{Duration, Instant};

use ko_pane_wire::frame::{Foreground, FromPane};
use ko_sys::pty;

use crate::io::Out;

const THROTTLE: Duration = Duration::from_millis(100);

#[derive(Debug, Default)]
pub(crate) struct Watch {
    sent: Option<pty::Foreground>,
    checked: Option<Instant>,
    deferred: Option<Instant>,
    armed: bool,
}

impl Watch {
    pub(crate) fn check(&mut self, master: BorrowedFd<'_>, out: &mut Out, now: Instant) {
        self.checked = Some(now);
        self.deferred = None;
        self.armed = false;
        if let Some(current) = pty::foreground(master)
            && self.sent.as_ref() != Some(&current)
        {
            out.frame(&FromPane::Foreground(Foreground {
                pid: current.group,
                name: &current.name,
            }));
            self.sent = Some(current);
        }
    }

    pub(crate) fn after_read(
        &mut self,
        master: BorrowedFd<'_>,
        out: &mut Out,
        event: bool,
        now: Instant,
    ) {
        match self.checked {
            Some(at) if !event && now.saturating_duration_since(at) < THROTTLE => {
                self.deferred.get_or_insert(at + THROTTLE);
            }
            _ => self.check(master, out, now),
        }
    }

    pub(crate) fn arm(&mut self, now: Instant) -> Option<Duration> {
        let deadline = self.deferred.filter(|_| !self.armed)?;
        self.armed = true;
        Some(deadline.saturating_duration_since(now))
    }

    pub(crate) fn run_deferred(&mut self, master: BorrowedFd<'_>, out: &mut Out, now: Instant) {
        if self.deferred.is_some_and(|deadline| now >= deadline) {
            self.check(master, out, now);
        }
    }
}
