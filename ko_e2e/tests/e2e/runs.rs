use std::fs;
use std::path::Path;
use std::time::{Duration, Instant};

use ko_sys::pid::{Exit, Pid};
use serde_json::{Value, json};

use crate::harness::{
    Run, Server, poll, run_ko, start, start_with, test_env, text_of, wait_gone, which,
};

pub(crate) fn ko_as(s: &Server, pane: Option<&str>, args: &[&str], stdin: &str) -> Run {
    let mut env = test_env(&s.dir);
    if let Some(pane) = pane {
        env.push(format!("KO_PANE={pane}").into_bytes());
    }
    let mut argv = vec![args[0], "--server", text_of(&s.dir)];
    argv.extend_from_slice(&args[1..]);
    run_ko(&s.scratch, &env, &argv, stdin)
}

pub(crate) fn code(run: &Run) -> i32 {
    match run.exit {
        Exit::Exited(code) => code,
        Exit::Signaled(signal) => panic!("killed by signal {signal}: {run:?}"),
    }
}

pub(crate) fn caller(s: &Server) -> String {
    s.pane("exec cat")
}

pub(crate) fn started(s: &Server, caller: &str, args: &[&str]) -> Value {
    let started = ko_as(s, Some(caller), args, "").json();
    let id = started["id"].as_str().unwrap_or_default();
    assert!(
        id.len() == 32 && id.bytes().all(|b| b.is_ascii_hexdigit()),
        "{started}"
    );
    assert!(
        started["window"]
            .as_str()
            .is_some_and(|w| w.starts_with("window_"))
            && started["pane"]
                .as_str()
                .is_some_and(|p| p.starts_with("pane_")),
        "{started}"
    );
    assert_eq!(
        started["output"],
        Path::new(text_of(&s.dir))
            .join("runs")
            .join(id)
            .join("output")
            .to_str()
            .unwrap(),
        "{started}"
    );
    started
}

pub(crate) fn run_of(s: &Server, caller: &str, name: &str, command: &[&str]) -> Value {
    let mut args = vec!["run", "--name", name, "--"];
    args.extend_from_slice(command);
    started(s, caller, &args)
}

pub(crate) fn child_of(
    s: &Server,
    caller: &str,
    parent: &str,
    name: &str,
    command: &[&str],
) -> Value {
    let mut args = vec!["run-child", parent, "--name", name, "--"];
    args.extend_from_slice(command);
    started(s, caller, &args)
}

pub(crate) fn id_of(run: &Value) -> &str {
    run["id"].as_str().unwrap()
}

pub(crate) fn pane_of(run: &Value) -> &str {
    run["pane"].as_str().unwrap()
}

pub(crate) fn info(s: &Server, id: &str) -> Value {
    ko_as(s, None, &["runs", "--json", id], "").json()
}

pub(crate) fn ending(s: &Server, id: &str) -> (String, String) {
    let info = info(s, id);
    match info["outcome"].as_object() {
        None => ("running".to_owned(), String::new()),
        Some(outcome) => (
            outcome["result"].as_str().unwrap().to_owned(),
            outcome
                .get("text")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned(),
        ),
    }
}

pub(crate) fn wait_ending(s: &Server, id: &str) -> (String, String) {
    let outcome = ko_as(s, None, &["run-wait", "--json", id], "").json();
    (
        outcome["result"].as_str().unwrap().to_owned(),
        outcome["text"].as_str().unwrap_or_default().to_owned(),
    )
}

pub(crate) fn has_pane(s: &Server, pane: &str) -> bool {
    s.rows().iter().any(|row| row["id"] == pane)
}

pub(crate) fn wait_pane_gone(s: &Server, pane: &str) {
    poll(&format!("{pane} to be removed"), || !has_pane(s, pane));
}

