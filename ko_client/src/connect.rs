use ko_sys::event::Wake;
use std::io;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::{Duration, Instant};

pub const PATIENCE: Patience = Patience {
    deadline: Duration::from_secs(5),
    retry: Duration::from_millis(10),
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Patience {
    pub(crate) deadline: Duration,
    pub(crate) retry: Duration,
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

pub const BACKOFF_FIRST: Duration = Duration::from_millis(100);
const BACKOFF_LAST: Duration = Duration::from_secs(2);

pub fn backoff_after(backoff: Duration) -> Duration {
    (backoff * 2).min(BACKOFF_LAST)
}

pub(crate) fn absent(error: &io::Error) -> bool {
    matches!(
        error.kind(),
        io::ErrorKind::NotFound | io::ErrorKind::ConnectionRefused
    )
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
