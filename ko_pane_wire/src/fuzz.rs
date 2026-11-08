#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::indexing_slicing,
    clippy::arithmetic_side_effects
)]

pub fn webview(data: &[u8]) {
    if data.len() > crate::webview::MAX_BYTES {
        return;
    }
    if let Some(crate::webview::Command::Enter(path)) = crate::webview::parse(data) {
        let text = path.as_str();
        assert!(text.starts_with('/'));
        assert!(text.len() <= crate::frame::WEBVIEW_PATH_MAX_BYTES);
        assert!(
            text.bytes()
                .all(|byte| byte.is_ascii() && !byte.is_ascii_control())
        );
        let encoded = format!("7502;a=enter:p={}", crate::base64::encode(text.as_bytes()));
        assert_eq!(
            crate::webview::parse(encoded.as_bytes()),
            Some(crate::webview::Command::Enter(path))
        );
    }
}

use crate::ring::{Commit, HEADER, Offset, Pos, Reach, Reader, RecordKind, Writer};

struct Bytes<'a>(&'a [u8]);

impl Bytes<'_> {
    fn next(&mut self) -> Option<u8> {
        let (&byte, rest) = self.0.split_first()?;
        self.0 = rest;
        Some(byte)
    }

    fn word(&mut self) -> Option<u64> {
        Some(u64::from(self.next()?) | u64::from(self.next()?) << 8)
    }
}

#[derive(Debug, Clone, Copy)]
pub(crate) enum Op {
    Write(RecordKind, u64),
    AdvanceToHead,
    AdvanceToTail,
    AdvanceToBoundary(u64),
    Resume(u64),
}

fn op(bytes: &mut Bytes<'_>) -> Option<Op> {
    let tag = bytes.next()?;
    Some(match tag % 7 {
        0 => Op::Write(RecordKind::Bytes, bytes.word()?),
        1 => Op::Write(RecordKind::Slice, bytes.word()?),
        2 => Op::Write(RecordKind::Marker, u64::from(bytes.next()?)),
        3 => Op::AdvanceToHead,
        4 => Op::AdvanceToTail,
        5 => Op::AdvanceToBoundary(bytes.word()?),
        _ => Op::Resume(bytes.word()?),
    })
}

pub(crate) fn payload(kind: RecordKind, offset: u64, len: u64) -> Vec<u8> {
    match kind {
        RecordKind::Bytes => (0..len).map(|i| (offset + i) as u8).collect(),
        RecordKind::Marker if len.is_multiple_of(2) => vec![1, 50, 0, 20, 0, 8, 0, 16, 0],
        RecordKind::Marker => [vec![2], vec![0; 16]].concat(),
        RecordKind::Slice | RecordKind::Pad => vec![0; len.max(2) as usize],
    }
}

#[derive(Debug, Clone, Copy)]
struct Modeled {
    pos: u64,
    kind: RecordKind,
    offset: u64,
    len: u64,
}

pub(crate) struct Model {
    capacity: u64,
    head: u64,
    tail: u64,
    offset: u64,
    records: Vec<Modeled>,
}

impl Model {
    fn push(&mut self, kind: RecordKind, len: u64) {
        self.records.push(Modeled {
            pos: self.head,
            kind,
            offset: self.offset,
            len,
        });
        self.head += HEADER + len;
        if kind == RecordKind::Bytes {
            self.offset += len;
        }
    }

    fn live(&self) -> impl Iterator<Item = &Modeled> {
        self.records.iter().filter(|r| r.pos >= self.tail)
    }

    fn plan(&self) -> (Option<u64>, u64) {
        let used: u64 = self.live().map(|r| HEADER + r.len).sum();
        let free = self.capacity - used;
        let room = self.capacity - self.head % self.capacity;
        let (pad, free, room) = if room <= 2 * HEADER {
            if free < room {
                (None, 0, 0)
            } else {
                (Some(room - HEADER), free - room, self.capacity)
            }
        } else {
            (None, free, room)
        };
        (pad, free.min(room).saturating_sub(2 * HEADER))
    }

