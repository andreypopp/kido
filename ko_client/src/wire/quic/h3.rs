use std::collections::VecDeque;
use std::io;
use std::os::fd::BorrowedFd;
use std::sync::{Arc, Mutex, MutexGuard};

use crate::wire::exchange::RequestHead as Request;
use ko_sys::event::{Due, Interest, Poll, Ready, Token, Wake};
use ko_wire::http::Response;
use quiche::h3::NameValue;

use super::Driver;
use crate::endpoint::tls;

impl Request {
    fn headers(&self, authority: &str) -> Vec<quiche::h3::Header> {
        use quiche::h3::Header;
        let (method, target, extra) = match self {
            Self::Http {
                method,
                target,
                headers,
                ..
            } => (method.http(), target, headers),
            Self::WebSocket { target, headers } => ("CONNECT", target, headers),
        };
        let mut headers = vec![
            Header::new(b":method", method.as_bytes()),
            Header::new(b":scheme", b"https"),
            Header::new(b":authority", authority.as_bytes()),
            Header::new(b":path", target.as_str().as_bytes()),
        ];
        if matches!(self, Self::WebSocket { .. }) {
            headers.push(Header::new(b":protocol", b"websocket"));
        }
        if let Self::Http { length, .. } = self {
            headers.push(Header::new(
                b"content-length",
                length.to_string().as_bytes(),
            ));
        }
        for (name, value) in extra {
            headers.push(Header::new(
                name.to_ascii_lowercase().as_bytes(),
                value.as_bytes(),
            ));
        }
        headers
    }
    fn length(&self) -> Option<usize> {
        match self {
            Self::Http { length, .. } => Some(*length),
            Self::WebSocket { .. } => None,
        }
    }
}

