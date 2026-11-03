#![allow(unreachable_pub)]

#[cfg(verus_only)]
use vstd::arithmetic::div_mod::{
    lemma_fundamental_div_mod, lemma_fundamental_div_mod_converse, lemma_mod_add_multiples_vanish,
    lemma_mod_equivalence, lemma_mod_sub_multiples_vanish, lemma_small_mod,
};
use vstd::prelude::*;

use super::RecordKind;
#[cfg(verus_only)]
use super::backend::{ByteTok, covers, dom_is, in_rng, tok_ok};
#[cfg(verus_only)]
use super::backend::{MAX_CAPACITY, MIN_CAPACITY};

verus! {

pub const HEADER: u64 = 13;
pub const PAD_ROOM: u64 = 2 * HEADER;
pub const MAX_HEAD: u64 = 0x3fff_ffff_0000_0000;
pub const MAX_OFFSET: u64 = 0x4000_0000_0000_0000;
pub const MAX_LENGTH: u64 = 0x1_0000_0000;
pub const BYTES: u8 = 1;
pub const MARKER: u8 = 2;
pub const SLICE: u8 = 3;
pub const PAD: u8 = 4;
#[allow(dead_code)]
pub const MAX_POS: u64 = 0x3fff_ffff_ffff_ffff;

pub open spec fn tag(kind: RecordKind) -> u8 {
    match kind {
        RecordKind::Bytes => BYTES,
        RecordKind::Marker => MARKER,
        RecordKind::Slice => SLICE,
        RecordKind::Pad => PAD,
    }
}

#[allow(dead_code)]
pub ghost struct Rec {
    pub kind: RecordKind,
    pub len: nat,
    pub off: nat,
}

pub open spec fn size(r: Rec) -> nat {
    HEADER as nat + r.len
}

pub open spec fn off_after(r: Rec) -> nat {
    if r.kind == RecordKind::Bytes {
        r.off + r.len
    } else {
        r.off
    }
}

#[allow(dead_code)]
pub ghost struct Log {
    pub m: Map<nat, Rec>,
    pub head: nat,
    pub head_offset: nat,
}

pub open spec fn boundary(l: Log, p: nat) -> bool {
    l.m.contains_key(p) || p == l.head
}

pub open spec fn off_at(l: Log, p: nat) -> nat {
    if p == l.head {
        l.head_offset
    } else if l.m.contains_key(p) {
        l.m[p].off
    } else {
        0
    }
}

pub open spec fn rec_ok(cap: nat, l: Log, p: nat, r: Rec) -> bool {
    &&& p + size(r) <= l.head
    &&& p % cap + size(r) <= cap
    &&& r.off <= p
    &&& r.off <= l.head_offset
    &&& boundary(l, p + size(r))
    &&& off_at(l, p + size(r)) == off_after(r)
    &&& forall|q: nat| p < q < p + size(r) ==> !(#[trigger] l.m.contains_key(q))
}

#[verifier::opaque]
pub open spec fn wf(cap: nat, l: Log) -> bool {
    &&& forall|p: nat| #[trigger] l.m.contains_key(p) ==> rec_ok(cap, l, p, l.m[p])
    &&& l.head % cap + HEADER as nat <= cap
    &&& l.head <= MAX_POS as nat
    &&& l.head_offset <= l.head
}

#[verifier::opaque]
pub open spec fn log_le(a: Log, b: Log) -> bool {
    &&& a.head <= b.head
    &&& a.head_offset <= b.head_offset
    &&& boundary(b, a.head)
    &&& off_at(b, a.head) == a.head_offset
    &&& forall|p: nat| p < a.head ==> (#[trigger] b.m.contains_key(p) <==> a.m.contains_key(p))
    &&& forall|p: nat| p < a.head && #[trigger] a.m.contains_key(p) ==> b.m[p] == a.m[p]
}

pub open spec fn empty_log() -> Log {
    Log { m: Map::empty(), head: 0, head_offset: 0 }
}

pub open spec fn extend(l: Log, r: Rec) -> Log {
    Log {
        m: l.m.insert(l.head, r),
        head: l.head + size(r),
        head_offset: l.head_offset + if r.kind == RecordKind::Bytes {
            r.len
        } else {
            0
        },
    }
}

pub open spec fn is_data(r: Rec) -> bool {
    r.kind == RecordKind::Bytes || r.kind == RecordKind::Marker
}

pub open spec fn quiet(l: Log, lo: nat, hi: nat) -> bool {
    forall|q: nat| lo <= q < hi && #[trigger] l.m.contains_key(q) ==> !is_data(l.m[q])
}

pub open spec fn lost_at(l: Log, p: nat, q: nat) -> bool {
    l.m.contains_key(q) && is_data(l.m[q]) && q + size(l.m[q]) > p
}

pub open spec fn lost(l: Log, tail: nat, p: nat) -> bool {
    exists|q: nat| q < tail && #[trigger] lost_at(l, p, q)
}

pub open spec fn data_end(l: Log, ev: nat) -> bool {
    exists|q: nat|
        q < ev && #[trigger] l.m.contains_key(q) && is_data(l.m[q]) && q + size(l.m[q]) == ev
}

#[verifier::opaque]
pub open spec fn evicted_ok(l: Log, ev: nat, tail: nat) -> bool {
    &&& ev <= tail
    &&& quiet(l, ev, tail)
    &&& (ev > 0 ==> data_end(l, ev))
}

pub open spec fn retain_of(cap: nat, upper: nat, keep: nat) -> nat {
    if upper < cap / 2 {
        0
    } else if upper - cap / 2 < keep {
        (upper - cap / 2) as nat
    } else {
        keep
    }
}

pub open spec fn before(r: Rec, target: nat) -> bool {
    match r.kind {
        RecordKind::Bytes => r.off + r.len <= target,
        RecordKind::Marker | RecordKind::Slice => r.off < target,
        RecordKind::Pad => true,
    }
}

pub open spec fn resumes(tail: nat, l: Log, target: nat, p: nat) -> bool {
    &&& boundary(l, p)
    &&& tail <= p <= l.head
    &&& (off_at(l, tail) <= target ==> off_at(l, p) <= target)
    &&& forall|q: nat| tail <= q < p && #[trigger] l.m.contains_key(q) ==> before(l.m[q], target)
    &&& (p < l.head ==> l.m.contains_key(p) && !before(l.m[p], target))
}

pub open spec fn enc(r: Rec, j: nat) -> u8 {
    let l = r.len as u64;
    let o = r.off as u64;
    if j == 0 {
        tag(r.kind)
    } else if j == 1 {
        l as u8
    } else if j == 2 {
        (l >> 8) as u8
    } else if j == 3 {
        (l >> 16) as u8
    } else if j == 4 {
        (l >> 24) as u8
    } else if j == 5 {
        o as u8
    } else if j == 6 {
        (o >> 8) as u8
    } else if j == 7 {
        (o >> 16) as u8
    } else if j == 8 {
        (o >> 24) as u8
    } else if j == 9 {
        (o >> 32) as u8
    } else if j == 10 {
        (o >> 40) as u8
    } else if j == 11 {
        (o >> 48) as u8
    } else if j == 12 {
        (o >> 56) as u8
    } else {
        0
    }
}

pub proof fn le4_enc(l: u64)
    requires
        l < 0x1_0000_0000,
    ensures
        (l as u8) as u64 | ((((l >> 8) as u8) as u64) << 8) | ((((l >> 16) as u8) as u64) << 16)
            | ((((l >> 24) as u8) as u64) << 24) == l,
{
    assert(((l as u8) as u64 | ((((l >> 8) as u8) as u64) << 8) | ((((l >> 16) as u8) as u64) << 16)
        | ((((l >> 24) as u8) as u64) << 24)) == l) by (bit_vector)
        requires
            l < 0x1_0000_0000,
    ;
}

pub proof fn le8_enc(o: u64)
    ensures
        (o as u8) as u64 | ((((o >> 8) as u8) as u64) << 8) | ((((o >> 16) as u8) as u64) << 16)
            | ((((o >> 24) as u8) as u64) << 24) | ((((o >> 32) as u8) as u64) << 32)
            | ((((o >> 40) as u8) as u64) << 40) | ((((o >> 48) as u8) as u64) << 48)
            | ((((o >> 56) as u8) as u64) << 56) == o,
{
    assert(((o as u8) as u64 | ((((o >> 8) as u8) as u64) << 8) | ((((o >> 16) as u8) as u64) << 16)
        | ((((o >> 24) as u8) as u64) << 24) | ((((o >> 32) as u8) as u64) << 32)
        | ((((o >> 40) as u8) as u64) << 40) | ((((o >> 48) as u8) as u64) << 48)
        | ((((o >> 56) as u8) as u64) << 56)) == o) by (bit_vector);
}

#[verifier::opaque]
pub open spec fn hdr_ok(cap: nat, l: Log, m: Map<nat, ByteTok>, lo: nat, hi: nat) -> bool {
    forall|p: nat, j: nat|
        lo <= p < hi && l.m.contains_key(p) && j < 13 && #[trigger] m.contains_key((p + j) % cap)
            ==> m[(p + j) % cap].val() == Some(enc(l.m[p], j))
}

pub open spec fn staged(cap: nat, m: Map<nat, ByteTok>, head: nat, r: Rec) -> bool {
    &&& dom_is(m.dom(), cap, head, head + size(r))
    &&& forall|j: nat|
        j < 13 ==> #[trigger] m.contains_key((head + j) % cap) && m[(head + j) % cap].val() == Some(enc(r, j))
    &&& filled_some(m, cap, head, r.len)
}

pub open spec fn some_at(m: Map<nat, ByteTok>, cap: nat, head: nat, j: nat) -> bool {
    &&& m.contains_key((head + HEADER as nat + j) % cap)
    &&& m[(head + HEADER as nat + j) % cap].val() is Some
}

pub open spec fn filled_some(m: Map<nat, ByteTok>, cap: nat, head: nat, f: nat) -> bool {
    forall|j: nat| j < f ==> #[trigger] some_at(m, cap, head, j)
}

pub open spec fn filled_ok(cap: nat, head: nat, tail: nat, f: nat) -> bool {
    &&& head % cap + HEADER as nat + f <= cap
    &&& head + HEADER as nat + f <= tail + cap
}

pub open spec fn fits_ok(cap: nat, head: nat, tail: nat, n: nat) -> bool {
    &&& head % cap + HEADER as nat + n <= cap
    &&& (head % cap + HEADER as nat + n == cap || head % cap + HEADER as nat + n + HEADER as nat
        <= cap)
    &&& head + HEADER as nat + n <= tail + cap
    &&& head + HEADER as nat + n <= MAX_HEAD as nat
}

pub proof fn rng_has(cap: nat, lo: nat, hi: nat, p: nat)
    requires
        lo <= p < hi,
    ensures
        in_rng(cap, lo, hi, p % cap),
{
    assert(lo <= p < hi && p % cap == p % cap);
}

pub proof fn rng_union(cap: nat, lo: nat, mid: nat, hi: nat, i: nat)
    requires
        lo <= mid <= hi,
    ensures
        in_rng(cap, lo, hi, i) <==> in_rng(cap, lo, mid, i) || in_rng(cap, mid, hi, i),
{
    if in_rng(cap, lo, hi, i) {
        let p = choose|p: nat| lo <= p < hi && #[trigger] (p % cap) == i;
        if p < mid {
            assert(in_rng(cap, lo, mid, i));
        } else {
            assert(in_rng(cap, mid, hi, i));
        }
    }
    if in_rng(cap, lo, mid, i) {
        let p = choose|p: nat| lo <= p < mid && #[trigger] (p % cap) == i;
        assert(lo <= p < hi && p % cap == i);
    }
    if in_rng(cap, mid, hi, i) {
        let p = choose|p: nat| mid <= p < hi && #[trigger] (p % cap) == i;
        assert(lo <= p < hi && p % cap == i);
    }
}

pub proof fn rng_disjoint(cap: nat, lo: nat, mid: nat, hi: nat, i: nat)
    requires
        cap > 0,
        lo <= mid <= hi,
        hi - lo <= cap,
    ensures
        !(in_rng(cap, lo, mid, i) && in_rng(cap, mid, hi, i)),
{
    if in_rng(cap, lo, mid, i) && in_rng(cap, mid, hi, i) {
        let a = choose|a: nat| lo <= a < mid && #[trigger] (a % cap) == i;
        let b = choose|b: nat| mid <= b < hi && #[trigger] (b % cap) == i;
        mod_distinct(cap, a, b);
    }
}

pub proof fn rng_shift(cap: nat, lo: nat, hi: nat, i: nat)
    requires
        cap > 0,
    ensures
        in_rng(cap, lo + cap, hi + cap, i) <==> in_rng(cap, lo, hi, i),
{
    if in_rng(cap, lo + cap, hi + cap, i) {
        let p = choose|p: nat| lo + cap <= p < hi + cap && #[trigger] (p % cap) == i;
        let q = (p - cap) as nat;
        assert(q % cap == p % cap) by {
            lemma_mod_sub_multiples_vanish(p as int, cap as int);
            assert((-(cap as int) + p as int) == q as int);
        }
        assert(lo <= q < hi && q % cap == i);
    }
    if in_rng(cap, lo, hi, i) {
        let p = choose|p: nat| lo <= p < hi && #[trigger] (p % cap) == i;
        assert((p + cap) % cap == p % cap) by {
            lemma_mod_add_multiples_vanish(p as int, cap as int);
            assert((cap as int + p as int) == (p + cap) as int);
        }
        assert(lo + cap <= p + cap < hi + cap && (p + cap) % cap == i);
    }
}

pub proof fn rng_empty(cap: nat, lo: nat, i: nat)
    ensures
        !in_rng(cap, lo, lo, i),
{
}

pub open spec fn range_keys(d: Set<nat>, cap: nat, lo: nat, hi: nat) -> Set<nat> {
    d.filter(|i: nat| in_rng(cap, lo, hi, i))
}

pub proof fn split_dom(cap: nat, m: Map<nat, ByteTok>, lo: nat, mid: nat, hi: nat)
    requires
        cap > 0,
        lo <= mid <= hi,
        hi - lo <= cap,
        dom_is(m.dom(), cap, lo, hi),
    ensures
        range_keys(m.dom(), cap, lo, mid).subset_of(m.dom()),
        dom_is(m.restrict(range_keys(m.dom(), cap, lo, mid)).dom(), cap, lo, mid),
        dom_is(m.remove_keys(range_keys(m.dom(), cap, lo, mid)).dom(), cap, mid, hi),
{
    let keys = range_keys(m.dom(), cap, lo, mid);
    assert forall|i: nat| m.restrict(keys).dom().contains(i) <==> #[trigger] in_rng(
        cap,
        lo,
        mid,
        i,
    ) by {
        if in_rng(cap, lo, mid, i) {
            rng_union(cap, lo, mid, hi, i);
        }
    }
    assert forall|i: nat| m.remove_keys(keys).dom().contains(i) <==> #[trigger] in_rng(
        cap,
        mid,
        hi,
        i,
    ) by {
        rng_union(cap, lo, mid, hi, i);
        rng_disjoint(cap, lo, mid, hi, i);
    }
}

pub proof fn map_facts(m: Map<nat, ByteTok>, keys: Set<nat>, k: nat)
    ensures
        m.remove_keys(keys).contains_key(k) <==> (m.contains_key(k) && !keys.contains(k)),
        m.remove_keys(keys).contains_key(k) ==> m.remove_keys(keys)[k] == m[k],
        m.restrict(keys).contains_key(k) <==> (m.contains_key(k) && keys.contains(k)),
        m.restrict(keys).contains_key(k) ==> m.restrict(keys)[k] == m[k],
{
}

pub proof fn tok_ok_union(base: nat, a: Map<nat, ByteTok>, b: Map<nat, ByteTok>)
    requires
        tok_ok(base, a),
        tok_ok(base, b),
    ensures
        tok_ok(base, a.union_prefer_right(b)),
{
    let u = a.union_prefer_right(b);
    assert forall|k: nat| #[trigger] u.contains_key(k) implies u[k].backing() == base
        && u[k].index() == k by {
        if b.contains_key(k) {
            assert(u[k] == b[k]);
        } else {
            assert(a.contains_key(k));
            assert(u[k] == a[k]);
        }
    }
}

pub proof fn tok_ok_remove(base: nat, m: Map<nat, ByteTok>, keys: Set<nat>)
    requires
        tok_ok(base, m),
    ensures
        tok_ok(base, m.remove_keys(keys)),
        tok_ok(base, m.restrict(keys)),
{
    assert forall|k: nat| #[trigger] m.remove_keys(keys).contains_key(k) implies m.remove_keys(
        keys,
    )[k].backing() == base && m.remove_keys(keys)[k].index() == k by {
        map_facts(m, keys, k);
    }
    assert forall|k: nat| #[trigger] m.restrict(keys).contains_key(k) implies m.restrict(keys)[k].backing()
        == base && m.restrict(keys)[k].index() == k by {
        map_facts(m, keys, k);
    }
}

