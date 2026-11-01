#![deny(clippy::indexing_slicing, clippy::arithmetic_side_effects)]

#[cfg(not(loom))]
mod mapping;
#[cfg(loom)]
mod model;

use std::fmt;
#[cfg(not(loom))]
use std::io;
#[cfg(not(loom))]
use std::os::fd::BorrowedFd;

use crate::frame::{self, Dead, Size};

#[cfg(not(loom))]
type Handle = mapping::Shared;
#[cfg(loom)]
type Handle = std::sync::Arc<model::Shared>;

const HEADER: u64 = 13;
const MIN_CAPACITY: u64 = 64;
const MAX_CAPACITY: u64 = 1 << 30;
const PAD_ROOM: u64 = 2 * HEADER;
const MAX_HEAD: u64 = 0x3fff_ffff_0000_0000;
const MAX_OFFSET: u64 = 1 << 62;
const MAX_LENGTH: u64 = 1 << 32;
const BYTES: u8 = 1;
const MARKER: u8 = 2;
const SLICE: u8 = 3;
const PAD: u8 = 4;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Index {
    Head = 1,
    Tail = 2,
    Read = 3,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Pos(u64);

impl Pos {
    pub fn get(self) -> u64 {
        self.0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Offset(u64);

impl Offset {
    pub fn get(self) -> u64 {
        self.0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reach {
    Behind,
    At(Pos),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecordKind {
    Bytes,
    Marker,
    Slice,
    Pad,
}

impl RecordKind {
    fn tag(self) -> u8 {
        match self {
            RecordKind::Bytes => BYTES,
            RecordKind::Marker => MARKER,
            RecordKind::Slice => SLICE,
            RecordKind::Pad => PAD,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Record {
    pub kind: RecordKind,
    pub len: u64,
    pub offset: Offset,
    pub next: Pos,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Marker {
    Resize(Size),
    Dead(Dead),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Slice {
    pub first: bool,
    pub last: bool,
    pub screen: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Invalid {
    Capacity,
    Record,
    Head,
    Slice,
    Marker,
}

impl fmt::Display for Invalid {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Invalid::Capacity => "invalid ring capacity",
            Invalid::Record => "invalid ring record",
            Invalid::Head => "invalid ring head",
            Invalid::Slice => "invalid ring slice",
            Invalid::Marker => "invalid ring marker",
        })
    }
}

fn valid_capacity(capacity: u64, room: u64) -> Result<u64, Invalid> {
    if (MIN_CAPACITY..=MAX_CAPACITY).contains(&capacity) && capacity <= room {
        Ok(capacity)
    } else {
        Err(Invalid::Capacity)
    }
}

#[derive(Debug, Clone, Copy)]
struct Header {
    tag: u8,
    len: u64,
    off: u64,
    next: u64,
}

impl Header {
    fn bytes_end(self) -> Option<u64> {
        let fits = self.tag == BYTES && self.off < MAX_OFFSET && self.len < MAX_LENGTH;
        self.off.checked_add(self.len).filter(|_| fits)
    }

    fn end_offset(self) -> u64 {
        self.bytes_end().unwrap_or(self.off)
    }
}

fn payload_at(pos: u64) -> Option<u64> {
    pos.checked_add(HEADER)
}

#[derive(Debug)]
pub struct Reader {
    shared: Handle,
    tail: u64,
    seen: u64,
    settled: u64,
    settled_offset: u64,
    evicted: u64,
}

impl Reader {
    fn attach(shared: Handle) -> Reader {
        Reader {
            shared,
            tail: 0,
            seen: 0,
            settled: 0,
            settled_offset: 0,
            evicted: 0,
        }
    }

    #[cfg(not(loom))]
    pub fn create(capacity: u64) -> io::Result<Reader> {
        mapping::Shared::create(capacity).map(Reader::attach)
    }

    #[cfg(not(loom))]
    pub fn fd(&self) -> BorrowedFd<'_> {
        self.shared.fd()
    }

    #[cfg(not(loom))]
    pub fn writer(&self) -> io::Result<Writer> {
        let mapping = ko_sys::mapping::Mapping::attach(self.fd().try_clone_to_owned()?)?;
        mapping::Shared::attach(mapping)
            .map(Writer::attach)
            .map_err(|invalid| io::Error::new(io::ErrorKind::InvalidData, invalid.to_string()))
    }

    pub fn head(&mut self) -> Pos {
        let before = self.seen;
        self.seen = self.shared.load(Index::Head);
        debug_assert!(self.seen >= before && self.seen >= self.tail, "Ring.head");
        Pos(self.seen)
    }

    pub fn tail(&self) -> Pos {
        Pos(self.tail)
    }

    pub fn seen(&self) -> Pos {
        Pos(self.seen)
    }

    fn copy(&self, at: u64, out: &mut [u8]) -> Option<()> {
        self.shared.copy(self.tail..self.seen, at, out)
    }

    fn header(&self, pos: u64) -> Option<Header> {
        let mut bytes = [0u8; HEADER as usize];
        self.copy(pos, &mut bytes)?;
        let [tag, l0, l1, l2, l3, o0, o1, o2, o3, o4, o5, o6, o7] = bytes;
        let len = u64::from(u32::from_le_bytes([l0, l1, l2, l3]));
        let next = payload_at(pos)?.checked_add(len)?;
        let index_end = pos
            .checked_rem(self.shared.capacity())?
            .checked_add(HEADER)?
            .checked_add(len)?;
        let ok = (BYTES..=PAD).contains(&tag)
            && index_end <= self.shared.capacity()
            && next <= self.seen;
        ok.then_some(Header {
            tag,
            len,
            off: u64::from_le_bytes([o0, o1, o2, o3, o4, o5, o6, o7]),
            next,
        })
    }

    pub fn record(&self, pos: Pos) -> Result<Record, Invalid> {
        let header = self.header(pos.0).ok_or(Invalid::Record)?;
        debug_assert!(
            pos.0 >= self.tail && header.next <= self.seen && header.off <= pos.0,
            "Ring.header"
        );
        Ok(Record {
            kind: match header.tag {
                BYTES => RecordKind::Bytes,
                MARKER => RecordKind::Marker,
                SLICE => RecordKind::Slice,
                _ => RecordKind::Pad,
            },
            len: header.len,
            offset: Offset(header.off),
            next: Pos(header.next),
        })
    }

    #[cfg(not(loom))]
    pub fn payload(&self, pos: Pos) -> Result<&[u8], Invalid> {
        let header = self.header(pos.0).ok_or(Invalid::Record)?;
        payload_at(pos.0)
            .and_then(|at| self.shared.bytes(self.tail..self.seen, at, header.len))
            .ok_or(Invalid::Record)
    }

    fn prefix(&self, pos: Pos, out: &mut [u8; 17]) -> Result<u64, Invalid> {
        let header = self.header(pos.0).ok_or(Invalid::Record)?;
        let copied = usize::try_from(header.len).map_or(out.len(), |len| len.min(out.len()));
        payload_at(pos.0)
            .zip(out.get_mut(..copied))
            .and_then(|(at, bytes)| self.copy(at, bytes))
            .ok_or(Invalid::Record)?;
        Ok(header.len)
    }

    pub fn slice(&self, pos: Pos) -> Result<Slice, Invalid> {
        let mut bytes = [0; 17];
        match (self.prefix(pos, &mut bytes)?, bytes) {
            (2.., [flags, screen, ..]) => Ok(Slice {
                first: flags & 1 != 0,
                last: flags & 2 != 0,
                screen: screen == 1,
            }),
            _ => Err(Invalid::Slice),
        }
    }

    pub fn marker(&self, pos: Pos) -> Result<Marker, Invalid> {
        let mut bytes = [0; 17];
        let len = self.prefix(pos, &mut bytes)?;
        let body = usize::try_from(len).ok().and_then(|len| bytes.get(..len));
        match body.and_then(<[u8]>::split_first) {
            Some((1, size)) => frame::size(size).map(Marker::Resize),
            Some((2, dead)) => frame::dead(dead).map(Marker::Dead),
            _ => None,
        }
        .ok_or(Invalid::Marker)
    }

    pub fn advance(&mut self, head: Pos, keep: Pos) -> Result<(), Invalid> {
        let before = self.tail;
        let upper = head.0;
        if upper != self.seen {
            return Err(Invalid::Head);
        }
        let retain = match upper.checked_sub(self.shared.capacity() / 2) {
            None => 0,
            Some(above) => above.min(keep.0),
        };
        let mut tail = self.tail;
        let mut last = 0;
        let mut evicted = self.evicted;
        while tail < retain {
            let header = self.header(tail).ok_or(Invalid::Head)?;
            last = header.end_offset();
            if header.tag <= MARKER {
                evicted = header.next;
            }
            tail = header.next;
        }
        if self.tail < tail {
            if self.settled < tail {
                let settled_offset = if tail < upper {
                    self.header(tail).ok_or(Invalid::Head)?.off
                } else {
                    last
                };
                self.settled = tail;
                self.settled_offset = settled_offset;
            }
            self.shared.store(Index::Tail, tail);
            self.tail = tail;
            self.evicted = evicted;
        }
        self.shared.store(Index::Read, upper);
        debug_assert!(
            before <= self.tail
                && self.tail <= upper
                && if retain <= before {
                    self.tail == before
                } else {
                    retain <= self.tail
                },
            "Ring.advance"
        );
        Ok(())
    }

    pub fn reachable(&self, pos: Pos) -> Reach {
        if pos.0 < self.evicted {
            Reach::Behind
        } else {
            Reach::At(Pos(pos.0.max(self.tail)))
        }
    }

    pub fn end_offset(&mut self) -> Result<Offset, Invalid> {
        let upper = self.head().0;
        let mut settled = self.settled;
        let mut offset = self.settled_offset;
        while settled < upper {
            let header = self.header(settled).ok_or(Invalid::Record)?;
            offset = header.end_offset();
            settled = header.next;
        }
        self.settled = settled;
        self.settled_offset = offset;
        Ok(Offset(offset))
    }

    pub fn oldest_offset(&mut self) -> Result<Offset, Invalid> {
        if self.tail < self.head().0 {
            self.record(Pos(self.tail)).map(|record| record.offset)
        } else {
            self.end_offset()
        }
    }

    pub fn resume(&mut self, target: Offset) -> Result<Pos, Invalid> {
        let upper = self.head().0;
        let mut pos = self.tail;
        while pos < upper {
            let header = self.header(pos).ok_or(Invalid::Record)?;
            let replayed = match header.tag {
                BYTES => header.bytes_end().is_some_and(|end| end <= target.0),
                tag => tag == PAD || header.off < target.0,
            };
            if !replayed {
                break;
            }
            pos = header.next;
        }
        debug_assert!(self.tail <= pos && pos <= self.seen, "Ring.resume");
        Ok(Pos(pos))
    }
}

#[derive(Debug)]
pub struct Writer {
    shared: Handle,
    head: u64,
    woff: u64,
    tail: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Commit {
    Refused,
    Published,
    Idle,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Available {
    pub room: u64,
    pub idle: bool,
}

impl Writer {
    fn attach(shared: Handle) -> Writer {
        Writer {
            shared,
            head: 0,
            woff: 0,
            tail: 0,
        }
    }

    fn fits(&self, tag: u8, len: u64) -> Option<u64> {
        let capacity = self.shared.capacity();
        let end = self
            .head
            .checked_rem(capacity)?
            .checked_add(HEADER)?
            .checked_add(len)?;
        let next = payload_at(self.head)?.checked_add(len)?;
        let fits = (BYTES..=PAD).contains(&tag)
            && len <= capacity
            && end <= capacity
            && (end == capacity || end.checked_add(HEADER)? <= capacity)
            && next <= self.tail.checked_add(capacity)?
            && next <= MAX_HEAD;
        fits.then_some(next)
    }

    fn commit(&mut self, tag: u8, len: u64) -> Option<Commit> {
        let Some(next) = self.fits(tag, len) else {
            return Some(Commit::Refused);
        };
        let [l0, l1, l2, l3, ..] = len.to_le_bytes();
        let [o0, o1, o2, o3, o4, o5, o6, o7] = self.woff.to_le_bytes();
        self.shared.write(
            self.head,
            &[tag, l0, l1, l2, l3, o0, o1, o2, o3, o4, o5, o6, o7],
        )?;
        let head = self.head;
        self.shared.store(Index::Head, next);
        let read = self.shared.load(Index::Read);
        if tag == BYTES {
            self.woff = self.woff.checked_add(len)?;
        }
        self.head = next;
        Some(if read == head {
            Commit::Idle
        } else {
            Commit::Published
        })
    }

    pub fn available(&mut self) -> Available {
        self.tail = self.shared.load(Index::Tail);
        self.room().unwrap_or(Available {
            room: 0,
            idle: false,
        })
    }

    fn room(&mut self) -> Option<Available> {
        if self.head >= MAX_HEAD {
            return None;
        }
        let capacity = self.shared.capacity();
        let free = capacity.checked_sub(self.head.checked_sub(self.tail)?)?;
        let end = capacity.checked_sub(self.head.checked_rem(capacity)?)?;
        let room = |n: u64| n.saturating_sub(PAD_ROOM);
        if end > PAD_ROOM {
            return Some(Available {
                room: room(free.min(end)),
                idle: false,
            });
        }
        if free < end {
            return None;
        }
        let idle = self.commit(PAD, end.checked_sub(HEADER)?)? == Commit::Idle;
        Some(Available {
            room: room(free.checked_sub(end)?.min(capacity)),
            idle,
        })
    }

    pub fn put(&mut self, kind: RecordKind, payload: &[u8]) -> Commit {
        let written = u64::try_from(payload.len()).ok().and_then(|len| {
            self.fits(kind.tag(), len)?;
            self.shared.write(payload_at(self.head)?, payload)?;
            self.commit(kind.tag(), len)
        });
        written.unwrap_or(Commit::Refused)
    }
}

#[cfg(test)]
#[cfg(not(loom))]
#[allow(clippy::arithmetic_side_effects)]
mod tests {
    use super::*;
    use crate::frame::{CellPx, Dim};
    use ko_sys::clock::Mono;
    use ko_sys::pid::Exit;
    use proptest::prelude::*;

    fn ring(capacity: u64) -> (Reader, Writer) {
        let reader = Reader::create(capacity).unwrap();
        let writer = reader.writer().unwrap();
        (reader, writer)
    }

    fn payload(kind: RecordKind, offset: u64, len: u64) -> Vec<u8> {
        match kind {
            RecordKind::Bytes => (0..len).map(|i| (offset + i) as u8).collect(),
            RecordKind::Marker if len.is_multiple_of(2) => vec![1, 50, 0, 20, 0, 8, 0, 16, 0],
            RecordKind::Marker => [vec![2], vec![0; 16]].concat(),
            RecordKind::Slice | RecordKind::Pad => vec![0; len.max(2) as usize],
        }
    }

    fn advances_offset(kind: RecordKind, len: u64) -> u64 {
        if kind == RecordKind::Bytes { len } else { 0 }
    }

    fn plan(capacity: u64, head: u64, tail: u64) -> (Option<u64>, u64) {
        let free = capacity - (head - tail);
        let room = capacity - head % capacity;
        let (pad, free, room) = if room <= 2 * HEADER {
            if free < room {
                (None, 0, 0)
            } else {
                (Some(room - HEADER), free - room, capacity)
            }
        } else {
            (None, free, room)
        };
        let n = free.min(room);
        (pad, n.saturating_sub(2 * HEADER))
    }

    #[derive(Debug, Clone)]
    struct Modeled {
        pos: u64,
        kind: RecordKind,
        offset: u64,
        len: u64,
    }

    #[derive(Debug)]
    struct Model {
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
            self.offset += advances_offset(kind, len);
        }

        fn write(&mut self, kind: RecordKind, len: u64) -> bool {
            let (pad, fits) = plan(self.capacity, self.head, self.tail);
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

        fn live(&self) -> impl Iterator<Item = &Modeled> {
            self.records.iter().filter(|r| r.pos >= self.tail)
        }

        fn boundaries(&self) -> Vec<u64> {
            self.live().map(|r| r.pos).chain([self.head]).collect()
        }

        fn advance(&mut self, keep: u64) {
            let retain = self
                .tail
                .max(self.head.saturating_sub(self.capacity / 2).min(keep));
            self.tail = *self.boundaries().iter().find(|&&p| p >= retain).unwrap();
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
                Reach::At(Pos(pos.max(self.tail)))
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

    #[derive(Debug)]
    struct Candidate {
        reader: Reader,
        writer: Writer,
    }

    impl Candidate {
        fn write(&mut self, kind: RecordKind, len: u64) -> bool {
            let room = self.writer.available().room;
            let body = payload(kind, self.writer.woff, len);
            body.len() as u64 <= room && self.writer.put(kind, &body) != Commit::Refused
        }

        fn positions(&mut self, from: Pos) -> Vec<Pos> {
            let head = self.reader.head();
            let mut positions = Vec::new();
            let mut pos = from;
            while pos < head {
                positions.push(pos);
                pos = self.reader.record(pos).unwrap().next;
            }
            positions
        }

        fn advance(&mut self, keep: u64) {
            let head = self.reader.head();
            self.reader.advance(head, Pos(keep)).unwrap();
        }

        fn boundaries(&mut self) -> Vec<u64> {
            let tail = self.reader.tail();
            let head = self.reader.head();
            let mut boundaries: Vec<u64> = self.positions(tail).iter().map(|p| p.0).collect();
            boundaries.push(head.0);
            boundaries
        }

        fn resume(&mut self, target: u64) -> (Vec<u8>, Vec<u64>) {
            let from = self.reader.resume(Offset(target)).unwrap();
            let mut bytes = Vec::new();
            let mut marks = Vec::new();
            for pos in self.positions(from) {
                let record = self.reader.record(pos).unwrap();
                match record.kind {
                    RecordKind::Bytes => {
                        let skip = target.saturating_sub(record.offset.0) as usize;
                        bytes.extend_from_slice(&self.reader.payload(pos).unwrap()[skip..]);
                    }
                    RecordKind::Marker | RecordKind::Slice => marks.push(record.offset.0),
                    RecordKind::Pad => {}
                }
            }
            (bytes, marks)
        }

        fn check(&mut self, model: &Model) {
            assert_eq!(self.reader.head().0, model.head);
            assert_eq!(self.reader.tail().0, model.tail);
            assert_eq!(self.reader.end_offset().unwrap().0, model.offset);
            assert_eq!(
                self.reader.oldest_offset().unwrap().0,
                model.oldest_offset()
            );
            for pos in model.records.iter().map(|r| r.pos).chain([model.head]) {
                assert_eq!(
                    self.reader.reachable(Pos(pos)),
                    model.reachable(pos),
                    "{pos}"
                );
            }
        }
    }

    fn pair(capacity: u64) -> (Model, Candidate) {
        let (reader, writer) = ring(capacity);
        (
            Model {
                capacity,
                head: 0,
                tail: 0,
                offset: 0,
                records: Vec::new(),
            },
            Candidate { reader, writer },
        )
    }

    #[test]
    fn a_marker_and_bytes_that_end_before_the_resume_target_are_not_replayed() {
        let (mut model, mut candidate) = pair(553);
        assert!(model.write(RecordKind::Marker, 0) && candidate.write(RecordKind::Marker, 0));
        assert!(model.write(RecordKind::Bytes, 180) && candidate.write(RecordKind::Bytes, 180));
        let replayed = candidate.resume(76);
        assert!(replayed.1.is_empty());
        assert_eq!(model.resume(76), replayed);
    }

    #[derive(Debug, Clone)]
    enum Op {
        Write(RecordKind, u64),
        AdvanceToHead,
        AdvanceToTail,
        AdvanceToBoundary(usize),
        Resume(u64),
    }

    fn op() -> impl Strategy<Value = Op> {
        prop_oneof![
            any::<u64>().prop_map(|n| Op::Write(RecordKind::Bytes, n)),
            any::<u64>().prop_map(|n| Op::Write(RecordKind::Slice, n)),
            (0..2u64).prop_map(|n| Op::Write(RecordKind::Marker, n)),
            Just(Op::AdvanceToHead),
            Just(Op::AdvanceToTail),
            any::<usize>().prop_map(Op::AdvanceToBoundary),
            any::<u64>().prop_map(Op::Resume),
        ]
    }

    proptest! {
        #[test]
        fn the_ring_agrees_with_a_list_of_records(
            capacity in 64..=600u64,
            ops in prop::collection::vec(op(), 0..40),
        ) {
            let (mut model, mut candidate) = pair(capacity);
            for op in ops {
                match op {
                    Op::Write(kind, n) => {
                        let len = match kind {
                            RecordKind::Marker => n,
                            _ => 1 + n % (capacity / 3),
                        };
                        prop_assert_eq!(model.write(kind, len), candidate.write(kind, len));
                    }
                    Op::AdvanceToHead => {
                        let head = model.head;
                        model.advance(head);
                        candidate.advance(head);
                    }
                    Op::AdvanceToTail => {
                        let tail = model.tail;
                        model.advance(tail);
                        candidate.advance(tail);
                    }
                    Op::AdvanceToBoundary(i) => {
                        let boundaries = model.boundaries();
                        prop_assert_eq!(&boundaries, &candidate.boundaries());
                        let keep = boundaries[i % boundaries.len()];
                        model.advance(keep);
                        candidate.advance(keep);
                    }
                    Op::Resume(n) => {
                        let oldest = model.oldest_offset();
                        let target = oldest + n % (model.offset - oldest + 1);
                        prop_assert_eq!(model.resume(target), candidate.resume(target));
                    }
                }
                candidate.check(&model);
            }
        }
    }

    #[test]
    fn constants_match_the_c_ring() {
        let protocol = include_str!("../../ko_pane/protocol.h");
        let ring = include_str!("../../ko_pane/ring.h");
        let proved = include_str!("../../ko_proofs/ko_ring_proved.h");
        assert!(protocol.contains(&format!("#define KO_HEADER {HEADER}\n")));
        assert!(protocol.contains(&format!(
            "enum ko_record {{ KO_BYTES = {BYTES}, KO_MARKER = {MARKER}, \
             KO_SNAPSHOT_SLICE = {SLICE}, KO_PAD = {PAD} }};"
        )));
        assert!(protocol.contains(
            "struct ko_ring { uint64_t capacity; _Atomic uint64_t head, tail, read; uint8_t data[]; };"
        ));
        assert_eq!(
            (
                Index::Head as usize,
                Index::Tail as usize,
                Index::Read as usize
            ),
            (1, 2, 3)
        );
        assert!(ring.contains(&format!(
            "offsetof(struct ko_ring, data) == {}",
            mapping::DATA
        )));
        assert!(proved.contains(&format!("KoRing_Inv_max_capacity = {MAX_CAPACITY:#x}ULL;")));
        assert!(proved.contains(&format!("KoRing_Inv_min_capacity = {MIN_CAPACITY}ULL;")));
        assert!(proved.contains(&format!("fin <= {MAX_HEAD:#x}ULL")));
        assert!(proved.contains(&format!(
            "h.hoff < {MAX_OFFSET:#x}ULL && h.hlen < {MAX_LENGTH:#x}ULL"
        )));
    }

    #[test]
    fn a_ring_outside_the_capacity_bounds_is_refused() {
        for capacity in [MIN_CAPACITY - 1, MAX_CAPACITY + 1] {
            let error = Reader::create(capacity).unwrap_err();
            assert_eq!(error.to_string(), Invalid::Capacity.to_string());
        }
    }

    #[test]
    fn markers_and_slices_decode_from_their_payload() {
        let (reader, mut writer) = ring(256);
        let dead = [
            &[2][..],
            &3i32.to_le_bytes(),
            &0i32.to_le_bytes(),
            &9u64.to_le_bytes(),
        ]
        .concat();
        let records: [(RecordKind, &[u8]); 4] = [
            (RecordKind::Marker, &[1, 50, 0, 20, 0, 8, 0, 16, 0]),
            (RecordKind::Marker, &dead),
            (RecordKind::Slice, &[3, 1]),
            (RecordKind::Marker, &[1, 0, 0, 20, 0, 0, 0, 0, 0]),
        ];
        for (kind, body) in records {
            writer.available();
            assert_ne!(writer.put(kind, body), Commit::Refused);
        }
        let mut candidate = Candidate { reader, writer };
        let at = candidate.positions(Pos(0));
        let reader = &candidate.reader;
        let cell_px = Some(CellPx::DEFAULT);
        let size = |cols, rows| Size {
            cols: Dim::new(cols).unwrap(),
            rows: Dim::new(rows).unwrap(),
            cell_px,
        };
        assert_eq!(reader.marker(at[0]), Ok(Marker::Resize(size(50, 20))));
        let died = Dead {
            at: Mono::from_nanos(9),
            exit: Exit::Exited(3),
        };
        assert_eq!(reader.marker(at[1]), Ok(Marker::Dead(died)));
        let slice = Slice {
            first: true,
            last: true,
            screen: true,
        };
        assert_eq!(reader.slice(at[2]), Ok(slice));
        assert_eq!(reader.marker(at[3]), Err(Invalid::Marker));
        assert_eq!(reader.marker(at[2]), Err(Invalid::Marker));
    }
}
