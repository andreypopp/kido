use std::io;
use std::os::fd::{AsFd, AsRawFd, BorrowedFd, FromRawFd, OwnedFd};
#[cfg(feature = "e2e")]
use std::time::Duration;

use crate::retry::{check, check_size, retry};

pub fn read(fd: BorrowedFd<'_>, buffer: &mut [u8]) -> io::Result<usize> {
    retry(|| {
        // SAFETY: buffer is writable for its length, and fd is open for the borrow.
        check_size(unsafe { libc::read(fd.as_raw_fd(), buffer.as_mut_ptr().cast(), buffer.len()) })
    })
}

pub fn write(fd: BorrowedFd<'_>, bytes: &[u8]) -> io::Result<usize> {
    retry(|| {
        // SAFETY: bytes is readable for its length, and fd is open for the borrow.
        check_size(unsafe { libc::write(fd.as_raw_fd(), bytes.as_ptr().cast(), bytes.len()) })
    })
}

pub fn wait_writable(fd: BorrowedFd<'_>) -> io::Result<()> {
    let mut wait = libc::pollfd {
        fd: fd.as_raw_fd(),
        events: libc::POLLOUT,
        revents: 0,
    };
    // SAFETY: wait is one initialized pollfd.
    retry(|| check(unsafe { libc::poll(&mut wait, 1, -1) })).map(drop)
}

#[cfg(feature = "e2e")]
fn wait(fd: BorrowedFd<'_>, events: libc::c_short, timeout: libc::c_int) -> io::Result<bool> {
    let mut wait = libc::pollfd {
        fd: fd.as_raw_fd(),
        events,
        revents: 0,
    };
    // SAFETY: wait is one initialized pollfd.
    retry(|| check(unsafe { libc::poll(&mut wait, 1, timeout) })).map(|ready| ready > 0)
}

#[cfg(feature = "e2e")]
pub fn wait_readable(fd: BorrowedFd<'_>) -> io::Result<()> {
    wait(fd, libc::POLLIN, -1).map(drop)
}

#[cfg(feature = "e2e")]
pub fn wait_writable_within(fd: BorrowedFd<'_>, timeout: Duration) -> io::Result<bool> {
    let millis = libc::c_int::try_from(timeout.as_millis()).unwrap_or(libc::c_int::MAX);
    wait(fd, libc::POLLOUT, millis)
}

pub fn inherited(number: u8) -> io::Result<OwnedFd> {
    let raw = libc::c_int::from(number);
    // SAFETY: F_GETFD only tests that the descriptor is open.
    check(unsafe { libc::fcntl(raw, libc::F_GETFD) })?;
    // SAFETY: the parent put this descriptor here (spawn::pane), and nothing else in this
    // process owns it.
    let fd = unsafe { OwnedFd::from_raw_fd(raw) };
    set_cloexec(fd.as_fd())?;
    Ok(fd)
}

pub(crate) fn set_cloexec(fd: BorrowedFd<'_>) -> io::Result<()> {
    // SAFETY: fd is open for the borrow.
    check(unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC) })?;
    Ok(())
}

pub fn set_nonblocking(fd: BorrowedFd<'_>) -> io::Result<()> {
    // SAFETY: fd is open for the borrow.
    let flags = check(unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_GETFL) })?;
    // SAFETY: as above.
    check(unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) })?;
    Ok(())
}

#[derive(Debug, Default)]
pub struct Queue {
    pub bytes: Vec<u8>,
    sent: usize,
}

impl Queue {
    pub fn is_empty(&self) -> bool {
        self.sent >= self.bytes.len()
    }

    pub fn clear(&mut self) {
        self.bytes.clear();
        self.sent = 0;
    }

    pub fn compact(&mut self) {
        self.bytes.drain(..self.sent.min(self.bytes.len()));
        self.sent = 0;
    }

    pub fn sent_past_half(&self) -> bool {
        self.sent > self.bytes.len() / 2
    }

    pub fn flush(&mut self, fd: BorrowedFd<'_>) -> io::Result<()> {
        while let Some(pending) = self
            .bytes
            .get(self.sent..)
            .filter(|pending| !pending.is_empty())
        {
            match write(fd, pending) {
                Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
                Ok(count) => self.sent = self.sent.saturating_add(count),
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => return Ok(()),
                Err(error) => return Err(error),
            }
        }
        self.clear();
        Ok(())
    }
}
