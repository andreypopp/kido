use std::collections::{BTreeMap, HashMap};
use std::ffi::{OsStr, OsString};
use std::path::PathBuf;
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use clap::CommandFactory;
use clap_complete::engine::CompletionCandidate;
use ko_client::api;
use ko_wire::api::Route;
use ko_wire::protocol::{LayoutPanes, LinkState, Listing, RuntimeInfo, RuntimeKind};

use crate::{Cli, Target};

fn targeting(command: clap::Command, words: &[OsString]) -> (Option<PathBuf>, bool) {
    let Ok(matches) = command.ignore_errors(true).try_get_matches_from(words) else {
        return (None, false);
    };
    let mut matches = &matches;
    let mut server = None;
    let mut remote = false;
    loop {
        if let Ok(Some(value)) = matches.try_get_one::<PathBuf>("server") {
            server = Some(value.clone());
        }
        remote |= matches
            .try_get_one::<String>("host")
            .ok()
            .flatten()
            .is_some();
        let Some((_, child)) = matches.subcommand() else {
            break;
        };
        matches = child;
    }
    (server, remote)
}

static LIVE: OnceLock<Live> = OnceLock::new();

#[derive(Debug)]
struct Live {
    target: Target,
    deadline: Instant,
    remote: bool,
    layout: OnceLock<Option<LayoutPanes>>,
}

