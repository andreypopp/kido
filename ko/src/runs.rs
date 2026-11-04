use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Duration;

use clap::{Args, ValueEnum};
use ko_client::runs::{self, Failure};
use ko_server::api::WaitMs;
use ko_server::config::look_path;
use ko_server::ids::{MessageId, RunId};
use ko_server::protocol::{
    self, Error, ErrorKind, Info, ReportOutcome, Reported, SendPrompt, SessionRef, Show, StartRun,
    StopResult, StopRun, Variable,
};
use ko_server::runs::{Parent, RunName, RunOutcome};
use ko_server::timestamp::Timestamp;

use crate::{Target, assignment, complain, fail, server_message, table, target};

const WAIT_POLL: Duration = Duration::from_secs(30);

#[derive(Debug, Args)]
pub(crate) struct RunArgs {
    /// The server's state directory.
    #[arg(long, value_name = "DIR")]
    server: Option<PathBuf>,
    /// The window name; required.
    #[arg(long, value_name = "NAME")]
    name: String,
    /// Working directory; defaults to the caller's.
    #[arg(long, value_name = "DIR")]
    cwd: Option<PathBuf>,
    /// Session id or name; defaults to the caller's.
    #[arg(long, value_name = "S")]
    session: Option<String>,
    /// A variable for the run's pane; repeatable.
    #[arg(long = "env", value_name = "K=V")]
    env: Vec<String>,
    /// The command, as an argv, after --.
    #[arg(last = true, value_name = "CMD")]
    command: Vec<String>,
}

#[derive(Debug, Args)]
pub(crate) struct RunChildArgs {
    /// The parent: a run id, or the pane id of a top-level pi.
    #[arg(value_name = "PARENT")]
    parent: String,
    #[command(flatten)]
    run: RunArgs,
}

#[derive(Debug, Args)]
pub(crate) struct RunsArgs {
    /// The server's state directory.
    #[arg(long, value_name = "DIR")]
    server: Option<PathBuf>,
    /// Print JSON instead of a table.
    #[arg(long)]
    json: bool,
    /// List ended runs too.
    #[arg(long)]
    all: bool,
    /// Only runs under this parent: a run id, or the pane id of a top-level pi.
    #[arg(long, value_name = "P")]
    parent: Option<String>,
    /// A run id, to show that run in any state.
    #[arg(value_name = "ARG")]
    args: Vec<String>,
}

#[derive(Debug, Clone, Copy, ValueEnum)]
enum OutcomeChoice {
    Stopped,
    Completed,
    Failed,
}

#[derive(Debug, Clone, Copy, ValueEnum)]
enum StopChoice {
    Stopped,
    Completed,
}

#[derive(Debug, Args)]
pub(crate) struct RunOutcomeArgs {
    /// The server's state directory.
    #[arg(long, value_name = "DIR")]
    server: Option<PathBuf>,
    /// stopped, completed or failed.
    #[arg(long, value_name = "RESULT")]
    result: OutcomeChoice,
    /// Optional detail.
    #[arg(long, value_name = "TEXT", default_value = "")]
    text: String,
    #[arg(value_name = "RUN_ID")]
    id: String,
}

#[derive(Debug, Args)]
pub(crate) struct RunWaitArgs {
    /// The server's state directory.
    #[arg(long, value_name = "DIR")]
    server: Option<PathBuf>,
    /// Print the outcome object instead of its result.
    #[arg(long)]
    json: bool,
    #[arg(value_name = "RUN_ID")]
    id: String,
}

#[derive(Debug, Args)]
pub(crate) struct RunStopArgs {
    /// The server's state directory.
    #[arg(long, value_name = "DIR")]
    server: Option<PathBuf>,
    /// Seconds to wait for the run to end before the pane is killed.
    #[arg(long, value_name = "SECS", value_parser = seconds, default_value = "0")]
    wait: Duration,
    /// stopped or completed; default stopped.
    #[arg(long, value_name = "RESULT", default_value = "stopped")]
    result: StopChoice,
    #[arg(value_name = "RUN_ID")]
    id: String,
}

