use std::path::PathBuf;

use super::*;
use crate::ids::PaneToken;

use crate::protocol::{Error, ErrorKind, LinkState, VisitClient, VisitRequest, VisitServer};
use crate::runtime::pane::{self, Dir, Wrap};
use crate::runtime::{RuntimeKey, Wait, Who};

#[derive(Debug)]
pub(crate) enum Stage {
    Open,
    Waiting(VisitRequest),
    Running,
    Ended,
}

#[derive(Debug)]
pub(crate) struct Visit {
    pub(crate) pane: PaneId,
    pub(crate) key: RuntimeKey,
    pub(crate) stage: Stage,
}

impl State {
    pub(crate) fn prepare_visit(
        &mut self,
        caller: Option<PaneId>,
        name: &RuntimeName,
    ) -> Result<Visit, Error> {
        let pane = caller.ok_or_else(|| Error::new(ErrorKind::Refused, "needs a pane"))?;
        self.visit_host(pane)?;
        let (key, _) = self.runtime_key(caller, None, name)?;
        Ok(Visit {
            pane,
            key,
            stage: Stage::Open,
        })
    }

    fn visit_host(&self, id: PaneId) -> Result<(), Error> {
        let pane = self
            .panes
            .find(id)
            .ok_or_else(|| Error::new(ErrorKind::Refused, "pane is gone"))?;
        if let Some(key) = pane.runtime() {
            return Err(Error::new(
                ErrorKind::Refused,
                format!("{id} is already in runtime {}", key.name),
            ));
        }
        if pane.proc().dead().is_some() {
            return Err(Error::new(ErrorKind::Refused, "pane is dead"));
        }
        Ok(())
    }

    fn visit_send(&mut self, conn: Token, message: &VisitServer) {
        if let Some((Role::Visit(_), wire)) = find(&mut self.conns, conn).and_then(Conn::role_mut) {
            wire.ws.send(wire.out, protocol::json(message));
        }
    }

    pub(super) fn visit_text(&mut self, poll: &mut Poll, index: usize, text: &[u8]) {
        let Some((Role::Visit(visit), _)) = self.conns[index].role_mut() else {
            return;
        };
        let (id, key, conn) = (visit.pane, visit.key.clone(), self.conns[index].token);
        let message = match protocol::decode::<VisitClient>(text) {
            Ok(message) => message,
            Err(_) => return self.visit_failed(poll, conn, id, "invalid message".to_owned()),
        };
        match message {
            VisitClient::Visit(request) => {
                if !matches!(
                    self.conns[index].role(),
                    Some(Role::Visit(Visit {
                        stage: Stage::Open,
                        ..
                    }))
                ) {
                    return self.visit_failed(poll, conn, id, "visit was already sent".to_owned());
                }
                if let Err(error) = self.visit_host(id) {
                    return self.visit_failed(poll, conn, id, error.message);
                }
                if let Some(message) = request.invalid() {
                    return self.visit_failed(poll, conn, id, message.to_owned());
                }
                let key = match self.runtime_key(Some(id), None, &key.name) {
                    Ok((key, _)) => key,
                    Err(error) => return self.visit_failed(poll, conn, id, error.message),
                };
                let token = match PaneToken::mint() {
                    Ok(token) => token,
                    Err(error) => return self.visit_failed(poll, conn, id, error.to_string()),
                };
                if !self
                    .panes
                    .find_mut(id)
                    .is_some_and(|pane| pane.begin_visit(key.clone(), token, conn))
                {
                    return self.visit_failed(poll, conn, id, "pane is not on the host".to_owned());
                }
                if let Some((Role::Visit(visit), _)) = self.conns[index].role_mut() {
                    visit.key = key.clone();
                    visit.stage = Stage::Waiting(request);
                }
                self.visit_row(poll, id, Some(key.name.clone()));
                if let Err(error) = self.start_runtime(poll, &key) {
                    return self.visit_failed(poll, conn, id, error.message);
                }

                let state = self.runtimes.state(&key);
                if state == LinkState::Starting {
                    self.visit_send(conn, &VisitServer::Starting {});
                }
                self.answer_wait(
                    poll,
                    &key,
                    Wait {
                        conn,
                        who: Who::Visit(id),
                    },
                    state,
                );
            }
            VisitClient::Lead(report) => {
                if !matches!(
                    self.conns[index].role(),
                    Some(Role::Visit(Visit {
                        stage: Stage::Waiting(_),
                        ..
                    }))
                ) {
                    return self.visit_failed(
                        poll,
                        conn,
                        id,
                        "the first message must be visit".to_owned(),
                    );
                }
                if let Err(error) = self.runtimes.report_lead(poll, &key, id, report) {
                    self.visit_failed(poll, conn, id, error.message);
                }
            }
        }
    }