pub proof fn hdr_ok_remove(
    cap: nat,
    l: Log,
    m: Map<nat, ByteTok>,
    lo: nat,
    mid: nat,
    hi: nat,
)
    requires
        lo <= mid,
        hdr_ok(cap, l, m, lo, hi),
    ensures
        hdr_ok(cap, l, m.remove_keys(range_keys(m.dom(), cap, lo, mid)), mid, hi),
{
    reveal(hdr_ok);
    let r = m.remove_keys(range_keys(m.dom(), cap, lo, mid));
    assert forall|p: nat, j: nat|
        mid <= p < hi && l.m.contains_key(p) && j < 13 && #[trigger] r.contains_key((p + j) % cap)
            implies r[(p + j) % cap].val() == Some(enc(l.m[p], j)) by {
        let k = (p + j) % cap;
        map_facts(m, range_keys(m.dom(), cap, lo, mid), k);
        assert(m.contains_key(k));
        assert(lo <= p < hi);
        reveal(hdr_ok);
    }
}

pub proof fn covers_window(d: Set<nat>, cap: nat, lo: nat, hi: nat, a: nat, b: nat)
    requires
        dom_is(d, cap, lo, hi),
        lo <= a,
        b <= hi,
    ensures
        covers(d, cap, a, b),
{
    assert forall|i: nat| #[trigger] in_rng(cap, a, b, i) implies d.contains(i) by {
        let p = choose|p: nat| a <= p < b && #[trigger] (p % cap) == i;
        assert(lo <= p < hi && p % cap == i);
        assert(in_rng(cap, lo, hi, i));
    }
}

