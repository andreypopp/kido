use std::path::PathBuf;
use std::time::Instant;

use super::*;
use crate::ids::RunId;
use crate::pane_kind::{self, Kind, RUN};
use crate::protocol::{
    Command, DraftLayout, Empty, Error, ErrorKind, Info, ReportOutcome, Reported, RunEvent,
    SessionRef, Show, StartRun, Started, StopResult, StopRun, Variable, WAIT_MAX_MS, Waited,
};
use crate::runs::{self, Closing, Condition, Ended, Meta, RunOutcome, RunResult, Seen};
use crate::timestamp::Timestamp;
use crate::vars::Loose;
use ko_pane_wire::frame::{Req, ScreenFormat};

const SCREEN_HISTORY: u32 = 1000;

#[derive(Debug)]
enum WaitKind {
    Ending(RunId),
    Stopping(PaneId),
}

#[derive(Debug)]
struct Wait {
    conn: Token,
    kind: WaitKind,
}

#[derive(Debug)]
enum Done {
    Outcome(Option<RunOutcome>),
    Stop(PaneId),
}

#[derive(Debug)]
struct Settled {
    conn: Token,
    done: Done,
}

#[derive(Debug)]
enum Then {
    Close,
    Reply(Token),
}

#[derive(Debug)]
struct Capture {
    pane: PaneId,
    req: Option<Req>,
    meta: Meta,
    outcome: RunOutcome,
    screen: Vec<u8>,
    then: Then,
}

#[derive(Debug)]
pub(super) struct RunState {
    root: PathBuf,
    sweep: Timer,
    escalation: Timer,
    waits: Vec<Wait>,
    captures: Vec<Capture>,
    doomed: Vec<(PaneId, Instant)>,
    sweep_due: bool,
    focused: BTreeSet<PaneId>,
}

fn capture_at(captures: &[Capture], pane: PaneId, req: Req) -> Option<usize> {
    captures.iter().position(|capture| {
        capture.pane == pane && capture.req.is_some_and(|found| found.same(req))
    })
}

fn next_escalation(doomed: &[(PaneId, Instant)], now: Instant) -> Option<Duration> {
    doomed
        .iter()
        .map(|(_, due)| due.saturating_duration_since(now))
        .min()
}

impl RunState {
    pub(super) fn new(config: &Config, poll: &mut Poll) -> RunState {
        RunState {
            root: runs::root(&config.dir),
            sweep: poll.timer(),
            escalation: poll.timer(),
            waits: Vec::new(),
            captures: Vec::new(),
            doomed: Vec::new(),
            sweep_due: false,
            focused: BTreeSet::new(),
        }
    }

    pub(super) fn stop(&self, poll: &mut Poll) {
        poll.stop(self.sweep);
        poll.stop(self.escalation);
    }

    pub(super) fn forget(&mut self, conn: Token) {
        self.waits.retain(|wait| wait.conn != conn);
    }

    pub(super) fn want_sweep(&mut self) {
        self.sweep_due = true;
    }

    pub(super) fn take_due(&mut self) -> bool {
        std::mem::take(&mut self.sweep_due)
    }

    pub(super) fn focus_changed(&mut self, focused: BTreeSet<PaneId>) -> bool {
        self.focused != focused && {
            self.focused = focused;
            true
        }
    }

    pub(super) fn is_sweep(&self, timer: Timer) -> bool {
        self.sweep == timer
    }

    pub(super) fn is_escalation(&self, timer: Timer) -> bool {
        self.escalation == timer
    }
}

fn no_such_run(id: &RunId) -> Error {
    Error::new(ErrorKind::Missing, format!("run {id}: no such run"))
}

fn lost(id: &RunId) -> Error {
    Error::new(
        ErrorKind::Refused,
        format!("run {id} already has an outcome, or is gone"),
    )
}

