use std::alloc::{Layout, alloc_zeroed, dealloc};
use std::io;
use std::os::fd::{AsFd, BorrowedFd, OwnedFd};
use std::ptr::NonNull;
use std::rc::Rc;

// Miri runs neither shm_open nor mmap, so a mapping is heap memory that `duplicate` shares.
// Its descriptor is /dev/null, which needs -Zmiri-disable-isolation.
#[derive(Debug)]
struct Heap {
    base: NonNull<u8>,
    layout: Layout,
}

impl Drop for Heap {
    fn drop(&mut self) {
        // SAFETY: base came from alloc_zeroed with this layout and is freed once.
        unsafe { dealloc(self.base.as_ptr(), self.layout) };
    }
}

#[derive(Debug)]
pub struct Mapping {
    base: NonNull<u8>,
    len: usize,
    fd: OwnedFd,
    _heap: Rc<Heap>,
}

impl Mapping {
    pub fn shared(len: usize) -> io::Result<Mapping> {
        let layout = Layout::from_size_align(len, 4096).map_err(io::Error::other)?;
        // SAFETY: len is not zero, because the ring header alone is longer.
        let base = unsafe { alloc_zeroed(layout) };
        let base = NonNull::new(base).ok_or_else(|| io::Error::other("out of memory"))?;
        Ok(Mapping {
            base,
            len,
            fd: OwnedFd::from(std::fs::File::open("/dev/null")?),
            _heap: Rc::new(Heap { base, layout }),
        })
    }

    pub fn duplicate(&self) -> io::Result<Mapping> {
        Ok(Mapping {
            base: self.base,
            len: self.len,
            fd: self.fd.try_clone()?,
            _heap: self._heap.clone(),
        })
    }

    pub fn attach(_fd: OwnedFd) -> io::Result<Mapping> {
        Err(io::ErrorKind::Unsupported.into())
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
