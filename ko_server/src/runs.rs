use std::borrow::Cow;
use std::fmt;
use std::fs::{self, DirBuilder};
use std::io;
use std::os::unix::fs::DirBuilderExt;
use std::path::{Path, PathBuf};
use std::str::FromStr;

use ko_sys::pid::Exit;
use schemars::{JsonSchema, Schema, SchemaGenerator, json_schema};
use serde::{Deserialize, Serialize};

use crate::ids::{PaneId, RunId, RuntimeName};
use crate::pane_proc::Cause;
use crate::panes::{Condition, Seen};
use crate::protocol::{Info, RunRow, Show};
use crate::timestamp::Timestamp;

const NAME_MAX: usize = 64;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct RunName(String);

impl JsonSchema for RunName {
    fn schema_name() -> Cow<'static, str> {
        "RunName".into()
    }

    fn json_schema(_: &mut SchemaGenerator) -> Schema {
        json_schema!({
            "type": "string",
            "maxLength": NAME_MAX,
            "description": format!("At most {NAME_MAX} bytes, without control characters.")
        })
    }
}

impl RunName {
    pub fn new(text: &str) -> Result<RunName, String> {
        if text.len() > NAME_MAX {
            Err(format!(
                "refusing run name {text:?}: {} bytes is over the {NAME_MAX} byte limit",
                text.len()
            ))
        } else if text.chars().any(char::is_control) {
            Err(format!(
                "refusing run name {text:?}: it has a control character"
            ))
        } else {
            Ok(RunName(text.to_owned()))
        }
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<String> for RunName {
    type Error = String;

    fn try_from(text: String) -> Result<RunName, String> {
        RunName::new(&text)
    }
}

impl From<RunName> for String {
    fn from(name: RunName) -> String {
        name.0
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub enum Parent {
    Run(RunId),
    Pane(PaneId),
}

impl JsonSchema for Parent {
    fn schema_name() -> Cow<'static, str> {
        "Parent".into()
    }

    fn json_schema(generator: &mut SchemaGenerator) -> Schema {
        json_schema!({
            "anyOf": [generator.subschema_for::<PaneId>(), generator.subschema_for::<RunId>()],
            "description": "A pane id, or the id of a run."
        })
    }
}

impl FromStr for Parent {
    type Err = String;

    fn from_str(text: &str) -> Result<Parent, String> {
        let parsed = if text.starts_with("pane_") {
            text.parse().map(Parent::Pane).ok()
        } else {
            text.parse().map(Parent::Run).ok()
        };
        parsed.ok_or_else(|| format!("invalid parent {text:?}"))
    }
}

impl fmt::Display for Parent {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Parent::Run(id) => id.fmt(f),
            Parent::Pane(id) => id.fmt(f),
        }
    }
}

impl TryFrom<String> for Parent {
    type Error = String;

