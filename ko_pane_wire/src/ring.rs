#![deny(clippy::indexing_slicing, clippy::arithmetic_side_effects)]

mod backend;
mod machine;
#[cfg(not(loom))]
mod mapping;
mod mark;
#[cfg(loom)]
mod model;
mod spec;

use std::fmt;
#[cfg(not(loom))]
use std::io;
#[cfg(not(loom))]
use std::os::fd::{BorrowedFd, OwnedFd};

use vstd::open_atomic_invariant;
use vstd::prelude::*;

use crate::frame::{self, Dead, Size};
use backend::{Backend, ByteTok, Handle, HandleBox, Index, MAX_CAPACITY, MIN_CAPACITY};
#[cfg(verus_only)]
use backend::{covers, dom_is, in_rng, tok_ok};
#[cfg(verus_only)]
use machine::{RGhost, WGhost, build, committed};
use machine::{RingSm, World};
pub use mark::Mark;
use mark::Marks;
pub(crate) use spec::HEADER;
use spec::*;
#[cfg(verus_only)]
pub use spec::{
    Log, before, boundary, is_data, log_le, log_le_boundary, log_le_head, log_le_same,
    log_le_trans, lost, lost_at, next_bnd, off_at, off_mono, quiet, rec_bounds, resumes, retain_of,
    size, wf as log_wf, wf_head, wf_rec,
};
#[cfg(verus_only)]
use vstd::tokens::InstanceId;

