use std::fmt;
use std::io;
use std::os::fd::{AsRawFd, BorrowedFd};

use crate::retry::check;

pub struct Saved(libc::termios);

impl fmt::Debug for Saved {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Saved")
    }
}

pub fn raw(fd: BorrowedFd<'_>) -> io::Result<Saved> {
    // SAFETY: an all-zero termios is valid, and tcgetattr fills it.
    let mut attributes: libc::termios = unsafe { std::mem::zeroed() };
    // SAFETY: fd is open for the borrow, and attributes is writable.
    check(unsafe { libc::tcgetattr(fd.as_raw_fd(), &mut attributes) })?;
    let saved = Saved(attributes);
    attributes.c_lflag &= !(libc::ECHO | libc::ICANON | libc::ISIG | libc::IEXTEN);
    attributes.c_iflag &= !(libc::IXON | libc::ICRNL);
    attributes.c_cc[libc::VMIN] = 1;
    attributes.c_cc[libc::VTIME] = 0;
    // SAFETY: fd is open for the borrow, and attributes is initialized.
    check(unsafe { libc::tcsetattr(fd.as_raw_fd(), libc::TCSANOW, &attributes) })?;
    Ok(saved)
}

pub fn restore(fd: BorrowedFd<'_>, saved: &Saved) -> io::Result<()> {
    // SAFETY: fd is open for the borrow, and the saved attributes came from tcgetattr.
    check(unsafe { libc::tcsetattr(fd.as_raw_fd(), libc::TCSANOW, &saved.0) })?;
    Ok(())
}

pub fn flush_input(fd: BorrowedFd<'_>) {
    // SAFETY: fd is open for the borrow; a failed flush leaves the input as it was.
    unsafe { libc::tcflush(fd.as_raw_fd(), libc::TCIFLUSH) };
}

pub fn size(fd: BorrowedFd<'_>) -> Option<(u16, u16)> {
    // SAFETY: an all-zero winsize is valid, and TIOCGWINSZ fills it.
    let mut size: libc::winsize = unsafe { std::mem::zeroed() };
    // SAFETY: fd is open for the borrow, and size is writable.
    check(unsafe { libc::ioctl(fd.as_raw_fd(), libc::TIOCGWINSZ, &mut size) }).ok()?;
    (size.ws_col > 0 && size.ws_row > 0).then_some((size.ws_col, size.ws_row))
}
