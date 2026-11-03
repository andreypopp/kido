use std::io::{self, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;

use ko_pane_wire::frame::History;
use ko_server::api::Route;
use ko_server::http::{Response, call, read_response, read_upgrade};
use ko_server::ids::PaneId;
use ko_server::protocol::{
    self, Command, CreatePane, Images, Input, Marker, Row, Text, ViewEvent, json,
};
use ko_server::ws::{Parsed, accepted, masked, parse_frame, parse_record, upgrade_request};
use ko_sys::clock::Mono;

fn send(stream: &mut UnixStream, route: &Route, body: &[u8]) -> io::Result<()> {
    let (method, target) = route.to_request();
    stream.write_all(&call(method, &target, None, &[], body))
}

pub(crate) fn exchange(socket: &Path, route: &Route, body: &str) -> io::Result<Response> {
    let mut stream = UnixStream::connect(socket)?;
    send(&mut stream, route, body.as_bytes())?;
    read_response(&mut stream)
}

pub(crate) fn create_pane(socket: &Path, argv: &[String]) -> io::Result<PaneId> {
    ko_client::layout::add_session(
        socket,
        (None, None),
        &CreatePane {
            cwd: Some("/".to_owned()),
            command: Some(Command::Argv {
                argv: argv.to_vec(),
            }),
            env: Vec::new(),
            vars: Default::default(),
            parent: None,
            close: Default::default(),
        },
    )
    .map_err(io::Error::other)
}

pub(crate) fn program_pids(socket: &Path) -> io::Result<Vec<i32>> {
    let response = exchange(socket, &Route::ListPanes {}, "")?;
    let rows: Vec<Row> = protocol::decode(&response.body).map_err(io::Error::other)?;
    Ok(rows.iter().filter_map(|row| row.pid).collect())
}

pub(crate) fn screen_text(socket: &Path, pane: PaneId) -> io::Result<String> {
    let route = Route::Screen {
        id: pane,
        format: ko_pane_wire::frame::ScreenFormat::Plain,
        history: ko_pane_wire::frame::ScreenRows::Visible,
    };
    let response = exchange(socket, &route, "")?;
    Ok(String::from_utf8_lossy(&response.body).into_owned())
}

#[derive(Debug)]
pub(crate) struct Typist {
    stream: UnixStream,
}

impl Typist {
    pub(crate) fn connect(socket: &Path) -> io::Result<Typist> {
        Ok(Typist {
            stream: UnixStream::connect(socket)?,
        })
    }

    pub(crate) fn type_text(&mut self, pane: PaneId, text: &[u8]) -> io::Result<()> {
        let body = json(&Input::Text {
            data: Text(text.to_vec()),
        });
        send(
            &mut self.stream,
            &Route::Input { id: pane },
            body.as_bytes(),
        )?;
        read_response(&mut self.stream).map(drop)
    }
}

#[derive(Debug)]
pub(crate) struct Message<'a> {
    pub(crate) opcode: u8,
    pub(crate) payload: &'a [u8],
    pub(crate) at: Mono,
}

#[derive(Debug)]
pub(crate) struct Socket {
    stream: UnixStream,
    buffer: Vec<u8>,
    start: usize,
    end: usize,
    at: Mono,
}

pub(crate) fn upgrade(socket: &Path, route: &Route) -> io::Result<Socket> {
    let mut stream = UnixStream::connect(socket)?;
    let (method, target) = route.to_request();
    let (request, key) = upgrade_request(method, &target, None);
    stream.write_all(&request)?;
    let (response, rest) = read_upgrade(&mut stream)?;
    accepted(&response, &key)?;
    let mut buffer = vec![0; 1 << 21];
    if buffer.len() < rest.len() {
        buffer.resize(rest.len(), 0);
    }
    buffer[..rest.len()].copy_from_slice(&rest);
    Ok(Socket {
        stream,
        buffer,
        start: 0,
        end: rest.len(),
        at: Mono::now(),
    })
}

pub(crate) fn open_view(socket: &Path, pane: PaneId, history: History) -> io::Result<Socket> {
    upgrade(
        socket,
        &Route::View {
            id: pane,
            history,
            images: Images::None,
            offset: None,
        },
    )
}

impl Socket {
    pub(crate) fn send_text(&mut self, text: &str) -> io::Result<()> {
        self.stream
            .write_all(&masked(1, true, text.as_bytes(), [1, 2, 3, 4], 0))
    }

    pub(crate) fn next(&mut self) -> io::Result<Option<Message<'_>>> {
        loop {
            if let Some(frame) = parse_frame(&self.buffer[self.start..self.end])
                && self.end - self.start >= frame.header + frame.length
            {
                let from = self.start + frame.header;
                self.start = from + frame.length;
                return Ok(Some(Message {
                    opcode: frame.opcode,
                    payload: &self.buffer[from..from + frame.length],
                    at: self.at,
                }));
            }
            if self.start > 0 {
                self.buffer.copy_within(self.start..self.end, 0);
                self.end -= self.start;
                self.start = 0;
            }
            if self.end == self.buffer.len() {
                self.buffer.resize(self.buffer.len() * 2, 0);
            }
            match self.stream.read(&mut self.buffer[self.end..]) {
                Ok(0) => return Ok(None),
                Ok(count) => {
                    self.at = Mono::now();
                    self.end += count;
                }
                Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                Err(error) => return Err(error),
            }
        }
    }
}

pub(crate) fn output<'a>(message: &Message<'a>) -> Option<(u64, &'a [u8])> {
    match parse_record(message.payload) {
        Ok(Parsed::Output { offset, data }) if message.opcode == 2 => Some((offset, data)),
        _ => None,
    }
}

pub(crate) fn skipped(message: &Message<'_>) -> bool {
    message.opcode == 1
        && matches!(
            protocol::decode::<ViewEvent>(message.payload),
            Ok(ViewEvent::Skipped(_))
        )
}

pub(crate) fn dead(message: &Message<'_>) -> bool {
    message.opcode == 1
        && matches!(
            protocol::decode::<ViewEvent>(message.payload),
            Ok(ViewEvent::Marked(marked)) if matches!(marked.marker, Marker::Dead(_))
        )
}

#[derive(Debug, Default)]
pub(crate) struct Stamps {
    carry: Vec<u8>,
}

impl Stamps {
    pub(crate) fn feed(&mut self, data: &[u8], mut found: impl FnMut(u64)) {
        self.carry.extend_from_slice(data);
        let bytes = &self.carry;
        let mut at = 0;
        let mut keep = bytes.len();
        while let Some(offset) = bytes[at..].iter().position(|b| *b == b'T') {
            let from = at + offset;
            let Some(digits) = bytes.get(from + 1..from + 22) else {
                keep = from;
                break;
            };
            if digits[20] == b'\r'
                && digits[..20].iter().all(u8::is_ascii_digit)
                && let Ok(stamp) = std::str::from_utf8(&digits[..20])
                    .unwrap_or_default()
                    .parse()
            {
                found(stamp);
                at = from + 22;
            } else {
                at = from + 1;
            }
        }
        self.carry.drain(..keep.min(self.carry.len()));
    }
}
