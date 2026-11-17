use super::stream::Stream;
use crate::endpoint::Resolved;
use std::io::{self, Read};
#[cfg(test)]
use std::os::fd::AsFd;
#[cfg(test)]
use std::os::unix::net::UnixStream;
use std::sync::Arc;
use std::time::Instant;

use ko_sys::event::{Poll, Read as PollData, Reads, Ready, Token, Wake};
use ko_sys::fd::Queue;
use ko_wire::api::Route;
use ko_wire::http::{self, Response};
use ko_wire::ids::ClientId;
use ko_wire::ws::upgrade_request;

use crate::wire::Link;
use ko_wire::protocol;

struct Buffered<'a> {
    bytes: &'a [u8],
    eof: bool,
}
impl Read for Buffered<'_> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        if !self.bytes.is_empty() || self.eof {
            self.bytes.read(buffer)
        } else {
            Err(io::ErrorKind::WouldBlock.into())
        }
    }
}

#[derive(Debug)]
pub struct Connecting {
    stream: Stream,
    request: Queue,
    response: Vec<u8>,
    key: String,
    cancel: Option<Arc<Wake>>,
    deadline: Instant,
}

#[derive(Debug)]
pub enum UpgradeStep {
    Pending(Connecting),
    Open(Box<Link>),
    Refused(Response),
}

impl Connecting {
    pub fn start(
        socket: &Resolved,
        client: ClientId,
        route: &Route,
        cancel: Option<Arc<Wake>>,
    ) -> io::Result<Connecting> {
        let stream = Stream::start(socket)?;
        let (method, target) = route.to_request();
        let (request, key) = upgrade_request(stream.host(), method, &target, Some(client), &[]);
        let mut queued = Queue::default();
        queued.bytes = request;
        Ok(Connecting {
            stream,
            request: queued,
            response: Vec::new(),
            key,
            cancel,
            deadline: Instant::now() + super::READ_TIMEOUT,
        })
    }

    pub fn watch(&self, poll: &mut Poll) -> Token {
        poll.watch(self.stream.fd(), self.stream.interest(true, true))
    }

    #[cfg(all(target_vendor = "apple", feature = "tls"))]
    pub(crate) fn deadline(&self) -> Instant {
        self.stream
            .deadline()
            .map_or(self.deadline, |deadline| deadline.min(self.deadline))
    }

    fn retry(&mut self, poll: &mut Poll, ready: &mut Ready, error: io::Error) -> io::Result<()> {
        if self.request.written() != 0 {
            return Err(error);
        }
        self.stream.retry_watched(poll, ready, error)
    }

