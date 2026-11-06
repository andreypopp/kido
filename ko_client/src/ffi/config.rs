use std::ffi::c_char;
use std::path::{Path, PathBuf};

use ko_config::config::{self, LoadError};
use ko_config::theme::{self, SetError};
use serde_json::json;

use super::{Buffer, Code, put, text_of};

fn message(code: Code, text: &str) -> (Code, Vec<u8>) {
    (
        code,
        json!({ "error": { "message": text } })
            .to_string()
            .into_bytes(),
    )
}

fn invalid(problem: &ko_config::yaml::Problem) -> (Code, Vec<u8>) {
    (
        Code::Invalid,
        json!({ "error": problem }).to_string().into_bytes(),
    )
}

/// # Safety
///
/// `out` is writable for one `ko_buffer`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_config_defaults(out: *mut Buffer) -> Code {
    if out.is_null() {
        return Code::Argument;
    }
    let home = std::env::var_os("HOME")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .or_else(std::env::home_dir)
        .unwrap_or_else(|| PathBuf::from("/"));
    let config_home = std::env::var_os("XDG_CONFIG_HOME")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from);
    let path = config::default_path(config_home.as_deref(), &home);
    let (code, bytes) = match path.to_str() {
        Some(path) => (
            Code::Ok,
            json!({ "path": path, "config": config::Config::default() })
                .to_string()
                .into_bytes(),
        ),
        None => message(Code::Io, "the configuration path is not UTF-8"),
    };
    // SAFETY: out is null or writable for one ko_buffer (ko_client.h).
    unsafe { put(out, bytes) };
    code
}

/// # Safety
///
/// `path` is a NUL-terminated string. `out` is writable for one `ko_buffer`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_config_load(path: *const c_char, out: *mut Buffer) -> Code {
    let scope = ();
    // SAFETY: ko_client.h requires these inputs to remain readable for this call.
    let path_text = unsafe { text_of(path, &scope) };

    if out.is_null() {
        return Code::Argument;
    }
    let (code, bytes) = match path_text {
        Some(path) => match config::load(Path::new(path)) {
            Ok(config) => (
                Code::Ok,
                json!({ "config": config }).to_string().into_bytes(),
            ),
            Err(LoadError::Invalid(problem)) => invalid(&problem),
            Err(LoadError::Io(text)) => message(Code::Io, &text),
        },
        None => (Code::Argument, Vec::new()),
    };
    // SAFETY: out is null or writable for one ko_buffer (ko_client.h).
    unsafe { put(out, bytes) };
    code
}

/// # Safety
///
/// `path`, `light` and `dark` are NUL-terminated strings. `out` is writable for one `ko_buffer`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_config_set_theme(
    path: *const c_char,
    light: *const c_char,
    dark: *const c_char,
    out: *mut Buffer,
) -> Code {
    let scope = ();
    // SAFETY: ko_client.h requires these inputs to remain readable for this call.
    let (path_text, light_text, dark_text) = unsafe {
        (
            text_of(path, &scope),
            text_of(light, &scope),
            text_of(dark, &scope),
        )
    };

    if out.is_null() {
        return Code::Argument;
    }
    let (code, bytes) = match (path_text, light_text, dark_text) {
        (Some(path), Some(light), Some(dark)) => {
            match theme::set_theme(Path::new(path), light, dark) {
                Ok(written) => (
                    Code::Ok,
                    json!({ "written": written }).to_string().into_bytes(),
                ),
                Err(SetError::Name(text)) => message(Code::Argument, &text),
                Err(SetError::Changed) => message(
                    Code::Conflict,
                    "the file changed while the theme was written",
                ),
                Err(SetError::Invalid(problem)) => invalid(&problem),
                Err(SetError::Io(text)) => message(Code::Io, &text),
            }
        }
        _ => (Code::Argument, Vec::new()),
    };
    // SAFETY: out is null or writable for one ko_buffer (ko_client.h).
    unsafe { put(out, bytes) };
    code
}
