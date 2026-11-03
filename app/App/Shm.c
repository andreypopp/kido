#include "Shm.h"

#include <fcntl.h>
#include <sys/mman.h>

int kido_shm_open_readonly(const char *name) {
    return shm_open(name, O_RDONLY, 0);
}
