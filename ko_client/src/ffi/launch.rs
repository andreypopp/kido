use super::{Buffer, Code, put, text_of};
use crate::connect::PATIENCE;
use crate::launch;
use std::ffi::c_char;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

/// # Safety
///
/// `out` is writable for one `ko_buffer`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_client_default_dir(out: *mut Buffer) -> Code {
    if out.is_null() {
        return Code::Argument;
    }
    let (code, bytes) = match std::path::absolute(ko_wire::local::dir(None)) {
        Ok(path) => match path.to_str() {
            Some(path) => (Code::Ok, path.as_bytes().to_vec()),
            None => (Code::Io, b"the server directory is not UTF-8".to_vec()),
        },
        Err(error) => (Code::Io, error.to_string().into_bytes()),
    };
    // SAFETY: out is null or writable for one ko_buffer (ko_client.h).
    unsafe { put(out, bytes) };
    code
}

/// # Safety
///
/// `dir` and `executable` are NUL-terminated strings. `path` and `cwd` are null or
/// NUL-terminated strings. `socket` is writable for
/// one `ko_buffer`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_client_launch(
    dir: *const c_char,
    executable: *const c_char,
    path: *const c_char,
    cwd: *const c_char,
    socket: *mut Buffer,
) -> Code {
    let scope = ();
    // SAFETY: ko_client.h requires these inputs to remain readable for this call.
    let (dir_text, executable_text, path_text, cwd_text) = unsafe {
        (
            text_of(dir, &scope),
            text_of(executable, &scope),
            text_of(path, &scope),
            text_of(cwd, &scope),
        )
    };

    let (Some(dir), Some(executable)) = (dir_text, executable_text) else {
        return Code::Argument;
    };
    if socket.is_null() {
        return Code::Argument;
    }
    let path = match (path.is_null(), path_text) {
        (false, None) => return Code::Argument,
        (_, path) => path,
    };
    let cwd = match (cwd.is_null(), cwd_text) {
        (false, None) => return Code::Argument,
        (_, cwd) => cwd.map(Path::new),
    };
    let (code, bytes) =
        match launch::attach(Path::new(dir), Path::new(executable), path, cwd, PATIENCE) {
            Ok((path, _stream)) => (Code::Ok, path.as_os_str().as_bytes().to_vec()),
            Err(message) => (Code::Io, message.into_bytes()),
        };
    // SAFETY: out is null or writable for one ko_buffer (ko_client.h).
    unsafe { put(socket, bytes) };
    code
}

/// # Safety
///
/// `dir` is a NUL-terminated string. `error` is null or writable for one
/// `ko_buffer`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_client_stop_server(dir: *const c_char, error: *mut Buffer) -> Code {
    let scope = ();
    // SAFETY: ko_client.h requires these inputs to remain readable for this call.
    let dir_text = unsafe { text_of(dir, &scope) };

    let Some(dir) = dir_text else {
        return Code::Argument;
    };
    let (code, bytes) = match launch::stop(Path::new(dir), PATIENCE) {
        Ok(()) => (Code::Ok, Vec::new()),
        Err(message) => (Code::Io, message.into_bytes()),
    };
    // SAFETY: out is null or writable for one ko_buffer (ko_client.h).
    unsafe { put(error, bytes) };
    code
}
