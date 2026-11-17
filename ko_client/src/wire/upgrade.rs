use super::stream::Stream;
use crate::endpoint::Endpoint;
use std::io::{self, Read};
#[cfg(test)]
use std::os::fd::AsFd;
use std::os::unix::net::UnixStream;
use std::sync::Arc;

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
}

#[derive(Debug)]
pub enum UpgradeStep {
    Pending(Connecting),
    Open(Box<Link>),
    Refused(Response),
}

impl Connecting {
    pub fn start(
        socket: &Endpoint,
        client: ClientId,
        route: &Route,
        cancel: Option<Arc<Wake>>,
    ) -> io::Result<Connecting> {
        let Endpoint::Unix(socket) = socket;
        let stream = Stream::Unix(UnixStream::from(ko_sys::sock::connect_nonblocking(socket)?));
        let (method, target) = route.to_request();
        let (request, key) = upgrade_request("localhost", method, &target, Some(client), &[]);
        let mut queued = Queue::default();
        queued.bytes = request;
        Ok(Connecting {
            stream,
            request: queued,
            response: Vec::new(),
            key,
            cancel,
        })
    }

    pub fn watch(&self, poll: &mut Poll) -> Token {
        poll.watch(self.stream.fd(), self.stream.interest(true, true))
    }

    pub fn advance(mut self, poll: &mut Poll, ready: Ready) -> io::Result<UpgradeStep> {
        if ready.write {
            self.stream.flush(&mut self.request)?;
        }
        poll.interest(
            ready.token,
            self.stream.interest(true, !self.request.is_empty()),
        );
        if !ready.read {
            return Ok(UpgradeStep::Pending(self));
        }
        let mut reads = Reads::new();

        let mut eof = false;
        loop {
            let mut buffer = [0; 4096];
            let count = match self
                .stream
                .read_ready(poll, ready.token, &mut buffer, &mut reads)?
            {
                Some(PollData::End) => {
                    eof = true;
                    0
                }
                Some(PollData::Data(count)) => count,
                None => break,
            };
            self.response.extend_from_slice(&buffer[..count]);
            match http::read_upgrade(&mut Buffered {
                bytes: &self.response,
                eof,
            }) {
                Ok(upgrade) => {
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
        };
        let mut poll = Poll::new();
        let token = connecting.watch(&mut poll);
        server
            .write_all(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: web")
            .unwrap();
        let UpgradeStep::Pending(connecting) =
            connecting.advance(&mut poll, buffered(token)).unwrap()
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
        let UpgradeStep::Open(mut link) = connecting.advance(&mut poll, buffered(token)).unwrap()
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
        };
        let mut poll = Poll::new();
        let token = connecting.watch(&mut poll);
        server
            .write_all(b"HTTP/1.1 101 Switching Protocols\r\nX: ")
            .unwrap();
        let mut rejected = None;
        for _ in 0..17 {
            server.write_all(&[b'x'; 4096]).unwrap();
            match connecting.advance(&mut poll, buffered(token)) {
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
