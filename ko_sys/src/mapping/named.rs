use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::ptr::{self, NonNull};

#[cfg(target_os = "linux")]
use crate::retry::check_code;
use crate::retry::{check, retry};

const MAX_NAME: usize = 30;

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct Name(String);

impl Name {
    pub fn new(name: &str) -> Option<Name> {
        let body = name.strip_prefix('/')?;
        let valid = !body.is_empty()
            && name.len() <= MAX_NAME
            && body
                .bytes()
                .all(|byte| byte.is_ascii_graphic() && byte != b'/');
        valid.then(|| Name(name.to_owned()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub(super) fn c_string(&self) -> io::Result<std::ffi::CString> {
        std::ffi::CString::new(self.0.as_str()).map_err(io::Error::other)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Access {
    Writable,
    ReadOnly,
}

#[derive(Debug)]
pub struct Named {
    base: NonNull<u8>,
    len: usize,
    access: Access,
}

// SAFETY: the mapping is plain memory that the owner reads or writes through &self or &mut self.
unsafe impl Send for Named {}

pub(super) fn map_shared(fd: &OwnedFd, len: usize, writable: bool) -> io::Result<NonNull<u8>> {
    let protection = if writable {
        libc::PROT_READ | libc::PROT_WRITE
    } else {
        libc::PROT_READ
    };
    // SAFETY: a new shared mapping of fd; the kernel picks the address.
    let base = unsafe {
        libc::mmap(
            ptr::null_mut(),
            len,
            protection,
            libc::MAP_SHARED,
            fd.as_raw_fd(),
            0,
        )
    };
    if base == libc::MAP_FAILED {
        return Err(io::Error::last_os_error());
    }
    NonNull::new(base.cast()).ok_or_else(|| io::Error::other("mmap returned NULL"))
}

pub(super) fn truncate(fd: &OwnedFd, len: usize) -> io::Result<()> {
    let size = libc::off_t::try_from(len)
        .ok()
        .filter(|&size| size > 0)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "empty or huge object"))?;
    // SAFETY: fd is a shared memory object.
    retry(|| check(unsafe { libc::ftruncate(fd.as_raw_fd(), size) })).map(drop)
}

// A mapped tmpfs object reserves no pages: on a full /dev/shm the first write to a page raises
// SIGBUS, not an error. posix_fallocate reserves them, and returns the error number.
#[cfg(target_os = "linux")]
fn reserve(fd: &OwnedFd, len: usize) -> io::Result<()> {
    let size = libc::off_t::try_from(len).map_err(io::Error::other)?;
    // SAFETY: fd is a shared memory object.
    retry(|| check_code(unsafe { libc::posix_fallocate(fd.as_raw_fd(), 0, size) }))
}

#[cfg(target_os = "macos")]
fn reserve(_fd: &OwnedFd, _len: usize) -> io::Result<()> {
    Ok(())
}

pub(super) fn size_of(fd: &OwnedFd) -> io::Result<usize> {
    // SAFETY: an all-zero stat is valid, and fstat fills it.
    let mut stat: libc::stat = unsafe { std::mem::zeroed() };
    // SAFETY: stat is writable.
    check(unsafe { libc::fstat(fd.as_raw_fd(), &mut stat) })?;
    usize::try_from(stat.st_size).map_err(io::Error::other)
}

pub(super) fn open_fd(name: &Name, flags: libc::c_int, mode: libc::mode_t) -> io::Result<OwnedFd> {
    let path = name.c_string()?;
    // SAFETY: path is a NUL-terminated name, and the mode is the variadic argument.
    let raw =
        retry(|| check(unsafe { libc::shm_open(path.as_ptr(), flags, libc::c_uint::from(mode)) }))?;
    // SAFETY: shm_open returned a new descriptor that nothing else owns.
    let fd = unsafe { OwnedFd::from_raw_fd(raw) };
    crate::fd::set_cloexec(std::os::fd::AsFd::as_fd(&fd))?;
    Ok(fd)
}

impl Named {
    pub fn create(name: &Name, len: usize) -> io::Result<Named> {
        let fd = open_fd(name, libc::O_CREAT | libc::O_EXCL | libc::O_RDWR, 0o600)?;
        let mapped = truncate(&fd, len)
            .and_then(|()| reserve(&fd, len))
            .and_then(|()| map_shared(&fd, len, true));
        match mapped {
            Ok(base) => Ok(Named {
                base,
                len,
                access: Access::Writable,
            }),
            Err(error) => {
                let _ = unlink(name);
                Err(error)
            }
        }
    }

    pub fn open(name: &Name, len: usize) -> io::Result<Named> {
        let fd = open_fd(name, libc::O_RDONLY, 0)?;
        if len == 0 || size_of(&fd)? < len {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "object shorter than its length",
            ));
        }
        Ok(Named {
            base: map_shared(&fd, len, false)?,
            len,
            access: Access::ReadOnly,
        })
    }

    pub fn bytes(&self) -> &[u8] {
        // SAFETY: base maps len readable bytes until drop.
        unsafe { std::slice::from_raw_parts(self.base.as_ptr(), self.len) }
    }

    pub fn bytes_mut(&mut self) -> Option<&mut [u8]> {
        // SAFETY: base maps len writable bytes until drop, and &mut self is the only access.
        (self.access == Access::Writable)
            .then(|| unsafe { std::slice::from_raw_parts_mut(self.base.as_ptr(), self.len) })
    }
}

impl Drop for Named {
    fn drop(&mut self) {
        // SAFETY: base and len are the mapping that map created, unmapped once.
        unsafe { libc::munmap(self.base.as_ptr().cast(), self.len) };
    }
}

pub fn unlink(name: &Name) -> io::Result<()> {
    let path = name.c_string()?;
    // SAFETY: path is a NUL-terminated name.
    match check(unsafe { libc::shm_unlink(path.as_ptr()) }) {
        Err(error) if error.raw_os_error() == Some(libc::ENOENT) => Ok(()),
        other => other.map(|_| ()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn name(suffix: &str) -> Name {
        Name::new(&format!("/ko-t-{}-{suffix}", std::process::id())).unwrap()
    }

    #[test]
    fn a_name_is_a_short_flat_path() {
        assert!(Name::new("/ko-1234567-12345").is_some());
        for bad in [
            "ko",
            "/",
            "",
            "/a/b",
            "/a b",
            &format!("/{}", "x".repeat(30)),
        ] {
            assert_eq!(Name::new(bad), None, "{bad}");
        }
    }

    #[test]
    fn a_created_object_is_read_by_name_until_it_is_unlinked() {
        let name = name("read");
        let mut created = Named::create(&name, 5000).unwrap();
        created.bytes_mut().unwrap()[..3].copy_from_slice(b"abc");
        let opened = Named::open(&name, 5000).unwrap();
        assert_eq!(&opened.bytes()[..3], b"abc");
        assert_eq!(opened.bytes().len(), 5000);
        assert!(Named::create(&name, 10).is_err());
        let mut opened = opened;
        assert!(opened.bytes_mut().is_none());
        assert!(Named::open(&name, 5000 * 100).is_err());
        unlink(&name).unwrap();
        assert!(Named::open(&name, 5000).is_err());
        assert_eq!(&created.bytes()[..3], b"abc");
        unlink(&name).unwrap();
    }
}
