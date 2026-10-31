module View_core
#lang-pulse
open Pulse.Lib.Pervasives
open KoRing.Spec
open KoRing.Inv
open Feed
module O = Oint
module R = Ring
module D = Delivery_io
module C = Connection
module P = Protocol
module B = Pulse.Lib.Box
module GR = Pulse.Lib.GhostReference
module Seq = FStar.Seq

type vstate = | Live | Snapshotting | Closed
type decision = | Resume | Snapshot : P.history -> decision | Skip

let skip_threshold : int = 65536
let generations : int = 1073741824

(* Ghost: the stream offset the client was sent up to, and for a snapshot in
   flight the head when it was asked for and the last slice it delivered. *)
noeq type vghost = { vpos: int; floor: nat; snapped: bool; last_slice: nat }

noeq type view = {
  ring: R.t;
  conn: C.t;
  io: D.view_io;
  state: B.box vstate;
  cpos: B.box O.t;
  coff: B.box O.t;
  blocked: B.box bool;
  history: B.box P.history;
  wanted: B.box (option P.history);
  gen: B.box O.t;
  nexts: O.arr;
  ends: O.arr;
  vg: GR.ref vghost;
}

noeq type vs = {
  st: vstate; cp: O.t; co: O.t; bl: bool; hi: P.history; wa: option P.history; gn: O.t;
  nx: Seq.seq O.t; en: Seq.seq O.t; gh: vghost; cs: C.cs;
}

let view_at (v: view) (s: vs) : slprop =
  B.pts_to v.state s.st ** B.pts_to v.cpos s.cp ** B.pts_to v.coff s.co **
  B.pts_to v.blocked s.bl ** B.pts_to v.history s.hi ** B.pts_to v.wanted s.wa **
  B.pts_to v.gen s.gn ** O.arr_pts v.nexts s.nx ** O.arr_pts v.ends s.en **
  GR.pts_to v.vg s.gh ** C.conn v.conn s.cs

(* The boundary after [p], or [p] at the head. *)
let next_bnd (l: log) (p: nat) : nat =
  match l.m p with Some r -> p + inc r | None -> p

(* The cursor is a boundary and its offset lies within the record there. *)
let cursor_ok (rg: rghost) (s: vs) : prop =
  0 <= O.v s.cp /\ O.v s.cp <= rg.lr.hd /\ boundary rg.lr (O.v s.cp) /\
  off_at rg.lr (O.v s.cp) <= O.v s.co /\ O.v s.co <= off_at rg.lr (next_bnd rg.lr (O.v s.cp))

(* The cursor is valid and the stream is at its offset. *)
let streaming (rg: rghost) (s: vs) : prop = cursor_ok rg s /\ O.v s.co == s.gh.vpos

let same_req (s0 s: vs) : prop = s.wa == s0.wa /\ s.hi == s0.hi /\ s.gn == s0.gn

let shape_inv (s: vs) : prop =
  Seq.length s.nx == O.v C.batch_capacity /\ Seq.length s.en == O.v C.batch_capacity /\
  0 <= O.v s.gn /\ O.v s.gn < generations

let base_inv (rg: rghost) (s: vs) : prop =
  shape_inv s /\
  (Closed? s.st ==> s.cs.C.closed) /\
  (~(Closed? s.st) ==>
     C.conn_ok s.cs /\ 0 <= s.gh.vpos /\ s.gh.vpos <= rg.lr.hoff /\
     (Snapshotting? s.st ==>
        s.gh.floor <= rg.lr.hd /\ boundary rg.lr s.gh.floor /\
        (s.gh.snapped ==>
           streaming rg s /\ Some? (rg.lr.m s.gh.last_slice) /\
           s.gh.vpos == off_at rg.lr s.gh.last_slice /\ s.gh.floor <= s.gh.last_slice) /\
        (not s.gh.snapped ==> s.gh.vpos <= off_at rg.lr s.gh.floor)))

let pre_inv (rg: rghost) (s: vs) : prop =
  base_inv rg s /\ (~(Closed? s.st) ==> s.cs.C.bcount == 0)

let view_inv (rg: rghost) (s: vs) : prop =
  pre_inv rg s /\ (Live? s.st /\ None? s.wa ==> streaming rg s)

(* Batch entry [i] ends at the boundary [nx i], at stream offset [en i]. *)
let batch_ok (rg: rghost) (s: vs) : prop =
  forall (i: nat). i < s.cs.C.bcount ==>
    i < Seq.length s.nx /\ i < Seq.length s.en /\ 0 <= O.v (Seq.index s.nx i) /\
    boundary rg.lr (O.v (Seq.index s.nx i)) /\ O.v (Seq.index s.nx i) <= rg.lr.hd /\
    O.v s.cp < O.v (Seq.index s.nx i) /\
    O.v (Seq.index s.en i) == off_at rg.lr (O.v (Seq.index s.nx i))

(* Where the stream will be once the batch is sent. *)
let bend (s: vs) : GTot int =
  if s.cs.C.bcount > 0 && s.cs.C.bcount <= Seq.length s.en then O.v (Seq.index s.en (s.cs.C.bcount - 1))
  else s.gh.vpos

(* Resume, skip to the head, or take a snapshot. *)
let decide (behind: bool) (offset head: O.t) (h: P.history) (resize blocked: bool)
  : Pure decision
    (requires 0 <= O.v offset /\ 0 <= O.v head)
    (ensures fun d ->
       (Skip? d <==> (blocked /\ O.v head - O.v offset >= skip_threshold)) /\
       (Resume? d ==> not behind) /\
       (Resume? d <==>
          (~(blocked /\ O.v head - O.v offset >= skip_threshold) /\ not behind /\
           ~(resize /\ P.History_none? h))))
= if blocked && O.le O.c65536 (O.sub head offset) then Skip
  else if behind then Snapshot h
  else if resize && P.History_none? h then Snapshot P.History_none
  else Resume

let same_vs (s: vs) (st: vstate) (cp co: O.t) (bl: bool) (hi: P.history) (wa: option P.history)
  (gn: O.t) (nx en: Seq.seq O.t) (gh: vghost) (cs: C.cs) : prop =
  s.st == st /\ s.cp == cp /\ s.co == co /\ s.bl == bl /\ s.hi == hi /\ s.wa == wa /\
  s.gn == gn /\ s.nx == nx /\ s.en == en /\ s.gh == gh /\ s.cs == cs

