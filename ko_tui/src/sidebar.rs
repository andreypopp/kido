use std::collections::BTreeMap;
use std::path::Path;

use ko_client::model::Item;
use ko_server::ids::PaneId;
use ko_server::protocol::{Cause, Dead, Row};

const WIDTH: usize = 24;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Line {
    pub(crate) pane: Option<PaneId>,
    pub(crate) text: String,
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

pub(crate) fn lines(selected: Option<PaneId>, items: &[Item], panes: &[Row]) -> Vec<Line> {
    let mut number = 0;
    let rows: BTreeMap<PaneId, &Row> = panes.iter().map(|row| (row.id, row)).collect();
    items
        .iter()
        .map(|item| match item {
            Item::Session { name, .. } => Line {
                pane: None,
                text: name.clone(),
                selected: false,
            },
            Item::Pane(id) => {
                number += 1;
                let pane = rows.get(id).copied();
                let title = match pane {
                    None => id.to_string(),
                    Some(pane) if !pane.title.is_empty() => pane.title.clone(),
                    Some(pane) => match pane.command.first() {
                        None => pane.id.to_string(),
                        Some(command) => Path::new(command).file_name().map_or_else(
                            || command.clone(),
                            |name| name.to_string_lossy().into_owned(),
                        ),
                    },
                };
                let status = match pane.and_then(|pane| pane.dead.as_ref()) {
                    Some(Dead {
                        cause: Cause::Exited { code },
                        ..
                    }) => format!(" \u{2020}{code}"),
                    Some(_) => " \u{2020}".to_owned(),
                    None => String::new(),
                };
                Line {
                    pane: Some(*id),
                    text: format!("{number} {title}{status}"),
                    selected: selected == Some(*id),
                }
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn id(number: u64) -> PaneId {
        format!("pane_{number}").parse().unwrap()
    }

    #[test]
    fn the_list_has_a_header_for_each_session_and_keeps_pane_titles_and_dead_status() {
        let pane = Row {
            id: id(1),
            pid: 1,
            command: vec!["/bin/sh".to_owned()],
            cwd: "/".to_owned(),
            title: String::new(),
            dead: None,
        };
        let dead = Dead {
            at: 0,
            cause: Cause::Exited { code: 7 },
        };
        let panes = [
            pane.clone(),
            Row {
                id: id(2),
                title: "build".to_owned(),
                dead: Some(dead.clone()),
                ..pane
            },
        ];
        let items = [
            Item::Session {
                id: "session_1".parse().unwrap(),
                name: "work".to_owned(),
            },
            Item::Pane(id(1)),
            Item::Session {
                id: "session_2".parse().unwrap(),
                name: "play".to_owned(),
            },
            Item::Pane(id(2)),
            Item::Pane(id(3)),
        ];
        let shown: Vec<String> = lines(Some(id(2)), &items, &panes)
            .iter()
            .map(|line| format!("{:?} {} {}", line.pane, line.selected, line.text))
            .collect();
        assert_eq!(
            shown,
            [
                "None false work",
                "Some(PaneId(1)) false 1 sh",
                "None false play",
                "Some(PaneId(2)) true 2 build \u{2020}7",
                "Some(PaneId(3)) false 3 pane_3",
            ]
        );
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
    }
}
