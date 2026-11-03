// The classifiers of the ssh steps of a remote host, pure: the caller runs ssh and passes what it saw.

use std::ffi::{c_char, c_int};

use ko_sys::pid::Exit;

use super::{Buffer, Code, bytes_of, empty, hand_over, text_of};
use crate::remote::{self, Error};

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SshRun {
    pub status: c_int,
    pub signaled: bool,
    pub stdout_data: *const u8,
    pub stdout_len: usize,
    pub stderr_data: *const u8,
    pub stderr_len: usize,
}

/// # Safety
///
/// `host` is a NUL-terminated string. `run` is null or points to a `ko_ssh_run` whose
/// buffers are readable for their lengths. `out` is writable for one `ko_buffer`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_remote_socket(
    host: *const c_char,
    run: *const SshRun,
    out: *mut Buffer,
) -> Code {
    // SAFETY: run is null or points to a live ko_ssh_run by contract.
    let run = unsafe { run.as_ref() };
    let (Some(host), Some(run)) = (text_of(host), run) else {
        return Code::Argument;
    };
    let (Some(stdout), Some(stderr)) = (
        bytes_of(run.stdout_data, run.stdout_len),
        bytes_of(run.stderr_data, run.stderr_len),
    ) else {
        return Code::Argument;
    };
    if out.is_null() {
        return Code::Argument;
    }
    let exit = if run.signaled {
        Exit::Signaled(run.status)
    } else {
        Exit::Exited(run.status)
    };
    match remote::remote_socket(host, exit, stdout, stderr) {
        Ok(path) => {
            hand_over(out, path.into_bytes());
            Code::Ok
        }
        Err(error) => {
            let code = match error {
                Error::NoRemoteKo { .. } => Code::NotFound,
                Error::Query { .. } => Code::Invalid,
                _ => Code::Io,
            };
            hand_over(out, error.to_string().into_bytes());
            code
        }
    }
}

/// # Safety
///
/// `host` is a NUL-terminated string. `out` is writable for one `ko_buffer`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_remote_unreachable(
    host: *const c_char,
    remote_answers: bool,
    out: *mut Buffer,
) -> Code {
    let Some(host) = text_of(host).filter(|_| !out.is_null()) else {
        return Code::Argument;
    };
    empty(out);
    let error = remote::unreachable(host, remote_answers);
    hand_over(out, error.to_string().into_bytes());
    if remote_answers {
        Code::Refused
    } else {
        Code::NoServer
    }
}
