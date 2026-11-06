use std::fmt;
use std::io;
use std::os::fd::BorrowedFd;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use ko_server::api::Route;
use ko_server::config::{self, Dir};
use ko_server::http::Response;
use ko_server::protocol::{self, ErrorKind, Snapshot, Version};
use ko_sys::event::{Events, Interest, Mode, Poll, Wake};
use serde::Serialize;
use serde::de::DeserializeOwned;

use crate::edit::Edit;
use crate::launch;
use crate::layout::{self, Document, Edited};
use crate::wire::{self, Caller, Link, Next};

#[derive(Debug)]
pub enum ReplyError {
    Server(Failure),
    Refused(protocol::Error),
}

pub fn describe(dir: &Path, failure: ReplyError) -> String {
    match failure {
        ReplyError::Refused(error) => error.message,
        ReplyError::Server(Failure::NoServer) => format!("no server at {}", dir.display()),
        ReplyError::Server(Failure::Failed(message)) => message,
    }
}

pub fn put_runtime(
    dir: &Path,
    caller: Option<Caller>,
    name: ko_config::values::RuntimeName,
    runtime: &ko_config::runtime::Runtime,
) -> Result<ko_server::protocol::RuntimeInfo, ReplyError> {
    call(
        dir,
        &Route::PutRuntime { name },
        caller,
        Some(runtime),
        wire::READ_TIMEOUT,
    )
}

pub(crate) fn call<T: Serialize + DeserializeOwned>(
    dir: &Path,
    route: &Route,
    caller: Option<Caller>,
    body: Option<&impl Serialize>,
    within: Duration,
) -> Result<T, ReplyError> {
    let (method, path) = route.to_request();
    let body = body.map(|body| protocol::json(body)).unwrap_or_default();
    let response = exchange(dir, caller, (method, &path), body.as_bytes(), within)
        .map_err(ReplyError::Server)?;
    if response.status / 100 != 2 {
        return Err(match protocol::decode::<protocol::Error>(&response.body) {
            Ok(error) => ReplyError::Refused(error),
            Err(_) => ReplyError::Server(Failure::Failed(
                String::from_utf8_lossy(&response.body).into_owned(),
            )),
        });
    }
    protocol::decode(&response.body)
        .map_err(|error| ReplyError::Server(Failure::Failed(error.to_string())))
}

pub fn version(
    socket: &Path,
    within: Duration,
    cancel: Option<&Wake>,
) -> io::Result<(Option<ErrorKind>, Version)> {
    let (method, target) = Route::Version {}.to_request();
    let response = wire::exchange(
        socket,
        (None, None),
        (method, &target),
        &[],
        b"",
        within,
        cancel,
    )?;
    if response.status != 200 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "GET /version answered {} {}",
                response.status, response.reason
            ),
        ));
    }
    let server = protocol::decode::<Version>(&response.body)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    let mismatch = protocol::check_version(Some(&server.protocol), Some(&server.vt))
        .err()
        .map(|error| error.kind);
    Ok((mismatch, server))
}

#[derive(Debug)]
pub enum Failure {
    NoServer,
    Failed(String),
}

#[derive(Debug)]
pub enum Error {
    Websocket,
    NotWebsocket,
    Server(Failure),
}

fn socket(dir: &Path, caller: Option<&Caller>) -> Result<PathBuf, Failure> {
    if let Err(error) = dir.symlink_metadata()
        && launch::absent(&error)
    {
        return Err(Failure::NoServer);
    }
    let mode = if caller.is_some() {
        Dir::Own
    } else {
        Dir::Existing
    };
    config::socket(mode, dir).map_err(Failure::Failed)
}

pub(crate) fn exchange(
    dir: &Path,
    caller: Option<Caller>,
    (method, path): (&str, &str),
    body: &[u8],
    within: Duration,
) -> Result<Response, Failure> {
    wire::exchange(
        &socket(dir, caller.as_ref())?,
        (None, caller),
        (method, path),
        &[],
        body,
        within,
        None,
    )
    .map_err(failure)
}

fn failure(error: std::io::Error) -> Failure {
    if launch::absent(&error) {
        Failure::NoServer
    } else {
        Failure::Failed(error.to_string())
    }
}

pub fn request(
    dir: &Path,
    caller: Option<Caller>,
    method: &str,
    path: &str,
    body: &[u8],
) -> Result<Response, Error> {
    request_within(dir, caller, method, path, body, wire::READ_TIMEOUT)
}

pub fn request_within(
    dir: &Path,
    caller: Option<Caller>,
    method: &str,
    path: &str,
    body: &[u8],
    within: Duration,
) -> Result<Response, Error> {
    let route = Route::of_request(method, path).ok();
    if route.is_some_and(|route| route.websocket()) {
        return Err(Error::Websocket);
    }
    exchange(dir, caller, (method, path), body, within).map_err(Error::Server)
}

