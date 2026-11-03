#![deny(clippy::indexing_slicing, clippy::arithmetic_side_effects)]

use std::io::{self, Read};

use crate::ids::ClientId;
use crate::protocol::version_headers;

pub(crate) const MAX_HEAD: usize = 16384;
const MAX_BODY: usize = 1 << 20;
const STACK_HEADERS: usize = 128;
const HEAP_HEADERS: usize = 4096;
const MAX_RESPONSE_HEAD: usize = 65536;

pub(crate) const BAD_REQUEST: &[u8] = b"HTTP/1.1 400 Bad Request\r\n\r\n400";
pub(crate) const LAST_CHUNK: &[u8] = b"0\r\n\r\n";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Head {
    pub(crate) method: String,
    pub(crate) target: String,
    headers: Vec<(String, String)>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Parsed {
    Complete { head: Head, size: usize },
    Partial,
    BadLine,
    Invalid,
    TooLarge,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Framing {
    Length(usize),
    Oversized(usize),
    Chunked,
    Invalid,
}

pub(crate) fn lossy(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

fn fields(headers: &[httparse::Header<'_>]) -> Vec<(String, String)> {
    headers
        .iter()
        .map(|header| (header.name.to_ascii_lowercase(), lossy(header.value)))
        .collect()
}

fn header<'a>(headers: &'a [(String, String)], name: &str) -> Option<&'a str> {
    headers
        .iter()
        .find(|(header, _)| header == name)
        .map(|(_, value)| value.as_str())
}

fn parse_with<'b>(bytes: &'b [u8], headers: &mut [httparse::Header<'b>]) -> Option<Parsed> {
    let mut request = httparse::Request::new(headers);
    Some(match request.parse(bytes) {
        Ok(httparse::Status::Partial) => Parsed::Partial,
        Ok(httparse::Status::Complete(size)) => Parsed::Complete {
            head: Head {
                method: request.method.unwrap_or_default().to_owned(),
                target: request.path.unwrap_or_default().to_owned(),
                headers: fields(request.headers),
            },
            size,
        },
        Err(httparse::Error::TooManyHeaders) => return None,
        Err(httparse::Error::Token) => Parsed::BadLine,
        Err(_) => Parsed::Invalid,
    })
}

fn ended(bytes: &[u8]) -> bool {
    bytes
        .windows(2)
        .any(|pair| pair == b"\n\n" || pair == b"\n\r")
}

pub(crate) fn parse_head(bytes: &[u8], scanned: &mut usize) -> Parsed {
    let from = scanned.saturating_sub(2);
    *scanned = bytes.len();
    let parsed = if bytes.get(from..).is_some_and(ended) {
        parse_with(bytes, &mut [httparse::EMPTY_HEADER; STACK_HEADERS])
            .or_else(|| parse_with(bytes, &mut vec![httparse::EMPTY_HEADER; HEAP_HEADERS]))
            .unwrap_or(Parsed::TooLarge)
    } else {
        Parsed::Partial
    };
    match parsed {
        Parsed::Complete { size, .. } if size > MAX_HEAD => Parsed::TooLarge,
        Parsed::Partial if bytes.len() >= MAX_HEAD => Parsed::TooLarge,
        parsed => parsed,
    }
}

impl Head {
    pub(crate) fn header(&self, name: &str) -> Option<&str> {
        header(&self.headers, name)
    }

    pub(crate) fn framing(&self) -> Framing {
        if self.header("transfer-encoding").is_some() {
            return Framing::Chunked;
        }
        let mut lengths = self
            .headers
            .iter()
            .filter(|(name, _)| name == "content-length")
            .map(|(_, value)| value.trim());
        let Some(first) = lengths.next() else {
            return Framing::Length(0);
        };
        if lengths.any(|other| other != first)
            || first.is_empty()
            || !first.bytes().all(|byte| byte.is_ascii_digit())
        {
            return Framing::Invalid;
        }
        match first.parse::<usize>() {
            Ok(length) if length <= MAX_BODY => Framing::Length(length),
            Ok(length) => Framing::Oversized(length),
            Err(_) => Framing::Invalid,
        }
    }
}

pub(crate) fn oversized(seen: usize) -> bool {
    seen > MAX_BODY
}

macro_rules! statuses {
    ($($name:ident = $code:literal $reason:literal),* $(,)?) => {
        #[derive(Debug, Clone, Copy, PartialEq, Eq)]
        pub(crate) enum Status {
            $($name = $code),*
        }

        impl Status {
            pub(crate) const fn of(code: u16) -> Option<Status> {
                match code {
                    $($code => Some(Status::$name),)*
                    _ => None,
                }
            }

            pub(crate) fn code(self) -> u16 {
                self as u16
            }

            pub(crate) fn reason(self) -> &'static str {
                match self {
                    $(Status::$name => $reason),*
                }
            }
        }
    };
}

statuses! {
    SwitchingProtocols = 101 "Switching Protocols",
    Ok = 200 "OK",
    BadRequest = 400 "Bad Request",
    NotFound = 404 "Not Found",
    Conflict = 409 "Conflict",
    Gone = 410 "Gone",
    LengthRequired = 411 "Length Required",
    PreconditionFailed = 412 "Precondition Failed",
    UpgradeRequired = 426 "Upgrade Required",
    HeadTooLarge = 431 "Request Header Fields Too Large",
    Internal = 500 "Internal Server Error",
}

fn message<'a>(
    start: &str,
    headers: impl IntoIterator<Item = (&'a str, &'a str)>,
    body: &[u8],
) -> Vec<u8> {
    let mut out = Vec::with_capacity(body.len().saturating_add(256));
    out.extend_from_slice(start.as_bytes());
    out.extend_from_slice(b"\r\n");
    for (name, value) in headers {
        out.extend_from_slice(name.as_bytes());
        out.extend_from_slice(b": ");
        out.extend_from_slice(value.as_bytes());
        out.extend_from_slice(b"\r\n");
    }
    out.extend_from_slice(b"\r\n");
    out.extend_from_slice(body);
    out
}

