#ifndef KO_BUFFER_H
#define KO_BUFFER_H
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

struct ko_buffer { uint8_t *p; size_t n, pos, cap; };

static inline int ko_reserve(struct ko_buffer *b, size_t extra) {
  if (extra > SIZE_MAX - b->n) return -1;
  if (b->n + extra <= b->cap) return 0;
  size_t cap = b->n + extra;
  if (cap < SIZE_MAX / 2) cap *= 2;
  void *q = realloc(b->p, cap);
  if (!q) return -1;
  b->p = q;
  b->cap = cap;
  return 0;
}

static inline int ko_append(struct ko_buffer *b, const void *p, size_t n) {
  if (!n) return 0;
  if (ko_reserve(b, n)) return -1;
  memcpy(b->p + b->n, p, n);
  b->n += n;
  return 0;
}
#endif
