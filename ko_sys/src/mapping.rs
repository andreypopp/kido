#[cfg(miri)]
mod heap;
#[cfg(not(miri))]
mod mmap;
mod named;

#[cfg(miri)]
pub use heap::Mapping;
#[cfg(not(miri))]
pub use mmap::Mapping;

pub use named::{Name, Named, unlink};
