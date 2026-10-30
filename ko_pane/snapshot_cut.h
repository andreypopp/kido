#ifndef KO_SNAPSHOT_CUT_H
#define KO_SNAPSHOT_CUT_H
#include <ghostty/vt.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>

#define KO_SNAPSHOT_HEADER 10
/* Tag.ready and Tag.kitty_image_payload in src/terminal/snapshot/record.zig;
   the C API does not export the record tags. */
#define KO_SNAPSHOT_READY 5
#define KO_SNAPSHOT_KITTY_PAYLOAD 9

struct ko_cut {
  uint8_t header[KO_SNAPSHOT_HEADER];
  size_t have, left;
  unsigned tag;
  int envelope, screen, images, done;
};
typedef int (*ko_cut_emit)(void *userdata, const uint8_t *bytes, size_t len);

static inline int ko_cut_keep(const struct ko_cut *c) {
  return c->images || c->tag != KO_SNAPSHOT_KITTY_PAYLOAD;
}

static inline int ko_cut_feed(struct ko_cut *c, const uint8_t *b, size_t n,
                              ko_cut_emit emit, void *userdata) {
  while (n && !c->done) {
    if (!c->left) {
      size_t take = KO_SNAPSHOT_HEADER - c->have;
      if (take > n) take = n;
      memcpy(c->header + c->have, b, take);
      c->have += take; b += take; n -= take;
      if (c->have < KO_SNAPSHOT_HEADER) continue;
      c->have = 0;
      if (!c->envelope) { c->envelope = 1; c->tag = 0; c->left = 0; }
      else {
        c->tag = (unsigned)c->header[0] | (unsigned)c->header[1] << 8;
        c->left = (size_t)c->header[2] | (size_t)c->header[3] << 8 |
                  (size_t)c->header[4] << 16 | (size_t)c->header[5] << 24;
      }
      if (ko_cut_keep(c) && emit(userdata, c->header, KO_SNAPSHOT_HEADER)) return -1;
      if (c->screen && c->tag == KO_SNAPSHOT_READY) { c->done = 1; return 0; }
    }
    size_t take = c->left < n ? c->left : n;
    if (take && ko_cut_keep(c) && emit(userdata, b, take)) return -1;
    b += take; n -= take; c->left -= take;
  }
  return 0;
}

struct ko_encoding { struct ko_cut *cut; ko_cut_emit emit; void *userdata; int failed; };

static inline bool ko_encoding_write(void *userdata, const uint8_t *b, size_t n) {
  struct ko_encoding *e = userdata;
  if (ko_cut_feed(e->cut, b, n, e->emit, e->userdata)) { e->failed = 1; return false; }
  return !e->cut->done;
}

static inline GhosttyResult ko_snapshot_encode(GhosttyTerminal vt, struct ko_cut *cut,
                                               ko_cut_emit emit, void *userdata) {
  GhosttyTerminalModeConfig mode = {.mode = GHOSTTY_MODE_SYNC_OUTPUT};
  GhosttyResult r = ghostty_terminal_get(vt, GHOSTTY_TERMINAL_DATA_MODE, &mode);
  if (r != GHOSTTY_SUCCESS) return r;
  bool saved = mode.value;
  mode.value = false;
  if (saved && (r = ghostty_terminal_set(vt, GHOSTTY_TERMINAL_OPT_MODE, &mode)) != GHOSTTY_SUCCESS)
    return r;
  struct ko_encoding e = {cut, emit, userdata, 0};
  r = ghostty_snapshot_encode(vt, (GhosttyWriter){ko_encoding_write, &e});
  if (e.failed) r = GHOSTTY_IO_ERROR;
  else if (cut->done) r = GHOSTTY_SUCCESS;
  if (saved) {
    mode.value = true;
    GhosttyResult restored = ghostty_terminal_set(vt, GHOSTTY_TERMINAL_OPT_MODE, &mode);
    if (r == GHOSTTY_SUCCESS) r = restored;
  }
  return r;
}
#endif
