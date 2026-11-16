use std::io::{self, Read};
use std::path::PathBuf;
use std::process::ExitCode;

use ko_client::api::ReplyError;
use ko_client::prompt;
use ko_wire::ids::MessageId;
use ko_wire::protocol::{ErrorKind, SendPrompt};

use crate::{Target, complain, fail, target};

pub(crate) fn prompt(server: Option<PathBuf>) -> ExitCode {
    let mut text = String::new();
    if let Err(error) = io::stdin().read_to_string(&mut text) {
        return fail("prompt", error);
    }
    let text = text.strip_suffix('\n').unwrap_or(&text).to_owned();
    if text.is_empty() {
        complain("no prompt given");
        return ExitCode::from(1);
    }
    let Target { dir, caller } = target(server);
    let Some(caller) = caller else {
        return fail("prompt", "pane \"\" not found");
    };
    let id = match MessageId::mint() {
        Ok(id) => id,
        Err(error) => return fail("prompt", error),
    };
    let request = SendPrompt {
        from: caller.pane,
        id,
        target: None,
        text,
    };
    let Err(failure) = prompt::send(&dir, Some(caller), &request) else {
        return ExitCode::SUCCESS;
    };
    let exit = match &failure {
        ReplyError::Refused(error) if error.kind == ErrorKind::NoAgent => 4,
        ReplyError::Refused(error) if error.kind == ErrorKind::MultipleAgents => 5,
        _ => 1,
    };
    fail("prompt", ko_client::api::describe(&dir, failure));
    ExitCode::from(exit)
}
