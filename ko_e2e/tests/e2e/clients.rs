use ko_sys::pid::{Pid, signal_descendant};
use ko_sys::signal::Signal;
use serde_json::{Value, json};

use crate::harness::{Server, decode, poll, sh, size, size_request, start};
use crate::layout::{consistent, new, old, ptys_follow, shape, split, tree, windows};

fn layout_until(client: &mut crate::harness::Ws, wanted: impl Fn(&Value) -> bool) -> Value {
    loop {
        let event = client.event("layout");
        if wanted(&event["layout"]["sessions"]) {
            return event;
        }
    }
}

fn one_window(s: &Server, tree: Value) -> Value {
    s.put(&json!({"layout": {"sessions": [
        {"name": "a", "windows": [{"name": "w", "tree": tree}]}]}}))
}

fn wait_doc(what: &str, s: &Server, mut check: impl FnMut(&Value) -> bool) {
    poll(what, || check(&s.doc()));
}

fn window_size(document: &Value, window: usize) -> (u64, u64) {
    let window = &windows(document)[window];
    (
        window["cols"].as_u64().unwrap(),
        window["rows"].as_u64().unwrap(),
    )
}

#[test]
fn a_tree_scaled_down_to_one_column_for_each_pane_and_back() {
    let s = start(&[]);
    let tree_of = split(
        "h",
        vec![new(), new(), split("v", vec![new(), new()]), new()],
    );
    one_window(&s, tree_of);
    let (mut c, _) = s.app_client(json!({"pane": "pane_1"}), true, (1, 1));
    wait_doc("the window at its smallest size", &s, |d| {
        window_size(d, 0) == (7, 3)
    });
    let smallest = s.doc();
    assert_eq!(tree(&smallest), "h[1:1x3 2:1x3 v[3:1x1 4:1x1] 5:1x3]");
    ptys_follow(&s, &smallest);

    c.send(&size_request(size(100, 30)));
    wait_doc("the window at 100x30", &s, |d| {
        window_size(d, 0) == (100, 30)
    });
    let grown = s.doc();
    assert_eq!(consistent(&windows(&grown)[0]["tree"]), (100, 30));
    ptys_follow(&s, &grown);

    c.send(&size_request(size(1, 1)));
    wait_doc("the window at its smallest size again", &s, |d| {
        window_size(d, 0) == (7, 3)
    });
    assert_eq!(tree(&s.doc()), tree(&smallest));
}

#[test]
fn a_change_the_server_makes_reaches_every_client_as_a_layout_event() {
    let s = start(&[]);
    let exiting = json!({"pane": {"new": sh("printf READY; read line; exit 0")}});
    let first = one_window(&s, split("h", vec![new(), exiting, new(), new()]));
    let (mut a, _) = s.app_client(json!({}), false, (80, 24));
    let (mut b, _) = s.app_client(json!({}), false, (80, 24));
    let revision = first["revision"].as_u64().unwrap();

    s.delete("pane_1");
    for client in [&mut a, &mut b] {
        let event = client.event("layout");
        assert_eq!(event["revision"].as_u64(), Some(revision + 1));
        assert!(!event.to_string().contains("pane_1"), "{event}");
    }
    s.text("pane_2", "\n");
    let dead = a.event("dead");
    assert_eq!(dead["pane"], json!("pane_2"));
    assert_eq!(dead["dead"]["cause"]["type"], json!("exited"));
    assert_eq!(
        s.doc()["revision"].as_u64(),
        Some(revision + 1),
        "an exit leaves the layout"
    );
    s.delete("pane_2");
    for client in [&mut a, &mut b] {
        assert_eq!(
            client.event("layout")["revision"].as_u64(),
            Some(revision + 2)
        );
    }

    let mut program = None;
    poll("the third pane's program", || {
        program = s
            .pane_pids()
            .into_iter()
            .find(|(id, pid)| id == "pane_3" && *pid > 1)
            .and_then(|(_, pid)| Pid::new(pid));
        program.is_some()
    });
    let program = program.unwrap();
    let parent = program.parent().expect("a pane process");
    signal_descendant(s.child.pid(), parent, Signal::Kill).unwrap();
    for client in [&mut a, &mut b] {
        let dead = client.event("dead");
        assert_eq!(dead["dead"]["cause"]["type"], json!("failed"));
        let event = client.event("layout");
        assert_eq!(event["revision"].as_u64(), Some(revision + 3));
        assert_eq!(
            shape(&event["layout"]["sessions"][0]["windows"][0]["tree"]),
            "4:80x24"
        );
    }
}

