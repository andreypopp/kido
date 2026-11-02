use std::io;

pub fn bytes() -> io::Result<[u8; 16]> {
    let mut bytes = [0; 16];
    // SAFETY: the pointer and the length come from one live array, and getentropy accepts up to
    // 256 bytes.
    let result = unsafe { libc::getentropy(bytes.as_mut_ptr().cast(), bytes.len()) };
    if result == 0 {
        Ok(bytes)
    } else {
        Err(io::Error::last_os_error())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn two_reads_differ() {
        assert_ne!(bytes().unwrap(), bytes().unwrap());
    }
}
