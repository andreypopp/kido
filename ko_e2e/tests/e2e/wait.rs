use std::fs::{self, File};
use std::os::fd::AsFd;
use std::time::{Duration, Instant};

use ko_sys::clock::process_cpu;
use serde_json::{Value, json};

use crate::harness::{Child, DEADLINE, Server, ko, start, test_env, text_of};
use crate::runs::{caller, id_of, ko_as, run_of};

fn waiter(s: &Server, args: &[&str], name: &str) -> (Child, std::path::PathBuf) {
    let out = s.scratch.join(name);
    let file = File::create(&out).unwrap();
    let null = File::open("/dev/null").unwrap();
    let mut argv = vec![args[0], "--server", text_of(&s.dir)];
    argv.extend_from_slice(&args[1..]);
    let child = Child::spawn(
        &ko(),
        &argv,
        &test_env(&s.dir),
        &[(null.as_fd(), 0), (file.as_fd(), 1), (file.as_fd(), 2)],
    );
    (child, out)
}

fn body(s: &Server, path: &str) -> (Value, Duration) {
    let began = Instant::now();
    let text = s.request("GET", path, None, 200);
    (serde_json::from_str(&text).unwrap(), began.elapsed())
}

#[test]
fn a_wait_answers_at_the_runs_end_and_at_its_deadline_and_the_server_sleeps_between() {
    let s = start(&[]);
    let caller = caller(&s);
    let run = run_of(&s, &caller, "long", &["sleep", "300"]);
    let id = id_of(&run);

    let (answer, took) = body(&s, &format!("/runs/{id}/wait?timeout_ms=400"));
    assert_eq!(answer, json!({}), "the deadline answers with no outcome");
    assert!(took >= Duration::from_millis(350), "{took:?}");
    assert!(took < Duration::from_secs(3), "{took:?}");
    let (answer, took) = body(&s, &format!("/runs/{id}/wait?timeout_ms=0"));
    assert_eq!(answer, json!({}));
    assert!(took < Duration::from_millis(300), "{took:?}");

    let mut waiters: Vec<(Child, std::path::PathBuf)> = vec![
        waiter(&s, &["run-wait", "--json", id], "json.out"),
        waiter(&s, &["run-wait", id], "word.out"),
        waiter(
            &s,
            &["api", &format!("/runs/{id}/wait?timeout_ms=60000")],
            "api.out",
        ),
    ];
    let before = process_cpu(s.child.pid()).unwrap();
    std::thread::sleep(Duration::from_secs(2));
    let grown = process_cpu(s.child.pid()).unwrap() - before;
    assert!(
        grown < Duration::from_millis(3),
        "the server's CPU grew {grown:?} over 2 s with three waiters pending"
    );
    for (child, _) in &mut waiters {
        assert_eq!(
            child.wait(Duration::ZERO),
            None,
            "a waiter answered before the run ended"
        );
    }

    ko_as(
        &s,
        None,
        &[
            "run-outcome",
            "--result",
            "completed",
            "--text",
            "done",
            "--",
            id,
        ],
        "",
    )
    .ok();
    for (child, _) in &mut waiters {
        assert_eq!(child.wait(DEADLINE), Some(ko_sys::pid::Exit::Exited(0)));
    }
    let json: Value = serde_json::from_str(&fs::read_to_string(&waiters[0].1).unwrap()).unwrap();
    assert_eq!(
        (&json["result"], &json["text"]),
        (&json!("completed"), &json!("done"))
    );
    assert_eq!(fs::read_to_string(&waiters[1].1).unwrap(), "completed\n");
    let api: Value = serde_json::from_str(&fs::read_to_string(&waiters[2].1).unwrap()).unwrap();
    assert_eq!(api["outcome"]["result"], "completed");
}

#[test]
fn a_wait_ends_with_the_pane_when_nothing_recorded_an_outcome() {
    let s = start(&[]);
    let caller = caller(&s);
    let run = run_of(&s, &caller, "short", &["sh", "-c", "sleep 0.5; exit 7"]);
    let (mut waiting, out) = waiter(&s, &["run-wait", "--json", id_of(&run)], "short.out");
    assert_eq!(waiting.wait(DEADLINE), Some(ko_sys::pid::Exit::Exited(0)));
    let json: Value = serde_json::from_str(&fs::read_to_string(out).unwrap()).unwrap();
    assert_eq!(
        (&json["result"], &json["text"]),
        (&json!("failed"), &json!("exit 7"))
    );

    let gone = run_of(&s, &caller, "gone", &["sleep", "300"]);
    let (mut waiting, out) = waiter(&s, &["run-wait", id_of(&gone)], "gone.out");
    s.delete(gone["pane"].as_str().unwrap());
    assert_eq!(waiting.wait(DEADLINE), Some(ko_sys::pid::Exit::Exited(0)));
    assert_eq!(fs::read_to_string(out).unwrap(), "died\n");
}

#[test]
fn a_dropped_waiter_costs_the_server_nothing() {
    let s = start(&[]);
    let caller = caller(&s);
    let run = run_of(&s, &caller, "dropped", &["sleep", "300"]);
    let id = id_of(&run);
    {
        let mut stream = s.dial().unwrap();
        let head = format!(
            "GET /runs/{id}/wait?timeout_ms=60000 HTTP/1.1\r\nHost: ko\r\n{}Content-Length: 0\r\n\r\n",
            s.headers()
                .iter()
                .map(|(n, v)| format!("{n}: {v}\r\n"))
                .collect::<String>()
        );
        std::io::Write::write_all(&mut stream, head.as_bytes()).unwrap();
    }
    let (answer, _) = body(&s, &format!("/runs/{id}/wait?timeout_ms=100"));
    assert_eq!(
        answer,
        json!({}),
        "the server answers while a dropped waiter is still stored"
    );
    ko_as(&s, None, &["run-stop", id], "").ok();
    assert_eq!(
        s.rows()
            .iter()
            .filter(|row| row["id"] == run["pane"])
            .count(),
        0
    );
}
