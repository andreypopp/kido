use std::path::{Path, PathBuf};

use ko_config::values::RuntimeName;
use ko_sys::pid::Exit;
use serde::Deserialize;

use crate::config::{env_path, installed, program_path};
use crate::ids::PaneToken;
use crate::runtime::exec::Launch;
use crate::runtime::{Cleanup, Ctx, Entry, Next, Outcome, text, version_next, words};
use ko_config::runtime::{Access, Container, Ko, Source, SshAgent};

const PROGRAM: &str = "container";
const SOCKET: &str = "/run/ko/socket";
const MOUNT: &str = "/opt/ko";
const SHIPPED: &str = "share/ko/linux/aarch64";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Stage {
    System,
    Inspect,
    Start,
    Run,
    Version,
}

#[derive(Debug, Deserialize)]
struct Inspected {
    configuration: Configuration,
    status: Status,
}

#[derive(Debug, Deserialize)]
struct Configuration {
    mounts: Vec<Mounted>,
}

#[derive(Debug, Deserialize)]
struct Mounted {
    destination: String,
    source: String,
}

#[derive(Debug, Deserialize)]
struct Status {
    state: String,
}

fn program(settings: &Container) -> &str {
    settings
        .container
        .as_ref()
        .map_or(PROGRAM, |program| program.as_str())
}

fn binary(settings: &Container, env: &[Vec<u8>]) -> Result<PathBuf, String> {
    let program = program(settings);
    program_path(&String::from_utf8_lossy(env_path(env)), program)
        .ok_or_else(|| format!("{program}: command not found on the PATH of the server"))
}

fn launch(settings: &Container, env: &[Vec<u8>], args: Vec<String>) -> Result<Launch, String> {
    Ok(Launch::new(binary(settings, env)?, args, env))
}

fn target(name: &RuntimeName, settings: &Container) -> String {
    match &settings.from {
        Source::Image(_) => format!("ko-{name}"),
        Source::Container(container) => container.as_str().to_owned(),
    }
}

fn inner_ko(settings: &Container) -> &'static str {
    match settings.ko {
        Ko::Path => "ko",
        Ko::Shipped | Ko::Mount(_) => "/opt/ko/bin/ko",
    }
}

fn mount(settings: &Container, exe: &Path) -> Result<Option<PathBuf>, String> {
    match &settings.ko {
        Ko::Path => Ok(None),
        Ko::Mount(dir) => Ok(Some(PathBuf::from(dir.as_str()))),
        Ko::Shipped => {
            let layouts = installed(exe, SHIPPED);
            layouts
                .iter()
                .find(|layout| layout.join("bin/ko").exists())
                .cloned()
                .map(Some)
                .ok_or_else(|| {
                    format!(
                        "the static Linux ko is missing at {}: run make build-ko-linux",
                        layouts
                            .first()
                            .map_or_else(|| text(exe), |layout| text(layout))
                    )
                })
        }
    }
}

pub(crate) fn token_text(token: &PaneToken) -> String {
    format!("KO_PANE_TOKEN={token}\n")
}

pub(crate) fn entry(
    name: &RuntimeName,
    settings: &Container,
    (env, env_file): (&[Vec<u8>], &Path),
) -> Entry {
    let program = binary(settings, env).unwrap_or_else(|_| PathBuf::from(PROGRAM));
    let mut prefix = vec![
        text(&program),
        "exec".to_owned(),
        "-t".to_owned(),
        "-i".to_owned(),
    ];
    if let Some(user) = &settings.user {
        prefix.extend(["-u".to_owned(), user.as_str().to_owned()]);
    }
    prefix.extend([
        "--env-file".to_owned(),
        text(env_file),
        target(name, settings),
    ]);
    Entry {
        prefix: prefix.into_iter().map(String::into_bytes).collect(),
        ko: vec![inner_ko(settings).as_bytes().to_vec()],
        location: vec![b"--socket".to_vec(), SOCKET.as_bytes().to_vec()],
        token: Vec::new(),
        quoted: false,
    }
}

pub(crate) fn exec_launch(settings: &Container, cx: &Ctx<'_>) -> Result<Launch, String> {
    let mut args = words(&["exec", "-i"]);
    if let Some(user) = &settings.user {
        args.extend(["-u".to_owned(), user.as_str().to_owned()]);
    }
    args.extend([
        target(cx.name, settings),
        inner_ko(settings).to_owned(),
        "enter".to_owned(),
        "--exec".to_owned(),
    ]);
    launch(settings, cx.env, args)
}