pub proof fn hdr_ok_empty(cap: nat, l: Log, m: Map<nat, ByteTok>, lo: nat)
    ensures
        hdr_ok(cap, l, m, lo, lo),
{
    reveal(hdr_ok);
}

pub proof fn hdr_ok_elim(cap: nat, l: Log, m: Map<nat, ByteTok>, lo: nat, hi: nat, p: nat, j: nat)
    requires
        hdr_ok(cap, l, m, lo, hi),
        lo <= p < hi,
        l.m.contains_key(p),
        j < 13,
        m.contains_key((p + j) % cap),
    ensures
        m[(p + j) % cap].val() == Some(enc(l.m[p], j)),
{
    reveal(hdr_ok);
}

pub proof fn hdr_ok_log_le(
    cap: nat,
    a: Log,
    b: Log,
    m: Map<nat, ByteTok>,
    lo: nat,
    hi: nat,
)
    requires
        hdr_ok(cap, a, m, lo, hi),
        log_le(a, b),
        hi <= a.head,
    ensures
        hdr_ok(cap, b, m, lo, hi),
{
    reveal(hdr_ok);
    assert forall|p: nat, j: nat|
        lo <= p < hi && b.m.contains_key(p) && j < 13 && #[trigger] m.contains_key((p + j) % cap)
            implies m[(p + j) % cap].val() == Some(enc(b.m[p], j)) by {
        log_le_same(a, b, p);
    }
}

