#define _DARWIN_C_SOURCE
#define _GNU_SOURCE
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/alloc.h>
#include <caml/fail.h>
#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#endif
#include "../ko_pane/now.h"
#include "cpu.h"
CAMLprim value ko_spike_pty(value unit) {
  CAMLparam1(unit); CAMLlocal1(pair);
  int master, slave;
  if (openpty(&master, &slave, NULL, NULL, NULL)) caml_failwith("openpty");
  pair = caml_alloc_tuple(2);
  Store_field(pair, 0, Val_int(master));
  Store_field(pair, 1, Val_int(slave));
  CAMLreturn(pair);
}

CAMLprim value ko_spike_now_ns(value unit) { (void)unit; return Val_long(ko_now_ns()); }

CAMLprim value ko_spike_cpu_seconds(value pid) {
  CAMLparam1(pid); CAMLlocal1(pair);
  pair = caml_alloc_tuple(2);
  Store_field(pair, 0, caml_copy_double(ko_cpu_raw_ns_seconds(Int_val(pid))));
  Store_field(pair, 1, caml_copy_double(ko_cpu_seconds(Int_val(pid))));
  CAMLreturn(pair);
}

