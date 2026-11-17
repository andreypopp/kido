use std::fmt;
use std::io::{self, Read as _, Write as _};
use std::net::{SocketAddr, TcpStream};
use std::os::fd::{AsFd, BorrowedFd};
use std::os::unix::net::UnixStream;
use std::sync::Arc;
use std::time::{Duration, Instant};

use ko_sys::event::{Interest, Poll, PollRead, Read, Reads, Token, Wake};
use ko_sys::fd::{self, Queue, Waited, Want};

use super::Limit;
use crate::endpoint::{Resolved, Tls};

#[derive(Debug)]
pub(crate) enum Failure {
    Tls(rustls::Error),
    Identity(rustls::Error),
}

impl fmt::Display for Failure {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Tls(error) | Self::Identity(error) => error.fmt(formatter),
        }
    }
}
impl std::error::Error for Failure {}

pub(crate) fn failure(error: rustls::Error) -> io::Error {
    let kind = match error {
        rustls::Error::AlertReceived(
            rustls::AlertDescription::BadCertificate
            | rustls::AlertDescription::CertificateRequired
            | rustls::AlertDescription::AccessDenied,
        ) => Failure::Identity(error),
        _ => Failure::Tls(error),
    };
    io::Error::other(kind)
}

#[derive(Debug)]
pub(crate) enum Stream {
    Unix(UnixStream),
    Tls(Box<Secured>),
}

#[derive(Debug)]
pub(crate) struct Secured {
    socket: TcpStream,
    session: rustls::ClientConnection,
    target: Arc<Tls>,
    remaining: std::collections::VecDeque<SocketAddr>,
    deadline: Instant,
    connected: bool,
    received: bool,
    pending_plaintext: u64,
}

impl Secured {
    fn start(
        target: Arc<Tls>,
        mut remaining: std::collections::VecDeque<SocketAddr>,
    ) -> io::Result<Self> {
        let mut last = io::Error::from(io::ErrorKind::NotFound);
        while let Some(address) = remaining.pop_front() {
            match ko_sys::sock::connect_tcp(address) {
                Ok(socket) => {
                    let name =
                        rustls::pki_types::ServerName::try_from(target.host.as_str().to_owned())
                            .map_err(io::Error::other)?;
                    let mut session =
                        rustls::ClientConnection::new(Arc::clone(&target.config), name)
                            .map_err(failure)?;
                    session.set_buffer_limit(Some(64 << 10));
                    return Ok(Self {
                        socket,
                        session,
                        target,
                        remaining,
                        deadline: Instant::now() + Duration::from_secs(5),
                        connected: false,
                        received: false,
                        pending_plaintext: 0,
                    });
                }
                Err(error) => last = error,
            }
        }
        Err(last)
    }

    fn flush(&mut self) -> io::Result<()> {
        while self.session.wants_write() {
            match self.session.write_tls(&mut self.socket) {
                Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
                Ok(_) => {}
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => return Ok(()),
                Err(error) => return Err(error),
            }
        }

        self.pending_plaintext = 0;
        Ok(())
    }
}

impl Stream {
    pub(crate) fn start(endpoint: &Resolved) -> io::Result<Self> {
        match endpoint {
            Resolved::Unix(path) => Ok(Self::Unix(UnixStream::from(
                ko_sys::sock::connect_nonblocking(path)?,
            ))),
            Resolved::Tls { target, addresses } => Ok(Self::Tls(Box::new(Secured::start(
                Arc::clone(target),
                addresses.iter().copied().collect(),
            )?))),
        }
    }

