use std::collections::BTreeMap;

use ko_client::model::{Item, Pane};
use ko_client::status::{self, Mark};
use ko_server::ids::PaneId;
use ko_server::protocol::{Cause, Dead};

const WIDTH: usize = 24;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Line {
    pub(crate) pane: Option<PaneId>,
    pub(crate) lead: String,
    pub(crate) mark: Mark,
    pub(crate) title: String,
    pub(crate) selected: bool,
}

pub(crate) fn visible(cols: usize) -> bool {
    cols >= 100
}

pub(crate) fn pane_x(cols: usize) -> usize {
    (WIDTH + 1).min(cols.saturating_sub(1))
}

fn signal_name(signal: i32) -> String {
    let names = [
        (1, "SIGHUP"),
        (2, "SIGINT"),
        (3, "SIGQUIT"),
        (6, "SIGABRT"),
        (9, "SIGKILL"),
        (11, "SIGSEGV"),
        (13, "SIGPIPE"),
        (14, "SIGALRM"),
        (15, "SIGTERM"),
    ];
    names
        .iter()
        .find(|(number, _)| *number == signal)
        .map_or_else(
            || format!("signal {signal}"),
            |(_, name)| (*name).to_owned(),
        )
}

pub(crate) fn dead_line(dead: &Dead) -> String {
    let what = match &dead.cause {
        Cause::Exited { code } => format!("exited {code}"),
        Cause::Signaled { signal } => format!("killed by {}", signal_name(*signal)),
        Cause::Failed { message } => format!("failed: {message}"),
    };
    format!("[{what} \u{2014} Ctrl+D to remove]")
}

pub(crate) fn lines(
    selected: Option<PaneId>,
    items: &[Item],
    panes: &[Pane],
    mark: impl Fn(&Pane) -> Mark,
) -> Vec<Line> {
    let mut number = 0;
    let by_id: BTreeMap<PaneId, &Pane> = panes.iter().map(|pane| (pane.row.id, pane)).collect();
    items
        .iter()
        .map(|item| match item {
            Item::Session { name, .. } => Line {
                pane: None,
                lead: String::new(),
                mark: Mark::None,
                title: name.clone(),
                selected: false,
            },
            Item::Pane { id, depth } => {
                number += 1;
                let pane = by_id.get(id).copied();
                let suffix = match pane.and_then(|pane| pane.row.dead.as_ref()) {
                    Some(Dead {
                        cause: Cause::Exited { code },
                        ..
                    }) => format!(" \u{2020}{code}"),
                    Some(_) => " \u{2020}".to_owned(),
                    None => String::new(),
                };
                Line {
                    pane: Some(*id),
                    lead: format!("{number} {}", " ".repeat(*depth)),
                    mark: pane.map_or(Mark::None, &mark),
                    title: format!(
                        "{}{suffix}",
                        pane.map_or_else(|| id.to_string(), status::title)
                    ),
                    selected: selected == Some(*id),
                }
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use ko_server::protocol::Row;

    use super::*;

    fn id(number: u64) -> PaneId {
        format!("pane_{number}").parse().unwrap()
    }

    fn pane(number: u64, title: &str, dead: Option<Dead>) -> Pane {
        Pane {
            row: Row {
                id: id(number),
                pid: 1,
                command: vec!["/bin/sh".to_owned()],
                cwd: "/".to_owned(),
                title: title.to_owned(),
                dead,
                foreground: None,
                status: None,
                progress: None,
            },
            vars: Default::default(),
        }
    }

    #[test]
    fn the_list_has_a_header_for_each_session_and_keeps_pane_titles_and_dead_status() {
        let dead = Dead {
            at: 0,
            cause: Cause::Exited { code: 7 },
        };
        let panes = [pane(1, "", None), pane(2, "build", Some(dead.clone()))];
        let items = [
            Item::Session {
                id: "session_1".parse().unwrap(),
                name: "work".to_owned(),
            },
            Item::Pane {
                id: id(1),
                depth: 0,
            },
            Item::Session {
                id: "session_2".parse().unwrap(),
                name: "play".to_owned(),
            },
            Item::Pane {
                id: id(2),
                depth: 0,
            },
            Item::Pane {
                id: id(3),
                depth: 1,
            },
        ];
        let shown: Vec<String> = lines(Some(id(2)), &items, &panes, |pane| {
            if pane.row.id == id(2) {
                Mark::Done
            } else {
                Mark::None
            }
        })
        .iter()
        .map(|line| {
            format!(
                "{:?} {} {:?} {}{}",
                line.pane, line.selected, line.mark, line.lead, line.title
            )
        })
        .collect();
        assert_eq!(
            shown,
            [
                "None false None work",
                "Some(PaneId(1)) false None 1 sh",
                "None false None play",
                "Some(PaneId(2)) true Done 2 build \u{2020}7",
                "Some(PaneId(3)) false None 3  pane_3",
            ]
        );
    }

    #[test]
    fn dead_lines_name_the_cause() {
        let dead = Dead {
            at: 0,
            cause: Cause::Exited { code: 7 },
        };
        assert_eq!((WIDTH, visible(99), visible(100)), (24, false, true));
        let causes = [
            Cause::Exited { code: 0 },
            Cause::Signaled { signal: 15 },
            Cause::Signaled { signal: 99 },
            Cause::Failed {
                message: "boom".to_owned(),
            },
        ];
        let dead_lines: Vec<String> = causes
            .into_iter()
            .map(|cause| dead_line(&Dead { cause, ..dead }))
            .collect();
        assert_eq!(
            dead_lines,
            [
                "[exited 0 \u{2014} Ctrl+D to remove]",
                "[killed by SIGTERM \u{2014} Ctrl+D to remove]",
                "[killed by signal 99 \u{2014} Ctrl+D to remove]",
                "[failed: boom \u{2014} Ctrl+D to remove]",
            ]
        );
        assert_eq!(id(1).to_string(), "pane_1");
    }
}
