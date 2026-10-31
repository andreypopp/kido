#ifndef KO_RING_H
#define KO_RING_H
#include "../ko_proofs/ko_ring_proved.h"
#include "protocol.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/mman.h>
#include <unistd.h>
static inline int ko_ring_create(size_t capacity, struct ko_ring **out) {
  char name[64];
  snprintf(name, sizeof(name), "/ko-ring-%d", getpid());
  int fd = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
  if (fd < 0) {
    return -1;
  }
  int error = 0;
  if (shm_unlink(name) || ftruncate(fd, sizeof(struct ko_ring) + capacity)) {
    error = errno;
  } else {
    struct ko_ring *ring = mmap(NULL, sizeof(struct ko_ring) + capacity,
                                PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (ring == MAP_FAILED) {
      error = errno;
    } else {
      ring->capacity = capacity;
      atomic_init(&ring->head, 0);
      atomic_init(&ring->tail, 0);
      atomic_init(&ring->read, 0);
      *out = ring;
      return fd;
    }
  }
  close(fd);
  errno = error;
  return -1;
}
_Static_assert(offsetof(struct ko_ring, data) == 32 && KO_HEADER == 13 && KO_BYTES == 1 &&
                   KO_MARKER == 2 && KO_SNAPSHOT_SLICE == 3 && KO_PAD == 4,
               "ko_proofs/ assumes this ring layout");
static inline int ko_ring_attach(struct ko_ring *ring, size_t size, KoRing_Inv_ring *out) {
  if (size < sizeof(struct ko_ring)) {
    return -1;
  }
  uint64_t capacity = ring->capacity;
  if (capacity < KoRing_Inv_min_capacity || capacity > KoRing_Inv_max_capacity ||
      capacity > size - sizeof(struct ko_ring)) {
    return -1;
  }
  *out = (KoRing_Inv_ring){capacity, (uint64_t *)&ring->head, (uint64_t *)&ring->tail,
                           (uint64_t *)&ring->read, ring->data};
  return 0;
}
#endif
