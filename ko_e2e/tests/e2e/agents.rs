use serde_json::json;

use crate::harness::start;
use crate::runs::{caller, id_of, info, ko_as, pane_of, run_of};
use crate::status::osc7501;

const PI_RUN: &str = "stty raw -echo; printf '\\033]0;pi - Pane fallback - ko\\007\\033]7501;state=idle:app=pi\\007'; exec cat";

#[test]
fn a_pi_run_row_keeps_its_name_and_a_cleared_name_falls_back_to_the_pane_title() {
    let s = start(&[]);
    let caller = caller(&s);
    let run = run_of(&s, &caller, "Launch", &["sh", "-c", PI_RUN]);
    let pane = pane_of(&run);
    s.wait_row(pane, "the pi root", |row| {
        row["status"]["program_status"]["records"]
            .as_array()
            .is_some_and(|records| !records.is_empty())
    });
    s.set_var(pane, "pi.session", &json!("ending-child"));
    s.set_var(pane, "pi.name", &json!("Current"));
    s.wait_row(pane, "the pi name", |row| {
        row["status"]["title"] == "Current"
    });
    assert_eq!(
        info(&s, id_of(&run))["name"],
        "Launch",
        "the run keeps the name it was started with"
    );

    s.unset_var(pane, "pi.name");
    s.text(
        pane,
        &osc7501("id=nested:state=blocked:app=builder:title=TmVzdGVk"),
    );
    let row = s.wait_row(pane, "the nested record", |row| {
        row["status"]["program_status"]["records"]
            .as_array()
            .is_some_and(|records| records.iter().any(|record| record["id"] == "nested"))
    });
    assert_eq!(
        row["status"]["title"], "pi - Pane fallback - ko",
        "a cleared name shows the pane's own title, not a nested program's"
    );
    ko_as(
        &s,
        None,
        &["run-outcome", "--result", "completed", "--", id_of(&run)],
        "",
    )
    .ok();
}

#[test]
fn a_subagent_keeps_its_start_while_its_activity_comes_and_goes() {
    let s = start(&[]);
    let caller = caller(&s);
    let run = run_of(&s, &caller, "elapsed-agent", &["sh", "-c", PI_RUN]);
    let (id, pane) = (id_of(&run), pane_of(&run));
    let (mut watcher, _) = s.client(None);
    s.wait_row(pane, "the pi root", |row| {
        row["status"]["program_status"]["records"]
            .as_array()
            .is_some_and(|records| !records.is_empty())
    });
    s.set_var(pane, "pi.session", &json!("elapsed-session"));
    let started = info(&s, id)["startedAt"].clone();

    for activity in ["checking tests", ""] {
        if activity.is_empty() {
            s.unset_var(pane, "pi.activity");
        } else {
            s.set_var(pane, "pi.activity", &json!(activity));
        }
        s.wait_row(pane, "the activity", |row| {
            row["status"]["message"].as_str().unwrap_or_default() == activity
        });
        assert_eq!(
            info(&s, id)["startedAt"],
            started,
            "the start time does not move"
        );
    }
    ko_as(
        &s,
        None,
        &["run-outcome", "--result", "completed", "--", id],
        "",
    )
    .ok();
    let event = loop {
        let event = watcher.event("run");
        if event.get("outcome").is_some() {
            break event;
        }
    };
    assert_eq!(
        event["startedAt"], started,
        "the ending event carries the same start"
    );
    assert_eq!(event["outcome"]["result"], "completed");
}
