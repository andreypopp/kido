use serde_json::json;

use crate::harness::{Dir, run_ko, start, test_env};

#[test]
fn defaults_and_pane_environment() {
    let mut s = start(&["--scrollback-bytes", "80M", "--scrollback-lines", "5000"]);
    let (mut c, _) = s.client("");
    let terminal = &s.limits["terminal"];
    let scrollback = &terminal["scrollback"];
    assert!(
        scrollback[0] == json!("scrollback")
            && scrollback[1]["max_bytes"] == json!(80 * 1024 * 1024)
            && scrollback[1]["max_lines"] == json!(5000)
            && terminal["continuation_max_bytes"] == json!(65 * 1024 * 1024),
        "terminal contract: {}",
        s.limits
    );
    let run = s.run(&["version"]);
    assert_eq!(run.code, 0, "ko version: {}", run.stderr);
    let cli: serde_json::Value = serde_json::from_str(&run.stdout).unwrap();
    let build = cli["build"].as_str().unwrap_or_default().to_owned();
    let created = s.request(
        "POST",
        "/panes",
        Some(&json!({"cwd": "/tmp", "env": [
            {"name": "X", "value": "custom"},
            {"name": "TERM", "value": "wrong"},
            {"name": "KO_PANE", "value": "wrong"},
        ]})),
        200,
    );
    let pane = created["pane"].as_str().unwrap_or_default().to_owned();
    let mut view = s.ws(&format!("/panes/{pane}/view"));
    let prompt_end = if ko_sys::sock::uid() == 0 { "# " } else { "$ " };
    view.ready(prompt_end);
    let command = "printf '%s|%s|%s|%s|%s|%s\\n' \"$TERM\" \"$KO_PANE\" \"$KO_SOCKET\" \"$X\" \"$TERM_PROGRAM\" \"$TERM_PROGRAM_VERSION\"; pwd; exit\n";
    s.text(&pane, command);
    c.event("dead");
    let screen = s.request_text(
        "GET",
        &format!("/panes/{pane}/screen?history=all"),
        None,
        200,
    );
    let expected = format!(
        "xterm-ghostty|{pane}|{}/socket|custom|ko|{build}",
        s.dir.display()
    );
    assert!(
        screen.contains(&expected) && screen.contains("/tmp"),
        "pane environment: {screen:?}"
    );
    assert!(!build.is_empty(), "ko version has no build field");
    s.request("POST", "/panes", Some(&json!({"cwd": "relative"})), 400);
    s.request("POST", "/panes", Some(&json!(["invalid"])), 400);
}

#[test]
fn fuzz_variables_do_not_reach_the_binary() {
    let dir = Dir::new("ko-");
    let mut env = test_env(&dir);
    env.extend([
        b"KO_FUZZ_SECONDS=abc".to_vec(),
        b"KO_FUZZ_SEED=abc".to_vec(),
        b"KO_AFL_SOURCE=/nonexistent".to_vec(),
    ]);
    let run = run_ko(&dir, &env, &["version"], "");
    assert_eq!(
        run.code, 0,
        "ko version with fuzz variables set: {} {}",
        run.stdout, run.stderr
    );
}
