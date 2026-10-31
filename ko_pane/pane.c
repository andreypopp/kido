#define _DARWIN_C_SOURCE
#define _GNU_SOURCE
#include "buffer.h"
#include "compress.h"
#include "now.h"
#include "pixels.h"
#include "protocol.h"
#include "ring.h"
#include "snapshot_cut.h"
#include <ghostty/vt.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#endif
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

struct group {
  pid_t leader;
};
static struct group group_of(pid_t child) {
  assert(child > 1);
  return (struct group){child};
}
static int group_signal(struct group group, int signo) {
  return kill(-group.leader, signo);
}

struct pane {
  struct ko_ring *ring;
  KoRing_Inv_ring view;
  KoRing_Inv_wstate writer;
  GhosttyTerminal vt;
  int master, alive, stopping, eof, reaped, code, termsig, full, depth;
  pid_t pid;
  struct ko_buffer input, output, pty_input, events, deferred;
  struct ko_compress compress;
};
static int sigchld[2] = {-1, -1};
static volatile sig_atomic_t shutdown_requested;
static void on_shutdown(int signo) {
  shutdown_requested = signo;
}
static void on_sigchld(int signo) {
  (void)signo;
  int saved = errno;
  ssize_t n = write(sigchld[1], "", 1);
  (void)n;
  errno = saved;
}
static int frame(struct ko_buffer *b, unsigned kind, const void *p, size_t n) {
  uint8_t h[5];
  ko_put(h, n + 1, 4);
  h[4] = kind;
  return ko_append(b, h, 5) || ko_append(b, p, n);
}
static int flush(int fd, struct ko_buffer *b) {
  while (b->pos < b->n) {
    ssize_t n = write(fd, b->p + b->pos, b->n - b->pos);
    if (n > 0) {
      b->pos += (size_t)n;
    } else if (n < 0 && errno == EINTR) {
      continue;
    } else if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
      return 0;
    } else {
      return -1;
    }
  }
  b->pos = b->n = 0;
  if (b->cap > 1024 * 1024) {
    free(b->p);
    *b = (struct ko_buffer){0};
  }
  return 0;
}
static uint8_t *at_head(struct pane *p) {
  return p->view.data + p->writer.whead % p->view.cap;
}
static void announce_head(struct pane *p) {
  uint8_t h[8];
  ko_put(h, p->writer.whead, 8);
  if (frame(&p->output, KO_HEAD, h, 8)) {
    p->stopping = 1;
  }
}
static size_t available(struct pane *p) {
  KoRing_Writer_avail a = KoRing_Writer_available(p->view, &p->writer);
  if (a.idle) {
    announce_head(p);
  }
  return a.room;
}
static void announce_full(struct pane *p) {
  if (p->full) {
    return;
  }
  p->full = 1;
  uint8_t b[8];
  ko_put(b, p->writer.wtail, 8);
  if (frame(&p->output, KO_FULL, b, 8)) {
    p->stopping = 1;
  }
}
static void commit(struct pane *p, unsigned kind, size_t n) {
  switch (KoRing_Writer_put_record(p->view, &p->writer, kind, n)) {
  case KoRing_Writer_Refused:
    p->stopping = 1;
    return;
  case KoRing_Writer_Idle:
    announce_head(p);
    break;
  }
  if (p->events.n) {
    if (ko_append(&p->output, p->events.p, p->events.n)) {
      p->stopping = 1;
    }
    p->events.n = 0;
  }
}
static void reply(GhosttyTerminal t, void *ud, const uint8_t *b, size_t n) {
  (void)t;
  struct pane *p = ud;
  if (ko_append(&p->pty_input, b, n)) {
    p->stopping = 1;
  }
}
static void string_event(struct pane *p, unsigned kind, GhosttyString s) {
  uint8_t b[4];
  ko_put(b, s.len, 4);
  uint8_t h[5];
  ko_put(h, s.len + 5, 4);
  h[4] = kind;
  if (ko_append(&p->events, h, 5) || ko_append(&p->events, b, 4) ||
      ko_append(&p->events, s.ptr, s.len)) {
    p->stopping = 1;
  }
}
static void title(GhosttyTerminal t, void *ud) {
  GhosttyString s = {0};
  ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_TITLE, &s);
  string_event(ud, KO_TITLE, s);
}
static void pwd(GhosttyTerminal t, void *ud) {
  GhosttyString s = {0};
  ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_PWD, &s);
  string_event(ud, KO_PWD, s);
}
struct cursor {
  const uint8_t *p;
  size_t n;
  int error;
};
static uint64_t number(struct cursor *c, unsigned n) {
  if (c->error || c->n < n) {
    c->error = 1;
    return 0;
  }
  uint64_t v = ko_get(c->p, n);
  c->p += n;
  c->n -= n;
  return v;
}
static char *blob(struct cursor *c, size_t *len) {
  size_t n = number(c, 4);
  if (c->error || n > c->n) {
    c->error = 1;
    return NULL;
  }
  char *s = malloc(n + 1);
  if (!s) {
    c->error = 1;
    return NULL;
  }
  memcpy(s, c->p, n);
  s[n] = 0;
  c->p += n;
  c->n -= n;
  *len = n;
  return s;
}
static char *string(struct cursor *c) {
  size_t len = 0;
  char *s = blob(c, &len);
  if (s && memchr(s, 0, len)) {
    free(s);
    c->error = 1;
    return NULL;
  }
  return s;
}
static char **strings(struct cursor *c) {
  size_t count = number(c, 4);
  if (count > 4096) {
    c->error = 1;
    return NULL;
  }
  char **v = calloc(count + 1, sizeof(char *));
  if (!v) {
    c->error = 1;
    return NULL;
  }
  for (size_t i = 0; i < count && !c->error; i++) {
    v[i] = string(c);
  }
  return v;
}
static void free_strings(char **v) {
  if (v) {
    for (size_t i = 0; v[i]; i++) {
      free(v[i]);
    }
    free(v);
  }
}
static void wire_vt(struct pane *p) {
  ghostty_terminal_set(p->vt, GHOSTTY_TERMINAL_OPT_USERDATA, p);
  ghostty_terminal_set(p->vt, GHOSTTY_TERMINAL_OPT_WRITE_PTY, reply);
  ghostty_terminal_set(p->vt, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, title);
  ghostty_terminal_set(p->vt, GHOSTTY_TERMINAL_OPT_PWD_CHANGED, pwd);
}
static int init(struct pane *p, const uint8_t *b, size_t n) {
  struct cursor c = {b, n, 0};
  unsigned version = number(&c, 2);
  uint16_t cols = number(&c, 2), rows = number(&c, 2), cw = number(&c, 2),
           ch = number(&c, 2);
  unsigned has_scrollback = number(&c, 1);
  size_t scrollback = number(&c, 8);
  unsigned has_lines = number(&c, 1);
  size_t lines = number(&c, 8), apc = number(&c, 8);
  uint64_t kitty = number(&c, 8);
  unsigned media = number(&c, 1);
  size_t continuation = number(&c, 8);
  char *cwd = string(&c);
  char **argv = strings(&c), **env = strings(&c);
  char *id = string(&c);
  int result = -1, slave = -1;
  struct winsize size = {.ws_row = rows,
                         .ws_col = cols,
                         .ws_xpixel = ko_pixels(cols, cw),
                         .ws_ypixel = ko_pixels(rows, ch)};
  if (c.error || c.n || version != 3 || has_scrollback > 1 || has_lines > 1 || !cols || !rows || !argv || !argv[0] ||
      argv[0][0] != '/' ||
      cols > KO_MAX_DIMENSION || rows > KO_MAX_DIMENSION) {
    goto done;
  }
  if (ghostty_terminal_new(NULL, &p->vt, cols, rows) != GHOSTTY_SUCCESS) {
    goto done;
  }
  ghostty_terminal_resize(p->vt, cols, rows, cw, ch);
  ghostty_terminal_set(p->vt, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES,
                       has_scrollback ? &scrollback : NULL);
  ghostty_terminal_set(p->vt, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES,
                       has_lines ? &lines : NULL);
  ghostty_terminal_set(p->vt, GHOSTTY_TERMINAL_OPT_APC_MAX_BYTES, &apc);
  ghostty_terminal_set(p->vt, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT,
                       &kitty);
  ghostty_terminal_set(p->vt, GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES,
                       &continuation);
  bool enabled = (media & 1) != 0;
  ghostty_terminal_set(p->vt, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_FILE,
                       &enabled);
  const char *tmp = getenv("TMPDIR");
  if (!tmp || !*tmp) {
    tmp = "/tmp";
  }
  GhosttyString tmpdir = {(const uint8_t *)tmp, strlen(tmp)};
  ghostty_terminal_set(p->vt, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_TEMP_FILE,
                       media & 2 ? &tmpdir : NULL);
  enabled = (media & 4) != 0;
  ghostty_terminal_set(
      p->vt, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_SHARED_MEM, &enabled);
  wire_vt(p);
  if (openpty(&p->master, &slave, NULL, NULL, &size) < 0) {
    goto done;
  }
  int started[2];
  if (pipe(started) < 0) {
    goto done;
  }
  fcntl(started[0], F_SETFD, FD_CLOEXEC);
  fcntl(started[1], F_SETFD, FD_CLOEXEC);
  p->pid = fork();
  if (p->pid == 0) {
    if (setsid() < 0 || ioctl(slave, TIOCSCTTY, 0) < 0 || dup2(slave, 0) < 0 ||
        dup2(slave, 1) < 0 || dup2(slave, 2) < 0 || chdir(cwd) < 0) {
      _exit(126);
    }
    close(slave);
    close(p->master);
    close(3);
    signal(SIGPIPE, SIG_DFL);
    signal(SIGHUP, SIG_DFL);
    signal(SIGINT, SIG_DFL);
    signal(SIGTERM, SIG_DFL);
    execve(argv[0], argv, env);
    _exit(127);
  }
  close(started[1]);
  if (p->pid < 0) {
    close(started[0]);
    goto done;
  }
  char byte;
  while (read(started[0], &byte, 1) < 0 && errno == EINTR) {
  }
  close(started[0]);
  fcntl(p->master, F_SETFL, O_NONBLOCK);
  fcntl(p->master, F_SETFD, FD_CLOEXEC);
  p->alive = 1;
  ko_compress_init(&p->compress, ko_now_ns());
  siginfo_t exited = {0};
  if (waitid(P_PID, p->pid, &exited, WEXITED | WNOHANG | WNOWAIT) < 0 ||
      exited.si_pid != p->pid) {
    uint8_t pid[4];
    ko_put(pid, p->pid, 4);
    frame(&p->output, KO_READY, pid, 4);
  }
  result = 0;
done:
  if (slave >= 0) {
    close(slave);
  }
  free(cwd);
  free(id);
  free_strings(argv);
  free_strings(env);
  return result;
}
static int control(struct pane *p, int snapshots);
static int wait_space(struct pane *p, size_t minimum) {
  while (available(p) < minimum && !p->stopping && !shutdown_requested) {
    announce_full(p);
    struct pollfd f = {0, POLLIN | (p->output.n ? POLLOUT : 0), 0};
    if (poll(&f, 1, -1) < 0) {
      if (errno == EINTR) {
        continue;
      }
      return -1;
    }
    if (flush(1, &p->output)) {
      return -1;
    }
    if (f.revents & (POLLIN | POLLHUP | POLLERR) && control(p, 0)) {
      return -1;
    }
  }
  return p->stopping || shutdown_requested ? -1 : 0;
}
struct slices {
  struct pane *p;
  size_t used, room;
  int first, screen;
};
static void slice_commit(struct slices *s) {
  if (!s->room) {
    return;
  }
  uint8_t *dst = at_head(s->p) + KO_HEADER;
  dst[0] = s->first ? 1 : 0;
  dst[1] = s->screen ? 1 : 0;
  s->first = 0;
  commit(s->p, KO_SNAPSHOT_SLICE, s->used + 2);
  s->used = s->room = 0;
}
static int slice_emit(void *ud, const uint8_t *b, size_t n) {
  struct slices *s = ud;
  while (n) {
    if (s->used == s->room) {
      slice_commit(s);
      if (wait_space(s->p, 3)) {
        return -1;
      }
      s->room = available(s->p) - 2;
    }
    size_t take = s->room - s->used;
    if (take > n) {
      take = n;
    }
    memcpy(at_head(s->p) + KO_HEADER + 2 + s->used, b, take);
    s->used += take;
    b += take;
    n -= take;
  }
  return 0;
}
static int snapshot(struct pane *p, const uint8_t *b, size_t n) {
  struct cursor c = {b, n, 0};
  uint32_t req = number(&c, 4);
  int screen = number(&c, 1), images = number(&c, 1);
  char *file = string(&c);
  if (c.error || c.n || !file || *file) {
    free(file);
    return -1;
  }
  free(file);
  struct ko_cut cut = {.screen = screen, .images = images};
  struct slices s = {.p = p, .first = 1, .screen = screen};
  if (ko_snapshot_encode(p->vt, &cut, slice_emit, &s) != GHOSTTY_SUCCESS) {
    return -1;
  }
  slice_commit(&s);
  if (wait_space(p, 2)) {
    return -1;
  }
  uint8_t *dst = at_head(p) + KO_HEADER;
  dst[0] = 2;
  dst[1] = screen ? 1 : 0;
  commit(p, KO_SNAPSHOT_SLICE, 2);
  uint8_t q[4];
  ko_put(q, req, 4);
  return frame(&p->output, KO_SNAPSHOT_DONE, q, 4);
}
static int shift_made_text(unsigned mods, unsigned unshifted,
                           const char *text, size_t n) {
  if (!(mods & GHOSTTY_MODS_SHIFT) ||
      (mods & (GHOSTTY_MODS_CTRL | GHOSTTY_MODS_ALT | GHOSTTY_MODS_SUPER)) ||
      !n) {
    return 0;
  }
  unsigned char c = (unsigned char)text[0];
  size_t len = c < 0x80 ? 1 : c < 0xe0 ? 2 : c < 0xf0 ? 3 : 4;
  if (len != n) {
    return 0;
  }
  unsigned cp = len == 1 ? c : c & (0xff >> (len + 1));
  for (size_t i = 1; i < len; i++) {
    cp = cp << 6 | ((unsigned char)text[i] & 0x3f);
  }
  return cp != unshifted && cp >= 0x20 && cp != 0x7f;
}
static int encoded_input(struct pane *p, unsigned kind, const uint8_t *b,
                         size_t n) {
  struct cursor c = {b, n, 0};
  size_t written = 0;
  GhosttyResult r = GHOSTTY_SUCCESS;
  char *out = NULL;
  if (kind == KO_KEY) {
    unsigned action = number(&c, 1), key = number(&c, 2), mods = number(&c, 2),
             codepoint = number(&c, 4);
    size_t text_len = 0;
    char *text = blob(&c, &text_len);
    unsigned composing = number(&c, 1);
    if (c.error || c.n || action > 2 || key > GHOSTTY_KEY_PASTE ||
        composing > 1 || codepoint > 0x10ffff ||
        (codepoint >= 0xd800 && codepoint <= 0xdfff)) {
      free(text);
      return -1;
    }
    GhosttyKeyEncoder encoder = NULL;
    GhosttyKeyEvent event = NULL;
    r = ghostty_key_encoder_new(NULL, &encoder);
    if (r == GHOSTTY_SUCCESS) {
      r = ghostty_key_event_new(NULL, &event);
    }
    if (r == GHOSTTY_SUCCESS) {
      ghostty_key_encoder_setopt_from_terminal(encoder, p->vt);
      GhosttyOptionAsAlt option_as_alt = GHOSTTY_OPTION_AS_ALT_TRUE;
      ghostty_key_encoder_setopt(
          encoder, GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, &option_as_alt);
      ghostty_key_event_set_action(event, action);
      ghostty_key_event_set_key(event, key);
      ghostty_key_event_set_mods(event, mods);
      ghostty_key_event_set_consumed_mods(
          event, shift_made_text(mods, codepoint, text, text_len)
                     ? GHOSTTY_MODS_SHIFT
                     : 0);
      ghostty_key_event_set_unshifted_codepoint(event, codepoint);
      ghostty_key_event_set_utf8(event, text, text_len);
      ghostty_key_event_set_composing(event, composing);
      r = ghostty_key_encoder_encode(encoder, event, NULL, 0, &written);
      if (r == GHOSTTY_OUT_OF_SPACE) {
        out = malloc(written);
        if (!out) {
          r = GHOSTTY_OUT_OF_MEMORY;
        } else {
          r = ghostty_key_encoder_encode(encoder, event, out, written,
                                         &written);
        }
      }
    }
    ghostty_key_event_free(event);
    ghostty_key_encoder_free(encoder);
    free(text);
  } else {
    unsigned action = number(&c, 1), button = number(&c, 1),
             col = number(&c, 2), row = number(&c, 2), mods = number(&c, 2);
    if (c.error || c.n || action > 2 || button > 11) {
      return -1;
    }
    GhosttyMouseEncoder encoder = NULL;
    GhosttyMouseEvent event = NULL;
    r = ghostty_mouse_encoder_new(NULL, &encoder);
    if (r == GHOSTTY_SUCCESS) {
      r = ghostty_mouse_event_new(NULL, &event);
    }
    if (r == GHOSTTY_SUCCESS) {
      ghostty_mouse_encoder_setopt_from_terminal(encoder, p->vt);
      uint16_t cols = 0, rows = 0;
      ghostty_terminal_get(p->vt, GHOSTTY_TERMINAL_DATA_COLS, &cols);
      ghostty_terminal_get(p->vt, GHOSTTY_TERMINAL_DATA_ROWS, &rows);
      GhosttyMouseEncoderSize size = {.size = sizeof(size),
                                      .screen_width = cols,
                                      .screen_height = rows,
                                      .cell_width = 1,
                                      .cell_height = 1};
      ghostty_mouse_encoder_setopt(encoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE,
                                   &size);
      bool pressed = button != GHOSTTY_MOUSE_BUTTON_UNKNOWN &&
                     action != GHOSTTY_MOUSE_ACTION_RELEASE;
      ghostty_mouse_encoder_setopt(
          encoder, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &pressed);
      ghostty_mouse_event_set_action(event, action);
      ghostty_mouse_event_set_button(event, button);
      ghostty_mouse_event_set_mods(event, mods);
      ghostty_mouse_event_set_position(event, (GhosttyMousePosition){col, row});
      r = ghostty_mouse_encoder_encode(encoder, event, NULL, 0, &written);
      if (r == GHOSTTY_OUT_OF_SPACE) {
        out = malloc(written);
        if (!out) {
          r = GHOSTTY_OUT_OF_MEMORY;
        } else {
          r = ghostty_mouse_encoder_encode(encoder, event, out, written,
                                           &written);
        }
      }
    }
    ghostty_mouse_event_free(event);
    ghostty_mouse_encoder_free(encoder);
  }
  int failed = r != GHOSTTY_SUCCESS || ko_append(&p->pty_input, out, written);
  free(out);
  return failed;
}
struct pasted_text {
  const char *p;
  size_t n;
};
static bool paste_read(void *ud, GhosttyString mime, GhosttyWriter writer) {
  (void)mime;
  struct pasted_text *text = ud;
  return writer.write(writer.userdata, (const uint8_t *)text->p, text->n);
}
struct screen_output {
  struct pane *pane;
  uint32_t req;
  uint8_t bytes[65536];
  size_t used;
};
static int screen_chunk(struct screen_output *s, int last) {
  uint8_t header[14];
  ko_put(header, s->used + 10, 4);
  header[4] = KO_SCREEN;
  ko_put(header + 5, s->req, 4);
  header[9] = last;
  ko_put(header + 10, s->used, 4);
  struct pane *p = s->pane;
  if (ko_append(&p->output, header, sizeof(header)) ||
      ko_append(&p->output, s->bytes, s->used)) {
    return -1;
  }
  s->used = 0;
  while (p->output.n && !p->stopping && !shutdown_requested) {
    if (flush(1, &p->output)) {
      return -1;
    }
    if (p->output.n) {
      struct pollfd f = {1, POLLOUT, 0};
      int ready = poll(&f, 1, 5000);
      if (ready < 0 && errno == EINTR) {
        continue;
      }
      if (ready <= 0) {
        return -1;
      }
    }
  }
  return p->stopping || shutdown_requested ? -1 : 0;
}
static bool screen_write(void *ud, const uint8_t *bytes, size_t n) {
  struct screen_output *s = ud;
  while (n) {
    size_t take = sizeof(s->bytes) - s->used;
    if (take > n) {
      take = n;
    }
    memcpy(s->bytes + s->used, bytes, take);
    s->used += take;
    bytes += take;
    n -= take;
    if (s->used == sizeof(s->bytes) && screen_chunk(s, 0)) {
      return false;
    }
  }
  return true;
}
static int screen(struct pane *p, const uint8_t *b, size_t n) {
  if (n != 9) {
    return -1;
  }
  uint32_t req = ko_get(b, 4), history = ko_get(b + 5, 4);
  GhosttyFormatterTerminalOptions options = {
      .size = sizeof(options),
      .emit =
          b[4] ? GHOSTTY_FORMATTER_FORMAT_VT : GHOSTTY_FORMATTER_FORMAT_PLAIN,
      .trim = true};
  options.extra.size = sizeof(options.extra);
  options.extra.screen.size = sizeof(options.extra.screen);
  GhosttySelection selection = {.size = sizeof(selection)};
  uint16_t cols = 0, rows = 0;
  size_t total = 0;
  ghostty_terminal_get(p->vt, GHOSTTY_TERMINAL_DATA_COLS, &cols);
  ghostty_terminal_get(p->vt, GHOSTTY_TERMINAL_DATA_ROWS, &rows);
  ghostty_terminal_get(p->vt, GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, &total);
  size_t start = total > rows ? total - rows : 0;
  start = history > start ? 0 : start - history;
  if (ghostty_terminal_grid_ref(p->vt,
                                (GhosttyPoint){.tag = GHOSTTY_POINT_TAG_SCREEN,
                                               .value.coordinate = {0, start}},
                                &selection.start) != GHOSTTY_SUCCESS) {
    return -1;
  }
  if (ghostty_terminal_grid_ref(
          p->vt,
          (GhosttyPoint){.tag = GHOSTTY_POINT_TAG_SCREEN,
                         .value.coordinate = {cols - 1, total - 1}},
          &selection.end) != GHOSTTY_SUCCESS) {
    return -1;
  }
  options.selection = &selection;
  GhosttyFormatter formatter = NULL;
  struct screen_output output = {.pane = p, .req = req};
  GhosttyResult r =
      ghostty_formatter_terminal_new(NULL, &formatter, p->vt, options);
  if (r == GHOSTTY_SUCCESS) {
    r = ghostty_formatter_format(formatter,
                                 (GhosttyWriter){screen_write, &output});
  }
  ghostty_formatter_free(formatter);
  if (r != GHOSTTY_SUCCESS) {
    return -1;
  }
  return screen_chunk(&output, 1);
}

