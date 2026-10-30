#ifndef KO_COMPRESS_H
#define KO_COMPRESS_H
#include "now.h"
#include <ghostty/vt.h>
#include <stdint.h>

#define KO_COMPRESS_IDLE_NS 250000000u
struct ko_compress {
  uint64_t activity, quiet_since;
  int pending;
};

static inline void ko_compress_init(struct ko_compress *c, uint64_t now) {
  *c = (struct ko_compress){.quiet_since = now, .pending = 1};
}

/* The next poll timeout in milliseconds, 0 when a step ran and more remains,
 * -1 when settled. */
static inline int ko_compress_tick(struct ko_compress *c, GhosttyTerminal vt,
                                   uint64_t now) {
  uint64_t activity;
  if (ghostty_terminal_compression_activity(vt, &activity) != GHOSTTY_SUCCESS) {
    return -1;
  }
  if (activity != c->activity) {
    c->activity = activity;
    c->quiet_since = now;
    c->pending = 1;
  }
  if (!c->pending) {
    return -1;
  }
  if (now - c->quiet_since < KO_COMPRESS_IDLE_NS) {
    return (int)((KO_COMPRESS_IDLE_NS - (now - c->quiet_since) + 999999u) /
                 1000000u);
  }
  GhosttyTerminalCompressionResult result;
  if (ghostty_terminal_compress(vt, GHOSTTY_TERMINAL_COMPRESSION_MODE_INCREMENTAL,
                                &result) != GHOSTTY_SUCCESS ||
      result != GHOSTTY_TERMINAL_COMPRESSION_RESULT_PENDING) {
    c->pending = 0;
    return -1;
  }
  ghostty_terminal_compression_activity(vt, &c->activity);
  return 0;
}
#endif
