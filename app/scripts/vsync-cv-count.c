#include <CoreVideo/CoreVideo.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <pthread.h>
#include <errno.h>
#include <string.h>
#include <time.h>
#include <stdlib.h>
#include <stdint.h>
#include <mach/mach.h>

static _Atomic unsigned long allocations;
unsigned long kido_cv_allocations(void) { return atomic_load(&allocations); }

#define INTERPOSE(replacement, original) \
  __attribute__((used)) static struct { const void *new; const void *old; } \
  pair_##original __attribute__((section("__DATA,__interpose"))) = { \
    (const void *)&replacement, (const void *)&original \
  }

static CVReturn active(CVDisplayLinkRef *result) {
  atomic_fetch_add(&allocations, 1);
  return CVDisplayLinkCreateWithActiveCGDisplays(result);
}
static CVReturn display(CGDirectDisplayID id, CVDisplayLinkRef *result) {
  atomic_fetch_add(&allocations, 1);
  return CVDisplayLinkCreateWithCGDisplay(id, result);
}
static CVReturn displays(CGDirectDisplayID *ids, CFIndex count, CVDisplayLinkRef *result) {
  atomic_fetch_add(&allocations, 1);
  return CVDisplayLinkCreateWithCGDisplays(ids, count, result);
}
static CVReturn mask(CGOpenGLDisplayMask value, CVDisplayLinkRef *result) {
  atomic_fetch_add(&allocations, 1);
  return CVDisplayLinkCreateWithOpenGLDisplayMask(value, result);
}
static struct { void *pointer; size_t size; } records[8192];
static atomic_flag allocation_lock = ATOMIC_FLAG_INIT;
static _Atomic bool capture_allocations;
static _Atomic size_t allocation_peak;
static bool allocation_overflow;
static size_t allocation_used;
void kido_renderer_allocation_reset(void) {
  while (atomic_flag_test_and_set(&allocation_lock)) {}
  memset(records, 0, sizeof(records));
  atomic_store(&allocation_peak, 0);
  allocation_overflow = false;
  allocation_used = 0;
  atomic_flag_clear(&allocation_lock);
}
static void account(void *old, void *pointer, size_t size) {
  if (!atomic_load(&capture_allocations) && !atomic_load(&allocation_peak)) return;
  bool capture = false;
  if (pointer && atomic_load(&capture_allocations)) {
    char name[64] = {0};
    capture = pthread_getname_np(pthread_self(), name, sizeof(name)) == 0 && strcmp(name, "renderer") == 0;
  }
  while (atomic_flag_test_and_set(&allocation_lock)) {}
  for (size_t i = 0; old && i < allocation_used; i++) if (records[i].pointer == old) {
    records[i].pointer = NULL;
    capture = pointer != NULL;
    break;
  }
  if (capture) {
    size_t slot = 8192;
    for (size_t i = 0; i < allocation_used; i++) {
      if (records[i].pointer == pointer) { slot = i; break; }
      if (!records[i].pointer && slot == 8192) slot = i;
    }
    if (slot == 8192 && allocation_used < 8192) slot = allocation_used++;
    if (slot == 8192) allocation_overflow = true;
    else { records[slot].pointer = pointer; records[slot].size = size; }
    if (size > allocation_peak) allocation_peak = size;
  }
  atomic_flag_clear(&allocation_lock);
}
size_t kido_renderer_allocation_bytes(bool peak) {
  while (atomic_flag_test_and_set(&allocation_lock)) {}
  if (peak) {
    size_t result = allocation_overflow ? SIZE_MAX : atomic_load(&allocation_peak);
    atomic_flag_clear(&allocation_lock);
    return result;
  }
  size_t bytes = 0;
  for (size_t i = 0; i < allocation_used; i++) if (records[i].pointer) bytes += records[i].size;
  size_t result = allocation_overflow ? SIZE_MAX : bytes;
  atomic_flag_clear(&allocation_lock);
  return result;
}
static void *allocate(size_t size) { void *p = malloc(size); account(NULL, p, size); return p; }
static void *allocate_zero(size_t count, size_t size) { void *p = calloc(count, size); account(NULL, p, count * size); return p; }
static void *resize_allocation(void *old, size_t size) { void *p = realloc(old, size); if (p) account(old, p, size); return p; }
static void release_allocation(void *p) { account(p, NULL, 0); free(p); }
static void *allocate_aligned(size_t alignment, size_t size) { void *p = aligned_alloc(alignment, size); account(NULL, p, size); return p; }
static int allocate_posix(void **p, size_t alignment, size_t size) { int r = posix_memalign(p, alignment, size); if (!r) account(NULL, *p, size); return r; }
INTERPOSE(allocate, malloc);
INTERPOSE(allocate_zero, calloc);
INTERPOSE(resize_allocation, realloc);
INTERPOSE(release_allocation, free);
INTERPOSE(allocate_aligned, aligned_alloc);
INTERPOSE(allocate_posix, posix_memalign);
static pthread_t previous;
static enum { disabled, fail_io, observe_renderer } thread_probe;
static uint64_t renderer_id;
static unsigned long io_failures;
uint64_t kido_renderer_thread(bool arm) {
  if (arm) { previous = NULL; renderer_id = 0; thread_probe = observe_renderer; }
  else thread_probe = disabled;
  return renderer_id;
}
unsigned long kido_io_spawn_fault(bool arm) {
  if (arm) {
    previous = NULL;
    kido_renderer_allocation_reset();
  }
  atomic_store(&capture_allocations, arm);
  thread_probe = arm ? fail_io : disabled;
  return io_failures;
}
static int create(pthread_t *thread, const pthread_attr_t *attrs,
                  void *(*start)(void *), void *context) {
  if (pthread_main_np() && thread_probe != disabled) {
    char name[64] = {0};
    for (unsigned i = 0; previous && i < 100; i++) {
      if (pthread_getname_np(previous, name, sizeof(name)) != 0 || name[0]) break;
      nanosleep(&(struct timespec){.tv_nsec = 1000000}, NULL);
    }
    if (strcmp(name, "renderer") == 0) {
      if (thread_probe == fail_io) {
        for (unsigned i = 0; i < 2000 && kido_renderer_allocation_bytes(true) <= 65536; i++) {
          nanosleep(&(struct timespec){.tv_nsec = 1000000}, NULL);
        }
        thread_probe = disabled;
        io_failures++;
        return EAGAIN;
      }
      thread_identifier_info_data_t info;
      mach_msg_type_number_t count = THREAD_IDENTIFIER_INFO_COUNT;
      if (thread_info(pthread_mach_thread_np(previous), THREAD_IDENTIFIER_INFO, (thread_info_t)&info, &count) == KERN_SUCCESS) renderer_id = info.thread_id;
      thread_probe = disabled;
    }
    int status = pthread_create(thread, attrs, start, context);
    if (status == 0) previous = *thread;
    return status;
  }
  return pthread_create(thread, attrs, start, context);
}
INTERPOSE(create, pthread_create);
INTERPOSE(active, CVDisplayLinkCreateWithActiveCGDisplays);
INTERPOSE(display, CVDisplayLinkCreateWithCGDisplay);
INTERPOSE(displays, CVDisplayLinkCreateWithCGDisplays);
INTERPOSE(mask, CVDisplayLinkCreateWithOpenGLDisplayMask);
