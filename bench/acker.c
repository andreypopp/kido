#define _DARWIN_C_SOURCE
#define _DEFAULT_SOURCE
#include "../ko_pane/protocol.h"
#include "../ko_pane/ring.h"
#include "cpu.h"
#include <sys/socket.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

struct data { uint8_t b[65536]; size_t n; };

static void bytes(struct data *d, const void *b, size_t n) {
  if (d->n + n > sizeof(d->b)) exit(2);
  memcpy(d->b + d->n, b, n);
  d->n += n;
}
static void num(struct data *d, uint64_t v, unsigned n) { uint8_t b[8]; ko_put(b, v, n); bytes(d, b, n); }
static void str(struct data *d, const char *s) { num(d, strlen(s), 4); bytes(d, s, strlen(s)); }

static void write_all(int fd, const uint8_t *p, size_t n) {
  while (n) {
    ssize_t w = write(fd, p, n);
    if (w > 0) { p += w; n -= (size_t)w; }
    else if (errno != EINTR) exit(1);
  }
}

static void frame(int fd, unsigned kind, const void *b, size_t n) {
  uint8_t h[5];
  ko_put(h, n + 1, 4);
  h[4] = (uint8_t)kind;
  write_all(fd, h, 5);
  if (n) write_all(fd, b, n);
}

int main(int argc, char **argv) {
  if (argc < 4) {
    fprintf(stderr, "usage: acker KO_PANE callbacks|no-callbacks PRODUCER ARGS...\n");
    return 2;
  }
  signal(SIGPIPE, SIG_IGN);
  size_t capacity=1 << 20;
  struct ko_ring *ring=NULL;
  int fd=ko_ring_create(capacity,&ring);
  if(fd<0)return 2;
  int sockets[2];
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, sockets)) return 2;
  struct timespec start, end;
  clock_gettime(CLOCK_MONOTONIC, &start);
  pid_t pane = fork();
  if (pane == 0) {
    if (dup2(sockets[1], 0) < 0 || dup2(sockets[1], 1) < 0 || dup2(fd, 3) < 0 || fcntl(3, F_SETFD, 0) < 0) _exit(126);
    for (int i = 4; i < 64; i++) close(i);
    char *args[] = {argv[1], strcmp(argv[2], "callbacks") ? "--no-callbacks" : NULL, NULL};
    execv(argv[1], args);
    _exit(127);
  }
  close(sockets[1]);
  close(fd);
  int control = sockets[0];
  struct data d = {0};
  num(&d, 2, 2); num(&d, 80, 2); num(&d, 24, 2); num(&d, 8, 2); num(&d, 16, 2);
  num(&d, 50000000, 8); num(&d, 0, 8); num(&d, 65u << 20, 8); num(&d, 10000000, 8); num(&d, 0, 1); num(&d, 65u << 20, 8);
  str(&d, "/");
  num(&d, (uint64_t)(argc - 3), 4);
  for (int i = 3; i < argc; i++) str(&d, argv[i]);
  num(&d, 1, 4); str(&d, "TERM=xterm-ghostty");
  str(&d, "pane_1");
  frame(control, KO_INIT, d.b, d.n);
  static uint8_t input[1 << 16];
  size_t filled = 0;
  uint64_t tail = 0, payload = 0, frames = 0;
  double pane_cpu = 0;
  for (int dead = 0; !dead;) {
    ssize_t n = read(control, input + filled, sizeof(input) - filled);
    if (n <= 0) {
      if (n < 0 && errno == EINTR) continue;
      fprintf(stderr, "ko-pane closed its control socket\n");
      return 1;
    }
    filled += (size_t)n;
    size_t pos = 0, frame_size;
    int full = 0;
    while (ko_frame_size(input + pos, filled - pos, &frame_size) == 1) {
      unsigned kind = input[pos + 4];
      frames++;
      if (kind == KO_FULL) full = 1;
      if (kind == KO_DEAD) { dead = 1; pane_cpu = ko_cpu_seconds(pane); }
      pos += frame_size;
    }
    memmove(input, input + pos, filled - pos);
    filled -= pos;
    for (uint64_t head = atomic_load(&ring->head); tail < head; head = atomic_load(&ring->head)) {
      while (tail < head) {
        uint8_t *record = ring->data + tail % capacity;
        size_t len = ko_get(record + 1, 4);
        if (record[0] == KO_BYTES) payload += len;
        tail += KO_HEADER + len;
      }
      atomic_store(&ring->tail, tail);
      atomic_store(&ring->read, tail);
    }
    if (full) {
      uint8_t b[8];
      ko_put(b, tail, 8);
      frame(control, KO_TAIL, b, 8);
    }
  }
  clock_gettime(CLOCK_MONOTONIC, &end);
  frame(control, KO_EXIT, NULL, 0);
  waitpid(pane, NULL, 0);
  double elapsed = (double)(end.tv_sec - start.tv_sec) + (double)(end.tv_nsec - start.tv_nsec) / 1e9;
  fprintf(stderr, "acker %s bytes=%llu seconds=%.3f MB/s=%.1f frames=%llu pane_cpu=%.3f cores=%.2f\n", argv[2],
          (unsigned long long)payload, elapsed, (double)payload / elapsed / 1e6, (unsigned long long)frames,
          pane_cpu, pane_cpu / elapsed);
  return 0;
}
