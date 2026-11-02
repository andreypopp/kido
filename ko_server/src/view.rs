use ko_pane_wire::frame::{Dead, History};
use ko_pane_wire::ring::{self, Invalid, Mark, Offset, Pos, Reach, Reader, Record, RecordKind};
#[cfg(verus_only)]
use ko_pane_wire::ring::{
    Log, before as replayed, boundary, is_data, log_le, log_le_boundary, log_le_head, log_le_same,
    log_le_trans, log_wf, lost, lost_at, next_bnd, off_at, off_mono, quiet, rec_bounds, resumes,
    size, wf_head, wf_rec,
};
use vstd::prelude::*;
#[cfg(verus_only)]
use vstd::view::View as _;

#[cfg(verus_only)]
use crate::conn::BATCH;
use crate::conn::{Batch, Output, Written};
#[cfg(verus_only)]
use crate::delivery::instance_of;
use crate::delivery::{Delivery, Done, Handle};
use crate::ids::{ClientId, PaneId};
use crate::link::Wire;
use crate::protocol::{self, Marked, Skipped, ViewEvent};
use crate::ws::{self, Ws};

verus! {

#[verifier::external_type_specification]
#[verifier::external_body]
#[allow(dead_code, unreachable_pub)]
pub struct ExPaneId(PaneId);

#[verifier::external_type_specification]
#[verifier::external_body]
#[allow(dead_code, unreachable_pub)]
pub struct ExClientId(ClientId);

#[verifier::external_type_specification]
#[allow(dead_code, unreachable_pub)]
pub struct ExHistory(History);

#[verifier::external_type_specification]
#[verifier::external_body]
#[allow(dead_code, unreachable_pub)]
pub struct ExDead(Dead);

#[verifier::external_type_specification]
#[verifier::external_body]
#[allow(dead_code, unreachable_pub)]
pub struct ExWs(Ws);

const RESUME_THRESHOLD: u64 = 65536;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Decision {
    Resume,
    Snapshot(History),
    Skip,
}

fn decide(
    behind: bool,
    offset: u64,
    head: u64,
    history: History,
    resize: bool,
    blocked: bool,
) -> (d: Decision)
    ensures
        (d is Skip) <==> (blocked && head as int - offset as int >= 65536),
        (d is Resume) ==> !behind,
        (d is Resume) <==> (!(blocked && head as int - offset as int >= 65536) && !behind
            && !(resize && history is None)),
{
    let gap = head.saturating_sub(offset);
    if blocked && gap >= RESUME_THRESHOLD {
        Decision::Skip
    } else if behind {
        Decision::Snapshot(history)
    } else if resize && matches!(history, History::None) {
        Decision::Snapshot(History::None)
    } else {
        Decision::Resume
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Stage {
    Live,
    Snapshotting { serial: u64, received: u64 },
    Closed,
}

spec fn cursor_ok(l: Log, cp: nat, co: nat) -> bool {
    &&& cp <= l.head
    &&& boundary(l, cp)
    &&& off_at(l, cp) <= co
    &&& co <= off_at(l, next_bnd(l, cp))
}

pub(crate) struct View {
    pub(crate) pane: PaneId,
    pub(crate) client: Option<ClientId>,
    stage: Stage,
    cpos: Pos,
    coff: u64,
    blocked: bool,
    history: History,
    wanted: Option<History>,
    batch: Batch,
    stamp: u64,
    mark: Tracked<Mark>,
}

impl View {
    spec fn bend(self) -> nat {
        if self.batch@.len() > 0 {
            self.batch@.last().1 as nat
        } else {
            self.coff as nat
        }
    }

    spec fn streaming(self, l: Log) -> bool {
        cursor_ok(l, self.cpos.v() as nat, self.coff as nat)
    }

    spec fn entry_ok(self, l: Log, e: (Pos, u64)) -> bool {
        &&& boundary(l, e.0.v() as nat)
        &&& e.0.v() as nat <= l.head
        &&& self.cpos.v() < e.0.v()
        &&& e.1 as nat == off_at(l, e.0.v() as nat)
    }

    spec fn batch_ok(self, l: Log) -> bool {
        forall|i: int| 0 <= i < self.batch@.len() ==> self.entry_ok(l, #[trigger] self.batch@[i])
    }

    spec fn inv(self, l: Log) -> bool {
        &&& (self.stage is Snapshotting && self.stage->Snapshotting_received > 0) ==> self.streaming(l)
        &&& (self.stage is Live && self.wanted is None) ==> self.streaming(l)
        &&& !(self.stage is Closed) ==> self.batch@.len() == 0
    }

    spec fn resuming(self, l: Log, tl: nat, pos: nat, go: bool) -> bool {
        &&& self.cpos.v() <= pos
        &&& pos <= l.head
        &&& boundary(l, pos)
        &&& tl <= self.cpos.v()
        &&& self.batch_ok(l)
        &&& self.stage is Live || self.stage is Closed
        &&& self.stage is Closed ==> !go
        &&& go ==> self.stage is Live
        &&& self.stage is Live ==> self.streaming(l)
        &&& forall|i: int| 0 <= i < self.batch@.len() ==> (#[trigger] self.batch@[i]).0.v() <= pos
        &&& (go && self.batch@.len() == 0) ==> (off_at(l, pos) == self.coff as nat || pos == self.cpos.v())
        &&& (go && self.batch@.len() > 0) ==> self.bend() == off_at(l, pos)
        &&& self.batch@.len() == 0 || go
    }

    spec fn tied(self) -> bool {
        self.mark@.id() == instance_of(self.stamp)
    }

    pub(crate) closed spec fn kept(self, old: View) -> bool {
        &&& self.pane == old.pane
        &&& self.client == old.client
        &&& self.history == old.history
        &&& self.stamp == old.stamp
        &&& self.mark@ == old.mark@
    }

    spec fn same_kept(self, old: View) -> bool {
        &&& self.kept(old)
        &&& self.wanted == old.wanted
    }

    pub(crate) closed spec fn wf(self) -> bool {
        &&& self.tied()
        &&& self.inv(self.mark@.log())
    }
}


proof fn cursor_grows(cap: nat, a: Log, b: Log, cp: nat, co: nat)
    requires
        log_wf(cap, a),
        log_wf(cap, b),
        log_le(a, b),
        cursor_ok(a, cp, co),
    ensures
        cursor_ok(b, cp, co),
{
    log_le_head(a, b);
    log_le_boundary(cap, a, b, cp);
    if a.m.contains_key(cp) {
        wf_rec(cap, a, cp);
        log_le_same(a, b, cp);
        log_le_boundary(cap, a, b, next_bnd(a, cp));
    } else {
        assert(cp == a.head);
        if b.m.contains_key(cp) {
            wf_rec(cap, b, cp);
        }
    }
}

proof fn sent_cursor(cap: nat, l: Log, next: nat, end: nat)
    requires
        log_wf(cap, l),
        boundary(l, next),
        next <= l.head,
        end == off_at(l, next),
    ensures
        cursor_ok(l, next, end),
{
    if l.m.contains_key(next) {
        wf_rec(cap, l, next);
        off_mono(cap, l, next, next_bnd(l, next));
    }
}

proof fn reach_cursor(cap: nat, l: Log, tl: nat, cp: nat, co: nat, p: nat)
    requires
        log_wf(cap, l),
        boundary(l, tl),
        tl <= l.head,
        cursor_ok(l, cp, co),
        !lost(l, tl, cp),
        p == if cp < tl { tl } else { cp },
    ensures
        cursor_ok(l, p, co),
{
    if cp < tl {
        wf_head(cap, l);
        assert(l.m.contains_key(cp));
        wf_rec(cap, l, cp);
        let next = cp + size(l.m[cp]);
        assert(!is_data(l.m[cp])) by {
            if is_data(l.m[cp]) {
                assert(lost_at(l, cp, cp));
            }
        }
        assert(next <= tl) by {
            if tl < next {
                assert(!l.m.contains_key(tl));
                assert(tl == l.head);
            }
        }
        off_mono(cap, l, cp, next);
        if l.m.contains_key(tl) {
            wf_rec(cap, l, tl);
        }
        off_mono(cap, l, tl, next_bnd(l, tl));
        assert(quiet(l, cp, tl)) by {
            assert forall|q: nat| cp <= q < tl && #[trigger] l.m.contains_key(q) implies !is_data(l.m[q]) by {
                if is_data(l.m[q]) {
                    wf_rec(cap, l, q);
                    assert(lost_at(l, cp, q));
                }
            }
        }
        off_mono(cap, l, cp, tl);
    }
}

proof fn lost_grows(cap: nat, a: Log, b: Log, tl: nat, p: nat)
    requires
        log_wf(cap, a),
        log_wf(cap, b),
        log_le(a, b),
        tl <= a.head,
    ensures
        lost(a, tl, p) <==> lost(b, tl, p),
{
    if lost(a, tl, p) {
        let q = choose|q: nat| q < tl && #[trigger] lost_at(a, p, q);
        log_le_same(a, b, q);
        assert(lost_at(b, p, q));
    }
    if lost(b, tl, p) {
        let q = choose|q: nat| q < tl && #[trigger] lost_at(b, p, q);
        log_le_same(a, b, q);
        assert(lost_at(a, p, q));
    }
}

proof fn resume_cursor(cap: nat, l: Log, tl: nat, value: nat, p: nat)
    requires
        log_wf(cap, l),
        resumes(tl, l, value, p),
        off_at(l, tl) <= value,
        value <= l.head_offset,
    ensures
        cursor_ok(l, p, value),
{
    if p < l.head {
        assert(l.m.contains_key(p));
        wf_rec(cap, l, p);
        assert(!replayed(l.m[p], value));
        off_mono(cap, l, p, next_bnd(l, p));
    } else {
        wf_head(cap, l);
        assert(p == l.head);
    }
}

proof fn view_grows(v: View, cap: nat, a: Log, b: Log)
    requires
        log_wf(cap, a),
        log_wf(cap, b),
        log_le(a, b),
        v.inv(a),
        v.batch_ok(a),
    ensures
        v.inv(b),
        v.batch_ok(b),
        v.streaming(a) ==> v.streaming(b),
{
    if v.streaming(a) {
        cursor_grows(cap, a, b, v.cpos.v() as nat, v.coff as nat);
    }
    assert forall|i: int| 0 <= i < v.batch@.len() implies v.entry_ok(b, #[trigger] v.batch@[i]) by {
        let nx = v.batch@[i].0.v() as nat;
        log_le_boundary(cap, a, b, nx);
        log_le_head(a, b);
    }
}

impl View {
    pub(crate) fn new(pane: PaneId, client: Option<ClientId>, history: History, delivery: &Delivery) -> (v: View)
        requires
            delivery.wf(),
        ensures
            v.wf(),
    {
        View {
            pane,
            client,
            stage: Stage::Live,
            cpos: delivery.ring().tail(),
            coff: 0,
            blocked: false,
            history,
            wanted: Some(history),
            batch: Batch::new(),
            stamp: delivery.stamp(),
            mark: delivery.mark(),
        }
    }

    pub(crate) closed spec fn is_waiting(self, out: Output) -> bool {
        match self.stage {
            Stage::Closed => false,
            Stage::Snapshotting { .. } => true,
            Stage::Live => out.waits(),
        }
    }

    pub(crate) closed spec fn started_from(self, old: View, serial: u64) -> bool {
        if old.stage is Live {
            self.stage == (Stage::Snapshotting { serial, received: 0 })
        } else {
            self.stage == old.stage
        }
    }

    pub(crate) closed spec fn keeps_sealed(self, old: View, before: Output, after: Output) -> bool {
        &&& before.closed() ==> after.closed()
        &&& old.sealed(before) ==> self.sealed(after)
    }

    pub(crate) closed spec fn sealed(self, out: Output) -> bool {
        self.stage is Closed ==> out.closed()
    }

    pub(crate) closed spec fn shut(self, old: View) -> bool {
        &&& self.stage is Closed
        &&& self.cpos == old.cpos
        &&& self.coff == old.coff
        &&& self.blocked == old.blocked
        &&& self.batch@ == old.batch@
        &&& self.same_kept(old)
    }

    pub(crate) fn waiting(&self, out: &Output) -> (b: bool)
        ensures
            b == self.is_waiting(*out),
    {
        match self.stage {
            Stage::Closed => false,
            Stage::Snapshotting { .. } => true,
            Stage::Live => out.waiting(),
        }
    }

    pub(crate) fn close(&mut self, out: &mut Output)
        ensures
            final(self).shut(*old(self)),
            final(out).closed(),
    {
        self.stage = Stage::Closed;
        out.close();
    }

    pub(crate) fn reject(&mut self, wire: &mut Wire<'_>)
        ensures
            final(self).shut(*old(self)),
            final(wire).out.closed(),
    {
        reject_ws(wire);
        self.close(&mut *wire.out);
    }

    pub(crate) fn started(&mut self, serial: u64, history: History)
        requires
            old(self).wf(),
        ensures
            final(self).wf(),
            final(self).started_from(*old(self), serial),
    {
        if matches!(self.stage, Stage::Live) {
            self.stage = Stage::Snapshotting { serial, received: 0 };
            self.history = history;
            self.wanted = None;
        }
    }

    fn flush_wanted(&self, out: &Output) -> (r: Option<History>)
        ensures
            r is Some ==> self.stage is Live && self.wanted == r && !out.waits(),
            r is None ==> (self.stage is Live && self.wanted is Some ==> out.waits()),
    {
        if matches!(self.stage, Stage::Live) && self.wanted.is_some() && !out.waiting() {
            self.wanted
        } else {
            None
        }
    }

    pub(crate) closed spec fn requested(self, old: View, history: History, out: Output, r: Option<History>) -> bool {
        &&& forall|l: Log| old.inv(l) ==> #[trigger] self.inv(l)
        &&& self.stage == old.stage
        &&& self.cpos == old.cpos
        &&& self.coff == old.coff
        &&& self.blocked == old.blocked
        &&& self.batch@ == old.batch@
        &&& self.kept(old)
        &&& self.wanted == Some(history)
        &&& r is Some ==> self.stage is Live && self.wanted == r && !out.waits()
        &&& r is None ==> (self.stage is Live ==> out.waits())
    }

    pub(crate) fn request(&mut self, out: &Output, history: History) -> (r: Option<History>)
        ensures
            final(self).requested(*old(self), history, *out, r),
            old(self).wf() ==> final(self).wf(),
    {
        self.wanted = Some(history);
        self.flush_wanted(out)
    }

    pub(crate) closed spec fn completed(self, old: View, done: Done) -> bool {
        (old.stage is Snapshotting && self.stage is Live) ==> {
            &&& old.stage->Snapshotting_serial == done.serial_of()
            &&& old.stamp == done.stamp_of()
            &&& done.hold_of() is Some
            &&& self.cpos.v() == done.hold_of()->Some_0.v()
            &&& done.tl_of() <= self.cpos.v()
        }
    }

    pub(crate) fn on_done(&mut self, wire: &mut Wire<'_>, done: &Done, dead: Option<Dead>)
        requires
            old(self).wf(),
            done.valid(),
        ensures
            final(self).wf(),
            final(self).completed(*old(self), *done),
            final(self).keeps_sealed(*old(self), *old(wire).out, *final(wire).out),
    {
        match self.stage {
            Stage::Snapshotting { serial, received } if serial == done.serial()
                && self.stamp == done.stamp() => {
                let finished = match done.hold() {
                    Some(hold) => received > 0 && received == done.slices() && self.cpos.get()
                        == hold.get(),
                    None => false,
                };
                if finished {
                    proof {
                        assert(done.hold_of() is Some);
                        assert(self.cpos.v() == done.hold_of()->Some_0.v());
                        assert(done.tl_of() <= self.cpos.v());
                    }
                    self.stage = Stage::Live;
                    if let Some(dead) = dead {
                        emit_dead(wire, dead, self.coff);
                    }
                } else {
                    self.reject(wire);
                }
            },
            _ => {},
        }
    }
}




// Assumes: it sends on the wire's output only, and an output never reopens once closed.
#[verifier::external_body]
fn reject_ws(wire: &mut Wire<'_>)
    ensures
        old(wire).out.closed() ==> final(wire).out.closed(),
{
    wire.ws.reject(wire.out, "io");
}

// Assumes: it sends the marker at `here` on the wire's output only, and never reopens a closed output.
#[verifier::external_body]
fn emit_marked(wire: &mut Wire<'_>, ring: &Reader, here: Pos, offset: u64) -> (r: Result<(), Invalid>)
    ensures
        old(wire).out.closed() ==> final(wire).out.closed(),
{
    match ring.marker(here) {
        Ok(marker) => {
            send_marked(wire, marker, offset);
            Ok(())
        },
        Err(e) => Err(e),
    }
}

// Assumes: it sends the death at `offset` on the wire's output only, and never reopens a closed output.
#[verifier::external_body]
fn emit_dead(wire: &mut Wire<'_>, dead: Dead, offset: u64)
    ensures
        old(wire).out.closed() ==> final(wire).out.closed(),
{
    send_marked(wire, ring::Marker::Dead(dead), offset);
}

// Assumes: it sends the skip event on the wire's output only, and never reopens a closed output.
#[verifier::external_body]
fn emit_skipped(wire: &mut Wire<'_>, head: u64, from: u64)
    requires
        from <= head,
    ensures
        old(wire).out.closed() ==> final(wire).out.closed(),
{
    let skipped = Skipped { offset: head, from, to: head };
    wire.ws.send(wire.out, protocol::json(&ViewEvent::Skipped(skipped)));
}

// Assumes: it writes the slice record to the output, closes the output when the write fails, and
// never reopens a closed output.
#[verifier::external_body]
fn write_slice(out: &mut Output, ring: &Reader, at: Pos, offset: u64) -> (r: Result<Written, Invalid>)
    ensures
        old(out).closed() ==> final(out).closed(),
        r is Ok && r->Ok_0 is Closed ==> final(out).closed(),
{
    match ring.payload(at) {
        Ok(payload) => Ok(out.record(true, ws::Record::Snapshot, offset, payload)),
        Err(e) => Err(e),
    }
}

// Assumes: it decodes the marker at `pos` and reports whether it is a resize.
#[verifier::external_body]
fn resize_marker(ring: &Reader, pos: Pos) -> (r: Result<bool, Invalid>) {
    match ring.marker(pos) {
        Ok(marker) => Ok(matches!(marker, ring::Marker::Resize(_))),
        Err(e) => Err(e),
    }
}


impl View {
    fn flush_batch(&mut self, out: &mut Output, ring: &Reader) -> (ok: bool)
        requires
            old(self).stage is Live,
            ring.wf(),
            old(self).batch_ok(ring.log()),
            old(self).streaming(ring.log()),
        ensures
            final(self).batch@.len() == 0,
            final(self).stage is Closed || final(self).stage is Live,
            final(self).stage is Live ==> final(self).streaming(ring.log()),
            ok ==> final(self).stage is Live && final(self).coff as nat == old(self).bend(),
            !ok ==> final(self).stage is Closed || final(self).blocked,
            old(self).cpos.v() <= final(self).cpos.v(),
            final(self).cpos == old(self).cpos || exists|i: int|
                0 <= i < old(self).batch@.len() && final(self).cpos == (#[trigger] old(self).batch@[i]).0,
            final(self).same_kept(*old(self)),
            final(self).keeps_sealed(*old(self), *old(out), *final(out)),
    {
        proof {
            ring.facts();
        }
        let count = self.batch.len();
        if count == 0 {
            return true;
        }
        let ghost before = *self;
        let accepted = out.send_batch(&self.batch, ring);
        let taken = accepted.unwrap_or_default();
        let moved = self.batch.sent(taken);
        if let Some((next, end)) = moved {
            proof {
                let i = taken - 1;
                assert(before.entry_ok(ring.log(), before.batch@[i as int]));
                sent_cursor(ring.cap(), ring.log(), next.v() as nat, end as nat);
            }
            self.cpos = next;
            self.coff = end;
        }
        match accepted {
            None => {
                self.close(out);
                false
            },
            Some(accepted) => {
                if accepted < count || out.waiting() {
                    self.blocked = true;
                    false
                } else {
                    true
                }
            },
        }
    }

    fn step_bytes(&mut self, out: &mut Output, ring: &Reader, here: Pos, record: Record) -> (go: bool)
        requires
            ring.wf(),
            ring.describes(here, record),
            record.kind == RecordKind::Bytes,
            old(self).resuming(ring.log(), ring.tl(), here.v() as nat, true),
            old(self).batch@.len() < BATCH,
        ensures
            final(self).resuming(ring.log(), ring.tl(), record.next.v() as nat, go),
            go ==> final(self).batch@.len() < BATCH,
            old(self).cpos.v() <= final(self).cpos.v(),
            final(self).same_kept(*old(self)),
            final(self).keeps_sealed(*old(self), *old(out), *final(out)),
    {
        proof {
            ring.facts();
            wf_rec(ring.cap(), ring.log(), here.v() as nat);
            rec_bounds(ring.cap(), ring.log(), here.v() as nat);
        }
        let start = record.offset.get();
        let end = start + record.len;
        let queued = self.batch.len();
        if end <= self.coff && queued == 0 {
            return true;
        }
        let skip = if queued == 0 && start < self.coff {
            self.coff - start
        } else {
            0
        };
        let len = (record.len - skip) as usize;
        proof {
            let l = ring.log();
            let h = here.v() as nat;
            let n = record.next.v() as nat;
            assert(off_at(l, h) == start as nat);
            assert(off_at(l, n) == end as nat);
            if queued == 0 {
                assert(start as nat + skip as nat == self.coff as nat);
            } else {
                assert(start as nat + skip as nat == self.bend());
            }
        }
        self.batch.add(start + skip, here, skip as usize, len, record.next, end);
        if self.batch.full() {
            self.flush_batch(out, ring)
        } else {
            true
        }
    }

    fn step_marker(&mut self, wire: &mut Wire<'_>, ring: &Reader, here: Pos, record: Record) -> (r: Result<bool, Invalid>)
        requires
            ring.wf(),
            ring.describes(here, record),
            record.kind == RecordKind::Marker,
            old(self).resuming(ring.log(), ring.tl(), here.v() as nat, true),
            old(self).batch@.len() < BATCH,
        ensures
            final(self).same_kept(*old(self)),
            final(self).keeps_sealed(*old(self), *old(wire).out, *final(wire).out),
            r is Ok ==> final(self).resuming(
                ring.log(),
                ring.tl(),
                if r->Ok_0 { record.next.v() as nat } else { here.v() as nat },
                r->Ok_0,
            ),
            r is Ok && r->Ok_0 ==> final(self).batch@.len() == 0,
            r is Err ==> final(self).stage is Live && final(self).batch@.len() == 0
                && final(self).streaming(ring.log()),
            old(self).cpos.v() <= final(self).cpos.v(),
    {
        proof {
            ring.facts();
            wf_rec(ring.cap(), ring.log(), here.v() as nat);
        }
        let ghost before = *self;
        if !self.flush_batch(&mut *wire.out, ring) {
            return Ok(false);
        }
        proof {
            let l = ring.log();
            let h = here.v() as nat;
            let n = record.next.v() as nat;
            if before.batch@.len() == 0 && h == before.cpos.v() as nat {
                wf_rec(ring.cap(), l, h);
            }
            assert(record.offset.v() as nat == off_at(l, h));
            assert(self.coff as nat == off_at(l, h));
            assert(off_at(l, n) == record.offset.v() as nat);
            sent_cursor(ring.cap(), l, n, self.coff as nat);
        }
        match emit_marked(wire, ring, here, record.offset.get()) {
            Ok(()) => {
                self.cpos = record.next;
                Ok(true)
            },
            Err(e) => Err(e),
        }
    }

    fn resume(&mut self, wire: &mut Wire<'_>, d: &mut Delivery) -> (r: Result<(), Invalid>)
        requires
            old(d).wf(),
            old(self).stage is Live,
            old(self).inv(old(d).log()),
            old(self).batch@.len() == 0,
            old(self).streaming(old(d).log()),
            old(d).tl() <= old(self).cpos.v(),
        ensures
            final(d).grew(*old(d)),
            final(self).inv(final(d).log()),
            final(self).batch@.len() == 0,
            final(self).stage is Live ==> final(self).streaming(final(d).log()),
            final(self).stage is Live || final(self).stage is Closed,
            final(self).same_kept(*old(self)),
            old(self).cpos.v() <= final(self).cpos.v(),
            final(self).keeps_sealed(*old(self), *old(wire).out, *final(wire).out),
    {
        proof {
            d.facts();
        }
        let ghost before = *d;
        let upper = d.head();
        proof {
            assert(before == *old(d));
            view_grows(*self, d.cap(), before.log(), d.log());
        }
        let ring = d.ring();
        let ghost l = ring.log();
        let ghost tl = ring.tl();
        let mut pos = self.cpos;
        let mut going = true;
        while going && pos.get() < upper.get()
            invariant
                before == *old(d),
                d.grew(before),
                ring.wf(),
                ring.log() == l,
                ring.tl() == tl,
                d.log() == l,
                upper.v() as nat == l.head,
                self.resuming(l, tl, pos.v() as nat, going),
                going ==> self.batch@.len() < BATCH,
                self.same_kept(*old(self)),
                old(self).cpos.v() <= self.cpos.v(),
                self.keeps_sealed(*old(self), *old(wire).out, *wire.out),
            decreases if going { 1 + l.head - pos.v() as int } else { 0int },
        {
            proof {
                ring.facts();
                assert(ring.visible(pos.v()));
            }
            let record = ring.record(pos)?;
            proof {
                wf_rec(ring.cap(), l, pos.v() as nat);
            }
            match record.kind {
                RecordKind::Bytes => {
                    going = self.step_bytes(&mut *wire.out, ring, pos, record);
                    pos = record.next;
                },
                RecordKind::Marker => {
                    going = self.step_marker(wire, ring, pos, record)?;
                    if going {
                        pos = record.next;
                    }
                },
                RecordKind::Slice | RecordKind::Pad => {
                    proof {
                        wf_rec(ring.cap(), l, pos.v() as nat);
                    }
                    pos = record.next;
                },
            }
        }
        if going && self.flush_batch(&mut *wire.out, ring) && self.cpos.get() < upper.get()
            && upper.get() <= pos.get()
        {
            proof {
                ring.facts();
                sent_cursor(ring.cap(), l, pos.v() as nat, self.coff as nat);
            }
            self.cpos = pos;
        }
        Ok(())
    }

    fn resize_pending(&self, d: &mut Delivery, from: Pos) -> (r: Result<bool, Invalid>)
        requires
            old(d).wf(),
            old(d).tl() <= from.v(),
            from.v() as nat <= old(d).log().head,
            boundary(old(d).log(), from.v() as nat),
        ensures
            final(d).grew(*old(d)),
    {
        proof {
            d.facts();
        }
        let ghost before = *d;
        let upper = d.head();
        proof {
            assert(before == *old(d));
            log_le_boundary(d.cap(), before.log(), d.log(), from.v() as nat);
            log_le_head(before.log(), d.log());
        }
        let ring = d.ring();
        let ghost l = ring.log();
        let mut pos = from;
        while pos.get() < upper.get()
            invariant
                before == *old(d),
                d.grew(before),
                ring.wf(),
                ring.log() == l,
                ring.tl() == d.tl(),
                d.log() == l,
                upper.v() as nat == l.head,
                boundary(l, pos.v() as nat),
                d.tl() <= pos.v(),
                pos.v() as nat <= l.head,
            decreases l.head - pos.v() as int,
        {
            proof {
                ring.facts();
                assert(ring.visible(pos.v()));
            }
            let record = ring.record(pos)?;
            proof {
                wf_rec(ring.cap(), l, pos.v() as nat);
            }
            if matches!(record.kind, RecordKind::Marker) {
                match resize_marker(ring, pos) {
                    Ok(true) => {
                        if self.coff <= record.offset.get() {
                            return Ok(true);
                        }
                    },
                    Ok(false) => {},
                    Err(e) => return Err(e),
                }
            }
            pos = record.next;
        }
        Ok(false)
    }

    fn pump_live(&mut self, wire: &mut Wire<'_>, d: &mut Delivery) -> (r: Result<Option<History>, Invalid>)
        requires
            old(d).wf(),
            old(self).stage is Live,
            old(self).inv(old(d).log()),
            old(self).wanted is Some ==> old(wire).out.waits(),
        ensures
            final(d).grew(*old(d)),
            final(self).inv(final(d).log()),
            final(self).stage is Live || final(self).stage is Closed,
            final(self).kept(*old(self)),
            r is Ok && r->Ok_0 is Some ==> (old(self).blocked || old(self).history is None
                || lost(old(d).log(), old(d).tl(), old(self).cpos.v() as nat)),
            final(self).keeps_sealed(*old(self), *old(wire).out, *final(wire).out),
    {
        proof {
            d.facts();
        }
        let ghost d0 = *d;
        let upper = d.head();
        proof {
            view_grows(*self, d.cap(), d0.log(), d.log());
        }
        if self.cpos.get() >= upper.get() || !wire.out.available() {
            return Ok(None);
        }
        let ghost d1 = *d;
        let ghost entry = *self;
        let reach = d.ring().reachable(self.cpos);
        let behind = match reach {
            Reach::Behind => true,
            Reach::At(pos) => {
                self.cpos = pos;
                false
            },
        };
        proof {
            if !behind {
                reach_cursor(
                    d.cap(),
                    d1.log(),
                    d.tl(),
                    entry.cpos.v() as nat,
                    entry.coff as nat,
                    self.cpos.v() as nat,
                );
            }
            lost_grows(d.cap(), d0.log(), d1.log(), d.tl(), entry.cpos.v() as nat);
        }
        let resize = if !behind && matches!(self.history, History::None) {
            let ghost before = *d;
            let found = self.resize_pending(d, self.cpos);
            proof {
                view_grows(*self, d.cap(), before.log(), d.log());
                Delivery::grew_trans(d0, before, *d);
            }
            found?
        } else {
            false
        };
        let ghost d2 = *d;
        let head = d.end_offset()?.get();
        proof {
            view_grows(*self, d.cap(), d2.log(), d.log());
            Delivery::grew_trans(d0, d2, *d);
        }
        let decision = decide(behind, self.coff, head, self.history, resize, self.blocked);
        self.blocked = false;
        match decision {
            Decision::Skip => {
                let ghost d3 = *d;
                let end = d.end_offset()?.get();
                proof {
                    view_grows(*self, d.cap(), d3.log(), d.log());
                    Delivery::grew_trans(d0, d3, *d);
                    log_le_head(d3.log(), d.log());
                }
                emit_skipped(wire, end, self.coff);
                let r = self.request(&*wire.out, History::None);
                self.coff = end;
                Ok(r)
            },
            Decision::Snapshot(history) => Ok(self.request(&*wire.out, history)),
            Decision::Resume => {
                let ghost d4 = *d;
                let r = self.resume(wire, d);
                proof {
                    Delivery::grew_trans(d0, d4, *d);
                }
                match r {
                    Ok(()) => Ok(None),
                    Err(e) => Err(e),
                }
            },
        }
    }

    pub(crate) closed spec fn took(self, old: View, handle: Handle<'_>) -> bool {
        self.cpos != old.cpos ==> old.accepts(handle)
    }

    pub(crate) closed spec fn accepts(self, handle: Handle<'_>) -> bool {
        &&& self.stage is Snapshotting
        &&& self.stage->Snapshotting_serial == handle.serial_of()
        &&& self.stamp == handle.stamp_of()
    }

    pub(crate) fn on_slice(&mut self, out: &mut Output, handle: Handle<'_>) -> (r: Result<(), Invalid>)
        requires
            old(self).wf(),
            handle.valid(),
        ensures
            final(self).wf(),
            final(self).took(*old(self), handle),
            final(self).keeps_sealed(*old(self), *old(out), *final(out)),
    {
        let (current, received) = match self.stage {
            Stage::Snapshotting { serial, received } => (serial, received),
            _ => return Ok(()),
        };
        if current != handle.serial() {
            return Ok(());
        }
        if handle.stamp() != self.stamp {
            return Err(Invalid::Slice);
        }
        let ring = handle.ring();
        proof {
            ring.facts();
            ring.bound(self.mark.borrow());
            view_grows(*self, ring.cap(), self.mark@.log(), ring.log());
        }
        let at = handle.pos();
        let record = ring.record(at)?;
        let offset = record.offset.get();
        if offset < self.coff {
            return Err(Invalid::Slice);
        }
        let written = write_slice(out, ring, at, offset)?;
        proof {
            let l = ring.log();
            wf_rec(ring.cap(), l, at.v() as nat);
            sent_cursor(ring.cap(), l, record.next.v() as nat, offset as nat);
        }
        if matches!(written, Written::Closed) {
            self.close(out);
        } else {
            self.stage = Stage::Snapshotting { serial: current, received: received.saturating_add(1) };
            if !matches!(written, Written::Accepted) {
                self.blocked = true;
            }
            self.cpos = record.next;
            self.coff = offset;
        }
        self.mark = ring.mark();
        Ok(())
    }

    pub(crate) closed spec fn pumped(self, old: View, r: Result<Option<History>, Invalid>, log: Log, tl: nat) -> bool {
        &&& (old.stage is Snapshotting || old.stage is Closed) ==> self.stage == old.stage && self.cpos == old.cpos
        &&& (old.stage is Live && old.wanted is None && r is Ok && r->Ok_0 is Some) ==> (old.blocked
            || old.history is None || lost(log, tl, old.cpos.v() as nat))
    }

    pub(crate) fn pump(&mut self, wire: &mut Wire<'_>, d: &mut Delivery) -> (r: Result<Option<History>, Invalid>)
        requires
            old(self).wf(),
            old(d).wf(),
        ensures
            final(self).wf(),
            final(d).wf(),
            final(self).pumped(*old(self), r, old(d).log(), old(d).tl()),
            final(self).keeps_sealed(*old(self), *old(wire).out, *final(wire).out),
    {
        if let Some(history) = self.flush_wanted(&*wire.out) {
            return Ok(Some(history));
        }
        if !matches!(self.stage, Stage::Live) {
            return Ok(None);
        }
        if d.stamp() != self.stamp {
            self.reject(wire);
            return Ok(None);
        }
        proof {
            d.facts();
            d.bound(self.mark.borrow());
            view_grows(*self, d.cap(), self.mark@.log(), d.log());
        }
        let r = self.pump_live(wire, d);
        self.mark = d.mark();
        r
    }

    pub(crate) fn open(&mut self, wire: &mut Wire<'_>, d: &mut Delivery, offset: Option<u64>) -> (r: Result<Option<History>, Invalid>)
        requires
            old(self).wf(),
            old(d).wf(),
        ensures
            final(self).wf(),
            final(d).wf(),
            final(self).keeps_sealed(*old(self), *old(wire).out, *final(wire).out),
    {
        if !matches!(self.stage, Stage::Live) || self.wanted.is_none() {
            return Ok(None);
        }
        if d.stamp() != self.stamp {
            self.reject(wire);
            return Ok(None);
        }
        proof {
            d.facts();
            d.bound(self.mark.borrow());
            view_grows(*self, d.cap(), self.mark@.log(), d.log());
        }
        let ghost l0 = d.log();
        let end = d.end_offset()?.get();
        proof {
            d.facts();
            view_grows(*self, d.cap(), l0, d.log());
        }
        self.coff = end;
        let mut resumed = false;
        if let Some(offset) = offset {
            let ghost l1 = d.log();
            proof {
                assert(end as nat == l1.head_offset);
            }
            let oldest = d.oldest_offset()?.get();
            proof {
                d.facts();
                view_grows(*self, d.cap(), l1, d.log());
            }
            if oldest <= offset && offset <= end {
                let ghost l2 = d.log();
                proof {
                    assert(off_at(l2, d.tl()) <= oldest as nat);
                }
                let p = d.resume(Offset::new(offset))?;
                proof {
                    d.facts();
                    log_le_boundary(d.cap(), l2, d.log(), d.tl());
                    log_le_trans(l1, l2, d.log());
                    log_le_head(l1, d.log());
                    resume_cursor(d.cap(), d.log(), d.tl(), offset as nat, p.v() as nat);
                }
                self.cpos = p;
                self.coff = offset;
                self.wanted = None;
                resumed = true;
            }
        }
        self.mark = d.mark();
        if resumed {
            self.pump(wire, d)
        } else {
            Ok(self.flush_wanted(&*wire.out))
        }
    }
}

} // verus!

fn send_marked(wire: &mut Wire<'_>, marker: ring::Marker, offset: u64) {
    let marked = Marked {
        offset,
        marker: marker.into(),
    };
    wire.ws
        .send(wire.out, protocol::json(&ViewEvent::Marked(marked)));
}

impl std::fmt::Debug for View {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("View")
            .field("pane", &self.pane)
            .field("client", &self.client)
            .field("stage", &self.stage)
            .field("cpos", &self.cpos)
            .field("coff", &self.coff)
            .finish_non_exhaustive()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::conn::tests::{full_output, output};
    use crate::delivery::mint_stamps;
    use crate::ws::Ws;
    use std::io::Read as _;

    fn drain(peer: &mut std::os::unix::net::UnixStream) -> Vec<u8> {
        let mut seen = Vec::new();
        let mut buffer = [0; 65536];
        while let Ok(count @ 1..) = peer.read(&mut buffer) {
            seen.extend_from_slice(&buffer[..count]);
        }
        seen
    }

    #[test]
    fn a_view_whose_socket_refused_a_write_whole_decides_no_skip_until_it_is_writable() {
        let (mut out, mut peer) = full_output();
        let mut delivery = Delivery::create(&mut mint_stamps(), 1 << 20).unwrap();
        let mut writer = delivery.ring().writer().unwrap();
        writer.available();
        writer.put(RecordKind::Bytes, &[1; 100_000]);
        delivery.head();
        let mut ws = Ws::new(Vec::new());
        let mut view = View::new(PaneId::new(1), None, History::None, &delivery);
        view.wanted = None;
        let mut pump = |view: &mut View, out: &mut Output| {
            view.pump(&mut Wire { ws: &mut ws, out }, &mut delivery)
                .unwrap()
        };
        assert_eq!(pump(&mut view, &mut out), None);
        assert!(view.blocked && out.waiting());
        assert_eq!(pump(&mut view, &mut out), None);
        assert!(view.blocked && out.waiting());
        let before = drain(&mut peer);
        assert!(!String::from_utf8_lossy(&before).contains("skipped"));
        out.writable();
        assert_eq!(pump(&mut view, &mut out), Some(History::None));
        out.flush();
        assert!(String::from_utf8_lossy(&drain(&mut peer)).contains("skipped"));
    }

    fn snapshot_with_a_dropped_slice(dropped: Option<usize>) -> Stage {
        let (mut out, _peer) = output();
        let mut delivery = Delivery::create(&mut mint_stamps(), 1 << 16).unwrap();
        let mut writer = delivery.ring().writer().unwrap();
        let mut ws = Ws::new(Vec::new());
        let mut view = View::new(PaneId::new(1), None, History::None, &delivery);
        let (serial, req) = delivery.request().unwrap();
        view.started(serial, History::None);
        for i in 0..3 {
            let mut body = vec![0; 100];
            body[0] = u8::from(i == 0) | (u8::from(i == 2) << 1);
            writer.available();
            writer.put(RecordKind::Slice, &body);
        }
        let mut seen = 0;
        let mut sink = |handle: Handle<'_>| {
            if Some(seen) != dropped {
                view.on_slice(&mut out, handle).unwrap();
            }
            seen += 1;
        };
        delivery.scan(&mut sink).unwrap();
        let done = delivery.snapshot_done(req).unwrap();
        view.on_done(
            &mut Wire {
                ws: &mut ws,
                out: &mut out,
            },
            &done,
            None,
        );
        view.stage
    }

    #[test]
    fn a_snapshot_completes_only_when_the_view_took_every_slice_up_to_the_hold() {
        assert_eq!(snapshot_with_a_dropped_slice(None), Stage::Live);
        for dropped in [1, 2] {
            assert_eq!(snapshot_with_a_dropped_slice(Some(dropped)), Stage::Closed);
        }
    }

    #[test]
    fn resume_resize_and_a_threshold_only_after_a_block() {
        let shown: Vec<&str> = [
            (10, false, true, false, false),
            (9, true, true, false, false),
            (10, false, false, true, false),
            (10, false, true, true, false),
            (10, false, true, false, true),
            (99999, false, false, false, true),
        ]
        .into_iter()
        .map(|(offset, behind, full, resize, blocked)| {
            let history = if full { History::All } else { History::None };
            match decide(behind, offset, 100000, history, resize, blocked) {
                Decision::Resume => "resume",
                Decision::Snapshot(History::All) => "full",
                Decision::Snapshot(History::None) => "screen",
                Decision::Skip => "skip",
            }
        })
        .collect();
        assert_eq!(
            shown,
            ["resume", "full", "screen", "resume", "skip", "resume"]
        );
    }
}
