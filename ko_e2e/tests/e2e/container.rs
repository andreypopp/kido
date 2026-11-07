use std::cell::RefCell;
use std::fs;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::Duration;

use ko_sys::pid::Exit;
use serde_json::{Value, json};

use crate::harness::{
    Dir, Server, enabled, ko, poll_for, run_ko, run_program, test_env, text_of, which,
};
use crate::panes::{api, post, token_pane_in_new_session};
use crate::runtime::{read_exec, serve_in, start_exec, start_tree};

// Runs only with KO_E2E_CONTAINER=1, on a Mac where `container system status` succeeds, with the
// debian:trixie image already present; then a missing layout or container CLI is a failure.
// VM start is slow, so the deadline is longer than the suite's.
const CONTAINER_DEADLINE: Duration = Duration::from_secs(60);
const LINK_POLL: (Duration, Duration) = (CONTAINER_DEADLINE, Duration::from_millis(10));
const ENGINE_POLL: (Duration, Duration) = (CONTAINER_DEADLINE, Duration::from_millis(200));

#[test]
fn the_static_linux_ko_runs_in_a_container() {
    if !enabled("KO_E2E_CONTAINER") {
        return;
    }
    let layout = layout(EngineKind::Apple);
    let container = which("container").expect("KO_E2E_CONTAINER needs the container CLI");
    let scratch = Dir::new("ko-container-");
    let env = test_env(&scratch);
    let volume = format!("{}:/opt/ko:ro", text_of(&layout.canonicalize().unwrap()));
    let args = [
        "run",
        "--rm",
        "--volume",
        &volume,
        "debian:trixie",
        "/bin/sh",
        "-c",
        "/opt/ko/bin/ko version && /opt/ko/bin/ko --help >/dev/null",
    ];
    let run = run_program(&scratch, &container, &env, &args, "", CONTAINER_DEADLINE);
    assert_eq!(run.exit, Exit::Exited(0), "{run:?}");
    let inside: Value = serde_json::from_str(&run.stdout).unwrap();
    let host = run_ko(&scratch, &env, &["version"], "").json();
    assert_eq!(inside, host);
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum EngineKind {
    Apple,
    Podman,
}

#[derive(Debug, Clone, Copy)]
struct EngineSpec {
    program: &'static str,
    arch: &'static str,
    image: &'static str,
    inspect: &'static [&'static str],
    missing_exit: Exit,
    missing_text: &'static str,
    state_path: [&'static str; 2],
    remove: &'static str,
    stopped: &'static str,
}

impl EngineKind {
    fn spec(self) -> EngineSpec {
        match self {
            Self::Apple => EngineSpec {
                program: "container",
                arch: "aarch64",
                image: "debian:trixie",
                inspect: &["inspect"],
                missing_exit: Exit::Exited(1),
                missing_text: "not found",
                state_path: ["status", "state"],
                remove: "delete",
                stopped: "stopped",
            },
            Self::Podman => EngineSpec {
                program: "podman",
                arch: std::env::consts::ARCH,
                image: "docker.io/library/debian:trixie",
                inspect: &["container", "inspect"],
                missing_exit: Exit::Exited(125),
                missing_text: "no such container",
                state_path: ["State", "Status"],
                remove: "rm",
                stopped: "exited",
            },
        }
    }
}

fn layout(kind: EngineKind) -> PathBuf {
    let layout = ko()
        .parent()
        .and_then(Path::parent)
        .unwrap()
        .join(format!("share/ko/linux/{}", kind.spec().arch));
    assert!(
        layout.join("bin/ko").exists(),
        "{} is missing: run make build-linux first",
        layout.display()
    );
    layout
}

struct Engine {
    kind: EngineKind,
    container: PathBuf,
    scratch: Dir,
    name: String,
}

impl Engine {
    fn run(&self, args: &[&str]) -> crate::harness::Run {
        let env = test_env(&self.scratch);
        run_program(
            &self.scratch,
            &self.container,
            &env,
            args,
            "",
            CONTAINER_DEADLINE,
        )
    }

    fn state(&self) -> Option<String> {
        let target = format!("ko-{}", self.name);
        let spec = self.kind.spec();
        let mut args = spec.inspect.to_vec();
        args.push(&target);
        let run = self.run(&args);
        if run.exit == spec.missing_exit && run.stderr.contains(spec.missing_text) {
            return None;
        }
        assert_eq!(run.exit, Exit::Exited(0), "{run:?}");
        let found: Value = serde_json::from_str(&run.stdout).unwrap();
        Some(
            found[0][spec.state_path[0]][spec.state_path[1]]
                .as_str()
                .unwrap()
                .to_owned(),
        )
    }

    fn wait_state(&self, want: Option<&str>) {
        poll_for(
            &format!("container ko-{} to be {want:?}", self.name),
            ENGINE_POLL,
            || self.state().as_deref() == want,
        );
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        let remove = self.kind.spec().remove;
        let run = self.run(&[remove, "--force", &format!("ko-{}", self.name)]);
        let gone = run.stderr.contains(self.kind.spec().missing_text);
        if std::thread::panicking() {
            eprintln!("container delete: {run:?}");
        } else {
            assert!(run.exit == Exit::Exited(0) || gone, "{run:?}");
        }
    }
}

fn state_of(s: &Server, name: &str) -> String {
    let info: Value =
        serde_json::from_str(&s.request("GET", &format!("/runtimes/{name}"), None, 200)).unwrap();
    info["state"]["type"].as_str().unwrap().to_owned()
}

fn wait_link(s: &Server, name: &str, want: &str) {
    poll_for(&format!("runtime {name} to be {want}"), LINK_POLL, || {
        state_of(s, name) == want
    });
}

struct Showing<'a>(&'a RefCell<String>);