pub proof fn hdr_ok_union(
    cap: nat,
    l: Log,
    a: Map<nat, ByteTok>,
    b: Map<nat, ByteTok>,
    lo: nat,
    mid: nat,
    hi: nat,
)
    requires
        cap > 0,
        wf(cap, l),
        lo <= mid <= hi,
        hi - lo <= cap,
        l.head == hi,
        boundary(l, mid),
        hdr_ok(cap, l, a, lo, mid),
        hdr_ok(cap, l, b, mid, hi),
        dom_is(a.dom(), cap, lo, mid),
        dom_is(b.dom(), cap, mid, hi),
    ensures
        hdr_ok(cap, l, a.union_prefer_right(b), lo, hi),
{
    let u = a.union_prefer_right(b);
    reveal(hdr_ok);
    assert forall|p: nat, j: nat|
        lo <= p < hi && l.m.contains_key(p) && j < 13 && #[trigger] u.contains_key((p + j) % cap)
            implies u[(p + j) % cap].val() == Some(enc(l.m[p], j)) by {
        wf_rec(cap, l, p);
        assert(p + j < p + size(l.m[p]));
        assert(p + j < hi);
        let i = (p + j) % cap;
        if p < mid {
            if p + size(l.m[p]) > mid {
                if mid != l.head {
                    assert(l.m.contains_key(mid));
                }
            }
            rng_has(cap, lo, mid, p + j);
            rng_disjoint(cap, lo, mid, hi, i);
            assert(a.contains_key(i));
            assert(!b.contains_key(i));
        } else {
            rng_has(cap, mid, hi, p + j);
            assert(b.contains_key(i));
        }
    }
}