const CAPACITY: usize = 65536;
const STREAMS: usize = 128;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum StreamFailure {
    Admission,
    Reset { code: u64 },
    Protocol(String),
    Io(String),
}
impl std::fmt::Display for StreamFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Admission => f.write_str("too many HTTP/3 streams"),
            Self::Reset { code } => write!(f, "HTTP/3 stream reset {code}"),
            Self::Protocol(message) | Self::Io(message) => f.write_str(message),
        }
    }
}
impl std::error::Error for StreamFailure {}
impl StreamFailure {
    fn error(&self) -> io::Error {
        let kind = match self {
            Self::Admission => io::ErrorKind::ResourceBusy,
            Self::Reset { .. } | Self::Io(_) => io::ErrorKind::ConnectionReset,
            Self::Protocol(_) => io::ErrorKind::InvalidData,
        };
        io::Error::new(kind, self.clone())
    }
}
#[derive(Debug, Clone)]
enum Failure {
    Io(io::ErrorKind, String),
    Tls(tls::Failure),
    Stream(StreamFailure),
}
impl Failure {
    fn of(error: &io::Error) -> Self {
        match error
            .get_ref()
            .and_then(|error| error.downcast_ref::<tls::Failure>())
        {
            Some(error) => Self::Tls(error.clone()),
            None => match error
                .get_ref()
                .and_then(|error| error.downcast_ref::<StreamFailure>())
            {
                Some(error) => Self::Stream(error.clone()),
                None => Self::Io(error.kind(), error.to_string()),
            },
        }
    }
    fn error(&self) -> io::Error {
        match self {
            Self::Io(kind, message) => io::Error::new(*kind, message.clone()),
            Self::Tls(failure) => io::Error::other(failure.clone()),
            Self::Stream(failure) => failure.error(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Submission {
    Queued,
    Submitted,
}
#[derive(Debug)]
enum Life {
    Opening,
    Open,
    Finished,
    Failed {
        error: Failure,
        submission: Submission,
    },
}
#[derive(Debug)]
enum Output {
    Http { bytes: VecDeque<u8>, left: usize },
    WebSocket { bytes: VecDeque<u8> },
    Stopped { code: u64 },
}
impl Output {
    fn bytes(&self) -> Option<&VecDeque<u8>> {
        match self {
            Self::Http { bytes, .. } | Self::WebSocket { bytes } => Some(bytes),
            Self::Stopped { .. } => None,
        }
    }
    fn bytes_mut(&mut self) -> Option<&mut VecDeque<u8>> {
        match self {
            Self::Http { bytes, .. } | Self::WebSocket { bytes } => Some(bytes),
            Self::Stopped { .. } => None,
        }
    }
    fn capacity(&self) -> usize {
        let space = CAPACITY.saturating_sub(self.bytes().map_or(0, VecDeque::len));
        match self {
            Self::Http { left, .. } => space.min(*left),
            Self::WebSocket { .. } => space,
            Self::Stopped { .. } => 0,
        }
    }
}
#[derive(Debug)]
enum ResponseState {
    Pending,
    Ready(Response),
    Consumed,
}
#[derive(Debug, Clone, Copy)]
pub(crate) enum WriteInterest {
    Capacity,
    Drained,
}
#[derive(Debug, Clone, Copy)]
pub(crate) enum Demand {
    Read,
    Write(WriteInterest),
    ReadWrite(WriteInterest),
    Hangup,
    Idle,
}
impl From<Interest> for Demand {
    fn from(interest: Interest) -> Self {
        match interest {
            Interest::Read => Self::Read,
            Interest::Write => Self::Write(WriteInterest::Capacity),
            Interest::ReadWrite => Self::ReadWrite(WriteInterest::Capacity),
            Interest::Hangup => Self::Hangup,
            Interest::Idle => Self::Idle,
        }
    }
}
#[derive(Debug)]
struct State {
    input: VecDeque<u8>,
    output: Output,
    head: ResponseState,
    life: Life,
    interest: Demand,
    received: bool,
}
impl State {
    fn submission(&self) -> Submission {
        match self.life {
            Life::Opening => Submission::Queued,
            Life::Open | Life::Finished => Submission::Submitted,
            Life::Failed { submission, .. } => submission,
        }
    }
    fn fail(&mut self, error: Failure) {
        self.life = Life::Failed {
            error,
            submission: self.submission(),
        };
        self.input.clear();
        if let Some(bytes) = self.output.bytes_mut() {
            bytes.clear();
        }
    }
    fn headers(&mut self, list: Vec<quiche::h3::Header>) -> Result<(), StreamFailure> {
        let invalid = |message: &str| StreamFailure::Protocol(message.to_owned());
        let size: usize = list
            .iter()
            .map(|header| header.name().len() + header.value().len())
            .sum();
        if size > ko_wire::http::MAX_RESPONSE_HEAD {
            return Err(invalid("HTTP/3 header too long"));
        }
        let mut statuses = list.iter().filter(|header| header.name() == b":status");
        let Some(status) = statuses.next() else {
            if matches!(self.head, ResponseState::Pending)
                || list.iter().any(|header| header.name().starts_with(b":"))
            {
                return Err(invalid("HTTP/3 status missing"));
            }
            self.received = true;
            return Ok(());
        };
        if statuses.next().is_some()
            || !matches!(self.head, ResponseState::Pending)
            || list
                .iter()
                .any(|header| header.name().starts_with(b":") && header.name() != b":status")
        {
            return Err(invalid("invalid HTTP/3 response headers"));
        }
        let bytes = status.value();
        let code = std::str::from_utf8(bytes)
            .ok()
            .and_then(|code| code.parse::<u16>().ok())
            .filter(|code| (100..=599).contains(code) && *code != 101)
            .ok_or_else(|| invalid("invalid HTTP/3 status"))?;
        if bytes.len() != 3 || !bytes.iter().all(u8::is_ascii_digit) {
            return Err(invalid("invalid HTTP/3 status"));
        }
        self.received = true;
        if code < 200 {
            return Ok(());
        }
        let mut headers = Vec::new();
        for header in list.iter().filter(|header| header.name() != b":status") {
            headers.push((
                String::from_utf8(header.name().to_vec())
                    .map_err(|_| invalid("invalid HTTP/3 header name"))?,
                String::from_utf8_lossy(header.value()).into_owned(),
            ));
        }
        self.head = ResponseState::Ready(Response {
            status: code,
            reason: String::new(),
            headers,
            body: Vec::new(),
        });
        Ok(())
    }
}
#[derive(Debug)]
struct Shared {
    state: Mutex<State>,
    wake: Wake,
}
fn locked<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|error| error.into_inner())
}
impl Shared {
    fn rearm(&self, state: &mut State) {
        let read = !state.input.is_empty()
            || matches!(state.head, ResponseState::Ready(_))
            || state.received
            || matches!(state.life, Life::Finished | Life::Failed { .. });
        let ready = match state.interest {
            Demand::Read => read,
            Demand::Write(when) | Demand::ReadWrite(when) => {
                let write = match when {
                    WriteInterest::Capacity => {
                        state.output.capacity() > 0
                            || matches!(state.output, Output::Stopped { .. })
                    }
                    WriteInterest::Drained => state.output.bytes().is_none_or(VecDeque::is_empty),
                };
                write || (matches!(state.interest, Demand::ReadWrite(_)) && read)
            }
            Demand::Hangup => matches!(state.life, Life::Finished | Life::Failed { .. }),
            Demand::Idle => false,
        };
        let notified = ready || matches!(state.life, Life::Failed { .. });
        if notified != self.wake.is_set() {
            if notified {
                self.wake.wake();
            } else {
                self.wake.drain();
            }
        }
    }
    fn fail(&self, failure: &Failure) {
        let mut state = locked(&self.state);
        state.fail(failure.clone());
        self.rearm(&mut state);
    }
}
#[derive(Debug)]
struct Encoded {
    headers: Vec<quiche::h3::Header>,
    length: Option<usize>,
}
#[derive(Debug)]
enum Command {
    Open {
        id: u64,
        request: Encoded,
        shared: Arc<Shared>,
    },
    Cancel(u64),
}
#[derive(Debug)]
enum Inbox {
    Active {
        next: u64,
        commands: VecDeque<Command>,
    },
    Failed(Failure),
}
#[derive(Debug)]
struct Mailbox {
    authority: String,
    inbox: Mutex<Inbox>,
    wake: Wake,
}
#[derive(Debug, Clone)]
pub struct Access(Arc<Mailbox>);

impl Access {
    fn check(&self) -> io::Result<()> {
        match &*locked(&self.0.inbox) {
            Inbox::Active { .. } => Ok(()),
            Inbox::Failed(error) => Err(error.error()),
        }
    }
    pub(crate) fn open(&self, request: Request) -> io::Result<StreamHandle> {
        let request = Encoded {
            headers: request.headers(&self.0.authority),
            length: request.length(),
        };
        let size: usize = request
            .headers
            .iter()
            .map(|header| header.name().len() + header.value().len())
            .sum();
        if size > ko_wire::http::MAX_HEAD {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "HTTP header too long",
            ));
        }
        let mut inbox = locked(&self.0.inbox);
        let (next, commands) = match &mut *inbox {
            Inbox::Failed(failure) => return Err(failure.error()),
            Inbox::Active { next, commands } => (next, commands),
        };
        if commands.len() >= STREAMS {
            return Err(StreamFailure::Admission.error());
        }
        let shared = Arc::new(Shared {
            state: Mutex::new(State {
                input: VecDeque::new(),
                output: match request.length {
                    Some(left) => Output::Http {
                        bytes: VecDeque::new(),
                        left,
                    },
                    None => Output::WebSocket {
                        bytes: VecDeque::new(),
                    },
                },
                head: ResponseState::Pending,
                life: Life::Opening,
                interest: Demand::Read,
                received: false,
            }),
            wake: Wake::new()?,
        });
        *next = next
            .checked_add(1)
            .ok_or_else(|| io::Error::other("QUIC handle ids exhausted"))?;
        let id = *next;
        commands.push_back(Command::Open {
            id,
            request,
            shared: Arc::clone(&shared),
        });
        self.0.wake.wake();
        Ok(StreamHandle {
            id,
            shared,
            access: self.clone(),
            reads: 32,
        })
    }
}