#[derive(Debug, Args)]
pub(crate) struct PromptArgs {
    /// The server's state directory.
    #[arg(long, value_name = "DIR")]
    server: Option<PathBuf>,
    /// Search only the caller's window, never widening to the session.
    #[arg(long)]
    window: bool,
}

fn say(text: &str) {
    let _ = writeln!(io::stdout().lock(), "{text}");
}

fn seconds(text: &str) -> Result<Duration, String> {
    text.parse::<f64>()
        .ok()
        .and_then(|seconds| Duration::try_from_secs_f64(seconds).ok())
        .filter(|wait| wait.as_millis() <= u128::from(WaitMs::MAX.get()))
        .ok_or_else(|| {
            format!(
                "{text:?} is not a number of seconds from 0 to {}",
                WaitMs::MAX.get() / 1000
            )
        })
}

fn describe(dir: &Path, failure: Failure) -> String {
    match failure {
        Failure::Server(failure) => server_message(dir, failure),
        Failure::Refused(Error { message, .. }) => message,
    }
}

fn failed(name: &str, dir: &Path, failure: Failure) -> ExitCode {
    fail(name, describe(dir, failure))
}

fn by_kind(name: &str, dir: &Path, failure: Failure, lost: u8) -> ExitCode {
    let code = match &failure {
        Failure::Refused(Error {
            kind: ErrorKind::Missing,
            ..
        }) => 3,
        Failure::Refused(Error {
            kind: ErrorKind::Refused,
            ..
        }) => lost,
        _ => return failed(name, dir, failure),
    };
    refused(name, describe(dir, failure), code)
}

fn exit(code: u8) -> ExitCode {
    ExitCode::from(code)
}

fn refused(name: &str, message: impl std::fmt::Display, code: u8) -> ExitCode {
    fail(name, message);
    exit(code)
}

fn run_id(name: &str, text: &str) -> Result<RunId, ExitCode> {
    text.parse::<RunId>()
        .map_err(|_| refused(name, format!("invalid run id {text:?}"), 3))
}

fn usage(name: &str, arguments: &str) -> String {
    let command = if arguments.is_empty() {
        name.to_owned()
    } else {
        format!("{name} {arguments}")
    };
    format!("usage: ko {command} --name N [--cwd D] [--session S] [--env K=V]... -- CMD...")
}

fn start(name: &str, parent: Option<Parent>, args: RunArgs) -> ExitCode {
    if args.command.is_empty() {
        let arguments = if parent.is_some() { "PARENT" } else { "" };
        return fail(
            name,
            format!("no command given\n{}", usage(name, arguments)),
        );
    }
    let run_name = match RunName::new(&args.name) {
        Ok(run_name) => run_name,
        Err(message) => return refused(name, message, 4),
    };
    let cwd = match args
        .cwd
        .map_or_else(std::env::current_dir, std::path::absolute)
    {
        Ok(cwd) => cwd,
        Err(error) => return fail(name, error),
    };
    let mut argv = args.command;
    if !argv[0].contains('/') {
        let path = std::env::var("PATH").unwrap_or_default();
        match look_path(&path, &argv[0]) {
            Some(found) => argv[0] = found.to_string_lossy().into_owned(),
            None => return fail(name, format!("{}: command not found", argv[0])),
        }
    }
    let mut env = Vec::new();
    for entry in args.env {
        match assignment(&entry) {
            Ok((name, value)) => env.push(Variable { name, value }),
            Err(want) => return fail(name, format!("invalid --env {entry:?}, {want}")),
        }
    }
    let session = match args.session.map(SessionRef::try_from).transpose() {
        Ok(session) => session,
        Err(message) => return fail(name, message),
    };
    let request = StartRun {
        name: run_name,
        cwd: Some(cwd.to_string_lossy().into_owned()),
        session,
        parent: parent.clone(),
        env,
        runtime: None,
        argv,
    };
    let Target { dir, caller } = target(args.server);
    match runs::start(&dir, caller, &request) {
        Ok(started) => {
            say(&protocol::json(&started));
            ExitCode::SUCCESS
        }
        Err(
            failure @ Failure::Refused(Error {
                kind: ErrorKind::Missing | ErrorKind::Gone,
                ..
            }),
        ) if parent.is_some() => refused(name, describe(&dir, failure), 2),
        Err(failure) => failed(name, &dir, failure),
    }
}

