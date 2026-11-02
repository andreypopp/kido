#![allow(unsafe_code)]

mod engine;
mod view;

use std::cell::Cell;
use std::collections::{BTreeMap, VecDeque};
use std::ffi::{CStr, CString, c_char, c_int, c_void};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::thread::JoinHandle;

use ko_pane_wire::frame::{self, History};
use ko_server::api::Route;
use ko_server::ids::{ClientId, PaneId, VarName, WindowId};
use ko_server::protocol::{
    self, ClientRequest, Direction, Hello, Input, Over, Paste, Revision, Row, RunEvent, Selection,
    SendPrompt, Show, Snapshot, Switch, Text,
};
use ko_sys::event::Wake;
use serde::Serialize;
use serde_json::Value;

use crate::layout::{self, Document};
use crate::model::{Fetched, Item, Model, Notice};
use crate::status::{self, Mark};
use crate::wire;
use view::{Restored, View};

unsafe extern "C" {
    fn dispatch_async_f(queue: *mut c_void, context: *mut c_void, work: extern "C" fn(*mut c_void));
    fn dispatch_retain(object: *mut c_void);
    fn dispatch_release(object: *mut c_void);
}

thread_local! {
    static RUNNING: Cell<*const Shared> = const { Cell::new(std::ptr::null()) };
}

#[cfg(test)]
static LIVE_BUFFERS: Mutex<std::collections::BTreeSet<usize>> =
    Mutex::new(std::collections::BTreeSet::new());

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i32)]
pub enum Code {
    Ok = 0,
    Argument = 1,
    NoServer = 2,
    Io = 3,
    Protocol = 4,
    Closed = 5,
    Conflict = 6,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct Welcome {
    pub client: *const c_char,
    pub instance: *const c_char,
    pub now: u64,
    pub fresh: bool,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct Layout {
    pub revision: u64,
    pub sessions: u32,
    pub windows: u32,
    pub panes: u32,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct Failure {
    pub code: Code,
    pub message: *const c_char,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct Selected {
    pub session: *const c_char,
    pub window: *const c_char,
    pub pane: *const c_char,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct Alert {
    pub kind: c_int,
    pub pane: *const c_char,
    pub title: *const c_char,
    pub body: *const c_char,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ViewRestored {
    pub view: *mut c_void,
    pub generation: u64,
    pub result: Restored,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ViewClosed {
    pub view: *mut c_void,
    pub code: Code,
    pub message: *const c_char,
}

const EVENT_WELCOME: c_int = 1;
const EVENT_LAYOUT: c_int = 2;
const EVENT_FAILED: c_int = 3;
const EVENT_MODEL: c_int = 4;
const EVENT_SELECTED: c_int = 5;
const EVENT_ALERT: c_int = 6;
const EVENT_VIEW_RESTORED: c_int = 7;
const EVENT_VIEW_CLOSED: c_int = 8;

#[repr(C)]
#[derive(Clone, Copy)]
pub union Body {
    pub welcome: Welcome,
    pub layout: Layout,
    pub failure: Failure,
    pub selected: Selected,
    pub alert: Alert,
    pub view_restored: ViewRestored,
    pub view_closed: ViewClosed,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct Event {
    pub kind: c_int,
    pub body: Body,
}

pub type Callback = unsafe extern "C" fn(user: *mut c_void, event: *const Event);
pub type RestoreFn =
    unsafe extern "C" fn(user: *mut c_void, snapshot: *const view::Snapshot) -> c_int;
pub type FeedFn = unsafe extern "C" fn(user: *mut c_void, item: *const FeedItem);

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct FeedItem {
    pub kind: c_int,
    pub offset: u64,
    pub data: *const u8,
    pub len: usize,
    pub cols: u16,
    pub rows: u16,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct HelloIn {
    pub cols: u16,
    pub rows: u16,
    pub focused: bool,
    pub sizes_windows: bool,
}

#[repr(C)]
#[derive(Debug)]
pub struct Buffer {
    pub data: *mut u8,
    pub len: usize,
    pub cap: usize,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct KeyInput {
    pub action: c_int,
    pub key: u16,
    pub mods: u16,
    pub unshifted: u32,
    pub text: *const c_char,
    pub composing: bool,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct MouseInput {
    pub action: c_int,
    pub button: c_int,
    pub col: u16,
    pub row: u16,
    pub mods: u16,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct PasteInput {
    pub text: *const u8,
    pub len: usize,
    pub check_safe: bool,
    pub has_id: bool,
    pub id: u64,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct TextInput {
    pub data: *const u8,
    pub len: usize,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub union InputBody {
    pub key: KeyInput,
    pub mouse: MouseInput,
    pub paste: PasteInput,
    pub text: TextInput,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct InputEvent {
    pub kind: c_int,
    pub body: InputBody,
}

#[derive(Debug)]
enum ViewEvent {
    Restored { generation: u64, result: Restored },
    Closed(Code, CString),
}

#[derive(Debug)]
enum Posted {
    Welcome {
        client: CString,
        instance: CString,
        now: u64,
        fresh: bool,
    },
    Layout(Layout),
    Model,
    Selected(Selection),
    Alert(Notice),
    Failed(Code, CString),
    View(Arc<View>, ViewEvent),
}

#[derive(Debug)]
struct Queue(*mut c_void);

// SAFETY: a dispatch queue is thread-safe, and this handle owns one retain.
unsafe impl Send for Queue {}
// SAFETY: as above; dispatching to a queue needs no exclusive access.
unsafe impl Sync for Queue {}

impl Drop for Queue {
    fn drop(&mut self) {
        // SAFETY: the pointer is a queue that connect retained, released here once.
        unsafe { dispatch_release(self.0) }
    }
}

#[derive(Debug, Clone, Copy)]
struct User(*mut c_void);

// SAFETY: the caller of ko_client_connect and ko_view_open promises that the
// callbacks may run with this pointer on the threads that the header names.
unsafe impl Send for User {}
// SAFETY: as above.
unsafe impl Sync for User {}

#[derive(Debug)]
enum Command {
    Request(ClientRequest),
    Open(Arc<View>),
    Close(u64),
    Resync(u64, protocol::ViewOptions),
    Input(u64, Input),
}

#[derive(Debug)]
struct Shared {
    queue: Queue,
    callback: Callback,
    user: User,
    socket: PathBuf,
    cancel: Arc<Wake>,
    wake: Wake,
    commands: Mutex<VecDeque<Command>>,
    hello: Mutex<Hello>,
    client: Mutex<Option<ClientId>>,
    model: Mutex<Option<Model>>,
    up: AtomicBool,
    model_pending: AtomicBool,
    fetched: Mutex<Option<(u64, Result<Fetched, String>)>>,
    decoders: Mutex<Vec<Arc<View>>>,
    views: AtomicU64,
    calls: Mutex<usize>,
    idle: Condvar,
    running: Mutex<()>,
}

#[derive(Debug)]
pub struct Client {
    shared: Arc<Shared>,
    worker: JoinHandle<()>,
}

#[derive(Debug)]
pub struct ViewHandle {
    view: Arc<View>,
    shared: Arc<Shared>,
}

#[derive(Debug)]
struct Delivery {
    shared: Arc<Shared>,
    posted: Posted,
}

fn locked<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

impl Shared {
    fn command(&self, command: Command) {
        locked(&self.commands).push_back(command);
        self.wake.wake();
    }
}

fn string(text: &str) -> CString {
    CString::new(text.replace('\0', " ")).unwrap_or_default()
}

fn post(shared: &Arc<Shared>, posted: Posted) {
    if shared.cancel.is_set() {
        return;
    }
    let item = Box::into_raw(Box::new(Delivery {
        shared: Arc::clone(shared),
        posted,
    }));
    // SAFETY: the queue is retained by shared, which the item keeps alive, and
    // deliver frees the item exactly once.
    unsafe { dispatch_async_f(shared.queue.0, item.cast(), deliver) }
}

fn pointer(text: &Option<CString>) -> *const c_char {
    text.as_ref().map_or(std::ptr::null(), |text| text.as_ptr())
}

extern "C" fn deliver(context: *mut c_void) {
    // SAFETY: context is the pointer that post made from a Box<Delivery>, and
    // dispatch runs each work item once.
    let item = unsafe { Box::from_raw(context.cast::<Delivery>()) };
    let shared = &item.shared;
    let _running = locked(&shared.running);
    if shared.cancel.is_set() {
        return;
    }
    let call = |event: Event| {
        RUNNING.set(Arc::as_ptr(shared));
        // SAFETY: the caller promised that the callback accepts this user pointer
        // and an event that is valid until the callback returns.
        unsafe { (shared.callback)(shared.user.0, &event) };
        RUNNING.set(std::ptr::null());
    };
    match &item.posted {
        Posted::Welcome {
            client,
            instance,
            now,
            fresh,
        } => call(Event {
            kind: EVENT_WELCOME,
            body: Body {
                welcome: Welcome {
                    client: client.as_ptr(),
                    instance: instance.as_ptr(),
                    now: *now,
                    fresh: *fresh,
                },
            },
        }),
        Posted::Layout(layout) => call(Event {
            kind: EVENT_LAYOUT,
            body: Body { layout: *layout },
        }),
        Posted::Model => {
            shared.model_pending.store(false, Ordering::SeqCst);
            call(Event {
                kind: EVENT_MODEL,
                body: Body {
                    layout: Layout {
                        revision: 0,
                        sessions: 0,
                        windows: 0,
                        panes: 0,
                    },
                },
            });
        }
        Posted::Selected(selection) => {
            let name = |id: Option<String>| id.map(|id| string(&id));
            let (session, window, pane) = (
                name(selection.session.map(|id| id.to_string())),
                name(selection.window.map(|id| id.to_string())),
                name(selection.pane.map(|id| id.to_string())),
            );
            call(Event {
                kind: EVENT_SELECTED,
                body: Body {
                    selected: Selected {
                        session: pointer(&session),
                        window: pointer(&window),
                        pane: pointer(&pane),
                    },
                },
            });
        }
        Posted::Alert(notice) => {
            let (kind, pane, title, body) = match notice {
                Notice::Bell(pane) => (1, pane, None, None),
                Notice::Notify { pane, title, body } => {
                    (2, pane, title.as_deref().map(string), Some(string(body)))
                }
            };
            let pane = string(&pane.to_string());
            call(Event {
                kind: EVENT_ALERT,
                body: Body {
                    alert: Alert {
                        kind,
                        pane: pane.as_ptr(),
                        title: pointer(&title),
                        body: pointer(&body),
                    },
                },
            });
        }
        Posted::Failed(code, message) => call(Event {
            kind: EVENT_FAILED,
            body: Body {
                failure: Failure {
                    code: *code,
                    message: message.as_ptr(),
                },
            },
        }),
        Posted::View(view, feed) => {
            if view.closed.load(Ordering::SeqCst) {
                return;
            }
            let user = view.user.0;
            match feed {
                ViewEvent::Restored { generation, result } => call(Event {
                    kind: EVENT_VIEW_RESTORED,
                    body: Body {
                        view_restored: ViewRestored {
                            view: user,
                            generation: *generation,
                            result: *result,
                        },
                    },
                }),
                ViewEvent::Closed(code, message) => call(Event {
                    kind: EVENT_VIEW_CLOSED,
                    body: Body {
                        view_closed: ViewClosed {
                            view: user,
                            code: *code,
                            message: message.as_ptr(),
                        },
                    },
                }),
            }
        }
    }
}

#[derive(Serialize)]
struct PaneJson<'a> {
    id: PaneId,
    label: String,
    mark: Mark,
    #[serde(flatten)]
    row: &'a Row,
    vars: &'a BTreeMap<VarName, Value>,
}

#[derive(Serialize)]
struct ModelJson<'a> {
    client: String,
    instance: String,
    now: u64,
    selection: &'a Selection,
    layout: &'a Snapshot,
    panes: Vec<PaneJson<'a>>,
    runs: Vec<&'a RunEvent>,
    outline: Vec<Item>,
}

fn model_json(model: &Model) -> Result<Vec<u8>, serde_json::Error> {
    serde_json::to_vec(&ModelJson {
        client: model.client.to_string(),
        instance: model.instance.to_string(),
        now: model.server_now(),
        selection: &model.selection,
        layout: &model.layout,
        panes: model
            .panes
            .iter()
            .map(|pane| PaneJson {
                id: pane.row.id,
                label: status::title(pane),
                mark: model.mark(pane),
                row: &pane.row,
                vars: &pane.vars,
            })
            .collect(),
        runs: model.runs().collect(),
        outline: model.outline(),
    })
}

fn count(length: usize) -> u32 {
    u32::try_from(length).unwrap_or(u32::MAX)
}

fn layout_of(model: &Model) -> Layout {
    let layout = &model.layout.layout;
    Layout {
        revision: model.layout.revision.get(),
        sessions: count(layout.sessions.len()),
        windows: count(layout.windows().count()),
        panes: count(model.order().len()),
    }
}

fn hand_over(out: *mut Buffer, bytes: Vec<u8>) {
    if out.is_null() {
        return;
    }
    let mut bytes = std::mem::ManuallyDrop::new(bytes);
    #[cfg(test)]
    if bytes.capacity() > 0 {
        locked(&LIVE_BUFFERS).insert(bytes.as_mut_ptr() as usize);
    }
    // SAFETY: out is non-null and writable by contract.
    unsafe {
        *out = Buffer {
            data: bytes.as_mut_ptr(),
            len: bytes.len(),
            cap: bytes.capacity(),
        };
    }
}

fn empty(out: *mut Buffer) {
    if !out.is_null() {
        // SAFETY: out is non-null and writable by contract.
        unsafe {
            *out = Buffer {
                data: std::ptr::null_mut(),
                len: 0,
                cap: 0,
            };
        }
    }
}

fn client<'a>(client: *const Client) -> Option<&'a Client> {
    // SAFETY: the caller promises that client is null or a live handle that no
    // concurrent close consumes.
    unsafe { client.as_ref() }
}

fn text_of<'a>(pointer: *const c_char) -> Option<&'a str> {
    if pointer.is_null() {
        return None;
    }
    // SAFETY: pointer is non-null and NUL-terminated by contract.
    unsafe { CStr::from_ptr(pointer) }.to_str().ok()
}

fn bytes_of<'a>(data: *const u8, len: usize) -> Option<&'a [u8]> {
    if data.is_null() {
        return (len == 0).then_some(&[]);
    }
    // SAFETY: data is readable for len bytes by contract.
    Some(unsafe { std::slice::from_raw_parts(data, len) })
}

// Runs a request on the calling thread. Close sets the cancel wake, which ends
// the request at once, and then waits for the call to leave.
fn call(
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

fn request(client: &Client, request: ClientRequest) -> Code {
    if !client.shared.up.load(Ordering::SeqCst) {
        return Code::Closed;
    }
    client.shared.command(Command::Request(request));
    Code::Ok
}

/// # Safety
///
/// `socket` is null or a NUL-terminated string. `queue` is null or a dispatch
/// queue. `callback` and `user` follow `ko_client.h`. `hello` is null or points
/// to a `ko_hello`. `out` is null or points to writable storage for one pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_client_connect(
    socket: *const c_char,
    queue: *mut c_void,
    callback: Option<Callback>,
    user: *mut c_void,
    hello: *const HelloIn,
    out: *mut *mut Client,
) -> Code {
    if out.is_null() {
        return Code::Argument;
    }
    // SAFETY: out is non-null and writable by contract.
    unsafe { *out = std::ptr::null_mut() };
    let (false, Some(callback)) = (socket.is_null() || queue.is_null(), callback) else {
        return Code::Argument;
    };
    // SAFETY: socket is non-null and NUL-terminated by contract.
    let socket = PathBuf::from(std::ffi::OsStr::from_bytes(
        unsafe { CStr::from_ptr(socket) }.to_bytes(),
    ));
    if socket.as_os_str().is_empty() {
        return Code::Argument;
    }
    // SAFETY: hello is null or points to a ko_hello by contract.
    let hello = unsafe { hello.as_ref() }.copied().unwrap_or(HelloIn {
        cols: 80,
        rows: 24,
        focused: false,
        sizes_windows: false,
    });
    let (Some(cols), Some(rows)) = (frame::Dim::new(hello.cols), frame::Dim::new(hello.rows))
    else {
        return Code::Argument;
    };
    let (Ok(cancel), Ok(wake)) = (Wake::new(), Wake::new()) else {
        return Code::Io;
    };
    // SAFETY: queue is a live dispatch queue by contract; Queue releases this retain.
    unsafe { dispatch_retain(queue) };
    let shared = Arc::new(Shared {
        queue: Queue(queue),
        callback,
        user: User(user),
        socket,
        cancel: Arc::new(cancel),
        wake,
        commands: Mutex::new(VecDeque::new()),
        hello: Mutex::new(Hello {
            kind: protocol::ClientKind::App,
            name: "ko_client".to_owned(),
            selection: Selection::default(),
            focused: hello.focused,
            size: protocol::Size(frame::Size {
                cols,
                rows,
                cell_px: None,
            }),
            ignore_size: !hello.sizes_windows,
        }),
        client: Mutex::new(None),
        model: Mutex::new(None),
        up: AtomicBool::new(false),
        model_pending: AtomicBool::new(false),
        fetched: Mutex::new(None),
        decoders: Mutex::new(Vec::new()),
        views: AtomicU64::new(0),
        calls: Mutex::new(0),
        idle: Condvar::new(),
        running: Mutex::new(()),
    });
    let worker = Arc::clone(&shared);
    let Ok(worker) = std::thread::Builder::new()
        .name("ko-client".to_owned())
        .spawn(move || engine::run(&worker))
    else {
        return Code::Io;
    };
    // SAFETY: out is non-null and writable by contract.
    unsafe { *out = Box::into_raw(Box::new(Client { shared, worker })) };
    Code::Ok
}

/// # Safety
///
/// `client` is null or a handle from `ko_client_connect` that no earlier call
/// closed, and no other call on it starts during this one.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_client_close(client: *mut Client) -> Code {
    if client.is_null() {
        return Code::Argument;
    }
    // SAFETY: client is a live handle that this call consumes, by contract.
    let Client { shared, worker } = *unsafe { Box::from_raw(client) };
    shared.cancel.wake();
    if RUNNING.get() != Arc::as_ptr(&shared) {
        drop(locked(&shared.running));
    }
    let _ = worker.join();
    for view in std::mem::take(&mut *locked(&shared.decoders)) {
        view.shut();
    }
    let mut calls = locked(&shared.calls);
    while *calls > 0 {
        calls = shared
            .idle
            .wait(calls)
            .unwrap_or_else(PoisonError::into_inner);
    }
    Code::Ok
}

/// # Safety
///
/// `client` is a live handle. `out` is null or writable for one `ko_buffer`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_client_model(client_: *const Client, out: *mut Buffer) -> Code {
    let Some(client) = client(client_).filter(|_| !out.is_null()) else {
        return Code::Argument;
    };
    empty(out);
    let model = locked(&client.shared.model);
    let Some(model) = model.as_ref() else {
        return Code::Closed;
    };
    match model_json(model) {
        Ok(json) => {
            hand_over(out, json);
            Code::Ok
        }
        Err(_) => Code::Protocol,
    }
}

const SELECT_SESSION: c_int = 1;
const SELECT_WINDOW: c_int = 2;
const SELECT_PANE: c_int = 3;

/// # Safety
///
/// `client` is a live handle. `id` is null or a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_client_select(
    client_: *const Client,
    kind: c_int,
    id: *const c_char,
) -> Code {
    let (Some(client), Some(id)) = (client(client_), text_of(id)) else {
        return Code::Argument;
    };
    let selection = match kind {
        SELECT_SESSION => id.parse().ok().map(|id| Selection {
            session: Some(id),
            ..Selection::default()
        }),
        SELECT_WINDOW => id.parse::<WindowId>().ok().map(|id| Selection {
            window: Some(id),
            ..Selection::default()
        }),
        SELECT_PANE => id.parse().ok().map(|id| Selection {
            pane: Some(id),
            ..Selection::default()
        }),
        _ => None,
    };
    let Some(selection) = selection else {
        return Code::Argument;
    };
    locked(&client.shared.hello).selection = selection;
    request(client, ClientRequest::Select(selection))
}

/// # Safety
///
/// `client` is a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_client_switch(
    client_: *const Client,
    over: c_int,
    direction: c_int,
) -> Code {
    let Some(client) = client(client_) else {
        return Code::Argument;
    };
    let (over, direction) = match (over, direction) {
        (1, 1) => (Over::Session, Direction::Next),
        (1, 2) => (Over::Session, Direction::Previous),
        (2, 1) => (Over::Window, Direction::Next),
        (2, 2) => (Over::Window, Direction::Previous),
        _ => return Code::Argument,
    };
    request(client, ClientRequest::Switch(Switch { over, direction }))
}

/// # Safety
///
/// `client` is a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_client_size(client_: *const Client, cols: u16, rows: u16) -> Code {
    let (Some(client), Some(cols), Some(rows)) = (
        client(client_),
        frame::Dim::new(cols),
        frame::Dim::new(rows),
    ) else {
        return Code::Argument;
    };
    let size = frame::Size {
        cols,
        rows,
        cell_px: None,
    };
    locked(&client.shared.hello).size = protocol::Size(size);
    request(client, ClientRequest::Size(protocol::Size(size)))
}

/// # Safety
///
/// `client` is a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_client_focus(client_: *const Client, focused: bool) -> Code {
    let Some(client) = client(client_) else {
        return Code::Argument;
    };
    locked(&client.shared.hello).focused = focused;
    request(client, ClientRequest::Focused { focused })
}

/// # Safety
///
/// `client` is a live handle. `panes` is null with `count` 0, or points to
/// `count` NUL-terminated strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_client_observe(
    client_: *const Client,
    panes: *const *const c_char,
    count: usize,
    attending: bool,
) -> Code {
    let Some(client) = client(client_) else {
        return Code::Argument;
    };
    let names: &[*const c_char] = if panes.is_null() {
        &[]
    } else {
        // SAFETY: panes points to count strings by contract.
        unsafe { std::slice::from_raw_parts(panes, count) }
    };
    let ids: Option<Vec<PaneId>> = names
        .iter()
        .map(|name| text_of(*name).and_then(|name| name.parse().ok()))
        .collect();
    let Some(ids) = ids else {
        return Code::Argument;
    };
    match locked(&client.shared.model).as_mut() {
        Some(model) => {
            model.observe(&ids, attending);
            Code::Ok
        }
        None => Code::Closed,
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
        match layout::send(socket, id, revision, document.layout, Some(cancel)) {
            Ok(Ok(snapshot)) => Ok(protocol::json(&snapshot).into_bytes()),
            Ok(Err(newer)) => Err((Code::Conflict, protocol::json(&newer).into_bytes())),
            Err(message) => Err(io_failure(message)),
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
            id,
            &Route::ListRuns { show, parent: None },
            b"",
            Some(cancel),
        )
        .map_err(io_failure)
    })
}

/// # Safety
///
/// `client` is a live handle. `target` is a NUL-terminated string. `text` is
/// readable for `len` bytes. `out` is writable for one `ko_buffer`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_client_prompt(
    client_: *const Client,
    target: *const c_char,
    text: *const u8,
    len: usize,
    out: *mut Buffer,
) -> Code {
    let (Some(client), Some(target), Some(text)) = (
        client(client_).filter(|_| !out.is_null()),
        text_of(target).and_then(|target| target.parse().ok()),
        bytes_of(text, len).and_then(|text| std::str::from_utf8(text).ok()),
    ) else {
        return Code::Argument;
    };
    let body = protocol::json(&SendPrompt {
        target,
        text: text.to_owned(),
    });
    call(client, out, |socket, id, cancel| {
        wire::request(
            socket,
            id,
            &Route::SendPrompt {},
            body.as_bytes(),
            Some(cancel),
        )
        .map_err(io_failure)
    })
}

/// # Safety
///
/// `buffer` is null or points to a `ko_buffer` that a call of this library
/// filled and that no earlier call freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_buffer_free(buffer: *mut Buffer) {
    // SAFETY: buffer is null or valid for one Buffer by contract.
    let Some(buffer) = (unsafe { buffer.as_mut() }) else {
        return;
    };
    let Buffer { data, len, cap } = std::mem::replace(
        buffer,
        Buffer {
            data: std::ptr::null_mut(),
            len: 0,
            cap: 0,
        },
    );
    if data.is_null() {
        return;
    }
    #[cfg(test)]
    locked(&LIVE_BUFFERS).remove(&(data as usize));
    // SAFETY: data, len and cap are the parts of the Vec that hand_over leaked, and
    // the replace above makes this the only free.
    drop(unsafe { Vec::from_raw_parts(data, len, cap) });
}

/// # Safety
///
/// `client` is a live handle. `pane` is a NUL-terminated string. `restore`,
/// `feed` and `user` follow `ko_client.h`. `out` is writable for one pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_view_open(
    client_: *const Client,
    pane: *const c_char,
    history: bool,
    restore: Option<RestoreFn>,
    feed: Option<FeedFn>,
    user: *mut c_void,
    out: *mut *mut ViewHandle,
) -> Code {
    if out.is_null() {
        return Code::Argument;
    }
    // SAFETY: out is non-null and writable by contract.
    unsafe { *out = std::ptr::null_mut() };
    let (Some(client), Some(pane), Some(restore), Some(feed)) = (
        client(client_),
        text_of(pane).and_then(|pane| pane.parse().ok()),
        restore,
        feed,
    ) else {
        return Code::Argument;
    };
    let shared = &client.shared;
    if shared.cancel.is_set() {
        return Code::Closed;
    }
    let id = shared.views.fetch_add(1, Ordering::SeqCst);
    let history = if history { History::All } else { History::None };
    let Ok(view) = View::start(shared, id, pane, history, (restore, feed), User(user)) else {
        return Code::Io;
    };
    locked(&shared.decoders).push(Arc::clone(&view));
    shared.command(Command::Open(Arc::clone(&view)));
    // SAFETY: out is non-null and writable by contract.
    unsafe {
        *out = Box::into_raw(Box::new(ViewHandle {
            view,
            shared: Arc::clone(shared),
        }));
    }
    Code::Ok
}

/// # Safety
///
/// `view` is null or a handle from `ko_view_open` that no earlier call closed.
/// The call is not made from inside the view's restore callback.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_view_close(view: *mut ViewHandle) -> Code {
    if view.is_null() {
        return Code::Argument;
    }
    // SAFETY: view is a live handle that this call consumes, by contract.
    let ViewHandle { view, shared } = *unsafe { Box::from_raw(view) };
    shared.command(Command::Close(view.id));
    locked(&shared.decoders).retain(|known| known.id != view.id);
    view.shut();
    if RUNNING.get() != Arc::as_ptr(&shared) {
        drop(locked(&shared.running));
    }
    Code::Ok
}

/// # Safety
///
/// `view` is a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_view_resync(view: *const ViewHandle, history: bool) -> Code {
    // SAFETY: view is null or a live handle by contract.
    let Some(handle) = (unsafe { view.as_ref() }) else {
        return Code::Argument;
    };
    if !handle.view.up.load(Ordering::SeqCst) {
        return Code::Closed;
    }
    handle
        .view
        .resync(if history { History::All } else { History::None });
    Code::Ok
}

