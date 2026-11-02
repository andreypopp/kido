use std::path::Path;

use ko_server::config::{self, Dir};
use ko_server::http::Response;
use ko_server::protocol::Route;

use crate::launch;
use crate::wire;

#[derive(Debug)]
pub enum Error {
    Websocket,
    NoServer,
    Failed(String),
}

pub fn request(dir: &Path, method: &str, path: &str, body: &[u8]) -> Result<Response, Error> {
    let route = Route::of_request(method, path).ok().flatten();
    if route.is_some_and(|route| route.websocket()) {
        return Err(Error::Websocket);
    }
    if let Err(error) = dir.symlink_metadata()
        && launch::absent(&error)
    {
        return Err(Error::NoServer);
    }
    let socket = config::socket(Dir::Existing, dir).map_err(Error::Failed)?;
    wire::exchange(&socket, None, (method, path), body).map_err(|error| {
        if launch::absent(&error) {
            Error::NoServer
        } else {
            Error::Failed(error.to_string())
        }
    })
}
