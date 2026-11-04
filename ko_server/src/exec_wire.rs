#![deny(clippy::indexing_slicing, clippy::arithmetic_side_effects)]

use std::fmt;
use std::io;
use std::ops::Range;

use serde::{Deserialize, Serialize};

use ko_config::values::AbsPath;

use crate::protocol::{self, EXEC_CHUNK, Ended, KillSignal, Variable};

const HEADER: usize = 5;
const MAX_PAYLOAD: usize = EXEC_CHUNK;
const READ: usize = MAX_PAYLOAD + HEADER;

const START: u8 = 1;
const STDIN: u8 = 2;
const EOF: u8 = 3;
const SIGNAL: u8 = 4;
const STDOUT: u8 = 1;
const STDERR: u8 = 2;
const EXIT: u8 = 3;

/// What the ko inside the runtime runs, in the first frame that the server sends it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Start {
    pub argv: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<AbsPath>,
    pub env: Vec<Variable>,
    pub escalation_ms: u64,
}

/// A frame from the server to the ko inside the runtime.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ToKo<'a> {
    Start(Start),
    Stdin(&'a [u8]),
    Eof,
    Signal(KillSignal),
}

/// A frame from the ko inside the runtime to the server.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FromKo<'a> {
    Stdout(&'a [u8]),
    Stderr(&'a [u8]),
    Exit(Ended),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Invalid {
    Kind(u8),
    Size(usize),
    Payload(u8),
    Truncated,
}

impl fmt::Display for Invalid {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Invalid::Kind(kind) => write!(f, "unknown frame kind {kind}"),
            Invalid::Size(size) => write!(f, "frame of {size} bytes"),
            Invalid::Payload(kind) => write!(f, "invalid payload of frame kind {kind}"),
            Invalid::Truncated => f.write_str("frame cut short by the end of the stream"),
        }
    }
}

fn frame(out: &mut Vec<u8>, kind: u8, payload: &[u8]) {
    let length = u32::try_from(payload.len()).unwrap_or(0);
    out.push(kind);
    out.extend_from_slice(&length.to_be_bytes());
    out.extend_from_slice(payload);
}

fn data(out: &mut Vec<u8>, kind: u8, bytes: &[u8]) {
    for part in bytes.chunks(MAX_PAYLOAD) {
        frame(out, kind, part);
    }
}

fn json(out: &mut Vec<u8>, kind: u8, value: &impl Serialize) {
    frame(out, kind, &serde_json::to_vec(value).unwrap_or_default());
}

impl ToKo<'_> {
    pub fn encode(&self, out: &mut Vec<u8>) {
        match self {
            ToKo::Start(start) => json(out, START, start),
            ToKo::Stdin(bytes) => data(out, STDIN, bytes),
            ToKo::Eof => frame(out, EOF, &[]),
            ToKo::Signal(signal) => json(out, SIGNAL, signal),
        }
    }
}

impl FromKo<'_> {
    pub fn encode(&self, out: &mut Vec<u8>) {
        match self {
            FromKo::Stdout(bytes) => data(out, STDOUT, bytes),
            FromKo::Stderr(bytes) => data(out, STDERR, bytes),
            FromKo::Exit(ended) => json(out, EXIT, ended),
        }
    }
}

fn payload<T: Serialize + serde::de::DeserializeOwned>(
    kind: u8,
    bytes: &[u8],
) -> Result<T, Invalid> {
    protocol::decode(bytes).map_err(|_| Invalid::Payload(kind))
}

/// The bytes of a stream, cut into frames. A data frame that does not fit the caller's room
/// comes in parts.
#[derive(Debug, Default)]
pub struct Frames {
    buffer: Vec<u8>,
    at: usize,
    within: usize,
}

impl Frames {
    pub fn is_empty(&self) -> bool {
        self.at >= self.buffer.len()
    }

    /// One read into the buffer. The consumed bytes leave first, so the buffer holds at most a
    /// frame and a read. The result is the read's, with 0 for the end of the stream.
    pub fn fill(&mut self, read: impl FnOnce(&mut [u8]) -> io::Result<usize>) -> io::Result<usize> {
        self.buffer.drain(..self.at.min(self.buffer.len()));
        self.at = 0;
        let length = self.buffer.len();
        self.buffer.resize(length.saturating_add(READ), 0);
        let result = self
            .buffer
            .get_mut(length..)
            .map_or(Ok(0), read)
            .map(|count| count.min(READ));
        self.buffer
            .truncate(length.saturating_add(*result.as_ref().unwrap_or(&0)));
        result
    }

