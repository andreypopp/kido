use serde_json::json;

use crate::harness::{history_lines, run_ko, start, test_env};

#[test]
fn defaults_and_pane_environment() {
    let mut s = start(&["--scrollback-bytes", "80M", "--scrollback-lines", "100"]);
    let (mut c, _) = s.client("");
    let terminal = &s.limits["terminal"];
    let scrollback = &terminal["scrollback"];
    assert!(
        scrollback[0] == json!("scrollback")
            && scrollback[1]["max_bytes"] == json!(80 * 1024 * 1024)
            && scrollback[1]["max_lines"] == json!(100)
            && terminal["continuation_max_bytes"] == json!(65 * 1024 * 1024),
        "terminal contract: {}",
        s.limits
    );
    let mut env = test_env(&s.dir);
    env.extend([
        b"KO_FUZZ_SECONDS=abc".to_vec(),
        b"KO_FUZZ_SEED=abc".to_vec(),
        b"KO_AFL_SOURCE=/nonexistent".to_vec(),
    ]);
    let run = run_ko(&s.scratch, &env, &["version"], "");
    assert_eq!(
        run.code, 0,
        "ko version with fuzz variables set: {} {}",
        run.stdout, run.stderr
    );
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
    let command = format!(
        "{}; printf '%s|%s|%s|%s|%s|%s\\n' \"$TERM\" \"$KO_PANE\" \"$KO_SOCKET\" \"$X\" \"$TERM_PROGRAM\" \"$TERM_PROGRAM_VERSION\"; pwd; exit\n",
        history_lines(3000)
    );
    s.text(&pane, &command);
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
    assert!(
        screen.contains("history-2999")
            && !screen.contains("history-0\n")
            && !screen.contains("history-0\r"),
        "lines limit kept {} bytes of history",
        screen.len()
    );
    assert!(!build.is_empty(), "ko version has no build field");
    s.request("POST", "/panes", Some(&json!({"cwd": "relative"})), 400);
    s.request("POST", "/panes", Some(&json!(["invalid"])), 400);
}
