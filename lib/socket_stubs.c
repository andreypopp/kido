#include <sys/un.h>
#include <caml/mlvalues.h>

CAMLprim value kido_sun_path_size(value unit) {
  return Val_int(sizeof(((struct sockaddr_un *)0)->sun_path));
}
