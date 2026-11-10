use std::io;

use super::{MAX_RESPONSE_HEAD, PIECE, Response, invalid, response_head};

#[derive(Debug)]
enum Phase {
    Head,
    Length(usize),
    ChunkHead,
    ChunkData(usize),
    ChunkEnd,
    Trailers(usize),
    UntilClose,
    End,
    Finished,
}

#[derive(Debug)]
pub enum Error {
    Io(io::Error),
    Encoded { coding: String },
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(error) => error.fmt(f),
            Self::Encoded { coding } => write!(f, "unsupported HTTP content encoding: {coding}"),
        }
    }
}

impl From<io::Error> for Error {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<Error> for io::Error {
    fn from(error: Error) -> Self {
        match error {
            Error::Io(error) => error,
            error @ Error::Encoded { .. } => {
                io::Error::new(io::ErrorKind::InvalidData, error.to_string())
            }
        }
    }
}

#[derive(Debug)]
pub enum Event {
    Upgrade(Response),
    Head(Response),
    Body(Vec<u8>),
    End,
}

pub fn identity(head: &Response) -> Result<(), Error> {
    for (_, coding) in head
        .headers
        .iter()
        .filter(|(name, _)| name.eq_ignore_ascii_case("content-encoding"))
    {
        if !coding
            .split(',')
            .all(|token| token.trim().eq_ignore_ascii_case("identity"))
        {
            return Err(Error::Encoded {
                coding: coding.clone(),
            });
        }
    }
    Ok(())
}

pub(super) fn transport_header(name: &str, tokens: &[&str]) -> bool {
    !super::hop_by_hop(name, tokens) && !name.eq_ignore_ascii_case(super::CONTENT_LENGTH_HEADER)
}

pub fn metadata(mut head: Response) -> Response {
    let tokens: Vec<_> = super::connection_tokens(&head.headers)
        .into_iter()
        .map(str::to_owned)
        .collect();
    let tokens: Vec<_> = tokens.iter().map(String::as_str).collect();
    head.headers
        .retain(|(name, _)| transport_header(name, &tokens));
    head
}

#[derive(Debug)]
pub struct Reader {
    buffer: Vec<u8>,
    phase: Phase,
    start: usize,
}

impl Default for Reader {
    fn default() -> Self {
        Self {
            buffer: Vec::new(),
            phase: Phase::Head,
            start: 0,
        }
    }
}

impl Reader {
    pub fn started(&self) -> bool {
        !matches!(self.phase, Phase::Head)
    }

    #[cfg(test)]
    fn push(&mut self, bytes: &[u8]) {
        if self.start == self.buffer.len() {
            self.buffer.clear();
            self.start = 0;
        }
        self.buffer.extend_from_slice(bytes);
    }
    pub fn read_buffer(&mut self) -> &mut [u8] {
        if self.start != 0 {
            self.buffer.copy_within(self.start.., 0);
            self.buffer
                .truncate(self.buffer.len().saturating_sub(self.start));
            self.start = 0;
        }
        let start = self.buffer.len();
        self.buffer.resize(start.saturating_add(PIECE), 0);
        self.buffer.get_mut(start..).unwrap_or_default()
    }

    pub fn commit_read(&mut self, count: usize) {
        let start = self.buffer.len().saturating_sub(PIECE);
        self.buffer.truncate(start.saturating_add(count.min(PIECE)));
    }

    fn body(&mut self, count: usize) -> Vec<u8> {
        if self.start == 0 && count == self.buffer.len() {
            return std::mem::take(&mut self.buffer);
        }
        let body = self.buffered().get(..count).unwrap_or_default().to_vec();
        self.start = self.start.saturating_add(count);
        body
    }

    pub fn take_rest(&mut self) -> Vec<u8> {
        self.buffer.drain(..self.start);
        self.start = 0;
        std::mem::take(&mut self.buffer)
    }

    fn buffered(&self) -> &[u8] {
        self.buffer.get(self.start..).unwrap_or_default()
    }

