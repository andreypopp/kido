#[cfg(miri)]
mod heap;
#[cfg(not(miri))]
mod mmap;

#[cfg(miri)]
pub use heap::Mapping;
#[cfg(not(miri))]
pub use mmap::Mapping;