#[derive(Debug)]
pub(crate) struct StreamHandle {
    id: u64,
    shared: Arc<Shared>,
    access: Access,
    reads: usize,
}
impl StreamHandle {
    pub(crate) fn host(&self) -> &str {
        &self.access.0.authority
    }
    pub(crate) fn begin_turn(&mut self) {
        self.reads = 32;
    }
    pub(crate) fn progress(&self) -> io::Result<()> {
        self.access.check()?;
        let state = locked(&self.shared.state);
        if let Life::Failed { error, .. } = &state.life {
            return Err(error.error());
        }
        Ok(())
    }
    pub(crate) fn pending_read(&self) -> bool {
        !locked(&self.shared.state).input.is_empty()
    }
    pub(crate) fn read_ready(
        &mut self,
        bytes: &mut [u8],
    ) -> io::Result<Option<ko_sys::event::Read>> {
        self.access.check()?;
        if self.reads == 0 {
            return Ok(None);
        }
        self.reads = self.reads.saturating_sub(1);
        match self.read(bytes) {
            Ok(0) => Ok(Some(ko_sys::event::Read::End)),
            Ok(count) => Ok(Some(ko_sys::event::Read::Data(count))),
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => Ok(None),
            Err(error) => Err(error),
        }
    }
    pub(crate) fn fd(&self) -> BorrowedFd<'_> {
        self.shared.wake.fd()
    }
    pub(crate) fn interest(&self, interest: Demand) {
        let mut state = locked(&self.shared.state);
        state.interest = interest;
        self.shared.rearm(&mut state);
    }
    pub(crate) fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        self.access.check()?;
        let mut state = locked(&self.shared.state);
        if let Life::Failed { error, .. } = &state.life {
            return Err(error.error());
        }
        if bytes.is_empty() {
            return Ok(0);
        }
        let full = state.input.len() == CAPACITY;
        let count = bytes.len().min(state.input.len());
        if count == 0 && !matches!(state.life, Life::Finished) {
            return Err(io::ErrorKind::WouldBlock.into());
        }
        for byte in bytes.iter_mut().take(count) {
            if let Some(value) = state.input.pop_front() {
                *byte = value;
            }
        }
        self.shared.rearm(&mut state);
        if full && count > 0 {
            self.access.0.wake.wake();
        }
        Ok(count)
    }
    pub(crate) fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.access.check()?;
        let mut state = locked(&self.shared.state);
        if let Life::Failed { error, .. } = &state.life {
            return Err(error.error());
        }
        if let Output::Stopped { code } = state.output {
            return Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                format!("HTTP/3 request stopped {code}"),
            ));
        }
        if !bytes.is_empty() && matches!(state.output, Output::Http { left: 0, .. }) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "HTTP body exceeds its declared length",
            ));
        }
        let count = bytes.len().min(state.output.capacity());
        if count == 0 && !bytes.is_empty() {
            return Err(io::ErrorKind::WouldBlock.into());
        }
        let empty = state.output.bytes().is_none_or(VecDeque::is_empty);
        if let Some(output) = state.output.bytes_mut() {
            output.extend(bytes.iter().take(count).copied());
        }
        if let Output::Http { left, .. } = &mut state.output {
            *left = left.saturating_sub(count);
        }
        self.shared.rearm(&mut state);
        if empty && count > 0 {
            self.access.0.wake.wake();
        }
        Ok(count)
    }
    pub(crate) fn response(&mut self) -> io::Result<Option<Response>> {
        self.access.check()?;
        let mut state = locked(&self.shared.state);
        if let Life::Failed { error, .. } = &state.life {
            return Err(error.error());
        }
        if matches!(state.life, Life::Finished) && matches!(state.head, ResponseState::Pending) {
            let error =
                StreamFailure::Protocol("HTTP/3 stream ended before final headers".to_owned());
            state.fail(Failure::Stream(error.clone()));
            self.shared.rearm(&mut state);
            return Err(error.error());
        }
        let head = match std::mem::replace(&mut state.head, ResponseState::Consumed) {
            ResponseState::Ready(head) => Some(head),
            ResponseState::Pending => {
                state.head = ResponseState::Pending;
                None
            }
            ResponseState::Consumed => None,
        };
        self.shared.rearm(&mut state);
        Ok(head)
    }
    pub(crate) fn drained(&self) -> bool {
        let state = locked(&self.shared.state);
        !matches!(state.life, Life::Failed { .. })
            && state.output.bytes().is_some_and(VecDeque::is_empty)
    }
    pub(crate) fn pending_write(&self) -> bool {
        locked(&self.shared.state)
            .output
            .bytes()
            .is_some_and(|bytes| !bytes.is_empty())
    }
    pub(crate) fn submitted(&self) -> bool {
        locked(&self.shared.state).submission() == Submission::Submitted
    }
    pub(crate) fn take_read(&self) -> bool {
        let mut state = locked(&self.shared.state);
        let received = std::mem::take(&mut state.received);
        self.shared.rearm(&mut state);
        received
    }
}
impl Drop for StreamHandle {
    fn drop(&mut self) {
        if let Inbox::Active { commands, .. } = &mut *locked(&self.access.0.inbox) {
            commands.push_back(Command::Cancel(self.id));
        }
        self.access.0.wake.wake();
    }
}