pub fn stream(
    dir: &Path,
    caller: Option<Caller>,
    path: &str,
) -> Result<Result<Link, Response>, Error> {
    let route = Route::of_request("GET", path)
        .ok()
        .filter(Route::websocket)
        .ok_or(Error::NotWebsocket)?;
    let stream = socket(dir, caller.as_ref())
        .and_then(|socket| launch::connect(&socket, launch::PATIENCE, None).map_err(failure))
        .map_err(Error::Server)?;
    Link::handshake(stream, (None, caller), &route, None, wire::READ_TIMEOUT)
        .map_err(|error| Error::Server(failure(error)))
}

pub fn patch_pane(
    socket: &Path,
    caller: Caller,
    body: &protocol::PanePatch,
) -> Result<(), Failure> {
    let route = Route::PatchPane { id: caller.pane };
    wire::request_within(
        socket,
        (None, Some(caller)),
        &route,
        protocol::json(body).as_bytes(),
        (None, Duration::from_secs(1)),
    )
    .map(drop)
    .map_err(|error| Failure::Failed(error.to_string()))
}

pub fn get(dir: &Path, caller: Option<Caller>, route: &Route) -> Result<Response, Failure> {
    let (method, path) = route.to_request();
    exchange(dir, caller, (method, &path), b"", wire::READ_TIMEOUT)
}

pub fn replace_layout(
    dir: &Path,
    caller: Option<Caller>,
    document: &Document,
) -> Result<Snapshot, Failure> {
    layout::replace(
        &socket(dir, caller.as_ref())?,
        (None, caller),
        document,
        None,
    )
    .map_err(Failure::Failed)
}

pub fn edit_layout(dir: &Path, caller: Option<Caller>, edit: &Edit) -> Result<Edited, Failure> {
    layout::edit(&socket(dir, caller.as_ref())?, (None, caller), edit)
        .map_err(|error| Failure::Failed(error.to_string()))
}

const LINE_MAX: usize = 1 << 20;

#[derive(Debug)]
pub enum StreamError {
    Io(io::Error),
    Binary,
    LineTooLong,
}

impl fmt::Display for StreamError {
    fn fmt(&self, out: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            StreamError::Io(error) => error.fmt(out),
            StreamError::Binary => out.write_str("binary message"),
            StreamError::LineTooLong => out.write_str("a line of standard input is too long"),
        }
    }
}

impl From<io::Error> for StreamError {
    fn from(error: io::Error) -> StreamError {
        StreamError::Io(error)
    }
}

fn send_lines(link: &mut Link, pending: &mut Vec<u8>, end: bool) -> Result<(), StreamError> {
    while let Some(at) = pending.iter().position(|byte| *byte == b'\n') {
        let line: Vec<u8> = pending.drain(..=at).take(at).collect();
        if line.len() > LINE_MAX {
            return Err(StreamError::LineTooLong);
        }
        if !line.is_empty() {
            link.send(String::from_utf8_lossy(&line).into_owned())?;
        }
    }
    if pending.len() > LINE_MAX {
        return Err(StreamError::LineTooLong);
    }
    if end && !pending.is_empty() {
        link.send(String::from_utf8_lossy(pending).into_owned())?;
        pending.clear();
    }
    Ok(())
}

pub fn forward(
    mut link: Link,
    stdin: BorrowedFd<'_>,
    mut print: impl FnMut(&str) -> io::Result<()>,
) -> Result<Option<(u16, String)>, StreamError> {
    let mut poll = Poll::new();
    link.watch(&mut poll)?;
    let mut input = Some(poll.watch(stdin, Interest::Read));
    let (mut events, mut pending, mut chunk) = (Events::default(), Vec::new(), vec![0u8; 1 << 16]);
    loop {
        link.begin_turn();
        loop {
            match link.next(&mut poll, Instant::now())? {
                Next::Text(text) => print(text.as_str())?,
                Next::Closed | Next::Gone => return Ok(link.close_frame().cloned()),
                Next::Binary(_) => return Err(StreamError::Binary),
                Next::Wait => break,
            }
        }
        link.settle(&mut poll)?;
        poll.turn(Mode::Wait, &mut events)?;
        if !events
            .ready()
            .iter()
            .any(|ready| Some(ready.token) == input && ready.read)
        {
            continue;
        }
        match ko_sys::fd::read(stdin, &mut chunk) {
            Ok(0) => {
                if let Some(token) = input.take() {
                    poll.unwatch(token);
                }
                send_lines(&mut link, &mut pending, true)?;
            }
            Ok(count) => {
                pending.extend(chunk.iter().take(count));
                send_lines(&mut link, &mut pending, false)?;
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
            Err(error) => return Err(error.into()),
        }
    }
}
