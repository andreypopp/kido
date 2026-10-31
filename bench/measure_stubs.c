#define _DARWIN_C_SOURCE
#define _GNU_SOURCE
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/alloc.h>
#include <caml/fail.h>
#include "../ko_pane/now.h"
#include "cpu.h"

CAMLprim value ko_spike_cpu_seconds(value pid) {
  CAMLparam1(pid); CAMLlocal1(pair);
  pair = caml_alloc_tuple(2);
  Store_field(pair, 0, caml_copy_double(ko_cpu_raw_ns_seconds(Int_val(pid))));
  Store_field(pair, 1, caml_copy_double(ko_cpu_seconds(Int_val(pid))));
  CAMLreturn(pair);
}

