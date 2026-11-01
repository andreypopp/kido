#define _DARWIN_C_SOURCE
#define _GNU_SOURCE
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "../ko_pane/now.h"

#define MARKER 22
#define KEEP (MARKER - 1)

static int compare(const void *a, const void *b) {
  double x = *(const double *)a, y = *(const double *)b;
  return (x > y) - (x < y);
}

int main(int argc, char **argv) {
  const char *label = argc > 1 ? argv[1] : "reader";
  static uint8_t buffer[(1 << 20) + KEEP];
  size_t capacity = 1 << 20, count = 0, kept = 0;
  double *samples = malloc(capacity * sizeof(double));
  uint64_t last = 0, total = 0;
  if (!samples) return 2;
  for (;;) {
    ssize_t n = read(0, buffer + kept, 1 << 20);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) break;
    uint64_t now = ko_now_ns();
    size_t have = kept + (size_t)n;
    total += (uint64_t)n;
    size_t i = 0;
    for (; i + MARKER <= have; i++) {
      if (buffer[i] != 'T') continue;
      uint64_t stamp = 0;
      int digits = 0;
      while (digits < 20 && buffer[i + 1 + digits] >= '0' && buffer[i + 1 + digits] <= '9') {
        stamp = stamp * 10 + (uint64_t)(buffer[i + 1 + digits] - '0');
        digits++;
      }
      if (digits != 20 || buffer[i + 21] != '\r' || stamp == last || stamp > now) continue;
      last = stamp;
      if (count < capacity) samples[count++] = (double)(now - stamp) / 1e3;
      i += MARKER - 1;
    }
    kept = have - i < KEEP ? have - i : KEEP;
    memmove(buffer, buffer + have - kept, kept);
  }
  qsort(samples, count, sizeof(double), compare);
  if (count)
    fprintf(stderr, "%s bytes=%llu samples=%zu p50_us=%.0f p99_us=%.0f max_us=%.0f\n", label,
            (unsigned long long)total, count, samples[count / 2], samples[count * 99 / 100],
            samples[count - 1]);
  else
    fprintf(stderr, "%s bytes=%llu samples=0\n", label, (unsigned long long)total);
  return 0;
}
