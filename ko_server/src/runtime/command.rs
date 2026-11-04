use std::path::{Path, PathBuf};

use ko_sys::pid::Exit;

use crate::config::program_path;
use crate::ids::RuntimeName;
use crate::protocol::ExecRequest;
use crate::runtime::exec::Launch;
use crate::runtime::file::{Command, Runtime};
use crate::runtime::{Entry, Next, Outcome};

const DEFAULT_PATH: &str = "/usr/bin:/bin";

fn bytes(path: &Path) -> Vec<u8> {
    path.as_os_str().as_encoded_bytes().to_vec()
}

pub(crate) fn entry(
    command: &Command,
    (exe, socket): (&Path, PathBuf),
    token_file: &Path,
) -> Entry {
    Entry {
        prefix: command
            .prefix
            .iter()
            .map(|arg| arg.as_bytes().to_vec())
            .collect(),
        ko: bytes(exe),
        socket: bytes(
            &command
                .socket
                .as_ref()
                .map_or(socket, |socket| socket.as_path().to_path_buf()),
        ),
        token: vec![b"--token-file".to_vec(), bytes(token_file)],
    }
}

pub(crate) fn first(command: &Command, env: &[Vec<u8>]) -> Option<Launch> {
    let (program, args) = command.up.as_deref()?.split_first()?;
    Some(Launch::new(PathBuf::from(program), args.to_vec(), env))
}

pub(crate) fn next(out: &Outcome<'_>) -> Next {
    if out.ok() {
        Next::Up
    } else {
        Next::Fail(out.failure("up"))
    }
}

pub(crate) fn exec_launch(
    name: &RuntimeName,
    runtime: &Runtime,
    command: &Command,
    request: &ExecRequest,
) -> Result<Launch, String> {
    let mut env = runtime.exec_env(name, request);
    let path = *env.entry("PATH").or_insert(DEFAULT_PATH);
    let mut words = command.prefix.iter().chain(&request.argv);
    let program = words
        .next()
        .ok_or_else(|| "argv needs a program".to_owned())?;
    let found =
        program_path(path, program).ok_or_else(|| format!("{program}: command not found"))?;
    let dir = request
        .cwd
        .as_ref()
        .or(runtime.cwd.as_ref())
        .map(|dir| dir.as_path().to_path_buf());
    Ok(Launch {
        program: found,
        args: words.cloned().collect(),
        dir,
        env: env
            .into_iter()
            .map(|(variable, value)| format!("{variable}={value}").into_bytes())
            .collect(),
    })
}

pub(crate) fn refused(_command: &Command, _exit: Exit) -> bool {
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::AbsPath;
    use crate::runtime::file::Kind;

    #[test]
    fn an_exec_gets_the_runtime_env_then_the_request_env_and_nothing_of_the_server() {
        let runtime: Runtime = serde_json::from_str(
            r#"{"kind":"command","env":{"A":"runtime","B":"runtime"},"cwd":"/work","prefix":["/usr/bin/env"]}"#,
        )
        .unwrap();
        let Kind::Command(command) = &runtime.kind else {
            panic!("not a command");
        };
        let request = |cwd: Option<&str>, path: Option<&str>| ExecRequest {
            argv: vec!["/bin/echo".to_owned(), "x".to_owned()],
            cwd: cwd.map(|cwd| AbsPath::try_from(cwd.to_owned()).unwrap()),
            env: [("B", "request")]
                .into_iter()
                .chain(path.map(|path| ("PATH", path)))
                .map(|(variable, value)| (variable.to_owned(), value.to_owned()))
                .collect(),
            stdin: false,
        };
        let name: RuntimeName = "dev".parse().unwrap();
        let launch = exec_launch(&name, &runtime, command, &request(None, None)).unwrap();
        let env: Vec<String> = launch
            .env
            .iter()
            .map(|entry| String::from_utf8_lossy(entry).into_owned())
            .collect();
        assert_eq!(
            env,
            [
                "A=runtime",
                "B=request",
                "KO_RUNTIME=dev",
                "PATH=/usr/bin:/bin"
            ]
        );
        assert_eq!(launch.program, PathBuf::from("/usr/bin/env"));
        assert_eq!(launch.args, ["/bin/echo", "x"]);
        assert_eq!(launch.dir, Some(PathBuf::from("/work")));
        let moved = exec_launch(
            &name,
            &runtime,
            command,
            &request(Some("/elsewhere"), Some("/opt")),
        )
        .unwrap();
        assert_eq!(moved.dir, Some(PathBuf::from("/elsewhere")));
        assert!(moved.env.contains(&b"PATH=/opt".to_vec()));
    }
}
