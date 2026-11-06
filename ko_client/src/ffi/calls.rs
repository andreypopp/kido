// The calls that block until the server answered: the caller runs them off the main queue.

use std::ffi::{c_char, c_int};
use std::path::Path;
use std::time::Duration;

use ko_server::api::{Route, WindowOnly};
use ko_server::ids::{ClientId, MessageId, PaneId};
use ko_server::protocol::{self, Revision, SendPrompt};
use ko_sys::event::Wake;

use super::engine::failure;
use super::{Buffer, Client, Code, client, locked, put, slice_of, text_of};
use crate::edit::{Edit, Refusal};
use crate::layout::{self, Document, EditError};
use crate::wire;

pub(super) fn call(
    client: &Client,
    work: impl FnOnce(&Path, Option<ClientId>, &Wake) -> Result<Vec<u8>, (Code, Vec<u8>)>,
) -> (Code, Vec<u8>) {
    let shared = &client.shared;
    let id = *locked(&shared.client);
    let result = work(&shared.socket, id, &shared.cancel);
    match result {
        Ok(bytes) => (Code::Ok, bytes),
        Err((code, bytes)) => (
            if shared.cancel.is_set() {
                Code::Closed
            } else {
                code
            },
            bytes,
        ),
    }
}

fn io_failure(message: String) -> (Code, Vec<u8>) {
    (Code::Io, message.into_bytes())
}

pub(super) fn rejected(rejected: wire::Rejected) -> (Code, Vec<u8>) {
    match rejected {
        wire::Rejected::Io(message) | wire::Rejected::Unanswered(message) => io_failure(message),
        wire::Rejected::Status { body, .. } => match protocol::decode::<protocol::Error>(&body) {
            Ok(error) => (Code::of(&error.kind), error.message.into_bytes()),
            Err(_) => (Code::Unknown, body),
        },
    }
}

// The server reports a send that failed partway as Io: the text may have reached the agent.
fn prompt_rejected(rejected: wire::Rejected) -> (Code, Vec<u8>) {
    match rejected {
        wire::Rejected::Unanswered(message) => (Code::Unknown, message.into_bytes()),
        wire::Rejected::Io(message) => io_failure(message),
        status => match self::rejected(status) {
            (Code::Io, message) => (Code::Unknown, message),
            other => other,
        },
    }
}

/// # Safety
///
/// `client` is a live handle. `document` is readable for `len` bytes. `out`
/// is writable for one `ko_buffer`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_client_put_layout(
    client_: *const Client,
    document: *const u8,
    len: usize,
    out: *mut Buffer,
) -> Code {
    let scope = ();
    // SAFETY: ko_client.h requires these inputs to remain readable for this call.
    let document_bytes = unsafe { slice_of(document, len, &scope) };

    let (Some(client), Some(bytes)) = (client(client_), document_bytes) else {
        return Code::Argument;
    };
    if out.is_null() {
        return Code::Argument;
    }
    let (code, bytes) = match protocol::decode::<Document>(bytes) {
        Ok(document) if document.revision.is_some() => call(&client, |socket, id, cancel| {
            let revision = document.revision.unwrap_or(Revision::FIRST);
            match layout::send(socket, (id, None), revision, document.layout, Some(cancel)) {
                Ok(Ok(snapshot)) => Ok(protocol::json(&snapshot).into_bytes()),
                Ok(Err(newer)) => Err((Code::Conflict, protocol::json(&newer).into_bytes())),
                Err(failure) => Err(rejected(failure)),
            }
        }),
        _ => (Code::Argument, Vec::new()),
    };
    // SAFETY: out is null or writable for one ko_buffer (ko_client.h).
    unsafe { put(out, bytes) };
    code
}

