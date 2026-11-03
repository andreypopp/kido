use std::io;
use std::os::fd::{AsFd, AsRawFd, BorrowedFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

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

pub fn connect_nonblocking(path: &Path) -> io::Result<OwnedFd> {
    let bytes = path.as_os_str().as_bytes();
    // SAFETY: an all-zero sockaddr_un is valid.
    let mut address: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    if bytes.contains(&0) || bytes.len() >= address.sun_path.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "invalid socket path",
        ));
    }
    address.sun_family = libc::sa_family_t::try_from(libc::AF_UNIX).unwrap_or_default();
    for (slot, byte) in address.sun_path.iter_mut().zip(bytes) {
        *slot = libc::c_char::from_ne_bytes([*byte]);
    }
    // SAFETY: socket has no memory preconditions.
    let raw = check(unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0) })?;
    // SAFETY: raw is a new descriptor that nothing else owns.
    let socket = unsafe { OwnedFd::from_raw_fd(raw) };
    crate::fd::set_cloexec(socket.as_fd())?;
    crate::fd::set_nonblocking(socket.as_fd())?;
    let length = libc::socklen_t::try_from(size_of::<libc::sockaddr_un>()).unwrap_or(106);
    crate::retry::retry(|| {
        // SAFETY: address is a sockaddr_un of length bytes, and socket is open.
        check(unsafe {
            libc::connect(
                socket.as_raw_fd(),
                (&raw const address).cast::<libc::sockaddr>(),
                length,
            )
        })
        .map(drop)
    })?;
    Ok(socket)
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
    use std::os::unix::net::{UnixListener, UnixStream};

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

    #[test]
    fn a_nonblocking_connect_reaches_a_listener_and_refuses_a_missing_path() {
        let dir = std::path::PathBuf::from(format!("/tmp/ko-sock-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("socket");
        let listener = UnixListener::bind(&path).unwrap();
        let socket = UnixStream::from(connect_nonblocking(&path).unwrap());
        let (accepted, _) = listener.accept().unwrap();
        assert_eq!(peer_uid(accepted.as_fd()).unwrap(), uid());
        assert_eq!(peer_uid(socket.as_fd()).unwrap(), uid());
        assert_eq!(
            connect_nonblocking(&dir.join("absent")).unwrap_err().kind(),
            io::ErrorKind::NotFound
        );
        assert_eq!(
            connect_nonblocking(&dir.join("x".repeat(200)))
                .unwrap_err()
                .kind(),
            io::ErrorKind::InvalidInput
        );
        std::fs::remove_dir_all(dir).unwrap();
    }
}
