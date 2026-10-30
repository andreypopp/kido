#define _DARWIN_C_SOURCE
#define _GNU_SOURCE
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/alloc.h>
#include <caml/bigarray.h>
#include <caml/fail.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <sys/wait.h>
#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#endif
#include <unistd.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <string.h>
#include "../ko_pane/protocol.h"
#include "../ko_pane/now.h"
#include "../bench/cpu.h"

#define VIEW_HEADER_MAX 20

static struct ko_ring *ring_of(value mapping) { return Caml_ba_data_val(mapping); }

CAMLprim value ko_spike_layout(value unit) {
  CAMLparam1(unit); CAMLlocal1(layout);
  intnat fields[] = {offsetof(struct ko_ring, data), KO_HEADER, VIEW_HEADER_MAX,
    KO_BYTES, KO_SNAPSHOT_SLICE, KO_PAD,
    KO_INIT, KO_TAIL, KO_RESIZE, KO_SNAPSHOT, KO_EXIT, KO_READY, KO_DEAD,
    KO_SNAPSHOT_DONE, KO_FULL};
  size_t count = sizeof(fields) / sizeof(fields[0]);
  layout = caml_alloc_tuple(count);
  for (size_t i = 0; i < count; i++) Store_field(layout, i, Val_long(fields[i]));
  CAMLreturn(layout);
}

CAMLprim value ko_spike_start(value path, value callbacks) {
  CAMLparam2(path, callbacks); CAMLlocal2(result, mapping);
  size_t capacity = 1024 * 1024, size = sizeof(struct ko_ring) + capacity;
  int fd;
#ifdef __APPLE__
  char name[64];
  snprintf(name, sizeof(name), "/ko-spike-%d", getpid());
  fd = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
  if (fd >= 0) shm_unlink(name);
#else
  fd = memfd_create("ko-spike", MFD_CLOEXEC);
#endif
  if (fd < 0) caml_failwith("create ring");
  if (ftruncate(fd, size)) { close(fd); caml_failwith("size ring"); }
  struct ko_ring *ring = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  if (ring == MAP_FAILED) { close(fd); caml_failwith("map ring"); }
  ring->capacity = capacity;
  atomic_init(&ring->head, 0);
  atomic_init(&ring->tail, 0);
  int sockets[2];
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, sockets)) { munmap(ring, size); close(fd); caml_failwith("socketpair"); }
  char *program = strdup(String_val(path));
  if (!program) { munmap(ring, size); close(fd); close(sockets[0]); close(sockets[1]); caml_raise_out_of_memory(); }
  pid_t pid = fork();
  if (pid == 0) {
    if (fd != 3 && dup2(fd, 3) < 0) _exit(126);
    if (dup2(sockets[1], 0) < 0 || dup2(sockets[1], 1) < 0 || fcntl(3, F_SETFD, 0) < 0) _exit(126);
    for (int i = 4; i < 256; i++) close(i);
    char *args[] = {program, Bool_val(callbacks) ? NULL : "--no-callbacks", NULL};
    extern char **environ;
    execve(program, args, environ);
    _exit(127);
  }
  free(program);
  close(fd);
  close(sockets[1]);
  if (pid < 0) { munmap(ring, size); close(sockets[0]); caml_failwith("fork pane"); }
  fcntl(sockets[0], F_SETFD, FD_CLOEXEC);
  mapping = caml_ba_alloc_dims(CAML_BA_CHAR | CAML_BA_C_LAYOUT | CAML_BA_EXTERNAL, 1, ring, (intnat)size);
  result = caml_alloc_tuple(3);
  Store_field(result, 0, mapping);
  Store_field(result, 1, Val_int(sockets[0]));
  Store_field(result, 2, Val_int(pid));
  CAMLreturn(result);
}

CAMLprim value ko_spike_unmap(value mapping) {
  munmap(Caml_ba_data_val(mapping), Caml_ba_array_val(mapping)->dim[0]);
  return Val_unit;
}

CAMLprim value ko_spike_ring_head(value mapping) { return Val_long(atomic_load(&ring_of(mapping)->head)); }

CAMLprim value ko_spike_ring_set_tail(value mapping, value tail) {
  atomic_store(&ring_of(mapping)->tail, (uint64_t)Long_val(tail));
  return Val_unit;
}

