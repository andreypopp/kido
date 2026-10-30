#ifndef KO_COMPRESS_H
#define KO_COMPRESS_H
#include "now.h"
#include <ghostty/vt.h>
#include <stdint.h>

#define KO_COMPRESS_IDLE_NS 250000000u
#define KO_COMPRESS_BUSY_NS 2000000000u
#define KO_COMPRESS_STEP_NS 10000000u
struct ko_compress {
  uint64_t activity, quiet_since, busy_since, stepped;
  int pending;
};

static inline void ko_compress_init(struct ko_compress *c, uint64_t now) {
  *c = (struct ko_compress){.quiet_since = now, .busy_since = now, .pending = 1};
}

/* The next poll timeout in milliseconds, 0 when an idle step ran and more
 * remains, -1 when settled. After KO_COMPRESS_BUSY_NS without an idle period,
 * one step runs per KO_COMPRESS_STEP_NS. */
static inline int ko_compress_tick(struct ko_compress *c, GhosttyTerminal vt,
                                   uint64_t now) {
  uint64_t activity;
  if (ghostty_terminal_compression_activity(vt, &activity) != GHOSTTY_SUCCESS) {
    return -1;
  }
  if (activity != c->activity) {
    if (now - c->quiet_since >= KO_COMPRESS_IDLE_NS) {
      c->busy_since = now;
    }
    c->activity = activity;
    c->quiet_since = now;
    c->pending = 1;
  }
  if (!c->pending) {
    return -1;
  }
  int paced = 0;
  if (now - c->quiet_since < KO_COMPRESS_IDLE_NS) {
    if (now - c->busy_since < KO_COMPRESS_BUSY_NS) {
      return (int)((KO_COMPRESS_IDLE_NS - (now - c->quiet_since) + 999999u) /
                   1000000u);
    }
    if (now - c->stepped < KO_COMPRESS_STEP_NS) {
      return (int)((KO_COMPRESS_STEP_NS - (now - c->stepped) + 999999u) /
                   1000000u);
    }
    paced = 1;
    c->stepped = now;
  }
  GhosttyTerminalCompressionResult result;
  if (ghostty_terminal_compress(vt, GHOSTTY_TERMINAL_COMPRESSION_MODE_INCREMENTAL,
                                &result) != GHOSTTY_SUCCESS ||
      result != GHOSTTY_TERMINAL_COMPRESSION_RESULT_PENDING) {
    c->pending = 0;
    return -1;
  }
  ghostty_terminal_compression_activity(vt, &c->activity);
  return paced ? (int)(KO_COMPRESS_STEP_NS / 1000000u) : 0;
}
#endif
