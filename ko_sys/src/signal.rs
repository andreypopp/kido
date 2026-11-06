use std::io::{self, PipeReader, PipeWriter};
use std::os::fd::{AsFd, AsRawFd, BorrowedFd};
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};

use crate::retry::check;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Signal {
    Child = 0,
    Hup = 1,
    Int = 2,
    Kill = 3,
    Pipe = 4,
    Quit = 5,
    Term = 6,
    Usr1 = 7,
    Usr2 = 8,
    Winch = 9,
    #[cfg(feature = "e2e")]
    Stop = 10,
    #[cfg(feature = "e2e")]
    Cont = 11,
}

impl Signal {
    pub fn number(self) -> libc::c_int {
        match self {
            Signal::Child => libc::SIGCHLD,
            Signal::Hup => libc::SIGHUP,
            Signal::Int => libc::SIGINT,
            Signal::Kill => libc::SIGKILL,
            Signal::Pipe => libc::SIGPIPE,
            Signal::Quit => libc::SIGQUIT,
            Signal::Term => libc::SIGTERM,
            Signal::Usr1 => libc::SIGUSR1,
            Signal::Usr2 => libc::SIGUSR2,
            Signal::Winch => libc::SIGWINCH,
            #[cfg(feature = "e2e")]
            Signal::Stop => libc::SIGSTOP,
            #[cfg(feature = "e2e")]
            Signal::Cont => libc::SIGCONT,
        }
    }

    fn of_number(number: libc::c_int) -> Option<Signal> {
        match number {
            libc::SIGCHLD => Some(Signal::Child),
            libc::SIGHUP => Some(Signal::Hup),
            libc::SIGINT => Some(Signal::Int),
            libc::SIGKILL => Some(Signal::Kill),
            libc::SIGPIPE => Some(Signal::Pipe),
            libc::SIGQUIT => Some(Signal::Quit),
            libc::SIGTERM => Some(Signal::Term),
            libc::SIGUSR1 => Some(Signal::Usr1),
            libc::SIGUSR2 => Some(Signal::Usr2),
            libc::SIGWINCH => Some(Signal::Winch),
            _ => None,
        }
    }
}

static PENDING: [AtomicBool; 10] = [const { AtomicBool::new(false) }; 10];
static PIPE: AtomicI32 = AtomicI32::new(-1);

extern "C" fn to_pipe(number: libc::c_int) {
    // SAFETY: errno is the calling thread's, which the handler restores.
    let saved = unsafe { *crate::retry::errno() };
    if let Some(signal) = Signal::of_number(number) {
        PENDING[signal as usize].store(true, Ordering::SeqCst);
    }
    let fd = PIPE.load(Ordering::SeqCst);
    if fd >= 0 {
        let byte = 0u8;
        // SAFETY: write is async-signal-safe, and byte is one readable byte.
        unsafe { libc::write(fd, (&raw const byte).cast(), 1) };
    }
    // SAFETY: as above.
    unsafe { *crate::retry::errno() = saved };
}

#[cfg(any(test, feature = "fuzz"))]
pub(crate) fn simulate(signal: Signal) {
    to_pipe(signal.number());
}

#[derive(Debug)]
pub struct Signals {
    read: PipeReader,
    write: PipeWriter,
    installed: Vec<Signal>,
}

fn set_handler(signal: Signal, handler: libc::sighandler_t) -> io::Result<()> {
    // SAFETY: an all-zero sigaction is valid; the fields are set below.
    let mut action: libc::sigaction = unsafe { std::mem::zeroed() };
    action.sa_sigaction = handler;
    action.sa_flags = libc::SA_RESTART;
    // SAFETY: sa_mask is a valid sigset_t.
    unsafe { libc::sigemptyset(&mut action.sa_mask) };
    // SAFETY: action is initialized, and the handler only stores a flag and writes the pipe.
    check(unsafe { libc::sigaction(signal.number(), &action, std::ptr::null_mut()) })?;
    Ok(())
}

