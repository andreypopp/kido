use std::path::{Path, PathBuf};
use std::time::Duration;

use ko_server::api::Route;
use ko_server::config::{self, Dir};
use ko_server::http::Response;
use ko_server::protocol::Snapshot;

use crate::edit::Edit;
use crate::launch;
use crate::layout::{self, Document, Edited};
use crate::wire::{self, Caller, Link};

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

fn socket(dir: &Path) -> Result<PathBuf, Failure> {
    if let Err(error) = dir.symlink_metadata()
        && launch::absent(&error)
    {
        return Err(Failure::NoServer);
    }
    config::socket(Dir::Existing, dir).map_err(Failure::Failed)
}

pub(crate) fn exchange(
    dir: &Path,
    caller: Option<Caller>,
    (method, path): (&str, &str),
    body: &[u8],
    within: Duration,
) -> Result<Response, Failure> {
    wire::exchange(
        &socket(dir)?,
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
    let stream = socket(dir)
        .and_then(|socket| launch::connect(&socket, launch::PATIENCE, None).map_err(failure))
        .map_err(Error::Server)?;
    Link::handshake(stream, (None, caller), &route, None, wire::READ_TIMEOUT)
        .map_err(|error| Error::Server(failure(error)))
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
    layout::replace(&socket(dir)?, (None, caller), document, None).map_err(Failure::Failed)
}

pub fn edit_layout(dir: &Path, caller: Option<Caller>, edit: &Edit) -> Result<Edited, Failure> {
    layout::edit(&socket(dir)?, (None, caller), edit)
        .map_err(|error| Failure::Failed(error.to_string()))
}