    fn try_from(text: String) -> Result<Parent, String> {
        text.parse()
    }
}

impl From<Parent> for String {
    fn from(parent: Parent) -> String {
        parent.to_string()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum RunResult {
    Completed,
    Failed,
    Died,
    Stopped,
}

impl fmt::Display for RunResult {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match serde_json::to_value(self) {
            Ok(serde_json::Value::String(name)) => f.write_str(&name),
            _ => Err(fmt::Error),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct RunOutcome {
    pub result: RunResult,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub at: Option<Timestamp>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Meta {
    pub id: RunId,
    pub name: RunName,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent: Option<Parent>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pane: Option<PaneId>,
    /// The runtime of the run's pane. The host has none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub runtime: Option<RuntimeName>,
    pub argv: Vec<String>,
    pub cwd: String,
    #[serde(rename = "startedAt")]
    pub started_at: Timestamp,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Ended {
    Unknown(String),
    Over(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Closing {
    pub(crate) pane: PaneId,
    pub(crate) run: Option<(RunId, RunOutcome)>,
}

pub(crate) fn root(dir: &Path) -> PathBuf {
    dir.join("runs")
}

fn run_dir(root: &Path, id: &RunId) -> PathBuf {
    root.join(id.to_string())
}

pub(crate) fn output_path(root: &Path, id: &RunId) -> PathBuf {
    run_dir(root, id).join("output")
}

fn file(root: &Path, id: &RunId, name: &str) -> PathBuf {
    run_dir(root, id).join(name)
}

pub(crate) fn write_meta(root: &Path, meta: &Meta) -> io::Result<()> {
    DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(run_dir(root, &meta.id))?;
    let temp = file(root, &meta.id, "meta.json.tmp");
    fs::write(&temp, serde_json::to_vec(meta)?)?;
    fs::rename(temp, file(root, &meta.id, "meta.json"))
}

pub(crate) fn read_meta(root: &Path, id: &RunId) -> Option<Meta> {
    serde_json::from_slice(&fs::read(file(root, id, "meta.json")).ok()?).ok()
}

fn read_outcome(root: &Path, id: &RunId) -> Option<RunOutcome> {
    serde_json::from_slice(&fs::read(file(root, id, "outcome")).ok()?).ok()
}

pub(crate) fn record_outcome_once(root: &Path, id: &RunId, outcome: &RunOutcome) -> bool {
    let write = || -> io::Result<()> {
        let temp = file(root, id, "outcome.tmp");
        fs::write(&temp, serde_json::to_vec(outcome)?)?;
        fs::rename(temp, file(root, id, "outcome"))
    };
    read_outcome(root, id).is_none() && write().is_ok()
}

pub(crate) fn recorded(root: &Path, id: &RunId) -> bool {
    read_outcome(root, id).is_some()
}

fn outcome(root: &Path, id: &RunId, condition: Option<Condition<'_>>) -> Option<RunOutcome> {
    read_outcome(root, id).or_else(|| ended_by_pane(condition))
}

pub(crate) fn open_screen(root: &Path, id: &RunId) -> Option<(fs::File, usize)> {
    let file = fs::File::open(file(root, id, "screen")).ok()?;
    let length = usize::try_from(file.metadata().ok()?.len()).ok()?;
    Some((file, length))
}

pub(crate) fn cut_point(screen: &[u8], max: usize) -> usize {
    let cut = screen.len().saturating_sub(max);
    cut + screen
        .get(cut..)
        .unwrap_or_default()
        .iter()
        .take_while(|byte| **byte & 0xC0 == 0x80)
        .count()
}

pub(crate) fn write_screen(root: &Path, id: &RunId, screen: &[u8]) {
    if screen.is_empty() {
        return;
    }
    let temp = file(root, id, "screen.tmp");
    if fs::write(&temp, screen).is_ok() {
        let _ = fs::rename(temp, file(root, id, "screen"));
    }
}

fn list(root: &Path) -> Vec<RunId> {
    let Ok(entries) = fs::read_dir(root) else {
        return Vec::new();
    };
    let mut ids: Vec<RunId> = entries
        .filter_map(Result::ok)
        .filter_map(|entry| entry.file_name().to_str()?.parse().ok())
        .collect();
    ids.sort();
    ids
}

fn signal_name(signal: i32) -> String {
    let named = [
        (libc::SIGHUP, "HUP"),
        (libc::SIGINT, "INT"),
        (libc::SIGQUIT, "QUIT"),
        (libc::SIGILL, "ILL"),
        (libc::SIGABRT, "ABRT"),
        (libc::SIGFPE, "FPE"),
        (libc::SIGKILL, "KILL"),
        (libc::SIGBUS, "BUS"),
        (libc::SIGSEGV, "SEGV"),
        (libc::SIGSYS, "SYS"),
        (libc::SIGPIPE, "PIPE"),
        (libc::SIGALRM, "ALRM"),
        (libc::SIGTERM, "TERM"),
        (libc::SIGUSR1, "USR1"),
        (libc::SIGUSR2, "USR2"),
    ];
    named
        .iter()
        .find(|(number, _)| *number == signal)
        .map_or_else(|| signal.to_string(), |(_, name)| (*name).to_owned())
}

fn dead_outcome(cause: &Cause) -> RunOutcome {
    let (result, text) = match cause {
        Cause::Exit(Exit::Exited(0)) => (RunResult::Completed, String::new()),
        Cause::Exit(Exit::Exited(code)) => (RunResult::Failed, format!("exit {code}")),
        Cause::Exit(Exit::Signaled(signal)) => (
            RunResult::Failed,
            format!("signal {}", signal_name(*signal)),
        ),
        Cause::Failed(_) => (RunResult::Died, String::new()),
    };
    RunOutcome {
        result,
        text,
        at: None,
    }
}

fn ended_by_pane(pane: Option<Condition<'_>>) -> Option<RunOutcome> {
    match pane {
        None => Some(RunOutcome {
            result: RunResult::Died,
            text: String::new(),
            at: None,
        }),
        Some(Condition::Live) => None,
        Some(Condition::Dead { cause, .. }) => Some(dead_outcome(cause)),
    }
}

fn run_pane<'a, 'b>(panes: &'a [Seen<'b>], meta: &Meta) -> Option<&'a Seen<'b>> {
    let id = meta.pane?;
    panes
        .iter()
        .find(|pane| pane.id == id && pane.run.as_ref() == Some(&meta.id))
}

pub(crate) fn ending(root: &Path, panes: &[Seen<'_>], meta: &Meta) -> Option<RunOutcome> {
    outcome(
        root,
        &meta.id,
        run_pane(panes, meta).map(|pane| pane.condition),
    )
}

pub(crate) fn row(
    root: &Path,
    pane: PaneId,
    run: &RunId,
    condition: Condition<'_>,
) -> Option<RunRow> {
    let mut meta = read_meta(root, run)?;
    meta.pane = Some(pane);
    Some(RunRow {
        outcome: outcome(root, run, Some(condition)),
        meta,
    })
}

pub(crate) fn parent_pane(
    root: &Path,
    panes: &[Seen<'_>],
    parent: &Parent,
) -> Result<PaneId, Ended> {
    match parent {
        Parent::Pane(id) => Ok(*id),
        Parent::Run(id) => {
            let meta = read_meta(root, id).ok_or_else(|| Ended::Unknown(format!("no run {id}")))?;
            let pane = meta
                .pane
                .ok_or_else(|| Ended::Unknown(format!("run {id} has no pane")))?;
            if ending(root, panes, &meta).is_some() {
                return Err(Ended::Over(format!("run {id} has ended")));
            }
            Ok(pane)
        }
    }
}

pub(crate) fn closing(root: &Path, panes: &[Seen<'_>], removed: &[PaneId]) -> Vec<Closing> {
    removed
        .iter()
        .filter_map(|id| panes.iter().find(|pane| pane.id == *id))
        .map(|pane| {
            let run = pane
                .run
                .as_ref()
                .and_then(|id| read_meta(root, id))
                .filter(|meta| meta.pane == Some(pane.id))
                .map(|meta| {
                    let outcome =
                        outcome(root, &meta.id, Some(pane.condition)).unwrap_or_else(|| {
                            RunOutcome {
                                result: RunResult::Failed,
                                text: "its parent ended".to_owned(),
                                at: None,
                            }
                        });
                    (meta.id, outcome)
                });
            Closing { pane: pane.id, run }
        })
        .collect()
}

fn info(root: &Path, panes: &[Seen<'_>], meta: Meta) -> Info {
    Info {
        output: output_path(root, &meta.id).to_string_lossy().into_owned(),
        session: None,
        run: RunRow {
            outcome: ending(root, panes, &meta),
            meta,
        },
    }
}

pub(crate) fn detail(root: &Path, panes: &[Seen<'_>], id: &RunId) -> Option<Info> {
    Some(info(root, panes, read_meta(root, id)?))
}

pub(crate) fn infos(
    root: &Path,
    panes: &[Seen<'_>],
    show: Show,
    parent: Option<&Parent>,
) -> Vec<Info> {
    let named: Vec<RunId> = match show {
        Show::All => list(root),
        Show::Live | Show::Present => {
            let mut ids: Vec<RunId> = panes.iter().filter_map(|pane| pane.run.clone()).collect();
            ids.sort();
            ids.dedup();
            ids
        }
    };
    let mut found: Vec<Info> = named
        .iter()
        .filter_map(|id| read_meta(root, id))
        .filter(|meta| parent.is_none_or(|parent| meta.parent.as_ref() == Some(parent)))
        .map(|meta| info(root, panes, meta))
        .filter(|info| match show {
            Show::All => true,
            Show::Live => info.run.outcome.is_none(),
            Show::Present => panes.iter().any(|pane| {
                info.run.meta.pane == Some(pane.id) && pane.run.as_ref() == Some(&info.run.meta.id)
            }),
        })
        .collect();
    found.sort_by_key(|info| std::cmp::Reverse(info.run.meta.started_at));
    found
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::Close;
    use ko_sys::clock::Mono;
    const NOW: u64 = 1_000_000_000_000;

    struct Scratch(PathBuf);

    impl Scratch {
        fn new(name: &str) -> Scratch {
            let dir = PathBuf::from(format!("/tmp/ko-runs-{name}-{}", std::process::id()));
            let _ = fs::remove_dir_all(&dir);
            fs::create_dir_all(&dir).unwrap();
            Scratch(dir)
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn run(index: u8) -> RunId {
        format!("{index:032x}").parse().unwrap()
    }

    fn pane(number: u64) -> PaneId {
        PaneId::new(number)
    }

    fn meta(root: &Path, index: u8, parent: Option<Parent>, on: Option<u64>) -> Meta {
        let meta = Meta {
            id: run(index),
            name: RunName::new(&format!("run-{index}")).unwrap(),
            parent,
            pane: on.map(pane),
            runtime: None,
            argv: vec!["run".to_owned()],
            cwd: "/tmp".to_owned(),
            started_at: Timestamp::from_micros(i64::from(index) * 1_000_000),
        };
        write_meta(root, &meta).unwrap();
        meta
    }

    fn seen<'a>(number: u64, index: Option<u8>, condition: Condition<'a>) -> Seen<'a> {
        Seen {
            id: pane(number),
            run: index.map(run),
            condition,
            parent: None,
            close: Close::OnExit,
            shown: false,
        }
    }

    fn dead(secs_ago: u64, cause: &Cause) -> Condition<'_> {
        Condition::Dead {
            at: Mono::from_nanos(NOW - secs_ago * 1_000_000_000),
            cause,
        }
    }

    fn closed(closings: &[Closing]) -> Vec<(u64, String)> {
        closings
            .iter()
            .map(|closing| {
                (
                    closing
                        .pane
                        .to_string()
                        .trim_start_matches("pane_")
                        .parse()
                        .unwrap(),
                    closing.run.as_ref().map_or_else(
                        || "no run".to_owned(),
                        |(_, outcome)| format!("{} {}", outcome.result, outcome.text),
                    ),
                )
            })
            .collect()
    }

    #[test]
    fn names_are_short_and_plain() {
        assert!(RunName::new(&"n".repeat(64)).is_ok());
        assert_eq!(
            RunName::new(&"n".repeat(65)),
            Err(format!(
                "refusing run name {:?}: 65 bytes is over the 64 byte limit",
                "n".repeat(65)
            ))
        );
        assert!(RunName::new("a\nb").is_err());
        assert!(RunName::new("").is_ok());
    }

    #[test]
    fn a_parent_is_a_pane_or_a_run_and_nothing_else() {
        let id = run(7).to_string();
        assert_eq!(id.parse(), Ok(Parent::Run(run(7))));
        assert_eq!("pane_4".parse(), Ok(Parent::Pane(pane(4))));
        for text in ["", "../x", "pane_x", "pane_", "%4", "abc"] {
            assert_eq!(
                text.parse::<Parent>(),
                Err(format!("invalid parent {text:?}"))
            );
        }
        assert_eq!(Parent::Pane(pane(4)).to_string(), "pane_4");
    }

    #[test]
    fn a_dead_pane_gives_the_ending_of_its_status() {
        let cause = Cause::Exit;
        fn ending(condition: Condition<'_>) -> Option<(String, String)> {
            ended_by_pane(Some(condition)).map(|outcome| (outcome.result.to_string(), outcome.text))
        }
        let at = Mono::from_nanos(0);
        let table = [
            (cause(Exit::Exited(0)), "completed", ""),
            (cause(Exit::Exited(3)), "failed", "exit 3"),
            (
                cause(Exit::Signaled(libc::SIGTERM)),
                "failed",
                "signal TERM",
            ),
            (cause(Exit::Signaled(77)), "failed", "signal 77"),
            (Cause::Failed("spawn".to_owned()), "died", ""),
        ];
        for (cause, result, text) in table {
            assert_eq!(
                ending(Condition::Dead { at, cause: &cause }),
                Some((result.to_owned(), text.to_owned()))
            );
        }
        assert_eq!(ended_by_pane(Some(Condition::Live)), None);
        assert_eq!(
            ended_by_pane(None).map(|outcome| outcome.result),
            Some(RunResult::Died)
        );
    }

    #[test]
    fn an_outcome_is_one_atomic_file() {
        let scratch = Scratch::new("first");
        let root = &scratch.0;
        meta(root, 1, None, None);
        let outcome = |result| RunOutcome {
            result,
            text: String::new(),
            at: None,
        };
        assert!(record_outcome_once(
            root,
            &run(1),
            &outcome(RunResult::Completed)
        ));
        assert!(!record_outcome_once(
            root,
            &run(1),
            &outcome(RunResult::Died)
        ));
        assert_eq!(
            read_outcome(root, &run(1)).map(|outcome| outcome.result),
            Some(RunResult::Completed)
        );
        assert!(!record_outcome_once(
            root,
            &run(2),
            &outcome(RunResult::Died)
        ));
        let mut names: Vec<_> = fs::read_dir(run_dir(root, &run(1)))
            .unwrap()
            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
            .collect();
        names.sort();
        assert_eq!(names, ["meta.json", "outcome"]);
    }

    #[test]
    fn a_pane_row_has_its_run_with_the_pane_named_and_the_ending_of_the_pane() {
        let scratch = Scratch::new("row");
        let root = &scratch.0;
        meta(root, 1, None, None);
        let row = |run_id, condition| row(root, pane(1), &run(run_id), condition);
        let found = row(1, Condition::Live).unwrap();
        assert_eq!(
            (found.meta.pane, found.meta.argv, found.outcome),
            (Some(pane(1)), vec!["run".to_owned()], None)
        );
        let cause = Cause::Exit(Exit::Exited(3));
        assert_eq!(
            row(1, dead(5, &cause)).and_then(|row| row.outcome.map(|o| (o.result, o.text))),
            Some((RunResult::Failed, "exit 3".to_owned()))
        );
        assert_eq!(row(4, Condition::Live), None, "no such run");
        record_outcome_once(
            root,
            &run(1),
            &RunOutcome {
                result: RunResult::Stopped,
                text: String::new(),
                at: None,
            },
        );
        assert_eq!(
            row(1, dead(5, &cause)).and_then(|row| row.outcome.map(|o| o.result)),
            Some(RunResult::Stopped),
            "a recorded outcome wins over the pane's"
        );
    }

    #[test]
    fn an_outcome_file_wins_over_the_pane() {
        let scratch = Scratch::new("wins");
        let root = &scratch.0;
        let m = meta(root, 1, None, Some(1));
        let cause = Cause::Exit(Exit::Exited(3));
        let panes = [seen(1, Some(1), dead(5, &cause))];
        assert_eq!(
            ending(root, &panes, &m).map(|o| (o.result, o.text)),
            Some((RunResult::Failed, "exit 3".to_owned()))
        );
        record_outcome_once(
            root,
            &run(1),
            &RunOutcome {
                result: RunResult::Stopped,
                text: String::new(),
                at: None,
            },
        );
        assert_eq!(
            ending(root, &panes, &m).map(|o| o.result),
            Some(RunResult::Stopped)
        );
        assert_eq!(
            ending(
                root,
                &[seen(1, Some(2), Condition::Live)],
                &meta(root, 2, None, Some(1))
            ),
            None
        );
        assert_eq!(
            ending(root, &[], &m).map(|o| o.result),
            Some(RunResult::Stopped),
            "an outcome outlives the pane"
        );
        assert_eq!(
            ending(root, &[], &meta(root, 3, None, Some(1))).map(|o| o.result),
            Some(RunResult::Died),
            "a pane that is gone is a run that died"
        );
        assert_eq!(
            ending(
                root,
                &[seen(1, Some(9), Condition::Live)],
                &meta(root, 4, None, Some(1))
            )
            .map(|o| o.result),
            Some(RunResult::Died),
            "a pane whose variable names another run is not the run's pane"
        );
    }

    #[test]
    fn a_removed_pane_gives_its_run_the_ending_of_its_pane_or_of_its_parent() {
        let scratch = Scratch::new("closing");
        let root = &scratch.0;
        for index in 1..=4 {
            meta(root, index, None, Some(u64::from(index)));
        }
        let (exit3, signal) = (
            Cause::Exit(Exit::Exited(3)),
            Cause::Exit(Exit::Signaled(libc::SIGTERM)),
        );
        record_outcome_once(
            root,
            &run(4),
            &RunOutcome {
                result: RunResult::Completed,
                text: String::new(),
                at: None,
            },
        );
        let panes = [
            seen(1, Some(1), dead(2, &exit3)),
            seen(2, Some(2), dead(2, &signal)),
            seen(3, Some(3), Condition::Live),
            seen(4, Some(4), dead(2, &exit3)),
            seen(5, None, Condition::Live),
            seen(6, Some(1), Condition::Live),
        ];
        let removed: Vec<PaneId> = (1..=6).map(pane).collect();
        assert_eq!(
            closed(&closing(root, &panes, &removed)),
            [
                (1, "failed exit 3".to_owned()),
                (2, "failed signal TERM".to_owned()),
                (3, "failed its parent ended".to_owned()),
                (4, "completed ".to_owned()),
                (5, "no run".to_owned()),
                (6, "no run".to_owned()),
            ],
            "a pane that no run names gets no record, and the recorded outcome wins"
        );
    }

    #[test]
    fn a_parent_run_gives_its_pane_and_an_unknown_or_ended_one_is_refused() {
        let scratch = Scratch::new("ended");
        let root = &scratch.0;
        meta(root, 1, None, Some(1));
        meta(root, 3, None, None);
        let live = [seen(1, Some(1), Condition::Live)];
        let found = |parent: Parent| parent_pane(root, &live, &parent);
        assert_eq!(found(Parent::Run(run(1))), Ok(pane(1)));
        assert_eq!(found(Parent::Pane(pane(8))), Ok(pane(8)));
        assert_eq!(
            found(Parent::Run(run(2))),
            Err(Ended::Unknown(format!("no run {}", run(2))))
        );
        assert_eq!(
            found(Parent::Run(run(3))),
            Err(Ended::Unknown(format!("run {} has no pane", run(3))))
        );
        record_outcome_once(
            root,
            &run(1),
            &RunOutcome {
                result: RunResult::Stopped,
                text: String::new(),
                at: None,
            },
        );
        assert_eq!(
            found(Parent::Run(run(1))),
            Err(Ended::Over(format!("run {} has ended", run(1))))
        );
    }

    #[test]
    fn a_listing_is_newest_first_and_live_by_default() {
        let scratch = Scratch::new("list");
        let root = &scratch.0;
        meta(root, 1, None, Some(1));
        meta(root, 2, Some(Parent::Run(run(1))), Some(2));
        meta(root, 3, Some(Parent::Run(run(1))), Some(3));
        let cause = Cause::Exit(Exit::Exited(0));
        let panes = [
            seen(1, Some(1), Condition::Live),
            seen(2, Some(2), Condition::Live),
            seen(3, Some(3), dead(1, &cause)),
        ];
        let names = |show, parent: Option<&Parent>| -> Vec<String> {
            infos(root, &panes, show, parent)
                .iter()
                .map(|info| info.run.meta.name.as_str().to_owned())
                .collect()
        };
        assert_eq!(names(Show::Live, None), ["run-2", "run-1"]);
        assert_eq!(names(Show::All, None), ["run-3", "run-2", "run-1"]);
        assert_eq!(
            names(Show::Present, Some(&Parent::Run(run(1)))),
            ["run-3", "run-2"]
        );
        assert_eq!(
            names(Show::Live, Some(&Parent::Pane(pane(1)))),
            Vec::<String>::new()
        );
        assert_eq!(names(Show::Present, None).len(), 3);
        assert_eq!(
            detail(root, &panes, &run(3)).map(|d| d.run.outcome.map(|o| o.result)),
            Some(Some(RunResult::Completed))
        );
        assert_eq!(detail(root, &panes, &run(9)), None);
    }

    #[test]
    fn a_record_is_json_with_the_names_of_the_harness_contract() {
        let scratch = Scratch::new("json");
        let root = &scratch.0;
        let m = meta(root, 1, Some(Parent::Pane(pane(4))), Some(2));
        let panes = [seen(2, Some(1), Condition::Live)];
        let info = infos(root, &panes, Show::Live, None).pop().unwrap();
        assert_eq!(
            serde_json::to_value(&info).unwrap(),
            serde_json::json!({
                "id": m.id.to_string(),
                "name": "run-1",
                "parent": "pane_4",
                "pane": "pane_2",
                "argv": ["run"],
                "cwd": "/tmp",
                "startedAt": "1970-01-01T00:00:01Z",
                "output": output_path(root, &m.id).to_string_lossy(),
            })
        );
        assert_eq!(
            serde_json::to_value(RunOutcome {
                result: RunResult::Failed,
                text: "exit 2".to_owned(),
                at: Some(Timestamp::from_micros(2_500_000)),
            })
            .unwrap(),
            serde_json::json!({"result": "failed", "text": "exit 2", "at": "1970-01-01T00:00:02.5Z"})
        );
    }

    #[test]
    fn a_screen_is_cut_to_its_end_at_the_start_of_a_character() {
        assert_eq!(cut_point(b"abcdef", 4), 2);
        assert_eq!(cut_point(b"abc", 4), 0);
        let text = "aé€b".as_bytes();
        assert_eq!(cut_point(text, 4), 3, "the cut at 3 starts the euro sign");
        assert_eq!(
            cut_point(text, 5),
            3,
            "the cut at 2 is inside é and moves on"
        );
        assert_eq!(
            cut_point(text, 3),
            6,
            "the cut at 4 is inside the euro sign and moves on"
        );
        assert_eq!(cut_point(text, 1), 6);
    }
}
