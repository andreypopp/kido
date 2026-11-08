use std::io::{self, Write};
use std::os::fd::AsFd;
use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Args, Subcommand};
use ko_pane_wire::frame::OwnedWebviewPath;
use ko_pane_wire::webview::{Command, encode};

#[derive(Debug, Args)]
pub(crate) struct WebviewArgs {
    #[command(subcommand)]
    command: WebviewCommand,
}

#[derive(Debug, Subcommand)]
enum WebviewCommand {
    /// Show the page in this pane.
    Enter {
        /// The page's path, with an initial slash. Defaults to /.
        #[arg(long, value_name = "P")]
        path: Option<String>,
    },
    /// Show the terminal content of this pane.
    Leave,
    /// Forward the pane's HTTP requests and WebSockets to a unix socket.
    Serve {
        /// The program's HTTP unix socket.
        #[arg(long, value_name = "PATH")]
        socket: PathBuf,
    },
}

pub(crate) fn run(args: WebviewArgs, server: Option<PathBuf>) -> ExitCode {
    let result = match args.command {
        WebviewCommand::Enter { path } => {
            let checked = match OwnedWebviewPath::try_from(path.unwrap_or_else(|| "/".to_owned())) {
                Ok(path) => path,
                Err(error) => return crate::fail("webview enter", error),
            };
            io::stdout()
                .lock()
                .write_all(&encode(&Command::Enter(checked)))
        }
        WebviewCommand::Leave => io::stdout().lock().write_all(&encode(&Command::Leave)),
        WebviewCommand::Serve { socket } => {
            let target = crate::target(server);
            let Some(caller) = target.caller else {
                let _ = crate::fail("webview serve", "requires a pane identity");
                return ExitCode::from(6);
            };
            ko_client::webview::serve(
                &target.dir,
                caller,
                &socket,
                io::stdin().as_fd(),
                |supported| {
                    writeln!(
                        io::stdout().lock(),
                        "{}",
                        ko_server::protocol::json(
                            &ko_server::protocol::webview::ServeOut::Supported { supported }
                        )
                    )
                },
            )
        }
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => crate::fail("webview", error),
    }
}
