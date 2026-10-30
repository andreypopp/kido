#include <ghostty/vt.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static void noop(GhosttyTerminal t, void *ud) { (void)t; (void)ud; }
static void prompt(GhosttyTerminal t, void *ud, const GhosttyTerminalSemanticPrompt *e) { (void)t; (void)ud; (void)e; }
static void record(GhosttyTerminal t, void *ud, const GhosttyTerminalProgramStatus *e) { (void)t; (void)ud; (void)e; }
static void reply(GhosttyTerminal t, void *ud, const uint8_t *b, size_t n) { (void)t; (void)ud; (void)b; (void)n; }

int main(int argc, char **argv) {
  if (argc < 4) {
    fprintf(stderr, "usage: parse BYTES CHUNK FILE...\n");
    return 2;
  }
  size_t total = strtoull(argv[1], NULL, 10), chunk = strtoull(argv[2], NULL, 10), size = 0;
  uint8_t *corpus = malloc(8 << 20);
  for (int i = 3; i < argc; i++) {
    int fd = open(argv[i], O_RDONLY);
    ssize_t n;
    while (fd >= 0 && (n = read(fd, corpus + size, (8 << 20) - size)) > 0) size += (size_t)n;
    if (fd >= 0) close(fd);
  }
  for (int callbacks = 0; callbacks < 2; callbacks++) {
    GhosttyTerminal vt;
    if (ghostty_terminal_new(NULL, &vt, 80, 24) != GHOSTTY_SUCCESS) return 1;
    size_t scrollback = 50000000;
    ghostty_terminal_set(vt, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &scrollback);
    ghostty_terminal_set(vt, GHOSTTY_TERMINAL_OPT_WRITE_PTY, reply);
    if (callbacks) {
      ghostty_terminal_set(vt, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, noop);
      ghostty_terminal_set(vt, GHOSTTY_TERMINAL_OPT_PWD_CHANGED, noop);
      ghostty_terminal_set(vt, GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT, prompt);
      ghostty_terminal_set(vt, GHOSTTY_TERMINAL_OPT_PROGRAM_STATUS, record);
    }
    struct timespec a, b;
    clock_gettime(CLOCK_MONOTONIC, &a);
    for (size_t done = 0, pos = 0; done < total;) {
      size_t n = chunk;
      if (n > size - pos) n = size - pos;
      if (n > total - done) n = total - done;
      ghostty_terminal_vt_write(vt, corpus + pos, n);
      done += n;
      pos = (pos + n) % size;
    }
    clock_gettime(CLOCK_MONOTONIC, &b);
    double s = (double)(b.tv_sec - a.tv_sec) + (double)(b.tv_nsec - a.tv_nsec) / 1e9;
    printf("vt_write in process callbacks=%d chunk=%zu MB/s=%.1f\n", callbacks, chunk, (double)total / s / 1e6);
    ghostty_terminal_free(vt);
  }
  return 0;
}
