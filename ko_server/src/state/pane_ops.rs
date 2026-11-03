use std::time::Instant;

use super::*;
use crate::api::{WaitMs, routes};
use crate::panes::{self, Edge, Standing, acts_as, scope};
use crate::protocol::{
    DraftLayout, DraftSession, DraftWindow, Empty, Error, ErrorKind, NewWindow, Placement,
    SessionRef,
};

#[derive(Debug, Clone, Copy)]
pub(super) enum Via {
    Pane,
    Run,
}

#[derive(Debug)]
struct Stop {
    conn: Token,
    pane: PaneId,
    via: Via,
}

#[derive(Debug)]
pub(super) struct Stops {
    escalation: Timer,
    waits: Vec<Stop>,
    doomed: Vec<(PaneId, Instant)>,
}

fn next_escalation(doomed: &[(PaneId, Instant)], now: Instant) -> Option<Duration> {
    doomed
        .iter()
        .map(|(_, due)| due.saturating_duration_since(now))
        .min()
}

impl Stops {
    pub(super) fn new(poll: &mut Poll) -> Stops {
        Stops {
            escalation: poll.timer(),
            waits: Vec::new(),
            doomed: Vec::new(),
        }
    }

    pub(super) fn stop(&self, poll: &mut Poll) {
        poll.stop(self.escalation);
    }

    pub(super) fn is_escalation(&self, timer: Timer) -> bool {
        self.escalation == timer
    }
}

impl State {
    fn edges(&self) -> Vec<Edge> {
        let layout = self.document.layout();
        self.panes
            .iter()
            .filter_map(|pane| {
                let (session, _) = layout.locate(pane.id())?;
                Some(Edge {
                    pane: pane.id(),
                    parent: pane.parent(),
                    session: session.id,
                })
            })
            .collect()
    }

    fn may_stop(&self, caller: Option<PaneId>, target: PaneId) -> Result<(), Error> {
        match caller {
            Some(caller) if !scope(&self.edges(), caller).contains(&target) => Err(Error::new(
                ErrorKind::Refused,
                format!("{target} is not a child, sibling or ancestor of {caller}"),
            )),
            _ => Ok(()),
        }
    }

    pub(crate) fn may_read_output(
        &self,
        caller: Option<PaneId>,
        target: PaneId,
    ) -> Result<(), Error> {
        match caller {
            Some(caller) if !panes::reads_output(&self.edges(), caller, target) => Err(Error::new(
                ErrorKind::Refused,
                format!("{caller} may read the output of itself and its children, not of {target}"),
            )),
            _ => Ok(()),
        }
    }

    pub(super) fn admit_parent(&self, caller: Option<PaneId>, parent: PaneId) -> Result<(), Error> {
        match panes::standing(&self.seen(), parent) {
            Standing::Live => acts_as(caller, parent, "name only itself as a parent"),
            Standing::Gone => Err(Error::new(
                ErrorKind::Missing,
                format!("no pane {parent} to be the parent"),
            )),
            Standing::Dead => Err(Error::new(
                ErrorKind::Gone,
                format!("the parent {parent} is dead"),
            )),
        }
    }

    pub(crate) fn new_pane(
        &mut self,
        poll: &mut Poll,
        caller: Option<PaneId>,
        request: NewWindow,
    ) -> Result<Placement, Error> {
        let NewWindow {
            session,
            name,
            pane,
        } = request;
        self.place_pane(poll, caller, session, name, pane, None)
    }

    pub(super) fn place_pane(
        &mut self,
        poll: &mut Poll,
        caller: Option<PaneId>,
        session: Option<SessionRef>,
        name: Option<Name>,
        pane: CreatePane,
        run: Option<RunId>,
    ) -> Result<Placement, Error> {
        if let Some(parent) = pane.parent {
            self.admit_parent(caller, parent)?;
        }
        let layout = self.document.layout();
        let session_of = |pane: Option<PaneId>| {
            pane.and_then(|pane| layout.locate(pane))
                .map(|(session, _)| session.id)
        };
        let chosen = match &session {
            Some(SessionRef::Id(id)) => Some(
                layout
                    .session(*id)
                    .ok_or_else(|| Error::new(ErrorKind::Missing, format!("no session {id}")))?
                    .id,
            ),
            Some(SessionRef::Name(name)) => Some(
                layout
                    .sessions
                    .iter()
                    .find(|session| session.name == *name)
                    .ok_or_else(|| Error::new(ErrorKind::Missing, "no such session"))?
                    .id,
            ),
            None => session_of(pane.parent).or_else(|| session_of(caller)),
        };
        let mut draft = DraftLayout::from(layout);
        match chosen {
            Some(id) => {
                let anchor = [pane.parent, caller]
                    .into_iter()
                    .flatten()
                    .find_map(|anchor| {
                        let (in_session, in_window) = layout.locate(anchor)?;
                        (in_session.id == id).then_some(in_window.id)
                    });
                let Some(draft_session) = draft.session_mut(id) else {
                    return Err(Error::new(ErrorKind::Missing, format!("no session {id}")));
                };
                let at = anchor
                    .and_then(|anchor| {
                        draft_session
                            .windows
                            .iter()
                            .position(|window| window.id == Some(anchor))
                    })
                    .map_or(draft_session.windows.len(), |position| position + 1);
                let mut window = DraftWindow::single(&pane);
                window.name = name;
                draft_session.windows.insert(at, window);
            }
            None => {
                let unnamed = Name::try_from(String::new())
                    .map_err(|message| Error::new(ErrorKind::Invalid, message))?;
                let mut fresh = DraftSession::single(unnamed, &pane);
                if let Some(window) = fresh.windows.first_mut() {
                    window.name = name;
                }
                draft.sessions.push(fresh);
            }
        }
        let before = layout.panes();
        let revision = self.document.revision();
        let snapshot = self
            .put_layout(
                poll,
                PutLayout {
                    revision,
                    layout: draft,
                },
                run,
                None,
            )
            .map_err(Error::from)?;
        snapshot
            .layout
            .panes()
            .difference(&before)
            .next()
            .and_then(|created| {
                let (session, window) = snapshot.layout.locate(*created)?;
                Some(Placement {
                    session: session.id,
                    window: window.id,
                    pane: *created,
                })
            })
            .ok_or_else(|| Error::new(ErrorKind::Io, "the new pane is missing"))
    }

