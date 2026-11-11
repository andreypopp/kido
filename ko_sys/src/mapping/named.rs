use std::fs::File;
use std::io;
use std::os::fd::{AsRawFd, BorrowedFd, FromRawFd, OwnedFd};
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

// SAFETY: moving the mapping does not move its address; access uses raw copies or syscalls,
// and no Rust reference to its shared bytes is created.
unsafe impl Send for Named {}

pub(super) fn map_shared(fd: &File, len: usize, writable: bool) -> io::Result<NonNull<u8>> {
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

// A mapped tmpfs object reserves no pages: on a full /dev/shm the first write to a page raises
// SIGBUS, not an error. posix_fallocate reserves them, and returns the error number.
#[cfg(target_os = "linux")]
fn reserve(fd: &File, len: usize) -> io::Result<()> {
    let size = libc::off_t::try_from(len).map_err(io::Error::other)?;
    // SAFETY: fd is a shared memory object.
    retry(|| check_code(unsafe { libc::posix_fallocate(fd.as_raw_fd(), 0, size) }))
}

#[cfg(target_vendor = "apple")]
fn reserve(_fd: &File, _len: usize) -> io::Result<()> {
    Ok(())
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
        let fd = File::from(open_fd(
            name,
            libc::O_CREAT | libc::O_EXCL | libc::O_RDWR,
            0o600,
        )?);
        let mapped = u64::try_from(len)
            .map_err(io::Error::other)
            .and_then(|len| fd.set_len(len))
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
        let fd = File::from(open_fd(name, libc::O_RDONLY, 0)?);
        if len == 0 || fd.metadata()?.len() < u64::try_from(len).map_err(io::Error::other)? {
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

    pub fn size(&self) -> usize {
        self.len
    }

    pub fn write(&mut self, offset: usize, bytes: &[u8]) -> io::Result<()> {
        if self.access != Access::Writable {
            return Err(io::ErrorKind::PermissionDenied.into());
        }
        if offset
            .checked_add(bytes.len())
            .is_none_or(|end| end > self.len)
        {
            return Err(io::ErrorKind::InvalidInput.into());
        }
        // SAFETY: only create's O_EXCL handle is writable; &mut self excludes other Rust
        // access in this process. The checked range is disjoint from bytes. Other accesses
        // are kernel reads through write_to or accesses in another process.
        unsafe {
            ptr::copy_nonoverlapping(bytes.as_ptr(), self.base.as_ptr().add(offset), bytes.len())
        };
        Ok(())
    }

    pub fn write_to(&self, fd: BorrowedFd<'_>, offset: usize, limit: usize) -> io::Result<usize> {
        let len = self.len.saturating_sub(offset).min(limit);
        if len == 0 {
            return Ok(0);
        }
        // SAFETY: fd is open and the checked range remains mapped during write. The kernel
        // reads the mapped pages, which concurrent writers may change; no Rust reference is formed.
        unsafe { crate::fd::write_raw(fd, self.base.as_ptr().add(offset), len) }
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

    fn read(object: &Named, len: usize) -> Vec<u8> {
        use std::io::Read;
        use std::os::fd::AsFd;
        let (mut reader, writer) = std::io::pipe().unwrap();
        assert_eq!(object.write_to(writer.as_fd(), 0, len).unwrap(), len);
        let mut bytes = vec![0; len];
        reader.read_exact(&mut bytes).unwrap();
        bytes
    }

    #[test]
    fn kernel_reads_do_not_borrow_the_mapping_and_writes_use_checked_ranges() {
        use std::io::Read;
        use std::os::fd::AsFd;
        let name = name("copy");
        let mut object = Named::create(&name, 8).unwrap();
        object.write(0, b"abcdefgh").unwrap();
        let copy = read(&object, 8);
        object.write(0, b"X").unwrap();
        assert_eq!(copy, b"abcdefgh");
        assert!(object.write(usize::MAX, b"x").is_err());
        let (mut reader, writer) = std::io::pipe().unwrap();
        assert_eq!(object.write_to(writer.as_fd(), 2, 3).unwrap(), 3);
        assert_eq!(object.write_to(writer.as_fd(), usize::MAX, 3).unwrap(), 0);
        let mut found = [0; 3];
        reader.read_exact(&mut found).unwrap();
        assert_eq!(&found, b"cde");
        unlink(&name).unwrap();
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
        created.write(0, b"abc").unwrap();
        let opened = Named::open(&name, 5000).unwrap();
        assert_eq!(read(&opened, 3), b"abc");
        assert_eq!(opened.size(), 5000);
        assert!(Named::create(&name, 10).is_err());
        let mut opened = opened;
        assert_eq!(
            opened.write(0, b"x").unwrap_err().kind(),
            io::ErrorKind::PermissionDenied
        );
        assert!(created.write(4999, b"xx").is_err());
        assert!(Named::open(&name, 5000 * 100).is_err());
        unlink(&name).unwrap();
        assert!(Named::open(&name, 5000).is_err());
        assert_eq!(read(&created, 3), b"abc");
        unlink(&name).unwrap();
    }
}
