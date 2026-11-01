use std::io::{self, Write};
use std::path::Path;
use std::time::Duration;

use ko_server::config::{self, Dir};
use ko_server::http::{self, Response};
use ko_server::protocol::{Route, version_headers};

use crate::launch::{self, Patience};

#[derive(Debug)]
pub enum Error {
    Websocket,
    NoServer,
    Failed(String),
}

pub fn request(
    dir: &Path,
    method: &str,
    path: &str,
    body: &[u8],
    patience: Patience,
    read_timeout: Duration,
) -> Result<Response, Error> {
    let route = Route::of_request(method, path).ok().flatten();
    if route.is_some_and(|route| route.websocket()) {
        return Err(Error::Websocket);
    }
    let absent = |error: &io::Error| {
        matches!(
            error.kind(),
            io::ErrorKind::NotFound | io::ErrorKind::ConnectionRefused
        )
    };
    match dir.symlink_metadata() {
        Err(error) if absent(&error) => return Err(Error::NoServer),
        _ => {}
    }
    let socket = config::socket(Dir::Existing, dir).map_err(Error::Failed)?;
    let failed = |error: io::Error| Error::Failed(error.to_string());
    let mut stream = launch::connect(&socket, patience).map_err(|error| {
        if absent(&error) {
            Error::NoServer
        } else {
            failed(error)
        }
    })?;
    stream
        .set_read_timeout(Some(read_timeout))
        .map_err(failed)?;
    let length = body.len().to_string();
    let versions = version_headers();
    let mut headers = vec![("Host", "localhost")];
    headers.extend(versions.iter().map(|(name, value)| (*name, value.as_str())));
    headers.extend([
        ("Content-Length", length.as_str()),
        ("Connection", "keep-alive"),
    ]);
    stream
        .write_all(&http::request(method, path, &headers, body))
        .map_err(failed)?;
    http::read_response(&mut stream).map_err(failed)
}
