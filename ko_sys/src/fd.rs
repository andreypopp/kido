use std::io;
use std::os::fd::{AsRawFd, BorrowedFd};

use crate::retry::{check, check_size, retry};

pub(crate) fn read(fd: BorrowedFd<'_>, buffer: &mut [u8]) -> io::Result<usize> {
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

pub(crate) fn set_cloexec(fd: BorrowedFd<'_>) -> io::Result<()> {
    // SAFETY: fd is open for the borrow.
    check(unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC) })?;
    Ok(())
}

pub(crate) fn set_nonblocking(fd: BorrowedFd<'_>) -> io::Result<()> {
    // SAFETY: fd is open for the borrow.
    let flags = check(unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_GETFL) })?;
    // SAFETY: as above.
    check(unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) })?;
    Ok(())
}
