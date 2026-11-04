use std::path::{Path, PathBuf};

use super::pane_ops::Via;
use super::runtime_ops::resolve_runtime;
use super::*;
use crate::api::routes;
use crate::ids::RunId;
use crate::pane_kind::{self, Kind};
use crate::panes::{self, Condition, Seen};
use crate::protocol::{
    Close, Command, CreatePane, Empty, Error, ErrorKind, Info, ReportOutcome, Reported, RunRow,
    SessionRef, Show, StartRun, Started, StopResult, StopRun, Variable, Waited,
};
use crate::runs::{self, Closing, Ended, Meta, RunOutcome, RunResult};
use crate::timestamp::Timestamp;
use crate::vars::Loose;
use ko_pane_wire::frame::{Req, ScreenFormat};

#[derive(Debug)]
struct Wait {
    conn: Token,
    run: RunId,
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
    waits: Vec<Wait>,
    captures: Vec<Capture>,
    sweep_due: bool,
    focused: BTreeSet<PaneId>,
}

fn capture_at(captures: &[Capture], pane: PaneId, req: Req) -> Option<usize> {
    captures.iter().position(|capture| {
        capture.pane == pane && capture.req.is_some_and(|found| found.same(req))
    })
}

impl RunState {
    pub(super) fn new(config: &Config, poll: &mut Poll) -> RunState {
        RunState {
            root: runs::root(&config.dir),
            sweep: poll.timer(),
            waits: Vec::new(),
            captures: Vec::new(),
            sweep_due: false,
            focused: BTreeSet::new(),
        }
    }

    pub(super) fn root(&self) -> &Path {
        &self.root
    }

    pub(super) fn stop(&self, poll: &mut Poll) {
        poll.stop(self.sweep);
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
}

fn condition_of(pane: &Pane) -> Condition<'_> {
    match pane.proc().dead() {
        Some(death) => Condition::Dead {
            at: death.at,
            cause: &death.cause,
        },
        None => Condition::Live,
    }
}