pub proof fn mod_step(cap: nat, lo: nat, d: nat)
    requires
        cap > 0,
        lo % cap + d <= cap,
    ensures
        (lo + d) % cap == if lo % cap + d < cap {
            lo % cap + d
        } else {
            0
        },
{
    lemma_fundamental_div_mod(lo as int, cap as int);
    let q = (lo / cap) as int;
    if lo % cap + d < cap {
        assert((lo + d) as int == q * (cap as int) + (lo % cap + d) as int) by (nonlinear_arith)
            requires
                lo as int == (cap as int) * q + (lo % cap) as int,
        ;
        lemma_fundamental_div_mod_converse((lo + d) as int, cap as int, q, (lo % cap + d) as int);
    } else {
        assert((lo + d) as int == (q + 1) * (cap as int) + 0int) by (nonlinear_arith)
            requires
                lo as int == (cap as int) * q + (lo % cap) as int,
                lo % cap + d == cap,
        ;
        lemma_fundamental_div_mod_converse((lo + d) as int, cap as int, q + 1, 0int);
    }
}

pub proof fn mod_distinct(cap: nat, a: nat, b: nat)
    requires
        cap > 0,
        a < b < a + cap,
    ensures
        a % cap != b % cap,
{
    lemma_mod_equivalence(b as int, a as int, cap as int);
    lemma_small_mod((b - a) as nat, cap);
}

