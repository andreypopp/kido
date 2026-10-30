#define _DARWIN_C_SOURCE
#define _DEFAULT_SOURCE
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/wait.h>
#include <sys/ioctl.h>
#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#endif

static double now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}

static pid_t spawn(int *master, size_t bytes) {
  int slave;
  if (openpty(master, &slave, NULL, NULL, NULL)) exit(2);
  pid_t pid = fork();
  if (pid == 0) {
    if (setsid() < 0 || ioctl(slave, TIOCSCTTY, 0) < 0 || dup2(slave, 1) < 0) _exit(126);
    close(*master);
    close(slave);
    static char data[1 << 20];
    memset(data, 'x', sizeof(data));
    for (size_t done = 0; done < bytes;) {
      ssize_t n = write(1, data, bytes - done < sizeof(data) ? bytes - done : sizeof(data));
      if (n > 0) done += (size_t)n;
      else if (errno != EINTR) _exit(1);
    }
    _exit(7);
  }
  close(slave);
  fcntl(*master, F_SETFL, O_NONBLOCK);
  return pid;
}

static double reap_within(pid_t pid, double seconds) {
  double start = now();
  while (now() - start < seconds) {
    int status;
    if (waitpid(pid, &status, WNOHANG) == pid) return now() - start;
    poll(NULL, 0, 5);
  }
  return -1;
}

static size_t drain(int master, int *error) {
  static char buffer[1 << 16];
  size_t total = 0;
  double start = now();
  for (;;) {
    ssize_t n = read(master, buffer, sizeof(buffer));
    if (n > 0) total += (size_t)n;
    else if (n < 0 && errno == EAGAIN && now() - start < 2) {
      struct pollfd f = {master, POLLIN, 0};
      if (poll(&f, 1, 100) == 0) { *error = EAGAIN; return total; }
    } else { *error = n == 0 ? 0 : errno; return total; }
  }
}

int main(void) {
  signal(SIGCHLD, SIG_DFL);
  size_t sizes[] = {0, 100, 1 << 20};
  for (unsigned i = 0; i < 3; i++) {
    int master, error = 0;
    pid_t pid = spawn(&master, sizes[i]);
    double reaped = reap_within(pid, 1.0);
    printf("output=%zu unread: reaped_after=%s", sizes[i], reaped < 0 ? "no (1s)" : "");
    if (reaped >= 0) printf("%.3fs", reaped);
    size_t got = drain(master, &error);
    if (reaped < 0) {
      reaped = reap_within(pid, 2.0);
      printf(" reaped_after_read=%s", reaped < 0 ? "no" : "yes");
    }
    printf(" read_after=%zu end=%s", got, error == EIO ? "EIO" : error == EAGAIN ? "EAGAIN" : error ? strerror(error) : "EOF");
    error = 0;
    got = drain(master, &error);
    printf(" master_still_open_read=%zu (%s)\n", got, error == EIO ? "EIO" : error == EAGAIN ? "EAGAIN" : "other");
    close(master);
  }
  return 0;
}
