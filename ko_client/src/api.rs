use std::path::{Path, PathBuf};
use std::time::Duration;

use ko_server::config::{self, Dir};
use ko_server::http::Response;
use ko_server::ids::PaneId;
use ko_server::protocol::{Route, Snapshot};

use crate::launch;
use crate::layout::{self, Document};
use crate::wire;

#[derive(Debug)]
pub enum Failure {
    NoServer,
    Failed(String),
}

#[derive(Debug)]
pub enum Error {
    Websocket,
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
    caller: Option<PaneId>,
    (method, path): (&str, &str),
    body: &[u8],
    within: Duration,
) -> Result<Response, Failure> {
    wire::exchange(
        &socket(dir)?,
        (None, caller),
        (method, path),
        body,
        within,
        None,
    )
    .map_err(|error| {
        if launch::absent(&error) {
            Failure::NoServer
        } else {
            Failure::Failed(error.to_string())
        }
    })
}

pub fn request(dir: &Path, method: &str, path: &str, body: &[u8]) -> Result<Response, Error> {
    request_within(dir, method, path, body, wire::READ_TIMEOUT)
}

pub fn request_within(
    dir: &Path,
    method: &str,
    path: &str,
    body: &[u8],
    within: Duration,
) -> Result<Response, Error> {
    let route = Route::of_request(method, path).ok().flatten();
    if route.is_some_and(|route| route.websocket()) {
        return Err(Error::Websocket);
    }
    exchange(dir, None, (method, path), body, within).map_err(Error::Server)
}

pub fn get(dir: &Path, route: &Route) -> Result<Response, Failure> {
    let (method, path) = route.to_request();
    exchange(dir, None, (method, &path), b"", wire::READ_TIMEOUT)
}

pub fn replace_layout(dir: &Path, document: &Document) -> Result<Snapshot, Failure> {
    layout::replace(&socket(dir)?, None, document, None).map_err(Failure::Failed)
}
