#![allow(unsafe_code)]

use std::cell::Cell;
use std::ffi::{CStr, CString, c_char, c_int, c_void};
use std::io;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::thread::JoinHandle;

use ko_pane_wire::frame::Size as FrameSize;
use ko_server::api::Route;
use ko_server::protocol::{self, ClientEvent, ClientKind, Hello, Selection};

use crate::launch::{self, Cancel, PATIENCE};
use crate::model::{Applied, Model};
use crate::wire::{Link, Next, text};

unsafe extern "C" {
    fn dispatch_async_f(queue: *mut c_void, context: *mut c_void, work: extern "C" fn(*mut c_void));
    fn dispatch_retain(object: *mut c_void);
    fn dispatch_release(object: *mut c_void);
}

thread_local! {
    static RUNNING: Cell<*const Shared> = const { Cell::new(std::ptr::null()) };
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i32)]
pub enum Code {
    Ok = 0,
    Argument = 1,
    NoServer = 2,
    Io = 3,
    Protocol = 4,
    Closed = 5,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct Welcome {
    pub client: *const c_char,
    pub instance: *const c_char,
    pub now: u64,
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

const EVENT_WELCOME: c_int = 1;
const EVENT_LAYOUT: c_int = 2;
const EVENT_FAILED: c_int = 3;

#[repr(C)]
#[derive(Clone, Copy)]
pub union Body {
    pub welcome: Welcome,
    pub layout: Layout,
    pub failure: Failure,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct Event {
    pub kind: c_int,
    pub body: Body,
}

pub type Callback = unsafe extern "C" fn(user: *mut c_void, event: *const Event);

#[derive(Debug)]
enum Posted {
    Welcome {
        client: CString,
        instance: CString,
        now: u64,
    },
    Layout(Layout),
    Failed(Code, CString),
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

// SAFETY: the caller of ko_client_connect promises that the callback may run
// with this pointer on the queue's threads.
unsafe impl Send for User {}
// SAFETY: as above.
unsafe impl Sync for User {}

#[derive(Debug)]
struct Shared {
    queue: Queue,
    callback: Callback,
    user: User,
    cancel: Arc<Cancel>,
    running: Mutex<()>,
}

#[derive(Debug)]
pub struct Client {
    shared: Arc<Shared>,
    worker: JoinHandle<()>,
}

#[derive(Debug)]
struct Item {
    shared: Arc<Shared>,
    posted: Posted,
}

fn locked<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

fn string(text: &str) -> CString {
    CString::new(text.replace('\0', " ")).unwrap_or_default()
}

fn post(shared: &Arc<Shared>, posted: Posted) {
    if shared.cancel.cancelled() {
        return;
    }
    let item = Box::into_raw(Box::new(Item {
        shared: Arc::clone(shared),
        posted,
    }));
    // SAFETY: the queue is retained by shared, which the item keeps alive, and
    // deliver frees the item exactly once.
    unsafe { dispatch_async_f(shared.queue.0, item.cast(), deliver) }
}

extern "C" fn deliver(context: *mut c_void) {
    // SAFETY: context is the pointer that post made from a Box<Item>, and
    // dispatch runs each work item once.
    let item = unsafe { Box::from_raw(context.cast::<Item>()) };
    let shared = &item.shared;
    let _running = locked(&shared.running);
    if shared.cancel.cancelled() {
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
        } => {
            call(Event {
                kind: EVENT_WELCOME,
                body: Body {
                    welcome: Welcome {
                        client: client.as_ptr(),
                        instance: instance.as_ptr(),
                        now: *now,
                    },
                },
            });
        }
        Posted::Layout(layout) => call(Event {
            kind: EVENT_LAYOUT,
            body: Body { layout: *layout },
        }),
        Posted::Failed(code, message) => {
            call(Event {
                kind: EVENT_FAILED,
                body: Body {
                    failure: Failure {
                        code: *code,
                        message: message.as_ptr(),
                    },
                },
            });
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

fn failure(error: &io::Error) -> (Code, String) {
    let code = if launch::absent(error) {
        Code::NoServer
    } else if matches!(
        error.kind(),
        io::ErrorKind::BrokenPipe | io::ErrorKind::ConnectionReset | io::ErrorKind::UnexpectedEof
    ) {
        Code::Closed
    } else {
        Code::Io
    };
    (code, error.to_string())
}

fn session(shared: &Arc<Shared>, socket: &Path) -> Result<(), (Code, String)> {
    let stream = launch::connect(socket, PATIENCE).map_err(|error| failure(&error))?;
    let mut link =
        Link::upgrade(stream, None, &Route::Client {}).map_err(|error| failure(&error))?;
    let hello = Hello {
        kind: ClientKind::App,
        name: "ko_client".to_owned(),
        selection: Selection::default(),
        focused: false,
        size: protocol::Size(FrameSize::DEFAULT),
        ignore_size: true,
    };
    let mut model =
        Model::join(&mut link, hello, socket).map_err(|message| (Code::Protocol, message))?;
    post(
        shared,
        Posted::Welcome {
            client: string(&model.client.to_string()),
            instance: string(&model.instance.to_string()),
            now: model.server_now(),
        },
    );
    post(shared, Posted::Layout(layout_of(&model)));
    loop {
        match link.receive().map_err(|error| failure(&error))? {
            Next::Text(event) => {
                let event = protocol::decode::<ClientEvent>(event.as_bytes())
                    .map_err(|error| (Code::Protocol, text(error)))?;
                let applied = model
                    .apply(event)
                    .map_err(|message| (Code::Protocol, message))?;
                if applied == Applied::Layout {
                    post(shared, Posted::Layout(layout_of(&model)));
                }
            }
            Next::Binary(_) => return Err((Code::Protocol, "binary client message".to_owned())),
            Next::Wait | Next::Closed => return Err((Code::Closed, "server closed".to_owned())),
        }
    }
}

fn run(shared: &Arc<Shared>, socket: &Path) {
    launch::cancellable(&shared.cancel, || {
        if let Err((code, message)) = session(shared, socket) {
            post(shared, Posted::Failed(code, string(&message)));
        }
    });
}

/// # Safety
///
/// `socket` is null or a NUL-terminated string. `queue` is null or a dispatch
/// queue. `callback` and `user` follow `ko_client.h`. `out` is null or points
/// to writable storage for one pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_client_connect(
    socket: *const c_char,
    queue: *mut c_void,
    callback: Option<Callback>,
    user: *mut c_void,
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
    // SAFETY: queue is a live dispatch queue by contract; Queue releases this retain.
    unsafe { dispatch_retain(queue) };
    let shared = Arc::new(Shared {
        queue: Queue(queue),
        callback,
        user: User(user),
        cancel: Arc::default(),
        running: Mutex::new(()),
    });
    let worker = Arc::clone(&shared);
    let Ok(worker) = std::thread::Builder::new()
        .name("ko-client".to_owned())
        .spawn(move || run(&worker, &socket))
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
/// closed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_client_close(client: *mut Client) -> Code {
    if client.is_null() {
        return Code::Argument;
    }
    // SAFETY: client is a live handle that this call consumes, by contract.
    let Client { shared, worker } = *unsafe { Box::from_raw(client) };
    shared.cancel.cancel();
    if RUNNING.get() != Arc::as_ptr(&shared) {
        drop(locked(&shared.running));
    }
    let _ = worker.join();
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
        _ => c"unknown code",
    };
    message.as_ptr()
}

#[cfg(test)]
mod tests {
    use std::io::{Read, Write};
    use std::os::unix::net::{UnixListener, UnixStream};
    use std::sync::atomic::{AtomicBool, AtomicPtr, Ordering};
    use std::sync::mpsc::{Receiver, Sender, channel};
    use std::time::{Duration, Instant};

    use tungstenite::protocol::{Role, WebSocket};
    use tungstenite::{Message, handshake::derive_accept_key};

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

    const WAIT: Duration = Duration::from_secs(10);
    const WELCOME: &str = r#"{"type":"welcome","client":"client_7","limits":{"terminal":{"scrollback":{"type":"disabled"},"apc_max_bytes":1,"kitty_images_max_bytes":1,"continuation_max_bytes":1},"media":[]},"instance":"0123456789abcdef0123456789abcdef","now":42}"#;

    fn layout(revision: u64) -> String {
        format!(
            r#"{{"type":"layout","revision":{revision},"layout":{{"sessions":[{{"id":"session_1","name":"s","vars":{{}},"windows":[{{"id":"window_1","name":"w","vars":{{}},"cols":80,"rows":24,"focus":"pane_1","tree":{{"split":"h","children":[{{"pane":"pane_1","cols":40,"rows":24}},{{"pane":"pane_2","cols":39,"rows":24}}]}},"floats":[]}}]}}]}}}}"#
        )
    }

    #[derive(Debug, PartialEq, Eq)]
    enum Seen {
        Welcome(String, String, u64),
        Layout(u64, u32, u32, u32),
        Failed(Code, String),
    }

    struct Probe {
        events: Sender<(Seen, Option<String>)>,
        client: AtomicPtr<Client>,
        on_welcome: Box<dyn Fn(&Probe) + Send + Sync>,
    }

    unsafe extern "C" fn record(user: *mut c_void, event: *const Event) {
        // SAFETY: user is the Probe that the test keeps alive until its queue is flushed,
        // and event is valid during the callback.
        let (probe, event) = unsafe { (&*user.cast::<Probe>(), &*event) };
        let owned = |pointer: *const c_char| {
            // SAFETY: the core passes NUL-terminated strings.
            unsafe { CStr::from_ptr(pointer) }
                .to_string_lossy()
                .into_owned()
        };
        // SAFETY: each arm reads the union member that the kind names.
        let seen = unsafe {
            match event.kind {
                EVENT_WELCOME => {
                    let welcome = event.body.welcome;
                    Seen::Welcome(owned(welcome.client), owned(welcome.instance), welcome.now)
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
                _ => {
                    let failure = event.body.failure;
                    Seen::Failed(failure.code, owned(failure.message))
                }
            }
        };
        let thread = std::thread::current().name().map(str::to_owned);
        let _ = probe.events.send((seen, thread));
        if event.kind == EVENT_WELCOME {
            (probe.on_welcome)(probe);
        }
    }

    fn close(client: *mut Client) {
        // SAFETY: the handle is live and closed once.
        assert_eq!(unsafe { ko_client_close(client) }, Code::Ok);
    }

    struct Fixture {
        queue: *mut c_void,
        probe: Box<Probe>,
        events: Receiver<(Seen, Option<String>)>,
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
                probe: Box::new(Probe {
                    events,
                    client: AtomicPtr::new(std::ptr::null_mut()),
                    on_welcome: Box::new(on_welcome),
                }),
                events: receiver,
            }
        }

        fn connect(&self, socket: &Server) -> *mut Client {
            let mut path = socket.socket();
            path.push(0);
            let mut out = std::ptr::null_mut();
            let user = std::ptr::from_ref::<Probe>(&self.probe).cast_mut().cast();
            // SAFETY: path is NUL-terminated, the queue is live, out is writable, and
            // the probe outlives the queue's last callback.
            let code = unsafe {
                ko_client_connect(
                    path.as_ptr().cast(),
                    self.queue,
                    Some(record),
                    user,
                    &mut out,
                )
            };
            path.fill(b'X');
            assert_eq!(code, Code::Ok);
            self.probe.client.store(out, Ordering::SeqCst);
            out
        }

        fn next(&self) -> Seen {
            let (seen, thread) = self.events.recv_timeout(WAIT).unwrap();
            assert_ne!(
                thread.as_deref(),
                Some("ko-client"),
                "a callback on the I/O thread"
            );
            seen
        }

        fn flush(&self) {
            extern "C" fn nothing(_: *mut c_void) {}
            // SAFETY: the queue is live and not suspended by the caller.
            unsafe { dispatch_sync_f(self.queue, std::ptr::null_mut(), nothing) }
        }

        fn quiet(&self) -> Vec<Seen> {
            self.flush();
            self.events.try_iter().map(|(seen, _)| seen).collect()
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            // SAFETY: the queue was created here and nothing uses it after the flush.
            unsafe { dispatch_release(self.queue) }
        }
    }

    enum Panes {
        Answer,
        Hold(Sender<()>),
    }

    struct Server {
        dir: PathBuf,
        stop: Arc<AtomicBool>,
        accept: Option<JoinHandle<()>>,
    }

    impl Server {
        fn socket(&self) -> Vec<u8> {
            self.dir.join("socket").as_os_str().as_bytes().to_vec()
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

    fn head(stream: &mut UnixStream) -> String {
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

    fn serve(
        name: &str,
        panes: Panes,
        script: impl FnOnce(&mut WebSocket<UnixStream>) + Send + 'static,
    ) -> Server {
        let dir = PathBuf::from(format!("/tmp/ko-ffi-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let listener = UnixListener::bind(dir.join("socket")).unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let halted = Arc::clone(&stop);
        let accept = std::thread::spawn(move || {
            let (mut script, mut connections) = (Some(script), Vec::new());
            while let Ok((mut stream, _)) = listener.accept() {
                if halted.load(Ordering::SeqCst) {
                    break;
                }
                let _ = stream.set_nonblocking(false);
                let _ = stream.set_read_timeout(Some(WAIT));
                let request = head(&mut stream);
                let key = request
                    .lines()
                    .find_map(|line| line.strip_prefix("Sec-WebSocket-Key: "))
                    .map(str::to_owned);
                match (key, script.take()) {
                    (Some(key), Some(script)) => connections.push(std::thread::spawn(move || {
                        let accept = derive_accept_key(key.as_bytes());
                        let _ = write!(
                            stream,
                            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n"
                        );
                        let mut socket = WebSocket::from_raw_socket(stream, Role::Server, None);
                        let _ = socket.read();
                        script(&mut socket);
                    })),
                    _ => match &panes {
                        Panes::Answer => {
                            let _ = stream.write_all(
                                b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n[]",
                            );
                        }
                        Panes::Hold(held) => {
                            let held = held.clone();
                            connections.push(std::thread::spawn(move || {
                                let _ = held.send(());
                                let mut byte = [0];
                                while stream.read(&mut byte).unwrap_or(0) > 0 {}
                                let _ = held.send(());
                            }));
                        }
                    },
                }
            }
            for connection in connections {
                let _ = connection.join();
            }
        });
        Server {
            dir,
            stop,
            accept: Some(accept),
        }
    }

    fn send(socket: &mut WebSocket<UnixStream>, text: &str) {
        socket.send(Message::text(text)).unwrap();
    }

    fn send_ping(socket: &mut WebSocket<UnixStream>) {
        socket.send(Message::Ping(Default::default())).unwrap();
    }

    fn wait_for_hangup(socket: &mut WebSocket<UnixStream>) {
        while socket.read().is_ok() {}
    }

    fn welcomed(socket: &mut WebSocket<UnixStream>) {
        send(socket, WELCOME);
        send(socket, &layout(0));
    }

    #[test]
    fn welcome_then_layout_arrive_on_the_queue_and_later_layouts_follow_in_order() {
        let server = serve("order", Panes::Answer, |socket| {
            send(socket, WELCOME);
            send(socket, &layout(3));
            send(socket, &layout(4));
            wait_for_hangup(socket);
        });
        let fixture = Fixture::new();
        let client = fixture.connect(&server);
        let seen = [fixture.next(), fixture.next(), fixture.next()];
        let Seen::Welcome(id, instance, now) = &seen[0] else {
            panic!("{seen:?}");
        };
        assert_eq!(
            (
                id.as_str(),
                instance.as_str(),
                (42..42 + 10_000_000_000).contains(now)
            ),
            ("client_7", "0123456789abcdef0123456789abcdef", true)
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
        let server = serve(name, Panes::Answer, move |socket| {
            send(socket, WELCOME);
            for revision in 0..50 {
                send(socket, &layout(revision));
            }
            let _ = socket.close(None);
            let _ = socket.flush();
            wait_for_hangup(socket);
            let _ = hung_up.send(());
        });
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
        let server = serve("waits", Panes::Answer, |socket| {
            welcomed(socket);
            wait_for_hangup(socket);
        });
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
        let held_server = serve("held", Panes::Answer, |socket| {
            welcomed(socket);
            wait_for_hangup(socket);
        });
        let closer_server = serve("closer", Panes::Answer, |socket| {
            welcomed(socket);
            wait_for_hangup(socket);
        });
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
    fn a_close_cancels_a_stalled_panes_request_and_ends_the_worker() {
        let (held, panes) = channel();
        let (hung_up, hangup) = channel();
        let server = serve("stalled", Panes::Hold(held), move |socket| {
            welcomed(socket);
            wait_for_hangup(socket);
            let _ = hung_up.send(());
        });
        let fixture = Fixture::new();
        let client = fixture.connect(&server);
        panes.recv_timeout(WAIT).unwrap();
        let started = Instant::now();
        close(client);
        assert!(started.elapsed() < Duration::from_secs(5));
        panes.recv_timeout(WAIT).unwrap();
        hangup.recv_timeout(WAIT).unwrap();
        assert_eq!(fixture.quiet(), []);
    }

    #[test]
    fn an_idle_connection_answers_a_ping_before_any_other_message_arrives() {
        let server = serve("ping", Panes::Answer, |socket| {
            welcomed(socket);
            send_ping(socket);
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
        });
        let fixture = Fixture::new();
        let client = fixture.connect(&server);
        assert!(matches!(fixture.next(), Seen::Welcome(..)));
        assert!(matches!(fixture.next(), Seen::Layout(0, ..)));
        assert!(matches!(fixture.next(), Seen::Layout(9, ..)));
        close(client);
    }

    #[test]
    fn a_missing_server_a_garbled_welcome_and_a_hangup_each_end_in_one_failed_event() {
        let fixture = Fixture::new();
        let nowhere = Server {
            dir: PathBuf::from("/tmp/ko-ffi-nowhere"),
            stop: Arc::default(),
            accept: None,
        };
        let client = fixture.connect(&nowhere);
        assert!(
            matches!(fixture.next(), Seen::Failed(Code::NoServer, message) if !message.is_empty())
        );
        close(client);

        let garbled = serve("garbled", Panes::Answer, |socket| send(socket, "not json"));
        let client = fixture.connect(&garbled);
        assert!(matches!(fixture.next(), Seen::Failed(Code::Protocol, _)));
        close(client);

        let hangs_up = serve("hangs-up", Panes::Answer, |socket| {
            send(socket, WELCOME);
            send(socket, &layout(1));
            let _ = socket.close(None);
            let _ = socket.flush();
        });
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

    #[test]
    fn bad_arguments_return_a_code_and_leave_the_out_pointer_null() {
        let fixture = Fixture::new();
        let user = std::ptr::from_ref::<Probe>(&fixture.probe)
            .cast_mut()
            .cast();
        let path = c"/tmp/ko-ffi-none/socket";
        let connect = |socket: *const c_char,
                       queue: *mut c_void,
                       callback: Option<Callback>,
                       out: *mut *mut Client| {
            // SAFETY: each argument is null or valid; the call rejects null ones.
            unsafe { ko_client_connect(socket, queue, callback, user, out) }
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
        assert_eq!(
            // SAFETY: a null handle is refused.
            unsafe { ko_client_close(std::ptr::null_mut()) },
            Code::Argument
        );
    }

    #[test]
    fn every_code_has_its_own_static_message() {
        let messages: Vec<String> = (0..=6)
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
        assert_eq!((unique.len(), messages[6].as_str()), (7, "unknown code"));
    }
}
