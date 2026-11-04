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
    /// Where the runtime's socket is reached from here. Without it, the socket and the token
    /// file are in the runtime's directory.
    #[arg(long, value_name = "PATH", conflicts_with = "prepare")]
    socket: Option<PathBuf>,
    /// The pane that the program belongs to.
    #[arg(long, value_name = "PANE", value_parser = pane_id, required_unless_present = "prepare", conflicts_with = "prepare")]
    pane: Option<PaneId>,
    /// A private file with the pane's token, which ko enter reads and removes. Without it,
    /// the token is KO_PANE_TOKEN in the environment.
    #[arg(long, value_name = "FILE", requires = "socket")]
    token_file: Option<PathBuf>,
    /// The runtime of the pane.
    #[arg(long, value_name = "NAME")]
    runtime: RuntimeName,
    /// The runtime's directory, when the socket is not given. Default: a private directory
    /// of this user for the runtime.
    #[arg(long, value_name = "DIR", conflicts_with_all = ["socket", "token_file"])]
    dir: Option<PathBuf>,
    /// Make the runtime's directory ready, remove what an earlier link left in it, and print
    /// it and the version of this ko, one for each line.
    #[arg(long, conflicts_with_all = ["cwd", "env", "command"])]
    prepare: bool,
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
        dir,
        prepare,
        cwd,
        env,
        command,
    } = args;
    let remote = |dir| {
        enter::remote_dir(
            &runtime,
            dir,
            std::env::var("XDG_RUNTIME_DIR").ok().as_deref(),
            ko_sys::sock::uid(),
        )
    };
    if prepare {
        let remote = remote(dir);
        if let Err(error) = enter::prepare(&remote) {
            return crate::fail("enter", error);
        }
        let Some(dir) = remote.dir.to_str() else {
            return crate::fail("enter", "the runtime directory is not UTF-8");
        };
        say(dir);
        say(&ko_server::protocol::json(&ko_server::protocol::version()));
        return ExitCode::SUCCESS;
    }
    let Some(pane) = pane else {
        return crate::fail("enter", "--pane is required");
    };
    let (socket, token) = match (socket, token_file) {
        (Some(socket), Some(file)) => (socket, TokenSource::File(file)),
        (Some(socket), None) => (
            socket,
            TokenSource::Environment(std::env::var("KO_PANE_TOKEN").ok()),
        ),
        (None, _) => {
            let remote = remote(dir);
            (remote.socket(), TokenSource::File(remote.token_file(pane)))
        }
    };
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
