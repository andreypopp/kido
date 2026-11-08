use ko_sys::pid::signal_descendant;
use ko_sys::signal::Signal;
use serde_json::{Value, json};

use crate::harness::{Server, decode, poll, quote, sh, size, size_request, start};
use crate::layout::{
    consistent, leaves, new, old, ptys_follow, shape, split, tree, window_size, windows,
};

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

#[test]
fn lifecycle_logs_rotate_and_input_logs_contain_only_counts() {
    let mut s = crate::harness::start_with(
        std::path::Path::new("/bin/sh"),
        &[("KO_LOG_BYTES", "1024"), ("KO_DEBUG_INPUT", "1")],
        &[],
    );
    one_window(&s, split("h", vec![new(), new()]));
    for _ in 0..12 {
        let (client, welcome) = s.app_client(json!({}), false, (80, 24));
        let id = welcome["client"].as_str().unwrap().to_owned();
        drop(client);
        poll("the client close in the log", || {
            std::fs::read_to_string(s.dir.join("log"))
                .unwrap_or_default()
                .contains(&format!("client {id} closed:"))
        });
    }
    assert!(s.dir.join("log.1").is_file());
    let (_client, welcome) = s.app_client(json!({"pane":"pane_2"}), false, (80, 24));
    let id = welcome["client"].as_str().unwrap();
    s.text("pane_2", "PRIVATE-INPUT\n");
    let marker = format!("client {id} selected session=session_1 window=window_1 pane=pane_2");
    poll(
        "the later lifecycle and input records in the new log",
        || {
            let log = std::fs::read_to_string(s.dir.join("log")).unwrap_or_default();
            log.contains(&marker) && log.contains("input to pane_2 source=http bytes=14")
        },
    );
    for path in [s.dir.join("log"), s.dir.join("log.1")] {
        let log = std::fs::read_to_string(path).unwrap();
        assert!(!log.contains("PRIVATE-INPUT"), "{log}");
        for line in log.lines() {
            assert_eq!(line.get(23..25), Some("Z "), "{line}");
        }
    }
    std::fs::remove_file(s.dir.join("log")).unwrap();
    let (_replacement, welcome) = s.app_client(json!({}), false, (80, 24));
    let marker = format!("client {} hello", welcome["client"].as_str().unwrap());
    poll("a lifecycle line after the log was removed", || {
        std::fs::read_to_string(s.dir.join("log"))
            .unwrap_or_default()
            .contains(&marker)
    });
    s.restart(&[]);
    let (_client, _) = s.app_client(json!({}), false, (80, 24));
    let before = std::fs::read_to_string(s.dir.join("log")).unwrap();
    let pane = s.pane("stty raw -echo; exec cat");
    s.text(&pane, "DEFAULT-PRIVATE-INPUT");
    let (_barrier, welcome) = s.app_client(json!({}), false, (80, 24));
    let marker = format!("client {} hello", welcome["client"].as_str().unwrap());
    poll("a lifecycle record after input with debug disabled", || {
        std::fs::read_to_string(s.dir.join("log"))
            .unwrap_or_default()
            .contains(&marker)
    });
    let after = std::fs::read_to_string(s.dir.join("log")).unwrap();
    assert_eq!(
        after.matches("input to ").count(),
        before.matches("input to ").count()
    );
    assert!(!after.contains("DEFAULT-PRIVATE-INPUT"));
}

#[test]
fn a_bad_client_hello_reports_the_decode_error_before_closing() {
    let s = start(&[]);
    let mut client = s.ws("/client");
    client.send(&json!({"type": "hello", "webview": false, "focused": false, "sizing": {"type": "disabled"}}));
    let refusal = client.event("refused");
    assert_eq!(refusal["message"], "missing field `name`");
    client.closed("the refused hello");

    let mut client = s.ws("/client");
    client.send(&json!({"type": "focused", "focused": false}));
    assert_eq!(client.event("refused")["message"], "hello must be first");
    client.closed("the request before hello");
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

    c.send(&size_request("window_1", size(100, 30)));
    wait_doc("the window at 100x30", &s, |d| {
        window_size(d, 0) == (100, 30)
    });
    let grown = s.doc();
    assert_eq!(consistent(&windows(&grown)[0]["tree"]), (100, 30));
    ptys_follow(&s, &grown);

    c.send(&size_request("window_1", size(1, 1)));
    wait_doc("the window at its smallest size again", &s, |d| {
        window_size(d, 0) == (7, 3)
    });
    assert_eq!(tree(&s.doc()), tree(&smallest));
}