/// # Safety
///
/// `client` is a live handle. `target` is a NUL-terminated string. `text` is
/// readable for `len` bytes. `out` is writable for one `ko_buffer`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_client_prompt(
    client_: *const Client,
    from: *const c_char,
    target: *const c_char,
    text: *const u8,
    len: usize,
    out: *mut Buffer,
) -> Code {
    let scope = ();
    // SAFETY: ko_client.h requires these inputs to remain readable for this call.
    let (from_text, target_text, text_bytes) = unsafe {
        (
            text_of(from, &scope),
            text_of(target, &scope),
            slice_of(text, len, &scope),
        )
    };

    let (Some(client), Some(from), Some(target), Some(text)) = (
        client(client_).filter(|_| !out.is_null()),
        from_text.and_then(|from| from.parse::<PaneId>().ok()),
        target_text.and_then(|target| target.parse().ok()),
        text_bytes.and_then(|text| std::str::from_utf8(text).ok()),
    ) else {
        return Code::Argument;
    };
    let Ok(message) = MessageId::mint() else {
        return Code::Io;
    };
    let body = protocol::json(&SendPrompt {
        from,
        id: message,
        target,
        text: text.to_owned(),
    });
    let (code, bytes) = call(&client, |socket, id, cancel| {
        wire::request(
            socket,
            (id, None),
            &Route::SendPrompt {},
            body.as_bytes(),
            Some(cancel),
        )
        .map_err(prompt_rejected)
    });
    // SAFETY: out is null or writable for one ko_buffer (ko_client.h).
    unsafe { put(out, bytes) };
    code
}

/// # Safety
///
/// `client` is a live handle. `from` is a NUL-terminated string. `out` is
/// writable for one `ko_buffer`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_client_prompt_resolve(
    client_: *const Client,
    from: *const c_char,
    window_only: bool,
    out: *mut Buffer,
) -> Code {
    let scope = ();
    // SAFETY: ko_client.h requires these inputs to remain readable for this call.
    let from_text = unsafe { text_of(from, &scope) };

    let (Some(client), Some(from)) = (
        client(client_).filter(|_| !out.is_null()),
        from_text.and_then(|from| from.parse::<PaneId>().ok()),
    ) else {
        return Code::Argument;
    };
    let route = Route::PromptResolve {
        from,
        window: window_only.then_some(WindowOnly),
    };
    let (code, bytes) = call(&client, |socket, id, cancel| {
        wire::request(socket, (id, None), &route, b"", Some(cancel)).map_err(rejected)
    });
    // SAFETY: out is null or writable for one ko_buffer (ko_client.h).
    unsafe { put(out, bytes) };
    code
}

fn edit_failure(failure: EditError) -> (Code, Vec<u8>) {
    match failure {
        EditError::Refused(Refusal::Gone(id)) => (Code::NotFound, id.into_bytes()),
        EditError::Refused(Refusal::Invalid(reason)) => (Code::Invalid, reason.into_bytes()),
        EditError::Rejected(failure) => rejected(failure),
        EditError::Exhausted => (Code::Conflict, failure.to_string().into_bytes()),
    }
}

/// # Safety
///
/// `client` is a live handle. `edit` is readable for `len` bytes. `out` is
/// writable for one `ko_buffer`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_client_edit(
    client_: *const Client,
    edit: *const u8,
    len: usize,
    out: *mut Buffer,
) -> Code {
    let scope = ();
    // SAFETY: ko_client.h requires these inputs to remain readable for this call.
    let edit_bytes = unsafe { slice_of(edit, len, &scope) };

    let (Some(client), Some(bytes)) = (client(client_).filter(|_| !out.is_null()), edit_bytes)
    else {
        return Code::Argument;
    };
    let (code, bytes) = match protocol::decode::<Edit>(bytes) {
        Ok(edit) => {
            let first = locked(&client.shared.model)
                .as_ref()
                .map(|model| model.layout.clone());
            match first {
                Some(first) => call(&client, |socket, id, cancel| {
                    layout::edit_from(first, &edit, |revision, draft| {
                        layout::send(socket, (id, None), revision, draft, Some(cancel))
                    })
                    .map(|edited| protocol::json(&edited).into_bytes())
                    .map_err(edit_failure)
                }),
                None => (Code::Closed, Vec::new()),
            }
        }
        Err(_) => (Code::Argument, Vec::new()),
    };
    // SAFETY: out is null or writable for one ko_buffer (ko_client.h).
    unsafe { put(out, bytes) };
    code
}