pub proof fn empty_wf(cap: nat)
    requires
        cap >= MIN_CAPACITY,
    ensures
        wf(cap, empty_log()),
{
    reveal(wf);
    assert(0nat % cap == 0) by (nonlinear_arith)
        requires
            cap > 0,
    ;
    assert forall|p: nat| #[trigger] empty_log().m.contains_key(p) implies false by {
        assert(!Map::<nat, Rec>::empty().contains_key(p));
    }
}

pub proof fn wf_rec(cap: nat, l: Log, p: nat)
    requires
        wf(cap, l),
        l.m.contains_key(p),
    ensures
        rec_ok(cap, l, p, l.m[p]),
        p < l.head,
{
    reveal(wf);
}

pub proof fn wf_head(cap: nat, l: Log)
    requires
        wf(cap, l),
    ensures
        l.head % cap + HEADER as nat <= cap,
        l.head <= MAX_POS as nat,
        l.head_offset <= l.head,
        !l.m.contains_key(l.head),
{
    reveal(wf);
    if l.m.contains_key(l.head) {
        assert(rec_ok(cap, l, l.head, l.m[l.head]));
    }
}

pub proof fn rec_bounds(cap: nat, l: Log, p: nat)
    requires
        wf(cap, l),
        MIN_CAPACITY as nat <= cap <= MAX_CAPACITY as nat,
        l.m.contains_key(p),
    ensures
        l.m[p].len < MAX_LENGTH as nat,
        l.m[p].off < MAX_OFFSET as nat,
        l.m[p].len <= cap,
{
    wf_rec(cap, l, p);
    wf_head(cap, l);
    assert(HEADER == 13);
    assert(MAX_CAPACITY == 0x4000_0000);
    assert(MAX_LENGTH == 0x1_0000_0000);
    assert(MAX_OFFSET == 0x4000_0000_0000_0000);
    assert(MAX_POS == 0x3fff_ffff_ffff_ffff);
    assert(size(l.m[p]) == 13 + l.m[p].len);
    assert(p % cap + size(l.m[p]) <= cap);
}

pub proof fn payload_fits(cap: nat, head: nat, n: nat)
    requires
        cap > 0,
        head % cap + HEADER as nat + n <= cap,
    ensures
        (head + HEADER as nat) % cap + n <= cap,
{
    assert(HEADER == 13);
    mod_step(cap, head, HEADER as nat);
}

pub proof fn extend_wf(cap: nat, l: Log, r: Rec)
    requires
        wf(cap, l),
        r.off == l.head_offset,
        l.head % cap + size(r) <= cap,
        (l.head + size(r)) % cap + HEADER as nat <= cap,
        l.head + size(r) <= MAX_POS as nat,
    ensures
        wf(cap, extend(l, r)),
        log_le(l, extend(l, r)),
{
    let e = extend(l, r);
    wf_head(cap, l);
    reveal(wf);
    reveal(log_le);
    assert forall|p: nat| #[trigger] e.m.contains_key(p) implies rec_ok(cap, e, p, e.m[p]) by {
        if p == l.head {
            assert(rec_ok(cap, e, p, r));
        } else {
            assert(l.m.contains_key(p));
            let q = l.m[p];
            assert(rec_ok(cap, l, p, q));
            assert(rec_ok(cap, e, p, q));
        }
    }
}