#[test]
fn a_change_the_server_makes_reaches_every_client_as_a_layout_event() {
    let s = start(&[]);
    let exiting = json!({"pane": {"new": { "close": "keep", "command": {"type": "shell", "command": "printf READY; read line; exit 0"} }}});
    let first = one_window(&s, split("h", vec![new(), exiting, new(), new()]));
    let (mut a, _) = s.app_client(json!({}), false, (80, 24));
    let (mut b, _) = s.app_client(json!({}), false, (80, 24));
    let revision = first["revision"].as_u64().unwrap();

    s.delete("/panes/pane_1").ok();
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
    s.delete("/panes/pane_2").ok();
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
            .find_map(|(id, pid)| (id == "pane_3").then_some(pid).flatten());
        program.is_some()
    });
    let program = program.unwrap();
    let parent = program.parent().expect("a pane process");
    signal_descendant(s.child.pid(), parent, Signal::Kill).unwrap();
    for client in [&mut a, &mut b] {
        let dead = client.event("dead");
        assert_eq!(dead["dead"]["cause"]["type"], json!("failed"));
    }
    for client in [&mut a, &mut b] {
        let event = client.event("layout");
        assert_eq!(event["revision"].as_u64(), Some(revision + 3));
        assert_eq!(
            shape(&event["layout"]["sessions"][0]["windows"][0]["tree"]),
            "4:80x24"
        );
    }
}

#[test]
fn a_connected_client_learns_the_pid_of_a_pane_when_it_becomes_ready() {
    let s = start(&[]);
    one_window(&s, new());
    s.pane_program("pane_1");
    let (mut a, _) = s.app_client(json!({}), false, (80, 24));
    one_window(&s, split("h", vec![old("pane_1"), new()]));
    let event = a.event("pid");
    assert_eq!(event["pane"], json!("pane_2"));
    assert_eq!(
        event["pid"].as_i64(),
        Some(i64::from(s.pane_program("pane_2").get()))
    );
}

