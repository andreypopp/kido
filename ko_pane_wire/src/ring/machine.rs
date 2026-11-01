#![allow(dead_code, non_snake_case, unreachable_pub)]

use verus_state_machines_macros::tokenized_state_machine;
use vstd::prelude::*;

use vstd::invariant::{AtomicInvariant, InvariantPredicate};
use vstd::raw_ptr::PointsTo;

use super::RecordKind;
use super::backend::ByteTok;
#[cfg(verus_only)]
use super::backend::{Backend, Index, Words, dom_is, in_rng, tok_ok};
#[cfg(verus_only)]
use super::backend::{MAX_CAPACITY, MIN_CAPACITY};
use super::spec::*;

verus! {

pub ghost struct WGhost {
    pub tail: nat,
    pub pend: Option<nat>,
    pub log: Log,
    pub read: nat,
}

pub ghost struct RGhost {
    pub tail: nat,
    pub log: Log,
    pub stored: bool,
}

pub ghost struct WordK {
    pub inst: RingSm::Instance,
    pub ptr: *mut u64,
}

pub struct HeadPred;

pub struct TailPred;

pub struct ReadPred;

impl InvariantPredicate<WordK, (PointsTo<u64>, RingSm::slog)> for HeadPred {
    open spec fn inv(k: WordK, v: (PointsTo<u64>, RingSm::slog)) -> bool {
        let (perm, slog) = v;
        &&& perm.ptr() == k.ptr
        &&& perm.is_init()
        &&& slog.instance_id() == k.inst.id()
        &&& perm.value() as nat == slog.value().head
    }
}

impl InvariantPredicate<WordK, (PointsTo<u64>, RingSm::tail)> for TailPred {
    open spec fn inv(k: WordK, v: (PointsTo<u64>, RingSm::tail)) -> bool {
        let (perm, tail) = v;
        &&& perm.ptr() == k.ptr
        &&& perm.is_init()
        &&& tail.instance_id() == k.inst.id()
        &&& perm.value() as nat == tail.value()
    }
}

impl InvariantPredicate<WordK, (PointsTo<u64>, RingSm::read, RingSm::wake)> for ReadPred {
    open spec fn inv(k: WordK, v: (PointsTo<u64>, RingSm::read, RingSm::wake)) -> bool {
        let (perm, read, wake) = v;
        &&& perm.ptr() == k.ptr
        &&& perm.is_init()
        &&& read.instance_id() == k.inst.id()
        &&& wake.instance_id() == k.inst.id()
        &&& perm.value() as nat == read.value()
    }
}

pub tracked struct World {
    pub inst: RingSm::Instance,
    pub head: AtomicInvariant<WordK, (PointsTo<u64>, RingSm::slog), HeadPred>,
    pub tail: AtomicInvariant<WordK, (PointsTo<u64>, RingSm::tail), TailPred>,
    pub read: AtomicInvariant<WordK, (PointsTo<u64>, RingSm::read, RingSm::wake), ReadPred>,
}

impl World {
    pub open spec fn wf(self, ring: Backend) -> bool {
        &&& self.inst.cap() == ring.cap()
        &&& self.inst.base() == ring.base()
        &&& self.head.constant() == WordK { inst: self.inst, ptr: ring.word(Index::Head) }
        &&& self.tail.constant() == WordK { inst: self.inst, ptr: ring.word(Index::Tail) }
        &&& self.read.constant() == WordK { inst: self.inst, ptr: ring.word(Index::Read) }
    }
}


pub open spec fn committed(
    w0: WGhost,
    w1: WGhost,
    kind: RecordKind,
    len: nat,
    idle: bool,
) -> bool {
    &&& w1.log == extend(w0.log, Rec { kind, len, off: w0.log.head_offset })
    &&& w1.tail == w0.tail
    &&& (idle <==> w1.read == w0.log.head)
}

tokenized_state_machine!{
    RingSm {
        fields {
            #[sharding(constant)]
            pub cap: nat,
            #[sharding(constant)]
            pub base: nat,
            #[sharding(variable)]
            pub slog: Log,
            #[sharding(variable)]
            pub tail: nat,
            #[sharding(variable)]
            pub read: nat,
            #[sharding(variable)]
            pub wake: bool,
            #[sharding(variable)]
            pub w: WGhost,
            #[sharding(variable)]
            pub r: RGhost,
            #[sharding(storage_map)]
            pub published: Map<nat, ByteTok>,
            #[sharding(storage_map)]
            pub released: Map<nat, ByteTok>,
        }

        #[invariant]
        pub fn capacity(&self) -> bool {
            MIN_CAPACITY as nat <= self.cap <= MAX_CAPACITY as nat
        }

        #[invariant]
        pub fn logs(&self) -> bool {
            &&& wf(self.cap, self.slog)
            &&& wf(self.cap, self.r.log)
            &&& log_le(self.r.log, self.slog)
        }

        #[invariant]
        pub fn windows(&self) -> bool {
            &&& self.w.tail <= self.r.tail
            &&& self.r.tail <= self.r.log.head
            &&& self.slog.head <= self.w.tail + self.cap
            &&& boundary(self.r.log, self.r.tail)
            &&& self.tail == self.r.tail
            &&& self.read <= self.r.log.head
        }

        #[invariant]
        pub fn writer_log(&self) -> bool {
            self.w.log == self.slog
        }

        #[invariant]
        pub fn pools(&self) -> bool {
            &&& dom_is(self.published.dom(), self.cap, self.r.log.head, self.slog.head)
            &&& dom_is(self.released.dom(), self.cap, self.w.tail + self.cap, self.r.tail + self.cap)
            &&& hdr_ok(self.cap, self.slog, self.published, self.r.log.head, self.slog.head)
            &&& tok_ok(self.base, self.published)
            &&& tok_ok(self.base, self.released)
        }

        #[invariant]
        pub fn no_lost_wakeup(&self) -> bool {
            (!self.r.stored && self.read == self.r.log.head && self.slog.head > self.r.log.head)
                ==> (self.wake || self.w.pend == Some(self.read))
        }

        init!{
            initialize(cap: nat, base: nat) {
                require(MIN_CAPACITY as nat <= cap <= MAX_CAPACITY as nat);
                init cap = cap;
                init base = base;
                init slog = empty_log();
                init tail = 0;
                init read = 0;
                init wake = false;
                init w = WGhost { tail: 0, pend: None, log: empty_log(), read: 0 };
                init published = Map::empty();
                init released = Map::empty();
                init r = RGhost { tail: 0, log: empty_log(), stored: false };
            }
        }

        transition!{
            publish(kind: RecordKind, n: nat, m: Map<nat, ByteTok>) {
                assert(pre.w.log == pre.slog);
                require(pre.w.pend is None);
                require(fits_ok(pre.cap, pre.w.log.head, pre.w.tail, n));
                require(tok_ok(pre.base, m));
                require(staged(pre.cap, m, pre.w.log.head, Rec { kind, len: n, off: pre.w.log.head_offset }));
                deposit published += (m) by {
                    log_le_head(pre.r.log, pre.slog);
                    assert forall|i: nat| !(pre.published.dom().contains(i) && #[trigger] m.dom().contains(i)) by {
                        rng_disjoint(
                            pre.cap,
                            pre.r.log.head,
                            pre.w.log.head,
                            pre.w.log.head + HEADER as nat + n,
                            i,
                        );
                    }
                };
                update slog = extend(pre.slog, Rec { kind, len: n, off: pre.slog.head_offset });
                update w = WGhost {
                    tail: pre.w.tail,
                    pend: Some(pre.w.log.head),
                    log: extend(pre.slog, Rec { kind, len: n, off: pre.slog.head_offset }),
                    read: pre.w.read,
                };
            }
        }

        transition!{
            check_read(value: nat) {
                require(pre.w.pend is Some);
                require(pre.read == value);
                update wake = pre.wake || value == pre.w.pend->0;
                update w = WGhost { pend: None, read: value, ..pre.w };
            }
        }

        transition!{
            load_tail() {
                birds_eye let m = pre.released;
                withdraw released -= (m);
                assert(dom_is(m.dom(), pre.cap, pre.w.tail + pre.cap, pre.tail + pre.cap));
                assert(tok_ok(pre.base, m));
                assert(pre.w.tail <= pre.tail);
                update w = WGhost { tail: pre.tail, ..pre.w };
            }
        }

        transition!{
            observe() {
                birds_eye let m = pre.published;
                withdraw published -= (m);
                assert(dom_is(m.dom(), pre.cap, pre.r.log.head, pre.slog.head));
                assert(tok_ok(pre.base, m));
                assert(hdr_ok(pre.cap, pre.slog, m, pre.r.log.head, pre.slog.head));
                assert(log_le(pre.r.log, pre.slog));
                assert(wf(pre.cap, pre.slog));
                assert(wf(pre.cap, pre.r.log));
                update r = RGhost { tail: pre.r.tail, log: pre.slog, stored: false };
            }
        }

        transition!{
            release(nt: nat, m: Map<nat, ByteTok>) {
                require(pre.r.tail <= nt <= pre.r.log.head);
                require(boundary(pre.r.log, nt));
                require(dom_is(m.dom(), pre.cap, pre.r.tail, nt));
                require(tok_ok(pre.base, m));
                deposit released += (m) by {
                    log_le_head(pre.r.log, pre.slog);
                    assert forall|i: nat| !(pre.released.dom().contains(i) && #[trigger] m.dom().contains(i)) by {
                        rng_shift(pre.cap, pre.r.tail, nt, i);
                        rng_disjoint(
                            pre.cap,
                            pre.w.tail + pre.cap,
                            pre.r.tail + pre.cap,
                            nt + pre.cap,
                            i,
                        );
                    }
                };
                update tail = nt;
                update r = RGhost { tail: nt, ..pre.r };
            }
        }

        transition!{
            set_read(upper: nat) {
                require(upper == pre.r.log.head);
                update read = upper;
                update wake = false;
                update r = RGhost { stored: true, ..pre.r };
            }
        }

        property!{
            cap_bounds() {
                assert(MIN_CAPACITY as nat <= pre.cap <= MAX_CAPACITY as nat);
            }
        }

        property!{
            reader_facts() {
                assert(wf(pre.cap, pre.r.log));
                assert(pre.r.tail <= pre.r.log.head);
                assert(pre.r.log.head <= pre.r.tail + pre.cap) by {
                    log_le_head(pre.r.log, pre.slog);
                };
                assert(boundary(pre.r.log, pre.r.tail));
            }
        }

        property!{
            log_facts() {
                assert(wf(pre.cap, pre.slog));
            }
        }

        property!{
            writer_facts() {
                assert(pre.w.log.head % pre.cap + HEADER as nat <= pre.cap) by {
                    wf_head(pre.cap, pre.slog);
                };
                assert(pre.w.log.head <= MAX_POS as nat) by {
                    wf_head(pre.cap, pre.slog);
                };
                assert(pre.w.log.head_offset <= pre.w.log.head) by {
                    wf_head(pre.cap, pre.slog);
                };
                assert(pre.w.tail <= pre.w.log.head) by {
                    log_le_head(pre.r.log, pre.slog);
                };
                assert(pre.w.log.head <= pre.w.tail + pre.cap);
                assert(wf(pre.cap, pre.w.log));
            }
        }

        #[inductive(initialize)]
        fn initialize_inductive(post: Self, cap: nat, base: nat) {
            empty_wf(cap);
            log_le_refl(empty_log());
            assert(tok_ok(base, post.published));
            assert(tok_ok(base, post.released));
            assert forall|i: nat| !post.published.dom().contains(i) by {}
            assert forall|i: nat| !post.released.dom().contains(i) by {}
            assert forall|i: nat| #[trigger] in_rng(cap, 0, 0, i) == false by {
                rng_empty(cap, 0, i);
            }
            assert forall|i: nat| #[trigger] in_rng(cap, 0 + cap, 0 + cap, i) == false by {
                rng_empty(cap, cap, i);
            }
            hdr_ok_empty(cap, empty_log(), post.published, 0);
        }

        #[inductive(publish)]
        fn publish_inductive(
            pre: Self,
            post: Self,
            kind: RecordKind,
            n: nat,
            m: Map<nat, ByteTok>,
        ) {
            let rec = Rec { kind, len: n, off: pre.slog.head_offset };
            mod_step(pre.cap, pre.slog.head, HEADER as nat + n);
            wf_head(pre.cap, pre.slog);
            log_le_head(pre.r.log, pre.slog);
            extend_wf(pre.cap, pre.slog, rec);
            log_le_trans(pre.r.log, pre.slog, post.slog);
            let head = pre.slog.head;
            let nhd = head + HEADER as nat + n;
            assert forall|i: nat| post.published.dom().contains(i) <==> #[trigger] in_rng(
                pre.cap,
                pre.r.log.head,
                nhd,
                i,
            ) by {
                rng_union(pre.cap, pre.r.log.head, head, nhd, i);
            }
            hdr_ok_log_le(pre.cap, pre.slog, post.slog, pre.published, pre.r.log.head, head);
            reveal(hdr_ok);
            assert forall|p: nat, j: nat|
                head <= p < nhd && post.slog.m.contains_key(p) && j < 13
                    && #[trigger] m.contains_key((p + j) % pre.cap)
                    implies m[(p + j) % pre.cap].val() == Some(enc(post.slog.m[p], j)) by {
                if p != head {
                    wf_head(pre.cap, pre.slog);
                    assert(pre.slog.m.contains_key(p));
                    wf_rec(pre.cap, pre.slog, p);
                }
            }
            assert(post.slog.m.contains_key(head));
            hdr_ok_union(pre.cap, post.slog, pre.published, m, pre.r.log.head, head, nhd);
            tok_ok_union(pre.base, pre.published, m);
        }

        #[inductive(check_read)]
        fn check_read_inductive(pre: Self, post: Self, value: nat) {
        }

        #[inductive(load_tail)]
        fn load_tail_inductive(pre: Self, post: Self) {
            assert forall|i: nat| !post.released.dom().contains(i) by {}
            assert forall|i: nat| #[trigger] in_rng(pre.cap, pre.r.tail + pre.cap, pre.r.tail + pre.cap, i)
                == false by {
                rng_empty(pre.cap, pre.r.tail + pre.cap, i);
            }
            tok_ok_remove(pre.base, pre.released, pre.released.dom());
        }

        #[inductive(observe)]
        fn observe_inductive(pre: Self, post: Self) {
            assert forall|i: nat| !post.published.dom().contains(i) by {}
            assert forall|i: nat| #[trigger] in_rng(pre.cap, pre.slog.head, pre.slog.head, i) == false by {
                rng_empty(pre.cap, pre.slog.head, i);
            }
            hdr_ok_empty(pre.cap, pre.slog, post.published, pre.slog.head);
            tok_ok_remove(pre.base, pre.published, pre.published.dom());
            log_le_refl(pre.slog);
            log_le_head(pre.r.log, pre.slog);
            log_le_boundary(pre.cap, pre.r.log, pre.slog, pre.r.tail);
        }

        #[inductive(release)]
        fn release_inductive(pre: Self, post: Self, nt: nat, m: Map<nat, ByteTok>) {
            log_le_head(pre.r.log, pre.slog);
            assert forall|i: nat| post.released.dom().contains(i) <==> #[trigger] in_rng(
                pre.cap,
                pre.w.tail + pre.cap,
                nt + pre.cap,
                i,
            ) by {
                rng_shift(pre.cap, pre.r.tail, nt, i);
                rng_union(pre.cap, pre.w.tail + pre.cap, pre.r.tail + pre.cap, nt + pre.cap, i);
            }
            tok_ok_union(pre.base, pre.released, m);
        }

        #[inductive(set_read)]
        fn set_read_inductive(pre: Self, post: Self, upper: nat) {
        }
    }
}

