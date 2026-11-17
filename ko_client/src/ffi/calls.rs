// The calls that block until the server answered: the caller runs them off the main queue.

use crate::endpoint::Resolved;
use std::ffi::{c_char, c_int, c_void};
use std::time::Duration;

use ko_sys::event::Wake;
use ko_wire::api::Route;
use ko_wire::ids::{ClientId, MessageId, PaneId, StatusId};
use ko_wire::protocol::{self, Revision, SendPrompt};

use super::engine::failure;
use super::{Buffer, Client, Code, client_call, locked, put, slice_of, text_of};
use crate::edit::{Edit, Refusal};
use crate::layout::{self, Document, EditError};
use crate::wire;

pub(super) fn call(
    client: &Client,
    work: impl FnOnce(&Resolved, Option<ClientId>, &Wake) -> Result<Vec<u8>, (Code, Vec<u8>)>,
) -> (Code, Vec<u8>) {
    let shared = &client.shared;
    let id = *locked(&shared.client);
    let Some(endpoint) = locked(&shared.resolved).clone() else {
        return (Code::NoServer, b"no resolved server".to_vec());
    };
    let result = work(&endpoint, id, &shared.cancel);
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

/// # Safety
///
/// The arguments follow the contract in ko_client.h.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_client_upload(
    client_: *const Client,
    pane: *const c_char,
    name: *const c_char,
    size: u64,
    read: Option<unsafe extern "C" fn(*mut c_void, *mut u8, usize, *mut usize) -> bool>,
    reader: *mut c_void,
    out: *mut Buffer,
) -> Code {
    let client = client_call!(client_);
    let scope = ();
    // SAFETY: ko_client.h requires both strings to remain readable for this call.
    let (pane, name) = unsafe { (text_of(pane, &scope), text_of(name, &scope)) };
    let (Some(client), Some(pane), Some(name), Some(read)) = (
        (!out.is_null()).then_some(client),
        pane.and_then(|pane| pane.parse::<PaneId>().ok()),
        name.and_then(|name| ko_wire::api::DropName::try_from(name.to_owned()).ok()),
        read,
    ) else {
        return Code::Argument;
    };
    let mut cancelled = false;
    let (code, bytes) = call(&client, |socket, id, cancel| {
        let body = wire::upload(
            socket,
            id,
            &Route::UploadDrop { id: pane, name },
            size,
            cancel,
            |buffer| {
                let mut count = 0;
                // SAFETY: the callback and reader remain valid for this call; buffer and count are writable.
                if !unsafe { read(reader, buffer.as_mut_ptr(), buffer.len(), &mut count) } {
                    cancelled = true;
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::Interrupted,
                        "upload cancelled",
                    ));
                }
                Ok(count)
            },
        )
        .map_err(upload_rejected)?;
        let dropped: protocol::Dropped = protocol::decode(&body)
            .map_err(|error| (Code::Protocol, error.to_string().into_bytes()))?;
        Ok(dropped.path.as_str().as_bytes().to_vec())
    });
    // SAFETY: ko_client.h requires out to be writable for one ko_buffer.
    unsafe { put(out, bytes) };
    if cancelled { Code::Closed } else { code }
}

fn upload_rejected(error: wire::Rejected) -> (Code, Vec<u8>) {
    match error {
        wire::Rejected::Status { reason, body, .. } => (
            Code::Refused,
            protocol::decode::<protocol::Error>(&body)
                .map_or(reason, |error| error.message)
                .into_bytes(),
        ),
        error => rejected(error),
    }
}

fn io_failure(message: String) -> (Code, Vec<u8>) {
    (Code::Io, message.into_bytes())
}