const INPUT_KEY: c_int = 1;
const INPUT_MOUSE: c_int = 2;
const INPUT_PASTE: c_int = 3;
const INPUT_TEXT: c_int = 4;

fn input_of(event: &InputEvent) -> Option<Input> {
    // SAFETY: each arm reads the union member that kind names.
    unsafe {
        match event.kind {
            INPUT_KEY => {
                let key = event.body.key;
                Some(Input::Key(protocol::Key(frame::Key {
                    action: frame::KeyAction::try_from(u8::try_from(key.action).ok()?).ok()?,
                    key: frame::KeyCode::new(key.key)?,
                    mods: key.mods,
                    unshifted: char::from_u32(key.unshifted)?,
                    text: text_of(key.text)?.to_owned(),
                    composing: key.composing,
                })))
            }
            INPUT_MOUSE => {
                let mouse = event.body.mouse;
                Some(Input::Mouse(protocol::Mouse(frame::Mouse {
                    action: frame::MouseAction::try_from(u8::try_from(mouse.action).ok()?).ok()?,
                    button: frame::MouseButton::try_from(u8::try_from(mouse.button).ok()?).ok()?,
                    col: mouse.col,
                    row: mouse.row,
                    mods: mouse.mods,
                })))
            }
            INPUT_PASTE => {
                let paste = event.body.paste;
                Some(Input::Paste(Paste {
                    text: std::str::from_utf8(bytes_of(paste.text, paste.len)?)
                        .ok()?
                        .to_owned(),
                    check_safe: paste.check_safe,
                    id: paste.has_id.then_some(paste.id),
                }))
            }
            INPUT_TEXT => {
                let text = event.body.text;
                Some(Input::Text {
                    data: Text(bytes_of(text.data, text.len)?.to_vec()),
                })
            }
            _ => None,
        }
    }
}

/// # Safety
///
/// `view` is a live handle. `input` is null or points to a `ko_input` whose
/// pointers are valid for the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_view_input(view: *const ViewHandle, input: *const InputEvent) -> Code {
    // SAFETY: view and input are null or valid by contract.
    let (Some(handle), Some(input)) = (unsafe { view.as_ref() }, unsafe { input.as_ref() }) else {
        return Code::Argument;
    };
    let Some(input) = input_of(input) else {
        return Code::Argument;
    };
    if !handle.view.up.load(Ordering::SeqCst) {
        return Code::Closed;
    }
    handle.shared.command(Command::Input(handle.view.id, input));
    Code::Ok
}

#[unsafe(no_mangle)]
pub extern "C" fn ko_code_message(code: c_int) -> *const c_char {
    let message: &'static CStr = match code {
        c if c == Code::Ok as c_int => c"ok",
        c if c == Code::Argument as c_int => c"invalid argument",
        c if c == Code::NoServer as c_int => c"no ko server at the socket",
        c if c == Code::Io as c_int => c"i/o error",
        c if c == Code::Protocol as c_int => c"protocol error",
        c if c == Code::Closed as c_int => c"the server closed the connection",
        c if c == Code::Conflict as c_int => {
            c"the layout changed: the buffer holds the newer document"
        }
        _ => c"unknown code",
    };
    message.as_ptr()
}

#[cfg(test)]
mod tests {
    use std::io::{Read, Write};
    use std::os::unix::net::{UnixListener, UnixStream};
    use std::sync::atomic::{AtomicPtr, AtomicUsize};
    use std::sync::mpsc::{Receiver, Sender, channel};
    use std::thread::ThreadId;
    use std::time::{Duration, Instant};

    use ko_server::protocol::{
        CommandExit, Listing, Live, PaneStatus, Phase, ProgramStatus, Shell,
    };
    use serde_json::json;
    use tungstenite::Message;
    use tungstenite::handshake::derive_accept_key;
    use tungstenite::protocol::{Role, WebSocket};

    use super::*;

    unsafe extern "C" {
        fn dispatch_queue_create(label: *const c_char, attr: *const c_void) -> *mut c_void;
        fn dispatch_suspend(object: *mut c_void);
        fn dispatch_resume(object: *mut c_void);
        fn dispatch_sync_f(
            queue: *mut c_void,
            context: *mut c_void,
            work: extern "C" fn(*mut c_void),
        );
    }

    type Ws = WebSocket<UnixStream>;
    type Script = Box<dyn FnOnce(&mut Ws, String) + Send>;
    type Plain = Arc<dyn Fn(&Request) -> Option<(u16, String)> + Send + Sync>;

    const WAIT: Duration = Duration::from_secs(10);
    const QUIET: Duration = Duration::from_millis(250);
    const INSTANCE: &str = "0123456789abcdef0123456789abcdef";
    const OTHER_INSTANCE: &str = "fedcba9876543210fedcba9876543210";
    const NO_FUTURE: u64 = 10_000_000_000;

    fn welcome(instance: &str, continuation: usize) -> String {
        format!(
            r#"{{"type":"welcome","client":"client_7","limits":{{"terminal":{{"scrollback":{{"type":"disabled"}},"apc_max_bytes":1,"kitty_images_max_bytes":1,"continuation_max_bytes":{continuation}}},"media":[]}},"instance":"{instance}","now":42}}"#
        )
    }

