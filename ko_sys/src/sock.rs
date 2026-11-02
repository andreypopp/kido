use std::io;
use std::os::fd::{AsRawFd, BorrowedFd};

use crate::pid::Pid;
use crate::retry::check;

fn set(fd: BorrowedFd<'_>, option: libc::c_int, bytes: usize) -> io::Result<()> {
    let value = libc::c_int::try_from(bytes)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "socket buffer too large"))?;
    // SAFETY: value is a c_int, the type that SO_SNDBUF and SO_RCVBUF take.
    check(unsafe {
        libc::setsockopt(
            fd.as_raw_fd(),
            libc::SOL_SOCKET,
            option,
            (&raw const value).cast(),
            libc::socklen_t::try_from(size_of::<libc::c_int>()).unwrap_or(4),
        )
    })?;
    Ok(())
}

pub fn set_send_buffer(fd: BorrowedFd<'_>, bytes: usize) -> io::Result<()> {
    set(fd, libc::SO_SNDBUF, bytes)
}

pub fn set_receive_buffer(fd: BorrowedFd<'_>, bytes: usize) -> io::Result<()> {
    set(fd, libc::SO_RCVBUF, bytes)
}

fn get<T>(
    fd: BorrowedFd<'_>,
    level: libc::c_int,
    option: libc::c_int,
    value: &mut T,
) -> io::Result<()> {
    let mut len = libc::socklen_t::try_from(size_of::<T>())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "socket option too large"))?;
    // SAFETY: value is writable for len bytes, the size of the option's type.
    check(unsafe {
        libc::getsockopt(
            fd.as_raw_fd(),
            level,
            option,
            std::ptr::from_mut(value).cast(),
            &mut len,
        )
    })?;
    Ok(())
}

#[cfg(target_os = "macos")]
pub fn peer_uid(fd: BorrowedFd<'_>) -> io::Result<u32> {
    // SAFETY: an all-zero xucred is valid.
    let mut credentials: libc::xucred = unsafe { std::mem::zeroed() };
    get(fd, libc::SOL_LOCAL, libc::LOCAL_PEERCRED, &mut credentials)?;
    if credentials.cr_version != libc::XUCRED_VERSION {
        return Err(io::Error::from_raw_os_error(libc::EPROTO));
    }
    Ok(credentials.cr_uid)
}

#[cfg(target_os = "linux")]
fn credentials(fd: BorrowedFd<'_>) -> io::Result<libc::ucred> {
    let mut credentials = libc::ucred {
        pid: 0,
        uid: 0,
        gid: 0,
    };
    get(fd, libc::SOL_SOCKET, libc::SO_PEERCRED, &mut credentials)?;
    Ok(credentials)
}

#[cfg(target_os = "linux")]
pub fn peer_uid(fd: BorrowedFd<'_>) -> io::Result<u32> {
    Ok(credentials(fd)?.uid)
}

pub fn uid() -> u32 {
    // SAFETY: getuid has no preconditions.
    unsafe { libc::getuid() }
}

#[cfg(target_os = "macos")]
pub fn peer_pid(fd: BorrowedFd<'_>) -> io::Result<Option<Pid>> {
    let mut pid: libc::pid_t = 0;
    get(fd, libc::SOL_LOCAL, libc::LOCAL_PEERPID, &mut pid)?;
    Ok(Pid::new(i64::from(pid)))
}

#[cfg(target_os = "linux")]
pub fn peer_pid(fd: BorrowedFd<'_>) -> io::Result<Option<Pid>> {
    Ok(Pid::new(i64::from(credentials(fd)?.pid)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::fd::AsFd;
    use std::os::unix::net::UnixStream;

    #[test]
    fn a_socketpair_peer_is_this_user_and_this_process() {
        let (a, _b) = UnixStream::pair().unwrap();
        assert_eq!(peer_uid(a.as_fd()).unwrap(), uid());
        assert_eq!(peer_pid(a.as_fd()).unwrap(), None);
        set_send_buffer(a.as_fd(), 1 << 20).unwrap();
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn so_peercred_names_the_process_that_made_the_socketpair() {
        let (a, _b) = UnixStream::pair().unwrap();
        let credentials = credentials(a.as_fd()).unwrap();
        assert_eq!(credentials.uid, uid());
        assert_eq!(u32::try_from(credentials.pid).unwrap(), std::process::id());
    }
}
