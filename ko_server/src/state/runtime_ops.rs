use std::collections::BTreeMap;

use super::*;
use crate::api::{Route, WaitMs, routes};
use crate::pane::Birth;
use crate::panes::{AddError, Start, is_descendant, program, scope};
use crate::protocol::{
    ClientRuntime, Empty, Error, ErrorKind, LinkState, RuntimeInfo, RuntimeSource, RuntimeWait,
};
use crate::runtime::pane::{self, Dir, Wrap as Entering, socket_path};
use crate::runtime::{CLEANUP_LIMIT, Due, PASS_HOLD, RuntimeKey, Wait, Who};
use crate::server::Origin;
use crate::vars::Vars;

pub(super) fn resolve_runtime(
    origin: &Origin,
    requested: Option<RuntimeName>,
) -> Result<Option<RuntimeName>, Error> {
    match (origin, requested) {
        (Origin::Host, requested) => Ok(requested),
        (Origin::Runtime(own), None) => Ok(Some(own.name.clone())),
        (Origin::Runtime(own), Some(named)) if named == own.name => Ok(Some(own.name.clone())),
        (Origin::Runtime(own), Some(named)) => Err(Error::new(
            ErrorKind::Refused,
            format!("a connection of runtime {own} creates panes in {own}, not in {named}"),
        )),
    }
}

#[derive(Debug)]
pub(super) struct ChosenRuntimes {
    pub(super) settings: BTreeMap<RuntimeKey, Runtime>,
    pub(super) keys: BTreeMap<PaneId, RuntimeKey>,
}

impl State {
    pub(super) fn session_of(&self, pane: PaneId) -> Option<SessionId> {
        self.document
            .layout()
            .locate(pane)
            .map(|(session, _)| session.id)
    }

    pub(super) fn validate_runtime_layout(
        &mut self,
        before: &Layout,
        read: &Read,
    ) -> Result<(), Error> {
        for pane in before.panes() {
            let Some(key) = self.panes.find(pane).and_then(Pane::runtime).cloned() else {
                continue;
            };
            let Some(session) = self.session_of(pane) else {
                continue;
            };
            if before
                .locate(pane)
                .is_some_and(|(previous, _)| previous.id == session)
            {
                continue;
            }
            let resolved = self
                .runtimes
                .resolve(&key.name, Some(session), read.get())?;
            if key != resolved {
                let message = match key.source {
                    RuntimeSource::Session { id } => {
                        format!("{pane} runs in runtime {} of {id}", key.name)
                    }
                    RuntimeSource::Config => format!(
                        "{pane} runs in configured runtime {}; runtime {} of {session} shadows it",
                        key.name, key.name
                    ),
                };
                return Err(Error::new(ErrorKind::Invalid, message));
            }
        }
        Ok(())
    }

    pub(super) fn remove_session_runtimes(&mut self, poll: &mut Poll, before: &Layout) {
        for session in &before.sessions {
            if self.document.layout().session(session.id).is_none() {
                for (key, settings) in self.runtimes.session_definitions(session.id) {
                    self.force_down_runtime(poll, &key);
                    self.runtimes.delete(&key, &settings);
                    self.runtimes.remove_directory(&key);
                }
            }
        }
        self.announce_runtimes();
    }

    pub(crate) fn runtime_key(
        &mut self,
        caller: Option<PaneId>,
        session: Option<SessionId>,
        name: &RuntimeName,
    ) -> Result<(RuntimeKey, Runtime), Error> {
        let own = caller.and_then(|id| self.session_of(id));
        if caller.is_some() && session.is_some() && session != own {
            return Err(Error::new(
                ErrorKind::Refused,
                "a pane may name only its own session",
            ));
        }
        let read = Read::new(&self.config.file);
        let key = self.runtimes.resolve(name, own.or(session), read.get())?;
        let settings = self.runtimes.settings_in(&key, read.get())?;
        Ok((key, settings))
    }