proof fn idle_reader_is_woken(tracked m1: Map<nat, ByteTok>, tracked m2: Map<nat, ByteTok>)
    requires
        tok_ok(0, m1),
        tok_ok(0, m2),
        staged(64, m1, 0, Rec { kind: RecordKind::Bytes, len: 3, off: 0 }),
        staged(64, m2, 16, Rec { kind: RecordKind::Bytes, len: 3, off: 3 }),
{
    let tracked (
        Tracked(inst),
        Tracked(mut slog),
        Tracked(tail),
        Tracked(mut read),
        Tracked(mut wake),
        Tracked(mut w),
        Tracked(mut r),
    ) = RingSm::Instance::initialize(64, 0, Map::tracked_empty(), Map::tracked_empty());
    inst.publish(RecordKind::Bytes, 3, m1, &mut slog, &mut w, m1);
    inst.check_read(0, &read, &mut wake, &mut w);
    assert(wake.value());
    inst.observe(&slog, &mut r);
    assert(r.value().log.head == 16);
    inst.set_read(16, &mut read, &mut wake, &mut r);
    assert(!wake.value());
    inst.observe(&slog, &mut r);
    inst.publish(RecordKind::Bytes, 3, m2, &mut slog, &mut w, m2);
    assert(slog.value().head == 32);
    assert(w.value().pend == Some(16nat));
    inst.check_read(16, &read, &mut wake, &mut w);
    assert(wake.value());
}

