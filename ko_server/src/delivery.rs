// vstd specifies VecDeque::len and index, not is_empty or front.
#![allow(clippy::len_zero)]
#![deny(clippy::arithmetic_side_effects)]

use std::collections::VecDeque;
use std::fmt;

use ko_pane_wire::frame::Req;
#[cfg(verus_only)]
use ko_pane_wire::frame::low32;
use ko_pane_wire::ring::{Invalid, Mark, Offset, Pos, Reader, RecordKind};
#[cfg(verus_only)]
use ko_pane_wire::ring::{
    Log, boundary, cursor_ok, log_le, log_le_boundary, log_le_head, log_le_trans, log_wf, off_at,
    resume_cursor, resumes, retain_of, wf_rec,
};
#[cfg(verus_only)]
use vstd::arithmetic::div_mod::{lemma_mod_equivalence, lemma_small_mod};
use vstd::prelude::*;
use vstd::tokens::InstanceId;

verus! {

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Fault {
    Ring(Invalid),
    EarlySlice,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Waiting {
    pub(crate) serial: u64,
    pub(crate) at: Pos,
    pub(crate) slices: u64,
}

pub(crate) struct Delivery {
    ring: Reader,
    requests: VecDeque<Waiting>,
    finished: VecDeque<Waiting>,
    delivered: Pos,
    last_slice: Ghost<Option<nat>>,
    slices: u64,
    next: u64,
    stamp: u64,
}

pub(crate) struct Done {
    stamp: u64,
    serial: u64,
    hold: Option<Pos>,
    slices: u64,
    #[allow(dead_code)]
    tl: Ghost<nat>,
}

pub(crate) uninterp spec fn instance_of(stamp: u64) -> InstanceId;

#[verifier::external_body]
tracked struct Bound {}

impl Bound {
    uninterp spec fn set(self) -> Set<u64>;
}

pub(crate) struct Stamps {
    next: u64,
    #[allow(dead_code)]
    bound: Tracked<Bound>,
}

// Assumes: the process mints one counter, so it makes one `Bound`, and no second counter hands
// out a stamp that this one handed out.
#[verifier::external_body]
pub(crate) fn mint_stamps() -> (r: Stamps)
    ensures
        r.wf(),
        r.next() == 1,
        r.bound() == Set::<u64>::empty(),
{
    Stamps { next: 1, bound: Tracked::assume_new() }
}

// Assumes: none; the body only builds the error value, and the contract says nothing about it.
#[verifier::external_body]
fn exhausted() -> std::io::Error {
    std::io::Error::other("the Delivery stamp counter is exhausted")
}

// Assumes: `instance_of` is unconstrained at a stamp that the one `Bound` does not hold, so the
// caller can define it there once.
#[verifier::external_body]
#[allow(unused_variables)]
proof fn bind_fresh(tracked bound: &mut Bound, stamp: u64, id: InstanceId)
    requires
        !old(bound).set().contains(stamp),
    ensures
        final(bound).set() == old(bound).set().insert(stamp),
        instance_of(stamp) == id,
{
}

impl Stamps {
    pub(crate) closed spec fn next(self) -> u64 {
        self.next
    }

    pub(crate) closed spec fn bound(self) -> Set<u64> {
        self.bound@.set()
    }

    pub(crate) closed spec fn wf(self) -> bool {
        forall|s: u64| #[trigger] self.bound().contains(s) ==> s < self.next()
    }

    #[allow(unused_variables)]
    fn bind(&mut self, id: Ghost<InstanceId>) -> (r: Result<u64, std::io::Error>)
        requires
            old(self).wf(),
        ensures
            final(self).wf(),
            final(self).next() >= old(self).next(),
            old(self).bound().subset_of(final(self).bound()),
            r is Ok ==> r->Ok_0 == old(self).next() && final(self).next() > r->Ok_0
                && final(self).bound() == old(self).bound().insert(r->Ok_0)
                && instance_of(r->Ok_0) == id@,
            r is Err ==> final(self).next() == old(self).next()
                && final(self).bound() == old(self).bound(),
    {
        let stamp = self.next;
        match stamp.checked_add(1) {
            Some(next) => {
                proof {
                    assert(!self.bound().contains(stamp));
                    bind_fresh(self.bound.borrow_mut(), stamp, id@);
                    assert forall|s: u64| #[trigger] self.bound().contains(s) implies s < next by {
                        if s != stamp {
                            assert(old(self).bound().contains(s));
                        }
                    }
                }
                self.next = next;
                Ok(stamp)
            },
            None => Err(exhausted()),
        }
    }
}

spec fn inv(
    log: Log,
    tl: nat,
    d: nat,
    requests: Seq<Waiting>,
    finished: Seq<Waiting>,
    last: Option<nat>,
) -> bool {
    &&& boundary(log, d)
    &&& d <= log.head
    &&& requests.len() > 0 ==> tl <= d
    &&& last is Some ==> requests.len() > 0 && last->Some_0 < d
    &&& forall|i: int, j: int|
        0 <= i <= j < finished.len() ==> (#[trigger] finished[i]).at.v() <= (#[trigger] finished[j]).at.v()
    &&& forall|i: int| 0 <= i < finished.len() ==> hold_ok(log, tl, d, #[trigger] finished[i])
}

spec fn serials_ok(all: Seq<u64>, next: u64) -> bool {
    &&& 1 <= next
    &&& forall|i: int| 0 <= i < all.len() ==> 1 <= (#[trigger] all[i]) < next
    &&& forall|i: int, j: int| 0 <= i < j < all.len() ==> (#[trigger] all[i]) < (#[trigger] all[j])
    &&& all.len() > 0 ==> next as nat - all[0] as nat <= 0x1_0000_0000nat
}

proof fn serials_skip(all: Seq<u64>, next: u64)
    requires
        serials_ok(all, next),
        all.len() > 0,
    ensures
        serials_ok(all.skip(1), next),
{
    let rest = all.skip(1);
    assert forall|i: int| 0 <= i < rest.len() implies 1 <= (#[trigger] rest[i]) < next by {
        assert(rest[i] == all[i + 1]);
    }
    assert forall|i: int, j: int|
        0 <= i < j < rest.len() implies (#[trigger] rest[i]) < (#[trigger] rest[j]) by {
        assert(rest[i] == all[i + 1]);
        assert(rest[j] == all[j + 1]);
    }
    if rest.len() > 0 {
        assert(rest[0] == all[1]);
        assert(all[0] < all[1]);
    }
}

proof fn serials_drop(finished: Seq<u64>, queue: Seq<u64>, next: u64)
    requires
        serials_ok(finished + queue, next),
        queue.len() > 0,
    ensures
        serials_ok(finished + queue.skip(1), next),
{
    let all = finished + queue;
    let rest = finished + queue.skip(1);
    assert forall|i: int| 0 <= i < rest.len() implies (rest[i] == all[i] || rest[i] == all[i + 1])
        && (i < finished.len() ==> rest[i] == all[i]) by {
        if i >= finished.len() {
            assert(rest[i] == queue.skip(1)[i - finished.len()]);
            assert(all[i + 1] == queue[i + 1 - finished.len()]);
        }
    }
    assert forall|i: int| 0 <= i < rest.len() implies 1 <= (#[trigger] rest[i]) < next by {}
    assert forall|i: int, j: int|
        0 <= i < j < rest.len() implies (#[trigger] rest[i]) < (#[trigger] rest[j]) by {
        assert(rest[i] == all[i] || rest[i] == all[i + 1]);
        assert(rest[j] == all[j] || rest[j] == all[j + 1]);
        assert(i < finished.len() ==> rest[i] == all[i]);
        assert(j >= finished.len() ==> rest[j] == all[j + 1]);
        if i < finished.len() && j >= finished.len() {
            assert(all[i] < all[j + 1]);
        }
    }
    if rest.len() > 0 {
        if finished.len() > 0 {
            assert(rest[0] == all[0]);
        } else {
            assert(rest[0] == all[1]);
            assert(all[0] < all[1]);
        }
    }
}

proof fn serials_push(all: Seq<u64>, next: u64, serial: u64)
    requires
        serials_ok(all, next),
        serial + 1 == next,
        1 <= serial,
        all.len() > 0 ==> all.last() < serial,
    ensures
        serials_ok(all.push(serial), next),
{
    let more = all.push(serial);
    assert forall|i: int| 0 <= i < more.len() implies 1 <= (#[trigger] more[i]) < next by {
        if i < all.len() {
            assert(more[i] == all[i]);
        }
    }
    assert forall|i: int, j: int|
        0 <= i < j < more.len() implies (#[trigger] more[i]) < (#[trigger] more[j]) by {
        assert(more[i] == all[i]);
        if j < all.len() {
            assert(more[j] == all[j]);
        } else {
            assert(more[j] == serial);
            if i < all.len() - 1 {
                assert(all[i] < all.last());
            }
        }
    }
    if all.len() > 0 {
        assert(more[0] == all[0]);
    } else {
        assert(more[0] == serial);
    }
}

proof fn serials_distinct(all: Seq<u64>, next: u64)
    requires
        serials_ok(all, next),
    ensures
        forall|i: int, j: int|
            0 <= i < j < all.len() ==> low32(#[trigger] all[i]) != low32(#[trigger] all[j]),
{
    assert forall|i: int, j: int| 0 <= i < j < all.len() implies low32(#[trigger] all[i])
        != low32(#[trigger] all[j]) by {
        let a = all[i] as int;
        let b = all[j] as int;
        assert(all[0] <= all[i]) by {
            if i > 0 {
                assert(all[0] < all[i]);
            }
        }
        if low32(all[i]) == low32(all[j]) {
            lemma_mod_equivalence(b, a, 0x1_0000_0000int);
            lemma_small_mod((b - a) as nat, 0x1_0000_0000nat);
        }
    }
}

pub(crate) closed spec fn serials_of(waiting: Seq<Waiting>) -> Seq<u64> {
    waiting.map_values(|w: Waiting| w.serial)
}

spec fn hold_ok(log: Log, tl: nat, d: nat, w: Waiting) -> bool {
    &&& tl <= w.at.v() as nat <= d
    &&& boundary(log, w.at.v() as nat)
}

proof fn inv_grows(
    cap: nat,
    a: Log,
    b: Log,
    tl: nat,
    d: nat,
    requests: Seq<Waiting>,
    finished: Seq<Waiting>,
    last: Option<nat>,
)
    requires
        log_wf(cap, a),
        log_wf(cap, b),
        log_le(a, b),
        inv(a, tl, d, requests, finished, last),
    ensures
        inv(b, tl, d, requests, finished, last),
{
    log_le_head(a, b);
    log_le_boundary(cap, a, b, d);
    assert forall|i: int| 0 <= i < finished.len() implies hold_ok(b, tl, d, #[trigger] finished[i]) by {
        log_le_boundary(cap, a, b, finished[i].at.v() as nat);
    }
}

impl Done {
    pub(crate) open spec fn valid(self) -> bool {
        match self.hold_of() {
            Some(hold) => self.tl_of() <= hold.v() as nat,
            None => true,
        }
    }

    pub(crate) closed spec fn stamp_of(self) -> u64 {
        self.stamp
    }

    pub(crate) closed spec fn serial_of(self) -> u64 {
        self.serial
    }

    pub(crate) closed spec fn hold_of(self) -> Option<Pos> {
        self.hold
    }

    pub(crate) closed spec fn slices_of(self) -> u64 {
        self.slices
    }

    pub(crate) closed spec fn tl_of(self) -> nat {
        self.tl@
    }

    pub(crate) fn stamp(&self) -> (r: u64)
        ensures
            r == self.stamp_of(),
    {
        self.stamp
    }

    pub(crate) fn serial(&self) -> (r: u64)
        ensures
            r == self.serial_of(),
    {
        self.serial
    }

    pub(crate) fn slices(&self) -> (r: u64)
        ensures
            r == self.slices_of(),
    {
        self.slices
    }

    pub(crate) fn hold(&self) -> (r: Option<Pos>)
        ensures
            r == self.hold_of(),
    {
        self.hold
    }

    pub(crate) fn req(&self) -> (r: Req)
        ensures
            r.val() as nat == low32(self.serial_of()),
    {
        Req::of_serial(self.serial)
    }
}

impl Delivery {
    pub(crate) closed spec fn wf(self) -> bool {
        &&& self.ring.wf()
        &&& inv(self.log(), self.tl(), self.at(), self.queue(), self.done(), self.last_slice@)
        &&& serials_ok(self.serials(), self.next)
        &&& instance_of(self.stamp) == self.ring.mark_id()
    }

    pub(crate) closed spec fn following(self) -> u64 {
        self.next
    }

    pub(crate) closed spec fn serials(self) -> Seq<u64> {
        serials_of(self.done()) + serials_of(self.queue())
    }

    pub(crate) closed spec fn log(self) -> Log {
        self.ring.log()
    }

    pub(crate) closed spec fn tl(self) -> nat {
        self.ring.tl()
    }

    pub(crate) closed spec fn queue(self) -> Seq<Waiting> {
        self.requests@
    }

    pub(crate) closed spec fn done(self) -> Seq<Waiting> {
        self.finished@
    }

    pub(crate) closed spec fn at(self) -> nat {
        self.delivered.v() as nat
    }

    pub(crate) closed spec fn stamp_of(self) -> u64 {
        self.stamp
    }

    pub(crate) closed spec fn cap(self) -> nat {
        self.ring.cap()
    }

    pub(crate) open spec fn grew(self, old: Delivery) -> bool {
        &&& self.wf()
        &&& log_wf(self.cap(), self.log())
        &&& self.tl() <= self.log().head
        &&& boundary(self.log(), self.tl())
        &&& self.cap() == old.cap()
        &&& self.stamp_of() == old.stamp_of()
        &&& self.tl() == old.tl()
        &&& log_le(old.log(), self.log())
        &&& self.queue() == old.queue()
        &&& self.done() == old.done()
        &&& self.at() == old.at()
    }

    pub(crate) proof fn grew_trans(a: Delivery, b: Delivery, c: Delivery)
        requires
            b.grew(a),
            c.grew(b),
        ensures
            c.grew(a),
    {
        log_le_trans(a.log(), b.log(), c.log());
    }

    proof fn regrown(tracked &self, old: Delivery)
        requires
            old.wf(),
            log_wf(old.cap(), old.log()),
            self.ring.wf(),
            self.ring.cap() == old.ring.cap(),
            self.ring.tl() == old.ring.tl(),
            self.ring.mark_id() == old.ring.mark_id(),
            log_le(old.log(), self.log()),
            self.requests@ == old.requests@,
            self.finished@ == old.finished@,
            self.delivered == old.delivered,
            self.last_slice@ == old.last_slice@,
            self.next == old.next,
            self.stamp == old.stamp,
        ensures
            self.grew(old),
    {
        self.ring.facts();
        inv_grows(
            self.ring.cap(),
            old.log(),
            self.log(),
            self.tl(),
            self.at(),
            self.queue(),
            self.done(),
            self.last_slice@,
        );
    }

    pub(crate) proof fn facts(tracked &self)
        requires
            self.wf(),
        ensures
            log_wf(self.cap(), self.log()),
            self.tl() <= self.log().head,
            boundary(self.log(), self.tl()),
    {
        self.ring.facts();
    }

    pub(crate) proof fn bound(tracked &self, tracked m: &Mark)
        requires
            self.wf(),
            m.id() == instance_of(self.stamp_of()),
        ensures
            log_wf(self.cap(), m.log()),
            log_le(m.log(), self.log()),
    {
        self.ring.bound(m);
    }

    closed spec fn queued_reqs(self) -> Seq<u32> {
        (self.done() + self.queue()).map_values(|w: Waiting| low32(w.serial) as u32)
    }

    proof fn reqs_unique(tracked &self)
        requires
            self.wf(),
        ensures
            self.queued_reqs().no_duplicates(),
    {
        let all = self.serials();
        serials_distinct(all, self.next);
        let reqs = self.queued_reqs();
        assert forall|i: int, j: int| 0 <= i < j < reqs.len() implies reqs[i] != reqs[j] by {
            assert(reqs[i] as nat == low32(all[i]));
            assert(reqs[j] as nat == low32(all[j]));
        }
    }

    pub(crate) closed spec fn keep_of(self, head: nat) -> nat {
        let reading = if self.queue().len() == 0 {
            head
        } else {
            self.at()
        };
        if self.done().len() == 0 || reading <= self.done()[0].at.v() as nat {
            reading
        } else {
            self.done()[0].at.v() as nat
        }
    }

    pub(crate) fn create(stamps: &mut Stamps, capacity: u64) -> (r: Result<Delivery, std::io::Error>)
        requires
            old(stamps).wf(),
        ensures
            final(stamps).wf(),
            final(stamps).next() >= old(stamps).next(),
            old(stamps).bound().subset_of(final(stamps).bound()),
            r is Ok ==> r->Ok_0.wf(),
    {
        match Reader::create(capacity) {
            Ok(ring) => {
                proof {
                    ring.facts();
                }
                let delivered = ring.tail();
                let stamp = stamps.bind(Ghost(ring.mark_id()))?;
                Ok(Delivery {
                    ring,
                    requests: VecDeque::new(),
                    finished: VecDeque::new(),
                    delivered,
                    last_slice: Ghost(None),
                    slices: 0,
                    next: 1,
                    stamp,
                })
            },
            Err(e) => Err(e),
        }
    }

    pub(crate) fn ring(&self) -> (r: &Reader)
        requires
            self.wf(),
        ensures
            r.wf(),
            r.log() == self.log(),
            r.tl() == self.tl(),
            r.mark_id() == instance_of(self.stamp_of()),
    {
        &self.ring
    }

    pub(crate) fn stamp(&self) -> (s: u64)
        ensures
            s == self.stamp_of(),
    {
        self.stamp
    }

    pub(crate) fn mark(&self) -> (m: Tracked<Mark>)
        requires
            self.wf(),
        ensures
            m@.id() == instance_of(self.stamp_of()),
            m@.log() == self.log(),
    {
        self.ring.mark()
    }

    pub(crate) fn head(&mut self) -> (head: Pos)
        requires
            old(self).wf(),
        ensures
            final(self).grew(*old(self)),
            head.v() as nat == final(self).log().head,
    {
        proof {
            self.ring.facts();
        }
        let ghost old = *self;
        let head = self.ring.head();
        proof {
            self.ring.facts();
            self.regrown(old);
        }
        head
    }

    pub(crate) fn end_offset(&mut self) -> (r: Result<Offset, Invalid>)
        requires
            old(self).wf(),
        ensures
            final(self).grew(*old(self)),
            r.is_ok(),
            r.unwrap().v() as nat == final(self).log().head_offset,
    {
        proof {
            self.ring.facts();
        }
        let ghost old = *self;
        let r = self.ring.end_offset();
        proof {
            self.ring.facts();
            self.regrown(old);
        }
        r
    }

    pub(crate) fn oldest_offset(&mut self) -> (r: Result<Offset, Invalid>)
        requires
            old(self).wf(),
        ensures
            final(self).grew(*old(self)),
            r.is_ok(),
            off_at(final(self).log(), final(self).tl()) <= r.unwrap().v(),
    {
        proof {
            self.ring.facts();
        }
        let ghost old = *self;
        let r = self.ring.oldest_offset();
        proof {
            self.ring.facts();
            self.regrown(old);
        }
        r
    }

    pub(crate) fn resume(&mut self, target: Offset) -> (r: Result<Pos, Invalid>)
        requires
            old(self).wf(),
        ensures
            final(self).grew(*old(self)),
            r.is_ok(),
            resumes(final(self).tl(), final(self).log(), target.v() as nat, r.unwrap().v() as nat),
    {
        proof {
            self.ring.facts();
        }
        let ghost old = *self;
        let r = self.ring.resume(target);
        proof {
            self.ring.facts();
            self.regrown(old);
        }
        r
    }



    pub(crate) fn seek(&mut self, want: u64) -> (r: Result<Option<(Pos, u64)>, Invalid>)
        requires
            old(self).wf(),
        ensures
            final(self).grew(*old(self)),
            r is Ok && r->Ok_0 is Some ==> {
                &&& cursor_ok(final(self).log(), r->Ok_0->Some_0.0.v() as nat, r->Ok_0->Some_0.1 as nat)
                &&& want <= r->Ok_0->Some_0.1
                &&& final(self).tl() <= r->Ok_0->Some_0.0.v()
            },
    {
        proof {
            self.facts();
        }
        let ghost d0 = *self;
        let oldest = self.oldest_offset()?.get();
        proof {
            self.facts();
        }
        let ghost d1 = *self;
        let end = self.end_offset()?.get();
        let ghost d2 = *self;
        proof {
            Delivery::grew_trans(d0, d1, d2);
        }
        let to = if want < oldest {
            oldest
        } else {
            want
        };
        if to > end {
            return Ok(None);
        }
        let p = self.resume(Offset::new(to))?;
        proof {
            Delivery::grew_trans(d0, d2, *self);
            Delivery::grew_trans(d1, d2, *self);
            self.facts();
            log_le_boundary(self.cap(), d1.log(), self.log(), self.tl());
            log_le_head(d2.log(), self.log());
            resume_cursor(self.cap(), self.log(), self.tl(), to as nat, p.v() as nat);
        }
        Ok(Some((p, to)))
    }

    // Assumes: the sink uses the handle during the call only.
    #[verifier::external_body]
    fn hand_over<S: FnMut(Handle<'_>)>(sink: &mut S, handle: Handle<'_>) {
        sink(handle)
    }

    fn pop_done(&mut self) -> (w: Waiting)
        requires
            old(self).wf(),
            old(self).done().len() > 0,
        ensures
            final(self).wf(),
            final(self).log() == old(self).log(),
            final(self).tl() == old(self).tl(),
            final(self).at() == old(self).at(),
            final(self).stamp_of() == old(self).stamp_of(),
            final(self).queue() == old(self).queue(),
            final(self).done() == old(self).done().skip(1),
            final(self).ring == old(self).ring,
            final(self).next == old(self).next,
            w == old(self).done()[0],
    {
        proof {
            self.ring.facts();
        }
        let w = self.finished[0];
        let ghost all0 = self.serials();
        self.finished.pop_front();
        proof {
            assert(self.serials() =~= all0.skip(1));
            serials_skip(all0, self.next);
        }
        w
    }

    fn pop_queue(&mut self) -> (w: Waiting)
        requires
            old(self).wf(),
            old(self).queue().len() > 0,
        ensures
            final(self).wf(),
            final(self).log() == old(self).log(),
            final(self).tl() == old(self).tl(),
            final(self).at() == old(self).at(),
            final(self).stamp_of() == old(self).stamp_of(),
            final(self).done() == old(self).done(),
            final(self).queue() == old(self).queue().skip(1),
            final(self).ring == old(self).ring,
            final(self).next == old(self).next,
            w == old(self).queue()[0],
    {
        proof {
            self.ring.facts();
        }
        let w = self.requests[0];
        proof {
            serials_drop(serials_of(self.finished@), serials_of(self.requests@), self.next);
        }
        self.requests.pop_front();
        proof {
            assert(serials_of(self.requests@) =~= serials_of(old(self).requests@).skip(1));
        }
        self.last_slice = Ghost(None);
        self.slices = 0;
        w
    }

    fn deliver<S: FnMut(Handle<'_>)>(&mut self, upper: Pos, sink: &mut S) -> (r: Result<
        (),
        Fault,
    >)
        requires
            old(self).wf(),
            upper.v() as nat <= old(self).log().head,
        ensures
            final(self).wf(),
            final(self).ring == old(self).ring,
            final(self).stamp_of() == old(self).stamp_of(),
            r is Ok && old(self).queue().len() > 0 ==> upper.v() <= final(self).at(),
    {
        proof {
            self.ring.facts();
        }
        if self.requests.len() == 0 {
            return Ok(());
        }
        while self.delivered.get() < upper.get()
            invariant
                self.wf(),
                self.ring == old(self).ring,
                self.stamp == old(self).stamp,
                upper.v() as nat <= self.log().head,
                self.tl() <= self.at(),
                old(self).at() <= self.at(),
            decreases self.log().head - self.at(),
        {
            proof {
                self.ring.facts();
            }
            let at = self.delivered;
            let record = match self.ring.record(at) {
                Ok(record) => record,
                Err(e) => return Err(Fault::Ring(e)),
            };
            proof {
                wf_rec(self.ring.cap(), self.ring.log(), at.v() as nat);
            }
            let next = record.next;
            match record.kind {
                RecordKind::Slice => {
                    if self.requests.len() == 0 {
                        self.delivered = next;
                    } else {
                        let front = self.requests[0];
                        if front.at.get() <= at.get() {
                            Self::hand_over(sink, Handle::new(self, front.serial, at));
                            self.last_slice = Ghost(Some(at.v() as nat));
                            self.slices = self.slices.saturating_add(1);
                            self.delivered = next;
                            match self.ring.slice(at) {
                                Err(e) => return Err(Fault::Ring(e)),
                                Ok(slice) => {
                                    if slice.last {
                                        let count = self.slices;
                                        let ghost all0 = self.serials();
                                        proof {
                                            assert(serials_ok(all0, self.next));
                                        }
                                        self.pop_queue();
                                        self.finished.push_back(
                                            Waiting { serial: front.serial, at: next, slices: count },
                                        );
                                        proof {
                                            assert(self.serials() =~= all0);
                                        }
                                    }
                                },
                            }
                        } else {
                            return Err(Fault::EarlySlice);
                        }
                    }
                },
                _ => {
                    self.delivered = next;
                },
            }
        }
        Ok(())
    }

    pub(crate) fn scan<S: FnMut(Handle<'_>)>(&mut self, sink: &mut S) -> (r: Result<
        Pos,
        Fault,
    >)
        requires
            old(self).wf(),
        ensures
            final(self).wf(),
            final(self).stamp_of() == old(self).stamp_of(),
            old(self).tl() <= final(self).tl(),
            log_le(old(self).log(), final(self).log()),
            r is Ok ==> {
                let head = r->Ok_0.v() as nat;
                &&& head == final(self).log().head
                &&& final(self).tl() <= final(self).keep_of(head)
            },
    {
        let head = self.head();
        match self.deliver(head, sink) {
            Ok(()) => {},
            Err(e) => return Err(e),
        }
        let reading = if self.requests.len() == 0 {
            head
        } else {
            self.delivered
        };
        let keep = if self.finished.len() == 0 {
            reading
        } else {
            let hold = self.finished[0].at;
            if hold.get() < reading.get() {
                hold
            } else {
                reading
            }
        };
        proof {
            self.ring.facts();
        }
        let ghost before = *self;
        match self.ring.advance(head, keep) {
            Ok(()) => {},
            Err(e) => return Err(Fault::Ring(e)),
        }
        proof {
            self.ring.facts();
            let log = self.ring.log();
            let cap = self.ring.cap();
            let tl1 = self.ring.tl();
            let k = keep.v() as nat;
            let retain = retain_of(cap, head.v() as nat, k);
            if tl1 > k && retain > before.ring.tl() {
                assert(retain <= k);
                assert(log.m.contains_key(k) || k == log.head);
            }
        }
        Ok(head)
    }

    pub(crate) fn mint_serial(&mut self) -> (r: Option<(u64, Req)>)
        requires
            old(self).wf(),
        ensures
            final(self).wf(),
            final(self).log() == old(self).log(),
            final(self).tl() == old(self).tl(),
            final(self).queue() == old(self).queue(),
            final(self).done() == old(self).done(),
            final(self).at() == old(self).at(),
            final(self).stamp_of() == old(self).stamp_of(),
            r is Some ==> {
                &&& 1 <= r->Some_0.0
                &&& r->Some_0.1.val() as nat == low32(r->Some_0.0)
                &&& r->Some_0.0 + 1 == final(self).following()
                &&& forall|i: int|
                    0 <= i < final(self).serials().len() ==> (#[trigger] final(self).serials()[i])
                        < r->Some_0.0
            },
    {
        proof {
            self.ring.facts();
        }
        let candidate = self.next;
        let following = candidate.checked_add(1)?;
        let oldest = if self.finished.len() > 0 {
            Some(self.finished[0].serial)
        } else if self.requests.len() > 0 {
            Some(self.requests[0].serial)
        } else {
            None
        };
        if let Some(oldest) = oldest {
            if Req::of_serial(oldest).same(Req::of_serial(candidate)) {
                return None;
            }
            proof {
                let all = self.serials();
                assert(all[0] == oldest);
                lemma_mod_equivalence(candidate as int, oldest as int, 0x1_0000_0000int);
                assert(candidate as nat - oldest as nat != 0x1_0000_0000nat) by {
                    if candidate as nat - oldest as nat == 0x1_0000_0000nat {
                        assert(0x1_0000_0000int % 0x1_0000_0000int == 0) by (nonlinear_arith);
                    }
                }
            }
        }
        self.next = following;
        Some((candidate, Req::of_serial(candidate)))
    }

    pub(crate) fn request(&mut self) -> (r: Option<(u64, Req)>)
        requires
            old(self).wf(),
        ensures
            final(self).wf(),
            log_le(old(self).log(), final(self).log()),
            final(self).tl() == old(self).tl(),
            final(self).done() == old(self).done(),
            final(self).stamp_of() == old(self).stamp_of(),
            match r {
                Some((serial, req)) => {
                    &&& final(self).queue().len() == old(self).queue().len() + 1
                    &&& final(self).queue().drop_last() == old(self).queue()
                    &&& final(self).queue().last().serial == serial
                    &&& final(self).queue().last().at.v() as nat == final(self).log().head
                    &&& req.val() as nat == low32(serial)
                    &&& old(self).queue().len() == 0 ==> final(self).at() == final(self).log().head
                    &&& old(self).queue().len() > 0 ==> final(self).at() == old(self).at()
                },
                None => {
                    &&& final(self).queue() == old(self).queue()
                    &&& final(self).at() == old(self).at()
                },
            },
    {
        let floor = self.head();
        let (serial, req) = self.mint_serial()?;
        proof {
            self.ring.facts();
        }
        if self.requests.len() == 0 {
            self.delivered = floor;
        }
        let ghost all0 = self.serials();
        self.requests.push_back(Waiting { serial, at: floor, slices: 0 });
        proof {
            assert(self.serials() =~= all0.push(serial));
            serials_push(all0, self.next, serial);
        }
        Some((serial, req))
    }

    pub(crate) fn snapshot_done(&mut self, req: Req) -> (r: Option<Done>)
        requires
            old(self).wf(),
        ensures
            final(self).wf(),
            final(self).log() == old(self).log(),
            final(self).tl() == old(self).tl(),
            final(self).stamp_of() == old(self).stamp_of(),
            match r {
                Some(done) => {
                    &&& done.valid()
                    &&& done.stamp_of() == old(self).stamp_of()
                    &&& done.tl_of() == old(self).tl()
                    &&& req.val() as nat == low32(done.serial_of())
                    &&& if done.hold_of() is Some {
                        &&& old(self).done().len() > 0
                        &&& old(self).done()[0].serial == done.serial_of()
                        &&& done.hold_of() == Some(old(self).done()[0].at)
                        &&& boundary(old(self).log(), old(self).done()[0].at.v() as nat)
                        &&& final(self).done() == old(self).done().skip(1)
                        &&& final(self).queue() == old(self).queue()
                    } else {
                        &&& old(self).done().len() == 0
                        &&& old(self).queue().len() > 0
                        &&& old(self).queue()[0].serial == done.serial_of()
                        &&& final(self).queue() == old(self).queue().skip(1)
                        &&& final(self).done() == old(self).done()
                    }
                },
                None => {
                    &&& final(self).queue() == old(self).queue()
                    &&& final(self).done() == old(self).done()
                },
            },
    {
        proof {
            self.ring.facts();
        }
        let ghost tl = self.tl();
        if self.finished.len() > 0 {
            let front = self.finished[0];
            if Req::of_serial(front.serial).same(req) {
                self.pop_done();
                Some(
                    Done {
                        stamp: self.stamp,
                        serial: front.serial,
                        hold: Some(front.at),
                        slices: front.slices,
                        tl: Ghost(tl),
                    },
                )
            } else {
                None
            }
        } else if self.requests.len() > 0 {
            let front = self.requests[0];
            if Req::of_serial(front.serial).same(req) {
                self.pop_queue();
                Some(
                    Done {
                        stamp: self.stamp,
                        serial: front.serial,
                        hold: None,
                        slices: 0,
                        tl: Ghost(tl),
                    },
                )
            } else {
                None
            }
        } else {
            None
        }
    }

    pub(crate) fn fail_all(&mut self) -> (out: Vec<Done>)
        requires
            old(self).wf(),
        ensures
            final(self).wf(),
            final(self).queue().len() == 0,
            final(self).done().len() == 0,
            out@.map_values(|d: Done| d.serial_of()) == serials_of(old(self).done()) + serials_of(
                old(self).queue(),
            ),
    {
        let mut out = Vec::new();
        let ghost tl = self.tl();
        while self.finished.len() > 0
            invariant
                self.wf(),
                self.tl() == tl,
                self.stamp == old(self).stamp,
                self.queue() == old(self).queue(),
                out@.map_values(|d: Done| d.serial_of()) + serials_of(self.done()) == serials_of(
                    old(self).done(),
                ),
            decreases self.finished@.len(),
        {
            let waiting = self.pop_done();
            out.push(
                Done { stamp: self.stamp, serial: waiting.serial, hold: None, slices: 0, tl: Ghost(tl) },
            );
        }
        proof {
            assert(serials_of(self.finished@) =~= Seq::<u64>::empty());
        }
        while self.requests.len() > 0
            invariant
                self.wf(),
                self.tl() == tl,
                self.stamp == old(self).stamp,
                self.done().len() == 0,
                out@.map_values(|d: Done| d.serial_of()) + serials_of(self.queue()) == serials_of(
                    old(self).done(),
                ) + serials_of(old(self).queue()),
            decreases self.requests@.len(),
        {
            let waiting = self.pop_queue();
            out.push(
                Done { stamp: self.stamp, serial: waiting.serial, hold: None, slices: 0, tl: Ghost(tl) },
            );
        }
        out
    }

    pub(crate) fn deliver_now<S: FnMut(Handle<'_>)>(&mut self, sink: &mut S) -> (r: Result<
        (),
        Fault,
    >)
        requires
            old(self).wf(),
        ensures
            final(self).wf(),
    {
        let upper = self.head();
        self.deliver(upper, sink)
    }
}

pub(crate) struct Handle<'a> {
    d: &'a Delivery,
    serial: u64,
    pos: Pos,
}

impl<'a> Handle<'a> {
    pub(crate) closed spec fn valid(self) -> bool {
        &&& self.d.wf()
        &&& self.d.requests@.len() > 0
        &&& self.d.requests@[0].serial == self.serial
        &&& self.d.requests@[0].at.v() <= self.pos.v()
        &&& self.d.last_slice@ is Some ==> self.d.last_slice@->Some_0 < self.pos.v()
        &&& self.d.ring.visible(self.pos.v())
        &&& self.d.ring.log().m[self.pos.v() as nat].kind == RecordKind::Slice
    }

    pub(crate) closed spec fn serial_of(self) -> u64 {
        self.serial
    }

    pub(crate) closed spec fn pos_of(self) -> u64 {
        self.pos.v()
    }

    pub(crate) closed spec fn stamp_of(self) -> u64 {
        self.d.stamp
    }

    fn new(d: &'a Delivery, serial: u64, pos: Pos) -> (h: Handle<'a>)
        requires
            d.wf(),
            d.requests@.len() > 0,
            d.requests@[0].serial == serial,
            d.requests@[0].at.v() <= pos.v(),
            d.last_slice@ is Some ==> d.last_slice@->Some_0 < pos.v(),
            d.ring.visible(pos.v()),
            d.ring.log().m[pos.v() as nat].kind == RecordKind::Slice,
        ensures
            h.valid(),
            h.serial_of() == serial,
            h.pos_of() == pos.v(),
            h.stamp_of() == d.stamp_of(),
    {
        Handle { d, serial, pos }
    }

    pub(crate) fn serial(&self) -> (r: u64)
        ensures
            r == self.serial_of(),
    {
        self.serial
    }

    pub(crate) fn pos(&self) -> (r: Pos)
        ensures
            r.v() == self.pos_of(),
    {
        self.pos
    }

    pub(crate) fn stamp(&self) -> (r: u64)
        ensures
            r == self.stamp_of(),
    {
        self.d.stamp
    }

    pub(crate) fn req(&self) -> (r: Req)
        ensures
            r.val() as nat == low32(self.serial_of()),
    {
        Req::of_serial(self.serial)
    }

    pub(crate) fn ring(&self) -> (r: &'a Reader)
        requires
            self.valid(),
        ensures
            r.wf(),
            r.visible(self.pos_of()),
            r.log().m[self.pos_of() as nat].kind == RecordKind::Slice,
            r.mark_id() == instance_of(self.stamp_of()),
    {
        &self.d.ring
    }
}

} // verus!

impl fmt::Debug for Done {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Done")
            .field("stamp", &self.stamp)
            .field("serial", &self.serial)
            .field("hold", &self.hold)
            .field("slices", &self.slices)
            .finish()
    }
}

impl PartialEq for Done {
    fn eq(&self, other: &Done) -> bool {
        (self.stamp, self.serial, self.hold, self.slices)
            == (other.stamp, other.serial, other.hold, other.slices)
    }
}

impl Eq for Done {}

impl fmt::Display for Fault {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Fault::Ring(invalid) => invalid.fmt(f),
            Fault::EarlySlice => f.write_str("ko-pane wrote a slice before its request"),
        }
    }
}

impl fmt::Debug for Stamps {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Stamps").field("next", &self.next).finish()
    }
}

impl fmt::Debug for Delivery {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Delivery")
            .field("ring", &self.ring)
            .field("requests", &self.requests)
            .field("finished", &self.finished)
            .field("delivered", &self.delivered)
            .field("next", &self.next)
            .finish()
    }
}
