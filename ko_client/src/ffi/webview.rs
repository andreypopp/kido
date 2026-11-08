use ko_server::protocol::webview::FrameKind;

use super::*;
use ko_server::api::Route;
use ko_server::protocol::CloseCode;
use ko_server::protocol::webview::Headers;
use std::ops::Range;
use std::sync::Weak;

const MAX_DELIVERIES: usize = 16;
const MAX_DELIVERY_BYTES: usize = 1 << 20;
const MAX_SENDS: usize = 1024;
const MAX_SEND_BYTES: usize = 1 << 20;

pub type WebviewResponseFn = unsafe extern "C" fn(*mut c_void, u16, *const WebviewHeader, usize);
pub type WebviewBodyFn = unsafe extern "C" fn(*mut c_void, *const u8, usize);
pub type WebviewEndFn = unsafe extern "C" fn(*mut c_void, Code, *const c_char);
pub type WebviewMessageFn = unsafe extern "C" fn(*mut c_void, *const u8, usize, bool);
pub type WebviewCloseFn = unsafe extern "C" fn(*mut c_void, Code, u16, *const c_char);
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct WebviewHeader {
    pub name: *const c_char,
    pub value: *const c_char,
}
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct WebviewFetchCallbacks {
    pub response: Option<WebviewResponseFn>,
    pub body: Option<WebviewBodyFn>,
    pub end: Option<WebviewEndFn>,
    pub user: *mut c_void,
}
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct WebviewSocketCallbacks {
    pub open: Option<WebviewResponseFn>,
    pub message: Option<WebviewMessageFn>,
    pub close: Option<WebviewCloseFn>,
    pub user: *mut c_void,
}
#[derive(Debug)]
pub(super) enum Callbacks {
    Fetch {
        response: WebviewResponseFn,
        body: WebviewBodyFn,
        end: WebviewEndFn,
    },
    Socket {
        open: WebviewResponseFn,
        message: WebviewMessageFn,
        close: WebviewCloseFn,
    },
}
#[derive(Debug, Default)]
struct Receiving {
    bytes: usize,
    count: usize,
}
impl Receiving {
    fn blocked(&self) -> bool {
        self.count >= MAX_DELIVERIES || self.bytes >= MAX_DELIVERY_BYTES
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
enum Admission {
    #[default]
    Waiting,
    Open,
    Closing,
    Ended,
}
#[derive(Debug)]
enum Payload {
    Queued(usize),
    Writing(Range<u64>),
}
#[derive(Debug)]
struct Send {
    serial: u64,
    payload: Payload,
}
#[derive(Debug, Default)]
struct Sending {
    admission: Admission,
    serial: u64,
    pending: VecDeque<Send>,
}
impl Sending {
    fn buffered(&self) -> usize {
        self.pending.iter().fold(0usize, |sum, send| {
            sum.saturating_add(match &send.payload {
                Payload::Queued(bytes) => *bytes,
                Payload::Writing(range) => {
                    usize::try_from(range.end.saturating_sub(range.start)).unwrap_or(usize::MAX)
                }
            })
        })
    }
}
#[derive(Debug)]
pub(super) struct Task {
    pub(super) id: u64,
    callbacks: Callbacks,
    user: User,
    shared: Weak<Shared>,
    closed: AtomicBool,
    joined: Mutex<bool>,
    idle: Condvar,
    receiving: Mutex<Receiving>,
    sending: Mutex<Sending>,
}
impl Task {
    pub(super) fn socket(&self) -> bool {
        matches!(self.callbacks, Callbacks::Socket { .. })
    }
    pub(super) fn cancelled(&self) -> bool {
        self.closed.load(Ordering::SeqCst)
    }
    pub(super) fn accepts_sends(&self) -> bool {
        locked(&self.sending).admission == Admission::Open
    }
    pub(super) fn opened(&self) {
        let mut sending = locked(&self.sending);
        if !self.cancelled() {
            sending.admission = Admission::Open;
        }
    }
    pub(super) fn ended(&self) {
        let mut sending = locked(&self.sending);
        sending.admission = Admission::Ended;
        sending.pending.clear();
    }
    fn closing(&self) -> bool {
        let mut sending = locked(&self.sending);
        if sending.admission != Admission::Open {
            return false;
        }
        sending.admission = Admission::Closing;
        true
    }
    pub(super) fn reserve(&self, len: usize) -> Result<u64, Code> {
        let mut sending = locked(&self.sending);
        if sending.admission != Admission::Open || self.cancelled() {
            return Err(Code::Closed);
        }
        if sending.pending.len() >= MAX_SENDS
            || sending.buffered().saturating_add(len) > MAX_SEND_BYTES
        {
            return Err(Code::Refused);
        }
        let serial = sending.serial.checked_add(1).ok_or(Code::Refused)?;
        sending.serial = serial;
        sending.pending.push_back(Send {
            serial,
            payload: Payload::Queued(len),
        });
        Ok(serial)
    }
    pub(super) fn writing(&self, serial: u64, range: Option<Range<u64>>) {
        let mut sending = locked(&self.sending);
        if let Some(range) = range {
            if let Some(send) = sending
                .pending
                .iter_mut()
                .find(|send| send.serial == serial)
            {
                send.payload = Payload::Writing(range);
            }
        } else {
            sending.pending.retain(|send| send.serial != serial);
        }
    }
    pub(super) fn progress(&self, written: u64) {
        locked(&self.sending)
            .pending
            .retain_mut(|send| match &mut send.payload {
                Payload::Queued(_) => true,
                Payload::Writing(range) => {
                    range.start = range.start.max(written).min(range.end);
                    range.end > written
                }
            });
    }
    pub(super) fn buffered(&self) -> usize {
        locked(&self.sending).buffered()
    }
    pub(super) fn backed_up(&self) -> bool {
        locked(&self.receiving).blocked()
    }
    pub(super) fn finish(&self) {
        self.ended();
        *locked(&self.joined) = true;
        self.idle.notify_all();
    }
    fn cancel(&self, shared: &Shared) {
        self.closed.store(true, Ordering::SeqCst);
        self.ended();
        shared.command(Command::WebviewStop(self.id));
        let mut joined = locked(&self.joined);
        while !*joined {
            joined = self
                .idle
                .wait(joined)
                .unwrap_or_else(PoisonError::into_inner);
        }
        shared.barrier();
    }
}
#[derive(Debug)]
pub(super) enum WebviewEvent {
    Response {
        status: u16,
        headers: Vec<(String, String)>,
    },
    Body(Vec<u8>),
    End(Code, CString),
    Message {
        data: tungstenite::Bytes,
        binary: FrameKind,
    },
    Close {
        result: Code,
        code: CloseCode,
        reason: CString,
    },
}
impl WebviewEvent {
    fn bytes(&self) -> usize {
        match self {
            Self::Response { headers, .. } => headers.iter().fold(0usize, |sum, (name, value)| {
                sum.saturating_add(name.len()).saturating_add(value.len())
            }),
            Self::Body(bytes) => bytes.len(),
            Self::Message { data, .. } => data.len(),
            Self::End(_, text) | Self::Close { reason: text, .. } => text.as_bytes().len(),
        }
    }
}
#[derive(Debug)]
pub(super) struct WebviewDelivery {
    task: Arc<Task>,
    event: WebviewEvent,
}
impl Drop for WebviewDelivery {
    fn drop(&mut self) {
        let mut pending = locked(&self.task.receiving);
        let blocked = pending.blocked();
        pending.count = pending.count.saturating_sub(1);
        pending.bytes = pending.bytes.saturating_sub(self.event.bytes());
        let resume = blocked && !pending.blocked();
        drop(pending);
        if resume && let Some(shared) = self.task.shared.upgrade() {
            shared.command(Command::WebviewResume(self.task.id));
        }
    }
}
pub(super) fn post_webview(shared: &Arc<Shared>, task: &Arc<Task>, event: WebviewEvent) {
    {
        let mut pending = locked(&task.receiving);
        pending.count = pending.count.saturating_add(1);
        pending.bytes = pending.bytes.saturating_add(event.bytes());
    }
    post(
        shared,
        Posted::Webview(WebviewDelivery {
            task: Arc::clone(task),
            event,
        }),
    );
}
impl WebviewDelivery {
    pub(super) fn deliver(&self, shared: &Shared) {
        if self.task.cancelled() {
            return;
        }
        let user = self.task.user.0;
        RUNNING.set(shared as *const Shared);
        // SAFETY: callbacks and user follow ko_client.h; all buffers live through this call.
        unsafe {
            match (&self.task.callbacks, &self.event) {
                (Callbacks::Fetch { response, .. }, WebviewEvent::Response { status, headers })
                | (
                    Callbacks::Socket { open: response, .. },
                    WebviewEvent::Response { status, headers },
                ) => {
                    let strings: Vec<_> = headers
                        .iter()
                        .map(|(name, value)| (string(name), string(value)))
                        .collect();
                    let fields: Vec<_> = strings
                        .iter()
                        .map(|(name, value)| WebviewHeader {
                            name: name.as_ptr(),
                            value: value.as_ptr(),
                        })
                        .collect();
                    response(user, *status, fields.as_ptr(), fields.len());
                }
                (Callbacks::Fetch { body, .. }, WebviewEvent::Body(data)) => {
                    body(user, data.as_ptr(), data.len())
                }
                (Callbacks::Fetch { end, .. }, WebviewEvent::End(code, message)) => {
                    end(user, *code, message.as_ptr())
                }
                (Callbacks::Socket { message, .. }, WebviewEvent::Message { data, binary }) => {
                    message(user, data.as_ptr(), data.len(), bool::from(*binary))
                }
                (
                    Callbacks::Socket { close, .. },
                    WebviewEvent::Close {
                        result,
                        code,
                        reason,
                    },
                ) => close(user, *result, (*code).into(), reason.as_ptr()),
                _ => {}
            }
        }
        RUNNING.set(std::ptr::null());
    }
}
#[derive(Debug)]
pub struct WebviewHandle {
    task: Arc<Task>,
    shared: Arc<Shared>,
}

static WEBVIEWS: Mutex<BTreeMap<usize, Arc<WebviewHandle>>> = Mutex::new(BTreeMap::new());

fn webview_handle(handle: *const WebviewHandle) -> Option<Arc<WebviewHandle>> {
    locked(&WEBVIEWS).get(&handle.addr()).cloned()
}
#[derive(Debug)]
pub(super) enum Write {
    Send {
        serial: u64,
        message: tungstenite::Message,
    },
    Close {
        code: CloseCode,
        reason: protocol::CloseReason,
    },
}
#[derive(Debug)]
pub(super) struct Request {
    pub(super) route: Route,
    pub(super) headers: Headers,
    pub(super) body: Vec<u8>,
}
// SAFETY: the pointers follow ko_client.h and stay readable for the lifetime of scope.
unsafe fn request_of(
    scope: &(),
    pane: *const c_char,
    method: &str,
    path: *const c_char,
    (headers, count): (*const WebviewHeader, usize),
    (body, len): (*const u8, usize),
) -> Option<Request> {
    // SAFETY: pane and path are NUL-terminated for scope by contract.
    let (pane, path) = unsafe { (text_of(pane, scope)?, text_of(path, scope)?) };
    let pane = pane.parse::<PaneId>().ok()?;
    if !path.starts_with('/') || len > ko_server::http::MAX_BODY {
        return None;
    }
    let route = Route::of_request(method, &format!("/panes/{pane}/webview{path}")).ok()?;
    // SAFETY: headers holds count records whose strings are NUL-terminated for scope,
    // and body is readable for len bytes, by contract.
    let (fields, body) = unsafe {
        (
            slice_of(headers, count, scope)?,
            slice_of(body, len, scope)?,
        )
    };
    let headers = Headers::try_from(
        fields
            .iter()
            .map(|field| {
                // SAFETY: each field's strings are NUL-terminated for scope by contract.
                let (name, value) =
                    unsafe { (text_of(field.name, scope)?, text_of(field.value, scope)?) };
                Some((name.to_owned(), value.to_owned()))
            })
            .collect::<Option<Vec<_>>>()?,
    )
    .ok()?;
    Some(Request {
        route,
        headers,
        body: body.to_vec(),
    })
}
fn opened(
    client: &Client,
    request: Request,
    callbacks: Callbacks,
    user: User,
    out: *mut *mut WebviewHandle,
) -> Code {
    let shared = &client.shared;
    let Some(handle_id) = next_handle() else {
        return Code::Io;
    };
    let mut commands = locked(&shared.commands);
    if shared.cancel.is_set() || !shared.up.load(Ordering::SeqCst) {
        return Code::Closed;
    }
    let id = shared.handles.fetch_add(1, Ordering::SeqCst);
    let task = Arc::new(Task {
        id,
        callbacks,
        user,
        shared: Arc::downgrade(shared),
        closed: AtomicBool::new(false),
        joined: Mutex::new(false),
        idle: Condvar::new(),
        receiving: Mutex::new(Receiving::default()),
        sending: Mutex::new(Sending::default()),
    });
    commands.push_back(Command::WebviewStart(Arc::clone(&task), request));
    drop(commands);
    shared.wake.wake();
    let handle = Arc::new(WebviewHandle {
        task,
        shared: Arc::clone(shared),
    });
    locked(&WEBVIEWS).insert(handle_id, handle);
    // SAFETY: each entry point checked out and its caller supplies writable storage.
    unsafe { out.write(std::ptr::without_provenance_mut(handle_id)) };
    Code::Ok
}
fn cancel(handle: *mut WebviewHandle) -> Code {
    let Some(handle) = locked(&WEBVIEWS).remove(&handle.addr()) else {
        return Code::Argument;
    };
    handle.task.cancel(&handle.shared);
    Code::Ok
}
/// # Safety
/// The client, input buffers, callbacks and output pointer follow ko_client.h.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_client_webview_fetch(
    client_: *const Client,
    pane: *const c_char,
    method: *const c_char,
    path: *const c_char,
    headers: *const WebviewHeader,
    count: usize,
    body: *const u8,
    len: usize,
    callbacks: *const WebviewFetchCallbacks,
    out: *mut *mut WebviewHandle,
) -> Code {
    if out.is_null() {
        return Code::Argument;
    }
    // SAFETY: out is writable and callbacks is null or a readable callback record.
    unsafe {
        *out = std::ptr::null_mut();
    }
    // SAFETY: callbacks follows the header's storage contract.
    let Some(callbacks) = (unsafe { callbacks.as_ref() }) else {
        return Code::Argument;
    };
    let scope = ();
    // SAFETY: method is NUL-terminated for this call by contract.
    let method = unsafe { text_of(method, &scope) };
    let (Some(client), Some(method), Some(response), Some(body_fn), Some(end)) = (
        client(client_),
        method,
        callbacks.response,
        callbacks.body,
        callbacks.end,
    ) else {
        return Code::Argument;
    };
    // SAFETY: the request's pointers follow ko_client.h for this call.
    let Some(request) =
        (unsafe { request_of(&scope, pane, method, path, (headers, count), (body, len)) })
    else {
        return Code::Argument;
    };
    opened(
        &client,
        request,
        Callbacks::Fetch {
            response,
            body: body_fn,
            end,
        },
        User(callbacks.user),
        out,
    )
}
/// # Safety
/// The handle is live and no other call uses it during cancellation.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_webview_fetch_cancel(handle: *mut WebviewHandle) -> Code {
    cancel(handle)
}
/// # Safety
/// The client, strings, headers, callbacks and output pointer follow ko_client.h.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_client_webview_ws_open(
    client_: *const Client,
    pane: *const c_char,
    path: *const c_char,
    headers: *const WebviewHeader,
    count: usize,
    callbacks: *const WebviewSocketCallbacks,
    out: *mut *mut WebviewHandle,
) -> Code {
    if out.is_null() {
        return Code::Argument;
    }
    // SAFETY: out is writable and callbacks is null or a readable callback record.
    unsafe {
        *out = std::ptr::null_mut();
    }
    // SAFETY: callbacks follows the header's storage contract.
    let Some(callbacks) = (unsafe { callbacks.as_ref() }) else {
        return Code::Argument;
    };
    let (Some(client), Some(open), Some(message), Some(close)) = (
        client(client_),
        callbacks.open,
        callbacks.message,
        callbacks.close,
    ) else {
        return Code::Argument;
    };
    let scope = ();
    // SAFETY: the request's pointers follow ko_client.h for this call.
    let Some(request) = (unsafe {
        request_of(
            &scope,
            pane,
            "GET",
            path,
            (headers, count),
            (std::ptr::null(), 0),
        )
    }) else {
        return Code::Argument;
    };
    opened(
        &client,
        request,
        Callbacks::Socket {
            open,
            message,
            close,
        },
        User(callbacks.user),
        out,
    )
}
/// # Safety
/// The handle is live; data is readable for len bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_webview_ws_send(
    handle: *const WebviewHandle,
    data: *const u8,
    len: usize,
    binary: bool,
) -> Code {
    let scope = ();
    // SAFETY: data is readable for len bytes during this call by contract.
    let data = unsafe { slice_of(data, len, &scope) };
    let (Some(handle), Some(data)) = (webview_handle(handle), data) else {
        return Code::Argument;
    };
    if handle.shared.cancel.is_set() {
        return Code::Closed;
    }
    if len > protocol::EXEC_CHUNK {
        return Code::Invalid;
    }
    let message = match FrameKind::from(binary).into_message(data.to_vec()) {
        Ok(message) => message,
        Err(_) => return Code::Invalid,
    };
    let serial = match handle.task.reserve(len) {
        Ok(serial) => serial,
        Err(code) => return code,
    };
    handle.shared.command(Command::WebviewWrite(
        handle.task.id,
        Write::Send { serial, message },
    ));
    Code::Ok
}
/// # Safety
/// The handle is live and reason is a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_webview_ws_close(
    handle: *const WebviewHandle,
    code: u16,
    reason: *const c_char,
) -> Code {
    let scope = ();
    // SAFETY: reason is NUL-terminated for this call by contract.
    let reason = unsafe { text_of(reason, &scope) };
    let (Some(handle), Some(reason), Ok(code)) =
        (webview_handle(handle), reason, CloseCode::try_from(code))
    else {
        return Code::Argument;
    };
    let Ok(reason) = protocol::CloseReason::try_from(reason.to_owned()) else {
        return Code::Invalid;
    };
    if handle.shared.cancel.is_set() || !handle.task.closing() {
        return Code::Closed;
    }
    handle.shared.command(Command::WebviewWrite(
        handle.task.id,
        Write::Close { code, reason },
    ));
    Code::Ok
}
/// # Safety
/// The handle is live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_webview_ws_buffered_amount(handle: *const WebviewHandle) -> usize {
    webview_handle(handle).map_or(0, |handle| handle.task.buffered())
}
/// # Safety
/// The handle is live and no other call uses it during cancellation.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_webview_ws_cancel(handle: *mut WebviewHandle) -> Code {
    cancel(handle)
}

#[cfg(test)]
pub(super) mod tests {
    use super::*;
    pub(in crate::ffi) fn socket_task() -> Arc<Task> {
        unsafe extern "C" fn open(_: *mut c_void, _: u16, _: *const WebviewHeader, _: usize) {}
        unsafe extern "C" fn message(_: *mut c_void, _: *const u8, _: usize, _: bool) {}
        unsafe extern "C" fn close(_: *mut c_void, _: Code, _: u16, _: *const c_char) {}
        let task = Arc::new(Task {
            id: 0,
            callbacks: Callbacks::Socket {
                open,
                message,
                close,
            },
            user: User(std::ptr::null_mut()),
            shared: Weak::new(),
            closed: AtomicBool::new(false),
            joined: Mutex::new(false),
            idle: Condvar::new(),
            receiving: Mutex::new(Receiving::default()),
            sending: Mutex::new(Sending::default()),
        });
        task.opened();
        task
    }
    #[test]
    fn a_send_after_the_socket_ends_cannot_reserve_bytes() {
        let task = socket_task();
        assert!(task.accepts_sends());
        task.finish();
        assert_eq!(task.reserve(3), Err(Code::Closed));
        assert_eq!(task.buffered(), 0);
    }
}
