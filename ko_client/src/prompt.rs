use std::path::Path;

use ko_wire::api::Route;
use ko_wire::protocol::{SendPrompt, Sent};

use crate::api::{ReplyError, call};
use crate::wire::{self, Caller};

pub fn send(dir: &Path, caller: Option<Caller>, request: &SendPrompt) -> Result<Sent, ReplyError> {
    call(
        dir,
        &Route::SendPrompt {},
        caller,
        Some(request),
        wire::READ_TIMEOUT,
    )
}
