use std::path::Path;
use std::time::Duration;

use ko_server::api::{Route, WaitMs, WindowOnly};
use ko_server::ids::{PaneId, RunId};
use ko_server::protocol::{
    self, Candidate, Empty, Error, Info, ReportOutcome, SendPrompt, Sent, Show, StartRun, Started,
    StopRun, Waited,
};
use ko_server::runs::{Parent, RunOutcome};
use serde::Serialize;
use serde::de::DeserializeOwned;

use crate::api::{self, Failure as Reach};
use crate::wire::{self, Caller};

#[derive(Debug)]
pub enum Failure {
    Server(Reach),
    Refused(Error),
}

fn call<T: Serialize + DeserializeOwned>(
    dir: &Path,
    route: &Route,
    caller: Option<Caller>,
    body: Option<&impl Serialize>,
    within: Duration,
) -> Result<T, Failure> {
    let (method, path) = route.to_request();
    let body = body.map(|body| protocol::json(body)).unwrap_or_default();
    let response = api::exchange(dir, caller, (method, &path), body.as_bytes(), within)
        .map_err(Failure::Server)?;
    if response.status / 100 != 2 {
        return Err(match protocol::decode::<Error>(&response.body) {
            Ok(error) => Failure::Refused(error),
            Err(_) => Failure::Server(Reach::Failed(
                String::from_utf8_lossy(&response.body).into_owned(),
            )),
        });
    }
    protocol::decode(&response.body)
        .map_err(|error| Failure::Server(Reach::Failed(error.to_string())))
}

fn plain<T: Serialize + DeserializeOwned>(
    dir: &Path,
    route: &Route,
    caller: Option<Caller>,
) -> Result<T, Failure> {
    call(dir, route, caller, None::<&Empty>, wire::READ_TIMEOUT)
}

pub fn start(dir: &Path, caller: Option<Caller>, request: &StartRun) -> Result<Started, Failure> {
    call(
        dir,
        &Route::StartRun {},
        caller,
        Some(request),
        wire::READ_TIMEOUT,
    )
}

pub fn list(
    dir: &Path,
    caller: Option<Caller>,
    show: Show,
    parent: Option<Parent>,
) -> Result<Vec<Info>, Failure> {
    plain(dir, &Route::ListRuns { show, parent }, caller)
}

pub fn detail(dir: &Path, caller: Option<Caller>, id: &RunId) -> Result<Info, Failure> {
    plain(dir, &Route::GetRun { id: id.clone() }, caller)
}

pub fn screen(dir: &Path, caller: Option<Caller>, id: &RunId) -> Result<Option<String>, Failure> {
    let (method, path) = Route::RunScreen { id: id.clone() }.to_request();
    let response = api::exchange(dir, caller, (method, &path), b"", wire::READ_TIMEOUT)
        .map_err(Failure::Server)?;
    match response.status {
        200 => Ok(Some(String::from_utf8_lossy(&response.body).into_owned())),
        404 => Ok(None),
        _ => Err(match protocol::decode::<Error>(&response.body) {
            Ok(error) => Failure::Refused(error),
            Err(_) => Failure::Server(Reach::Failed(format!("HTTP {}", response.status))),
        }),
    }
}

pub fn wait(
    dir: &Path,
    caller: Option<Caller>,
    id: &RunId,
    timeout: Duration,
) -> Result<Option<RunOutcome>, Failure> {
    let milliseconds = u64::try_from(timeout.as_millis()).unwrap_or(WaitMs::MAX.get());
    let within = timeout.saturating_add(wire::READ_TIMEOUT);
    call::<Waited>(
        dir,
        &Route::WaitRun {
            id: id.clone(),
            timeout_ms: WaitMs::clamped(milliseconds),
        },
        caller,
        None::<&Empty>,
        within,
    )
    .map(|waited| waited.outcome)
}

pub fn outcome(
    dir: &Path,
    caller: Option<Caller>,
    id: &RunId,
    report: &ReportOutcome,
) -> Result<(), Failure> {
    call::<Empty>(
        dir,
        &Route::RunOutcome { id: id.clone() },
        caller,
        Some(report),
        wire::READ_TIMEOUT,
    )
    .map(drop)
}

pub fn stop(
    dir: &Path,
    caller: Option<Caller>,
    id: &RunId,
    request: &StopRun,
) -> Result<(), Failure> {
    let within = Duration::from_millis(request.wait_ms.get()).saturating_add(wire::READ_TIMEOUT);
    call::<Empty>(
        dir,
        &Route::StopRun { id: id.clone() },
        caller,
        Some(request),
        within,
    )
    .map(drop)
}

pub fn resolve(
    dir: &Path,
    caller: Option<Caller>,
    from: PaneId,
    window_only: bool,
) -> Result<Vec<Candidate>, Failure> {
    plain(
        dir,
        &Route::PromptResolve {
            from,
            window: window_only.then_some(WindowOnly),
        },
        caller,
    )
}

pub fn send(dir: &Path, caller: Option<Caller>, request: &SendPrompt) -> Result<Sent, Failure> {
    call(
        dir,
        &Route::SendPrompt {},
        caller,
        Some(request),
        wire::READ_TIMEOUT,
    )
}
