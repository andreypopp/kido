use std::path::{Path, PathBuf};

use crate::runtime::exec::Launch;
use crate::runtime::{Ctx, Entry, Next, Outcome, text, words};
use ko_config::runtime::{Command, Runtime};
use ko_sys::file::program_path;
use ko_wire::protocol::ExecRequest;

pub(crate) const DEFAULT_PATH: &str = "/usr/bin:/bin";

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
            .as_slice()
            .iter()
            .map(|arg| arg.as_bytes().to_vec())
            .collect(),
        ko: vec![bytes(exe)],
        location: vec![
            b"--socket".to_vec(),
            bytes(
                &command
                    .socket
                    .as_ref()
                    .map_or(socket, |socket| PathBuf::from(socket.as_str())),
            ),
        ],
        token: vec![b"--token-file".to_vec(), bytes(token_file)],
        quoted: false,
    }
}

pub(crate) fn first(command: &Command, env: &[Vec<u8>]) -> Option<Launch> {
    let (program, args) = command.up.as_ref()?.as_slice().split_first()?;
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
    runtime: &Runtime,
    command: &Command,
    (request, cx): (&ExecRequest, &Ctx<'_>),
) -> Result<Launch, String> {
    let env = super::exec_env(runtime, &cx.key.name, request);
    let path = env.get("PATH").copied().unwrap_or(DEFAULT_PATH);
    let mut words = command
        .prefix
        .as_slice()
        .iter()
        .cloned()
        .chain([text(cx.exe)])
        .chain(words(&["enter", "--exec"]));
    let program = words.next().unwrap_or_default();
    let found =
        program_path(path, &program).ok_or_else(|| format!("{program}: command not found"))?;
    Ok(Launch::new(found, words.collect(), &[]))
}

#[cfg(test)]
mod tests {
    use ko_config::runtime::Kind;
    use ko_config::values::{AbsPath, RuntimeName};

    use super::*;
    use crate::runtime::exec_start;

    #[test]
    fn an_exec_helper_is_the_prefix_then_the_ko_in_exec_mode_with_no_environment_and_the_start_has_the_variables()
     {
        let runtime: Runtime = serde_json::from_str(
            r#"{"env":{"A":"runtime","B":"runtime"},"cwd":"/work","command":{"prefix":["/usr/bin/env"]}}"#,
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
        let socket = PathBuf::from("/s");
        let cx = Ctx {
            root: Path::new("/state/runtimes"),
            key: &crate::runtime::RuntimeKey::config(name.clone()),
            env: &[],
            socket: &socket,
            exe: Path::new("/opt/ko"),
        };
        let launch = exec_launch(&runtime, command, (&request(None, None), &cx)).unwrap();
        assert_eq!(launch.program, PathBuf::from("/usr/bin/env"));
        assert_eq!(launch.args, ["/opt/ko", "enter", "--exec"]);
        assert!(launch.env.is_empty(), "nothing of the server's environment");

        let escalation = std::time::Duration::from_millis(2500);
        let start = exec_start(&runtime, &name, &request(None, None), escalation);
        let env: Vec<String> = start
            .env
            .iter()
            .map(|variable| format!("{}={}", variable.name, variable.value))
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
        assert_eq!(start.argv, ["/bin/echo", "x"]);
        assert_eq!(start.cwd.unwrap().as_str(), "/work");
        assert_eq!(start.escalation_ms, 2500);
        let moved = exec_start(
            &runtime,
            &name,
            &request(Some("/elsewhere"), Some("/opt")),
            escalation,
        );
        assert_eq!(moved.cwd.unwrap().as_str(), "/elsewhere");
        assert!(
            moved
                .env
                .iter()
                .any(|variable| variable.name == "PATH" && variable.value == "/opt")
        );
    }
}