impl Drop for Showing<'_> {
    fn drop(&mut self) {
        if std::thread::panicking() {
            eprintln!("last screen:\n{}", self.0.borrow());
        }
    }
}

fn shell_in(name: &str, script: &str) -> Value {
    json!({"runtime": name, "command": {"type": "shell", "command": script}})
}

#[test]
fn adhoc_container_sessions_are_separate_and_replace_a_stale_container() {
    if !enabled("KO_E2E_CONTAINER") {
        return;
    }
    layout(EngineKind::Apple);
    let program = which("container").expect("KO_E2E_CONTAINER needs the container CLI");
    let s = serve_in(Dir::new("ko-"), "", &[]);
    let name = format!("dev-{}", std::process::id());
    let definition = json!({"container": {"from": {"image": "debian:trixie"}}});
    let mut engines = Vec::new();
    for session in ["first", "second"] {
        let host = token_pane_in_new_session(&s, session);
        let info = api(
            &s,
            Some(&host),
            "PUT",
            &format!("/runtimes/{name}"),
            &definition,
        )
        .json();
        let id = info["source"]["id"].as_str().unwrap();
        let engine = Engine {
            kind: EngineKind::Apple,
            container: program.clone(),
            scratch: Dir::new("ko-container-"),
            name: format!("{id}-{name}"),
        };
        let target = format!("ko-{}", engine.name);
        assert_eq!(engine.state(), None);
        if session == "second" {
            engine
                .run(&["create", "--name", &target, "debian:trixie", "/bin/false"])
                .ok();
            assert_eq!(engine.state().as_deref(), Some("stopped"));
        }
        engines.push(engine);
        let mut body = shell_in(&name, "ko api /version && printf 'ADHOC-READY'; exec cat");
        body["parent"] = json!(host);
        let born = post(&s, Some(&host), "/panes", &body);
        let pane = born["pane"].as_str().unwrap();
        poll_for(
            "ad-hoc container pane reaches its own socket",
            LINK_POLL,
            || s.screen(pane).contains("ADHOC-READY"),
        );
        for engine in &engines {
            assert_eq!(engine.state().as_deref(), Some("running"));
        }
    }
    assert_eq!(engines[1].state().as_deref(), Some("running"));
    assert_ne!(engines[0].name, engines[1].name);
}

#[test]
fn a_container_runtime_starts_on_the_first_pane_and_follows_its_container() {
    if !enabled("KO_E2E_CONTAINER") {
        return;
    }
    runtime_lifecycle(EngineKind::Apple);
}

#[test]
fn a_podman_runtime_starts_on_the_first_pane_and_follows_its_container() {
    if !enabled("KO_E2E_PODMAN") {
        return;
    }
    if cfg!(target_os = "linux") {
        runtime_lifecycle(EngineKind::Podman);
    } else {
        panic!("KO_E2E_PODMAN needs a Linux server");
    }
}

