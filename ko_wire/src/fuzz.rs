#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::indexing_slicing,
    clippy::arithmetic_side_effects
)]

use crate::api::Route;
use crate::http::{MAX_HEAD, Parsed, Upgrade, parse_head, read_response, read_upgrade};
use crate::protocol::{
    self, ClientRequest, CreatePane, Input, SendMessage, SendPrompt, StreamRequest, ViewRequest,
};
use serde::Serialize;
use serde::de::DeserializeOwned;
use std::fmt::Debug;
use std::io::{self, Read};

fn roundtrip<T: DeserializeOwned + Serialize + PartialEq + Debug>(data: &[u8]) {
    if let Ok(value) = protocol::decode::<T>(data) {
        let text = protocol::json(&value);
        let again = protocol::decode::<T>(text.as_bytes()).expect("an encoded value decodes");
        assert_eq!(value, again, "{text}");
    }
}

pub fn decode(data: &[u8]) {
    roundtrip::<CreatePane>(data);
    roundtrip::<ClientRequest>(data);
    roundtrip::<ViewRequest>(data);
    roundtrip::<Input>(data);
    roundtrip::<SendMessage>(data);
    roundtrip::<SendPrompt>(data);
    roundtrip::<StreamRequest>(data);
    let text = String::from_utf8_lossy(data);
    let (method, target) = text.split_once(' ').unwrap_or((&text, &text));
    if let Ok(route) = Route::of_request(method, target) {
        let (method, target) = route.to_request();
        assert_eq!(Route::of_request(method, target.as_str()), Ok(route));
    }
}

fn pieces<'a>(data: &'a [u8], cuts: &[usize]) -> Vec<&'a [u8]> {
    let mut pieces = Vec::new();
    let mut from = 0;
    for &cut in cuts {
        let cut = cut.clamp(from, data.len());
        pieces.push(&data[from..cut]);
        from = cut;
    }
    pieces.push(&data[from..]);
    pieces
}

fn settle(pieces: &[&[u8]]) -> Parsed {
    let mut buffer = Vec::new();
    let mut scanned = 0;
    let mut last = Parsed::Partial;
    for piece in pieces {
        buffer.extend_from_slice(piece);
        last = parse_head(&buffer, &mut scanned);
        if last != Parsed::Partial {
            if let Parsed::Complete { size, .. } = last {
                assert!(size <= MAX_HEAD && size <= buffer.len(), "head size {size}");
            }
            break;
        }
        assert!(
            buffer.len() < MAX_HEAD,
            "a partial head of {} bytes",
            buffer.len()
        );
    }
    last
}

fn same_head(a: &Parsed, b: &Parsed, len: usize) -> bool {
    match (a, b) {
        (Parsed::Complete { .. }, _) | (_, Parsed::Complete { .. }) => a == b,
        (Parsed::BadLine, Parsed::Partial) | (Parsed::Partial, Parsed::BadLine) => true,
        _ => len >= MAX_HEAD || a == b,
    }
}

pub fn head(data: &[u8]) {
    let Some((&count, rest)) = data.split_first() else {
        return;
    };
    let count = usize::from(count % 8);
    if rest.len() < count {
        return;
    }
    let (fractions, bytes) = rest.split_at(count);
    let mut cuts: Vec<usize> = fractions
        .iter()
        .map(|&fraction| usize::from(fraction) * bytes.len() / 256)
        .collect();
    cuts.sort_unstable();
    let whole = settle(&[bytes]);
    let cut = settle(&pieces(bytes, &cuts));
    assert!(
        same_head(&whole, &cut, bytes.len()),
        "{whole:?} against {cut:?}"
    );
    if let Parsed::Complete { head, .. } = &whole {
        let _ = head.framing();
    }
    if bytes.len() <= 20000 {
        let every: Vec<usize> = (1..bytes.len()).collect();
        let single = settle(&pieces(bytes, &every));
        assert!(
            same_head(&whole, &single, bytes.len()),
            "{whole:?} against {single:?}"
        );
    }
}

struct Pieces<'a> {
    pieces: Vec<&'a [u8]>,
    next: usize,
}

impl Read for Pieces<'_> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        while self
            .pieces
            .get(self.next)
            .is_some_and(|piece| piece.is_empty())
        {
            self.next += 1;
        }
        let Some(piece) = self.pieces.get(self.next) else {
            return Ok(0);
        };
        let count = piece.len().min(buffer.len());
        buffer[..count].copy_from_slice(&piece[..count]);
        if count == piece.len() {
            self.next += 1;
        } else {
            self.pieces[self.next] = &piece[count..];
        }
        Ok(count)
    }
}

fn summary<T: Debug>(result: io::Result<T>) -> String {
    match result {
        Ok(value) => format!("{value:?}"),
        Err(error) => format!("{:?} {error}", error.kind()),
    }
}

fn upgraded(mut source: impl Read) -> String {
    summary(read_upgrade(&mut source).and_then(|upgrade| match upgrade {
        Upgrade::Accepted(response, mut rest) => {
            source.read_to_end(&mut rest)?;
            Ok(Upgrade::Accepted(response, rest))
        }
        Upgrade::Refused(response) => Ok(Upgrade::Refused(response)),
    }))
}

