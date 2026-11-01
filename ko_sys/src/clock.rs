use std::time::Duration;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Mono(u64);

fn read(clock: libc::clockid_t) -> Duration {
    let mut time = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: time is a valid timespec.
    unsafe { libc::clock_gettime(clock, &mut time) };
    Duration::new(
        u64::try_from(time.tv_sec).unwrap_or(0),
        u32::try_from(time.tv_nsec).unwrap_or(0),
    )
}

impl Mono {
    pub fn now() -> Mono {
        // CLOCK_UPTIME_RAW exists on macOS (ko_now_ns).
        Mono(u64::try_from(read(libc::CLOCK_UPTIME_RAW).as_nanos()).unwrap_or(u64::MAX))
    }

    pub fn from_nanos(nanos: u64) -> Mono {
        Mono(nanos)
    }

    pub fn nanos(self) -> u64 {
        self.0
    }
}

pub fn thread_cpu_time() -> Duration {
    read(libc::CLOCK_THREAD_CPUTIME_ID)
}

fn rusage(who: libc::c_int) -> Duration {
    // SAFETY: an all-zero rusage is valid, and getrusage fills it.
    let mut usage: libc::rusage = unsafe { std::mem::zeroed() };
    // SAFETY: usage is writable.
    unsafe { libc::getrusage(who, &mut usage) };
    let time = |value: libc::timeval| {
        Duration::from_secs(u64::try_from(value.tv_sec).unwrap_or(0))
            + Duration::from_micros(u64::try_from(value.tv_usec).unwrap_or(0))
    };
    time(usage.ru_utime) + time(usage.ru_stime)
}

pub fn cpu_time() -> Duration {
    rusage(libc::RUSAGE_SELF)
}

pub fn children_cpu_time() -> Duration {
    rusage(libc::RUSAGE_CHILDREN)
}

#[cfg(target_os = "macos")]
pub use macos::{MachTicks, ProcessCpu, process_cpu};

#[cfg(target_os = "macos")]
mod macos {
    use std::time::Duration;

    use crate::pid::Pid;

    #[repr(C)]
    struct Timebase {
        numer: u32,
        denom: u32,
    }

    unsafe extern "C" {
        fn mach_timebase_info(info: *mut Timebase) -> libc::c_int;
    }

    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub struct MachTicks(u64);

    impl MachTicks {
        pub fn get(self) -> u64 {
            self.0
        }
    }

    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub struct ProcessCpu {
        pub ticks: MachTicks,
        pub time: Duration,
    }

    pub fn process_cpu(pid: Pid) -> std::io::Result<ProcessCpu> {
        // SAFETY: an all-zero rusage_info_v2 is valid, and proc_pid_rusage fills it.
        let mut info: libc::rusage_info_v2 = unsafe { std::mem::zeroed() };
        // SAFETY: info is writable and has the layout of the V2 flavor.
        let found = unsafe {
            libc::proc_pid_rusage(
                pid.get(),
                libc::RUSAGE_INFO_V2,
                (&raw mut info).cast::<libc::rusage_info_t>(),
            )
        };
        if found != 0 {
            return Err(std::io::Error::last_os_error());
        }
        let mut base = Timebase { numer: 0, denom: 0 };
        // SAFETY: base has the layout of mach_timebase_info_data_t and is writable.
        unsafe { mach_timebase_info(&mut base) };
        let ticks = info.ri_user_time.saturating_add(info.ri_system_time);
        let nanos = u128::from(ticks) * u128::from(base.numer) / u128::from(base.denom.max(1));
        Ok(ProcessCpu {
            ticks: MachTicks(ticks),
            time: Duration::from_nanos(u64::try_from(nanos).unwrap_or(u64::MAX)),
        })
    }
}