    pub(super) fn choose_runtimes<'a>(
        &mut self,
        requests: impl Iterator<Item = (PaneId, &'a CreatePane)>,
        origin: &Origin,
        read: &Read,
    ) -> Result<ChosenRuntimes, Error> {
        let mut chosen = BTreeMap::new();
        let mut keys = BTreeMap::new();
        for (id, name) in
            requests.filter_map(|(id, request)| request.runtime.as_ref().map(|name| (id, name)))
        {
            let session = self.session_of(id);
            let key = self.runtimes.resolve(name, session, read.get())?;
            if let Origin::Runtime(own) = origin
                && (*own != key
                    || matches!(own.source, RuntimeSource::Session { id } if Some(id) != session))
            {
                return Err(Error::new(
                    ErrorKind::Refused,
                    format!(
                        "a connection of runtime {} cannot create a pane in another runtime or session",
                        own.name
                    ),
                ));
            }
            keys.insert(id, key.clone());
            if !chosen.contains_key(&key) {
                chosen.insert(key.clone(), self.runtimes.settings_in(&key, read.get())?);
            }
        }
        Ok(ChosenRuntimes {
            settings: chosen,
            keys,
        })
    }

    pub(super) fn birth(
        &self,
        id: PaneId,
        shell: &Path,
        request: &CreatePane,
        vars: Vars,
        (chosen, dir, key): (&BTreeMap<RuntimeKey, Runtime>, &Dir, Option<&RuntimeKey>),
    ) -> Result<Birth, AddError> {
        let program = match key {
            None => program(&self.config, shell, request, Start::Host(dir.host()))?,
            Some(key) => {
                let runtime = chosen
                    .get(key)
                    .ok_or(AddError::Invalid("no such runtime"))?;
                let entering = Entering {
                    exe: &self.config.exe,
                    root: self.runtimes.root(),
                    key,
                    runtime,
                    pane: id,
                    cwd: dir,
                    env: &request.env,
                    server_env: &self.config.env,
                };
                program(
                    &self.config,
                    shell,
                    request,
                    Start::Runtime(&|inner| pane::wrapper(&entering, inner)),
                )?
            }
        };
        Ok(Birth {
            vars,
            parent: request.parent,
            close: request.close,
            runtime: key.cloned(),
            program,
        })
    }

    pub(super) fn shown_to(
        &self,
        runtime: &RuntimeKey,
        caller: PaneId,
        id: PaneId,
    ) -> Result<(), Error> {
        if self.panes.is_in(id, runtime) || self.visible_to(runtime, caller).contains(&id) {
            Ok(())
        } else {
            Err(State::hidden(caller, id, runtime))
        }
    }

    fn occupied(&self, key: &RuntimeKey) -> bool {
        self.panes.any_in(key) || self.conns.iter().any(|conn| conn.runs_exec(key))
    }

    pub(super) fn touch_runtime(&mut self, poll: &mut Poll, key: &RuntimeKey) {
        let occupied = self.occupied(key);
        self.runtimes.occupy(poll, key, occupied);
    }

    pub(super) fn client_runtimes(&mut self, read: &Read) -> Vec<ClientRuntime> {
        let listed = self.runtimes.listed(read.get());
        self.announce_runtimes();
        listed
    }

    pub(super) fn announce_runtimes(&mut self) {
        for event in self.runtimes.take_changes() {
            self.broadcast(&event);
        }
    }

    pub(crate) fn runtimes_changed(&mut self, poll: &mut Poll) {
        for key in self.runtimes.take_departed() {
            self.end_runtime_visits(poll, &key, "runtime link ended");
        }
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
        for (key, wait, state) in self.runtimes.take_settled() {
            self.answer_wait(poll, &key, wait, state);
        }
        for (wait, state) in self.runtimes.take_passed() {
            self.answer_passed(poll, wait, state);
        }
        self.announce_runtimes();
    }

    fn pass_token(&mut self, poll: &mut Poll, key: &RuntimeKey, wait: Wait) {
        let pane = match wait.who {
            Who::Pane(pane) | Who::Visit(pane) => pane,
            Who::Exec => return,
        };
        let started = self
            .panes
            .find(pane)
            .and_then(Pane::runtime_token)
            .ok_or_else(|| format!("{pane} has left runtime {key}"))
            .and_then(|token| self.runtimes.pass(poll, key, wait, token.to_string()));
        if let Err(message) = started {
            self.answer_passed(poll, wait, LinkState::Failed { message });
        }
    }

    fn answer_passed(&mut self, poll: &mut Poll, wait: Wait, state: LinkState) {
        match wait.who {
            Who::Pane(_) => router::answer::<routes::WaitRuntime>(
                self,
                poll,
                wait.conn,
                Ok(RuntimeWait { state }),
            ),
            Who::Visit(_) => self.visit_passed(poll, wait.conn, state),
            Who::Exec => {}
        }
    }

