use std::fs::{File, OpenOptions, TryLockError};
use std::io::{self, Read, Seek, SeekFrom};
use std::os::fd::AsFd;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

use ko_server::config::{self, Dir};
use ko_sys::event::Wake;
use ko_sys::pid::Pid;
use ko_sys::signal::Signal;

pub const PATIENCE: Patience = Patience {
    deadline: Duration::from_secs(5),
    retry: Duration::from_millis(10),
};

pub const BACKOFF_FIRST: Duration = Duration::from_millis(100);
const BACKOFF_LAST: Duration = Duration::from_secs(2);

pub fn backoff_after(backoff: Duration) -> Duration {
    (backoff * 2).min(BACKOFF_LAST)
}

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

pub(crate) fn cancelled_error() -> io::Error {
    io::Error::other("cancelled")
}

pub(crate) fn connect(
    socket: &Path,
    patience: Patience,
    cancel: Option<&Wake>,
) -> io::Result<UnixStream> {
    let deadline = Instant::now() + patience.deadline;
    loop {
        if cancel.is_some_and(Wake::is_set) {
            return Err(cancelled_error());
        }
        match UnixStream::connect(socket) {
            Err(error)
                if error.kind() == io::ErrorKind::WouldBlock && Instant::now() < deadline =>
            {
                std::thread::sleep(patience.retry);
            }
            connected => return connected,
        }
    }
}
// The servers that this process started. A server is this process's child, so a thread waits for
// it, or it stays a zombie that looks alive; after that wait its pid may name another process, so
// the thread marks it ended.
static STARTED: Mutex<Vec<(Pid, Arc<AtomicBool>)>> = Mutex::new(Vec::new());

fn reap(child: Pid) -> Arc<AtomicBool> {
    let ended = Arc::new(AtomicBool::new(false));
    STARTED
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .push((child, Arc::clone(&ended)));
    let mark = Arc::clone(&ended);
    std::thread::spawn(move || {
        let _ = child.wait();
        mark.store(true, Ordering::SeqCst);
    });
    ended
}

fn started(pid: Pid) -> Option<Arc<AtomicBool>> {
    STARTED
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .iter()
        .rev()
        .find(|(child, _)| *child == pid)
        .map(|(_, ended)| Arc::clone(ended))
}

const LAUNCH_LOCK: &str = "launch.lock";
const BIND_LOCK: &str = "bind.lock";

fn lock(dir: &Path, name: &str, patience: Patience) -> io::Result<File> {
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(dir.join(name))?;
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
    let _lock = lock(dir, BIND_LOCK, patience)?;
    if let Err(error) = connect(socket, patience, None) {
        remove_stale(socket, &error)?;
    }
    UnixListener::bind(socket)
}

pub fn attach(
    dir: &Path,
    executable: &Path,
    path: Option<&str>,
    cwd: Option<&Path>,
    patience: Patience,
) -> Result<(PathBuf, UnixStream), String> {
    let socket = config::socket(Dir::Create, dir)?;
    let message = |error: io::Error| error.to_string();
    match connect(&socket, patience, None) {
        Ok(stream) => return Ok((socket, stream)),
        Err(error) if absent(&error) => {}
        Err(error) => return Err(message(error)),
    }
    let _held = lock(dir, LAUNCH_LOCK, patience).map_err(message)?;
    match connect(&socket, patience, None) {
        Ok(stream) => return Ok((socket, stream)),
        Err(error) if absent(&error) => {}
        Err(error) => return Err(message(error)),
    }
    let log = dir.join("log");
    let mut output = OpenOptions::new()
        .read(true)
        .create(true)
        .append(true)
        .mode(0o600)
        .open(&log)
        .map_err(message)?;
    let log_start = output.metadata().map_err(message)?.len();
    let args = ["server", "--server", &dir.to_string_lossy()];
    let environment = path.map(|path| {
        std::env::vars_os()
            .filter(|(key, _)| key != "PATH")
            .map(|(key, value)| [key.as_bytes(), b"=", value.as_bytes()].concat())
            .chain([[b"PATH=", path.as_bytes()].concat()])
            .collect::<Vec<Vec<u8>>>()
    });
    let env = environment
        .as_deref()
        .map_or(ko_sys::spawn::Env::Inherit, ko_sys::spawn::Env::Only);
    let child =
        ko_sys::spawn::detached(executable, &args, output.as_fd(), env, cwd).map_err(message)?;
    let ended = reap(child);
    let deadline = Instant::now() + patience.deadline;
    loop {
        match connect(&socket, patience, None) {
            Ok(stream) => return Ok((socket, stream)),
            Err(error) if absent(&error) => {}
            Err(error) => return Err(message(error)),
        }
        let failure = if ended.load(Ordering::SeqCst) {
            "server exited".to_owned()
        } else if Instant::now() >= deadline {
            format!(
                "server did not start within {} seconds",
                patience.deadline.as_secs()
            )
        } else {
            std::thread::sleep(patience.retry);
            continue;
        };
        let mut detail = Vec::new();
        if output.seek(SeekFrom::Start(log_start)).is_ok() {
            let _ = output.take(16 * 1024).read_to_end(&mut detail);
        }
        return Err(format!(
            "{failure}; see {}\n{}",
            log.display(),
            String::from_utf8_lossy(&detail).trim()
        ));
    }
}