#[test]
fn one_client_sizes_each_reported_window_independently_of_its_selection() {
    let s = start(&[]);
    let parent = crate::panes::post(
        &s,
        None,
        "/panes",
        &json!({"command": {"type": "shell", "command": "exec /bin/sh"}}),
    );
    let child = crate::panes::post(
        &s,
        None,
        "/panes",
        &json!({"parent": parent["pane"], "command": {"type": "shell", "command": "exec /bin/sh"}}),
    );
    let sibling = crate::panes::post(
        &s,
        None,
        "/panes",
        &json!({"parent": parent["pane"], "command": {"type": "shell", "command": "exec /bin/sh"}}),
    );
    let mut client = s.ws("/client");
    client.send(&json!({"type": "hello", "webview": false, "name": "test", "pane": child["pane"], "focused": true, "sizing": {"type": "windows", "viewport": size(120, 40), "windows": []}}));
    client.welcome();
    let before = s.doc()["revision"].as_u64().unwrap();
    let mut report = json!({"type": "size", "sizing": {"type": "windows", "viewport": size(120, 40), "windows": [
        {"window": parent["window"], "size": size(120, 40)},
        {"window": child["window"], "size": size(35, 12)},
        {"window": sibling["window"], "size": size(60, 20)}
    ]}});
    client.send(&report);
    let event = client.event("layout");
    assert_eq!(event["revision"], before + 1);
    let dimensions = |doc: &Value, id: &Value| {
        let window = windows(doc)
            .into_iter()
            .find(|window| window["id"] == *id)
            .unwrap();
        (
            window["cols"].as_u64().unwrap(),
            window["rows"].as_u64().unwrap(),
        )
    };
    wait_doc("all reported sizes", &s, |doc| {
        dimensions(doc, &parent["window"]) == (120, 40)
            && dimensions(doc, &child["window"]) == (35, 12)
            && dimensions(doc, &sibling["window"]) == (60, 20)
    });
    assert_eq!(
        s.sttys(&[
            parent["pane"].as_str().unwrap(),
            child["pane"].as_str().unwrap(),
            sibling["pane"].as_str().unwrap()
        ]),
        vec![(40, 120), (12, 35), (20, 60)]
    );
    report["sizing"]["windows"][1]["size"] = size(39, 14);
    client.send(&report);
    wait_doc("only the child resize", &s, |doc| {
        dimensions(doc, &parent["window"]) == (120, 40)
            && dimensions(doc, &child["window"]) == (39, 14)
            && dimensions(doc, &sibling["window"]) == (60, 20)
    });
    let mut peer = s.ws("/client");
    peer.send(&json!({"type": "hello", "webview": false, "name": "peer", "pane": sibling["pane"], "focused": true, "sizing": {"type": "windows", "viewport": size(90, 30), "windows": [{"window": child["window"], "size": size(51, 21)}]}}));
    peer.welcome();
    wait_doc("peer claims its reported child", &s, |doc| {
        dimensions(doc, &child["window"]) == (51, 21)
    });
    report["sizing"]["windows"][0]["size"] = size(121, 41);
    report["sizing"]["windows"][1]["size"] = size(40, 15);
    client.send(&report);
    let deadline = std::time::Instant::now() + crate::harness::DEADLINE;
    let event = loop {
        assert!(
            std::time::Instant::now() < deadline,
            "no retained report resize"
        );
        let event = client.event("layout");
        if dimensions(&event, &parent["window"]) == (121, 41) {
            break event;
        }
    };
    assert_eq!(dimensions(&event, &parent["window"]), (121, 41));
    assert_eq!(dimensions(&event, &child["window"]), (51, 21));
    peer.send(&json!({"type": "size", "sizing": {"type": "disabled"}}));
    peer.send(&json!({"type": "select", "request": 1, "pane": sibling["pane"]}));
    peer.event("selected");
    report["sizing"]["windows"][0]["size"] = size(122, 42);
    client.send(&report);
    let event = client.event("layout");
    assert_eq!(dimensions(&event, &parent["window"]), (122, 42));
    assert_eq!(dimensions(&event, &child["window"]), (51, 21));
    client.send(&json!({"type": "focused", "focused": true}));
    wait_doc("focus reclaims the released child", &s, |doc| {
        dimensions(doc, &child["window"]) == (40, 15)
    });
    report["sizing"]["windows"][0]["size"] = size(123, 43);
    report["sizing"]["windows"]
        .as_array_mut()
        .unwrap()
        .push(json!({"window": "window_999999", "size": size(2, 2)}));
    client.send(&report);
    client.send(&json!({"type": "select", "request": 1, "pane": parent["pane"]}));
    assert_eq!(client.event("selected")["pane"], parent["pane"]);
    assert_eq!(dimensions(&s.doc(), &parent["window"]), (123, 43));
    let mut invalid = s.ws("/client");
    invalid.send(&json!({"type": "hello", "webview": false, "name": "invalid", "focused": true, "sizing": {"type": "disabled"}}));
    invalid.welcome();
    let before = s.doc();
    invalid.send(&json!({"type": "size", "sizing": {"type": "windows", "viewport": size(1, 1), "windows": [
        {"window": parent["window"], "size": size(1, 1)}, {"window": parent["window"], "size": size(2, 2)}
    ]}}));
    invalid.closed("duplicate window ids were accepted");
    let after = s.doc();
    assert_eq!(after["layout"], before["layout"]);
    assert_eq!(after["revision"], before["revision"]);
    client.send(&json!({"type": "select", "request": 1, "pane": child["pane"]}));
    client.event("selected");
    let created = crate::panes::post(
        &s,
        None,
        "/panes",
        &json!({"command": {"type": "shell", "command": "exec /bin/sh"}}),
    );
    assert_eq!(dimensions(&s.doc(), &created["window"]), (120, 40));
    assert_eq!(s.stty(created["pane"].as_str().unwrap()), (40, 120));
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
    b.send(&size_request("window_1", size(61, 21)));
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
    b.send(&size_request("window_1", size(70, 22)));
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
        selection: json!({"pane": "pane_1"}),
        focused: true,
        size: size(50, 10),
        windows: vec![json!("window_1")],
    });
    terminal.welcome();
    terminal.send(&size_request("window_1", size(51, 11)));
    wait_doc("the terminal client sizes the split window", &s, |d| {
        window_size(d, 0) == (51, 11)
    });
    assert_eq!(consistent(&windows(&s.doc())[0]["tree"]), (51, 11));
    let (mut late, _) = s.app_client(json!({"pane": "pane_1"}), true, (90, 40));
    late.send(&size_request("window_1", size(91, 41)));
    wait_doc("the app client's size", &s, |d| {
        window_size(d, 0) == (91, 41)
    });
    assert_eq!(consistent(&windows(&s.doc())[0]["tree"]), (91, 41));
}

