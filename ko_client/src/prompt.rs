use std::path::Path;

use ko_wire::api::{Route, WindowOnly};
use ko_wire::ids::PaneId;
use ko_wire::protocol::{Candidate, Empty, SendPrompt, Sent};

use crate::api::{ReplyError, call};
use crate::wire::{self, Caller};

pub fn resolve(
    dir: &Path,
    caller: Option<Caller>,
    from: PaneId,
    window_only: bool,
) -> Result<Vec<Candidate>, ReplyError> {
    call(
        dir,
        &Route::PromptResolve {
            from,
            window: window_only.then_some(WindowOnly),
        },
        caller,
        None::<&Empty>,
        wire::READ_TIMEOUT,
    )
}

pub fn send(dir: &Path, caller: Option<Caller>, request: &SendPrompt) -> Result<Sent, ReplyError> {
    call(
        dir,
        &Route::SendPrompt {},
        caller,
        Some(request),
        wire::READ_TIMEOUT,
    )
}