#[derive(Debug)]
enum Stream {
    Pending(Encoded),
    Open { id: u64, send: Send },
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Send {
    Open,
    Finished,
}
#[derive(Debug)]
struct Entry {
    id: u64,
    stream: Stream,
    shared: Arc<Shared>,
    readable: bool,
}
enum Protocol {
    Handshaking,
    Http3(Box<quiche::h3::Connection>),
}
pub(crate) struct Connection {
    driver: Driver,
    protocol: Protocol,
    access: Access,
    token: Token,
    streams: Vec<Entry>,
    pending: bool,
}
impl std::fmt::Debug for Connection {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("Connection")
            .field("streams", &self.streams)
            .finish_non_exhaustive()
    }
}

impl Connection {
    pub(crate) fn established(&mut self) -> bool {
        self.driver.connection().is_established()
    }
    #[cfg(any(target_vendor = "apple", test))]
    pub(crate) fn start(
        target: &crate::endpoint::Remote,
        peer: std::net::SocketAddr,
        poll: &mut Poll,
        keep_alive: std::time::Duration,
    ) -> io::Result<(Self, Access)> {
        let driver = Driver::start(
            &target.tcp.host,
            peer,
            &target.quic.config,
            poll,
            keep_alive,
        )?;
        let authority = if target.tcp.port == 443 {
            target.tcp.host.as_str().to_owned()
        } else {
            format!("{}:{}", target.tcp.host.as_str(), target.tcp.port)
        };
        Self::new(driver, poll, authority)
    }
    pub(super) fn new(
        driver: Driver,
        poll: &mut Poll,
        authority: String,
    ) -> io::Result<(Self, Access)> {
        let wake = match Wake::new() {
            Ok(wake) => wake,
            Err(error) => {
                driver.detach(poll);
                return Err(error);
            }
        };
        let access = Access(Arc::new(Mailbox {
            authority,
            inbox: Mutex::new(Inbox::Active {
                next: 0,
                commands: VecDeque::new(),
            }),
            wake,
        }));
        let token = poll.watch(access.0.wake.fd(), Interest::Read);
        Ok((
            Self {
                driver,
                protocol: Protocol::Handshaking,
                access: access.clone(),
                token,
                streams: Vec::new(),
                pending: false,
            },
            access,
        ))
    }
    pub(crate) fn ready(&mut self, poll: &mut Poll, ready: Ready) -> io::Result<bool> {
        let handled = if ready.token == self.token {
            self.access.0.wake.drain();
            true
        } else {
            self.driver.ready(poll, ready)?
        };
        self.pending |= handled;
        Ok(handled)
    }
    pub(crate) fn due(&mut self, poll: &mut Poll, due: Due) -> io::Result<bool> {
        let handled = self.driver.due(poll, due)?;
        self.pending |= handled;
        Ok(handled)
    }
    pub(crate) fn finish_turn(&mut self, poll: &mut Poll) -> io::Result<bool> {
        if !std::mem::take(&mut self.pending) {
            return Ok(false);
        }
        self.progress(poll)?;
        Ok(true)
    }
    fn progress(&mut self, poll: &mut Poll) -> io::Result<()> {
        let commands = match &mut *locked(&self.access.0.inbox) {
            Inbox::Active { commands, .. } => std::mem::take(commands),
            Inbox::Failed(error) => return Err(error.error()),
        };
        for command in commands {
            match command {
                Command::Open {
                    id,
                    request,
                    shared,
                } => {
                    if self.streams.len() >= STREAMS {
                        shared.fail(&Failure::Stream(StreamFailure::Admission));
                    } else {
                        self.streams.push(Entry {
                            id,
                            stream: Stream::Pending(request),
                            shared,
                            readable: false,
                        });
                    }
                }
                Command::Cancel(id) => {
                    if let Some(at) = self.streams.iter().position(|entry| entry.id == id) {
                        let entry = self.streams.remove(at);
                        if let Stream::Open { id, .. } = entry.stream {
                            let transport = self.driver.connection();
                            let _ = transport.stream_shutdown(id, quiche::Shutdown::Read, 0x10c);
                            let _ = transport.stream_shutdown(id, quiche::Shutdown::Write, 0x10c);
                        }
                    }
                }
            }
        }
        if matches!(self.protocol, Protocol::Handshaking)
            && self.driver.connection().is_established()
        {
            let mut config = quiche::h3::Config::new().map_err(io::Error::other)?;
            config.set_max_field_section_size(
                u64::try_from(ko_wire::http::MAX_RESPONSE_HEAD).map_err(io::Error::other)?,
            );
            self.protocol = Protocol::Http3(Box::new(
                quiche::h3::Connection::with_transport(self.driver.connection(), &config)
                    .map_err(io::Error::other)?,
            ));
        }
        let Protocol::Http3(http) = &mut self.protocol else {
            return self.driver.flush(poll);
        };
        let transport = self.driver.connection();
        let extended_connect = http.extended_connect_enabled_by_peer();
        for entry in &mut self.streams {
            if matches!(locked(&entry.shared.state).life, Life::Failed { .. }) {
                continue;
            }
            if let Stream::Pending(request) = &entry.stream {
                if request.length.is_none() && !http.extended_connect_enabled_by_peer() {
                    continue;
                }
                match http.send_request(transport, &request.headers, request.length == Some(0)) {
                    Ok(id) => {
                        entry.stream = Stream::Open {
                            id,
                            send: if request.length == Some(0) {
                                Send::Finished
                            } else {
                                Send::Open
                            },
                        };
                        let mut state = locked(&entry.shared.state);
                        state.life = Life::Open;
                        entry.shared.rearm(&mut state);
                    }
                    Err(quiche::h3::Error::Done | quiche::h3::Error::StreamBlocked) => {}
                    Err(error) => entry
                        .shared
                        .fail(&Failure::Stream(StreamFailure::Io(error.to_string()))),
                }
            }
        }
        let mut events = 0;
        for _ in 0..128 {
            let (id, event) = match http.poll(transport) {
                Ok(event) => event,
                Err(quiche::h3::Error::Done) => break,
                Err(error) => return Err(io::Error::other(error)),
            };
            events += 1;
            let Some(entry) = self.streams.iter_mut().find(
                |entry| matches!(entry.stream, Stream::Open { id: stream, .. } if stream == id),
            ) else {
                continue;
            };
            if matches!(locked(&entry.shared.state).life, Life::Failed { .. }) {
                continue;
            }
            match event {
                quiche::h3::Event::Headers { list, .. } => {
                    let mut state = locked(&entry.shared.state);
                    if let Err(error) = state.headers(list) {
                        state.fail(Failure::Stream(error));
                    }
                    entry.shared.rearm(&mut state);
                }
                quiche::h3::Event::Data => {
                    entry.readable = true;
                    locked(&entry.shared.state).received = true;
                }
                quiche::h3::Event::Finished => {
                    let mut state = locked(&entry.shared.state);
                    state.life = Life::Finished;
                    entry.shared.rearm(&mut state);
                }
                quiche::h3::Event::Reset(code) => entry
                    .shared
                    .fail(&Failure::Stream(StreamFailure::Reset { code })),
                quiche::h3::Event::PriorityUpdate | quiche::h3::Event::GoAway => {}
            }
        }
        if events == 128 || (!extended_connect && http.extended_connect_enabled_by_peer()) {
            self.access.0.wake.wake();
        }
        for entry in &mut self.streams {
            let Stream::Open { id, send } = &mut entry.stream else {
                continue;
            };
            let mut state = locked(&entry.shared.state);
            if matches!(state.life, Life::Failed { .. }) {
                continue;
            }
            let fin = matches!(state.output, Output::Http { left: 0, .. });
            if *send == Send::Open
                && let Some(bytes) = state.output.bytes_mut()
                && (!bytes.is_empty() || fin)
            {
                match http.send_body(transport, *id, bytes.make_contiguous(), fin) {
                    Ok(count) => {
                        bytes.drain(..count);
                        if fin && bytes.is_empty() {
                            *send = Send::Finished;
                        }
                    }
                    Err(quiche::h3::Error::Done | quiche::h3::Error::StreamBlocked) => {}
                    Err(quiche::h3::Error::TransportError(quiche::Error::StreamStopped(code))) => {
                        state.output = Output::Stopped { code };
                    }
                    Err(error) => state.fail(Failure::Stream(StreamFailure::Io(error.to_string()))),
                }
            }
            if entry.readable && state.input.len() < CAPACITY {
                let mut bytes = [0; CAPACITY];
                let capacity = CAPACITY.saturating_sub(state.input.len());
                match http.recv_body(transport, *id, &mut bytes[..capacity]) {
                    Ok(count) => {
                        state.input.extend(bytes.iter().take(count).copied());
                        self.access.0.wake.wake();
                    }
                    Err(quiche::h3::Error::Done) => entry.readable = false,
                    Err(error) => state.fail(Failure::Stream(StreamFailure::Io(error.to_string()))),
                }
            }
            entry.shared.rearm(&mut state);
        }
        self.driver.flush(poll)
    }
    pub(crate) fn detach(self, poll: &mut Poll, error: io::Error) {
        let failure = Failure::of(&error);
        let prior = std::mem::replace(
            &mut *locked(&self.access.0.inbox),
            Inbox::Failed(failure.clone()),
        );
        if let Inbox::Active { commands, .. } = prior {
            for command in commands {
                if let Command::Open { shared, .. } = command {
                    shared.fail(&failure);
                }
            }
        }
        for entry in self.streams {
            entry.shared.fail(&failure);
        }
        poll.unwatch(self.token);
        self.driver.detach(poll);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn access() -> Access {
        Access(Arc::new(Mailbox {
            authority: "localhost".to_owned(),
            inbox: Mutex::new(Inbox::Active {
                next: 0,
                commands: VecDeque::new(),
            }),
            wake: Wake::new().unwrap(),
        }))
    }
    #[test]
    fn command_admission_keeps_its_stream_scope() {
        let access = access();
        let request = || Request::WebSocket {
            target: "/client".to_owned().try_into().unwrap(),
            headers: Vec::new(),
        };
        let handles: Vec<_> = (0..STREAMS)
            .map(|_| access.open(request()).unwrap())
            .collect();
        let error = access.open(request()).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::ResourceBusy);
        assert_eq!(
            error
                .get_ref()
                .and_then(|error| error.downcast_ref::<StreamFailure>()),
            Some(&StreamFailure::Admission)
        );
        drop(handles);
    }
    #[test]
    fn interim_headers_and_trailers_do_not_replace_the_final_head() {
        let access = access();
        let mut handle = access
            .open(Request::Http {
                method: ko_wire::protocol::Method::Get,
                target: "/version".to_owned().try_into().unwrap(),
                headers: Vec::new(),
                length: 0,
            })
            .unwrap();
        let status = |code: &[u8]| vec![quiche::h3::Header::new(b":status", code)];
        locked(&handle.shared.state)
            .headers(status(b"103"))
            .unwrap();
        assert_eq!(handle.response().unwrap(), None);
        locked(&handle.shared.state)
            .headers(status(b"200"))
            .unwrap();
        assert_eq!(handle.response().unwrap().unwrap().status, 200);
        locked(&handle.shared.state)
            .headers(vec![quiche::h3::Header::new(b"x-checksum", b"ok")])
            .unwrap();
        assert_eq!(handle.response().unwrap(), None);
        assert!(handle.take_read());
        assert!(!handle.take_read());
        assert!(matches!(
            locked(&handle.shared.state).headers(status(b"201")),
            Err(StreamFailure::Protocol(_))
        ));
    }