pub(crate) fn first(settings: &Container, cx: &Ctx<'_>) -> Result<Launch, String> {
    launch(settings, cx.env, words(&["system", "status"]))
}

pub(crate) fn watch(settings: &Container, cx: &Ctx<'_>) -> Result<Launch, String> {
    let args = words(&[
        "exec",
        "-i",
        &target(cx.name, settings),
        inner_ko(settings),
        "enter",
        "--watch",
    ]);
    launch(settings, cx.env, args)
}

pub(crate) fn cleanup(
    settings: &Container,
    (name, env): (&RuntimeName, &[Vec<u8>]),
    what: Cleanup,
) -> Option<Launch> {
    let Source::Image(_) = settings.from else {
        return None;
    };
    let target = target(name, settings);
    let args = match what {
        Cleanup::Stop => words(&["stop", &target]),
        Cleanup::Delete => words(&["delete", "--force", &target]),
    };
    launch(settings, env, args).ok()
}

fn run(settings: &Container, image: &str, cx: &Ctx<'_>) -> Next {
    let mount = match mount(settings, cx.exe) {
        Ok(mount) => mount,
        Err(message) => return Next::Fail(message),
    };
    let mut args = words(&["run", "-d", "--name", &target(cx.name, settings), "--init"]);
    args.extend(["-v".to_owned(), format!("{}:{SOCKET}", text(cx.socket))]);
    for volume in &settings.volumes {
        let access = match volume.options {
            Some(Access::Ro) => ":ro",
            None => "",
        };
        args.extend([
            "-v".to_owned(),
            format!(
                "{}:{}{access}",
                text(Path::new(volume.host.as_str())),
                text(Path::new(volume.runtime.as_str()))
            ),
        ]);
    }
    if let Some(dir) = mount {
        args.extend([
            "--mount".to_owned(),
            format!("type=bind,source={},target={MOUNT},readonly", text(&dir)),
        ]);
    }
    if settings.ssh_agent == SshAgent::Forward {
        args.push("--ssh".to_owned());
    }
    args.extend(settings.run_args.as_slice().iter().cloned());
    args.push(image.to_owned());
    args.extend(settings.init.as_slice().iter().cloned());
    step(settings, cx, args)
}

fn step(settings: &Container, cx: &Ctx<'_>, args: Vec<String>) -> Next {
    match launch(settings, cx.env, args) {
        Ok(launch) => Next::Run(launch),
        Err(message) => Next::Fail(message),
    }
}

fn inspected(settings: &Container, stage: &mut Stage, cx: &Ctx<'_>, out: &Outcome<'_>) -> Next {
    let missing = String::from_utf8_lossy(out.tail).contains("not found");
    if let (Source::Image(image), Exit::Exited(1), true) = (&settings.from, out.exit, missing) {
        *stage = Stage::Run;
        return run(settings, image.as_str(), cx);
    }
    if !out.ok() {
        return Next::Fail(out.failure("container inspect"));
    }
    let found = serde_json::from_slice::<Vec<Inspected>>(out.stdout).unwrap_or_default();
    let Some(found) = found.first() else {
        return Next::Fail("container inspect printed no container".to_owned());
    };
    let target = target(cx.name, settings);
    if let Source::Container(_) = settings.from {
        let real = cx.socket.canonicalize().unwrap_or_default();
        let shared = found.configuration.mounts.iter().any(|mounted| {
            mounted.destination == SOCKET
                && [cx.socket, real.as_path()]
                    .iter()
                    .any(|socket| Path::new(&mounted.source) == *socket)
        });
        if !shared {
            return Next::Fail(format!(
                "container {target} does not mount the socket of runtime {}: create it with -v {}:{SOCKET}",
                cx.name,
                text(cx.socket)
            ));
        }
    }
    if found.status.state == "running" {
        *stage = Stage::Version;
        step(settings, cx, version_args(settings, &target))
    } else {
        *stage = Stage::Start;
        step(settings, cx, words(&["start", &target]))
    }
}

fn version_args(settings: &Container, target: &str) -> Vec<String> {
    words(&["exec", target, inner_ko(settings), "version"])
}

