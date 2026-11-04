use std::io;

pub fn name() -> io::Result<String> {
    let mut buffer = [0u8; 256];
    // SAFETY: the pointer and the length come from one live array; gethostname writes at most
    // that many bytes.
    let result = unsafe { libc::gethostname(buffer.as_mut_ptr().cast(), buffer.len()) };
    if result != 0 {
        return Err(io::Error::last_os_error());
    }
    let end = buffer
        .iter()
        .position(|byte| *byte == 0)
        .unwrap_or(buffer.len());
    let name = buffer.get(..end).unwrap_or_default();
    String::from_utf8(name.to_vec())
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
}

#[cfg(test)]
mod tests {
    #[test]
    fn the_host_has_a_name() {
        assert!(!super::name().unwrap().is_empty());
    }
}
