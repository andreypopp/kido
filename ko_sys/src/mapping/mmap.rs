use std::fs::File;
use std::io;
use std::os::fd::{AsFd, BorrowedFd, OwnedFd};
#[cfg(target_os = "linux")]
use std::os::fd::{AsRawFd, FromRawFd};
use std::ptr::NonNull;
#[cfg(target_vendor = "apple")]
use std::sync::atomic::{AtomicU32, Ordering};

use super::named::map_shared;
#[cfg(target_vendor = "apple")]
use super::named::{Name, open_fd, unlink};
#[cfg(target_os = "linux")]
use crate::retry::{check, retry};

#[derive(Debug)]
pub struct Mapping {
    base: NonNull<u8>,
    len: usize,
    fd: File,
}

#[cfg(target_vendor = "apple")]
static NEXT: AtomicU32 = AtomicU32::new(0);

#[cfg(target_vendor = "apple")]
fn create() -> io::Result<OwnedFd> {
    loop {
        let name = Name::new(&format!(
            "/ko-ring-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::SeqCst)
        ))
        .ok_or_else(|| io::Error::other("invalid ring name"))?;
        match open_fd(&name, libc::O_CREAT | libc::O_EXCL | libc::O_RDWR, 0o600) {
            Ok(fd) => {
                unlink(&name)?;
                return Ok(fd);
            }
            Err(error) if error.raw_os_error() == Some(libc::EEXIST) => {}
            Err(error) => return Err(error),
        }
    }
}

#[cfg(target_os = "linux")]
fn create() -> io::Result<OwnedFd> {
    let raw = retry(|| {
        // SAFETY: the name is a NUL-terminated string.
        check(unsafe {
            libc::memfd_create(
                c"ko-ring".as_ptr(),
                libc::MFD_CLOEXEC | libc::MFD_ALLOW_SEALING,
            )
        })
    })?;
    // SAFETY: memfd_create returned a new descriptor that nothing else owns.
    Ok(unsafe { OwnedFd::from_raw_fd(raw) })
}

fn map(fd: File, len: usize) -> io::Result<Mapping> {
    let base = map_shared(&fd, len, true)?;
    Ok(Mapping { base, len, fd })
}

impl Mapping {
    pub fn shared(len: usize) -> io::Result<Mapping> {
        if len == 0 {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "empty mapping"));
        }
        let fd = File::from(create()?);
        fd.set_len(u64::try_from(len).map_err(io::Error::other)?)?;
        #[cfg(target_os = "linux")]
        // SAFETY: fd is open; the seals stop the other process from shrinking the ring under a
        // mapping (SIGBUS) or growing it.
        check(unsafe {
            libc::fcntl(
                fd.as_raw_fd(),
                libc::F_ADD_SEALS,
                libc::F_SEAL_SHRINK | libc::F_SEAL_GROW | libc::F_SEAL_SEAL,
            )
        })?;
        map(fd, len)
    }

    pub fn duplicate(&self) -> io::Result<Mapping> {
        Mapping::attach(self.fd.try_clone()?.into())
    }

    pub fn attach(fd: OwnedFd) -> io::Result<Mapping> {
        let fd = File::from(fd);
        let len = Some(usize::try_from(fd.metadata()?.len()).map_err(io::Error::other)?)
            .filter(|&len| len > 0)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "empty mapping"))?;
        map(fd, len)
    }

    pub fn base(&self) -> NonNull<u8> {
        self.base
    }

    pub fn size(&self) -> usize {
        self.len
    }

    pub fn fd(&self) -> BorrowedFd<'_> {
        self.fd.as_fd()
    }
}

impl Drop for Mapping {
    fn drop(&mut self) {
        // SAFETY: base and len are the mapping that map created, unmapped once.
        unsafe { libc::munmap(self.base.as_ptr().cast(), self.len) };
    }
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::*;

    fn fcntl(fd: BorrowedFd<'_>, command: libc::c_int) -> io::Result<libc::c_int> {
        // SAFETY: fd is open for the borrow, and the commands take no argument.
        check(unsafe { libc::fcntl(fd.as_raw_fd(), command) })
    }

    #[test]
    fn a_memfd_ring_is_close_on_exec_sealed_and_shared_by_a_duplicate() {
        let ring = Mapping::shared(1 << 16).unwrap();
        assert_ne!(
            fcntl(ring.fd(), libc::F_GETFD).unwrap() & libc::FD_CLOEXEC,
            0
        );
        assert_eq!(
            fcntl(ring.fd(), libc::F_GET_SEALS).unwrap(),
            libc::F_SEAL_SHRINK | libc::F_SEAL_GROW | libc::F_SEAL_SEAL
        );
        // SAFETY: fd is open for the borrow, and the sealed size refuses both calls.
        let grown = unsafe { libc::ftruncate(ring.fd().as_raw_fd(), 1 << 17) };
        assert_eq!(grown, -1);
        let twin = ring.duplicate().unwrap();
        assert_eq!(twin.size(), 1 << 16);
        // SAFETY: both mappings are 1 << 16 bytes long.
        unsafe {
            ring.base().as_ptr().write(7);
            assert_eq!(twin.base().as_ptr().read(), 7);
        }
    }
}
