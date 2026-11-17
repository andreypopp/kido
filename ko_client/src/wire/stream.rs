use std::io;
use std::os::fd::{AsFd, BorrowedFd};
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};

use ko_sys::event::{Interest, Poll, Read, Reads, Token, Wake};
#[cfg(feature = "tls")]
use ko_sys::fd::Waited;
use ko_sys::fd::{self, Queue, Want};

use super::Limit;
use crate::endpoint::Resolved;

#[cfg(feature = "tls")]
mod tls;
#[cfg(feature = "tls")]
use tls::Secured;

#[derive(Debug, Clone, Copy)]
pub(crate) enum DirectEndpoint<'a> {
    Unix(&'a std::path::Path),
    #[cfg(feature = "tls")]
    Tls {
        target: &'a std::sync::Arc<crate::endpoint::Tls>,
        addresses: &'a [std::net::SocketAddr],
    },
}

impl<'a> TryFrom<&'a Resolved> for DirectEndpoint<'a> {
    type Error = io::Error;

    fn try_from(endpoint: &'a Resolved) -> io::Result<Self> {
        match endpoint {
            Resolved::Unix(path) => Ok(Self::Unix(path)),
            #[cfg(feature = "tls")]
            Resolved::Tls { target, addresses } => Ok(Self::Tls { target, addresses }),
            #[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
            Resolved::Quic(_) => Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "a direct endpoint is required",
            )),
        }
    }
}

#[derive(Debug)]
pub(crate) enum Direct {
    Unix(UnixStream),
    #[cfg(feature = "tls")]
    Tls(Box<Secured>),
}