#[test]
fn two_clients_on_one_window_follow_the_focused_one_and_the_window_keeps_its_size() {
    let s = start(&[]);
    one_window(&s, new());
    let (a, _) = s.app_client(json!({"pane": "pane_1"}), true, (100, 30));
    wait_doc("the first client's size", &s, |d| {
        window_size(d, 0) == (100, 30)
    });
    let (mut b, _) = s.app_client(json!({"pane": "pane_1"}), false, (60, 20));
    b.send(&size_request(size(61, 21)));
    assert_eq!(
        s.stty("pane_1"),
        (30, 100),
        "an unfocused second client sizes nothing"
    );
    assert_eq!(window_size(&s.doc(), 0), (100, 30));

    b.send(&json!({"type": "focused", "focused": true}));
    wait_doc("the second client's size", &s, |d| {
        window_size(d, 0) == (61, 21)
    });
    assert_eq!(s.stty("pane_1"), (21, 61));

    drop(a);
    b.send(&size_request(size(70, 22)));
    wait_doc("the sizing client's new size", &s, |d| {
        window_size(d, 0) == (70, 22)
    });
    drop(b);
    let kept = s.stty("pane_1");
    assert_eq!(
        (kept, window_size(&s.doc(), 0)),
        ((22, 70), (70, 22)),
        "no sizing client"
    );

    s.edit(|layout| {
        layout["sessions"][0]["windows"][0]["tree"] = split("h", vec![old("pane_1"), new()]);
    });
    let mut terminal = s.hello(crate::harness::Hello {
        kind: "terminal",
        selection: json!({"pane": "pane_1"}),
        focused: true,
        size: size(50, 10),
    });
    terminal.welcome();
    terminal.send(&size_request(size(51, 11)));
    let (mut late, _) = s.app_client(json!({"pane": "pane_1"}), true, (90, 40));
    late.send(&size_request(size(91, 41)));
    wait_doc("the app client's size", &s, |d| {
        window_size(d, 0) == (91, 41)
    });
    assert_eq!(consistent(&windows(&s.doc())[0]["tree"]), (91, 41));
}

#[test]
fn removing_the_last_pane_of_a_window_and_of_a_session_moves_the_client() {
    let s = start(&[]);
    s.put(&json!({"layout": {"sessions": [
        {"name": "one", "windows": [
            {"name": "w1", "tree": new()}, {"name": "w2", "tree": new()}]},
        {"name": "two", "windows": [{"name": "w3", "tree": new()}]},
    ]}}));
    let (mut c, _) = s.app_client(json!({"pane": "pane_1"}), false, (80, 24));
    c.event("layout");
    s.delete("pane_1");
    let layout = layout_until(&mut c, |sessions| {
        sessions[0]["windows"].as_array().map(Vec::len) == Some(1)
    });
    assert_eq!(
        layout["layout"]["sessions"][0]["windows"][0]["id"],
        json!("window_2")
    );
    assert_eq!(
        c.event("selected"),
        json!({"type": "selected", "session": "session_1", "window": "window_2", "pane": "pane_2"})
    );
    s.delete("pane_2");
    layout_until(&mut c, |sessions| {
        sessions.as_array().map(Vec::len) == Some(1)
    });
    assert_eq!(
        c.event("selected"),
        json!({"type": "selected", "session": "session_2", "window": "window_3", "pane": "pane_3"})
    );
    s.delete("pane_3");
    layout_until(&mut c, |sessions| sessions == &json!([]));
    assert_eq!(c.event("selected"), json!({"type": "selected"}));
    assert_eq!(s.doc()["layout"]["sessions"], json!([]));
    assert_eq!(s.ko(&["panes", "--json"], "").json(), json!([]));
}

const FOCUS_PROGRAM: &str = r#"import os,tty
tty.setraw(0)
os.write(1,b'\x1b[?1004hREADY\r\n')
while True:
 c=os.read(0,16)
 if c==b'\x1b[I': os.write(1,b'F:I\r\n')
 elif c==b'\x1b[O': os.write(1,b'F:O\r\n')
"#;

fn focus_pane() -> Value {
    json!({"pane": {"new": sh(&format!(
        "exec python3 -u -c {}",
        crate::harness::quote(FOCUS_PROGRAM)
    ))}})
}

fn focus_log(s: &Server, pane: &str) -> String {
    s.request(
        "GET",
        &format!("/panes/{pane}/screen?history=all"),
        None,
        200,
    )
    .lines()
    .filter_map(|line| line.trim().strip_prefix("F:"))
    .collect()
}

fn logs(s: &Server, expected: [&str; 3]) {
    let mut seen = [String::new(), String::new(), String::new()];
    poll(&format!("focus reports {expected:?}"), || {
        seen = ["pane_1", "pane_2", "pane_3"].map(|pane| focus_log(s, pane));
        seen.iter().zip(expected).all(|(seen, want)| seen == want)
    });
}