pub proof fn log_le_refl(a: Log)
    ensures
        log_le(a, a),
{
    reveal(log_le);
}

pub proof fn log_le_trans(a: Log, b: Log, c: Log)
    requires
        log_le(a, b),
        log_le(b, c),
    ensures
        log_le(a, c),
{
    reveal(log_le);
    assert(boundary(c, a.head) && off_at(c, a.head) == a.head_offset) by {
        if a.head < b.head {
            assert(b.m.contains_key(a.head));
            assert(c.m.contains_key(a.head));
            assert(c.m[a.head] == b.m[a.head]);
        }
    }
    assert forall|p: nat| p < a.head implies (#[trigger] c.m.contains_key(p)
        <==> a.m.contains_key(p)) by {
        assert(b.m.contains_key(p) <==> a.m.contains_key(p));
        assert(c.m.contains_key(p) <==> b.m.contains_key(p));
    }
    assert forall|p: nat| p < a.head && #[trigger] a.m.contains_key(p) implies c.m[p] == a.m[p] by {
        assert(b.m.contains_key(p));
        assert(b.m[p] == a.m[p]);
        assert(c.m[p] == b.m[p]);
    }
}

pub proof fn log_le_head(a: Log, b: Log)
    requires
        log_le(a, b),
    ensures
        a.head <= b.head,
        a.head_offset <= b.head_offset,
        boundary(b, a.head),
        off_at(b, a.head) == a.head_offset,
{
    reveal(log_le);
}

pub proof fn log_le_same(a: Log, b: Log, p: nat)
    requires
        log_le(a, b),
        p < a.head,
    ensures
        b.m.contains_key(p) <==> a.m.contains_key(p),
        a.m.contains_key(p) ==> b.m[p] == a.m[p],
{
    reveal(log_le);
}

pub proof fn log_le_boundary(cap: nat, a: Log, b: Log, p: nat)
    requires
        wf(cap, a),
        wf(cap, b),
        log_le(a, b),
        boundary(a, p),
    ensures
        boundary(b, p),
        off_at(b, p) == off_at(a, p),
{
    log_le_head(a, b);
    if p != a.head {
        wf_rec(cap, a, p);
        log_le_same(a, b, p);
    }
}

pub proof fn evicted_facts(l: Log, ev: nat, tail: nat)
    requires
        evicted_ok(l, ev, tail),
    ensures
        ev <= tail,
        quiet(l, ev, tail),
        ev > 0 ==> data_end(l, ev),
{
    reveal(evicted_ok);
}

pub proof fn evicted_intro(l: Log, ev: nat, tail: nat)
    requires
        ev <= tail,
        quiet(l, ev, tail),
        ev > 0 ==> data_end(l, ev),
    ensures
        evicted_ok(l, ev, tail),
{
    reveal(evicted_ok);
}

pub proof fn evicted_grows(l: Log, l2: Log, ev: nat, tail: nat)
    requires
        evicted_ok(l, ev, tail),
        log_le(l, l2),
        tail <= l.head,
    ensures
        evicted_ok(l2, ev, tail),
{
    evicted_facts(l, ev, tail);
    log_le_head(l, l2);
    assert forall|q: nat| ev <= q < tail && #[trigger] l2.m.contains_key(q) implies !is_data(
        l2.m[q],
    ) by {
        log_le_same(l, l2, q);
        assert(l.m.contains_key(q));
    }
    if ev > 0 {
        let q = choose|q: nat|
            q < ev && #[trigger] l.m.contains_key(q) && is_data(l.m[q]) && q + size(l.m[q]) == ev;
        log_le_same(l, l2, q);
        assert(q < ev && l2.m.contains_key(q) && is_data(l2.m[q]) && q + size(l2.m[q]) == ev);
    }
    evicted_intro(l2, ev, tail);
}

