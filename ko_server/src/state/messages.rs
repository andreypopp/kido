use super::*;
use crate::api::routes;
use crate::ids::MessageId;
use crate::inbox::{Admit, Outcome, Status};
use crate::pane_kind::{self, Kind, LocalKind};
use crate::panes::{Edge, acts_as, relation};
use crate::protocol::{
    Content, End, Error, ErrorKind, MessageState, Payload, Posted, Relation, SendMessage, Sender,
    Sent, StreamRequest,
};

#[derive(Debug, Clone, Copy)]
pub(super) enum Reply {
    Post,
    Prompt,
}

#[derive(Debug)]
struct Wait {
    conn: Token,
    pane: PaneId,
    id: MessageId,
    seq: u64,
    duplicate: bool,
    reply: Reply,
}

#[derive(Debug)]
pub(super) struct Posting {
    pub(super) caller: Option<PaneId>,
    pub(super) target: PaneId,
    pub(super) id: MessageId,
    pub(super) content: Content,
    pub(super) reply: Reply,
}

#[derive(Debug, Default)]
pub(super) struct Waits(Vec<Wait>);

impl Waits {
    pub(super) fn forget(&mut self, conn: Token) {
        self.0.retain(|wait| wait.conn != conn);
    }
}

fn stamp(id: PaneId, pane: Option<&Pane>) -> Sender {
    match pane.map(pane_kind::of_pane).as_ref().and_then(Kind::local) {
        Some(LocalKind::PiAgent { session, name, .. }) => Sender::Pane {
            pane: id,
            session: Some(session.clone()),
            name: Some(name.clone()).filter(|name| !name.is_empty()),
        },
        _ => Sender::Pane {
            pane: id,
            session: None,
            name: None,
        },
    }
}

fn missing() -> Error {
    Error::new(ErrorKind::Missing, "pane not found")
}

fn dead(pane: PaneId) -> Error {
    Error::new(ErrorKind::Gone, format!("{pane} is dead"))
}

impl State {
    pub(super) fn pane(&self, id: PaneId) -> Result<&Pane, Error> {
        self.panes.find(id).ok_or_else(missing)
    }

    fn live(&self, id: PaneId) -> Result<&Pane, Error> {
        let pane = self.pane(id)?;
        if pane.proc().dead().is_some() {
            Err(dead(id))
        } else {
            Ok(pane)
        }
    }

    pub(crate) fn admit_stream(&self, caller: Option<PaneId>, id: PaneId) -> Result<(), Error> {
        acts_as(caller, id, "open only its own message stream")?;
        if self.live(id)?.inbox().stream().is_some() {
            Err(Error::new(
                ErrorKind::Refused,
                "the pane already has a message stream",
            ))
        } else {
            Ok(())
        }
    }

    pub(crate) fn open_stream(&mut self, id: PaneId, stream: Token) {
        if self
            .panes
            .find_mut(id)
            .is_some_and(|pane| pane.inbox_mut().open(stream))
        {
            self.broadcast(&ClientEvent::Inbox {
                pane: id,
                inbox: true,
            });
            self.flush_messages(id);
        }
    }

    fn flush_messages(&mut self, id: PaneId) {
        let State { panes, conns, .. } = self;
        let Some(pane) = panes.find_mut(id) else {
            return;
        };
        let Some(token) = pane.inbox().stream() else {
            return;
        };
        let Some((_, wire)) = find(conns, token).and_then(Conn::role_mut) else {
            return;
        };
        while let Some(frame) = pane.inbox_mut().next_write() {
            wire.ws.send(wire.out, frame);
        }
    }

    pub(super) fn stream_text(&mut self, poll: &mut Poll, index: usize, pane: PaneId, text: &[u8]) {
        let (id, outcome) = match protocol::decode::<StreamRequest>(text) {
            Ok(StreamRequest::Ack { id }) => (id, Outcome::Acked),
            Ok(StreamRequest::Refuse { id }) => (id, Outcome::Refused),
            Err(_) => {
                if let Some((_, wire)) = self.conns.get_mut(index).and_then(Conn::role_mut) {
                    wire.ws.reject(wire.out, crate::ws::Rejection::Invalid);
                }
                return;
            }
        };
        let settled = self
            .panes
            .find_mut(pane)
            .and_then(|found| found.inbox_mut().settle(&id, outcome));
        if settled.is_some() {
            self.answer_waits(
                poll,
                |wait| wait.pane == pane && wait.id == id,
                || match outcome {
                    Outcome::Acked => Ok(MessageState::Acked),
                    Outcome::Refused => Err(refused_by_receiver()),
                },
            );
            self.flush_messages(pane);
        }
    }

    pub(super) fn stream_closed(&mut self, poll: &mut Poll, pane: PaneId, stream: Token) {
        let closed = self
            .panes
            .find_mut(pane)
            .is_some_and(|found| found.inbox_mut().close(stream));
        if closed {
            self.answer_waits(poll, |wait| wait.pane == pane, || Ok(MessageState::Queued));
            self.broadcast(&ClientEvent::Inbox { pane, inbox: false });
        }
    }