const DELETE_PANE: c_int = 1;
const DELETE_WINDOW: c_int = 2;
const DELETE_SESSION: c_int = 3;

/// # Safety
///
/// `client` is a live handle. `id` is a NUL-terminated string. `out` is writable
/// for one `ko_buffer`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_client_delete(
    client_: *const Client,
    kind: c_int,
    id: *const c_char,
    out: *mut Buffer,
) -> Code {
    let scope = ();
    // SAFETY: ko_client.h requires these inputs to remain readable for this call.
    let id_text = unsafe { text_of(id, &scope) };

    let (Some(client), Some(id)) = (client(client_).filter(|_| !out.is_null()), id_text) else {
        return Code::Argument;
    };
    let route = match kind {
        DELETE_PANE => id.parse().ok().map(|id| Route::DeletePane { id }),
        DELETE_WINDOW => id.parse().ok().map(|id| Route::DeleteWindow { id }),
        DELETE_SESSION => id.parse().ok().map(|id| Route::DeleteSession { id }),
        _ => None,
    };
    let (code, bytes) = match route {
        Some(route) => call(&client, |socket, id, cancel| {
            wire::request(socket, (id, None), &route, b"", Some(cancel)).map_err(rejected)
        }),
        None => (Code::Argument, Vec::new()),
    };
    // SAFETY: out is null or writable for one ko_buffer (ko_client.h).
    unsafe { put(out, bytes) };
    code
}

/// # Safety
///
/// `client_` is live, `name` is NUL-terminated, and `out` is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_client_runtime_down(
    client_: *const Client,
    name: *const c_char,
    out: *mut Buffer,
) -> Code {
    let scope = ();
    // SAFETY: ko_client.h requires these inputs to remain readable for this call.
    let name_text = unsafe { text_of(name, &scope) };

    let (Some(client), Some(name)) = (client(client_).filter(|_| !out.is_null()), name_text) else {
        return Code::Argument;
    };
    let (code, bytes) = match name.parse() {
        Ok(name) => call(&client, |socket, id, cancel| {
            wire::request(
                socket,
                (id, None),
                &Route::DownRuntime { name },
                protocol::json(&protocol::DownRuntime { force: true }).as_bytes(),
                Some(cancel),
            )
            .map_err(rejected)
        }),
        Err(_) => (Code::Argument, Vec::new()),
    };
    // SAFETY: out is null or writable for one ko_buffer (ko_client.h).
    unsafe { put(out, bytes) };
    code
}

/// # Safety
///
/// `socket` is a NUL-terminated string. `out` is writable for one `ko_buffer`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_client_probe(
    socket: *const c_char,
    within_ms: u32,
    out: *mut Buffer,
) -> Code {
    let scope = ();
    // SAFETY: ko_client.h requires these inputs to remain readable for this call.
    let socket_text = unsafe { text_of(socket, &scope) };

    let Some(socket) = socket_text.filter(|_| !out.is_null()) else {
        return Code::Argument;
    };
    let within = Duration::from_millis(u64::from(within_ms));
    let (code, bytes) = match crate::api::version(Path::new(socket), within, None)
        .map_err(|error| failure(&error))
    {
        Ok((mismatch, server)) => (
            mismatch.as_ref().map(Code::of).unwrap_or(Code::Ok),
            protocol::json(&server).into_bytes(),
        ),
        Err((code, message)) => (code, message.into_bytes()),
    };
    // SAFETY: out is null or writable for one ko_buffer (ko_client.h).
    unsafe { put(out, bytes) };
    code
}