    pub(crate) fn open(
        endpoint: &Resolved,
        within: Limit,
        cancel: Option<&Wake>,
    ) -> io::Result<Self> {
        match endpoint {
            Resolved::Unix(path) => {
                let stream = match within {
                    Limit::Idle(_) => {
                        crate::connect::connect(path, crate::connect::PATIENCE, cancel)?
                    }
                    Limit::Deadline(_) => loop {
                        let remaining = within.remaining()?;
                        match ko_sys::sock::connect_nonblocking(path) {
                            Ok(socket) => break UnixStream::from(socket),
                            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                                std::thread::sleep(remaining.min(Duration::from_millis(10)))
                            }
                            Err(error) => return Err(error),
                        }
                    },
                };
                Ok(Self::Unix(stream))
            }
            Resolved::Tls { .. } => {
                let within = match within {
                    Limit::Idle(within) => Limit::Deadline(Instant::now() + within),
                    deadline => deadline,
                };
                let mut stream = Self::start(endpoint)?;
                loop {
                    let _ = within.remaining()?;
                    match stream.progress() {
                        Ok(()) if stream.ready() => return Ok(stream),
                        Ok(()) => {}
                        Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                        Err(error) => {
                            stream.retry(error)?;
                            continue;
                        }
                    }
                    let deadline = stream.deadline().unwrap_or_else(Instant::now);
                    let remaining = deadline
                        .saturating_duration_since(Instant::now())
                        .min(within.remaining()?);
                    if remaining.is_zero() {
                        stream.retry(io::ErrorKind::TimedOut.into())?;
                        continue;
                    }
                    let want = if stream.pending_write() {
                        Want::Write
                    } else {
                        Want::Read
                    };
                    match fd::wait(stream.fd(), want, cancel.map(Wake::fd), Some(remaining))? {
                        Waited::Cancelled => return Err(crate::connect::cancelled_error()),
                        Waited::TimedOut => stream.retry(io::ErrorKind::TimedOut.into())?,
                        Waited::Ready => {
                            if matches!(want, Want::Write)
                                && let Err(error) = stream.writable()
                            {
                                stream.retry(error)?;
                                continue;
                            }
                            if matches!(want, Want::Read) {
                                let Self::Tls(secured) = &mut stream else {
                                    return Err(io::Error::other("TLS dial changed transport"));
                                };
                                match secured.session.read_tls(&mut secured.socket) {
                                    Ok(0) => {
                                        stream.retry(io::ErrorKind::UnexpectedEof.into())?;
                                    }
                                    Ok(_) => {
                                        secured.session.process_new_packets().map_err(failure)?;
                                    }
                                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                                    Err(error) => stream.retry(error)?,
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    pub(crate) fn retry(&mut self, error: io::Error) -> io::Result<()> {
        match self {
            Self::Tls(secured)
                if !self::terminal(&error)
                    && !secured.remaining.is_empty()
                    && secured.session.is_handshaking() =>
            {
                let remaining = std::mem::take(&mut secured.remaining);
                **secured = Secured::start(Arc::clone(&secured.target), remaining)?;
                Ok(())
            }
            _ => Err(error),
        }
    }

    pub(crate) fn retry_watched(
        &mut self,
        poll: &mut Poll,
        ready: &mut ko_sys::event::Ready,
        error: io::Error,
    ) -> io::Result<()> {
        poll.unwatch(ready.token);
        self.retry(error)?;
        ready.token = poll.watch(self.fd(), self.interest(true, true));
        ready.read = false;
        ready.write = false;
        Ok(())
    }

    pub(crate) fn deadline(&self) -> Option<Instant> {
        match self {
            Self::Unix(_) => None,
            Self::Tls(secured) => secured.session.is_handshaking().then_some(secured.deadline),
        }
    }

    pub(crate) fn writable(&mut self) -> io::Result<()> {
        if let Self::Tls(secured) = self
            && !secured.connected
        {
            if let Some(error) = secured.socket.take_error()? {
                return Err(error);
            }
            secured.connected = true;
        }
        self.progress()
    }

    pub(crate) fn progress(&mut self) -> io::Result<()> {
        match self {
            Self::Unix(_) => Ok(()),
            Self::Tls(secured) => {
                if !secured.connected {
                    return Err(io::ErrorKind::WouldBlock.into());
                }
                secured.flush()
            }
        }
    }

    pub(crate) fn ready(&self) -> bool {
        match self {
            Self::Unix(_) => true,
            Self::Tls(secured) => secured.connected && !secured.session.is_handshaking(),
        }
    }

    pub(crate) fn host(&self) -> &str {
        match self {
            Self::Unix(_) => "localhost",
            Self::Tls(secured) => secured.target.host.as_str(),
        }
    }

    pub(crate) fn fd(&self) -> BorrowedFd<'_> {
        match self {
            Self::Unix(stream) => stream.as_fd(),
            Self::Tls(secured) => secured.socket.as_fd(),
        }
    }

    pub(crate) fn buffered(&mut self, bytes: &mut [u8]) -> Option<io::Result<usize>> {
        match self {
            Self::Unix(_) => None,
            Self::Tls(secured) => Some(secured.session.reader().read(bytes)),
        }
    }

    pub(crate) fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        match self {
            Self::Unix(stream) => fd::read(stream.as_fd(), bytes),
            Self::Tls(secured) => loop {
                match secured.session.reader().read(bytes) {
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                    read => return read,
                }
                let count = secured.session.read_tls(&mut secured.socket)?;
                secured.received |= count > 0;
                secured.session.process_new_packets().map_err(failure)?;
                secured.flush()?;
                if count == 0 {
                    return secured.session.reader().read(bytes);
                }
            },
        }
    }

    pub(crate) fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.progress()?;
        match self {
            Self::Unix(stream) => fd::write(stream.as_fd(), bytes),
            Self::Tls(secured) => {
                if secured.session.is_handshaking() || secured.session.wants_write() {
                    return Err(io::ErrorKind::WouldBlock.into());
                }
                let count = secured.session.writer().write(bytes)?;
                secured.pending_plaintext = secured.pending_plaintext.saturating_add(count as u64);
                secured.flush()?;
                Ok(count)
            }
        }
    }

    pub(crate) fn read_ready(
        &mut self,
        poll: &mut Poll,
        token: Token,
        bytes: &mut [u8],
        reads: &mut Reads,
    ) -> io::Result<Option<Read>> {
        match self {
            Self::Unix(stream) => poll.read(token, stream.as_fd(), bytes, reads),
            Self::Tls(secured) => loop {
                if !secured.connected {
                    return Ok(None);
                }
                match secured.session.reader().read(bytes) {
                    Ok(0) => return Ok(Some(Read::End)),
                    Ok(count) => return Ok(Some(Read::Data(count))),
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                    Err(error) => return Err(error),
                }
                let mut source = PollRead::new(poll, token, secured.socket.as_fd(), reads);
                let count = match secured.session.read_tls(&mut source) {
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => return Ok(None),
                    count => count?,
                };
                secured.received |= count > 0;
                secured.session.process_new_packets().map_err(failure)?;
                secured.flush()?;
                if count == 0 {
                    return secured.session.reader().read(bytes).map(|count| {
                        Some(if count == 0 {
                            Read::End
                        } else {
                            Read::Data(count)
                        })
                    });
                }
            },
        }
    }

    pub(crate) fn flush(&mut self, queue: &mut Queue) -> io::Result<()> {
        queue.flush_with(|bytes| self.write(bytes))?;
        match self.progress() {
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => Ok(()),
            result => result,
        }
    }

    pub(crate) fn take_read(&mut self) -> bool {
        match self {
            Self::Unix(_) => false,
            Self::Tls(secured) => std::mem::take(&mut secured.received),
        }
    }

    pub(crate) fn pending_write(&self) -> bool {
        match self {
            Self::Unix(_) => false,
            Self::Tls(secured) => !secured.connected || secured.session.wants_write(),
        }
    }

    pub(crate) fn flushed(&self, accepted: u64) -> u64 {
        match self {
            Self::Unix(_) => accepted,
            Self::Tls(secured) => accepted.saturating_sub(secured.pending_plaintext),
        }
    }

    pub(crate) fn interest(&self, read: bool, write: bool) -> Interest {
        Interest::of(read, (write && self.ready()) || self.pending_write())
    }

    pub(crate) fn set_nonblocking(&mut self, nonblocking: bool) -> io::Result<()> {
        match self {
            Self::Unix(stream) => stream.set_nonblocking(nonblocking),
            Self::Tls(secured) => secured.socket.set_nonblocking(true),
        }
    }
}

pub(crate) fn terminal(error: &io::Error) -> bool {
    error.get_ref().is_some_and(|error| error.is::<Failure>())
}
