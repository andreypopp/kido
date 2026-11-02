use serde_json::json;

use crate::harness::{history_lines, run_ko, start, test_env};

#[test]
fn defaults_and_pane_environment() {
    let s = start(&["--scrollback-bytes", "80M", "--scrollback-lines", "100"]);
    let (mut c, welcome) = s.client(None);
    let terminal = &welcome["limits"]["terminal"];
    let scrollback = &terminal["scrollback"];
    assert_eq!(
        scrollback["type"],
        json!("scrollback"),
        "limits: {}",
        welcome["limits"]
    );
    assert_eq!(scrollback["max_bytes"], json!(80 * 1024 * 1024));
    assert_eq!(scrollback["max_lines"], json!(100));
    assert_eq!(terminal["continuation_max_bytes"], json!(65 * 1024 * 1024));

    let mut env = test_env(&s.dir);
    env.extend([
        b"KO_FUZZ_SECONDS=abc".to_vec(),
        b"KO_FUZZ_SEED=abc".to_vec(),
        b"KO_AFL_SOURCE=/nonexistent".to_vec(),
    ]);
    let version = run_ko(&s.scratch, &env, &["version"], "").json();
    let build = version["build"].as_str().unwrap_or_default().to_owned();
    assert!(!build.is_empty(), "ko version has no build field");

    let created = s
        .ko(
            &["api", "--input", "-", "/panes"],
            r#"{"cwd": "/tmp", "env": [
                {"name": "X", "value": "custom"},
                {"name": "TERM", "value": "wrong"},
                {"name": "KO_PANE", "value": "wrong"}
            ]}"#,
        )
        .json();
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

    let screen = s
        .ko(&["api", &format!("/panes/{pane}/screen?history=all")], "")
        .ok();
    let expected = format!(
        "xterm-ghostty|{pane}|{}/socket|custom|ko|{build}",
        s.dir.display()
    );
    assert!(screen.contains(&expected), "pane environment: {screen:?}");
    assert!(screen.contains("/tmp"), "pane cwd: {screen:?}");
    assert!(
        screen.contains("history-2999"),
        "last history line: {screen:?}"
    );
    assert!(
        !screen.contains("history-0\n") && !screen.contains("history-0\r"),
        "lines limit kept {} bytes of history",
        screen.len()
    );

    s.ko(&["api", "--input", "-", "/panes"], r#"{"cwd": "relative"}"#)
        .http_error(400);
    s.ko(&["api", "--input", "-", "/panes"], "[]")
        .http_error(400);
}