impl Direct {
    pub(crate) fn start(endpoint: &Resolved) -> io::Result<Self> {
        match endpoint {
            #[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
            Resolved::Quic(_) => Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "QUIC requires a typed request",
            )),
            Resolved::Unix(path) => Ok(Self::Unix(UnixStream::from(
                ko_sys::sock::connect_nonblocking(path)?,
            ))),
            #[cfg(feature = "tls")]
            Resolved::Tls { target, addresses } => Ok(Self::Tls(Box::new(Secured::start(
                std::sync::Arc::clone(target),
                addresses.iter().copied().collect(),
            )?))),
        }
    }

    pub(crate) fn open(
        endpoint: DirectEndpoint<'_>,
        within: Limit,
        cancel: Option<&Wake>,
    ) -> io::Result<Self> {
        match endpoint {
            DirectEndpoint::Unix(path) => {
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
            #[cfg(feature = "tls")]
            DirectEndpoint::Tls { target, addresses } => {
                let mut stream = Self::Tls(Box::new(Secured::start(
                    std::sync::Arc::clone(target),
                    addresses.iter().copied().collect(),
                )?));
                stream.finish_open(within, cancel)?;
                Ok(stream)
            }
        }
    }

    #[cfg(feature = "tls")]
    fn finish_open(&mut self, within: Limit, cancel: Option<&Wake>) -> io::Result<()> {
        let within = match within {
            Limit::Idle(within) => Limit::Deadline(Instant::now() + within),
            deadline => deadline,
        };
        loop {
            let _ = within.remaining()?;
            if let Err(error) = self.progress() {
                self.retry(error)?;
                continue;
            }
            if self.ready() {
                return Ok(());
            }
            let remaining = self
                .deadline()
                .unwrap_or_else(Instant::now)
                .saturating_duration_since(Instant::now())
                .min(within.remaining()?);
            if remaining.is_zero() {
                self.retry(io::ErrorKind::TimedOut.into())?;
                continue;
            }
            let want = self.wait(Want::Read);
            match fd::wait(self.fd(), want, cancel.map(Wake::fd), Some(remaining))? {
                Waited::Cancelled => return Err(crate::connect::cancelled_error()),
                Waited::TimedOut => self.retry(io::ErrorKind::TimedOut.into())?,
                Waited::Ready => {
                    let result = match want {
                        Want::Write => self.writable(),
                        Want::Read => {
                            let Self::Tls(secured) = &mut *self else {
                                return Err(io::Error::other("TLS dial changed transport"));
                            };
                            secured.receive().and_then(|()| secured.progress())
                        }
                    };
                    if let Err(error) = result {
                        self.retry(error)?;
                    }
                }
            }
        }
    }

    fn retry(&mut self, error: io::Error) -> io::Result<()> {
        match self {
            #[cfg(feature = "tls")]
            Self::Tls(secured)
                if !terminal(&error) && !secured.remaining.is_empty() && !secured.ready() =>
            {
                let remaining = std::mem::take(&mut secured.remaining);
                **secured = Secured::start(std::sync::Arc::clone(&secured.target), remaining)?;
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
        self.retry(error)?;
        poll.retarget(ready.token, self.fd(), self.interest(true, true));
        ready.read = false;
        ready.write = false;
        Ok(())
    }

    pub(crate) fn deadline(&self) -> Option<Instant> {
        match self {
            Self::Unix(_) => None,
            #[cfg(feature = "tls")]
            Self::Tls(secured) => (!secured.ready()).then_some(secured.deadline),
        }
    }
    pub(crate) fn writable(&mut self) -> io::Result<()> {
        match self {
            Self::Unix(_) => Ok(()),
            #[cfg(feature = "tls")]
            Self::Tls(secured) => secured.writable(),
        }
    }
    fn progress(&mut self) -> io::Result<()> {
        match self {
            Self::Unix(_) => Ok(()),
            #[cfg(feature = "tls")]
            Self::Tls(secured) => secured.progress(),
        }
    }
    #[cfg(feature = "tls")]
    fn ready(&self) -> bool {
        match self {
            Self::Unix(_) => true,
            #[cfg(feature = "tls")]
            Self::Tls(secured) => secured.ready(),
        }
    }
    pub(crate) fn host(&self) -> &str {
        match self {
            Self::Unix(_) => "localhost",
            #[cfg(feature = "tls")]
            Self::Tls(secured) => secured.target.host.as_str(),
        }
    }
    pub(crate) fn fd(&self) -> BorrowedFd<'_> {
        match self {
            Self::Unix(stream) => stream.as_fd(),
            #[cfg(feature = "tls")]
            Self::Tls(secured) => secured.fd(),
        }
    }
    fn buffered(&mut self, bytes: &mut [u8]) -> Option<io::Result<usize>> {
        match self {
            Self::Unix(_) => {
                let _ = bytes;
                None
            }
            #[cfg(feature = "tls")]
            Self::Tls(secured) => Some(secured.buffered(bytes)),
        }
    }
    fn receive(&mut self) -> io::Result<()> {
        match self {
            Self::Unix(_) => Ok(()),
            #[cfg(feature = "tls")]
            Self::Tls(secured) => secured.receive(),
        }
    }

    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        match self {
            Self::Unix(stream) => fd::read(stream.as_fd(), bytes),
            #[cfg(feature = "tls")]
            Self::Tls(secured) => loop {
                match secured.buffered(bytes) {
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                    result => return result,
                }
                secured.receive()?;
            },
        }
    }
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.progress()?;
        match self {
            Self::Unix(stream) => fd::write(stream.as_fd(), bytes),
            #[cfg(feature = "tls")]
            Self::Tls(secured) => secured.write(bytes),
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
            #[cfg(feature = "tls")]
            Self::Tls(secured) => secured.read_ready(poll, token, bytes, reads),
        }
    }
    fn flush(&mut self, queue: &mut Queue) -> io::Result<()> {
        queue.flush_with(|bytes| self.write(bytes))?;
        self.progress()
    }
    pub(crate) fn flush_ready(
        &mut self,
        poll: &mut Poll,
        token: Token,
        reads: &mut Reads,
        queue: &mut Queue,
    ) -> io::Result<()> {
        match self {
            Self::Unix(_) => {
                let _ = (poll, token, reads);
                self.flush(queue)
            }
            #[cfg(feature = "tls")]
            Self::Tls(secured) => secured.flush_ready(poll, token, reads, queue),
        }
    }

    pub(crate) fn take_read(&mut self) -> bool {
        match self {
            Self::Unix(_) => false,
            #[cfg(feature = "tls")]
            Self::Tls(secured) => std::mem::take(&mut secured.received),
        }
    }

    pub(crate) fn pending_write(&self) -> bool {
        match self {
            Self::Unix(_) => false,
            #[cfg(feature = "tls")]
            Self::Tls(secured) => secured.pending_write(),
        }
    }
    fn pending_read(&self) -> bool {
        match self {
            Self::Unix(_) => false,
            #[cfg(feature = "tls")]
            Self::Tls(secured) => !secured.plaintext.is_empty(),
        }
    }
    fn wait(&self, fallback: Want) -> Want {
        match self {
            Self::Unix(_) => fallback,
            #[cfg(feature = "tls")]
            Self::Tls(secured) => secured.wait(fallback),
        }
    }
    pub(crate) fn interest(&self, read: bool, write: bool) -> Interest {
        match self {
            Self::Unix(_) => Interest::of(read, write),
            #[cfg(feature = "tls")]
            Self::Tls(secured) => secured.interest(read, write),
        }
    }
    fn set_nonblocking(&mut self, nonblocking: bool) -> io::Result<()> {
        match self {
            Self::Unix(stream) => stream.set_nonblocking(nonblocking),
            #[cfg(feature = "tls")]
            Self::Tls(secured) => secured.socket().set_nonblocking(true),
        }
    }
}

pub(crate) fn terminal(error: &io::Error) -> bool {
    #[cfg(feature = "tls")]
    {
        error
            .get_ref()
            .is_some_and(|error| error.is::<crate::endpoint::tls::Failure>())
    }
    #[cfg(not(feature = "tls"))]
    {
        let _ = error;
        false
    }
}