pub(crate) fn response(status: Status, headers: &[(&str, &str)], body: &[u8]) -> Vec<u8> {
    message(
        &format!("HTTP/1.1 {} {}", status.code(), status.reason()),
        headers.iter().copied(),
        body,
    )
}

pub(crate) fn chunk(data: &[u8], out: &mut Vec<u8>) {
    if !data.is_empty() {
        out.extend_from_slice(format!("{:x}\r\n", data.len()).as_bytes());
        out.extend_from_slice(data);
        out.extend_from_slice(b"\r\n");
    }
}

pub fn request(method: &str, target: &str, headers: &[(&str, &str)], body: &[u8]) -> Vec<u8> {
    message(
        &format!("{method} {target} HTTP/1.1"),
        headers.iter().copied(),
        body,
    )
}

pub fn call(
    method: &str,
    target: &str,
    client: Option<ClientId>,
    extra: &[(&str, &str)],
    body: &[u8],
) -> Vec<u8> {
    let versions = version_headers();
    let client = client.map(|client| client.to_string());
    let length = body.len().to_string();
    let mut headers = vec![("Host", "localhost")];
    headers.extend(versions.iter().map(|(name, value)| (*name, value.as_str())));
    if let Some(client) = &client {
        headers.push(("Ko-Client", client));
    }
    headers.extend_from_slice(extra);
    headers.push(("Content-Length", &length));
    request(method, target, &headers, body)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Response {
    pub status: u16,
    pub reason: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Response {
    pub fn header(&self, name: &str) -> Option<&str> {
        header(&self.headers, name)
    }

    pub fn head(&self) -> Vec<u8> {
        message(
            &format!("HTTP/1.1 {} {}", self.status, self.reason),
            self.headers
                .iter()
                .map(|(name, value)| (name.as_str(), value.as_str())),
            b"",
        )
    }
}

fn invalid(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

struct Incoming<'a, R> {
    stream: &'a mut R,
    buffer: Vec<u8>,
    start: usize,
    eof: bool,
}

impl<R: Read> Incoming<'_, R> {
    fn buffered(&self) -> &[u8] {
        self.buffer.get(self.start..).unwrap_or_default()
    }

    fn more(&mut self) -> io::Result<()> {
        self.buffer.drain(..self.start);
        self.start = 0;
        let mut chunk = [0; 65536];
        let count = ko_sys::retry::retry(|| self.stream.read(&mut chunk))?;
        self.eof = count == 0;
        self.buffer
            .extend_from_slice(chunk.get(..count).unwrap_or_default());
        Ok(())
    }

    fn need(&mut self, count: usize) -> io::Result<()> {
        while self.buffered().len() < count {
            self.more()?;
            if self.eof {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "server closed the connection",
                ));
            }
        }
        Ok(())
    }

    fn take(&mut self, count: usize) -> io::Result<&[u8]> {
        self.need(count)?;
        let at = self.start;
        self.start = at.saturating_add(count);
        Ok(self.buffer.get(at..self.start).unwrap_or_default())
    }

    fn head(&mut self) -> io::Result<Response> {
        loop {
            let mut headers = [httparse::EMPTY_HEADER; STACK_HEADERS];
            let mut response = httparse::Response::new(&mut headers);
            match response.parse(self.buffered()) {
                Ok(httparse::Status::Complete(size)) => {
                    let head = Response {
                        status: response
                            .code
                            .ok_or_else(|| invalid("invalid HTTP status"))?,
                        reason: response.reason.unwrap_or_default().to_owned(),
                        headers: fields(response.headers),
                        body: Vec::new(),
                    };
                    self.take(size)?;
                    return Ok(head);
                }
                Ok(httparse::Status::Partial) if self.buffered().len() < MAX_RESPONSE_HEAD => {
                    let wanted = self.buffered().len().saturating_add(1);
                    self.need(wanted)?;
                }
                Ok(httparse::Status::Partial) => return Err(invalid("HTTP header too long")),
                Err(_) => return Err(invalid("invalid HTTP status")),
            }
        }
    }
}

