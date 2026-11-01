#define _DARWIN_C_SOURCE
#define _GNU_SOURCE
/* The idle handshake: the writer stores head then loads read; the reader
   stores read (in advance) then loads head. One of them must see the other. */
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include "ko_ring_proved.h"

#define CAP 64
static struct {
  _Atomic uint64_t head, tail, read;
} idx;
static uint8_t data[CAP];
static KoRing_Inv_ring ring = {CAP, (uint64_t *)&idx.head, (uint64_t *)&idx.tail,
                               (uint64_t *)&idx.read, data};
static KoRing_Inv_wstate w;
static KoRing_Inv_rstate r;
static KoRing_Writer_commit commit;
static uint64_t first, seen_after;

static void *writer(void *arg) {
  (void)arg;
  KoRing_Writer_available(ring, &w);
  commit = KoRing_Writer_put_record(ring, &w, 1, 3);
  return NULL;
}

static void *reader(void *arg) {
  (void)arg;
  assert(KoRing_Walk_advance(ring, &r, first, first));
  seen_after = KoRing_Reader_observe(ring, &r).seen;
  return NULL;
}

int main(void) {
  KoRing_Writer_available(ring, &w);
  KoRing_Writer_put_record(ring, &w, 1, 3);
  first = KoRing_Reader_observe(ring, &r).seen;
  pthread_t a, b;
  pthread_create(&a, NULL, writer, NULL);
  pthread_create(&b, NULL, reader, NULL);
  pthread_join(a, NULL);
  pthread_join(b, NULL);
  assert(!(commit == KoRing_Writer_Published && seen_after == first));
  return 0;
}