static int dispatch(struct pane *p, unsigned kind, const uint8_t *b, size_t n,
                    int snapshots) {
  if (!p->vt) {
    return kind == KO_INIT ? init(p, b, n) : -1;
  }
  switch (kind) {
  case KO_TAIL:
    if (n != 8) {
      return -1;
    }
    p->full = 0;
    return 0;
  case KO_TEXT:
    return ko_append(&p->pty_input, b, n);
  case KO_KEY:
  case KO_MOUSE:
    return encoded_input(p, kind, b, n);
  case KO_FOCUS: {
    if (n != 1 || b[0] > 1) {
      return -1;
    }
    GhosttyTerminalModeConfig mode = {.mode = 1004};
    if (ghostty_terminal_get(p->vt, GHOSTTY_TERMINAL_DATA_MODE, &mode) !=
        GHOSTTY_SUCCESS) {
      return -1;
    }
    if (mode.value) {
      char out[3];
      size_t written = 0;
      ghostty_focus_encode(b[0] ? GHOSTTY_FOCUS_GAINED : GHOSTTY_FOCUS_LOST,
                           out, sizeof(out), &written);
      return ko_append(&p->pty_input, out, written);
    }
    return 0;
  }
  case KO_PASTE: {
    struct cursor c = {b, n, 0};
    uint32_t id = number(&c, 4);
    size_t text_len = 0;
    char *text = blob(&c, &text_len);
    unsigned check = number(&c, 1);
    if (c.error || c.n || check > 1) {
      free(text);
      return -1;
    }
    struct pasted_text data = {text, text_len};
    GhosttyString mime = {(const uint8_t *)"text/plain", 10};
    GhosttyPaste paste = {.size = sizeof(paste),
                          .source = GHOSTTY_PASTE_SOURCE_TEXT,
                          .mimes = &mime,
                          .mimes_len = 1,
                          .reader = {paste_read, &data},
                          .allow_unsafe = !check};
    bool pasted = false;
    GhosttyResult r = ghostty_terminal_paste(p->vt, &paste, &pasted);
    free(text);
    uint8_t result[6];
    ko_put(result, id, 4);
    result[4] = pasted;
    result[5] = r == GHOSTTY_REJECTED;
    if (r != GHOSTTY_SUCCESS && r != GHOSTTY_REJECTED) {
      return -1;
    }
    return frame(&p->output, KO_PASTE_DONE, result, 6);
  }
  case KO_SCREEN:
    return screen(p, b, n);
  case KO_RESIZE: {
    if (n != 8 || !ko_get(b, 2) || !ko_get(b + 2, 2) ||
        ko_get(b, 2) > KO_MAX_DIMENSION || ko_get(b + 2, 2) > KO_MAX_DIMENSION) {
      return -1;
    }
    uint16_t cols = ko_get(b, 2), rows = ko_get(b + 2, 2),
             cw = ko_get(b + 4, 2), ch = ko_get(b + 6, 2);
    if (wait_space(p, 9)) {
      return -1;
    }
    if (ghostty_terminal_resize(p->vt, cols, rows, cw, ch) != GHOSTTY_SUCCESS) {
      return -1;
    }
    struct winsize size = {.ws_row = rows,
                           .ws_col = cols,
                           .ws_xpixel = ko_pixels(cols, cw),
                           .ws_ypixel = ko_pixels(rows, ch)};
    ioctl(p->master, TIOCSWINSZ, &size);
    uint8_t *marker = at_head(p) + KO_HEADER;
    marker[0] = 1;
    ko_put(marker + 1, cols, 2);
    ko_put(marker + 3, rows, 2);
    ko_put(marker + 5, cw, 2);
    ko_put(marker + 7, ch, 2);
    commit(p, KO_MARKER, 9);
    return 0;
  }
  case KO_SNAPSHOT:
    return snapshots ? snapshot(p, b, n) : -1;
  case KO_EXIT:
    p->stopping = 1;
    return 0;
  default:
    return -1;
  }
}
static int run_deferred(struct pane *p) {
  struct ko_buffer pending = p->deferred;
  p->deferred = (struct ko_buffer){0};
  int r = 0;
  for (size_t pos = 0; !r && pos < pending.n;) {
    size_t size = ko_get(pending.p + pos, 4) + 4;
    r = dispatch(p, pending.p[pos + 4], pending.p + pos + 5, size - 5, 1);
    pos += size;
  }
  free(pending.p);
  return r;
}
static int control(struct pane *p, int snapshots) {
  int eof = 0;
  for (;;) {
    if (p->input.n - p->input.pos >= KO_MAX_FRAME + 4 ||
        ko_reserve(&p->input, 65536)) {
      return -1;
    }
    ssize_t n = read(0, p->input.p + p->input.n, p->input.cap - p->input.n);
    if (n > 0) {
      p->input.n += (size_t)n;
    } else if (n == 0) {
      eof = 1;
      break;
    } else if (errno == EINTR) {
      continue;
    } else if (errno == EAGAIN || errno == EWOULDBLOCK) {
      break;
    } else {
      return -1;
    }
  }
  p->depth++;
  int failed = 0;
  while (!failed && p->input.n - p->input.pos >= 4) {
    size_t size;
    int complete = ko_frame_size(p->input.p + p->input.pos,
                                 p->input.n - p->input.pos, &size);
    if (complete < 0) {
      failed = 1;
      break;
    }
    if (!complete) {
      break;
    }
    size_t at = p->input.pos;
    p->input.pos += size;
    unsigned kind = p->input.p[at + 4];
    if (!snapshots && kind != KO_TAIL && kind != KO_EXIT) {
      failed = ko_append(&p->deferred, p->input.p + at, size);
    } else {
      failed = dispatch(p, kind, p->input.p + at + 5, size - 5, snapshots);
    }
    if (failed && p->vt) {
      const char *message = "invalid control frame";
      struct ko_buffer error = {0};
      uint8_t length[4];
      ko_put(length, strlen(message), 4);
      failed = ko_append(&error, length, 4) ||
               ko_append(&error, message, strlen(message)) ||
               frame(&p->output, KO_ERROR, error.p, error.n);
      free(error.p);
    }
  }
  if (--p->depth == 0) {
    memmove(p->input.p, p->input.p + p->input.pos, p->input.n - p->input.pos);
    p->input.n -= p->input.pos;
    p->input.pos = 0;
  }
  while (!failed && snapshots && p->deferred.n) {
    failed = run_deferred(p);
  }
  if (failed) {
    return -1;
  }
  if (eof) {
    p->stopping = 1;
  }
  return 0;
}
static int read_pty(struct pane *p) {
  size_t room = available(p), used = 0;
  if (!room) {
    announce_full(p);
    return 0;
  }
  uint8_t *dst = at_head(p) + KO_HEADER;
  while (used < room) {
    ssize_t got = read(p->master, dst + used, room - used);
    if (got > 0) {
      used += (size_t)got;
    } else if (got < 0 && errno == EINTR) {
      continue;
    } else {
      if (got == 0 || (got < 0 && errno == EIO)) {
        p->eof = 1;
      }
      break;
    }
  }
  if (used) {
    ghostty_terminal_vt_write(p->vt, dst, used);
    commit(p, KO_BYTES, used);
  }
  return used > 0;
}
int main(void) {
  signal(SIGPIPE, SIG_IGN);
  struct stat st;
  if (fstat(3, &st) || st.st_size <= 0) {
    return 2;
  }
  struct pane p = {.master = -1};
  p.ring = mmap(NULL, st.st_size, PROT_READ | PROT_WRITE, MAP_SHARED, 3, 0);
  if (p.ring == MAP_FAILED || ko_ring_attach(p.ring, st.st_size, &p.view)) {
    return 2;
  }
  if (pipe(sigchld)) {
    return 2;
  }
  for (int i = 0; i < 2; i++) {
    fcntl(sigchld[i], F_SETFL, O_NONBLOCK);
    fcntl(sigchld[i], F_SETFD, FD_CLOEXEC);
  }
  struct sigaction action = {.sa_handler = on_sigchld,
                             .sa_flags = SA_RESTART | SA_NOCLDSTOP};
  sigemptyset(&action.sa_mask);
  if (sigaction(SIGCHLD, &action, NULL)) {
    return 2;
  }
  fcntl(0, F_SETFL, O_NONBLOCK);
  fcntl(1, F_SETFL, O_NONBLOCK);
  signal(SIGHUP, on_shutdown);
  signal(SIGTERM, on_shutdown);
  int failure = 0, timeout = -1;
  while (!p.stopping && !shutdown_requested) {
    int reading = p.vt && !p.eof && !p.full, committed = 0;
    struct pollfd f[3] = {
        {0, POLLIN | (p.output.n ? POLLOUT : 0), 0},
        {reading || p.pty_input.n ? p.master : -1,
         (reading ? POLLIN : 0) | (p.pty_input.n ? POLLOUT : 0), 0},
        {sigchld[0], POLLIN, 0}};
    int ready = poll(f, 3, timeout);
    if (ready < 0) {
      if (errno == EINTR) {
        continue;
      }
      failure = 1;
      break;
    }
    if (f[0].revents & (POLLIN | POLLHUP | POLLERR) && control(&p, 1)) {
      fprintf(stderr, "pane control failed\n");
      failure = 1;
      break;
    }
    if (p.master >= 0 && flush(p.master, &p.pty_input)) {
      p.pty_input.n = p.pty_input.pos = 0;
    }
    if (f[2].revents & POLLIN) {
      char drain[64];
      while (read(sigchld[0], drain, sizeof(drain)) > 0) {
      }
      siginfo_t info = {0};
      if (p.alive && !p.reaped &&
          waitid(P_PID, p.pid, &info, WEXITED | WNOHANG | WNOWAIT) == 0 &&
          info.si_pid == p.pid) {
        p.reaped = 1;
        p.code = info.si_code == CLD_EXITED ? info.si_status : 0;
        p.termsig = info.si_code == CLD_EXITED ? 0 : info.si_status;
      }
    }
    if (p.vt && !p.eof &&
        (f[1].revents & (POLLIN | POLLHUP | POLLERR) || p.reaped)) {
      committed = read_pty(&p);
    }
    if (p.reaped && p.eof) {
      uint8_t b[16];
      ko_put(b, p.code, 4);
      ko_put(b + 4, p.termsig, 4);
      ko_put(b + 8, ko_now_ns(), 8);
      if (wait_space(&p, 17)) {
        failure = 1;
        break;
      }
      uint8_t *marker = at_head(&p) + KO_HEADER;
      marker[0] = 2;
      memcpy(marker + 1, b, 16);
      commit(&p, KO_MARKER, 17);
      p.alive = 0;
      p.reaped = 0;
      frame(&p.output, KO_DEAD, b, 16);
    }
    if (flush(1, &p.output)) {
      failure = 1;
      break;
    }
    timeout = p.vt && (ready == 0 || committed || f[0].revents || p.compress.pending)
                  ? ko_compress_tick(&p.compress, p.vt, ko_now_ns())
                  : -1;
  }
  if (p.pid > 1) {
    struct group group = group_of(p.pid);
    if (p.alive && !p.reaped) {
      group_signal(group, SIGHUP);
      struct timespec start, now;
      clock_gettime(CLOCK_MONOTONIC, &start);
      for (;;) {
        siginfo_t info = {0};
        if (waitid(P_PID, p.pid, &info, WEXITED | WNOHANG | WNOWAIT) == 0 &&
            info.si_pid == p.pid) {
          break;
        }
        clock_gettime(CLOCK_MONOTONIC, &now);
        if ((now.tv_sec - start.tv_sec) * 1000000000L + now.tv_nsec -
                start.tv_nsec >=
            250000000L) {
          break;
        }
        poll(NULL, 0, 5);
      }
    }
    group_signal(group, SIGKILL);
    waitpid(p.pid, NULL, 0);
  }
  if (p.master >= 0) {
    close(p.master);
  }
  if (p.vt) {
    ghostty_terminal_free(p.vt);
  }
  munmap(p.ring, st.st_size);
  free(p.input.p);
  free(p.output.p);
  free(p.pty_input.p);
  free(p.events.p);
  free(p.deferred.p);
  return failure ? 2 : 0;
}