    pub(super) fn pane_ended(&mut self, poll: &mut Poll, id: PaneId) {
        let stream = self
            .panes
            .find_mut(id)
            .and_then(|pane| pane.inbox_mut().clear());
        self.answer_waits(poll, |wait| wait.pane == id, || Err(dead(id)));
        if let Some(token) = stream {
            if let Some((_, wire)) = find(&mut self.conns, token).and_then(Conn::role_mut) {
                wire.ws.finish(wire.out);
                wire.out.close();
            }
            self.broadcast(&ClientEvent::Inbox {
                pane: id,
                inbox: false,
            });
        }
    }

    pub(super) fn tell_parent_gone(&mut self, id: PaneId) {
        if self.live(id).is_ok() {
            self.tell_parent(id, End::Gone);
        }
    }

    pub(super) fn tell_parent(&mut self, id: PaneId, end: End) {
        let Some(child) = self.panes.find(id) else {
            return;
        };
        let from = stamp(id, Some(child));
        let Some(parent) = child.parent() else {
            return;
        };
        let Some(found) = self
            .panes
            .find_mut(parent)
            .filter(|found| found.proc().dead().is_none())
        else {
            return;
        };
        let admitted = found.inbox_mut().admit(
            MessageId::ended(id),
            from,
            Some(Relation::Child),
            Content::Ended { end },
        );
        if matches!(admitted, Admit::New(_)) {
            self.flush_messages(parent);
        }
    }

    pub(crate) fn post_message(
        &mut self,
        poll: &mut Poll,
        index: usize,
        caller: Option<PaneId>,
        target: PaneId,
        body: SendMessage,
    ) -> Option<Result<Posted, Error>> {
        let edges = self.edges();
        if let Err(error) = self.may_reach(&edges, caller, target) {
            return Some(Err(error));
        }
        let SendMessage {
            id,
            kind,
            text,
            data,
        } = body;
        let posting = Posting {
            caller,
            target,
            id,
            content: Content::sent(kind, Payload { text, data }),
            reply: Reply::Post,
        };
        self.submit(poll, index, posting, &edges)
    }

    pub(super) fn submit(
        &mut self,
        poll: &mut Poll,
        index: usize,
        posting: Posting,
        edges: &[Edge],
    ) -> Option<Result<Posted, Error>> {
        let Posting {
            caller,
            target,
            id,
            content,
            reply,
        } = posting;
        if let Err(error) = self.live(target) {
            return Some(Err(error));
        }
        let from = match caller {
            Some(caller) => stamp(caller, self.panes.find(caller)),
            None => Sender::User,
        };
        let relation = caller.and_then(|caller| relation(edges, caller, target));
        let Some(pane) = self.panes.find_mut(target) else {
            return Some(Err(missing()));
        };
        let admitted = pane.inbox_mut().admit(id.clone(), from, relation, content);
        let duplicate = matches!(admitted, Admit::Repeat(_));
        if matches!(admitted, Admit::New(_)) {
            self.flush_messages(target);
        }
        if admitted == Admit::Full {
            return Some(Err(Error::new(
                ErrorKind::Refused,
                "the pane's message queue is full",
            )));
        }
        let Some(seen) = self
            .panes
            .find(target)
            .and_then(|pane| pane.inbox().seen(&id))
        else {
            return Some(Err(Error::new(ErrorKind::Io, "the message is missing")));
        };
        let posted = |state| Posted {
            state,
            seq: seen.seq,
            duplicate,
        };
        match seen.status {
            Status::Queued => Some(Ok(posted(MessageState::Queued))),
            Status::Settled(Outcome::Acked) => Some(Ok(posted(MessageState::Acked))),
            Status::Settled(Outcome::Refused) => Some(Err(refused_by_receiver())),
            Status::Delivered => {
                let conn = self.hold(poll, index, self.config.message_ack);
                self.messages.0.push(Wait {
                    conn,
                    pane: target,
                    id,
                    seq: seen.seq,
                    duplicate,
                    reply,
                });
                None
            }
        }
    }

    pub(super) fn message_due(&mut self, poll: &mut Poll, timer: Timer) -> bool {
        let Some(token) = self.token_of_timer(timer) else {
            return false;
        };
        self.answer_waits(
            poll,
            |wait| wait.conn == token,
            || Ok(MessageState::Delivered),
        )
    }

    fn answer_waits(
        &mut self,
        poll: &mut Poll,
        matching: impl Fn(&Wait) -> bool,
        outcome: impl Fn() -> Result<MessageState, Error>,
    ) -> bool {
        let released: Vec<Wait> = self
            .messages
            .0
            .extract_if(.., |wait| matching(wait))
            .collect();
        let any = !released.is_empty();
        for wait in released {
            let posted = outcome().map(|state| Posted {
                state,
                seq: wait.seq,
                duplicate: wait.duplicate,
            });
            match wait.reply {
                Reply::Post => router::answer::<routes::PostMessage>(self, poll, wait.conn, posted),
                Reply::Prompt => router::answer::<routes::SendPrompt>(
                    self,
                    poll,
                    wait.conn,
                    posted.map(Sent::from),
                ),
            }
        }
        any
    }
}

fn refused_by_receiver() -> Error {
    Error::new(ErrorKind::Refused, "the receiver refused the message")
}
