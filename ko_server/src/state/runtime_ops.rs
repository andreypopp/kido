use std::collections::BTreeMap;

use super::*;
use crate::api::{Route, WaitMs, routes};
use crate::pane::Birth;
use crate::panes::{AddError, is_descendant, program, scope};
use crate::protocol::{
    Empty, Error, ErrorKind, Info, LeadReport, LinkState, RuntimeInfo, RuntimeWait,
};
use crate::runtime::pane::{self, Wrap as Entering, socket_path};
use crate::runtime::{CLEANUP_LIMIT, Due, PASS_HOLD, Wait, Who};
use crate::server::Origin;
use crate::vars::Vars;

pub(super) fn resolve_runtime(
    origin: &Origin,
    requested: Option<RuntimeName>,
) -> Result<Option<RuntimeName>, Error> {
    match (origin, requested) {
        (Origin::Host, requested) => Ok(requested),
        (Origin::Runtime(own), None) => Ok(Some(own.clone())),
        (Origin::Runtime(own), Some(named)) if named == *own => Ok(Some(named)),
        (Origin::Runtime(own), Some(named)) => Err(Error::new(
            ErrorKind::Refused,
            format!("a connection of runtime {own} creates panes in {own}, not in {named}"),
        )),
    }
}

impl State {
    pub(super) fn choose_runtimes<'a>(
        &self,
        requests: impl Iterator<Item = &'a CreatePane>,
    ) -> Result<BTreeMap<RuntimeName, Runtime>, Error> {
        let mut chosen = BTreeMap::new();
        for name in requests.filter_map(|request| request.runtime.as_ref()) {
            if !chosen.contains_key(name) {
                chosen.insert(name.clone(), self.runtimes.settings(name)?);
            }
        }
        Ok(chosen)
    }

    pub(super) fn birth(
        &self,
        id: PaneId,
        request: &CreatePane,
        (vars, run): (Vars, Option<RunId>),
        (caller, chosen): (Option<PaneId>, &BTreeMap<RuntimeName, Runtime>),
    ) -> Result<Birth, AddError> {
        let program = match &request.runtime {
            None => program(&self.config, request, None)?,
            Some(name) => {
                let runtime = chosen
                    .get(name)
                    .ok_or(AddError::Invalid("no such runtime"))?;
                let entering = Entering {
                    exe: &self.config.exe,
                    root: self.runtimes.root(),
                    name,
                    runtime,
                    pane: id,
                    cwd: request.cwd.as_deref(),
                    env: &request.env,
                    server_env: &self.config.env,
                    from_runtime: caller.is_some_and(|caller| self.panes.is_in(caller, name)),
                };
                program(
                    &self.config,
                    request,
                    Some(&|inner| pane::wrapper(&entering, inner)),
                )?
            }
        };
        Ok(Birth {
            vars,
            run,
            parent: request.parent,
            close: request.close,
            runtime: request.runtime.clone(),
            program,
        })
    }

    fn occupied(&self, name: &RuntimeName) -> bool {
        self.panes.any_in(name) || self.conns.iter().any(|conn| conn.runs_exec(name))
    }

    pub(super) fn touch_runtime(&mut self, poll: &mut Poll, name: &RuntimeName) {
        let occupied = self.occupied(name);
        self.runtimes.occupy(poll, name, occupied);
    }

    pub(super) fn runtimes_changed(&mut self, poll: &mut Poll) {
        for pid in self.runtimes.take_dying() {
            self.leaving
                .hand_over(poll, pid, self.config.stop_escalation);
        }
        for pid in self.runtimes.take_cleaning() {
            self.leaving.track(poll, pid, CLEANUP_LIMIT);
        }
        for pid in self.runtimes.take_released() {
            self.leaving.release(pid);
        }
        for (name, wait, state) in self.runtimes.take_settled() {
            self.answer_wait(poll, &name, wait, state);
        }
        for (conn, state) in self.runtimes.take_passed() {
            let reply = Ok(RuntimeWait { state, lead: None });
            router::answer::<routes::WaitRuntime>(self, poll, conn, reply);
        }
    }

    fn pass_token(&mut self, poll: &mut Poll, name: &RuntimeName, conn: Token, pane: PaneId) {
        let started = match self.panes.find(pane) {
            Some(found) => {
                let token = found.token().to_string();
                self.runtimes.pass(poll, name, (conn, pane), token)
            }
            None => Err(format!("{pane} is gone")),
        };
        if let Err(message) = started {
            let reply = Ok(RuntimeWait {
                state: LinkState::Failed { message },
                lead: None,
            });
            router::answer::<routes::WaitRuntime>(self, poll, conn, reply);
        }
    }

    fn answer_wait(&mut self, poll: &mut Poll, name: &RuntimeName, wait: Wait, state: LinkState) {
        match wait.who {
            Who::Pane(pane)
                if state == LinkState::Up && self.runtimes.remote_tokens(name, pane) =>
            {
                self.pass_token(poll, name, wait.conn, pane);
            }
            Who::Pane(pane) => {
                let reply = self.runtime_reply(name, pane, state);
                router::answer::<routes::WaitRuntime>(self, poll, wait.conn, reply);
            }
            Who::Exec => self.exec_linked(poll, wait.conn, name, state),
        }
    }

    fn runtime_reply(
        &self,
        name: &RuntimeName,
        pane: PaneId,
        state: LinkState,
    ) -> Result<RuntimeWait, Error> {
        if state == LinkState::Up
            && let Some(found) = self.panes.find(pane)
        {
            self.runtimes
                .write_token(name, pane, found.token())
                .map_err(|error| Error::new(ErrorKind::Io, format!("token file: {error}")))?;
        }
        Ok(RuntimeWait { state, lead: None })
    }

    pub(super) fn runtime_ready(&mut self, poll: &mut Poll, ready: Ready) -> bool {
        let mut accepted = Vec::new();
        if self.runtimes.accept(poll, ready, &mut accepted) {
            for stream in accepted {
                self.accept(poll, stream);
            }
            return true;
        }
        self.runtimes.helper_ready(poll, ready)
    }

    pub(super) fn runtime_due(&mut self, poll: &mut Poll, timer: Timer) -> bool {
        match self.runtimes.due(poll, timer) {
            Due::Handled => {
                self.runtimes_changed(poll);
                true
            }
            Due::Idle(name) => {
                let _ = self.down_runtime(poll, &name, false);
                true
            }
            Due::Other => {
                let Some(token) = self.token_of_timer(timer) else {
                    return false;
                };
                let Some(state) = self.runtimes.expire_pane_wait(poll, token) else {
                    return false;
                };
                let reply = Ok(RuntimeWait { state, lead: None });
                router::answer::<routes::WaitRuntime>(self, poll, token, reply);
                true
            }
        }
    }

    fn runtime_info(&self, name: &RuntimeName, runtime: &Runtime) -> RuntimeInfo {
        RuntimeInfo {
            name: name.clone(),
            kind: runtime.kind(),
            state: self.runtimes.state(name),
            panes: u32::try_from(self.panes.in_runtime(name).count()).unwrap_or(u32::MAX),
            socket: socket_path(self.runtimes.root(), name)
                .to_string_lossy()
                .into_owned(),
            paths: runtime.paths(),
        }
    }

    pub(crate) fn list_runtimes(&self) -> Result<Vec<RuntimeInfo>, Error> {
        Ok(self
            .runtimes
            .known()?
            .iter()
            .map(|(name, runtime)| self.runtime_info(name, runtime))
            .collect())
    }

    pub(crate) fn get_runtime(&self, name: &RuntimeName) -> Result<RuntimeInfo, Error> {
        Ok(self.runtime_info(name, &self.runtimes.settings(name)?))
    }

    fn runtime_pane(&self, caller: Option<PaneId>, name: &RuntimeName) -> Result<PaneId, Error> {
        caller
            .filter(|caller| self.panes.is_in(*caller, name))
            .ok_or_else(|| {
                Error::new(
                    ErrorKind::Refused,
                    format!("only a pane of runtime {name} may use this route"),
                )
            })
    }

    pub(crate) fn wait_runtime(
        &mut self,
        poll: &mut Poll,
        index: usize,
        caller: Option<PaneId>,
        name: RuntimeName,
        timeout: WaitMs,
    ) -> Option<Result<RuntimeWait, Error>> {
        let pane = match self.runtime_pane(caller, &name) {
            Ok(pane) => pane,
            Err(error) => return Some(Err(error)),
        };
        let state = self.runtimes.state(&name);
        if state == LinkState::Up && self.runtimes.remote_tokens(&name, pane) {
            let conn = self.hold(poll, index, PASS_HOLD);
            self.pass_token(poll, &name, conn, pane);
            return None;
        }
        if state != LinkState::Starting {
            return Some(self.runtime_reply(&name, pane, state));
        }
        if let Some(lead) = self.runtimes.elect(&name, pane) {
            return Some(Ok(RuntimeWait {
                state,
                lead: Some(lead),
            }));
        }
        if timeout == WaitMs::NONE {
            return Some(Ok(RuntimeWait { state, lead: None }));
        }
        let conn = self.hold(poll, index, Duration::from_millis(timeout.get()));
        self.runtimes.wait(
            &name,
            Wait {
                conn,
                who: Who::Pane(pane),
            },
        );
        None
    }

    pub(crate) fn report_lead(
        &mut self,
        poll: &mut Poll,
        caller: Option<PaneId>,
        name: RuntimeName,
        report: LeadReport,
    ) -> Result<Empty, Error> {
        let pane = self.runtime_pane(caller, &name)?;
        self.runtimes.report_lead(poll, &name, pane, report)?;
        self.runtimes_changed(poll);
        Ok(Empty {})
    }

    pub(crate) fn down_runtime(
        &mut self,
        poll: &mut Poll,
        name: &RuntimeName,
        force: bool,
    ) -> Result<(), Error> {
        if !self.runtimes.is_live(name) {
            return self.runtimes.settings(name).map(|_| ());
        }
        let live: Vec<PaneId> = self
            .panes
            .in_runtime(name)
            .filter(|pane| pane.proc().dead().is_none())
            .map(Pane::id)
            .collect();
        let sessions = self.conns.iter().any(|conn| conn.runs_exec(name));
        if (!live.is_empty() || sessions) && !force {
            return Err(Error::new(
                ErrorKind::Refused,
                format!(
                    "runtime {name} has live panes or exec sessions; stop them or force the request"
                ),
            ));
        }
        for id in live {
            self.kill_pane(poll, id);
        }
        self.exec_down(poll, name);
        let waiters = self.runtimes.waiters_of(name);
        self.runtimes.down(poll, name, false);
        for wait in waiters {
            self.answer_wait(poll, name, wait, LinkState::Down);
        }
        let own = Origin::Runtime(name.clone());
        for conn in self.conns.iter_mut().filter(|conn| conn.origin == own) {
            conn.out.close();
        }
        self.runtimes_changed(poll);
        Ok(())
    }

    pub(crate) fn delete_runtime(
        &mut self,
        poll: &mut Poll,
        name: &RuntimeName,
    ) -> Result<Empty, Error> {
        let settings = self.runtimes.settings(name)?;
        self.down_runtime(poll, name, false)?;
        self.runtimes.delete(name, &settings);
        self.runtimes.remove_directory(name);
        Ok(Empty {})
    }

    fn hidden(caller: PaneId, target: PaneId, runtime: &RuntimeName) -> Error {
        Error::new(
            ErrorKind::Refused,
            format!("{target} is not visible to {caller} on runtime {runtime}"),
        )
    }

    pub(crate) fn visible_to(&self, runtime: &RuntimeName, caller: PaneId) -> BTreeSet<PaneId> {
        let mut seen = scope(&self.edges(), caller);
        seen.extend(self.panes.in_runtime(runtime).map(Pane::id));
        seen
    }

    pub(crate) fn visible_runs(
        &self,
        runtime: &RuntimeName,
        caller: PaneId,
        infos: Vec<Info>,
    ) -> Vec<Info> {
        let seen = self.visible_to(runtime, caller);
        infos
            .into_iter()
            .filter(
                |info| match info.run.meta.pane.filter(|p| self.panes.find(*p).is_some()) {
                    Some(pane) => seen.contains(&pane),
                    None => info.run.meta.runtime.as_ref() == Some(runtime),
                },
            )
            .collect()
    }

    pub(crate) fn runtime_gate(
        &self,
        runtime: &RuntimeName,
        caller: PaneId,
        route: &Route,
    ) -> Result<(), Error> {
        let allow = |ok: bool, id: PaneId| {
            if ok {
                Ok(())
            } else {
                Err(State::hidden(caller, id, runtime))
            }
        };
        let shown = |id: PaneId| {
            allow(
                self.panes.is_in(id, runtime) || self.visible_to(runtime, caller).contains(&id),
                id,
            )
        };
        let reached = |id: PaneId| {
            allow(
                self.panes.is_in(id, runtime) || is_descendant(&self.edges(), caller, id),
                id,
            )
        };
        let of_run = |id: &RunId, check: &dyn Fn(PaneId) -> Result<(), Error>| {
            let Some(meta) = runs::read_meta(self.runs.root(), id) else {
                return Ok(());
            };
            match meta.pane.filter(|pane| self.panes.find(*pane).is_some()) {
                Some(pane) => check(pane),
                None if meta.runtime.as_ref() == Some(runtime) => Ok(()),
                None => Err(Error::new(
                    ErrorKind::Refused,
                    format!("run {id} is not visible to {caller} on runtime {runtime}"),
                )),
            }
        };
        match route {
            Route::Version {}
            | Route::GetLayout {}
            | Route::ListPanes {}
            | Route::NewPane {}
            | Route::StartRun {}
            | Route::ListRuns { .. }
            | Route::StopPane { .. }
            | Route::SetVar { .. }
            | Route::DeleteVar { .. }
            | Route::DeleteVars { .. }
            | Route::Output { .. }
            | Route::Messages { .. }
            | Route::PostMessage { .. }
            | Route::PromptResolve { .. }
            | Route::SendPrompt { .. } => Ok(()),
            Route::GetPane { id } => shown(*id),
            Route::ClearHistory { id } | Route::Input { id } | Route::Screen { id, .. } => {
                reached(*id)
            }
            Route::GetRun { id }
            | Route::WaitRun { id, .. }
            | Route::RunOutcome { id }
            | Route::StopRun { id } => of_run(id, &shown),
            Route::RunScreen { id } => of_run(id, &reached),
            _ => {
                let (method, target) = route.to_request();
                Err(Error::new(
                    ErrorKind::Refused,
                    format!("{method} {target} is not available on a runtime connection"),
                ))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_pane_goes_in_the_runtime_of_its_connection_and_a_host_connection_names_any() {
        let dev: RuntimeName = "dev".parse().unwrap();
        let other: RuntimeName = "other".parse().unwrap();
        let on_dev = Origin::Runtime(dev.clone());
        assert_eq!(resolve_runtime(&Origin::Host, None), Ok(None));
        assert_eq!(
            resolve_runtime(&Origin::Host, Some(other.clone())),
            Ok(Some(other.clone()))
        );
        assert_eq!(resolve_runtime(&on_dev, None), Ok(Some(dev.clone())));
        assert_eq!(
            resolve_runtime(&on_dev, Some(dev.clone())),
            Ok(Some(dev.clone()))
        );
        let refused = resolve_runtime(&on_dev, Some(other)).unwrap_err();
        assert_eq!(refused.kind, ErrorKind::Refused);
        assert!(
            refused
                .message
                .contains("creates panes in dev, not in other")
        );
    }
}
