#define _GNU_SOURCE
#include <errno.h>
#include <sys/socket.h>
#include <sys/types.h>
#ifdef __APPLE__
#include <sys/un.h>
#include <sys/ucred.h>
#endif
#include <caml/mlvalues.h>
#include <caml/unixsupport.h>

value ko_spike_peer_uid(value storage)
{
  int fd = *(int *)Nativeint_val(storage);
#ifdef __APPLE__
  struct xucred cr;
  socklen_t len = sizeof cr;
  if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &cr, &len) != 0) caml_uerror("getsockopt", Nothing);
  if (cr.cr_version != XUCRED_VERSION) caml_unix_error(EPROTO, "getsockopt", Nothing);
  return Val_int(cr.cr_uid);
#else
  struct ucred cr;
  socklen_t len = sizeof cr;
  if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cr, &len) != 0) caml_uerror("getsockopt", Nothing);
  return Val_int(cr.uid);
#endif
}