verus! {

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecordKind {
    Bytes,
    Marker,
    Slice,
    Pad,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Pos(u64);

impl Pos {
    pub(crate) fn new(value: u64) -> Pos {
        Pos(value)
    }

    pub fn get(self) -> (r: u64)
        ensures
            r == self.v(),
    {
        self.0
    }

    pub closed spec fn v(self) -> u64 {
        self.0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Offset(u64);

impl Offset {
    pub fn new(value: u64) -> (r: Offset)
        ensures
            r.v() == value,
    {
        Offset(value)
    }

    pub fn get(self) -> (r: u64)
        ensures
            r == self.v(),
    {
        self.0
    }

    pub closed spec fn v(self) -> u64 {
        self.0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reach {
    Behind,
    At(Pos),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Record {
    pub kind: RecordKind,
    pub len: u64,
    pub offset: Offset,
    pub next: Pos,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Invalid {
    Capacity,
    Record,
    Head,
    Slice,
    Marker,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Commit {
    Refused,
    Published,
    Idle,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Slice {
    pub first: bool,
    pub last: bool,
    pub screen: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Available {
    pub room: u64,
    pub idle: bool,
}

impl RecordKind {
    fn tag(self) -> (t: u8)
        ensures
            t == tag(self),
    {
        match self {
            RecordKind::Bytes => BYTES,
            RecordKind::Marker => MARKER,
            RecordKind::Slice => SLICE,
            RecordKind::Pad => PAD,
        }
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
    spec fn counts_bytes(self) -> bool {
        self.tag == BYTES && self.off < MAX_OFFSET && self.len < MAX_LENGTH
    }

    fn bytes_end(self) -> (end: Option<u64>)
        ensures
            end.is_some() ==> self.counts_bytes() && end.unwrap() as nat == self.off as nat
                + self.len as nat,
            self.counts_bytes() ==> end.is_some(),
            !self.counts_bytes() ==> end.is_none(),
    {
        if self.tag == BYTES && self.off < MAX_OFFSET && self.len < MAX_LENGTH {
            self.off.checked_add(self.len)
        } else {
            None
        }
    }

    fn end_offset(self) -> (end: u64)
        ensures
            self.counts_bytes() ==> end as nat == self.off as nat + self.len as nat,
            !self.counts_bytes() ==> end == self.off,
    {
        match self.bytes_end() {
            Some(end) => end,
            None => self.off,
        }
    }
}

pub struct Reader {
    shared: Backend,
    tail: u64,
    seen: u64,
    settled: u64,
    settled_offset: u64,
    evicted: u64,
    #[allow(dead_code)]
    world: Tracked<World>,
    #[allow(dead_code)]
    tok: Tracked<RingSm::r>,
    #[allow(dead_code)]
    rperm: Tracked<Map<nat, ByteTok>>,
    #[allow(dead_code)]
    log_marks: Tracked<Marks>,
}

impl Reader {
    pub closed spec fn ghost(&self) -> RGhost {
        self.tok@.value()
    }

    pub closed spec fn cap(&self) -> nat {
        self.shared.cap()
    }

    pub closed spec fn wf(&self) -> bool {
        &&& self.world@.wf(self.shared)
        &&& self.tok@.instance_id() == self.world@.inst.id()
        &&& self.tail as nat == self.ghost().tail
        &&& self.seen as nat == self.ghost().log.head
        &&& boundary(self.ghost().log, self.settled as nat)
        &&& self.ghost().tail <= self.settled as nat <= self.ghost().log.head
        &&& self.settled_offset as nat == off_at(self.ghost().log, self.settled as nat)
        &&& evicted_ok(self.ghost().log, self.evicted as nat, self.ghost().tail)
        &&& dom_is(self.rperm@.dom(), self.cap(), self.ghost().tail, self.ghost().log.head)
        &&& hdr_ok(self.cap(), self.ghost().log, self.rperm@, self.ghost().tail, self.ghost().log.head)
        &&& tok_ok(self.shared.base(), self.rperm@)
        &&& self.log_marks@.wf(self.cap(), self.ghost().log)
    }

    pub closed spec fn mark_id(&self) -> InstanceId {
        self.log_marks@.id()
    }

    pub open spec fn log(&self) -> Log {
        self.ghost().log
    }

    pub open spec fn tl(&self) -> nat {
        self.ghost().tail
    }

    pub closed spec fn marks(&self) -> (u64, u64, u64) {
        (self.settled, self.settled_offset, self.evicted)
    }

    pub open spec fn visible(&self, pos: u64) -> bool {
        &&& self.ghost().tail <= pos as nat
        &&& (pos as nat) < self.ghost().log.head
        &&& self.ghost().log.m.contains_key(pos as nat)
    }

    pub open spec fn describes(&self, pos: Pos, r: Record) -> bool {
        &&& self.visible(pos.v())
        &&& r.kind == self.log().m[pos.v() as nat].kind
        &&& r.len as nat == self.log().m[pos.v() as nat].len
        &&& r.offset.v() as nat == self.log().m[pos.v() as nat].off
        &&& r.next.v() as nat == pos.v() as nat + size(self.log().m[pos.v() as nat])
    }

    pub proof fn facts(tracked &self)
        requires
            self.wf(),
        ensures
            wf(self.cap(), self.ghost().log),
            self.ghost().tail <= self.ghost().log.head <= self.ghost().tail + self.cap(),
            boundary(self.ghost().log, self.ghost().tail),
            MIN_CAPACITY as nat <= self.cap() <= MAX_CAPACITY as nat,
    {
        self.world.borrow().inst.reader_facts(self.tok.borrow());
        self.world.borrow().inst.cap_bounds();
    }

    #[cfg(not(loom))]
    pub fn create(capacity: u64) -> (r: Result<Reader, std::io::Error>)
        ensures
            r is Ok ==> r->Ok_0.wf(),
    {
        match backend::create_handle(capacity) {
            Ok(handle) => Ok(Reader::with(handle)),
            Err(e) => Err(e),
        }
    }

    fn with(handle: HandleBox) -> (r: Reader)
        ensures
            r.wf(),
    {
        let (shared, Tracked(words)) = Backend::mint_reader(handle);
        let tracked (world, _w, rtok, _data) = build(shared.cap(), shared.base(), words);
        proof {
            evicted_intro(empty_log(), 0, 0);
            hdr_ok_empty(shared.cap(), empty_log(), Map::<nat, ByteTok>::empty(), 0);
            assert(tok_ok(shared.base(), Map::<nat, ByteTok>::empty()));
            assert(dom_is(Map::<nat, ByteTok>::empty().dom(), shared.cap(), 0, 0));
        }
        proof {
            empty_wf(shared.cap());
        }
        let tracked marks = Marks::new(shared.cap(), empty_log());
        Reader {
            shared,
            tail: 0,
            seen: 0,
            settled: 0,
            settled_offset: 0,
            evicted: 0,
            world: Tracked(world),
            tok: Tracked(rtok),
            rperm: Tracked(Map::tracked_empty()),
            log_marks: Tracked(marks),
        }
    }

    pub fn mark(&self) -> (m: Tracked<Mark>)
        requires
            self.wf(),
        ensures
            m@.id() == self.mark_id(),
            m@.log() == self.log(),
    {
        Tracked(self.log_marks.borrow().mark(self.cap(), self.ghost().log))
    }

    pub proof fn bound(tracked &self, tracked m: &Mark)
        requires
            self.wf(),
            m.id() == self.mark_id(),
        ensures
            wf(self.cap(), m.log()),
            log_le(m.log(), self.log()),
    {
        self.log_marks.borrow().bound(m, self.cap(), self.ghost().log);
    }

    pub fn head(&mut self) -> (p: Pos)
        requires
            old(self).wf(),
        ensures
            final(self).mark_id() == old(self).mark_id(),
            final(self).wf(),
            final(self).cap() == old(self).cap(),
            final(self).ghost().tail == old(self).ghost().tail,
            log_le(old(self).ghost().log, final(self).ghost().log),
            p.v() as nat == final(self).ghost().log.head,
            final(self).marks() == old(self).marks(),
    {
        proof {
            self.facts();
        }
        let before = self.seen;
        let v;
        open_atomic_invariant!(&self.world.borrow().head => pair => {
            let tracked (perm, slog) = pair;
            v = self.shared.load(Index::Head, Tracked(&perm));
            proof {
                let tracked inst = &self.world.borrow().inst;
                inst.log_facts(&slog);
                let ghost cap = self.cap();
                let ghost g0 = self.ghost();
                let ghost perm0 = self.rperm@;
                let tracked (Ghost(gm), Tracked(pool)) = inst.observe(&slog, self.tok.borrow_mut());
                inst.reader_facts(self.tok.borrow());
                log_le_head(g0.log, slog.value());
                hdr_ok_log_le(cap, g0.log, slog.value(), perm0, g0.tail, g0.log.head);
                log_le_boundary(cap, g0.log, slog.value(), g0.log.head);
                hdr_ok_union(cap, slog.value(), perm0, pool, g0.tail, g0.log.head, slog.value().head);
                tok_ok_union(self.shared.base(), perm0, pool);
                self.rperm.borrow_mut().tracked_union_prefer_right(pool);
                assert forall|i: nat| self.rperm@.dom().contains(i) <==> #[trigger] in_rng(
                    cap,
                    g0.tail,
                    slog.value().head,
                    i,
                ) by {
                    rng_union(cap, g0.tail, g0.log.head, slog.value().head, i);
                }
                pair = (perm, slog);
            }
        });
        self.seen = v;
        proof {
            let ghost old_lr = old(self).ghost().log;
            self.world.borrow().inst.reader_facts(self.tok.borrow());
            log_le_head(old_lr, self.ghost().log);
            log_le_boundary(self.cap(), old_lr, self.ghost().log, self.settled as nat);
            evicted_grows(old_lr, self.ghost().log, self.evicted as nat, self.ghost().tail);
            let ghost cap = self.cap();
            let ghost log = self.ghost().log;
            self.log_marks.borrow_mut().grow(cap, old_lr, log);
        }
        debug_assert!(self.seen >= before && self.seen >= self.tail, "Ring.head");
        Pos(self.seen)
    }

    fn copy(&self, at: u64, out: &mut [u8]) -> (res: Option<()>)
        requires
            self.wf(),
        ensures
            final(out).len() == old(out).len(),
            res.is_some() ==> self.ghost().tail <= at && at as nat + final(out).len() <= self.ghost().log.head,
            (self.ghost().tail <= at && at as nat + final(out).len() <= self.ghost().log.head
                && at as nat % self.cap() + final(out).len() <= self.cap()) ==> res.is_some(),
            res.is_some() ==> forall|j: nat|
                j < final(out).len() && self.rperm@.contains_key((at as nat + j) % self.cap())
                    && #[trigger] self.rperm@[(at as nat + j) % self.cap()].val() is Some
                    ==> final(out)@[j as int] == self.rperm@[(at as nat + j) % self.cap()].val()->0,
    {
        proof {
            self.facts();
            covers_window(
                self.rperm@.dom(),
                self.cap(),
                self.ghost().tail,
                self.ghost().log.head,
                self.ghost().tail,
                self.ghost().log.head,
            );
        }
        self.shared.copy(self.tail, self.seen, at, out, Tracked(self.rperm.borrow()))
    }

    fn header(&self, pos: u64) -> (h: Option<Header>)
        requires
            self.wf(),
        ensures
            h.is_some() ==> {
                let h = h.unwrap();
                &&& BYTES <= h.tag <= PAD
                &&& self.ghost().tail <= pos
                &&& pos as nat + HEADER as nat + h.len as nat <= self.ghost().log.head
                &&& pos as nat % self.cap() + HEADER as nat + h.len as nat <= self.cap()
                &&& h.next as nat == pos as nat + HEADER as nat + h.len as nat
            },
            self.visible(pos) ==> {
                &&& h.is_some()
                &&& h.unwrap().tag == tag(self.ghost().log.m[pos as nat].kind)
                &&& h.unwrap().len as nat == self.ghost().log.m[pos as nat].len
                &&& h.unwrap().off as nat == self.ghost().log.m[pos as nat].off
            },
    {
        proof {
            self.facts();
            if self.visible(pos) {
                wf_rec(self.cap(), self.ghost().log, pos as nat);
            }
        }
        let mut bytes = [0u8; 13];
        self.copy(pos, &mut bytes)?;
        let tag_byte = bytes[0];
        let len = (bytes[1] as u64) | ((bytes[2] as u64) << 8) | ((bytes[3] as u64) << 16)
            | ((bytes[4] as u64) << 24);
        let off = (bytes[5] as u64) | ((bytes[6] as u64) << 8) | ((bytes[7] as u64) << 16)
            | ((bytes[8] as u64) << 24) | ((bytes[9] as u64) << 32) | ((bytes[10] as u64) << 40)
            | ((bytes[11] as u64) << 48) | ((bytes[12] as u64) << 56);
        proof {
            if self.visible(pos) {
                let rec = self.ghost().log.m[pos as nat];
                let cap = self.cap();
                assert forall|j: nat| j < 13 implies #[trigger] bytes@[j as int] == enc(rec, j) by {
                    rng_has(cap, self.ghost().tail, self.ghost().log.head, pos as nat + j);
                    hdr_ok_elim(
                        cap,
                        self.ghost().log,
                        self.rperm@,
                        self.ghost().tail,
                        self.ghost().log.head,
                        pos as nat,
                        j,
                    );
                }
                assert(rec.len <= self.cap());
                le4_enc(rec.len as u64);
                le8_enc(rec.off as u64);
                assert(len as nat == rec.len);
                assert(off as nat == rec.off);
            }
        }
        let next = pos.checked_add(HEADER)?.checked_add(len)?;
        let capacity = self.shared.capacity();
        let index_end = pos.checked_rem(capacity)?.checked_add(HEADER)?.checked_add(len)?;
        let ok = (BYTES..=PAD).contains(&tag_byte) && index_end <= capacity && next <= self.seen;
        if ok {
            Some(Header { tag: tag_byte, len, off, next })
        } else {
            None
        }
    }

    pub fn record(&self, pos: Pos) -> (r: Result<Record, Invalid>)
        requires
            self.wf(),
        ensures
            self.visible(pos.v()) ==> r.is_ok() && self.describes(pos, r.unwrap()),
    {
        proof {
            self.facts();
        }
        let header = match self.header(pos.0) {
            Some(h) => h,
            None => return Err(Invalid::Record),
        };
        debug_assert!(pos.0 >= self.tail && header.next <= self.seen, "Ring.header");
        let kind = if header.tag == BYTES {
            RecordKind::Bytes
        } else if header.tag == MARKER {
            RecordKind::Marker
        } else if header.tag == SLICE {
            RecordKind::Slice
        } else {
            RecordKind::Pad
        };
        Ok(Record { kind, len: header.len, offset: Offset(header.off), next: Pos(header.next) })
    }

    #[cfg(not(loom))]
    pub fn payload(&self, pos: Pos) -> (r: Result<&[u8], Invalid>)
        requires
            self.wf(),
    {
        proof {
            self.facts();
            covers_window(
                self.rperm@.dom(),
                self.cap(),
                self.ghost().tail,
                self.ghost().log.head,
                self.ghost().tail,
                self.ghost().log.head,
            );
        }
        let header = match self.header(pos.0) {
            Some(h) => h,
            None => return Err(Invalid::Record),
        };
        let at = match pos.0.checked_add(HEADER) {
            Some(at) => at,
            None => return Err(Invalid::Record),
        };
        match self.shared.bytes(self.tail, self.seen, at, header.len, Tracked(self.rperm.borrow())) {
            Some(bytes) => Ok(bytes),
            None => Err(Invalid::Record),
        }
    }

    pub fn advance(&mut self, head: Pos, keep: Pos) -> (r: Result<(), Invalid>)
        requires
            old(self).wf(),
        ensures
            final(self).mark_id() == old(self).mark_id(),
            final(self).wf(),
            final(self).ghost().log == old(self).ghost().log,
            head.v() as nat == old(self).ghost().log.head ==> r.is_ok(),
            r.is_err() ==> final(self).tl() == old(self).tl(),
            r.is_ok() ==> {
                let tl0 = old(self).ghost().tail;
                let tl1 = final(self).ghost().tail;
                let retain = retain_of(old(self).cap(), head.v() as nat, keep.v() as nat);
                &&& head.v() as nat == old(self).ghost().log.head
                &&& tl0 <= tl1 <= old(self).ghost().log.head
                &&& boundary(old(self).ghost().log, tl1)
                &&& (retain <= tl0 ==> tl1 == tl0)
                &&& (tl0 < retain ==> retain <= tl1 && forall|q: nat|
                    retain <= q < tl1 ==> !(#[trigger] old(self).ghost().log.m.contains_key(q)))
            },
    {
        proof {
            self.facts();
        }
        let before = self.tail;
        let upper = head.0;
        if upper != self.seen {
            return Err(Invalid::Head);
        }
        let capacity = self.shared.capacity();
        let retain = match upper.checked_sub(capacity / 2) {
            None => 0,
            Some(above) => if above < keep.0 { above } else { keep.0 },
        };
        let mut tail = self.tail;
        let mut last: u64 = 0;
        let mut evicted = self.evicted;
        let ghost lr = self.ghost().log;
        let ghost tl0 = self.ghost().tail;
        while tail < retain
            invariant
                self.wf(),
                self.ghost().log == lr,
                self.ghost().tail == tl0,
                retain <= upper,
                upper as nat == lr.head,
                retain as nat == retain_of(self.cap(), upper as nat, keep.v() as nat),
                boundary(lr, tail as nat),
                tl0 <= tail as nat <= lr.head,
                evicted_ok(lr, evicted as nat, tail as nat),
                tl0 < tail as nat ==> last as nat == off_at(lr, tail as nat),
                tail as nat == tl0 || forall|q: nat|
                    retain as nat <= q < tail as nat ==> !(#[trigger] lr.m.contains_key(q)),
                self.cap() == old(self).cap(),
            decreases lr.head - tail as nat,
        {
            proof {
                self.facts();
                assert(lr.m.contains_key(tail as nat));
            }
            let header = match self.header(tail) {
                Some(h) => h,
                None => return Err(Invalid::Head),
            };
            proof {
                let rec = lr.m[tail as nat];
                wf_rec(self.cap(), lr, tail as nat);
                rec_bounds(self.cap(), lr, tail as nat);
                evicted_step(self.cap(), lr, evicted as nat, tail as nat);
                assert(header.tag == tag(rec.kind));
                assert(header.next as nat == tail as nat + size(rec));
            }
            last = header.end_offset();
            if header.tag <= MARKER {
                evicted = header.next;
            }
            tail = header.next;
        }
        let ghost perm0 = self.rperm@;
        proof {
            self.facts();
            assert(dom_is(perm0.dom(), self.cap(), tl0, lr.head));
            assert(hdr_ok(self.cap(), lr, perm0, tl0, lr.head));
        }
        if self.tail < tail {
            if self.settled < tail {
                let settled_offset = if tail < upper {
                    match self.header(tail) {
                        Some(h) => h.off,
                        None => return Err(Invalid::Head),
                    }
                } else {
                    last
                };
                self.settled = tail;
                self.settled_offset = settled_offset;
            }
            open_atomic_invariant!(&self.world.borrow().tail => pair => {
                let tracked (mut perm, mut tail_tok) = pair;
                self.shared.store(Index::Tail, tail, Tracked(&mut perm));
                proof {
                    let tracked inst = &self.world.borrow().inst;
                    let ghost cap = self.cap();
                    let ghost keys = range_keys(perm0.dom(), cap, tl0, tail as nat);
                    split_dom(cap, perm0, tl0, tail as nat, lr.head);
                    hdr_ok_remove(cap, lr, perm0, tl0, tail as nat, lr.head);
                    tok_ok_remove(self.shared.base(), perm0, keys);
                    let tracked m = self.rperm.borrow_mut().tracked_remove_keys(keys);
                    inst.release(tail as nat, m, &mut tail_tok, self.tok.borrow_mut(), m);
                    pair = (perm, tail_tok);
                }
            });
            self.tail = tail;
            self.evicted = evicted;
        }
        open_atomic_invariant!(&self.world.borrow().read => pair => {
            let tracked (mut perm, mut read_tok, mut wake) = pair;
            self.shared.store(Index::Read, upper, Tracked(&mut perm));
            proof {
                let tracked inst = &self.world.borrow().inst;
                inst.set_read(upper as nat, &mut read_tok, &mut wake, self.tok.borrow_mut());
                pair = (perm, read_tok, wake);
            }
        });
        debug_assert!(
            before <= self.tail
                && self.tail <= upper
                && if retain <= before { self.tail == before } else { retain <= self.tail },
            "Ring.advance"
        );
        Ok(())
    }

    pub fn tail(&self) -> (p: Pos)
        requires
            self.wf(),
        ensures
            p.v() as nat == self.tl(),
    {
        Pos(self.tail)
    }

    pub fn seen(&self) -> (p: Pos)
        requires
            self.wf(),
        ensures
            p.v() as nat == self.log().head,
    {
        Pos(self.seen)
    }

    fn prefix(&self, pos: Pos, out: &mut [u8]) -> (r: Result<u64, Invalid>)
        requires
            self.wf(),
        ensures
            final(out).len() == old(out).len(),
    {
        let header = match self.header(pos.0) {
            Some(h) => h,
            None => return Err(Invalid::Record),
        };
        let at = match pos.0.checked_add(HEADER) {
            Some(at) => at,
            None => return Err(Invalid::Record),
        };
        let copied = if header.len < out.len() as u64 {
            header.len as usize
        } else {
            out.len()
        };
        let (head, _) = out.split_at_mut(copied);
        match self.copy(at, head) {
            Some(()) => Ok(header.len),
            None => Err(Invalid::Record),
        }
    }

    pub fn slice(&self, pos: Pos) -> (r: Result<Slice, Invalid>)
        requires
            self.wf(),
    {
        let mut bytes = [0u8; 2];
        let len = self.prefix(pos, &mut bytes)?;
        if len < 2 {
            return Err(Invalid::Slice);
        }
        Ok(Slice { first: bytes[0] & 1 != 0, last: bytes[0] & 2 != 0, screen: bytes[1] == 1 })
    }

    pub fn reachable(&self, pos: Pos) -> (r: Reach)
        requires
            self.wf(),
        ensures
            (r is Behind) <==> lost(self.ghost().log, self.ghost().tail, pos.v() as nat),
            r is At ==> r->At_0.v() == if pos.v() < self.ghost().tail {
                self.ghost().tail as u64
            } else {
                pos.v()
            },
    {
        proof {
            self.facts();
            let lr = self.ghost().log;
            reachable_iff(self.cap(), lr, self.evicted as nat, self.ghost().tail, pos.v() as nat);
        }
        if pos.0 < self.evicted {
            Reach::Behind
        } else {
            Reach::At(Pos(if pos.0 > self.tail { pos.0 } else { self.tail }))
        }
    }

    pub fn end_offset(&mut self) -> (r: Result<Offset, Invalid>)
        requires
            old(self).wf(),
        ensures
            final(self).mark_id() == old(self).mark_id(),
            final(self).wf(),
            final(self).cap() == old(self).cap(),
            final(self).ghost().tail == old(self).ghost().tail,
            log_le(old(self).ghost().log, final(self).ghost().log),
            r.is_ok(),
            r.unwrap().v() as nat == final(self).ghost().log.head_offset,
    {
        let upper = self.head().0;
        let mut settled = self.settled;
        let mut offset = self.settled_offset;
        let ghost g1 = self.ghost();
        let ghost lr = g1.log;
        proof {
            self.facts();
            wf_head(self.cap(), lr);
        }
        while settled < upper
            invariant
                self.wf(),
                self.ghost().log == lr,
                self.ghost().tail == g1.tail,
                g1.tail == old(self).ghost().tail,
                log_le(old(self).ghost().log, g1.log),
                self.cap() == old(self).cap(),
                upper as nat == lr.head,
                boundary(lr, settled as nat),
                g1.tail <= settled as nat <= lr.head,
                offset as nat == off_at(lr, settled as nat),
            decreases lr.head - settled as nat,
        {
            proof {
                self.facts();
                assert(lr.m.contains_key(settled as nat));
                assert(self.visible(settled));
            }
            let header = match self.header(settled) {
                Some(h) => h,
                None => return Err(Invalid::Record),
            };
            proof {
                let rec = lr.m[settled as nat];
                wf_rec(self.cap(), lr, settled as nat);
                rec_bounds(self.cap(), lr, settled as nat);
                assert(header.tag == tag(rec.kind));
            }
            offset = header.end_offset();
            settled = header.next;
        }
        self.settled = settled;
        self.settled_offset = offset;
        Ok(Offset(offset))
    }

    pub fn oldest_offset(&mut self) -> (r: Result<Offset, Invalid>)
        requires
            old(self).wf(),
        ensures
            final(self).mark_id() == old(self).mark_id(),
            final(self).wf(),
            final(self).cap() == old(self).cap(),
            final(self).ghost().tail == old(self).ghost().tail,
            log_le(old(self).ghost().log, final(self).ghost().log),
            r.is_ok(),
            off_at(final(self).ghost().log, final(self).ghost().tail) <= r.unwrap().v(),
    {
        let upper = self.head().0;
        if self.tail < upper {
            proof {
                self.facts();
                assert(self.visible(self.tail));
                wf_rec(self.cap(), self.ghost().log, self.tail as nat);
            }
            match self.record(Pos(self.tail)) {
                Ok(record) => Ok(record.offset),
                Err(e) => Err(e),
            }
        } else {
            let ghost g1 = self.ghost();
            proof {
                self.facts();
            }
            let r = self.end_offset();
            proof {
                log_le_trans(old(self).ghost().log, g1.log, self.ghost().log);
                self.facts();
                log_le_boundary(self.cap(), g1.log, self.ghost().log, g1.tail);
                if self.ghost().tail != self.ghost().log.head {
                    wf_rec(self.cap(), self.ghost().log, self.ghost().tail);
                }
            }
            r
        }
    }

    pub fn resume(&mut self, target: Offset) -> (r: Result<Pos, Invalid>)
        requires
            old(self).wf(),
        ensures
            final(self).mark_id() == old(self).mark_id(),
            final(self).wf(),
            final(self).cap() == old(self).cap(),
            final(self).ghost().tail == old(self).ghost().tail,
            log_le(old(self).ghost().log, final(self).ghost().log),
            r.is_ok(),
            resumes(
                final(self).ghost().tail,
                final(self).ghost().log,
                target.v() as nat,
                r.unwrap().v() as nat,
            ),
    {
        let upper = self.head().0;
        let mut pos = self.tail;
        let ghost g1 = self.ghost();
        let ghost lr = g1.log;
        proof {
            self.facts();
            wf_head(self.cap(), lr);
        }
        while pos < upper
            invariant_except_break
                self.wf(),
                self.ghost().log == lr,
                self.ghost().tail == g1.tail,
                g1.tail == old(self).ghost().tail,
                log_le(old(self).ghost().log, g1.log),
                self.cap() == old(self).cap(),
                upper as nat == lr.head,
                boundary(lr, pos as nat),
                g1.tail <= pos as nat <= lr.head,
                off_at(lr, g1.tail) <= target.v() ==> off_at(lr, pos as nat) <= target.v(),
                forall|q: nat|
                    g1.tail <= q < pos as nat && #[trigger] lr.m.contains_key(q) ==> before(
                        lr.m[q],
                        target.v() as nat,
                    ),
            ensures
                self.wf(),
                self.ghost().log == lr,
                self.ghost().tail == g1.tail,
                self.cap() == old(self).cap(),
                boundary(lr, pos as nat),
                g1.tail <= pos as nat <= lr.head,
                off_at(lr, g1.tail) <= target.v() ==> off_at(lr, pos as nat) <= target.v(),
                forall|q: nat|
                    g1.tail <= q < pos as nat && #[trigger] lr.m.contains_key(q) ==> before(
                        lr.m[q],
                        target.v() as nat,
                    ),
                (pos as nat) < lr.head ==> lr.m.contains_key(pos as nat) && !before(
                    lr.m[pos as nat],
                    target.v() as nat,
                ),
            decreases lr.head - pos as nat,
        {
            proof {
                self.facts();
                assert(lr.m.contains_key(pos as nat));
                assert(self.visible(pos));
            }
            let header = match self.header(pos) {
                Some(h) => h,
                None => return Err(Invalid::Record),
            };
            proof {
                let rec = lr.m[pos as nat];
                wf_rec(self.cap(), lr, pos as nat);
                rec_bounds(self.cap(), lr, pos as nat);
                assert(header.tag == tag(rec.kind));
            }
            let replayed = if header.tag == BYTES {
                match header.bytes_end() {
                    Some(end) => end <= target.0,
                    None => false,
                }
            } else {
                header.tag == PAD || header.off < target.0
            };
            if !replayed {
                break;
            }
            proof {
                let rec = lr.m[pos as nat];
                assert(before(rec, target.v() as nat));
                assert forall|q: nat|
                    g1.tail <= q < header.next as nat && #[trigger] lr.m.contains_key(
                        q,
                    ) implies before(lr.m[q], target.v() as nat) by {
                    if q < pos as nat {
                    } else if q == pos as nat {
                    } else {
                        assert((pos as nat) < q && q < pos as nat + size(rec));
                    }
                }
            }
            pos = header.next;
        }
        debug_assert!(self.tail <= pos && pos <= self.seen, "Ring.resume");
        Ok(Pos(pos))
    }
}

pub struct Writer {
    shared: Backend,
    head: u64,
    woff: u64,
    tail: u64,
    #[allow(dead_code)]
    world: Tracked<World>,
    #[allow(dead_code)]
    tok: Tracked<RingSm::w>,
    #[allow(dead_code)]
    wperm: Tracked<Map<nat, ByteTok>>,
}

impl Writer {
    pub closed spec fn ghost(&self) -> WGhost {
        self.tok@.value()
    }

    pub closed spec fn cap(&self) -> nat {
        self.shared.cap()
    }

    pub closed spec fn wf(&self) -> bool {
        &&& self.world@.wf(self.shared)
        &&& self.tok@.instance_id() == self.world@.inst.id()
        &&& self.head as nat == self.ghost().log.head
        &&& self.woff as nat == self.ghost().log.head_offset
        &&& self.tail as nat == self.ghost().tail
        &&& self.ghost().pend is None
        &&& dom_is(self.wperm@.dom(), self.cap(), self.ghost().log.head, self.ghost().tail + self.cap())
        &&& tok_ok(self.shared.base(), self.wperm@)
    }

    pub closed spec fn same_as(&self, other: &Writer) -> bool {
        &&& self.ghost() == other.ghost()
        &&& self.head == other.head
        &&& self.woff == other.woff
        &&& self.tail == other.tail
    }

    proof fn facts(tracked &self)
        requires
            self.wf(),
        ensures
            self.ghost().log.head % self.cap() + HEADER as nat <= self.cap(),
            self.ghost().log.head <= MAX_POS as nat,
            self.ghost().log.head_offset <= self.ghost().log.head,
            self.ghost().tail <= self.ghost().log.head <= self.ghost().tail + self.cap(),
            wf(self.cap(), self.ghost().log),
            MIN_CAPACITY as nat <= self.cap() <= MAX_CAPACITY as nat,
    {
        self.world.borrow().inst.writer_facts(self.tok.borrow());
        self.world.borrow().inst.cap_bounds();
    }

    fn with(handle: HandleBox) -> (w: Writer)
        ensures
            w.wf(),
    {
        let (shared, Tracked(words)) = Backend::mint_writer(handle);
        let tracked (world, wtok, _r, data) = build(shared.cap(), shared.base(), words);
        Writer {
            shared,
            head: 0,
            woff: 0,
            tail: 0,
            world: Tracked(world),
            tok: Tracked(wtok),
            wperm: Tracked(data),
        }
    }

    fn fits(&self, len: u64) -> (r: Option<u64>)
        requires
            self.wf(),
        ensures
            r.is_some() <==> fits_ok(self.cap(), self.ghost().log.head, self.ghost().tail, len as nat),
            r.is_some() ==> r.unwrap() as nat == self.ghost().log.head + HEADER as nat + len as nat,
    {
        proof {
            self.facts();
        }
        let capacity = self.shared.capacity();
        let end = self.head.checked_rem(capacity)?.checked_add(HEADER)?.checked_add(len)?;
        let next = self.head.checked_add(HEADER)?.checked_add(len)?;
        if len > capacity || end > capacity {
            return None;
        }
        if end != capacity && end.checked_add(HEADER)? > capacity {
            return None;
        }
        if next > self.tail.checked_add(capacity)? || next > MAX_HEAD {
            return None;
        }
        Some(next)
    }

    fn commit(&mut self, kind: RecordKind, len: u64) -> (r: Commit)
        requires
            old(self).wf(),
        ensures
            final(self).wf(),
            final(self).cap() == old(self).cap(),
            (r is Refused) <==> !fits_ok(
                old(self).cap(),
                old(self).ghost().log.head,
                old(self).ghost().tail,
                len as nat,
            ),
            (r is Refused) ==> final(self).same_as(old(self)),
            !(r is Refused) ==> committed(old(self).ghost(), final(self).ghost(), kind, len as nat, r is Idle),
    {
        proof {
            self.facts();
        }
        let next = match self.fits(len) {
            Some(next) => next,
            None => return Commit::Refused,
        };
        let woff = match kind {
            RecordKind::Bytes => match self.woff.checked_add(len) {
                Some(woff) => woff,
                None => {
                    proof {
                        assert(false);
                    }
                    return Commit::Refused;
                },
            },
            _ => self.woff,
        };
        let header = [
            kind.tag(),
            len as u8,
            (len >> 8) as u8,
            (len >> 16) as u8,
            (len >> 24) as u8,
            self.woff as u8,
            (self.woff >> 8) as u8,
            (self.woff >> 16) as u8,
            (self.woff >> 24) as u8,
            (self.woff >> 32) as u8,
            (self.woff >> 40) as u8,
            (self.woff >> 48) as u8,
            (self.woff >> 56) as u8,
        ];
        let ghost w0 = self.ghost();
        let ghost cap = self.cap();
        let ghost rec = Rec { kind, len: len as nat, off: w0.log.head_offset };
        proof {
            assert(forall|j: nat| j < 13 ==> #[trigger] header@[j as int] == enc(rec, j));
            covers_window(
                self.wperm@.dom(),
                cap,
                w0.log.head,
                w0.tail + cap,
                w0.log.head,
                w0.log.head + HEADER as nat,
            );
            payload_fits(cap, w0.log.head, 0);
        }
        match self.shared.write(self.head, &header, Tracked(self.wperm.borrow_mut())) {
            Some(_) => {},
            None => {
                proof {
                    assert(false);
                }
                return Commit::Refused;
            },
        }
        let head = self.head;
        let ghost nhd = w0.log.head + HEADER as nat + len as nat;
        open_atomic_invariant!(&self.world.borrow().head => pair => {
            let tracked (mut perm, mut slog) = pair;
            self.shared.store(Index::Head, next, Tracked(&mut perm));
            proof {
                let tracked inst = &self.world.borrow().inst;
                let ghost perm0 = self.wperm@;
                let ghost keys = range_keys(perm0.dom(), cap, w0.log.head, nhd);
                split_dom(cap, perm0, w0.log.head, nhd, w0.tail + cap);
                tok_ok_remove(self.shared.base(), perm0, keys);
                let tracked m = self.wperm.borrow_mut().tracked_remove_keys(keys);
                assert(fits_ok(cap, w0.log.head, w0.tail, len as nat));
                assert(dom_is(m.dom(), cap, w0.log.head, nhd));
                assert forall|j: nat| j < 13 implies #[trigger] m.contains_key((w0.log.head + j) % cap)
                    && m[(w0.log.head + j) % cap].val() == Some(enc(rec, j)) by {
                    rng_has(cap, w0.log.head, nhd, w0.log.head + j);
                    map_facts(perm0, keys, (w0.log.head + j) % cap);
                }
                assert(staged(cap, m, w0.log.head, rec));
                inst.publish(kind, len as nat, m, &mut slog, self.tok.borrow_mut(), m);
                pair = (perm, slog);
            }
        });
        let read;
        open_atomic_invariant!(&self.world.borrow().read => pair => {
            let tracked (perm, read_tok, mut wake) = pair;
            read = self.shared.load(Index::Read, Tracked(&perm));
            proof {
                let tracked inst = &self.world.borrow().inst;
                inst.check_read(read as nat, &read_tok, &mut wake, self.tok.borrow_mut());
                pair = (perm, read_tok, wake);
            }
        });
        self.woff = woff;
        self.head = next;
        proof {
            assert(self.ghost().log.head == w0.log.head + HEADER as nat + len as nat);
            assert(self.ghost().tail == w0.tail);
            assert(self.ghost().log.head_offset == w0.log.head_offset + if kind == RecordKind::Bytes {
                len as nat
            } else {
                0nat
            });
            assert(self.ghost().log == extend(w0.log, rec));
            assert(self.ghost().read == read as nat);
        }
        if read == head {
            Commit::Idle
        } else {
            Commit::Published
        }
    }

    pub fn available(&mut self) -> (a: Available)
        requires
            old(self).wf(),
        ensures
            final(self).wf(),
            final(self).ghost().log == old(self).ghost().log || final(self).ghost().log == extend(
                old(self).ghost().log,
                Rec {
                    kind: RecordKind::Pad,
                    len: (old(self).cap() - old(self).ghost().log.head % old(self).cap()
                        - HEADER as nat) as nat,
                    off: old(self).ghost().log.head_offset,
                },
            ),
            a.room > 0 ==> forall|n: nat|
                n <= a.room && final(self).ghost().log.head + HEADER as nat + n <= MAX_HEAD as nat
                    ==> #[trigger] fits_ok(
                    final(self).cap(),
                    final(self).ghost().log.head,
                    final(self).ghost().tail,
                    n,
                ),
    {
        let t;
        open_atomic_invariant!(&self.world.borrow().tail => pair => {
            let tracked (perm, tail_tok) = pair;
            t = self.shared.load(Index::Tail, Tracked(&perm));
            proof {
                let tracked inst = &self.world.borrow().inst;
                let ghost cap = self.cap();
                let ghost w0 = self.ghost();
                self.facts();
                let tracked (Ghost(gm), Tracked(pool)) = inst.load_tail(&tail_tok, self.tok.borrow_mut());
                assert(w0.tail <= tail_tok.value());
                let ghost perm0 = self.wperm@;
                tok_ok_union(self.shared.base(), perm0, pool);
                self.wperm.borrow_mut().tracked_union_prefer_right(pool);
                assert forall|i: nat| self.wperm@.dom().contains(i) <==> #[trigger] in_rng(
                    cap,
                    w0.log.head,
                    tail_tok.value() + cap,
                    i,
                ) by {
                    rng_union(cap, w0.log.head, w0.tail + cap, tail_tok.value() + cap, i);
                }
                pair = (perm, tail_tok);
            }
        });
        self.tail = t;
        match self.room() {
            Some(available) => available,
            None => Available { room: 0, idle: false },
        }
    }

    fn room(&mut self) -> (r: Option<Available>)
        requires
            old(self).wf(),
        ensures
            final(self).wf(),
            final(self).ghost().log == old(self).ghost().log || final(self).ghost().log == extend(
                old(self).ghost().log,
                Rec {
                    kind: RecordKind::Pad,
                    len: (old(self).cap() - old(self).ghost().log.head % old(self).cap()
                        - HEADER as nat) as nat,
                    off: old(self).ghost().log.head_offset,
                },
            ),
            r.is_some() && r.unwrap().room > 0 ==> forall|n: nat|
                n <= r.unwrap().room && final(self).ghost().log.head + HEADER as nat + n
                    <= MAX_HEAD as nat ==> #[trigger] fits_ok(
                    final(self).cap(),
                    final(self).ghost().log.head,
                    final(self).ghost().tail,
                    n,
                ),
    {
        if self.head >= MAX_HEAD {
            return None;
        }
        proof {
            self.facts();
        }
        let capacity = self.shared.capacity();
        let free = capacity.checked_sub(self.head.checked_sub(self.tail)?)?;
        let end = capacity.checked_sub(self.head.checked_rem(capacity)?)?;
        if end > PAD_ROOM {
            return Some(Available {
                room: (if free < end { free } else { end }).saturating_sub(PAD_ROOM),
                idle: false,
            });
        }
        if free < end {
            return None;
        }
        let ghost w0 = self.ghost();
        let committed = self.commit(RecordKind::Pad, end.checked_sub(HEADER)?);
        let idle = match committed {
            Commit::Refused => return None,
            Commit::Idle => true,
            Commit::Published => false,
        };
        proof {
            self.facts();
            mod_step(self.cap(), w0.log.head, end as nat);
        }
        let remaining = free.checked_sub(end)?;
        Some(Available {
            room: (if remaining < capacity { remaining } else { capacity })
                .saturating_sub(PAD_ROOM),
            idle,
        })
    }

    #[cfg(not(loom))]
    pub fn payload(&mut self, len: usize) -> (r: Option<&mut [u8]>)
        requires
            old(self).wf(),
        ensures
            final(self).wf(),
            final(self).same_as(old(self)),
            r.is_some() <==> fits_ok(
                old(self).cap(),
                old(self).ghost().log.head,
                old(self).ghost().tail,
                len as nat,
            ),
    {
        proof {
            self.facts();
        }
        let len64 = len as u64;
        self.fits(len64)?;
        let at = self.head.checked_add(HEADER)?;
        proof {
            payload_fits(self.cap(), self.ghost().log.head, len64 as nat);
            covers_window(
                self.wperm@.dom(),
                self.cap(),
                self.ghost().log.head,
                self.ghost().tail + self.cap(),
                at as nat,
                at as nat + len as nat,
            );
        }
        self.shared.room(at, len, Tracked(self.wperm.borrow_mut()))
    }

    pub fn publish(&mut self, kind: RecordKind, len: usize) -> (c: Commit)
        requires
            old(self).wf(),
        ensures
            final(self).wf(),
            (c is Refused) <==> !fits_ok(
                old(self).cap(),
                old(self).ghost().log.head,
                old(self).ghost().tail,
                len as nat,
            ),
            (c is Refused) ==> final(self).same_as(old(self)),
            !(c is Refused) ==> committed(old(self).ghost(), final(self).ghost(), kind, len as nat, c is Idle),
    {
        self.commit(kind, len as u64)
    }

    pub fn put(&mut self, kind: RecordKind, payload: &[u8]) -> (c: Commit)
        requires
            old(self).wf(),
        ensures
            final(self).wf(),
            (c is Refused) <==> !fits_ok(
                old(self).cap(),
                old(self).ghost().log.head,
                old(self).ghost().tail,
                payload.len() as nat,
            ),
            (c is Refused) ==> final(self).same_as(old(self)),
            !(c is Refused) ==> committed(
                old(self).ghost(),
                final(self).ghost(),
                kind,
                payload.len() as nat,
                c is Idle,
            ),
    {
        proof {
            self.facts();
        }
        let len = payload.len() as u64;
        if self.fits(len).is_none() {
            return Commit::Refused;
        }
        let at = match self.head.checked_add(HEADER) {
            Some(at) => at,
            None => {
                proof {
                    assert(false);
                }
                return Commit::Refused;
            },
        };
        proof {
            payload_fits(self.cap(), self.ghost().log.head, len as nat);
            covers_window(
                self.wperm@.dom(),
                self.cap(),
                self.ghost().log.head,
                self.ghost().tail + self.cap(),
                at as nat,
                at as nat + len as nat,
            );
        }
        match self.shared.write(at, payload, Tracked(self.wperm.borrow_mut())) {
            Some(_) => {},
            None => {
                proof {
                    assert(false);
                }
                return Commit::Refused;
            },
        }
        self.commit(kind, len)
    }
}

} // verus!

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Marker {
    Resize(Size),
    Dead(Dead),
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

impl fmt::Debug for Reader {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Reader")
            .field("tail", &self.tail)
            .field("seen", &self.seen)
            .field("settled", &self.settled)
            .field("evicted", &self.evicted)
            .finish_non_exhaustive()
    }
}

impl fmt::Debug for Writer {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Writer")
            .field("head", &self.head)
            .field("woff", &self.woff)
            .field("tail", &self.tail)
            .finish_non_exhaustive()
    }
}

impl Reader {
    #[cfg(loom)]
    fn attach(handle: Handle) -> Reader {
        Reader::with(HandleBox::new(handle))
    }

    #[cfg(not(loom))]
    pub fn fd(&self) -> BorrowedFd<'_> {
        self.shared.fd()
    }

    #[cfg(not(loom))]
    pub fn writer(&self) -> io::Result<Writer> {
        self.shared.duplicate().map(Writer::attach)
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
}

impl Writer {
    fn attach(handle: Handle) -> Writer {
        Writer::with(HandleBox::new(handle))
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

    pub fn put_marker(&mut self, marker: Marker) -> Commit {
        let (bytes, len) = marker.encode();
        self.put(RecordKind::Marker, bytes.get(..len).unwrap_or_default())
    }

    pub fn put_slice(&mut self, slice: Slice) -> Commit {
        self.put(RecordKind::Slice, &slice.encode())
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