    pub(super) fn stop_after(
        &mut self,
        poll: &mut Poll,
        index: usize,
        pane: PaneId,
        wait: WaitMs,
        via: Via,
    ) -> Option<Result<Empty, Error>> {
        let Some(found) = self.panes.find(pane) else {
            return Some(Err(Error::new(ErrorKind::Missing, "pane not found")));
        };
        if found.proc().dead().is_some() || wait == WaitMs::NONE {
            self.kill_pane(poll, pane);
            return Some(Ok(Empty {}));
        }
        let conn = self.hold(poll, index, Duration::from_millis(wait.get()));
        self.stops.waits.push(Stop { conn, pane, via });
        None
    }

    pub(crate) fn stop_route(
        &mut self,
        poll: &mut Poll,
        index: usize,
        caller: Option<PaneId>,
        pane: PaneId,
        wait: WaitMs,
    ) -> Option<Result<Empty, Error>> {
        if let Err(error) = self.may_stop(caller, pane) {
            return Some(Err(error));
        }
        self.stop_after(poll, index, pane, wait, Via::Pane)
    }

    fn answer_stop(&mut self, poll: &mut Poll, stop: Stop) {
        self.kill_pane(poll, stop.pane);
        match stop.via {
            Via::Pane => router::answer::<routes::StopPane>(self, poll, stop.conn, Ok(Empty {})),
            Via::Run => router::answer::<routes::StopRun>(self, poll, stop.conn, Ok(Empty {})),
        }
    }

    pub(super) fn settle_stops(&mut self, poll: &mut Poll) {
        if self.stops.waits.is_empty() {
            return;
        }
        let waits = std::mem::take(&mut self.stops.waits);
        let (ended, pending): (Vec<Stop>, Vec<Stop>) = waits.into_iter().partition(|stop| {
            self.panes
                .find(stop.pane)
                .is_none_or(|pane| pane.proc().dead().is_some())
        });
        self.stops.waits.extend(pending);
        for stop in ended {
            self.answer_stop(poll, stop);
        }
    }

    pub(super) fn stop_due(&mut self, poll: &mut Poll, timer: Timer) -> bool {
        let Some(token) = self.token_of_timer(timer) else {
            return false;
        };
        let Some(at) = self.stops.waits.iter().position(|stop| stop.conn == token) else {
            return false;
        };
        let stop = self.stops.waits.swap_remove(at);
        self.answer_stop(poll, stop);
        true
    }

    pub(super) fn forget_stops(&mut self, poll: &mut Poll, conn: Token) {
        let (closed, pending): (Vec<Stop>, Vec<Stop>) = std::mem::take(&mut self.stops.waits)
            .into_iter()
            .partition(|stop| stop.conn == conn);
        self.stops.waits = pending;
        for stop in closed {
            self.kill_pane(poll, stop.pane);
        }
    }

    fn kill_pane(&mut self, poll: &mut Poll, pane: PaneId) {
        let lives = self
            .panes
            .find(pane)
            .is_some_and(|pane| pane.proc().dead().is_none());
        self.delete_pane(poll, pane);
        if lives {
            self.stops
                .doomed
                .push((pane, Instant::now() + self.config.stop_escalation));
            self.arm_escalation(poll);
        }
    }

    fn arm_escalation(&mut self, poll: &mut Poll) {
        match next_escalation(&self.stops.doomed, Instant::now()) {
            Some(next) => {
                let _ = poll.start(self.stops.escalation, next, None);
            }
            None => poll.stop(self.stops.escalation),
        }
    }

    pub(super) fn escalate(&mut self, poll: &mut Poll) {
        let now = Instant::now();
        let State { stops, panes, .. } = self;
        stops.doomed.retain(|(pane, due)| {
            if *due > now {
                return true;
            }
            let _ = panes.kill_removed(*pane);
            false
        });
        self.arm_escalation(poll);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_escalation_timer_waits_for_the_earliest_deadline_not_a_full_interval() {
        let now = Instant::now();
        let at = |secs| (PaneId::new(secs), now + Duration::from_secs(secs));
        assert_eq!(next_escalation(&[], now), None);
        assert_eq!(
            next_escalation(&[at(5), at(2), at(9)], now),
            Some(Duration::from_secs(2))
        );
        assert_eq!(
            next_escalation(&[at(5), at(2)], now + Duration::from_secs(3)),
            Some(Duration::ZERO),
            "a deadline that passed fires at once"
        );
    }
}
