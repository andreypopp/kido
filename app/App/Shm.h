#ifndef KIDO_SHM_H
#define KIDO_SHM_H

// Swift cannot call the variadic shm_open.
int kido_shm_open_readonly(const char *name);

#endif
