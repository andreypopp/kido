use std::path::Path;
use std::time::Duration;

use ko_sys::pid::Exit;
use serde_json::Value;

use crate::harness::{Dir, enabled, ko, run_ko, run_program, test_env, text_of, which};

// Runs only with KO_E2E_CONTAINER=1, on a Mac where `container system status` succeeds, with the
// debian:trixie image already present; then a missing layout or container CLI is a failure.
// VM start is slow, so the deadline is longer than the suite's.
const CONTAINER_DEADLINE: Duration = Duration::from_secs(60);

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
