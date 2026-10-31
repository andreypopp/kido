module KoRing.Spec
module U8 = FStar.UInt8

let hdr : nat = 13
let min_cap : nat = 64
let max_cap : nat = 0x40000000
let max_pos : nat = 0x3fffffffffffffff

type capt = c:pos{min_cap <= c /\ c <= max_cap}

type kind = | Bytes | Marker | Slice | Pad

let tag (k: kind) : n:nat{1 <= n /\ n <= 4} =
  match k with Bytes -> 1 | Marker -> 2 | Slice -> 3 | Pad -> 4

let kind_of (t: nat{1 <= t /\ t <= 4}) : k: kind{tag k == t} =
  if t = 1 then Bytes else if t = 2 then Marker else if t = 3 then Slice else Pad

noeq type record = { kind: kind; len: nat; off: nat }

let inc (r: record) : pos = hdr + r.len
let off_after (r: record) : nat = if Bytes? r.kind then r.off + r.len else r.off

(* The ghost log of published records: [m] maps the start of each record to
   it, [hd] is the head and [hoff] the stream offset at the head. *)
noeq type log = { m: nat -> option record; hd: nat; hoff: nat }

let boundary (l: log) (p: nat) : prop = Some? (l.m p) \/ p == l.hd

(* The stream offset at a boundary. *)
let off_at (l: log) (p: nat) : nat =
  if p = l.hd then l.hoff else match l.m p with Some r -> r.off | None -> 0

