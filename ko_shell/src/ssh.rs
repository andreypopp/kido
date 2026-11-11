use std::ffi::OsString;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use ko_client::api;
use ko_client::wire::Caller;
use ko_config::ssh_args::{SshArgs, connection_args, interactive, parse};
use ko_wire::api::Route;
use ko_wire::ids::VarName;
use serde_json::json;

use crate::prime::ssh_bootstrap;

const MARK_DEADLINE: Duration = Duration::from_secs(2);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pane {
    pub dir: PathBuf,
    pub caller: Caller,
}

fn mark(pane: &Pane, parsed: Option<&SshArgs>) {
    let (Ok(dest), Ok(extra)) = (VarName::new("ssh.dest"), VarName::new("ssh.args")) else {
        return;
    };
    let requests = [
        match parsed {
            Some(parsed) => (
                Route::SetVar {
                    id: pane.caller.pane,
                    name: dest,
                },
                json!(parsed.dest).to_string().into_bytes(),
            ),
            None => (
                Route::DeleteVar {
                    id: pane.caller.pane,
                    name: dest,
                },
                Vec::new(),
            ),
        },
        match parsed.and_then(connection_args) {
            Some(connection) => (
                Route::SetVar {
                    id: pane.caller.pane,
                    name: extra,
                },
                json!(connection).to_string().into_bytes(),
            ),
            None => (
                Route::DeleteVar {
                    id: pane.caller.pane,
                    name: extra,
                },
                Vec::new(),
            ),
        },
    ];
    let deadline = Instant::now() + MARK_DEADLINE;
    for (route, body) in requests {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return;
        }
        let (method, path) = route.to_request();
        let _ = api::request_within(
            &pane.dir,
            Some(pane.caller.clone()),
            method,
            path.as_str(),
            &body,
            left,
        );
    }
}

pub fn prepare(
    tty: bool,
    pane: Option<&Pane>,
    args: &[OsString],
    terminfo: Option<&[u8]>,
) -> Vec<OsString> {
    let unchanged = || {
        std::iter::once(OsString::from("ssh"))
            .chain(args.iter().cloned())
            .collect()
    };
    let Some(text) = args
        .iter()
        .map(|arg| arg.to_str().map(str::to_owned))
        .collect::<Option<Vec<String>>>()
    else {
        return unchanged();
    };
    let parsed = parse(&text);
    if let Some(pane) = pane {
        mark(pane, parsed.as_ref());
    }
    match parsed {
        Some(parsed) if tty && parsed.command.is_empty() && interactive(&parsed) => {
            std::iter::once(OsString::from("ssh"))
                .chain(parsed.opts.iter().map(OsString::from))
                .chain(["-t", "--"].map(OsString::from))
                .chain([
                    OsString::from(&parsed.dest),
                    OsString::from(ssh_bootstrap(terminfo)),
                ])
                .collect()
        }
        _ => unchanged(),
    }
}

#[cfg(test)]
mod tests {
    use std::os::unix::ffi::OsStringExt;

    use super::*;

    #[test]
    fn an_argument_that_is_not_utf8_passes_through_unprimed_and_unmarked() {
        let args = [OsString::from("host"), OsString::from_vec(vec![0xff])];
        let pane = Pane {
            dir: PathBuf::from("/nonexistent"),
            caller: Caller {
                pane: "pane_1".parse().unwrap(),
                token: "0123456789abcdef0123456789abcdef".parse().unwrap(),
            },
        };
        let argv = prepare(true, Some(&pane), &args, None);
        assert_eq!(
            argv,
            [OsString::from("ssh"), args[0].clone(), args[1].clone()]
        );
    }

    #[test]
    fn a_terminal_session_without_a_command_runs_the_bootstrap_after_the_options() {
        let args = [OsString::from("-oBatchMode=yes"), OsString::from("alias")];
        let primed = prepare(true, None, &args, None);
        let bootstrap = ssh_bootstrap(None);
        assert_eq!(
            primed,
            [
                "ssh",
                "-oBatchMode=yes",
                "-t",
                "--",
                "alias",
                bootstrap.as_str()
            ]
            .map(OsString::from)
        );
        for passthrough in [
            prepare(false, None, &args, None),
            prepare(
                true,
                None,
                &[OsString::from("alias"), OsString::from("uptime")],
                None,
            ),
            prepare(
                true,
                None,
                &[OsString::from("-N"), OsString::from("alias")],
                None,
            ),
        ] {
            assert!(
                !passthrough.contains(&OsString::from("-t")),
                "{passthrough:?}"
            );
        }
    }
}
