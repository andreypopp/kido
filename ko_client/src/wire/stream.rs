use std::io;
use std::os::fd::{AsFd, BorrowedFd};
use std::os::unix::net::UnixStream;

use ko_sys::event::{Interest, Poll, Read, Reads, Token};
use ko_sys::fd::{self, Queue};

#[derive(Debug)]
pub(crate) enum Stream {
    Unix(UnixStream),
}

impl Stream {
    pub(crate) fn fd(&self) -> BorrowedFd<'_> {
        match self {
            Self::Unix(stream) => stream.as_fd(),
        }
    }

    pub(crate) fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        fd::read(self.fd(), bytes)
    }

    pub(crate) fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        fd::write(self.fd(), bytes)
    }

    pub(crate) fn read_ready(
        &mut self,
        poll: &mut Poll,
        token: Token,
        bytes: &mut [u8],
        reads: &mut Reads,
    ) -> io::Result<Option<Read>> {
        poll.read(token, self.fd(), bytes, reads)
    }

    pub(crate) fn flush(&mut self, queue: &mut Queue) -> io::Result<()> {
        queue.flush(self.fd())
    }

    pub(crate) fn interest(&self, read: bool, write: bool) -> Interest {
        Interest::of(read, write)
    }

    pub(crate) fn set_nonblocking(&mut self, nonblocking: bool) -> io::Result<()> {
        match self {
            Self::Unix(stream) => stream.set_nonblocking(nonblocking),
        }
    }

    pub(crate) fn take_error(&mut self) -> io::Result<Option<io::Error>> {
        match self {
            Self::Unix(stream) => stream.take_error(),
        }
    }
}
