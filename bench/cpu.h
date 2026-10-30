#ifndef KO_BENCH_CPU_H
#define KO_BENCH_CPU_H
#include <sys/types.h>
#ifdef __APPLE__
#include <libproc.h>
#include <mach/mach_time.h>
#endif
#include <stdio.h>
#include <unistd.h>

/* User plus system seconds of a live process, or -1. proc_pid_rusage reports
   mach ticks on Apple Silicon, not nanoseconds; spikes/coordinator.exe cpu-check
   compares this against getrusage. */
static inline double ko_cpu_seconds(pid_t pid) {
#ifdef __APPLE__
  struct rusage_info_v2 info;
  if (proc_pid_rusage(pid, RUSAGE_INFO_V2, (rusage_info_t *)&info)) return -1;
  mach_timebase_info_data_t base;
  mach_timebase_info(&base);
  return (double)(info.ri_user_time + info.ri_system_time) * base.numer / base.denom / 1e9;
#else
  char path[64];
  snprintf(path, sizeof(path), "/proc/%d/stat", (int)pid);
  FILE *f = fopen(path, "r");
  if (!f) return -1;
  unsigned long user = 0, sys = 0;
  int n = fscanf(f, "%*d %*s %*c %*d %*d %*d %*d %*d %*u %*u %*u %*u %*u %lu %lu", &user, &sys);
  fclose(f);
  return n == 2 ? (double)(user + sys) / (double)sysconf(_SC_CLK_TCK) : -1;
#endif
}

static inline double ko_cpu_raw_ns_seconds(pid_t pid) {
#ifdef __APPLE__
  struct rusage_info_v2 info;
  if (proc_pid_rusage(pid, RUSAGE_INFO_V2, (rusage_info_t *)&info)) return -1;
  return (double)(info.ri_user_time + info.ri_system_time) / 1e9;
#else
  return ko_cpu_seconds(pid);
#endif
}
#endif