fn same_reads(bytes: &[u8], cuts: &[usize]) {
    let cut = || Pieces {
        pieces: pieces(bytes, cuts),
        next: 0,
    };
    assert_eq!(
        summary(read_response(&mut &bytes[..])),
        summary(read_response(&mut cut())),
        "a response cut at {cuts:?}"
    );
    assert_eq!(
        upgraded(bytes),
        upgraded(cut()),
        "an upgrade cut at {cuts:?}"
    );
}

pub fn client(data: &[u8]) {
    let Some((&count, rest)) = data.split_first() else {
        return;
    };
    let count = usize::from(count % 8);
    if rest.len() < count {
        return;
    }
    let (fractions, bytes) = rest.split_at(count);
    let mut cuts: Vec<usize> = fractions
        .iter()
        .map(|&fraction| usize::from(fraction) * bytes.len() / 256)
        .collect();
    cuts.sort_unstable();
    same_reads(bytes, &cuts);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    fn replay(target: &str, run: fn(&[u8])) -> usize {
        let corpus = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../fuzz/corpus")
            .join(target);
        let mut replayed = 0;
        for entry in std::fs::read_dir(corpus).unwrap() {
            run(&std::fs::read(entry.unwrap().path()).unwrap());
            replayed += 1;
        }
        replayed
    }

    #[test]
    fn a_reader_with_empty_pieces_and_an_upgrade_cut_at_its_head_read_the_same_as_a_whole() {
        let head = b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n";
        let upgrade = [&head[..], b"\x81\x02hi"].concat();
        let response = b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok";
        for cuts in [
            &[0][..],
            &[0, 0, 7, 7],
            &[head.len()],
            &[head.len(), head.len()],
        ] {
            same_reads(&upgrade, cuts);
            same_reads(response, cuts);
        }
        assert_eq!(
            upgraded(&upgrade[..]),
            upgraded(Pieces {
                pieces: vec![head, b"\x81\x02hi"],
                next: 0
            })
        );
    }

    #[test]
    fn head_finding_0() {
        head(b"\x01\x0d\x0a\x0d\x0a\x00\x00\x00\x61\x61\x61\x61\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x27\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x0a");
    }

    #[test]
    fn head_finding_1() {
        head(b"\x02\xcb\x2f\x0a\x0d\x0a\x2d\x45\x6e\x74\x72\x61\x6e\x73\x66\x65\x72\x2d\x65\x6e\x63\x6f\x64\x69\x00\x0b");
    }

    #[test]
    fn client_finding_0() {
        client(b"\xff\xff\xff\xff\x03\x20\x60\xa0\x48\x54\x54\x50\x2f\x31\x2e\x31\x20\x32\x30\x30\x20\x4f\x4b\x0d\x0a\x54\x72\x61\x6e\x73\x66\x65\x72\x2d\x45\x6e\x63\x6f\x64\x69\x6e\x67\x3a\x20\x63\x68\x75\x6e\x6b\x65\x64\x0d\x0a\x0d\x0a\x0d\x0a\x33\x0d\x0a\x71\x62\x63\x0d\x0a\x32\x3b\x05\x00\xfe\xff\xff\xff\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x0a\x7e\x0d\x0d\x30\x0a\x0a");
    }

    #[test]
    fn client_finding_1() {
        client(b"\x02\x40\x80\x48\x54\x54\x50\x2f\x31\x2e\x31\x20\x32\x30\x30\x20\x4f\x4b\x31\x2e\x31\x20\x32\x30\x30\x20\x4f\x4b\x0d\x0a\x43\x6f\x6e\x74\x65\x6e\x74\x2d\x4c\x65\x6e\x67\x74\x68\x3a\x31\x20\x0d\x0a\x0d\x0a\x43\x6f\x6e\x6e\x65\x63\x74\x69\x6f\x6e\x3a\x20\x6b\x65\x65\x70\x2d\x61\x6c\x69\x76\x65\x0d\x0a\x0d\x0a\x68\x65\x6c\x6c\x6f\x20\x77\x6f\x72\x30\x0d\x0a\x43\x6f\x6e\x74\x65\x6e\x74\x2d\x4c\x65\x6e\x67\x74\x68\x3a\x20\x0d\x0a\x63\x6e\x43\x6e\x6f\x0a\x65\x0d\x74\x69\x6f\x6e\x3a\x20\x6b\x65\x65\x70\x2d\x61\x6c\x69\x76\x65\x0d\x0a\x0d\x0a\x68\x65\x6c\x6c\x6f\x20\x77\x6f\x72\x30\x0d\x0a\x0d\x0a\x6c\x64");
    }

    #[test]
    fn refused_upgrade_does_not_compare_read_ahead() {
        let response = b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\nextra";
        same_reads(response, &[response.len() - 5]);
    }

    #[test]
    fn the_replayed_corpora_run_to_the_end() {
        let replayed = [
            replay("decode", decode),
            replay("head", head),
            replay("client", client),
        ];
        assert!(replayed.iter().all(|&count| count >= 4), "{replayed:?}");
    }
}
