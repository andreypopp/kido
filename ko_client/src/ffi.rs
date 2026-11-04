#![allow(unsafe_code)]

mod calls;
mod config;
mod engine;
mod images;
mod remote;
mod view;

pub use calls::*;
pub use config::*;
pub use images::*;
pub use remote::*;

use std::cell::Cell;
use std::collections::VecDeque;
use std::ffi::{CStr, CString, c_char, c_int, c_void};
use std::num::NonZeroU16;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::thread::JoinHandle;

use ko_pane_wire::frame::{self, History, ServedBuf};
use ko_server::ids::{ClientId, PaneId, WindowId};
use ko_server::protocol::{
    self, ClientRequest, ClipboardContent, ClipboardLocation, Direction, ErrorKind, Hello, Input,
    Over, Selection, Switch, Text, Version,
};
use ko_sys::event::Wake;

use crate::launch::{self, PATIENCE};
use crate::model::{Model, Notice};
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
    NotFound = 7,
    Invalid = 8,
    Refused = 9,
    Gone = 10,
    Unknown = 11,
    ProtocolMismatch = 12,
    VtMismatch = 13,
}

impl Code {
    fn of(kind: &ErrorKind) -> Code {
        match kind {
            ErrorKind::Invalid => Code::Invalid,
            ErrorKind::Refused => Code::Refused,
            ErrorKind::Gone => Code::Gone,
            ErrorKind::Io => Code::Io,
            ErrorKind::PreconditionFailed => Code::Conflict,
            ErrorKind::Missing => Code::NotFound,
            ErrorKind::ProtocolMismatch(_) => Code::ProtocolMismatch,
            ErrorKind::VtMismatch(_) => Code::VtMismatch,
        }
    }
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
pub struct ClipboardItem {
    pub mime: *const c_char,
    pub data: *const u8,
    pub len: usize,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ClipboardWrite {
    pub pane: *const c_char,
    pub location: c_int,
    pub contents: *const ClipboardItem,
    pub count: usize,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ClipboardRead {
    pub pane: *const c_char,
    pub id: u64,
    pub location: c_int,
    pub mimes: *const *const c_char,
    pub count: usize,
    pub list: bool,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct VersionInfo {
    pub protocol: *const c_char,
    pub vt: *const c_char,
    pub build: *const c_char,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct Mismatch {
    pub code: Code,
    pub server: VersionInfo,
    pub own: VersionInfo,
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
const EVENT_MISMATCH: c_int = 9;
const EVENT_CLIPBOARD_WRITE: c_int = 10;
const EVENT_CLIPBOARD_READ: c_int = 11;

const LOCATION_STANDARD: c_int = 1;
const LOCATION_SELECTION: c_int = 2;
const LOCATION_PRIMARY: c_int = 3;

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
    pub mismatch: Mismatch,
    pub clipboard_write: ClipboardWrite,
    pub clipboard_read: ClipboardRead,
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
    pub name: *const c_char,
}

#[repr(C)]
#[derive(Debug)]
pub struct Buffer {
    pub data: *mut u8,
    pub len: usize,
    pub cap: usize,
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
    Mismatch(Code, Version),
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

fn location_number(location: ClipboardLocation) -> c_int {
    match location {
        ClipboardLocation::Standard => LOCATION_STANDARD,
        ClipboardLocation::Selection => LOCATION_SELECTION,
        ClipboardLocation::Primary => LOCATION_PRIMARY,
    }
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
                Notice::ClipboardWrite {
                    pane,
                    location,
                    contents,
                } => {
                    let pane = string(&pane.to_string());
                    let mimes: Vec<CString> =
                        contents.iter().map(|item| string(&item.mime)).collect();
                    let items: Vec<ClipboardItem> = contents
                        .iter()
                        .zip(&mimes)
                        .map(|(item, mime)| ClipboardItem {
                            mime: mime.as_ptr(),
                            data: item.data.0.as_ptr(),
                            len: item.data.0.len(),
                        })
                        .collect();
                    return call(Event {
                        kind: EVENT_CLIPBOARD_WRITE,
                        body: Body {
                            clipboard_write: ClipboardWrite {
                                pane: pane.as_ptr(),
                                location: location_number(*location),
                                contents: items.as_ptr(),
                                count: items.len(),
                            },
                        },
                    });
                }
                Notice::ClipboardRead {
                    pane,
                    id,
                    location,
                    mimes,
                    list,
                } => {
                    let pane = string(&pane.to_string());
                    let names: Vec<CString> = mimes.iter().map(|mime| string(mime)).collect();
                    let pointers: Vec<*const c_char> =
                        names.iter().map(|name| name.as_ptr()).collect();
                    return call(Event {
                        kind: EVENT_CLIPBOARD_READ,
                        body: Body {
                            clipboard_read: ClipboardRead {
                                pane: pane.as_ptr(),
                                id: *id,
                                location: location_number(*location),
                                mimes: pointers.as_ptr(),
                                count: pointers.len(),
                                list: *list,
                            },
                        },
                    });
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
        Posted::Mismatch(code, server) => {
            let (server, own) = (
                VersionTexts::of(server),
                VersionTexts::of(&protocol::version()),
            );
            call(Event {
                kind: EVENT_MISMATCH,
                body: Body {
                    mismatch: Mismatch {
                        code: *code,
                        server: server.info(),
                        own: own.info(),
                    },
                },
            });
        }
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

fn texts_of<'a>(pointers: *const *const c_char, count: usize) -> Option<Vec<&'a str>> {
    if pointers.is_null() {
        return Some(Vec::new());
    }
    // SAFETY: pointers points to count NUL-terminated strings by contract.
    let pointers = unsafe { std::slice::from_raw_parts(pointers, count) };
    pointers.iter().map(|pointer| text_of(*pointer)).collect()
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
        name: std::ptr::null(),
    });
    let (Some(cols), Some(rows)) = (frame::Dim::new(hello.cols), frame::Dim::new(hello.rows))
    else {
        return Code::Argument;
    };
    let name = if hello.name.is_null() {
        "app".to_owned()
    } else {
        let Some(name) = text_of(hello.name) else {
            return Code::Argument;
        };
        name.to_owned()
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
            name,
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
/// `out` is writable for one `ko_buffer`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_client_default_dir(out: *mut Buffer) -> Code {
    if out.is_null() {
        return Code::Argument;
    }
    match std::path::absolute(ko_server::config::dir(None)) {
        Ok(path) => {
            let Some(path) = path.to_str() else {
                hand_over(out, b"the server directory is not UTF-8".to_vec());
                return Code::Io;
            };
            hand_over(out, path.as_bytes().to_vec());
            Code::Ok
        }
        Err(error) => {
            hand_over(out, error.to_string().into_bytes());
            Code::Io
        }
    }
}

/// # Safety
///
/// `dir` and `executable` are NUL-terminated strings. `socket` is writable for
/// one `ko_buffer`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_client_launch(
    dir: *const c_char,
    executable: *const c_char,
    socket: *mut Buffer,
) -> Code {
    let (Some(dir), Some(executable)) = (text_of(dir), text_of(executable)) else {
        return Code::Argument;
    };
    if socket.is_null() {
        return Code::Argument;
    }
    match launch::attach(Path::new(dir), Path::new(executable), PATIENCE) {
        Ok((path, _stream)) => {
            hand_over(socket, path.as_os_str().as_bytes().to_vec());
            Code::Ok
        }
        Err(message) => {
            hand_over(socket, message.into_bytes());
            Code::Io
        }
    }
}

/// # Safety
///
/// `dir` is a NUL-terminated string. `error` is null or writable for one
/// `ko_buffer`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_client_stop_server(dir: *const c_char, error: *mut Buffer) -> Code {
    let Some(dir) = text_of(dir) else {
        return Code::Argument;
    };
    empty(error);
    match launch::stop(Path::new(dir), PATIENCE) {
        Ok(()) => Code::Ok,
        Err(message) => {
            hand_over(error, message.into_bytes());
            Code::Io
        }
    }
}

struct VersionTexts {
    protocol: CString,
    vt: CString,
    build: CString,
}

impl VersionTexts {
    fn of(version: &Version) -> VersionTexts {
        VersionTexts {
            protocol: string(&version.protocol),
            vt: string(&version.vt),
            build: string(&version.build),
        }
    }

    // Valid while `self` lives.
    fn info(&self) -> VersionInfo {
        VersionInfo {
            protocol: self.protocol.as_ptr(),
            vt: self.vt.as_ptr(),
            build: self.build.as_ptr(),
        }
    }
}

/// # Safety
///
/// `out` is null or writable for one `ko_version`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_client_version(out: *mut VersionInfo) -> Code {
    static OWN: std::sync::OnceLock<VersionTexts> = std::sync::OnceLock::new();
    if out.is_null() {
        return Code::Argument;
    }
    let own = OWN.get_or_init(|| VersionTexts::of(&protocol::version()));
    // SAFETY: out is non-null and writable by contract.
    unsafe { *out = own.info() };
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
    match serde_json::to_vec(&model.json()) {
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
    if let Some(pane) = selection.pane {
        let known = match locked(&client.shared.model).as_ref() {
            Some(model) => model.layout.layout.locate(pane).is_some(),
            None => return Code::Closed,
        };
        if !known {
            return Code::NotFound;
        }
    }
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
pub unsafe extern "C" fn ko_client_size(
    client_: *const Client,
    cols: u16,
    rows: u16,
    cell_width: u16,
    cell_height: u16,
) -> Code {
    let (Some(client), Some(cols), Some(rows)) = (
        client(client_),
        frame::Dim::new(cols),
        frame::Dim::new(rows),
    ) else {
        return Code::Argument;
    };
    let cell_px = match (NonZeroU16::new(cell_width), NonZeroU16::new(cell_height)) {
        (Some(width), Some(height)) => Some(frame::CellPx { width, height }),
        (None, None) => None,
        _ => return Code::Argument,
    };
    let size = frame::Size {
        cols,
        rows,
        cell_px,
    };
    locked(&client.shared.hello).size = protocol::Size(size);
    request(client, ClientRequest::Size(protocol::Size(size)))
}

/// # Safety
///
/// `client` is a live handle. `contents` is null, or points to `count` items
/// whose strings are NUL-terminated and whose data is readable for `len` bytes.
/// `available` is null, or points to `available_count` NUL-terminated strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_client_clipboard_answer(
    client_: *const Client,
    id: u64,
    contents: *const ClipboardItem,
    count: usize,
    available: *const *const c_char,
    available_count: usize,
) -> Code {
    let Some(client) = client(client_) else {
        return Code::Argument;
    };
    let served = if contents.is_null() {
        None
    } else {
        let items = if count == 0 {
            &[]
        } else {
            // SAFETY: contents points to count items by contract.
            unsafe { std::slice::from_raw_parts(contents, count) }
        };
        let (Some(items), Some(available)) = (
            items
                .iter()
                .map(|item| {
                    Some(ClipboardContent {
                        mime: text_of(item.mime)?.to_owned(),
                        data: Text(bytes_of(item.data, item.len)?.to_vec()),
                    })
                })
                .collect::<Option<Vec<_>>>(),
            texts_of(available, available_count),
        ) else {
            return Code::Argument;
        };
        let fits = ServedBuf::new(
            items
                .iter()
                .map(|item| (item.mime.as_bytes(), item.data.0.as_slice())),
            available.iter().map(|name| name.as_bytes()),
        )
        .is_ok();
        fits.then(|| protocol::ClipboardServed {
            contents: items,
            available: available.into_iter().map(str::to_owned).collect(),
        })
    };
    request(client, ClientRequest::ClipboardAnswer { id, served })
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct Limits {
    pub kitty_images_max_bytes: u64,
}

/// # Safety
///
/// `client` is a live handle. `out` is writable for one `ko_limits`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_client_limits(client_: *const Client, out: *mut Limits) -> Code {
    let Some(client) = client(client_).filter(|_| !out.is_null()) else {
        return Code::Argument;
    };
    let Some(kitty_images_max_bytes) = locked(&client.shared.model)
        .as_ref()
        .map(|model| model.limits.kitty_images_max_bytes)
    else {
        return Code::Closed;
    };
    // SAFETY: out is non-null and writable by contract.
    unsafe {
        *out = Limits {
            kitty_images_max_bytes,
        }
    };
    Code::Ok
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
    let ids: Option<Vec<PaneId>> = texts_of(panes, count)
        .and_then(|names| names.iter().map(|name| name.parse().ok()).collect());
    let Some(ids) = ids else {
        return Code::Argument;
    };
    let changed = match locked(&client.shared.model).as_mut() {
        Some(model) => model.observe(&ids, attending),
        None => return Code::Closed,
    };
    if changed && !client.shared.model_pending.swap(true, Ordering::SeqCst) {
        post(&client.shared, Posted::Model);
    }
    Code::Ok
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

/// # Safety
///
/// `view` is a live handle. `data` is null with `len` 0, or readable for `len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_view_input(
    view: *const ViewHandle,
    data: *const u8,
    len: usize,
) -> Code {
    // SAFETY: view is null or valid by contract.
    let (Some(handle), Some(data)) = (unsafe { view.as_ref() }, bytes_of(data, len)) else {
        return Code::Argument;
    };
    if !handle.view.up.load(Ordering::SeqCst) {
        return Code::Closed;
    }
    handle.shared.command(Command::Input(
        handle.view.id,
        Input::Text {
            data: Text(data.to_vec()),
        },
    ));
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
        c if c == Code::NotFound as c_int => c"not found",
        c if c == Code::Invalid as c_int => c"the server refused the request as invalid",
        c if c == Code::Refused as c_int => c"the server refused the request",
        c if c == Code::Gone as c_int => c"the target is gone",
        c if c == Code::Unknown as c_int => c"the server answered with an unknown error",
        c if c == Code::ProtocolMismatch as c_int => c"the server speaks another protocol major",
        c if c == Code::VtMismatch as c_int => c"the server has another terminal revision",
        _ => c"unknown code",
    };
    message.as_ptr()
}

#[cfg(test)]
mod tests {
    use std::io::{Read, Write};
    use std::os::unix::net::{UnixListener, UnixStream};
    use std::sync::atomic::AtomicPtr;
    use std::sync::mpsc::{Receiver, Sender, channel};
    use std::thread::ThreadId;
    use std::time::{Duration, Instant};

    use ko_server::protocol::{
        CommandExit, Listing, Live, PaneStatus, Phase, ProgramStatus, Row, Shell,
    };
    use serde_json::{Value, json};
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
            r#"{{"type":"welcome","client":"client_7","limits":{{"terminal":{{"scrollback":{{"type":"disabled"}},"apc_max_bytes":1,"kitty_images_max_bytes":1,"continuation_max_bytes":{continuation}}},"media":[]}},"instance":"{instance}","now":42,"runtimes":[]}}"#
        )
    }

    fn layout(revision: u64) -> String {
        layout_with(revision, &[])
    }

    fn layout_with(revision: u64, rows: &[Listing]) -> String {
        let panes = serde_json::to_string(rows).unwrap();
        format!(
            r#"{{"type":"layout","revision":{revision},"layout":{{"sessions":[{{"id":"session_1","name":"s","vars":{{}},"windows":[{{"id":"window_1","name":"w","vars":{{}},"cols":80,"rows":24,"focus":"pane_1","tree":{{"split":"h","children":[{{"pane":"pane_1","cols":40,"rows":24}},{{"pane":"pane_2","cols":39,"rows":24}}]}},"floats":[]}}]}}]}},"panes":{panes}}}"#
        )
    }

    #[derive(Debug, PartialEq, Eq)]
    enum Seen {
        Welcome(String, String, u64, bool),
        Layout(u64, u32, u32, u32),
        Model,
        Selected(Option<String>, Option<String>, Option<String>),
        Alert(c_int, String, Option<String>, Option<String>),
        ClipboardWrite(String, c_int, Vec<(String, Vec<u8>)>),
        ClipboardRead(String, u64, c_int, Vec<String>, bool),
        Failed(Code, String),
        Mismatch(Code, String, String),
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
                EVENT_MISMATCH => {
                    let mismatch = event.body.mismatch;
                    Seen::Mismatch(
                        mismatch.code,
                        owned(mismatch.server.build),
                        owned(mismatch.own.build),
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
                EVENT_CLIPBOARD_WRITE => {
                    let write = event.body.clipboard_write;
                    Seen::ClipboardWrite(
                        owned(write.pane),
                        write.location,
                        std::slice::from_raw_parts(write.contents, write.count)
                            .iter()
                            .map(|item| {
                                (
                                    owned(item.mime),
                                    std::slice::from_raw_parts(item.data, item.len).to_vec(),
                                )
                            })
                            .collect(),
                    )
                }
                EVENT_CLIPBOARD_READ => {
                    let read = event.body.clipboard_read;
                    Seen::ClipboardRead(
                        owned(read.pane),
                        read.id,
                        read.location,
                        std::slice::from_raw_parts(read.mimes, read.count)
                            .iter()
                            .map(|mime| owned(*mime))
                            .collect(),
                        read.list,
                    )
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

        fn heads(&self, method: &str, target: &str) -> Vec<String> {
            locked(&self.requests)
                .iter()
                .filter(|request| request.method == method && request.target == target)
                .map(|request| request.head.clone())
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
                Some((0, _)) => {}
                Some((200, body))
                    if request.target.contains("/images/")
                        && header(&head, "Ko-Accept-Shm").is_none() =>
                {
                    let generation = request.target.split("generation=").nth(1).unwrap_or("0");
                    let _ = write!(
                        stream,
                        "HTTP/1.1 200 Reply\r\nContent-Type: application/octet-stream\r\nko-image-format: rgba\r\nko-image-width: 2\r\nko-image-height: 1\r\nko-image-generation: {generation}\r\nko-image-gap-ms: 40\r\nko-image-frames: 3\r\nContent-Length: {}\r\n\r\n{body}",
                        body.len()
                    );
                }
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
        let header = ko_pane_wire::ring::Slice {
            first,
            last,
            screen: !full,
        }
        .encode();
        [
            &[2][..],
            &offset.to_le_bytes(),
            &header,
            &miniz_oxide::deflate::compress_to_vec(body, 1),
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

    fn freed_once_if_any(buffer: &mut Buffer) {
        if !buffer.data.is_null() {
            freed_once(buffer);
        }
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
                "type": "hello", "name": "app", "focused": false,
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
    fn a_close_cancels_a_join_that_waits_for_the_welcome_and_ends_the_worker() {
        let (accepting, accepted) = channel();
        let (hung_up, hangup) = channel();
        let routes = client_script(move |socket, _| {
            let _ = accepting.send(());
            wait_for_hangup(socket);
            let _ = hung_up.send(());
        });
        let server = serve("stalled", routes);
        let fixture = Fixture::new();
        let client = fixture.connect(&server);
        accepted.recv_timeout(WAIT).unwrap();
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
    fn an_outage_reports_its_first_failure_and_a_later_missing_server_once() {
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
        drop(hangs_up);
        assert!(matches!(fixture.next(), Seen::Failed(Code::NoServer, _)));
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
        // SAFETY: the handle is live and the input's pointer is valid for the call.
        let code = unsafe { ko_view_input(view, b"x".as_ptr(), 1) };
        assert_eq!(code, Code::Closed);
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
            pid: Some(100),
            command: vec!["/bin/sh".to_owned()],
            cwd: "/".to_owned(),
            title: String::new(),
            dead: None,
            foreground: None,
            status,
            progress: None,
            run: None,
            parent: None,
            close: Default::default(),
            inbox: false,
            runtime: None,
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
        let rows = [pane_row(1, Some(failed_idle_status())), pane_row(2, None)];
        let server = serve(
            "model",
            client_script(move |socket, _| {
                send(socket, &welcome(INSTANCE, 1));
                send(socket, &layout_with(0, &rows));
                wait_for_hangup(socket);
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
                {"type": "pane", "id": "pane_1", "window": "window_1", "depth": 0},
                {"type": "pane", "id": "pane_2", "window": "window_1", "depth": 0},
            ])
        );
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
        assert!(fixture.quiet().is_empty(), "no mark changed");
        assert_eq!(observe(&[c"pane_1", c"pane_2"], true), Code::Ok);
        assert_eq!(
            fixture.quiet(),
            [Seen::Model],
            "a changed mark is a model event"
        );
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
                name: c"window_7".as_ptr(),
            }),
        );
        let hello: Value = serde_json::from_str(&hellos.recv_timeout(WAIT).unwrap()).unwrap();
        assert_eq!(
            (
                &hello["type"],
                &hello["name"],
                &hello["focused"],
                &hello["ignore_size"],
                &hello["size"]
            ),
            (
                &json!("hello"),
                &json!("window_7"),
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
            assert_eq!(ko_client_size(client, 100, 30, 9, 18), Code::Ok);
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
            assert_eq!(ko_client_size(client, 0, 30, 0, 0), Code::Argument);
            assert_eq!(ko_client_size(client, 100, 30, 9, 0), Code::Argument);
            assert_eq!(
                ko_client_select(client, SELECT_PANE, c"pane_9".as_ptr()),
                Code::NotFound
            );
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
                r#"{"type":"size","cols":100,"rows":30,"cell_px":{"width":9,"height":18}}"#,
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
                json!({"cols": 100, "rows": 30, "cell_px": {"width": 9, "height": 18}})
            )
        );
        close(client);
    }

    fn snapshot_json(revision: u64) -> String {
        format!(r#"{{"revision":{revision},"layout":{{"sessions":[]}}}}"#)
    }

    #[test]
    fn an_edit_is_applied_in_the_core_and_applied_again_to_the_newer_document_after_a_conflict() {
        let newer = r#"{"revision":5,"layout":{"sessions":[{"id":"session_1","name":"s","vars":{},"windows":[{"id":"window_1","name":"w","vars":{},"cols":80,"rows":24,"focus":"pane_1","tree":{"split":"h","children":[{"pane":"pane_1","cols":40,"rows":24},{"pane":"pane_2","cols":39,"rows":24}]},"floats":[]},{"id":"window_7","name":"added","vars":{},"cols":80,"rows":24,"focus":"pane_8","tree":{"pane":"pane_8","cols":80,"rows":24},"floats":[]}]}]}}"#;
        let server = serve(
            "edit",
            client_script(|socket, _| {
                welcomed(socket);
                wait_for_hangup(socket);
            })
            .plain(move |request| {
                if request.method != "PUT" {
                    return answer_empty(request);
                }
                let body = String::from_utf8_lossy(&request.body).into_owned();
                if body.contains(r#""name":"boom""#) {
                    Some((400, r#"{"kind":"invalid","message":"no"}"#.to_owned()))
                } else if body.starts_with(r#"{"revision":5,"#) {
                    Some((200, snapshot_json(6)))
                } else {
                    Some((409, newer.to_owned()))
                }
            }),
        );
        let fixture = Fixture::new();
        let client = fixture.connect(&server);
        assert!(matches!(fixture.next(), Seen::Welcome(..)));
        assert!(matches!(fixture.next(), Seen::Layout(0, ..)));
        let edit = |text: &str| {
            let mut out = empty_buffer();
            // SAFETY: the client is live, the edit is readable and out is writable.
            let code = unsafe { ko_client_edit(client, text.as_ptr(), text.len(), &mut out) };
            (code, out)
        };

        let (code, mut out) =
            edit(r#"{"type":"rename_window","window":"window_1","name":"edited"}"#);
        assert_eq!(code, Code::Ok);
        assert_eq!(
            serde_json::from_str::<Value>(&contents(&out)).unwrap(),
            json!({"snapshot": {"revision": 6, "layout": {"sessions": []}}})
        );
        freed_once(&mut out);
        let bodies = server.bodies("PUT", "/layout");
        assert_eq!(bodies.len(), 2, "one conflict, one converged put");
        assert!(bodies[0].starts_with(r#"{"revision":0,"#) && !bodies[0].contains("added"));
        assert!(bodies[1].starts_with(r#"{"revision":5,"#) && bodies[1].contains("added"));
        assert!(
            bodies
                .iter()
                .all(|body| body.contains(r#""name":"edited""#))
        );

        let (code, mut out) = edit(r#"{"type":"rename_window","window":"window_9","name":"x"}"#);
        assert_eq!(
            (code, contents(&out).as_str()),
            (Code::NotFound, "window_9")
        );
        freed_once(&mut out);
        let (code, mut out) =
            edit(r#"{"type":"dock","pane":"pane_1","target":"pane_1","edge":"left"}"#);
        assert_eq!(code, Code::Invalid);
        freed_once(&mut out);
        let (code, mut out) = edit(r#"{"type":"rename_window","window":"window_1","name":"boom"}"#);
        assert_eq!((code, contents(&out).as_str()), (Code::Invalid, "no"));
        freed_once(&mut out);
        let (code, _) = edit(r#"{"type":"nonsense"}"#);
        assert_eq!(code, Code::Argument);
        assert_eq!(
            server.bodies("PUT", "/layout").len(),
            3,
            "only the boom edit was sent"
        );
        close(client);
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
        assert_eq!((code, contents(&out).as_str()), (Code::Invalid, "no"));
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
        let server = serve(
            "runs",
            client_script(|socket, _| {
                welcomed(socket);
                wait_for_hangup(socket);
            })
            .plain(move |request| match request.target.as_str() {
                "/prompt" if request.body.windows(5).any(|window| window == b"boom!") => Some((
                    500,
                    r#"{"kind":"io","message":"the paste was not written"}"#.to_owned(),
                )),
                "/prompt" if request.body.windows(5).any(|window| window == b"lost!") => {
                    Some((0, String::new()))
                }
                "/prompt" if request.body.windows(5).any(|window| window == b"nope!") => Some((
                    409,
                    r#"{"kind":"refused","message":"the agent is busy"}"#.to_owned(),
                )),
                "/prompt" if request.body.windows(5).any(|window| window == b"nada!") => Some((
                    400,
                    r#"{"kind":"invalid","message":"pane_3 is not a candidate"}"#.to_owned(),
                )),
                "/prompt" => Some((200, r#"{"via":"paste"}"#.to_owned())),
                target if target.starts_with("/prompt/resolve") => {
                    Some((200, format!(r#"[{{"asked":"{target}"}}]"#)))
                }
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
                ko_client_prompt(
                    client,
                    c"pane_1".as_ptr(),
                    target.as_ptr(),
                    text.as_ptr(),
                    text.len(),
                    &mut out,
                )
            };
            (code, out)
        };
        for (window_only, expected) in [
            (false, "/prompt/resolve?from=pane_1"),
            (true, "/prompt/resolve?from=pane_1&window=true"),
        ] {
            let mut out = empty_buffer();
            // SAFETY: the client is live, the caller is NUL-terminated and out is writable.
            let code = unsafe {
                ko_client_prompt_resolve(client, c"pane_1".as_ptr(), window_only, &mut out)
            };
            assert_eq!(
                (code, contents(&out)),
                (Code::Ok, format!(r#"[{{"asked":"{expected}"}}]"#))
            );
            freed_once(&mut out);
        }
        // SAFETY: the client is live; the caller is no pane id.
        let code = unsafe {
            ko_client_prompt_resolve(client, c"window_1".as_ptr(), false, &mut empty_buffer())
        };
        assert_eq!(code, Code::Argument);
        let (code, mut out) = prompt(c"pane_3", "hi\nthere \u{e9}".as_bytes());
        assert_eq!(
            (code, contents(&out).as_str()),
            (Code::Ok, r#"{"via":"paste"}"#)
        );
        freed_once(&mut out);
        let bodies = server.bodies("POST", "/prompt");
        let sent: serde_json::Value = serde_json::from_str(&bodies[0]).unwrap();
        assert_eq!(
            (
                sent["from"].as_str(),
                sent["target"].as_str(),
                sent["text"].as_str(),
                sent["id"].as_str().map(str::len)
            ),
            (
                Some("pane_1"),
                Some("pane_3"),
                Some("hi\nthere é"),
                Some(22)
            )
        );
        let heads: Vec<String> = server
            .heads("POST", "/prompt")
            .into_iter()
            .chain(server.heads("GET", "/prompt/resolve?from=pane_1"))
            .chain(server.heads("GET", "/prompt/resolve?from=pane_1&window=true"))
            .collect();
        assert!(heads.len() >= 3);
        assert!(
            heads.iter().all(|head| !head.contains("Ko-Pane")),
            "the prompt routes name their pane in the request, not as an identity"
        );
        let (code, mut out) = prompt(c"pane_3", b"boom!");
        assert_eq!(
            (code, contents(&out).as_str()),
            (Code::Unknown, "the paste was not written"),
            "a send that failed partway may have reached the agent"
        );
        freed_once(&mut out);
        let (code, mut out) = prompt(c"pane_3", b"lost!");
        assert_eq!(
            code,
            Code::Unknown,
            "a send with no answer may have reached the agent"
        );
        freed_once(&mut out);
        for (text, expected, message) in [
            (&b"nope!"[..], Code::Refused, "the agent is busy"),
            (&b"nada!"[..], Code::Invalid, "pane_3 is not a candidate"),
        ] {
            let (code, mut out) = prompt(c"pane_3", text);
            assert_eq!((code, contents(&out).as_str()), (expected, message));
            freed_once(&mut out);
        }
        assert_eq!(prompt(c"pane_3", &[0xff, 0xfe]).0, Code::Argument);
        assert_eq!(prompt(c"nonsense", b"x").0, Code::Argument);
        // SAFETY: the client is live; the show value is refused.
        let code = unsafe { ko_client_runs(client, 4, &mut empty_buffer()) };
        assert_eq!(code, Code::Argument);
        for (kind, id, expected) in [
            (1, c"pane_4", Code::Ok),
            (2, c"window_2", Code::Ok),
            (3, c"session_9", Code::Ok),
            (1, c"window_2", Code::Argument),
            (4, c"pane_4", Code::Argument),
        ] {
            let mut out = empty_buffer();
            // SAFETY: the client is live, the string is valid and out is writable.
            let code = unsafe { ko_client_delete(client, kind, id.as_ptr(), &mut out) };
            assert_eq!(code, expected);
            if expected == Code::Ok {
                freed_once(&mut out);
            }
        }
        assert_eq!(
            server.targets("DELETE"),
            ["/panes/pane_4", "/windows/window_2", "/sessions/session_9"]
        );
        close(client);
    }

    #[test]
    fn another_protocol_or_terminal_revision_reports_one_mismatch_and_no_retry() {
        let ours = protocol::version();
        let versions = [
            (
                Code::ProtocolMismatch,
                format!("2.0\",\"vt\":\"{}", ours.vt),
            ),
            (
                Code::VtMismatch,
                format!("{}\",\"vt\":\"abc", ours.protocol),
            ),
        ];
        for (code, protocol_and_vt) in versions {
            let body = format!(r#"{{"protocol":"{protocol_and_vt}","build":"theirs"}}"#);
            let server = serve(
                "version-mismatch",
                Routes {
                    clients: Vec::new(),
                    views: Vec::new(),
                    plain: Arc::new(move |request| match request.target.as_str() {
                        "/version" => Some((200, body.clone())),
                        _ => Some((426, String::new())),
                    }),
                    stall: None,
                },
            );
            let fixture = Fixture::new();
            let client = fixture.connect(&server);
            assert_eq!(
                fixture.next(),
                Seen::Mismatch(code, "theirs".to_owned(), ours.build.clone())
            );
            assert_eq!(fixture.quiet_for(Duration::from_millis(500)), []);
            assert_eq!(
                server
                    .targets("GET")
                    .iter()
                    .filter(|target| *target == "/version")
                    .count(),
                1
            );
            let mut out = empty_buffer();
            // SAFETY: the client is live and out is writable.
            assert_eq!(unsafe { ko_client_model(client, &mut out) }, Code::Closed);
            close(client);
        }
    }

    #[test]
    fn the_core_launches_stops_and_names_its_version() {
        let dir = PathBuf::from(format!("/tmp/ko-ffi-launch-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let c_dir = CString::new(dir.as_os_str().as_bytes()).unwrap();
        let mut socket = empty_buffer();
        // SAFETY: the strings are valid and socket is writable.
        let code =
            unsafe { ko_client_launch(c_dir.as_ptr(), c"/nonexistent/ko".as_ptr(), &mut socket) };
        assert_eq!(code, Code::Io, "no executable, no server");
        assert!(!contents(&socket).is_empty());
        freed_once(&mut socket);

        let listener = UnixListener::bind(dir.join("socket")).unwrap();
        // SAFETY: as above.
        let code =
            unsafe { ko_client_launch(c_dir.as_ptr(), c"/nonexistent/ko".as_ptr(), &mut socket) };
        assert_eq!(
            (code, contents(&socket)),
            (Code::Ok, dir.join("socket").display().to_string()),
            "a live server is reused"
        );
        freed_once(&mut socket);
        drop(listener);
        let _ = std::fs::remove_dir_all(&dir);

        let mut error = empty_buffer();
        // SAFETY: the string is valid and error is writable.
        let code = unsafe { ko_client_stop_server(c_dir.as_ptr(), &mut error) };
        assert_eq!(code, Code::Io, "no directory, no server");
        assert!(!contents(&error).is_empty());
        freed_once(&mut error);

        let mut version = VersionInfo {
            protocol: std::ptr::null(),
            vt: std::ptr::null(),
            build: std::ptr::null(),
        };
        // SAFETY: version is writable.
        assert_eq!(unsafe { ko_client_version(&mut version) }, Code::Ok);
        let ours = protocol::version();
        assert_eq!(
            (
                owned(version.protocol),
                owned(version.vt),
                owned(version.build)
            ),
            (ours.protocol, ours.vt, ours.build)
        );
    }

    #[test]
    fn a_probe_reports_the_servers_version_and_how_a_forward_leads_nowhere() {
        let ours = protocol::version();
        let answering = |name: &str, body: String| {
            serve(
                name,
                Routes {
                    clients: Vec::new(),
                    views: Vec::new(),
                    plain: Arc::new(move |request| match request.target.as_str() {
                        "/version" => Some((200, body.clone())),
                        _ => Some((404, String::new())),
                    }),
                    stall: None,
                },
            )
        };
        let probe = |socket: Vec<u8>| {
            let socket = CString::new(socket).unwrap();
            let mut out = empty_buffer();
            // SAFETY: the string is valid and out is writable.
            let code = unsafe { ko_client_probe(socket.as_ptr(), 5_000, &mut out) };
            let text = contents(&out);
            freed_once(&mut out);
            (code, text)
        };
        let theirs = [
            (
                Code::Ok,
                format!(
                    r#"{{"protocol":"{}","vt":"{}","build":"b"}}"#,
                    ours.protocol, ours.vt
                ),
            ),
            (
                Code::ProtocolMismatch,
                format!(r#"{{"protocol":"2.0","vt":"{}","build":"b"}}"#, ours.vt),
            ),
            (
                Code::VtMismatch,
                format!(
                    r#"{{"protocol":"{}","vt":"abc","build":"b"}}"#,
                    ours.protocol
                ),
            ),
        ];
        for (code, body) in theirs {
            let server = answering("probe", body.clone());
            assert_eq!(probe(server.socket()), (code, body));
        }

        let server = answering("probe-garbage", "not a version".to_owned());
        assert_eq!(probe(server.socket()).0, Code::Protocol);

        let dir = PathBuf::from(format!("/tmp/ko-ffi-probe-none-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("socket").as_os_str().as_bytes().to_vec();
        assert_eq!(probe(socket.clone()).0, Code::NoServer, "no socket file");

        let listener = UnixListener::bind(dir.join("socket")).unwrap();
        let hangup = std::thread::spawn(move || drop(listener.accept()));
        assert_eq!(
            probe(socket).0,
            Code::Closed,
            "a listener that closes at once"
        );
        hangup.join().unwrap();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_remote_classifiers_name_each_failure_of_the_ssh_steps() {
        let classify = |status: c_int, signaled: bool, stdout: &[u8], stderr: &[u8]| {
            let run = SshRun {
                status,
                signaled,
                stdout_data: stdout.as_ptr(),
                stdout_len: stdout.len(),
                stderr_data: stderr.as_ptr(),
                stderr_len: stderr.len(),
            };
            let mut out = empty_buffer();
            // SAFETY: the string and the run are valid and out is writable.
            let code = unsafe { ko_remote_socket(c"box".as_ptr(), &run, &mut out) };
            let text = contents(&out);
            freed_once(&mut out);
            (code, text)
        };
        assert_eq!(
            classify(0, false, b"/home/u/.local/state/ko/socket\n", b""),
            (Code::Ok, "/home/u/.local/state/ko/socket".to_owned())
        );
        assert_eq!(
            classify(0, false, b"welcome!\n", b"").0,
            Code::Invalid,
            "a shell that prints on start"
        );
        assert_eq!(
            classify(127, false, b"", b"sh: ko: not found"),
            (
                Code::NotFound,
                "ko was not found on box; install it there, on the PATH of ssh commands".to_owned()
            )
        );
        assert_eq!(
            classify(255, false, b"", b"Permission denied\n"),
            (Code::Io, "Permission denied".to_owned())
        );
        assert_eq!(classify(1, false, b"", b"boom").0, Code::Invalid);
        assert_eq!(classify(9, true, b"", b"").0, Code::Invalid);

        let unreachable = |answers: bool| {
            let mut out = empty_buffer();
            // SAFETY: the string is valid and out is writable.
            let code = unsafe { ko_remote_unreachable(c"box".as_ptr(), answers, &mut out) };
            let text = contents(&out);
            freed_once(&mut out);
            (code, text)
        };
        assert_eq!(
            unreachable(true),
            (
                Code::Refused,
                "box refuses unix-socket forwarding, and ko needs it (sshd AllowStreamLocalForwarding)".to_owned()
            )
        );
        assert_eq!(
            unreachable(false),
            (
                Code::NoServer,
                "no ko server is running on box; start one there with: ssh box ko server"
                    .to_owned()
            )
        );
    }

    fn config_dir(name: &str) -> PathBuf {
        let dir = PathBuf::from(format!("/tmp/ko-ffi-config-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn c_string(path: &Path) -> CString {
        CString::new(path.as_os_str().as_bytes()).unwrap()
    }

    fn load(path: &Path) -> (Code, Value) {
        let mut out = empty_buffer();
        // SAFETY: the string is valid and out is writable.
        let code = unsafe { ko_config_load(c_string(path).as_ptr(), &mut out) };
        let value = serde_json::from_str(&contents(&out)).unwrap();
        freed_once(&mut out);
        (code, value)
    }

    fn set_theme(path: &Path, light: &CStr, dark: &CStr) -> (Code, Value) {
        let mut out = empty_buffer();
        // SAFETY: the strings are valid and out is writable.
        let code = unsafe {
            ko_config_set_theme(
                c_string(path).as_ptr(),
                light.as_ptr(),
                dark.as_ptr(),
                &mut out,
            )
        };
        let value = serde_json::from_str(&contents(&out)).unwrap();
        freed_once(&mut out);
        (code, value)
    }

    #[test]
    fn config_defaults_returns_the_path_and_config_without_reading_a_file() {
        let mut out = empty_buffer();
        // SAFETY: out is writable; a null out is tested as a refused argument.
        unsafe {
            assert_eq!(ko_config_defaults(&mut out), Code::Ok);
            assert_eq!(ko_config_defaults(std::ptr::null_mut()), Code::Argument);
        }
        let value: Value = serde_json::from_str(&contents(&out)).unwrap();
        assert!(Path::new(value["path"].as_str().unwrap()).ends_with("ko/config.yaml"));
        assert_eq!(
            value["config"],
            serde_json::to_value(ko_config::config::Config::default()).unwrap()
        );
        freed_once(&mut out);
    }

    #[test]
    fn a_config_load_gives_the_decoded_file_with_defaults_or_the_error_with_its_place() {
        let dir = config_dir("load");
        let file = dir.join("config.yaml");

        let (code, value) = load(&file);
        assert_eq!(code, Code::Ok);
        assert_eq!(value["config"]["app"]["font"]["size"], json!(13.0));
        assert_eq!(
            value["config"]["app"]["theme"],
            json!({"light": "kido-light", "dark": "kido-dark"})
        );
        assert_eq!(value["config"]["server"]["linger_seconds"], json!(30.0));
        assert_eq!(value["config"]["runtimes"], json!({}));

        std::fs::write(
            &file,
            "app:\n  font: {size: 16, family: Menlo}\nserver: {runtime_idle_seconds: none}\n",
        )
        .unwrap();
        let (code, value) = load(&file);
        assert_eq!(code, Code::Ok);
        assert_eq!(
            value["config"]["app"]["font"],
            json!({"family": "Menlo", "size": 16.0, "features": [], "thicken": false, "line_height": 0.0})
        );
        assert_eq!(
            value["config"]["server"]["runtime_idle_seconds"],
            json!("none")
        );

        std::fs::write(&file, "app:\n  font: {size: 3}\n").unwrap();
        let (code, value) = load(&file);
        assert_eq!(code, Code::Invalid);
        assert_eq!(
            value,
            json!({"error": {"line": 2, "column": 16, "message": "app: font: size: 3 is not at least 4 and at most 72"}})
        );

        std::fs::remove_file(&file).unwrap();
        std::fs::create_dir(&file).unwrap();
        let (code, value) = load(&file);
        assert_eq!(code, Code::Io);
        assert!(
            value["error"]["message"]
                .as_str()
                .is_some_and(|text| text.starts_with(file.to_str().unwrap()))
                && value["error"]
                    .as_object()
                    .is_some_and(|error| error.len() == 1),
            "{value}"
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_config_set_theme_writes_the_pair_or_says_why_not() {
        let dir = config_dir("theme");
        let file = dir.join("ko/config.yaml");
        let (code, value) = set_theme(&file, c"A", c"B");
        assert_eq!((code, value), (Code::Ok, json!({"written": true})));
        assert_eq!(
            std::fs::read_to_string(&file).unwrap(),
            "app:\n  theme:\n    light: \"A\"\n    dark: \"B\"\n"
        );
        assert_eq!(
            set_theme(&file, c"A", c"B"),
            (Code::Ok, json!({"written": false}))
        );
        assert_eq!(
            load(&file).1["config"]["app"]["theme"],
            json!({"light": "A", "dark": "B"})
        );

        let (code, value) = set_theme(&file, c"a/b", c"B");
        assert_eq!(code, Code::Argument);
        assert!(
            value["error"]["message"]
                .as_str()
                .is_some_and(|text| text.starts_with("\"a/b\" is not a theme name")),
            "{value}"
        );

        std::fs::write(&file, "app: {theme: x}\n").unwrap();
        let (code, value) = set_theme(&file, c"A", c"B");
        assert_eq!(code, Code::Invalid);
        assert_eq!(value["error"]["message"], json!("duplicate key \"app\""));
        assert_eq!(std::fs::read_to_string(&file).unwrap(), "app: {theme: x}\n");

        std::fs::write(&file, "app: [\n").unwrap();
        assert_eq!(set_theme(&file, c"A", c"B").0, Code::Invalid);

        std::fs::write(&file, "# mine\n").unwrap();
        std::fs::set_permissions(&file, std::os::unix::fs::PermissionsExt::from_mode(0o444))
            .unwrap();
        let (code, value) = set_theme(&file, c"A", c"B");
        assert_eq!(code, Code::Io);
        assert_eq!(value, json!({"error": {"message": "permission denied"}}));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn config_calls_refuse_a_bad_argument_and_empty_the_out_buffer() {
        let bad = CString::new(vec![0xff]).unwrap();
        let sentinel = || Buffer {
            data: std::ptr::dangling_mut(),
            len: 3,
            cap: 3,
        };
        let emptied = |out: &Buffer| out.data.is_null() && (out.len, out.cap) == (0, 0);
        let mut out = sentinel();
        // SAFETY: each argument is null, not UTF-8 or valid; the calls reject the first two.
        unsafe {
            assert_eq!(ko_config_load(bad.as_ptr(), &mut out), Code::Argument);
            assert!(emptied(&out));
            out = sentinel();
            assert_eq!(ko_config_load(std::ptr::null(), &mut out), Code::Argument);
            assert!(emptied(&out));
            out = sentinel();
            assert_eq!(
                ko_config_load(c"/x".as_ptr(), std::ptr::null_mut()),
                Code::Argument
            );
            let set = |light: *const c_char, out: &mut Buffer| {
                ko_config_set_theme(c"/x".as_ptr(), light, c"B".as_ptr(), out)
            };
            assert_eq!(set(bad.as_ptr(), &mut out), Code::Argument);
            assert!(emptied(&out));
            out = sentinel();
            assert_eq!(set(std::ptr::null(), &mut out), Code::Argument);
            assert!(emptied(&out));
        }
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
            name: std::ptr::null(),
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
            assert_eq!(ko_client_size(std::ptr::null(), 1, 1, 0, 0), Code::Argument);
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
                ko_client_prompt_resolve(
                    std::ptr::null(),
                    c"pane_1".as_ptr(),
                    false,
                    &mut empty_buffer()
                ),
                Code::Argument
            );
            assert_eq!(
                ko_client_prompt(
                    std::ptr::null(),
                    c"pane_1".as_ptr(),
                    c"pane_2".as_ptr(),
                    b"x".as_ptr(),
                    1,
                    &mut empty_buffer()
                ),
                Code::Argument
            );
            assert_eq!(ko_view_close(std::ptr::null_mut()), Code::Argument);
            assert_eq!(ko_view_resync(std::ptr::null(), true), Code::Argument);
            assert_eq!(
                ko_view_input(std::ptr::null(), std::ptr::null(), 0),
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
        let messages: Vec<String> = (0..=14)
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
        assert_eq!((unique.len(), messages[14].as_str()), (15, "unknown code"));
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
        // SAFETY: the view handle is live; its client is closed.
        let code = unsafe { ko_view_input(blocked.view, b"x".as_ptr(), 1) };
        assert_eq!(code, Code::Closed);
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
    fn input_bytes_reach_the_pane_as_text_and_a_null_pointer_with_a_length_is_refused() {
        let (got, received) = channel();
        let routes = client_script(|socket, _| {
            welcomed(socket);
            wait_for_hangup(socket);
        })
        .view(move |socket, _| {
            send_binary(socket, slice_record(10, true, true, true, b"s"));
            for message in text_messages(socket, 1) {
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
        // SAFETY: the view is live and the bytes outlive the call.
        assert_eq!(unsafe { ko_view_input(view, b"hi".as_ptr(), 2) }, Code::Ok);
        assert_eq!(
            received.recv_timeout(WAIT).unwrap(),
            r#"{"type":"input","input":{"type":"text","data":"aGk="}}"#
        );
        // SAFETY: the view is live; the pointer is null.
        let code = unsafe { ko_view_input(view, std::ptr::null(), 2) };
        assert_eq!(code, Code::Argument);
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
                    c"pane_2".as_ptr(),
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

    fn a_server_close_during_a_restore(name: &str, paused: bool, close_frame: bool) {
        const SLICE: usize = 512 << 10;
        let (restore_started, started) = channel::<()>();
        let routes = client_script(|socket, _| {
            welcomed(socket);
            wait_for_hangup(socket);
        })
        .view(move |socket, _| {
            let count = if paused { 16 } else { 1 };
            for index in 0..count {
                let record = slice_record(10, index == 0, false, true, &pattern(index, SLICE));
                send_binary(socket, record);
            }
            let _ = started.recv_timeout(WAIT);
            if close_frame {
                let _ = socket.close(Some(tungstenite::protocol::CloseFrame {
                    code: tungstenite::protocol::frame::coding::CloseCode::Again,
                    reason: "view queue overflow".into(),
                }));
            }
        });
        let server = serve(name, routes);
        let fixture = Fixture::new();
        let client = fixture.connect(&server);
        assert!(matches!(fixture.next(), Seen::Welcome(..)));
        assert!(matches!(fixture.next(), Seen::Layout(0, ..)));
        let (reading, is_reading) = channel();
        let (release, gate) = channel::<()>();
        let (cancelled, was_cancelled) = channel();
        let decoder = Decoder::new(move |snapshot| {
            let _ = restore_started.send(());
            if paused {
                let _ = pull(snapshot, 64 << 10, 64 << 10);
                let _ = reading.send(());
                let _ = gate.recv_timeout(WAIT);
            }
            let _ = cancelled.send(pull(snapshot, usize::MAX, 64 << 10).is_err());
            Restored::Rejected
        });
        let view = open_view(client, decoder, true);
        if paused {
            is_reading.recv_timeout(WAIT).unwrap();
            until("the core stops reading a snapshot nobody takes", || {
                handle_of(view).view.pause.load(Ordering::SeqCst)
            });
            let _ = release.send(());
        }
        let closed = fixture.next();
        if close_frame {
            assert!(
                matches!(closed, Seen::Closed(Code::Closed, _)),
                "{closed:?}"
            );
        } else {
            assert!(matches!(closed, Seen::Closed(Code::Io, _)), "{closed:?}");
        }
        assert!(
            was_cancelled.recv_timeout(WAIT).unwrap(),
            "the restore read on after the view closed"
        );
        close_view(view);
        close(client);
    }

    #[test]
    fn a_server_close_during_a_restore_closes_the_view_and_fails_the_decoders_read() {
        a_server_close_during_a_restore("close-restore", false, true);
        a_server_close_during_a_restore("hangup-restore", false, false);
    }

    #[test]
    fn a_server_hangup_closes_a_paused_view_once_its_decoder_takes_what_waits() {
        a_server_close_during_a_restore("close-paused", true, false);
    }

    #[test]
    fn a_close_frame_closes_a_paused_view_once_its_decoder_takes_what_waits() {
        a_server_close_during_a_restore("close-frame-paused", true, true);
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
        let rows = [pane_row(1, None), pane_row(2, None)];
        let server = serve(
            "coalesce",
            client_script(move |socket, _| {
                send(socket, &welcome(INSTANCE, 1));
                send(socket, &layout_with(0, &rows));
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

    #[test]
    fn clipboard_events_reach_the_callback_and_answers_reach_the_wire() {
        let (answers, answered) = channel();
        let server = serve(
            "clipboard",
            client_script(move |socket, _| {
                welcomed(socket);
                send(
                    socket,
                    r#"{"type":"clipboard_write","pane":"pane_1","location":"primary","contents":[{"mime":"text/plain","data":"aGk="},{"mime":"image/png","data":"AAEC"}]}"#,
                );
                send(
                    socket,
                    r#"{"type":"clipboard_read","pane":"pane_2","id":5,"location":"selection","mimes":["text/plain"],"list":true}"#,
                );
                for text in text_messages(socket, 4) {
                    let _ = answers.send(text);
                }
                wait_for_hangup(socket);
            }),
        );
        let fixture = Fixture::new();
        let client = fixture.connect(&server);
        assert!(matches!(fixture.next(), Seen::Welcome(..)));
        assert!(matches!(fixture.next(), Seen::Layout(0, ..)));
        assert_eq!(
            fixture.next(),
            Seen::ClipboardWrite(
                "pane_1".to_owned(),
                3,
                vec![
                    ("text/plain".to_owned(), b"hi".to_vec()),
                    ("image/png".to_owned(), vec![0, 1, 2]),
                ]
            )
        );
        assert_eq!(
            fixture.next(),
            Seen::ClipboardRead(
                "pane_2".to_owned(),
                5,
                2,
                vec!["text/plain".to_owned()],
                true
            )
        );
        let item = ClipboardItem {
            mime: c"text/plain".as_ptr(),
            data: b"clip".as_ptr(),
            len: 4,
        };
        let avail = [c"text/plain".as_ptr(), c"image/png".as_ptr()];
        // SAFETY: the client is live; the item and its strings are valid for the call.
        unsafe {
            assert_eq!(
                ko_client_clipboard_answer(client, 5, &item, 1, std::ptr::null(), 0),
                Code::Ok
            );
            assert_eq!(
                ko_client_clipboard_answer(client, 6, std::ptr::null(), 0, std::ptr::null(), 0),
                Code::Ok
            );
            assert_eq!(
                ko_client_clipboard_answer(client, 7, &item, 0, avail.as_ptr(), 2),
                Code::Ok
            );
            let big = vec![0u8; ko_pane_wire::frame::MAX_CLIPBOARD];
            let large = ClipboardItem {
                mime: c"image/png".as_ptr(),
                data: big.as_ptr(),
                len: big.len(),
            };
            assert_eq!(
                ko_client_clipboard_answer(client, 8, &large, 1, std::ptr::null(), 0),
                Code::Ok
            );
        }
        let sent: Vec<Value> = (0..4)
            .map(|_| serde_json::from_str(&answered.recv_timeout(WAIT).unwrap()).unwrap())
            .collect();
        assert_eq!(
            sent,
            [
                json!({"type": "clipboard_answer", "id": 5, "contents": [{"mime": "text/plain", "data": "Y2xpcA=="}]}),
                json!({"type": "clipboard_answer", "id": 6}),
                json!({"type": "clipboard_answer", "id": 7, "contents": [], "available": ["text/plain", "image/png"]}),
                json!({"type": "clipboard_answer", "id": 8}),
            ]
        );
        close(client);
    }

    fn image_of(
        client: *mut Client,
        (pane, image, frame, generation): (&CStr, u32, u32, u64),
        accept_shm: bool,
    ) -> (Code, Image) {
        let mut out = Image {
            format: 0,
            width: 0,
            height: 0,
            generation: 0,
            gap_ms: 0,
            frames: 0,
            length: 0,
            shm_name: [0; 32],
            body: empty_buffer(),
        };
        // SAFETY: the client is live, the pane is NUL-terminated and out is writable.
        let code = unsafe {
            ko_client_image(
                client,
                pane.as_ptr(),
                image,
                frame,
                generation,
                accept_shm,
                &mut out,
            )
        };
        (code, out)
    }

    #[test]
    fn an_image_frame_comes_as_a_shared_memory_name_or_a_body_and_a_missing_one_is_not_found() {
        let server = serve(
            "image",
            client_script(|socket, _| {
                welcomed(socket);
                wait_for_hangup(socket);
            })
            .plain(|request| {
                if !request.target.starts_with("/panes/pane_1/images/") {
                    return answer_empty(request);
                }
                if request.target.contains("/images/9/") {
                    return Some((
                        404,
                        r#"{"kind":"not_found","message":"image not found"}"#.to_owned(),
                    ));
                }
                if header(&request.head, "Ko-Accept-Shm").is_some() {
                    return Some((
                        200,
                        r#"{"name":"/ko-77-3","length":8,"format":"rgb","width":1,"height":2,"generation":42,"gap_ms":15,"frames":2}"#.to_owned(),
                    ));
                }
                Some((200, "PIXELS!!".to_owned()))
            }),
        );
        let fixture = Fixture::new();
        let client = fixture.connect(&server);
        assert!(matches!(fixture.next(), Seen::Welcome(..)));
        assert!(matches!(fixture.next(), Seen::Layout(0, ..)));

        let (code, mut shm) = image_of(client, (c"pane_1", 7, 2, 42), true);
        assert_eq!(code, Code::Ok);
        assert_eq!(
            (
                shm.format,
                shm.width,
                shm.height,
                shm.generation,
                shm.gap_ms,
                shm.frames,
                shm.length
            ),
            (1, 1, 2, 42, 15, 2, 8)
        );
        assert_eq!(owned(shm.shm_name.as_ptr()), "/ko-77-3");
        assert!(shm.body.data.is_null());
        freed_once_if_any(&mut shm.body);
        let heads = server.heads("GET", "/panes/pane_1/images/7/frames/2?generation=42");
        assert_eq!(heads.len(), 1);
        assert!(
            header(&heads[0], "Ko-Accept-Shm") == Some("1")
                && heads[0].contains("Ko-Client: client_7"),
            "{}",
            heads[0]
        );

        let (code, mut body) = image_of(client, (c"pane_1", 7, 3, 99), false);
        assert_eq!(code, Code::Ok);
        assert_eq!(
            (
                body.format,
                body.width,
                body.height,
                body.generation,
                body.gap_ms,
                body.frames,
                body.length
            ),
            (2, 2, 1, 99, 40, 3, 8)
        );
        assert_eq!(owned(body.shm_name.as_ptr()), "");
        assert_eq!(contents(&body.body), "PIXELS!!");
        freed_once(&mut body.body);
        let heads = server.heads("GET", "/panes/pane_1/images/7/frames/3?generation=99");
        assert!(header(&heads[0], "Ko-Accept-Shm").is_none(), "{}", heads[0]);

        for accept in [true, false] {
            let (code, mut gone) = image_of(client, (c"pane_1", 9, 1, 1), accept);
            assert_eq!(code, Code::NotFound);
            assert_eq!(contents(&gone.body), "image not found");
            freed_once(&mut gone.body);
        }
        for bad in [
            (c"bogus", 7, 1, 1),
            (c"pane_1", 0, 1, 1),
            (c"pane_1", 7, 0, 1),
            (c"pane_1", 7, 1, 0),
        ] {
            let (code, out) = image_of(client, bad, true);
            assert_eq!((code, out.body.data.is_null()), (Code::Argument, true));
        }
        let fetched = server.targets("GET");
        assert_eq!(
            fetched
                .iter()
                .filter(|target| target.starts_with("/panes/"))
                .count(),
            4,
            "a bad argument sends nothing: {fetched:?}"
        );
        close(client);
    }
}