const PIECE: usize = 65536;

impl<R: Read> Incoming<'_, R> {
    fn pour(
        &mut self,
        mut left: usize,
        head: &Response,
        sink: &mut impl FnMut(&Response, &[u8]) -> io::Result<()>,
    ) -> io::Result<()> {
        while left > 0 {
            if self.buffered().is_empty() {
                self.more()?;
                if self.eof {
                    return Err(io::Error::new(
                        io::ErrorKind::UnexpectedEof,
                        "server closed the connection",
                    ));
                }
            }
            let count = left.min(self.buffered().len()).min(PIECE);
            sink(head, self.buffered().get(..count).unwrap_or_default())?;
            self.start = self.start.saturating_add(count);
            left = left.saturating_sub(count);
        }
        Ok(())
    }
}

pub fn read_response_with(
    stream: &mut impl Read,
    mut sink: impl FnMut(&Response, &[u8]) -> io::Result<()>,
) -> io::Result<Response> {
    let mut incoming = Incoming {
        stream,
        buffer: Vec::new(),
        start: 0,
        eof: false,
    };
    let response = incoming.head()?;
    read_body(&mut incoming, &response, &mut sink)?;
    Ok(response)
}

fn read_body<R: Read>(
    incoming: &mut Incoming<'_, R>,
    response: &Response,
    mut sink: impl FnMut(&Response, &[u8]) -> io::Result<()>,
) -> io::Result<()> {
    if response.header("transfer-encoding") == Some("chunked") {
        loop {
            let (start, size) = loop {
                match httparse::parse_chunk_size(incoming.buffered()) {
                    Ok(httparse::Status::Complete(found)) => break found,
                    Ok(httparse::Status::Partial) => {
                        let wanted = incoming.buffered().len().saturating_add(1);
                        incoming.need(wanted)?;
                    }
                    Err(_) => return Err(invalid("invalid HTTP chunk")),
                }
            };
            let size = usize::try_from(size).map_err(|_| invalid("invalid HTTP chunk"))?;
            incoming.take(start)?;
            if size == 0 {
                break;
            }
            incoming.pour(size, response, &mut sink)?;
            if incoming.take(2)? != b"\r\n" {
                return Err(invalid("invalid HTTP chunk"));
            }
        }
    } else if let Some(length) = response.header("content-length") {
        let length = length.parse().map_err(|_| invalid("invalid HTTP status"))?;
        incoming.pour(length, response, &mut sink)?;
    } else {
        loop {
            let count = incoming.buffered().len().min(PIECE);
            if count > 0 {
                sink(
                    response,
                    incoming.buffered().get(..count).unwrap_or_default(),
                )?;
                incoming.start = incoming.start.saturating_add(count);
            } else if incoming.eof {
                break;
            } else {
                incoming.more()?;
            }
        }
    }
    Ok(())
}

pub fn read_response(stream: &mut impl Read) -> io::Result<Response> {
    let mut body = Vec::new();
    let mut response = read_response_with(stream, |_, piece| {
        body.extend_from_slice(piece);
        Ok(())
    })?;
    response.body = body;
    Ok(response)
}

#[derive(Debug)]
pub enum Upgrade {
    Accepted(Response, Vec<u8>),
    Refused(Response),
}

pub fn read_upgrade(stream: &mut impl Read) -> io::Result<Upgrade> {
    let mut incoming = Incoming {
        stream,
        buffer: Vec::new(),
        start: 0,
        eof: false,
    };
    let mut response = incoming.head()?;
    if response.status == 101 {
        return Ok(Upgrade::Accepted(response, incoming.buffered().to_vec()));
    }
    let mut body = Vec::new();
    read_body(&mut incoming, &response, |_, piece| {
        body.extend_from_slice(piece);
        Ok(())
    })?;
    response.body = body;
    Ok(Upgrade::Refused(response))
}

