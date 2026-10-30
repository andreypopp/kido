#define _DARWIN_C_SOURCE
#define _DEFAULT_SOURCE
#include <unistd.h>
#include <fcntl.h>
#include <termios.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdio.h>
#include <errno.h>
#include <poll.h>
#include <string.h>
#include <time.h>
#include "../ko_pane/now.h"

static void output(const void *ptr, size_t n) {
  const uint8_t *p = ptr;
  while (n) {
    ssize_t got = write(1, p, n);
    if (got > 0) { p += got; n -= (size_t)got; }
    else if (errno != EINTR) _exit(1);
  }
}

static int await_reply(void) {
  struct termios term;
  if (tcgetattr(0, &term)) return 2;
  term.c_lflag &= ~(tcflag_t)(ICANON | ECHO);
  term.c_cc[VMIN] = 1;
  term.c_cc[VTIME] = 0;
  if (tcsetattr(0, TCSAFLUSH, &term)) return 2;
  output("\033\\\033[c", 5);
  char reply[4096];
  size_t have = 0;
  for (int waited = 0; waited < 600 && have < sizeof(reply) - 1; waited++) {
    struct pollfd f = {0, POLLIN, 0};
    if (poll(&f, 1, 100) > 0) {
      ssize_t n = read(0, reply + have, sizeof(reply) - 1 - have);
      if (n > 0) have += (size_t)n;
      reply[have] = 0;
      char *start = strstr(reply, "\033[?");
      if (start && strchr(start, 'c')) return 0;
    }
  }
  return 1;
}

int main(int argc, char **argv) {
  int query = argc > 1 && !strcmp(argv[1], "--query");
  if (query) {
    argv++;
    argc--;
  }
  if (argc < 3) {
    fprintf(stderr, "usage: produce [--query] BYTES FILE... | --latency COUNT | --lines COUNT\n");
    return 2;
  }
  struct termios term;
  if (!tcgetattr(1, &term)) {
    term.c_oflag &= ~(tcflag_t)OPOST;
    if (tcsetattr(1, TCSANOW, &term)) return 2;
  }
  if (!strcmp(argv[1], "--latency")) {
    long count = atol(argv[2]);
    for (long i = 0; i < count; i++) {
      char line[32];
      int n = snprintf(line, sizeof(line), "T%020llu\r\n", (unsigned long long)ko_now_ns());
      output(line, (size_t)n);
      struct timespec pause = {0, 1000000};
      nanosleep(&pause, NULL);
    }
    return 0;
  }
  if (!strcmp(argv[1], "--lines")) {
    long count = atol(argv[2]);
    for (long i = 1; i <= count; i++) {
      char line[64];
      int n = snprintf(line, sizeof(line), "%06ld: \033[32mok\033[0m build step completed\r\n", i);
      output(line, (size_t)n);
    }
    return 0;
  }
  uint64_t remaining = strtoull(argv[1], NULL, 10);
  int files = argc - 2;
  uint8_t **data = calloc((size_t)files, sizeof(uint8_t *));
  size_t *sizes = calloc((size_t)files, sizeof(size_t));
  if (!data || !sizes) return 2;
  for (int i = 0; i < files; i++) {
    int fd = open(argv[i + 2], O_RDONLY);
    if (fd < 0) return 2;
    data[i] = malloc(1 << 20);
    if (!data[i]) return 2;
    ssize_t n;
    while ((n = read(fd, data[i] + sizes[i], (1 << 20) - sizes[i])) > 0) sizes[i] += (size_t)n;
    close(fd);
    if (!sizes[i]) return 2;
  }
  for (int i = 0; remaining; i = (i + 1) % files) {
    size_t n = remaining < sizes[i] ? (size_t)remaining : sizes[i];
    output(data[i], n);
    remaining -= n;
  }
  return query ? await_reply() : 0;
}
