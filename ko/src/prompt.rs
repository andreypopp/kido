use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use clap::Args;
use ko_client::api::ReplyError;
use ko_client::prompt;
use ko_server::ids::MessageId;
use ko_server::protocol::SendPrompt;

use crate::{Target, complain, fail, target};

#[derive(Debug, Args)]
pub(crate) struct PromptArgs {
    /// The server's state directory.
    #[arg(long, value_name = "DIR")]
    server: Option<PathBuf>,
    /// Search only the caller's window, never widening to the session.
    #[arg(long)]
    window: bool,
}

fn failed(dir: &Path, failure: ReplyError) -> ExitCode {
    fail("prompt", ko_client::api::describe(dir, failure))
}

pub(crate) fn prompt(args: PromptArgs) -> ExitCode {
    let mut text = String::new();
    if let Err(error) = io::stdin().read_to_string(&mut text) {
        return fail("prompt", error);
    }
    let text = text.strip_suffix('\n').unwrap_or(&text).to_owned();
    if text.is_empty() {
        complain("no prompt given");
        return ExitCode::from(1);
    }
    let Target { dir, caller } = target(args.server);
    let Some(caller) = caller else {
        return fail("prompt", "pane \"\" not found");
    };
    let from = caller.pane;
    let found = match prompt::resolve(&dir, Some(caller.clone()), from, args.window) {
        Ok(found) => found,
        Err(failure) => return failed(&dir, failure),
    };
    match found.as_slice() {
        [] => {
            complain("agent not found");
            ExitCode::from(4)
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
            let mut sent = prompt::send(&dir, Some(caller.clone()), &request);
            if one.inbox && matches!(sent, Err(ReplyError::Server(_))) {
                sent = prompt::send(&dir, Some(caller), &request);
            }
            match sent {
                Ok(_) => ExitCode::SUCCESS,
                Err(failure) => failed(&dir, failure),
            }
        }
        _ => {
            complain("multiple agents found");
            ExitCode::from(5)
        }
    }
}