pub(crate) fn windows(s: &Server) -> usize {
    s.doc()["layout"]["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|session| session["windows"].as_array().unwrap().len())
        .sum()
}

pub(crate) fn lingering() -> Server {
    start_with(Path::new("/bin/sh"), &[("KO_LINGER_SECONDS", "0.2")], &[])
}

fn ids(rows: &Value) -> Vec<&str> {
    rows.as_array()
        .unwrap()
        .iter()
        .map(|row| row["id"].as_str().unwrap())
        .collect()
}

#[test]
fn a_run_is_a_pane_marked_at_creation_that_runs_the_argv_as_given() {
    let s = start(&[]);
    let caller = caller(&s);
    let (mut watcher, _) = s.client(None);
    let script = "echo \"run-output $KO_RUN_ID\" | tee \"$KO_RUN_OUTPUT\"; exit 3";
    let run = run_of(&s, &caller, "env", &["sh", "-c", script, "ignored"]);
    let (id, pane) = (id_of(&run), pane_of(&run));

    let layout = watcher.event("layout");
    assert!(layout.to_string().contains(pane), "{layout}");
    let row = s.row(pane);
    assert_eq!(row["vars"]["ko.run"], id, "the mark exists with the pane");
    let sh = which("sh").unwrap();
    assert_eq!(
        row["command"],
        json!([sh.to_str().unwrap(), "-c", script, "ignored"]),
        "the argv is the pane's command, with no wrapper"
    );

    let record = s.dir.join("runs").join(id);
    let command: Value =
        serde_json::from_slice(&fs::read(record.join("command")).unwrap()).unwrap();
    assert_eq!(command, row["command"]);
    let meta: Value = serde_json::from_slice(&fs::read(record.join("meta.json")).unwrap()).unwrap();
    assert_eq!(
        (&meta["name"], &meta["pane"]),
        (&json!("env"), &json!(pane))
    );
    assert_eq!(meta.get("parent"), None, "a parentless run has no parent");
    assert_eq!(
        meta["cwd"],
        std::env::current_dir().unwrap().to_str().unwrap()
    );

    let event = watcher.event("run");
    assert_eq!(
        (
            &event["id"],
            &event["name"],
            &event["pane"],
            event.get("outcome")
        ),
        (&json!(id), &json!("env"), &json!(pane), None)
    );
    assert_eq!(event["startedAt"], meta["startedAt"]);

    assert_eq!(
        wait_ending(&s, id),
        ("failed".to_owned(), "exit 3".to_owned())
    );
    let output = fs::read_to_string(record.join("output")).unwrap();
    assert_eq!(output, format!("run-output {id}\n"));
    let outcome = ko_as(&s, None, &["run-wait", "--json", id], "").json();
    assert_eq!(outcome["result"], "failed");
    assert_eq!(outcome["text"], "exit 3");
    assert_eq!(ko_as(&s, None, &["run-wait", id], "").ok(), "failed\n");
}

#[test]
fn the_command_line_refuses_what_it_cannot_run_with_kidos_exit_codes() {
    let s = start(&[]);
    let caller = caller(&s);
    let long = "n".repeat(65);
    let unknown = "0123456789abcdef0123456789abcdef";
    let windows_before = windows(&s);
    let cases: Vec<(Vec<&str>, i32, String)> = vec![
        (vec!["run"], 124, "--name".to_owned()),
        (
            vec!["run", "--name", "no-command"],
            1,
            "no command given\nusage: ko run --name N".to_owned(),
        ),
        (
            vec!["run", "--name", "a\nb", "--", "true"],
            4,
            "refusing run name \"a\\nb\"".to_owned(),
        ),
        (
            vec!["run", "--name", &long, "--", "true"],
            4,
            "65 bytes is over the 64 byte limit".to_owned(),
        ),
        (
            vec!["run", "--name", "x", "--session", "absent", "--", "true"],
            1,
            "no such session".to_owned(),
        ),
        (
            vec!["run", "--name", "x", "--", "no-such-command-anywhere"],
            1,
            "command not found".to_owned(),
        ),
        (
            vec!["run", "--name", "x", "--env", "NOEQUALS", "--", "true"],
            1,
            "invalid --env".to_owned(),
        ),
        (
            vec!["run-child", "pane_999999", "--name", "x", "--", "true"],
            2,
            "pane pane_999999 is gone".to_owned(),
        ),
        (
            vec!["run-child", unknown, "--name", "x", "--", "true"],
            2,
            format!("no run {unknown}"),
        ),
        (
            vec!["run-child", "no-such-parent", "--name", "x", "--", "true"],
            2,
            "invalid parent".to_owned(),
        ),
        (vec!["runs", "no-such-run"], 3, "invalid run id".to_owned()),
        (
            vec!["runs", unknown],
            3,
            format!("run {unknown}: no such run"),
        ),
        (
            vec!["runs", unknown, "extra"],
            1,
            "unknown argument \"extra\"\nusage: ko runs [--json] [--all] [--parent P] [<run-id>]"
                .to_owned(),
        ),
        (
            vec!["runs", "--parent", "nope"],
            2,
            "invalid parent".to_owned(),
        ),
        (
            vec!["run-wait", unknown],
            3,
            format!("run {unknown}: no such run"),
        ),
        (
            vec!["run-stop", unknown],
            3,
            format!("run {unknown}: no such run"),
        ),
        (
            vec!["run-outcome", "--result", "completed", unknown],
            3,
            "no such run".to_owned(),
        ),
        (
            vec!["run-outcome", "--result", "completed", "../bad"],
            3,
            "invalid run id".to_owned(),
        ),
        (
            vec!["run-outcome", "--result", "died", unknown],
            124,
            "invalid value 'died'".to_owned(),
        ),
        (
            vec!["run-stop", "--wait", "1e300", unknown],
            124,
            "is not a number of seconds".to_owned(),
        ),
        (
            vec!["run-stop", "--wait", "inf", unknown],
            124,
            "is not a number of seconds".to_owned(),
        ),
    ];
    for (args, want, message) in cases {
        let run = ko_as(&s, Some(&caller), &args, "");
        assert_eq!(run.stdout, "", "{args:?}: {run:?}");
        assert_eq!(code(&run), want, "{args:?}: {run:?}");
        assert!(
            run.stderr.contains(&message),
            "{args:?}: {message:?} not in {:?}",
            run.stderr
        );
    }
    let prompt = ko_as(&s, Some(&caller), &["prompt"], "\n");
    assert_eq!(
        (code(&prompt), prompt.stderr.as_str()),
        (1, "no prompt given\n")
    );
    assert_eq!(
        windows(&s),
        windows_before,
        "a refused run starts no window"
    );
}

#[test]
fn a_run_stops_after_its_wait_and_a_stop_records_before_it_closes() {
    let s = start(&[]);
    let caller = caller(&s);

    let stopped = run_of(&s, &caller, "run-stop", &["sleep", "300"]);
    let out = ko_as(&s, None, &["run-stop", id_of(&stopped)], "").ok();
    assert_eq!(
        out,
        format!("stopped run {}; killed its pane\n", id_of(&stopped))
    );
    assert_eq!(ending(&s, id_of(&stopped)).0, "stopped");
    wait_pane_gone(&s, pane_of(&stopped));
    let again = ko_as(&s, None, &["run-stop", id_of(&stopped)], "");
    assert_eq!(code(&again), 5, "{again:?}");
    assert!(again.stderr.contains("already ended"), "{again:?}");

    let completed = run_of(&s, &caller, "run-done", &["sleep", "300"]);
    ko_as(
        &s,
        None,
        &["run-stop", "--result", "completed", id_of(&completed)],
        "",
    )
    .ok();
    assert_eq!(ending(&s, id_of(&completed)).0, "completed");

    let phased = run_of(&s, &caller, "run-phased", &["sleep", "300"]);
    let phased_id = id_of(&phased);
    ko_as(
        &s,
        None,
        &["run-outcome", "--result", "stopped", "--", phased_id],
        "",
    )
    .ok();
    let lost = ko_as(
        &s,
        None,
        &["run-outcome", "--result", "completed", "--", phased_id],
        "",
    );
    assert_eq!(code(&lost), 5, "{lost:?}");
    assert!(
        lost.stderr.contains("already has an outcome, or is gone"),
        "{lost:?}"
    );
    ko_as(&s, None, &["run-stop", phased_id], "").ok();
    wait_pane_gone(&s, pane_of(&phased));
    assert_eq!(
        ending(&s, phased_id).0,
        "stopped",
        "the first outcome stands"
    );

    let ended = run_of(&s, &caller, "run-ended", &["sh", "-c", "exit 3"]);
    poll("the exited run's pane to die", || {
        s.row(pane_of(&ended))["dead"].is_object()
    });
    let late = ko_as(&s, None, &["run-stop", id_of(&ended)], "");
    assert_eq!(code(&late), 5, "{late:?}");
    assert!(late.stderr.contains("already ended"), "{late:?}");
    assert_eq!(
        ending(&s, id_of(&ended)).0,
        "failed",
        "a stop of an ended run records nothing"
    );
}

#[test]
fn a_stop_waits_for_the_run_to_end_by_itself_and_then_kills_what_ignores_hup() {
    let s = start(&[]);
    let caller = caller(&s);

    let finished = s.scratch.join("polite.finished");
    let script = format!("sleep 0.8; touch {}", finished.display());
    let polite = run_of(&s, &caller, "polite", &["sh", "-c", &script]);
    let began = Instant::now();
    ko_as(&s, None, &["run-stop", "--wait", "4", id_of(&polite)], "").ok();
    assert!(
        began.elapsed() < Duration::from_secs(3),
        "the stop ended with the run"
    );
    assert!(finished.exists(), "the stop killed the run before it ended");
    assert_eq!(ending(&s, id_of(&polite)).0, "stopped");
    wait_pane_gone(&s, pane_of(&polite));

    let file = s.scratch.join("hup.pid");
    let script = format!("trap '' HUP; echo $$ > {}; exec sleep 300", file.display());
    let stubborn = run_of(&s, &caller, "stubborn", &["sh", "-c", &script]);
    poll("the pid file", || {
        fs::read_to_string(&file).is_ok_and(|text| !text.trim().is_empty())
    });
    let pid = Pid::new(fs::read_to_string(&file).unwrap().trim().parse().unwrap()).unwrap();
    let began = Instant::now();
    ko_as(
        &s,
        None,
        &["run-stop", "--wait", "0.3", id_of(&stubborn)],
        "",
    )
    .ok();
    assert!(
        began.elapsed() >= Duration::from_millis(250),
        "{:?}",
        began.elapsed()
    );
    wait_gone(pid, "a stop of a program that ignores HUP");
    wait_pane_gone(&s, pane_of(&stubborn));
}

#[test]
fn a_child_runs_under_a_run_or_a_pane_that_has_not_ended_and_lists_under_it() {
    let s = start(&[]);
    let caller = caller(&s);
    let parent_pane = s.new_pane(json!({
        "command": {"type": "argv", "argv": ["/bin/sh", "-c", "exec cat"]},
        "vars": {"pi.session": "parent-session"}
    }));
    let parent_run = run_of(&s, &caller, "parent", &["sleep", "300"]);
    let by_run = child_of(
        &s,
        &caller,
        id_of(&parent_run),
        "child-of-run",
        &["sleep", "300"],
    );
    let by_pane = child_of(
        &s,
        &caller,
        &parent_pane,
        "child-of-pane",
        &["sleep", "300"],
    );

    let meta = |run: &Value| info(&s, id_of(run));
    assert_eq!(meta(&by_run)["parent"], id_of(&parent_run));
    assert_eq!(meta(&by_pane)["parent"], parent_pane.as_str());
    let list = |args: &[&str]| -> Value {
        let mut argv = vec!["runs", "--json"];
        argv.extend_from_slice(args);
        ko_as(&s, None, &argv, "").json()
    };
    assert_eq!(ids(&list(&["--parent", &parent_pane])), [id_of(&by_pane)]);
    assert_eq!(
        ids(&list(&["--parent", id_of(&parent_run)])),
        [id_of(&by_run)]
    );

    ko_as(
        &s,
        None,
        &[
            "run-outcome",
            "--result",
            "completed",
            "--",
            id_of(&parent_run),
        ],
        "",
    )
    .ok();
    s.unset_var(&parent_pane, "pi.session");
    for orphan in [&by_run, &by_pane] {
        wait_pane_gone(&s, pane_of(orphan));
        assert_eq!(
            wait_ending(&s, id_of(orphan)),
            ("failed".to_owned(), "its parent ended".to_owned())
        );
    }
    assert_eq!(
        ids(&list(&["--parent", id_of(&parent_run)])),
        Vec::<&str>::new()
    );
    assert_eq!(
        ids(&list(&["--all", "--parent", id_of(&parent_run)])),
        [id_of(&by_run)]
    );
}

fn write_run(s: &Server, id: &str, meta: &Value, outcome: Option<&str>) {
    let dir = s.dir.join("runs").join(id);
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join("meta.json"), meta.to_string()).unwrap();
    if let Some(outcome) = outcome {
        fs::write(dir.join("outcome"), outcome).unwrap();
    }
}