    fn layout(revision: u64) -> String {
        format!(
            r#"{{"type":"layout","revision":{revision},"layout":{{"sessions":[{{"id":"session_1","name":"s","vars":{{}},"windows":[{{"id":"window_1","name":"w","vars":{{}},"cols":80,"rows":24,"focus":"pane_1","tree":{{"split":"h","children":[{{"pane":"pane_1","cols":40,"rows":24}},{{"pane":"pane_2","cols":39,"rows":24}}]}},"floats":[]}}]}}]}}}}"#
        )
    }

    #[derive(Debug, PartialEq, Eq)]
    enum Seen {
        Welcome(String, String, u64, bool),
        Layout(u64, u32, u32, u32),
        Model,
        Selected(Option<String>, Option<String>, Option<String>),
        Alert(c_int, String, Option<String>, Option<String>),
        Failed(Code, String),
        Restored(u64, Restored),
        Closed(Code, String),
    }

    struct Delivered {
        seen: Seen,
        name: Option<String>,
    }

    struct Probe {
        events: Sender<Delivered>,
        client: AtomicPtr<Client>,
        on_welcome: Box<dyn Fn(&Probe) + Send + Sync>,
    }

    fn owned(pointer: *const c_char) -> String {
        // SAFETY: the core passes NUL-terminated strings.
        unsafe { CStr::from_ptr(pointer) }
            .to_string_lossy()
            .into_owned()
    }

    fn optional(pointer: *const c_char) -> Option<String> {
        (!pointer.is_null()).then(|| owned(pointer))
    }

    unsafe extern "C" fn record(user: *mut c_void, event: *const Event) {
        // SAFETY: user is the Probe that the test keeps alive until its queue is flushed,
        // and event is valid during the callback.
        let (probe, event) = unsafe { (&*user.cast::<Probe>(), &*event) };
        // SAFETY: each arm reads the union member that the kind names.
        let seen = unsafe {
            match event.kind {
                EVENT_WELCOME => {
                    let welcome = event.body.welcome;
                    Seen::Welcome(
                        owned(welcome.client),
                        owned(welcome.instance),
                        welcome.now,
                        welcome.fresh,
                    )
                }
                EVENT_LAYOUT => {
                    let layout = event.body.layout;
                    Seen::Layout(
                        layout.revision,
                        layout.sessions,
                        layout.windows,
                        layout.panes,
                    )
                }
                EVENT_MODEL => Seen::Model,
                EVENT_SELECTED => {
                    let selected = event.body.selected;
                    Seen::Selected(
                        optional(selected.session),
                        optional(selected.window),
                        optional(selected.pane),
                    )
                }
                EVENT_ALERT => {
                    let alert = event.body.alert;
                    Seen::Alert(
                        alert.kind,
                        owned(alert.pane),
                        optional(alert.title),
                        optional(alert.body),
                    )
                }
                EVENT_VIEW_RESTORED => {
                    let restored = event.body.view_restored;
                    Seen::Restored(restored.generation, restored.result)
                }
                EVENT_VIEW_CLOSED => {
                    let closed = event.body.view_closed;
                    Seen::Closed(closed.code, owned(closed.message))
                }
                _ => {
                    let failure = event.body.failure;
                    Seen::Failed(failure.code, owned(failure.message))
                }
            }
        };
        let thread = std::thread::current();
        let _ = probe.events.send(Delivered {
            seen,
            name: thread.name().map(str::to_owned),
        });
        if event.kind == EVENT_WELCOME {
            (probe.on_welcome)(probe);
        }
    }

    fn close(client: *mut Client) {
        // SAFETY: the handle is live and closed once.
        assert_eq!(unsafe { ko_client_close(client) }, Code::Ok);
    }

    fn close_view(view: *mut ViewHandle) {
        // SAFETY: the handle is live and closed once, not from a restore.
        assert_eq!(unsafe { ko_view_close(view) }, Code::Ok);
    }

    struct Fixture {
        queue: *mut c_void,
        probe: &'static Probe,
        events: Receiver<Delivered>,
    }

    impl Fixture {
        fn new() -> Fixture {
            Fixture::on_welcome(|_| {})
        }

        fn on_welcome(on_welcome: impl Fn(&Probe) + Send + Sync + 'static) -> Fixture {
            let (events, receiver) = channel();
            Fixture {
                // SAFETY: a null attribute makes a serial queue; the label is NUL-terminated.
                queue: unsafe { dispatch_queue_create(c"ko.test".as_ptr(), std::ptr::null()) },
                probe: Box::leak(Box::new(Probe {
                    events,
                    client: AtomicPtr::new(std::ptr::null_mut()),
                    on_welcome: Box::new(on_welcome),
                })),
                events: receiver,
            }
        }

        fn connect(&self, socket: &Server) -> *mut Client {
            self.connect_as(socket, None)
        }

        fn connect_as(&self, socket: &Server, hello: Option<HelloIn>) -> *mut Client {
            let mut path = socket.socket();
            path.push(0);
            let mut out = std::ptr::null_mut();
            let user = std::ptr::from_ref(self.probe).cast_mut().cast();
            // SAFETY: path is NUL-terminated, the queue is live, out is writable, and
            // the probe outlives the queue's last callback.
            let code = unsafe {
                ko_client_connect(
                    path.as_ptr().cast(),
                    self.queue,
                    Some(record),
                    user,
                    hello.as_ref().map_or(std::ptr::null(), std::ptr::from_ref),
                    &mut out,
                )
            };
            path.fill(b'X');
            assert_eq!(code, Code::Ok);
            self.probe.client.store(out, Ordering::SeqCst);
            out
        }

        fn delivered(&self) -> Delivered {
            let delivered = self.events.recv_timeout(WAIT).unwrap();
            assert!(
                !matches!(
                    delivered.name.as_deref(),
                    Some("ko-client" | "ko-view-decoder")
                ),
                "a callback on {:?}",
                delivered.name
            );
            delivered
        }

        fn next(&self) -> Seen {
            self.delivered().seen
        }

        fn flush(&self) {
            extern "C" fn nothing(_: *mut c_void) {}
            // SAFETY: the queue is live and not suspended by the caller.
            unsafe { dispatch_sync_f(self.queue, std::ptr::null_mut(), nothing) }
        }

        fn quiet(&self) -> Vec<Seen> {
            self.flush();
            self.events.try_iter().map(|seen| seen.seen).collect()
        }

        fn quiet_for(&self, window: Duration) -> Vec<Seen> {
            std::thread::sleep(window);
            self.quiet()
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            // SAFETY: the queue was created here and nothing uses it after the flush.
            unsafe { dispatch_release(self.queue) }
        }
    }

    #[derive(Debug, Clone)]
    struct Request {
        head: String,
        method: String,
        target: String,
        body: Vec<u8>,
    }

    struct Routes {
        clients: Vec<Script>,
        views: Vec<Option<Script>>,
        plain: Plain,
        stall: Option<(String, Mutex<Sender<()>>)>,
    }

    fn answer_empty(_: &Request) -> Option<(u16, String)> {
        Some((200, "[]".to_owned()))
    }

    fn client_script(script: impl FnOnce(&mut Ws, String) + Send + 'static) -> Routes {
        Routes {
            clients: vec![Box::new(script)],
            views: Vec::new(),
            plain: Arc::new(answer_empty),
            stall: None,
        }
    }

    impl Routes {
        fn view(mut self, script: impl FnOnce(&mut Ws, String) + Send + 'static) -> Routes {
            self.views.push(Some(Box::new(script)));
            self
        }

        fn refused_view(mut self) -> Routes {
            self.views.push(None);
            self
        }

        fn stall(mut self, target: &str, stalled: Sender<()>) -> Routes {
            self.stall = Some((target.to_owned(), Mutex::new(stalled)));
            self
        }

        fn client(mut self, script: impl FnOnce(&mut Ws, String) + Send + 'static) -> Routes {
            self.clients.push(Box::new(script));
            self
        }

        fn plain(
            mut self,
            plain: impl Fn(&Request) -> Option<(u16, String)> + Send + Sync + 'static,
        ) -> Routes {
            self.plain = Arc::new(plain);
            self
        }
    }

    struct Server {
        dir: PathBuf,
        stop: Arc<AtomicBool>,
        accept: Option<JoinHandle<()>>,
        requests: Arc<Mutex<Vec<Request>>>,
    }

    impl Server {
        fn socket(&self) -> Vec<u8> {
            self.dir.join("socket").as_os_str().as_bytes().to_vec()
        }

        fn targets(&self, method: &str) -> Vec<String> {
            locked(&self.requests)
                .iter()
                .filter(|request| request.method == method)
                .map(|request| request.target.clone())
                .collect()
        }

        fn bodies(&self, method: &str, target: &str) -> Vec<String> {
            locked(&self.requests)
                .iter()
                .filter(|request| request.method == method && request.target == target)
                .map(|request| String::from_utf8_lossy(&request.body).into_owned())
                .collect()
        }
    }

    impl Drop for Server {
        fn drop(&mut self) {
            self.stop.store(true, Ordering::SeqCst);
            if let Some(accept) = self.accept.take() {
                let _ = UnixStream::connect(self.dir.join("socket"));
                let _ = accept.join();
            }
            let _ = std::fs::remove_dir_all(&self.dir);
        }
    }

    fn read_head(stream: &mut UnixStream) -> String {
        let mut head = Vec::new();
        let mut byte = [0];
        while !head.ends_with(b"\r\n\r\n") {
            if stream.read(&mut byte).unwrap_or(0) == 0 {
                break;
            }
            head.push(byte[0]);
        }
        String::from_utf8_lossy(&head).into_owned()
    }

