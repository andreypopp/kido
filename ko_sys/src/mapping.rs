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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_empty_mapping_is_rejected() {
        assert_eq!(
            Mapping::shared(0).unwrap_err().kind(),
            std::io::ErrorKind::InvalidInput
        );
    }
}