pub(super) fn run_row(root: &Path, pane: &Pane) -> Option<RunRow> {
    runs::row(root, pane.id(), pane.run()?, condition_of(pane))
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
            .map(|pane| Seen {
                id: pane.id(),
                run: pane.run().cloned(),
                condition: condition_of(pane),
                parent: pane.parent(),
                close: pane.close(),
                shown: shown.contains(&pane.id()),
            })
            .collect()
    }

    fn with_session(&self, mut info: Info) -> Info {
        info.session = info
            .run
            .meta
            .pane
            .and_then(|id| self.panes.find(id))
            .filter(|pane| pane.proc().dead().is_none() && pane.run() == Some(&info.run.meta.id))
            .and_then(
                |pane| match pane_kind::of_pane(pane.telemetry(), pane.vars()) {
                    Kind::PiAgent { session, .. } => Some(session),
                    _ => None,
                },
            );
        info
    }

    pub(crate) fn list_runs(&self, show: Show, parent: Option<&runs::Parent>) -> Vec<Info> {
        runs::infos(&self.runs.root, &self.seen(), show, parent)
            .into_iter()
            .map(|info| self.with_session(info))
            .collect()
    }

    pub(crate) fn run_detail(&self, id: &RunId) -> Result<Info, Error> {
        runs::detail(&self.runs.root, &self.seen(), id)
            .map(|info| self.with_session(info))
            .ok_or_else(|| no_such_run(id))
    }

    pub(crate) fn run_screen(&self, id: &RunId) -> Result<(std::fs::File, usize), Error> {
        if runs::read_meta(&self.runs.root, id).is_none() {
            return Err(no_such_run(id));
        }
        runs::open_screen(&self.runs.root, id).ok_or_else(|| {
            Error::new(
                ErrorKind::Missing,
                format!("run {id}: no screen was captured"),
            )
        })
    }

    fn ending(&self, meta: &Meta) -> Option<RunOutcome> {
        runs::ending(&self.runs.root, &self.seen(), meta)
    }

    fn live_run_pane(&self, meta: &Meta) -> Option<PaneId> {
        let pane = self.panes.find(meta.pane?)?;
        (pane.proc().dead().is_none() && pane.run() == Some(&meta.id)).then(|| pane.id())
    }

    fn record(&mut self, poll: &mut Poll, meta: &Meta, outcome: RunOutcome) -> bool {
        let recorded = runs::record_outcome_once(&self.runs.root, &meta.id, &outcome);
        if recorded {
            if meta.pane.is_some() {
                self.broadcast(&ClientEvent::Run(RunRow {
                    meta: meta.clone(),
                    outcome: Some(outcome),
                }));
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
        self.settle_stops(poll);
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
        for (conn, outcome) in settled {
            router::answer::<routes::WaitRun>(self, poll, conn, Ok(Waited { outcome }));
        }
    }

    fn settle_wait(
        &self,
        seen: &[Seen<'_>],
        wait: Wait,
    ) -> Result<(Token, Option<RunOutcome>), Wait> {
        match runs::read_meta(&self.runs.root, &wait.run) {
            None => Ok((wait.conn, None)),
            Some(meta) => match runs::ending(&self.runs.root, seen, &meta) {
                Some(outcome) => Ok((wait.conn, Some(outcome))),
                None => Err(wait),
            },
        }
    }

    pub(super) fn wait_due(&mut self, poll: &mut Poll, timer: Timer) -> bool {
        let Some(token) = self.token_of_timer(timer) else {
            return false;
        };
        let Some(at) = self.runs.waits.iter().position(|wait| wait.conn == token) else {
            return false;
        };
        self.runs.waits.swap_remove(at);
        router::answer::<routes::WaitRun>(self, poll, token, Ok(Waited { outcome: None }));
        true
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
        let conn = self.hold(poll, index, Duration::from_millis(timeout_ms));
        self.runs.waits.push(Wait { conn, run: id });
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
        self.stop_after(poll, index, pane, request.wait_ms, Via::Run)
    }

    pub(crate) fn start_run(
        &mut self,
        poll: &mut Poll,
        caller: Option<PaneId>,
        origin: &crate::server::Origin,
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
        let parent = request
            .parent
            .as_ref()
            .map(|parent| {
                runs::parent_pane(&self.runs.root, &self.seen(), parent).map_err(
                    |ended| match ended {
                        Ended::Unknown(message) => Error::new(ErrorKind::Missing, message),
                        Ended::Over(message) => Error::new(ErrorKind::Gone, message),
                    },
                )
            })
            .transpose()?;
        if let Some(parent) = parent {
            self.admit_parent(caller, parent)?;
        }
        self.admit_cwd(caller, origin, request.cwd.as_ref())?;
        let io = |error: std::io::Error| Error::new(ErrorKind::Io, error.to_string());
        let id = RunId::mint().map_err(io)?;
        let mut env = vec![Variable {
            name: "KO_RUN_ID".to_owned(),
            value: id.to_string(),
        }];
        env.extend(request.env);
        let create = CreatePane {
            cwd: request.cwd,
            command: Some(Command::Argv {
                argv: request.argv.clone(),
            }),
            env,
            vars: Loose::new(),
            parent,
            close: Close::OnExit,
            runtime: resolve_runtime(origin, request.runtime)?,
        };
        let read = Read::new(&self.config.file);
        let dir = self.start_dir(&create, caller, &read);
        let mut meta = runs::Meta {
            id: id.clone(),
            name: request.name.clone(),
            parent: request.parent.clone(),
            pane: None,
            runtime: None,
            argv: request.argv,
            cwd: self.recorded_dir(&create, &dir, &read)?,
            started_at: Timestamp::now(),
        };
        runs::write_meta(&self.runs.root, &meta).map_err(io)?;
        let name =
            Name::try_from(request.name.as_str().to_owned()).map_err(|m| invalid(m.to_owned()))?;
        let placed = self.place_pane(
            poll,
            (caller, origin),
            Some(SessionRef::Id(session_id)),
            Some(name),
            create,
            (Some(id.clone()), &read),
        );
        let placement = match placed {
            Ok(placement) => placement,
            Err(error) => {
                runs::record_outcome_once(
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
        let (window, pane) = (placement.window, placement.pane);
        meta.pane = Some(pane);
        meta.runtime = self
            .panes
            .find(pane)
            .and_then(|found| found.runtime().cloned());
        if let Err(failed) = runs::write_meta(&self.runs.root, &meta) {
            self.delete_pane(poll, pane);
            return Err(io(failed));
        }
        Ok(Started { id, window, pane })
    }

    #[cfg(test)]
    pub(crate) fn sweep_now(&mut self, poll: &mut Poll) {
        self.sweep(poll);
    }

    pub(super) fn sweep(&mut self, poll: &mut Poll) {
        let (closing, next) = {
            let seen = self.seen();
            let swept = panes::sweep(&seen, ko_sys::clock::Mono::now(), || self.config.linger());
            (
                runs::closing(&self.runs.root, &seen, &swept.removed),
                swept.next,
            )
        };
        for Closing { pane, run } in closing {
            if self
                .runs
                .captures
                .iter()
                .any(|capture| capture.pane == pane)
            {
                continue;
            }
            match run {
                Some((id, outcome)) => {
                    if let Some(meta) = runs::read_meta(&self.runs.root, &id) {
                        self.begin_capture(poll, pane, meta, outcome, Then::Close);
                    }
                }
                None => self.delete_pane(poll, pane),
            }
        }
        match next {
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
                .screen(ScreenFormat::Plain, ScreenRows::Full, io)
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
        let max = self.config.run_screen_bytes;
        let screen = &mut self.runs.captures[at].screen;
        screen.extend_from_slice(chunk);
        if last || screen.len() > max.saturating_mul(2) {
            let cut = runs::cut_point(screen, max);
            screen.drain(..cut);
        }
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
        panes::sweep(&seen, ko_sys::clock::Mono::now(), || self.config.linger())
            .removed
            .contains(&pane)
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
                router::answer::<routes::RunOutcome>(self, poll, conn, reply);
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
                runtime: None,
                argv: Vec::new(),
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
}
