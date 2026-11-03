use std::io::{Read, Write};
use std::os::unix::net::UnixListener;
use std::sync::{Arc, Mutex};
use std::thread;

use serde_json::{Value, json};

use crate::harness::{Server, poll, start, start_with, which};
use crate::runs::{caller, code, ko_as, run_of};

const AGENT: &str =
    "printf '\\033]7501;state=idle:app=pi\\007'; while read line; do echo \"got: $line\"; done";

fn agent_of(name: &str, inbox: Option<&str>) -> Value {
    let mut vars = json!({"pi.session": format!("session-{name}"), "pi.name": name});
    if let Some(inbox) = inbox {
        vars["pi.inbox"] = json!(inbox);
    }
    json!({"command": {"type": "shell", "command": AGENT}, "vars": vars})
}

fn rooted(s: &Server, pane: &str) {
    s.wait_row(pane, "its pi root", |row| {
        row["status"]["program_status"]["records"]
            .as_array()
            .is_some_and(|records| !records.is_empty())
    });
}

fn agent(s: &Server, name: &str) -> String {
    let pane = s.new_pane(agent_of(name, None));
    rooted(s, &pane);
    pane
}

fn split_into(s: &Server, anchor: &str, new: Value) -> String {
    let put = s.edit(|layout| {
        for session in layout["sessions"].as_array_mut().unwrap() {
            for window in session["windows"].as_array_mut().unwrap() {
                if window["tree"]["pane"] == anchor {
                    window["tree"] = json!({"split": "h", "children": [
                        {"pane": anchor}, {"pane": {"new": new.clone()}}]});
                }
            }
        }
    });
    let mut leaves = Vec::new();
    for window in crate::layout::windows(&put) {
        crate::layout::leaves(&window["tree"], &mut leaves);
    }
    let added = leaves
        .into_iter()
        .map(|leaf| leaf.0)
        .filter(|pane| s.rows().iter().any(|row| row["id"] == pane.as_str()))
        .max_by_key(|pane| pane.trim_start_matches("pane_").parse::<u64>().unwrap_or(0));
    added.expect("the split pane")
}

fn prompt(s: &Server, from: &str, text: &str, window: bool) -> (i32, String) {
    let mut args = vec!["prompt"];
    if window {
        args.push("--window");
    }
    let run = ko_as(s, Some(from), &args, text);
    (code(&run), run.stderr)
}

fn arrived(s: &Server, pane: &str, text: &str) {
    s.screen_has(pane, &format!("got: {text}"));
}

fn silent(s: &Server, pane: &str, text: &str) -> bool {
    !s.screen(pane).contains(&format!("got: {text}"))
}

#[derive(Debug)]
struct Inbox {
    path: String,
    received: Arc<Mutex<Vec<String>>>,
}

fn inbox(s: &Server, name: &str, reply: &'static str) -> Inbox {
    let path = s.scratch.join(format!("{name}.sock"));
    let listener = UnixListener::bind(&path).unwrap();
    let received = Arc::new(Mutex::new(Vec::new()));
    let log = received.clone();
    thread::spawn(move || {
        while let Ok((mut peer, _)) = listener.accept() {
            let mut text = String::new();
            let _ = peer.read_to_string(&mut text);
            log.lock().unwrap().push(text);
            let _ = peer.write_all(reply.as_bytes());
        }
    });
    Inbox {
        path: path.to_str().unwrap().to_owned(),
        received,
    }
}

fn stale_socket(s: &Server) -> String {
    let path = s.scratch.join("stale.sock");
    drop(UnixListener::bind(&path).unwrap());
    assert!(path.exists());
    path.to_str().unwrap().to_owned()
}

#[test]
fn a_prompt_goes_by_the_inbox_when_the_agent_has_one_and_by_paste_only_when_it_has_none() {
    let s = start(&[]);
    let from = caller(&s);
    let pane = agent(&s, "pastee");

    assert_eq!(prompt(&s, &from, "hi claude", false), (0, String::new()));
    arrived(&s, &pane, "hi claude");

    let stale = stale_socket(&s);
    s.set_var(&pane, "pi.inbox", &json!(stale));
    let (status, stderr) = prompt(&s, &from, "hello", false);
    assert_eq!(status, 1);
    assert!(
        stderr.contains("pastee is not accepting messages"),
        "{stderr}"
    );
    poll("the pane to be quiet", || silent(&s, &pane, "hello"));

    let served = inbox(&s, "served", "ok\n");
    s.set_var(&pane, "pi.inbox", &json!(served.path));
    assert_eq!(
        prompt(&s, &from, "over the socket", false),
        (0, String::new())
    );
    assert_eq!(*served.received.lock().unwrap(), ["over the socket"]);
    assert!(
        silent(&s, &pane, "over the socket"),
        "an inbox send types nothing"
    );

    let refusing = inbox(&s, "refusing", "no\n");
    s.set_var(&pane, "pi.inbox", &json!(refusing.path));
    let (status, stderr) = prompt(&s, &from, "refused", false);
    assert_eq!(status, 1);
    assert!(stderr.contains("answered \"no\""), "{stderr}");
}