    fn header<'a>(head: &'a str, name: &str) -> Option<&'a str> {
        head.lines().find_map(|line| {
            let (found, value) = line.split_once(": ")?;
            found.eq_ignore_ascii_case(name).then_some(value)
        })
    }

    type Queued = Arc<Mutex<(VecDeque<Script>, VecDeque<Option<Script>>)>>;

    type Stall = Option<(String, Mutex<Sender<()>>)>;

    fn handle(
        mut stream: UnixStream,
        queued: &Queued,
        (plain, stall, halted): (&Plain, &Stall, &AtomicBool),
        requests: &Arc<Mutex<Vec<Request>>>,
    ) {
        let _ = stream.set_nonblocking(false);
        let _ = stream.set_read_timeout(Some(WAIT));
        let head = read_head(&mut stream);
        let mut line = head.lines().next().unwrap_or_default().split(' ');
        let (method, target) = (
            line.next().unwrap_or_default().to_owned(),
            line.next().unwrap_or_default().to_owned(),
        );
        if let Some((stalled, signal)) = stall
            && *stalled == target
        {
            let _ = locked(signal).send(());
            while !halted.load(Ordering::SeqCst) {
                std::thread::sleep(Duration::from_millis(20));
            }
            return;
        }
        let length = header(&head, "Content-Length")
            .and_then(|length| length.parse().ok())
            .unwrap_or(0);
        let mut body = vec![0; length];
        let _ = stream.read_exact(&mut body);
        let request = Request {
            head: head.clone(),
            method,
            target,
            body,
        };
        locked(requests).push(request.clone());
        if let Some(key) = header(&head, "Sec-WebSocket-Key") {
            let script = {
                let mut queued = locked(queued);
                if request.target == "/client" {
                    queued.0.pop_front().map(Some)
                } else {
                    queued.1.pop_front()
                }
            };
            let Some(script) = script.flatten() else {
                let _ = stream.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
                return;
            };
            let accept = derive_accept_key(key.as_bytes());
            let _ = write!(
                stream,
                "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n"
            );
            let mut socket = WebSocket::from_raw_socket(stream, Role::Server, None);
            let hello = if request.target == "/client" {
                socket
                    .read()
                    .ok()
                    .and_then(|message| message.into_text().ok())
                    .map(|text| text.as_str().to_owned())
                    .unwrap_or_default()
            } else {
                String::new()
            };
            script(&mut socket, hello);
        } else {
            match plain(&request) {
                Some((status, body)) => {
                    let _ = write!(
                        stream,
                        "HTTP/1.1 {status} Reply\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}",
                        body.len()
                    );
                }
                None => {
                    let mut byte = [0];
                    while stream.read(&mut byte).unwrap_or(0) > 0 {}
                }
            }
        }
    }

    fn serve(name: &str, routes: Routes) -> Server {
        let dir = PathBuf::from(format!("/tmp/ko-ffi-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let listener = UnixListener::bind(dir.join("socket")).unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let requests = Arc::new(Mutex::new(Vec::new()));
        let (halted, seen) = (Arc::clone(&stop), Arc::clone(&requests));
        let accept = std::thread::spawn(move || {
            let queued: Queued = Arc::new(Mutex::new((
                VecDeque::from(routes.clients),
                VecDeque::from(routes.views),
            )));
            let mut connections = Vec::new();
            let stall = Arc::new(routes.stall);
            while let Ok((stream, _)) = listener.accept() {
                if halted.load(Ordering::SeqCst) {
                    break;
                }
                let (queued, plain, stall, seen, halted) = (
                    Arc::clone(&queued),
                    Arc::clone(&routes.plain),
                    Arc::clone(&stall),
                    Arc::clone(&seen),
                    Arc::clone(&halted),
                );
                connections.push(std::thread::spawn(move || {
                    handle(stream, &queued, (&plain, &stall, &halted), &seen);
                }));
            }
            for connection in connections {
                let _ = connection.join();
            }
        });
        Server {
            dir,
            stop,
            accept: Some(accept),
            requests,
        }
    }

    fn send(socket: &mut Ws, text: &str) {
        socket.send(Message::text(text)).unwrap();
    }

    fn send_binary(socket: &mut Ws, bytes: Vec<u8>) {
        socket.send(Message::binary(bytes)).unwrap();
    }

    fn wait_for_hangup(socket: &mut Ws) {
        while socket.read().is_ok() {}
    }

    fn welcomed(socket: &mut Ws) {
        send(socket, &welcome(INSTANCE, 1));
        send(socket, &layout(0));
    }

    fn text_messages(socket: &mut Ws, count: usize) -> Vec<String> {
        socket.get_ref().set_read_timeout(Some(WAIT)).unwrap();
        (0..count)
            .map_while(|_| {
                loop {
                    match socket.read() {
                        Ok(Message::Text(text)) => break Some(text.as_str().to_owned()),
                        Ok(_) => {}
                        Err(_) => break None,
                    }
                }
            })
            .collect()
    }

    fn output_record(offset: u64, data: &[u8]) -> Vec<u8> {
        [&[1][..], &offset.to_le_bytes(), data].concat()
    }

    fn slice_record(offset: u64, first: bool, last: bool, full: bool, body: &[u8]) -> Vec<u8> {
        let flags = u8::from(first) | u8::from(last) << 1;
        [
            &[2][..],
            &offset.to_le_bytes(),
            &[flags, u8::from(!full)],
            body,
        ]
        .concat()
    }

    fn pattern(from: usize, count: usize) -> Vec<u8> {
        (from..from + count)
            .map(|index| (index.wrapping_mul(31) % 251) as u8)
            .collect()
    }

    type Act = Box<dyn FnMut(&view::Snapshot) -> Restored + Send>;

    #[derive(Debug, Clone, PartialEq, Eq)]
    enum Fed {
        Bytes(u64, Vec<u8>),
        Resize(u64, u16, u16),
        Dead(u64),
    }

    struct Decoder {
        act: Mutex<Act>,
        threads: Mutex<Vec<(ThreadId, Option<String>)>>,
        trace: Mutex<Vec<String>>,
        fed: Mutex<Sender<Fed>>,
        feeds: Mutex<Receiver<Fed>>,
        fed_on: Mutex<Vec<Option<String>>>,
        hold_first_feed: Mutex<Option<Receiver<()>>>,
    }

    impl Decoder {
        fn new(act: impl FnMut(&view::Snapshot) -> Restored + Send + 'static) -> &'static Decoder {
            let (fed, feeds) = channel();
            Box::leak(Box::new(Decoder {
                act: Mutex::new(Box::new(act)),
                threads: Mutex::new(Vec::new()),
                trace: Mutex::new(Vec::new()),
                fed: Mutex::new(fed),
                feeds: Mutex::new(feeds),
                fed_on: Mutex::new(Vec::new()),
                hold_first_feed: Mutex::new(None),
            }))
        }

        fn ran_on(&self) -> Vec<(ThreadId, Option<String>)> {
            locked(&self.threads).clone()
        }

        fn trace(&self) -> Vec<String> {
            locked(&self.trace).clone()
        }

        fn hold_first_feed(&self, gate: Receiver<()>) {
            *locked(&self.hold_first_feed) = Some(gate);
        }

        fn next_feed(&self) -> Fed {
            locked(&self.feeds).recv_timeout(WAIT).unwrap()
        }
    }

    unsafe extern "C" fn restore(user: *mut c_void, snapshot: *const view::Snapshot) -> c_int {
        // SAFETY: user is the Decoder that the test keeps alive until the view closed, and
        // snapshot is valid during the call.
        let (decoder, snapshot) = unsafe { (&*user.cast::<Decoder>(), &*snapshot) };
        let thread = std::thread::current();
        locked(&decoder.threads).push((thread.id(), thread.name().map(str::to_owned)));
        let generation = snapshot.generation;
        locked(&decoder.trace).push(format!("restore {generation} start"));
        let result = (locked(&decoder.act))(snapshot);
        locked(&decoder.trace).push(format!("restore {generation} end"));
        result as c_int
    }

    unsafe extern "C" fn feed(user: *mut c_void, item: *const FeedItem) {
        // SAFETY: as in restore; the item is valid during the call.
        let (decoder, item) = unsafe { (&*user.cast::<Decoder>(), &*item) };
        let fed = match item.kind {
            1 => Fed::Bytes(
                item.offset,
                // SAFETY: a bytes item points at len bytes.
                unsafe { std::slice::from_raw_parts(item.data, item.len) }.to_vec(),
            ),
            2 => Fed::Resize(item.offset, item.cols, item.rows),
            _ => Fed::Dead(item.offset),
        };
        let held = locked(&decoder.hold_first_feed).take();
        if let Some(gate) = held {
            let _ = gate.recv_timeout(WAIT);
        }
        locked(&decoder.fed_on).push(std::thread::current().name().map(str::to_owned));
        let line = match &fed {
            Fed::Bytes(_, data) => format!("feed {}", String::from_utf8_lossy(data)),
            other => format!("feed {other:?}"),
        };
        locked(&decoder.trace).push(line);
        let _ = locked(&decoder.fed).send(fed);
    }

    // Bytes up to `limit` or the end; Err when the core cancelled the read.
    fn pull(snapshot: &view::Snapshot, limit: usize, chunk: usize) -> Result<(Vec<u8>, bool), ()> {
        let mut all = Vec::new();
        while all.len() < limit {
            let mut buffer = vec![0; chunk.min(limit - all.len())];
            let mut count = 0;
            // SAFETY: the reader and the buffer are valid for the call.
            let read = unsafe {
                (snapshot.read)(
                    snapshot.reader,
                    buffer.as_mut_ptr(),
                    buffer.len(),
                    &mut count,
                )
            };
            if !read {
                return Err(());
            }
            if count == 0 {
                return Ok((all, true));
            }
            all.extend_from_slice(&buffer[..count]);
        }
        Ok((all, false))
    }

    fn open_view(client: *mut Client, decoder: &Decoder, history: bool) -> *mut ViewHandle {
        let mut out = std::ptr::null_mut();
        let user = std::ptr::from_ref::<Decoder>(decoder).cast_mut().cast();
        // SAFETY: the client is live, the pane is NUL-terminated, out is writable, and the
        // decoder outlives the view.
        let code = unsafe {
            ko_view_open(
                client,
                c"pane_1".as_ptr(),
                history,
                Some(restore),
                Some(feed),
                user,
                &mut out,
            )
        };
        assert_eq!(code, Code::Ok);
        out
    }

    fn handle_of<'a>(view: *mut ViewHandle) -> &'a ViewHandle {
        // SAFETY: the test keeps the handle live while it reads it.
        unsafe { &*view }
    }

    fn ready_session(name: &str) -> (Server, Fixture, *mut Client) {
        let server = serve(
            name,
            client_script(|socket, _| {
                welcomed(socket);
                wait_for_hangup(socket);
            }),
        );
        let fixture = Fixture::new();
        let client = fixture.connect(&server);
        assert!(matches!(fixture.next(), Seen::Welcome(..)));
        assert!(matches!(fixture.next(), Seen::Layout(0, ..)));
        (server, fixture, client)
    }

    fn model_of(client: *mut Client) -> Value {
        let mut buffer = Buffer {
            data: std::ptr::null_mut(),
            len: 0,
            cap: 0,
        };
        // SAFETY: the client is live and the buffer is writable.
        assert_eq!(unsafe { ko_client_model(client, &mut buffer) }, Code::Ok);
        // SAFETY: the buffer holds len bytes that the call filled.
        let model =
            serde_json::from_slice(unsafe { std::slice::from_raw_parts(buffer.data, buffer.len) })
                .unwrap();
        freed_once(&mut buffer);
        model
    }

    fn freed_once(buffer: &mut Buffer) {
        let pointer = buffer.data as usize;
        assert!(
            locked(&LIVE_BUFFERS).contains(&pointer),
            "an unknown buffer"
        );
        // SAFETY: the buffer was filled by a call and is freed here for the first time.
        unsafe { ko_buffer_free(buffer) };
        assert!(buffer.data.is_null() && (buffer.len, buffer.cap) == (0, 0));
        assert!(
            !locked(&LIVE_BUFFERS).contains(&pointer),
            "a buffer that stayed live"
        );
        // SAFETY: a zeroed buffer is allowed and frees nothing.
        unsafe { ko_buffer_free(buffer) };
        // SAFETY: a null buffer is allowed and frees nothing.
        unsafe { ko_buffer_free(std::ptr::null_mut()) };
    }

    fn empty_buffer() -> Buffer {
        Buffer {
            data: std::ptr::null_mut(),
            len: 0,
            cap: 0,
        }
    }

    fn contents(buffer: &Buffer) -> String {
        // SAFETY: the buffer was filled by a call and not freed.
        String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(buffer.data, buffer.len) })
            .into_owned()
    }

    #[test]
    fn welcome_then_layout_arrive_on_the_queue_and_later_layouts_follow_in_order() {
        let (greeted, hellos) = channel();
        let server = serve(
            "order",
            client_script(move |socket, hello| {
                let _ = greeted.send(hello);
                send(socket, &welcome(INSTANCE, 1));
                send(socket, &layout(3));
                send(socket, &layout(4));
                wait_for_hangup(socket);
            }),
        );
        let fixture = Fixture::new();
        let client = fixture.connect(&server);
        let hello: Value = serde_json::from_str(&hellos.recv_timeout(WAIT).unwrap()).unwrap();
        assert_eq!(
            hello,
            json!({
                "type": "hello", "kind": "app", "name": "ko_client", "focused": false,
                "size": {"cols": 80, "rows": 24}, "ignore_size": true
            }),
            "a client without a hello struct neither sizes windows nor has focus"
        );
        let seen = [fixture.next(), fixture.next(), fixture.next()];
        let Seen::Welcome(id, instance, now, fresh) = &seen[0] else {
            panic!("{seen:?}");
        };
        assert_eq!(
            (
                id.as_str(),
                instance.as_str(),
                (42..42 + NO_FUTURE).contains(now),
                fresh
            ),
            ("client_7", INSTANCE, true, &true)
        );
        assert_eq!(
            seen[1..],
            [Seen::Layout(3, 1, 1, 2), Seen::Layout(4, 1, 1, 2)]
        );
        close(client);
        assert_eq!(fixture.quiet(), []);
    }

    fn flood(name: &str) -> (Server, Receiver<()>) {
        let (hung_up, hangup) = channel();
        let server = serve(
            name,
            client_script(move |socket, _| {
                send(socket, &welcome(INSTANCE, 1));
                for revision in 0..50 {
                    send(socket, &layout(revision));
                }
                let _ = socket.close(None);
                let _ = socket.flush();
                wait_for_hangup(socket);
                let _ = hung_up.send(());
            }),
        );
        (server, hangup)
    }

    #[test]
    fn nothing_queued_is_delivered_after_a_close_from_inside_a_callback() {
        let (server, hangup) = flood("inside");
        let fixture = Fixture::on_welcome(|probe| close(probe.client.load(Ordering::SeqCst)));
        // SAFETY: the queue is live; it resumes below.
        unsafe { dispatch_suspend(fixture.queue) };
        fixture.connect(&server);
        hangup.recv_timeout(WAIT).unwrap();
        // SAFETY: the queue was suspended once above.
        unsafe { dispatch_resume(fixture.queue) };
        let rest = fixture.quiet();
        assert_eq!(rest.len(), 1, "the welcome only: {rest:?}");
        assert!(matches!(rest[0], Seen::Welcome(..)));
    }

    #[test]
    fn nothing_queued_is_delivered_after_a_close_from_another_thread() {
        let (server, hangup) = flood("outside");
        let fixture = Fixture::new();
        // SAFETY: the queue is live; it resumes below.
        unsafe { dispatch_suspend(fixture.queue) };
        let client = fixture.connect(&server);
        hangup.recv_timeout(WAIT).unwrap();
        close(client);
        // SAFETY: the queue was suspended once above.
        unsafe { dispatch_resume(fixture.queue) };
        assert_eq!(fixture.quiet(), []);
    }

    struct Handle(*mut Client);

    // SAFETY: the pointer is only passed to ko_client_close on one other thread.
    unsafe impl Send for Handle {}

    #[test]
    fn a_close_from_another_thread_waits_for_the_callback_that_is_running() {
        let server = serve(
            "waits",
            client_script(|socket, _| {
                welcomed(socket);
                wait_for_hangup(socket);
            }),
        );
        let (entered, inside) = channel();
        let (open, gate) = channel::<()>();
        let (returned, finished) = (
            Arc::new(AtomicBool::new(false)),
            Arc::new(AtomicBool::new(false)),
        );
        let (callback_done, close_done) = (Arc::clone(&returned), Arc::clone(&finished));
        let gate = Mutex::new(gate);
        let fixture = Fixture::on_welcome(move |_| {
            let _ = entered.send(());
            let _ = locked(&gate).recv_timeout(WAIT);
            callback_done.store(true, Ordering::SeqCst);
        });
        let client = Handle(fixture.connect(&server));
        inside.recv_timeout(WAIT).unwrap();
        let (done, closed) = channel();
        let closing = std::thread::spawn(move || {
            let client = client;
            close(client.0);
            close_done.store(returned.load(Ordering::SeqCst), Ordering::SeqCst);
            let _ = done.send(());
        });
        assert!(closed.recv_timeout(Duration::from_millis(100)).is_err());
        open.send(()).unwrap();
        closed.recv_timeout(WAIT).unwrap();
        closing.join().unwrap();
        assert!(
            finished.load(Ordering::SeqCst),
            "close returned before the callback did"
        );
    }

    #[test]
    fn a_callback_closing_another_handle_waits_for_that_handles_callback() {
        let (entered, inside) = channel();
        let (open, gate) = channel::<()>();
        let returned = Arc::new(AtomicBool::new(false));
        let callback_done = Arc::clone(&returned);
        let gate = Mutex::new(gate);
        let held = Fixture::on_welcome(move |_| {
            let _ = entered.send(());
            let _ = locked(&gate).recv_timeout(WAIT);
            callback_done.store(true, Ordering::SeqCst);
        });
        let (started, a_started) = channel();
        let (answer, answered) = channel();
        let target = Arc::new(AtomicPtr::new(std::ptr::null_mut()));
        let aimed = Arc::clone(&target);
        let seen = Arc::clone(&returned);
        let closer = Fixture::on_welcome(move |_| {
            let _ = started.send(());
            close(aimed.load(Ordering::SeqCst));
            let _ = answer.send(seen.load(Ordering::SeqCst));
        });
        let held_server = serve(
            "held",
            client_script(|socket, _| {
                welcomed(socket);
                wait_for_hangup(socket);
            }),
        );
        let closer_server = serve(
            "closer",
            client_script(|socket, _| {
                welcomed(socket);
                wait_for_hangup(socket);
            }),
        );
        target.store(held.connect(&held_server), Ordering::SeqCst);
        inside.recv_timeout(WAIT).unwrap();
        let client = closer.connect(&closer_server);
        a_started.recv_timeout(WAIT).unwrap();
        assert!(
            answered.recv_timeout(Duration::from_millis(100)).is_err(),
            "close returned while the callback was running"
        );
        open.send(()).unwrap();
        assert!(
            answered.recv_timeout(WAIT).unwrap(),
            "close returned before the callback did"
        );
        close(client);
        held.flush();
    }

    #[test]
    fn a_close_cancels_a_stalled_join_request_and_a_blocked_call_and_ends_the_worker() {
        let (held, panes) = channel();
        let (hung_up, hangup) = channel();
        let held = Mutex::new(held);
        let routes = client_script(move |socket, _| {
            welcomed(socket);
            wait_for_hangup(socket);
            let _ = hung_up.send(());
        })
        .plain(move |request| {
            let _ = locked(&held).send(request.target.clone());
            None
        });
        let server = serve("stalled", routes);
        let fixture = Fixture::new();
        let client = fixture.connect(&server);
        assert_eq!(panes.recv_timeout(WAIT).unwrap(), "/panes");
        let started = Instant::now();
        close(client);
        assert!(started.elapsed() < Duration::from_secs(5));
        hangup.recv_timeout(WAIT).unwrap();
        assert_eq!(fixture.quiet(), []);
    }

    #[test]
    fn a_close_cancels_a_blocked_put_layout_on_another_thread() {
        let (held, requested) = channel();
        let held = Mutex::new(held);
        let routes = client_script(|socket, _| {
            welcomed(socket);
            wait_for_hangup(socket);
        })
        .plain(move |request| {
            if request.method == "PUT" {
                let _ = locked(&held).send(());
                None
            } else {
                answer_empty(request)
            }
        });
        let server = serve("blocked-put", routes);
        let fixture = Fixture::new();
        let client = fixture.connect(&server);
        assert!(matches!(fixture.next(), Seen::Welcome(..)));
        assert!(matches!(fixture.next(), Seen::Layout(0, ..)));
        let blocked = Handle(client);
        let call = std::thread::spawn(move || {
            let blocked = blocked;
            let document = br#"{"revision":0,"layout":{"sessions":[]}}"#;
            let mut out = empty_buffer();
            // SAFETY: the client stays live until the close below returned, which waits
            // for this call.
            let code = unsafe {
                ko_client_put_layout(blocked.0, document.as_ptr(), document.len(), &mut out)
            };
            freed_once(&mut out);
            code
        });
        requested.recv_timeout(WAIT).unwrap();
        let started = Instant::now();
        close(client);
        assert_eq!(call.join().unwrap(), Code::Closed);
        assert!(started.elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn an_idle_connection_answers_a_ping_before_any_other_message_arrives() {
        let server = serve(
            "ping",
            client_script(|socket, _| {
                welcomed(socket);
                socket.send(Message::Ping(Default::default())).unwrap();
                socket
                    .get_ref()
                    .set_read_timeout(Some(Duration::from_secs(5)))
                    .unwrap();
                while let Ok(message) = socket.read() {
                    if matches!(message, Message::Pong(_)) {
                        send(socket, &layout(9));
                        break;
                    }
                }
                wait_for_hangup(socket);
            }),
        );
        let fixture = Fixture::new();
        let client = fixture.connect(&server);
        assert!(matches!(fixture.next(), Seen::Welcome(..)));
        assert!(matches!(fixture.next(), Seen::Layout(0, ..)));
        assert!(matches!(fixture.next(), Seen::Layout(9, ..)));
        close(client);
    }

    #[test]
    fn a_missing_server_a_garbled_welcome_and_a_hangup_each_report_one_failure_per_outage() {
        let fixture = Fixture::new();
        let nowhere = Server {
            dir: PathBuf::from("/tmp/ko-ffi-nowhere"),
            stop: Arc::default(),
            accept: None,
            requests: Arc::default(),
        };
        let client = fixture.connect(&nowhere);
        assert!(
            matches!(fixture.next(), Seen::Failed(Code::NoServer, message) if !message.is_empty())
        );
        assert_eq!(fixture.quiet_for(Duration::from_millis(500)), []);
        close(client);

        let garbled = serve(
            "garbled",
            client_script(|socket, _| send(socket, "not json")),
        );
        let client = fixture.connect(&garbled);
        assert!(matches!(fixture.next(), Seen::Failed(Code::Protocol, _)));
        assert_eq!(fixture.quiet_for(Duration::from_millis(500)), []);
        close(client);

        let hangs_up = serve(
            "hangs-up",
            client_script(|socket, _| {
                send(socket, &welcome(INSTANCE, 1));
                send(socket, &layout(1));
                let _ = socket.close(None);
                let _ = socket.flush();
            }),
        );
        let client = fixture.connect(&hangs_up);
        assert!(matches!(fixture.next(), Seen::Welcome(..)));
        assert!(matches!(fixture.next(), Seen::Layout(1, ..)));
        let failed = fixture.next();
        assert!(
            matches!(failed, Seen::Failed(Code::Closed, _)),
            "{failed:?}"
        );
        close(client);
        assert_eq!(fixture.quiet(), []);
    }

    fn reconnect_server(name: &str, second_instance: &'static str) -> (Server, Sender<()>) {
        let (drop_first, dropped) = channel::<()>();
        let routes = client_script(move |socket, _| {
            welcomed(socket);
            let _ = dropped.recv_timeout(WAIT);
            let _ = socket.close(None);
            let _ = socket.flush();
        })
        .client(move |socket, _| {
            send(socket, &welcome(second_instance, 1));
            send(socket, &layout(2));
            wait_for_hangup(socket);
        })
        .view(|socket, _| {
            send_binary(socket, slice_record(100, true, true, true, b"snap"));
            send_binary(socket, output_record(100, b"abc"));
            send_binary(socket, output_record(103, b"de"));
            wait_for_hangup(socket);
        })
        .view(|socket, _| {
            send_binary(socket, output_record(105, b"f"));
            wait_for_hangup(socket);
        });
        (serve(name, routes), drop_first)
    }

    #[test]
    fn a_reconnect_to_the_same_server_reopens_a_view_at_the_offset_of_its_last_delivered_bytes() {
        let (server, drop_first) = reconnect_server("resume", INSTANCE);
        let fixture = Fixture::new();
        let client = fixture.connect(&server);
        assert!(matches!(fixture.next(), Seen::Welcome(_, _, _, true)));
        assert!(matches!(fixture.next(), Seen::Layout(0, ..)));
        let decoder = Decoder::new(|snapshot| {
            assert_eq!(
                pull(snapshot, usize::MAX, 3).unwrap(),
                (b"snap".to_vec(), true)
            );
            Restored::Ok
        });
        let view = open_view(client, decoder, true);
        assert_eq!(fixture.next(), Seen::Restored(1, Restored::Ok));
        assert_eq!(decoder.next_feed(), Fed::Bytes(100, b"abc".to_vec()));
        assert_eq!(decoder.next_feed(), Fed::Bytes(103, b"de".to_vec()));
        drop_first.send(()).unwrap();
        assert!(matches!(fixture.next(), Seen::Failed(Code::Closed, _)));
        assert!(matches!(fixture.next(), Seen::Welcome(_, _, _, false)));
        assert!(matches!(fixture.next(), Seen::Layout(2, ..)));
        assert_eq!(decoder.next_feed(), Fed::Bytes(105, b"f".to_vec()));
        let views: Vec<String> = server
            .targets("GET")
            .into_iter()
            .filter(|target| target.starts_with("/panes/pane_1/view"))
            .collect();
        assert_eq!(views.len(), 2);
        assert!(!views[0].contains("offset"), "{views:?}");
        assert!(views[1].ends_with("offset=105"), "{views:?}");
        assert_eq!(decoder.ran_on().len(), 1, "no second restore");
        close(client);
        close_view(view);
    }

    #[test]
    fn a_fetch_that_outlives_its_session_does_not_swallow_the_fetch_of_the_next_one() {
        let one = serde_json::to_string(&[pane_row(1, None)]).unwrap();
        let both = serde_json::to_string(&[pane_row(1, None), pane_row(2, None)]).unwrap();
        let panes = AtomicUsize::new(0);
        let (held, is_held) = channel::<()>();
        let (release, gate) = channel::<()>();
        let (held, gate) = (Mutex::new(held), Mutex::new(gate));
        let (drop_first, dropped) = channel::<()>();
        let routes = client_script(move |socket, _| {
            welcomed(socket);
            send(socket, &layout(1));
            let _ = dropped.recv_timeout(WAIT);
            let _ = socket.close(None);
            let _ = socket.flush();
        })
        .client(|socket, _| {
            send(socket, &welcome(INSTANCE, 1));
            send(socket, &layout(2));
            send(socket, &layout(3));
            send(
                socket,
                r#"{"type":"title","pane":"pane_1","title":"after"}"#,
            );
            wait_for_hangup(socket);
        })
        .plain(move |request| {
            if request.target != "/panes" {
                return answer_empty(request);
            }
            Some((
                200,
                match panes.fetch_add(1, Ordering::SeqCst) {
                    0 => "[]".to_owned(),
                    1 => {
                        let _ = locked(&held).send(());
                        let _ = locked(&gate).recv_timeout(WAIT);
                        "[]".to_owned()
                    }
                    2 => one.clone(),
                    _ => both.clone(),
                },
            ))
        });
        let server = serve("stale-fetch", routes);
        let fixture = Fixture::new();
        let client = fixture.connect(&server);
        assert!(matches!(fixture.next(), Seen::Welcome(_, _, _, true)));
        assert!(matches!(fixture.next(), Seen::Layout(0, ..)));
        is_held.recv_timeout(WAIT).unwrap();
        drop_first.send(()).unwrap();
        assert!(matches!(fixture.next(), Seen::Failed(Code::Closed, _)));
        assert!(matches!(fixture.next(), Seen::Welcome(_, _, _, false)));
        assert!(matches!(fixture.next(), Seen::Layout(2, ..)));
        assert_eq!(fixture.next(), Seen::Model);
        release.send(()).unwrap();
        assert!(matches!(fixture.next(), Seen::Layout(3, ..)));
        let mut buffer = empty_buffer();
        // SAFETY: the client is live and the buffer is writable.
        assert_eq!(unsafe { ko_client_model(client, &mut buffer) }, Code::Ok);
        let model: Value = serde_json::from_str(&contents(&buffer)).unwrap();
        freed_once(&mut buffer);
        assert_eq!(model["panes"].as_array().unwrap().len(), 2);
        close(client);
    }

    #[test]
    fn a_reconnect_to_another_server_closes_the_views_and_reports_a_fresh_welcome() {
        let (server, drop_first) = reconnect_server("fresh", OTHER_INSTANCE);
        let fixture = Fixture::new();
        let client = fixture.connect(&server);
        assert!(matches!(fixture.next(), Seen::Welcome(_, _, _, true)));
        assert!(matches!(fixture.next(), Seen::Layout(0, ..)));
        let decoder = Decoder::new(|snapshot| {
            pull(snapshot, usize::MAX, 64).unwrap();
            Restored::Ok
        });
        let view = open_view(client, decoder, true);
        assert_eq!(fixture.next(), Seen::Restored(1, Restored::Ok));
        assert_eq!(decoder.next_feed(), Fed::Bytes(100, b"abc".to_vec()));
        assert_eq!(decoder.next_feed(), Fed::Bytes(103, b"de".to_vec()));
        drop_first.send(()).unwrap();
        assert!(matches!(fixture.next(), Seen::Failed(Code::Closed, _)));
        let welcomed = fixture.next();
        assert!(
            matches!(&welcomed, Seen::Welcome(_, instance, _, true) if instance == OTHER_INSTANCE),
            "{welcomed:?}"
        );
        assert!(matches!(fixture.next(), Seen::Layout(2, ..)));
        assert_eq!(
            fixture.next(),
            Seen::Closed(Code::Closed, "the server restarted".to_owned())
        );
        let input = InputEvent {
            kind: INPUT_TEXT,
            body: InputBody {
                text: TextInput {
                    data: b"x".as_ptr(),
                    len: 1,
                },
            },
        };
        // SAFETY: the handle is live and the input's pointer is valid for the call.
        assert_eq!(unsafe { ko_view_input(view, &input) }, Code::Closed);
        assert_eq!(
            server
                .targets("GET")
                .iter()
                .filter(|t| t.contains("/view"))
                .count(),
            1
        );
        close(client);
        close_view(view);
    }

    fn pane_row(number: u64, status: Option<PaneStatus>) -> Listing {
        let row = Row {
            id: format!("pane_{number}").parse().unwrap(),
            pid: 100,
            command: vec!["/bin/sh".to_owned()],
            cwd: "/".to_owned(),
            title: String::new(),
            dead: None,
            foreground: None,
            status,
            progress: None,
        };
        Listing {
            row,
            vars: Default::default(),
        }
    }

    fn failed_idle_status() -> PaneStatus {
        PaneStatus {
            kind: Live::Terminal(Shell {
                phase: Phase::Idle {
                    last: Some(CommandExit {
                        code: 1,
                        command: "false".to_owned(),
                        started_at: 90,
                        ended_at: 100,
                    }),
                },
                report: None,
            }),
            program_status: ProgramStatus::default(),
            title: "zsh".to_owned(),
            message: None,
            progress: None,
            since: 0,
        }
    }

    #[test]
    fn the_model_buffer_carries_the_tree_the_titles_and_the_seen_marks_and_is_freed_once() {
        let rows =
            serde_json::to_string(&[pane_row(1, Some(failed_idle_status())), pane_row(2, None)])
                .unwrap();
        let server = serve(
            "model",
            client_script(|socket, _| {
                welcomed(socket);
                wait_for_hangup(socket);
            })
            .plain(move |request| {
                Some((
                    200,
                    if request.target == "/panes" {
                        rows.clone()
                    } else {
                        "[]".to_owned()
                    },
                ))
            }),
        );
        let fixture = Fixture::new();
        let client = fixture.connect(&server);
        assert!(matches!(fixture.next(), Seen::Welcome(..)));
        assert!(matches!(fixture.next(), Seen::Layout(0, 1, 1, 2)));
        let marks = |client| {
            let model = model_of(client);
            (
                model["panes"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|pane| {
                        (
                            pane["id"].as_str().unwrap().to_owned(),
                            pane["label"].as_str().unwrap().to_owned(),
                            pane["mark"].as_str().unwrap().to_owned(),
                        )
                    })
                    .collect::<Vec<_>>(),
                model,
            )
        };
        let (panes, model) = marks(client);
        assert_eq!(
            panes,
            [
                ("pane_1".to_owned(), "zsh".to_owned(), "failed".to_owned()),
                ("pane_2".to_owned(), "sh".to_owned(), "none".to_owned()),
            ]
        );
        assert_eq!(
            model["outline"],
            json!([
                {"type": "session", "id": "session_1", "name": "s"},
                {"type": "pane", "id": "pane_1", "depth": 0},
                {"type": "pane", "id": "pane_2", "depth": 0},
            ])
        );
        assert_eq!(model["client"], "client_7");
        assert_eq!(
            model["layout"]["layout"]["sessions"][0]["windows"][0]["cols"],
            80
        );

        let observe = |panes: &[&CStr], attending: bool| {
            let pointers: Vec<*const c_char> = panes.iter().map(|pane| pane.as_ptr()).collect();
            // SAFETY: the client is live and the pointers are NUL-terminated strings.
            unsafe { ko_client_observe(client, pointers.as_ptr(), pointers.len(), attending) }
        };
        assert_eq!(observe(&[c"pane_1"], false), Code::Ok);
        assert_eq!(marks(client).0[0].2, "failed", "not attending sees nothing");
        assert_eq!(observe(&[c"pane_2"], true), Code::Ok);
        assert_eq!(
            marks(client).0[0].2,
            "failed",
            "a pane that is not shown stays unseen"
        );
        assert_eq!(observe(&[c"pane_1", c"pane_2"], true), Code::Ok);
        assert_eq!(marks(client).0[0].2, "none");
        assert_eq!(observe(&[c"nonsense"], true), Code::Argument);
        // SAFETY: the client is live; a null list with count 0 is allowed.
        let code = unsafe { ko_client_observe(client, std::ptr::null(), 0, true) };
        assert_eq!(code, Code::Ok);
        close(client);
    }

    fn focus_of(model: &Value) -> (Value, Value) {
        (
            model["layout"]["revision"].clone(),
            model["layout"]["layout"]["sessions"][0]["windows"][0]["focus"].clone(),
        )
    }

    #[test]
    fn a_focus_event_moves_the_focus_in_the_model_snapshot_and_keeps_the_layout_revision() {
        let (move_focus, moved) = channel::<()>();
        let server = serve(
            "focus",
            client_script(move |socket, _| {
                send(socket, &welcome(INSTANCE, 1));
                send(socket, &layout(4));
                let _ = moved.recv_timeout(WAIT);
                send(
                    socket,
                    r#"{"type":"focus","window":"window_1","pane":"pane_2"}"#,
                );
                wait_for_hangup(socket);
            }),
        );
        let fixture = Fixture::new();
        let client = fixture.connect(&server);
        assert!(matches!(fixture.next(), Seen::Welcome(..)));
        assert_eq!(fixture.next(), Seen::Layout(4, 1, 1, 2));
        assert_eq!(focus_of(&model_of(client)), (json!(4), json!("pane_1")));
        move_focus.send(()).unwrap();
        assert_eq!(fixture.next(), Seen::Layout(4, 1, 1, 2));
        assert_eq!(focus_of(&model_of(client)), (json!(4), json!("pane_2")));
        close(client);
    }

    #[test]
    fn selection_switch_size_and_focus_reach_the_server_and_a_reconnect_greets_with_the_latest() {
        let (sent, requests) = channel();
        let (greeted, hellos) = channel();
        let (drop_first, dropped) = channel::<()>();
        let first_hello = greeted.clone();
        let routes = client_script(move |socket, hello| {
            let _ = first_hello.send(hello);
            welcomed(socket);
            for message in text_messages(socket, 6) {
                let _ = sent.send(message);
            }
            let _ = dropped.recv_timeout(WAIT);
            let _ = socket.close(None);
            let _ = socket.flush();
        })
        .client(move |socket, hello| {
            let _ = greeted.send(hello);
            welcomed(socket);
            wait_for_hangup(socket);
        });
        let server = serve("requests", routes);
        let fixture = Fixture::new();
        let client = fixture.connect_as(
            &server,
            Some(HelloIn {
                cols: 90,
                rows: 28,
                focused: false,
                sizes_windows: true,
            }),
        );
        let hello: Value = serde_json::from_str(&hellos.recv_timeout(WAIT).unwrap()).unwrap();
        assert_eq!(
            (
                &hello["type"],
                &hello["kind"],
                &hello["focused"],
                &hello["ignore_size"],
                &hello["size"]
            ),
            (
                &json!("hello"),
                &json!("app"),
                &json!(false),
                &json!(false),
                &json!({"cols": 90, "rows": 28})
            )
        );
        assert!(matches!(fixture.next(), Seen::Welcome(..)));
        assert!(matches!(fixture.next(), Seen::Layout(0, ..)));
        // SAFETY: the client is live and the strings are NUL-terminated.
        unsafe {
            assert_eq!(
                ko_client_select(client, SELECT_PANE, c"pane_2".as_ptr()),
                Code::Ok
            );
            assert_eq!(
                ko_client_select(client, SELECT_WINDOW, c"window_1".as_ptr()),
                Code::Ok
            );
            assert_eq!(
                ko_client_select(client, SELECT_SESSION, c"session_1".as_ptr()),
                Code::Ok
            );
            assert_eq!(ko_client_switch(client, 2, 1), Code::Ok);
            assert_eq!(ko_client_size(client, 100, 30), Code::Ok);
            assert_eq!(ko_client_focus(client, true), Code::Ok);
            assert_eq!(
                ko_client_select(client, SELECT_PANE, c"nonsense".as_ptr()),
                Code::Argument
            );
            assert_eq!(
                ko_client_select(client, 9, c"pane_1".as_ptr()),
                Code::Argument
            );
            assert_eq!(ko_client_switch(client, 3, 1), Code::Argument);
            assert_eq!(ko_client_size(client, 0, 30), Code::Argument);
        }
        let received: Vec<String> = (0..6)
            .map(|_| requests.recv_timeout(WAIT).unwrap())
            .collect();
        assert_eq!(
            received,
            [
                r#"{"type":"select","pane":"pane_2"}"#,
                r#"{"type":"select","window":"window_1"}"#,
                r#"{"type":"select","session":"session_1"}"#,
                r#"{"type":"switch","over":"window","direction":"next"}"#,
                r#"{"type":"size","cols":100,"rows":30}"#,
                r#"{"type":"focused","focused":true}"#,
            ]
        );
        drop_first.send(()).unwrap();
        let hello: Value = serde_json::from_str(&hellos.recv_timeout(WAIT).unwrap()).unwrap();
        assert_eq!(
            (
                hello["session"].clone(),
                hello["focused"].clone(),
                hello["ignore_size"].clone(),
                hello["size"].clone()
            ),
            (
                json!("session_1"),
                json!(true),
                json!(false),
                json!({"cols": 100, "rows": 30})
            )
        );
        close(client);
    }

    fn snapshot_json(revision: u64) -> String {
        format!(r#"{{"revision":{revision},"layout":{{"sessions":[]}}}}"#)
    }

    #[test]
    fn a_stale_layout_edit_is_a_conflict_with_the_newer_document_and_is_never_sent_again() {
        let taken = Arc::new(Mutex::new(Vec::<String>::new()));
        let kept = Arc::clone(&taken);
        let server = serve(
            "put",
            client_script(|socket, _| {
                welcomed(socket);
                wait_for_hangup(socket);
            })
            .plain(move |request| {
                if request.method != "PUT" {
                    return answer_empty(request);
                }
                let body = String::from_utf8_lossy(&request.body).into_owned();
                if body.starts_with(r#"{"revision":5,"#) {
                    locked(&kept).push(body);
                    Some((200, snapshot_json(6)))
                } else if body.starts_with(r#"{"revision":9,"#) {
                    Some((400, r#"{"kind":"invalid","message":"no"}"#.to_owned()))
                } else {
                    Some((409, snapshot_json(5)))
                }
            }),
        );
        let fixture = Fixture::new();
        let client = fixture.connect(&server);
        assert!(matches!(fixture.next(), Seen::Welcome(..)));
        assert!(matches!(fixture.next(), Seen::Layout(0, ..)));
        let put = |document: &str| {
            let mut out = empty_buffer();
            // SAFETY: the client is live, the document is readable and out is writable.
            let code = unsafe {
                ko_client_put_layout(client, document.as_ptr(), document.len(), &mut out)
            };
            (code, out)
        };
        let window = r#"{"id":"window_1","name":"w","focus":"pane_2","tree":{"pane":"pane_1"}}"#;
        let edit = |revision: u32| {
            format!(
                r#"{{"revision":{revision},"layout":{{"sessions":[{{"id":"session_1","name":"s","windows":[{window}]}}]}}}}"#
            )
        };

        let (code, mut out) = put(&edit(4));
        assert_eq!(code, Code::Conflict);
        assert_eq!(
            serde_json::from_str::<Value>(&contents(&out)).unwrap(),
            json!({"revision": 5, "layout": {"sessions": []}}),
            "the buffer holds the newer document"
        );
        freed_once(&mut out);
        assert_eq!(server.bodies("PUT", "/layout").len(), 1, "no second try");
        assert!(locked(&taken).is_empty(), "the stale edit changed nothing");

        let (code, mut out) = put(&edit(5));
        assert_eq!(
            code,
            Code::Ok,
            "the caller applies its edit to the newer document"
        );
        assert_eq!(
            serde_json::from_str::<Value>(&contents(&out)).unwrap(),
            json!({"revision": 6, "layout": {"sessions": []}})
        );
        freed_once(&mut out);
        let bodies = server.bodies("PUT", "/layout");
        assert_eq!(bodies.len(), 2);
        assert!(
            bodies.iter().all(|body| !body.contains("focus")),
            "a PUT carries no focus: {bodies:?}"
        );
        assert!(
            locked(&server.requests)
                .iter()
                .any(|request| request.method == "PUT"
                    && request.head.contains("Ko-Client: client_7"))
        );

        let (code, mut out) = put(&edit(9));
        assert_eq!(code, Code::Io);
        assert!(contents(&out).contains("400"), "{}", contents(&out));
        freed_once(&mut out);
        let (code, out) = put(r#"{"layout":{"sessions":[]}}"#);
        assert_eq!(
            (code, out.data.is_null()),
            (Code::Argument, true),
            "a document needs the revision it edits"
        );
        let (code, out) = put("not json");
        assert_eq!((code, out.data.is_null()), (Code::Argument, true));
        assert_eq!(server.bodies("PUT", "/layout").len(), 3);
        assert!(
            server
                .targets("GET")
                .iter()
                .all(|target| target != "/layout")
        );
        close(client);
    }

    #[test]
    fn runs_and_prompts_go_to_the_server_as_written_and_come_back_verbatim() {
        let listing = Arc::new(AtomicBool::new(false));
        let armed = Arc::clone(&listing);
        let server = serve(
            "runs",
            client_script(|socket, _| {
                welcomed(socket);
                wait_for_hangup(socket);
            })
            .plain(move |request| match request.target.as_str() {
                "/runs?show=present" if !listing.load(Ordering::SeqCst) => answer_empty(request),
                "/prompt" if request.body.windows(5).any(|window| window == b"boom!") => Some((
                    502,
                    r#"{"kind":"unknown","message":"maybe sent"}"#.to_owned(),
                )),
                "/prompt" => Some((200, r#"{"via":"paste"}"#.to_owned())),
                target if target.starts_with("/runs") => {
                    Some((200, format!(r#"[{{"shown":"{target}"}}]"#)))
                }
                _ => answer_empty(request),
            }),
        );
        let fixture = Fixture::new();
        let client = fixture.connect(&server);
        assert!(matches!(fixture.next(), Seen::Welcome(..)));
        assert!(matches!(fixture.next(), Seen::Layout(0, ..)));
        armed.store(true, Ordering::SeqCst);
        for (show, expected) in [
            (1, "/runs"),
            (2, "/runs?show=present"),
            (3, "/runs?show=all"),
        ] {
            let mut out = empty_buffer();
            // SAFETY: the client is live and out is writable.
            assert_eq!(unsafe { ko_client_runs(client, show, &mut out) }, Code::Ok);
            assert_eq!(contents(&out), format!(r#"[{{"shown":"{expected}"}}]"#));
            freed_once(&mut out);
        }
        let prompt = |target: &CStr, text: &[u8]| {
            let mut out = empty_buffer();
            // SAFETY: the client is live, the strings are valid and out is writable.
            let code = unsafe {
                ko_client_prompt(client, target.as_ptr(), text.as_ptr(), text.len(), &mut out)
            };
            (code, out)
        };
        let (code, mut out) = prompt(c"pane_3", "hi\nthere \u{e9}".as_bytes());
        assert_eq!(
            (code, contents(&out).as_str()),
            (Code::Ok, r#"{"via":"paste"}"#)
        );
        freed_once(&mut out);
        assert_eq!(
            server.bodies("POST", "/prompt"),
            [r#"{"target":"pane_3","text":"hi\nthere é"}"#]
        );
        let (code, mut out) = prompt(c"pane_3", b"boom!");
        assert_eq!(code, Code::Io);
        assert!(contents(&out).contains("502") && contents(&out).contains("maybe sent"));
        freed_once(&mut out);
        assert_eq!(prompt(c"pane_3", &[0xff, 0xfe]).0, Code::Argument);
        assert_eq!(prompt(c"nonsense", b"x").0, Code::Argument);
        // SAFETY: the client is live; the show value is refused.
        let code = unsafe { ko_client_runs(client, 4, &mut empty_buffer()) };
        assert_eq!(code, Code::Argument);
        close(client);
    }

    #[test]
    fn bad_arguments_return_a_code_and_leave_the_out_pointer_null() {
        let fixture = Fixture::new();
        let user = std::ptr::from_ref(fixture.probe).cast_mut().cast();
        let path = c"/tmp/ko-ffi-none/socket";
        let connect = |socket: *const c_char,
                       queue: *mut c_void,
                       callback: Option<Callback>,
                       out: *mut *mut Client| {
            // SAFETY: each argument is null or valid; the call rejects null ones.
            unsafe { ko_client_connect(socket, queue, callback, user, std::ptr::null(), out) }
        };
        let mut out = std::ptr::dangling_mut::<Client>();
        let cases = [
            connect(std::ptr::null(), fixture.queue, Some(record), &mut out),
            connect(c"".as_ptr(), fixture.queue, Some(record), &mut out),
            connect(path.as_ptr(), std::ptr::null_mut(), Some(record), &mut out),
            connect(path.as_ptr(), fixture.queue, None, &mut out),
        ];
        assert_eq!(cases, [Code::Argument; 4]);
        assert!(out.is_null());
        assert_eq!(
            connect(
                path.as_ptr(),
                fixture.queue,
                Some(record),
                std::ptr::null_mut()
            ),
            Code::Argument
        );
        let empty_window = HelloIn {
            cols: 0,
            rows: 24,
            focused: false,
            sizes_windows: false,
        };
        // SAFETY: the socket, the queue and the hello are valid, and out is writable.
        let code = unsafe {
            ko_client_connect(
                path.as_ptr(),
                fixture.queue,
                Some(record),
                user,
                &empty_window,
                &mut out,
            )
        };
        assert_eq!((code, out.is_null()), (Code::Argument, true));
        // SAFETY: null handles are refused by every call below.
        unsafe {
            assert_eq!(ko_client_close(std::ptr::null_mut()), Code::Argument);
            assert_eq!(
                ko_client_model(std::ptr::null(), &mut empty_buffer()),
                Code::Argument
            );
            assert_eq!(
                ko_client_select(std::ptr::null(), 3, c"pane_1".as_ptr()),
                Code::Argument
            );
            assert_eq!(ko_client_switch(std::ptr::null(), 1, 1), Code::Argument);
            assert_eq!(ko_client_size(std::ptr::null(), 1, 1), Code::Argument);
            assert_eq!(ko_client_focus(std::ptr::null(), true), Code::Argument);
            assert_eq!(
                ko_client_observe(std::ptr::null(), std::ptr::null(), 0, true),
                Code::Argument
            );
            assert_eq!(
                ko_client_put_layout(std::ptr::null(), b"{}".as_ptr(), 2, &mut empty_buffer()),
                Code::Argument
            );
            assert_eq!(
                ko_client_runs(std::ptr::null(), 1, &mut empty_buffer()),
                Code::Argument
            );
            assert_eq!(
                ko_client_prompt(
                    std::ptr::null(),
                    c"pane_1".as_ptr(),
                    b"x".as_ptr(),
                    1,
                    &mut empty_buffer()
                ),
                Code::Argument
            );
            assert_eq!(ko_view_close(std::ptr::null_mut()), Code::Argument);
            assert_eq!(ko_view_resync(std::ptr::null(), true), Code::Argument);
            assert_eq!(
                ko_view_input(std::ptr::null(), std::ptr::null()),
                Code::Argument
            );
        }
        let (server, _fixture, client) = ready_session("arguments");
        let mut view = std::ptr::dangling_mut::<ViewHandle>();
        // SAFETY: the client is live; each call has one invalid argument.
        unsafe {
            assert_eq!(
                ko_view_open(
                    client,
                    c"pane_1".as_ptr(),
                    true,
                    None,
                    Some(feed),
                    std::ptr::null_mut(),
                    &mut view
                ),
                Code::Argument
            );
            assert!(view.is_null());
            assert_eq!(
                ko_view_open(
                    client,
                    c"pane_1".as_ptr(),
                    true,
                    Some(restore),
                    None,
                    std::ptr::null_mut(),
                    &mut view
                ),
                Code::Argument
            );
            assert_eq!(
                ko_view_open(
                    client,
                    c"nonsense".as_ptr(),
                    true,
                    Some(restore),
                    Some(feed),
                    std::ptr::null_mut(),
                    &mut view
                ),
                Code::Argument
            );
            assert_eq!(
                ko_view_open(
                    client,
                    std::ptr::null(),
                    true,
                    Some(restore),
                    Some(feed),
                    std::ptr::null_mut(),
                    &mut view
                ),
                Code::Argument
            );
            assert_eq!(
                ko_view_open(
                    client,
                    c"pane_1".as_ptr(),
                    true,
                    Some(restore),
                    Some(feed),
                    std::ptr::null_mut(),
                    std::ptr::null_mut()
                ),
                Code::Argument
            );
        }
        assert!(
            server
                .targets("GET")
                .iter()
                .all(|target| !target.contains("/view"))
        );
        close(client);
    }

    #[test]
    fn every_code_has_its_own_static_message() {
        let messages: Vec<String> = (0..=7)
            .map(|code| {
                // SAFETY: the function returns a static NUL-terminated string.
                unsafe { CStr::from_ptr(ko_code_message(code)) }
                    .to_string_lossy()
                    .into_owned()
            })
            .collect();
        let mut unique = messages.clone();
        unique.sort();
        unique.dedup();
        assert_eq!((unique.len(), messages[7].as_str()), (8, "unknown code"));
    }

    fn logged(log: &Arc<Mutex<Vec<String>>>, line: impl Into<String>) {
        locked(log).push(line.into());
    }

    fn until(what: &str, condition: impl Fn() -> bool) {
        let deadline = Instant::now() + WAIT;
        while !condition() {
            assert!(Instant::now() < deadline, "timed out: {what}");
            std::thread::sleep(Duration::from_millis(1));
        }
    }

    #[test]
    fn a_big_snapshot_streams_to_the_views_decoder_thread_and_the_core_never_holds_it_whole() {
        const TOTAL: usize = 8 << 20;
        const SLICE: usize = 512 << 10;
        let (asked, resync) = channel::<String>();
        let routes = client_script(|socket, _| {
            welcomed(socket);
            wait_for_hangup(socket);
        })
        .view(move |socket, _| {
            let mut sent = 0;
            while sent < TOTAL {
                let count = SLICE.min(TOTAL - sent);
                let record = slice_record(1000, sent == 0, sent + count == TOTAL, true, &pattern(sent, count));
                send_binary(socket, record);
                sent += count;
            }
            send_binary(socket, output_record(1000, b"tail"));
            send(socket, r#"{"type":"marked","offset":1004,"marker":{"type":"resize","cols":100,"rows":30}}"#);
            send(socket, r#"{"type":"marked","offset":1004,"marker":{"type":"dead","at":5,"cause":{"type":"exited","code":0}}}"#);
            let _ = asked.send(text_messages(socket, 1).concat());
            send_binary(socket, slice_record(2000, true, true, false, b"screen"));
            wait_for_hangup(socket);
        });
        let server = serve("stream", routes);
        let fixture = Fixture::new();
        let client = fixture.connect(&server);
        assert!(matches!(fixture.next(), Seen::Welcome(..)));
        assert!(matches!(fixture.next(), Seen::Layout(0, ..)));
        let log = Arc::new(Mutex::new(Vec::new()));
        let notes = Arc::clone(&log);
        let (engaged_tx, engaged) = channel();
        let (proceed_tx, proceed) = channel::<()>();
        let mut calls = 0;
        let decoder = Decoder::new(move |snapshot| {
            calls += 1;
            let (history, generation, offset) =
                (snapshot.history, snapshot.generation, snapshot.offset);
            let mut position = 0;
            let mut intact = true;
            loop {
                let Ok((bytes, ended)) = pull(snapshot, 64 << 10, 64 << 10) else {
                    return Restored::Rejected;
                };
                intact &= bytes
                    == if calls == 1 {
                        pattern(position, bytes.len())
                    } else {
                        b"screen"[position..position + bytes.len()].to_vec()
                    };
                position += bytes.len();
                if ended {
                    break;
                }
                if calls == 1 && position == 64 << 10 {
                    let _ = engaged_tx.send(());
                    let _ = proceed.recv_timeout(WAIT);
                }
            }
            logged(
                &notes,
                format!(
                    "{calls}: history {history} generation {generation} offset {offset} read {position} intact {intact}"
                ),
            );
            Restored::Ok
        });
        let view = open_view(client, decoder, true);
        engaged.recv_timeout(WAIT).unwrap();
        until("the core stops reading a snapshot nobody reads", || {
            handle_of(view).view.pause.load(Ordering::SeqCst)
        });
        proceed_tx.send(()).unwrap();
        assert_eq!(fixture.next(), Seen::Restored(1, Restored::Ok));
        assert_eq!(decoder.next_feed(), Fed::Bytes(1000, b"tail".to_vec()));
        assert_eq!(decoder.next_feed(), Fed::Resize(1004, 100, 30));
        assert_eq!(decoder.next_feed(), Fed::Dead(1004));
        let peak = handle_of(view).view.peak();
        assert!(
            peak > 0 && peak <= 4 * (1 << 20) + SLICE && peak < TOTAL,
            "peak {peak} of {TOTAL}"
        );
        // SAFETY: the view is live.
        assert_eq!(unsafe { ko_view_resync(view, false) }, Code::Ok);
        assert_eq!(
            resync.recv_timeout(WAIT).unwrap(),
            r#"{"type":"resync","history":"none","images":"none"}"#
        );
        assert_eq!(fixture.next(), Seen::Restored(2, Restored::Ok));
        assert_eq!(
            *locked(&log),
            [
                format!("1: history true generation 1 offset 1000 read {TOTAL} intact true"),
                "2: history false generation 2 offset 2000 read 6 intact true".to_owned(),
            ]
        );
        let threads = decoder.ran_on();
        let io_thread = std::thread::current().id();
        assert_eq!(threads.len(), 2);
        assert_eq!(threads[0], threads[1], "one decoder thread for the view");
        assert_eq!(threads[0].1.as_deref(), Some("ko-view-decoder"));
        assert_ne!(threads[0].0, io_thread, "not the test's thread");
        assert!(
            locked(&decoder.fed_on)
                .iter()
                .all(|name| name.as_deref() == Some("ko-view-decoder")),
            "bytes and markers go to the surface on the decoder thread"
        );
        close_view(view);
        close(client);
    }

    #[test]
    fn a_newer_snapshot_cancels_the_blocked_reads_of_the_older_and_waits_for_it_to_end() {
        let (go, proceed) = channel::<()>();
        let routes = client_script(|socket, _| {
            welcomed(socket);
            wait_for_hangup(socket);
        })
        .view(move |socket, _| {
            send_binary(
                socket,
                slice_record(10, true, false, true, &pattern(0, 1000)),
            );
            let _ = proceed.recv_timeout(WAIT);
            send_binary(socket, slice_record(20, true, true, true, &pattern(0, 500)));
            send_binary(socket, output_record(20, b"x"));
            wait_for_hangup(socket);
        });
        let server = serve("newer", routes);
        let fixture = Fixture::new();
        let client = fixture.connect(&server);
        assert!(matches!(fixture.next(), Seen::Welcome(..)));
        assert!(matches!(fixture.next(), Seen::Layout(0, ..)));
        let log = Arc::new(Mutex::new(Vec::new()));
        let notes = Arc::clone(&log);
        let (blocked, is_blocked) = channel();
        let (finish_first, hold) = channel::<()>();
        let mut calls = 0;
        let decoder = Decoder::new(move |snapshot| {
            calls += 1;
            if calls == 1 {
                let first = pull(snapshot, 1000, 1000).map(|(bytes, _)| bytes.len());
                logged(&notes, format!("first read {first:?}"));
                let _ = blocked.send(());
                let cancelled = pull(snapshot, 1, 1).is_err();
                logged(&notes, format!("first cancelled {cancelled}"));
                let _ = hold.recv_timeout(WAIT);
                logged(&notes, "first ended");
                Restored::Rejected
            } else {
                logged(&notes, "second started");
                let read =
                    pull(snapshot, usize::MAX, 64).map(|(bytes, ended)| (bytes.len(), ended));
                logged(&notes, format!("second read {read:?}"));
                Restored::Ok
            }
        });
        let view = open_view(client, decoder, true);
        is_blocked.recv_timeout(WAIT).unwrap();
        go.send(()).unwrap();
        until("the first restore sees its snapshot cancelled", || {
            locked(&log).contains(&"first cancelled true".to_owned())
        });
        assert_eq!(handle_of(view).view.generation(), 2);
        assert!(
            !locked(&log).contains(&"second started".to_owned()),
            "the second restore waits for the first to end"
        );
        finish_first.send(()).unwrap();
        assert_eq!(fixture.next(), Seen::Restored(2, Restored::Ok));
        assert_eq!(decoder.next_feed(), Fed::Bytes(20, b"x".to_vec()));
        assert_eq!(
            *locked(&log),
            [
                "first read Ok(1000)",
                "first cancelled true",
                "first ended",
                "second started",
                "second read Ok((500, true))",
            ]
        );
        assert_eq!(fixture.quiet(), [], "no event for generation 1");
        close_view(view);
        close(client);
    }

    #[test]
    fn a_restore_that_ends_after_a_newer_snapshot_began_delivers_nothing_for_its_generation() {
        let (go, proceed) = channel::<()>();
        let routes = client_script(|socket, _| {
            welcomed(socket);
            wait_for_hangup(socket);
        })
        .view(move |socket, _| {
            send_binary(socket, slice_record(10, true, true, true, b"old"));
            send_binary(socket, output_record(10, b"stale"));
            let _ = proceed.recv_timeout(WAIT);
            send_binary(socket, slice_record(20, true, true, true, b"new"));
            send_binary(socket, output_record(20, b"fresh"));
            wait_for_hangup(socket);
        });
        let server = serve("stale", routes);
        let fixture = Fixture::new();
        let client = fixture.connect(&server);
        assert!(matches!(fixture.next(), Seen::Welcome(..)));
        assert!(matches!(fixture.next(), Seen::Layout(0, ..)));
        let (read, has_read) = channel();
        let (release, gate) = channel::<()>();
        let mut calls = 0;
        let decoder = Decoder::new(move |snapshot| {
            calls += 1;
            let (bytes, ended) = pull(snapshot, usize::MAX, 64).unwrap();
            if calls == 1 {
                let _ = read.send((bytes, ended));
                let _ = gate.recv_timeout(WAIT);
            }
            Restored::Ok
        });
        // SAFETY: the queue is live; it resumes below.
        unsafe { dispatch_suspend(fixture.queue) };
        let view = open_view(client, decoder, true);
        assert_eq!(
            has_read.recv_timeout(WAIT).unwrap(),
            (b"old".to_vec(), true)
        );
        go.send(()).unwrap();
        until("the newer snapshot began", || {
            handle_of(view).view.generation() == 2
        });
        release.send(()).unwrap();
        assert_eq!(decoder.next_feed(), Fed::Bytes(20, b"fresh".to_vec()));
        assert_eq!(
            decoder.trace(),
            [
                "restore 1 start",
                "restore 1 end",
                "restore 2 start",
                "restore 2 end",
                "feed fresh"
            ],
            "the bytes of the old snapshot never reach the surface after the newer restore began"
        );
        // SAFETY: the queue was suspended once above.
        unsafe { dispatch_resume(fixture.queue) };
        assert_eq!(fixture.next(), Seen::Restored(2, Restored::Ok));
        assert_eq!(
            fixture.quiet(),
            [],
            "the old generation's result was dropped"
        );
        close_view(view);
        close(client);
    }

    struct Blocked {
        _server: Server,
        fixture: Fixture,
        client: *mut Client,
        decoder: &'static Decoder,
        view: *mut ViewHandle,
        ended: Arc<AtomicBool>,
        release: Sender<()>,
    }

    impl Blocked {
        // The restore ends once the view is closed, after a pause that only the
        // close can have to wait for.
        fn end_restore_when_closed(&self) {
            let view = Arc::clone(&handle_of(self.view).view);
            let release = self.release.clone();
            std::thread::spawn(move || {
                until("the view is closed", || view.closed.load(Ordering::SeqCst));
                let _ = release.send(());
            });
        }
    }

    fn blocked_view(name: &str) -> Blocked {
        let routes = client_script(|socket, _| {
            welcomed(socket);
            wait_for_hangup(socket);
        })
        .view(|socket, _| {
            send_binary(
                socket,
                slice_record(10, true, false, true, &pattern(0, 100)),
            );
            wait_for_hangup(socket);
        });
        let server = serve(name, routes);
        let fixture = Fixture::new();
        let client = fixture.connect(&server);
        assert!(matches!(fixture.next(), Seen::Welcome(..)));
        assert!(matches!(fixture.next(), Seen::Layout(0, ..)));
        let ended = Arc::new(AtomicBool::new(false));
        let finished = Arc::clone(&ended);
        let (blocked, is_blocked) = channel();
        let (release, released) = channel::<()>();
        let decoder = Decoder::new(move |snapshot| {
            let _ = pull(snapshot, 100, 100);
            let _ = blocked.send(());
            let cancelled = pull(snapshot, 1, 1).is_err();
            let _ = released.recv_timeout(WAIT);
            finished.store(cancelled, Ordering::SeqCst);
            Restored::Rejected
        });
        let view = open_view(client, decoder, true);
        is_blocked.recv_timeout(WAIT).unwrap();
        Blocked {
            _server: server,
            fixture,
            client,
            decoder,
            view,
            ended,
            release,
        }
    }

    #[test]
    fn a_view_close_fails_the_blocked_read_and_returns_only_after_the_restore_ended() {
        let blocked = blocked_view("view-close");
        blocked.end_restore_when_closed();
        close_view(blocked.view);
        assert!(
            blocked.ended.load(Ordering::SeqCst),
            "close returned before the restore ended"
        );
        assert_eq!(
            blocked.fixture.quiet_for(QUIET),
            [],
            "no callback after close"
        );
        assert_eq!(blocked.decoder.ran_on().len(), 1);
        close(blocked.client);
    }

    #[test]
    fn a_client_close_ends_the_restore_of_a_view_that_is_still_open_and_the_view_close_still_works()
    {
        let blocked = blocked_view("client-close");
        blocked.end_restore_when_closed();
        close(blocked.client);
        assert!(
            blocked.ended.load(Ordering::SeqCst),
            "close returned before the restore ended"
        );
        let input = InputEvent {
            kind: INPUT_TEXT,
            body: InputBody {
                text: TextInput {
                    data: b"x".as_ptr(),
                    len: 1,
                },
            },
        };
        // SAFETY: the view handle is live; its client is closed.
        assert_eq!(unsafe { ko_view_input(blocked.view, &input) }, Code::Closed);
        // SAFETY: as above.
        assert_eq!(unsafe { ko_view_resync(blocked.view, true) }, Code::Closed);
        close_view(blocked.view);
        assert_eq!(blocked.fixture.quiet(), []);
    }

    #[test]
    fn a_history_incomplete_restore_asks_the_server_for_a_full_snapshot_and_drops_the_bytes_of_the_failed_one()
     {
        let (asked, resync) = channel::<String>();
        let routes = client_script(|socket, _| {
            welcomed(socket);
            wait_for_hangup(socket);
        })
        .view(move |socket, _| {
            send_binary(socket, slice_record(10, true, true, true, b"cut"));
            send_binary(socket, output_record(10, b"lost"));
            let _ = asked.send(text_messages(socket, 1).concat());
            send_binary(socket, slice_record(50, true, true, true, b"whole"));
            send_binary(socket, output_record(50, b"kept"));
            wait_for_hangup(socket);
        });
        let server = serve("incomplete", routes);
        let fixture = Fixture::new();
        let client = fixture.connect(&server);
        assert!(matches!(fixture.next(), Seen::Welcome(..)));
        assert!(matches!(fixture.next(), Seen::Layout(0, ..)));
        let mut calls = 0;
        let decoder = Decoder::new(move |snapshot| {
            calls += 1;
            pull(snapshot, usize::MAX, 64).unwrap();
            if calls == 1 {
                Restored::HistoryIncomplete
            } else {
                Restored::Ok
            }
        });
        let view = open_view(client, decoder, false);
        assert_eq!(
            resync.recv_timeout(WAIT).unwrap(),
            r#"{"type":"resync","history":"all","images":"none"}"#
        );
        assert_eq!(
            fixture.next(),
            Seen::Restored(1, Restored::HistoryIncomplete)
        );
        assert_eq!(fixture.next(), Seen::Restored(2, Restored::Ok));
        assert_eq!(decoder.next_feed(), Fed::Bytes(50, b"kept".to_vec()));
        assert_eq!(fixture.quiet(), []);
        assert_eq!(
            locked(&handle_of(view).view.options).history,
            History::All,
            "a reconnect opens the view with the options of the resync"
        );
        close_view(view);
        close(client);
    }

    #[test]
    fn only_a_full_snapshot_gives_a_view_an_offset_to_resume_from() {
        let (screen_seen, screen_done) = channel::<()>();
        let (go, proceed) = channel::<()>();
        let routes = client_script(|socket, _| {
            welcomed(socket);
            wait_for_hangup(socket);
        })
        .view(move |socket, _| {
            send_binary(socket, slice_record(10, true, true, false, b"screen"));
            send_binary(socket, output_record(10, b"after"));
            let _ = screen_seen.send(());
            let _ = proceed.recv_timeout(WAIT);
            send_binary(socket, slice_record(50, true, true, true, b"whole"));
            send_binary(socket, output_record(50, b"kept"));
            wait_for_hangup(socket);
        });
        let server = serve("resume-eligibility", routes);
        let fixture = Fixture::new();
        let client = fixture.connect(&server);
        assert!(matches!(fixture.next(), Seen::Welcome(..)));
        assert!(matches!(fixture.next(), Seen::Layout(0, ..)));
        let decoder = Decoder::new(|snapshot| {
            pull(snapshot, usize::MAX, 64).unwrap();
            Restored::Ok
        });
        let view = open_view(client, decoder, false);
        assert_eq!(fixture.next(), Seen::Restored(1, Restored::Ok));
        assert_eq!(decoder.next_feed(), Fed::Bytes(10, b"after".to_vec()));
        screen_done.recv_timeout(WAIT).unwrap();
        assert_eq!(handle_of(view).view.resume_offset(), None);
        go.send(()).unwrap();
        assert_eq!(fixture.next(), Seen::Restored(2, Restored::Ok));
        assert_eq!(decoder.next_feed(), Fed::Bytes(50, b"kept".to_vec()));
        until("the full snapshot's bytes advance the offset", || {
            handle_of(view).view.resume_offset() == Some(54)
        });
        close_view(view);
        close(client);
    }

    #[test]
    fn a_size_mismatch_is_reported_without_a_resync_and_the_apps_resync_is_the_next_request() {
        let (asked, resync) = channel::<String>();
        let routes = client_script(|socket, _| {
            welcomed(socket);
            wait_for_hangup(socket);
        })
        .view(move |socket, _| {
            send_binary(socket, slice_record(10, true, true, true, b"wide"));
            send_binary(socket, output_record(10, b"lost"));
            let _ = asked.send(text_messages(socket, 1).concat());
            send_binary(socket, slice_record(60, true, true, true, b"fit"));
            send_binary(socket, output_record(60, b"later"));
            wait_for_hangup(socket);
        });
        let server = serve("mismatch", routes);
        let fixture = Fixture::new();
        let client = fixture.connect(&server);
        assert!(matches!(fixture.next(), Seen::Welcome(..)));
        assert!(matches!(fixture.next(), Seen::Layout(0, ..)));
        let mut calls = 0;
        let decoder = Decoder::new(move |snapshot| {
            calls += 1;
            pull(snapshot, usize::MAX, 64).unwrap();
            if calls == 1 {
                Restored::SizeMismatch
            } else {
                Restored::Ok
            }
        });
        let view = open_view(client, decoder, true);
        assert_eq!(fixture.next(), Seen::Restored(1, Restored::SizeMismatch));
        // SAFETY: the view is live.
        assert_eq!(unsafe { ko_view_resync(view, true) }, Code::Ok);
        assert_eq!(
            resync.recv_timeout(WAIT).unwrap(),
            r#"{"type":"resync","history":"all","images":"none"}"#,
            "the first request is the app's: the core asked for nothing"
        );
        assert_eq!(fixture.next(), Seen::Restored(2, Restored::Ok));
        assert_eq!(
            decoder.next_feed(),
            Fed::Bytes(60, b"later".to_vec()),
            "the bytes of the rejected snapshot were dropped"
        );
        close_view(view);
        close(client);
    }

    #[test]
    fn the_continuation_limit_in_each_snapshot_is_the_one_the_server_announced() {
        let limits = Arc::new(Mutex::new(Vec::new()));
        for (name, limit, full) in [("limit-a", 3_000_000, true), ("limit-b", 7_000_000, false)] {
            let routes = Routes {
                clients: vec![Box::new(move |socket, _| {
                    send(socket, &welcome(INSTANCE, limit));
                    send(socket, &layout(0));
                    wait_for_hangup(socket);
                })],
                views: Vec::new(),
                plain: Arc::new(answer_empty),
                stall: None,
            }
            .view(move |socket, _| {
                send_binary(socket, slice_record(10, true, true, full, b"s"));
                wait_for_hangup(socket);
            });
            let server = serve(name, routes);
            let fixture = Fixture::new();
            let client = fixture.connect(&server);
            assert!(matches!(fixture.next(), Seen::Welcome(..)));
            assert!(matches!(fixture.next(), Seen::Layout(0, ..)));
            let seen = Arc::clone(&limits);
            let decoder = Decoder::new(move |snapshot| {
                locked(&seen).push((snapshot.continuation_max_bytes, snapshot.history));
                pull(snapshot, usize::MAX, 64).unwrap();
                Restored::Ok
            });
            let view = open_view(client, decoder, true);
            assert_eq!(fixture.next(), Seen::Restored(1, Restored::Ok));
            close_view(view);
            close(client);
        }
        assert_eq!(*locked(&limits), [(3_000_000, true), (7_000_000, false)]);
    }

    #[test]
    fn nothing_is_delivered_for_a_view_after_its_close_even_when_the_events_were_queued() {
        let routes = client_script(|socket, _| {
            welcomed(socket);
            wait_for_hangup(socket);
        })
        .view(|socket, _| {
            send_binary(socket, slice_record(10, true, true, true, b"s"));
            send_binary(socket, output_record(10, b"queued"));
            wait_for_hangup(socket);
        });
        let server = serve("view-queued", routes);
        let fixture = Fixture::new();
        let client = fixture.connect(&server);
        assert!(matches!(fixture.next(), Seen::Welcome(..)));
        assert!(matches!(fixture.next(), Seen::Layout(0, ..)));
        // SAFETY: the queue is live; it resumes below.
        unsafe { dispatch_suspend(fixture.queue) };
        let decoder = Decoder::new(|snapshot| {
            pull(snapshot, usize::MAX, 64).unwrap();
            Restored::Ok
        });
        let view = open_view(client, decoder, true);
        assert_eq!(
            decoder.next_feed(),
            Fed::Bytes(10, b"queued".to_vec()),
            "the surface does not wait for the caller's queue, and the restored event is queued by now"
        );
        close_view(view);
        // SAFETY: the queue was suspended once above.
        unsafe { dispatch_resume(fixture.queue) };
        assert_eq!(fixture.quiet(), []);
        close(client);
    }

    #[test]
    fn every_kind_of_input_reaches_the_pane_as_the_protocol_writes_it_and_bad_input_is_refused() {
        let (got, received) = channel();
        let routes = client_script(|socket, _| {
            welcomed(socket);
            wait_for_hangup(socket);
        })
        .view(move |socket, _| {
            send_binary(socket, slice_record(10, true, true, true, b"s"));
            for message in text_messages(socket, 4) {
                let _ = got.send(message);
            }
            wait_for_hangup(socket);
        });
        let server = serve("input", routes);
        let fixture = Fixture::new();
        let client = fixture.connect(&server);
        assert!(matches!(fixture.next(), Seen::Welcome(..)));
        assert!(matches!(fixture.next(), Seen::Layout(0, ..)));
        let decoder = Decoder::new(|snapshot| {
            pull(snapshot, usize::MAX, 64).unwrap();
            Restored::Ok
        });
        let view = open_view(client, decoder, true);
        assert_eq!(fixture.next(), Seen::Restored(1, Restored::Ok));
        let input = |input: InputEvent| {
            // SAFETY: the view is live and the input's pointers outlive the call.
            unsafe { ko_view_input(view, &input) }
        };
        let key = |key: u16, text: &CStr| InputEvent {
            kind: INPUT_KEY,
            body: InputBody {
                key: KeyInput {
                    action: 1,
                    key,
                    mods: 2,
                    unshifted: 97,
                    text: text.as_ptr(),
                    composing: false,
                },
            },
        };
        assert_eq!(input(key(4, c"a")), Code::Ok);
        assert_eq!(
            input(InputEvent {
                kind: INPUT_MOUSE,
                body: InputBody {
                    mouse: MouseInput {
                        action: 0,
                        button: 1,
                        col: 3,
                        row: 4,
                        mods: 0
                    }
                },
            }),
            Code::Ok
        );
        assert_eq!(
            input(InputEvent {
                kind: INPUT_PASTE,
                body: InputBody {
                    paste: PasteInput {
                        text: b"a\nb".as_ptr(),
                        len: 3,
                        check_safe: true,
                        has_id: true,
                        id: 7
                    }
                },
            }),
            Code::Ok
        );
        assert_eq!(
            input(InputEvent {
                kind: INPUT_TEXT,
                body: InputBody {
                    text: TextInput {
                        data: b"hi".as_ptr(),
                        len: 2
                    }
                },
            }),
            Code::Ok
        );
        let sent: Vec<String> = (0..4)
            .map(|_| received.recv_timeout(WAIT).unwrap())
            .collect();
        assert_eq!(
            sent,
            [
                r#"{"type":"input","input":{"type":"key","action":"press","key":4,"mods":2,"unshifted_codepoint":97,"text":"a","composing":false}}"#,
                r#"{"type":"input","input":{"type":"mouse","action":"press","button":"left","col":3,"row":4,"mods":0}}"#,
                r#"{"type":"input","input":{"type":"paste","text":"a\nb","check_safe":true,"id":7}}"#,
                r#"{"type":"input","input":{"type":"text","data":"aGk="}}"#,
            ]
        );
        assert_eq!(input(key(u16::MAX, c"a")), Code::Argument);
        assert_eq!(
            input(InputEvent {
                kind: INPUT_PASTE,
                body: InputBody {
                    paste: PasteInput {
                        text: [0xff].as_ptr(),
                        len: 1,
                        check_safe: false,
                        has_id: false,
                        id: 0
                    }
                },
            }),
            Code::Argument
        );
        assert_eq!(
            input(InputEvent {
                kind: 99,
                body: InputBody {
                    text: TextInput {
                        data: std::ptr::null(),
                        len: 0
                    }
                }
            }),
            Code::Argument
        );
        close_view(view);
        close(client);
    }

    #[test]
    fn a_close_cancels_a_request_write_that_the_server_stopped_reading() {
        let (stalled, is_stalled) = channel();
        let routes = client_script(|socket, _| {
            welcomed(socket);
            wait_for_hangup(socket);
        })
        .stall("/prompt", stalled);
        let server = serve("stalled-write", routes);
        let fixture = Fixture::new();
        let client = fixture.connect(&server);
        assert!(matches!(fixture.next(), Seen::Welcome(..)));
        assert!(matches!(fixture.next(), Seen::Layout(0, ..)));
        let blocked = Handle(client);
        let call = std::thread::spawn(move || {
            let blocked = blocked;
            let text = vec![b'x'; 16 << 20];
            let mut out = empty_buffer();
            // SAFETY: the client stays live until the close below returned, which waits for
            // this call; the strings and the buffer are valid.
            let code = unsafe {
                ko_client_prompt(
                    blocked.0,
                    c"pane_1".as_ptr(),
                    text.as_ptr(),
                    text.len(),
                    &mut out,
                )
            };
            freed_once(&mut out);
            code
        });
        is_stalled.recv_timeout(WAIT).unwrap();
        let started = Instant::now();
        close(client);
        assert_eq!(call.join().unwrap(), Code::Closed);
        assert!(started.elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn a_client_close_waits_for_the_restore_of_a_view_the_server_already_closed() {
        let (server, drop_first) = reconnect_server("closed-by-server", OTHER_INSTANCE);
        let fixture = Fixture::new();
        let client = fixture.connect(&server);
        assert!(matches!(fixture.next(), Seen::Welcome(..)));
        assert!(matches!(fixture.next(), Seen::Layout(0, ..)));
        let (read, has_read) = channel();
        let (release, gate) = channel::<()>();
        let ended = Arc::new(AtomicBool::new(false));
        let finished = Arc::clone(&ended);
        let decoder = Decoder::new(move |snapshot| {
            pull(snapshot, usize::MAX, 64).unwrap();
            let _ = read.send(());
            let _ = gate.recv_timeout(WAIT);
            finished.store(true, Ordering::SeqCst);
            Restored::Ok
        });
        let view = open_view(client, decoder, true);
        has_read.recv_timeout(WAIT).unwrap();
        drop_first.send(()).unwrap();
        assert!(matches!(fixture.next(), Seen::Failed(Code::Closed, _)));
        assert!(matches!(fixture.next(), Seen::Welcome(_, _, _, true)));
        assert!(matches!(fixture.next(), Seen::Layout(2, ..)));
        assert_eq!(
            fixture.next(),
            Seen::Closed(Code::Closed, "the server restarted".to_owned())
        );
        let closing = Handle(client);
        let (done, closed) = channel();
        std::thread::spawn(move || {
            let closing = closing;
            close(closing.0);
            let _ = done.send(());
        });
        assert!(
            closed.recv_timeout(Duration::from_millis(200)).is_err(),
            "the client close returned while the restore of the closed view ran"
        );
        release.send(()).unwrap();
        closed.recv_timeout(WAIT).unwrap();
        assert!(ended.load(Ordering::SeqCst));
        close_view(view);
    }

    #[test]
    fn a_surface_that_is_slow_to_take_live_output_pauses_the_connection_and_it_goes_on_after() {
        const RECORD: usize = 256 << 10;
        const COUNT: usize = 64;
        let routes = client_script(|socket, _| {
            welcomed(socket);
            wait_for_hangup(socket);
        })
        .view(|socket, _| {
            send_binary(socket, slice_record(100, true, true, true, b"s"));
            for record in 0..COUNT {
                send_binary(
                    socket,
                    output_record(100 + (record * RECORD) as u64, &pattern(record, RECORD)),
                );
            }
            wait_for_hangup(socket);
        });
        let server = serve("live-pause", routes);
        let fixture = Fixture::new();
        let client = fixture.connect(&server);
        assert!(matches!(fixture.next(), Seen::Welcome(..)));
        assert!(matches!(fixture.next(), Seen::Layout(0, ..)));
        let decoder = Decoder::new(|snapshot| {
            pull(snapshot, usize::MAX, 64).unwrap();
            Restored::Ok
        });
        let (open, gate) = channel::<()>();
        decoder.hold_first_feed(gate);
        let view = open_view(client, decoder, true);
        until("the core stops reading output nobody takes", || {
            handle_of(view).view.pause.load(Ordering::SeqCst)
        });
        let queued = handle_of(view).view.queued();
        assert!(
            queued <= 4 * (1 << 20) + RECORD,
            "{queued} bytes wait for the surface"
        );
        open.send(()).unwrap();
        for record in 0..COUNT {
            assert_eq!(
                decoder.next_feed(),
                Fed::Bytes(100 + (record * RECORD) as u64, pattern(record, RECORD))
            );
        }
        close_view(view);
        close(client);
    }

    #[test]
    fn a_reconnect_reopens_the_next_view_when_the_first_one_cannot_be_opened_again() {
        let (drop_first, dropped) = channel::<()>();
        let routes = client_script(move |socket, _| {
            welcomed(socket);
            let _ = dropped.recv_timeout(WAIT);
            let _ = socket.close(None);
            let _ = socket.flush();
        })
        .client(|socket, _| {
            welcomed(socket);
            wait_for_hangup(socket);
        })
        .view(|socket, _| {
            send_binary(socket, slice_record(10, true, true, true, b"a"));
            send_binary(socket, output_record(10, b"A"));
            wait_for_hangup(socket);
        })
        .view(|socket, _| {
            send_binary(socket, slice_record(10, true, true, true, b"b"));
            send_binary(socket, output_record(10, b"B"));
            wait_for_hangup(socket);
        })
        .refused_view()
        .view(|socket, _| {
            send_binary(socket, output_record(11, b"B2"));
            wait_for_hangup(socket);
        });
        let server = serve("two-views", routes);
        let fixture = Fixture::new();
        let client = fixture.connect(&server);
        assert!(matches!(fixture.next(), Seen::Welcome(..)));
        assert!(matches!(fixture.next(), Seen::Layout(0, ..)));
        let quick = || {
            Decoder::new(|snapshot| {
                pull(snapshot, usize::MAX, 64).unwrap();
                Restored::Ok
            })
        };
        let (first, second) = (quick(), quick());
        let a = open_view(client, first, true);
        assert_eq!(first.next_feed(), Fed::Bytes(10, b"A".to_vec()));
        assert_eq!(fixture.next(), Seen::Restored(1, Restored::Ok));
        let b = open_view(client, second, true);
        assert_eq!(second.next_feed(), Fed::Bytes(10, b"B".to_vec()));
        assert_eq!(fixture.next(), Seen::Restored(1, Restored::Ok));
        drop_first.send(()).unwrap();
        let seen: Vec<_> = (0..4).map(|_| fixture.next()).collect();
        assert!(matches!(seen[0], Seen::Failed(Code::Closed, _)), "{seen:?}");
        assert!(matches!(seen[1], Seen::Welcome(_, _, _, false)), "{seen:?}");
        assert!(matches!(seen[2], Seen::Layout(0, ..)), "{seen:?}");
        assert!(matches!(seen[3], Seen::Closed(Code::Io, _)), "{seen:?}");
        assert_eq!(second.next_feed(), Fed::Bytes(11, b"B2".to_vec()));
        let views: Vec<String> = server
            .targets("GET")
            .into_iter()
            .filter(|target| target.contains("/view"))
            .collect();
        assert!(
            views.len() == 4 && views[2].ends_with("offset=11") && views[3].ends_with("offset=11"),
            "{views:?}"
        );
        close_view(a);
        close_view(b);
        close(client);
    }

    #[test]
    fn model_events_coalesce_while_the_queue_is_busy_and_events_that_change_nothing_post_nothing() {
        let rows = serde_json::to_string(&[pane_row(1, None), pane_row(2, None)]).unwrap();
        let server = serve(
            "coalesce",
            client_script(|socket, _| {
                welcomed(socket);
                for title in ["a", "b"] {
                    send(
                        socket,
                        &format!(r#"{{"type":"title","pane":"pane_1","title":"{title}"}}"#),
                    );
                }
                send(socket, r#"{"type":"pwd","pane":"pane_1","pwd":"/x"}"#);
                send(socket, r#"{"type":"title","pane":"pane_9","title":"x"}"#);
                send(socket, &layout(7));
                wait_for_hangup(socket);
            })
            .plain(move |request| {
                Some((
                    200,
                    if request.target == "/panes" {
                        rows.clone()
                    } else {
                        "[]".to_owned()
                    },
                ))
            }),
        );
        let fixture = Fixture::new();
        // SAFETY: the queue is live; it resumes below.
        unsafe { dispatch_suspend(fixture.queue) };
        let client = fixture.connect(&server);
        until("the last event is applied", || {
            let mut buffer = empty_buffer();
            // SAFETY: the client is live and the buffer is writable.
            if unsafe { ko_client_model(client, &mut buffer) } != Code::Ok {
                return false;
            }
            let model: Value = serde_json::from_str(&contents(&buffer)).unwrap();
            freed_once(&mut buffer);
            model["layout"]["revision"] == json!(7) && model["panes"][0]["title"] == json!("b")
        });
        // SAFETY: the queue was suspended once above.
        unsafe { dispatch_resume(fixture.queue) };
        let seen = fixture.quiet();
        let models = seen.iter().filter(|seen| **seen == Seen::Model).count();
        assert_eq!(models, 1, "{seen:?}");
        close(client);
    }
}
