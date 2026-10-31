#ifndef KO_ATOMIC_H
#define KO_ATOMIC_H
#include <stdatomic.h>
#include <stdint.h>
/* The proof treats each index access as one indivisible step in a single
   interleaving: C11 sequentially consistent atomics. The pointers point at
   the _Atomic fields of struct ko_ring. */
static inline uint64_t ko_atomic_load(uint64_t *p) {
  return atomic_load((_Atomic uint64_t *)p);
}
static inline void ko_atomic_store(uint64_t *p, uint64_t v) {
  atomic_store((_Atomic uint64_t *)p, v);
}
#endif
