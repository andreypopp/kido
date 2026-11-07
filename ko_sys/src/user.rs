use std::ffi::{CStr, OsString};
use std::io;
use std::mem::MaybeUninit;
use std::os::unix::ffi::OsStringExt;
use std::path::PathBuf;

pub fn login_shell() -> io::Result<Option<PathBuf>> {
    // SAFETY: getuid and sysconf do not take pointers.
    let (uid, suggested) = unsafe { (libc::getuid(), libc::sysconf(libc::_SC_GETPW_R_SIZE_MAX)) };
    let cap = 1024 * 1024;
    let mut size = usize::try_from(suggested).unwrap_or(1024).clamp(1024, cap);
    loop {
        let mut buffer = vec![0u8; size];
        let mut pwd = MaybeUninit::<libc::passwd>::uninit();
        let mut result = std::ptr::null_mut();
        let lookup = crate::retry::retry(|| {
            // SAFETY: pwd and result are writable and buffer has size writable bytes.
            crate::retry::check_code(unsafe {
                libc::getpwuid_r(
                    uid,
                    pwd.as_mut_ptr(),
                    buffer.as_mut_ptr().cast(),
                    size,
                    &mut result,
                )
            })
        });
        if let Err(error) = lookup {
            if error.raw_os_error() == Some(libc::ERANGE) && size < cap {
                size = size.saturating_mul(2).min(cap);
                continue;
            }
            return Err(error);
        }
        if result != pwd.as_mut_ptr() {
            return Ok(None);
        }
        // SAFETY: getpwuid_r returned success with result pointing to pwd.
        let pwd = unsafe { pwd.assume_init() };
        if pwd.pw_shell.is_null() {
            return Ok(None);
        }
        // SAFETY: the successful lookup gives a terminated string in the live buffer.
        let shell = unsafe { CStr::from_ptr(pwd.pw_shell) };
        let path = PathBuf::from(OsString::from_vec(shell.to_bytes().to_vec()));
        return Ok(path.is_absolute().then_some(path));
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn current_user_has_an_absolute_login_shell() {
        assert!(super::login_shell().unwrap().unwrap().is_absolute());
    }
}