#[cfg(test)]
#[allow(clippy::indexing_slicing, clippy::arithmetic_side_effects)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    fn fed(pieces: &[&[u8]]) -> Parsed {
        let mut buffer = Vec::new();
        let mut scanned = 0;
        let mut parsed = Parsed::Partial;
        for piece in pieces {
            buffer.extend_from_slice(piece);
            parsed = parse_head(&buffer, &mut scanned);
            if parsed != Parsed::Partial {
                break;
            }
        }
        parsed
    }

    fn head_of(size: usize) -> Vec<u8> {
        let prefix = "GET / HTTP/1.1\r\nX: ";
        format!("{prefix}{}\r\n\r\n", "a".repeat(size - prefix.len() - 4)).into_bytes()
    }

    proptest! {
        #[test]
        fn a_request_cut_into_pieces_parses_as_the_whole(
            headers in prop::collection::vec(("[a-zA-Z-]{1,12}", "[ -~]{0,40}"), 0..40),
            target in "/[a-z0-9/?=&_]{0,30}",
            cuts in prop::collection::vec(any::<prop::sample::Index>(), 0..12),
            body in "[a-z{}\"]{0,20}",
        ) {
            let mut request = format!("POST {target} HTTP/1.1\r\n");
            for (name, value) in &headers {
                request.push_str(&format!("{name}: {value}\r\n"));
            }
            request.push_str("\r\n");
            request.push_str(&body);
            let bytes = request.as_bytes();
            let mut points: Vec<usize> = cuts.iter().map(|cut| cut.index(bytes.len())).collect();
            points.sort_unstable();
            let mut pieces = Vec::new();
            let mut start = 0;
            for point in points.into_iter().chain([bytes.len()]) {
                pieces.push(&bytes[start..point]);
                start = point;
            }
            prop_assert_eq!(fed(&pieces), fed(&[bytes]));
        }

        #[test]
        fn a_head_of_n_bytes_parses_up_to_the_limit_and_is_too_large_above(size in 30usize..20_000) {
            let parsed = fed(&[&head_of(size)]);
            if size <= MAX_HEAD {
                let complete = matches!(parsed, Parsed::Complete { size: found, .. } if found == size);
                prop_assert!(complete);
            } else {
                prop_assert_eq!(parsed, Parsed::TooLarge);
            }
        }
    }

    #[test]
    fn a_head_with_thousands_of_headers_uses_the_heap_and_its_byte_count_is_the_limit() {
        let headers = |count: usize| {
            format!("GET / HTTP/1.1\r\n{}\r\n", "A:b\r\n".repeat(count)).into_bytes()
        };
        let shown: Vec<String> = [100, 129, 3000, 3300]
            .into_iter()
            .map(|count| match fed(&[&headers(count)]) {
                Parsed::Complete { head, .. } => format!("{count}: {}", head.headers.len()),
                parsed => format!("{count}: {parsed:?}"),
            })
            .collect();
        assert_eq!(
            shown,
            ["100: 100", "129: 129", "3000: 3000", "3300: TooLarge"]
        );
    }

    #[test]
    fn a_response_is_read_by_its_length_its_chunks_or_its_end() {
        let read = |bytes: &[u8]| match read_response(&mut &bytes[..]) {
            Ok(response) => format!(
                "{} {} {:?} {}",
                response.status,
                response.reason,
                response.headers,
                String::from_utf8_lossy(&response.body)
            ),
            Err(error) => error.to_string(),
        };
        assert_eq!(
            [
                read(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nokextra"),
                read(b"HTTP/1.1 404 Not Found\r\nX: y\r\n\r\nto the end"),
                read(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2;x=y\r\nde\r\n0\r\n\r\n"),
                read(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabcXY"),
                read(b"HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nshort"),
                read(b"garbage\r\n\r\n"),
                read(&[b"HTTP/1.1 200 OK\r\nX: ".as_slice(), &[b'a'; 70000]].concat()),
            ],
            [
                r#"200 OK [("content-length", "2")] ok"#,
                r#"404 Not Found [("x", "y")] to the end"#,
                r#"200 OK [("transfer-encoding", "chunked")] abcde"#,
                "invalid HTTP chunk",
                "server closed the connection",
                "invalid HTTP status",
                "HTTP header too long",
            ]
        );
    }

    #[test]
    fn a_body_reaches_the_sink_in_pieces_of_at_most_64_kib() {
        let body = vec![b'x'; 200_000];
        let length = [
            format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n", body.len()).as_bytes(),
            &body,
        ]
        .concat();
        let chunked = [
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n".as_slice(),
            format!("{:x}\r\n", body.len()).as_bytes(),
            &body,
            b"\r\n0\r\n\r\n",
        ]
        .concat();
        let to_end = [b"HTTP/1.1 200 OK\r\n\r\n".as_slice(), &body].concat();
        for bytes in [length, chunked, to_end] {
            let mut sizes = Vec::new();
            read_response_with(&mut &bytes[..], |head, piece| {
                assert_eq!(head.status, 200);
                sizes.push(piece.len());
                Ok(())
            })
            .unwrap();
            assert_eq!(sizes.iter().sum::<usize>(), body.len());
            assert!(sizes.iter().all(|size| *size <= PIECE), "{sizes:?}");
        }
    }
}
