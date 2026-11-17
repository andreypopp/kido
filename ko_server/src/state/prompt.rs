use ko_pane_wire::frame::{Key, KeyAction, KeyCode};

use super::*;
use crate::pane::Pane;
use crate::pane_kind::{self, Kind};
use crate::panes::{acts_as, is_descendant};
use crate::server::Origin;
use ko_wire::api::routes;
use ko_wire::protocol::{Candidate, Content, Error, ErrorKind, Payload, SendPrompt, Sent, Via};

use super::messages::{Posting, Reply};

fn not_found(pane: PaneId) -> Error {
    Error::new(ErrorKind::Invalid, format!("pane {pane} not found"))
}

const ENTER: u16 = 58;

fn enter() -> Option<Key> {
    Some(Key {
        action: KeyAction::Press,
        key: KeyCode::new(ENTER)?,
        mods: 0,
        unshifted: '\0',
        text: String::new(),
        composing: false,
    })
}

impl State {
    fn live_agent(&self, id: PaneId) -> Option<(&Pane, Kind)> {
        let pane = self.panes.find(id)?;
        let kind = pane_kind::of_pane(pane);
        (pane.proc().dead().is_none() && kind.is_agent()).then_some((pane, kind))
    }

    pub(crate) fn resolve_prompt(
        &self,
        caller: Option<PaneId>,
        from: PaneId,
    ) -> Result<Vec<Candidate>, Error> {
        acts_as(caller, from, "prompt only from itself")?;
        let layout = self.document.layout();
        let (session, own) = layout.locate(from).ok_or_else(|| not_found(from))?;
        let ordered = std::iter::once(own).chain(session.windows.iter().filter(|w| w.id != own.id));
        let mut found = Vec::new();
        for window in ordered {
            let mut ids = window.panes();
            ids.sort();
            for id in ids {
                if let Some((pane, kind)) = self.live_agent(id) {
                    found.push(Candidate {
                        pane: id,
                        session: session.id,
                        window: window.id,
                        title: pane_kind::title(&kind, &lossy(pane.proc().title()))
                            .unwrap_or_default(),
                    });
                }
            }
        }
        Ok(found)
    }

    fn prompt_target(&self, caller: Option<PaneId>, request: &SendPrompt) -> Result<PaneId, Error> {
        let from = request.from;
        acts_as(caller, from, "prompt only from itself")?;
        let layout = self.document.layout();
        let (session, window) = layout.locate(from).ok_or_else(|| not_found(from))?;
        if let Some(target) = request.target {
            let reachable = session.windows.iter().any(|window| window.has(target));
            return if target != from && reachable && self.live_agent(target).is_some() {
                Ok(target)
            } else {
                Err(Error::new(
                    ErrorKind::Invalid,
                    format!("pane {target} is no live agent of the session of pane {from}"),
                ))
            };
        }
        let mut agents = window
            .panes()
            .into_iter()
            .filter(|&id| id != from && self.live_agent(id).is_some());
        match (agents.next(), agents.next()) {
            (Some(one), None) => Ok(one),
            (None, _) => Err(Error::new(ErrorKind::NoAgent, "agent not found")),
            _ => Err(Error::new(
                ErrorKind::MultipleAgents,
                "multiple agents found",
            )),
        }
    }

    pub(crate) fn send_prompt(
        &mut self,
        poll: &mut Poll,
        index: usize,
        (caller, origin): (Option<PaneId>, &Origin),
        request: SendPrompt,
    ) -> Option<Result<Sent, Error>> {
        if request.text.is_empty() {
            return Some(Err(Error::new(ErrorKind::Invalid, "no prompt given")));
        }
        let target = match self.prompt_target(caller, &request) {
            Ok(target) => target,
            Err(failure) => return Some(Err(failure)),
        };
        let inbox = self.panes.find(target).is_some_and(|pane| {
            pane.inbox().stream().is_some() || pane.inbox().seen(&request.id).is_some()
        });
        if inbox {
            let posting = Posting {
                caller,
                target,
                id: request.id,
                content: Content::User(Payload {
                    text: request.text,
                    data: None,
                }),
                reply: Reply::Prompt,
            };
            return self
                .submit(poll, index, posting, &self.edges())
                .map(|result| result.map(Sent::from));
        }
        if let Err(refused) = self.may_paste(caller, origin, target) {
            return Some(Err(refused));
        }
        self.paste_prompt(poll, index, target, &request.text)
    }

    // A paste is input to the target's terminal, so a runtime connection may paste only where it
    // may send input: into its own runtime or into a descendant of the caller.
    fn may_paste(
        &self,
        caller: Option<PaneId>,
        origin: &Origin,
        target: PaneId,
    ) -> Result<(), Error> {
        let Origin::Runtime(runtime) = origin else {
            return Ok(());
        };
        let allowed = self.panes.is_in(target, runtime)
            || caller.is_some_and(|caller| is_descendant(&self.edges(), caller, target));
        if allowed {
            Ok(())
        } else {
            Err(Error::new(
                ErrorKind::Refused,
                format!(
                    "{target} would get a paste, which a connection of runtime {runtime} may not send there"
                ),
            ))
        }
    }

    fn paste_prompt(
        &mut self,
        poll: &mut Poll,
        index: usize,
        pane: PaneId,
        text: &str,
    ) -> Option<Result<Sent, Error>> {
        let token = self.conns[index].token;
        let sent = self.call(poll, pane, |pane, io| {
            pane.proc_mut().input(
                pane_proc::Input::Paste {
                    text,
                    check_safe: false,
                },
                io,
            )
        });
        let (sent, events) = sent.unwrap_or((Err(Refusal::Ended), Vec::new()));
        let reply = match sent {
            Ok(Some(req)) => {
                self.owners.insert((pane, req), Owner::Prompt(token));
                self.conns[index].phase = Phase::Handling(crate::conn::Handling::Wait);
                None
            }
            Ok(None) => Some(Err(Error::new(ErrorKind::Io, "the paste has no answer"))),
            Err(refusal) => Some(Err(Error::new(ErrorKind::Io, refusal.to_string()))),
        };
        self.dispatch(poll, pane, events);
        reply
    }

    pub(super) fn prompt_pasted(
        &mut self,
        poll: &mut Poll,
        pane: PaneId,
        conn: Token,
        pasted: bool,
    ) {
        let reply = if !pasted {
            Err(Error::new(ErrorKind::Io, "the paste was not written"))
        } else if self.live_agent(pane).is_none() {
            Err(Error::new(
                ErrorKind::Refused,
                format!("{pane} is no live agent any more"),
            ))
        } else if let Some(key) = enter() {
            match self.run(poll, pane, |pane, io| {
                pane.proc_mut().input(pane_proc::Input::Key(&key), io)
            }) {
                Some(Ok(_)) => Ok(Sent { via: Via::Paste }),
                Some(Err(refusal)) => Err(Error::new(ErrorKind::Io, refusal.to_string())),
                None => Err(Error::new(ErrorKind::Io, Refusal::Ended.to_string())),
            }
        } else {
            Err(Error::new(ErrorKind::Io, "no Enter key"))
        };
        router::answer::<routes::SendPrompt>(self, poll, conn, reply);
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn the_enter_key_is_the_terminal_libraries_enter() {
        assert_eq!(super::ENTER, ko_vt::input::key::ENTER);
    }
}
