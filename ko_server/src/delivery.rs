// vstd specifies VecDeque::len and index, not is_empty or front.
#![allow(clippy::len_zero)]
#![deny(clippy::arithmetic_side_effects)]

use std::collections::VecDeque;
use std::fmt;

use ko_pane_wire::frame::Req;
use ko_pane_wire::ring::{Invalid, Pos, Reader, RecordKind};
#[cfg(verus_only)]
use ko_pane_wire::ring::{
    Log, boundary, log_le, log_le_boundary, log_le_head, log_wf, retain_of, wf_rec,
};
use vstd::prelude::*;

verus! {

#[allow(dead_code, unreachable_pub)]
#[verifier::external_type_specification]
#[verifier::external_body]
pub struct ExReq(Req);

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Fault {
    Ring(Invalid),
    EarlySlice,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Waiting {
    pub(crate) req: Req,
    pub(crate) at: Pos,
}

pub(crate) struct Delivery {
    ring: Reader,
    requests: VecDeque<Waiting>,
    finished: VecDeque<Waiting>,
    delivered: Pos,
    last_slice: Ghost<Option<nat>>,
}

// Assumes: Req's derived PartialEq is equality of the values.
#[verifier::external_body]
fn same_req(a: Req, b: Req) -> (r: bool)
    ensures
        r == (a == b),
{
    a == b
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

pub(crate) closed spec fn reqs_of(waiting: Seq<Waiting>) -> Seq<Req> {
    waiting.map_values(|w: Waiting| w.req)
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

impl Delivery {
    pub(crate) closed spec fn wf(self) -> bool {
        &&& self.ring.wf()
        &&& inv(self.log(), self.tl(), self.at(), self.queue(), self.done(), self.last_slice@)
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

    pub(crate) fn create(capacity: u64) -> (r: Result<Delivery, std::io::Error>)
        ensures
            r is Ok ==> r->Ok_0.wf(),
    {
        match Reader::create(capacity) {
            Ok(ring) => {
                proof {
                    ring.facts();
                }
                let delivered = ring.tail();
                Ok(Delivery {
                    ring,
                    requests: VecDeque::new(),
                    finished: VecDeque::new(),
                    delivered,
                    last_slice: Ghost(None),
                })
            },
            Err(e) => Err(e),
        }
    }

    pub(crate) fn observe(&mut self) -> (head: Pos)
        requires
            old(self).wf(),
        ensures
            final(self).wf(),
            head.v() as nat == final(self).log().head,
            final(self).tl() == old(self).tl(),
            log_le(old(self).log(), final(self).log()),
            final(self).queue() == old(self).queue(),
            final(self).done() == old(self).done(),
            final(self).at() == old(self).at(),
    {
        proof {
            self.ring.facts();
        }
        let ghost before = self.ring.log();
        let head = self.ring.head();
        proof {
            self.ring.facts();
            inv_grows(
                self.ring.cap(),
                before,
                self.log(),
                self.tl(),
                self.at(),
                self.queue(),
                self.done(),
                self.last_slice@,
            );
        }
        head
    }

    // Assumes: the sink reads the slice at `at` from the ring during the call only, and keeps
    // neither the ring nor the position.
    #[verifier::external_body]
    fn hand_over<S: FnMut(&Reader, Req, Pos)>(&self, sink: &mut S, req: Req, at: Pos)
        requires
            self.wf(),
            self.requests@.len() > 0,
            self.requests@[0].req == req,
            self.ring.visible(at.v()),
            self.ring.log().m[at.v() as nat].kind == RecordKind::Slice,
            self.requests@[0].at.v() <= at.v(),
            self.last_slice@ is Some ==> self.last_slice@->Some_0 < at.v() as nat,
    {
        sink(&self.ring, req, at)
    }

    fn deliver<S: FnMut(&Reader, Req, Pos)>(&mut self, upper: Pos, sink: &mut S) -> (r: Result<
        (),
        Fault,
    >)
        requires
            old(self).wf(),
            upper.v() as nat <= old(self).log().head,
        ensures
            final(self).wf(),
            final(self).ring == old(self).ring,
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
                            self.hand_over(sink, front.req, at);
                            self.last_slice = Ghost(Some(at.v() as nat));
                            self.delivered = next;
                            match self.ring.slice(at) {
                                Err(e) => return Err(Fault::Ring(e)),
                                Ok(slice) => {
                                    if slice.last {
                                        self.requests.pop_front();
                                        self.finished.push_back(Waiting { req: front.req, at: next });
                                        self.last_slice = Ghost(None);
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

    pub(crate) fn scan<S: FnMut(&Reader, Req, Pos)>(&mut self, sink: &mut S) -> (r: Result<
        Pos,
        Fault,
    >)
        requires
            old(self).wf(),
        ensures
            final(self).wf(),
            old(self).tl() <= final(self).tl(),
            log_le(old(self).log(), final(self).log()),
            r is Ok ==> {
                let head = r->Ok_0.v() as nat;
                &&& head == final(self).log().head
                &&& final(self).tl() <= final(self).keep_of(head)
            },
    {
        let head = self.observe();
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

    pub(crate) fn request(&mut self, req: Req)
        requires
            old(self).wf(),
        ensures
            final(self).wf(),
            final(self).log() == old(self).log(),
            final(self).tl() == old(self).tl(),
            final(self).queue().len() == old(self).queue().len() + 1,
            final(self).queue().drop_last() == old(self).queue(),
            final(self).queue().last().req == req,
            final(self).queue().last().at.v() as nat == final(self).log().head,
            final(self).done() == old(self).done(),
            old(self).queue().len() == 0 ==> final(self).at() == final(self).log().head,
            old(self).queue().len() > 0 ==> final(self).at() == old(self).at(),
    {
        proof {
            self.ring.facts();
        }
        let floor = self.ring.seen();
        if self.requests.len() == 0 {
            self.delivered = floor;
        }
        self.requests.push_back(Waiting { req, at: floor });
    }

    pub(crate) fn snapshot_done(&mut self, req: Req) -> (r: Option<bool>)
        requires
            old(self).wf(),
        ensures
            final(self).wf(),
            final(self).log() == old(self).log(),
            final(self).tl() == old(self).tl(),
            match r {
                Some(true) => {
                    &&& old(self).done().len() > 0
                    &&& old(self).done()[0].req == req
                    &&& old(self).tl() <= old(self).done()[0].at.v() as nat
                    &&& old(self).done()[0].at.v() as nat <= old(self).log().head
                    &&& boundary(old(self).log(), old(self).done()[0].at.v() as nat)
                    &&& final(self).done() == old(self).done().skip(1)
                    &&& final(self).queue() == old(self).queue()
                },
                Some(false) => {
                    &&& old(self).done().len() == 0
                    &&& old(self).queue().len() > 0
                    &&& old(self).queue()[0].req == req
                    &&& final(self).queue() == old(self).queue().skip(1)
                    &&& final(self).done() == old(self).done()
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
        if self.finished.len() > 0 {
            let front = self.finished[0];
            if same_req(front.req, req) {
                self.finished.pop_front();
                Some(true)
            } else {
                None
            }
        } else if self.requests.len() > 0 {
            let front = self.requests[0];
            if same_req(front.req, req) {
                self.requests.pop_front();
                self.last_slice = Ghost(None);
                Some(false)
            } else {
                None
            }
        } else {
            None
        }
    }

    pub(crate) fn fail_all(&mut self) -> (out: Vec<Req>)
        requires
            old(self).wf(),
        ensures
            final(self).wf(),
            final(self).queue().len() == 0,
            final(self).done().len() == 0,
            out@ == reqs_of(old(self).done()) + reqs_of(old(self).queue()),
    {
        let mut out = Vec::new();
        while self.finished.len() > 0
            invariant
                self.wf(),
                self.queue() == old(self).queue(),
                out@ + reqs_of(self.done()) == reqs_of(old(self).done()),
            decreases self.finished@.len(),
        {
            proof {
                self.ring.facts();
            }
            let front = self.finished.pop_front();
            if let Some(waiting) = front {
                out.push(waiting.req);
            }
        }
        while self.requests.len() > 0
            invariant
                self.wf(),
                self.done().len() == 0,
                out@ + reqs_of(self.queue()) == reqs_of(old(self).done()) + reqs_of(old(self).queue()),
            decreases self.requests@.len(),
        {
            let front = self.requests.pop_front();
            self.last_slice = Ghost(None);
            if let Some(waiting) = front {
                out.push(waiting.req);
            }
        }
        out
    }

    pub(crate) fn deliver_now<S: FnMut(&Reader, Req, Pos)>(&mut self, sink: &mut S) -> (r: Result<
        (),
        Fault,
    >)
        requires
            old(self).wf(),
        ensures
            final(self).wf(),
    {
        let upper = self.observe();
        self.deliver(upper, sink)
    }
}

} // verus!

impl fmt::Display for Fault {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Fault::Ring(invalid) => invalid.fmt(f),
            Fault::EarlySlice => f.write_str("ko-pane wrote a slice before its request"),
        }
    }
}

impl fmt::Debug for Delivery {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Delivery")
            .field("ring", &self.ring)
            .field("requests", &self.requests)
            .field("finished", &self.finished)
            .field("delivered", &self.delivered)
            .finish()
    }
}

impl Delivery {
    pub(crate) fn ring(&self) -> &Reader {
        &self.ring
    }

    // Unverified: a holder of the `&mut Reader` can call `head`, `end_offset`,
    // `oldest_offset` and `resume`, which keep the tail and only grow the log
    // (`inv_grows`). It must not call `advance`: only `scan` moves the tail.
    pub(crate) fn ring_mut(&mut self) -> &mut Reader {
        &mut self.ring
    }
}