#[test]
fn removing_a_window_returns_the_client_to_its_previous_visit() {
    let s = start(&[]);
    s.put(&json!({"layout": {"sessions": [
        {"name": "one", "windows": [
            {"name": "a", "tree": new()},
            {"name": "c", "tree": new()},
            {"name": "b", "tree": new()}]}
    ]}}));
    let mut client = s.ws("/client");
    client.send(&json!({"type": "hello", "webview": false, "name": "test", "pane": "pane_1", "focused": false, "sizing": {"type": "disabled"}}));
    let hello = client.event("selected");
    assert_eq!(hello["pane"], "pane_1");
    assert!(hello.get("request").is_none());
    client.send(&json!({"type": "select", "request": 41, "window": "window_3"}));
    let answer = client.event("selected");
    assert_eq!(answer["window"], "window_3");
    assert_eq!(answer["request"], 41);
    s.delete("/panes/pane_3").ok();
    assert_eq!(
        client.event("selected"),
        json!({"type": "selected", "session": "session_1", "window": "window_1", "pane": "pane_1"})
    );
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
    s.delete("/panes/pane_1").ok();
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
    s.delete("/panes/pane_2").ok();
    layout_until(&mut c, |sessions| {
        sessions.as_array().map(Vec::len) == Some(1)
    });
    assert_eq!(
        c.event("selected"),
        json!({"type": "selected", "session": "session_2", "window": "window_3", "pane": "pane_3"})
    );
    s.delete("/panes/pane_3").ok();
    layout_until(&mut c, |sessions| sessions == &json!([]));
    assert_eq!(c.event("selected"), json!({"type": "selected"}));
    assert_eq!(s.doc()["layout"]["sessions"], json!([]));
    assert_eq!(s.ko(&["panes", "--json"], "").json(), json!([]));
}