pub(crate) fn next(
    settings: &Container,
    stage: &mut Stage,
    cx: &Ctx<'_>,
    out: &Outcome<'_>,
) -> Next {
    match *stage {
        Stage::System if out.ok() => {
            *stage = Stage::Inspect;
            step(
                settings,
                cx,
                words(&["inspect", &target(cx.name, settings)]),
            )
        }
        Stage::System => {
            Next::Fail("container system is not running: run container system start".to_owned())
        }
        Stage::Inspect => inspected(settings, stage, cx, out),
        Stage::Start | Stage::Run if out.ok() => {
            *stage = Stage::Version;
            step(
                settings,
                cx,
                version_args(settings, &target(cx.name, settings)),
            )
        }
        Stage::Start => Next::Fail(out.failure("container start")),
        Stage::Run => Next::Fail(out.failure("container run")),
        Stage::Version => version_next(cx.name, out),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::version;

    const RUNNING: &str = r#"[{"configuration":{"id":"ko-dev","mounts":[
        {"destination":"/run/ko/socket","options":[],"source":"/state/runtimes/dev/socket","type":{"virtiofs":{}}},
        {"destination":"/work","options":["ro"],"source":"/src","type":{"virtiofs":{}}}],
        "platform":{"architecture":"arm64","os":"linux"}},
        "id":"ko-dev","status":{"startedDate":"2026-11-04T00:40:36Z","state":"running"}}]"#;

    const IMAGE: &str = r#"{"from":{"image":"debian:trixie"},"container":"/usr/local/bin/container",
        "volumes":[{"host":"/src","runtime":"/work","options":"ro"}],
        "ko":{"mount":"/ko/share/ko/linux/aarch64"},"run_args":["--cpus","2"],"ssh_agent":"forward"}"#;

    struct Rig {
        name: RuntimeName,
        socket: PathBuf,
        exe: PathBuf,
    }

    impl Rig {
        fn new() -> Rig {
            Rig {
                name: "dev".parse().unwrap(),
                socket: PathBuf::from("/state/runtimes/dev/socket"),
                exe: PathBuf::from("/nonexistent/bin/ko"),
            }
        }

        fn ctx(&self) -> Ctx<'_> {
            Ctx {
                name: &self.name,
                env: &[],
                socket: &self.socket,
                exe: &self.exe,
            }
        }
    }

    fn settings(text: &str) -> Container {
        serde_json::from_str(text).unwrap()
    }

    fn outcome(code: i32, stdout: &str, tail: &str) -> (Vec<u8>, Vec<u8>, Exit) {
        (
            stdout.as_bytes().to_vec(),
            tail.as_bytes().to_vec(),
            Exit::Exited(code),
        )
    }

    fn advance(settings: &Container, stage: &mut Stage, seen: (i32, &str, &str)) -> Next {
        let (stdout, tail, exit) = outcome(seen.0, seen.1, seen.2);
        next(
            settings,
            stage,
            &Rig::new().ctx(),
            &Outcome {
                exit,
                stdout: &stdout,
                tail: &tail,
            },
        )
    }

    fn args(next: Next) -> Vec<String> {
        match next {
            Next::Run(launch) => launch.args,
            Next::Up | Next::Lead(_) => panic!("up"),
            Next::Fail(message) => panic!("{message}"),
        }
    }

    fn failure(next: Next) -> String {
        match next {
            Next::Fail(message) => message,
            Next::Run(launch) => panic!("run {:?}", launch.args),
            Next::Up | Next::Lead(_) => panic!("up"),
        }
    }

    #[test]
    fn a_start_runs_the_system_check_then_inspects_the_container() {
        let image = settings(IMAGE);
        let rig = Rig::new();
        assert_eq!(
            first(&image, &rig.ctx()).unwrap().args,
            words(&["system", "status"])
        );
        let mut stage = Stage::System;
        assert_eq!(
            args(advance(&image, &mut stage, (0, "", ""))),
            words(&["inspect", "ko-dev"])
        );
        assert_eq!(stage, Stage::Inspect);
        let mut stage = Stage::System;
        assert_eq!(
            failure(advance(
                &image,
                &mut stage,
                (1, "", "Error: XPC connection error\n")
            )),
            "container system is not running: run container system start"
        );
    }

    #[test]
    fn an_absent_container_is_run_from_the_image_with_the_socket_the_volumes_and_the_ko() {
        let image = settings(IMAGE);
        let mut stage = Stage::Inspect;
        let missing = (1, "", "Error: container not found: ko-dev\n");
        assert_eq!(
            args(advance(&image, &mut stage, missing)),
            words(&[
                "run",
                "-d",
                "--name",
                "ko-dev",
                "--init",
                "-v",
                "/state/runtimes/dev/socket:/run/ko/socket",
                "-v",
                "/src:/work:ro",
                "--mount",
                "type=bind,source=/ko/share/ko/linux/aarch64,target=/opt/ko,readonly",
                "--ssh",
                "--cpus",
                "2",
                "debian:trixie",
                "sleep",
                "infinity",
            ])
        );
        assert_eq!(stage, Stage::Run);
        let mut stage = Stage::Inspect;
        assert_eq!(
            failure(advance(
                &image,
                &mut stage,
                (1, "", "Error: XPC connection invalid\n")
            )),
            "Error: XPC connection invalid"
        );
    }

    #[test]
    fn the_shipped_layout_is_looked_for_only_when_the_container_is_run() {
        let shipped = settings(
            r#"{"from":{"image":"debian:trixie"},"container":"/usr/local/bin/container"}"#,
        );
        let missing = (1, "", "Error: container not found: ko-dev\n");
        let mut stage = Stage::Inspect;
        assert_eq!(
            failure(advance(&shipped, &mut stage, missing)),
            "the static Linux ko is missing at /nonexistent/share/ko/linux/aarch64: run make build-ko-linux"
        );
        let mut stage = Stage::Inspect;
        assert_eq!(
            args(advance(&shipped, &mut stage, (0, RUNNING, ""))),
            words(&["exec", "ko-dev", "/opt/ko/bin/ko", "version"])
        );
    }

    #[test]
    fn a_stopped_container_starts_and_a_running_one_goes_to_the_version_check() {
        let image = settings(IMAGE);
        let mut stage = Stage::Inspect;
        assert_eq!(
            args(advance(&image, &mut stage, (0, RUNNING, ""))),
            words(&["exec", "ko-dev", "/opt/ko/bin/ko", "version"])
        );
        assert_eq!(stage, Stage::Version);
        let stopped = RUNNING.replace("running", "stopped");
        let mut stage = Stage::Inspect;
        assert_eq!(
            args(advance(&image, &mut stage, (0, &stopped, ""))),
            words(&["start", "ko-dev"])
        );
        assert_eq!(stage, Stage::Start);
        assert_eq!(
            args(advance(&image, &mut stage, (0, "", ""))),
            words(&["exec", "ko-dev", "/opt/ko/bin/ko", "version"])
        );
        let mut stage = Stage::Start;
        assert_eq!(
            failure(advance(&image, &mut stage, (1, "", "Error: no space\n"))),
            "Error: no space"
        );
    }

    #[test]
    fn a_container_of_the_user_must_mount_the_socket_of_the_runtime() {
        let mine = settings(
            r#"{"from":{"container":"mine"},"container":"/usr/local/bin/container","ko":"path"}"#,
        );
        let mut stage = Stage::Inspect;
        assert_eq!(
            args(advance(&mine, &mut stage, (0, RUNNING, ""))),
            words(&["exec", "mine", "ko", "version"])
        );
        let elsewhere = RUNNING.replace("/state/runtimes/dev/socket", "/other/socket");
        let mut stage = Stage::Inspect;
        assert_eq!(
            failure(advance(&mine, &mut stage, (0, &elsewhere, ""))),
            "container mine does not mount the socket of runtime dev: create it with -v /state/runtimes/dev/socket:/run/ko/socket"
        );
        let mut stage = Stage::Inspect;
        let absent = (1, "", "Error: container not found: mine\n");
        assert_eq!(
            failure(advance(&mine, &mut stage, absent)),
            "Error: container not found: mine"
        );
        let name: RuntimeName = "dev".parse().unwrap();
        assert!(cleanup(&mine, (&name, &[]), Cleanup::Stop).is_none());
        assert!(cleanup(&mine, (&name, &[]), Cleanup::Delete).is_none());
    }

    #[test]
    fn the_version_check_refuses_another_protocol_or_terminal_and_a_missing_ko() {
        let host = version();
        let json = |protocol: &str, vt: &str| {
            format!(r#"{{"protocol":"{protocol}","vt":"{vt}","build":"abc123"}}"#)
        };
        let image = settings(IMAGE);
        let check = |seen: (i32, &str, &str)| advance(&image, &mut Stage::Version, seen);
        assert!(matches!(check((0, &json("1.7", &host.vt), "")), Next::Up));
        assert_eq!(
            failure(check((0, &json("2.0", &host.vt), ""))),
            format!(
                "ko in runtime dev is abc123 (protocol 2.0, terminal {}), but this server is {} (protocol {}, terminal {})",
                host.vt, host.build, host.protocol, host.vt
            )
        );
        assert!(failure(check((0, &json("1.0", "other"), ""))).contains("terminal other"));
        let absent = (
            1,
            "",
            "Error: failed to find target executable /opt/ko/bin/ko\n",
        );
        assert_eq!(failure(check(absent)), "ko is not installed in runtime dev");
        assert_eq!(
            failure(check((127, "", ""))),
            "ko is not installed in runtime dev"
        );
        assert_eq!(
            failure(check((0, "not json", ""))),
            "ko version printed no version in runtime dev"
        );
    }

    #[test]
    fn a_container_that_ko_owns_is_watched_stopped_and_deleted() {
        let image = settings(IMAGE);
        let rig = Rig::new();
        assert_eq!(
            watch(&image, &rig.ctx()).unwrap().args,
            words(&["exec", "-i", "ko-dev", "/opt/ko/bin/ko", "enter", "--watch"])
        );
        let target = (&rig.name, &[][..]);
        let stop = cleanup(&image, target, Cleanup::Stop).unwrap();
        assert_eq!(stop.program, PathBuf::from("/usr/local/bin/container"));
        assert_eq!(stop.args, words(&["stop", "ko-dev"]));
        let delete = cleanup(&image, target, Cleanup::Delete).unwrap();
        assert_eq!(delete.args, words(&["delete", "--force", "ko-dev"]));
    }

    #[test]
    fn a_pane_enters_through_exec_with_the_token_in_an_env_file_and_never_in_an_argv() {
        let name: RuntimeName = "dev".parse().unwrap();
        let found = settings(
            r#"{"from":{"image":"debian:trixie"},"user":"1000:1000","container":"/usr/local/bin/container"}"#,
        );
        let file = Path::new("/state/runtimes/dev/panes/pane_7.env");
        let entry = entry(&name, &found, (&[], file));
        let prefix: Vec<String> = entry
            .prefix
            .into_iter()
            .map(|word| String::from_utf8(word).unwrap())
            .collect();
        assert_eq!(
            prefix,
            [
                "/usr/local/bin/container",
                "exec",
                "-t",
                "-i",
                "-u",
                "1000:1000",
                "--env-file",
                "/state/runtimes/dev/panes/pane_7.env",
                "ko-dev",
            ]
        );
        assert_eq!(entry.ko, [b"/opt/ko/bin/ko".to_vec()]);
        assert_eq!(
            entry.location,
            [b"--socket".to_vec(), b"/run/ko/socket".to_vec()]
        );
        assert!(entry.token.is_empty());
        let token: PaneToken = "0123456789abcdef0123456789abcdef".parse().unwrap();
        assert_eq!(token_text(&token), format!("KO_PANE_TOKEN={token}\n"));
        assert!(prefix.iter().all(|word| !word.contains(&token.to_string())));
    }

    #[test]
    fn an_exec_runs_ko_enter_exec_in_the_container_with_nothing_of_the_request_in_the_argv() {
        let rig = Rig::new();
        let found = settings(r#"{"from":{"image":"x"},"container":"/c","user":"app"}"#);
        let env = [b"HOME=/home/me".to_vec()];
        let cx = Ctx {
            name: &rig.name,
            env: &env,
            socket: &rig.socket,
            exe: &rig.exe,
        };
        let launch = exec_launch(&found, &cx).unwrap();
        assert_eq!(launch.program, PathBuf::from("/c"));
        assert_eq!(
            launch.args,
            words(&[
                "exec",
                "-i",
                "-u",
                "app",
                "ko-dev",
                "/opt/ko/bin/ko",
                "enter",
                "--exec"
            ])
        );
        assert_eq!(launch.env, env);
    }
}
