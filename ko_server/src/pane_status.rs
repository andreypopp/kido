use std::collections::BTreeMap;

use crate::pane_kind::{self, Kind, RemoteKind};
use crate::program_status::app;
use crate::protocol::{
    Agent, AgentState, CommandExit, Live, Origin, Outcome, OutcomeResult, Phase, ProgramKind,
    ProgramRecord, ProgramState, ProgramStatus, Remote, Shell,
};
use crate::telemetry::Telemetry;

pub(crate) const DEBOUNCE: u64 = 200_000_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Shown {
    Running,
    Waiting,
    Idle(Option<Outcome>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Retained {
    outcome: Outcome,
    id: String,
    at: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Episode {
    finals: BTreeMap<String, OutcomeResult>,
    retained: Option<Retained>,
    shown: Option<Shown>,
    since: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Command {
    start: u64,
    observed: u64,
    promoted: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Root {
    Agent(String),
    Program,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Identity {
    root: Root,
    session: Option<String>,
    ssh: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Track {
    identity: Identity,
    episode: Episode,
    last: Option<CommandExit>,
    command: Option<Command>,
    interactive: bool,
}

#[derive(Debug, Clone, Copy)]
enum Activity {
    Running(Option<u8>),
    Waiting(Option<ProgramKind>, Option<u8>),
    Idle,
}

fn final_result(record: &ProgramRecord) -> Option<OutcomeResult> {
    match record.state {
        ProgramState::Done => Some(OutcomeResult::Success),
        ProgramState::Error => Some(OutcomeResult::Failure),
        _ => None,
    }
}

fn advance(
    now: u64,
    serial: u64,
    activity: Activity,
    records: &[ProgramRecord],
    e: &Episode,
) -> Episode {
    let entered = records.iter().find_map(|record| {
        let result = final_result(record)?;
        (e.finals.get(&record.id) != Some(&result)).then(|| Retained {
            outcome: Outcome { serial, result },
            id: record.id.clone(),
            at: now,
        })
    });
    let retained = match (&e.shown, activity) {
        (Some(Shown::Idle(_)), Activity::Running(_) | Activity::Waiting(..)) => None,
        _ => e.retained.clone(),
    };
    let retained = entered.or(retained);
    let key = match activity {
        Activity::Idle => Shown::Idle(retained.as_ref().map(|retained| retained.outcome)),
        Activity::Running(_) => Shown::Running,
        Activity::Waiting(..) => Shown::Waiting,
    };
    Episode {
        finals: records
            .iter()
            .filter_map(|record| Some((record.id.clone(), final_result(record)?)))
            .collect(),
        retained,
        shown: Some(key),
        since: if e.shown == Some(key) { e.since } else { now },
    }
}

fn representative<'a>(e: &Episode, records: &'a [ProgramRecord]) -> Option<&'a ProgramRecord> {
    let first = |keep: &dyn Fn(&ProgramRecord) -> bool| records.iter().find(|record| keep(record));
    first(&|record| matches!(record.state, ProgramState::Blocked { .. }))
        .or_else(|| first(&|record| matches!(record.state, ProgramState::Working { .. })))
        .or_else(|| {
            let retained = e.retained.as_ref()?;
            first(&|record| record.id == retained.id)
        })
        .or_else(|| first(&|record| matches!(record.state, ProgramState::Idle)))
        .or_else(|| records.first())
}

fn core(
    now: u64,
    serial: u64,
    msg: impl FnOnce(Option<String>) -> Option<String>,
    records: &[ProgramRecord],
    e: &Episode,
) -> (Episode, Agent) {
    let blocked = records.iter().find_map(|record| match record.state {
        ProgramState::Blocked { kind, progress } => Some((kind, progress)),
        _ => None,
    });
    let working = records.iter().find_map(|record| match record.state {
        ProgramState::Working { progress } => Some(progress),
        _ => None,
    });
    let activity = match (blocked, working) {
        (Some((kind, progress)), _) => Activity::Waiting(kind, progress),
        (None, Some(progress)) => Activity::Running(progress),
        (None, None) => Activity::Idle,
    };
    let e = advance(now, serial, activity, records, e);
    let msg = msg(representative(&e, records).and_then(|record| record.msg.clone()));
    let state = match activity {
        Activity::Waiting(kind, progress) => AgentState::Waiting { kind, progress },
        Activity::Running(progress) => AgentState::Running { progress },
        Activity::Idle => AgentState::Idle {
            outcome: match e.shown {
                Some(Shown::Idle(outcome)) => outcome,
                _ => None,
            },
        },
    };
    let agent = Agent {
        since: e.since,
        msg,
        state,
    };
    (e, agent)
}

fn report(
    now: u64,
    serial: u64,
    records: &[ProgramRecord],
    e: &Episode,
) -> (Episode, Option<Agent>) {
    let (e, agent) = core(now, serial, |msg| msg, records, e);
    if records.is_empty() && e.retained.is_none() {
        (Episode { shown: None, ..e }, None)
    } else {
        (e, Some(agent))
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Reading {
    Unintegrated,
    Exited(CommandExit),
    Prompt,
    Command {
        command: String,
        started_at: u64,
        prompted: bool,
    },
}

fn reading(transport: bool, telemetry: &Telemetry) -> Reading {
    let command = telemetry.command.as_ref();
    let running = command.filter(|command| command.running);
    match (command, running, telemetry.last_exit) {
        (Some(command), _, _) if transport => Reading::Command {
            command: command.line.clone(),
            started_at: command.started_at,
            prompted: telemetry.last_prompt.is_some(),
        },
        (None, ..) if transport => Reading::Unintegrated,
        (_, Some(command), _) => Reading::Command {
            command: command.line.clone(),
            started_at: command.started_at,
            prompted: true,
        },
        (Some(command), None, Some(exit)) => Reading::Exited(CommandExit {
            code: exit.code,
            command: command.line.clone(),
            started_at: command.started_at,
            ended_at: exit.at,
        }),
        _ if telemetry.last_prompt.is_some() => Reading::Prompt,
        _ => Reading::Unintegrated,
    }
}

fn fullscreen_or(fullscreen: bool, otherwise: Phase) -> Phase {
    if fullscreen {
        Phase::Running {
            origin: Origin::Unknown,
            fullscreen: true,
        }
    } else {
        otherwise
    }
}

fn shell(
    now: u64,
    fullscreen: bool,
    serial: u64,
    records: &[ProgramRecord],
    reading: Reading,
    mut t: Track,
) -> (Track, Shell) {
    let phase = match reading {
        Reading::Command {
            command,
            started_at,
            prompted,
        } => {
            let mut cmd = match t.command {
                Some(known) if known.start == started_at => known,
                _ => Command {
                    start: started_at,
                    observed: now,
                    promoted: false,
                },
            };
            let promote =
                !cmd.promoted && (fullscreen || now.saturating_sub(cmd.observed) >= DEBOUNCE);
            if promote {
                t.last = None;
                t.episode.retained = t
                    .episode
                    .retained
                    .take()
                    .filter(|retained| retained.at >= cmd.observed);
            }
            cmd.promoted |= promote;
            t.command = Some(cmd);
            if cmd.promoted {
                Phase::Running {
                    origin: Origin::Command {
                        command,
                        started_at,
                    },
                    fullscreen,
                }
            } else if prompted {
                Phase::Idle {
                    last: t.last.clone(),
                }
            } else {
                Phase::Unknown
            }
        }
        Reading::Exited(exit) => {
            t.last = Some(exit.clone());
            t.command = None;
            fullscreen_or(fullscreen, Phase::Idle { last: Some(exit) })
        }
        Reading::Prompt => {
            if t.command.is_some() {
                t.last = None;
            }
            t.command = None;
            fullscreen_or(
                fullscreen,
                Phase::Idle {
                    last: t.last.clone(),
                },
            )
        }
        Reading::Unintegrated => {
            t.command = None;
            fullscreen_or(fullscreen, Phase::Unknown)
        }
    };
    let (episode, report) = report(now, serial, records, &t.episode);
    t.episode = episode;
    (t, Shell { phase, report })
}

fn identity(kind: &Kind) -> Identity {
    Identity {
        root: match kind {
            Kind::SomeAgent { name }
            | Kind::Ssh {
                pane: RemoteKind::Agent { name },
                ..
            } => Root::Agent(name.clone()),
            Kind::PiAgent { .. } => Root::Agent("pi".to_owned()),
            Kind::Terminal
            | Kind::Ssh {
                pane: RemoteKind::Terminal,
                ..
            } => Root::Program,
        },
        session: match kind {
            Kind::PiAgent { session, .. } => Some(session.clone()),
            _ => None,
        },
        ssh: match kind {
            Kind::Ssh { destination, .. } => Some(destination.clone()),
            _ => None,
        },
    }
}

pub(crate) fn observe(
    now: u64,
    telemetry: &Telemetry,
    pane_title: &str,
    kind: &Kind,
    status: &ProgramStatus,
    prev: Option<Track>,
) -> (Track, Live) {
    let identity = identity(kind);
    let mut t = match prev {
        Some(t) if t.identity == identity => t,
        _ => Track {
            identity,
            episode: Episode {
                finals: BTreeMap::new(),
                retained: None,
                shown: None,
                since: now,
            },
            last: None,
            command: None,
            interactive: false,
        },
    };
    let (serial, records) = (status.serial, status.records.as_slice());
    let title = pane_kind::title(kind, pane_title).unwrap_or_default();
    let agent = |t: &mut Track, dedupe: bool, fallback: Option<String>| {
        let (episode, agent) = core(
            now,
            serial,
            |msg| {
                msg.filter(|msg| {
                    !(dedupe && (title == *msg || title.starts_with(&format!("{msg} - "))))
                })
                .or(fallback)
            },
            records,
            &t.episode,
        );
        t.episode = episode;
        agent
    };
    let fullscreen = telemetry.alternate;
    let live = match kind {
        Kind::Terminal => {
            let (next, shell) = shell(
                now,
                fullscreen,
                serial,
                records,
                reading(false, telemetry),
                t,
            );
            t = next;
            Live::Terminal(shell)
        }
        Kind::SomeAgent { name } => Live::SomeAgent {
            name: name.clone(),
            status: agent(&mut t, false, None),
        },
        Kind::PiAgent {
            session, activity, ..
        } => Live::PiAgent {
            session: session.clone(),
            status: agent(
                &mut t,
                true,
                (!activity.is_empty()).then(|| activity.clone()),
            ),
        },
        Kind::Ssh {
            destination,
            pane: RemoteKind::Agent { name },
        } => Live::Ssh {
            destination: destination.clone(),
            pane: Remote::Agent {
                name: name.clone(),
                status: agent(&mut t, false, None),
            },
        },
        Kind::Ssh {
            destination,
            pane: RemoteKind::Terminal,
        } => {
            t.interactive |= match (telemetry.last_prompt, &telemetry.command) {
                (Some(prompt), Some(command)) => prompt > command.started_at,
                _ => false,
            };
            let interactive = t.interactive;
            let (next, status) = shell(
                now,
                fullscreen,
                serial,
                records,
                reading(!interactive, telemetry),
                t,
            );
            t = next;
            Live::Ssh {
                destination: destination.clone(),
                pane: Remote::Terminal {
                    interactive,
                    status,
                },
            }
        }
    };
    (t, live)
}

pub(crate) fn pending(t: &Track) -> Option<u64> {
    t.command
        .filter(|command| !command.promoted)
        .map(|command| command.observed)
}

pub(crate) fn label(t: &Track, telemetry: &Telemetry, records: &[ProgramRecord]) -> String {
    let foreground = telemetry.foreground_name();
    match representative(&t.episode, records) {
        Some(ProgramRecord {
            title: Some(title), ..
        }) => title.clone(),
        Some(record) => app(records, record).unwrap_or(foreground).to_owned(),
        None => foreground.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::ids::VarName;
    use crate::pane_kind::classify;
    use crate::protocol::Foreground;
    use crate::telemetry::{CommandRun, LastExit};
    use crate::vars::Vars;

    const T0: u64 = 1_000_000_000_000;
    const MS: u64 = 1_000_000;

    fn at(offset_ms: i64) -> u64 {
        T0.saturating_add_signed(offset_ms * MS as i64)
    }

    fn seconds(nanos: u64) -> f64 {
        (nanos as f64 - T0 as f64) / 1e9
    }

    fn rec(id: &str, state: ProgramState, app: Option<&str>, msg: Option<&str>) -> ProgramRecord {
        ProgramRecord {
            id: id.to_owned(),
            started: None,
            state,
            app: app.map(str::to_owned),
            title: None,
            msg: msg.map(str::to_owned),
        }
    }

    fn status(serial: u64, mut records: Vec<ProgramRecord>) -> ProgramStatus {
        records.sort_by(|a, b| a.id.cmp(&b.id));
        ProgramStatus { serial, records }
    }

    fn outcome(outcome: Option<Outcome>) -> String {
        outcome.map_or(String::new(), |outcome| {
            let result = match outcome.result {
                OutcomeResult::Success => "success",
                OutcomeResult::Failure => "failure",
            };
            format!(":{result}@{}", outcome.serial)
        })
    }

    fn percent(progress: Option<u8>) -> String {
        progress.map_or(String::new(), |percent| format!("({percent}%)"))
    }

    fn agent_text(agent: &Agent) -> String {
        let state = match agent.state {
            AgentState::Running { progress } => format!("running{}", percent(progress)),
            AgentState::Waiting { kind, progress } => {
                let kind = match kind {
                    None => "none",
                    Some(ProgramKind::Permission) => "permission",
                    Some(ProgramKind::Question) => "question",
                    Some(ProgramKind::Auth) => "auth",
                };
                format!("waiting:{kind}{}", percent(progress))
            }
            AgentState::Idle { outcome: o } => format!("idle{}", outcome(o)),
        };
        let msg = agent
            .msg
            .as_ref()
            .map_or(String::new(), |msg| format!(" msg={msg:?}"));
        format!("{state} since=+{:.1}{msg}", seconds(agent.since))
    }

    fn shell_text(shell: &Shell) -> String {
        let phase = match &shell.phase {
            Phase::Unknown => "unknown".to_owned(),
            Phase::Idle { last: None } => "idle".to_owned(),
            Phase::Idle { last: Some(exit) } => format!(
                "idle last={} {:?} {:.0}-{:.0}",
                exit.code,
                exit.command,
                seconds(exit.started_at),
                seconds(exit.ended_at)
            ),
            Phase::Running {
                origin:
                    Origin::Command {
                        command,
                        started_at,
                    },
                fullscreen,
            } => format!(
                "running {command:?} {:.0}{}",
                seconds(*started_at),
                if *fullscreen { " fullscreen" } else { "" }
            ),
            Phase::Running {
                origin: Origin::Unknown,
                ..
            } => "running ? fullscreen".to_owned(),
        };
        match &shell.report {
            Some(agent) => format!("{phase} | report {}", agent_text(agent)),
            None => phase,
        }
    }

    fn text(live: &Live) -> String {
        match live {
            Live::Terminal(shell) => shell_text(shell),
            Live::SomeAgent { status, .. } | Live::PiAgent { status, .. } => agent_text(status),
            Live::Ssh {
                pane: Remote::Agent { status, .. },
                ..
            } => format!("remote {}", agent_text(status)),
            Live::Ssh {
                pane:
                    Remote::Terminal {
                        interactive,
                        status,
                    },
                ..
            } => format!(
                "ssh{} {}",
                if *interactive { " interactive" } else { "" },
                shell_text(status)
            ),
        }
    }

    struct Run {
        track: Option<Track>,
        now: u64,
    }

    impl Run {
        fn new() -> Run {
            Run {
                track: None,
                now: T0,
            }
        }

        fn step(
            &mut self,
            ms: u64,
            label: &str,
            (telemetry, vars): (&Telemetry, &Vars),
            records: &ProgramStatus,
        ) -> String {
            self.now += ms * MS;
            let kind = classify(telemetry, vars, &records.records);
            self.observe(label, 22, telemetry, &kind, records)
        }

        fn observe(
            &mut self,
            label: &str,
            width: usize,
            telemetry: &Telemetry,
            kind: &Kind,
            records: &ProgramStatus,
        ) -> String {
            let (track, live) = observe(
                self.now,
                telemetry,
                "agent",
                kind,
                records,
                self.track.take(),
            );
            self.track = Some(track);
            format!("{label:<width$} {}", text(&live))
        }
    }

    fn working(progress: Option<u8>) -> ProgramState {
        ProgramState::Working { progress }
    }

    fn blocked(kind: Option<ProgramKind>, progress: Option<u8>) -> ProgramState {
        ProgramState::Blocked { kind, progress }
    }

    fn agent(
        app: &str,
        root: ProgramState,
        children: &[(&str, ProgramState)],
    ) -> Vec<ProgramRecord> {
        let mut records = vec![rec("", root, Some(app), None)];
        records.extend(
            children
                .iter()
                .map(|(id, state)| rec(id, *state, None, None)),
        );
        records
    }

    fn agent_steps(steps: Vec<(u64, &str, u64, Vec<ProgramRecord>)>) -> Vec<String> {
        let mut run = Run::new();
        steps
            .into_iter()
            .map(|(ms, label, serial, records)| {
                run.step(
                    ms,
                    label,
                    (&Telemetry::default(), &Vars::default()),
                    &status(serial, records),
                )
            })
            .collect()
    }

    #[test]
    fn agent_precedence_is_waiting_then_running_then_idle_with_ties_bytewise() {
        let shown = agent_steps(vec![
            (0, "idle", 1, agent("pi", ProgramState::Idle, &[])),
            (1000, "working", 1, agent("pi", working(Some(10)), &[])),
            (
                1000,
                "blocked > working",
                1,
                agent(
                    "pi",
                    working(None),
                    &[
                        ("b", blocked(Some(ProgramKind::Question), None)),
                        ("a", blocked(Some(ProgramKind::Auth), Some(3))),
                    ],
                ),
            ),
            (
                1000,
                "working ties by id",
                1,
                agent(
                    "pi",
                    ProgramState::Idle,
                    &[("z", working(Some(9))), ("y", working(Some(8)))],
                ),
            ),
        ]);
        assert_eq!(
            shown,
            [
                "idle                   idle since=+0.0",
                "working                running(10%) since=+1.0",
                "blocked > working      waiting:auth(3%) since=+2.0",
                "working ties by id     running(8%) since=+3.0",
            ]
        );
    }

    #[test]
    fn since_moves_only_on_a_tag_or_idle_outcome_change() {
        let claude = |root, children: &[(&str, ProgramState)]| agent("claude-code", root, children);
        let with_msg = |state, msg: &str| vec![rec("", state, Some("claude-code"), Some(msg))];
        let shown = agent_steps(vec![
            (0, "working", 1, claude(working(Some(1)), &[])),
            (
                1000,
                "progress, msg, serial",
                2,
                with_msg(working(Some(2)), "M"),
            ),
            (
                1000,
                "representative",
                3,
                claude(ProgramState::Idle, &[("a", working(None))]),
            ),
            (
                1000,
                "blocked",
                3,
                claude(blocked(Some(ProgramKind::Permission), None), &[]),
            ),
            (
                1000,
                "kind changes",
                3,
                claude(blocked(Some(ProgramKind::Question), None), &[]),
            ),
            (1000, "idle", 3, claude(ProgramState::Idle, &[])),
            (
                1000,
                "title only",
                3,
                vec![ProgramRecord {
                    title: Some("T".to_owned()),
                    ..rec("", ProgramState::Idle, Some("claude-code"), None)
                }],
            ),
            (1000, "done", 5, claude(ProgramState::Done, &[])),
            (1000, "msg on done", 6, with_msg(ProgramState::Done, "M")),
            (1000, "done -> error", 7, claude(ProgramState::Error, &[])),
        ]);
        assert_eq!(
            shown,
            [
                "working                running(1%) since=+0.0",
                "progress, msg, serial  running(2%) since=+0.0 msg=\"M\"",
                "representative         running since=+0.0",
                "blocked                waiting:permission since=+3.0",
                "kind changes           waiting:question since=+3.0",
                "idle                   idle since=+5.0",
                "title only             idle since=+5.0",
                "done                   idle:success@5 since=+7.0",
                "msg on done            idle:success@5 since=+7.0 msg=\"M\"",
                "done -> error          idle:failure@7 since=+9.0",
            ]
        );
    }

    #[test]
    fn outcome_entries_initial_reappearing_flips_and_unrelated_updates_never_rearm() {
        let claude = |root, children: &[(&str, ProgramState)]| agent("claude-code", root, children);
        let shown = agent_steps(vec![
            (0, "initial final", 4, claude(ProgramState::Done, &[])),
            (
                1000,
                "unchanged, new serial",
                5,
                vec![rec("", ProgramState::Done, Some("claude-code"), Some("M"))],
            ),
            (1000, "error -> ", 6, claude(ProgramState::Error, &[])),
            (1000, "-> done", 7, claude(ProgramState::Done, &[])),
            (1000, "turned idle", 8, claude(ProgramState::Idle, &[])),
            (
                1000,
                "simultaneous",
                9,
                claude(
                    ProgramState::Idle,
                    &[("b", ProgramState::Done), ("a", ProgramState::Error)],
                ),
            ),
            (1000, "removed", 10, claude(ProgramState::Idle, &[])),
            (
                1000,
                "reappears",
                11,
                claude(ProgramState::Idle, &[("b", ProgramState::Done)]),
            ),
        ]);
        assert_eq!(
            shown,
            [
                "initial final          idle:success@4 since=+0.0",
                "unchanged, new serial  idle:success@4 since=+0.0 msg=\"M\"",
                "error ->               idle:failure@6 since=+2.0",
                "-> done                idle:success@7 since=+3.0",
                "turned idle            idle:success@7 since=+3.0",
                "simultaneous           idle:failure@9 since=+5.0",
                "removed                idle:failure@9 since=+5.0",
                "reappears              idle:success@11 since=+7.0",
            ]
        );
    }

    #[test]
    fn outcomes_are_cleared_by_new_work_pending_during_other_work_and_never_resurrected() {
        let claude = |root, children: &[(&str, ProgramState)]| agent("claude-code", root, children);
        let shown = agent_steps(vec![
            (
                0,
                "done",
                1,
                claude(ProgramState::Idle, &[("a", ProgramState::Done)]),
            ),
            (
                1000,
                "new work",
                2,
                claude(working(None), &[("a", ProgramState::Done)]),
            ),
            (
                1000,
                "idle again",
                3,
                claude(ProgramState::Idle, &[("a", ProgramState::Done)]),
            ),
            (
                1000,
                "child ends, root works",
                4,
                claude(
                    working(None),
                    &[("a", ProgramState::Done), ("b", ProgramState::Error)],
                ),
            ),
            (
                1000,
                "blocked meanwhile",
                5,
                claude(
                    blocked(None, None),
                    &[("a", ProgramState::Done), ("b", ProgramState::Error)],
                ),
            ),
            (
                1000,
                "root idle",
                6,
                claude(
                    ProgramState::Idle,
                    &[("a", ProgramState::Done), ("b", ProgramState::Error)],
                ),
            ),
        ]);
        assert_eq!(
            shown,
            [
                "done                   idle:success@1 since=+0.0",
                "new work               running since=+1.0",
                "idle again             idle since=+2.0",
                "child ends, root works running since=+3.0",
                "blocked meanwhile      waiting:none since=+4.0",
                "root idle              idle:failure@4 since=+5.0",
            ]
        );
    }

    #[test]
    fn a_root_app_session_or_ssh_destination_change_resets_tracking() {
        let mut run = Run::new();
        let telemetry = Telemetry::default();
        let mut shown = Vec::new();
        let mut step = |label: &str, kind: &Kind, serial: u64, records: Vec<ProgramRecord>| {
            run.now += 1000 * MS;
            shown.push(run.observe(label, 20, &telemetry, kind, &status(serial, records)));
        };
        let pi = |id: &str| Kind::PiAgent {
            session: id.to_owned(),
            name: String::new(),
            activity: String::new(),
        };
        let done = |app: &str| agent(app, ProgramState::Done, &[]);
        step("pi done", &pi("a"), 1, done("pi"));
        step("same", &pi("a"), 2, done("pi"));
        step("new session id", &pi("b"), 3, done("pi"));
        let claude = Kind::SomeAgent {
            name: "claude-code".to_owned(),
        };
        step("claude replaces pi", &claude, 4, done("claude-code"));
        step("same claude", &claude, 5, done("claude-code"));
        step("root cleared", &Kind::Terminal, 5, Vec::new());
        step("claude again", &claude, 6, done("claude-code"));
        let ssh = |destination: &str| Kind::Ssh {
            destination: destination.to_owned(),
            pane: RemoteKind::Agent {
                name: "pi".to_owned(),
            },
        };
        step("remote pi", &ssh("one"), 7, done("pi"));
        step("same destination", &ssh("one"), 8, done("pi"));
        step("new destination", &ssh("two"), 9, done("pi"));
        assert_eq!(
            shown,
            [
                "pi done              idle:success@1 since=+1.0",
                "same                 idle:success@1 since=+1.0",
                "new session id       idle:success@3 since=+3.0",
                "claude replaces pi   idle:success@4 since=+4.0",
                "same claude          idle:success@4 since=+4.0",
                "root cleared         unknown",
                "claude again         idle:success@6 since=+7.0",
                "remote pi            remote idle:success@7 since=+8.0",
                "same destination     remote idle:success@7 since=+8.0",
                "new destination      remote idle:success@9 since=+10.0",
            ]
        );
    }

    #[derive(Default)]
    struct Pane {
        prompt: Option<i64>,
        start: Option<i64>,
        running: bool,
        exit: Option<(i32, i64)>,
        cmd: &'static str,
        alternate: bool,
        records: Vec<ProgramRecord>,
        serial: u64,
        ssh_host: Option<&'static str>,
    }

    impl Pane {
        fn parts(&self) -> (Telemetry, Vars) {
            let telemetry = Telemetry {
                last_prompt: self.prompt.map(|offset| at(offset * 1000)),
                command: self.start.map(|offset| CommandRun {
                    started_at: at(offset * 1000),
                    line: self.cmd.to_owned(),
                    running: self.running,
                }),
                last_exit: self.exit.map(|(code, offset)| LastExit {
                    code,
                    at: at(offset * 1000),
                }),
                alternate: self.alternate,
                foreground: Some(Foreground {
                    pid: 1,
                    name: if self.ssh_host.is_some() {
                        "ssh"
                    } else {
                        "zsh"
                    }
                    .to_owned(),
                }),
                ..Telemetry::default()
            };
            let mut vars = Vars::default();
            if let Some(host) = self.ssh_host {
                vars.set(&VarName::new("ssh.dest").unwrap(), json!(host))
                    .unwrap();
            }
            (telemetry, vars)
        }

        fn step(&self, run: &mut Run, ms: u64, label: &str) -> String {
            let (telemetry, vars) = self.parts();
            run.step(
                ms,
                label,
                (&telemetry, &vars),
                &status(self.serial, self.records.clone()),
            )
        }
    }

    fn sh(
        prompt: Option<i64>,
        start: Option<i64>,
        running: bool,
        exit: Option<(i32, i64)>,
        cmd: &'static str,
    ) -> Pane {
        Pane {
            prompt,
            start,
            running,
            exit,
            cmd,
            serial: 1,
            ..Pane::default()
        }
    }

    #[test]
    fn shell_debounce_first_observation_successive_commands_and_short_commands() {
        let mut run = Run::new();
        let mut shown = Vec::new();
        let mut go = |ms: u64, label: &str, pane: Pane| shown.push(pane.step(&mut run, ms, label));
        go(
            0,
            "prompt",
            sh(Some(-9), Some(-10), false, Some((0, -9)), "ls"),
        );
        go(
            100,
            "make starts",
            sh(Some(-9), Some(0), true, None, "make"),
        );
        go(150, "debouncing", sh(Some(-9), Some(0), true, None, "make"));
        go(50, "promoted", sh(Some(-9), Some(0), true, None, "make"));
        go(
            1000,
            "next start, no prompt",
            sh(Some(-9), Some(1), true, None, "test"),
        );
        go(250, "promoted", sh(Some(-9), Some(1), true, None, "test"));
        go(
            500,
            "finished",
            sh(Some(2), Some(1), false, Some((2, 2)), "test"),
        );
        go(
            100,
            "short starts",
            sh(Some(2), Some(3), true, None, "true"),
        );
        go(
            50,
            "short finished",
            sh(Some(3), Some(3), false, Some((0, 3)), "true"),
        );
        let mut other = Run::new();
        let mut first =
            |ms: u64, label: &str, pane: Pane| shown.push(pane.step(&mut other, ms, label));
        first(
            0,
            "first read running",
            sh(Some(-9), Some(-5), true, None, "sleep"),
        );
        first(
            190,
            "still debouncing",
            sh(Some(-9), Some(-5), true, None, "sleep"),
        );
        first(10, "promoted", sh(Some(-9), Some(-5), true, None, "sleep"));
        assert_eq!(
            shown,
            [
                "prompt                 idle last=0 \"ls\" -10--9",
                "make starts            idle last=0 \"ls\" -10--9",
                "debouncing             idle last=0 \"ls\" -10--9",
                "promoted               running \"make\" 0",
                "next start, no prompt  idle",
                "promoted               running \"test\" 1",
                "finished               idle last=2 \"test\" 1-2",
                "short starts           idle last=2 \"test\" 1-2",
                "short finished         idle last=0 \"true\" 3-3",
                "first read running     idle",
                "still debouncing       idle",
                "promoted               running \"sleep\" -5",
            ]
        );
    }

    #[test]
    fn a_missing_d_is_not_an_exit_and_unintegrated_is_unknown_never_idle() {
        let mut run = Run::new();
        let mut shown = Vec::new();
        let mut go = |ms: u64, label: &str, pane: Pane| shown.push(pane.step(&mut run, ms, label));
        go(
            0,
            "failed",
            sh(Some(1), Some(0), false, Some((1, 1)), "false"),
        );
        go(100, "next", sh(Some(1), Some(2), true, None, "lost"));
        go(300, "running", sh(Some(1), Some(2), true, None, "lost"));
        go(
            100,
            "healed prompt",
            sh(Some(3), Some(2), false, None, "lost"),
        );
        go(
            100,
            "no integration",
            sh(None, None, false, Some((0, 3)), ""),
        );
        assert_eq!(
            shown,
            [
                "failed                 idle last=1 \"false\" 0-1",
                "next                   idle last=1 \"false\" 0-1",
                "running                running \"lost\" 2",
                "healed prompt          idle",
                "no integration         unknown",
            ]
        );
    }

    #[test]
    fn fullscreen_runs_at_once_keeps_a_known_origin_else_unknown() {
        let mut run = Run::new();
        let mut shown = Vec::new();
        let mut go = |ms: u64, label: &str, alternate: bool, pane: Pane| {
            shown.push(Pane { alternate, ..pane }.step(&mut run, ms, label));
        };
        go(
            0,
            "prompt",
            false,
            sh(Some(-1), Some(-2), false, Some((1, -1)), "false"),
        );
        go(100, "vim", true, sh(Some(-1), Some(0), true, None, "vim"));
        go(
            100,
            "left fullscreen",
            false,
            sh(Some(-1), Some(0), true, None, "vim"),
        );
        go(
            100,
            "finished",
            false,
            sh(Some(1), Some(0), false, Some((0, 1)), "vim"),
        );
        go(
            100,
            "alternate at a prompt",
            true,
            sh(Some(1), Some(0), false, Some((0, 1)), "vim"),
        );
        go(
            100,
            "back",
            false,
            sh(Some(1), Some(0), false, Some((0, 1)), "vim"),
        );
        go(100, "no integration", true, sh(None, None, false, None, ""));
        go(100, "back", false, sh(None, None, false, None, ""));
        assert_eq!(
            shown,
            [
                "prompt                 idle last=1 \"false\" -2--1",
                "vim                    running \"vim\" 0 fullscreen",
                "left fullscreen        running \"vim\" 0",
                "finished               idle last=0 \"vim\" 0-1",
                "alternate at a prompt  running ? fullscreen",
                "back                   idle last=0 \"vim\" 0-1",
                "no integration         running ? fullscreen",
                "back                   unknown",
            ]
        );
    }

    #[test]
    fn a_report_rides_every_phase_and_promotion_drops_only_an_outcome_from_before_it() {
        let built = vec![rec("", ProgramState::Done, Some("make"), Some("Built"))];
        let running = vec![rec("", working(Some(40)), Some("make"), None)];
        let blocked_auth = vec![rec(
            "",
            blocked(Some(ProgramKind::Auth), None),
            Some("make"),
            None,
        )];
        let mut run = Run::new();
        let mut shown = Vec::new();
        let mut go = |ms: u64,
                      label: &str,
                      serial: u64,
                      records: &Vec<ProgramRecord>,
                      alternate: bool,
                      pane: Pane| {
            let pane = Pane {
                serial,
                records: records.clone(),
                alternate,
                ..pane
            };
            shown.push(pane.step(&mut run, ms, label));
        };
        let none = Vec::new();
        go(0, "unknown", 1, &running, false, Pane::default());
        go(
            100,
            "idle, built",
            2,
            &built,
            false,
            sh(Some(0), None, false, None, ""),
        );
        go(
            100,
            "records cleared",
            3,
            &none,
            false,
            sh(Some(0), None, false, None, ""),
        );
        go(
            100,
            "command observed",
            3,
            &none,
            false,
            sh(Some(0), Some(1), true, None, "make"),
        );
        go(
            300,
            "promoted",
            3,
            &none,
            false,
            sh(Some(0), Some(1), true, None, "make"),
        );
        go(
            100,
            "finished",
            3,
            &none,
            false,
            sh(Some(2), Some(1), false, Some((0, 2)), "make"),
        );
        go(
            100,
            "next command",
            4,
            &running,
            false,
            sh(Some(2), Some(3), true, None, "make"),
        );
        go(
            100,
            "built in debounce",
            5,
            &built,
            false,
            sh(Some(2), Some(3), true, None, "make"),
        );
        go(
            200,
            "promoted",
            5,
            &built,
            false,
            sh(Some(2), Some(3), true, None, "make"),
        );
        go(
            100,
            "blocked fullscreen",
            6,
            &blocked_auth,
            true,
            sh(Some(2), Some(3), true, None, "make"),
        );
        go(
            100,
            "new report episode",
            7,
            &none,
            false,
            sh(Some(4), Some(3), false, Some((0, 4)), "make"),
        );
        assert_eq!(
            shown,
            [
                "unknown                unknown | report running(40%) since=+0.0",
                "idle, built            idle | report idle:success@2 since=+0.1 msg=\"Built\"",
                "records cleared        idle | report idle:success@2 since=+0.1",
                "command observed       idle | report idle:success@2 since=+0.1",
                "promoted               running \"make\" 1",
                "finished               idle last=0 \"make\" 1-2",
                "next command           idle last=0 \"make\" 1-2 | report running(40%) since=+0.8",
                "built in debounce      idle last=0 \"make\" 1-2 | report idle:success@5 since=+0.9 msg=\"Built\"",
                "promoted               running \"make\" 3 | report idle:success@5 since=+0.9 msg=\"Built\"",
                "blocked fullscreen     running \"make\" 3 fullscreen | report waiting:auth since=+1.2",
                "new report episode     idle last=0 \"make\" 3-4",
            ]
        );
    }

    #[test]
    fn ssh_is_a_transport_command_until_a_strictly_later_prompt_latched_per_destination() {
        let ssh = |host: &'static str,
                   prompt: i64,
                   start: i64,
                   running: bool,
                   exit: Option<(i32, i64)>,
                   cmd: &'static str| Pane {
            ssh_host: Some(host),
            ..sh(Some(prompt), Some(start), running, exit, cmd)
        };
        let mut run = Run::new();
        let mut shown = Vec::new();
        let mut go = |ms: u64, label: &str, pane: Pane| shown.push(pane.step(&mut run, ms, label));
        go(0, "ssh starts", ssh("box", -1, 0, true, None, "ssh box"));
        go(300, "transport", ssh("box", -1, 0, true, None, "ssh box"));
        go(
            100,
            "same-second prompt",
            ssh("box", 0, 0, true, None, "ssh box"),
        );
        go(
            100,
            "remote prompt",
            ssh("box", 1, 0, false, None, "ssh box"),
        );
        go(
            100,
            "remote command",
            ssh("box", 1, 2, true, None, "sleep 45"),
        );
        go(300, "promoted", ssh("box", 1, 2, true, None, "sleep 45"));
        go(
            100,
            "remote prompt",
            ssh("box", 3, 2, false, Some((0, 3)), "sleep 45"),
        );
        go(
            100,
            "new destination",
            ssh("other", 3, 4, true, None, "ssh other"),
        );
        go(
            300,
            "transport again",
            ssh("other", 3, 4, true, None, "ssh other"),
        );
        assert_eq!(
            shown,
            [
                "ssh starts             ssh idle",
                "transport              ssh running \"ssh box\" 0",
                "same-second prompt     ssh running \"ssh box\" 0",
                "remote prompt          ssh interactive idle",
                "remote command         ssh interactive idle",
                "promoted               ssh interactive running \"sleep 45\" 2",
                "remote prompt          ssh interactive idle last=0 \"sleep 45\" 2-3",
                "new destination        ssh idle",
                "transport again        ssh running \"ssh other\" 4",
            ]
        );
    }
}