    fn write(&mut self, kind: RecordKind, len: u64) -> bool {
        let (pad, fits) = self.plan();
        if let Some(n) = pad {
            self.push(RecordKind::Pad, n);
        }
        let length = payload(kind, self.offset, len).len() as u64;
        let ok = length <= fits;
        if ok {
            self.push(kind, length);
        }
        ok
    }

    fn boundaries(&self) -> Vec<u64> {
        self.live().map(|r| r.pos).chain([self.head]).collect()
    }

    fn advance(&mut self, keep: u64) {
        let retain = self
            .tail
            .max(self.head.saturating_sub(self.capacity / 2).min(keep));
        self.tail = self
            .boundaries()
            .into_iter()
            .find(|&p| p >= retain)
            .expect("the head is a boundary");
    }

    fn oldest_offset(&self) -> u64 {
        self.live().next().map_or(self.offset, |r| r.offset)
    }

    fn reachable(&self, pos: u64) -> Reach {
        let lost = self.records.iter().any(|r| {
            r.pos < self.tail
                && matches!(r.kind, RecordKind::Bytes | RecordKind::Marker)
                && r.pos + HEADER + r.len > pos
        });
        if lost {
            Reach::Behind
        } else {
            Reach::At(Pos::new(pos.max(self.tail)))
        }
    }

    fn resume(&self, target: u64) -> (Vec<u8>, Vec<u64>) {
        let marks = self
            .live()
            .filter(|r| matches!(r.kind, RecordKind::Marker | RecordKind::Slice))
            .filter(|r| r.offset >= target)
            .map(|r| r.offset)
            .collect();
        (
            payload(RecordKind::Bytes, target, self.offset - target),
            marks,
        )
    }
}

pub(crate) struct Candidate {
    pub(crate) reader: Reader,
    pub(crate) writer: Writer,
}

impl Candidate {
    fn write(&mut self, kind: RecordKind, len: u64, offset: u64) -> bool {
        let room = self.writer.available().room;
        let body = payload(kind, offset, len);
        body.len() as u64 <= room && self.writer.put(kind, &body) != Commit::Refused
    }

    pub(crate) fn positions(&mut self, from: Pos) -> Vec<Pos> {
        let head = self.reader.head();
        let mut positions = Vec::new();
        let mut pos = from;
        while pos < head {
            positions.push(pos);
            pos = self
                .reader
                .record(pos)
                .expect("a record at a boundary")
                .next;
        }
        positions
    }

    fn boundaries(&mut self) -> Vec<u64> {
        let tail = self.reader.tail();
        let head = self.reader.head();
        let mut boundaries: Vec<u64> = self.positions(tail).iter().map(|p| p.get()).collect();
        boundaries.push(head.get());
        boundaries
    }

    pub(crate) fn resume(&mut self, target: u64) -> (Vec<u8>, Vec<u64>) {
        let from = self
            .reader
            .resume(Offset::new(target))
            .expect("a target inside the retained offsets");
        let mut bytes = Vec::new();
        let mut marks = Vec::new();
        for pos in self.positions(from) {
            let record = self.reader.record(pos).expect("a record at a boundary");
            match record.kind {
                RecordKind::Bytes => {
                    let skip = target.saturating_sub(record.offset.get()) as usize;
                    bytes.extend_from_slice(&self.reader.payload(pos).expect("a payload")[skip..]);
                }
                RecordKind::Marker | RecordKind::Slice => marks.push(record.offset.get()),
                RecordKind::Pad => {}
            }
        }
        (bytes, marks)
    }

