#define _DARWIN_C_SOURCE
#define _DEFAULT_SOURCE
#include <ghostty/vt.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#endif
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <time.h>

enum mode { DISCARD, PARSE, SOCKET };

static void reply(GhosttyTerminal t, void *ud, const uint8_t *b, size_t n) { (void)t; (void)ud; (void)b; (void)n; }

static double seconds(struct timeval t) { return (double)t.tv_sec + (double)t.tv_usec / 1e6; }

int main(int argc, char **argv) {
  if (argc < 4) {
    fprintf(stderr, "usage: pty_read discard|parse|socket DRAIN PRODUCER ARGS...\n");
    return 2;
  }
  enum mode mode = !strcmp(argv[1], "parse") ? PARSE : !strcmp(argv[1], "socket") ? SOCKET : DISCARD;
  int view[2] = {-1, -1};
  pid_t drain = -1;
  if (mode == SOCKET) {
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, view)) return 2;
    int size = 1 << 20;
    setsockopt(view[0], SOL_SOCKET, SO_SNDBUF, &size, sizeof(size));
    setsockopt(view[1], SOL_SOCKET, SO_RCVBUF, &size, sizeof(size));
    drain = fork();
    if (drain == 0) {
      if (dup2(view[1], 0) < 0) _exit(126);
      close(view[0]);
      close(view[1]);
      execl(argv[2], argv[2], NULL);
      _exit(127);
    }
    close(view[1]);
  }
  GhosttyTerminal vt = NULL;
  if (mode == PARSE) {
    if (ghostty_terminal_new(NULL, &vt, 80, 24) != GHOSTTY_SUCCESS) return 2;
    size_t scrollback = 32 << 20;
    ghostty_terminal_set(vt, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &scrollback);
    ghostty_terminal_set(vt, GHOSTTY_TERMINAL_OPT_WRITE_PTY, reply);
  }
  int master, slave;
  struct winsize window = {.ws_row = 24, .ws_col = 80};
  if (openpty(&master, &slave, NULL, NULL, &window)) return 2;
  struct timespec start, end;
  clock_gettime(CLOCK_MONOTONIC, &start);
  pid_t pid = fork();
  if (pid == 0) {
    if (setsid() < 0 || ioctl(slave, TIOCSCTTY, 0) < 0 || dup2(slave, 0) < 0 ||
        dup2(slave, 1) < 0 || dup2(slave, 2) < 0)
      _exit(126);
    close(master);
    close(slave);
    if (view[0] >= 0) close(view[0]);
    execv(argv[3], argv + 3);
    _exit(127);
  }
  close(slave);
  fcntl(master, F_SETFL, O_NONBLOCK);
  size_t capacity = 1 << 20;
  uint8_t *buffer = malloc(capacity);
  uint64_t total = 0, reads = 0, wakeups = 0, sizes[13] = {0};
  for (int eof = 0; !eof;) {
    struct pollfd f = {master, POLLIN, 0};
    if (poll(&f, 1, -1) < 0) {
      if (errno == EINTR) continue;
      return 1;
    }
    wakeups++;
    size_t used = 0;
    for (;;) {
      ssize_t n = read(master, buffer + used, capacity - used);
      if (n > 0) {
        used += (size_t)n;
        reads++;
        int bucket = 0;
        while (bucket < 12 && ((size_t)1 << (bucket + 1)) <= (size_t)n) bucket++;
        sizes[bucket]++;
        if (used == capacity) break;
      } else if (n < 0 && errno == EINTR) continue;
      else {
        if (n == 0 || errno == EIO) eof = 1;
        break;
      }
    }
    total += used;
    if (mode == PARSE && used) ghostty_terminal_vt_write(vt, buffer, used);
    for (size_t done = 0; mode == SOCKET && done < used;) {
      ssize_t w = write(view[0], buffer + done, used - done);
      if (w > 0) done += (size_t)w;
      else if (errno != EINTR) return 1;
    }
  }
  waitpid(pid, NULL, 0);
  clock_gettime(CLOCK_MONOTONIC, &end);
  if (mode == SOCKET) {
    close(view[0]);
    waitpid(drain, NULL, 0);
  }
  struct rusage self;
  getrusage(RUSAGE_SELF, &self);
  double elapsed = (double)(end.tv_sec - start.tv_sec) + (double)(end.tv_nsec - start.tv_nsec) / 1e9;
  double cpu = seconds(self.ru_utime) + seconds(self.ru_stime);
  fprintf(stderr, "pty_read mode=%s bytes=%llu seconds=%.3f MB/s=%.1f reader_cpu=%.3f cores=%.2f reads=%llu wakeups=%llu bytes/wakeup=%.0f\n",
          argv[1], (unsigned long long)total, elapsed, (double)total / elapsed / 1e6, cpu, cpu / elapsed,
          (unsigned long long)reads, (unsigned long long)wakeups, (double)total / (double)wakeups);
  fprintf(stderr, "read sizes:");
  for (int i = 0; i < 13; i++)
    if (sizes[i]) fprintf(stderr, " [%zu,%zu):%.1f%%", (size_t)1 << i, (size_t)1 << (i + 1), 100.0 * (double)sizes[i] / (double)reads);
  fprintf(stderr, "\n");
  if (vt) ghostty_terminal_free(vt);
  free(buffer);
  return 0;
}
