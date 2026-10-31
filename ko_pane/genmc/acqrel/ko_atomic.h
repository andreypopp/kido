#ifndef KO_ATOMIC_H
#define KO_ATOMIC_H
#include <stdatomic.h>
#include <stdint.h>
static inline uint64_t ko_atomic_load(uint64_t *p) {
  return atomic_load_explicit((_Atomic uint64_t *)p, memory_order_acquire);
}
static inline void ko_atomic_store(uint64_t *p, uint64_t v) {
  atomic_store_explicit((_Atomic uint64_t *)p, v, memory_order_release);
}
#endif
