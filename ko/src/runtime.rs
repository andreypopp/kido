use std::io::{self, Write};
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Command, ExitCode};

use clap::Args;
use ko_client::runtimes::{self, Shown, Up};
use ko_server::ids::{InvalidId, PaneId, RuntimeName};
use ko_shell::enter::{self, Enter, TokenSource};

use crate::{Target, assignment, complain, invoked, say, target};

fn pane_id(text: &str) -> Result<PaneId, String> {
    text.parse().map_err(|error: InvalidId| error.to_string())
}

#[derive(Debug, Args)]
pub(crate) struct EnterArgs {
    /// Where the runtime's socket is reached from here.
    #[arg(long, value_name = "PATH")]
    socket: PathBuf,
    /// The pane that the program belongs to.
    #[arg(long, value_name = "PANE", value_parser = pane_id)]
    pane: PaneId,
    /// A private file with the pane's token, which ko enter reads and removes. Without it,
    /// the token is KO_PANE_TOKEN in the environment.
    #[arg(long, value_name = "FILE")]
    token_file: Option<PathBuf>,
    /// The runtime of the pane.
    #[arg(long, value_name = "NAME")]
    runtime: RuntimeName,
    /// The directory to start in.
    #[arg(long, value_name = "DIR")]
    cwd: Option<PathBuf>,
    /// A variable for the program; repeatable.
    #[arg(long = "env", value_name = "K=V", value_parser = assignment)]
    env: Vec<(String, String)>,
    /// The command, after --. Without it, the primed login shell.
    #[arg(last = true, value_name = "CMD")]
    command: Vec<String>,
}

#[derive(Debug, Args)]
pub(crate) struct RuntimeExecArgs {
    /// The runtime of the pane.
    #[arg(value_name = "NAME")]
    name: RuntimeName,
    /// The program to run when the runtime is up, after --.
    #[arg(last = true, required = true, value_name = "ARGV")]
    argv: Vec<String>,
}

pub(crate) fn enter(args: EnterArgs) -> ExitCode {
    let EnterArgs {
        socket,
        pane,
        token_file,
        runtime,
        cwd,
        env,
        command,
    } = args;
    let token = token_file.map_or_else(
        || TokenSource::Environment(std::env::var("KO_PANE_TOKEN").ok()),
        TokenSource::File,
    );
    let enter = Enter {
        socket,
        pane,
        token,
        runtime,
        cwd,
        env,
        command,
        path: std::env::var("PATH").unwrap_or_default(),
        agent: std::env::var_os("SSH_AUTH_SOCK").is_some(),
    };
    crate::fail("enter", enter::exec(&enter, &invoked()))
}

pub(crate) fn runtime_exec(args: RuntimeExecArgs) -> ExitCode {
    let RuntimeExecArgs { name, argv } = args;
    let Target { dir, caller } = target(None);
    let stop = |message: String| {
        complain(format_args!("runtime {name}: {message}"));
        ExitCode::FAILURE
    };
    let mut shown = |event: Shown<'_>| match event {
        Shown::Starting => say(&format!("starting runtime {name}")),
        Shown::Stderr(bytes) => {
            let _ = io::stderr().write_all(bytes);
        }
    };
    match runtimes::bring_up(&dir, caller, &name, &mut shown) {
        Up::Up => {}
        Up::Failed(message) => return stop(message),
        Up::StillStarting => return stop("still starting".to_owned()),
    }
    let Some((program, rest)) = argv.split_first() else {
        return stop("no program".to_owned());
    };
    let error = Command::new(program)
        .args(rest)
        .env_remove("KO_SOCKET")
        .env_remove("KO_PANE")
        .env_remove("KO_PANE_TOKEN")
        .exec();
    stop(format!("{program}: {error}"))
}
