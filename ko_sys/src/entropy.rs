use std::io;

// libc binds getentropy for glibc and macOS but not for musl, so ko declares it for every target.
unsafe extern "C" {
    fn getentropy(buffer: *mut libc::c_void, length: libc::size_t) -> libc::c_int;
}

pub fn bytes() -> io::Result<[u8; 16]> {
    let mut bytes = [0; 16];
    // SAFETY: the pointer and the length come from one live array, and getentropy accepts up to
    // 256 bytes.
    let result = unsafe { getentropy(bytes.as_mut_ptr().cast(), bytes.len()) };
    if result == 0 {
        Ok(bytes)
    } else {
        Err(io::Error::last_os_error())
    }
}

pub fn hex(count: usize) -> io::Result<String> {
    Ok(bytes()?
        .iter()
        .take(count)
        .map(|byte| format!("{byte:02x}"))
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hex_is_two_lowercase_digits_for_each_requested_byte() {
        let text = hex(5).unwrap();
        assert!(
            text.len() == 10
                && text
                    .bytes()
                    .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
        );
        assert_eq!(hex(16).unwrap().len(), 32);
    }

    #[test]
    fn two_reads_differ() {
        assert_ne!(bytes().unwrap(), bytes().unwrap());
    }
}