    pub(super) fn answer_wait(
        &mut self,
        poll: &mut Poll,
        key: &RuntimeKey,
        wait: Wait,
        state: LinkState,
    ) {
        match wait.who {
            Who::Pane(pane) | Who::Visit(pane)
                if state == LinkState::Up && self.runtimes.remote_tokens(key, pane) =>
            {
                self.pass_token(poll, key, wait)
            }
            Who::Pane(pane) => {
                let reply = self.runtime_reply(key, pane, state);
                router::answer::<routes::WaitRuntime>(self, poll, wait.conn, reply);
            }
            Who::Visit(_) => self.visit_passed(poll, wait.conn, state),
            Who::Exec => self.exec_linked(poll, wait.conn, key, state),
        }
    }

    pub(crate) fn start_runtime(&mut self, poll: &mut Poll, key: &RuntimeKey) -> Result<(), Error> {
        if matches!(
            self.runtimes.state(key),
            LinkState::Down | LinkState::Failed { .. }
        ) {
            let settings = self.runtimes.settings(key)?;
            self.runtimes.begin(poll, key, settings);
        }
        self.touch_runtime(poll, key);
        Ok(())
    }

    pub(super) fn write_runtime_token(&self, key: &RuntimeKey, pane: PaneId) -> Result<(), Error> {
        let token = self
            .panes
            .find(pane)
            .and_then(Pane::runtime_token)
            .ok_or_else(|| Error::new(ErrorKind::Refused, "runtime membership has ended"))?;
        self.runtimes
            .write_token(key, pane, token)
            .map_err(|error| Error::new(ErrorKind::Io, format!("token file: {error}")))
    }

