package rusage

/*
#include <libproc.h>
#include <mach/mach_time.h>
#include <stdint.h>

static int usage(int pid, uint64_t *cpu_ns, uint64_t *wakeups) {
	struct rusage_info_v4 info;
	if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&info) != 0) return -1;
	mach_timebase_info_data_t base;
	mach_timebase_info(&base);
	*cpu_ns = (info.ri_user_time + info.ri_system_time) * base.numer / base.denom;
	*wakeups = info.ri_pkg_idle_wkups + info.ri_interrupt_wkups;
	return 0;
}
*/
import "C"

import (
	"fmt"
	"time"
)

func Read(pid int) (Usage, error) {
	var cpu, wakeups C.uint64_t
	if C.usage(C.int(pid), &cpu, &wakeups) != 0 {
		return Usage{}, fmt.Errorf("proc_pid_rusage(%d) failed", pid)
	}
	return Usage{CPU: time.Duration(cpu), Wakeups: uint64(wakeups)}, nil
}
