use serde_json::json;

use crate::harness::start;
use crate::status::osc7501;

#[test]
fn a_pi_pane_uses_its_name_then_its_own_title() {
    let s = start(&[]);
    let pane = s.new_pane(json!({
        "command": {"type": "shell", "command": "stty raw -echo; printf '\\033]0;Pane fallback\\007\\033]7501;state=idle:app=pi\\007'; exec cat"},
        "parent": s.token_pane("exec cat"), "close": "on_exit",
    }));
    s.wait_row(&pane, "the pi root", |row| {
        row["status"]["program_status"]["records"]
            .as_array()
            .is_some_and(|records| !records.is_empty())
    });
    s.set_var(&pane, "pi.session", &json!("child"));
    s.set_var(&pane, "pi.name", &json!("Current"));
    s.wait_row(&pane, "the pi name", |row| {
        row["status"]["title"] == "Current"
    });
    s.delete(&format!("/panes/{pane}/vars/pi.name")).ok();
    s.text(
        &pane,
        &osc7501("id=nested:state=blocked:app=builder:title=TmVzdGVk"),
    );
    s.wait_row(&pane, "the nested record", |row| {
        row["status"]["program_status"]["records"]
            .as_array()
            .is_some_and(|records| records.iter().any(|record| record["id"] == "nested"))
    });
    assert_eq!(s.row(&pane)["status"]["title"], "Pane fallback");
}