    #[test]
    fn a_connection_failure_wins_before_each_stream_waiter_is_failed() {
        let access = access();
        let mut handle = access
            .open(Request::Http {
                method: ko_wire::protocol::Method::Get,
                target: "/version".to_owned().try_into().unwrap(),
                headers: Vec::new(),
                length: 0,
            })
            .unwrap();
        {
            let mut state = locked(&handle.shared.state);
            state.input.push_back(b'x');
            state.life = Life::Open;
        }
        *locked(&access.0.inbox) = Inbox::Failed(Failure::Io(
            io::ErrorKind::ConnectionReset,
            "connection ended".to_owned(),
        ));
        assert_eq!(
            handle.read(&mut [0; 1]).unwrap_err().kind(),
            io::ErrorKind::ConnectionReset
        );
        assert_eq!(
            handle.write(b"x").unwrap_err().kind(),
            io::ErrorKind::ConnectionReset
        );
        assert_eq!(
            handle.response().unwrap_err().kind(),
            io::ErrorKind::ConnectionReset
        );
    }

    #[test]
    fn a_peer_fin_does_not_close_the_http_request_body() {
        let access = access();
        let mut handle = access
            .open(Request::Http {
                method: ko_wire::protocol::Method::Post,
                target: "/body".to_owned().try_into().unwrap(),
                headers: Vec::new(),
                length: 4,
            })
            .unwrap();
        locked(&handle.shared.state).life = Life::Finished;
        assert_eq!(handle.write(b"body").unwrap(), 4);
        assert_eq!(handle.read(&mut [0; 1]).unwrap(), 0);
        assert_eq!(
            handle.write(b"overflow").unwrap_err().kind(),
            io::ErrorKind::InvalidInput
        );
    }
}