impl Live {
    fn get() -> &'static Live {
        LIVE.get_or_init(|| {
            let args: Vec<_> = std::env::args_os().collect();
            let words = args
                .iter()
                .position(|word| word == "--")
                .and_then(|at| args.get(at + 1..))
                .unwrap_or_default();
            let (server, remote) = targeting(Cli::command(), words);
            Live {
                target: crate::target(server),
                deadline: Instant::now() + Duration::from_millis(150),
                remote,
                layout: OnceLock::new(),
            }
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
enum Resource {
    Panes,
    Runtimes,
    Sessions,
    Windows,
}

impl Resource {
    fn parse(segment: &str) -> Option<Self> {
        match segment {
            "panes" => Some(Self::Panes),
            "runtimes" => Some(Self::Runtimes),
            "sessions" => Some(Self::Sessions),
            "windows" => Some(Self::Windows),
            _ => None,
        }
    }

    fn values(self, live: &Live) -> Vec<(String, String)> {
        if live.remote {
            return Vec::new();
        }
        let Target { dir, caller } = &live.target;
        match self {
            Self::Panes => {
                api::probe::<Vec<Listing>>(dir, caller.clone(), &Route::ListPanes {}, live.deadline)
                    .unwrap_or_default()
                    .into_iter()
                    .map(|pane| (pane.row.id.to_string(), pane.row.title))
                    .collect()
            }
            Self::Runtimes => api::probe::<Vec<RuntimeInfo>>(
                dir,
                caller.clone(),
                &Route::ListRuntimes {},
                live.deadline,
            )
            .unwrap_or_default()
            .into_iter()
            .map(|info| {
                let runtime = info.runtime;
                let kind = match runtime.kind {
                    RuntimeKind::Ssh => "ssh",
                    RuntimeKind::Command => "command",
                    RuntimeKind::Container => "container",
                    RuntimeKind::Podman => "podman",
                };
                let state = match runtime.state {
                    LinkState::Down => "down",
                    LinkState::Starting => "starting",
                    LinkState::Up => "up",
                    LinkState::Failed { .. } => "failed",
                };
                (runtime.name.to_string(), format!("{kind}, {state}"))
            })
            .collect(),
            Self::Sessions | Self::Windows => {
                let Some(layout) = live.layout.get_or_init(|| {
                    api::probe(dir, caller.clone(), &Route::GetLayout {}, live.deadline)
                }) else {
                    return Vec::new();
                };
                let mut values = Vec::new();
                for session in &layout.snapshot.layout.sessions {
                    match self {
                        Self::Sessions => {
                            values.push((session.id.to_string(), session.name.as_str().to_owned()))
                        }
                        Self::Windows => values.extend(session.windows.iter().map(|window| {
                            (window.id.to_string(), window.name.as_str().to_owned())
                        })),
                        Self::Panes | Self::Runtimes => {}
                    }
                }
                values
            }
        }
    }
}

pub(crate) fn panes(current: &OsStr) -> Vec<CompletionCandidate> {
    candidates(current, Resource::Panes.values(Live::get()))
}

pub(crate) fn runtimes(current: &OsStr) -> Vec<CompletionCandidate> {
    candidates(current, Resource::Runtimes.values(Live::get()))
}

fn candidates(
    current: &OsStr,
    values: impl IntoIterator<Item = (String, String)>,
) -> Vec<CompletionCandidate> {
    let Some(prefix) = current.to_str() else {
        return Vec::new();
    };
    let unique: BTreeMap<_, _> = values
        .into_iter()
        .filter(|(value, _)| value.starts_with(prefix))
        .collect();
    unique
        .into_iter()
        .map(|(value, help)| {
            let help: String = help.chars().filter(|ch| !ch.is_control()).collect();
            CompletionCandidate::new(value).help(Some(help.into()))
        })
        .collect()
}

fn expand(template: &str, sources: &mut HashMap<Resource, Vec<(String, String)>>) -> Vec<String> {
    let mut paths = vec![String::new()];
    let mut resource = None;
    for segment in template.split('/').skip(1) {
        if segment.starts_with('{') {
            let Some(source) = resource else { break };
            let values = sources
                .entry(source)
                .or_insert_with(|| source.values(Live::get()));
            paths = paths
                .into_iter()
                .flat_map(|path| {
                    values
                        .iter()
                        .map(move |(value, _)| format!("{path}/{value}"))
                })
                .collect();
            resource = None;
        } else {
            resource = Resource::parse(segment);
            for path in &mut paths {
                path.push('/');
                path.push_str(segment);
            }
        }
    }
    paths
}

pub(crate) fn paths(current: &OsStr) -> Vec<CompletionCandidate> {
    let Some(prefix) = current.to_str() else {
        return Vec::new();
    };
    let mut sources = HashMap::new();
    let mut paths = Vec::new();
    for (template, docs) in ko_wire::api::route_paths() {
        if !template.contains('{') {
            paths.push((template.to_owned(), docs.join(" ")));
            continue;
        }
        let segment = template.split('/').nth(1).unwrap_or_default();
        let base = format!("/{segment}/");
        if !prefix.starts_with(&base) && !base.starts_with(prefix) {
            continue;
        }
        paths.extend(
            expand(template, &mut sources)
                .into_iter()
                .map(|path| (path, docs.join(" "))),
        );
    }
    candidates(current, paths)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clap_targeting_respects_option_values() {
        let check = |words: &[&str]| {
            targeting(
                Cli::command(),
                &words.iter().map(OsString::from).collect::<Vec<_>>(),
            )
        };
        for words in [
            vec!["ko", "--server", "/one", "api", "/panes"],
            vec!["ko", "api", "--server=/one", "/panes"],
        ] {
            assert_eq!(check(&words), (Some("/one".into()), false));
        }
        for words in [
            vec!["ko", "api", "--server"],
            vec!["ko", "api", "--input=--server", "/panes"],
            vec!["ko", "api", "--", "--server=/bad"],
            vec!["ko", "api", "-iX=--server", "/panes"],
        ] {
            assert_eq!(check(&words), (None, false), "{words:?}");
        }
        assert_eq!(
            check(&["ko", "api", "--input", "--server", "/panes"]),
            (Some("/panes".into()), false)
        );
        assert_eq!(
            check(&["ko", "api", "--host=remote", "/panes"]),
            (None, true)
        );
    }

    #[test]
    fn templates_stop_at_unknown_segments() {
        let mut sources =
            HashMap::from([(Resource::Panes, vec![("pane_8".to_owned(), String::new())])]);
        assert_eq!(
            expand("/panes/{id}/screen", &mut sources),
            ["/panes/pane_8/screen"]
        );
        assert_eq!(
            expand("/panes/{id}/images/{image}/frames/{frame}", &mut sources),
            ["/panes/pane_8/images"]
        );
        assert_eq!(
            expand("/panes/{id}/vars/{name}", &mut sources),
            ["/panes/pane_8/vars"]
        );
        assert_eq!(expand("/panes", &mut sources), ["/panes"]);
    }

    #[test]
    fn values_are_filtered_unique_and_safe() {
        let values = candidates(
            OsStr::new("pa"),
            [
                ("pane_1".into(), "title\n\u{1b}\ttext".into()),
                ("other".into(), String::new()),
                ("pane_1".into(), "title\n\u{1b}\ttext".into()),
            ],
        );
        assert_eq!(values.len(), 1);
        assert_eq!(values[0].get_value(), "pane_1");
        assert_eq!(values[0].get_help().unwrap().to_string(), "titletext");
    }
}