    pub fn next(&mut self, eof: bool) -> io::Result<Option<Event>> {
        loop {
            match self.phase {
                Phase::Head => {
                    let Some((head, size)) = response_head(self.buffered())? else {
                        if eof {
                            return Err(io::ErrorKind::UnexpectedEof.into());
                        }
                        return Ok(None);
                    };
                    self.start = self.start.saturating_add(size);
                    if (100..200).contains(&head.status) && head.status != 101 {
                        continue;
                    }
                    self.phase = if matches!(head.status, 101 | 204 | 304) {
                        Phase::End
                    } else if let Some(coding) = head.header("transfer-encoding") {
                        if !coding.eq_ignore_ascii_case("chunked") {
                            return Err(invalid("unsupported HTTP transfer encoding"));
                        }
                        Phase::ChunkHead
                    } else if let Some(length) = head.header("content-length") {
                        Phase::Length(length.parse().map_err(|_| invalid("invalid HTTP length"))?)
                    } else {
                        Phase::UntilClose
                    };
                    if head.status == 101 {
                        return Ok(Some(Event::Upgrade(head)));
                    }
                    return Ok(Some(Event::Head(metadata(head))));
                }
                Phase::Length(0) => self.phase = Phase::End,
                Phase::Length(left) | Phase::ChunkData(left) => {
                    if self.buffered().is_empty() {
                        if eof {
                            return Err(io::ErrorKind::UnexpectedEof.into());
                        }
                        return Ok(None);
                    }
                    let take = left.min(self.buffered().len()).min(PIECE);
                    let body = self.body(take);
                    let left = left.saturating_sub(take);
                    self.phase = match self.phase {
                        Phase::Length(_) => Phase::Length(left),
                        _ if left == 0 => Phase::ChunkEnd,
                        _ => Phase::ChunkData(left),
                    };
                    return Ok(Some(Event::Body(body)));
                }
                Phase::ChunkHead => match httparse::parse_chunk_size(self.buffered()) {
                    Ok(httparse::Status::Complete((size, count))) => {
                        self.start = self.start.saturating_add(size);
                        let count =
                            usize::try_from(count).map_err(|_| invalid("invalid HTTP chunk"))?;
                        self.phase = if count == 0 {
                            Phase::Trailers(0)
                        } else {
                            Phase::ChunkData(count)
                        };
                    }
                    Ok(httparse::Status::Partial)
                        if self.buffered().len() <= MAX_RESPONSE_HEAD && !eof =>
                    {
                        return Ok(None);
                    }
                    _ => return Err(invalid("invalid HTTP chunk")),
                },
                Phase::ChunkEnd => {
                    if self.buffered().len() < 2 {
                        if eof {
                            return Err(io::ErrorKind::UnexpectedEof.into());
                        }
                        return Ok(None);
                    }
                    if self.buffered().get(..2) != Some(b"\r\n") {
                        return Err(invalid("invalid HTTP chunk"));
                    }
                    self.start = self.start.saturating_add(2);
                    self.phase = Phase::ChunkHead;
                }
                Phase::Trailers(seen) => {
                    if seen.saturating_add(self.buffered().len()) > MAX_RESPONSE_HEAD {
                        return Err(invalid("HTTP trailers too long"));
                    }
                    let Some(end) = self
                        .buffered()
                        .windows(2)
                        .position(|bytes| bytes == b"\r\n")
                    else {
                        if eof {
                            return Err(io::ErrorKind::UnexpectedEof.into());
                        }
                        return Ok(None);
                    };
                    self.start = self.start.saturating_add(end).saturating_add(2);
                    self.phase = if end == 0 {
                        Phase::End
                    } else {
                        Phase::Trailers(seen.saturating_add(end).saturating_add(2))
                    };
                }
                Phase::UntilClose => {
                    if !self.buffered().is_empty() {
                        let take = self.buffered().len().min(PIECE);
                        return Ok(Some(Event::Body(self.body(take))));
                    }
                    if !eof {
                        return Ok(None);
                    }
                    self.phase = Phase::End;
                }
                Phase::End => {
                    self.phase = Phase::Finished;
                    return Ok(Some(Event::End));
                }
                Phase::Finished => return Ok(None),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn metadata_has_no_framing_or_connection_fields() {
        for framing in [
            "Content-Length: 3\r\n",
            "Transfer-Encoding: chunked\r\n",
            "",
        ] {
            let mut reader = Reader::default();
            reader.push(format!("HTTP/1.1 200 OK\r\n{framing}cOnNeCtIoN: X-Private\r\nx-PrIvAtE: secret\r\npRoXy-Custom: secret\r\nCache-Control: public\r\nContent-Security-Policy: default-src 'none'\r\nContent-Encoding: identity\r\n\r\n").as_bytes());
            let Some(Event::Head(head)) = reader.next(false).unwrap() else {
                panic!()
            };
            assert_eq!(
                head.headers,
                [
                    ("cache-control".into(), "public".into()),
                    (
                        "content-security-policy".into(),
                        "default-src 'none'".into()
                    ),
                    ("content-encoding".into(), "identity".into())
                ]
            );
        }
        for status in [204, 304] {
            let mut reader = Reader::default();
            reader
                .push(format!("HTTP/1.1 {status} Empty\r\nContent-Length: 123\r\n\r\n").as_bytes());
            let Some(Event::Head(head)) = reader.next(false).unwrap() else {
                panic!()
            };
            assert_eq!(head.headers, []);
            assert!(matches!(reader.next(false).unwrap(), Some(Event::End)));
        }
    }

    #[test]
    fn identity_delivery_refuses_encoded_responses() {
        let mut reader = Reader::default();
        reader.push(b"HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 3\r\n\r\nabc");
        let Some(Event::Head(head)) = reader.next(false).unwrap() else {
            panic!("missing encoded head")
        };
        assert_eq!(
            identity(&head).unwrap_err().to_string(),
            "unsupported HTTP content encoding: gzip"
        );
        assert!(matches!(reader.next(false).unwrap(), Some(Event::Body(bytes)) if bytes == b"abc"));
        for (fields, accepted) in [
            ("", true),
            ("Content-Encoding: Identity, identity\r\n", true),
            (
                "Content-Encoding: identity\r\nContent-Encoding: Br\r\n",
                false,
            ),
            ("Content-Encoding: identity, deflate\r\n", false),
        ] {
            let mut reader = Reader::default();
            reader.push(format!("HTTP/1.1 200 OK\r\n{fields}Content-Length: 0\r\n\r\n").as_bytes());
            let Some(Event::Head(head)) = reader.next(false).unwrap() else {
                panic!("missing head")
            };
            assert_eq!(identity(&head).is_ok(), accepted);
        }
    }

    #[test]
    fn every_cut_preserves_the_head_body_and_end() {
        for input in [
            b"HTTP/1.1 200 OK\r\nContent-Length: 7\r\n\r\nabcdefg".as_slice(),
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3;ext=yes\r\nabc\r\n4\r\ndefg\r\n0\r\nX-Trailer: yes\r\n\r\n",
            b"HTTP/1.1 200 OK\r\n\r\nabcdefg",
        ] {
            for cut in 0..=input.len() {
                let mut reader = Reader::default();
                let mut body = Vec::new();
                let mut statuses = Vec::new();
                let mut ends = 0usize;
                for (piece, eof) in [(&input[..cut], false), (&input[cut..], false), (&[][..], true)] {
                    reader.push(piece);
                    while let Some(event) = reader.next(eof).unwrap() {
                        match event {
                            Event::Head(head) => statuses.push(head.status),
                            Event::Upgrade(_) => panic!("unexpected upgrade"),
                            Event::Body(bytes) => body.extend_from_slice(&bytes),
                            Event::End => ends = ends.saturating_add(1),
                        }
                    }
                }
                assert_eq!(statuses, [200]);
                assert_eq!(body, b"abcdefg");
                assert_eq!(ends, 1);
            }
        }
    }

    #[test]
    fn split_chunks_stream_before_the_end_and_refuse_truncation() {
        let mut reader = Reader::default();
        reader.push(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\na");
        assert!(matches!(
            reader.next(false).unwrap(),
            Some(Event::Head(Response { status: 200, .. }))
        ));
        assert!(matches!(reader.next(false).unwrap(), Some(Event::Body(bytes)) if bytes == b"a"));
        assert!(reader.next(false).unwrap().is_none());
        reader.push(b"bc\r");
        assert!(matches!(reader.next(false).unwrap(), Some(Event::Body(bytes)) if bytes == b"bc"));
        assert!(reader.next(false).unwrap().is_none());
        reader.push(b"\n0\r\nX-Test: yes\r\n\r\n");
        assert!(matches!(reader.next(false).unwrap(), Some(Event::End)));
        let mut reader = Reader::default();
        reader.push(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\na");
        reader.next(false).unwrap();
        reader.next(false).unwrap();
        assert_eq!(
            reader.next(true).unwrap_err().kind(),
            io::ErrorKind::UnexpectedEof
        );
    }
}