fn runtime_lifecycle(kind: EngineKind) {
    let spec = kind.spec();
    let layout = layout(kind);
    let program = spec.program;
    let cli = which(program).expect("the enabled engine test needs its CLI");
    let scratch = Dir::new("ko-e2e-engine-");
    let container = match kind {
        EngineKind::Apple => cli,
        EngineKind::Podman => {
            let wrapper = scratch.join("podman");
            let mut script = String::from("#!/bin/sh\n");
            for key in [
                "HOME",
                "XDG_CONFIG_HOME",
                "XDG_DATA_HOME",
                "XDG_RUNTIME_DIR",
            ] {
                match std::env::var(key) {
                    Ok(value) => script
                        .push_str(&format!("export {key}={}\n", crate::harness::quote(&value))),
                    Err(_) => script.push_str(&format!("unset {key}\n")),
                }
            }
            script.push_str(&format!(
                "exec {} \"$@\"\n",
                crate::harness::quote(text_of(&cli))
            ));
            fs::write(&wrapper, script).unwrap();
            fs::set_permissions(&wrapper, fs::Permissions::from_mode(0o700)).unwrap();
            wrapper
        }
    };
    let name = format!("e2e-{program}-{}", std::process::id());
    let engine = Engine {
        kind,
        container: container.clone(),
        scratch,
        name: name.clone(),
    };
    if matches!(kind, EngineKind::Podman) {
        let present = engine.run(&["image", "exists", spec.image]);
        assert_eq!(
            present.exit,
            Exit::Exited(0),
            "KO_E2E_PODMAN needs docker.io/library/debian:trixie already present: {present:?}"
        );
    }
    let volume = Dir::new("ko-vol-");
    fs::write(volume.join("hello.txt"), "from-the-host").unwrap();
    let host_volume = fs::canonicalize(&*volume).unwrap();
    let user_name = format!("{name}-user");
    let user_config = match kind {
        EngineKind::Apple => String::new(),
        EngineKind::Podman => format!(
            "  {user_name}:\n    podman:\n      from: {{container: ko-{user_name}}}\n      podman: {}\n",
            text_of(&container)
        ),
    };
    let text = format!(
        r#"
runtimes:
  {name}:
    {program}:
      from: {{image: "{image}"}}
      {program}: {container}
      {run_args}
      volumes:
        - host: {host}
          runtime: /work
    env:
      FROM_CONFIG: "yes"
{user_config}"#,
        run_args = match kind {
            EngineKind::Apple => "",
            EngineKind::Podman => "run_args: ['--pull=never']",
        },
        image = spec.image,
        container = text_of(&container),
        host = text_of(&host_volume),
    );
    let s = serve_in(
        Dir::new("ko-"),
        &text,
        &[
            ("KO_STOP_ESCALATION_MS", "2000"),
            ("HOST_ONLY_SENTINEL", "secret"),
            ("HTTP_PROXY", "http://ko-e2e-proxy.invalid:1234"),
        ],
    );

    let script = "stty -echo; echo up-$KO_RUNTIME; echo S=$KO_SOCKET; echo T=$TERM; \
        echo D=$TERMINFO_DIRS; echo F=$FROM_CONFIG; echo H=$(cat /work/hello.txt); \
        echo V=$(/opt/ko/bin/ko api /version | grep -o '\"protocol\":\"[0-9.]*\"'); \
        echo P=$(/opt/ko/bin/ko api /panes | grep -o -m1 '\"runtime\":\"'$KO_RUNTIME'\"'); \
        echo I=$(test ! -e /run/ko/panes && echo private); \
        echo E=${HOST_ONLY_SENTINEL-unset}/${HTTP_PROXY-unset}; echo W=$PWD; exec cat";
    let mut request = shell_in(&name, script);
    request["cwd"] = json!(text_of(&host_volume));
    let first = s.new_pane(request);
    let second = s.new_pane(shell_in(&name, "echo second-$KO_RUNTIME; exec cat"));
    wait_link(&s, &name, "up");
    for needle in [
        format!("up-{name}"),
        "S=/run/ko/socket".to_owned(),
        "T=xterm-ghostty".to_owned(),
        "/opt/ko/share/ko/terminfo".to_owned(),
        "F=yes".to_owned(),
        "H=from-the-host".to_owned(),
        "V=\"protocol\":\"1.0\"".to_owned(),
        format!("P=\"runtime\":\"{name}\""),
        "W=/work".to_owned(),
        "I=private".to_owned(),
        "E=unset/unset".to_owned(),
    ] {
        s.screen_has(&first, &needle);
    }
    s.screen_has(&second, &format!("second-{name}"));
    let shell = s.new_pane(json!({"runtime": name}));
    s.wait_row(&shell, "passwd shell is primed", |row| {
        row["status"]["kind"]["phase"]["type"] == "idle"
    });
    s.text(&shell, "printf 'PASSWD=%s\\n' \"${BASH_VERSION:+bash}\"; mkdir -p '/tmp/sp ace'; cd '/tmp/sp ace'\r");
    s.screen_has(&shell, "PASSWD=bash");
    s.wait_row(&shell, "container cwd follows cd", |row| {
        row["cwd"]
            .as_str()
            .is_some_and(|cwd| cwd.ends_with("/sp%20ace"))
    });
    let split = s.new_pane(json!({"runtime": name, "cwd": {"pane": shell}}));
    s.text(&split, "pwd -P\r");
    s.screen_has(&split, "/tmp/sp ace");
    s.wait_row(&split, "container split reports cwd", |row| {
        row["cwd"]
            .as_str()
            .is_some_and(|cwd| cwd.ends_with("/sp%20ace"))
    });
    assert_eq!(engine.state().as_deref(), Some("running"));
    let io = s.dir.join(format!("runtimes/{name}/io"));
    let inode = fs::metadata(&io).unwrap().ino();

    let env_file = s.dir.join(format!("runtimes/{name}/panes/{first}.env"));
    assert_eq!(
        fs::metadata(&env_file).unwrap().permissions().mode() & 0o777,
        0o600
    );
    let contents = fs::read_to_string(&env_file).unwrap();
    let token = contents
        .strip_prefix("KO_PANE_TOKEN=")
        .unwrap()
        .trim()
        .to_owned();
    let ps = run_program(
        &s.scratch,
        Path::new("/bin/ps"),
        &test_env(&s.scratch),
        &["-axww", "-o", "args="],
        "",
        CONTAINER_DEADLINE,
    )
    .ok();
    assert!(ps.contains(&format!("{program} exec")), "{ps}");
    assert!(!ps.contains(&token), "the token is in an argv");

    let shell = s.new_pane(json!({"runtime": name}));
    s.text(&shell, "echo shell-$KO_RUNTIME\n");
    s.screen_has(&shell, &format!("shell-{name}"));

    let mut ws = start_exec(
        &s,
        &name,
        json!({"argv": ["sh", "-c", "echo out-$KO_RUNTIME-$FROM_CONFIG; echo err >&2; exit 3"],
        "stdin": false}),
    );
    ws.within(CONTAINER_DEADLINE);
    let exec = read_exec(&mut ws);
    assert_eq!(
        String::from_utf8(exec.stdout).unwrap(),
        format!("out-{name}-yes\n")
    );
    assert_eq!(String::from_utf8(exec.stderr).unwrap(), "err\n");
    assert_eq!(exec.end, json!({"type": "exit", "status": 3}));

    let mut ws = start_exec(
        &s,
        &name,
        json!({"argv": ["sh", "-c", "kill -USR1 $$"], "stdin": false}),
    );
    ws.within(CONTAINER_DEADLINE);
    assert_eq!(
        read_exec(&mut ws).end,
        json!({"type": "exit", "signal": "USR1"}),
        "a signal exit keeps its name"
    );

    // The pids are the container's, so the probe is an exec in the container as well.
    let ws = start_tree(&s, &name, (&host_volume, "/work"));
    let numbers: Vec<String> = ["leader", "child", "grandchild"]
        .iter()
        .map(|member| {
            let file = host_volume.join(member);
            poll_for(&format!("the pid of the {member}"), LINK_POLL, || {
                fs::read_to_string(&file).is_ok_and(|text| text.trim().parse::<u32>().is_ok())
            });
            fs::read_to_string(&file).unwrap().trim().to_owned()
        })
        .collect();
    drop(ws);
    let probe = format!(
        "for pid in {}; do read -r _ _ state _ < /proc/$pid/stat 2>/dev/null && [ \"$state\" != Z ] && echo \"$pid $state\" && exit 1; done; exit 0",
        numbers.join(" ")
    );
    let last = RefCell::new(String::new());
    let _showing = Showing(&last);
    poll_for(
        "the group of a closed session to end in the container",
        ENGINE_POLL,
        || {
            let mut ws = start_exec(
                &s,
                &name,
                json!({"argv": ["sh", "-c", &probe], "stdin": false}),
            );
            ws.within(CONTAINER_DEADLINE);
            let done = read_exec(&mut ws);
            *last.borrow_mut() = String::from_utf8_lossy(&done.stdout).into_owned();
            done.end == json!({"type": "exit", "status": 0})
        },
    );

    s.request(
        "POST",
        &format!("/runtimes/{name}/down"),
        Some(&json!({"force": true})),
        200,
    );
    assert_eq!(state_of(&s, &name), "down");
    engine.wait_state(Some(spec.stopped));

    let again = s.new_pane(shell_in(&name, "echo again-$KO_RUNTIME; echo API=$(/opt/ko/bin/ko api /version | grep -o '\"protocol\":\"[0-9.]*\"'); exec cat"));
    wait_link(&s, &name, "up");
    s.screen_has(&again, &format!("again-{name}"));
    s.screen_has(&again, "API=\"protocol\":\"1.0\"");
    wait_link(&s, &name, "up");
    assert_eq!(
        engine.run(&["stop", &format!("ko-{name}")]).exit,
        Exit::Exited(0)
    );
    wait_link(&s, &name, "down");
    let revived = s.new_pane(shell_in(&name, "echo revived-$KO_RUNTIME; exec cat"));
    s.screen_has(&revived, &format!("revived-{name}"));

    s.request(
        "POST",
        &format!("/runtimes/{name}/down"),
        Some(&json!({"force": true})),
        200,
    );
    s.request("DELETE", &format!("/runtimes/{name}"), None, 200);
    engine.wait_state(None);
    assert_eq!(fs::metadata(&io).unwrap().ino(), inode);
    assert_eq!(
        fs::read_dir(s.dir.join(format!("runtimes/{name}/io")))
            .unwrap()
            .count(),
        0
    );
    if kind == EngineKind::Podman {
        let user = Engine {
            kind,
            container: engine.container.clone(),
            scratch: Dir::new("ko-e2e-user-"),
            name: user_name.clone(),
        };
        let user_io = s.dir.join(format!("runtimes/{user_name}/io"));
        fs::create_dir_all(&user_io).unwrap();
        let user_inode = fs::metadata(&user_io).unwrap().ino();
        let target = format!("ko-{user_name}");
        let socket_mount = format!("{}:/run/ko", text_of(&user_io));
        let ko_mount = format!(
            "type=bind,source={},target=/opt/ko,readonly",
            text_of(&layout.canonicalize().unwrap())
        );
        user.run(&[
            "run",
            "-d",
            "--name",
            &target,
            "--init",
            "--security-opt",
            "label=disable",
            "--http-proxy=false",
            "-v",
            &socket_mount,
            "--mount",
            &ko_mount,
            "--pull=never",
            spec.image,
            "sleep",
            "infinity",
        ])
        .ok();
        let command = "echo API=$(/opt/ko/bin/ko api /version | grep -o '\"protocol\":\"[0-9.]*\"'); exec cat";
        let first = s.new_pane(shell_in(&user_name, command));
        wait_link(&s, &user_name, "up");
        s.screen_has(&first, "API=\"protocol\":\"1.0\"");
        s.request(
            "POST",
            &format!("/runtimes/{user_name}/down"),
            Some(&json!({"force": true})),
            200,
        );
        assert_eq!(user.state().as_deref(), Some("running"));
        s.request("DELETE", &format!("/runtimes/{user_name}"), None, 200);
        assert_eq!(user.state().as_deref(), Some("running"));
        assert_eq!(fs::metadata(&user_io).unwrap().ino(), user_inode);
        let again = s.new_pane(shell_in(&user_name, command));
        wait_link(&s, &user_name, "up");
        s.screen_has(&again, "API=\"protocol\":\"1.0\"");
        s.request(
            "POST",
            &format!("/runtimes/{user_name}/down"),
            Some(&json!({"force": true})),
            200,
        );
        s.request("DELETE", &format!("/runtimes/{user_name}"), None, 200);
        assert_eq!(user.state().as_deref(), Some("running"));
    }
}

#[test]
fn a_container_runtime_that_cannot_start_fails_and_leaves_no_socket() {
    let s = serve_in(
        Dir::new("ko-"),
        "
runtimes:
  nocli:
    container: {from: {image: x}, container: no-such-container-cli}
  linuxonly:
    podman: {from: {image: x}, podman: no-such-podman-cli}
  gone:
    container: {from: {image: x}, container: /nonexistent/container}
",
        &[],
    );
    let mut cases = vec![
        (
            "nocli",
            "no-such-container-cli: command not found on the PATH of the server",
        ),
        ("gone", "the up step did not start:"),
    ];
    if !cfg!(target_os = "linux") {
        cases.push(("linuxonly", "the podman kind runs only on a Linux server"));
    }
    for (name, message) in cases {
        s.new_pane(shell_in(name, "exec cat"));
        wait_link(&s, name, "failed");
        let info: Value =
            serde_json::from_str(&s.request("GET", &format!("/runtimes/{name}"), None, 200))
                .unwrap();
        let shown = info["state"]["message"].as_str().unwrap();
        assert!(shown.starts_with(message), "{name}: {shown}");
        assert!(!s.dir.join(format!("runtimes/{name}/io/socket")).exists());
    }
}
