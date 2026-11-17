use std::io;
use std::os::fd::BorrowedFd;
use std::time::Instant;

#[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
use super::quic::h3::{StreamFailure, StreamHandle};
use super::{
    Caller, Limit,
    stream::{Direct, Stream},
};
use crate::endpoint::Resolved;
use ko_sys::event::{Interest, Poll, Read, Reads, Token};
use ko_sys::fd::Queue;
use ko_wire::http::{self, Response, response};
use ko_wire::protocol::{Method, RequestTarget};

#[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
#[derive(Debug)]
pub(crate) enum RequestHead {
    Http {
        method: Method,
        target: RequestTarget,
        headers: Vec<(String, String)>,
        length: usize,
    },
    WebSocket {
        target: RequestTarget,
        headers: Vec<(String, String)>,
    },
}
#[derive(Debug)]
pub(crate) enum Destination {
    Server {
        client: Option<ko_wire::ids::ClientId>,
        caller: Option<Caller>,
    },
    Program,
}
#[derive(Debug)]
pub(crate) enum Body<'a> {
    Complete(&'a [u8]),
    Streaming(&'a [u8]),
}
#[derive(Debug)]
pub(crate) enum RequestKind<'a> {
    Http {
        method: Method,
        target: RequestTarget,
        headers: Vec<(String, String)>,
        body: Body<'a>,
    },
    WebSocket {
        target: RequestTarget,
        headers: Vec<(String, String)>,
    },
}
#[derive(Debug)]
pub(crate) struct Request<'a> {
    pub(crate) kind: RequestKind<'a>,
    pub(crate) destination: Destination,
}
#[derive(Debug)]
enum Http1Reply {
    Http,
    WebSocket { key: String },
}
#[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
#[derive(Debug)]
enum Reply {
    Http,
    WebSocket,
}
#[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
#[derive(Debug)]
enum Phase {
    AwaitHead,
    Body { remaining: Option<usize> },
    Ended,
}
#[derive(Debug)]
enum Transport {
    Http1 {
        stream: Direct,
        reader: response::Reader,
        reply: Http1Reply,
        eof: bool,
    },
    #[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
    Http3 {
        handle: StreamHandle,
        reply: Reply,
        phase: Phase,
    },
}
impl Transport {
    fn fd(&self) -> BorrowedFd<'_> {
        match self {
            Self::Http1 { stream, .. } => stream.fd(),
            #[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
            Self::Http3 { handle, .. } => handle.fd(),
        }
    }
    fn interest(&self, read: bool, write: bool) -> Interest {
        match self {
            Self::Http1 { stream, .. } => stream.interest(read, write),
            #[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
            Self::Http3 { handle, .. } => {
                handle.interest(Interest::of(read, write));
                if read || write {
                    Interest::Read
                } else {
                    Interest::Idle
                }
            }
        }
    }
    fn pending_write(&self) -> bool {
        match self {
            Self::Http1 { stream, .. } => stream.pending_write(),
            #[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
            Self::Http3 { handle, .. } => handle.pending_write(),
        }
    }
}
#[derive(Debug)]
pub(crate) struct Exchange {
    transport: Transport,
    out: Queue,
    reads: Reads,
    token: Token,
    within: Limit,
    deadline: Instant,
}
impl Exchange {
    pub(crate) fn start(
        poll: &mut Poll,
        endpoint: &Resolved,
        request: Request<'_>,
        within: Limit,
    ) -> io::Result<Self> {
        let (client, identity) = match &request.destination {
            Destination::Server { client, caller } => (*client, super::identity(caller.as_ref())),
            Destination::Program => (None, Vec::new()),
        };
        #[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
        if let Resolved::Quic(access) = endpoint {
            let mut kind = request.kind;
            let (method, target, headers) = match &mut kind {
                RequestKind::Http {
                    method,
                    target,
                    headers,
                    ..
                } => (method.http(), target, headers),
                RequestKind::WebSocket { target, headers } => ("CONNECT", target, headers),
            };
            let policy = match request.destination {
                Destination::Server { .. } => http::ForwardIdentity::Remove,
                Destination::Program => http::ForwardIdentity::Pane,
            };
            let filtered: Vec<_> =
                http::forwarded(headers, http::ForwardLength::Replace, policy).collect();
            let mut fields = filtered;
            fields.extend(super::borrowed(&identity));
            *headers = match request.destination {
                Destination::Server { .. } => http::call_headers(method, target, client, &fields),
                Destination::Program => fields
                    .into_iter()
                    .map(|(name, value)| (name.to_owned(), value.to_owned()))
                    .collect(),
            };
            let (head, body, reply) = match kind {
                RequestKind::WebSocket {
                    target,
                    mut headers,
                } => {
                    headers.push(("sec-websocket-version".to_owned(), "13".to_owned()));
                    (
                        RequestHead::WebSocket { target, headers },
                        b"".as_slice(),
                        Reply::WebSocket,
                    )
                }
                RequestKind::Http {
                    method,
                    target,
                    headers,
                    body: Body::Complete(body),
                } => (
                    RequestHead::Http {
                        method,
                        target,
                        headers,
                        length: body.len(),
                    },
                    body,
                    Reply::Http,
                ),
                RequestKind::Http {
                    body: Body::Streaming(_),
                    ..
                } => {
                    return Err(io::Error::new(
                        io::ErrorKind::Unsupported,
                        "streamed program request over HTTP/3",
                    ));
                }
            };
            let handle = access.open(head)?;
            return Ok(Self::new(
                poll,
                Transport::Http3 {
                    handle,
                    reply,
                    phase: Phase::AwaitHead,
                },
                body.to_vec(),
                within,
            ));
        }
        let stream = Direct::start(endpoint)?;
        let (target, headers) = match &request.kind {
            RequestKind::Http {
                target, headers, ..
            }
            | RequestKind::WebSocket { target, headers } => (target, headers),
        };
        let mut fields: Vec<_> = headers
            .iter()
            .map(|(name, value)| (name.as_str(), value.as_str()))
            .collect();
        fields.extend(super::borrowed(&identity));
        let (bytes, reply) = match &request.kind {
            RequestKind::WebSocket { .. } => {
                let (bytes, key) =
                    ko_wire::ws::upgrade_request(stream.host(), "GET", target, client, &fields);
                (bytes, Http1Reply::WebSocket { key })
            }
            RequestKind::Http { method, body, .. } => {
                let body = match body {
                    Body::Complete(bytes) | Body::Streaming(bytes) => *bytes,
                };
                let bytes = match request.destination {
                    Destination::Server { .. } => {
                        http::call(stream.host(), method.http(), target, client, &fields, body)
                    }
                    Destination::Program => {
                        http::program_call(stream.host(), method.http(), target, &fields, body)
                    }
                };
                (bytes, Http1Reply::Http)
            }
        };
        Ok(Self::new(
            poll,
            Transport::Http1 {
                stream,
                reader: response::Reader::default(),
                reply,
                eof: false,
            },
            bytes,
            within,
        ))
    }
    fn new(poll: &mut Poll, transport: Transport, bytes: Vec<u8>, within: Limit) -> Self {
        let token = poll.watch(transport.fd(), transport.interest(true, true));
        let deadline = match within {
            Limit::Idle(within) => Instant::now() + within,
            Limit::Deadline(deadline) => deadline,
        };
        Self {
            transport,
            out: Queue::new(bytes),
            reads: Reads::new(),
            token,
            within,
            deadline,
        }
    }
    pub(crate) fn token(&self) -> Token {
        self.token
    }
    pub(crate) fn dispose(self, poll: &mut Poll) {
        poll.unwatch(self.token);
    }
    pub(crate) fn begin_turn(&mut self) {
        #[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
        if let Transport::Http3 { handle, .. } = &mut self.transport {
            handle.begin_turn();
        }
        self.reads = Reads::new();
    }
    pub(crate) fn started(&self) -> bool {
        match &self.transport {
            Transport::Http1 { reader, .. } => reader.started(),
            #[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
            Transport::Http3 { phase, .. } => !matches!(phase, Phase::AwaitHead),
        }
    }
    pub(crate) fn backed_up(&self) -> bool {
        self.out.backed_up(http::MAX_BODY) || self.transport.pending_write()
    }
    pub(crate) fn drained(&self) -> bool {
        self.out.is_empty() && !self.transport.pending_write()
    }
    #[cfg(all(target_vendor = "apple", feature = "tls"))]
    pub(crate) fn written(&self) -> u64 {
        self.out.written()
    }
    pub(crate) fn body(&mut self, bytes: &[u8]) -> io::Result<()> {
        match &self.transport {
            Transport::Http1 {
                reply: Http1Reply::WebSocket { .. },
                ..
            } => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "body for a WebSocket",
                ));
            }
            #[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
            Transport::Http3 {
                reply: Reply::WebSocket,
                ..
            } => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "body for a WebSocket",
                ));
            }
            _ => {}
        }
        self.out.extend(bytes);
        Ok(())
    }
    pub(crate) fn deadline(&self) -> Instant {
        let transport = match &self.transport {
            Transport::Http1 { stream, .. } => stream.deadline(),
            #[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
            Transport::Http3 { .. } => None,
        };
        transport.map_or(self.deadline, |deadline| deadline.min(self.deadline))
    }
    fn progress(&mut self) {
        if let Limit::Idle(within) = self.within {
            self.deadline = Instant::now() + within;
        }
    }
    fn retry(&mut self, poll: &mut Poll, error: io::Error) -> io::Result<()> {
        if self.out.written() != 0 {
            return Err(error);
        }
        match &mut self.transport {
            Transport::Http1 { stream, .. } => {
                let mut ready = super::buffered(self.token);
                stream.retry_watched(poll, &mut ready, error)?;
                self.token = ready.token;
                self.reads = Reads::new();
                Ok(())
            }
            #[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
            Transport::Http3 { .. } => Err(error),
        }
    }
    pub(crate) fn expired(&mut self, poll: &mut Poll, now: Instant) -> io::Result<bool> {
        if now >= self.deadline {
            return Ok(true);
        }
        if self.deadline() <= now {
            self.retry(poll, io::ErrorKind::TimedOut.into())?;
        }
        Ok(false)
    }
    pub(crate) fn interest(&self, poll: &mut Poll, read: bool) {
        let ended = match &self.transport {
            Transport::Http1 { eof, .. } => *eof,
            #[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
            Transport::Http3 { phase, .. } => matches!(phase, Phase::Ended),
        };
        poll.retarget(
            self.token,
            self.transport.fd(),
            self.transport
                .interest(read && !ended, !self.out.is_empty()),
        );
    }
    pub(crate) fn writable(&mut self, poll: &mut Poll) -> io::Result<()> {
        let result = match &mut self.transport {
            Transport::Http1 { stream, .. } => stream.writable(),
            #[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
            Transport::Http3 { handle, .. } => handle.progress(),
        };
        result.or_else(|error| self.retry(poll, error))
    }
    pub(crate) fn flush(&mut self, poll: &mut Poll) -> io::Result<()> {
        let before = self.out.written();
        let result = match &mut self.transport {
            Transport::Http1 { stream, .. } => {
                stream.flush_ready(poll, self.token, &mut self.reads, &mut self.out)
            }
            #[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
            Transport::Http3 { handle, .. } => self
                .out
                .flush_with(|bytes| handle.write(bytes))
                .and_then(|()| handle.progress()),
        };
        result.or_else(|error| self.retry(poll, error))?;
        if self.out.written() != before {
            self.progress();
        }
        Ok(())
    }
    pub(crate) fn submitted(&self) -> bool {
        self.out.written() != 0
            || match &self.transport {
                Transport::Http1 { .. } => false,
                #[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
                Transport::Http3 { handle, .. } => handle.submitted(),
            }
    }
    pub(crate) fn next(
        &mut self,
        poll: &mut Poll,
    ) -> Result<Option<response::Event>, response::Error> {
        let received = match &mut self.transport {
            Transport::Http1 { stream, .. } => stream.take_read(),
            #[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
            Transport::Http3 { handle, .. } => handle.take_read(),
        };
        if received {
            self.progress();
        }
        loop {
            match &mut self.transport {
                Transport::Http1 {
                    stream,
                    reader,
                    eof,
                    ..
                } => {
                    if let Some(event) = reader.next(*eof)? {
                        return Ok(Some(event));
                    }
                    let result =
                        stream.read_ready(poll, self.token, reader.read_buffer(), &mut self.reads);
                    let count = match &result {
                        Ok(Some(Read::Data(count))) => *count,
                        _ => 0,
                    };
                    reader.commit_read(count);
                    match result {
                        Ok(Some(Read::Data(_))) => self.progress(),
                        Ok(Some(Read::End)) => *eof = true,
                        Ok(None) => return Ok(None),
                        Err(error) => {
                            self.retry(poll, error)?;
                            return Ok(None);
                        }
                    }
                }
                #[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
                Transport::Http3 {
                    handle,
                    reply,
                    phase,
                } => match phase {
                    Phase::AwaitHead => {
                        let Some(head) = handle.response()? else {
                            return Ok(None);
                        };
                        let tunnel = matches!(reply, Reply::WebSocket) && head.status == 200;
                        let remaining = if tunnel {
                            None
                        } else if matches!(head.status, 204 | 304) {
                            Some(0)
                        } else {
                            let mut length = None;
                            for (_, value) in head
                                .headers
                                .iter()
                                .filter(|(name, _)| name.eq_ignore_ascii_case("content-length"))
                            {
                                let parsed = value.trim().parse::<usize>().map_err(|_| {
                                    io::Error::new(
                                        io::ErrorKind::InvalidData,
                                        StreamFailure::Protocol(
                                            "invalid content-length".to_owned(),
                                        ),
                                    )
                                })?;
                                if length.is_some_and(|previous| previous != parsed) {
                                    return Err(io::Error::new(
                                        io::ErrorKind::InvalidData,
                                        StreamFailure::Protocol(
                                            "conflicting content-length".to_owned(),
                                        ),
                                    )
                                    .into());
                                }
                                length = Some(parsed);
                            }
                            length
                        };
                        *phase = Phase::Body { remaining };
                        return Ok(Some(if tunnel {
                            response::Event::Upgrade(head)
                        } else {
                            response::Event::Head(head)
                        }));
                    }
                    Phase::Ended => return Ok(None),
                    Phase::Body { remaining } => {
                        let mut bytes = [0; 65536];
                        return match handle.read_ready(&mut bytes)? {
                            Some(Read::Data(count)) => {
                                if let Some(left) = remaining {
                                    *left = left.checked_sub(count).ok_or_else(|| {
                                        io::Error::new(
                                            io::ErrorKind::InvalidData,
                                            StreamFailure::Protocol(
                                                "HTTP/3 body exceeds content-length".to_owned(),
                                            ),
                                        )
                                    })?;
                                }
                                self.progress();
                                Ok(Some(response::Event::Body(
                                    bytes.get(..count).unwrap_or_default().to_vec(),
                                )))
                            }
                            Some(Read::End) => {
                                let short = remaining.is_some_and(|left| left != 0);
                                *phase = Phase::Ended;
                                if short {
                                    return Err(io::Error::new(
                                        io::ErrorKind::UnexpectedEof,
                                        StreamFailure::Protocol(
                                            "HTTP/3 body shorter than content-length".to_owned(),
                                        ),
                                    )
                                    .into());
                                }
                                Ok(Some(response::Event::End))
                            }
                            None => Ok(None),
                        };
                    }
                },
            }
        }
    }
    pub(crate) fn accepted(&self, head: &Response) -> io::Result<()> {
        match &self.transport {
            Transport::Http1 {
                reply: Http1Reply::WebSocket { key },
                ..
            } => ko_wire::ws::accepted(head, key),
            #[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
            Transport::Http3 {
                reply: Reply::WebSocket,
                ..
            } if head.status == 200 => Ok(()),
            _ => Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "unexpected WebSocket upgrade",
            )),
        }
    }
    pub(crate) fn into_stream(self) -> (Stream, Vec<u8>, Token) {
        match self.transport {
            Transport::Http1 {
                stream, mut reader, ..
            } => (Stream::Direct(stream), reader.take_rest(), self.token),
            #[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
            Transport::Http3 { handle, .. } => (Stream::Quic(handle), Vec::new(), self.token),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wire::{Link, Next};
    use ko_sys::fd;
    use std::io::Write;
    use std::os::fd::AsFd;
    use std::os::unix::net::UnixStream;

    fn upgrade(poll: &mut Poll, ours: UnixStream) -> Exchange {
        fd::set_nonblocking(ours.as_fd()).unwrap();
        Exchange::new(
            poll,
            Transport::Http1 {
                stream: Direct::Unix(ours),
                reader: response::Reader::default(),
                reply: Http1Reply::WebSocket {
                    key: "test-key".to_owned(),
                },
                eof: false,
            },
            Vec::new(),
            Limit::Deadline(Instant::now() + crate::wire::READ_TIMEOUT),
        )
    }
    #[test]
    fn an_upgrade_keeps_a_partial_head_and_delivers_the_frames_after_it() {
        let (ours, mut server) = UnixStream::pair().unwrap();
        let mut poll = Poll::new();
        let mut exchange = upgrade(&mut poll, ours);
        server
            .write_all(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: web")
            .unwrap();
        assert!(exchange.next(&mut poll).unwrap().is_none());
        let accept = tungstenite::handshake::derive_accept_key(b"test-key");
        server
            .write_all(
                format!("socket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n")
                    .as_bytes(),
            )
            .unwrap();
        server.write_all(b"\x81\x0dafter-upgrade").unwrap();
        exchange.begin_turn();
        let Some(response::Event::Upgrade(head)) = exchange.next(&mut poll).unwrap() else {
            panic!("the complete head did not open");
        };
        exchange.accepted(&head).unwrap();
        let (stream, rest, token) = exchange.into_stream();
        let mut link = Link::of_stream(stream, rest, ko_wire::protocol::Upgrade::Control);
        link.token = Some(token);
        link.interest(&mut poll, true);
        assert_eq!(
            link.next(&mut poll, Instant::now()).unwrap(),
            Next::Text("after-upgrade".into())
        );
    }
    #[test]
    fn an_unterminated_upgrade_head_has_a_bound() {
        let (ours, mut server) = UnixStream::pair().unwrap();
        let mut poll = Poll::new();
        let mut exchange = upgrade(&mut poll, ours);
        server
            .write_all(b"HTTP/1.1 101 Switching Protocols\r\nX: ")
            .unwrap();
        let mut rejected = None;
        for _ in 0..17 {
            server.write_all(&[b'x'; 4096]).unwrap();
            exchange.begin_turn();
            match exchange.next(&mut poll) {
                Ok(None) => {}
                Ok(Some(_)) => panic!("an unterminated head opened"),
                Err(error) => {
                    rejected = Some(io::Error::from(error).kind());
                    break;
                }
            }
        }
        assert_eq!(rejected, Some(io::ErrorKind::InvalidData));
    }
}
