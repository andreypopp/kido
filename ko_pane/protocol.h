#ifndef KO_PROTOCOL_H
#define KO_PROTOCOL_H
#include <stdint.h>
#include <stddef.h>
#include <stdatomic.h>
#define KO_HEADER 13
#define KO_MAX_FRAME (16u*1024u*1024u)
enum ko_frame {
  KO_INIT = 1, KO_TAIL = 2, KO_RESIZE = 3, KO_TEXT = 4, KO_SNAPSHOT = 5, KO_EXIT = 6,
  KO_READY = 7, KO_HEAD = 8, KO_TITLE = 9, KO_PWD = 10, KO_PROMPT = 11, KO_RECORD = 12,
  KO_DEAD = 13, KO_SNAPSHOT_DONE = 14, KO_ERROR = 15, KO_FULL = 16,
  KO_KEY = 17, KO_PASTE = 18, KO_PASTE_DONE = 19, KO_MOUSE = 20,
  KO_FOCUS = 21, KO_SCREEN = 22
};
enum ko_record { KO_BYTES = 1, KO_MARKER = 2, KO_SNAPSHOT_SLICE = 3, KO_PAD = 4 };
struct ko_ring { uint64_t capacity; _Atomic uint64_t head, tail, read; uint8_t data[]; };
static inline uint64_t ko_get(const uint8_t *p,unsigned n) {
  uint64_t v=0; for(unsigned i=0;i<n;i++) v|=(uint64_t)p[i]<<(8*i); return v;
}
static inline void ko_put(uint8_t *p,uint64_t v,unsigned n) {
  for(unsigned i=0;i<n;i++) p[i]=(uint8_t)(v>>(8*i));
}
static inline int ko_frame_size(const uint8_t *p,size_t len,size_t *size) {
  if(len<4) return 0;
  uint64_t n=ko_get(p,4);
  if(n<1 || n>KO_MAX_FRAME) return -1;
  *size=(size_t)n+4; return len>=*size;
}
#endif
