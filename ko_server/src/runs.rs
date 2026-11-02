use std::borrow::Cow;
use std::fmt;
use std::fs::{self, DirBuilder, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::time::Duration;

use ko_sys::clock::Mono;
use ko_sys::pid::Exit;
use schemars::{JsonSchema, Schema, SchemaGenerator, json_schema};
use serde::{Deserialize, Serialize};

use crate::ids::{PaneId, RunId};
use crate::pane_proc::Cause;
use crate::protocol::{Detail, Info, Show};
use crate::timestamp::Timestamp;

const NAME_MAX: usize = 64;
const SCREEN_MAX: usize = 64 * 1024;

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
    pub cwd: String,
    #[serde(rename = "startedAt")]
    pub started_at: Timestamp,
}

#[derive(Debug, Clone, Copy)]
pub(crate) enum Condition<'a> {
    Live,
    Dead { at: Mono, cause: &'a Cause },
}

#[derive(Debug, Clone)]
pub(crate) struct Seen<'a> {
    pub(crate) id: PaneId,
    pub(crate) run: Option<RunId>,
    pub(crate) condition: Condition<'a>,
    pub(crate) agent_session: Option<String>,
    pub(crate) pi_evidence: bool,
    pub(crate) shown: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Ended {
    Unknown(String),
    Over(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Closing {
    pub(crate) pane: PaneId,
    pub(crate) run: RunId,
    pub(crate) outcome: RunOutcome,
}

#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct Swept {
    pub(crate) closing: Vec<Closing>,
    pub(crate) next: Option<Duration>,
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

pub(crate) fn write_command(root: &Path, id: &RunId, argv: &[String]) -> io::Result<()> {
    let mut command = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(file(root, id, "command"))?;
    command.write_all(&serde_json::to_vec(argv)?)
}

pub(crate) fn read_meta(root: &Path, id: &RunId) -> Option<Meta> {
    serde_json::from_slice(&fs::read(file(root, id, "meta.json")).ok()?).ok()
}

fn read_outcome(root: &Path, id: &RunId) -> Option<RunOutcome> {
    serde_json::from_slice(&fs::read(file(root, id, "outcome")).ok()?).ok()
}

pub(crate) fn record_outcome(root: &Path, id: &RunId, outcome: &RunOutcome) -> bool {
    let Ok(body) = serde_json::to_vec(outcome) else {
        return false;
    };
    let path = file(root, id, "outcome");
    let Ok(mut created) = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o644)
        .open(&path)
    else {
        return false;
    };
    if created.write_all(&body).is_err() {
        let _ = fs::remove_file(path);
        return false;
    }
    true
}

fn read_screen(root: &Path, id: &RunId) -> Option<String> {
    fs::read(file(root, id, "screen"))
        .ok()
        .map(|bytes| String::from_utf8_lossy(&bytes).into_owned())
}

pub(crate) fn write_screen(root: &Path, id: &RunId, screen: &[u8]) {
    let tail = screen
        .len()
        .checked_sub(SCREEN_MAX)
        .and_then(|cut| screen.get(cut..))
        .unwrap_or(screen);
    if tail.is_empty() {
        return;
    }
    let temp = file(root, id, "screen.tmp");
    if fs::write(&temp, tail).is_ok() {
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
    read_outcome(root, &meta.id)
        .or_else(|| ended_by_pane(run_pane(panes, meta).map(|pane| pane.condition)))
}

pub(crate) fn parent_ended(root: &Path, panes: &[Seen<'_>], parent: &Parent) -> Option<Ended> {
    match parent {
        Parent::Run(id) => match read_meta(root, id) {
            None => Some(Ended::Unknown(format!("no run {id}"))),
            Some(meta) => {
                ending(root, panes, &meta).map(|_| Ended::Over(format!("run {id} has ended")))
            }
        },
        Parent::Pane(id) => match panes.iter().find(|pane| pane.id == *id) {
            None => Some(Ended::Over(format!("pane {id} is gone"))),
            Some(pane) if matches!(pane.condition, Condition::Dead { .. }) => {
                Some(Ended::Over(format!("pane {id} is dead")))
            }
            Some(pane) if !pane.pi_evidence => Some(Ended::Over(format!("pane {id} shows no pi"))),
            Some(_) => None,
        },
    }
}

pub(crate) fn sweep(root: &Path, panes: &[Seen<'_>], now: Mono, grace: Duration) -> Swept {
    let mut swept = Swept::default();
    for pane in panes {
        let Some(meta) = pane
            .run
            .as_ref()
            .and_then(|id| read_meta(root, id))
            .filter(|meta| meta.pane == Some(pane.id))
        else {
            continue;
        };
        let outcome = match pane.condition {
            Condition::Dead { at, cause } => {
                let age = Duration::from_nanos(now.nanos().saturating_sub(at.nanos()));
                if age < grace {
                    let left = grace.saturating_sub(age);
                    swept.next = Some(swept.next.map_or(left, |next| next.min(left)));
                    continue;
                }
                read_outcome(root, &meta.id).unwrap_or_else(|| dead_outcome(cause))
            }
            Condition::Live => {
                let orphan = meta
                    .parent
                    .as_ref()
                    .is_some_and(|parent| parent_ended(root, panes, parent).is_some());
                if !orphan {
                    continue;
                }
                RunOutcome {
                    result: RunResult::Failed,
                    text: "its parent ended".to_owned(),
                    at: None,
                }
            }
        };
        if !pane.shown {
            swept.closing.push(Closing {
                pane: pane.id,
                run: meta.id,
                outcome,
            });
        }
    }
    swept
}

fn info(root: &Path, panes: &[Seen<'_>], meta: Meta) -> Info {
    let session = run_pane(panes, &meta)
        .filter(|pane| matches!(pane.condition, Condition::Live))
        .and_then(|pane| pane.agent_session.clone());
    Info {
        outcome: ending(root, panes, &meta),
        output: output_path(root, &meta.id).to_string_lossy().into_owned(),
        session,
        meta,
    }
}

pub(crate) fn detail(root: &Path, panes: &[Seen<'_>], id: &RunId) -> Option<Detail> {
    let info = info(root, panes, read_meta(root, id)?);
    Some(Detail {
        screen: read_screen(root, id),
        info,
    })
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
            Show::Live => info.outcome.is_none(),
            Show::Present => panes.iter().any(|pane| {
                info.meta.pane == Some(pane.id) && pane.run.as_ref() == Some(&info.meta.id)
            }),
        })
        .collect();
    found.sort_by_key(|info| std::cmp::Reverse(info.meta.started_at));
    found
}

#[cfg(test)]
mod tests {
    use super::*;

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
            agent_session: None,
            pi_evidence: false,
            shown: false,
        }
    }

    fn dead(secs_ago: u64, cause: &Cause) -> Condition<'_> {
        Condition::Dead {
            at: Mono::from_nanos(NOW - secs_ago * 1_000_000_000),
            cause,
        }
    }

    fn closed(swept: &Swept) -> Vec<(u64, String, String)> {
        swept
            .closing
            .iter()
            .map(|closing| {
                (
                    closing
                        .pane
                        .to_string()
                        .trim_start_matches("pane_")
                        .parse()
                        .unwrap(),
                    closing.outcome.result.to_string(),
                    closing.outcome.text.clone(),
                )
            })
            .collect()
    }

    const GRACE: Duration = Duration::from_secs(1);

    fn swept(root: &Path, panes: &[Seen<'_>]) -> Swept {
        sweep(root, panes, Mono::from_nanos(NOW), GRACE)
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
    fn the_first_outcome_stands() {
        let scratch = Scratch::new("first");
        let root = &scratch.0;
        meta(root, 1, None, None);
        let outcome = |result| RunOutcome {
            result,
            text: String::new(),
            at: None,
        };
        assert!(record_outcome(
            root,
            &run(1),
            &outcome(RunResult::Completed)
        ));
        assert!(!record_outcome(root, &run(1), &outcome(RunResult::Died)));
        assert_eq!(
            read_outcome(root, &run(1)).map(|outcome| outcome.result),
            Some(RunResult::Completed)
        );
        assert!(!record_outcome(root, &run(2), &outcome(RunResult::Died)));
        let mut names: Vec<_> = fs::read_dir(run_dir(root, &run(1)))
            .unwrap()
            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
            .collect();
        names.sort();
        assert_eq!(names, ["meta.json", "outcome"]);
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
        record_outcome(
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
    fn rule_one_waits_for_the_grace_and_records_the_ending() {
        let scratch = Scratch::new("grace");
        let root = &scratch.0;
        meta(root, 1, None, Some(1));
        meta(root, 2, None, Some(2));
        meta(root, 3, None, Some(3));
        let (young, exit3, signal) = (
            Cause::Exit(Exit::Exited(0)),
            Cause::Exit(Exit::Exited(3)),
            Cause::Exit(Exit::Signaled(libc::SIGTERM)),
        );
        let outcome = swept(
            root,
            &[
                seen(
                    1,
                    Some(1),
                    Condition::Dead {
                        at: Mono::from_nanos(NOW - 400_000_000),
                        cause: &young,
                    },
                ),
                seen(2, Some(2), dead(2, &exit3)),
                seen(3, Some(3), dead(2, &signal)),
            ],
        );
        assert_eq!(
            closed(&outcome),
            [
                (2, "failed".to_owned(), "exit 3".to_owned()),
                (3, "failed".to_owned(), "signal TERM".to_owned())
            ]
        );
        assert_eq!(outcome.next, Some(Duration::from_millis(600)));
    }

    #[test]
    fn the_sweep_acts_only_on_a_pane_that_the_run_names() {
        let scratch = Scratch::new("trust");
        let root = &scratch.0;
        meta(root, 1, None, Some(1));
        let cause = Cause::Exit(Exit::Exited(0));
        assert_eq!(
            closed(&swept(root, &[seen(2, Some(1), dead(5, &cause))])),
            [],
            "the meta names pane 1, not pane 2"
        );
        assert_eq!(
            closed(&swept(root, &[seen(1, None, dead(5, &cause))])),
            [],
            "a pane without the variable is the user's"
        );
        assert_eq!(
            closed(&swept(root, &[seen(1, Some(5), dead(5, &cause))])),
            [],
            "a variable for a run without a record"
        );
        let mut shown = seen(1, Some(1), dead(5, &cause));
        shown.shown = true;
        assert_eq!(
            closed(&swept(root, &[shown])),
            [],
            "a pane that a client shows stays"
        );
    }

    #[test]
    fn rule_two_reads_the_status_of_the_parent() {
        let scratch = Scratch::new("orphan");
        let root = &scratch.0;
        let cause = Cause::Exit(Exit::Exited(0));
        let parent_pane = |condition, evidence| Seen {
            pi_evidence: evidence,
            ..seen(9, None, condition)
        };
        let child = |label: u8, parent: Option<Parent>| {
            meta(root, label, parent, Some(1));
            seen(1, Some(label), Condition::Live)
        };
        let outcome = |label: &str, child: Seen<'_>, others: Vec<Seen<'_>>| {
            let mut panes = vec![child];
            panes.extend(others);
            (label.to_owned(), closed(&swept(root, &panes)).len())
        };
        let by_pane = Some(Parent::Pane(pane(9)));
        meta(root, 50, None, Some(9));
        let by_run = Some(Parent::Run(run(50)));
        let results = vec![
            outcome("parentless", child(10, None), vec![]),
            outcome(
                "pane alive",
                child(11, by_pane.clone()),
                vec![parent_pane(Condition::Live, true)],
            ),
            outcome(
                "pane without pi evidence",
                child(12, by_pane.clone()),
                vec![parent_pane(Condition::Live, false)],
            ),
            outcome(
                "pane dead",
                child(13, by_pane.clone()),
                vec![parent_pane(dead(0, &cause), true)],
            ),
            outcome("pane gone", child(14, by_pane), vec![]),
            outcome(
                "run alive",
                child(15, by_run.clone()),
                vec![seen(9, Some(50), Condition::Live)],
            ),
            outcome("run gone", child(16, Some(Parent::Run(run(60)))), vec![]),
            outcome(
                "run dead",
                child(17, by_run.clone()),
                vec![seen(9, Some(50), dead(0, &cause))],
            ),
        ];
        assert_eq!(
            results,
            [
                ("parentless".to_owned(), 0),
                ("pane alive".to_owned(), 0),
                ("pane without pi evidence".to_owned(), 1),
                ("pane dead".to_owned(), 1),
                ("pane gone".to_owned(), 1),
                ("run alive".to_owned(), 0),
                ("run gone".to_owned(), 1),
                ("run dead".to_owned(), 1),
            ]
        );
        record_outcome(
            root,
            &run(50),
            &RunOutcome {
                result: RunResult::Completed,
                text: String::new(),
                at: None,
            },
        );
        let panes = [child(18, by_run), seen(9, Some(50), Condition::Live)];
        assert_eq!(
            closed(&swept(root, &panes)),
            [(1, "failed".to_owned(), "its parent ended".to_owned())]
        );
    }

    #[test]
    fn an_unknown_parent_differs_from_an_ended_one() {
        let scratch = Scratch::new("ended");
        let root = &scratch.0;
        meta(root, 1, None, Some(1));
        let live = [seen(1, Some(1), Condition::Live)];
        let ended = |parent: Parent| parent_ended(root, &live, &parent);
        assert_eq!(ended(Parent::Run(run(1))), None);
        assert_eq!(
            ended(Parent::Run(run(2))),
            Some(Ended::Unknown(format!("no run {}", run(2))))
        );
        assert_eq!(
            ended(Parent::Pane(pane(8))),
            Some(Ended::Over("pane pane_8 is gone".to_owned()))
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
                .map(|info| info.meta.name.as_str().to_owned())
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
            detail(root, &panes, &run(3)).map(|d| d.info.outcome.map(|o| o.result)),
            Some(Some(RunResult::Completed))
        );
        assert_eq!(detail(root, &panes, &run(9)), None);
    }

    #[test]
    fn the_session_shows_while_the_pane_lives_and_is_a_pi() {
        let scratch = Scratch::new("session");
        let root = &scratch.0;
        meta(root, 1, None, Some(1));
        let mut agent = seen(1, Some(1), Condition::Live);
        agent.agent_session = Some("s-1".to_owned());
        let cause = Cause::Exit(Exit::Exited(0));
        let mut gone = seen(1, Some(1), dead(1, &cause));
        gone.agent_session = Some("s-1".to_owned());
        let session = |pane: Seen<'_>| {
            infos(root, &[pane], Show::All, None)
                .pop()
                .and_then(|info| info.session)
        };
        assert_eq!(session(agent), Some("s-1".to_owned()));
        assert_eq!(session(gone), None);
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
    fn a_screen_keeps_its_tail() {
        let scratch = Scratch::new("screen");
        let root = &scratch.0;
        meta(root, 1, None, None);
        write_screen(root, &run(1), b"");
        assert_eq!(read_screen(root, &run(1)), None);
        let long = [vec![b'x'; 10], vec![b'y'; SCREEN_MAX]].concat();
        write_screen(root, &run(1), &long);
        assert_eq!(read_screen(root, &run(1)), Some("y".repeat(SCREEN_MAX)));
    }
}
