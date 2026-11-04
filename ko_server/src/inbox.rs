use std::collections::{HashMap, VecDeque};

use ko_sys::event::Token;
use tungstenite::Utf8Bytes;

use crate::ids::MessageId;
use crate::protocol::{self, Content, Data, Message, Relation, Sender};

const WINDOW: usize = 16;
const CAP_BYTES: usize = 64 << 20;
const CAP_MESSAGES: usize = 1 << 16;
const SETTLED: usize = 4096;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Place {
    Fresh,
    Out,
    Back,
}

#[derive(Debug)]
struct Entry {
    seq: u64,
    frame: Utf8Bytes,
    size: usize,
    place: Place,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Outcome {
    Acked,
    Refused,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Status {
    Queued,
    Delivered,
    Settled(Outcome),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Seen {
    pub(crate) seq: u64,
    pub(crate) status: Status,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Admit {
    New(u64),
    Repeat(Seen),
    Full,
}

#[derive(Debug, Clone, Copy)]
enum Known {
    Pending(u64),
    Settled(Outcome, u64),
}

#[derive(Debug, Default)]
pub(crate) struct Inbox {
    stream: Option<Token>,
    last: u64,
    fifo: VecDeque<Entry>,
    bytes: usize,
    known: HashMap<MessageId, Known>,
    settled: VecDeque<MessageId>,
}

impl Inbox {
    pub(crate) fn stream(&self) -> Option<Token> {
        self.stream
    }

    pub(crate) fn open(&mut self, stream: Token) -> bool {
        let free = self.stream.is_none();
        if free {
            self.stream = Some(stream);
        }
        free
    }

    pub(crate) fn close(&mut self, stream: Token) -> bool {
        let ours = self.stream == Some(stream);
        if ours {
            self.stream = None;
            for entry in self
                .fifo
                .iter_mut()
                .take_while(|entry| entry.place == Place::Out)
            {
                entry.place = Place::Back;
            }
        }
        ours
    }

    pub(crate) fn clear(&mut self) -> Option<Token> {
        self.fifo.clear();
        self.bytes = 0;
        self.known.clear();
        self.settled.clear();
        self.stream.take()
    }

    fn at(&self, seq: u64) -> Option<usize> {
        self.fifo.binary_search_by_key(&seq, |entry| entry.seq).ok()
    }

    pub(crate) fn seen(&self, id: &MessageId) -> Option<Seen> {
        Some(match self.known.get(id)? {
            Known::Pending(seq) => Seen {
                seq: *seq,
                status: match self.fifo.get(self.at(*seq)?)?.place {
                    Place::Out => Status::Delivered,
                    Place::Fresh | Place::Back => Status::Queued,
                },
            },
            Known::Settled(outcome, seq) => Seen {
                seq: *seq,
                status: Status::Settled(*outcome),
            },
        })
    }

    pub(crate) fn admit(
        &mut self,
        id: MessageId,
        from: Sender,
        relation: Option<Relation>,
        content: Content,
    ) -> Admit {
        if let Some(seen) = self.seen(&id) {
            return Admit::Repeat(seen);
        }
        let size = size(&content);
        if self.fifo.len() >= CAP_MESSAGES || self.bytes.saturating_add(size) > CAP_BYTES {
            return Admit::Full;
        }
        self.last = self.last.saturating_add(1);
        let seq = self.last;
        self.bytes = self.bytes.saturating_add(size);
        self.known.insert(id.clone(), Known::Pending(seq));
        let message = Message {
            seq,
            id,
            from,
            relation,
            content,
        };
        self.fifo.push_back(Entry {
            seq,
            frame: protocol::json(&message).into(),
            size,
            place: Place::Fresh,
        });
        Admit::New(seq)
    }

    pub(crate) fn next_write(&mut self) -> Option<Utf8Bytes> {
        self.stream?;
        let head = self
            .fifo
            .iter()
            .position(|entry| entry.place != Place::Out)?;
        if head >= WINDOW {
            return None;
        }
        let entry = self.fifo.get_mut(head)?;
        entry.place = Place::Out;
        Some(entry.frame.clone())
    }

    pub(crate) fn settle(&mut self, id: &MessageId, outcome: Outcome) -> Option<u64> {
        let Some(Known::Pending(seq)) = self.known.get(id).copied() else {
            return None;
        };
        let at = self.at(seq)?;
        if self.fifo.get(at)?.place == Place::Fresh {
            return None;
        }
        let entry = self.fifo.remove(at)?;
        self.bytes = self.bytes.saturating_sub(entry.size);
        *self.known.get_mut(id)? = Known::Settled(outcome, seq);
        self.settled.push_back(id.clone());
        if self.settled.len() > SETTLED
            && let Some(oldest) = self.settled.pop_front()
        {
            self.known.remove(&oldest);
        }
        Some(seq)
    }
}

fn size(content: &Content) -> usize {
    match content {
        Content::Message(payload)
        | Content::Steer(payload)
        | Content::Interrupt(payload)
        | Content::Stop(payload)
        | Content::Notice(payload)
        | Content::User(payload) => payload
            .text
            .len()
            .saturating_add(payload.data.as_ref().map_or(0, Data::len)),
        Content::Ended { .. } => 0,
    }
}

#[cfg(test)]
mod tests {
    use proptest::prelude::*;

    use super::*;
    use crate::ids::PaneId;
    use crate::protocol::Payload;

    fn id(number: usize) -> MessageId {
        MessageId::try_from(format!("id{number:06}")).unwrap()
    }

    fn admit(inbox: &mut Inbox, number: usize, text: usize) -> Admit {
        let from = Sender::Pane {
            pane: PaneId::new(1),
            session: None,
            name: None,
        };
        let content = Content::Message(Payload {
            text: "x".repeat(text),
            data: None,
        });
        inbox.admit(id(number), from, None, content)
    }

    fn streams<const N: usize>() -> [Token; N] {
        let mut poll = ko_sys::event::Poll::new();
        let sockets: Vec<_> = (0..N)
            .map(|_| std::os::unix::net::UnixStream::pair().unwrap().0)
            .collect();
        let tokens: Vec<Token> = sockets
            .iter()
            .map(|socket| {
                poll.watch(
                    std::os::fd::AsFd::as_fd(socket),
                    ko_sys::event::Interest::Read,
                )
            })
            .collect();
        tokens.try_into().unwrap()
    }

    fn stream() -> Token {
        let [token] = streams();
        token
    }

    fn written(inbox: &mut Inbox) -> Vec<u64> {
        std::iter::from_fn(|| inbox.next_write())
            .map(|frame| {
                let message: serde_json::Value = serde_json::from_str(frame.as_str()).unwrap();
                message["seq"].as_u64().unwrap()
            })
            .collect()
    }

    #[test]
    fn nothing_is_written_without_a_stream_and_at_most_sixteen_wait_for_an_ack() {
        let mut inbox = Inbox::default();
        for number in 1..=20 {
            assert_eq!(admit(&mut inbox, number, 1), Admit::New(number as u64));
        }
        assert_eq!(written(&mut inbox), Vec::<u64>::new());
        assert!(inbox.open(stream()));
        assert_eq!(written(&mut inbox), (1..=16).collect::<Vec<_>>());
        assert_eq!(inbox.settle(&id(3), Outcome::Acked), Some(3));
        assert_eq!(written(&mut inbox), [17]);
        assert_eq!(inbox.settle(&id(1), Outcome::Refused), Some(1));
        assert_eq!(inbox.settle(&id(2), Outcome::Acked), Some(2));
        assert_eq!(written(&mut inbox), [18, 19]);
        assert_eq!(admit(&mut inbox, 21, 1), Admit::New(21));
        assert_eq!(written(&mut inbox), Vec::<u64>::new(), "the window is full");
        assert_eq!(inbox.settle(&id(4), Outcome::Acked), Some(4));
        assert_eq!(inbox.settle(&id(5), Outcome::Acked), Some(5));
        assert_eq!(written(&mut inbox), [20, 21]);
    }

    #[test]
    fn a_closed_stream_puts_the_written_messages_back_in_seq_order() {
        let mut inbox = Inbox::default();
        let [first, second] = streams();
        assert!(inbox.open(first));
        assert!(!inbox.open(second), "a pane has one stream");
        for number in 1..=5 {
            admit(&mut inbox, number, 1);
        }
        assert_eq!(written(&mut inbox), [1, 2, 3, 4, 5]);
        inbox.settle(&id(2), Outcome::Acked);
        admit(&mut inbox, 6, 1);
        assert!(!inbox.close(second), "only the open stream closes");
        assert!(inbox.close(first));
        assert_eq!(
            inbox.seen(&id(1)),
            Some(Seen {
                seq: 1,
                status: Status::Queued
            })
        );
        assert_eq!(written(&mut inbox), Vec::<u64>::new());
        assert!(inbox.open(second));
        assert_eq!(written(&mut inbox), [1, 3, 4, 5, 6]);
    }

    #[test]
    fn only_a_message_that_was_written_settles() {
        let mut inbox = Inbox::default();
        let first = stream();
        admit(&mut inbox, 1, 1);
        assert_eq!(inbox.settle(&id(1), Outcome::Acked), None, "never written");
        assert_eq!(inbox.settle(&id(9), Outcome::Acked), None, "unknown");
        inbox.open(first);
        written(&mut inbox);
        inbox.close(first);
        assert_eq!(
            inbox.settle(&id(1), Outcome::Acked),
            Some(1),
            "queued after a requeue"
        );
        assert_eq!(inbox.settle(&id(1), Outcome::Acked), None, "settled once");
    }

    #[test]
    fn a_repeat_reads_the_state_of_the_original() {
        let mut inbox = Inbox::default();
        let open = stream();
        let repeat = |inbox: &mut Inbox, number| match admit(inbox, number, 1) {
            Admit::Repeat(seen) => (seen.seq, seen.status),
            other => panic!("{other:?}"),
        };
        admit(&mut inbox, 1, 1);
        admit(&mut inbox, 2, 1);
        admit(&mut inbox, 3, 1);
        assert_eq!(repeat(&mut inbox, 1), (1, Status::Queued));
        inbox.open(open);
        inbox.next_write();
        inbox.next_write();
        assert_eq!(repeat(&mut inbox, 1), (1, Status::Delivered));
        assert_eq!(repeat(&mut inbox, 3), (3, Status::Queued));
        inbox.settle(&id(1), Outcome::Acked);
        inbox.settle(&id(2), Outcome::Refused);
        assert_eq!(repeat(&mut inbox, 1), (1, Status::Settled(Outcome::Acked)));
        assert_eq!(
            repeat(&mut inbox, 2),
            (2, Status::Settled(Outcome::Refused))
        );
        assert_eq!(inbox.clear(), Some(open));
        assert_eq!(inbox.seen(&id(1)), None, "the ring goes with the pane");
    }

    #[test]
    fn the_queue_holds_exactly_64_mib_of_text_and_data() {
        let mut inbox = Inbox::default();
        for number in 1..=64 {
            assert_eq!(
                admit(&mut inbox, number, 1 << 20),
                Admit::New(number as u64)
            );
        }
        assert_eq!(admit(&mut inbox, 65, 1), Admit::Full);
        assert_eq!(
            admit(&mut inbox, 66, 0),
            Admit::New(65),
            "no byte is no excess"
        );
        let open = stream();
        inbox.open(open);
        written(&mut inbox);
        assert_eq!(
            admit(&mut inbox, 67, 1),
            Admit::Full,
            "a written message counts until it is acked"
        );
        inbox.settle(&id(1), Outcome::Acked);
        assert_eq!(admit(&mut inbox, 67, (1 << 20) + 1), Admit::Full);
        assert_eq!(admit(&mut inbox, 68, 1 << 20), Admit::New(66));
    }

    #[test]
    fn the_queue_holds_at_most_65536_messages() {
        let mut inbox = Inbox::default();
        for number in 0..CAP_MESSAGES {
            assert!(matches!(admit(&mut inbox, number, 0), Admit::New(_)));
        }
        assert_eq!(admit(&mut inbox, CAP_MESSAGES, 0), Admit::Full);
    }

    #[test]
    fn the_ring_keeps_the_last_4096_settled_ids_and_forgets_the_oldest_first() {
        let mut inbox = Inbox::default();
        inbox.open(stream());
        let total = SETTLED + 3;
        for number in 0..total {
            admit(&mut inbox, number, 0);
            written(&mut inbox);
            assert_eq!(
                inbox.settle(&id(number), Outcome::Acked),
                Some(number as u64 + 1)
            );
        }
        for number in 0..3 {
            assert_eq!(inbox.seen(&id(number)), None, "{number}");
        }
        for number in 3..total {
            assert_eq!(
                inbox.seen(&id(number)).map(|seen| seen.status),
                Some(Status::Settled(Outcome::Acked)),
                "{number}"
            );
        }
        assert_eq!(inbox.settled.len(), SETTLED);
        assert_eq!(inbox.known.len(), SETTLED);
        assert_eq!(admit(&mut inbox, 0, 0), Admit::New(total as u64 + 1));
    }

    #[derive(Debug, Clone)]
    enum Op {
        Admit(usize),
        Open,
        Close,
        Write,
        Settle(usize, bool),
    }

    proptest! {
        #[test]
        fn the_fifo_stays_sorted_with_its_written_messages_first(
            ops in proptest::collection::vec(
                prop_oneof![
                    (0usize..12).prop_map(Op::Admit),
                    Just(Op::Open),
                    Just(Op::Close),
                    Just(Op::Write),
                    (0usize..12, any::<bool>()).prop_map(|(number, acked)| Op::Settle(number, acked)),
                ],
                0..200,
            )
        ) {
            let mut inbox = Inbox::default();
            let streams = streams::<2>();
            let mut next = 0;
            for op in ops {
                match op {
                    Op::Admit(number) => { admit(&mut inbox, number, number); }
                    Op::Open => { inbox.open(streams[next % 2]); }
                    Op::Close => { inbox.close(streams[next % 2]); next += 1; }
                    Op::Write => { inbox.next_write(); }
                    Op::Settle(number, acked) => {
                        let outcome = if acked { Outcome::Acked } else { Outcome::Refused };
                        inbox.settle(&id(number), outcome);
                    }
                }
                let seqs: Vec<u64> = inbox.fifo.iter().map(|entry| entry.seq).collect();
                prop_assert!(seqs.windows(2).all(|pair| pair[0] < pair[1]));
                let places: Vec<Place> = inbox.fifo.iter().map(|entry| entry.place).collect();
                let out = places.iter().filter(|place| **place == Place::Out).count();
                prop_assert!(out <= WINDOW);
                prop_assert!(places.iter().take(out).all(|place| *place == Place::Out));
                prop_assert_eq!(inbox.bytes, inbox.fifo.iter().map(|entry| entry.size).sum::<usize>());
                prop_assert!(inbox.stream.is_some() || out == 0);
            }
        }
    }
}
