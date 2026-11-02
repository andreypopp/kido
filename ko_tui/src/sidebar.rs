use ko_client::model::Model;
use ko_client::status::{self, Mark};
use ko_server::ids::PaneId;
use ko_server::protocol::{Cause, Dead};

const WIDTH: usize = 24;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Line {
    pub(crate) pane: PaneId,
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

pub(crate) fn lines(selected: Option<PaneId>, model: &Model) -> Vec<Line> {
    model
        .panes
        .iter()
        .enumerate()
        .map(|(i, pane)| {
            let suffix = match &pane.row.dead {
                Some(Dead {
                    cause: Cause::Exited { code },
                    ..
                }) => format!(" \u{2020}{code}"),
                Some(_) => " \u{2020}".to_owned(),
                None => String::new(),
            };
            Line {
                pane: pane.row.id,
                lead: format!("{} ", i + 1),
                mark: model.mark(pane),
                title: format!("{}{suffix}", status::title(pane)),
                selected: selected == Some(pane.row.id),
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
