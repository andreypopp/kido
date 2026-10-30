#ifndef KO_NOW_H
#define KO_NOW_H
#include <stdint.h>
#include <time.h>

static inline uint64_t ko_now_ns(void) {
#ifdef __APPLE__
  return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#else
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec;
#endif
}
#endif