    fn runtime_reply(
        &self,
        key: &RuntimeKey,
        pane: PaneId,
        state: LinkState,
    ) -> Result<RuntimeWait, Error> {
        if state == LinkState::Up {
            self.write_runtime_token(key, pane)?;
        }
        Ok(RuntimeWait { state })
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
                let reply = Ok(RuntimeWait { state });
                router::answer::<routes::WaitRuntime>(self, poll, token, reply);
                true
            }
        }
    }

    pub(crate) fn runtime_info(&self, key: &RuntimeKey, runtime: &Runtime) -> RuntimeInfo {
        RuntimeInfo {
            runtime: ClientRuntime {
                name: key.name.clone(),
                source: key.source,
                kind: crate::runtime::kind(runtime),
                color: runtime.color.clone(),
                state: self.runtimes.state(key),
            },
            panes: u32::try_from(self.panes.in_runtime(key).count()).unwrap_or(u32::MAX),
            socket: socket_path(self.runtimes.root(), key)
                .to_string_lossy()
                .into_owned(),
            paths: runtime.paths(),
            cwd: runtime.cwd.clone(),
            pi: runtime.pi,
        }
    }

    pub(crate) fn list_runtimes(
        &mut self,
        caller: Option<PaneId>,
    ) -> Result<Vec<RuntimeInfo>, Error> {
        let session = caller.and_then(|pane| self.session_of(pane));
        Ok(self
            .runtimes
            .known()?
            .iter()
            .filter(|(key, _)| match key.source {
                RuntimeSource::Config => true,
                RuntimeSource::Session { id } => caller.is_none() || session == Some(id),
            })
            .map(|(key, runtime)| self.runtime_info(key, runtime))
            .collect())
    }

    pub(crate) fn wait_runtime(
        &mut self,
        poll: &mut Poll,
        index: usize,
        caller: Option<PaneId>,
        name: RuntimeName,
        timeout: WaitMs,
    ) -> Option<Result<RuntimeWait, Error>> {
        let name = match self.runtime_key(caller, None, &name) {
            Ok((key, _)) => key,
            Err(error) => return Some(Err(error)),
        };
        let Some(pane) = caller.filter(|caller| self.panes.is_in(*caller, &name)) else {
            return Some(Err(Error::new(
                ErrorKind::Refused,
                format!("only a pane of runtime {name} may use this route"),
            )));
        };
        let state = self.runtimes.state(&name);
        if state == LinkState::Up && self.runtimes.remote_tokens(&name, pane) {
            let conn = self.hold(poll, index, PASS_HOLD);
            self.pass_token(
                poll,
                &name,
                Wait {
                    conn,
                    who: Who::Pane(pane),
                },
            );
            return None;
        }
        if state != LinkState::Starting {
            return Some(self.runtime_reply(&name, pane, state));
        }
        if timeout == WaitMs::NONE {
            return Some(Ok(RuntimeWait { state }));
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

    pub(crate) fn down_runtime(
        &mut self,
        poll: &mut Poll,
        key: &RuntimeKey,
        force: bool,
    ) -> Result<(), Error> {
        let live = self
            .panes
            .in_runtime(key)
            .any(|pane| pane.proc().dead().is_none());
        let sessions = self.conns.iter().any(|conn| conn.runs_exec(key));
        if (live || sessions) && !force {
            return Err(Error::new(
                ErrorKind::Refused,
                format!(
                    "runtime {key} has live panes or exec sessions; stop them or force the request"
                ),
            ));
        }
        self.force_down_runtime(poll, key);
        Ok(())
    }

    fn force_down_runtime(&mut self, poll: &mut Poll, key: &RuntimeKey) {
        self.end_runtime_visits(poll, key, "runtime taken down");
        let live: Vec<_> = self
            .panes
            .in_runtime(key)
            .filter(|pane| pane.proc().dead().is_none())
            .map(Pane::id)
            .collect();
        for id in live {
            self.kill_pane(poll, id);
        }
        self.exec_down(poll, key);
        let waiters = self.runtimes.waiters_of(key);
        self.runtimes.down(poll, key, false);
        for wait in waiters {
            self.answer_wait(poll, key, wait, LinkState::Down);
        }
        let own = Origin::Runtime(key.clone());
        for conn in self.conns.iter_mut().filter(|conn| conn.origin == own) {
            conn.out.close();
        }
        self.runtimes_changed(poll);
    }

    pub(crate) fn delete_runtime(
        &mut self,
        poll: &mut Poll,
        key: &RuntimeKey,
        settings: &Runtime,
    ) -> Result<Empty, Error> {
        self.down_runtime(poll, key, false)?;
        self.runtimes.delete(key, settings);
        self.runtimes.remove_directory(key);
        self.announce_runtimes();
        Ok(Empty {})
    }

    pub(crate) fn put_runtime(
        &mut self,
        caller: Option<PaneId>,
        name: RuntimeName,
        runtime: Runtime,
    ) -> Result<RuntimeInfo, Error> {
        let id = caller
            .and_then(|pane| self.session_of(pane))
            .ok_or_else(|| {
                Error::new(
                    ErrorKind::Refused,
                    "define an ad-hoc runtime from a pane of its session",
                )
            })?;
        let read = Read::new(&self.config.file);
        let key = self
            .runtimes
            .define(name, id, runtime.clone(), read.get())?;
        self.announce_runtimes();
        Ok(self.runtime_info(&key, &runtime))
    }

    fn hidden(caller: PaneId, target: PaneId, runtime: &RuntimeKey) -> Error {
        Error::new(
            ErrorKind::Refused,
            format!("{target} is not visible to {caller} on runtime {runtime}"),
        )
    }

    pub(crate) fn visible_to(&self, runtime: &RuntimeKey, caller: PaneId) -> BTreeSet<PaneId> {
        let mut seen = scope(&self.edges(), caller);
        seen.extend(self.panes.in_runtime(runtime).map(Pane::id));
        seen
    }

    pub(crate) fn runtime_gate(
        &self,
        runtime: &RuntimeKey,
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
        let shown = |id: PaneId| self.shown_to(runtime, caller, id);
        let reached = |id: PaneId| {
            allow(
                self.panes.is_in(id, runtime) || is_descendant(&self.edges(), caller, id),
                id,
            )
        };
        match route {
            Route::Version {}
            | Route::GetLayout {}
            | Route::ListPanes {}
            | Route::NewPane {}
            | Route::StopPane { .. }
            | Route::PatchPane { .. }
            | Route::SetVar { .. }
            | Route::DeleteVar { .. }
            | Route::DeleteVars { .. }
            | Route::Messages { .. }
            | Route::PostMessage { .. }
            | Route::PromptResolve { .. }
            | Route::SendPrompt { .. } => Ok(()),
            Route::GetPane { id } => shown(*id),
            Route::ClearHistory { id } | Route::Input { id } | Route::Screen { id, .. } => {
                reached(*id)
            }
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
        let on_dev = Origin::Runtime(RuntimeKey::config(dev.clone()));
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
