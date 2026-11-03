use std::fs;

use serde_json::Value;

use crate::harness::{ko, poll, text_of};
use crate::runs::{
    caller, child_of, ending, has_pane, id_of, ko_as, lingering, pane_of, wait_ending,
    wait_pane_gone,
};
use crate::shell::script;

const FIND_ID: &str = "id() { sed -n 's/.*\"id\":\"\\([0-9a-f]*\\)\".*/\\1/p'; }";

fn children(s: &crate::harness::Server, parent: &str) -> Vec<Value> {
    ko_as(
        s,
        None,
        &["runs", "--json", "--all", "--parent", parent],
        "",
    )
    .json()
    .as_array()
    .unwrap()
    .clone()
}

#[test]
fn a_tree_of_depth_two_reports_to_its_parents_is_stopped_and_is_swept() {
    let s = lingering();
    let caller = caller(&s);
    let ko = ko();
    let notices_root = s.scratch.join("notices-root");
    let notices_child = s.scratch.join("notices-child");
    let child_script = script(
        &s.scratch,
        "child.sh",
        &format!(
            "{FIND_ID}\n\
             live=$(\"$KO\" run-child \"$KO_RUN_ID\" --name grandchild-live --env KO=\"$KO\" -- sleep 300 | id)\n\
             done=$(\"$KO\" run-child \"$KO_RUN_ID\" --name grandchild-done --env KO=\"$KO\" -- sh -c 'exit 0' | id)\n\
             \"$KO\" run-wait --json \"$done\" >> {}\n\
             exec sleep 300\n",
            notices_child.display()
        ),
    );
    let root_script = script(
        &s.scratch,
        "root.sh",
        &format!(
            "{FIND_ID}\n\
             child=$(\"$KO\" run-child \"$KO_RUN_ID\" --name child --env KO=\"$KO\" -- sh {} | id)\n\
             \"$KO\" run-wait --json \"$child\" >> {}\n\
             exec sleep 300\n",
            child_script.display(),
            notices_root.display()
        ),
    );
    let root = {
        let args = [
            "run",
            "--name",
            "root",
            "--env",
            &format!("KO={}", ko.display()),
            "--",
            "sh",
            text_of(&root_script),
        ];
        crate::runs::started(&s, &caller, &args)
    };
    let root_id = id_of(&root);

    poll("the child to be started", || {
        children(&s, root_id).len() == 1
    });
    let child = children(&s, root_id).remove(0);
    let child_id = child["id"].as_str().unwrap().to_owned();
    assert_eq!(
        (child["name"].as_str(), child["parent"].as_str()),
        (Some("child"), Some(root_id))
    );
    poll("the grandchildren to be started", || {
        children(&s, &child_id).len() == 2
    });
    let grandchildren = children(&s, &child_id);
    let by_name = |name: &str| -> Value {
        grandchildren
            .iter()
            .find(|run| run["name"] == name)
            .unwrap()
            .clone()
    };
    let (live, done) = (by_name("grandchild-live"), by_name("grandchild-done"));
    assert_eq!(live["parent"].as_str(), Some(child_id.as_str()));

    poll("the grandchild's report to reach its parent", || {
        fs::read_to_string(&notices_child)
            .is_ok_and(|text| text.contains("\"result\":\"completed\""))
    });
    assert_eq!(ending(&s, done["id"].as_str().unwrap()).0, "completed");

    ko_as(&s, None, &["run-stop", live["id"].as_str().unwrap()], "").ok();
    wait_pane_gone(&s, live["pane"].as_str().unwrap());
    assert_eq!(ending(&s, live["id"].as_str().unwrap()).0, "stopped");
    wait_pane_gone(&s, done["pane"].as_str().unwrap());

    let late = child_of(&s, &caller, &child_id, "late", &["sleep", "300"]);
    assert!(has_pane(&s, pane_of(&late)));
    ko_as(
        &s,
        None,
        &["run-outcome", "--result", "completed", "--", &child_id],
        "",
    )
    .ok();
    poll("the child's report to reach the root", || {
        fs::read_to_string(&notices_root)
            .is_ok_and(|text| text.contains("\"result\":\"completed\""))
    });
    wait_pane_gone(&s, pane_of(&late));
    assert_eq!(
        wait_ending(&s, id_of(&late)),
        ("failed".to_owned(), "its parent ended".to_owned()),
        "a child of a run that reported is swept"
    );

    ko_as(&s, None, &["run-stop", &child_id], "").ok();
    wait_pane_gone(&s, child["pane"].as_str().unwrap());
    ko_as(&s, None, &["run-stop", root_id], "").ok();
    wait_pane_gone(&s, pane_of(&root));
    assert_eq!(
        ending(&s, &child_id).0,
        "completed",
        "the first outcome stands"
    );
    assert_eq!(ending(&s, root_id).0, "stopped");
    let rows = s.rows();
    assert_eq!(rows.len(), 1, "only the caller's pane is left: {rows:?}");
}

#[test]
fn the_client_lists_a_subagent_under_its_parent_indented_one_column() {
    use crate::outer::{Keys, Outer};

    let s = crate::harness::start(&[]);
    let title = |name: &str| {
        serde_json::json!({
            "command": {"type": "shell", "command": format!("printf '\\033]0;{name}\\007'; exec cat")},
            "vars": {"pi.session": format!("session-{name}")}
        })
    };
    let parent = s.new_pane(title("parent"));
    s.new_pane(title("other"));
    let child = child_of(
        &s,
        &parent,
        &parent,
        "kid",
        &["sh", "-c", "printf '\\033]0;child\\007'; exec cat"],
    );
    let o = Outer::new(&s.dir, Keys::Extended);
    o.attach("");
    o.wait("the nested rows", || {
        let lines = o.lines();
        lines.iter().any(|line| line.starts_with("1  parent"))
            && lines.iter().any(|line| line.starts_with("2   child"))
            && lines.iter().any(|line| line.starts_with("3  other"))
    });
    let lines = o.lines();
    let at = |prefix: &str| {
        lines
            .iter()
            .position(|line| line.starts_with(prefix))
            .unwrap()
    };
    assert!(
        at("1  parent") < at("2   child") && at("2   child") < at("3  other"),
        "{lines:?}"
    );
    assert!(has_pane(&s, pane_of(&child)));
    o.detach();
}
