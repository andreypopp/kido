use ko_pane_wire::ring::{Invalid, Mark, Pos, Reach, Reader, RecordKind};
#[cfg(verus_only)]
use ko_pane_wire::ring::{
    Log, cursor_grows, cursor_ok, next_bnd, off_at, reach_cursor, rec_bounds, sent_cursor, wf_rec,
};
use vstd::prelude::*;

use crate::conn::Output;
use crate::delivery::Delivery;
#[cfg(verus_only)]
use crate::delivery::instance_of;
use crate::ids::PaneId;
use crate::link::Wire;
use crate::pane_proc::Death;
use crate::protocol::{self, Dead as WireDead, OutputBytes, OutputEvent};

verus! {

#[verifier::external_type_specification]
#[verifier::external_body]
#[allow(dead_code, unreachable_pub)]
pub struct ExDeath(Death);

const CHUNK: u64 = 32768;

pub(crate) struct Tail {
    pub(crate) pane: PaneId,
    cpos: Pos,
    coff: u64,
    lost: Option<u64>,
    ended: bool,
    stamp: u64,
    mark: Tracked<Mark>,
}

impl Tail {
    spec fn streaming(self, l: Log) -> bool {
        cursor_ok(l, self.cpos.v() as nat, self.coff as nat)
    }

    spec fn tied(self) -> bool {
        self.mark@.id() == instance_of(self.stamp)
    }

    pub(crate) closed spec fn offset(self) -> nat {
        self.coff as nat
    }

    pub(crate) closed spec fn wf(self) -> bool {
        &&& self.tied()
        &&& self.streaming(self.mark@.log())
    }
}

// Assumes: it sends the bytes record that starts at `offset` on the wire's output only, from the
// payload of the record at `at` without its first `skip` bytes, and never reopens a closed output.
#[verifier::external_body]
fn emit_bytes(wire: &mut Wire<'_>, ring: &Reader, at: Pos, offset: u64, skip: u64, len: u64) -> (r: Result<(), Invalid>) {
    let payload = ring.payload(at)?;
    let data = usize::try_from(skip)
        .ok()
        .and_then(|skip| payload.get(skip..))
        .zip(usize::try_from(len).ok())
        .and_then(|(rest, len)| rest.get(..len))
        .ok_or(Invalid::Record)?;
    let event = OutputBytes::Bytes { offset, data };
    let size = data.len().div_ceil(3).saturating_mul(4).saturating_add(64);
    wire.ws.send(wire.out, protocol::json_sized(&event, size));
    Ok(())
}

// Assumes: it sends the skip event on the wire's output only, and never reopens a closed output.
#[verifier::external_body]
fn emit_skip(wire: &mut Wire<'_>, from: u64, to: u64) {
    wire.ws.send(wire.out, protocol::json(&OutputEvent::Skip { from, to }));
}

// Assumes: it sends the death on the wire's output, then the normal close frame, on that output
// only, and never reopens a closed output.
#[verifier::external_body]
fn emit_dead(wire: &mut Wire<'_>, death: &Death) {
    wire.ws.send(wire.out, protocol::json(&OutputEvent::Dead(WireDead::from(death))));
    wire.ws.finish(wire.out);
}

impl Tail {
    pub(crate) fn new(pane: PaneId, d: &mut Delivery, offset: Option<u64>) -> (r: Result<Option<Tail>, Invalid>)
        requires
            old(d).wf(),
        ensures
            final(d).grew(*old(d)),
            r is Ok && r->Ok_0 is Some ==> r->Ok_0->Some_0.wf(),
    {
        proof {
            d.facts();
        }
        let ghost d0 = *d;
        let end = d.end_offset()?.get();
        let ghost d1 = *d;
        let want = match offset {
            Some(offset) => offset,
            None => end,
        };
        let placed = d.seek(want);
        proof {
            Delivery::grew_trans(d0, d1, *d);
        }
        match placed? {
            Some((cpos, coff)) => Ok(
                Some(
                    Tail {
                        pane,
                        cpos,
                        coff,
                        lost: if want < coff {
                            Some(want)
                        } else {
                            None
                        },
                        ended: false,
                        stamp: d.stamp(),
                        mark: d.mark(),
                    },
                ),
            ),
            None => Ok(None),
        }
    }

    pub(crate) fn close(&mut self, out: &mut Output)
        ensures
            old(self).wf() ==> final(self).wf(),
            final(self).offset() == old(self).offset(),
    {
        self.ended = true;
        out.close();
    }

    fn pump_live(&mut self, wire: &mut Wire<'_>, d: &mut Delivery, dead: Option<&Death>) -> (r: Result<(), Invalid>)
        requires
            old(d).wf(),
            old(self).streaming(old(d).log()),
        ensures
            final(d).grew(*old(d)),
            final(self).streaming(final(d).log()),
            final(self).stamp == old(self).stamp,
            old(self).offset() <= final(self).offset(),
            (final(self).ended && !old(self).ended) ==> final(self).cpos.v() as nat == final(d).log().head,
    {
        proof {
            d.facts();
        }
        let ghost d0 = *d;
        let upper = d.head();
        proof {
            d.facts();
            cursor_grows(d.cap(), d0.log(), d.log(), self.cpos.v() as nat, self.coff as nat);
        }
        if self.ended || !wire.out.available() {
            return Ok(());
        }
        let ghost d1 = *d;
        if self.cpos.get() < upper.get() {
            let reach = d.ring().reachable(self.cpos);
            match reach {
                Reach::Behind => {
                    let from = self.coff;
                    let placed = d.seek(from);
                    proof {
                        Delivery::grew_trans(d0, d1, *d);
                        d.facts();
                        cursor_grows(d.cap(), d1.log(), d.log(), self.cpos.v() as nat, self.coff as nat);
                    }
                    match placed {
                        Ok(Some((cpos, coff))) => {
                            self.cpos = cpos;
                            self.coff = coff;
                            if from < coff && self.lost.is_none() {
                                self.lost = Some(from);
                            }
                        },
                        Ok(None) => return Err(Invalid::Record),
                        Err(e) => return Err(e),
                    }
                },
                Reach::At(pos) => {
                    proof {
                        reach_cursor(
                            d.cap(),
                            d.log(),
                            d.tl(),
                            self.cpos.v() as nat,
                            self.coff as nat,
                            pos.v() as nat,
                        );
                    }
                    self.cpos = pos;
                },
            }
        }
        if let Some(from) = self.lost {
            emit_skip(wire, from, self.coff);
            self.lost = None;
        }
        let ghost d2 = *d;
        let upper = d.head();
        proof {
            d.facts();
            Delivery::grew_trans(d0, d2, *d);
            cursor_grows(d.cap(), d2.log(), d.log(), self.cpos.v() as nat, self.coff as nat);
        }
        let ring = d.ring();
        let ghost l = ring.log();
        let ghost tl = ring.tl();
        proof {
            ring.facts();
            assert(tl <= self.cpos.v());
        }
        while self.cpos.get() < upper.get() && wire.out.available()
            invariant
                d0 == *old(d),
                old(self).coff <= self.coff,
                self.stamp == old(self).stamp,
                self.ended == old(self).ended,
                ring.wf(),
                ring.log() == l,
                ring.tl() == tl,
                d.grew(d0),
                d.log() == l,
                upper.v() as nat == l.head,
                self.streaming(l),
                tl <= self.cpos.v(),
            decreases
                l.head - self.cpos.v() as int,
                off_at(l, next_bnd(l, self.cpos.v() as nat)) as int - self.coff as int,
        {
            let here = self.cpos;
            proof {
                ring.facts();
                assert(ring.visible(here.v()));
            }
            let record = ring.record(here)?;
            proof {
                wf_rec(ring.cap(), l, here.v() as nat);
                rec_bounds(ring.cap(), l, here.v() as nat);
                assert(off_at(l, record.next.v() as nat) == if record.kind == RecordKind::Bytes {
                    (record.offset.v() + record.len) as nat
                } else {
                    record.offset.v() as nat
                });
            }
            if matches!(record.kind, RecordKind::Bytes) {
                let start = record.offset.get();
                let skip = self.coff - start;
                let left = record.len - skip;
                if left == 0 {
                    proof {
                        sent_cursor(ring.cap(), l, record.next.v() as nat, self.coff as nat);
                    }
                    self.cpos = record.next;
                } else {
                    let take = if left > CHUNK {
                        CHUNK
                    } else {
                        left
                    };
                    emit_bytes(wire, ring, here, self.coff, skip, take)?;
                    self.coff += take;
                    if take == left {
                        proof {
                            sent_cursor(ring.cap(), l, record.next.v() as nat, self.coff as nat);
                        }
                        self.cpos = record.next;
                    }
                }
            } else {
                proof {
                    sent_cursor(ring.cap(), l, record.next.v() as nat, self.coff as nat);
                }
                self.cpos = record.next;
            }
        }
        match dead {
            Some(dead) if self.cpos.get() >= upper.get() && wire.out.available() => {
                emit_dead(wire, dead);
                self.ended = true;
            },
            _ => {},
        }
        Ok(())
    }

    pub(crate) fn pump(&mut self, wire: &mut Wire<'_>, d: &mut Delivery, dead: Option<&Death>) -> (r: Result<(), Invalid>)
        requires
            old(self).wf(),
            old(d).wf(),
        ensures
            final(self).wf(),
            final(d).wf(),
            old(self).offset() <= final(self).offset(),
    {
        if d.stamp() != self.stamp {
            self.close(&mut *wire.out);
            return Ok(());
        }
        proof {
            d.facts();
            d.bound(self.mark.borrow());
            cursor_grows(d.cap(), self.mark@.log(), d.log(), self.cpos.v() as nat, self.coff as nat);
        }
        let r = self.pump_live(wire, d, dead);
        self.mark = d.mark();
        r
    }
}

} // verus!

impl Tail {
    pub(crate) fn remove(&mut self, wire: &mut Wire<'_>) {
        if !self.ended {
            self.ended = true;
            wire.ws.abort(wire.out, "pane removed");
        }
    }
}

impl std::fmt::Debug for Tail {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Tail")
            .field("pane", &self.pane)
            .field("cpos", &self.cpos)
            .field("coff", &self.coff)
            .field("lost", &self.lost)
            .field("ended", &self.ended)
            .finish_non_exhaustive()
    }
}