    fn check(&mut self, model: &Model) {
        assert_eq!(self.reader.head().get(), model.head, "head");
        assert_eq!(self.reader.tail().get(), model.tail, "tail");
        assert_eq!(
            self.reader.end_offset().expect("an end offset").get(),
            model.offset,
            "end offset"
        );
        assert_eq!(
            self.reader.oldest_offset().expect("an oldest offset").get(),
            model.oldest_offset(),
            "oldest offset"
        );
        for pos in model.records.iter().map(|r| r.pos).chain([model.head]) {
            assert_eq!(
                self.reader.reachable(Pos::new(pos)),
                model.reachable(pos),
                "{pos}"
            );
        }
    }
}

pub(crate) struct Pair {
    pub(crate) model: Model,
    pub(crate) candidate: Candidate,
}

impl Pair {
    pub(crate) fn new(capacity: u64) -> Option<Pair> {
        let reader = Reader::create(capacity).ok()?;
        let writer = reader.writer().ok()?;
        Some(Pair {
            model: Model {
                capacity,
                head: 0,
                tail: 0,
                offset: 0,
                records: Vec::new(),
            },
            candidate: Candidate { reader, writer },
        })
    }

    pub(crate) fn apply(&mut self, op: Op) {
        let Pair { model, candidate } = self;
        match op {
            Op::Write(kind, raw) => {
                let len = match kind {
                    RecordKind::Marker => raw & 1,
                    _ => 1 + raw % (model.capacity / 3),
                };
                let offset = model.offset;
                assert_eq!(model.write(kind, len), candidate.write(kind, len, offset));
            }
            Op::AdvanceToHead => {
                let head = model.head;
                model.advance(head);
                let head = candidate.reader.head();
                candidate
                    .reader
                    .advance(head, head)
                    .expect("advance to the head");
            }
            Op::AdvanceToTail => {
                let tail = model.tail;
                model.advance(tail);
                let head = candidate.reader.head();
                let tail = candidate.reader.tail();
                candidate
                    .reader
                    .advance(head, tail)
                    .expect("advance to the tail");
            }
            Op::AdvanceToBoundary(n) => {
                let boundaries = model.boundaries();
                assert_eq!(boundaries, candidate.boundaries());
                let keep = boundaries[n as usize % boundaries.len()];
                model.advance(keep);
                let head = candidate.reader.head();
                candidate
                    .reader
                    .advance(head, Pos::new(keep))
                    .expect("advance to a boundary");
            }
            Op::Resume(n) => {
                let oldest = model.oldest_offset();
                let target = oldest + n % (model.offset - oldest + 1);
                assert_eq!(model.resume(target), candidate.resume(target));
            }
        }
        candidate.check(model);
    }
}

pub fn ring(data: &[u8]) {
    let mut bytes = Bytes(data);
    let Some(size) = bytes.word() else {
        return;
    };
    let Some(mut pair) = Pair::new(64 + size % 537) else {
        return;
    };
    while let Some(op) = op(&mut bytes) {
        pair.apply(op);
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn webview_corpus() {
        for data in [
            b"7502;a=enter".as_slice(),
            b"7502;a=leave",
            b"7502;?",
            b"7502;a=enter:p=Lz9hPWI=",
        ] {
            super::webview(data);
        }
    }

    use super::*;
    use std::path::Path;

    #[test]
    fn the_model_agrees_on_inputs_without_a_corpus_directory() {
        ring(&[0xe9, 0x01, 2, 0, 0, 0xb3, 0, 6, 0x4c, 0]);
        ring(&[
            0x00, 0x00, 0, 10, 0, 0, 30, 0, 2, 1, 5, 2, 0, 6, 5, 0, 3, 0, 60, 0, 4,
        ]);
    }

    #[test]
    fn the_replayed_corpus_runs_to_the_end() {
        let corpus = Path::new(env!("CARGO_MANIFEST_DIR")).join("../fuzz/corpus/ring");
        let mut replayed = 0;
        for entry in std::fs::read_dir(corpus).unwrap() {
            ring(&std::fs::read(entry.unwrap().path()).unwrap());
            replayed += 1;
        }
        assert!(replayed >= 4, "{replayed}");
    }
}