fn ko_in_zone(s: &Server, zone: &str, args: &[&str]) -> String {
    let mut env = test_env(&s.dir);
    env.push(format!("TZ={zone}").into_bytes());
    let mut argv = vec![args[0], "--server", text_of(&s.dir)];
    argv.extend_from_slice(&args[1..]);
    run_ko(&s.scratch, &env, &argv, "").ok()
}

#[test]
fn the_runs_table_the_detail_and_the_json_render_the_records_for_a_human() {
    let s = start(&[]);
    let (a, b) = (
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    );
    write_run(
        &s,
        a,
        &json!({"id": a, "name": "kid", "parent": b, "cwd": "/tmp/some project", "startedAt": "2023-11-14T22:13:20Z"}),
        Some(r#"{"result":"completed","at":"2023-11-14T22:14:50Z"}"#),
    );
    write_run(
        &s,
        b,
        &json!({"id": b, "name": "later", "cwd": "", "startedAt": "2023-11-14T23:13:20Z"}),
        None,
    );
    let ko = |args: &[&str]| ko_in_zone(&s, "IST-5:30", args);
    let row = |cells: [&str; 8]| {
        format!(
            "{:<34}{:<7}{:<9}{:<34}{:<27}{:<10}{:<11}{}\n",
            cells[0], cells[1], cells[2], cells[3], cells[4], cells[5], cells[6], cells[7]
        )
    };
    assert_eq!(
        ko(&["runs"]),
        "ID  NAME  SESSION  PARENT  STARTED  DURATION  OUTCOME  CWD\n",
        "both runs ended, so the live listing has only the header"
    );
    assert_eq!(
        ko(&["runs", "--all"]),
        row([
            "ID", "NAME", "SESSION", "PARENT", "STARTED", "DURATION", "OUTCOME", "CWD"
        ]) + &row([
            b,
            "later",
            "",
            "",
            "2023-11-15T04:43:20+05:30",
            "-",
            "died",
            ""
        ]) + &row([
            a,
            "kid",
            "",
            b,
            "2023-11-15T03:43:20+05:30",
            "1m30s",
            "completed",
            "/tmp/some project"
        ])
    );
    let output = s.dir.join("runs").join(a).join("output");
    assert_eq!(
        ko(&["runs", a]),
        format!(
            "id:       {a}\nname:     kid\nsession:  \nparent:   {b}\ncwd:      /tmp/some project\n\
             started:  2023-11-15T03:43:20+05:30\noutcome:  completed\nended:    2023-11-15T03:44:50+05:30\noutput:   {}\n",
            output.display()
        )
    );
    assert_eq!(ko(&["runs", "--all", a]), ko(&["runs", a]));
    let detail = ko(&["runs", "--json", a]);
    let order: Vec<usize> = [
        "id",
        "name",
        "parent",
        "cwd",
        "startedAt",
        "output",
        "outcome",
    ]
    .iter()
    .map(|key| detail.find(&format!("\"{key}\":")).unwrap_or(usize::MAX))
    .collect();
    assert!(order.windows(2).all(|pair| pair[0] < pair[1]), "{detail}");
    let listed: Value = serde_json::from_str(&ko(&["runs", "--all", "--json"])).unwrap();
    assert_eq!(ids(&listed), [b, a]);

    let zone = "NST3:30NDT,M3.2.0,M11.1.0";
    for (at, (zone, instant, want)) in [
        (
            "NST3:30",
            "2023-11-14T22:13:20Z",
            "2023-11-14T18:43:20-03:30",
        ),
        (
            "NST3:30",
            "2024-01-01T01:00:00Z",
            "2023-12-31T21:30:00-03:30",
        ),
        (
            "IST-5:30",
            "2023-12-31T20:00:00Z",
            "2024-01-01T01:30:00+05:30",
        ),
        (zone, "2024-03-10T05:00:00Z", "2024-03-10T01:30:00-03:30"),
        (zone, "2024-03-10T06:00:00Z", "2024-03-10T03:30:00-02:30"),
        (zone, "2024-11-03T04:00:00Z", "2024-11-03T01:30:00-02:30"),
        (zone, "2024-11-03T05:00:00Z", "2024-11-03T01:30:00-03:30"),
    ]
    .into_iter()
    .enumerate()
    {
        let id = format!("{:032x}", at + 1);
        write_run(
            &s,
            &id,
            &json!({"id": id, "name": "tz", "cwd": "", "startedAt": instant}),
            None,
        );
        let shown = ko_in_zone(&s, zone, &["runs", &id]);
        let started = shown
            .lines()
            .find_map(|line| line.strip_prefix("started:  "))
            .unwrap();
        assert_eq!(started, want, "TZ={zone} at {instant}");
    }
}

#[test]
fn a_run_that_reports_failure_has_its_screen_saved_before_it_exits() {
    let s = start(&[]);
    let caller = caller(&s);
    let ko = crate::harness::ko();
    let script = format!(
        "echo SCREEN-MARKER-9f3c; sleep 0.3; {} run-outcome --result failed --text 'no turn' -- \"$KO_RUN_ID\"; sleep 300",
        ko.display()
    );
    let run = run_of(&s, &caller, "no-turn", &["sh", "-c", &script]);
    assert_eq!(
        wait_ending(&s, id_of(&run)),
        ("failed".to_owned(), "no turn".to_owned())
    );
    assert!(
        has_pane(&s, pane_of(&run)),
        "the pane is still up: the capture happened at report time"
    );
    let shown = ko_as(&s, None, &["runs", id_of(&run)], "").ok();
    assert!(shown.contains("SCREEN-MARKER-9f3c"), "{shown}");
    assert!(shown.contains("detail:   no turn"), "{shown}");
}

#[test]
fn a_dead_run_reads_died_when_its_pane_is_gone_and_a_signal_names_itself() {
    let s = start(&[]);
    let caller = caller(&s);
    let file = s.scratch.join("signalled.pid");
    let script = format!("echo $$ > {}; exec sleep 300", file.display());
    let run = run_of(&s, &caller, "run-signal", &["sh", "-c", &script]);
    poll("the pid file", || {
        fs::read_to_string(&file).is_ok_and(|text| !text.trim().is_empty())
    });
    let pid = Pid::new(fs::read_to_string(&file).unwrap().trim().parse().unwrap()).unwrap();
    ko_sys::pid::signal_descendant(s.child.pid(), pid, ko_sys::signal::Signal::Term).unwrap();
    assert_eq!(
        wait_ending(&s, id_of(&run)),
        ("failed".to_owned(), "signal TERM".to_owned())
    );

    let gone = run_of(&s, &caller, "run-gone", &["sleep", "300"]);
    s.delete(&format!("/panes/{}", pane_of(&gone))).ok();
    assert_eq!(
        ending(&s, id_of(&gone)).0,
        "died",
        "a pane that is gone is a run that died"
    );
    let wait = ko_as(&s, None, &["run-wait", id_of(&gone)], "").ok();
    assert_eq!(wait, "died\n");
}

#[test]
fn a_reader_that_stops_early_ends_the_listing_quietly() {
    use std::os::fd::AsFd;

    let s = start(&[]);
    let (reader, writer) = std::io::pipe().unwrap();
    drop(reader);
    let stderr = s.scratch.join("closed.err");
    let errors = fs::File::create(&stderr).unwrap();
    let mut child = crate::harness::Child::spawn(
        &crate::harness::ko(),
        &["runs", "--all", "--server", text_of(&s.dir)],
        &test_env(&s.dir),
        &[(writer.as_fd(), 1), (errors.as_fd(), 2)],
    );
    assert_eq!(child.wait(crate::harness::DEADLINE), Some(Exit::Exited(0)));
    assert_eq!(fs::read_to_string(stderr).unwrap(), "");
}

#[test]
fn a_stop_that_waits_longer_than_the_bound_is_refused_and_records_nothing() {
    let s = start(&[]);
    let caller = caller(&s);
    let run = run_of(&s, &caller, "bounded", &["sleep", "300"]);
    let id = id_of(&run);
    let too_long = json!({"wait_ms": 3_600_001u64, "result": "stopped"});
    let path = format!("/runs/{id}/stop");
    let (status, _) = s.exchange("POST", &path, &s.headers(), too_long.to_string().as_bytes());
    assert_eq!(status, 400);
    assert_eq!(
        ending(&s, id).0,
        "running",
        "a refused stop records nothing"
    );
    let wait = format!("/runs/{id}/wait?timeout_ms=3600001");
    assert_eq!(s.exchange("GET", &wait, &s.headers(), b"").0, 400);
}

#[test]
fn the_coordinator_kills_a_removed_run_pane_whose_pane_process_cannot_hang_it_up() {
    use ko_sys::signal::Signal;

    let delay = Duration::from_millis(600);
    let s = start_with(
        Path::new("/bin/sh"),
        &[("KO_STOP_ESCALATION_MS", "600")],
        &[],
    );
    let caller = caller(&s);
    let run = run_of(
        &s,
        &caller,
        "stuck",
        &["sh", "-c", "trap '' HUP; exec sleep 300"],
    );
    let program = s.pane_program(pane_of(&run));
    let pane_process = program.parent().expect("the pane process");
    ko_sys::pid::signal_descendant(s.child.pid(), pane_process, Signal::Stop).unwrap();

    let began = Instant::now();
    ko_as(&s, None, &["run-stop", id_of(&run)], "").ok();
    wait_pane_gone(&s, pane_of(&run));
    crate::harness::stays(
        "the program lived on while its stopped pane process could not hang it up",
        Duration::from_millis(250),
        || !program.has_ended(),
    );
    wait_gone(program, "the coordinator's escalation");
    wait_gone(pane_process, "the coordinator's escalation");
    let took = began.elapsed();
    assert!(took >= delay, "{took:?}");
    assert!(
        took < Duration::from_secs(3),
        "the configured delay, not the 5 s default: {took:?}"
    );
}
