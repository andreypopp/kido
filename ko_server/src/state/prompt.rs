use ko_pane_wire::frame::{Key, KeyAction, KeyCode};

use super::*;
use crate::api::routes;
use crate::ids::WindowId;
use crate::pane_kind::{self, Kind, RemoteKind};
use crate::panes::{acts_as, is_descendant};
use crate::protocol::{
    Candidate, Content, Error, ErrorKind, Payload, SendPrompt, Sent, Via, Window,
};
use crate::server::Origin;

use super::messages::{Posting, Reply};

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
    fn reachable(
        &self,
        caller: Option<PaneId>,
        from: PaneId,
    ) -> Result<(Vec<Candidate>, WindowId), Error> {
        acts_as(caller, from, "prompt only from itself")?;
        let layout = self.document.layout();
        let (session, own) = layout
            .locate(from)
            .ok_or_else(|| Error::new(ErrorKind::Invalid, format!("pane {from} not found")))?;
        let run_window = |window: &Window| {
            window.panes().iter().any(|pane| {
                self.panes
                    .find(*pane)
                    .is_some_and(|pane| pane.run().is_some())
            })
        };
        let ordered = std::iter::once(own).chain(session.windows.iter().filter(|w| w.id != own.id));
        let mut found = Vec::new();
        for window in ordered.filter(|window| !run_window(window)) {
            let mut ids = window.panes();
            ids.sort();
            for id in ids {
                let Some(pane) = self.panes.find(id) else {
                    continue;
                };
                let kind = pane_kind::of_pane(pane.telemetry(), pane.vars());
                let title = lossy(pane.proc().title());
                if matches!(
                    kind,
                    Kind::Terminal
                        | Kind::Ssh {
                            pane: RemoteKind::Terminal,
                            ..
                        }
                ) {
                    continue;
                }
                found.push(Candidate {
                    pane: id,
                    session: session.id,
                    window: window.id,
                    title: pane_kind::title(&kind, &title).unwrap_or_default(),
                    inbox: pane.inbox().stream().is_some(),
                });
            }
        }
        Ok((found, own.id))
    }

    pub(crate) fn resolve_prompt(
        &self,
        caller: Option<PaneId>,
        from: PaneId,
        window_only: bool,
    ) -> Result<Vec<Candidate>, Error> {
        let (candidates, own) = self.reachable(caller, from)?;
        let in_window: Vec<Candidate> = candidates
            .iter()
            .filter(|candidate| candidate.window == own)
            .cloned()
            .collect();
        Ok(if window_only || !in_window.is_empty() {
            in_window
        } else {
            candidates
        })
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
        let reachable = match self.reachable(caller, request.from) {
            Ok((reachable, _)) => reachable,
            Err(failure) => return Some(Err(failure)),
        };
        let Some(target) = reachable
            .into_iter()
            .find(|candidate| candidate.pane == request.target)
        else {
            return Some(Err(Error::new(
                ErrorKind::Invalid,
                format!(
                    "pane {} is not a candidate of pane {}",
                    request.target, request.from
                ),
            )));
        };
        let known = self
            .pane(request.target)
            .is_ok_and(|pane| pane.inbox().seen(&request.id).is_some());
        if target.inbox || known {
            let posting = Posting {
                caller,
                target: request.target,
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
        if let Err(refused) = self.may_paste(caller, origin, request.target) {
            return Some(Err(refused));
        }
        self.paste_prompt(poll, index, request.target, &request.text)
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
                self.conns[index].phase = Phase::Handling;
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