(* The five facts the WhyML reader had to assume about the writer, for the
   record [r] at [p]: it does not wrap; its tag is valid (by its type); the
   next boundary follows it with nothing between; 0 <= off <= p; the next
   record's offset is [off_after r]. *)
let rec_ok (cap: capt) (l: log) (p: nat) (r: record) : prop =
  p + inc r <= l.hd /\
  p % cap + inc r <= cap /\
  r.off <= p /\ r.off <= l.hoff /\
  boundary l (p + inc r) /\
  off_at l (p + inc r) == off_after r /\
  (forall (q: nat). {:pattern (l.m q)} p < q /\ q < p + inc r ==> None? (l.m q))

[@@"opaque_to_smt"]
let wf (cap: capt) (l: log) : prop =
  (forall (p: nat). {:pattern (l.m p)} Some? (l.m p) ==> rec_ok cap l p (Some?.v (l.m p))) /\
  l.hd % cap + hdr <= cap /\
  l.hd <= max_pos /\
  l.hoff <= l.hd

let log_le (a b: log) : prop =
  a.hd <= b.hd /\ a.hoff <= b.hoff /\ boundary b a.hd /\ off_at b a.hd == a.hoff /\
  (forall (p: nat). {:pattern (b.m p)} p < a.hd ==> b.m p == a.m p)

let empty_log : log = { m = (fun _ -> None); hd = 0; hoff = 0 }

let extend (l: log) (r: record) : log =
  { m = (fun p -> if p = l.hd then Some r else l.m p);
    hd = l.hd + inc r;
    hoff = l.hoff + (if Bytes? r.kind then r.len else 0) }

let empty_wf (cap: capt) : Lemma (wf cap empty_log) = reveal_opaque (`%wf) (wf cap empty_log)

let extend_wf (cap: capt) (l: log) (r: record)
  : Lemma
    (requires wf cap l /\ r.off == l.hoff /\
              l.hd % cap + inc r <= cap /\ (l.hd + inc r) % cap + hdr <= cap /\
              l.hd + inc r <= max_pos)
    (ensures wf cap (extend l r) /\ log_le l (extend l r))
= reveal_opaque (`%wf) (wf cap l); reveal_opaque (`%wf) (wf cap (extend l r))

let wf_rec (cap: capt) (l: log) (p: nat)
  : Lemma (requires wf cap l /\ Some? (l.m p)) (ensures rec_ok cap l p (Some?.v (l.m p)))
= reveal_opaque (`%wf) (wf cap l)

let wf_head (cap: capt) (l: log)
  : Lemma (requires wf cap l)
          (ensures l.hd % cap + hdr <= cap /\ l.hd <= max_pos /\ l.hoff <= l.hd /\ None? (l.m l.hd))
= reveal_opaque (`%wf) (wf cap l)

(* What a newer log keeps from an older one below the older head. *)
let log_le_boundary (cap: capt) (a b: log) (p: nat)
  : Lemma (requires wf cap a /\ wf cap b /\ log_le a b /\ boundary a p)
          (ensures boundary b p /\ off_at b p == off_at a p)
= reveal_opaque (`%wf) (wf cap a); reveal_opaque (`%wf) (wf cap b)

(* Digit [k] of [n] in base 256: little-endian byte [k]. *)
let rec digit (n: nat) (k: nat) : Tot (d: nat{d < 256}) (decreases k) =
  if k = 0 then n % 256 else digit (n / 256) (k - 1)

let enc (r: record) (j: nat) : U8.t =
  if j = 0 then U8.uint_to_t (tag r.kind)
  else if j <= 4 then U8.uint_to_t (digit r.len (j - 1))
  else if j <= 12 then U8.uint_to_t (digit r.off (j - 5))
  else 0uy

let rec dec (n: nat) (m: nat) : Tot nat (decreases m) =
  if m = 0 then 0 else n % 256 + 256 * dec (n / 256) (m - 1)

let rec dec_mod (n: nat) (m: nat)
  : Lemma (ensures dec n m == n % pow2 (8 * m)) (decreases m)
= if m = 0 then () else begin
    dec_mod (n / 256) (m - 1);
    let c = pow2 (8 * (m - 1)) in
    FStar.Math.Lemmas.pow2_plus 8 (8 * (m - 1));
    FStar.Math.Lemmas.modulo_modulo_lemma n 256 c;
    FStar.Math.Lemmas.modulo_division_lemma n 256 c;
    FStar.Math.Lemmas.lemma_div_mod (n % (256 * c)) 256
  end

(* Little-endian decoding, as the reader computes it. *)
let le4 (b0 b1 b2 b3: U8.t) : nat =
  U8.v b0 + 256 * (U8.v b1 + 256 * (U8.v b2 + 256 * U8.v b3))

let le8 (b0 b1 b2 b3 b4 b5 b6 b7: U8.t) : nat =
  U8.v b0 + 256 * (U8.v b1 + 256 * (U8.v b2 + 256 * (U8.v b3 + 256 *
  (U8.v b4 + 256 * (U8.v b5 + 256 * (U8.v b6 + 256 * U8.v b7))))))

#push-options "--fuel 9 --ifuel 0"
let le4_enc (r: record)
  : Lemma (requires r.len < pow2 32)
          (ensures le4 (enc r 1) (enc r 2) (enc r 3) (enc r 4) == r.len)
= dec_mod r.len 4; FStar.Math.Lemmas.small_mod r.len (pow2 32)

let le8_enc (r: record)
  : Lemma (requires r.off < pow2 64)
          (ensures le8 (enc r 5) (enc r 6) (enc r 7) (enc r 8) (enc r 9) (enc r 10) (enc r 11) (enc r 12) == r.off)
= dec_mod r.off 8; FStar.Math.Lemmas.small_mod r.off (pow2 64)
#pop-options

let off_le_hoff (cap: capt) (l: log) (p: nat)
  : Lemma (requires wf cap l /\ boundary l p) (ensures off_at l p <= l.hoff)
= if Some? (l.m p) && p <> l.hd then wf_rec cap l p

(* Offsets grow between any two boundaries: walk the records from [p] to [q]. *)
let rec off_mono (cap: capt) (l: log) (p q: nat)
  : Lemma (requires wf cap l /\ boundary l p /\ boundary l q /\ p <= q)
          (ensures off_at l p <= off_at l q)
          (decreases (q - p))
= if p = q then ()
  else begin
    if Some? (l.m q) then wf_rec cap l q;
    wf_rec cap l p;
    let r = Some?.v (l.m p) in
    if q < p + inc r then begin
      assert (None? (l.m q));
      assert (q == l.hd)
    end
    else off_mono cap l (p + inc r) q
  end

(* A record the view sends: bytes or a marker. Slices and pads are not. *)
let data (r: record) : bool = Bytes? r.kind || Marker? r.kind

(* No record in [lo, hi) is data, so the stream offset is the same at both ends. *)
let quiet (l: log) (lo hi: nat) : prop =
  forall (q: nat). {:pattern (l.m q)} lo <= q /\ q < hi /\ Some? (l.m q) ==> not (data (Some?.v (l.m q)))

(* A data record before the tail [tl] ends after [p]: a view at [p] lost it. *)
let lost (l: log) (tl p: nat) : prop =
  exists (q: nat). q < tl /\ Some? (l.m q) /\ data (Some?.v (l.m q)) /\ q + inc (Some?.v (l.m q)) > p

(* [ev] is where the last released data record ends, 0 if none. *)
let evicted_ok (l: log) (ev tl: nat) : prop =
  ev <= tl /\ quiet l ev tl /\
  (ev > 0 ==> (exists (q: nat). q < ev /\ Some? (l.m q) /\ data (Some?.v (l.m q)) /\
                              q + inc (Some?.v (l.m q)) == ev))

let lost_at (l: log) (p q: nat) : prop =
  Some? (l.m q) /\ data (Some?.v (l.m q)) /\ q + inc (Some?.v (l.m q)) > p

let reachable_iff (cap: capt) (l: log) (ev tl p: nat)
  : Lemma (requires wf cap l /\ evicted_ok l ev tl /\ tl <= l.hd)
          (ensures lost l tl p <==> p < ev)
= let not_lost (q: nat)
    : Lemma (requires p >= ev /\ q < tl) (ensures ~(lost_at l p q))
    = if Some? (l.m q) then begin
        wf_rec cap l q;
        if ev > 0 then
          eliminate exists (q0: nat). q0 < ev /\ Some? (l.m q0) /\ data (Some?.v (l.m q0)) /\
                                      q0 + inc (Some?.v (l.m q0)) == ev
          with (wf_rec cap l q0)
      end
  in
  Classical.forall_intro (Classical.move_requires not_lost)

let evicted_grows (l l': log) (ev tl: nat)
  : Lemma (requires evicted_ok l ev tl /\ log_le l l' /\ tl <= l.hd) (ensures evicted_ok l' ev tl)
= ()

(* The walk from [p] over a record [r]: data moves the eviction point past it. *)
let evicted_step (cap: capt) (l: log) (ev p: nat)
  : Lemma (requires wf cap l /\ evicted_ok l ev p /\ Some? (l.m p))
          (ensures evicted_ok l (if data (Some?.v (l.m p)) then p + inc (Some?.v (l.m p)) else ev)
                                (p + inc (Some?.v (l.m p))))
= wf_rec cap l p

(* Across a quiet stretch the stream offset does not change. *)
let rec quiet_off (cap: capt) (l: log) (p q: nat)
  : Lemma (requires wf cap l /\ boundary l p /\ boundary l q /\ p <= q /\ quiet l p q)
          (ensures off_at l p == off_at l q) (decreases (q - p))
= if p < q then begin
    if Some? (l.m q) then wf_rec cap l q;
    wf_rec cap l p;
    let r = Some?.v (l.m p) in
    if q < p + inc r then assert (q == l.hd) else quiet_off cap l (p + inc r) q
  end
