#![allow(unsafe_code)]

use std::io;
use std::ops::Range;
use std::os::fd::BorrowedFd;
use std::sync::atomic::{AtomicU64, Ordering};

use ko_sys::mapping::Mapping;

use super::{Index, Invalid, valid_capacity};

pub(super) const DATA: usize = 32;

#[derive(Debug)]
pub(super) struct Shared {
    mapping: Mapping,
    capacity: u64,
}

fn room(mapping: &Mapping) -> u64 {
    mapping
        .size()
        .checked_sub(DATA)
        .and_then(|room| u64::try_from(room).ok())
        .unwrap_or(0)
}

impl Shared {
    pub(super) fn create(capacity: u64) -> io::Result<Shared> {
        let invalid =
            |_| io::Error::new(io::ErrorKind::InvalidInput, Invalid::Capacity.to_string());
        valid_capacity(capacity, u64::MAX).map_err(invalid)?;
        let len = usize::try_from(capacity)
            .ok()
            .and_then(|capacity| capacity.checked_add(DATA))
            .ok_or_else(|| invalid(Invalid::Capacity))?;
        let mapping = Mapping::shared(len)?;
        // SAFETY: the new mapping is zero-filled, page-aligned and longer than the header; no
        // other process has it yet.
        unsafe { mapping.base().cast::<u64>().write(capacity) };
        Ok(Shared { mapping, capacity })
    }

    pub(super) fn duplicate(&self) -> io::Result<Shared> {
        Ok(Shared {
            mapping: self.mapping.duplicate()?,
            capacity: self.capacity,
        })
    }

    pub(super) fn attach(mapping: Mapping) -> Result<Shared, Invalid> {
        if mapping.size() < DATA {
            return Err(Invalid::Capacity);
        }
        // SAFETY: the header's first word is the capacity, written before the mapping is shared.
        let capacity = unsafe { mapping.base().cast::<u64>().read() };
        let capacity = valid_capacity(capacity, room(&mapping))?;
        Ok(Shared { mapping, capacity })
    }

    pub(super) fn capacity(&self) -> u64 {
        self.capacity
    }

    pub(super) fn fd(&self) -> BorrowedFd<'_> {
        self.mapping.fd()
    }

    fn word(&self, index: Index) -> &AtomicU64 {
        // SAFETY: the header holds four aligned u64 words that both processes access only as
        // atomics, and the mapping outlives the borrow.
        unsafe {
            AtomicU64::from_ptr(
                self.mapping
                    .base()
                    .cast::<u64>()
                    .add(index as usize)
                    .as_ptr(),
            )
        }
    }

    pub(super) fn load(&self, index: Index) -> u64 {
        self.word(index).load(Ordering::SeqCst)
    }

    pub(super) fn store(&self, index: Index, value: u64) {
        self.word(index).store(value, Ordering::SeqCst);
    }

    fn data(&self, at: u64, len: usize) -> Option<*mut u8> {
        let index = usize::try_from(at.checked_rem(self.capacity)?).ok()?;
        let capacity = usize::try_from(self.capacity).ok()?;
        if index.checked_add(len)? > capacity {
            return None;
        }
        // SAFETY: DATA + index + len lies inside the mapping, which is DATA + capacity long.
        Some(unsafe { self.mapping.base().as_ptr().add(DATA).add(index) })
    }

    pub(super) fn bytes(&self, readable: Range<u64>, at: u64, len: u64) -> Option<&[u8]> {
        let end = at.checked_add(len)?;
        if at < readable.start
            || end > readable.end
            || readable.end.checked_sub(readable.start)? > self.capacity
        {
            return None;
        }
        let len = usize::try_from(len).ok()?;
        let start = self.data(at, len)?;
        // SAFETY: the bytes lie inside the mapping and inside [tail, seen) of the reader, which
        // the writer does not change until the reader stores a new tail.
        Some(unsafe { std::slice::from_raw_parts(start, len) })
    }

    pub(super) fn copy(&self, readable: Range<u64>, at: u64, out: &mut [u8]) -> Option<()> {
        out.copy_from_slice(self.bytes(readable, at, u64::try_from(out.len()).ok()?)?);
        Some(())
    }

    pub(super) fn room(&mut self, at: u64, len: usize) -> Option<&mut [u8]> {
        let start = self.data(at, len)?;
        // SAFETY: the bytes lie inside the mapping; the writer owns its room, which no reader
        // reads before the writer publishes a head past it, and `&mut self` is its only handle.
        Some(unsafe { std::slice::from_raw_parts_mut(start, len) })
    }

    pub(super) fn write(&self, at: u64, bytes: &[u8]) -> Option<()> {
        let start = self.data(at, bytes.len())?;
        // SAFETY: the bytes lie inside the mapping; the writer writes only its room, which no
        // reader reads before the writer publishes a head past it.
        unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), start, bytes.len()) };
        Some(())
    }
}