#[derive(Debug)]
pub(crate) enum Stream {
    Direct(Direct),
    #[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
    Quic(super::quic::h3::StreamHandle),
}
impl Stream {
    pub(crate) fn open(
        endpoint: &Resolved,
        within: Limit,
        cancel: Option<&Wake>,
    ) -> io::Result<Self> {
        Direct::open(endpoint.try_into()?, within, cancel).map(Self::Direct)
    }
    pub(crate) fn progress(&mut self) -> io::Result<()> {
        match self {
            Self::Direct(stream) => stream.progress(),
            #[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
            Self::Quic(handle) => handle.progress(),
        }
    }
    pub(crate) fn host(&self) -> &str {
        match self {
            Self::Direct(stream) => stream.host(),
            #[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
            Self::Quic(handle) => handle.host(),
        }
    }
    pub(crate) fn fd(&self) -> BorrowedFd<'_> {
        match self {
            Self::Direct(stream) => stream.fd(),
            #[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
            Self::Quic(handle) => handle.fd(),
        }
    }
    pub(crate) fn buffered(&mut self, bytes: &mut [u8]) -> Option<io::Result<usize>> {
        match self {
            Self::Direct(stream) => stream.buffered(bytes),
            #[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
            Self::Quic(handle) => Some(handle.read(bytes)),
        }
    }
    pub(crate) fn receive(&mut self) -> io::Result<()> {
        match self {
            Self::Direct(stream) => stream.receive(),
            #[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
            Self::Quic(handle) => handle.progress(),
        }
    }
    pub(crate) fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        match self {
            Self::Direct(stream) => stream.read(bytes),
            #[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
            Self::Quic(handle) => handle.read(bytes),
        }
    }
    pub(crate) fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        match self {
            Self::Direct(stream) => stream.write(bytes),
            #[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
            Self::Quic(handle) => handle.write(bytes),
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
            Self::Direct(stream) => stream.read_ready(poll, token, bytes, reads),
            #[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
            Self::Quic(handle) => handle.read_ready(bytes),
        }
    }
    pub(crate) fn flush(&mut self, queue: &mut Queue) -> io::Result<()> {
        match self {
            Self::Direct(stream) => stream.flush(queue),
            #[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
            Self::Quic(handle) => queue
                .flush_with(|bytes| handle.write(bytes))
                .and_then(|()| handle.progress()),
        }
    }
    pub(crate) fn flush_ready(
        &mut self,
        poll: &mut Poll,
        token: Token,
        reads: &mut Reads,
        queue: &mut Queue,
    ) -> io::Result<()> {
        match self {
            Self::Direct(stream) => stream.flush_ready(poll, token, reads, queue),
            #[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
            Self::Quic(handle) => queue
                .flush_with(|bytes| handle.write(bytes))
                .and_then(|()| handle.progress()),
        }
    }
    pub(crate) fn take_read(&mut self) -> bool {
        match self {
            Self::Direct(stream) => stream.take_read(),
            #[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
            Self::Quic(handle) => handle.take_read(),
        }
    }
    pub(crate) fn pending_write(&self) -> bool {
        match self {
            Self::Direct(stream) => stream.pending_write(),
            #[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
            Self::Quic(handle) => handle.pending_write(),
        }
    }
    pub(crate) fn pending_read(&self) -> bool {
        match self {
            Self::Direct(stream) => stream.pending_read(),
            #[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
            Self::Quic(handle) => handle.pending_read(),
        }
    }
    pub(crate) fn wait(&self, fallback: Want) -> Want {
        match self {
            Self::Direct(stream) => stream.wait(fallback),
            #[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
            Self::Quic(handle) => {
                handle.interest(match fallback {
                    Want::Read => Interest::Read,
                    Want::Write => Interest::Write,
                });
                Want::Read
            }
        }
    }
    pub(crate) fn interest(&self, read: bool, write: bool) -> Interest {
        match self {
            Self::Direct(stream) => stream.interest(read, write),
            #[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
            Self::Quic(handle) => {
                handle.interest(Interest::of(read, write));
                if read || write {
                    Interest::Read
                } else {
                    Interest::Idle
                }
            }
        }
    }
    pub(crate) fn set_nonblocking(&mut self, nonblocking: bool) -> io::Result<()> {
        match self {
            Self::Direct(stream) => stream.set_nonblocking(nonblocking),
            #[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
            Self::Quic(handle) => {
                let _ = handle;
                Ok(())
            }
        }
    }
    pub(crate) fn begin_turn(&mut self) {
        #[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
        if let Self::Quic(handle) = self {
            handle.begin_turn();
        }
    }
    pub(crate) fn watch_interest(&self, poll: &mut Poll, token: Token, read: bool, write: bool) {
        poll.retarget(token, self.fd(), self.interest(read, write));
    }
}
