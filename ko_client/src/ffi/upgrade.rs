use std::io::{self, Read};
use std::os::fd::AsFd;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::sync::Arc;

use ko_server::api::Route;
use ko_server::http;
use ko_server::ids::ClientId;
use ko_server::ws::{refused, upgrade_request};
use ko_sys::event::{Interest, Poll, PollRead, Reads, Ready, Token, Wake};
use ko_sys::fd::Queue;

use crate::wire::Link;

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
pub(crate) struct Connecting {
    stream: UnixStream,
    request: Queue,
    response: Vec<u8>,
    key: String,
    cancel: Arc<Wake>,
}

#[derive(Debug)]
pub(crate) enum UpgradeStep {
    Pending(Connecting),
    Open(Box<Link>),
}

impl Connecting {
    pub(crate) fn start(
        socket: &Path,
        client: ClientId,
        route: &Route,
        cancel: Arc<Wake>,
    ) -> io::Result<Connecting> {
        let stream = UnixStream::from(ko_sys::sock::connect_nonblocking(socket)?);
        let (method, target) = route.to_request();
        let (request, key) = upgrade_request(method, &target, Some(client), &[]);
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

    pub(crate) fn watch(&self, poll: &mut Poll) -> Token {
        poll.watch(self.stream.as_fd(), Interest::of(true, true))
    }

    pub(crate) fn advance(mut self, poll: &mut Poll, ready: Ready) -> io::Result<UpgradeStep> {
        if ready.write {
            self.request.flush(self.stream.as_fd())?;
        }
        poll.interest(ready.token, Interest::of(true, !self.request.is_empty()));
        if !ready.read {
            return Ok(UpgradeStep::Pending(self));
        }
        let mut reads = Reads::new();
        let mut source = PollRead::new(poll, ready.token, self.stream.as_fd(), &mut reads);
        let mut eof = false;
        loop {
            let mut buffer = [0; 4096];
            let count = match source.read(&mut buffer) {
                Ok(0) => {
                    eof = true;
                    0
                }
                Ok(count) => count,
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                Err(error) => return Err(error),
            };
            self.response.extend_from_slice(&buffer[..count]);
            match http::read_upgrade(&mut Buffered {
                bytes: &self.response,
                eof,
            }) {
                Ok(upgrade) => {
                    let link = Link::upgraded(
                        self.stream,
                        upgrade,
                        &self.key,
                        Some(self.cancel),
                        Some(ready.token),
                    )?
                    .map_err(|response| refused(&response))?;
                    return Ok(UpgradeStep::Open(Box::new(link)));
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
            stream: ours,
            request: Queue::default(),
            response: Vec::new(),
            key: "test-key".to_owned(),
            cancel: Arc::new(Wake::new().unwrap()),
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
            stream: ours,
            request: Queue::default(),
            response: Vec::new(),
            key: "test-key".to_owned(),
            cancel: Arc::new(Wake::new().unwrap()),
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
                Err(error) => {
                    rejected = Some(error.kind());
                    break;
                }
            }
        }
        assert_eq!(rejected, Some(io::ErrorKind::InvalidData));
    }
}