pub(crate) fn run(args: RunArgs) -> ExitCode {
    start("run", None, args)
}

pub(crate) fn run_child(args: RunChildArgs) -> ExitCode {
    match args.parent.parse::<Parent>() {
        Ok(parent) => start("run-child", Some(parent), args.run),
        Err(message) => refused("run-child", message, 2),
    }
}

fn local_time(time: Timestamp) -> String {
    let offset = ko_sys::clock::local_utc_offset_seconds(time.unix_seconds()).unwrap_or(0);
    let local = Timestamp::from_micros(
        time.unix_seconds()
            .saturating_add(offset)
            .saturating_mul(1_000_000),
    )
    .to_string();
    let local = local
        .split('.')
        .next()
        .unwrap_or_default()
        .trim_end_matches('Z');
    if offset == 0 {
        format!("{local}Z")
    } else {
        let minutes = offset.abs() / 60;
        format!(
            "{local}{}{:02}:{:02}",
            if offset < 0 { '-' } else { '+' },
            minutes / 60,
            minutes % 60
        )
    }
}

fn duration_text(micros: i64) -> String {
    let milliseconds = (micros + 500) / 1000;
    if milliseconds == 0 {
        return "0s".to_owned();
    }
    if milliseconds.abs() < 1000 {
        return format!("{milliseconds}ms");
    }
    let seconds = milliseconds / 1000;
    let part = match milliseconds % 1000 {
        0 => (seconds % 60).to_string(),
        fraction => format!(
            "{}.{}",
            seconds % 60,
            format!("{fraction:03}").trim_end_matches('0')
        ),
    };
    if seconds >= 3600 {
        format!("{}h{}m{part}s", seconds / 3600, seconds / 60 % 60)
    } else if seconds >= 60 {
        format!("{}m{part}s", seconds / 60)
    } else {
        format!("{part}s")
    }
}

fn list(args: RunsArgs, target: &Target, parent: Option<Parent>) -> ExitCode {
    let Target { dir, caller } = target;
    let show = if args.all { Show::All } else { Show::Live };
    let infos = match runs::list(dir, caller.clone(), show, parent) {
        Ok(infos) => infos,
        Err(failure) => return failed("runs", dir, failure),
    };
    if args.json {
        say(&protocol::json(&infos));
        return ExitCode::SUCCESS;
    }
    let now = Timestamp::now();
    let mut rows = vec![
        [
            "ID", "NAME", "SESSION", "PARENT", "STARTED", "DURATION", "OUTCOME", "CWD",
        ]
        .map(str::to_owned)
        .to_vec(),
    ];
    rows.extend(infos.iter().map(|info: &Info| {
        let (outcome, ended) = match &info.run.outcome {
            None => ("running".to_owned(), Some(now)),
            Some(outcome) => (outcome.result.to_string(), outcome.at),
        };
        vec![
            info.run.meta.id.to_string(),
            info.run.meta.name.as_str().to_owned(),
            info.session.clone().unwrap_or_default(),
            info.run
                .meta
                .parent
                .as_ref()
                .map(ToString::to_string)
                .unwrap_or_default(),
            local_time(info.run.meta.started_at),
            ended.map_or("-".to_owned(), |ended| {
                let whole = (ended.micros_since(info.run.meta.started_at) + 500_000) / 1_000_000;
                duration_text(whole * 1_000_000)
            }),
            outcome,
            info.run.meta.cwd.clone(),
        ]
    }));
    table(&rows);
    ExitCode::SUCCESS
}