ghost
fn vfold (v: view) (s: vs) (#st: vstate) (#cp #co: O.t) (#bl: bool) (#hi: P.history)
  (#wa: option P.history) (#gn: O.t) (#nx #en: Seq.seq O.t) (#gh: vghost) (#cs: C.cs)
  requires B.pts_to v.state st ** B.pts_to v.cpos cp ** B.pts_to v.coff co **
           B.pts_to v.blocked bl ** B.pts_to v.history hi ** B.pts_to v.wanted wa **
           B.pts_to v.gen gn ** O.arr_pts v.nexts nx ** O.arr_pts v.ends en **
           GR.pts_to v.vg gh ** C.conn v.conn cs
  requires pure (same_vs s st cp co bl hi wa gn nx en gh cs)
  ensures view_at v s
{
  rewrite each st as s.st, cp as s.cp, co as s.co, bl as s.bl, hi as s.hi, wa as s.wa, gn as s.gn, nx as s.nx, en as s.en, gh as s.gh, cs as s.cs;
  fold (view_at v s)
}

let closed_vs (s: vs) : vs = { s with st = Closed; cs = C.closed_now s.cs }

fn close (v: view) (#rg: erased rghost) (#s: erased vs)
  requires view_at v s
  requires pure (shape_inv s /\ (Closed? s.st ==> s.cs.C.closed))
  ensures exists* (s': vs). view_at v s' **
    pure (base_inv rg s' /\ Closed? s'.st /\ s'.cp == s.cp /\ s'.co == s.co /\ s'.nx == s.nx /\
          s'.en == s.en /\ s'.bl == s.bl /\ same_req s s' /\ s'.gh == s.gh /\
          s'.cs.C.closed /\ s'.cs.C.bcount == s.cs.C.bcount)
{
  unfold view_at;
  let st = B.op_Bang v.state;
  if (Closed? st) {
    fold (view_at v s)
  } else {
    B.op_Colon_Equals v.state Closed;
    C.close v.conn;
    vfold v (closed_vs s)
  }
}

fn view_waiting (v: view) (#s: erased vs)
  preserves view_at v s
  returns b: bool
{
  unfold view_at;
  let st = B.op_Bang v.state;
  match st {
    Closed -> { fold (view_at v s); false }
    Snapshotting -> { fold (view_at v s); true }
    Live -> { let w = C.waiting v.conn; fold (view_at v s); w }
  }
}

(* Move the cursor past the last batch entry the kernel took. *)
fn take_sent (v: view) (accepted: O.t{0 <= O.v accepted}) (#cp #co: erased O.t)
  (#nx: erased (Seq.seq O.t){O.v accepted <= Seq.length nx})
  (#en: erased (Seq.seq O.t){Seq.length en == Seq.length nx})
  requires B.pts_to v.cpos cp ** B.pts_to v.coff co ** O.arr_pts v.nexts nx ** O.arr_pts v.ends en
  ensures exists* (cp' co': O.t). B.pts_to v.cpos cp' ** B.pts_to v.coff co' **
    O.arr_pts v.nexts nx ** O.arr_pts v.ends en **
    pure (if O.v accepted = 0 then cp' == reveal cp /\ co' == reveal co
          else cp' == Seq.index nx (O.v accepted - 1) /\ co' == Seq.index en (O.v accepted - 1))
{
  if (O.lt O.zero accepted) {
    let i = O.sub accepted O.one;
    let n = O.arr_get v.nexts i;
    let e = O.arr_get v.ends i;
    B.op_Colon_Equals v.cpos n;
    B.op_Colon_Equals v.coff e;
  }
}

let at_vpos (g: vghost) (p: int) : vghost = { g with vpos = p }
let after_send (s: vs) (cp co: O.t) (cs: C.cs) : GTot vs = { s with cp = cp; co = co; cs = cs; gh = at_vpos s.gh (O.v co) }

let flushed (rg: rghost) (s s': vs) (ok: bool) : prop =
  base_inv rg s' /\ s'.cs.C.bcount == 0 /\
  (Closed? s'.st \/ (Live? s'.st /\ streaming rg s')) /\
  (ok ==> Live? s'.st /\ O.v s'.co == bend s) /\
  (not ok ==> Closed? s'.st \/ s'.bl) /\
  O.v s.cp <= O.v s'.cp /\ s'.nx == s.nx /\ s'.en == s.en /\ same_req s s' /\
  (s'.cp == s.cp \/ (exists (i: nat). i < s.cs.C.bcount /\ i < Seq.length s.nx /\ s'.cp == Seq.index s.nx i))

let sent_cursor (cap: capt) (rg: rghost) (s: vs) (cs': C.cs) (a: int) (cp co: O.t)
  : Lemma (requires Live? s.st /\ base_inv rg s /\ batch_ok rg s /\ streaming rg s /\
                    C.sent s.cs cs' a /\ 0 <= a /\ wf cap rg.lr /\ a <= Seq.length s.nx /\ Seq.length s.en == Seq.length s.nx /\
                    (if a = 0 then cp == s.cp /\ co == s.co
                     else cp == Seq.index s.nx (a - 1) /\ co == Seq.index s.en (a - 1)))
          (ensures streaming rg (after_send s cp co cs') /\ O.v s.cp <= O.v cp /\
                   0 <= O.v co /\ O.v co <= rg.lr.hoff /\ (a == s.cs.C.bcount ==> O.v co == bend s) /\
                   (cp == s.cp \/ (exists (i: nat). i < s.cs.C.bcount /\ i < Seq.length s.nx /\ cp == Seq.index s.nx i)))
= if a > 0 then begin
    let p : nat = O.v (Seq.index s.nx (a - 1)) in
    if Some? (rg.lr.m p) then wf_rec cap rg.lr p;
    off_le_hoff cap rg.lr p;
    assert (exists (i: nat). i < s.cs.C.bcount /\ i < Seq.length s.nx /\ cp == Seq.index s.nx i)
  end

(* Send the batch. Not sent means the view closed or its connection blocked. *)
fn flush_batch (v: view) (#g: erased gst) (#rg: erased rghost) (#s: erased vs)
  preserves R.res v.ring g rg
  requires view_at v s
  requires pure (Live? s.st /\ base_inv rg s /\ batch_ok rg s /\ streaming rg s)
  returns ok: bool
  ensures exists* (s': vs). view_at v s' ** pure (flushed rg s s' ok)
{
  R.facts v.ring;
  unfold view_at;
  let count = C.batch_count v.conn;
  if (O.eq count O.zero) {
    fold (view_at v s);
    true
  } else {
    let accepted = C.batch_send v.conn (R.buffer_of v.ring);
    with cs1. assert (C.conn v.conn cs1);
    if (O.lt accepted O.zero) {
      vfold v ({ s with cs = cs1 });
      close v #rg;
      false
    } else {
      take_sent v accepted;
      with cp co. assert (B.pts_to v.cpos cp ** B.pts_to v.coff co);
      sent_cursor (R.cap v.ring) rg s cs1 (O.v accepted) cp co;
      GR.op_Colon_Equals v.vg (at_vpos s.gh (O.v co));
      let w = C.waiting v.conn;
      if (O.lt accepted count || w) {
        B.op_Colon_Equals v.blocked true;
        vfold v ({ after_send s cp co cs1 with bl = true });
        false
      } else {
        vfold v (after_send s cp co cs1);
        true
      }
    }
  }
}

(* A head load keeps the view's facts: the log only grows. *)
let grow_cursor (cap: capt) (rg rg1: rghost) (s: vs)
  : Lemma (requires cursor_ok rg s /\ R.grows rg rg1 /\ wf cap rg.lr /\ wf cap rg1.lr)
          (ensures cursor_ok rg1 s)
= let p : nat = O.v s.cp in
  log_le_boundary cap rg.lr rg1.lr p;
  if Some? (rg.lr.m p) then (wf_rec cap rg.lr p; log_le_boundary cap rg.lr rg1.lr (next_bnd rg.lr p))
  else if Some? (rg1.lr.m p) then wf_rec cap rg1.lr p

let grow_view (cap: capt) (rg rg1: rghost) (s: vs)
  : Lemma (requires view_inv rg s /\ R.grows rg rg1 /\ wf cap rg.lr /\ wf cap rg1.lr)
          (ensures view_inv rg1 s)
= if Snapshotting? s.st then begin
    log_le_boundary cap rg.lr rg1.lr s.gh.floor;
    if s.gh.snapped then begin
      grow_cursor cap rg rg1 s;
      wf_rec cap rg.lr s.gh.last_slice;
      log_le_boundary cap rg.lr rg1.lr s.gh.last_slice
    end
  end;
  if Live? s.st && None? s.wa then grow_cursor cap rg rg1 s

(* Whether a resize marker at or after [offset] follows [pos]. *)
fn resize_pending (h: R.t) (pos offset: O.t) (#g: erased gst) (#rg: erased rghost)
  requires R.res h g rg
  requires pure (rg.tl <= O.v pos /\ O.v pos <= rg.lr.hd /\ boundary rg.lr (O.v pos))
  returns found: bool
  ensures exists* (rg': rghost). R.res h g rg' ** pure (R.loaded h rg rg')
{
  R.facts h;
  let upper = R.head h;
  with rg1. assert (R.res h g rg1);
  log_le_boundary (R.cap h) rg.lr rg1.lr (O.v pos);
  let mut p = pos;
  let mut found = false;
  while (not !found && O.lt !p upper)
  invariant exists* (vp: O.t) (vf: bool). pts_to p vp ** pts_to found vf ** R.res h g rg1 **
    pure (O.v pos <= O.v vp /\ O.v vp <= rg1.lr.hd /\ boundary rg1.lr (O.v vp) /\ rg1.tl <= O.v pos)
  decreases (if !found then 0 else 1 + rg1.lr.hd - O.v !p)
  {
    let vp = !p;
    KoRing.Walk.step (R.cap h) rg1.lr (O.v vp);
    let nx = R.next h vp;
    p := nx;
    let k = R.kind h vp;
    match k {
      R.Marker -> {
        let r = D.is_resize h vp;
        if (r) {
          let o = R.offset h vp;
          found := O.le offset o
        }
      }
      _ -> { () }
    }
  };
  !found
}

(* A resume walk at [pos]: the batch holds the bytes from the cursor's offset
   up to [pos], each entry ending at a boundary; once the walk stops, the
   batch is empty. *)
let resuming (rg: rghost) (s0 s: vs) (pos: int) (go: bool) : prop =
  0 <= O.v s.cp /\ O.v s.cp <= pos /\ pos <= rg.lr.hd /\ boundary rg.lr pos /\ rg.tl <= O.v s.cp /\
  base_inv rg s /\ batch_ok rg s /\
  (Closed? s.st ==> not go) /\ (go ==> Live? s.st) /\ ~(Snapshotting? s.st) /\
  (Live? s.st ==> streaming rg s) /\
  (forall (i: nat). i < s.cs.C.bcount ==> i < Seq.length s.nx /\ O.v (Seq.index s.nx i) <= pos) /\
  (go /\ s.cs.C.bcount == 0 ==> (off_at rg.lr pos == O.v s.co \/ pos == O.v s.cp)) /\
  (go /\ s.cs.C.bcount > 0 ==> bend s == off_at rg.lr pos) /\
  (s.cs.C.bcount == 0 \/ go) /\
  same_req s0 s

let flushed_resuming (rg: rghost) (s0 s s': vs) (pos: nat) (ok: bool)
  : Lemma (requires resuming rg s0 s pos true /\ flushed rg s s' ok /\ s.cs.C.bcount > 0)
          (ensures resuming rg s0 s' pos ok)
= ()

let marked (s: vs) (cs: C.cs) (cp: O.t) : vs = { s with cs = cs; cp = cp }

(* After the flush, the marker is exactly at the stream position. *)
let marker_next (cap: capt) (rg: rghost) (s0 s s1: vs) (cs2: C.cs) (here: nat) (following: O.t)
  : Lemma (requires resuming rg s0 s here true /\ wf cap rg.lr /\ R.vis rg here /\
                    R.Marker? (R.kind_of rg here) /\ flushed rg s s1 true /\
                    O.v following == R.next_of rg here /\ D.kept s1.cs cs2 /\
                    (R.rec_of rg here).off == s1.gh.vpos /\ off_at rg.lr here == O.v s1.co)
          (ensures resuming rg s0 (marked s1 cs2 following) (O.v following) true)
= wf_rec cap rg.lr here;
  let f : nat = O.v following in
  if Some? (rg.lr.m f) then wf_rec cap rg.lr f;
  off_le_hoff cap rg.lr f

fn step_marker (v: view) (here following: O.t) (#g: erased gst)
  (#rg: erased rghost{R.vis rg (O.v here) /\ R.kind_of rg (O.v here) == R.Marker}) (#s0 #s: erased vs)
  requires view_at v s ** R.res v.ring g rg
  requires pure (resuming rg s0 s (O.v here) true /\ O.v following == R.next_of rg (O.v here))
  returns go: bool
  ensures exists* (s': vs). view_at v s' ** R.res v.ring g rg **
    pure (resuming rg s0 s' (if go then O.v following else O.v here) go /\ s'.cs.C.bcount == 0)
{
  R.facts v.ring;
  let ok = flush_batch v;
  with s1. assert (view_at v s1);
  if (ok) {
    wf_rec (R.cap v.ring) rg.lr (O.v here);
    unfold view_at;
    let o = R.offset v.ring here;
    assert (pure (O.v o == s1.gh.vpos));
    D.json_marked v.conn v.ring here o;
    with cs2. assert (C.conn v.conn cs2);
    B.op_Colon_Equals v.cpos following;
    marker_next (R.cap v.ring) rg s0 s s1 cs2 (O.v here) following;
    vfold v (marked s1 cs2 following);
    true
  } else {
    false
  }
}

let skip_of (start: O.t{0 <= O.v start}) (co: O.t{0 <= O.v co}) (cnt: O.t) : O.t =
  if O.eq cnt O.zero then (if O.lt start co then O.sub co start else O.zero) else O.zero

let batched (s: vs) (n: int) (nx en: Seq.seq O.t) : vs = { s with cs = { s.cs with C.bcount = n }; nx = nx; en = en }

(* The bytes record at [here] continues the stream where the batch ends. *)
let bytes_fit (cap: capt) (rg: rghost) (s0 s: vs) (here: nat) (start len co cnt: O.t)
  : Lemma (requires resuming rg s0 s here true /\ wf cap rg.lr /\ R.vis rg here /\
                    R.Bytes? (R.kind_of rg here) /\ O.v start == (R.rec_of rg here).off /\
                    O.v len == (R.rec_of rg here).len /\ co == s.co /\ O.v cnt == s.cs.C.bcount /\
                    ~(O.v start + O.v len <= O.v co /\ O.v cnt == 0) /\ 0 <= O.v start /\ 0 <= O.v co)
          (ensures (let sk = O.v (skip_of start co cnt) in
                    0 <= sk /\ sk <= O.v len /\ O.v start + sk == bend s /\
                    O.v start + O.v len == off_at rg.lr (R.next_of rg here) /\
                    O.v start + O.v len <= rg.lr.hoff))
= wf_rec cap rg.lr here;
  off_le_hoff cap rg.lr (R.next_of rg here)

let bytes_added (cap: capt) (rg: rghost) (s0 s: vs) (here: nat) (following e: O.t) (nx en: Seq.seq O.t)
  : Lemma (requires resuming rg s0 s here true /\ wf cap rg.lr /\ R.vis rg here /\
                    O.v following == R.next_of rg here /\ O.v e == off_at rg.lr (O.v following) /\
                    0 <= s.cs.C.bcount /\ s.cs.C.bcount < O.v C.batch_capacity /\
                    Seq.length s.nx == O.v C.batch_capacity /\ Seq.length s.en == O.v C.batch_capacity /\
                    nx == Seq.upd s.nx s.cs.C.bcount following /\ en == Seq.upd s.en s.cs.C.bcount e)
          (ensures resuming rg s0 (batched s (s.cs.C.bcount + 1) nx en) (O.v following) true)
= wf_rec cap rg.lr here

fn step_bytes (v: view) (here following: O.t) (#g: erased gst)
  (#rg: erased rghost{R.vis rg (O.v here) /\ R.kind_of rg (O.v here) == R.Bytes}) (#s0 #s: erased vs)
  requires view_at v s ** R.res v.ring g rg
  requires pure (resuming rg s0 s (O.v here) true /\ O.v following == R.next_of rg (O.v here) /\
                 s.cs.C.bcount < O.v C.batch_capacity)
  returns go: bool
  ensures exists* (s': vs). view_at v s' ** R.res v.ring g rg **
    pure (resuming rg s0 s' (O.v following) go /\ (go ==> s'.cs.C.bcount < O.v C.batch_capacity))
{
  R.facts v.ring;
  wf_rec (R.cap v.ring) rg.lr (O.v here);
  let start = R.offset v.ring here;
  let len = R.length v.ring here;
  unfold view_at;
  let co = B.op_Bang v.coff;
  let cnt = C.batch_count v.conn;
  if (O.le (O.add start len) co && O.eq cnt O.zero) {
    fold (view_at v s);
    true
  } else {
    bytes_fit (R.cap v.ring) rg s0 s (O.v here) start len co cnt;
    let skip = skip_of start co cnt;
    assert (pure (O.v start + O.v skip == bend s));
    let at = R.at v.ring here;
    D.batch_add v.conn (O.add start skip) (O.add at skip) (O.sub len skip) #v.ring #(O.v here) #rg #(O.v skip);
    let e = O.add start len;
    O.arr_set v.nexts cnt following;
    O.arr_set v.ends cnt e;
    let nx1 : erased (Seq.seq O.t) = Seq.upd s.nx (O.v cnt) following;
    let en1 : erased (Seq.seq O.t) = Seq.upd s.en (O.v cnt) e;
    bytes_added (R.cap v.ring) rg s0 s (O.v here) following e nx1 en1;
    let full = C.batch_full v.conn;
    vfold v (batched s (s.cs.C.bcount + 1) nx1 en1);
    if (full) {
      let ok = flush_batch v;
      with s2. assert (view_at v s2);
      flushed_resuming rg s0 (batched s (s.cs.C.bcount + 1) nx1 en1) s2 (O.v following) ok;
      ok
    } else {
      true
    }
  }
}

let cursor_end (s: vs) (cp: O.t) : vs = { s with cp = cp }

let ended (rg: rghost) (s0 s: vs) : prop =
  base_inv rg s /\ s.cs.C.bcount == 0 /\
  (Closed? s.st \/ (Live? s.st /\ streaming rg s)) /\
  same_req s0 s

(* The walk ended: flush, and if everything up to the head went out, the
   cursor is the head. *)
fn resume_end (v: view) (p: O.t) (g0: bool) (upper: O.t) (#g: erased gst) (#rg: erased rghost)
  (#s0 #s: erased vs)
  requires view_at v s ** R.res v.ring g rg
  requires pure (resuming rg s0 s (O.v p) g0 /\ (g0 ==> O.v upper <= O.v p) /\ O.v upper == rg.lr.hd)
  ensures exists* (s': vs). view_at v s' ** R.res v.ring g rg ** pure (ended rg s0 s')
{
  if (g0) {
    let ok = flush_batch v;
    with s1. assert (view_at v s1);
    if (ok) {
      unfold view_at;
      let c = B.op_Bang v.cpos;
      if (O.lt c upper && O.le upper p) {
        R.facts v.ring;
        B.op_Colon_Equals v.cpos p;
        vfold v (cursor_end s1 p)
      } else {
        fold (view_at v s1)
      }
    }
  }
}

(* Send the ring from the cursor to the head: bytes from exactly the stream
   offset on, markers at their offsets. *)
fn resume (v: view) (#g: erased gst) (#rg: erased rghost) (#s: erased vs)
  requires view_at v s ** R.res v.ring g rg
  requires pure (Live? s.st /\ base_inv rg s /\ s.cs.C.bcount == 0 /\ streaming rg s /\ rg.tl <= O.v s.cp)
  ensures exists* (rg': rghost) (s': vs). view_at v s' ** R.res v.ring g rg' **
    pure (R.loaded v.ring rg rg' /\ ended rg' s s')
{
  R.facts v.ring;
  let upper = R.head v.ring;
  with rg1. assert (R.res v.ring g rg1);
  grow_view (R.cap v.ring) rg rg1 ({ s with wa = None });
  grow_cursor (R.cap v.ring) rg rg1 s;
  unfold view_at;
  let cp0 = B.op_Bang v.cpos;
  fold (view_at v s);
  let mut pos = cp0;
  let mut go = true;
  while (!go && O.lt !pos upper)
  invariant exists* (s1: vs) (vp: O.t) (vg: bool).
    view_at v s1 ** pts_to pos vp ** pts_to go vg ** R.res v.ring g rg1 **
    pure (resuming rg1 s s1 (O.v vp) vg /\ (vg ==> s1.cs.C.bcount < O.v C.batch_capacity))
  decreases (if !go then 1 + rg1.lr.hd - O.v !pos else 0)
  {
    with s1 vp vg. assert (view_at v s1 ** pts_to pos vp ** pts_to go vg);
    let h = !pos;
    let following = R.next v.ring h;
    let k = R.kind v.ring h;
    match k {
      R.Bytes -> {
        let more = step_bytes v h following #g #rg1 #s #s1;
        pos := following;
        go := more
      }
      R.Marker -> {
        let ok = step_marker v h following #g #rg1 #s #s1;
        pos := (if ok then following else h);
        go := ok
      }
      _ -> {
        wf_rec (R.cap v.ring) rg1.lr (O.v h);
        pos := following
      }
    }
  };
  with s1 vp vg. assert (view_at v s1 ** pts_to pos vp ** pts_to go vg);
  let p = !pos;
  let g0 = !go;
  resume_end v p g0 upper #g #rg1 #s #s1
}

(* The view's side of its snapshot request's progress. *)
let linked (s: vs) (g: int) (f: st) : prop =
  match f with
  | Absent -> ~(Snapshotting? s.st)
  | Pending g' fl ->
      g' == g /\ (Closed? s.st \/
        (Snapshotting? s.st /\ O.v s.gn == g /\ s.gh.floor <= fl /\ not s.gh.snapped))
  | Sliced g' fl last ->
      g' == g /\ (Closed? s.st \/
        (Snapshotting? s.st /\ O.v s.gn == g /\ s.gh.floor <= fl /\ s.gh.snapped /\ s.gh.last_slice == last))
  | Finished g' hold ->
      g' == g /\ (Closed? s.st \/ (Snapshotting? s.st /\ O.v s.gn == g /\ s.gh.snapped /\ O.v s.cp == hold))

let next_gen (n: O.t{0 <= O.v n /\ O.v n < generations}) : m: O.t{0 <= O.v m /\ O.v m < generations} =
  if O.eq n (O.sub O.c2p30 O.one) then O.zero else O.add n O.one

let snapping_gh (g: vghost) (floor: nat) : vghost = { g with floor = floor; snapped = false }

let snapping (s: vs) (gn: O.t) (h: P.history) (floor: nat) : vs =
  { s with st = Snapshotting; gn = gn; hi = h; gh = snapping_gh s.gh floor }

(* A step keeps a snapshot in flight and a closed view closed; a new
   snapshot is linked to every request floor at or after its own. *)
let moved (s s': vs) : prop =
  (Snapshotting? s'.st /\ ~(Snapshotting? s.st) ==> not s'.gh.snapped /\
     (forall (fl: int). s'.gh.floor <= fl ==> linked s' (O.v s'.gn) (Pending (O.v s'.gn) fl))) /\
  (Snapshotting? s.st ==> Snapshotting? s'.st /\ s'.gh == s.gh /\ s'.gn == s.gn /\ s'.cp == s.cp) /\
  (Closed? s.st ==> Closed? s'.st)

(* Ask the pane for a snapshot: one in flight at a time, under a new generation. *)
fn start_snapshot (v: view) (h: P.history) (#g: erased gst) (#rg: erased rghost) (#s: erased vs)
  requires R.res v.ring g rg ** view_at v s
  requires pure (Live? s.st /\ base_inv rg s /\ s.cs.C.bcount == 0)
  ensures exists* (rg': rghost) (s': vs). R.res v.ring g rg' ** view_at v s' **
    pure (R.loaded v.ring rg rg' /\ base_inv rg' s' /\ s'.cs.C.bcount == 0 /\
          (Snapshotting? s'.st \/ Closed? s'.st) /\
          moved s s' /\ s'.wa == s.wa /\ s'.cp == s.cp /\ s'.bl == s.bl)
{
  R.facts v.ring;
  unfold view_at;
  let gn = B.op_Bang v.gen;
  let gn' = next_gen gn;
  B.op_Colon_Equals v.gen gn';
  let floor : erased nat = rg.lr.hd;
  off_le_hoff (R.cap v.ring) rg.lr rg.lr.hd;
  let ok = D.request v.io h gn' v.ring;
  with rg1. assert (R.res v.ring g rg1);
  R.facts v.ring;
  log_le_boundary (R.cap v.ring) rg.lr rg1.lr rg.lr.hd;
  if (ok) {
    B.op_Colon_Equals v.state Snapshotting;
    B.op_Colon_Equals v.history h;
    GR.op_Colon_Equals v.vg (snapping_gh s.gh floor);
    vfold v (snapping s gn' h floor)
  } else {
    D.reject_io v.conn;
    vfold v ({ s with gn = gn'; cs = C.closed_now s.cs });
    close v #rg1
  }
}

let unwanted (s: vs) : vs = { s with wa = None }

(* A wanted snapshot starts once the connection is not waiting. *)
fn flush_wanted (v: view) (#g: erased gst) (#rg: erased rghost) (#s: erased vs)
  requires R.res v.ring g rg ** view_at v s
  requires pure (view_inv rg s)
  ensures exists* (rg': rghost) (s': vs). R.res v.ring g rg' ** view_at v s' **
    pure (R.loaded v.ring rg rg' /\ view_inv rg' s' /\
          (Live? s'.st /\ Some? s'.wa ==> s'.cs.C.waits) /\
          (None? s.wa ==> s' == s /\ rg' == reveal rg) /\ moved s s')
{
  R.facts v.ring;
  KoRing.Mask.log_le_refl rg.lr;
  unfold view_at;
  let st = B.op_Bang v.state;
  let wa = B.op_Bang v.wanted;
  match st {
    Live -> {
      match wa {
        Some h -> {
          let w = C.waiting v.conn;
          if (w) {
            fold (view_at v s)
          } else {
            B.op_Colon_Equals v.wanted None;
            vfold v (unwanted s);
            start_snapshot v h
          }
        }
        None -> { fold (view_at v s) }
      }
    }
    _ -> { fold (view_at v s) }
  }
}

let wanting (s: vs) (h: P.history) : vs = { s with wa = Some h }

fn request_snapshot (v: view) (h: P.history) (#g: erased gst) (#rg: erased rghost) (#s: erased vs)
  requires R.res v.ring g rg ** view_at v s
  requires pure (pre_inv rg s)
  ensures exists* (rg': rghost) (s': vs). R.res v.ring g rg' ** view_at v s' **
    pure (R.loaded v.ring rg rg' /\ view_inv rg' s' /\ moved s s')
{
  unfold view_at;
  B.op_Colon_Equals v.wanted (Some h);
  vfold v (wanting s h);
  flush_wanted v
}

let cursor_bound (cap: capt) (rg: rghost) (s: vs)
  : Lemma (requires cursor_ok rg s /\ wf cap rg.lr) (ensures O.v s.co <= rg.lr.hoff)
= let p : nat = O.v s.cp in
  if Some? (rg.lr.m p) then (wf_rec cap rg.lr p; off_le_hoff cap rg.lr (next_bnd rg.lr p))
  else off_le_hoff cap rg.lr p

(* A cursor that lost nothing moves to the tail without moving its stream. *)
let reach_cursor (cap: capt) (rg: rghost) (s: vs) (p: O.t)
  : Lemma (requires streaming rg s /\ wf cap rg.lr /\ ~(lost rg.lr rg.tl (O.v s.cp)) /\
                    boundary rg.lr rg.tl /\ rg.tl <= rg.lr.hd /\
                    O.v p == (if O.v s.cp < rg.tl then rg.tl else O.v s.cp))
          (ensures streaming rg ({ s with cp = p }))
= let c : nat = O.v s.cp in
  if c < rg.tl then begin
    let q (x: nat) : Lemma (c <= x /\ x < rg.tl /\ Some? (rg.lr.m x) ==> not (data (Some?.v (rg.lr.m x))))
      = if c <= x && x < rg.tl && Some? (rg.lr.m x) then (assert (~(lost_at rg.lr c x))) in
    Classical.forall_intro q;
    quiet_off cap rg.lr c rg.tl;
    wf_rec cap rg.lr c;
    if Some? (rg.lr.m rg.tl) then wf_rec cap rg.lr rg.tl
  end

(* Pulse keeps the facts of a branch only at a function's end. *)
fn resize_check (h: R.t) (go: bool) (pos offset: O.t) (#g: erased gst) (#rg: erased rghost)
  requires R.res h g rg
  requires pure (R.sane h rg /\ (go ==> rg.tl <= O.v pos /\ O.v pos <= rg.lr.hd /\ boundary rg.lr (O.v pos)))
  returns b: bool
  ensures exists* (rg': rghost). R.res h g rg' ** pure (R.loaded h rg rg' /\ (b ==> go))
{
  if (go) { resize_pending h pos offset } else { KoRing.Mask.log_le_refl rg.lr; false }
}

let reach_opt (cap: capt) (rg: rghost) (s: vs) (a: option O.t)
  : Lemma (requires streaming rg s /\ wf cap rg.lr /\ boundary rg.lr rg.tl /\ rg.tl <= rg.lr.hd /\
                    (Some? a ==> ~(lost rg.lr rg.tl (O.v s.cp)) /\
                                 O.v (Some?.v a) == (if O.v s.cp < rg.tl then rg.tl else O.v s.cp)))
          (ensures streaming rg ({ s with cp = (match a with Some p -> p | None -> s.cp) }))
= match a with Some p -> reach_cursor cap rg s p | None -> ()

let unblocked (s: vs) : vs = { s with bl = false }

(* The progress rule: a live view with nothing wanted that lost nothing to the
   tail takes a snapshot only if its own connection blocked or a resize
   follows a screen-only view. *)
let progress (rg: rghost) (s s': vs) : prop =
  Live? s.st /\ None? s.wa /\ Snapshotting? s'.st /\ O.v s.cp >= 0 /\ ~(lost rg.lr rg.tl (O.v s.cp)) ==>
    s.bl \/ P.History_none? s.hi

let pumped (rg rg': rghost) (s s': vs) : prop =
  R.grows rg rg' /\ view_inv rg' s' /\ progress rg s s' /\ moved s s'

let lost_grows (rg rg': rghost) (p: nat)
  : Lemma (requires R.grows rg rg' /\ rg.tl <= rg.lr.hd) (ensures lost rg.lr rg.tl p <==> lost rg'.lr rg'.tl p)
= let a (q: nat) : Lemma (requires q < rg.tl) (ensures rg'.lr.m q == rg.lr.m q) = () in
  Classical.forall_intro (Classical.move_requires a)

#push-options "--z3rlimit 20"
fn pump_live (v: view) (#g: erased gst) (#rg: erased rghost) (#s: erased vs)
  requires view_at v s ** R.res v.ring g rg
  requires pure (view_inv rg s /\ Live? s.st /\ (Some? s.wa ==> s.cs.C.waits))
  ensures exists* (rg': rghost) (s': vs). view_at v s' ** R.res v.ring g rg' ** pure (pumped rg rg' s s')
{
  R.facts v.ring;
  let upper = R.head v.ring;
  with rg1. assert (R.res v.ring g rg1);
  grow_view (R.cap v.ring) rg rg1 s;
  unfold view_at;
  let cp = B.op_Bang v.cpos;
  if (O.lt cp upper) {
    let avail = C.available v.conn;
    if (avail) {
      lost_grows rg rg1 (O.v cp);
      let reach = R.reachable v.ring cp;
      let behind = None? reach;
      let cp1 = (match reach with Some p -> p | None -> cp);
      reach_opt (R.cap v.ring) rg1 s reach;
      B.op_Colon_Equals v.cpos cp1;
      let s1 : erased vs = { s with cp = cp1 };
      let co = B.op_Bang v.coff;
      let hi = B.op_Bang v.history;
      let bl = B.op_Bang v.blocked;
      vfold v s1;
      let resize = resize_check v.ring (not behind && P.History_none? hi) cp1 co;
      with rg2. assert (R.res v.ring g rg2);
      R.facts v.ring;
      grow_view (R.cap v.ring) rg1 rg2 s1;
      KoRing.Mask.log_le_trans rg.lr rg1.lr rg2.lr;
      let head = R.end_offset v.ring;
      with rg3. assert (R.res v.ring g rg3);
      grow_view (R.cap v.ring) rg2 rg3 s1;
      KoRing.Mask.log_le_trans rg.lr rg2.lr rg3.lr;
      cursor_bound (R.cap v.ring) rg3 s1;
      let d = decide behind co head hi resize bl;
      match d {
        Skip -> {
          let head2 = R.end_offset v.ring;
          with rg4. assert (R.res v.ring g rg4);
          grow_view (R.cap v.ring) rg3 rg4 s1;
          KoRing.Mask.log_le_trans rg.lr rg3.lr rg4.lr;
          cursor_bound (R.cap v.ring) rg4 s1;
          unfold view_at;
          D.json_skipped v.conn head2 co;
          with cs1. assert (C.conn v.conn cs1);
          B.op_Colon_Equals v.blocked false;
          GR.op_Colon_Equals v.vg (at_vpos s1.gh (O.v head2));
          vfold v ({ s1 with bl = false; cs = cs1; gh = at_vpos s1.gh (O.v head2) });
          request_snapshot v P.History_none
        }
        Snapshot h -> {
          unfold view_at;
          B.op_Colon_Equals v.blocked false;
          vfold v (unblocked s1);
          request_snapshot v h
        }
        Resume -> {
          unfold view_at;
          B.op_Colon_Equals v.blocked false;
          vfold v (unblocked s1);
          resume v
        }
      }
    } else {
      fold (view_at v s)
    }
  } else {
    fold (view_at v s)
  }
}

#pop-options

fn pump (v: view) (#g: erased gst) (#rg: erased rghost) (#s: erased vs)
  requires view_at v s ** R.res v.ring g rg
  requires pure (view_inv rg s)
  ensures exists* (rg': rghost) (s': vs). view_at v s' ** R.res v.ring g rg' ** pure (pumped rg rg' s s')
{
  flush_wanted v;
  with s1. assert (view_at v s1);
  unfold view_at;
  let st = B.op_Bang v.state;
  fold (view_at v s1);
  match st {
    Live -> { pump_live v }
    _ -> { KoRing.Mask.log_le_refl rg.lr }
  }
}

let sliced_vs (s: vs) (cs: C.cs) (cp co: O.t) (bl: bool) (pos: nat) : GTot vs =
  { s with cs = cs; cp = cp; co = co; bl = bl;
           gh = { s.gh with snapped = true; last_slice = pos; vpos = O.v co } }

let slice_fits (cap: capt) (rg: rghost) (s: vs) (g: int) (prior now: st) (pos: nat)
  : Lemma (requires view_inv rg s /\ linked s g prior /\ slice_step prior now g pos /\ R.vis rg pos /\
                    Snapshotting? s.st /\ O.v s.gn == g /\ wf cap rg.lr)
          (ensures s.gh.vpos <= (R.rec_of rg pos).off /\ s.gh.floor <= pos)
= if s.gh.snapped then off_mono cap rg.lr s.gh.last_slice pos
  else off_mono cap rg.lr s.gh.floor pos

let slice_taken (cap: capt) (rg: rghost) (s: vs) (g: int) (prior now: st) (pos: nat) (cs: C.cs)
  (following off: O.t) (bl: bool)
  : Lemma (requires view_inv rg s /\ linked s g prior /\ slice_step prior now g pos /\ R.vis rg pos /\
                    R.Slice? (R.kind_of rg pos) /\ Snapshotting? s.st /\ O.v s.gn == g /\ wf cap rg.lr /\
                    O.v following == R.next_of rg pos /\ O.v off == (R.rec_of rg pos).off /\
                    D.kept s.cs cs /\ s.gh.floor <= pos)
          (ensures view_inv rg (sliced_vs s cs following off bl pos) /\ linked (sliced_vs s cs following off bl pos) g now)
= wf_rec cap rg.lr pos;
  let f : nat = O.v following in
  if Some? (rg.lr.m f) then wf_rec cap rg.lr f;
  off_le_hoff cap rg.lr pos

fn on_slice_live (v: view) (gn pos: O.t) (#g: erased gst)
  (#rg: erased rghost{R.vis rg (O.v pos) /\ R.kind_of rg (O.v pos) == R.Slice})
  (#s: erased vs) (#prior #now: erased st)
  requires view_at v s ** R.res v.ring g rg
  requires pure (view_inv rg s /\ linked s (O.v gn) prior /\ slice_step prior now (O.v gn) (O.v pos) /\
                 Snapshotting? s.st /\ s.gn == gn)
  ensures exists* (s': vs). view_at v s' ** R.res v.ring g rg ** pure (view_inv rg s' /\ linked s' (O.v gn) now)
{
  R.facts v.ring;
  slice_fits (R.cap v.ring) rg s (O.v gn) prior now (O.v pos);
  let off = R.offset v.ring pos;
  let following = R.next v.ring pos;
  let len = R.length v.ring pos;
  let at = R.at v.ring pos;
  unfold view_at;
  let w = D.record v.conn (R.buffer_of v.ring) off at len #v.ring #(O.v pos) #rg;
  with cs1. assert (C.conn v.conn cs1);
  if (C.Closed? w) {
    vfold v ({ s with cs = cs1 });
    close v #rg
  } else {
    let bl0 = B.op_Bang v.blocked;
    let bl = (if C.Accepted? w then bl0 else true);
    B.op_Colon_Equals v.cpos following;
    B.op_Colon_Equals v.coff off;
    B.op_Colon_Equals v.blocked bl;
    GR.op_Colon_Equals v.vg { s.gh with snapped = true; last_slice = O.v pos; vpos = O.v off };
    slice_taken (R.cap v.ring) rg s (O.v gn) prior now (O.v pos) cs1 following off bl;
    vfold v (sliced_vs s cs1 following off bl (O.v pos))
  }
}

(* A slice of this view's snapshot: it continues the stream, which moves to it. *)
fn on_slice (v: view) (gn pos: O.t) (#g: erased gst) (#rg: erased rghost{R.vis rg (O.v pos) /\ R.kind_of rg (O.v pos) == R.Slice})
  (#s: erased vs) (#prior #now: erased st)
  requires view_at v s ** R.res v.ring g rg
  requires pure (view_inv rg s /\ linked s (O.v gn) prior /\ slice_step prior now (O.v gn) (O.v pos))
  ensures exists* (s': vs). view_at v s' ** R.res v.ring g rg ** pure (view_inv rg s' /\ linked s' (O.v gn) now)
{
  unfold view_at;
  let st = B.op_Bang v.state;
  let cur = B.op_Bang v.gen;
  fold (view_at v s);
  if (Snapshotting? st && O.eq gn cur) {
    on_slice_live v gn pos #g #rg #s #prior #now
  }
}

(* The view may resume: closed, or live with its cursor not behind the tail. *)
let resumable (rg: rghost) (s: vs) : prop = Closed? s.st \/ (Live? s.st /\ rg.tl <= O.v s.cp)

(* snapshot_done for this view's snapshot. *)
fn on_done (v: view) (gn: O.t) (ok: bool) (#g: erased gst) (#rg: erased rghost) (#s: erased vs) (#prior: erased st)
  preserves R.res v.ring g rg
  requires view_at v s
  requires pure (view_inv rg s /\ linked s (O.v gn) prior /\ ~(Absent? prior) /\
                 (ok ==> done_step prior (O.v gn) rg))
  ensures exists* (s': vs). view_at v s' **
    pure (view_inv rg s' /\ linked s' (O.v gn) Absent /\ (ok ==> resumable rg s') /\
          s'.bl == s.bl /\ s'.hi == s.hi /\ s'.wa == s.wa)
{
  unfold view_at;
  let st = B.op_Bang v.state;
  let cur = B.op_Bang v.gen;
  if (Snapshotting? st && O.eq gn cur) {
    if (ok) {
      B.op_Colon_Equals v.state Live;
      vfold v ({ s with st = Live })
    } else {
      D.reject_io v.conn;
      vfold v ({ s with cs = C.closed_now s.cs });
      close v #rg
    }
  } else {
    fold (view_at v s)
  }
}

(* A position [resume] found for [value] is a valid cursor at that offset. *)
let resume_cursor (cap: capt) (rg: rghost) (value: nat) (p: nat)
  : Lemma (requires KoRing.Walk.resumes rg value p /\ wf cap rg.lr /\ off_at rg.lr rg.tl <= value /\
                    value <= rg.lr.hoff)
          (ensures off_at rg.lr p <= value /\ value <= off_at rg.lr (next_bnd rg.lr p))
= if p < rg.lr.hd then wf_rec cap rg.lr p
  else if Some? (rg.lr.m p) then wf_rec cap rg.lr p

let fresh_gh : vghost = { vpos = 0; floor = 0; snapped = false; last_slice = 0 }

let opened (s: vs) (cp co: O.t) : GTot vs = { s with cp = cp; co = co; wa = None; gh = at_vpos s.gh (O.v co) }

let fresh (h: P.history) (cs: C.cs) : GTot vs =
  Mkvs Live O.zero O.zero false h (Some h) O.zero (Seq.create (O.v C.batch_capacity) O.zero)
    (Seq.create (O.v C.batch_capacity) O.zero) fresh_gh cs

fn make_view (r: R.t) (c: C.t) (io: D.view_io) (h: P.history) (#cs: erased C.cs)
  requires C.conn c cs
  returns v: view
  ensures view_at v (fresh h cs) ** pure (v.ring == r /\ v.conn == c)
{
  let z : O.t = O.zero;
  let st = B.alloc Live;
  let cp = B.alloc z;
  let co = B.alloc z;
  let bl = B.alloc false;
  let hi = B.alloc h;
  let wa = B.alloc (Some h);
  let gn = B.alloc z;
  let nexts = O.arr_make C.batch_capacity z;
  let ends = O.arr_make C.batch_capacity z;
  let vg = GR.alloc fresh_gh;
  let v = { ring = r; conn = c; io; state = st; cpos = cp; coff = co; blocked = bl; history = hi;
            wanted = wa; gen = gn; nexts; ends; vg };
  rewrite each st as v.state, cp as v.cpos, co as v.coff, bl as v.blocked, hi as v.history, wa as v.wanted, gn as v.gen, nexts as v.nexts, ends as v.ends, vg as v.vg, c as v.conn;
  vfold v (fresh h cs);
  v
}

(* Start the stream at [requested] if the ring still has it, else at a snapshot. *)
fn open_view (v: view) (requested: option O.t) (#h: erased P.history)
  (#g: erased gst) (#rg: erased rghost) (#cs: erased C.cs)
  requires R.res v.ring g rg ** view_at v (fresh h cs)
  requires pure (not cs.C.closed /\ cs.C.bcount == 0 /\ not cs.C.waits)
  ensures exists* (rg': rghost) (s: vs). view_at v s ** R.res v.ring g rg' **
    pure (R.grows rg rg' /\ view_inv rg' s)
{
  R.facts v.ring;
  let e = R.end_offset v.ring;
  with rg1. assert (R.res v.ring g rg1);
  unfold view_at;
  B.op_Colon_Equals v.coff e;
  let s0 : erased vs = { fresh h cs with co = e };
  vfold v s0;
  match requested {
    Some value -> {
      let oldest = R.oldest_offset v.ring;
      with rg2. assert (R.res v.ring g rg2);
      if (O.le oldest value && O.le value e) {
        let p = R.resume v.ring value;
        with rg3. assert (R.res v.ring g rg3);
        KoRing.Mask.log_le_trans rg.lr rg1.lr rg2.lr;
        KoRing.Mask.log_le_trans rg.lr rg2.lr rg3.lr;
        log_le_boundary (R.cap v.ring) rg2.lr rg3.lr rg.tl;
        resume_cursor (R.cap v.ring) rg3 (O.v value) (O.v p);
        unfold view_at;
        B.op_Colon_Equals v.cpos p;
        B.op_Colon_Equals v.coff value;
        B.op_Colon_Equals v.wanted None;
        GR.op_Colon_Equals v.vg (at_vpos fresh_gh (O.v value));
        vfold v (opened s0 p value);
        pump v
      } else {
        KoRing.Mask.log_le_trans rg.lr rg1.lr rg2.lr;
        flush_wanted v
      }
    }
    None -> {
      flush_wanted v
    }
  }
}

let conn (v: view) : C.t = v.conn