#[test]
fn select_switch_and_the_server_selecting_move_one_client_and_focus_reports_follow_the_shown_pane()
{
    let s = start(&[]);
    s.put(&json!({"layout": {"sessions": [
        {"name": "one", "windows": [
            {"name": "w1", "tree": focus_pane()}, {"name": "w2", "tree": focus_pane()}]},
        {"name": "two", "windows": [{"name": "w3", "tree": focus_pane()}]},
    ]}}));
    for pane in ["pane_1", "pane_2", "pane_3"] {
        poll("the focus program", || {
            s.request("GET", &format!("/panes/{pane}/screen"), None, 200)
                .contains("READY")
        });
    }
    let (mut c, _) = s.app_client(json!({"pane": "pane_1"}), true, (80, 24));
    logs(&s, ["I", "", ""]);

    c.send(&json!({"type": "select", "pane": "pane_2"}));
    logs(&s, ["IO", "I", ""]);
    c.send(&json!({"type": "switch", "over": "window", "direction": "next"}));
    assert_eq!(
        c.event("selected"),
        json!({"type": "selected", "session": "session_2", "window": "window_3", "pane": "pane_3"})
    );
    logs(&s, ["IO", "IO", "I"]);
    c.send(&json!({"type": "switch", "over": "session", "direction": "previous"}));
    assert_eq!(c.event("selected")["pane"], json!("pane_2"));
    logs(&s, ["IO", "IOI", "IO"]);
    c.send(&json!({"type": "select", "session": "session_2"}));
    assert_eq!(
        c.event("selected")["pane"],
        json!("pane_3"),
        "the server chose the pane"
    );
    logs(&s, ["IO", "IOIO", "IOI"]);

    let moved = s
        .ko(
            &["api", "--input", "-", "/clients/client_1/select"],
            r#"{"window": "window_1"}"#,
        )
        .ok();
    assert_eq!(moved, "{}");
    assert_eq!(c.event("selected")["pane"], json!("pane_1"));
    logs(&s, ["IOI", "IOIO", "IOIO"]);
    s.ko(
        &["api", "--input", "-", "/clients/client_9/select"],
        r#"{"window": "window_1"}"#,
    )
    .http_error(404);
    s.ko(&["api", "--input", "-", "/clients/client_1/select"], "{}")
        .http_error(400);

    let (mut watcher, _) = s.app_client(json!({"pane": "pane_1"}), true, (80, 24));
    c.send(&json!({"type": "select", "pane": "pane_2"}));
    logs(&s, ["IOI", "IOIOI", "IOIO"]);
    watcher.send(&json!({"type": "focused", "focused": false}));
    logs(&s, ["IOIO", "IOIOI", "IOIO"]);
}

#[test]
fn clearing_the_history_reaches_every_view_as_output_and_a_fresh_mirror_has_none() {
    let s = start(&[]);
    let pane = s.pane("seq 300; printf READY; exec cat");
    let mut full = s.ws(&format!("/panes/{pane}/view?history=all"));
    let mut partial = s.ws(&format!("/panes/{pane}/view?history=none"));
    full.ready("READY");
    partial.ready("READY");
    let before = s.request(
        "GET",
        &format!("/panes/{pane}/screen?history=all"),
        None,
        200,
    );
    assert!(before.contains("\n150\n"), "history before: {before:?}");

    assert_eq!(
        s.ko(
            &["api", "-X", "POST", &format!("/panes/{pane}/clear_history")],
            ""
        )
        .ok(),
        "{}"
    );
    full.output("\x1b[3J");
    partial.output("\x1b[3J");
    let (data, _) = s.ws(&format!("/panes/{pane}/view?history=all")).snapshot();
    let full_after = decode(&data, true);
    let (data, _) = s.ws(&format!("/panes/{pane}/view?history=none")).snapshot();
    let partial_after = decode(&data, false);
    assert!(
        full_after.history.lines().count() <= 24 && !full_after.history.contains("\n150\n"),
        "history: {:?}",
        full_after.history
    );
    assert!(full_after.screen.contains("READY") && full_after.screen.contains("300"));
    assert_eq!(partial_after.screen, full_after.screen);
    let after = s.request(
        "GET",
        &format!("/panes/{pane}/screen?history=all"),
        None,
        200,
    );
    assert!(
        !after.contains("\n150\n") && after.contains("READY"),
        "history after: {after:?}"
    );
    s.ko(&["api", "-X", "POST", "/panes/pane_9/clear_history"], "")
        .http_error(404);
}