    pub(super) fn visit_passed(&mut self, poll: &mut Poll, conn: Token, state: LinkState) {
        let Some(found) = find(&mut self.conns, conn) else {
            return;
        };
        let Some((Role::Visit(visit), _)) = found.role_mut() else {
            return;
        };
        if !matches!(visit.stage, Stage::Waiting(_)) {
            return;
        }
        let (id, key) = (visit.pane, visit.key.clone());
        match state {
            LinkState::Up => {
                let Stage::Waiting(request) = std::mem::replace(&mut visit.stage, Stage::Running)
                else {
                    return;
                };
                match self.visit_argv(&key, id, &request) {
                    Ok(argv) => self.visit_send(conn, &VisitServer::Up { argv }),
                    Err(message) => self.visit_failed(poll, conn, id, message),
                }
            }
            LinkState::Failed { message } => self.visit_failed(poll, conn, id, message),
            LinkState::Down => self.visit_failed(poll, conn, id, "runtime is down".to_owned()),
            LinkState::Starting => {
                if let Some(argv) = self.runtimes.elect(&key, id) {
                    self.visit_send(conn, &VisitServer::Lead { argv });
                }
                self.runtimes.wait(
                    &key,
                    Wait {
                        conn,
                        who: Who::Visit(id),
                    },
                );
            }
        }
    }

    fn visit_argv(
        &mut self,
        key: &RuntimeKey,
        id: PaneId,
        request: &VisitRequest,
    ) -> Result<Vec<String>, String> {
        let settings = self.runtimes.settings(key).map_err(|error| error.message)?;
        self.write_runtime_token(key, id)
            .map_err(|error| error.message)?;
        let cwd = Dir::Host(PathBuf::from(request.cwd.as_str()));
        let wrap = Wrap {
            exe: &self.config.exe,
            root: self.runtimes.root(),
            key,
            runtime: &settings,
            pane: id,
            cwd: &cwd,
            env: &request.env,
            server_env: &self.config.env,
        };
        let command = request.command.as_ref().map(|argv| {
            argv.iter()
                .map(|word| word.as_bytes().to_vec())
                .collect::<Vec<_>>()
        });
        pane::transport(&wrap, command.as_deref())
            .into_iter()
            .map(|word| {
                String::from_utf8(word).map_err(|_| "runtime command is not UTF-8".to_owned())
            })
            .collect()
    }

    fn visit_failed(&mut self, poll: &mut Poll, conn: Token, id: PaneId, message: String) {
        self.visit_send(conn, &VisitServer::Failed { message });
        self.finish_visit(conn);
        if self.panes.find(id).and_then(Pane::visit_conn) == Some(conn) {
            self.end_visit(poll, id, None);
        }
    }

    fn finish_visit(&mut self, conn: Token) {
        if let Some((Role::Visit(visit), wire)) =
            find(&mut self.conns, conn).and_then(Conn::role_mut)
        {
            visit.stage = Stage::Ended;
            wire.ws.finish(wire.out);
        }
    }

    fn visit_row(&mut self, poll: &mut Poll, id: PaneId, runtime: Option<RuntimeName>) {
        self.mark(poll, id);
        self.broadcast(&ClientEvent::PaneRuntime { pane: id, runtime });
    }

    pub(super) fn end_runtime_visits(&mut self, poll: &mut Poll, key: &RuntimeKey, message: &str) {
        let visits: Vec<_> = self
            .panes
            .in_runtime(key)
            .filter(|pane| pane.visit_conn().is_some())
            .map(Pane::id)
            .collect();
        for pane in visits {
            self.end_visit(poll, pane, Some(message.to_owned()));
        }
    }

    pub(super) fn end_visit(&mut self, poll: &mut Poll, id: PaneId, message: Option<String>) {
        let Some((key, conn)) = self.panes.find_mut(id).and_then(Pane::end_visit) else {
            return;
        };
        if let Some(message) = message {
            self.visit_send(conn, &VisitServer::Ended { message });
        }
        self.finish_visit(conn);
        self.runtimes.forget_wait(poll, conn);
        self.runtimes.remove_token(&key, id);
        self.visit_row(poll, id, None);
        for connection in &mut self.conns {
            if matches!(&connection.origin, Origin::Runtime(own) if own == &key)
                && connection.caller == Some(id)
            {
                connection.out.close();
            }
        }
        self.touch_runtime(poll, &key);
        self.runtimes.pane_ended(poll, id);
    }
}
