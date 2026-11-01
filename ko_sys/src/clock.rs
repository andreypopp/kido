use std::time::Duration;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Mono(u64);

impl Mono {
    pub fn now() -> Mono {
        let mut time = libc::timespec {
            tv_sec: 0,
            tv_nsec: 0,
        };
        // SAFETY: time is a valid timespec, and CLOCK_UPTIME_RAW exists on macOS (ko_now_ns).
        unsafe { libc::clock_gettime(libc::CLOCK_UPTIME_RAW, &mut time) };
        let seconds = u64::try_from(time.tv_sec).unwrap_or(0);
        let nanos = u64::try_from(time.tv_nsec).unwrap_or(0);
        Mono(seconds.saturating_mul(1_000_000_000).saturating_add(nanos))
    }

    pub fn from_nanos(nanos: u64) -> Mono {
        Mono(nanos)
    }
}

pub fn cpu_time() -> Duration {
    // SAFETY: an all-zero rusage is valid, and getrusage fills it.
    let mut usage: libc::rusage = unsafe { std::mem::zeroed() };
    // SAFETY: usage is writable.
    unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut usage) };
    let time = |value: libc::timeval| {
        Duration::from_secs(u64::try_from(value.tv_sec).unwrap_or(0))
            + Duration::from_micros(u64::try_from(value.tv_usec).unwrap_or(0))
    };
    time(usage.ru_utime) + time(usage.ru_stime)
}
