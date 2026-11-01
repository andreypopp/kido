#![deny(clippy::indexing_slicing, clippy::arithmetic_side_effects)]

#[cfg(not(loom))]
mod mapping;
#[cfg(loom)]
mod model;

use std::fmt;
#[cfg(not(loom))]
use std::io;
#[cfg(not(loom))]
use std::os::fd::{BorrowedFd, OwnedFd};

use crate::frame::{self, Dead, Size};

#[cfg(not(loom))]
type Handle = mapping::Shared;
#[cfg(loom)]
type Handle = std::sync::Arc<model::Shared>;

pub(crate) const HEADER: u64 = 13;
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
    pub(crate) fn new(value: u64) -> Pos {
        Pos(value)
    }

    pub fn get(self) -> u64 {
        self.0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Offset(u64);

impl Offset {
    pub fn new(value: u64) -> Offset {
        Offset(value)
    }

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

pub const SLICE_HEADER: usize = 2;
pub const RESIZE_LEN: usize = 9;
pub const DEAD_LEN: usize = 17;

impl Slice {
    pub fn encode(self) -> [u8; SLICE_HEADER] {
        [
            u8::from(self.first) | u8::from(self.last) << 1,
            u8::from(self.screen),
        ]
    }
}

fn tagged(out: &mut [u8; DEAD_LEN], tag: u8, body: &[u8]) -> usize {
    for (slot, byte) in out.iter_mut().zip(std::iter::once(&tag).chain(body)) {
        *slot = *byte;
    }
    body.len().saturating_add(1)
}

impl Marker {
    fn encode(self) -> ([u8; DEAD_LEN], usize) {
        let mut out = [0; DEAD_LEN];
        let len = match self {
            Marker::Resize(size) => tagged(&mut out, 1, &frame::size_bytes(size)),
            Marker::Dead(dead) => tagged(&mut out, 2, &frame::dead_bytes(dead)),
        };
        (out, len)
    }
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
        self.shared.duplicate().map(Writer::attach)
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

    #[cfg(not(loom))]
    pub fn open(fd: OwnedFd) -> io::Result<Writer> {
        let mapping = ko_sys::mapping::Mapping::attach(fd)?;
        mapping::Shared::attach(mapping)
            .map(Writer::attach)
            .map_err(|invalid| io::Error::new(io::ErrorKind::InvalidData, invalid.to_string()))
    }

    pub fn head(&self) -> Pos {
        Pos(self.head)
    }

    pub fn tail(&self) -> Pos {
        Pos(self.tail)
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

    #[cfg(not(loom))]
    pub fn payload(&mut self, kind: RecordKind, len: usize) -> Option<&mut [u8]> {
        self.fits(kind.tag(), u64::try_from(len).ok()?)?;
        self.shared.room(payload_at(self.head)?, len)
    }

    pub fn publish(&mut self, kind: RecordKind, len: usize) -> Commit {
        u64::try_from(len)
            .ok()
            .and_then(|len| self.commit(kind.tag(), len))
            .unwrap_or(Commit::Refused)
    }

    pub fn put_marker(&mut self, marker: Marker) -> Commit {
        let (bytes, len) = marker.encode();
        self.put(RecordKind::Marker, bytes.get(..len).unwrap_or_default())
    }

    pub fn put_slice(&mut self, slice: Slice) -> Commit {
        self.put(RecordKind::Slice, &slice.encode())
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
    use crate::fuzz::{Candidate, Op, Pair};
    use ko_sys::clock::Mono;
    use ko_sys::pid::Exit;
    use proptest::prelude::*;

    fn ring(capacity: u64) -> (Reader, Writer) {
        let reader = Reader::create(capacity).unwrap();
        let writer = reader.writer().unwrap();
        (reader, writer)
    }

    #[test]
    fn a_marker_and_bytes_that_end_before_the_resume_target_are_not_replayed() {
        let mut pair = Pair::new(553).unwrap();
        pair.apply(Op::Write(RecordKind::Marker, 0));
        pair.apply(Op::Write(RecordKind::Bytes, 179));
        assert!(pair.candidate.resume(76).1.is_empty());
        pair.apply(Op::Resume(76));
    }

    fn op() -> impl Strategy<Value = Op> {
        prop_oneof![
            any::<u64>().prop_map(|n| Op::Write(RecordKind::Bytes, n)),
            any::<u64>().prop_map(|n| Op::Write(RecordKind::Slice, n)),
            (0..2u64).prop_map(|n| Op::Write(RecordKind::Marker, n)),
            Just(Op::AdvanceToHead),
            Just(Op::AdvanceToTail),
            any::<u64>().prop_map(Op::AdvanceToBoundary),
            any::<u64>().prop_map(Op::Resume),
        ]
    }

    proptest! {
        #[test]
        fn the_ring_agrees_with_a_list_of_records(
            capacity in 64..=600u64,
            ops in prop::collection::vec(op(), 0..40),
        ) {
            let mut pair = Pair::new(capacity).unwrap();
            for op in ops {
                pair.apply(op);
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
    fn the_markers_and_slices_the_writer_puts_are_the_ones_the_reader_decodes() {
        let (reader, writer) = ring(512);
        let mut candidate = Candidate { reader, writer };
        let resize = Marker::Resize(Size {
            cols: Dim::new(40).unwrap(),
            rows: Dim::new(20).unwrap(),
            cell_px: None,
        });
        let dead = Marker::Dead(Dead {
            at: Mono::from_nanos(5),
            exit: Exit::Signaled(15),
        });
        let slice = Slice {
            first: false,
            last: true,
            screen: true,
        };
        let lengths = [RESIZE_LEN, DEAD_LEN, SLICE_HEADER];
        candidate.writer.available();
        assert_ne!(candidate.writer.put_marker(resize), Commit::Refused);
        candidate.writer.available();
        assert_ne!(candidate.writer.put_marker(dead), Commit::Refused);
        candidate.writer.available();
        assert_ne!(candidate.writer.put_slice(slice), Commit::Refused);
        let at = candidate.positions(Pos(0));
        let reader = &candidate.reader;
        assert_eq!(reader.marker(at[0]), Ok(resize));
        assert_eq!(reader.marker(at[1]), Ok(dead));
        assert_eq!(reader.slice(at[2]), Ok(slice));
        for (pos, length) in at.iter().zip(lengths) {
            assert_eq!(reader.record(*pos).unwrap().len, length as u64);
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
