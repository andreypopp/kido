use std::path::{Path, PathBuf};

use ko_config::runtime::{Access, Engine, Ko, Source, SshAgent};
use ko_config::values::Operand;
use ko_sys::pid::Exit;
use serde::Deserialize;

use crate::config::{env_path, installed, program_path};
use crate::ids::PaneToken;
use crate::runtime::RuntimeKey;
use crate::runtime::exec::Launch;
use crate::runtime::{Cleanup, Ctx, Entry, Next, Outcome, pane, text, version_next, words};

const PROGRAM: &str = "container";
const PODMAN: &str = "podman";
const RUN_DIR: &str = "/run/ko";
const SOCKET: &str = "/run/ko/socket";
const MOUNT: &str = "/opt/ko";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Stage {
    System,
    DeleteStale(Operand),
    Inspect,
    Start,
    Run,
    Version,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Platform {
    AppleVm,
    Linux,
}

#[derive(Debug)]
struct Facts {
    program: &'static str,
    inspect: &'static [&'static str],
    missing_exit: Exit,
    missing_text: &'static str,
    delete: &'static str,
    platform: Platform,
    decode: fn(&[u8]) -> Result<Vec<Inspected>, serde_json::Error>,
}

const APPLE: Facts = Facts {
    program: PROGRAM,
    inspect: &["inspect"],
    missing_exit: Exit::Exited(1),
    missing_text: "not found",
    delete: "delete",
    platform: Platform::AppleVm,
    decode: |bytes| {
        serde_json::from_slice::<Vec<AppleInspected>>(bytes).map(|items| {
            items
                .into_iter()
                .map(|item| Inspected {
                    state: item.status.state,
                    mounts: item.configuration.mounts,
                })
                .collect()
        })
    },
};
const LINUX: Facts = Facts {
    program: PODMAN,
    inspect: &["container", "inspect"],
    missing_exit: Exit::Exited(125),
    missing_text: "no such container",
    delete: "rm",
    platform: Platform::Linux,
    decode: |bytes| {
        serde_json::from_slice::<Vec<PodmanInspected>>(bytes).map(|items| {
            items
                .into_iter()
                .map(|item| Inspected {
                    state: item.state.status,
                    mounts: item
                        .mounts
                        .into_iter()
                        .map(|m| Mounted {
                            source: m.source,
                            destination: m.destination,
                        })
                        .collect(),
                })
                .collect()
        })
    },
};

fn facts(settings: &Engine) -> &'static Facts {
    match settings {
        Engine::Apple(_) => &APPLE,
        Engine::Podman(_) => &LINUX,
    }
}

impl Facts {
    fn supported(&self) -> Result<(), String> {
        if self.platform == Platform::Linux && !cfg!(target_os = "linux") {
            Err("the podman kind runs only on a Linux server".to_owned())
        } else {
            Ok(())
        }
    }

    fn inspect_args(&self, key: &RuntimeKey, settings: &Engine) -> Vec<String> {
        let mut args = words(self.inspect);
        args.push(target(key, settings));
        args
    }

    fn missing(&self, out: &Outcome<'_>) -> bool {
        out.exit == self.missing_exit
            && String::from_utf8_lossy(out.tail).contains(self.missing_text)
    }

    fn socket_mount(&self, cx: &Ctx<'_>) -> (PathBuf, &'static str) {
        match self.platform {
            Platform::AppleVm => (cx.socket.to_path_buf(), SOCKET),
            Platform::Linux => (pane::io_directory(cx.root, cx.key), RUN_DIR),
        }
    }

    fn shipped(&self) -> Result<String, String> {
        let arch = match self.platform {
            Platform::AppleVm => "aarch64",
            Platform::Linux => match std::env::consts::ARCH {
                arch @ ("aarch64" | "x86_64") => arch,
                arch => {
                    return Err(format!(
                        "the podman kind has no shipped ko for architecture {arch}"
                    ));
                }
            },
        };
        Ok(format!("share/ko/linux/{arch}"))
    }

    fn failure(&self, out: &Outcome<'_>, step: &str) -> Next {
        Next::Fail(out.failure(&format!("{} {step}", self.program)))
    }
}