#[test]
fn a_swept_child_selects_its_parent_or_the_existing_window_fallback() {
    let s = crate::harness::start_serving("  linger_seconds: 0.2\n");
    s.put(&json!({"layout": {"sessions": [
        {"name": "children", "windows": [{"name": "fallback", "tree": new()}]},
        {"name": "parent", "windows": [{"name": "parent", "tree": new()}]}
    ]}}));
    let exiting = |parent: Option<&str>| {
        json!({"pane": {"new": {
            "command": {"type": "argv", "argv": ["/bin/sh", "-c", "printf READY; read line; exit 0"]},
            "parent": parent, "close": "on_exit"
        }}})
    };
    s.edit(|layout| {
        layout["sessions"][0]["windows"]
            .as_array_mut()
            .unwrap()
            .push(json!({"name": "child", "tree": exiting(Some("pane_2"))}));
    });
    let (mut c, _) = s.app_client(json!({"pane": "pane_3"}), true, (80, 24));
    poll("the child is ready", || {
        s.request("GET", "/panes/pane_3/screen", None, 200)
            .contains("READY")
    });
    s.text("pane_3", "\n");
    assert_eq!(c.event("dead")["pane"], "pane_3");
    c.send(&json!({"type": "focused", "focused": false}));
    assert_eq!(
        c.event("selected"),
        json!({"type": "selected", "session": "session_2", "window": "window_2", "pane": "pane_2"})
    );
    assert!(!s.has_pane("pane_3"));

    s.edit(|layout| {
        layout["sessions"][0]["windows"]
            .as_array_mut()
            .unwrap()
            .push(json!({"name": "fallback", "tree": split("h", vec![exiting(None), new()])}));
    });
    c.send(&json!({"type": "select", "request": 1, "pane": "pane_4"}));
    assert_eq!(c.event("selected")["pane"], "pane_4");
    poll("the root pane is ready", || {
        s.request("GET", "/panes/pane_4/screen", None, 200)
            .contains("READY")
    });
    s.text("pane_4", "\n");
    assert_eq!(
        c.event("selected"),
        json!({"type": "selected", "session": "session_1", "window": "window_4", "pane": "pane_5"})
    );
    assert!(!s.has_pane("pane_4"));
    s.delete("/panes/pane_5").ok();
    assert_eq!(c.event("selected")["pane"], "pane_1");

    s.edit(|layout| {
        layout["sessions"][0]["windows"]
            .as_array_mut()
            .unwrap()
            .push(json!({"name": "orphan", "tree": exiting(Some("pane_2"))}));
    });
    c.send(&json!({"type": "focused", "focused": true}));
    c.send(&json!({"type": "select", "request": 1, "pane": "pane_6"}));
    assert_eq!(c.event("selected")["pane"], "pane_6");
    s.delete("/panes/pane_2").ok();
    assert!(!s.has_pane("pane_6"));
    assert_eq!(
        c.event("selected"),
        json!({"type": "selected", "session": "session_1", "window": "window_1", "pane": "pane_1"})
    );
    assert!(!s.has_pane("pane_6"));

    let parent = s.new_pane(json!({"close": "keep", "command": {"type": "argv", "argv": ["/bin/sh", "-c", "printf READY; read line; printf FINISHED"]}}));
    let child = s.new_pane(json!({"parent": parent, "close": "on_exit"}));
    let grandchild = s.new_pane(json!({"parent": child, "close": "on_exit"}));
    c.send(&json!({"type": "select", "request": 43, "pane": child}));
    let selected = c.event("selected");
    assert_eq!(selected["pane"], child);
    assert_eq!(selected["request"], 43);
    c.send(&json!({"type": "size", "sizing": {"type": "windows", "viewport": {"cols": 80, "rows": 24}, "windows": [
        {"window": "window_6", "size": {"cols": 80, "rows": 24}},
        {"window": selected["window"], "size": {"cols": 80, "rows": 24}}
    ]}}));
    poll("the kept parent is ready", || {
        s.request("GET", &format!("/panes/{parent}/screen"), None, 200)
            .contains("READY")
    });
    s.text(&parent, "\n");
    assert_eq!(c.event("dead")["pane"], parent);
    layout_until(&mut c, |sessions| {
        sessions[0]["windows"].as_array().map(Vec::len) == Some(2)
    });
    let selected = c.event("selected");
    assert_eq!(selected["pane"], parent);
    assert!(selected.get("request").is_none());
    assert!(!s.has_pane(&child));
    assert!(!s.has_pane(&grandchild));
    assert!(
        s.request("GET", &format!("/panes/{parent}/screen"), None, 200)
            .contains("FINISHED")
    );
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

    c.send(&json!({"type": "select", "request": 1, "pane": "pane_2"}));
    assert_eq!(c.event("selected")["pane"], json!("pane_2"));
    c.send(&json!({"type": "select", "request": 1, "pane": "pane_2"}));
    assert_eq!(
        c.event("selected")["pane"],
        json!("pane_2"),
        "a select is announced also for the pane that is current"
    );
    logs(&s, ["IO", "I", ""]);
    c.send(&json!({"type": "switch", "request": 1, "over": "window", "direction": "next"}));
    assert_eq!(
        c.event("selected"),
        json!({"type": "selected", "request": 1, "session": "session_2", "window": "window_3", "pane": "pane_3"})
    );
    logs(&s, ["IO", "IO", "I"]);
    c.send(&json!({"type": "switch", "request": 1, "over": "session", "direction": "previous"}));
    assert_eq!(c.event("selected")["pane"], json!("pane_2"));
    logs(&s, ["IO", "IOI", "IO"]);
    c.send(&json!({"type": "select", "request": 1, "session": "session_2"}));
    assert_eq!(
        c.event("selected")["pane"],
        json!("pane_3"),
        "the server chose the pane"
    );
    logs(&s, ["IO", "IOIO", "IOI"]);

    c.send(&json!({"type": "select", "request": 1, "window": "window_1"}));
    assert_eq!(c.event("selected")["pane"], json!("pane_1"));
    logs(&s, ["IOI", "IOIO", "IOIO"]);

    let (mut watcher, _) = s.app_client(json!({"pane": "pane_1"}), true, (80, 24));
    c.send(&json!({"type": "select", "request": 1, "pane": "pane_2"}));
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

const SIZE_PROBE: &str = r#"import os,fcntl,termios,struct,tty,select
tty.setraw(0)
def out(s): os.write(1,(s+'\r\n').encode())
def ask(q):
 os.write(1,q); buf=b''
 while not buf.endswith(b't'):
  if not select.select([0],[],[],3)[0]: return 'NONE'
  buf+=os.read(0,64)
 return buf.decode().replace('\x1b','E')
n=-1
while True:
 n+=1
 r,c,x,y=struct.unpack('4H',fcntl.ioctl(0,termios.TIOCGWINSZ,b'\0'*8))
 out('%d size=%dx%d'%(n,c,r))
 out('%d px=%dx%d'%(n,x,y))
 if x:
  out('%d t14=%s'%(n,ask(b'\x1b[14t')))
  out('%d t16=%s'%(n,ask(b'\x1b[16t')))
  out('%d t18=%s'%(n,ask(b'\x1b[18t')))
 out('READY')
 if not os.read(0,1): break
"#;

fn probe(s: &Server, pane: &str, n: u32, size: (u32, u32), cell: (u32, u32)) {
    s.text(pane, "x");
    probe_round(s, pane, n, size, cell);
}

fn probe_round(
    s: &Server,
    pane: &str,
    n: u32,
    (cols, rows): (u32, u32),
    (width, height): (u32, u32),
) {
    let (x, y) = (cols * width, rows * height);
    for line in [
        format!("{n} size={cols}x{rows}"),
        format!("{n} px={x}x{y}"),
        format!("{n} t14=E[4;{y};{x}t"),
        format!("{n} t16=E[6;{height};{width}t"),
        format!("{n} t18=E[8;{rows};{cols}t"),
    ] {
        s.screen_has(pane, &line);
    }
}

#[test]
fn a_pane_knows_its_pixel_size_from_the_cell_size_of_the_sizing_client() {
    let s = start(&[]);
    let command = format!("exec python3 -u -c {}", quote(SIZE_PROBE));
    let first = s.pane(&command);
    let mut client = s.hello(crate::harness::Hello {
        selection: json!({"pane": first}),
        focused: true,
        size: json!({"cols": 100, "rows": 30, "cell_px": {"width": 16, "height": 35}}),
        windows: vec![json!("window_1")],
    });
    client.welcome();
    wait_doc("the client's size", &s, |d| window_size(d, 0) == (100, 30));
    s.screen_has(&first, "READY");
    probe(&s, &first, 1, (100, 30), (16, 35));

    s.edit(|layout| {
        layout["sessions"][0]["windows"][0]["tree"] = split(
            "h",
            vec![old(&first), json!({"pane": {"new": sh(&command)}})],
        );
    });
    let mut panes = Vec::new();
    leaves(&windows(&s.doc())[0]["tree"], &mut panes);
    let (second, rows, cols) = panes[1].clone();
    s.screen_has(&second, "READY");
    probe(&s, &second, 1, (cols, rows), (16, 35));
    assert_eq!((panes[0].2, cols), (50, 49));
    probe(&s, &first, 2, (panes[0].2, panes[0].1), (16, 35));

    client.send(&size_request(
        "window_1",
        json!({"cols": 100, "rows": 30, "cell_px": {"width": 9, "height": 20}}),
    ));
    wait_doc("the new cell size", &s, |d| {
        windows(d)[0]["cell_px"] == json!({"width": 9, "height": 20})
    });
    probe(&s, &first, 3, (panes[0].2, panes[0].1), (9, 20));
    probe(&s, &second, 2, (cols, rows), (9, 20));
}

#[test]
fn a_new_pane_reports_its_size_to_a_program_that_asks_at_startup() {
    let s = start(&[]);
    let command = format!("exec python3 -u -c {}", quote(SIZE_PROBE));
    let first = s.pane("cat");
    let mut client = s.hello(crate::harness::Hello {
        selection: json!({"pane": first}),
        focused: true,
        size: json!({"cols": 69, "rows": 28, "cell_px": {"width": 16, "height": 35}}),
        windows: vec![json!("window_1")],
    });
    client.welcome();
    wait_doc("the client's size", &s, |d| window_size(d, 0) == (69, 28));
    s.edit(|layout| {
        let windows = layout["sessions"][0]["windows"].as_array_mut().unwrap();
        windows[0]["tree"] = split(
            "h",
            vec![old(&first), json!({"pane": {"new": sh(&command)}})],
        );
        windows.push(json!({"name": "other", "tree": {"pane": {"new": sh(&command)}}}));
    });
    let document = s.doc();
    assert_eq!(window_size(&document, 1), (69, 28));
    for (window, at) in [(0, 1), (1, 0)] {
        let mut panes = Vec::new();
        leaves(&windows(&document)[window]["tree"], &mut panes);
        let (pane, rows, cols) = panes[at].clone();
        s.screen_has(&pane, "READY");
        probe_round(&s, &pane, 0, (cols, rows), (16, 35));
    }
}
