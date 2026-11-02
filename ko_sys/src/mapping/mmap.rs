#[cfg(target_os = "macos")]
use std::ffi::CString;
use std::io;
use std::os::fd::{AsFd, AsRawFd, BorrowedFd, FromRawFd, OwnedFd};
use std::ptr::{self, NonNull};
#[cfg(target_os = "macos")]
use std::sync::atomic::{AtomicU32, Ordering};

use crate::retry::{check, retry};

#[derive(Debug)]
pub struct Mapping {
    base: NonNull<u8>,
    len: usize,
    fd: OwnedFd,
}

#[cfg(target_os = "macos")]
static NEXT: AtomicU32 = AtomicU32::new(0);

#[cfg(target_os = "macos")]
fn create() -> io::Result<OwnedFd> {
    loop {
        let pid = std::process::id();
        let name = CString::new(format!(
            "/ko-ring-{pid}-{}",
            NEXT.fetch_add(1, Ordering::SeqCst)
        ))
        .map_err(io::Error::other)?;
        let flags = libc::O_CREAT | libc::O_EXCL | libc::O_RDWR;
        // SAFETY: name is a NUL-terminated path, and the mode is the variadic argument.
        match retry(|| check(unsafe { libc::shm_open(name.as_ptr(), flags, 0o600) })) {
            Ok(raw) => {
                // SAFETY: shm_open returned a new descriptor that nothing else owns.
                let fd = unsafe { OwnedFd::from_raw_fd(raw) };
                // SAFETY: name names the object just created.
                check(unsafe { libc::shm_unlink(name.as_ptr()) })?;
                crate::fd::set_cloexec(fd.as_fd())?;
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

fn map(fd: OwnedFd, len: usize) -> io::Result<Mapping> {
    // SAFETY: a new shared mapping of fd; the kernel picks the address.
    let base = unsafe {
        libc::mmap(
            ptr::null_mut(),
            len,
            libc::PROT_READ | libc::PROT_WRITE,
            libc::MAP_SHARED,
            fd.as_raw_fd(),
            0,
        )
    };
    if base == libc::MAP_FAILED {
        return Err(io::Error::last_os_error());
    }
    let base = NonNull::new(base.cast()).ok_or_else(|| io::Error::other("mmap returned NULL"))?;
    Ok(Mapping { base, len, fd })
}

impl Mapping {
    pub fn shared(len: usize) -> io::Result<Mapping> {
        let size = libc::off_t::try_from(len)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "mapping too large"))?;
        let fd = create()?;
        // SAFETY: fd is the new shared memory object.
        retry(|| check(unsafe { libc::ftruncate(fd.as_raw_fd(), size) }))?;
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
        Mapping::attach(self.fd.try_clone()?)
    }

    pub fn attach(fd: OwnedFd) -> io::Result<Mapping> {
        // SAFETY: an all-zero stat is valid, and fstat fills it.
        let mut stat: libc::stat = unsafe { std::mem::zeroed() };
        // SAFETY: stat is writable.
        check(unsafe { libc::fstat(fd.as_raw_fd(), &mut stat) })?;
        let len = usize::try_from(stat.st_size)
            .ok()
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
