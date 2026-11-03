# ko: the Linux measurements

Status: plan. The next step after the cut-over. ko builds, tests and
verifies on Linux in CI, but every row of the performance table
(docs/design-ko.md, "Performance") was measured on macOS.

Scope, 1 to 2 agent-days: run `bench/run.sh`, `bench/flood.sh` and
`bench/client.py` on a Linux box and record the rows beside the macOS
rows; check `SO_SNDBUF` behaviour on a unix stream socket (on macOS the
sender's buffer is the one that counts, docs/design-ko.md, "Views and
flow control") and the 4 KiB pty read (macOS gives 1 KiB for each
read). A row that misses its rule gets a tuning task. The scaffold is
done: `bench/client.py idle` already reads the coordinator's wakeups
through `strace -c -f` on Linux, and the e2e idle test reads the CPU
time from `/proc/<pid>/schedstat`.