    /// The kind of the next frame and the range of its payload, or of the part of it that fits
    /// the room when the kind is a data kind. `None` while the frame is not whole.
    fn next(
        &mut self,
        room: usize,
        (data, control): (&[u8], &[u8]),
    ) -> Result<Option<(u8, Range<usize>)>, Invalid> {
        let Some(&[kind, a, b, c, d]) = self
            .buffer
            .get(self.at..)
            .and_then(|rest| rest.get(..HEADER))
        else {
            return Ok(None);
        };
        let is_data = data.contains(&kind);
        if !is_data && !control.contains(&kind) {
            return Err(Invalid::Kind(kind));
        }
        let length = usize::try_from(u32::from_be_bytes([a, b, c, d])).unwrap_or(usize::MAX);
        if length > MAX_PAYLOAD {
            return Err(Invalid::Size(length));
        }
        let start = self.at.saturating_add(HEADER);
        let end = start.saturating_add(length);
        if self.buffer.len() < end {
            return Ok(None);
        }
        if !is_data {
            self.at = end;
            return Ok(Some((kind, start..end)));
        }
        let from = start.saturating_add(self.within);
        let upto = from.saturating_add(room).min(end);
        if upto <= from && from < end {
            return Ok(None);
        }
        if upto == end {
            self.at = end;
            self.within = 0;
        } else {
            self.within = upto.saturating_sub(start);
        }
        Ok(Some((kind, from..upto)))
    }

    /// The next frame of the server's stream.
    pub fn to_ko(&mut self, room: usize) -> Result<Option<ToKo<'_>>, Invalid> {
        let Some((kind, range)) = self.next(room, (&[STDIN], &[START, EOF, SIGNAL]))? else {
            return Ok(None);
        };
        let bytes = self.buffer.get(range).unwrap_or_default();
        Ok(Some(match kind {
            STDIN => ToKo::Stdin(bytes),
            START => ToKo::Start(payload(kind, bytes)?),
            SIGNAL => ToKo::Signal(payload(kind, bytes)?),
            _ if bytes.is_empty() => ToKo::Eof,
            _ => return Err(Invalid::Payload(kind)),
        }))
    }

    /// The next frame of the ko's stream.
    pub fn from_ko(&mut self, room: usize) -> Result<Option<FromKo<'_>>, Invalid> {
        let Some((kind, range)) = self.next(room, (&[STDOUT, STDERR], &[EXIT]))? else {
            return Ok(None);
        };
        let bytes = self.buffer.get(range).unwrap_or_default();
        Ok(Some(match kind {
            STDOUT => FromKo::Stdout(bytes),
            STDERR => FromKo::Stderr(bytes),
            _ => FromKo::Exit(payload(kind, bytes)?),
        }))
    }
}

#[cfg(test)]
#[allow(clippy::indexing_slicing, clippy::arithmetic_side_effects)]
mod tests {
    use super::*;
    use crate::protocol::ExitSignal;
    use proptest::prelude::*;

    fn feed(frames: &mut Frames, bytes: &[u8], cut: usize) -> Vec<usize> {
        let mut taken = Vec::new();
        let mut rest = bytes;
        while !rest.is_empty() {
            let count = frames
                .fill(|buffer| {
                    let count = cut.min(buffer.len()).min(rest.len());
                    buffer[..count].copy_from_slice(&rest[..count]);
                    Ok(count)
                })
                .unwrap();
            taken.push(count);
            rest = &rest[count..];
        }
        taken
    }

    fn start() -> Start {
        Start {
            argv: vec!["ls".to_owned(), "-l".to_owned()],
            cwd: Some("/work".to_owned().try_into().unwrap()),
            env: vec![Variable {
                name: "A".to_owned(),
                value: "1".to_owned(),
            }],
            escalation_ms: 2500,
        }
    }

    #[derive(Debug, Clone)]
    enum Owned {
        Out(Vec<u8>),
        Err(Vec<u8>),
        Exit(Ended),
    }

    fn owned() -> impl Strategy<Value = Owned> {
        prop_oneof![
            proptest::collection::vec(any::<u8>(), 1..300).prop_map(Owned::Out),
            proptest::collection::vec(any::<u8>(), 1..300).prop_map(Owned::Err),
            any::<i32>().prop_map(|status| Owned::Exit(Ended::Status { status })),
            Just(Owned::Exit(Ended::Signal {
                signal: ExitSignal::Other
            })),
        ]
    }

    proptest! {
        #[test]
        fn frames_arrive_whole_or_in_parts_however_the_stream_and_the_room_are_cut(
            messages in proptest::collection::vec(owned(), 0..8),
            cut in 1usize..40,
            room in 1usize..50,
        ) {
            let mut stream = Vec::new();
            for message in &messages {
                match message {
                    Owned::Out(bytes) => FromKo::Stdout(bytes).encode(&mut stream),
                    Owned::Err(bytes) => FromKo::Stderr(bytes).encode(&mut stream),
                    Owned::Exit(ended) => FromKo::Exit(*ended).encode(&mut stream),
                }
            }
            let mut frames = Frames::default();
            let mut seen: Vec<Owned> = Vec::new();
            let mut rest = stream.as_slice();
            while !rest.is_empty() {
                let count = frames.fill(|buffer| {
                    let count = cut.min(buffer.len()).min(rest.len());
                    buffer[..count].copy_from_slice(&rest[..count]);
                    Ok(count)
                }).unwrap();
                rest = &rest[count..];
                while let Some(message) = frames.from_ko(room).unwrap() {
                    match message {
                        FromKo::Stdout(bytes) => seen.push(Owned::Out(bytes.to_vec())),
                        FromKo::Stderr(bytes) => seen.push(Owned::Err(bytes.to_vec())),
                        FromKo::Exit(ended) => seen.push(Owned::Exit(ended)),
                    }
                }
            }
            prop_assert!(frames.is_empty());
            let flat = |list: &[Owned], out: bool| -> Vec<u8> {
                list.iter()
                    .flat_map(|message| match message {
                        Owned::Out(bytes) if out => bytes.clone(),
                        Owned::Err(bytes) if !out => bytes.clone(),
                        _ => Vec::new(),
                    })
                    .collect()
            };
            prop_assert_eq!(flat(&seen, true), flat(&messages, true));
            prop_assert_eq!(flat(&seen, false), flat(&messages, false));
            let exits = |list: &[Owned]| -> Vec<String> {
                list.iter()
                    .filter_map(|message| match message {
                        Owned::Exit(ended) => Some(format!("{ended:?}")),
                        _ => None,
                    })
                    .collect()
            };
            prop_assert_eq!(exits(&seen), exits(&messages));
        }
    }

