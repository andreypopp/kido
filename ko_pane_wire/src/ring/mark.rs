#![allow(dead_code, non_snake_case, unreachable_pub)]

use verus_state_machines_macros::tokenized_state_machine;
use vstd::prelude::*;
#[cfg(verus_only)]
use vstd::tokens::{ElementToken, InstanceId};

use super::spec::*;

verus! {

tokenized_state_machine!{
    LogMark {
        fields {
            #[sharding(constant)]
            pub cap: nat,
            #[sharding(variable)]
            pub cur: Log,
            #[sharding(persistent_set)]
            pub marks: Set<Log>,
        }

        #[invariant]
        pub fn current_wf(&self) -> bool {
            wf(self.cap, self.cur)
        }

        #[invariant]
        pub fn marks_below(&self) -> bool {
            forall|l: Log| #[trigger] self.marks.contains(l) ==> wf(self.cap, l) && log_le(l, self.cur)
        }

        init!{
            initialize(cap: nat, l: Log) {
                require(wf(cap, l));
                init cap = cap;
                init cur = l;
                init marks = Set::empty();
            }
        }

        transition!{
            grow(n: Log) {
                require(wf(pre.cap, n));
                require(log_le(pre.cur, n));
                update cur = n;
            }
        }

        transition!{
            mark() {
                add marks (union)= set { pre.cur };
            }
        }

        property!{
            bound(l: Log) {
                have marks >= set { l };
                assert(wf(pre.cap, l) && log_le(l, pre.cur));
            }
        }

        #[inductive(initialize)]
        fn initialize_inductive(post: Self, cap: nat, l: Log) {}

        #[inductive(grow)]
        fn grow_inductive(pre: Self, post: Self, n: Log) {
            assert forall|l: Log| #[trigger] post.marks.contains(l) implies wf(post.cap, l)
                && log_le(l, post.cur) by {
                log_le_trans(l, pre.cur, n);
            }
        }

        #[inductive(mark)]
        fn mark_inductive(pre: Self, post: Self) {
            log_le_refl(pre.cur);
            assert forall|l: Log| #[trigger] post.marks.contains(l) implies wf(post.cap, l)
                && log_le(l, post.cur) by {
                if l == pre.cur {
                } else {
                    assert(pre.marks.contains(l));
                }
            }
        }
    }
}

pub tracked struct Mark {
    tok: LogMark::marks,
}

impl Mark {
    pub closed spec fn log(self) -> Log {
        self.tok.element()
    }

    pub closed spec fn id(self) -> InstanceId {
        self.tok.instance_id()
    }
}

pub tracked struct Marks {
    inst: LogMark::Instance,
    cur: LogMark::cur,
}

impl Marks {
    pub closed spec fn wf(self, cap: nat, log: Log) -> bool {
        &&& self.cur.instance_id() == self.inst.id()
        &&& self.inst.cap() == cap
        &&& self.cur.value() == log
    }

    pub closed spec fn id(self) -> InstanceId {
        self.inst.id()
    }

    pub proof fn new(cap: nat, log: Log) -> (tracked m: Marks)
        requires
            wf(cap, log),
        ensures
            m.wf(cap, log),
    {
        let tracked (Tracked(inst), Tracked(cur), _) = LogMark::Instance::initialize(cap, log);
        Marks { inst, cur }
    }

    pub proof fn grow(tracked &mut self, cap: nat, before: Log, log: Log)
        requires
            old(self).wf(cap, before),
            wf(cap, log),
            log_le(before, log),
        ensures
            final(self).wf(cap, log),
            final(self).id() == old(self).id(),
    {
        self.inst.grow(log, &mut self.cur);
    }

    pub proof fn mark(tracked &self, cap: nat, log: Log) -> (tracked m: Mark)
        requires
            self.wf(cap, log),
        ensures
            m.id() == self.id(),
            m.log() == log,
    {
        let tracked tok = self.inst.mark(&self.cur);
        Mark { tok }
    }

    pub proof fn bound(tracked &self, tracked m: &Mark, cap: nat, log: Log)
        requires
            self.wf(cap, log),
            m.id() == self.id(),
        ensures
            wf(cap, m.log()),
            log_le(m.log(), log),
    {
        self.inst.bound(m.tok.element(), &self.cur, &m.tok);
    }
}

} // verus!
