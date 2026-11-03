use std::fs;
use std::time::Duration;

use serde_json::{Value, json};

use crate::harness::{Server, poll, start, stays, wait_gone};
use crate::runs::{
    caller, child_of, has_pane, id_of, info, ko_as, lingering, pane_of, run_of, wait_ending,
    wait_pane_gone, windows,
};
use crate::status::osc7501;
use ko_sys::pid::Pid;

fn screen(s: &Server, id: &str) -> String {
    ko_as(s, None, &["runs", "--json", id], "").json()["screen"]
        .as_str()
        .unwrap_or_default()
        .to_owned()
}

fn pi_parent(s: &Server) -> String {
    s.new_pane(json!({
        "command": {"type": "shell", "command": "stty raw -echo; printf '\\033]7501;state=idle:app=pi\\007'; exec cat"},
        "vars": {"pi.session": "parent-session"}
    }))
}

fn a_dead_run_is_collected_after_the_linger_with_its_ending_and_its_last_screen(
    s: &Server,
    caller: &str,
) {
    let before = windows(s);
    let failed = run_of(
        s,
        caller,
        "dies",
        &["sh", "-c", "echo LAST-WORDS-7d1; exit 3"],
    );
    assert_eq!(windows(s), before + 1);
    let ko = crate::harness::ko();
    let script = format!(
        "echo REPORTED-SCREEN-4f2a; sleep 0.3; {} run-outcome --result completed -- \"$KO_RUN_ID\"",
        ko.display()
    );
    let reported = run_of(s, caller, "reports", &["sh", "-c", &script]);
    for run in [&failed, &reported] {
        wait_pane_gone(s, pane_of(run));
    }
    assert_eq!(windows(s), before, "the windows go with their panes");
    assert_eq!(
        wait_ending(s, id_of(&failed)),
        ("failed".to_owned(), "exit 3".to_owned())
    );
    assert!(screen(s, id_of(&failed)).contains("LAST-WORDS-7d1"));
    assert_eq!(
        wait_ending(s, id_of(&reported)).0,
        "completed",
        "the run's own outcome beats the sweep's guess"
    );
    assert!(screen(s, id_of(&reported)).contains("REPORTED-SCREEN-4f2a"));
}

#[test]
fn the_sweep_acts_only_on_the_pane_a_run_names() {
    let s = lingering();
    let caller = caller(&s);
    let young = run_of(
        &s,
        &caller,
        "young",
        &["sh", "-c", "echo young-screen-e2e; exit 0"],
    );
    let bystander = s.new_pane(json!({
        "command": {"type": "argv", "argv": ["/bin/sh", "-c", "exit 0"]},
    }));
    let user = s.pane("exit 0");
    poll("the other panes to die", || {
        s.row(&bystander)["dead"].is_object() && s.row(&user)["dead"].is_object()
    });
    wait_pane_gone(&s, pane_of(&young));
    assert!(screen(&s, id_of(&young)).contains("young-screen-e2e"));
    stays(
        "a pane that no run owns was collected",
        Duration::from_millis(600),
        || has_pane(&s, &bystander) && has_pane(&s, &user),
    );
}

fn a_split_pane_survives_a_finished_run_and_the_window_goes_plain(s: &Server, caller: &str) {
    let finish = s.scratch.join("finish");
    let stop = s.scratch.join("stop");
    let wait_for =
        |file: &std::path::Path| format!("while [ ! -f {} ]; do sleep 0.1; done", file.display());
    let run = run_of(s, caller, "splitrun", &["sh", "-c", &wait_for(&finish)]);
    let run_pane = pane_of(&run).to_owned();
    let command = json!({"command": {"type": "shell", "command": wait_for(&stop)}});
    let put = s.edit(|layout| {
        for session in layout["sessions"].as_array_mut().unwrap() {
            for window in session["windows"].as_array_mut().unwrap() {
                if window["tree"]["pane"] == run_pane.as_str() {
                    window["tree"] = json!({"split": "h", "children": [
                        {"pane": run_pane.as_str()}, {"pane": {"new": command}}]});
                }
            }
        }
    });
    let mut leaves = Vec::new();
    for window in crate::layout::windows(&put) {
        crate::layout::leaves(&window["tree"], &mut leaves);
    }
    let split = leaves
        .into_iter()
        .map(|leaf| leaf.0)
        .find(|pane| {
            pane.as_str() != run_pane
                && pane.as_str() != caller
                && s.row(pane)["command"][2].as_str() == Some(&wait_for(&stop))
        })
        .expect("the split pane");
    fs::write(&finish, "").unwrap();
    assert_eq!(wait_ending(s, id_of(&run)).0, "completed");
    wait_pane_gone(s, &run_pane);
    assert!(
        has_pane(s, &split),
        "the user's split went with the run's pane"
    );
    assert_eq!(s.row(&split).get("run"), None);
    let document = s.doc();
    let window = crate::layout::windows(&document)
        .into_iter()
        .find(|window| window["tree"]["pane"] == split.as_str())
        .unwrap_or_else(|| panic!("the window holds the split alone: {document}"))
        .clone();
    assert_eq!(window["tree"]["pane"], split.as_str());
    fs::write(&stop, "").unwrap();
    poll("the split to end", || s.row(&split)["dead"].is_object());
}

