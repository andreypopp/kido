use std::thread;

use serde_json::{Value, json};

use crate::harness::{Server, poll, run_ko, start, start_with, which};
use crate::messages::{ack, answer, open, received};
use crate::panes::as_pane;
use crate::runs::{caller, code, ko_as, ko_command, run_of};

const AGENT: &str = "printf '\\033]7501;state=idle:app=pi\\007'; printf 'TOKEN<%s>' \"$KO_PANE_TOKEN\"; while read line; do echo \"got: $line\"; done";

fn agent_of(name: &str) -> Value {
    let vars = json!({"pi.session": format!("session-{name}"), "pi.name": name});
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
    let pane = s.new_pane(agent_of(name));
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

#[test]
fn a_prompt_goes_by_paste_when_the_agent_has_no_stream() {
    let s = start(&[]);
    let from = caller(&s);
    let pane = agent(&s, "pastee");

    assert_eq!(prompt(&s, &from, "hi claude", false), (0, String::new()));
    arrived(&s, &pane, "hi claude");
}

#[test]
fn the_scope_is_the_callers_window_then_its_session_and_never_a_run() {
    let s = start(&[]);
    let from = caller(&s);
    let stale = s.new_pane(json!({
        "command": {"type": "shell", "command": "while read line; do echo \"got: $line\"; done"},
        "vars": {"pi.session": "stale", "pi.name": "stale"}
    }));
    let headers = as_pane(&s, &from);
    let resolve = |query: &str| -> Vec<String> {
        let (status, body) = s.exchange(
            "GET",
            &format!("/prompt/resolve?from={from}{query}"),
            &headers,
            b"",
        );
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
    assert_eq!(resolve("&window=true"), Vec::<String>::new());

    let here = split_into(&s, &from, agent_of("here"));
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
    assert_eq!(resolve("&window=true"), [here.as_str()]);
    let (status, body) = s.exchange(
        "GET",
        &format!("/prompt/resolve?from={from}"),
        &headers,
        b"",
    );
    assert_eq!(status, 200);
    let candidates: Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(candidates[0]["title"], "here");
    let send_as = |who: &crate::panes::Headers, from: &str, target: &str, text: &str| {
        let body =
            json!({"from": from, "id": "prompt-0001", "target": target, "text": text}).to_string();
        s.exchange("POST", "/prompt", who, body.as_bytes()).0
    };
    let send = |target: &str, text: &str| send_as(&headers, &from, target, text);
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
        "no pane to prompt from"
    );

    let forged = format!("/prompt/resolve?from={second}");
    assert_eq!(
        s.exchange("GET", &forged, &headers, b"").0,
        409,
        "a pane identity names only itself"
    );
    assert_eq!(send_as(&headers, &second, &here, "x"), 409);
    assert_eq!(
        s.exchange("GET", &forged, &s.headers(), b"").0,
        200,
        "the user names any pane"
    );
    let mut claim = s.headers();
    claim.push(("Ko-Pane".to_owned(), from.clone()));
    assert_eq!(
        s.exchange("GET", &format!("/prompt/resolve?from={from}"), &claim, b"")
            .0,
        409,
        "Ko-Pane without its token is a claim, not an identity"
    );
}

#[test]
fn a_prompt_goes_through_the_message_queue_when_the_agent_has_a_stream() {
    let s = start(&[]);
    let from = caller(&s);
    let pane = agent(&s, "streamer");
    let mut stream = open(&s, &pane);
    let mut next = || {
        let message = received(&mut stream);
        ack(&mut stream, message["id"].as_str().unwrap());
        message
    };

    let (env, argv) = ko_command(&s, Some(&from), &["prompt"]);
    let argv: Vec<&str> = argv.iter().map(String::as_str).collect();
    let scratch = &s.scratch;
    let (sent, message) = thread::scope(|scope| {
        let sending = scope.spawn(|| run_ko(scratch, &env, &argv, "over the stream"));
        let message = next();
        (sending.join().unwrap(), message)
    });
    assert_eq!((code(&sent), sent.stderr.as_str()), (0, ""));
    assert_eq!(
        (
            message["kind"].as_str(),
            message["text"].as_str(),
            message["from"].clone(),
            message["relation"].as_str()
        ),
        (
            Some("user"),
            Some("over the stream"),
            json!({"type": "pane", "pane": from}),
            Some("sibling")
        ),
        "a pane sender is stamped"
    );
    assert!(
        silent(&s, &pane, "over the stream"),
        "a queued prompt types nothing"
    );

    let body = json!({"from": from, "id": "prompt-user-1", "target": pane, "text": "as the user"});
    let waiting = s.send_request("POST", "/prompt", &s.headers(), body.to_string().as_bytes());
    let message = next();
    assert_eq!(
        answer(&s, waiting),
        (
            200,
            json!({"via": {"type": "message", "state": "acked", "seq": 2}})
        )
    );
    assert_eq!(message["from"], json!({"type": "user"}));
    assert_eq!(message.get("relation"), None);

    let lost_body =
        json!({"from": from, "id": "prompt-lost-1", "target": pane, "text": "lost reply"})
            .to_string();
    let lost = s.send_request("POST", "/prompt", &s.headers(), lost_body.as_bytes());
    assert_eq!(received(&mut stream)["id"], "prompt-lost-1");
    drop(lost);
    drop(stream);
    s.wait_row(&pane, "its stream to close", |row| {
        row.get("inbox").is_none()
    });
    let (status, repeat) = s.exchange("POST", "/prompt", &s.headers(), lost_body.as_bytes());
    assert_eq!(
        (status, serde_json::from_slice::<Value>(&repeat).unwrap()),
        (
            200,
            json!({"via": {"type": "message", "state": "queued", "seq": 3, "duplicate": true}})
        ),
        "a repeat of a prompt id that the queue knows goes by the queue, not by a paste"
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
