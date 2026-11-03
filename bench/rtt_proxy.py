#!/usr/bin/env python3
"""usage: rtt_proxy.py [--delay MS] [--bw MBIT] [--stats FILE] HOST PORT

An ssh ProxyCommand that delays each direction by MS milliseconds (RTT/2) and caps each direction
at MBIT megabits per second (0 = unlimited, 64 KiB burst). FILE ({pid} in it becomes the proxy's pid) gets the wire bytes as JSON
{"up": ..., "down": ...} while the link runs and at exit; up is stdin to the server, down is the
server to stdout."""
import argparse
import collections
import json
import os
import select
import signal
import socket
import sys
import time

BURST = 65536
QUEUE_MAX = 8 << 20
MIN_WRITE = 4096
STATS_EVERY = 0.02
# macOS coalesces timers: select returns up to 20 % of its timeout late. A shortened timeout
# converges on the deadline, and the last SPIN seconds poll.
SHORTEN = 0.6
SPIN = 0.0005


class Lane:
    def __init__(self, source, sink, close_sink, delay, rate):
        self.source, self.sink, self.close_sink, self.delay, self.rate = source, sink, close_sink, delay, rate
        self.queue = collections.deque()
        self.queued = 0
        self.tokens = float(BURST)
        self.refilled = time.monotonic()
        self.source_open = True
        self.sink_open = True
        self.blocked = False
        self.bytes = 0

    def finished(self):
        return not self.sink_open

    def reads(self):
        return self.source_open and self.sink_open and self.queued < QUEUE_MAX

    def read(self, now):
        try:
            data = os.read(self.source, 65536)
        except BlockingIOError:
            return
        except OSError:
            data = b""
        if data:
            self.queue.append((now + self.delay, memoryview(data)))
            self.queued += len(data)
        else:
            self.source_open = False

    def refill(self, now):
        if self.rate is not None:
            self.tokens = min(float(BURST), self.tokens + (now - self.refilled) * self.rate)
        self.refilled = now

    def next_write(self, now):
        if not self.queue or self.blocked or not self.sink_open:
            return None
        due, data = self.queue[0]
        if self.rate is None:
            return due
        self.refill(now)
        return max(due, now + max(0.0, min(len(data), MIN_WRITE) - self.tokens) / self.rate)

    def write(self, now):
        while self.queue and self.sink_open:
            due, data = self.queue[0]
            if now < due:
                return
            allowed = len(data)
            if self.rate is not None:
                self.refill(now)
                allowed = min(allowed, int(self.tokens))
                if allowed < min(len(data), MIN_WRITE):
                    return
            try:
                wrote = os.write(self.sink, data[:allowed])
            except BlockingIOError:
                self.blocked = True
                return
            except OSError:
                self.shut()
                return
            self.blocked = False
            self.bytes += wrote
            self.queued -= wrote
            if self.rate is not None:
                self.tokens -= wrote
            if wrote == len(data):
                self.queue.popleft()
            else:
                self.queue[0] = (due, data[wrote:])
        if not self.source_open and not self.queue:
            self.shut()

    def shut(self):
        self.sink_open = False
        self.queue.clear()
        self.queued = 0
        try:
            self.close_sink()
        except OSError:
            pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--delay", type=float, default=0)
    parser.add_argument("--bw", type=float, default=0)
    parser.add_argument("--stats")
    parser.add_argument("host")
    parser.add_argument("port", type=int)
    args = parser.parse_args()
    if args.stats:
        args.stats = args.stats.replace("{pid}", str(os.getpid()))
    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, lambda *_: sys.exit(0))
    sock = socket.create_connection((args.host, args.port))
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    sock.setblocking(False)
    os.set_blocking(0, False)
    os.set_blocking(1, False)
    rate = args.bw * 125000 if args.bw > 0 else None
    delay = args.delay / 1000
    up = Lane(0, sock.fileno(), lambda: sock.shutdown(socket.SHUT_WR), delay, rate)
    down = Lane(sock.fileno(), 1, lambda: os.close(1), delay, rate)
    saved, saved_at = (0, 0), 0.0

    def save(force=False):
        nonlocal saved, saved_at
        now = time.monotonic()
        counts = (up.bytes, down.bytes)
        if args.stats and counts != saved and (force or now - saved_at >= STATS_EVERY):
            with open(args.stats + ".tmp", "w") as f:
                json.dump({"up": counts[0], "down": counts[1]}, f)
            os.replace(args.stats + ".tmp", args.stats)
            saved, saved_at = counts, now

    try:
        while not (up.finished() and down.finished()):
            now = time.monotonic()
            wakes = []
            for lane in (up, down):
                lane.write(now)
                wakes.append(lane.next_write(now))
            save()
            if args.stats and (up.bytes, down.bytes) != saved:
                wakes.append(saved_at + STATS_EVERY)
            wakes = [w for w in wakes if w is not None]
            readers = [lane.source for lane in (up, down) if lane.reads()]
            writers = [lane.sink for lane in (up, down) if lane.blocked and lane.sink_open]
            if not readers and not writers and not wakes:
                break
            timeout = None
            if wakes:
                timeout = max(0.0, min(wakes) - time.monotonic())
                timeout = timeout * SHORTEN if timeout > SPIN else 0.0
            ready_r, ready_w, _ = select.select(readers, writers, [], timeout)
            now = time.monotonic()
            for lane in (up, down):
                if lane.sink in ready_w:
                    lane.blocked = False
                if lane.source in ready_r:
                    lane.read(now)
    finally:
        save(True)


if __name__ == "__main__":
    main()
