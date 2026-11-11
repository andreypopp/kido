// The classifiers of the ssh steps of a remote host, pure: the caller runs ssh and passes what it saw.

use std::ffi::{c_char, c_int};

use ko_sys::pid::Exit;

use super::{Buffer, Code, put, slice_of, text_of};
use crate::remote::{self, Failure};

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
    let scope = ();
    // SAFETY: ko_client.h requires host, run and its buffers to remain readable for this call.
    let (host, run, stdout, stderr) = unsafe {
        let run = run.as_ref();
        let (stdout, stderr) = match run {
            Some(run) => (
                slice_of(run.stdout_data, run.stdout_len, &scope),
                slice_of(run.stderr_data, run.stderr_len, &scope),
            ),
            None => (None, None),
        };
        (text_of(host, &scope), run, stdout, stderr)
    };
    let (Some(host), Some(run), Some(stdout), Some(stderr)) = (host, run, stdout, stderr) else {
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
    let (code, bytes) = match remote::remote_socket(host, exit, stdout, stderr) {
        Ok(path) => (Code::Ok, path.into_bytes()),
        Err(error) => {
            let code = match error {
                Failure::NoRemoteKo { .. } => Code::NotFound,
                Failure::Query { .. } => Code::Invalid,
                _ => Code::Io,
            };
            (code, error.to_string().into_bytes())
        }
    };
    // SAFETY: out is null or writable for one ko_buffer (ko_client.h).
    unsafe { put(out, bytes) };
    code
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
    let scope = ();
    // SAFETY: ko_client.h requires these inputs to remain readable for this call.
    let host_text = unsafe { text_of(host, &scope) };

    let Some(host) = host_text.filter(|_| !out.is_null()) else {
        return Code::Argument;
    };
    let error = remote::unreachable(host, remote_answers);
    // SAFETY: out is null or writable for one ko_buffer (ko_client.h).
    unsafe { put(out, error.to_string().into_bytes()) };
    if remote_answers {
        Code::Refused
    } else {
        Code::NoServer
    }
}
