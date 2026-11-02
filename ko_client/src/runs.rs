use std::path::Path;
use std::time::Duration;

use ko_server::ids::{PaneId, RunId};
use ko_server::protocol::{
    self, Candidate, Detail, Empty, Error, Info, ReportOutcome, Route, SendPrompt, Sent, Show,
    StartRun, Started, StopRun, Waited,
};
use ko_server::runs::{Parent, RunOutcome};
use serde::Serialize;
use serde::de::DeserializeOwned;

use crate::api::{self, Failure as Reach};
use crate::wire;

#[derive(Debug)]
pub enum Failure {
    Server(Reach),
    Refused(Error),
}

fn call<T: Serialize + DeserializeOwned>(
    dir: &Path,
    route: &Route,
    caller: Option<PaneId>,
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
    caller: Option<PaneId>,
) -> Result<T, Failure> {
    call(dir, route, caller, None::<&Empty>, wire::READ_TIMEOUT)
}

pub fn start(dir: &Path, caller: Option<PaneId>, request: &StartRun) -> Result<Started, Failure> {
    call(
        dir,
        &Route::StartRun,
        caller,
        Some(request),
        wire::READ_TIMEOUT,
    )
}

pub fn list(dir: &Path, show: Show, parent: Option<Parent>) -> Result<Vec<Info>, Failure> {
    plain(dir, &Route::ListRuns(show, parent), None)
}

pub fn detail(dir: &Path, id: &RunId) -> Result<Detail, Failure> {
    plain(dir, &Route::GetRun(id.clone()), None)
}

pub fn wait(dir: &Path, id: &RunId, timeout: Duration) -> Result<Option<RunOutcome>, Failure> {
    let milliseconds = u64::try_from(timeout.as_millis()).unwrap_or(protocol::WAIT_MAX_MS);
    let within = timeout.saturating_add(wire::READ_TIMEOUT);
    call::<Waited>(
        dir,
        &Route::WaitRun(id.clone(), milliseconds.min(protocol::WAIT_MAX_MS)),
        None,
        None::<&Empty>,
        within,
    )
    .map(|waited| waited.outcome)
}

pub fn outcome(dir: &Path, id: &RunId, report: &ReportOutcome) -> Result<(), Failure> {
    call::<Empty>(
        dir,
        &Route::RunOutcome(id.clone()),
        None,
        Some(report),
        wire::READ_TIMEOUT,
    )
    .map(drop)
}

pub fn stop(dir: &Path, id: &RunId, request: &StopRun) -> Result<(), Failure> {
    let within = Duration::from_millis(request.wait_ms).saturating_add(wire::READ_TIMEOUT);
    call::<Empty>(
        dir,
        &Route::StopRun(id.clone()),
        None,
        Some(request),
        within,
    )
    .map(drop)
}

pub fn reap(dir: &Path) -> Result<(), Failure> {
    call::<Empty>(dir, &Route::Reap, None, Some(&Empty {}), wire::READ_TIMEOUT).map(drop)
}

pub fn resolve(
    dir: &Path,
    caller: Option<PaneId>,
    window_only: bool,
) -> Result<Vec<Candidate>, Failure> {
    plain(dir, &Route::PromptResolve { window_only }, caller)
}

pub fn send(dir: &Path, caller: Option<PaneId>, request: &SendPrompt) -> Result<Sent, Failure> {
    call(
        dir,
        &Route::SendPrompt,
        caller,
        Some(request),
        wire::READ_TIMEOUT,
    )
}
