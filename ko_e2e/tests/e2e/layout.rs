use serde_json::{Value, json};

use std::time::Duration;

use crate::harness::{Message, Server, Ws, poll, sh, start, tagged, wait_gone};

pub(crate) fn put_edit(s: &Server, edit: &Value) -> Value {
    s.ko(&["layout", "edit", &edit.to_string()], "").json()["snapshot"].take()
}

pub(crate) fn window_size(document: &Value, window: usize) -> (u64, u64) {
    let window = windows(document)[window];
    (
        window["cols"].as_u64().unwrap(),
        window["rows"].as_u64().unwrap(),
    )
}

pub(crate) fn shell() -> Value {
    sh("exec /bin/sh")
}

pub(crate) fn new() -> Value {
    json!({"pane": {"new": shell()}})
}

pub(crate) fn old(pane: &str) -> Value {
    json!({"pane": pane})
}

pub(crate) fn split(axis: &str, children: Vec<Value>) -> Value {
    json!({"split": axis, "children": children})
}

pub(crate) fn shape(node: &Value) -> String {
    match node["split"].as_str() {
        Some(axis) => format!(
            "{axis}[{}]",
            node["children"]
                .as_array()
                .unwrap()
                .iter()
                .map(shape)
                .collect::<Vec<_>>()
                .join(" ")
        ),
        None => format!(
            "{}:{}x{}",
            node["pane"].as_str().unwrap().trim_start_matches("pane_"),
            node["cols"],
            node["rows"]
        ),
    }
}

