#ifndef KO_RING_H
#define KO_RING_H
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
#endif
