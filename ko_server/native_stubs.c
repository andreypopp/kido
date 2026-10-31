#define _DARWIN_C_SOURCE
#define _GNU_SOURCE
#include <caml/alloc.h>
#include <caml/bigarray.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/signals.h>
#include <caml/unixsupport.h>
#include <signal.h>
extern int caml_convert_signal_number(int);
#include <sys/socket.h>
#include <sys/uio.h>
#include <sys/wait.h>
#ifdef __APPLE__
#include <sys/ucred.h>
#include <sys/un.h>
#endif
#include "../ko_pane/now.h"
#include "../ko_pane/ring.h"
#include <ghostty/vt/key/event.h>
#include <stdlib.h>
#include <string.h>

CAMLprim value ko_pane_layout(value unit) {
  CAMLparam1(unit);
  CAMLlocal2(result, kinds);
  int frames[] = {KO_INIT,  KO_TAIL,          KO_RESIZE, KO_TEXT,  KO_SNAPSHOT,
                  KO_EXIT,  KO_READY,         KO_HEAD,   KO_TITLE, KO_PWD,
                  KO_DEAD,  KO_SNAPSHOT_DONE, KO_ERROR,  KO_FULL,  KO_KEY,
                  KO_PASTE, KO_PASTE_DONE,    KO_MOUSE,  KO_FOCUS, KO_SCREEN,
                  KO_SIGNAL};
  size_t count = sizeof(frames) / sizeof(frames[0]);
  kinds = caml_alloc(count, 0);
  for (size_t i = 0; i < count; i++) {
    Store_field(kinds, i, Val_int(frames[i]));
  }
  result = caml_alloc_tuple(9);
  Store_field(result, 0, Val_int(offsetof(struct ko_ring, data)));
  Store_field(result, 1, Val_int(KO_HEADER));
  Store_field(result, 2, Val_int(KO_MAX_FRAME));
  Store_field(result, 3, Val_int(GHOSTTY_KEY_PASTE));
  Store_field(result, 4, kinds);
  Store_field(result, 5, Val_int(KO_BYTES));
  Store_field(result, 6, Val_int(KO_MARKER));
  Store_field(result, 7, Val_int(KO_SNAPSHOT_SLICE));
  Store_field(result, 8, Val_int(KO_PAD));
  CAMLreturn(result);
}
CAMLprim value ko_pane_start(value path, value callbacks) {
  CAMLparam2(path, callbacks);
  CAMLlocal2(result, mapping);
  size_t capacity = 1024 * 1024, size = sizeof(struct ko_ring) + capacity;
  struct ko_ring *ring = NULL;
  int fd = ko_ring_create(capacity, &ring);
  if (fd < 0) {
    caml_uerror("create_ring", Nothing);
  }
  int sockets[2];
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, sockets)) {
    int error = errno;
    munmap(ring, size);
    close(fd);
    errno = error;
    caml_uerror("socketpair", Nothing);
  }
  fcntl(sockets[0], F_SETFD, FD_CLOEXEC);
  fcntl(sockets[1], F_SETFD, FD_CLOEXEC);
  char *program = strdup(String_val(path));
  if (!program) {
    munmap(ring, size);
    close(fd);
    close(sockets[0]);
    close(sockets[1]);
    caml_raise_out_of_memory();
  }
  pid_t pid = fork();
  if (pid == 0) {
    if (fd != 3 && dup2(fd, 3) < 0) {
      _exit(126);
    }
    if (dup2(sockets[1], 0) < 0 || dup2(sockets[1], 1) < 0 ||
        fcntl(3, F_SETFD, 0) < 0) {
      _exit(126);
    }
    for (int i = 4; i < 256; i++) {
      close(i);
    }
    char *args[] = {program, Bool_val(callbacks) ? NULL : "--no-callbacks",
                    NULL};
    extern char **environ;
    execve(program, args, environ);
    _exit(127);
  }
  int error = errno;
  free(program);
  close(fd);
  close(sockets[1]);
  if (pid < 0) {
    munmap(ring, size);
    close(sockets[0]);
    errno = error;
    caml_uerror("fork", Nothing);
  }
  mapping =
      caml_ba_alloc_dims(CAML_BA_CHAR | CAML_BA_C_LAYOUT | CAML_BA_EXTERNAL, 1,
                         ring, (intnat)size);
  result = caml_alloc_tuple(3);
  Store_field(result, 0, mapping);
  Store_field(result, 1, Val_int(sockets[0]));
  Store_field(result, 2, Val_int(pid));
  CAMLreturn(result);
}
CAMLprim value ko_pane_unmap(value mapping) {
  munmap(Caml_ba_data_val(mapping), Caml_ba_array_val(mapping)->dim[0]);
  return Val_unit;
}
CAMLprim value ko_pane_ring_head(value mapping) {
  struct ko_ring *ring = Caml_ba_data_val(mapping);
  return Val_long(atomic_load(&ring->head));
}
CAMLprim value ko_pane_ring_set_tail(value mapping, value tail) {
  struct ko_ring *ring = Caml_ba_data_val(mapping);
  atomic_store(&ring->tail, Long_val(tail));
  return Val_unit;
}
CAMLprim value ko_pane_ring_set_read(value mapping, value read) {
  struct ko_ring *ring = Caml_ba_data_val(mapping);
  atomic_store(&ring->read, Long_val(read));
  return Val_unit;
}
CAMLprim value ko_writev(value fd, value header, value header_len,
                         value mapping, value offset, value length) {
  struct iovec iov[2] = {
      {(void *)Bytes_val(header), Long_val(header_len)},
      {(char *)Caml_ba_data_val(mapping) + Long_val(offset), Long_val(length)}};
  ssize_t n;
  do {
    n = writev(Int_val(fd), iov, 2);
  } while (n < 0 && errno == EINTR);
  return Val_long(n < 0 ? (errno == EAGAIN || errno == EWOULDBLOCK ? 0 : -errno)
                        : n);
}
CAMLprim value ko_writev_bytecode(value *argv, int argc) {
  (void)argc;
  return ko_writev(argv[0], argv[1], argv[2], argv[3], argv[4], argv[5]);
}
CAMLprim value ko_write_strings(value fd, value strings, value count,
                                value offset) {
  struct iovec iov[64];
  for (int i = 0; i < Int_val(count); i++) {
    value s = Field(strings, i);
    size_t skip = i == 0 ? Long_val(offset) : 0;
    iov[i] = (struct iovec){(void *)(String_val(s) + skip),
                            caml_string_length(s) - skip};
  }
  ssize_t n;
  do {
    n = writev(Int_val(fd), iov, Int_val(count));
  } while (n < 0 && errno == EINTR);
  return Val_long(n < 0 ? (errno == EAGAIN || errno == EWOULDBLOCK ? 0 : -errno)
                        : n);
}
CAMLprim value ko_peer_uid(value descriptor) {
  int fd = Int_val(descriptor);
#ifdef __APPLE__
  struct xucred cr;
  socklen_t len = sizeof(cr);
  if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &cr, &len)) {
    caml_uerror("getsockopt", Nothing);
  }
  if (cr.cr_version != XUCRED_VERSION) {
    caml_unix_error(EPROTO, "getsockopt", Nothing);
  }
  return Val_int(cr.cr_uid);
#else
  struct ucred cr;
  socklen_t len = sizeof(cr);
  if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cr, &len)) {
    caml_uerror("getsockopt", Nothing);
  }
  return Val_int(cr.uid);
#endif
}
CAMLprim value ko_peer_pid(value descriptor) {
  int fd = Int_val(descriptor);
#ifdef __APPLE__
  pid_t pid;
  socklen_t len = sizeof(pid);
  if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len)) {
    caml_uerror("getsockopt", Nothing);
  }
  return Val_int(pid);
#else
  struct ucred cr;
  socklen_t len = sizeof(cr);
  if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cr, &len)) {
    caml_uerror("getsockopt", Nothing);
  }
  return Val_int(cr.pid);
#endif
}
CAMLprim value ko_sigchld(value unit) {
  (void)unit;
  return Val_int(SIGCHLD);
}
CAMLprim value ko_now(value unit) {
  (void)unit;
  return Val_long(ko_now_ns());
}
CAMLprim value ko_native_signal(value signo) {
  return Val_int(caml_convert_signal_number(Int_val(signo)));
}
