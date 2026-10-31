module KoAtomic
#lang-pulse
open Pulse.Lib.Pervasives
open PulseCore.Observability
module U64 = FStar.UInt64

[@@custard_extern "ko_atomic_load"; custard_c_header "ko_atomic.h"]
val load (r: ref U64.t) (#n: erased U64.t) (#p: perm)
  : stt_atomic U64.t #Observable emp_inames
      (pts_to r #p n)
      (fun x -> pts_to r #p n ** pure (x == reveal n))

[@@custard_extern "ko_atomic_store"; custard_c_header "ko_atomic.h"]
val store (r: ref U64.t) (x: U64.t) (#n: erased U64.t)
  : stt_atomic unit #Observable emp_inames
      (pts_to r n)
      (fun _ -> pts_to r x)