fn show(args: &RunsArgs, target: &Target, id: &RunId) -> ExitCode {
    let Target { dir, caller } = target;
    let info = match runs::detail(dir, caller.clone(), id) {
        Ok(info) => info,
        Err(failure) => return by_kind("runs", dir, failure, 3),
    };
    if args.json {
        say(&protocol::json(&info));
        return ExitCode::SUCCESS;
    }
    let screen = match runs::screen(dir, caller.clone(), id) {
        Ok(screen) => screen,
        Err(failure) => return failed("runs", dir, failure),
    };
    let mut out = io::stdout().lock();
    let mut line = |key: &str, value: &str| {
        let _ = writeln!(out, "{:<10}{value}", format!("{key}:"));
    };
    line("id", &info.run.meta.id.to_string());
    line("name", info.run.meta.name.as_str());
    line("session", info.session.as_deref().unwrap_or_default());
    line(
        "parent",
        &info
            .run
            .meta
            .parent
            .as_ref()
            .map(ToString::to_string)
            .unwrap_or_default(),
    );
    line("command", &info.run.meta.argv.join(" "));
    line("cwd", &info.run.meta.cwd);
    line("started", &local_time(info.run.meta.started_at));
    match &info.run.outcome {
        None => line("outcome", "running"),
        Some(outcome) => {
            line("outcome", &outcome.result.to_string());
            if let Some(at) = outcome.at {
                line("ended", &local_time(at));
            }
            if !outcome.text.is_empty() {
                line("detail", &outcome.text);
            }
        }
    }
    line("output", &info.output);
    if let Some(screen) = &screen {
        let _ = writeln!(out, "screen:\n{screen}");
    }
    ExitCode::SUCCESS
}

pub(crate) fn runs(args: RunsArgs) -> ExitCode {
    let target = target(args.server.clone());
    let parent = match args.parent.as_deref().map(str::parse::<Parent>).transpose() {
        Ok(parent) => parent,
        Err(message) => return refused("runs", message, 2),
    };
    match args.args.as_slice() {
        [] => list(args, &target, parent),
        [id] => match run_id("runs", id) {
            Ok(id) => show(&args, &target, &id),
            Err(code) => code,
        },
        [_, extra, ..] => fail(
            "runs",
            format!(
                "unknown argument {extra:?}\nusage: ko runs [--json] [--all] [--parent P] [<run-id>]"
            ),
        ),
    }
}

pub(crate) fn run_outcome(args: RunOutcomeArgs) -> ExitCode {
    let id = match run_id("run-outcome", &args.id) {
        Ok(id) => id,
        Err(code) => return code,
    };
    let report = ReportOutcome {
        result: match args.result {
            OutcomeChoice::Stopped => Reported::Stopped,
            OutcomeChoice::Completed => Reported::Completed,
            OutcomeChoice::Failed => Reported::Failed,
        },
        text: args.text,
    };
    let Target { dir, caller } = target(args.server);
    match runs::outcome(&dir, caller, &id, &report) {
        Ok(()) => ExitCode::SUCCESS,
        Err(failure) => by_kind("run-outcome", &dir, failure, 5),
    }
}

fn outcome_line(json: bool, outcome: &RunOutcome) -> String {
    if json {
        protocol::json(outcome)
    } else {
        outcome.result.to_string()
    }
}

