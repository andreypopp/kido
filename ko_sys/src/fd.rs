use std::io;
use std::os::fd::{AsFd, AsRawFd, BorrowedFd, FromRawFd, OwnedFd};
use std::time::{Duration, Instant};

use crate::retry::{check, check_size, retry};

pub fn onto_stderr(fd: BorrowedFd<'_>) -> io::Result<()> {
    retry(|| {
        // SAFETY: fd is open for the borrow; dup2 replaces fd 2 atomically,
        // and no OwnedFd owns fd 2 in a caller that uses this.
        check(unsafe { libc::dup2(fd.as_raw_fd(), 2) }).map(drop)
    })
}

pub fn read(fd: BorrowedFd<'_>, buffer: &mut [u8]) -> io::Result<usize> {
    let read = retry(|| {
        // SAFETY: buffer is writable for its length, and fd is open for the borrow.
        check_size(unsafe { libc::read(fd.as_raw_fd(), buffer.as_mut_ptr().cast(), buffer.len()) })
    });
    match read {
        // Linux resets a unix socket whose peer closed with unread input; macOS reports EOF.
        Err(error) if error.raw_os_error() == Some(libc::ECONNRESET) => Ok(0),
        read => read,
    }
}

pub fn write(fd: BorrowedFd<'_>, bytes: &[u8]) -> io::Result<usize> {
    // SAFETY: bytes remains readable for its length during the call.
    unsafe { write_raw(fd, bytes.as_ptr(), bytes.len()) }
}

/// # Safety
/// The pointer must cover len readable bytes that remain allocated until the call returns.
/// The kernel reads the bytes; concurrent changes can produce mixed output.
pub(crate) unsafe fn write_raw(
    fd: BorrowedFd<'_>,
    pointer: *const u8,
    len: usize,
) -> io::Result<usize> {
    retry(|| {
        // SAFETY: the caller keeps len bytes mapped; the kernel reads them without a Rust reference.
        check_size(unsafe { libc::write(fd.as_raw_fd(), pointer.cast(), len) })
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Want {
    Read,
    Write,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Waited {
    Ready,
    Cancelled,
    TimedOut,
}

// Waits for `fd`, until `cancel` is readable or `timeout` passes. No timeout waits for ever.
pub fn wait(
    fd: BorrowedFd<'_>,
    want: Want,
    cancel: Option<BorrowedFd<'_>>,
    timeout: Option<Duration>,
) -> io::Result<Waited> {
    let events = match want {
        Want::Read => libc::POLLIN,
        Want::Write => libc::POLLOUT,
    };
    let mut waits = [
        libc::pollfd {
            fd: fd.as_raw_fd(),
            events,
            revents: 0,
        },
        libc::pollfd {
            fd: cancel.map_or(-1, |cancel| cancel.as_raw_fd()),
            events: libc::POLLIN,
            revents: 0,
        },
    ];
    let deadline = timeout.map(|timeout| Instant::now() + timeout);
    let found = retry(|| {
        let millis = deadline.map_or(-1, |deadline| {
            libc::c_int::try_from(
                deadline
                    .saturating_duration_since(Instant::now())
                    .as_millis(),
            )
            .unwrap_or(libc::c_int::MAX)
        });
        // SAFETY: waits holds two initialized pollfd entries; a negative descriptor is ignored.
        check(unsafe { libc::poll(waits.as_mut_ptr(), 2, millis) })
    })?;
    Ok(match (found, waits[1].revents != 0) {
        (0, _) => Waited::TimedOut,
        (_, true) => Waited::Cancelled,
        _ => Waited::Ready,
    })
}

pub fn wait_writable(fd: BorrowedFd<'_>) -> io::Result<()> {
    wait(fd, Want::Write, None, None).map(drop)
}

#[cfg(feature = "e2e")]
pub fn wait_readable(fd: BorrowedFd<'_>) -> io::Result<()> {
    wait(fd, Want::Read, None, None).map(drop)
}

#[cfg(feature = "e2e")]
pub fn wait_writable_within(fd: BorrowedFd<'_>, timeout: Duration) -> io::Result<bool> {
    wait(fd, Want::Write, None, Some(timeout)).map(|waited| waited == Waited::Ready)
}

pub fn inherited(number: u8) -> io::Result<OwnedFd> {
    let raw = libc::c_int::from(number);
    // SAFETY: F_GETFD only tests that the descriptor is open.
    check(unsafe { libc::fcntl(raw, libc::F_GETFD) })?;
    // SAFETY: each binary takes each inherited descriptor once, before creating any other
    // descriptor owner; the parent transferred ownership through the exec boundary.
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::os::unix::net::UnixStream;

    fn reset_pair() -> UnixStream {
        let (mut a, b) = UnixStream::pair().unwrap();
        a.write_all(b"unread").unwrap();
        drop(b);
        a
    }

    #[test]
    fn a_wait_ends_on_data_a_cancel_or_the_timeout() {
        let wake = crate::event::Wake::new().unwrap();
        let (a, mut b) = UnixStream::pair().unwrap();
        let wait = || {
            wait(
                a.as_fd(),
                Want::Read,
                Some(wake.fd()),
                Some(Duration::from_millis(30)),
            )
        };
        assert_eq!(wait().unwrap(), Waited::TimedOut);
        b.write_all(b"x").unwrap();
        assert_eq!(wait().unwrap(), Waited::Ready);
        wake.wake();
        assert_eq!(wait().unwrap(), Waited::Cancelled);
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn a_peer_that_closed_with_unread_input_resets_a_unix_socket() {
        let error = std::io::Read::read(&mut reset_pair(), &mut [0; 8]).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::ConnectionReset);
    }

    #[test]
    fn a_reset_is_the_end_of_the_source() {
        let a = reset_pair();
        assert_eq!(read(a.as_fd(), &mut [0; 8]).unwrap(), 0);
    }
}
