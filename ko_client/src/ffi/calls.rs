// The calls that block until the server answered: the caller runs them off the main queue.

use std::ffi::{c_char, c_int};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use ko_server::api::{Route, WindowOnly};
use ko_server::ids::{ClientId, MessageId, PaneId};
use ko_server::protocol::{self, Revision, SendPrompt, Show};
use ko_sys::event::Wake;

use super::engine::{mismatch_of, probe};
use super::{Buffer, Client, Code, bytes_of, client, empty, hand_over, locked, text_of};
use crate::edit::{Edit, Refusal};
use crate::layout::{self, Document, EditError};
use crate::wire;

pub(super) fn call(
    client: &Client,
    out: *mut Buffer,
    work: impl FnOnce(&Path, Option<ClientId>, &Wake) -> Result<Vec<u8>, (Code, Vec<u8>)>,
) -> Code {
    empty(out);
    let shared = Arc::clone(&client.shared);
    {
        let mut calls = locked(&shared.calls);
        if shared.cancel.is_set() {
            return Code::Closed;
        }
        *calls += 1;
    }
    let id = *locked(&shared.client);
    let result = work(&shared.socket, id, &shared.cancel);
    *locked(&shared.calls) -= 1;
    shared.idle.notify_all();
    match result {
        Ok(bytes) => {
            hand_over(out, bytes);
            Code::Ok
        }
        Err((code, bytes)) => {
            hand_over(out, bytes);
            if shared.cancel.is_set() {
                Code::Closed
            } else {
                code
            }
        }
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
    let (Some(client), Some(bytes)) = (client(client_), bytes_of(document, len)) else {
        return Code::Argument;
    };
    if out.is_null() {
        return Code::Argument;
    }
    let document = match protocol::decode::<Document>(bytes) {
        Ok(document) if document.revision.is_some() => document,
        _ => {
            empty(out);
            return Code::Argument;
        }
    };
    call(client, out, |socket, id, cancel| {
        let revision = document.revision.unwrap_or(Revision::FIRST);
        match layout::send(socket, (id, None), revision, document.layout, Some(cancel)) {
            Ok(Ok(snapshot)) => Ok(protocol::json(&snapshot).into_bytes()),
            Ok(Err(newer)) => Err((Code::Conflict, protocol::json(&newer).into_bytes())),
            Err(failure) => Err(rejected(failure)),
        }
    })
}

/// # Safety
///
/// `client` is a live handle. `out` is writable for one `ko_buffer`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_client_runs(
    client_: *const Client,
    show: c_int,
    out: *mut Buffer,
) -> Code {
    let Some(client) = client(client_).filter(|_| !out.is_null()) else {
        return Code::Argument;
    };
    let show = match show {
        1 => Show::Live,
        2 => Show::Present,
        3 => Show::All,
        _ => return Code::Argument,
    };
    call(client, out, |socket, id, cancel| {
        wire::request(
            socket,
            (id, None),
            &Route::ListRuns { show, parent: None },
            b"",
            Some(cancel),
        )
        .map_err(rejected)
    })
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
    let (Some(client), Some(from), Some(target), Some(text)) = (
        client(client_).filter(|_| !out.is_null()),
        text_of(from).and_then(|from| from.parse::<PaneId>().ok()),
        text_of(target).and_then(|target| target.parse().ok()),
        bytes_of(text, len).and_then(|text| std::str::from_utf8(text).ok()),
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
    call(client, out, |socket, id, cancel| {
        wire::request(
            socket,
            (id, None),
            &Route::SendPrompt {},
            body.as_bytes(),
            Some(cancel),
        )
        .map_err(prompt_rejected)
    })
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
    let (Some(client), Some(from)) = (
        client(client_).filter(|_| !out.is_null()),
        text_of(from).and_then(|from| from.parse::<PaneId>().ok()),
    ) else {
        return Code::Argument;
    };
    let route = Route::PromptResolve {
        from,
        window: window_only.then_some(WindowOnly),
    };
    call(client, out, |socket, id, cancel| {
        wire::request(socket, (id, None), &route, b"", Some(cancel)).map_err(rejected)
    })
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
    let (Some(client), Some(bytes)) = (
        client(client_).filter(|_| !out.is_null()),
        bytes_of(edit, len),
    ) else {
        return Code::Argument;
    };
    let Ok(edit) = protocol::decode::<Edit>(bytes) else {
        empty(out);
        return Code::Argument;
    };
    let Some(first) = locked(&client.shared.model)
        .as_ref()
        .map(|model| model.layout.clone())
    else {
        empty(out);
        return Code::Closed;
    };
    call(client, out, |socket, id, cancel| {
        layout::edit_from(first, &edit, |revision, draft| {
            layout::send(socket, (id, None), revision, draft, Some(cancel))
        })
        .map(|edited| protocol::json(&edited).into_bytes())
        .map_err(edit_failure)
    })
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
    let (Some(client), Some(id)) = (client(client_).filter(|_| !out.is_null()), text_of(id)) else {
        return Code::Argument;
    };
    let route = match kind {
        DELETE_PANE => id.parse().ok().map(|id| Route::DeletePane { id }),
        DELETE_WINDOW => id.parse().ok().map(|id| Route::DeleteWindow { id }),
        DELETE_SESSION => id.parse().ok().map(|id| Route::DeleteSession { id }),
        _ => None,
    };
    let Some(route) = route else {
        empty(out);
        return Code::Argument;
    };
    call(client, out, |socket, id, cancel| {
        wire::request(socket, (id, None), &route, b"", Some(cancel)).map_err(rejected)
    })
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
    let Some(socket) = text_of(socket).filter(|_| !out.is_null()) else {
        return Code::Argument;
    };
    let within = Duration::from_millis(u64::from(within_ms));
    match probe(Path::new(socket), within, None) {
        Ok(server) => {
            hand_over(out, protocol::json(&server).into_bytes());
            mismatch_of(&server).unwrap_or(Code::Ok)
        }
        Err((code, message)) => {
            hand_over(out, message.into_bytes());
            code
        }
    }
}
