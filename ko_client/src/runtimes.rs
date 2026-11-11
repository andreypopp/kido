use std::path::Path;

use std::time::{Duration, Instant};

use ko_config::values::RuntimeName;
use ko_wire::api::{Route, WaitMs};

use ko_wire::protocol::{Empty, LinkState, RuntimeWait};

use crate::api::{call, describe};
use crate::wire::{self, Caller};

pub(crate) const STILL_STARTING: Duration = Duration::from_secs(120);
const POLL: Duration = Duration::from_secs(30);

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Up {
    Up,
    Failed(String),
    StillStarting,
}

pub fn bring_up(
    dir: &Path,
    caller: Option<Caller>,
    name: &RuntimeName,
    shown: &mut impl FnMut(),
) -> Up {
    let started = Instant::now();
    let mut announced = false;
    let mut poll = Duration::ZERO;
    loop {
        let milliseconds = u64::try_from(poll.as_millis()).unwrap_or(WaitMs::MAX.get());
        let reply = match call::<RuntimeWait>(
            dir,
            &Route::WaitRuntime {
                name: name.clone(),
                timeout_ms: WaitMs::clamped(milliseconds),
            },
            caller.clone(),
            None::<&Empty>,
            poll.saturating_add(wire::READ_TIMEOUT),
        ) {
            Ok(reply) => reply,
            Err(failure) => return Up::Failed(describe(dir, failure)),
        };
        match reply.state {
            LinkState::Up => return Up::Up,
            LinkState::Failed { message } => return Up::Failed(message),
            LinkState::Down => return Up::Failed("is down".to_owned()),
            LinkState::Starting => {}
        }
        if !announced {
            shown();
            announced = true;
        }
        let left = STILL_STARTING.saturating_sub(started.elapsed());
        if left.is_zero() {
            return Up::StillStarting;
        }
        poll = left.min(POLL);
    }
}
