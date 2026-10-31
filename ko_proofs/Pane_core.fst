module Pane_core
#lang-pulse
open Pulse.Lib.Pervasives
open KoRing.Spec
open KoRing.Inv
open Feed
module O = Oint
module R = Ring
module D = Delivery_io
module B = Pulse.Lib.Box
module GR = Pulse.Lib.GhostReference
module Seq = FStar.Seq

(* The delivery state of one ko-pane: how far the snapshot slices are handed
   out, the last head seen, and the progress of each queued request. *)
noeq type pane = {
  ring: R.t;
  io: D.pane_io;
  delivered: B.box O.t;
  observed: B.box O.t;
  busy: B.box bool;
  feed: GR.ref (Seq.seq st);
}

noeq type pstate = { dl: O.t; ob: O.t; bz: bool; sts: Seq.seq st; q: D.queues }

let pane_at (p: pane) (s: pstate) : slprop =
  B.pts_to p.delivered s.dl ** B.pts_to p.observed s.ob ** B.pts_to p.busy s.bz **
  GR.pts_to p.feed s.sts ** D.pio p.io s.q

let entry_ok (p: pane) (s: pstate) (i: nat) : prop =
  i < Seq.length s.q.qs /\ i < Seq.length s.sts /\
  D.tring (fst (Seq.index s.q.qs i)) == p.ring /\
  gen_of (Seq.index s.sts i) == D.tgen (fst (Seq.index s.q.qs i)) /\
  (match Seq.index s.sts i with
   | Pending _ fl -> fl == snd (Seq.index s.q.qs i)
   | Sliced _ fl last -> i == 0 /\ fl == snd (Seq.index s.q.qs i) /\ last < O.v s.dl
   | _ -> False)

let pane_inv (p: pane) (rg: rghost) (s: pstate) : prop =
  let d = O.v s.dl in
  let q = s.q in
  0 <= d /\ d <= rg.lr.hd /\ boundary rg.lr d /\
  Seq.length s.sts == Seq.length q.qs /\
  (forall (i: nat). i < Seq.length q.qs ==> entry_ok p s i) /\
  (Seq.length q.qs > 0 ==> rg.tl <= d) /\
  (forall (i j: nat). i <= j /\ j < Seq.length q.fs ==> snd (Seq.index q.fs i) <= snd (Seq.index q.fs j)) /\
  (forall (i: nat). i < Seq.length q.fs ==>
     D.tring (fst (Seq.index q.fs i)) == p.ring /\
     rg.tl <= snd (Seq.index q.fs i) /\ snd (Seq.index q.fs i) <= d /\ boundary rg.lr (snd (Seq.index q.fs i)))

