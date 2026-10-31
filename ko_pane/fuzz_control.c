#define _DARWIN_C_SOURCE
#define _GNU_SOURCE
#include <assert.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <ghostty/vt.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#endif
static GhosttyTerminal pooled;
static GhosttyResult pooled_new(GhosttyTerminal *out, uint16_t cols, uint16_t rows) {
  GhosttyResult result = GHOSTTY_SUCCESS;
  if (pooled) {
    ghostty_terminal_reset(pooled);
    result = ghostty_terminal_resize(pooled, cols, rows, 0, 0);
  } else {
    result = ghostty_terminal_new(NULL, &pooled, cols, rows);
  }
  *out = pooled;
  return result;
}
#define ghostty_terminal_new(allocator, out, cols, rows) pooled_new(out, cols, rows)
#define ghostty_terminal_free(vt) ((void)(vt))
#define main ko_pane_main
#define openpty(master, slave, name, term, size) ((void)(size), -1)
#include "pane.c"
#undef main

#define CAPACITY (1u << 20)

static int refused;

int LLVMFuzzerInitialize(int *argc, char ***argv) {
  (void)argc;
  (void)argv;
  signal(SIGPIPE, SIG_IGN);
  int null = open("/dev/null", O_WRONLY);
  dup2(null, 1);
  close(null);
  FILE *file = tmpfile();
  if (!file) {
    abort();
  }
  dup2(fileno(file), 0);
  fclose(file);
  return 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  if (!size || size > 60000) {
    return 0;
  }
  unsigned mode = data[0];
  data++;
  size--;
  static struct ko_ring *ring;
  if (!ring) {
    ring = malloc(sizeof(struct ko_ring) + CAPACITY);
  }
  memset(ring, 0, sizeof(struct ko_ring));
  ring->capacity = CAPACITY;
  struct pane p = {.master = -1, .ring = ring};
  if (ko_ring_attach(ring, sizeof(struct ko_ring) + CAPACITY, &p.view)) {
    abort();
  }
  if (mode & 1) {
    if (ghostty_terminal_new(NULL, &p.vt, 80, 24) != GHOSTTY_SUCCESS) {
      abort();
    }
    size_t limit = 1 << 20;
    ghostty_terminal_set(p.vt, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES,
                         &limit);
    wire_vt(&p);
  }
  if (ftruncate(0, 0) || pwrite(0, data, size, 0) != (ssize_t)size) {
    abort();
  }
  lseek(0, mode & 2 ? 0 : (off_t)size, SEEK_SET);
  if (mode & 2) {
    control(&p, 1);
  } else {
    for (size_t pos = 0, frame_len; pos < size;) {
      if (ko_frame_size(data + pos, size - pos, &frame_len) <= 0) {
        break;
      }
      uint8_t *body = malloc(frame_len - 5 ? frame_len - 5 : 1);
      memcpy(body, data + pos + 5, frame_len - 5);
      ko_atomic_store((uint64_t *)&ring->tail, p.writer.whead);
      ko_atomic_store((uint64_t *)&ring->read, p.writer.whead);
      int failed = dispatch(&p, data[pos + 4], body, frame_len - 5, 1);
      free(body);
      refused = failed;
      if (failed) {
        break;
      }
      pos += frame_len;
    }
  }
  if (p.vt) {
    ghostty_terminal_free(p.vt);
  }
  free(p.input.p);
  free(p.output.p);
  free(p.pty_input.p);
  free(p.events.p);
  free(p.deferred.p);
  return 0;
}