pub proof fn evicted_step(cap: nat, l: Log, ev: nat, p: nat)
    requires
        wf(cap, l),
        evicted_ok(l, ev, p),
        l.m.contains_key(p),
    ensures
        evicted_ok(
            l,
            if is_data(l.m[p]) {
                p + size(l.m[p])
            } else {
                ev
            },
            p + size(l.m[p]),
        ),
{
    wf_rec(cap, l, p);
    evicted_facts(l, ev, p);
    let r = l.m[p];
    let ev2 = if is_data(r) {
        p + size(r)
    } else {
        ev
    };
    assert forall|q: nat| ev2 <= q < p + size(r) && #[trigger] l.m.contains_key(q) implies !is_data(
        l.m[q],
    ) by {
        if is_data(r) {
            assert(false);
        } else if q < p {
            assert(ev <= q < p);
        } else if q == p {
        } else {
            assert(p < q < p + size(r));
        }
    }
    if is_data(r) {
        assert(l.m.contains_key(p) && is_data(l.m[p]) && p + size(l.m[p]) == ev2);
    } else if ev > 0 {
        let q = choose|q: nat|
            q < ev && #[trigger] l.m.contains_key(q) && is_data(l.m[q]) && q + size(l.m[q]) == ev;
        assert(q < ev2 && l.m.contains_key(q) && is_data(l.m[q]) && q + size(l.m[q]) == ev2);
    }
    evicted_intro(l, ev2, p + size(r));
}

pub proof fn reachable_iff(cap: nat, l: Log, ev: nat, tail: nat, p: nat)
    requires
        wf(cap, l),
        evicted_ok(l, ev, tail),
        tail <= l.head,
    ensures
        lost(l, tail, p) <==> p < ev,
{
    evicted_facts(l, ev, tail);
    if p < ev {
        let q = choose|q: nat|
            q < ev && #[trigger] l.m.contains_key(q) && is_data(l.m[q]) && q + size(l.m[q]) == ev;
        wf_rec(cap, l, q);
        assert(q < tail && lost_at(l, p, q));
    }
    if lost(l, tail, p) {
        let q = choose|q: nat| q < tail && #[trigger] lost_at(l, p, q);
        wf_rec(cap, l, q);
        if p >= ev {
            if q >= ev {
                assert(ev <= q < tail);
                assert(false);
            } else {
                assert(ev > 0);
                let q0 = choose|q0: nat|
                    q0 < ev && #[trigger] l.m.contains_key(q0) && is_data(l.m[q0]) && q0 + size(
                        l.m[q0],
                    ) == ev;
                wf_rec(cap, l, q0);
                if q < q0 {
                    assert(q0 < q + size(l.m[q]));
                    assert(false);
                } else if q0 < q {
                    assert(q < q0 + size(l.m[q0]));
                    assert(false);
                } else {
                    assert(q + size(l.m[q]) == ev);
                    assert(false);
                }
            }
        }
    }
}

pub open spec fn next_bnd(l: Log, p: nat) -> nat {
    if l.m.contains_key(p) {
        p + size(l.m[p])
    } else {
        p
    }
}

pub proof fn off_mono(cap: nat, l: Log, p: nat, q: nat)
    requires
        wf(cap, l),
        boundary(l, p),
        boundary(l, q),
        p <= q,
    ensures
        off_at(l, p) <= off_at(l, q),
        quiet(l, p, q) ==> off_at(l, p) == off_at(l, q),
    decreases q - p,
{
    if p < q {
        wf_head(cap, l);
        if l.m.contains_key(q) {
            wf_rec(cap, l, q);
        }
        assert(l.m.contains_key(p));
        wf_rec(cap, l, p);
        let r = l.m[p];
        if q < p + size(r) {
            assert(false);
        } else {
            off_mono(cap, l, (p + size(r)) as nat, q);
        }
    }
}


pub open spec fn cursor_ok(l: Log, cp: nat, co: nat) -> bool {
    &&& cp <= l.head
    &&& boundary(l, cp)
    &&& off_at(l, cp) <= co
    &&& co <= off_at(l, next_bnd(l, cp))
}

pub proof fn cursor_grows(cap: nat, a: Log, b: Log, cp: nat, co: nat)
    requires
        wf(cap, a),
        wf(cap, b),
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

pub proof fn sent_cursor(cap: nat, l: Log, next: nat, end: nat)
    requires
        wf(cap, l),
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

pub proof fn reach_cursor(cap: nat, l: Log, tl: nat, cp: nat, co: nat, p: nat)
    requires
        wf(cap, l),
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

pub proof fn resume_cursor(cap: nat, l: Log, tl: nat, value: nat, p: nat)
    requires
        wf(cap, l),
        resumes(tl, l, value, p),
        off_at(l, tl) <= value,
        value <= l.head_offset,
    ensures
        cursor_ok(l, p, value),
{
    if p < l.head {
        assert(l.m.contains_key(p));
        wf_rec(cap, l, p);
        assert(!before(l.m[p], value));
        off_mono(cap, l, p, next_bnd(l, p));
    } else {
        wf_head(cap, l);
        assert(p == l.head);
    }
}

} // verus!
