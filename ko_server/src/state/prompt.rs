use ko_pane_wire::frame::{Key, KeyAction, KeyCode};

use super::*;
use crate::api::routes;
use crate::ids::WindowId;
use crate::msg::{self, Delivery, Step};
use crate::pane_kind::{self, Kind, RUN, RemoteKind};
use crate::protocol::{Candidate, Error, ErrorKind, SendPrompt, Sent, Via, Window};

const INBOX_TIMEOUT: Duration = Duration::from_secs(2);
const ENTER: u16 = 58;

#[derive(Debug)]
struct Sending {
    conn: Option<Token>,
    delivery: Delivery,
    name: String,
}

#[derive(Debug, Default)]
pub(super) struct PromptState {
    sends: Vec<Sending>,
}

impl PromptState {
    pub(super) fn stop(&mut self, poll: &mut Poll) {
        for sending in self.sends.drain(..) {
            sending.delivery.close(poll);
        }
    }

    pub(super) fn forget(&mut self, conn: Token) {
        for sending in &mut self.sends {
            if sending.conn == Some(conn) {
                sending.conn = None;
            }
        }
    }
}

#[derive(Debug)]
struct Reachable {
    candidate: Candidate,
    inbox: Option<String>,
    name: String,
}

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
    fn reachable(&self, caller: Option<PaneId>) -> Result<(Vec<Reachable>, WindowId), Error> {
        let caller = caller.ok_or_else(|| Error::new(ErrorKind::Invalid, "no caller pane"))?;
        let layout = self.document.layout();
        let (session, own) = layout
            .locate(caller)
            .ok_or_else(|| Error::new(ErrorKind::Invalid, format!("pane {caller} not found")))?;
        let run_window = |window: &Window| {
            window.panes().iter().any(|pane| {
                self.panes
                    .find(*pane)
                    .and_then(|pane| pane.vars().text(&RUN))
                    .is_some()
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
                let (inbox, name) = match &kind {
                    Kind::Terminal
                    | Kind::Ssh {
                        pane: RemoteKind::Terminal,
                        ..
                    } => continue,
                    Kind::PiAgent { inbox, name, .. } => (inbox.clone(), name.clone()),
                    Kind::SomeAgent { .. } | Kind::Ssh { .. } => (None, title.clone()),
                };
                found.push(Reachable {
                    candidate: Candidate {
                        pane: id,
                        session: session.id,
                        window: window.id,
                        title: pane_kind::title(&kind, &title).unwrap_or_default(),
                    },
                    inbox,
                    name,
                });
            }
        }
        Ok((found, own.id))
    }

    pub(crate) fn resolve_prompt(
        &self,
        caller: Option<PaneId>,
        window_only: bool,
    ) -> Result<Vec<Candidate>, Error> {
        let (found, own) = self.reachable(caller)?;
        let candidates: Vec<Candidate> = found
            .into_iter()
            .map(|reachable| reachable.candidate)
            .collect();
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
        caller: Option<PaneId>,
        request: SendPrompt,
    ) -> Option<Result<Sent, Error>> {
        if request.text.is_empty() {
            return Some(Err(Error::new(ErrorKind::Invalid, "no prompt given")));
        }
        let reachable = match self.reachable(caller) {
            Ok((reachable, _)) => reachable,
            Err(failure) => return Some(Err(failure)),
        };
        let Some(target) = reachable
            .into_iter()
            .find(|reachable| reachable.candidate.pane == request.target)
        else {
            return Some(Err(Error::new(
                ErrorKind::Invalid,
                format!(
                    "pane {} is not a candidate of pane {}",
                    request.target,
                    caller.map(|pane| pane.to_string()).unwrap_or_default()
                ),
            )));
        };
        let token = self.conns[index].token;
        let Some(inbox) = target.inbox else {
            return self.paste_prompt(poll, index, request.target, &request.text);
        };
        let mut delivery = match Delivery::start(poll, &inbox, &request.text, INBOX_TIMEOUT) {
            Ok(delivery) => delivery,
            Err(failure) => return Some(Err(inbox_error(&target.name, failure))),
        };
        match delivery.step(poll) {
            Step::Done(result) => {
                delivery.close(poll);
                Some(
                    result
                        .map(|()| Sent { via: Via::Inbox })
                        .map_err(|failure| inbox_error(&target.name, failure)),
                )
            }
            Step::Pending => {
                self.conns[index].phase = Phase::Handling;
                self.prompts.sends.push(Sending {
                    conn: Some(token),
                    delivery,
                    name: target.name,
                });
                None
            }
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

    pub(super) fn prompt_ready(&mut self, poll: &mut Poll, ready: Ready) -> bool {
        let Some(at) = self
            .prompts
            .sends
            .iter()
            .position(|send| send.delivery.token() == ready.token)
        else {
            return false;
        };
        if let Step::Done(result) = self.prompts.sends[at].delivery.step(poll) {
            self.finish_send(poll, at, result);
        }
        true
    }

    pub(super) fn prompt_due(&mut self, poll: &mut Poll, timer: Timer) -> bool {
        let Some(at) = self
            .prompts
            .sends
            .iter()
            .position(|send| send.delivery.timer() == timer)
        else {
            return false;
        };
        if let Step::Done(result) = self.prompts.sends[at].delivery.expire() {
            self.finish_send(poll, at, result);
        }
        true
    }

    fn finish_send(&mut self, poll: &mut Poll, at: usize, result: Result<(), msg::Error>) {
        let Sending {
            conn,
            delivery,
            name,
        } = self.prompts.sends.swap_remove(at);
        delivery.close(poll);
        if let Some(conn) = conn {
            let reply = result
                .map(|()| Sent { via: Via::Inbox })
                .map_err(|failure| inbox_error(&name, failure));
            router::answer::<routes::SendPrompt>(self, poll, conn, reply);
        }
    }
}

fn inbox_error(name: &str, failure: msg::Error) -> Error {
    match failure {
        msg::Error::Unavailable => Error::new(
            ErrorKind::Refused,
            format!("{name} is not accepting messages"),
        ),
        msg::Error::Failed(message) => Error::new(ErrorKind::Io, message),
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn the_enter_key_is_the_terminal_libraries_enter() {
        assert_eq!(super::ENTER, ko_vt::input::key::ENTER);
    }
}