impl State {
    pub(crate) fn seen(&self) -> Vec<Seen<'_>> {
        let shown = self.focused_panes();
        self.panes
            .iter()
            .map(|pane| {
                let condition = match pane.proc().dead() {
                    Some(death) => Condition::Dead {
                        at: death.at,
                        cause: &death.cause,
                    },
                    None => Condition::Live,
                };
                let (telemetry, vars) = (pane.telemetry(), pane.vars());
                Seen {
                    id: pane.id(),
                    run: vars.text(&RUN).and_then(|text| text.parse().ok()),
                    condition,
                    agent_session: match pane_kind::of_pane(telemetry, vars) {
                        Kind::PiAgent { session, .. } => Some(session),
                        _ => None,
                    },
                    pi_evidence: pane_kind::pi_evidence(telemetry, vars),
                    shown: shown.contains(&pane.id()),
                }
            })
            .collect()
    }

    pub(crate) fn list_runs(&self, show: Show, parent: Option<&runs::Parent>) -> Vec<Info> {
        runs::infos(&self.runs.root, &self.seen(), show, parent)
    }

    pub(crate) fn run_detail(&self, id: &RunId) -> Result<crate::protocol::Detail, Error> {
        runs::detail(&self.runs.root, &self.seen(), id).ok_or_else(|| no_such_run(id))
    }

    fn ending(&self, meta: &Meta) -> Option<RunOutcome> {
        runs::ending(&self.runs.root, &self.seen(), meta)
    }

    fn live_run_pane(&self, meta: &Meta) -> Option<PaneId> {
        let pane = self.panes.find(meta.pane?)?;
        (pane.proc().dead().is_none()
            && pane
                .vars()
                .text(&RUN)
                .and_then(|text| text.parse().ok())
                .as_ref()
                == Some(&meta.id))
        .then(|| pane.id())
    }

    fn record(&mut self, poll: &mut Poll, meta: &Meta, outcome: RunOutcome) -> bool {
        let recorded = runs::record_outcome(&self.runs.root, &meta.id, &outcome);
        if recorded {
            if let Some(event) = RunEvent::of(meta, Some(outcome)) {
                self.broadcast(&ClientEvent::Run(event));
            }
            self.runs_changed(poll);
        }
        recorded
    }

    pub(super) fn sweep_soon(&mut self, poll: &mut Poll) {
        self.runs.want_sweep();
        self.model.arm(poll);
    }

    pub(super) fn runs_changed(&mut self, poll: &mut Poll) {
        self.sweep_soon(poll);
        if self.runs.waits.is_empty() {
            return;
        }
        let waits = std::mem::take(&mut self.runs.waits);
        let (settled, pending) = {
            let seen = self.seen();
            let mut settled = Vec::new();
            let mut pending = Vec::new();
            for wait in waits {
                match self.settle_wait(&seen, wait) {
                    Ok(done) => settled.push(done),
                    Err(wait) => pending.push(wait),
                }
            }
            (settled, pending)
        };
        self.runs.waits.extend(pending);
        for done in settled {
            self.complete(poll, done);
        }
    }

    fn settle_wait(&self, seen: &[Seen<'_>], wait: Wait) -> Result<Settled, Wait> {
        let done = match &wait.kind {
            WaitKind::Ending(id) => match runs::read_meta(&self.runs.root, id) {
                None => Done::Outcome(None),
                Some(meta) => match runs::ending(&self.runs.root, seen, &meta) {
                    Some(outcome) => Done::Outcome(Some(outcome)),
                    None => return Err(wait),
                },
            },
            WaitKind::Stopping(pane) => {
                if self
                    .panes
                    .find(*pane)
                    .is_some_and(|pane| pane.proc().dead().is_none())
                {
                    return Err(wait);
                }
                Done::Stop(*pane)
            }
        };
        Ok(Settled {
            conn: wait.conn,
            done,
        })
    }

    fn complete(&mut self, poll: &mut Poll, settled: Settled) {
        if let Some(index) = self.index(settled.conn) {
            poll.stop(self.conns[index].timer);
        }
        match settled.done {
            Done::Outcome(outcome) => {
                router::answer(self, poll, settled.conn, Ok(Waited { outcome }));
            }
            Done::Stop(pane) => {
                self.kill_run_pane(poll, pane);
                router::answer(self, poll, settled.conn, Ok(Empty {}));
            }
        }
    }

    pub(super) fn wait_due(&mut self, poll: &mut Poll, timer: Timer) -> bool {
        let Some(token) = self
            .conns
            .iter()
            .find(|conn| conn.timer == timer)
            .map(|conn| conn.token)
        else {
            return false;
        };
        let Some(at) = self.runs.waits.iter().position(|wait| wait.conn == token) else {
            return false;
        };
        let wait = self.runs.waits.swap_remove(at);
        match wait.kind {
            WaitKind::Ending(_) => router::answer(self, poll, token, Ok(Waited { outcome: None })),
            WaitKind::Stopping(pane) => {
                self.kill_run_pane(poll, pane);
                router::answer(self, poll, token, Ok(Empty {}));
            }
        }
        true
    }

    fn defer(&mut self, poll: &mut Poll, index: usize, kind: WaitKind, within: Duration) {
        let conn = &mut self.conns[index];
        conn.phase = Phase::Handling;
        let _ = poll.start(conn.timer, within, None);
        self.runs.waits.push(Wait {
            conn: conn.token,
            kind,
        });
    }

    pub(crate) fn wait_run(
        &mut self,
        poll: &mut Poll,
        index: usize,
        id: RunId,
        timeout_ms: u64,
    ) -> Option<Result<Waited, Error>> {
        let Some(meta) = runs::read_meta(&self.runs.root, &id) else {
            return Some(Err(no_such_run(&id)));
        };
        let ending = self.ending(&meta);
        if ending.is_some() || timeout_ms == 0 {
            return Some(Ok(Waited { outcome: ending }));
        }
        self.defer(
            poll,
            index,
            WaitKind::Ending(id),
            Duration::from_millis(timeout_ms),
        );
        None
    }

    pub(crate) fn run_outcome(
        &mut self,
        poll: &mut Poll,
        index: usize,
        id: RunId,
        report: ReportOutcome,
    ) -> Option<Result<Empty, Error>> {
        let Some(meta) = runs::read_meta(&self.runs.root, &id) else {
            return Some(Err(no_such_run(&id)));
        };
        let outcome = RunOutcome {
            result: report.result.into(),
            text: report.text,
            at: Some(Timestamp::now()),
        };
        if report.result == Reported::Failed
            && let Some(pane) = meta.pane.filter(|pane| self.panes.find(*pane).is_some())
        {
            let token = self.conns[index].token;
            self.conns[index].phase = Phase::Handling;
            self.begin_capture(poll, pane, meta, outcome, Then::Reply(token));
            return None;
        }
        Some(if self.record(poll, &meta, outcome) {
            Ok(Empty {})
        } else {
            Err(lost(&id))
        })
    }

    pub(crate) fn stop_run(
        &mut self,
        poll: &mut Poll,
        index: usize,
        id: RunId,
        request: StopRun,
    ) -> Option<Result<Empty, Error>> {
        let Some(meta) = runs::read_meta(&self.runs.root, &id) else {
            return Some(Err(no_such_run(&id)));
        };
        if request.wait_ms > WAIT_MAX_MS {
            return Some(Err(Error::new(ErrorKind::Invalid, "wait is too long")));
        }
        let live = self.live_run_pane(&meta);
        let result = match request.result {
            StopResult::Stopped => RunResult::Stopped,
            StopResult::Completed => RunResult::Completed,
        };
        let Some(pane) = live else {
            return Some(Err(Error::new(
                ErrorKind::Refused,
                format!("run {id} has already ended"),
            )));
        };
        self.record(
            poll,
            &meta,
            RunOutcome {
                result,
                text: String::new(),
                at: Some(Timestamp::now()),
            },
        );
        if request.wait_ms == 0 {
            self.kill_run_pane(poll, pane);
            return Some(Ok(Empty {}));
        }
        self.defer(
            poll,
            index,
            WaitKind::Stopping(pane),
            Duration::from_millis(request.wait_ms),
        );
        None
    }

    fn kill_run_pane(&mut self, poll: &mut Poll, pane: PaneId) {
        self.delete_pane(poll, pane);
        self.runs
            .doomed
            .push((pane, Instant::now() + self.config.stop_escalation));
        self.arm_escalation(poll);
    }

    fn arm_escalation(&mut self, poll: &mut Poll) {
        match next_escalation(&self.runs.doomed, Instant::now()) {
            Some(next) => {
                let _ = poll.start(self.runs.escalation, next, None);
            }
            None => poll.stop(self.runs.escalation),
        }
    }

    pub(super) fn escalate(&mut self, poll: &mut Poll) {
        let now = Instant::now();
        let State { runs, panes, .. } = self;
        runs.doomed.retain(|(pane, due)| {
            if *due > now {
                return true;
            }
            let _ = panes.kill_removed(*pane);
            false
        });
        self.arm_escalation(poll);
    }

    pub(crate) fn start_run(
        &mut self,
        poll: &mut Poll,
        caller: Option<PaneId>,
        request: StartRun,
    ) -> Result<Started, Error> {
        let invalid = |message: String| Error::new(ErrorKind::Invalid, message);
        let layout = self.document.layout();
        let session = match (&request.session, caller) {
            (Some(SessionRef::Id(id)), _) => layout.session(*id),
            (Some(SessionRef::Name(name)), _) => {
                layout.sessions.iter().find(|session| session.name == *name)
            }
            (None, Some(pane)) => layout.locate(pane).map(|(session, _)| session),
            (None, None) => return Err(invalid("no caller pane; name a session".to_owned())),
        }
        .ok_or_else(|| invalid("no such session".to_owned()))?;
        let session_id = session.id;
        if let Some(parent) = &request.parent {
            let gone = runs::parent_ended(&self.runs.root, &self.seen(), parent);
            match gone {
                Some(Ended::Unknown(message)) => {
                    return Err(Error::new(ErrorKind::Missing, message));
                }
                Some(Ended::Over(message)) => return Err(Error::new(ErrorKind::Gone, message)),
                None => {}
            }
        }
        let io = |error: std::io::Error| Error::new(ErrorKind::Io, error.to_string());
        let id = RunId::mint().map_err(io)?;
        let mut meta = runs::Meta {
            id: id.clone(),
            name: request.name.clone(),
            parent: request.parent.clone(),
            pane: None,
            cwd: request.cwd.clone().unwrap_or_default(),
            started_at: Timestamp::now(),
        };
        runs::write_meta(&self.runs.root, &meta).map_err(io)?;
        runs::write_command(&self.runs.root, &id, &request.argv).map_err(io)?;
        let output = runs::output_path(&self.runs.root, &id)
            .to_string_lossy()
            .into_owned();
        let mut env = vec![
            Variable {
                name: "KO_RUN_ID".to_owned(),
                value: id.to_string(),
            },
            Variable {
                name: "KO_RUN_OUTPUT".to_owned(),
                value: output.clone(),
            },
        ];
        env.extend(request.env);
        let create = CreatePane {
            cwd: request.cwd,
            command: Some(Command::Argv { argv: request.argv }),
            env,
            vars: Loose::from([(RUN.as_str().to_owned(), serde_json::json!(id.to_string()))]),
        };
        let name =
            Name::try_from(request.name.as_str().to_owned()).map_err(|m| invalid(m.to_owned()))?;
        let mut draft = DraftLayout::from(self.document.layout());
        if let Some(draft_session) = draft
            .sessions
            .iter_mut()
            .find(|candidate| candidate.id == Some(session_id))
        {
            let mut window = crate::protocol::DraftWindow::single(&create);
            window.name = Some(name);
            draft_session.windows.push(window);
        }
        let revision = self.document.revision();
        let put = self.put_layout(
            poll,
            PutLayout {
                revision,
                layout: draft,
            },
        );
        let snapshot = match put {
            Ok(snapshot) => snapshot,
            Err(failure) => {
                let error = Error::from(failure);
                runs::record_outcome(
                    &self.runs.root,
                    &id,
                    &RunOutcome {
                        result: RunResult::Failed,
                        text: error.message.clone(),
                        at: Some(Timestamp::now()),
                    },
                );
                return Err(error);
            }
        };
        let created = snapshot
            .layout
            .session(session_id)
            .and_then(|session| session.windows.last())
            .and_then(|window| Some((window.id, window.panes().first().copied()?)));
        let Some((window, pane)) = created else {
            return Err(Error::new(ErrorKind::Io, "the run's window is missing"));
        };
        meta.pane = Some(pane);
        if let Err(failed) = runs::write_meta(&self.runs.root, &meta) {
            self.delete_pane(poll, pane);
            return Err(io(failed));
        }
        if let Some(event) = RunEvent::of(&meta, None) {
            self.broadcast(&ClientEvent::Run(event));
        }
        Ok(Started {
            id,
            window,
            pane,
            output,
        })
    }

    pub(crate) fn reap_runs(&mut self, poll: &mut Poll) {
        self.sweep(poll);
    }

    pub(super) fn sweep(&mut self, poll: &mut Poll) {
        let now = ko_sys::clock::Mono::now();
        let swept = runs::sweep(&self.runs.root, &self.seen(), now, self.config.linger);
        for Closing { pane, run, outcome } in swept.closing {
            if self
                .runs
                .captures
                .iter()
                .any(|capture| capture.pane == pane)
            {
                continue;
            }
            if let Some(meta) = runs::read_meta(&self.runs.root, &run) {
                self.begin_capture(poll, pane, meta, outcome, Then::Close);
            }
        }
        match swept.next {
            Some(next) => {
                let _ = poll.start(self.runs.sweep, next, None);
            }
            None => poll.stop(self.runs.sweep),
        }
    }

    fn begin_capture(
        &mut self,
        poll: &mut Poll,
        pane: PaneId,
        meta: Meta,
        mut outcome: RunOutcome,
        then: Then,
    ) {
        outcome.at.get_or_insert_with(Timestamp::now);
        let requested = self.call(poll, pane, |pane, io| {
            pane.proc_mut()
                .screen(ScreenFormat::Plain, ScreenRows::Last(SCREEN_HISTORY), io)
        });
        let (req, events) = match requested {
            Some((req, events)) => (req, events),
            None => (None, Vec::new()),
        };
        let capture = Capture {
            pane,
            req,
            meta,
            outcome,
            screen: Vec::new(),
            then,
        };
        match req {
            Some(req) => {
                self.owners.insert((pane, req), Owner::Capture);
                self.runs.captures.push(capture);
                self.dispatch(poll, pane, events);
            }
            None => self.finish_capture(poll, capture),
        }
    }

    pub(super) fn capture_chunk(
        &mut self,
        poll: &mut Poll,
        pane: PaneId,
        req: Req,
        chunk: &[u8],
        last: bool,
    ) {
        let Some(at) = capture_at(&self.runs.captures, pane, req) else {
            return;
        };
        self.runs.captures[at].screen.extend_from_slice(chunk);
        if last {
            let capture = self.runs.captures.swap_remove(at);
            self.finish_capture(poll, capture);
        }
    }

    pub(super) fn capture_failed(&mut self, poll: &mut Poll, pane: PaneId, req: Req) {
        if let Some(at) = capture_at(&self.runs.captures, pane, req) {
            let capture = self.runs.captures.swap_remove(at);
            self.finish_capture(poll, capture);
        }
    }

    fn still_sweepable(&self, pane: PaneId) -> bool {
        let seen = self.seen();
        if !seen.iter().any(|candidate| candidate.id == pane) {
            return true;
        }
        runs::sweep(
            &self.runs.root,
            &seen,
            ko_sys::clock::Mono::now(),
            self.config.linger,
        )
        .closing
        .iter()
        .any(|closing| closing.pane == pane)
    }

    fn finish_capture(&mut self, poll: &mut Poll, capture: Capture) {
        let Capture {
            pane,
            meta,
            outcome,
            screen,
            then,
            ..
        } = capture;
        self.sweep_soon(poll);
        if matches!(then, Then::Close) && !self.still_sweepable(pane) {
            return;
        }
        runs::write_screen(&self.runs.root, &meta.id, &screen);
        let recorded = self.record(poll, &meta, outcome);
        match then {
            Then::Close => self.delete_pane(poll, pane),
            Then::Reply(conn) => {
                let reply = if recorded {
                    Ok(Empty {})
                } else {
                    Err(lost(&meta.id))
                };
                router::answer(self, poll, conn, reply);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn capture(pane: u64, serial: u64) -> Capture {
        Capture {
            pane: PaneId::new(pane),
            req: Some(Req::of_serial(serial)),
            meta: Meta {
                id: format!("{:032x}", serial).parse().unwrap(),
                name: crate::runs::RunName::new("r").unwrap(),
                parent: None,
                pane: None,
                cwd: String::new(),
                started_at: Timestamp::from_micros(0),
            },
            outcome: RunOutcome {
                result: RunResult::Failed,
                text: String::new(),
                at: None,
            },
            screen: Vec::new(),
            then: Then::Close,
        }
    }

    #[test]
    fn a_screen_reply_finds_its_capture_by_pane_and_request_after_others_left() {
        let mut captures = vec![capture(1, 1), capture(1, 2), capture(1, 3), capture(2, 1)];
        let (pane, other) = (PaneId::new(1), PaneId::new(2));
        let first = capture_at(&captures, pane, Req::of_serial(1)).unwrap();
        captures.swap_remove(first);
        assert!(capture_at(&captures, pane, Req::of_serial(3)).is_some());
        for (at, serial) in [(pane, 2), (pane, 3)] {
            let found = capture_at(&captures, at, Req::of_serial(serial)).unwrap();
            assert_eq!(
                captures[found]
                    .req
                    .map(|req| req.same(Req::of_serial(serial))),
                Some(true)
            );
        }
        assert_eq!(capture_at(&captures, pane, Req::of_serial(1)), None);
        assert!(capture_at(&captures, other, Req::of_serial(1)).is_some());
    }

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