static size_t view_header(uint8_t *out, const uint8_t *record) {
  uint64_t len = ko_get(record + 1, 4) + 9;
  size_t n;
  out[0] = 0x82;
  if (len < 126) { out[1] = (uint8_t)len; n = 2; }
  else if (len < 65536) { out[1] = 126; out[2] = (uint8_t)(len >> 8); out[3] = (uint8_t)len; n = 4; }
  else { out[1] = 127; for (int i = 0; i < 8; i++) out[2 + i] = (uint8_t)(len >> (56 - 8 * i)); n = 10; }
  out[n] = record[0];
  memcpy(out + n + 1, record + 5, 8);
  return n + 9;
}

CAMLprim value ko_spike_view_header(value area, value slot, value mapping, value index) {
  return Val_long(view_header((uint8_t *)Caml_ba_data_val(area) + Long_val(slot) * VIEW_HEADER_MAX,
                              (uint8_t *)Caml_ba_data_val(mapping) + Long_val(index)));
}

/* state: [| ring position of the next record; bytes of it already written; records; payload bytes |] */
CAMLprim value ko_spike_view_writev(value fd, value mapping, value state, value head_value) {
  struct ko_ring *ring = ring_of(mapping);
  int64_t *s = Caml_ba_data_val(state);
  uint64_t head = (uint64_t)Long_val(head_value);
  uint8_t headers[64][VIEW_HEADER_MAX];
  struct iovec iov[128];
  while ((uint64_t)s[0] < head) {
    int count = 0, records = 0;
    uint64_t pos = (uint64_t)s[0];
    size_t skip = (size_t)s[1];
    while (pos < head && records < 64) {
      uint8_t *record = ring->data + pos % ring->capacity;
      size_t len = ko_get(record + 1, 4);
      if (record[0] == KO_PAD) {
        if (records == 0) { s[0] = (int64_t)(pos + KO_HEADER + len); s[1] = 0; skip = 0; }
        pos += KO_HEADER + len;
        if (records) break;
        continue;
      }
      size_t h = view_header(headers[records], record);
      struct iovec parts[2] = {{headers[records], h}, {record + KO_HEADER, len}};
      for (int i = 0; i < 2; i++) {
        if (skip >= parts[i].iov_len) { skip -= parts[i].iov_len; continue; }
        iov[count].iov_base = (uint8_t *)parts[i].iov_base + skip;
        iov[count].iov_len = parts[i].iov_len - skip;
        skip = 0;
        count++;
      }
      records++;
      pos += KO_HEADER + len;
    }
    if (!count) continue;
    ssize_t n = writev(Int_val(fd), iov, count);
    if (n < 0) {
      if (errno == EINTR) continue;
      return Val_long(errno == EAGAIN || errno == EWOULDBLOCK ? 1 : -errno);
    }
    size_t written = (size_t)n + (size_t)s[1];
    pos = (uint64_t)s[0];
    while (pos < head) {
      uint8_t *record = ring->data + pos % ring->capacity;
      size_t len = ko_get(record + 1, 4);
      if (record[0] == KO_PAD) { pos += KO_HEADER + len; continue; }
      uint8_t scratch[VIEW_HEADER_MAX];
      size_t framed = view_header(scratch, record) + len;
      if (written < framed) break;
      written -= framed;
      pos += KO_HEADER + len;
      s[2]++;
      if (record[0] == KO_BYTES) s[3] += (int64_t)len;
    }
    s[0] = (int64_t)pos;
    s[1] = (int64_t)written;
  }
  return Val_long(0);
}

CAMLprim value ko_spike_pty(value unit) {
  CAMLparam1(unit); CAMLlocal1(pair);
  int master, slave;
  if (openpty(&master, &slave, NULL, NULL, NULL)) caml_failwith("openpty");
  pair = caml_alloc_tuple(2);
  Store_field(pair, 0, Val_int(master));
  Store_field(pair, 1, Val_int(slave));
  CAMLreturn(pair);
}

CAMLprim value ko_spike_now_ns(value unit) { (void)unit; return Val_long(ko_now_ns()); }

CAMLprim value ko_spike_cpu_seconds(value pid) {
  CAMLparam1(pid); CAMLlocal1(pair);
  pair = caml_alloc_tuple(2);
  Store_field(pair, 0, caml_copy_double(ko_cpu_raw_ns_seconds(Int_val(pid))));
  Store_field(pair, 1, caml_copy_double(ko_cpu_seconds(Int_val(pid))));
  CAMLreturn(pair);
}
