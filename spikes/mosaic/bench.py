#!/usr/bin/env python3
"""Run spikes/mosaic/main.exe under a private pty and print one result line.

usage: bench.py EXE MODE COLS ROWS SECONDS
The pty reader stands in for a terminal: it reads as fast as it can, counts
bytes and timestamps the frame that carries each key's marker.
"""
import fcntl, os, pty, select, struct, sys, tempfile, termios, time

exe, mode, cols, rows, seconds = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), float(sys.argv[5])
stats = tempfile.mktemp(prefix="mosaic-stats-")
pid, fd = pty.fork()
if pid == 0:
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    os.execv(exe, [exe, mode, str(seconds), stats, str(cols), str(rows)])

deadline = time.monotonic() + seconds + 10
total = 0
measured = 0
tail = b""
warm_until = time.monotonic() + 1.0
keys_sent = 0
sent_at = None
lat = []
next_key = warm_until
while time.monotonic() < deadline:
    now = time.monotonic()
    if sent_at is None and now >= next_key and now < warm_until + seconds - 2:
        keys_sent += 1
        os.write(fd, b"x")
        sent_at = time.monotonic()
    r, _, _ = select.select([fd], [], [], 0.005)
    if not r:
        continue
    try:
        data = os.read(fd, 1 << 20)
    except OSError:
        break
    if not data:
        break
    now = time.monotonic()
    total += len(data)
    if now >= warm_until:
        measured += len(data)
    if sent_at is not None:
        buf = tail + data
        if bytes([65 + keys_sent % 26]) * 8 in buf:
            lat.append((now - sent_at) * 1000)
            sent_at = None
            next_key = now + 0.1
        tail = buf[-16:]
if time.monotonic() >= deadline:
    os.kill(pid, 9)
while True:
    r, _, _ = select.select([fd], [], [], 0.2)
    if not r:
        break
    try:
        if not os.read(fd, 1 << 20):
            break
    except OSError:
        break
_, status, ru = os.wait4(pid, 0)
s = dict(l.split() for l in open(stats))
os.unlink(stats)
frames, wall, fps = int(s["frames"]), float(s["wall"]), float(s["fps"])
cpu = ru.ru_utime + ru.ru_stime
lat.sort()
pct = lambda p: lat[min(len(lat) - 1, len(lat) * p // 100)] if lat else float("nan")
print(
    f"{mode:7} {cols}x{rows}  fps {fps:6.1f}  gap p50/p99 {float(s['gap_p50_ms']):5.1f}/{float(s['gap_p99_ms']):5.1f} ms"
    f"  cpu {100 * cpu / wall:5.1f}%  cpu/frame {1000 * cpu / frames:6.2f} ms"
    f"  KB/frame {total / frames / 1024:7.1f}  MB/s {measured / (wall - 1) / 1e6:6.2f}"
    f"  key->frame p50/p99 {pct(50):5.1f}/{pct(99):5.1f} ms (n={len(lat)}/{keys_sent}, keys seen {s['keys']})"
    f"  maxrss {ru.ru_maxrss / 1048576:.0f} MiB"
)