pub(crate) fn windows(document: &Value) -> Vec<&Value> {
    document["layout"]["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|session| session["windows"].as_array().unwrap())
        .collect()
}

pub(crate) fn tree(document: &Value) -> String {
    shape(&windows(document)[0]["tree"])
}

pub(crate) fn leaves(node: &Value, out: &mut Vec<(String, u32, u32)>) {
    match node["children"].as_array() {
        Some(children) => children.iter().for_each(|child| leaves(child, out)),
        None => out.push((
            node["pane"].as_str().unwrap().to_owned(),
            node["rows"].as_u64().unwrap() as u32,
            node["cols"].as_u64().unwrap() as u32,
        )),
    }
}

pub(crate) fn consistent(node: &Value) -> (u64, u64) {
    match node["split"].as_str() {
        None => (
            node["cols"].as_u64().unwrap(),
            node["rows"].as_u64().unwrap(),
        ),
        Some(axis) => {
            let sizes: Vec<_> = node["children"]
                .as_array()
                .unwrap()
                .iter()
                .map(consistent)
                .collect();
            let gaps = sizes.len() as u64 - 1;
            if axis == "h" {
                assert!(sizes.iter().all(|size| size.1 == sizes[0].1), "{node}");
                (
                    sizes.iter().map(|size| size.0).sum::<u64>() + gaps,
                    sizes[0].1,
                )
            } else {
                assert!(sizes.iter().all(|size| size.0 == sizes[0].0), "{node}");
                (
                    sizes[0].0,
                    sizes.iter().map(|size| size.1).sum::<u64>() + gaps,
                )
            }
        }
    }
}

pub(crate) fn ptys_follow(s: &Server, document: &Value) {
    let mut expected = Vec::new();
    for window in windows(document) {
        let mut sizes = Vec::new();
        leaves(&window["tree"], &mut sizes);
        for float in window["floats"].as_array().unwrap() {
            sizes.push((
                float["pane"].as_str().unwrap().to_owned(),
                float["rows"].as_u64().unwrap() as u32,
                float["cols"].as_u64().unwrap() as u32,
            ));
        }
        for (pane, rows, cols) in sizes {
            let zoomed = window["zoom"].as_str() == Some(&pane);
            expected.push(if zoomed {
                (
                    pane,
                    window["rows"].as_u64().unwrap() as u32,
                    window["cols"].as_u64().unwrap() as u32,
                )
            } else {
                (pane, rows, cols)
            });
        }
    }
    let panes: Vec<&str> = expected.iter().map(|(pane, ..)| pane.as_str()).collect();
    let found = s.sttys(&panes);
    for ((pane, rows, cols), found) in expected.iter().zip(found) {
        assert_eq!((*rows, *cols), found, "{pane} in {document}");
    }
}

#[test]
fn every_edit_of_the_layout_is_normalized_and_resizes_the_panes() {
    let s = start(&[]);
    let first = s.put(&json!({"layout": {"sessions": [
        {"name": "main", "windows": [{"name": "edit", "tree": new()}]}]}}));
    assert_eq!(tree(&first), "1:80x24");
    ptys_follow(&s, &first);

    let split_h = s.edit(|layout| {
        layout["sessions"][0]["windows"][0]["tree"] = split("h", vec![old("pane_1"), new()]);
    });
    assert_eq!(tree(&split_h), "h[1:40x24 2:39x24]");
    ptys_follow(&s, &split_h);

    let split_v = s.edit(|layout| {
        layout["sessions"][0]["windows"][0]["tree"] = split(
            "h",
            vec![old("pane_1"), split("v", vec![old("pane_2"), new()])],
        );
    });
    assert_eq!(tree(&split_v), "h[1:40x24 v[2:39x12 3:39x11]]");
    ptys_follow(&s, &split_v);

    let resized = s.edit(|layout| {
        layout["sessions"][0]["windows"][0]["tree"] = split(
            "h",
            vec![
                json!({"pane": "pane_1", "cols": 20, "rows": 24}),
                split(
                    "v",
                    vec![
                        json!({"pane": "pane_2", "cols": 59, "rows": 12}),
                        json!({"pane": "pane_3", "cols": 59, "rows": 11}),
                    ],
                ),
            ],
        );
    });
    assert_eq!(tree(&resized), "h[1:20x24 v[2:59x12 3:59x11]]");
    ptys_follow(&s, &resized);

    let equalized = s.edit(|layout| {
        layout["sessions"][0]["windows"][0]["tree"] = split(
            "h",
            vec![
                old("pane_1"),
                split("v", vec![old("pane_2"), old("pane_3")]),
            ],
        );
    });
    assert_eq!(tree(&equalized), "h[1:40x24 v[2:39x12 3:39x11]]");
    ptys_follow(&s, &equalized);

    let swapped = s.edit(|layout| {
        let window = &mut layout["sessions"][0]["windows"][0];
        let children = window["tree"]["children"].as_array_mut().unwrap();
        children.reverse();
    });
    assert_eq!(tree(&swapped), "h[v[2:39x12 3:39x11] 1:40x24]");
    assert_eq!(revision(&swapped), revision(&equalized) + 1);
    ptys_follow(&s, &swapped);

    s.delete("/panes/pane_3").ok();
    let killed = s.doc();
    assert_eq!(tree(&killed), "h[2:39x24 1:40x24]");
    assert_eq!(revision(&killed), revision(&swapped) + 1);
    ptys_follow(&s, &killed);

    let with_second_window = s.edit(|layout| {
        layout["sessions"][0]["windows"]
            .as_array_mut()
            .unwrap()
            .push(json!({"name": "other", "tree": new()}));
    });
    assert_eq!(windows(&with_second_window).len(), 2);
    let moved = s.edit(|layout| {
        let windows = layout["sessions"][0]["windows"].as_array_mut().unwrap();
        windows.truncate(1);
        windows[0]["tree"] = split(
            "h",
            vec![
                old("pane_2"),
                split("v", vec![old("pane_1"), old("pane_4")]),
            ],
        );
    });
    assert_eq!(windows(&moved).len(), 1);
    assert_eq!(tree(&moved), "h[2:40x24 v[1:39x12 4:39x11]]");
    ptys_follow(&s, &moved);

    let zoomed = s.edit(|layout| layout["sessions"][0]["windows"][0]["zoom"] = json!("pane_1"));
    assert_eq!(windows(&zoomed)[0]["zoom"], json!("pane_1"));
    assert_eq!(tree(&zoomed), "h[2:40x24 v[1:39x12 4:39x11]]");
    ptys_follow(&s, &zoomed);
    let unzoomed = s.edit(|layout| {
        layout["sessions"][0]["windows"][0]
            .as_object_mut()
            .unwrap()
            .remove("zoom");
    });
    assert!(windows(&unzoomed)[0].get("zoom").is_none());
    ptys_follow(&s, &unzoomed);

    let floating = s.edit(|layout| {
        layout["sessions"][0]["windows"][0]["floats"] = json!([
            {"pane": {"new": shell()}, "x": 10, "y": 5, "cols": 30, "rows": 8, "title": "f"},
            {"pane": {"new": shell()}},
        ]);
    });
    let floats = windows(&floating)[0]["floats"].clone();
    assert_eq!(
        floats,
        json!([
            {"pane": "pane_5", "x": 10, "y": 5, "cols": 30, "rows": 8, "z": 0, "border": false, "title": "f"},
            {"pane": "pane_6", "x": 20, "y": 6, "cols": 40, "rows": 12, "z": 1, "border": false, "title": ""},
        ])
    );
    ptys_follow(&s, &floating);
    let raised = s.edit(|layout| {
        let floats = layout["sessions"][0]["windows"][0]["floats"]
            .as_array_mut()
            .unwrap();
        floats[0]["x"] = json!(75);
        floats[0]["y"] = json!(20);
        floats[0]["z"] = json!(9);
    });
    let floats = &windows(&raised)[0]["floats"];
    assert_eq!(
        (
            &floats[0]["pane"],
            &floats[0]["z"],
            &floats[1]["pane"],
            &floats[1]["z"]
        ),
        (&json!("pane_6"), &json!(0), &json!("pane_5"), &json!(1))
    );
    assert_eq!((&floats[1]["x"], &floats[1]["y"]), (&json!(50), &json!(16)));
    ptys_follow(&s, &raised);

    let renamed = s.edit(|layout| {
        layout["sessions"][0]["name"] = json!("work");
        layout["sessions"][0]["windows"][0]["name"] = json!("main");
    });
    assert_eq!(
        (
            &renamed["layout"]["sessions"][0]["name"],
            &windows(&renamed)[0]["name"]
        ),
        (&json!("work"), &json!("main"))
    );
    assert_eq!(renamed["layout"]["sessions"][0]["id"], json!("session_1"));

    let grown = s.edit(|layout| {
        layout["sessions"][0]["windows"]
            .as_array_mut()
            .unwrap()
            .push(json!({"name": "third", "tree": new()}));
        layout["sessions"]
            .as_array_mut()
            .unwrap()
            .push(json!({"name": "second", "windows": [{"name": "w", "tree": new()}]}));
    });
    let ids: Vec<_> = grown["layout"]["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|session| {
            let windows: Vec<_> = session["windows"]
                .as_array()
                .unwrap()
                .iter()
                .map(|window| window["id"].as_str().unwrap())
                .collect();
            format!("{} {}", session["id"].as_str().unwrap(), windows.join(","))
        })
        .collect();
    assert_eq!(ids, ["session_1 window_1,window_3", "session_2 window_4"]);
    ptys_follow(&s, &grown);

    let reordered = s.edit(|layout| {
        layout["sessions"].as_array_mut().unwrap().reverse();
        layout["sessions"][1]["windows"]
            .as_array_mut()
            .unwrap()
            .reverse();
    });
    let order: Vec<_> = reordered["layout"]["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|session| session["id"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(order, ["session_2", "session_1"]);
    assert_eq!(
        reordered["layout"]["sessions"][1]["windows"][0]["id"],
        json!("window_3")
    );

    let mut listed = Value::Null;
    poll("the CLI and the HTTP pane lists to agree", || {
        listed = s.ko(&["panes", "--json"], "").json();
        serde_json::from_str::<Value>(&s.request("GET", "/panes", None, 200)).unwrap() == listed
    });
    assert_eq!(listed.as_array().map(Vec::len), Some(7));
    let table = s.ko(&["panes"], "").ok();
    assert!(
        table.starts_with("PANE  ") && table.lines().count() == 8 && table.contains("running"),
        "{table}"
    );
}

fn current(s: &Server) -> Value {
    let mut document = s.doc();
    document.as_object_mut().unwrap().remove("panes");
    document
}

#[test]
fn a_stale_revision_gets_409_and_the_current_document_and_the_retry_lands() {
    let s = start(&[]);
    let first = s.edit(|layout| {
        layout["sessions"] = json!([{"name": "a", "windows": [{"name": "w", "tree": new()}]}]);
    });
    let stale = json!({"revision": 0, "layout": first["layout"]});
    assert_eq!(put_stale(&s, &stale, |_| {}), current(&s));
    assert_eq!(
        s.doc()["panes"]
            .as_array()
            .map(|panes| panes[0]["id"].clone()),
        Some(json!("pane_1")),
        "the layout names its panes with their rows"
    );

    let renamed = json!({"revision": 0, "layout": {"sessions": [{"id": "session_1", "name": "b",
        "windows": [{"id": "window_1", "name": "w", "tree": old("pane_1")}]}]}});
    let landed = s.put(&renamed);
    assert_eq!(revision(&landed), 2);
    assert_eq!(landed["layout"]["sessions"][0]["name"], json!("b"));

    let (status, body) = s.exchange(
        "PUT",
        "/layout",
        &s.headers(),
        b"{\"revision\":2,\"layout\":{\"sessions\":[]}}",
    );
    assert_eq!(status, 400, "{}", String::from_utf8_lossy(&body));
    assert_eq!(
        serde_json::from_slice::<Value>(&body).unwrap(),
        json!({"kind": "invalid", "message": "pane_1 is in no window"})
    );
    assert_eq!(current(&s), landed);
}

fn revision(document: &Value) -> u64 {
    document["revision"].as_u64().unwrap()
}

fn layout_at(client: &mut Ws, reached: impl Fn(&Value) -> bool) -> Value {
    loop {
        let event = client.event("layout");
        if reached(&event) {
            return event;
        }
    }
}

fn put_stale(s: &Server, stale: &Value, change: impl FnOnce(&mut Value)) -> Value {
    let mut document = stale.clone();
    change(&mut document["layout"]);
    let (status, body) = s.exchange(
        "PUT",
        "/layout",
        &s.headers(),
        document.to_string().as_bytes(),
    );
    assert_eq!(status, 409, "{}", String::from_utf8_lossy(&body));
    serde_json::from_slice(&body).unwrap()
}

#[test]
fn deleting_a_window_or_a_session_is_one_change_and_a_put_from_before_it_gets_409() {
    let s = start(&[]);
    s.put(&json!({"layout": {"sessions": [
        {"name": "one", "windows": [
            {"name": "w1", "tree": split("h", vec![new(), new()])},
            {"name": "w2", "tree": new()}]},
        {"name": "two", "windows": [{"name": "w3", "tree": new()}, {"name": "w4", "tree": new()}]},
    ]}}));
    let (mut client, _) = s.app_client(json!({"pane": "pane_1"}), false, (80, 24));
    let rows = s.rows().len();
    assert_eq!(rows, 5);

    let before = s.doc();
    let doomed = [s.pane_program("pane_1"), s.pane_program("pane_2")];
    assert_eq!(s.delete("/windows/window_1").ok(), "{}");
    let event = layout_at(&mut client, |event| revision(event) > revision(&before));
    assert_eq!(
        revision(&event),
        revision(&before) + 1,
        "one change, one event"
    );
    let names: Vec<_> = windows(&event).iter().map(|w| w["name"].clone()).collect();
    assert_eq!(names, [json!("w2"), json!("w3"), json!("w4")]);
    assert_eq!(
        client.event("selected"),
        json!({"type": "selected", "session": "session_1", "window": "window_2", "pane": "pane_3"}),
        "the client in the deleted window moves to the next one"
    );
    for pid in doomed {
        wait_gone(pid, "the delete of its window");
    }
    assert_eq!(s.rows().len(), rows - 2);
    let stale_reply = put_stale(&s, &before, |layout| {
        layout["sessions"][0]["windows"][0]["tree"] = split("h", vec![old("pane_1"), new()]);
    });
    assert_eq!(
        stale_reply,
        current(&s),
        "the stale edit gets the current document"
    );
    let after_stale = current(&s);
    assert_eq!(s.rows().len(), rows - 2, "no pane survived the stale edit");
    let missing = s.delete("/windows/window_1").http_error(404);
    assert_eq!(
        serde_json::from_str::<Value>(&missing).unwrap()["kind"],
        json!("not_found")
    );
    s.delete("/windows/window_77").http_error(404);
    assert_eq!(current(&s), after_stale, "a refused delete changes nothing");

    let before = s.doc();
    let doomed = [s.pane_program("pane_4"), s.pane_program("pane_5")];
    assert_eq!(s.delete("/sessions/session_2").ok(), "{}");
    let event = layout_at(&mut client, |event| revision(event) > revision(&before));
    assert_eq!(revision(&event), revision(&before) + 1);
    assert_eq!(
        event["layout"]["sessions"].as_array().map(Vec::len),
        Some(1)
    );
    for pid in doomed {
        wait_gone(pid, "the delete of its session");
    }
    put_stale(&s, &before, |layout| {
        layout["sessions"][1]["windows"][0]["tree"] = split("h", vec![old("pane_4"), new()]);
    });
    assert_eq!(s.rows().len(), 1);
    s.delete("/sessions/session_2").http_error(404);
    assert_eq!(
        s.doc()["layout"]["sessions"].as_array().map(Vec::len),
        Some(1)
    );
}

#[test]
fn the_last_session_going_leaves_a_running_server_and_a_put_starts_the_next_session() {
    let s = start(&[]);
    let one = || {
        json!({"layout": {"sessions": [
            {"name": "only", "windows": [{"name": "w", "tree": new()}]}]}})
    };
    let (mut client, _) = {
        s.put(&one());
        s.app_client(json!({"pane": "pane_1"}), false, (80, 24))
    };
    let gone = [
        ("/sessions/session_1", "the session delete"),
        ("/windows/window_2", "the window delete"),
        ("/panes/pane_3", "the pane delete"),
    ];
    for (round, (path, what)) in gone.into_iter().enumerate() {
        if round > 0 {
            s.put(&json!({"revision": revision(&s.doc()), "layout": one()["layout"]}));
        }
        let before = s.doc();
        assert_eq!(s.delete(path).ok(), "{}", "{what}");
        let after = s.doc();
        assert_eq!(after["layout"], json!({"sessions": []}), "{what}");
        assert_eq!(revision(&after), revision(&before) + 1, "{what}");
        layout_at(&mut client, |event| revision(event) >= revision(&after));
        assert_eq!(s.ko(&["panes", "--json"], "").json(), json!([]), "{what}");
        s.request("GET", "/version", None, 200);
    }
    let again = s.doc();
    assert_eq!(again["layout"]["sessions"], json!([]));
    let created = s.put(&json!({"revision": revision(&again), "layout": one()["layout"]}));
    assert_eq!(created["layout"]["sessions"][0]["id"], json!("session_4"));
    poll("the new pane", || s.rows().len() == 1);
}

#[test]
fn a_new_window_is_named_after_its_first_panes_program_and_a_name_in_a_put_renames_it() {
    let s = start(&[]);
    let argv =
        |words: &[&str]| json!({"pane": {"new": {"command": {"type": "argv", "argv": words}}}});
    let created = s.put(&json!({"layout": {"sessions": [{"name": "s", "windows": [
        {"tree": argv(&["/bin/sleep", "300"])},
        {"tree": {"pane": {"new": {"command": {"type": "shell", "command": "sleep 301"}}}}},
        {"tree": {"pane": {"new": {}}}},
        {"name": "given", "tree": argv(&["/bin/sleep", "302"])},
    ]}]}}));
    let names = |document: &Value| -> Vec<String> {
        windows(document)
            .iter()
            .map(|window| window["name"].as_str().unwrap().to_owned())
            .collect()
    };
    assert_eq!(names(&created), ["sleep", "sleep", "sh", "given"]);

    let renamed = s.edit(|layout| {
        let windows = layout["sessions"][0]["windows"].as_array_mut().unwrap();
        windows[0]["name"] = json!("work");
        windows[1].as_object_mut().unwrap().remove("name");
        windows.push(json!({"tree": {"pane": "pane_4"}}));
        windows[3]["tree"] = argv(&["/bin/sleep", "303"]);
    });
    assert_eq!(
        names(&renamed),
        ["work", "sleep", "sh", "given", "given"],
        "a rename sticks, a missing name keeps the old one, a pane moved to a new window gives it its old window's name"
    );
    let again = s.put(&renamed);
    assert_eq!(names(&again), names(&renamed));
}

#[test]
fn a_window_names_its_last_focused_pane_and_a_put_cannot_set_it() {
    let s = start(&[]);
    let first = s.put(&json!({"layout": {"sessions": [{"name": "s", "windows": [
        {"name": "w", "tree": split("h", vec![new(), new()])}]}]}}));
    assert_eq!(windows(&first)[0]["focus"], json!("pane_1"));
    let (mut client, _) = s.app_client(json!({"pane": "pane_1"}), true, (80, 24));
    let (mut peer, _) = s.app_client(json!({"pane": "pane_1"}), false, (80, 24));
    let before = s.doc();
    assert!(revision(&before) >= revision(&first));

    client.send(&json!({"type": "select", "pane": "pane_2"}));
    let current = s.doc();
    assert_eq!(windows(&current)[0]["focus"], json!("pane_2"));
    assert_eq!(
        revision(&current),
        revision(&before),
        "a focus change is outside the revision"
    );
    let renamed = s.put(&{
        let mut stale = before.clone();
        stale["layout"]["sessions"][0]["name"] = json!("renamed");
        stale
    });
    assert_eq!(
        (revision(&renamed), windows(&renamed)[0]["focus"].clone()),
        (revision(&before) + 1, json!("pane_2")),
        "a PUT made before the select still lands, and the first layout event is its own"
    );
    peer.within(Duration::from_secs(5));
    let mut seen = Vec::new();
    let layout = loop {
        let Message::Text(text) = peer.read() else {
            continue;
        };
        match tagged(&text) {
            Some((tag, payload)) if tag == "layout" => break payload,
            Some((tag, payload)) if tag == "focus" => seen.push(payload),
            _ => {}
        }
    };
    assert_eq!(layout["revision"], renamed["revision"]);
    assert_eq!(
        seen.len(),
        1,
        "one focus event and no layout event before the rename's"
    );
    assert_eq!(
        (&seen[0]["window"], &seen[0]["pane"]),
        (&json!("window_1"), &json!("pane_2"))
    );

    let mut sent = s.doc();
    sent["layout"]["sessions"][0]["windows"][0]["focus"] = json!("pane_1");
    let kept = s.put(&sent);
    assert_eq!(windows(&kept)[0]["focus"], json!("pane_2"));
    assert_eq!(
        revision(&kept),
        revision(&renamed),
        "a PUT of focus alone changes nothing"
    );
    sent["layout"]["sessions"][0]["windows"][0]["focus"] = json!("pane_99");
    assert_eq!(s.put(&sent), kept);

    s.delete("/panes/pane_2").ok();
    let after = layout_at(&mut client, |event| revision(event) > revision(&kept));
    assert_eq!(windows(&after)[0]["focus"], json!("pane_1"));
}

fn two_windows_and_a_wide_client(s: &Server) -> Ws {
    s.put(&json!({"layout": {"sessions": [{"name": "s", "windows": [
        {"name": "a", "tree": new()}, {"name": "b", "tree": new()}]}]}}));
    let (client, _) = s.app_client(json!({"pane": "pane_1"}), true, (100, 30));
    poll("the client to size its window", || {
        windows(&s.doc())[0]["cols"] == json!(100)
    });
    client
}

fn assert_one_event_for_one_revision(s: &Server, client: &mut Ws, before: &Value) -> Value {
    let event = layout_at(client, |event| revision(event) > revision(before));
    assert_eq!(revision(&event), revision(before) + 1, "one revision");
    assert_eq!(s.doc()["revision"], event["revision"]);
    s.edit(|layout| layout["sessions"][0]["name"] = json!("marker"));
    assert_eq!(
        client.event("layout")["revision"],
        json!(revision(before) + 2),
        "no second event came before the next change"
    );
    event
}

#[test]
fn deleting_the_window_of_a_sizing_client_sizes_its_next_window_in_the_same_change() {
    let s = start(&[]);
    let mut client = two_windows_and_a_wide_client(&s);
    let before = s.doc();
    assert_eq!(windows(&before)[1]["cols"], json!(80));
    s.delete("/windows/window_1").ok();
    let event = assert_one_event_for_one_revision(&s, &mut client, &before);
    let moved = windows(&event)[0];
    assert_eq!(
        (&moved["id"], &moved["cols"], &moved["rows"]),
        (&json!("window_2"), &json!(100), &json!(30))
    );
}

#[test]
fn selecting_another_window_sizes_it_in_the_same_change_as_the_focus() {
    let s = start(&[]);
    let mut client = two_windows_and_a_wide_client(&s);
    let before = s.doc();
    client.send(&json!({"type": "select", "pane": "pane_2"}));
    let event = assert_one_event_for_one_revision(&s, &mut client, &before);
    let moved = windows(&event)[1];
    assert_eq!((&moved["cols"], &moved["rows"]), (&json!(100), &json!(30)));
}

#[test]
fn a_title_change_moves_no_revision_and_a_pop_restores_the_pushed_title() {
    let s = start(&[]);
    let pane =
        s.pane("printf READY; read x; stty raw -echo; printf '\\033]0;changed\\007'; exec cat");
    s.screen_has(&pane, "READY");
    assert_eq!(s.row(&pane)["title"], "");
    let before = s.doc();
    s.text(&pane, "\n");
    s.wait_row(&pane, "the title", |row| row["title"] == "changed");
    assert_eq!(s.doc()["revision"], before["revision"]);
    assert_eq!(s.put(&before)["revision"], before["revision"]);
    s.text(&pane, "\x1b[22;0t\x1b]2;second\x07");
    s.wait_row(&pane, "the second title", |row| row["title"] == "second");
    s.text(&pane, "\x1b[23;0t");
    s.wait_row(&pane, "the restored title", |row| row["title"] == "changed");
    let path = format!("/panes/{pane}");
    assert_eq!(s.ko(&["api", &path], "").json()["title"], "changed");
}