impl Signals {
    pub fn install(signals: &[Signal]) -> io::Result<Signals> {
        let (read, write) = io::pipe()?;
        crate::fd::set_nonblocking(read.as_fd())?;
        crate::fd::set_nonblocking(write.as_fd())?;
        PIPE.compare_exchange(-1, write.as_raw_fd(), Ordering::SeqCst, Ordering::SeqCst)
            .map_err(|_| {
                io::Error::new(
                    io::ErrorKind::AlreadyExists,
                    "the signal pipe is already installed",
                )
            })?;
        let mut installed = Signals {
            read,
            write,
            installed: Vec::new(),
        };
        for &signal in signals {
            set_handler(
                signal,
                to_pipe as extern "C" fn(libc::c_int) as libc::sighandler_t,
            )?;
            installed.installed.push(signal);
        }
        Ok(installed)
    }

    pub fn fd(&self) -> BorrowedFd<'_> {
        self.read.as_fd()
    }

    pub fn take(&self, pending: &mut Vec<Signal>) -> io::Result<()> {
        let mut drain = [0u8; 64];
        loop {
            match crate::fd::read(self.read.as_fd(), &mut drain) {
                Ok(count) if count == drain.len() => {}
                Ok(_) => break,
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                Err(error) => return Err(error),
            }
        }
        pending.extend(
            self.installed
                .iter()
                .filter(|&&signal| PENDING[signal as usize].swap(false, Ordering::SeqCst)),
        );
        Ok(())
    }
}

impl Drop for Signals {
    fn drop(&mut self) {
        for &signal in &self.installed {
            let _ = set_handler(signal, libc::SIG_DFL);
        }
        let _ = PIPE.compare_exchange(
            self.write.as_raw_fd(),
            -1,
            Ordering::SeqCst,
            Ordering::SeqCst,
        );
    }
}

#[cfg(test)]
pub(crate) static SERIAL: std::sync::Mutex<()> = std::sync::Mutex::new(());

#[cfg(test)]
mod tests {
    use super::*;
    use crate::event::{Events, Interest, Mode, Poll};
    use crate::spawn;
    use std::path::Path;
    use std::time::{Duration, Instant};

    #[test]
    fn a_signal_is_never_lost_runs_once_per_wakeup_and_wakes_the_loop() {
        let _serial = SERIAL
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let signals = Signals::install(&[Signal::Usr1, Signal::Usr2, Signal::Child]).unwrap();
        assert_eq!(
            Signals::install(&[Signal::Usr1]).unwrap_err().kind(),
            io::ErrorKind::AlreadyExists
        );
        let mut poll = Poll::new();
        let mut events = Events::default();
        poll.watch(signals.fd(), Interest::Read);
        let mut pending = Vec::new();
        let mut turn = |poll: &mut Poll, mode, pending: &mut Vec<Signal>| {
            pending.clear();
            poll.turn(mode, &mut events).unwrap();
            if events.ready().iter().any(|&ready| poll.wants(ready).read) {
                signals.take(pending).unwrap();
            }
        };
        let users = |pending: &[Signal]| -> Vec<Signal> {
            pending
                .iter()
                .copied()
                .filter(|&signal| signal != Signal::Child)
                .collect()
        };
        for _ in 0..200_000 {
            to_pipe(Signal::Usr1.number());
        }
        to_pipe(Signal::Usr2.number());
        turn(&mut poll, Mode::Peek, &mut pending);
        assert_eq!(users(&pending), [Signal::Usr1, Signal::Usr2]);
        turn(&mut poll, Mode::Peek, &mut pending);
        assert_eq!(users(&pending), []);
        let deadline = poll.timer();
        poll.start(deadline, Duration::from_secs(5), None).unwrap();
        let child = spawn::program(
            Path::new("/usr/bin/true"),
            &[],
            &[],
            spawn::Env::Inherit,
            None,
        )
        .unwrap();
        let start = Instant::now();
        while !pending.contains(&Signal::Child) && poll.is_active(deadline) {
            turn(&mut poll, Mode::Wait, &mut pending);
        }
        assert!(pending.contains(&Signal::Child), "{:?}", start.elapsed());
        child.wait().unwrap();
    }
}
