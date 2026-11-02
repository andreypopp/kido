use std::cell::RefCell;
use std::fs::{File, OpenOptions, TryLockError};
use std::io;
use std::os::fd::AsFd;
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

use ko_server::config::{self, Dir};
use ko_sys::pid::Waited;
use ko_sys::signal::Signal;

pub const PATIENCE: Patience = Patience {
    deadline: Duration::from_secs(5),
    retry: Duration::from_millis(10),
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Patience {
    deadline: Duration,
    retry: Duration,
}

pub(crate) fn absent(error: &io::Error) -> bool {
    matches!(
        error.kind(),
        io::ErrorKind::NotFound | io::ErrorKind::ConnectionRefused
    )
}

fn remove_stale(socket: &Path, error: &io::Error) -> io::Result<()> {
    if error.kind() != io::ErrorKind::ConnectionRefused {
        return Ok(());
    }
    match std::fs::remove_file(socket) {
        Err(error) if error.kind() != io::ErrorKind::NotFound => Err(error),
        _ => Ok(()),
    }
}

// Cancels every connection that a thread opens through `connect` while it runs
// `cancellable`. The first one is the long-lived link; each later one replaces
// the previous, which a single-threaded caller has finished with.
#[derive(Debug, Default)]
pub(crate) struct Cancel {
    done: AtomicBool,
    streams: Mutex<[Option<UnixStream>; 2]>,
}

thread_local! {
    static CANCEL: RefCell<Option<Arc<Cancel>>> = const { RefCell::new(None) };
}

impl Cancel {
    pub(crate) fn cancelled(&self) -> bool {
        self.done.load(Ordering::SeqCst)
    }

    pub(crate) fn cancel(&self) {
        self.done.store(true, Ordering::SeqCst);
        let mut streams = self.streams.lock().unwrap_or_else(PoisonError::into_inner);
        for stream in streams.iter_mut().filter_map(Option::take) {
            let _ = stream.shutdown(std::net::Shutdown::Both);
        }
    }

    fn watch(&self, stream: &UnixStream) -> io::Result<()> {
        let mut streams = self.streams.lock().unwrap_or_else(PoisonError::into_inner);
        if self.cancelled() {
            return Err(cancelled_error());
        }
        let slot = usize::from(streams[0].is_some());
        streams[slot] = Some(stream.try_clone()?);
        Ok(())
    }
}

pub(crate) fn cancellable<T>(cancel: &Arc<Cancel>, work: impl FnOnce() -> T) -> T {
    CANCEL.with(|current| *current.borrow_mut() = Some(Arc::clone(cancel)));
    let done = work();
    CANCEL.with(|current| *current.borrow_mut() = None);
    done
}

fn cancelled_error() -> io::Error {
    io::Error::other("cancelled")
}

fn cancel_of_thread() -> Option<Arc<Cancel>> {
    CANCEL.with(|current| current.borrow().clone())
}

pub(crate) fn connect(socket: &Path, patience: Patience) -> io::Result<UnixStream> {
    let cancel = cancel_of_thread();
    let deadline = Instant::now() + patience.deadline;
    loop {
        if cancel.as_ref().is_some_and(|cancel| cancel.cancelled()) {
            return Err(cancelled_error());
        }
        match UnixStream::connect(socket) {
            Err(error)
                if error.kind() == io::ErrorKind::WouldBlock && Instant::now() < deadline =>
            {
                std::thread::sleep(patience.retry);
            }
            Ok(stream) => {
                if let Some(cancel) = &cancel {
                    cancel.watch(&stream)?;
                }
                return Ok(stream);
            }
            failed => return failed,
        }
    }
}

fn lock(dir: &Path, patience: Patience) -> io::Result<File> {
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(dir.join("launch.lock"))?;
    let deadline = Instant::now() + patience.deadline;
    loop {
        match lock.try_lock() {
            Ok(()) => return Ok(lock),
            Err(TryLockError::WouldBlock) if Instant::now() < deadline => {
                std::thread::sleep(patience.retry);
            }
            Err(TryLockError::WouldBlock) => {
                return Err(io::Error::new(io::ErrorKind::TimedOut, "launch lock"));
            }
            Err(TryLockError::Error(error)) => return Err(error),
        }
    }
}

pub fn bind(dir: &Path, socket: &Path, patience: Patience) -> io::Result<UnixListener> {
    let _lock = lock(dir, patience)?;
    if let Err(error) = connect(socket, patience) {
        remove_stale(socket, &error)?;
    }
    UnixListener::bind(socket)
}

pub fn attach(
    dir: &Path,
    executable: &Path,
    patience: Patience,
) -> Result<(PathBuf, UnixStream), String> {
    let socket = config::socket(Dir::Create, dir)?;
    let message = |error: io::Error| error.to_string();
    match connect(&socket, patience) {
        Ok(stream) => return Ok((socket, stream)),
        Err(error) if absent(&error) => {}
        Err(error) => return Err(message(error)),
    }
    let held = lock(dir, patience).map_err(message)?;
    match connect(&socket, patience) {
        Ok(stream) => return Ok((socket, stream)),
        Err(error) if absent(&error) => remove_stale(&socket, &error).map_err(message)?,
        Err(error) => return Err(message(error)),
    }
    let log = dir.join("log");
    let output = OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(&log)
        .map_err(message)?;
    let args = ["server", "--server", &dir.to_string_lossy()];
    let child = ko_sys::spawn::detached(executable, &args, output.as_fd()).map_err(message)?;
    drop(held);
    let deadline = Instant::now() + patience.deadline;
    loop {
        match connect(&socket, patience) {
            Ok(stream) => return Ok((socket, stream)),
            Err(error) if absent(&error) => {}
            Err(error) => return Err(message(error)),
        }
        if !matches!(child.try_wait(), Ok(Waited::Running)) {
            return Err(format!("server exited; see {}", log.display()));
        }
        if Instant::now() >= deadline {
            return Err(format!(
                "server did not start within {} seconds; see {}",
                patience.deadline.as_secs(),
                log.display()
            ));
        }
        std::thread::sleep(patience.retry);
    }
}

pub fn stop(dir: &Path, patience: Patience) -> Result<(), String> {
    let socket = config::socket(Dir::Existing, dir)?;
    let message = |error: io::Error| error.to_string();
    let stream = connect(&socket, patience).map_err(message)?;
    if ko_sys::sock::peer_uid(stream.as_fd()).map_err(message)? != ko_sys::sock::uid() {
        return Err("server belongs to another user".to_owned());
    }
    let pid = ko_sys::sock::peer_pid(stream.as_fd())
        .map_err(message)?
        .ok_or("invalid server pid")?;
    pid.signal(Signal::Term).map_err(message)?;
    drop(stream);
    let deadline = Instant::now() + patience.deadline;
    while socket.exists() || pid.alive() {
        if Instant::now() >= deadline {
            return Err(format!(
                "server did not stop within {} s",
                patience.deadline.as_secs()
            ));
        }
        std::thread::sleep(patience.retry);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn scratch(name: &str) -> PathBuf {
        let dir = PathBuf::from(format!("/tmp/ko-launch-{name}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn a_stale_socket_is_replaced_and_a_live_one_is_refused() {
        let dir = scratch("bind");
        let socket = dir.join("socket");
        drop(UnixListener::bind(&socket).unwrap());
        let stale = (
            socket.exists(),
            UnixStream::connect(&socket).unwrap_err().kind(),
        );
        let listener = bind(&dir, &socket, PATIENCE).unwrap();
        let reached = UnixStream::connect(&socket).is_ok();
        let refused = bind(&dir, &socket, PATIENCE).unwrap_err().kind();
        let still = UnixStream::connect(&socket).is_ok();
        assert_eq!(
            (stale, reached, refused, still),
            (
                (true, io::ErrorKind::ConnectionRefused),
                true,
                io::ErrorKind::AddrInUse,
                true
            )
        );
        drop(listener);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_missing_socket_binds_and_a_held_lock_is_waited_for_until_the_deadline() {
        let dir = scratch("lock");
        let socket = dir.join("socket");
        let held = lock(&dir, PATIENCE).unwrap();
        let short = Patience {
            deadline: Duration::from_millis(50),
            retry: Duration::from_millis(10),
        };
        let waited = bind(&dir, &socket, short).unwrap_err().kind();
        drop(held);
        let bound = bind(&dir, &socket, short).map(|_| ());
        assert_eq!((waited, bound.is_ok()), (io::ErrorKind::TimedOut, true));
        std::fs::remove_dir_all(dir).unwrap();
    }
}
