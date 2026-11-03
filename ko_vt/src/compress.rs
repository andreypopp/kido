use std::time::Duration;

use ko_sys::clock::Mono;

use crate::Terminal;

const IDLE: Duration = Duration::from_millis(250);
const BUSY: Duration = Duration::from_secs(2);
const STEP: Duration = Duration::from_millis(10);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tick {
    Settled,
    Now,
    After(Duration),
}

#[derive(Debug)]
pub struct Compress {
    activity: u64,
    quiet_since: Mono,
    busy_since: Mono,
    stepped: Mono,
    pending: bool,
}

fn since(now: Mono, then: Mono) -> Duration {
    Duration::from_nanos(now.nanos().saturating_sub(then.nanos()))
}

impl Compress {
    pub fn new(now: Mono) -> Compress {
        Compress {
            activity: 0,
            quiet_since: now,
            busy_since: now,
            stepped: Mono::from_nanos(0),
            pending: true,
        }
    }

    pub fn pending(&self) -> bool {
        self.pending
    }

    pub fn tick(&mut self, vt: &mut Terminal, now: Mono) -> Tick {
        let Ok(activity) = vt.compression_activity() else {
            return Tick::Settled;
        };
        if activity != self.activity {
            if since(now, self.quiet_since) >= IDLE {
                self.busy_since = now;
            }
            self.activity = activity;
            self.quiet_since = now;
            self.pending = true;
        }
        if !self.pending {
            return Tick::Settled;
        }
        let mut paced = false;
        let quiet = since(now, self.quiet_since);
        if quiet < IDLE {
            if since(now, self.busy_since) < BUSY {
                return Tick::After(IDLE - quiet);
            }
            let stepped = since(now, self.stepped);
            if stepped < STEP {
                return Tick::After(STEP - stepped);
            }
            paced = true;
            self.stepped = now;
        }
        if !matches!(vt.compress_step(), Ok(true)) {
            self.pending = false;
            return Tick::Settled;
        }
        if let Ok(activity) = vt.compression_activity() {
            self.activity = activity;
        }
        if paced { Tick::After(STEP) } else { Tick::Now }
    }
}

#[cfg(test)]
mod tests {
    use std::num::NonZeroUsize;

    use ko_pane_wire::frame::{Dim, Limits, Scrollback};
    use ko_vt_sys as sys;

    use super::*;

    const START: u64 = 1_000_000_000;

    fn terminal() -> Terminal {
        let limits = Limits {
            scrollback: Scrollback::Bounded {
                max_bytes: NonZeroUsize::new(50_000_000),
                max_lines: None,
            },
            apc_max_bytes: 65 * 1024 * 1024,
            kitty_images_max_bytes: 0,
            continuation_max_bytes: 65 * 1024 * 1024,
        };
        let mut vt = Terminal::new(Dim::new(80).unwrap(), Dim::new(24).unwrap(), limits).unwrap();
        for i in 0..20_000 {
            vt.write(format!("compressible scrollback line {i}\r\n").as_bytes());
        }
        vt
    }

    fn usage(vt: &Terminal) -> sys::GhosttyTerminalMemoryUsage {
        let usage = sys::GhosttyTerminalMemoryUsage {
            size: size_of::<sys::GhosttyTerminalMemoryUsage>(),
            ..Default::default()
        };
        vt.get(sys::GHOSTTY_TERMINAL_DATA_MEMORY_USAGE, usage)
            .unwrap()
    }

    fn at(nanos: u64) -> Mono {
        Mono::from_nanos(START + nanos)
    }

    #[test]
    fn an_idle_terminal_compresses_its_history_in_steps_and_settles() {
        let mut vt = terminal();
        let before = usage(&vt);
        assert!(before.compression_supported);
        let mut compress = Compress::new(at(0));
        match compress.tick(&mut vt, at(0)) {
            Tick::After(wait) => assert!(!wait.is_zero() && wait <= IDLE, "{wait:?}"),
            other => panic!("{other:?}"),
        }
        for i in 0..10 {
            vt.write(format!("compressible scrollback line {i}\r\n").as_bytes());
        }
        match compress.tick(&mut vt, at(200_000_000)) {
            Tick::After(wait) => assert!(wait > Duration::from_millis(200), "{wait:?}"),
            other => panic!("{other:?}"),
        }
        assert_eq!(usage(&vt).primary_compressed_pages, 0);
        let now = at(200_000_000 + IDLE.as_nanos() as u64);
        vt.write(b"\rspinner 1234");
        let mut steps = 0;
        while compress.tick(&mut vt, now) == Tick::Now {
            steps += 1;
            assert!(steps < 100_000);
        }
        assert_eq!(compress.tick(&mut vt, now), Tick::Settled);
        assert!(steps > 0);
        let after = usage(&vt);
        assert!(after.primary_compressed_pages > 0);
        assert!(after.primary_resident_bytes < before.primary_resident_bytes / 2);
        let later = Mono::from_nanos(now.nanos() + IDLE.as_nanos() as u64);
        assert_eq!(compress.tick(&mut vt, later), Tick::Settled);
    }

    #[test]
    fn continuous_output_compresses_one_step_per_ten_milliseconds_after_two_seconds() {
        let mut vt = terminal();
        let before = usage(&vt);
        let mut compress = Compress::new(at(0));
        let mut stepped = 0;
        for i in 1..=800u64 {
            let t = i * STEP.as_nanos() as u64;
            if i % 10 == 0 {
                vt.write(b"compressible scrollback line\r\n");
            }
            let pages = usage(&vt).primary_compressed_pages;
            let next = compress.tick(&mut vt, at(t));
            assert!(
                matches!(next, Tick::Settled) || matches!(next, Tick::After(wait) if wait <= IDLE),
                "{next:?}"
            );
            if t < BUSY.as_nanos() as u64 {
                assert_eq!(pages, 0, "a step before {BUSY:?} at {t}");
            } else if usage(&vt).primary_compressed_pages > pages {
                stepped += 1;
            }
        }
        let after = usage(&vt);
        assert!(stepped > 0 && after.primary_compressed_pages > 0);
        assert!(after.primary_resident_bytes < before.primary_resident_bytes / 2);
    }
}
