use std::collections::BTreeMap;
use std::path::Path;

use ko_wire::ids::PaneId;
use ko_wire::protocol::Local;
use ko_wire::protocol::{AgentState, CommandExit, Live, Outcome, OutcomeResult, PaneStatus, Phase};
use schemars::JsonSchema;
use serde::Serialize;

use crate::model::Pane;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Mark {
    None,
    Running,
    Waiting,
    Done,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Source {
    Agent,
    Report,
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
struct Keys {
    outcome: Option<(Source, u64)>,
    exit: Option<(u64, u64)>,
    records: Option<u64>,
}

#[derive(Debug)]
pub struct Seen {
    started: u64,
    keys: BTreeMap<PaneId, Keys>,
}

fn outcomes(status: &PaneStatus) -> (Option<(Source, Outcome)>, Option<&CommandExit>) {
    if let Some(agent) = status.kind.agent() {
        return match agent.state {
            AgentState::Idle {
                outcome: Some(outcome),
            } => (Some((Source::Agent, outcome)), None),
            _ => (None, None),
        };
    }
    let Some(shell) = status.kind.shell() else {
        return (None, None);
    };
    let report = match shell.report.as_ref().map(|report| report.state) {
        Some(AgentState::Idle {
            outcome: Some(outcome),
        }) => Some((Source::Report, outcome)),
        _ => None,
    };
    let exit = match &shell.phase {
        Phase::Idle { last } | Phase::Pending { last } => last.as_ref(),
        Phase::Unknown | Phase::Running { .. } => None,
    };
    (report, exit)
}

impl Seen {
    pub fn new(started: u64) -> Seen {
        Seen {
            started,
            keys: BTreeMap::new(),
        }
    }

    pub fn observe(&mut self, shown: &[PaneId], attending: bool, panes: &[Pane]) {
        if !attending {
            return;
        }
        for pane in panes.iter().filter(|pane| shown.contains(&pane.row.id)) {
            let keys = pane
                .row
                .status
                .as_ref()
                .map_or_else(Keys::default, |status| {
                    let (outcome, exit) = outcomes(status);
                    Keys {
                        outcome: outcome.map(|(source, outcome)| (source, outcome.serial)),
                        exit: exit.map(|exit| (exit.started_at, exit.ended_at)),
                        records: Some(status.program_status.serial),
                    }
                });
            self.keys.insert(pane.row.id, keys);
        }
    }

    fn unseen<'a>(
        &self,
        pane: PaneId,
        status: &'a PaneStatus,
    ) -> (Option<(Source, Outcome)>, Option<&'a CommandExit>) {
        let seen = self.keys.get(&pane).copied().unwrap_or_default();
        let (outcome, exit) = outcomes(status);
        (
            outcome.filter(|(source, outcome)| seen.outcome != Some((*source, outcome.serial))),
            exit.filter(|exit| {
                exit.ended_at > self.started && seen.exit != Some((exit.started_at, exit.ended_at))
            }),
        )
    }

    // The pane's program records were shown as they are now: their done and error read as idle.
    pub fn records_seen(&self, pane: &Pane) -> bool {
        pane.row.status.as_ref().is_some_and(|status| {
            self.keys.get(&pane.row.id).and_then(|keys| keys.records)
                == Some(status.program_status.serial)
        })
    }

    pub fn mark(&self, pane: &Pane) -> Mark {
        let Some(status) = pane.row.status.as_ref().filter(|_| pane.row.dead.is_none()) else {
            return Mark::None;
        };
        let (unseen_outcome, unseen_exit) = self.unseen(pane.row.id, status);
        let outcome = |source: Source| {
            unseen_outcome
                .filter(|(found, _)| *found == source)
                .map(|(_, outcome)| match outcome.result {
                    OutcomeResult::Success => Mark::Done,
                    OutcomeResult::Failure => Mark::Failed,
                })
        };
        if let Some(agent) = status.kind.agent() {
            return match agent.state {
                AgentState::Running { .. } => Mark::Running,
                AgentState::Waiting { .. } => Mark::Waiting,
                AgentState::Idle { .. } => outcome(Source::Agent).unwrap_or(Mark::None),
            };
        }
        let Some(shell) = status.kind.shell() else {
            return Mark::None;
        };
        let exit = unseen_exit.map(|exit| {
            if exit.code == 0 {
                Mark::Done
            } else {
                Mark::Failed
            }
        });
        let mark = match (&shell.phase, &shell.report) {
            (_, Some(report)) => match report.state {
                AgentState::Running { .. } => Some(Mark::Running),
                AgentState::Waiting { .. } => Some(Mark::Waiting),
                AgentState::Idle { .. } => match (outcome(Source::Report), unseen_exit) {
                    (Some(Mark::Failed), _) => Some(Mark::Failed),
                    (_, Some(exit)) if exit.code != 0 => Some(Mark::Failed),
                    (report, _) => report,
                },
            },
            (
                Phase::Running {
                    fullscreen: true, ..
                },
                None,
            ) => None,
            (Phase::Running { .. }, None) => Some(Mark::Running),
            (_, None) => exit,
        };
        mark.unwrap_or(Mark::None)
    }
}

fn explicit_title(live: &Live) -> bool {
    match live {
        Live::Host { pane } | Live::Runtime { pane } => match pane {
            Local::Terminal(shell) => shell.running_command().is_some(),
            Local::SomeAgent { .. } | Local::PiAgent { .. } => true,
        },
        Live::Ssh { .. } => true,
    }
}

pub fn title(pane: &Pane) -> String {
    if let Some(fixed) = &pane.row.fixed_title {
        return fixed.as_str().to_owned();
    }
    let from_status = pane
        .row
        .status
        .as_ref()
        .filter(|status| !status.title.is_empty());
    if let Some(status) = from_status.filter(|status| explicit_title(&status.kind)) {
        status.title.clone()
    } else if !pane.row.title.is_empty() {
        pane.row.title.clone()
    } else if let Some(status) = from_status {
        status.title.clone()
    } else {
        match pane.row.command.first() {
            None => pane.row.id.to_string(),
            Some(command) => Path::new(command).file_name().map_or_else(
                || command.clone(),
                |name| name.to_string_lossy().into_owned(),
            ),
        }
    }
}

#[cfg(test)]
mod tests {
    use ko_wire::ids::Name;
    use ko_wire::protocol::{Agent, Cause, Dead, Origin, ProgramStatus, Shell};

    use super::*;

    fn id(number: u64) -> PaneId {
        format!("pane_{number}").parse().unwrap()
    }

    fn pane(number: u64, status: Option<Live>) -> Pane {
        Pane {
            row: ko_wire::protocol::Row {
                webview: None,
                id: id(number),
                started: 0,
                pid: Some(1),
                command: vec!["/bin/sh".to_owned()],
                cwd: "/".to_owned(),
                title: String::new(),
                dead: None,
                foreground: None,
                status: status.map(|kind| PaneStatus {
                    kind,
                    program_status: ProgramStatus::default(),
                    title: "zsh".to_owned(),
                    message: None,
                    progress: None,
                    since: 0,
                }),
                progress: None,
                parent: None,
                close: Default::default(),
                fixed_title: None,
                close_confirm: Default::default(),
                inbox: false,
                runtime: None,
            },
            vars: BTreeMap::new(),
        }
    }

    fn exit(code: i32, started_at: u64, ended_at: u64) -> CommandExit {
        CommandExit {
            code,
            command: "c".to_owned(),
            started_at,
            ended_at,
        }
    }

    fn idle(last: Option<CommandExit>, report: Option<AgentState>) -> Live {
        Live::Host {
            pane: Local::Terminal(Shell {
                phase: Phase::Idle { last },
                report: report.map(|state| Agent {
                    since: 0,
                    msg: None,
                    state,
                }),
            }),
        }
    }

    fn running(fullscreen: bool) -> Live {
        Live::Host {
            pane: Local::Terminal(Shell {
                phase: Phase::Running {
                    origin: Origin::Command {
                        command: "sleep 2".to_owned(),
                        started_at: 1,
                    },
                    fullscreen,
                },
                report: None,
            }),
        }
    }

    fn outcome(serial: u64, result: OutcomeResult) -> AgentState {
        AgentState::Idle {
            outcome: Some(Outcome { serial, result }),
        }
    }

    fn agent(state: AgentState) -> Live {
        Live::Host {
            pane: Local::SomeAgent {
                name: "claude-code".to_owned(),
                status: Agent {
                    since: 0,
                    msg: None,
                    state,
                },
            },
        }
    }

    #[test]
    fn the_mark_follows_kidos_indicator() {
        let seen = Seen::new(0);
        let cases = [
            ("a running command", running(false), Mark::Running),
            ("a fullscreen program", running(true), Mark::None),
            (
                "a report of a fullscreen program",
                Live::Host {
                    pane: Local::Terminal(Shell {
                        phase: Phase::Running {
                            origin: Origin::Unknown,
                            fullscreen: true,
                        },
                        report: Some(Agent {
                            since: 0,
                            msg: None,
                            state: AgentState::Waiting {
                                kind: None,
                                progress: None,
                            },
                        }),
                    }),
                },
                Mark::Waiting,
            ),
            ("a clean exit", idle(Some(exit(0, 1, 2)), None), Mark::Done),
            (
                "a failed exit",
                idle(Some(exit(2, 1, 2)), None),
                Mark::Failed,
            ),
            ("nothing yet", idle(None, None), Mark::None),
            (
                "a report that works",
                idle(None, Some(AgentState::Running { progress: None })),
                Mark::Running,
            ),
            (
                "a report that waits",
                idle(
                    None,
                    Some(AgentState::Waiting {
                        kind: None,
                        progress: None,
                    }),
                ),
                Mark::Waiting,
            ),
            (
                "a report with a failed outcome beats a clean exit",
                idle(
                    Some(exit(0, 1, 2)),
                    Some(outcome(4, OutcomeResult::Failure)),
                ),
                Mark::Failed,
            ),
            (
                "a report with a success outcome and a failed exit",
                idle(
                    Some(exit(1, 1, 2)),
                    Some(outcome(4, OutcomeResult::Success)),
                ),
                Mark::Failed,
            ),
            (
                "a report with a success outcome",
                idle(None, Some(outcome(4, OutcomeResult::Success))),
                Mark::Done,
            ),
            (
                "an agent that works",
                agent(AgentState::Running { progress: None }),
                Mark::Running,
            ),
            (
                "an agent that waits",
                agent(AgentState::Waiting {
                    kind: None,
                    progress: Some(3),
                }),
                Mark::Waiting,
            ),
            (
                "an agent with a failed outcome",
                agent(outcome(1, OutcomeResult::Failure)),
                Mark::Failed,
            ),
            (
                "an idle agent",
                agent(AgentState::Idle { outcome: None }),
                Mark::None,
            ),
        ];
        for (what, live, expected) in cases {
            let idle_pane = pane(1, Some(live.clone()));
            assert_eq!(seen.mark(&idle_pane), expected, "{what}");
            if let Live::Host {
                pane:
                    Local::Terminal(Shell {
                        phase: Phase::Idle { last },
                        report,
                    }),
            } = live
            {
                let pending = pane(
                    1,
                    Some(Live::Host {
                        pane: Local::Terminal(Shell {
                            phase: Phase::Pending { last },
                            report,
                        }),
                    }),
                );
                assert_eq!(seen.mark(&pending), expected, "pending: {what}");
                assert_eq!(title(&pending), title(&idle_pane), "pending: {what}");
            }
        }
        assert_eq!(seen.mark(&pane(1, None)), Mark::None);
        let mut dead = pane(1, Some(running(false)));
        dead.row.dead = Some(Dead {
            at: 0,
            cause: Cause::Exited { code: 0 },
        });
        assert_eq!(seen.mark(&dead), Mark::None);
    }

    #[test]
    fn a_visit_acknowledges_an_outcome_or_exit_and_a_new_one_shows_again() {
        let mut seen = Seen::new(10);
        let failed = pane(1, Some(idle(Some(exit(1, 20, 30)), None)));
        let other = pane(2, Some(idle(Some(exit(0, 20, 30)), None)));
        assert_eq!(
            (seen.mark(&failed), seen.mark(&other)),
            (Mark::Failed, Mark::Done)
        );
        seen.observe(&[id(1)], true, &[failed.clone(), other.clone()]);
        assert_eq!(
            (seen.mark(&failed), seen.mark(&other)),
            (Mark::None, Mark::Done)
        );
        let again = pane(1, Some(idle(Some(exit(1, 40, 50)), None)));
        assert_eq!(seen.mark(&again), Mark::Failed);
        let early = pane(3, Some(idle(Some(exit(1, 1, 9)), None)));
        assert_eq!(seen.mark(&early), Mark::None);
        let reported = pane(1, Some(agent(outcome(7, OutcomeResult::Success))));
        assert_eq!(seen.mark(&reported), Mark::Done);
        seen.observe(&[id(1)], true, std::slice::from_ref(&reported));
        assert_eq!(seen.mark(&reported), Mark::None);
        let later = pane(1, Some(agent(outcome(8, OutcomeResult::Success))));
        assert_eq!(seen.mark(&later), Mark::Done);
    }

    #[test]
    fn program_records_read_as_seen_once_shown_at_their_serial() {
        let mut seen = Seen::new(0);
        let with_records = |serial| {
            let mut found = pane(1, Some(agent(AgentState::Idle { outcome: None })));
            if let Some(status) = found.row.status.as_mut() {
                status.program_status.serial = serial;
            }
            found
        };
        assert!(!seen.records_seen(&with_records(3)));
        seen.observe(&[id(1)], false, &[with_records(3)]);
        assert!(!seen.records_seen(&with_records(3)), "not attending");
        seen.observe(&[id(1)], true, &[with_records(3)]);
        assert!(seen.records_seen(&with_records(3)));
        assert!(
            !seen.records_seen(&with_records(4)),
            "a newer record shows again"
        );
    }

    #[test]
    fn the_server_title_wins_for_agents_and_running_commands_not_for_an_idle_shell() {
        let with_osc2 = |live: Live| {
            let mut found = pane(1, Some(live));
            found.row.title = "osc2".to_owned();
            found
        };
        let titles = [
            title(&with_osc2(idle(None, None))),
            title(&with_osc2(running(false))),
            title(&with_osc2(agent(AgentState::Idle { outcome: None }))),
            title(&pane(1, Some(idle(None, None)))),
            title(&pane(1, None)),
        ];
        assert_eq!(titles, ["osc2", "zsh", "zsh", "zsh", "sh"]);
    }

    #[test]
    fn a_fixed_title_wins_over_the_osc_title_and_the_command() {
        let mut found = pane(1, Some(running(false)));
        found.row.title = "osc2".to_owned();
        found.row.fixed_title = Some(Name::try_from("Draft for @ko".to_owned()).unwrap());
        assert_eq!(title(&found), "Draft for @ko");
    }
}
