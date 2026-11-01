package rusage

import "time"

type Usage struct {
	CPU     time.Duration
	Wakeups uint64
}
