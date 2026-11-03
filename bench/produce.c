#define _DARWIN_C_SOURCE
#define _GNU_SOURCE
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

static inline uint64_t ko_now_ns(void) {
#ifdef __APPLE__
  return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#else
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec;
#endif
}

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

static uint64_t mixed_state;

static uint32_t mixed_random(void) {
  mixed_state ^= mixed_state << 13;
  mixed_state ^= mixed_state >> 7;
  mixed_state ^= mixed_state << 17;
  return (uint32_t)(mixed_state >> 16);
}

static size_t utf8_encode(char *out, uint32_t cp) {
  if (cp < 0x80) {
    out[0] = (char)cp;
    return 1;
  }
  if (cp < 0x800) {
    out[0] = (char)(0xc0 | (cp >> 6));
    out[1] = (char)(0x80 | (cp & 0x3f));
    return 2;
  }
  if (cp < 0x10000) {
    out[0] = (char)(0xe0 | (cp >> 12));
    out[1] = (char)(0x80 | ((cp >> 6) & 0x3f));
    out[2] = (char)(0x80 | (cp & 0x3f));
    return 3;
  }
  out[0] = (char)(0xf0 | (cp >> 18));
  out[1] = (char)(0x80 | ((cp >> 12) & 0x3f));
  out[2] = (char)(0x80 | ((cp >> 6) & 0x3f));
  out[3] = (char)(0x80 | (cp & 0x3f));
  return 4;
}

enum { MIXED_COLS = 70 };

static size_t mixed_line(char *out, long number, uint32_t longest_run) {
  size_t n = (size_t)sprintf(out, "\033[0mline %06ld ", number);
  int col = 12;
  mixed_state = (uint64_t)number * 0x9e3779b97f4a7c15ull + 1;
  while (col < MIXED_COLS) {
    uint32_t run = 1 + mixed_random() % longest_run;
    if (run > (uint32_t)(MIXED_COLS - col)) run = (uint32_t)(MIXED_COLS - col);
    n += (size_t)sprintf(out + n, "\033[0");
    switch (mixed_random() % 4) {
      case 0: n += (size_t)sprintf(out + n, ";38;2;%u;%u;%u", mixed_random() % 256, mixed_random() % 256, mixed_random() % 256); break;
      case 1: n += (size_t)sprintf(out + n, ";48;5;%u;38;5;%u", mixed_random() % 256, mixed_random() % 256); break;
      case 2: n += (size_t)sprintf(out + n, ";1;3;4;3%u", mixed_random() % 8); break;
      default: n += (size_t)sprintf(out + n, ";7;9;4%u", mixed_random() % 8); break;
    }
    out[n++] = 'm';
    int link = mixed_random() % 16 == 0;
    if (link) n += (size_t)sprintf(out + n, "\033]8;id=%u;https://example.com/%ld/%u\033\\", mixed_random() % 1000, number, mixed_random());
    for (uint32_t used = 0; used < run;) {
      uint32_t kind = mixed_random() % 20, room = run - used;
      if (kind < 3 && room >= 2) {
        n += utf8_encode(out + n, 0x4e00 + mixed_random() % 20000);
        used += 2;
      } else if (kind == 3 && room >= 2) {
        n += utf8_encode(out + n, 0x1f600 + mixed_random() % 80);
        used += 2;
      } else if (kind < 5) {
        out[n++] = (char)('a' + mixed_random() % 26);
        n += utf8_encode(out + n, 0x300 + mixed_random() % 0x70);
        used += 1;
      } else {
        out[n++] = (char)(' ' + 1 + mixed_random() % 94);
        used += 1;
      }
    }
    if (link) n += (size_t)sprintf(out + n, "\033]8;;\033\\");
    col += (int)run;
  }
  n += (size_t)sprintf(out + n, "\033[0m\r\n");
  return n;
}

int main(int argc, char **argv) {
  int query = argc > 1 && !strcmp(argv[1], "--query");
  if (query) {
    argv++;
    argc--;
  }
  int stamped = argc > 1 && !strcmp(argv[1], "--stamped");
  if (stamped) {
    argv++;
    argc--;
  }
  if (argc < 3) {
    fprintf(stderr, "usage: produce [--query|--stamped] BYTES FILE... | --latency COUNT | --lines COUNT | --mixed COUNT LONGEST_RUN\n");
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
      struct timespec pause = {0, 3300000};
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
  if (!strcmp(argv[1], "--mixed")) {
    long count = atol(argv[2]);
    uint32_t longest_run = argc > 3 ? (uint32_t)atol(argv[3]) : 8;
    char line[8192];
    for (long i = 1; i <= count; i++) output(line, mixed_line(line, i, longest_run));
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
    if (stamped) {
      char line[32];
      int len = snprintf(line, sizeof(line), "T%020llu\r\n", (unsigned long long)ko_now_ns());
      output(line, (size_t)len);
    }
  }
  return query ? await_reply() : 0;
}
