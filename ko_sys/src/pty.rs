use std::fmt;
use std::io;
use std::os::fd::BorrowedFd;

#[cfg(not(target_os = "ios"))]
mod desktop;
#[cfg(not(target_os = "ios"))]
pub use desktop::*;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Step {
    Sigmask = 1,
    Setsid,
    Tiocsctty,
    Dup2,
    Chdir,
    Exec,
}

impl Step {
    pub fn code(self) -> u8 {
        self as u8
    }

    pub fn of_code(code: u8) -> Option<Step> {
        Some(match code {
            1 => Step::Sigmask,
            2 => Step::Setsid,
            3 => Step::Tiocsctty,
            4 => Step::Dup2,
            5 => Step::Chdir,
            6 => Step::Exec,
            _ => return None,
        })
    }

    fn name(self) -> &'static str {
        match self {
            Step::Sigmask => "sigprocmask",
            Step::Setsid => "setsid",
            Step::Tiocsctty => "tiocsctty",
            Step::Dup2 => "dup2",
            Step::Chdir => "chdir",
            Step::Exec => "exec",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Failed {
    step: Step,
    errno: i32,
}

impl Failed {
    pub fn new(step: Step, errno: i32) -> Option<Self> {
        (errno > 0).then_some(Self { step, errno })
    }
    pub fn step(self) -> Step {
        self.step
    }
    pub fn errno(self) -> i32 {
        self.errno
    }
}

impl fmt::Display for Failed {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{}: {}",
            self.step.name(),
            io::Error::from_raw_os_error(self.errno)
        )
    }
}

pub fn read(master: BorrowedFd<'_>, buffer: &mut [u8]) -> io::Result<usize> {
    match crate::fd::read(master, buffer) {
        Err(error) if error.raw_os_error() == Some(libc::EIO) => Ok(0),
        read => read,
    }
}
