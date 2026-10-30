#define _DARWIN_C_SOURCE
#include "compress.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static GhosttyTerminalMemoryUsage usage(GhosttyTerminal vt) {
  GhosttyTerminalMemoryUsage u = GHOSTTY_INIT_SIZED(GhosttyTerminalMemoryUsage);
  assert(ghostty_terminal_get(vt, GHOSTTY_TERMINAL_DATA_MEMORY_USAGE, &u) == GHOSTTY_SUCCESS);
  return u;
}
static void write_text(GhosttyTerminal vt, const char *text, size_t n) {
  ghostty_terminal_vt_write(vt, (const uint8_t *)text, n);
}
static void lines(GhosttyTerminal vt, int count) {
  char text[64];
  for (int i = 0; i < count; i++) {
    int n = snprintf(text, sizeof(text), "compressible scrollback line %d\r\n", i);
    write_text(vt, text, (size_t)n);
  }
}
int main(void) {
  GhosttyTerminal vt;
  struct ko_compress c;
  size_t limit = 50000000;
  assert(ghostty_terminal_new(NULL, &vt, 80, 24) == GHOSTTY_SUCCESS);
  ghostty_terminal_set(vt, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &limit);
  lines(vt, 20000);
  GhosttyTerminalMemoryUsage before = usage(vt);
  assert(before.compression_supported);
  uint64_t start = 1000000000u;
  ko_compress_init(&c, start);
  int timeout = ko_compress_tick(&c, vt, start);
  assert(timeout > 0 && timeout <= 250);
  lines(vt, 10);
  timeout = ko_compress_tick(&c, vt, start + 200000000u);
  assert(timeout > 200 && usage(vt).primary_compressed_pages == 0);
  uint64_t now = start + 200000000u + KO_COMPRESS_IDLE_NS;
  write_text(vt, "\rspinner 1234", 13);
  int steps = 0;
  while ((timeout = ko_compress_tick(&c, vt, now)) == 0) {
    steps++;
    assert(steps < 100000);
  }
  assert(timeout == -1 && steps > 0);
  GhosttyTerminalMemoryUsage after = usage(vt);
  assert(after.primary_compressed_pages > 0);
  assert(after.primary_resident_bytes < before.primary_resident_bytes / 2);
  assert(ko_compress_tick(&c, vt, now + KO_COMPRESS_IDLE_NS) == -1);
  printf("PASS idle compression: %llu of %llu pages, resident %llu to %llu bytes in %d steps\n",
         (unsigned long long)after.primary_compressed_pages, (unsigned long long)after.primary_pages,
         (unsigned long long)before.primary_resident_bytes, (unsigned long long)after.primary_resident_bytes, steps);
  ghostty_terminal_free(vt);

  assert(ghostty_terminal_new(NULL, &vt, 80, 24) == GHOSTTY_SUCCESS);
  ghostty_terminal_set(vt, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &limit);
  lines(vt, 20000);
  before = usage(vt);
  ko_compress_init(&c, start);
  uint64_t t = start;
  int steps_busy = 0;
  for (int i = 1; i <= 800; i++) {
    t = start + (uint64_t)i * KO_COMPRESS_STEP_NS;
    if (i % 10 == 0) {
      lines(vt, 1);
    }
    uint64_t pages = usage(vt).primary_compressed_pages;
    int next = ko_compress_tick(&c, vt, t);
    assert(next != 0 && next <= 250);
    if (t - start < KO_COMPRESS_BUSY_NS) {
      assert(pages == 0);
    } else if (usage(vt).primary_compressed_pages > pages) {
      steps_busy++;
    }
  }
  after = usage(vt);
  assert(steps_busy > 0 && after.primary_compressed_pages > 0);
  assert(after.primary_resident_bytes < before.primary_resident_bytes / 2);
  printf("PASS busy compression: %llu of %llu pages, resident %llu to %llu bytes\n",
         (unsigned long long)after.primary_compressed_pages, (unsigned long long)after.primary_pages,
         (unsigned long long)before.primary_resident_bytes, (unsigned long long)after.primary_resident_bytes);
  ghostty_terminal_free(vt);
  return 0;
}
