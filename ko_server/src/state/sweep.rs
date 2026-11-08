use super::*;
use crate::panes::{self, Condition, Seen};

#[derive(Debug)]
pub(super) struct Sweep {
    timer: Timer,
    due: bool,
    shown: BTreeSet<PaneId>,
}

impl Sweep {
    pub(super) fn new(poll: &mut Poll) -> Self {
        Self {
            timer: poll.timer(),
            due: false,
            shown: BTreeSet::new(),
        }
    }

    pub(super) fn is_timer(&self, timer: Timer) -> bool {
        self.timer == timer
    }

    pub(super) fn take_due(&mut self) -> bool {
        std::mem::take(&mut self.due)
    }

    pub(super) fn stop(&self, poll: &mut Poll) {
        poll.stop(self.timer);
    }

    pub(super) fn shown_changed(&mut self, shown: &BTreeSet<PaneId>) -> bool {
        if self.shown == *shown {
            return false;
        }
        self.shown = shown.clone();
        true
    }
}

impl State {
    pub(super) fn seen(&self) -> Vec<Seen> {
        let shown = self.focused_panes();
        self.panes
            .iter()
            .map(|pane| Seen {
                id: pane.id(),
                condition: match pane.proc().dead() {
                    Some(death) => match death.cause {
                        pane_proc::Cause::StartFailed(_) => Condition::Failed { at: death.at },
                        _ => Condition::Dead { at: death.at },
                    },
                    None => Condition::Live,
                },
                parent: pane.parent(),
                close: pane.close(),
                shown: shown.contains(&pane.id()),
            })
            .collect()
    }

    pub(super) fn sweep_soon(&mut self, poll: &mut Poll) {
        self.sweep.due = true;
        self.model.arm(poll);
    }

    pub(super) fn sweep(&mut self, poll: &mut Poll) {
        let swept = panes::sweep(&self.seen(), ko_sys::clock::Mono::now(), || {
            self.config.linger()
        });
        for pane in swept.removed {
            self.delete(poll, crate::layout::Remove::Pane(pane));
        }
        match swept.next {
            Some(next) => {
                let _ = poll.start(self.sweep.timer, next, None);
            }
            None => poll.stop(self.sweep.timer),
        }
    }
}