#[test]
fn the_scope_is_the_callers_window_then_its_session_and_never_a_run() {
    let s = start(&[]);
    let from = caller(&s);
    let stale = s.new_pane(json!({
        "command": {"type": "shell", "command": "while read line; do echo \"got: $line\"; done"},
        "vars": {"pi.session": "stale", "pi.name": "stale"}
    }));
    let headers = {
        let mut headers = s.headers();
        headers.push(("Ko-Pane".to_owned(), from.clone()));
        headers
    };
    let resolve = |query: &str| -> Vec<String> {
        let (status, body) = s.exchange("GET", &format!("/prompt/resolve{query}"), &headers, b"");
        assert_eq!(status, 200);
        let candidates: Value = serde_json::from_slice(&body).unwrap();
        candidates
            .as_array()
            .unwrap()
            .iter()
            .map(|candidate| candidate["pane"].as_str().unwrap().to_owned())
            .collect()
    };

    assert_eq!(prompt(&s, &from, "none", false).0, 4);
    assert!(
        silent(&s, &stale, "none"),
        "a variable without a pi root is no agent"
    );
    assert_eq!(prompt(&s, &from, "none", true).0, 4);

    let elsewhere = agent(&s, "elsewhere");
    assert_eq!(
        prompt(&s, &from, "session scope", true).0,
        4,
        "--window never widens"
    );
    assert_eq!(
        prompt(&s, &from, "session scope", false),
        (0, String::new())
    );
    arrived(&s, &elsewhere, "session scope");

    let run = run_of(&s, &from, "sub", &["sh", "-c", AGENT]);
    rooted(&s, run["pane"].as_str().unwrap());
    assert_eq!(prompt(&s, &from, "not a run", false), (0, String::new()));
    arrived(&s, &elsewhere, "not a run");
    assert!(
        silent(&s, run["pane"].as_str().unwrap(), "not a run"),
        "a run's window is no candidate"
    );

    let second = agent(&s, "second");
    let (status, stderr) = prompt(&s, &from, "several", false);
    assert_eq!((status, stderr.as_str()), (5, "multiple agents found\n"));
    assert_eq!(prompt(&s, &from, "several", true).0, 4);
    assert_eq!(resolve(""), [elsewhere.as_str(), second.as_str()]);
    assert_eq!(resolve("?window=true"), Vec::<String>::new());

    let here = split_into(&s, &from, agent_of("here", None));
    rooted(&s, &here);
    assert_eq!(prompt(&s, &from, "window scope", false), (0, String::new()));
    arrived(&s, &here, "window scope");
    assert_eq!(prompt(&s, &from, "window only", true), (0, String::new()));
    arrived(&s, &here, "window only");
    for pane in [&elsewhere, &second] {
        assert!(
            silent(&s, pane, "window scope"),
            "the window won over the session"
        );
    }

    assert_eq!(
        resolve(""),
        [here.as_str()],
        "the window's candidates come alone"
    );
    assert_eq!(resolve("?window=true"), [here.as_str()]);
    let (status, body) = s.exchange("GET", "/prompt/resolve", &headers, b"");
    assert_eq!(status, 200);
    let candidates: Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(candidates[0]["title"], "here");
    let send = |target: &str, text: &str| {
        let body = json!({"target": target, "text": text}).to_string();
        s.exchange("POST", "/prompt", &headers, body.as_bytes()).0
    };
    assert_eq!(send(&from, "x"), 400, "a terminal is no candidate");
    assert_eq!(
        send(run["pane"].as_str().unwrap(), "x"),
        400,
        "nor is a run"
    );
    assert_eq!(send(&second, ""), 400);
    assert_eq!(
        s.exchange("GET", "/prompt/resolve", &s.headers(), b"").0,
        400,
        "no caller"
    );
}

#[test]
fn a_multi_line_prompt_reaches_the_agent_as_one_paste() {
    let Some(zsh) = which("zsh") else {
        return;
    };
    let s = start_with(std::path::Path::new("/bin/sh"), &[], &[]);
    let from = caller(&s);
    let command = format!(
        "printf '\\033]7501;state=idle:app=pi\\007'; exec {} -f",
        zsh.display()
    );
    let pane = s.new_pane(json!({
        "command": {"type": "shell", "command": command},
        "vars": {"pi.session": "multi"}
    }));
    rooted(&s, &pane);
    poll("a zsh prompt", || {
        s.screen(&pane)
            .lines()
            .any(|line| line.trim_end().ends_with('%'))
    });

    assert_eq!(
        prompt(&s, &from, "echo AAA\necho BBB", false),
        (0, String::new())
    );
    poll("both lines to have run", || {
        s.screen(&pane).lines().any(|line| line.trim() == "BBB")
    });
    let screen = s.screen(&pane);
    let rows: Vec<&str> = screen.lines().map(str::trim).collect();
    let echo_bbb = rows
        .iter()
        .position(|row| row.contains("echo BBB"))
        .unwrap();
    let out_aaa = rows.iter().position(|row| *row == "AAA").unwrap();
    assert!(
        echo_bbb < out_aaa,
        "the two lines were one input, so both echoes show before either output: {screen}"
    );
}
