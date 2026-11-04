use std::cell::RefCell;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::Duration;

use ko_sys::pid::Exit;
use serde_json::{Value, json};

use crate::harness::{
    Dir, Server, enabled, ko, poll_for, run_ko, run_program, start_in, test_env, text_of, which,
};
use crate::runtime::{read_exec, start_exec};

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
    let host_ko = ko();
    let layout = host_ko
        .parent()
        .and_then(Path::parent)
        .unwrap()
        .join("share/ko/linux/aarch64");
    assert!(
        layout.join("bin/ko").exists(),
        "{} is missing: run make build-ko-linux first",
        layout.display()
    );
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

struct Engine {
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
        let run = self.run(&["inspect", &format!("ko-{}", self.name)]);
        if run.exit == Exit::Exited(1) && run.stderr.contains("not found") {
            return None;
        }
        assert_eq!(run.exit, Exit::Exited(0), "{run:?}");
        let found: Value = serde_json::from_str(&run.stdout).unwrap();
        Some(found[0]["status"]["state"].as_str().unwrap().to_owned())
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
        let run = self.run(&["delete", "--force", &format!("ko-{}", self.name)]);
        let gone = run.stderr.contains("not found");
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

fn screen_has(s: &Server, pane: &str, needle: &str) {
    let last = RefCell::new(String::new());
    let _showing = Showing(&last);
    poll_for(
        &format!("{needle} on the screen of {pane}"),
        LINK_POLL,
        || {
            *last.borrow_mut() = s.screen(pane);
            last.borrow().contains(needle)
        },
    );
}

fn shell_in(name: &str, script: &str) -> Value {
    json!({"runtime": name, "command": {"type": "shell", "command": script}})
}

#[test]
fn a_container_runtime_starts_on_the_first_pane_and_follows_its_container() {
    if !enabled("KO_E2E_CONTAINER") {
        return;
    }
    let layout = ko()
        .parent()
        .and_then(Path::parent)
        .unwrap()
        .join("share/ko/linux/aarch64");
    assert!(
        layout.join("bin/ko").exists(),
        "{} is missing: run make build-ko-linux first",
        layout.display()
    );
    let container = which("container").expect("KO_E2E_CONTAINER needs the container CLI");
    let name = format!("ctr{}", std::process::id());
    let engine = Engine {
        container: container.clone(),
        scratch: Dir::new("ko-ctr-"),
        name: name.clone(),
    };
    let volume = Dir::new("ko-vol-");
    fs::write(volume.join("hello.txt"), "from-the-host").unwrap();
    let host_volume = fs::canonicalize(&*volume).unwrap();
    let config = Dir::new("ko-rtc-");
    let file = config.join("runtimes.json");
    let runtimes = json!({"runtimes": {&name: {
        "kind": "container",
        "from": {"image": "debian:trixie"},
        "container": text_of(&container),
        "volumes": [{"host": text_of(&host_volume), "runtime": "/work"}],
        "env": {"FROM_CONFIG": "yes"},
    }}});
    fs::write(&file, runtimes.to_string()).unwrap();
    let s = start_in(
        Dir::new("ko-"),
        Path::new("/bin/sh"),
        &[],
        &["--runtimes", text_of(&file)],
    );

    let script = "stty raw -echo; echo up-$KO_RUNTIME; echo S=$KO_SOCKET; echo T=$TERM; \
        echo D=$TERMINFO_DIRS; echo F=$FROM_CONFIG; echo H=$(cat /work/hello.txt); \
        echo V=$(/opt/ko/bin/ko api /version | grep -o '\"protocol\":\"[0-9.]*\"'); \
        echo P=$(/opt/ko/bin/ko api /panes | grep -o -m1 '\"runtime\":\"'$KO_RUNTIME'\"'); \
        echo W=$PWD; exec cat";
    let mut request = shell_in(&name, script);
    request["cwd"] = json!(text_of(&host_volume));
    let first = s.new_pane(request);
    let second = s.new_pane(shell_in(&name, "echo second-$KO_RUNTIME; exec cat"));
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
    ] {
        screen_has(&s, &first, &needle);
    }
    screen_has(&s, &second, &format!("second-{name}"));
    assert_eq!(engine.state().as_deref(), Some("running"));

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
    assert!(ps.contains("container exec"), "{ps}");
    assert!(!ps.contains(&token), "the token is in an argv");

    let shell = s.new_pane(json!({"runtime": name}));
    s.text(&shell, "echo shell-$KO_RUNTIME\n");
    screen_has(&s, &shell, &format!("shell-{name}"));

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

    s.request(
        "POST",
        &format!("/runtimes/{name}/down"),
        Some(&json!({"force": true})),
        200,
    );
    assert_eq!(state_of(&s, &name), "down");
    engine.wait_state(Some("stopped"));

    let again = s.new_pane(shell_in(&name, "echo again-$KO_RUNTIME; exec cat"));
    screen_has(&s, &again, &format!("again-{name}"));
    wait_link(&s, &name, "up");
    assert_eq!(
        engine.run(&["stop", &format!("ko-{name}")]).exit,
        Exit::Exited(0)
    );
    wait_link(&s, &name, "down");
    let revived = s.new_pane(shell_in(&name, "echo revived-$KO_RUNTIME; exec cat"));
    screen_has(&s, &revived, &format!("revived-{name}"));

    s.request(
        "POST",
        &format!("/runtimes/{name}/down"),
        Some(&json!({"force": true})),
        200,
    );
    s.request("DELETE", &format!("/runtimes/{name}"), None, 200);
    engine.wait_state(None);
    assert!(!s.dir.join(format!("runtimes/{name}")).exists());
}

#[test]
fn a_container_runtime_that_cannot_start_fails_and_leaves_no_socket() {
    let config = Dir::new("ko-rtc-");
    let file = config.join("runtimes.json");
    let runtimes = json!({"runtimes": {
        "nocli": {"kind": "container", "from": {"image": "x"}, "container": "no-such-container-cli"},
        "gone": {"kind": "container", "from": {"image": "x"}, "container": "/nonexistent/container"},
    }});
    fs::write(&file, runtimes.to_string()).unwrap();
    let s = start_in(
        Dir::new("ko-"),
        Path::new("/bin/sh"),
        &[],
        &["--runtimes", text_of(&file)],
    );
    for (name, message) in [
        (
            "nocli",
            "no-such-container-cli: command not found on the PATH of the server",
        ),
        ("gone", "the up step did not start:"),
    ] {
        s.new_pane(shell_in(name, "exec cat"));
        wait_link(&s, name, "failed");
        let info: Value =
            serde_json::from_str(&s.request("GET", &format!("/runtimes/{name}"), None, 200))
                .unwrap();
        let shown = info["state"]["message"].as_str().unwrap();
        assert!(shown.starts_with(message), "{name}: {shown}");
        assert!(!s.dir.join(format!("runtimes/{name}/socket")).exists());
    }
}
