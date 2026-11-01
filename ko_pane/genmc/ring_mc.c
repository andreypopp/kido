#define _DARWIN_C_SOURCE
#define _GNU_SOURCE
/* The extracted writer and reader as two threads over one 64-byte ring.
   The writer fills each Bytes payload with the stream offsets of its bytes;
   the reader checks every byte once from its cursor, as a view does,
   then advances the tail. */
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include "ko_ring_proved.h"

#define CAP 64
#define RECORDS 5
#define LEN 9
static struct {
  _Atomic uint64_t head, tail, read;
} idx;
static uint8_t data[CAP];
static KoRing_Inv_ring ring = {CAP, (uint64_t *)&idx.head, (uint64_t *)&idx.tail,
                               (uint64_t *)&idx.read, data};

static void *writer(void *arg) {
  (void)arg;
  KoRing_Inv_wstate w = {0, 0, 0};
  int written = 0;
  for (int attempt = 0; attempt < 8 && written < RECORDS; attempt++) {
    KoRing_Writer_avail a = KoRing_Writer_available(ring, &w);
    if (a.room < LEN) {
      continue;
    }
    for (int i = 0; i < LEN; i++) {
      data[(w.whead + 13 + i) % CAP] = (uint8_t)(w.woff + i);
    }
    assert(KoRing_Writer_put_record(ring, &w, 1, LEN) != KoRing_Writer_Refused);
    written++;
  }
  return NULL;
}

static void *reader(void *arg) {
  (void)arg;
  KoRing_Inv_rstate r = {0};
  uint64_t expect = 0, pos = 0;
  for (int scan = 0; scan < 4; scan++) {
    uint64_t upper = KoRing_Reader_observe(ring, &r).seen;
    while (pos < upper) {
      KoRing_Reader_hdr_view h = KoRing_Reader_header(ring, &r, pos);
      assert(h.ok);
      if (h.htag == 1) {
        assert(h.hoff == expect);
        for (uint64_t i = 0; i < h.hlen; i++) {
          assert(data[(pos + 13 + i) % CAP] == (uint8_t)(h.hoff + i));
        }
        expect += h.hlen;
      }
      pos += 13 + h.hlen;
    }
    assert(KoRing_Walk_advance(ring, &r, upper, upper));
  }
  return NULL;
}

int main(void) {
  pthread_t a, b;
  pthread_create(&a, NULL, writer, NULL);
  pthread_create(&b, NULL, reader, NULL);
  pthread_join(a, NULL);
  pthread_join(b, NULL);
  return 0;
}