(* A head load keeps every fact about the pane. *)
let inv_grows (p: pane) (rg rg': rghost) (s: pstate)
  : Lemma (requires pane_inv p rg s /\ R.grows rg rg' /\ R.sane p.ring rg /\ R.sane p.ring rg')
          (ensures pane_inv p rg' s)
= let lb (x: nat) : Lemma (requires boundary rg.lr x) (ensures boundary rg'.lr x)
    = log_le_boundary (R.cap p.ring) rg.lr rg'.lr x in
  lb (O.v s.dl);
  Classical.forall_intro (Classical.move_requires lb)

let refold (p: pane) (s: pstate) (dl ob: O.t) (bz: bool) (sts: Seq.seq st) (q: D.queues) : prop =
  s.dl == dl /\ s.ob == ob /\ s.bz == bz /\ s.sts == sts /\ s.q == q

ghost
fn fold_at (p: pane) (s: pstate) (#dl #ob: O.t) (#bz: bool) (#sts: Seq.seq st) (#q: D.queues)
  requires B.pts_to p.delivered dl ** B.pts_to p.observed ob ** B.pts_to p.busy bz **
           GR.pts_to p.feed sts ** D.pio p.io q
  requires pure (refold p s dl ob bz sts q)
  ensures pane_at p s
{
  rewrite each dl as s.dl;
  rewrite each ob as s.ob;
  rewrite each bz as s.bz;
  rewrite each sts as s.sts;
  rewrite each q as s.q;
  fold (pane_at p s)
}

let no_sts : Seq.seq st = Seq.empty

type scanned = | Unchanged | Changed | Aborted

fn make (ring: R.t) (io: D.pane_io) (#g: erased gst) (#rg: erased rghost)
  preserves R.res ring g rg
  requires D.pio io D.empty_queues
  requires pure (boundary rg.lr 0)
  returns p: pane
  ensures exists* (s: pstate). pane_at p s ** pure (pane_inv p rg s /\ p.ring == ring /\ p.io == io)
{
  R.facts ring;
  let z : O.t = O.zero;
  let d = B.alloc z;
  let o = B.alloc z;
  let b = B.alloc false;
  let f = GR.alloc no_sts;
  let p = { ring; io; delivered = d; observed = o; busy = b; feed = f };
  rewrite each d as p.delivered, o as p.observed, b as p.busy, f as p.feed, io as p.io;
  let s : erased pstate = hide (Mkpstate z z false no_sts D.empty_queues);
  fold_at p s;
  p
}

let with_dl (s: pstate) (d: O.t) : pstate = { s with dl = d }

(* Passing the record at the delivered position. *)
let inv_move (p: pane) (rg: rghost) (s: pstate) (nx: O.t)
  : Lemma (requires pane_inv p rg s /\ O.v s.dl <= O.v nx /\ O.v nx <= rg.lr.hd /\ boundary rg.lr (O.v nx))
          (ensures pane_inv p rg (with_dl s nx))
= let s' = with_dl s nx in
  assert (forall (i: nat). i < Seq.length s.q.qs ==> entry_ok p s i ==> entry_ok p s' i)

let slice_now (s: pstate{Seq.length s.sts > 0}) (fl pos: int) : st =
  Sliced (gen_of (Seq.index s.sts 0)) fl pos

let sliced (s: pstate{Seq.length s.sts > 0}) (fl pos: int) : pstate =
  { s with sts = Seq.upd s.sts 0 (slice_now s fl pos) }

(* Handing the slice at [pos] to the front request. *)
let inv_slice (p: pane) (rg: rghost) (s: pstate) (pos: int)
  : Lemma (requires pane_inv p rg s /\ Seq.length s.q.qs > 0 /\ pos < O.v s.dl /\
                    snd (Seq.index s.q.qs 0) <= pos /\
                    (match Seq.index s.sts 0 with Sliced _ _ last -> last < pos | _ -> True))
          (ensures pane_inv p rg (sliced s (snd (Seq.index s.q.qs 0)) pos) /\
                   slice_step (Seq.index s.sts 0) (slice_now s (snd (Seq.index s.q.qs 0)) pos)
                     (D.tgen (fst (Seq.index s.q.qs 0))) pos)
= let s' = sliced s (snd (Seq.index s.q.qs 0)) pos in
  assert (entry_ok p s 0);
  let aux (i: nat) : Lemma (requires i < Seq.length s.q.qs) (ensures entry_ok p s' i)
    = assert (entry_ok p s i) in
  Classical.forall_intro (Classical.move_requires aux)

let fin_state (s: pstate{Seq.length s.q.qs > 0 /\ Seq.length s.sts > 0}) (hold: int) : pstate =
  { s with sts = Seq.tail s.sts;
           q = { D.qs = Seq.tail s.q.qs; D.fs = Seq.snoc s.q.fs (fst (Seq.index s.q.qs 0), hold) } }

(* Dropping the front request keeps every other entry's facts. *)
let entries_shift (p: pane) (s s': pstate)
  : Lemma (requires (forall (i: nat). i < Seq.length s.q.qs ==> entry_ok p s i) /\ Seq.length s.q.qs > 0 /\
                    s'.q.qs == Seq.tail s.q.qs /\ s'.sts == Seq.tail s.sts /\
                    s'.dl == s.dl)
          (ensures (forall (i: nat). i < Seq.length s'.q.qs ==> entry_ok p s' i) /\ entry_ok p s 0)
= let aux (i: nat) : Lemma (requires i < Seq.length s'.q.qs) (ensures entry_ok p s' i)
    = assert (entry_ok p s (i + 1)) in
  Classical.forall_intro (Classical.move_requires aux)

(* The front request's last slice: it waits for snapshot_done, holding the
   tail at the position after that slice. *)
#push-options "--z3rlimit 20"
let inv_fin (p: pane) (rg: rghost) (s: pstate)
  : Lemma (requires pane_inv p rg s /\ Seq.length s.q.qs > 0 /\ rg.tl <= O.v s.dl)
          (ensures pane_inv p rg (fin_state s (O.v s.dl)))
= entries_shift p s (fin_state s (O.v s.dl))


#pop-options

let delivering (p: pane) (rg: rghost) (s0 s: pstate) (d: O.t) : prop =
  pane_inv p rg (with_dl s d) /\ s.dl == s0.dl /\ rg.tl <= O.v d /\ s.ob == s0.ob /\ s.bz == s0.bz /\
  O.v s0.dl <= O.v d

(* Hand every snapshot slice below [upper] to the request it answers. False if
   ko-pane wrote a slice before the request it answers. *)
fn deliver (p: pane) (upper: O.t) (#g: erased gst) (#rg: erased rghost) (#s0: erased pstate)
  preserves R.res p.ring g rg
  requires pane_at p s0
  requires pure (pane_inv p rg s0 /\ 0 <= O.v upper /\ O.v upper <= rg.lr.hd)
  returns ok: bool
  ensures exists* (s: pstate). pane_at p s **
    pure (pane_inv p rg s /\ s.ob == s0.ob /\ s.bz == s0.bz /\
          (ok /\ Seq.length s0.q.qs > 0 ==> O.v upper <= O.v s.dl))
{
  R.facts p.ring;
  unfold pane_at;
  let e = D.queue_empty p.io;
  if e {
    fold (pane_at p s0);
    true
  } else {
    let d0 = B.op_Bang p.delivered;
    fold (pane_at p s0);
    let mut d = d0;
    let mut good = true;
    while (!good && O.lt !d upper)
    invariant exists* (s: pstate) (vd: O.t) (vg: bool).
      pane_at p s ** pts_to d vd ** pts_to good vg **
      pure (delivering p rg s0 s vd)
    decreases (if !good then 1 + rg.lr.hd - O.v !d else 0)
    {
      with s vd0 vg0. assert (pane_at p s ** pts_to d vd0 ** pts_to good vg0);
      let pos = !d;
      KoRing.Walk.step (R.cap p.ring) rg.lr (O.v pos);
      let nx = R.next p.ring pos;
      let k = R.kind p.ring pos;
      inv_move p rg (with_dl s pos) nx;
      if (R.Slice? k) {
        unfold pane_at;
        let qe = D.queue_empty p.io;
        if (qe) {
          fold (pane_at p s);
          d := nx
        } else {
          let t = D.queue_front p.io;
          let fl = D.queue_floor p.io;
          if (O.le fl pos) {
            let s1 : erased pstate = with_dl s nx;
            inv_slice p rg s1 (O.v pos);
            let prior : erased st = Seq.index s.sts 0;
            let now : erased st = slice_now s1 (O.v fl) (O.v pos);
            D.slice t pos p.ring #g #rg #prior #now;
            GR.op_Colon_Equals p.feed (Seq.upd s.sts 0 now);
            let s2 : erased pstate = sliced s1 (O.v fl) (O.v pos);
            let last = D.slice_last p.ring pos;
            if (last) {
              D.queue_to_fin p.io nx;
              GR.op_Colon_Equals p.feed (Seq.tail s2.sts);
              inv_fin p rg s2;
              let s3 : erased pstate = fin_state s2 (O.v nx);
              fold_at p (with_dl s3 s.dl);
              d := nx
            } else {
              fold_at p (with_dl s2 s.dl);
              d := nx
            }
          } else {
            fold (pane_at p s);
            good := false
          }
        }
      } else {
        d := nx
      }
    };
    with s vd vg. assert (pane_at p s ** pts_to d vd ** pts_to good vg);
    unfold pane_at;
    let vd = !d;
    B.op_Colon_Equals p.delivered vd;
    fold (pane_at p (with_dl s vd));
    !good
  }
}

let request_state (s: pstate) (t: D.token) (floor: int) : GTot pstate =
  { s with sts = Seq.snoc s.sts (Pending (D.tgen t) floor); q = { s.q with D.qs = Seq.snoc s.q.qs (t, floor) } }

let inv_request (p: pane) (rg: rghost) (s: pstate) (t: D.token) (floor: int)
  : Lemma (requires pane_inv p rg s /\ D.tring t == p.ring /\ rg.tl <= O.v s.dl)
          (ensures pane_inv p rg (request_state s t floor))
= let s' = request_state s t floor in
  let aux (i: nat) : Lemma (requires i < Seq.length s'.q.qs) (ensures entry_ok p s' i)
    = if i < Seq.length s.q.qs then assert (entry_ok p s i) in
  Classical.forall_intro (Classical.move_requires aux)

(* Queue a view's snapshot request. Its floor is the head now: ko-pane writes
   the request's slices after it reads the request. *)
fn note_snapshot (p: pane) (t: D.token) (#g: erased gst) (#rg: erased rghost) (#s: erased pstate)
  requires R.res p.ring g rg ** pane_at p s
  requires pure (pane_inv p rg s /\ D.tring t == p.ring)
  ensures exists* (rg': rghost) (s': pstate). R.res p.ring g rg' ** pane_at p s' **
    pure (R.grows rg rg' /\ pane_inv p rg' s' /\ s'.ob == s.ob /\ s'.bz == s.bz /\
          Seq.length s'.q.qs == Seq.length s.q.qs + 1)
{
  R.facts p.ring;
  let h = R.head p.ring;
  with rg1. assert (R.res p.ring g rg1);
  inv_grows p rg rg1 s;
  unfold pane_at;
  let e = D.queue_empty p.io;
  let s1 : erased pstate = (if e then FStar.Ghost.elift1 (fun x -> with_dl x h) s else s);
  if e {
    B.op_Colon_Equals p.delivered h;
    rewrite B.pts_to p.delivered h as B.pts_to p.delivered s1.dl
  } else {
    rewrite B.pts_to p.delivered s.dl as B.pts_to p.delivered s1.dl
  };
  D.queue_push p.io t h;
  GR.op_Colon_Equals p.feed (Seq.snoc s.sts (Pending (D.tgen t) (O.v h)));
  inv_request p rg1 s1 t (O.v h);
  let s2 : erased pstate = request_state s1 t (O.v h);
  fold_at p s2;
}

let fin_drop (s: pstate{Seq.length s.q.fs > 0}) : pstate = { s with q = { s.q with D.fs = Seq.tail s.q.fs } }

let inv_fin_drop (p: pane) (rg: rghost) (s: pstate)
  : Lemma (requires pane_inv p rg s /\ Seq.length s.q.fs > 0)
          (ensures pane_inv p rg (fin_drop s))
= let s' = fin_drop s in
  let fs = s.q.fs in
  assert (s'.q.qs == s.q.qs /\ s'.sts == s.sts /\ s'.dl == s.dl);
  let e (i: nat) : Lemma (requires i < Seq.length s.q.qs) (ensures entry_ok p s' i) = assert (entry_ok p s i) in
  Classical.forall_intro (Classical.move_requires e);
  let ft = Seq.tail fs in
  let o (i j: nat) : Lemma (i <= j /\ j < Seq.length ft ==> snd (Seq.index ft i) <= snd (Seq.index ft j))
    = if i <= j && j < Seq.length ft then
        assert (Seq.index ft i == Seq.index fs (i + 1) /\ Seq.index ft j == Seq.index fs (j + 1)) in
  Classical.forall_intro_2 o;
  let m (i: nat) : Lemma (i < Seq.length ft ==>
      D.tring (fst (Seq.index ft i)) == p.ring /\ rg.tl <= snd (Seq.index ft i) /\
      snd (Seq.index ft i) <= O.v s.dl /\ boundary rg.lr (snd (Seq.index ft i)))
    = if i < Seq.length ft then assert (Seq.index ft i == Seq.index fs (i + 1)) in
  Classical.forall_intro m

let drop_front (s: pstate{Seq.length s.q.qs > 0 /\ Seq.length s.sts > 0}) : pstate =
  { s with sts = Seq.tail s.sts; q = { s.q with D.qs = Seq.tail s.q.qs } }

let inv_drop_front (p: pane) (rg: rghost) (s: pstate)
  : Lemma (requires pane_inv p rg s /\ Seq.length s.q.qs > 0)
          (ensures pane_inv p rg (drop_front s))
= entries_shift p s (drop_front s)

(* snapshot_done for request [req]: the oldest finished request's view may
   resume, and the tail no longer has to wait at its hold. If [req] is still
   reading, ko-pane ended it without its last slice and it fails; any other
   [req] is ignored. *)
fn snapshot_done (p: pane) (req: O.t) (#g: erased gst) (#rg: erased rghost) (#s: erased pstate)
  preserves R.res p.ring g rg
  requires pane_at p s
  requires pure (pane_inv p rg s)
  ensures exists* (s': pstate). pane_at p s' ** pure (pane_inv p rg s' /\ s'.ob == s.ob /\ s'.bz == s.bz)
{
  unfold pane_at;
  let fe = D.fin_empty p.io;
  let qe = D.queue_empty p.io;
  if (not fe) {
    let t = D.fin_front p.io;
    if (O.eq (D.req t) req) {
      let prior : erased st = Finished (D.tgen t) (snd (Seq.index s.q.fs 0));
      D.fin_pop p.io;
      D.finish t true p.ring #g #rg #prior;
      inv_fin_drop p rg s;
      fold_at p (fin_drop s)
    } else {
      fold (pane_at p s)
    }
  } else if (not qe) {
    let t = D.queue_front p.io;
    if (O.eq (D.req t) req) {
      assert (pure (entry_ok p s 0));
      let prior : erased st = Seq.index s.sts 0;
      D.queue_pop p.io;
      D.finish t false p.ring #g #rg #prior;
      GR.op_Colon_Equals p.feed (Seq.tail s.sts);
      inv_drop_front p rg s;
      fold_at p (drop_front s)
    } else {
      fold (pane_at p s)
    }
  } else {
    fold (pane_at p s)
  }
}

(* The pane process ended: every request, finished or not, fails. *)
divergent fn fail_requests (p: pane) (#g: erased gst) (#rg: erased rghost) (#s: erased pstate)
  preserves R.res p.ring g rg
  requires pane_at p s
  requires pure (pane_inv p rg s)
  ensures exists* (s': pstate). pane_at p s' **
    pure (pane_inv p rg s' /\ s'.ob == s.ob /\ s'.bz == s.bz /\
          Seq.length s'.q.qs == 0 /\ Seq.length s'.q.fs == 0)
{
  let mut more = true;
  while (!more)
  invariant exists* (s1: pstate) (vm: bool). pane_at p s1 ** pts_to more vm **
    pure (pane_inv p rg s1 /\ s1.ob == s.ob /\ s1.bz == s.bz /\
          (not vm ==> Seq.length s1.q.qs == 0 /\ Seq.length s1.q.fs == 0))
  {
    with s1 vm. assert (pane_at p s1 ** pts_to more vm);
    unfold pane_at;
    let fe = D.fin_empty p.io;
    if (not fe) {
      let t = D.fin_front p.io;
      D.fin_pop p.io;
      let prior : erased st = Finished (D.tgen t) 0;
      D.finish t false p.ring #g #rg #prior;
      inv_fin_drop p rg s1;
      fold_at p (fin_drop s1)
    } else {
      let qe = D.queue_empty p.io;
      if (not qe) {
        let t = D.queue_front p.io;
        D.queue_pop p.io;
        assert (pure (entry_ok p s1 0));
        let prior : erased st = Seq.index s1.sts 0;
        D.finish t false p.ring #g #rg #prior;
        GR.op_Colon_Equals p.feed (Seq.tail s1.sts);
        inv_drop_front p rg s1;
        fold_at p (drop_front s1)
      } else {
        fold (pane_at p s1);
        more := false
      }
    }
  }
}

(* The tail moved, but not past a position the pane still needs. *)
let inv_advance (p: pane) (rg rg': rghost) (s: pstate) (keep: int)
  : Lemma (requires pane_inv p rg s /\ rg'.lr == rg.lr /\ rg.tl <= rg'.tl /\ rg'.tl <= keep /\
                    (Seq.length s.q.qs > 0 ==> keep <= O.v s.dl) /\
                    (Seq.length s.q.fs > 0 ==> keep <= snd (Seq.index s.q.fs 0)))
          (ensures pane_inv p rg' s)
= ()

let keep_of (s: pstate) (hd: int) : GTot int =
  let k = if Seq.length s.q.qs = 0 then hd else O.v s.dl in
  if Seq.length s.q.fs = 0 then k else (if snd (Seq.index s.q.fs 0) < k then snd (Seq.index s.q.fs 0) else k)

(* Load the head, hand out slices, and release the ring up to what nothing
   needs: no snapshot request still reading, no finished one waiting for its
   snapshot_done. *)
fn scan (p: pane) (opened: bool) (#g: erased gst) (#rg: erased rghost) (#s: erased pstate)
  requires R.res p.ring g rg ** pane_at p s
  requires pure (pane_inv p rg s)
  returns r: scanned
  ensures exists* (rg': rghost) (s': pstate). R.res p.ring g rg' ** pane_at p s' **
    pure (pane_inv p rg' s' /\ rg'.tl >= rg.tl /\ log_le rg.lr rg'.lr /\ (not opened ==> r == Unchanged))
{
  if (not opened) {
    Unchanged
  } else {
    R.facts p.ring;
    let head = R.head p.ring;
    with rg1. assert (R.res p.ring g rg1);
    inv_grows p rg rg1 s;
    let ok = deliver p head;
    with s1. assert (pane_at p s1);
    if (not ok) {
      Aborted
    } else {
      unfold pane_at;
      let qe = D.queue_empty p.io;
      let d = B.op_Bang p.delivered;
      let k0 = (if qe then head else d);
      let fe = D.fin_empty p.io;
      let h = (if fe then k0 else D.fin_hold p.io);
      let keep = (if O.lt h k0 then h else k0);
      assert (pure (O.v keep == keep_of s1 (O.v head)));
      assert (pure (boundary rg1.lr (O.v keep) /\ rg1.tl <= O.v keep));
      R.advance p.ring head keep;
      with rg2. assert (R.res p.ring g rg2);
      KoRing.Walk.keeps (R.cap p.ring) rg1 rg2 (O.v head) (O.v keep);
      inv_advance p rg1 rg2 s1 (O.v keep);
      let ob = B.op_Bang p.observed;
      let changed = not (O.eq head ob);
      B.op_Colon_Equals p.observed head;
      B.op_Colon_Equals p.busy changed;
      let s2 : erased pstate = Mkpstate s1.dl head changed s1.sts s1.q;
      fold_at p s2;
      (if changed then Changed else Unchanged)
    }
  }
}

let ring (p: pane) : R.t = p.ring

fn busy (p: pane) (#s: erased pstate)
  preserves pane_at p s
  returns b: bool
  ensures pure (b == s.bz)
{
  unfold pane_at;
  let b = B.op_Bang p.busy;
  fold (pane_at p s);
  b
}