    pub fn advance(mut self, poll: &mut Poll, ready: &mut Ready) -> io::Result<UpgradeStep> {
        if self.cancel.as_ref().is_some_and(|cancel| cancel.is_set()) {
            return Err(crate::connect::cancelled_error());
        }
        let now = Instant::now();
        if now >= self.deadline {
            return Err(io::ErrorKind::TimedOut.into());
        }
        if self
            .stream
            .deadline()
            .is_some_and(|deadline| now >= deadline)
        {
            self.retry(poll, ready, io::ErrorKind::TimedOut.into())?;
            return Ok(UpgradeStep::Pending(self));
        }
        if ready.write
            && let Err(error) = self
                .stream
                .writable()
                .and_then(|()| self.stream.flush(&mut self.request))
        {
            self.retry(poll, ready, error)?;
            return Ok(UpgradeStep::Pending(self));
        }
        let mut reads = Reads::new();
        if ready.read || ready.write {
            let mut eof = false;
            loop {
                let mut buffer = [0; 4096];
                let read = self
                    .stream
                    .read_ready(poll, ready.token, &mut buffer, &mut reads);
                let count = match read {
                    Err(error) => {
                        self.retry(poll, ready, error)?;
                        return Ok(UpgradeStep::Pending(self));
                    }
                    Ok(read) => match read {
                        Some(PollData::End) => {
                            eof = true;
                            0
                        }
                        Some(PollData::Data(count)) => count,
                        None => break,
                    },
                };
                self.response.extend_from_slice(&buffer[..count]);
                match http::read_upgrade(&mut Buffered {
                    bytes: &self.response,
                    eof,
                }) {
                    Ok(upgrade) => {
                        self.stream.watch_interest(poll, ready.token, true, false);
                        let linked = Link::upgraded(
                            self.stream,
                            upgrade,
                            &self.key,
                            self.cancel,
                            Some(ready.token),
                            protocol::Upgrade::Control,
                        )?;
                        return Ok(match linked {
                            Ok(link) => UpgradeStep::Open(Box::new(link)),
                            Err(response) => UpgradeStep::Refused(response),
                        });
                    }
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                    Err(error) => return Err(error),
                }
                if eof {
                    return Err(io::ErrorKind::UnexpectedEof.into());
                }
            }
        }
        self.stream
            .flush_ready(poll, ready.token, &mut reads, &mut self.request)?;
        self.stream
            .watch_interest(poll, ready.token, true, !self.request.is_empty());
        Ok(UpgradeStep::Pending(self))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wire::{Next, buffered};
    use ko_sys::fd;
    use std::io::Write;
    use std::time::Instant;

    #[test]
    fn an_upgrade_keeps_a_partial_head_and_delivers_the_frames_after_it() {
        let (ours, mut server) = UnixStream::pair().unwrap();
        fd::set_nonblocking(ours.as_fd()).unwrap();
        let connecting = Connecting {
            stream: Stream::Unix(ours),
            request: Queue::default(),
            response: Vec::new(),
            key: "test-key".to_owned(),
            cancel: None,
            deadline: Instant::now() + super::super::READ_TIMEOUT,
        };
        let mut poll = Poll::new();
        let token = connecting.watch(&mut poll);
        server
            .write_all(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: web")
            .unwrap();
        let UpgradeStep::Pending(connecting) =
            connecting.advance(&mut poll, &mut buffered(token)).unwrap()
        else {
            panic!("a partial head completed");
        };
        let accept = tungstenite::handshake::derive_accept_key(b"test-key");
        server
            .write_all(
                format!("socket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n")
                    .as_bytes(),
            )
            .unwrap();
        server.write_all(b"\x81\x0dafter-upgrade").unwrap();
        let UpgradeStep::Open(mut link) =
            connecting.advance(&mut poll, &mut buffered(token)).unwrap()
        else {
            panic!("the complete head did not open");
        };
        assert_eq!(
            link.next(&mut poll, Instant::now()).unwrap(),
            Next::Text("after-upgrade".into())
        );
    }

    #[test]
    fn an_unterminated_upgrade_head_has_a_bound() {
        let (ours, mut server) = UnixStream::pair().unwrap();
        fd::set_nonblocking(ours.as_fd()).unwrap();
        let mut connecting = Connecting {
            stream: Stream::Unix(ours),
            request: Queue::default(),
            response: Vec::new(),
            key: "test-key".to_owned(),
            cancel: None,
            deadline: Instant::now() + super::super::READ_TIMEOUT,
        };
        let mut poll = Poll::new();
        let token = connecting.watch(&mut poll);
        server
            .write_all(b"HTTP/1.1 101 Switching Protocols\r\nX: ")
            .unwrap();
        let mut rejected = None;
        for _ in 0..17 {
            server.write_all(&[b'x'; 4096]).unwrap();
            match connecting.advance(&mut poll, &mut buffered(token)) {
                Ok(UpgradeStep::Pending(pending)) => connecting = pending,
                Ok(UpgradeStep::Open(_)) => panic!("an unterminated head opened"),
                Ok(UpgradeStep::Refused(_)) => panic!("an unterminated head was refused"),
                Err(error) => {
                    rejected = Some(error.kind());
                    break;
                }
            }
        }
        assert_eq!(rejected, Some(io::ErrorKind::InvalidData));
    }
}
