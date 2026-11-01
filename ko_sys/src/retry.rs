use std::io;

pub fn retry<T>(mut call: impl FnMut() -> io::Result<T>) -> io::Result<T> {
    loop {
        match call() {
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            result => return result,
        }
    }
}

pub(crate) fn check(result: libc::c_int) -> io::Result<libc::c_int> {
    if result == -1 {
        Err(io::Error::last_os_error())
    } else {
        Ok(result)
    }
}

pub(crate) fn check_code(code: libc::c_int) -> io::Result<()> {
    match code {
        0 => Ok(()),
        code => Err(io::Error::from_raw_os_error(code)),
    }
}

pub(crate) fn check_size(result: libc::ssize_t) -> io::Result<usize> {
    usize::try_from(result).map_err(|_| io::Error::last_os_error())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn retry_repeats_only_an_interrupted_call() {
        let mut calls = 0;
        let result = retry(|| {
            calls += 1;
            match calls {
                1 | 2 => Err(io::Error::from(io::ErrorKind::Interrupted)),
                _ => Ok(calls),
            }
        });
        assert_eq!(result.unwrap(), 3);
        let mut calls = 0;
        let result: io::Result<()> = retry(|| {
            calls += 1;
            Err(io::Error::from(io::ErrorKind::WouldBlock))
        });
        assert_eq!(result.unwrap_err().kind(), io::ErrorKind::WouldBlock);
        assert_eq!(calls, 1);
    }
}
