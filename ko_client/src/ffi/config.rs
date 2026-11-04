use std::ffi::c_char;
use std::path::Path;

use ko_config::config::{self, LoadError};
use ko_config::theme::{self, SetError};
use serde_json::json;

use super::{Buffer, Code, empty, hand_over, text_of};

fn message(code: Code, out: *mut Buffer, text: &str) -> Code {
    hand_over(
        out,
        json!({ "error": { "message": text } })
            .to_string()
            .into_bytes(),
    );
    code
}

/// # Safety
///
/// `path` is a NUL-terminated string. `out` is writable for one `ko_buffer`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_config_load(path: *const c_char, out: *mut Buffer) -> Code {
    empty(out);
    let Some(path) = text_of(path).filter(|_| !out.is_null()) else {
        return Code::Argument;
    };
    match config::load(Path::new(path)) {
        Ok(config) => {
            hand_over(out, json!({ "config": config }).to_string().into_bytes());
            Code::Ok
        }
        Err(LoadError::Invalid(problem)) => invalid(out, &problem),
        Err(LoadError::Io(text)) => message(Code::Io, out, &text),
    }
}

fn invalid(out: *mut Buffer, problem: &ko_config::yaml::Problem) -> Code {
    hand_over(out, json!({ "error": problem }).to_string().into_bytes());
    Code::Invalid
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
    empty(out);
    let (Some(path), Some(light), Some(dark), false) =
        (text_of(path), text_of(light), text_of(dark), out.is_null())
    else {
        return Code::Argument;
    };
    match theme::set_theme(Path::new(path), light, dark) {
        Ok(written) => {
            hand_over(out, json!({ "written": written }).to_string().into_bytes());
            Code::Ok
        }
        Err(SetError::Name(text)) => message(Code::Argument, out, &text),
        Err(SetError::Changed) => message(
            Code::Conflict,
            out,
            "the file changed while the theme was written",
        ),
        Err(SetError::Invalid(problem)) => invalid(out, &problem),
        Err(SetError::Io(text)) => message(Code::Io, out, &text),
    }
}