pub(super) fn rejected(rejected: wire::Rejected) -> (Code, Vec<u8>) {
    match rejected {
        wire::Rejected::Tls(message) => (Code::Tls, message.into_bytes()),
        wire::Rejected::Identity(message) => (Code::Identity, message.into_bytes()),
        wire::Rejected::Protocol(message) => (Code::Protocol, message.into_bytes()),
        wire::Rejected::Io(message) | wire::Rejected::Unanswered(message) => io_failure(message),
        wire::Rejected::Status {
            status: 502,
            reason,
            ..
        } => (Code::NoServer, reason.into_bytes()),
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
    let client = client_call!(client_);
    let scope = ();
    // SAFETY: ko_client.h requires these inputs to remain readable for this call.
    let document_bytes = unsafe { slice_of(document, len, &scope) };

    let (Some(client), Some(bytes)) = (Some(client), document_bytes) else {
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
    let client = client_call!(client_);
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
        (!out.is_null()).then_some(client),
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
        target: Some(target),
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
/// `client` is a live handle. `pane` and `record_id` are NUL-terminated strings. `out` is
/// writable for one `ko_buffer`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_client_select_record(
    client_: *const Client,
    pane: *const c_char,
    record_id: *const c_char,
    out: *mut Buffer,
) -> Code {
    // SAFETY: the caller upholds the contract of this function, which is that of `send_record`.
    unsafe { send_record(protocol::SendKind::Select, client_, pane, record_id, out) }
}

/// # Safety
///
/// `client` is a live handle. `pane` and `record_id` are NUL-terminated strings. `out` is
/// writable for one `ko_buffer`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_client_close_record(
    client_: *const Client,
    pane: *const c_char,
    record_id: *const c_char,
    out: *mut Buffer,
) -> Code {
    // SAFETY: the caller upholds the contract of this function, which is that of `send_record`.
    unsafe { send_record(protocol::SendKind::Close, client_, pane, record_id, out) }
}

/// # Safety
///
/// `client` is a live handle. `pane` and `record_id` are NUL-terminated strings. `out` is
/// writable for one `ko_buffer`.
unsafe fn send_record(
    kind: protocol::SendKind,
    client_: *const Client,
    pane: *const c_char,
    record_id: *const c_char,
    out: *mut Buffer,
) -> Code {
    let client = client_call!(client_);
    let scope = ();
    // SAFETY: ko_client.h requires these inputs to remain readable for this call.
    let (pane_text, record_text) = unsafe { (text_of(pane, &scope), text_of(record_id, &scope)) };

    let (Some(client), Some(pane), Some(record)) = (
        (!out.is_null()).then_some(client),
        pane_text.and_then(|pane| pane.parse::<PaneId>().ok()),
        record_text.and_then(|record| StatusId::try_from(record.to_owned()).ok()),
    ) else {
        return Code::Argument;
    };
    let Ok(message) = MessageId::mint() else {
        return Code::Io;
    };
    let body = protocol::json(&protocol::SendMessage {
        id: message,
        kind,
        text: String::from(record),
        data: None,
    });
    let (code, bytes) = call(&client, |socket, id, cancel| {
        wire::request(
            socket,
            (id, None),
            &Route::PostMessage { id: pane },
            body.as_bytes(),
            Some(cancel),
        )
        .map_err(rejected)
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
    out: *mut Buffer,
) -> Code {
    let client = client_call!(client_);
    let scope = ();
    // SAFETY: ko_client.h requires these inputs to remain readable for this call.
    let from_text = unsafe { text_of(from, &scope) };

    let (Some(client), Some(from)) = (
        (!out.is_null()).then_some(client),
        from_text.and_then(|from| from.parse::<PaneId>().ok()),
    ) else {
        return Code::Argument;
    };
    let route = Route::PromptResolve { from };
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
    let client = client_call!(client_);
    let scope = ();
    // SAFETY: ko_client.h requires these inputs to remain readable for this call.
    let edit_bytes = unsafe { slice_of(edit, len, &scope) };

    let (Some(client), Some(bytes)) = ((!out.is_null()).then_some(client), edit_bytes) else {
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
    let client = client_call!(client_);
    let scope = ();
    // SAFETY: ko_client.h requires these inputs to remain readable for this call.
    let id_text = unsafe { text_of(id, &scope) };

    let (Some(client), Some(id)) = ((!out.is_null()).then_some(client), id_text) else {
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RuntimeCommand {
    Up,
    Down,
}

fn runtime_command(
    client: &Client,
    name: &str,
    session: Option<&str>,
    command: RuntimeCommand,
) -> (Code, Vec<u8>) {
    let (Ok(name), Ok(session)) = (name.parse(), session.map(str::parse).transpose()) else {
        return (Code::Argument, Vec::new());
    };
    let (route, body) = match command {
        RuntimeCommand::Up => (Route::UpRuntime { name, session }, String::new()),
        RuntimeCommand::Down => (
            Route::DownRuntime { name, session },
            protocol::json(&protocol::DownRuntime { force: true }),
        ),
    };
    call(client, |socket, id, cancel| {
        wire::request(socket, (id, None), &route, body.as_bytes(), Some(cancel)).map_err(rejected)
    })
}

/// # Safety
///
/// `client_` is live, `name` is NUL-terminated, `session` is null or NUL-terminated, and `out` is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_client_runtime_up(
    client_: *const Client,
    name: *const c_char,
    session: *const c_char,
    out: *mut Buffer,
) -> Code {
    let client = client_call!(client_);
    let scope = ();
    // SAFETY: ko_client.h requires these inputs to remain readable for this call.
    let (name_text, session_text) = unsafe { (text_of(name, &scope), text_of(session, &scope)) };
    if !session.is_null() && session_text.is_none() {
        return Code::Argument;
    }
    let (Some(client), Some(name)) = ((!out.is_null()).then_some(client), name_text) else {
        return Code::Argument;
    };
    let (code, bytes) = runtime_command(&client, name, session_text, RuntimeCommand::Up);
    // SAFETY: out is null or writable for one ko_buffer (ko_client.h).
    unsafe { put(out, bytes) };
    code
}

/// # Safety
///
/// `client_` is live, `name` is NUL-terminated, `session` is null or NUL-terminated, and `out` is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_client_runtime_down(
    client_: *const Client,
    name: *const c_char,
    session: *const c_char,
    out: *mut Buffer,
) -> Code {
    let client = client_call!(client_);
    let scope = ();
    // SAFETY: ko_client.h requires these inputs to remain readable for this call.
    let (name_text, session_text) = unsafe { (text_of(name, &scope), text_of(session, &scope)) };
    if !session.is_null() && session_text.is_none() {
        return Code::Argument;
    }
    let (Some(client), Some(name)) = ((!out.is_null()).then_some(client), name_text) else {
        return Code::Argument;
    };
    let (code, bytes) = runtime_command(&client, name, session_text, RuntimeCommand::Down);
    // SAFETY: out is null or writable for one ko_buffer (ko_client.h).
    unsafe { put(out, bytes) };
    code
}

/// # Safety
///
/// `endpoint` follows ko_client.h. `out` is writable for one `ko_buffer`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_client_probe(
    endpoint: *const super::identity::Endpoint,
    within_ms: u32,
    out: *mut Buffer,
) -> Code {
    // SAFETY: ko_client.h requires the endpoint to remain readable for this call.
    let endpoint = match unsafe { super::identity::endpoint(endpoint, Vec::new()) } {
        Ok(endpoint) => endpoint,
        Err(code) => return code,
    };
    // SAFETY: out is writable by contract.
    unsafe { probe(endpoint, within_ms, out) }
}

pub(super) unsafe fn probe(
    endpoint: crate::endpoint::Endpoint,
    within_ms: u32,
    out: *mut Buffer,
) -> Code {
    if out.is_null() {
        return Code::Argument;
    }
    let within = Duration::from_millis(u64::from(within_ms));
    let (code, bytes) = match endpoint
        .resolve(None, within)
        .and_then(|resolved| crate::api::version(&resolved, within, None))
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn upload_refusals_keep_protocol_messages_instead_of_status_reasons() {
        let refusal = wire::Rejected::Status {
            status: 502,
            reason: "Bad Gateway".to_owned(),
            body: protocol::json(&protocol::Error::new(
                protocol::ErrorKind::Io,
                "runtime quota refused",
            ))
            .into_bytes(),
        };
        assert_eq!(
            upload_rejected(refusal),
            (Code::Refused, b"runtime quota refused".to_vec())
        );
        let proxy = wire::Rejected::Status {
            status: 502,
            reason: "Proxy gateway failure".to_owned(),
            body: b"<html>proxy error</html>".to_vec(),
        };
        assert_eq!(
            upload_rejected(proxy),
            (Code::Refused, b"Proxy gateway failure".to_vec())
        );
    }
}
