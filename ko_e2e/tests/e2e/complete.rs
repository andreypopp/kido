use std::io::Read;
use std::os::unix::net::UnixListener;
use std::time::Duration;

use crate::harness::{DEADLINE, Dir, ko, poll, run_program, test_env, text_of};
use crate::panes::token_pane_in_new_session;
use crate::runtime::serve_in;

#[test]
fn complete_live_values_and_paths() {
    let s = serve_in(
        Dir::new("ko-complete-"),
        "runtimes:\n  configured: {command: {}}\n",
        &[],
    );
    let a = token_pane_in_new_session(&s, "a");
    let b = token_pane_in_new_session(&s, "b");
    s.ko_as(
        Some(&a),
        &["api", "--method", "PUT", "--input", "-", "/runtimes/local"],
        r#"{"command":{}}"#,
    )
    .ok();
    let document = s.doc();
    let session = document["layout"]["sessions"][0]["id"].as_str().unwrap();
    let window = document["layout"]["sessions"][0]["windows"][0]["id"]
        .as_str()
        .unwrap();
    let complete = |shell: &str, words: &[&str], pane: Option<&str>| {
        let mut env = test_env(&s.dir);
        env.extend([
            format!("COMPLETE={shell}").into_bytes(),
            format!("_CLAP_COMPLETE_INDEX={}", words.len() - 1).into_bytes(),
            format!("KO_STATE_DIR={}/absent", s.dir.display()).into_bytes(),
        ]);
        if let Some(pane) = pane {
            env.extend([
                format!("KO_SOCKET={}/socket", s.dir.display()).into_bytes(),
                format!("KO_PANE={pane}").into_bytes(),
                format!("KO_PANE_TOKEN={}", s.token(pane).unwrap()).into_bytes(),
            ]);
        }
        let args: Vec<_> = ["--"].into_iter().chain(words.iter().copied()).collect();
        let run = run_program(&s.scratch, &ko(), &env, &args, "", DEADLINE);
        assert_eq!(run.stderr, "", "{run:?}");
        run.ok()
    };
    for shell in ["zsh", "bash"] {
        let mut env = test_env(&s.dir);
        env.push(format!("COMPLETE={shell}").into_bytes());
        let registration = run_program(&s.scratch, &ko(), &env, &[], "", DEADLINE);
        assert_eq!(registration.stderr, "");
        let registration = registration.ok();
        let (stub, variables): (&str, &[&str]) = if shell == "zsh" {
            (
                include_str!("../../../share/ko/zsh/_ko"),
                &["COMPLETE", "_CLAP_COMPLETE_INDEX", "_CLAP_IFS"],
            )
        } else {
            (
                include_str!("../../../share/ko/bash/integration.bash"),
                &[
                    "COMPLETE",
                    "_CLAP_COMPLETE_INDEX",
                    "_CLAP_IFS",
                    "_CLAP_COMPLETE_COMP_TYPE",
                    "_CLAP_COMPLETE_SPACE",
                ],
            )
        };
        for variable in variables {
            assert!(
                registration.contains(variable),
                "{variable}: {registration}"
            );
            assert!(stub.contains(variable), "{variable}: {stub}");
        }
        assert!(stub.contains("ko -- \"${words[@]}\" </dev/null 2>/dev/null"));
        let server = text_of(&s.dir);
        let values = complete(
            shell,
            &["ko", "run", "--server", server, "--name", ""],
            None,
        );
        assert!(values.contains("configured"), "{values}");
        assert!(values.contains("local"), "{values}");
        let scoped = complete(shell, &["ko", "run", "--name", ""], Some(&b));
        assert!(scoped.contains("configured"), "{scoped}");
        assert!(!scoped.contains("local"), "{scoped}");
        let scoped = complete(shell, &["ko", "run", "--name", ""], Some(&a));
        assert!(scoped.contains("local"), "{scoped}");
        let excluded = complete(
            shell,
            &["ko", "run", "--server", server, "--name", "missing"],
            None,
        );
        assert_eq!(excluded, "");
        let override_arg = format!("--server={server}");
        let values = complete(
            shell,
            &["ko", &override_arg, "enter", "--pane", "pane_"],
            None,
        );
        assert!(values.contains(&a) && values.contains(&b), "{values}");
        for path in [
            format!("/panes/{a}/screen"),
            format!("/sessions/{session}"),
            format!("/windows/{window}"),
            "/runtimes/configured/up".into(),
        ] {
            let values = complete(shell, &["ko", "api", &override_arg, &path], None);
            assert!(values.contains(&path), "{path}: {values}");
            assert!(!values.contains("{"), "{values}");
        }
        let values = complete(shell, &["ko", "api", &override_arg, "/panes/missing"], None);
        assert_eq!(values, "");
        let values = complete(
            shell,
            &[
                "ko",
                "api",
                "--host",
                "must-not-connect",
                "/runtimes/configured",
            ],
            None,
        );
        assert_eq!(values, "");
    }
}

#[test]
fn complete_without_a_server_and_with_a_stalled_server() {
    let scratch = Dir::new("ko-complete-absent-");
    let missing = scratch.join("state");
    for shell in ["zsh", "bash"] {
        let mut env = test_env(&scratch);
        env.extend([
            format!("COMPLETE={shell}").into_bytes(),
            b"_CLAP_COMPLETE_INDEX=3".to_vec(),
            format!("KO_STATE_DIR={}", missing.display()).into_bytes(),
        ]);
        let args = ["--", "ko", "run", "--name", ""];
        let run = run_program(&scratch, &ko(), &env, &args, "", DEADLINE);
        assert_eq!(run.stderr, "", "{run:?}");
        assert_eq!(run.ok(), "");
        assert!(!missing.exists());
        let static_path = run_program(
            &scratch,
            &ko(),
            &env,
            &["--", "ko", "api", "--include", "/version"],
            "",
            DEADLINE,
        );
        assert_eq!(static_path.stderr, "");
        assert!(static_path.ok().contains("/version"));

        let state = Dir::new("ko-complete-stalled-");
        let listener = UnixListener::bind(state.join("socket")).unwrap();
        listener.set_nonblocking(true).unwrap();
        let stalled = std::thread::spawn(move || {
            let mut accepted = None;
            poll("the completion connection", || {
                accepted = listener.accept().ok();
                accepted.is_some()
            });
            let (mut socket, _) = accepted.unwrap();
            socket.set_nonblocking(false).unwrap();
            socket.set_read_timeout(Some(DEADLINE)).unwrap();
            let mut received = Vec::new();
            socket.read_to_end(&mut received).unwrap();
            String::from_utf8(received).unwrap()
        });
        let env: Vec<_> = env
            .into_iter()
            .filter(|value| !value.starts_with(b"KO_STATE_DIR="))
            .chain([format!("KO_STATE_DIR={}", state.display()).into_bytes()])
            .collect();
        let run = run_program(&scratch, &ko(), &env, &args, "", Duration::from_secs(1));
        assert_eq!(run.stderr, "", "{run:?}");
        assert_eq!(run.ok(), "");
        assert!(
            stalled
                .join()
                .unwrap()
                .starts_with("GET /runtimes HTTP/1.1\r\n")
        );
    }
}