proof fn published_is_seen(tracked m1: Map<nat, ByteTok>, tracked m2: Map<nat, ByteTok>)
    requires
        tok_ok(0, m1),
        tok_ok(0, m2),
        staged(64, m1, 0, Rec { kind: RecordKind::Bytes, len: 3, off: 0 }),
        staged(64, m2, 16, Rec { kind: RecordKind::Bytes, len: 3, off: 3 }),
{
    let tracked (
        Tracked(inst),
        Tracked(mut slog),
        Tracked(tail),
        Tracked(mut read),
        Tracked(mut wake),
        Tracked(mut w),
        Tracked(mut r),
    ) = RingSm::Instance::initialize(64, 0, Map::tracked_empty(), Map::tracked_empty());
    inst.publish(RecordKind::Bytes, 3, m1, &mut slog, &mut w, m1);
    inst.check_read(0, &read, &mut wake, &mut w);
    inst.publish(RecordKind::Bytes, 3, m2, &mut slog, &mut w, m2);
    inst.check_read(0, &read, &mut wake, &mut w);
    assert(read.value() != 16);
    inst.set_read(0, &mut read, &mut wake, &mut r);
    inst.observe(&slog, &mut r);
    assert(r.value().log.head == 32);
}

pub proof fn build(cap: nat, base: nat, tracked words: Words) -> (tracked out: (
    World,
    RingSm::w,
    RingSm::r,
    Map<nat, ByteTok>,
))
    requires
        MIN_CAPACITY <= cap <= MAX_CAPACITY,
        words.head.is_init() && words.head.value() == 0,
        words.tail.is_init() && words.tail.value() == 0,
        words.read.is_init() && words.read.value() == 0,
    ensures
        out.0.inst.cap() == cap,
        out.0.inst.base() == base,
        out.1.instance_id() == out.0.inst.id(),
        out.2.instance_id() == out.0.inst.id(),
        out.1.value() == (WGhost {
            tail: 0,
            pend: None,
            log: empty_log(),
            read: 0,
        }),
        out.2.value() == (RGhost { tail: 0, log: empty_log(), stored: false }),
        out.0.head.constant() == (WordK { inst: out.0.inst, ptr: words.head.ptr() }),
        out.0.tail.constant() == (WordK { inst: out.0.inst, ptr: words.tail.ptr() }),
        out.0.read.constant() == (WordK { inst: out.0.inst, ptr: words.read.ptr() }),
        out.3 == words.data,
{
    let tracked (
        Tracked(inst),
        Tracked(slog),
        Tracked(tail),
        Tracked(read),
        Tracked(wake),
        Tracked(w),
        Tracked(r),
    ) = RingSm::Instance::initialize(cap, base, Map::tracked_empty(), Map::tracked_empty());
    let tracked Words { head: head_perm, tail: tail_perm, read: read_perm, data } = words;
    let tracked head = AtomicInvariant::new(
        WordK { inst, ptr: head_perm.ptr() },
        (head_perm, slog),
        0,
    );
    let tracked tail = AtomicInvariant::new(
        WordK { inst, ptr: tail_perm.ptr() },
        (tail_perm, tail),
        1,
    );
    let tracked read = AtomicInvariant::new(
        WordK { inst, ptr: read_perm.ptr() },
        (read_perm, read, wake),
        2,
    );
    (World { inst, head, tail, read }, w, r, data)
}


} // verus!
