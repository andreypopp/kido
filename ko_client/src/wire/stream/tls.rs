use std::collections::VecDeque;
use std::io::{self, Read as _};
use std::net::{SocketAddr, TcpStream};
use std::os::fd::{AsFd, BorrowedFd};
use std::sync::Arc;
use std::time::{Duration, Instant};

use boring::ssl::{Error, ErrorCode, SslStream};
#[cfg(target_vendor = "apple")]
use ko_sys::event::Wake;
use ko_sys::event::{Interest, Poll, PollRead, Read, Reads, Token};
use ko_sys::fd::Want;

#[cfg(all(test, target_vendor = "apple"))]
mod tests;
use crate::endpoint::Tls;
use crate::endpoint::tls::{self, Connection, Failure};

#[derive(Debug)]
struct Transport {
    socket: TcpStream,
    input: VecDeque<u8>,
    eof: bool,
}

impl io::Read for Transport {
    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        if self.input.is_empty() && !self.eof && !bytes.is_empty() {
            return Err(io::ErrorKind::WouldBlock.into());
        }
        self.input.read(bytes)
    }
}
impl io::Write for Transport {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.socket.write(bytes)
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[derive(Debug, Clone, Copy)]
enum Wait {
    Socket(Want),
    #[cfg(target_vendor = "apple")]
    Trust,
}
#[derive(Debug)]
enum Dial {
    Connecting,
    Handshake(Wait),
    Open,
}

#[derive(Debug)]
pub(crate) struct Secured {
    stream: SslStream<Transport>,
    pub(super) target: Arc<Tls>,
    pub(super) remaining: VecDeque<SocketAddr>,
    pub(super) deadline: Instant,
    dial: Dial,
    read_wait: Option<Want>,
    #[cfg(test)]
    read_retry: Option<Want>,
    write_wait: Option<(Want, usize)>,
    pub(super) plaintext: VecDeque<u8>,
    #[cfg(target_vendor = "apple")]
    wake: Arc<Wake>,
    pub(super) received: bool,
}

impl Secured {
    pub(super) fn start(target: Arc<Tls>, mut remaining: VecDeque<SocketAddr>) -> io::Result<Self> {
        let mut last = io::Error::from(io::ErrorKind::NotFound);
        while let Some(address) = remaining.pop_front() {
            match ko_sys::sock::connect_tcp(address) {
                Ok(socket) => {
                    let mut ssl = target
                        .connector
                        .configure()
                        .and_then(|config| config.into_ssl(target.host.as_str()))
                        .map_err(io::Error::other)?;
                    let connection = Connection::new(target.host.as_str())?;
                    #[cfg(target_vendor = "apple")]
                    let wake = connection.wake();
                    ssl.set_ex_data(tls::index().map_err(io::Error::other)?, connection);
                    let stream = SslStream::new(
                        ssl,
                        Transport {
                            socket,
                            input: VecDeque::new(),
                            eof: false,
                        },
                    )
                    .map_err(io::Error::other)?;
                    return Ok(Self {
                        stream,
                        target,
                        remaining,
                        deadline: Instant::now() + Duration::from_secs(5),
                        dial: Dial::Connecting,
                        read_wait: None,
                        #[cfg(test)]
                        read_retry: None,
                        write_wait: None,
                        plaintext: VecDeque::new(),
                        #[cfg(target_vendor = "apple")]
                        wake,
                        received: false,
                    });
                }
                Err(error) => last = error,
            }
        }
        Err(last)
    }
    pub(crate) fn socket(&self) -> &TcpStream {
        &self.stream.get_ref().socket
    }
    pub(super) fn fd(&self) -> BorrowedFd<'_> {
        match self.dial {
            #[cfg(target_vendor = "apple")]
            Dial::Handshake(Wait::Trust) => self.wake.fd(),
            _ => self.socket().as_fd(),
        }
    }
    pub(super) fn ready(&self) -> bool {
        matches!(self.dial, Dial::Open)
    }
    fn error(&self, error: Error) -> io::Error {
        let connection = tls::index()
            .ok()
            .and_then(|index| self.stream.ssl().ex_data(index));
        let Some(connection) = connection else {
            return io::Error::other(Failure::Tls(error.to_string()));
        };
        if let Some(failure) = connection.failure(&error.to_string(), None) {
            return io::Error::other(failure);
        }
        if let Some(source) = error.io_error() {
            return source.raw_os_error().map_or_else(
                || io::Error::new(source.kind(), source.to_string()),
                io::Error::from_raw_os_error,
            );
        }
        if error.code() == ErrorCode::SYSCALL && self.stream.get_ref().eof {
            return io::ErrorKind::UnexpectedEof.into();
        }
        io::Error::other(Failure::Tls(error.to_string()))
    }
    fn pending(error: &Error) -> Option<Wait> {
        match error.code() {
            ErrorCode::WANT_READ => Some(Wait::Socket(Want::Read)),
            ErrorCode::WANT_WRITE => Some(Wait::Socket(Want::Write)),
            #[cfg(target_vendor = "apple")]
            ErrorCode::WANT_CERTIFICATE_VERIFY => Some(Wait::Trust),
            _ => None,
        }
    }
    pub(super) fn writable(&mut self) -> io::Result<()> {
        if matches!(self.dial, Dial::Connecting) {
            if let Some(error) = self.socket().take_error()? {
                return Err(error);
            }
            self.dial = Dial::Handshake(Wait::Socket(Want::Write));
        }
        self.progress()
    }
    pub(super) fn progress(&mut self) -> io::Result<()> {
        if matches!(self.dial, Dial::Handshake(_)) {
            #[cfg(target_vendor = "apple")]
            if matches!(self.dial, Dial::Handshake(Wait::Trust)) {
                self.wake.drain();
            }
            match self.stream.connect() {
                Ok(()) => self.dial = Dial::Open,
                Err(error) => match Self::pending(&error) {
                    Some(wait) => self.dial = Dial::Handshake(wait),
                    None => return Err(self.error(error)),
                },
            }
        }
        if self.ready() && matches!(self.read_wait, Some(Want::Write)) && self.plaintext.is_empty()
        {
            let mut bytes = [0; 16 << 10];
            match self.read_plaintext(&mut bytes) {
                Ok(count) => self.plaintext.extend(&bytes[..count]),
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                Err(error) => return Err(error),
            }
        }
        Ok(())
    }
    pub(super) fn wait(&self, fallback: Want) -> Want {
        match self.dial {
            Dial::Connecting => Want::Write,
            Dial::Handshake(Wait::Socket(want)) => want,
            #[cfg(target_vendor = "apple")]
            Dial::Handshake(Wait::Trust) => Want::Read,
            Dial::Open => self
                .write_wait
                .map(|(want, _)| want)
                .or(self.read_wait)
                .unwrap_or(fallback),
        }
    }
    pub(super) fn pending_write(&self) -> bool {
        !self.ready() || self.write_wait.is_some() || matches!(self.read_wait, Some(Want::Write))
    }
    pub(super) fn interest(&self, read: bool, write: bool) -> Interest {
        match self.dial {
            Dial::Connecting | Dial::Handshake(Wait::Socket(Want::Write)) => Interest::Write,
            Dial::Handshake(_) => Interest::Read,
            Dial::Open => Interest::of(
                read || matches!(self.write_wait, Some((Want::Read, _))),
                matches!(self.read_wait, Some(Want::Write))
                    || match self.write_wait {
                        Some((Want::Write, _)) => true,
                        Some((Want::Read, _)) => false,
                        None => write,
                    },
            ),
        }
    }
    pub(super) fn buffered(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        self.progress()?;
        if !self.ready() {
            return Err(io::ErrorKind::WouldBlock.into());
        }
        if !self.plaintext.is_empty() {
            return self.plaintext.read(bytes);
        }
        self.read_plaintext(bytes)
    }
    fn read_plaintext(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        #[cfg(test)]
        if let Some(want) = self.read_retry.take() {
            self.read_wait = Some(want);
            return Err(io::ErrorKind::WouldBlock.into());
        }
        match self.stream.ssl_read(bytes) {
            Ok(count) => {
                self.read_wait = None;
                Ok(count)
            }
            Err(error) if error.code() == ErrorCode::ZERO_RETURN => {
                self.read_wait = None;
                Ok(0)
            }
            Err(error) => match Self::pending(&error) {
                Some(Wait::Socket(want)) => {
                    self.read_wait = Some(want);
                    Err(io::ErrorKind::WouldBlock.into())
                }
                _ => Err(self.error(error)),
            },
        }
    }
    pub(super) fn receive(&mut self) -> io::Result<()> {
        #[cfg(target_vendor = "apple")]
        if matches!(self.dial, Dial::Handshake(Wait::Trust)) {
            return self.progress();
        }
        let mut bytes = [0; 16 << 10];
        let count = self.stream.get_mut().socket.read(&mut bytes)?;
        self.feed(&bytes[..count])?;
        self.progress()
    }
    fn feed(&mut self, bytes: &[u8]) -> io::Result<()> {
        if self
            .stream
            .get_ref()
            .input
            .len()
            .saturating_add(bytes.len())
            > 64 << 10
        {
            return Err(io::Error::other(Failure::Tls(
                "TLS ciphertext buffer limit exceeded".to_owned(),
            )));
        }
        self.received |= !bytes.is_empty();
        self.stream.get_mut().eof |= bytes.is_empty();
        self.stream.get_mut().input.extend(bytes);
        Ok(())
    }
    pub(super) fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if !self.ready() {
            return Err(io::ErrorKind::WouldBlock.into());
        }
        let length = self
            .write_wait
            .map_or(bytes.len().min(16 << 10), |(_, length)| length);
        let bytes = bytes
            .get(..length)
            .ok_or_else(|| io::Error::other("TLS write retry changed length"))?;
        match self.stream.ssl_write(bytes) {
            Ok(count) => {
                self.write_wait = None;
                Ok(count)
            }
            Err(error) => match Self::pending(&error) {
                Some(Wait::Socket(want)) => {
                    self.write_wait = Some((want, length));
                    Err(io::ErrorKind::WouldBlock.into())
                }
                _ => Err(self.error(error)),
            },
        }
    }
    fn receive_ready(
        &mut self,
        poll: &mut Poll,
        token: Token,
        reads: &mut Reads,
    ) -> io::Result<bool> {
        #[cfg(target_vendor = "apple")]
        if matches!(self.dial, Dial::Handshake(Wait::Trust)) {
            self.progress()?;
            poll.retarget(
                token,
                self.fd(),
                self.interest(true, self.write_wait.is_some()),
            );
            return Ok(!matches!(self.dial, Dial::Handshake(Wait::Trust)));
        }
        poll.retarget(
            token,
            self.fd(),
            self.interest(true, self.write_wait.is_some()),
        );
        if matches!(
            self.dial,
            Dial::Connecting | Dial::Handshake(Wait::Socket(Want::Write))
        ) {
            return Ok(false);
        }
        let mut input = [0; 16 << 10];
        let mut source = PollRead::new(poll, token, self.socket().as_fd(), reads);
        let count = match source.read(&mut input) {
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => return Ok(false),
            result => result?,
        };
        self.feed(&input[..count])?;
        self.progress()?;
        poll.retarget(
            token,
            self.fd(),
            self.interest(true, self.write_wait.is_some()),
        );
        Ok(true)
    }

    pub(super) fn flush_ready(
        &mut self,
        poll: &mut Poll,
        token: Token,
        reads: &mut Reads,
        queue: &mut ko_sys::fd::Queue,
    ) -> io::Result<()> {
        loop {
            queue.flush_with(|bytes| self.write(bytes))?;
            self.progress()?;
            if !matches!(self.write_wait, Some((Want::Read, _)))
                || !self.receive_ready(poll, token, reads)?
            {
                return Ok(());
            }
        }
    }

    pub(super) fn read_ready(
        &mut self,
        poll: &mut Poll,
        token: Token,
        bytes: &mut [u8],
        reads: &mut Reads,
    ) -> io::Result<Option<Read>> {
        loop {
            match self.buffered(bytes) {
                Ok(0) => return Ok(Some(Read::End)),
                Ok(count) => return Ok(Some(Read::Data(count))),
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                Err(error) => return Err(error),
            }
            if (self.ready() && !matches!(self.read_wait, Some(Want::Read)))
                || !self.receive_ready(poll, token, reads)?
            {
                return Ok(None);
            }
        }
    }
}