    #[test]
    fn every_frame_of_the_servers_stream_round_trips_and_stdin_over_the_limit_is_split() {
        let mut stream = Vec::new();
        ToKo::Start(start()).encode(&mut stream);
        ToKo::Stdin(&vec![7; MAX_PAYLOAD + 1]).encode(&mut stream);
        ToKo::Eof.encode(&mut stream);
        ToKo::Signal(KillSignal::Kill).encode(&mut stream);
        let mut frames = Frames::default();
        feed(&mut frames, &stream, 1 << 20);
        assert_eq!(frames.to_ko(usize::MAX), Ok(Some(ToKo::Start(start()))));
        assert_eq!(
            frames.to_ko(usize::MAX),
            Ok(Some(ToKo::Stdin(&vec![7; MAX_PAYLOAD])))
        );
        assert_eq!(frames.to_ko(usize::MAX), Ok(Some(ToKo::Stdin(&[7]))));
        assert_eq!(frames.to_ko(usize::MAX), Ok(Some(ToKo::Eof)));
        assert_eq!(
            frames.to_ko(usize::MAX),
            Ok(Some(ToKo::Signal(KillSignal::Kill)))
        );
        assert_eq!(frames.to_ko(usize::MAX), Ok(None));
    }

    #[test]
    fn a_longer_frame_a_cut_frame_and_bad_frames_are_refused_or_wait() {
        let mut frames = Frames::default();
        feed(&mut frames, &[STDOUT, 0, 1, 0, 1], 100);
        assert_eq!(frames.from_ko(10), Err(Invalid::Size(MAX_PAYLOAD + 1)));

        let mut out = Vec::new();
        FromKo::Stdout(b"abc").encode(&mut out);
        let mut frames = Frames::default();
        feed(&mut frames, &out[..out.len() - 1], 1);
        assert_eq!(frames.from_ko(10), Ok(None));
        assert!(!frames.is_empty());

        let cases: [(&[u8], Invalid); 4] = [
            (&[9, 0, 0, 0, 0], Invalid::Kind(9)),
            (&[EXIT, 0, 0, 0, 1, b'x'], Invalid::Payload(EXIT)),
            (&[EXIT, 0, 0, 0, 2, b'[', b']'], Invalid::Payload(EXIT)),
            (
                &[
                    EXIT, 0, 0, 0, 9, b'{', b'"', b's', b't', b'a', b't', b'u', b's', b'"',
                ],
                Invalid::Payload(EXIT),
            ),
        ];
        for (bytes, why) in cases {
            let mut frames = Frames::default();
            feed(&mut frames, bytes, 100);
            assert_eq!(frames.from_ko(10), Err(why));
        }
        for bytes in [
            &[SIGNAL, 0, 0, 0, 3, b'"', b'x', b'"'][..],
            &[EOF, 0, 0, 0, 1, 0],
            &[START, 0, 0, 0, 2, b'{', b'}'],
        ] {
            let mut frames = Frames::default();
            feed(&mut frames, bytes, 100);
            assert!(matches!(frames.to_ko(10), Err(Invalid::Payload(_))));
        }
    }

    #[test]
    fn a_stream_that_always_ends_inside_a_frame_keeps_the_storage_bounded() {
        let mut unit = Vec::new();
        FromKo::Stdout(&[1; 1000]).encode(&mut unit);
        let mut frames = Frames::default();
        let mut at = 0;
        for round in 0..5000 {
            frames
                .fill(|buffer| {
                    for slot in buffer.iter_mut().take(700) {
                        *slot = unit[at % unit.len()];
                        at += 1;
                    }
                    Ok(700.min(buffer.len()))
                })
                .unwrap();
            while frames.from_ko(usize::MAX).unwrap().is_some() {}
            assert!(
                frames.buffer.len() <= 2 * READ && frames.buffer.capacity() <= 4 * READ,
                "round {round}: {} bytes",
                frames.buffer.len()
            );
        }
        assert!(!frames.is_empty(), "the stream ends inside a frame");
    }
}