pub fn stop(dir: &Path, patience: Patience) -> Result<(), String> {
    let socket = config::socket(Dir::Existing, dir)?;
    let message = |error: io::Error| error.to_string();
    let stream = connect(&socket, patience, None).map_err(message)?;
    if ko_sys::sock::peer_uid(stream.as_fd()).map_err(message)? != ko_sys::sock::uid() {
        return Err("server belongs to another user".to_owned());
    }
    let pid = ko_sys::sock::peer_pid(stream.as_fd())
        .map_err(message)?
        .ok_or("invalid server pid")?;
    pid.signal(Signal::Term).map_err(message)?;
    drop(stream);
    let ended = started(pid);
    let alive = || match &ended {
        Some(ended) => !ended.load(Ordering::SeqCst),
        None => pid.alive(),
    };
    let deadline = Instant::now() + patience.deadline;
    while alive() {
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
    fn the_backoff_doubles_up_to_its_last_value() {
        let mut backoff = BACKOFF_FIRST;
        let mut seen = Vec::new();
        for _ in 0..7 {
            seen.push(backoff.as_millis());
            backoff = backoff_after(backoff);
        }
        assert_eq!(seen, [100, 200, 400, 800, 1600, 2000, 2000]);
    }

    // A child forked while the bind test drops its listener holds that socket open until it
    // execs, so a connect reaches it.
    static FORKING: Mutex<()> = Mutex::new(());

    #[test]
    fn a_server_that_exits_at_once_is_reported_as_an_exit_and_not_a_timeout() {
        let _forking = FORKING.lock().unwrap_or_else(PoisonError::into_inner);
        let dir = scratch("exit");
        std::fs::set_permissions(&dir, std::os::unix::fs::PermissionsExt::from_mode(0o700))
            .unwrap();
        let executable = dir.join("ko");
        std::fs::write(
            &executable,
            "#!/bin/sh\nprintf '\\377START-FAILED\\n' >&2\nexit 1\n",
        )
        .unwrap();
        std::fs::set_permissions(
            &executable,
            std::os::unix::fs::PermissionsExt::from_mode(0o700),
        )
        .unwrap();
        std::fs::write(dir.join("log"), "OLD-FAILURE\n").unwrap();
        let error = attach(&dir, &executable, None, None, PATIENCE).unwrap_err();
        assert!(error.starts_with("server exited"), "{error}");
        assert!(error.contains("�START-FAILED"), "{error}");
        assert!(!error.contains("OLD-FAILURE"), "{error}");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_stale_socket_is_replaced_and_a_live_one_is_refused() {
        let _forking = FORKING.lock().unwrap_or_else(PoisonError::into_inner);
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
        let held = lock(&dir, BIND_LOCK, PATIENCE).unwrap();
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
