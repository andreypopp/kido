use std::fs::{File, OpenOptions, TryLockError};
use std::io;
use std::os::fd::AsFd;
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::time::{Duration, Instant};

use ko_server::config::{self, Dir};
use ko_sys::signal::Signal;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Patience {
    pub deadline: Duration,
    pub retry: Duration,
}

pub(crate) fn connect(socket: &Path, patience: Patience) -> io::Result<UnixStream> {
    let deadline = Instant::now() + patience.deadline;
    loop {
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
    if let Err(error) = connect(socket, patience)
        && error.kind() == io::ErrorKind::ConnectionRefused
    {
        match std::fs::remove_file(socket) {
            Err(error) if error.kind() != io::ErrorKind::NotFound => return Err(error),
            _ => {}
        }
    }
    UnixListener::bind(socket)
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

    const PATIENCE: Patience = Patience {
        deadline: Duration::from_secs(5),
        retry: Duration::from_millis(10),
    };

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