pub(crate) fn run_wait(args: RunWaitArgs) -> ExitCode {
    let id = match run_id("run-wait", &args.id) {
        Ok(id) => id,
        Err(code) => return code,
    };
    let Target { dir, caller } = target(args.server);
    loop {
        match runs::wait(&dir, caller.clone(), &id, WAIT_POLL) {
            Ok(Some(outcome)) => {
                say(&outcome_line(args.json, &outcome));
                return ExitCode::SUCCESS;
            }
            Ok(None) => {}
            Err(failure) => return refused("run-wait", describe(&dir, failure), 3),
        }
    }
}

pub(crate) fn run_stop(args: RunStopArgs) -> ExitCode {
    let id = match run_id("run-stop", &args.id) {
        Ok(id) => id,
        Err(code) => return code,
    };
    let request = StopRun {
        wait_ms: WaitMs::clamped(u64::try_from(args.wait.as_millis()).unwrap_or(WaitMs::MAX.get())),
        result: match args.result {
            StopChoice::Stopped => StopResult::Stopped,
            StopChoice::Completed => StopResult::Completed,
        },
    };
    let Target { dir, caller } = target(args.server);
    match runs::stop(&dir, caller, &id, &request) {
        Ok(()) => {
            say(&format!("stopped run {id}; killed its pane"));
            ExitCode::SUCCESS
        }
        Err(failure) => by_kind("run-stop", &dir, failure, 5),
    }
}

pub(crate) fn prompt(args: PromptArgs) -> ExitCode {
    let mut text = String::new();
    if let Err(error) = io::stdin().read_to_string(&mut text) {
        return fail("prompt", error);
    }
    let text = text.strip_suffix('\n').unwrap_or(&text).to_owned();
    if text.is_empty() {
        complain("no prompt given");
        return exit(1);
    }
    let Target { dir, caller } = target(args.server);
    let Some(caller) = caller else {
        return fail("prompt", "pane \"\" not found");
    };
    let from = caller.pane;
    let found = match runs::resolve(&dir, Some(caller.clone()), from, args.window) {
        Ok(found) => found,
        Err(failure) => return failed("prompt", &dir, failure),
    };
    match found.as_slice() {
        [] => {
            complain("agent not found");
            exit(4)
        }
        [one] => {
            let id = match MessageId::mint() {
                Ok(id) => id,
                Err(error) => return fail("prompt", error),
            };
            let request = SendPrompt {
                from,
                id,
                target: one.pane,
                text,
            };
            match runs::send(&dir, Some(caller), &request) {
                Ok(_) => ExitCode::SUCCESS,
                Err(failure) => failed("prompt", &dir, failure),
            }
        }
        _ => {
            complain("multiple agents found");
            exit(5)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn durations_print_as_the_runs_table_always_did() {
        let micros = [
            0,
            400_000,
            999_600,
            1_000_000,
            1_250_000,
            59_000_000,
            61_000_000,
            3_725_000_000,
        ];
        let shown: Vec<String> = micros.iter().map(|micros| duration_text(*micros)).collect();
        assert_eq!(
            shown,
            ["0s", "400ms", "1s", "1s", "1.25s", "59s", "1m1s", "1h2m5s"]
        );
    }

    #[test]
    fn a_usage_line_names_the_command() {
        assert_eq!(
            usage("run", ""),
            "usage: ko run --name N [--cwd D] [--session S] [--env K=V]... -- CMD..."
        );
        assert_eq!(
            usage("run-child", "PARENT"),
            "usage: ko run-child PARENT --name N [--cwd D] [--session S] [--env K=V]... -- CMD..."
        );
    }

    #[test]
    fn a_local_time_has_the_zone_of_the_machine() {
        let time: Timestamp = "2023-11-14T22:13:20Z".parse().unwrap();
        let shown = local_time(time);
        assert!(shown.starts_with("2023-11-1"), "{shown}");
        assert!(
            shown.ends_with('Z') || shown.contains('+') || shown[19..].contains('-'),
            "{shown}"
        );
        assert_eq!(shown.len(), if shown.ends_with('Z') { 20 } else { 25 });
    }
}