#[derive(Debug)]
struct Inspected {
    state: String,
    mounts: Vec<Mounted>,
}

#[derive(Debug, Deserialize)]
struct AppleInspected {
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
#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct PodmanInspected {
    state: PodmanState,
    mounts: Vec<PodmanMount>,
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct PodmanState {
    status: String,
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct PodmanMount {
    destination: String,
    source: String,
}

fn program(settings: &Engine) -> &str {
    let custom = match settings {
        Engine::Apple(s) => &s.container,
        Engine::Podman(s) => &s.podman,
    };
    custom
        .as_ref()
        .map_or(facts(settings).program, |p| p.as_str())
}

fn binary(settings: &Engine, env: &[Vec<u8>]) -> Result<PathBuf, String> {
    let program = program(settings);
    program_path(&String::from_utf8_lossy(env_path(env)), program)
        .ok_or_else(|| format!("{program}: command not found on the PATH of the server"))
}

fn launch(settings: &Engine, env: &[Vec<u8>], args: Vec<String>) -> Result<Launch, String> {
    Ok(Launch::new(binary(settings, env)?, args, env))
}

fn target(key: &RuntimeKey, settings: &Engine) -> String {
    match settings.options().from {
        Source::Image(_) => format!("ko-{}", key.tag()),
        Source::Container(container) => container.as_str().to_owned(),
    }
}

fn inner_ko(settings: &Engine) -> &'static str {
    match settings.options().ko {
        Ko::Path => "ko",
        Ko::Shipped | Ko::Mount(_) => "/opt/ko/bin/ko",
    }
}

fn mount(settings: &Engine, exe: &Path) -> Result<Option<PathBuf>, String> {
    match settings.options().ko {
        Ko::Path => Ok(None),
        Ko::Mount(dir) => Ok(Some(PathBuf::from(dir.as_str()))),
        Ko::Shipped => {
            let layouts = installed(exe, &facts(settings).shipped()?);
            layouts
                .iter()
                .find(|layout| layout.join("bin/ko").exists())
                .cloned()
                .map(Some)
                .ok_or_else(|| {
                    format!(
                        "the static Linux ko is missing at {}: run make build-linux",
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
    key: &RuntimeKey,
    settings: &Engine,
    (env, env_file): (&[Vec<u8>], &Path),
) -> Entry {
    let program = binary(settings, env).unwrap_or_else(|_| PathBuf::from(program(settings)));
    let mut prefix = vec![
        text(&program),
        "exec".to_owned(),
        "-t".to_owned(),
        "-i".to_owned(),
    ];
    if let Some(user) = settings.options().user {
        prefix.extend(["-u".to_owned(), user.as_str().to_owned()]);
    }
    prefix.extend([
        "--env-file".to_owned(),
        text(env_file),
        target(key, settings),
    ]);
    Entry {
        prefix: prefix.into_iter().map(String::into_bytes).collect(),
        ko: vec![inner_ko(settings).as_bytes().to_vec()],
        location: vec![b"--socket".to_vec(), SOCKET.as_bytes().to_vec()],
        token: Vec::new(),
        quoted: false,
    }
}

pub(crate) fn exec_launch(settings: &Engine, cx: &Ctx<'_>) -> Result<Launch, String> {
    let mut args = words(&["exec", "-i"]);
    if let Some(user) = settings.options().user {
        args.extend(["-u".to_owned(), user.as_str().to_owned()]);
    }
    args.extend([
        target(cx.key, settings),
        inner_ko(settings).to_owned(),
        "enter".to_owned(),
        "--exec".to_owned(),
    ]);
    launch(settings, cx.env, args)
}

pub(crate) fn first(settings: &Engine, cx: &Ctx<'_>) -> Result<Launch, String> {
    let facts = facts(settings);
    facts.supported()?;
    let args = match facts.platform {
        Platform::AppleVm => words(&["system", "status"]),
        Platform::Linux => facts.inspect_args(cx.key, settings),
    };
    launch(settings, cx.env, args)
}

pub(crate) fn watch(settings: &Engine, cx: &Ctx<'_>) -> Result<Launch, String> {
    launch(
        settings,
        cx.env,
        words(&[
            "exec",
            "-i",
            &target(cx.key, settings),
            inner_ko(settings),
            "enter",
            "--watch",
        ]),
    )
}

pub(crate) fn cleanup(
    settings: &Engine,
    (key, env): (&RuntimeKey, &[Vec<u8>]),
    what: Cleanup,
) -> Option<Launch> {
    let facts = facts(settings);
    facts.supported().ok()?;
    let Source::Image(_) = settings.options().from else {
        return None;
    };
    let target = target(key, settings);
    let args = match what {
        Cleanup::Stop => words(&["stop", &target]),
        Cleanup::Delete => words(&[facts.delete, "--force", &target]),
    };
    launch(settings, env, args).ok()
}

fn run(settings: &Engine, image: &str, cx: &Ctx<'_>) -> Next {
    let mount = match mount(settings, cx.exe) {
        Ok(mount) => mount,
        Err(message) => return Next::Fail(message),
    };
    let mut args = words(&["run", "-d", "--name", &target(cx.key, settings), "--init"]);
    let facts = facts(settings);
    if facts.platform == Platform::Linux {
        args.extend(words(&[
            "--security-opt",
            "label=disable",
            "--http-proxy=false",
        ]));
    }
    let (source, destination) = facts.socket_mount(cx);
    args.extend(["-v".to_owned(), format!("{}:{destination}", text(&source))]);
    for volume in settings.options().volumes {
        let access = match volume.options {
            Some(Access::Ro) => ":ro",
            None => "",
        };
        args.extend([
            "-v".to_owned(),
            format!(
                "{}:{}{access}",
                volume.host.as_str(),
                volume.runtime.as_str()
            ),
        ]);
    }
    if let Some(dir) = mount {
        args.extend([
            "--mount".to_owned(),
            format!("type=bind,source={},target={MOUNT},readonly", text(&dir)),
        ]);
    }
    if matches!(settings, Engine::Apple(s) if s.ssh_agent == SshAgent::Forward) {
        args.push("--ssh".to_owned());
    }
    args.extend(settings.options().run_args.as_slice().iter().cloned());
    args.push(image.to_owned());
    args.extend(settings.options().init.as_slice().iter().cloned());
    step(settings, cx, args)
}

fn step(settings: &Engine, cx: &Ctx<'_>, args: Vec<String>) -> Next {
    match launch(settings, cx.env, args) {
        Ok(launch) => Next::Run(launch),
        Err(message) => Next::Fail(message),
    }
}

fn inspected(
    settings: &Engine,
    stage: &mut Stage,
    fresh: bool,
    cx: &Ctx<'_>,
    out: &Outcome<'_>,
) -> Next {
    let facts = facts(settings);
    if let Source::Image(image) = settings.options().from
        && facts.missing(out)
    {
        *stage = Stage::Run;
        return run(settings, image.as_str(), cx);
    }
    if !out.ok() {
        return facts.failure(out, "inspect");
    }
    let found = (facts.decode)(out.stdout).unwrap_or_default();
    let Some(found) = found.first() else {
        return Next::Fail(format!("{} inspect printed no container", facts.program));
    };
    let target = target(cx.key, settings);
    if let Source::Container(_) = settings.options().from {
        let (source, destination) = facts.socket_mount(cx);
        let real = source.canonicalize().unwrap_or_default();
        let shared = found.mounts.iter().any(|mounted| {
            mounted.destination == destination
                && [source.as_path(), real.as_path()]
                    .iter()
                    .any(|path| Path::new(&mounted.source) == *path)
        });
        if !shared {
            return Next::Fail(format!(
                "container {target} does not mount the socket of runtime {}: create it with -v {}:{destination}",
                cx.key,
                text(&source)
            ));
        }
    }
    if fresh && let Source::Image(image) = settings.options().from {
        *stage = Stage::DeleteStale(image.clone());
        return step(settings, cx, words(&[facts.delete, "--force", &target]));
    }
    if found.state == "running" {
        *stage = Stage::Version;
        step(settings, cx, version_args(settings, &target))
    } else {
        *stage = Stage::Start;
        step(settings, cx, words(&["start", &target]))
    }
}

fn version_args(settings: &Engine, target: &str) -> Vec<String> {
    words(&["exec", target, inner_ko(settings), "version"])
}

pub(crate) fn next(
    settings: &Engine,
    stage: &mut Stage,
    fresh: bool,
    cx: &Ctx<'_>,
    out: &Outcome<'_>,
) -> Next {
    let facts = facts(settings);
    match stage {
        Stage::System if out.ok() => {
            *stage = Stage::Inspect;
            step(settings, cx, facts.inspect_args(cx.key, settings))
        }
        Stage::System => {
            Next::Fail("container system is not running: run container system start".to_owned())
        }
        Stage::Inspect => inspected(settings, stage, fresh, cx, out),
        Stage::DeleteStale(image) if out.ok() => {
            let image = image.clone();
            *stage = Stage::Run;
            run(settings, image.as_str(), cx)
        }
        Stage::DeleteStale(_) => facts.failure(out, "delete"),
        Stage::Start | Stage::Run if out.ok() => {
            *stage = Stage::Version;
            step(
                settings,
                cx,
                version_args(settings, &target(cx.key, settings)),
            )
        }
        Stage::Start => facts.failure(out, "start"),
        Stage::Run => facts.failure(out, "run"),
        Stage::Version => version_next(&cx.key.name, out),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::version;
    use ko_config::runtime::{Container, Podman};

    const RUNNING: &str = r#"[{"configuration":{"id":"ko-dev","mounts":[
        {"destination":"/run/ko/socket","options":[],"source":"/state/runtimes/dev/io/socket","type":{"virtiofs":{}}},
        {"destination":"/work","options":["ro"],"source":"/src","type":{"virtiofs":{}}}],
        "platform":{"architecture":"arm64","os":"linux"}},
        "id":"ko-dev","status":{"startedDate":"2026-11-04T00:40:36Z","state":"running"}}]"#;

    const IMAGE: &str = r#"{"from":{"image":"debian:trixie"},"container":"/usr/local/bin/container",
        "volumes":[{"host":"/src","runtime":"/work","options":"ro"}],
        "ko":{"mount":"/ko/share/ko/linux/aarch64"},"run_args":["--cpus","2"],"ssh_agent":"forward"}"#;

    struct Rig {
        key: RuntimeKey,
        socket: PathBuf,
        exe: PathBuf,
    }

    impl Rig {
        fn new() -> Rig {
            Rig {
                key: RuntimeKey::config("dev".parse().unwrap()),
                socket: PathBuf::from("/state/runtimes/dev/io/socket"),
                exe: PathBuf::from("/nonexistent/bin/ko"),
            }
        }

        fn ctx(&self) -> Ctx<'_> {
            Ctx {
                root: Path::new("/state/runtimes"),
                key: &self.key,
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
            &Engine::Apple(settings.clone()),
            stage,
            false,
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
    fn a_fresh_image_deletes_a_stale_owned_container_but_a_user_container_is_kept() {
        let image = settings(IMAGE);
        let mut stage = Stage::Inspect;
        let advance = |settings: &Container, stage: &mut Stage, seen: (i32, &str, &str)| {
            let (stdout, tail, exit) = outcome(seen.0, seen.1, seen.2);
            next(
                &Engine::Apple(settings.clone()),
                stage,
                true,
                &Rig::new().ctx(),
                &Outcome {
                    exit,
                    stdout: &stdout,
                    tail: &tail,
                },
            )
        };
        assert_eq!(
            args(advance(&image, &mut stage, (0, RUNNING, ""))),
            words(&["delete", "--force", "ko-dev"])
        );
        assert_eq!(
            stage,
            Stage::DeleteStale(Operand::try_from("debian:trixie".to_owned()).unwrap())
        );
        assert!(
            args(advance(&image, &mut stage, (0, "", "")))
                .starts_with(&words(&["run", "-d", "--name", "ko-dev"]))
        );
        let mut user = image;
        user.from =
            Source::Container(ko_config::values::Operand::try_from("mine".to_owned()).unwrap());
        stage = Stage::Inspect;
        assert_eq!(
            args(advance(&user, &mut stage, (0, RUNNING, ""))),
            words(&["exec", "mine", "/opt/ko/bin/ko", "version"])
        );
        assert_eq!(stage, Stage::Version);
    }

    #[test]
    fn podman_uses_its_argv_and_inspect_table() {
        let settings: Podman = serde_json::from_str(r#"{"from":{"image":"docker.io/library/debian:trixie"},"podman":"/usr/bin/podman","volumes":[{"host":"/src","runtime":"/work","options":"ro"}],"ko":{"mount":"/layout"},"user":"1000","run_args":["--cpus","2"],"init":["sleep","infinity"]}"#).unwrap();
        let engine = &Engine::Podman(settings.clone());
        let rig = Rig::new();
        let cx = rig.ctx();
        if cfg!(target_os = "linux") {
            assert_eq!(
                first(engine, &cx).unwrap().args,
                words(&["container", "inspect", "ko-dev"])
            );
        } else {
            assert_eq!(
                first(engine, &cx).unwrap_err(),
                "the podman kind runs only on a Linux server"
            );
        }
        let advance = |stage: &mut Stage, code, stdout: &str, tail: &str| {
            next(
                engine,
                stage,
                false,
                &cx,
                &Outcome {
                    exit: Exit::Exited(code),
                    stdout: stdout.as_bytes(),
                    tail: tail.as_bytes(),
                },
            )
        };
        let mut stage = Stage::Inspect;
        assert_eq!(
            args(advance(
                &mut stage,
                125,
                "[]",
                "Error: no such container \"ko-dev\""
            )),
            words(&[
                "run",
                "-d",
                "--name",
                "ko-dev",
                "--init",
                "--security-opt",
                "label=disable",
                "--http-proxy=false",
                "-v",
                "/state/runtimes/dev/io:/run/ko",
                "-v",
                "/src:/work:ro",
                "--mount",
                "type=bind,source=/layout,target=/opt/ko,readonly",
                "--cpus",
                "2",
                "docker.io/library/debian:trixie",
                "sleep",
                "infinity"
            ])
        );
        assert_eq!(stage, Stage::Run);
        assert_eq!(
            args(advance(&mut stage, 0, "", "")),
            words(&["exec", "ko-dev", "/opt/ko/bin/ko", "version"])
        );
        assert_eq!(stage, Stage::Version);
        assert_eq!(
            failure(advance(&mut stage, 127, "", "executable file not found")),
            "ko is not installed in runtime dev"
        );
        let mut stage = Stage::Inspect;
        assert_eq!(
            failure(advance(&mut stage, 125, "", "permission denied")),
            "permission denied"
        );
        let running = r#"[{"State":{"Status":"running"},"Mounts":[{"Destination":"/run/ko","Source":"/state/runtimes/dev/io"}]}]"#;
        let mut stage = Stage::Inspect;
        assert_eq!(
            args(advance(
                &mut stage,
                0,
                &running.replace("running", "exited"),
                ""
            )),
            words(&["start", "ko-dev"])
        );
        assert_eq!(stage, Stage::Start);
        assert_eq!(
            args(advance(&mut Stage::Inspect, 0, running, "")),
            words(&["exec", "ko-dev", "/opt/ko/bin/ko", "version"])
        );
        let mut mine = settings.clone();
        mine.from = Source::Container("mine".to_owned().try_into().unwrap());
        let check = |stdout: &str| {
            next(
                &Engine::Podman(mine.clone()),
                &mut Stage::Inspect,
                false,
                &cx,
                &Outcome {
                    exit: Exit::Exited(0),
                    stdout: stdout.as_bytes(),
                    tail: &[],
                },
            )
        };
        assert_eq!(
            args(check(running)),
            words(&["exec", "mine", "/opt/ko/bin/ko", "version"])
        );
        assert_eq!(
            failure(check(&running.replace("/state/runtimes/dev/io", "/other"))),
            "container mine does not mount the socket of runtime dev: create it with -v /state/runtimes/dev/io:/run/ko"
        );
        assert!(
            cleanup(
                &Engine::Podman(mine.clone()),
                (&rig.key, &[]),
                Cleanup::Stop
            )
            .is_none()
        );
        assert!(
            cleanup(
                &Engine::Podman(mine.clone()),
                (&rig.key, &[]),
                Cleanup::Delete
            )
            .is_none()
        );
        for (what, want) in [
            (Cleanup::Stop, words(&["stop", "ko-dev"])),
            (Cleanup::Delete, words(&["rm", "--force", "ko-dev"])),
        ] {
            let launch = cleanup(engine, (&rig.key, &[]), what);
            if cfg!(target_os = "linux") {
                assert_eq!(launch.unwrap().args, want);
            } else {
                assert!(launch.is_none());
            }
        }
        assert_eq!(
            watch(engine, &cx).unwrap().args,
            words(&["exec", "-i", "ko-dev", "/opt/ko/bin/ko", "enter", "--watch"])
        );
        assert_eq!(
            exec_launch(engine, &cx).unwrap().args,
            words(&[
                "exec",
                "-i",
                "-u",
                "1000",
                "ko-dev",
                "/opt/ko/bin/ko",
                "enter",
                "--exec"
            ])
        );
        let file = Path::new("/state/runtimes/dev/panes/pane_7.env");
        let entry = entry(&rig.key, engine, (&[], file));
        assert_eq!(
            entry.prefix,
            words(&[
                "/usr/bin/podman",
                "exec",
                "-t",
                "-i",
                "-u",
                "1000",
                "--env-file",
                "/state/runtimes/dev/panes/pane_7.env",
                "ko-dev"
            ])
            .into_iter()
            .map(String::into_bytes)
            .collect::<Vec<_>>()
        );
    }

    #[test]
    fn a_start_runs_the_system_check_then_inspects_the_container() {
        let image = settings(IMAGE);
        let rig = Rig::new();
        assert_eq!(
            first(&Engine::Apple(image.clone()), &rig.ctx())
                .unwrap()
                .args,
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
                "/state/runtimes/dev/io/socket:/run/ko/socket",
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
            "the static Linux ko is missing at /nonexistent/share/ko/linux/aarch64: run make build-linux"
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
        let elsewhere = RUNNING.replace("/state/runtimes/dev/io/socket", "/other/socket");
        let mut stage = Stage::Inspect;
        assert_eq!(
            failure(advance(&mine, &mut stage, (0, &elsewhere, ""))),
            "container mine does not mount the socket of runtime dev: create it with -v /state/runtimes/dev/io/socket:/run/ko/socket"
        );
        let mut stage = Stage::Inspect;
        let absent = (1, "", "Error: container not found: mine\n");
        assert_eq!(
            failure(advance(&mine, &mut stage, absent)),
            "Error: container not found: mine"
        );
        let key = RuntimeKey::config("dev".parse().unwrap());
        assert!(cleanup(&Engine::Apple(mine.clone()), (&key, &[]), Cleanup::Stop).is_none());
        assert!(cleanup(&Engine::Apple(mine.clone()), (&key, &[]), Cleanup::Delete).is_none());
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
            watch(&Engine::Apple(image.clone()), &rig.ctx())
                .unwrap()
                .args,
            words(&["exec", "-i", "ko-dev", "/opt/ko/bin/ko", "enter", "--watch"])
        );
        let target = (&rig.key, &[][..]);
        let stop = cleanup(&Engine::Apple(image.clone()), target, Cleanup::Stop).unwrap();
        assert_eq!(stop.program, PathBuf::from("/usr/local/bin/container"));
        assert_eq!(stop.args, words(&["stop", "ko-dev"]));
        let delete = cleanup(&Engine::Apple(image.clone()), target, Cleanup::Delete).unwrap();
        assert_eq!(delete.args, words(&["delete", "--force", "ko-dev"]));
    }

    #[test]
    fn a_pane_enters_through_exec_with_the_token_in_an_env_file_and_never_in_an_argv() {
        let key = RuntimeKey::config("dev".parse().unwrap());
        let found = settings(
            r#"{"from":{"image":"debian:trixie"},"user":"1000:1000","container":"/usr/local/bin/container"}"#,
        );
        let file = Path::new("/state/runtimes/dev/panes/pane_7.env");
        let entry = entry(&key, &Engine::Apple(found.clone()), (&[], file));
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
            root: Path::new("/state/runtimes"),
            key: &rig.key,
            env: &env,
            socket: &rig.socket,
            exe: &rig.exe,
        };
        let launch = exec_launch(&Engine::Apple(found.clone()), &cx).unwrap();
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
