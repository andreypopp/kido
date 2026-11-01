#define _DARWIN_C_SOURCE
#define _GNU_SOURCE
#include <unistd.h>
#include <stdio.h>
#include <stdint.h>
#include <errno.h>

int main(void) {
  static uint8_t buffer[1 << 20];
  uint64_t total = 0;
  for (;;) {
    ssize_t n = read(0, buffer, sizeof(buffer));
    if (n > 0) total += (uint64_t)n;
    else if (n < 0 && errno == EINTR) continue;
    else break;
  }
  fprintf(stderr, "drain bytes=%llu\n", (unsigned long long)total);
  return 0;
}