#ifndef KO_LIBFUZZER
static uint8_t input[60000];
static size_t used;
static void put(uint64_t v, unsigned n) {
  if (used + n <= sizeof(input)) {
    ko_put(input + used, v, n);
    used += n;
  }
}
static uint64_t number_of(unsigned bytes) {
  static const uint64_t edges[] = {0, 1, 0xff, 0xffff, 0x7fffffff, 0xffffffff, UINT64_MAX};
  int roll = rand() % 10;
  uint64_t v = roll < 6 ? (uint64_t)(rand() % 5) : roll < 9 ? edges[rand() % 7] : (uint64_t)rand() * 65537u;
  return bytes < 8 ? v & ((1ull << (8 * bytes)) - 1) : v;
}
static void text(const char *s) {
  size_t n = strlen(s);
  put(rand() % 8 ? n : number_of(4), 4);
  for (size_t i = 0; i < n; i++) {
    put((uint8_t)s[i], 1);
  }
}
static void strings_of(unsigned count) {
  put(rand() % 8 ? count : number_of(4), 4);
  for (unsigned i = 0; i < count; i++) {
    text(rand() % 4 ? "/bin/sh" : "");
  }
}
static void size_fields(void) {
  for (int i = 0; i < 4; i++) {
    put(rand() % 4 ? (uint64_t)(1 + rand() % 120) : number_of(2), 2);
  }
}
static void body(unsigned kind) {
  switch (kind) {
  case KO_INIT:
    put(rand() % 8 ? 3 : number_of(2), 2);
    size_fields();
    put(rand() % 2, 1);
    put(number_of(8), 8);
    put(rand() % 2, 1);
    put(number_of(8), 8);
    put(rand() % 4 ? 1 << 16 : number_of(8), 8);
    put(rand() % 4 ? 1 << 20 : number_of(8), 8);
    put(rand() % 8, 1);
    put(rand() % 4 ? 1 << 16 : number_of(8), 8);
    text(rand() % 4 ? "/" : "relative");
    strings_of(1 + rand() % 3);
    strings_of(rand() % 3);
    text("pane_1");
    break;
  case KO_TAIL:
    put(number_of(8), 8);
    break;
  case KO_RESIZE:
    size_fields();
    break;
  case KO_SNAPSHOT:
    put(number_of(4), 4);
    put(rand() % 3, 1);
    put(rand() % 3, 1);
    text(rand() % 8 ? "" : "x");
    break;
  case KO_KEY:
    put(rand() % 4, 1);
    put(rand() % 4 ? (uint64_t)(rand() % 200) : number_of(2), 2);
    put(rand() % 4 ? (uint64_t)(rand() % 16) : number_of(2), 2);
    put(rand() % 4 ? (uint64_t)('a' + rand() % 26) : number_of(4), 4);
    text(rand() % 2 ? "a" : "\xc3\xa9");
    put(rand() % 3, 1);
    break;
  case KO_MOUSE:
    put(rand() % 4, 1);
    put(rand() % 13, 1);
    put(rand() % 100, 2);
    put(rand() % 100, 2);
    put(rand() % 8, 2);
    break;
  case KO_PASTE:
    put(number_of(4), 4);
    text(rand() % 2 ? "pasted\ntext" : "\x1b[201~");
    put(rand() % 3, 1);
    break;
  case KO_FOCUS:
    put(rand() % 3, 1);
    break;
  case KO_SCREEN:
    put(rand() % 3, 1);
    put(rand() % 4 ? (uint64_t)(rand() % 50) : number_of(4), 4);
    break;
  default:
    for (int i = rand() % 12; i > 0; i--) {
      put((uint8_t)rand(), 1);
    }
  }
}
int main(int argc, char **argv) {
  alarm(120);
  LLVMFuzzerInitialize(NULL, NULL);
  if (argc > 1) {
    DIR *dir = opendir(argv[1]);
    assert(dir);
    for (struct dirent *entry; (entry = readdir(dir));) {
      char path[1024];
      snprintf(path, sizeof(path), "%s/%s", argv[1], entry->d_name);
      FILE *file = fopen(path, "rb");
      if (file) {
        size_t n = fread(input, 1, sizeof(input), file);
        fclose(file);
        LLVMFuzzerTestOneInput(input, n);
      }
    }
    closedir(dir);
  }
  srand(182);
  static const uint8_t huge[] = {1, 9, 0, 0, 0, 3, 0xff, 0xff, 0xff, 0xff, 8, 0, 16, 0};
  LLVMFuzzerTestOneInput(huge, sizeof(huge));
  assert(refused);
  for (int round = 0; round < 3000; round++) {
    used = 0;
    put((uint8_t)rand(), 1);
    for (int frames = 1 + rand() % 8; frames > 0; frames--) {
      size_t start = used;
      unsigned kind = rand() % 12 ? (unsigned)(1 + rand() % 22) : (unsigned)rand() % 256;
      put(0, 4);
      put(kind, 1);
      body(kind);
      size_t length = used - start - 4;
      int roll = rand() % 16;
      if (roll == 0 && length > 1) {
        length -= 1 + (size_t)rand() % (length - 1);
      } else if (roll == 1) {
        length += 1 + (size_t)rand() % 9;
      }
      ko_put(input + start, length, 4);
    }
    LLVMFuzzerTestOneInput(input, used);
  }
  return 0;
}
#endif