fn the_last_window_of_a_session_goes_with_its_collected_run_and_the_session_ends(
    s: &Server,
    caller: &str,
) {
    let solo = s.edit(|layout| {
        layout["sessions"].as_array_mut().unwrap().push(json!({
            "name": "solo",
            "windows": [{"name": "w", "tree": {"pane": {"new": {"command": {"type": "shell", "command": "exec cat"}}}}}]
        }));
    });
    let user_pane = crate::layout::windows(&solo)
        .last()
        .map(|window| window["tree"]["pane"].as_str().unwrap().to_owned())
        .unwrap();
    let run = ko_as(
        s,
        Some(caller),
        &[
            "run",
            "--name",
            "alone",
            "--session",
            "solo",
            "--",
            "sh",
            "-c",
            "exit 0",
        ],
        "",
    )
    .json();
    s.delete(&format!("/panes/{}", user_pane)).ok();
    wait_pane_gone(s, pane_of(&run));
    let sessions: Vec<Value> = s.doc()["layout"]["sessions"].as_array().unwrap().clone();
    assert_eq!(
        sessions
            .iter()
            .map(|session| session["name"].clone())
            .collect::<Vec<_>>(),
        [json!("test")],
        "an empty session ends"
    );
    assert_eq!(wait_ending(s, id_of(&run)).0, "completed");
}

#[test]
fn a_child_whose_parent_ended_is_collected_while_its_command_runs() {
    let s = start(&[]);
    let caller = caller(&s);
    let parent = pi_parent(&s);
    let file = s.scratch.join("orphan.pid");
    let script = format!("echo $$ > {}; exec sleep 300", file.display());
    let child = child_of(&s, &caller, &parent, "orphan", &["sh", "-c", &script]);
    poll("the pid file", || {
        fs::read_to_string(&file).is_ok_and(|text| !text.trim().is_empty())
    });
    let pid = Pid::new(fs::read_to_string(&file).unwrap().trim().parse().unwrap()).unwrap();
    assert_eq!(info(&s, id_of(&child)).get("outcome"), None);

    s.text(&parent, &osc7501("state=clear"));
    s.wait_row(&parent, "the root to clear", |row| {
        row["status"]["program_status"]["records"] == json!([])
    });
    stays(
        "a child died while its parent was in the editor",
        Duration::from_millis(800),
        || has_pane(&s, pane_of(&child)),
    );

    s.delete(&format!("/panes/{}", parent)).ok();
    wait_pane_gone(&s, pane_of(&child));
    wait_gone(pid, "the orphan's command");
    assert_eq!(
        wait_ending(&s, id_of(&child)),
        ("failed".to_owned(), "its parent ended".to_owned())
    );
}

#[test]
fn the_sweep_collects_a_finished_run_a_run_beside_a_split_and_a_runs_last_window() {
    let s = lingering();
    let caller = caller(&s);
    a_dead_run_is_collected_after_the_linger_with_its_ending_and_its_last_screen(&s, &caller);
    a_split_pane_survives_a_finished_run_and_the_window_goes_plain(&s, &caller);
    the_last_window_of_a_session_goes_with_its_collected_run_and_the_session_ends(&s, &caller);
}

#[test]
fn a_run_pane_is_kept_while_a_focused_client_shows_it_and_only_then() {
    let s = lingering();
    let caller = caller(&s);
    let gate = s.scratch.join("gate");
    let wait = format!("while [ ! -f {} ]; do sleep 0.05; done", gate.display());
    let kept = run_of(&s, &caller, "kept", &["sh", "-c", &wait]);
    let unfocused = run_of(&s, &caller, "unfocused", &["sh", "-c", &wait]);
    let (mut first, _) = s.app_client(json!({"pane": pane_of(&kept)}), true, (80, 24));
    let (_second, _) = s.app_client(json!({"pane": caller.as_str()}), true, (80, 24));
    let _third = s.app_client(json!({"pane": pane_of(&unfocused)}), false, (80, 24));
    fs::write(&gate, "").unwrap();
    wait_pane_gone(&s, pane_of(&unfocused));
    stays(
        "a pane that a focused client shows was collected",
        Duration::from_millis(700),
        || has_pane(&s, pane_of(&kept)),
    );
    assert_eq!(wait_ending(&s, id_of(&kept)).0, "completed");

    first.send(&json!({"type": "focused", "focused": false}));
    wait_pane_gone(&s, pane_of(&kept));
}
