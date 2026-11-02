#![allow(unreachable_pub)]

#[cfg(not(loom))]
use std::os::fd::BorrowedFd;

use vstd::prelude::*;
use vstd::raw_ptr::PointsTo;

#[cfg(not(loom))]
pub type Handle = super::mapping::Shared;
#[cfg(loom)]
pub type Handle = std::sync::Arc<super::model::Shared>;

verus! {

pub const MIN_CAPACITY: u64 = 64;
pub const MAX_CAPACITY: u64 = 0x4000_0000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Index {
    Head = 1,
    Tail = 2,
    Read = 3,
}

#[allow(dead_code)]
#[verifier::external_body]
pub tracked struct ByteTok {
    no_construct: (),
}

impl ByteTok {
    pub uninterp spec fn val(&self) -> Option<u8>;

    pub uninterp spec fn backing(&self) -> nat;

    pub uninterp spec fn index(&self) -> nat;
}

pub open spec fn in_rng(cap: nat, lo: nat, hi: nat, i: nat) -> bool {
    exists|p: nat| lo <= p < hi && #[trigger] (p % cap) == i
}

pub open spec fn dom_is(d: Set<nat>, cap: nat, lo: nat, hi: nat) -> bool {
    forall|i: nat| d.contains(i) <==> #[trigger] in_rng(cap, lo, hi, i)
}

pub open spec fn covers(d: Set<nat>, cap: nat, lo: nat, hi: nat) -> bool {
    forall|i: nat| #[trigger] in_rng(cap, lo, hi, i) ==> d.contains(i)
}

pub open spec fn tok_ok(base: nat, m: Map<nat, ByteTok>) -> bool {
    forall|k: nat| #[trigger] m.contains_key(k) ==> m[k].backing() == base && m[k].index() == k
}

#[allow(dead_code)]
pub tracked struct Words {
    pub head: PointsTo<u64>,
    pub tail: PointsTo<u64>,
    pub read: PointsTo<u64>,
    pub data: Map<nat, ByteTok>,
}

#[verifier::external_body]
pub struct HandleBox(Handle);

#[allow(dead_code)]
#[verifier::external_type_specification]
#[verifier::external_body]
pub struct ExIoError(std::io::Error);

// Assumes: it returns a fresh mapping that only this handle refers to; it states nothing, and
// `Reader::with` establishes `wf` from the zero-filled mapping.
#[cfg(not(loom))]
#[verifier::external_body]
pub fn create_handle(capacity: u64) -> Result<HandleBox, std::io::Error> {
    super::mapping::Shared::create(capacity).map(HandleBox::new)
}

#[verifier::external_body]
pub struct Backend {
    handle: Handle,
}

impl Backend {
    pub uninterp spec fn word(&self, index: Index) -> *mut u64;

    pub uninterp spec fn cap(&self) -> nat;

    pub uninterp spec fn base(&self) -> nat;

    // Assumes: it returns the validated capacity, 64 to 2^30.
    #[verifier::external_body]
    pub fn capacity(&self) -> (c: u64)
        ensures
            c as nat == self.cap(),
    {
        self.handle.capacity()
    }

    // Assumes: the reader process calls this once for a ring that it created itself, so the
    // mapping is zero-filled and no record exists. The writer process holds the other token of
    // the same ring (the two processes act as one heap, which one Verus instance cannot span).
    // The three header words are aligned u64 words that both processes access only as atomics.
    // The reader owns no data byte at the start.
    #[verifier::external_body]
    pub fn mint_reader(handle: HandleBox) -> (res: (Backend, Tracked<Words>))
        ensures
            MIN_CAPACITY <= res.0.cap() <= MAX_CAPACITY,
            res.1@.head.ptr() == res.0.word(Index::Head),
            res.1@.tail.ptr() == res.0.word(Index::Tail),
            res.1@.read.ptr() == res.0.word(Index::Read),
            res.1@.head.is_init() && res.1@.head.value() == 0,
            res.1@.tail.is_init() && res.1@.tail.value() == 0,
            res.1@.read.is_init() && res.1@.read.value() == 0,
            res.1@.data == Map::<nat, ByteTok>::empty(),
    {
        (Backend { handle: handle.0 }, Tracked::assume_new())
    }

    // Assumes: the writer process attaches once for each ring, before any record exists, so the
    // header words and the data bytes are zero, and the reader process holds the other token of
    // the same ring (one heap). The three header words are aligned u64 words that both processes
    // access only as atomics. The key `i` of a data token is the data byte `i`, and the tokens
    // belong to this backing.
    #[verifier::external_body]
    pub fn mint_writer(handle: HandleBox) -> (res: (Backend, Tracked<Words>))
        ensures
            MIN_CAPACITY <= res.0.cap() <= MAX_CAPACITY,
            res.1@.head.ptr() == res.0.word(Index::Head),
            res.1@.tail.ptr() == res.0.word(Index::Tail),
            res.1@.read.ptr() == res.0.word(Index::Read),
            res.1@.head.is_init() && res.1@.head.value() == 0,
            res.1@.tail.is_init() && res.1@.tail.value() == 0,
            res.1@.read.is_init() && res.1@.read.value() == 0,
            dom_is(res.1@.data.dom(), res.0.cap(), 0, res.0.cap()),
            tok_ok(res.0.base(), res.1@.data),
            forall|k: nat| #[trigger] res.1@.data.contains_key(k) ==> res.1@.data[k].val()
                == Some(0u8),
    {
        (Backend { handle: handle.0 }, Tracked::assume_new())
    }

    // Assumes: this is the sequentially consistent atomic load of the word `index`, exactly the
    // contract of vstd's `AtomicU64::from_ptr_load`.
    #[verifier::external_body]
    #[verifier::atomic]
    #[inline(always)]
    pub fn load(&self, index: Index, Tracked(perm): Tracked<&PointsTo<u64>>) -> (v: u64)
        requires
            perm.ptr() == self.word(index),
            perm.is_init(),
        ensures
            v == perm.value(),
        opens_invariants none
        no_unwind
    {
        self.handle.load(index)
    }

    // Assumes: this is the sequentially consistent atomic store of the word `index`, exactly the
    // contract of vstd's `AtomicU64::from_ptr_store`.
    #[verifier::external_body]
    #[verifier::atomic]
    #[inline(always)]
    pub fn store(
        &self,
        index: Index,
        value: u64,
        Tracked(perm): Tracked<&mut PointsTo<u64>>,
    )
        requires
            old(perm).ptr() == self.word(index),
        ensures
            value == final(perm).value(),
            old(perm).ptr() == final(perm).ptr(),
            final(perm).is_init(),
        opens_invariants none
        no_unwind
    {
        self.handle.store(index, value)
    }

    // Assumes: it reads the bytes [at, at + out.len()) of the stream, which are the data bytes
    // with the indices `(at + j) % capacity`, and it refuses every range outside [tail, seen).
    // The permission `perm` covers that window, and its tokens give the bytes their contents.
    #[verifier::external_body]
    pub fn copy(
        &self,
        tail: u64,
        seen: u64,
        at: u64,
        out: &mut [u8],
        Tracked(perm): Tracked<&Map<nat, ByteTok>>,
    ) -> (res: Option<()>)
        requires
            seen - tail <= self.cap(),
            covers(perm.dom(), self.cap(), tail as nat, seen as nat),
            tok_ok(self.base(), *perm),
        ensures
            final(out).len() == old(out).len(),
            res.is_some() ==> tail <= at && at as nat + final(out).len() <= seen,
            (tail <= at && at as nat + final(out).len() <= seen && at as nat % self.cap()
                + final(out).len() <= self.cap()) ==> res.is_some(),
            res.is_some() ==> forall|j: nat|
                j < final(out).len() && perm.contains_key((at as nat + j) % self.cap())
                    && #[trigger] perm[(at as nat + j) % self.cap()].val() is Some
                    ==> final(out)@[j as int] == perm[(at as nat + j) % self.cap()].val()->0,
    {
        self.handle.copy(tail..seen, at, out)
    }

    // Assumes: the same as `copy`. The slice lives only while the Backend is borrowed, so the
    // permission cannot move while the slice is live.
    #[cfg(not(loom))]
    #[verifier::external_body]
    pub fn bytes(
        &self,
        tail: u64,
        seen: u64,
        at: u64,
        len: u64,
        Tracked(perm): Tracked<&Map<nat, ByteTok>>,
    ) -> (res: Option<&[u8]>)
        requires
            seen - tail <= self.cap(),
            covers(perm.dom(), self.cap(), tail as nat, seen as nat),
            tok_ok(self.base(), *perm),
        ensures
            res.is_some() ==> tail <= at && at as nat + len <= seen && res.unwrap().len() == len,
            (tail <= at && at as nat + len <= seen && at as nat % self.cap() + len <= self.cap())
                ==> res.is_some(),
            res.is_some() ==> forall|j: nat|
                j < len && perm.contains_key((at as nat + j) % self.cap())
                    && #[trigger] perm[(at as nat + j) % self.cap()].val() is Some
                    ==> res.unwrap()@[j as int] == perm[(at as nat + j) % self.cap()].val()->0,
    {
        self.handle.bytes(tail..seen, at, len)
    }

    // Assumes: it writes `bytes` at the data bytes with the indices `(at + j) % capacity`, which
    // the permission `perm` covers. The permission gives these bytes the new contents.
    #[verifier::external_body]
    pub fn write(
        &self,
        at: u64,
        bytes: &[u8],
        Tracked(perm): Tracked<&mut Map<nat, ByteTok>>,
    ) -> (res: Option<()>)
        requires
            covers(old(perm).dom(), self.cap(), at as nat, (at as nat + bytes.len()) as nat),
            tok_ok(self.base(), *old(perm)),
            at as nat % self.cap() + bytes.len() <= self.cap(),
        ensures
            res.is_some(),
            final(perm).dom() == old(perm).dom(),
            tok_ok(self.base(), *final(perm)),
            forall|j: nat|
                j < bytes.len() ==> #[trigger] final(perm)[(at as nat + j) % self.cap()].val()
                    == Some(bytes@[j as int]),
            forall|k: nat|
                old(perm).contains_key(k) && !in_rng(
                    self.cap(),
                    at as nat,
                    (at as nat + bytes.len()) as nat,
                    k,
                ) ==> #[trigger] final(perm)[k] == old(perm)[k],
    {
        self.handle.write(at, bytes)
    }

    // Assumes: the same as `write`, but the slice gives the caller the bytes to fill, and the
    // permission keeps no claim about their contents. The slice lives only while the Backend is
    // borrowed.
    #[cfg(not(loom))]
    #[verifier::external_body]
    pub fn room(
        &mut self,
        at: u64,
        len: usize,
        Tracked(perm): Tracked<&mut Map<nat, ByteTok>>,
    ) -> (res: Option<&mut [u8]>)
        requires
            covers(old(perm).dom(), old(self).cap(), at as nat, (at as nat + len) as nat),
            tok_ok(old(self).base(), *old(perm)),
            at as nat % old(self).cap() + len <= old(self).cap(),
        ensures
            res.is_some(),
            *final(self) == *old(self),
            final(perm).dom() == old(perm).dom(),
            tok_ok(old(self).base(), *final(perm)),
            forall|j: nat|
                j < len ==> #[trigger] final(perm)[(at as nat + j) % old(self).cap()].val() is None,
            forall|k: nat|
                old(perm).contains_key(k) && !in_rng(
                    old(self).cap(),
                    at as nat,
                    (at as nat + len) as nat,
                    k,
                ) ==> #[trigger] final(perm)[k] == old(perm)[k],
    {
        self.handle.room(at, len)
    }
}

} // verus!

impl HandleBox {
    pub fn new(handle: Handle) -> HandleBox {
        HandleBox(handle)
    }
}

impl Backend {
    #[cfg(not(loom))]
    pub fn fd(&self) -> BorrowedFd<'_> {
        self.handle.fd()
    }

    #[cfg(not(loom))]
    pub fn duplicate(&self) -> std::io::Result<Handle> {
        self.handle.duplicate()
    }
}
