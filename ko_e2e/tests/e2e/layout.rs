use serde_json::{Value, json};

use crate::harness::{Server, sh, start};

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
    assert_eq!(
        swapped["revision"].as_u64(),
        Some(equalized["revision"].as_u64().unwrap() + 1)
    );
    ptys_follow(&s, &swapped);

    s.delete("pane_3");
    let killed = s.doc();
    assert_eq!(tree(&killed), "h[2:39x24 1:40x24]");
    assert_eq!(
        killed["revision"].as_u64(),
        Some(swapped["revision"].as_u64().unwrap() + 1)
    );
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

    let listed = s.ko(&["panes", "--json"], "").json();
    assert_eq!(listed.as_array().map(Vec::len), Some(7));
    assert_eq!(
        serde_json::from_str::<Value>(&s.request("GET", "/panes", None, 200)).unwrap(),
        listed
    );
    let table = s.ko(&["panes"], "").ok();
    assert!(
        table.starts_with("PANE  ") && table.lines().count() == 8 && table.contains("running"),
        "{table}"
    );
}

#[test]
fn a_stale_revision_gets_409_and_the_current_document_and_the_retry_lands() {
    let s = start(&[]);
    let first = s.edit(|layout| {
        layout["sessions"] = json!([{"name": "a", "windows": [{"name": "w", "tree": new()}]}]);
    });
    let stale = json!({"revision": 0, "layout": first["layout"]});
    let (status, body) = s.exchange("PUT", "/layout", &s.headers(), stale.to_string().as_bytes());
    assert_eq!(status, 409);
    assert_eq!(serde_json::from_slice::<Value>(&body).unwrap(), s.doc());

    let renamed = json!({"revision": 0, "layout": {"sessions": [{"id": "session_1", "name": "b",
        "windows": [{"id": "window_1", "name": "w", "tree": old("pane_1")}]}]}});
    let landed = s.put(&renamed);
    assert_eq!(landed["revision"].as_u64(), Some(2));
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
    assert_eq!(s.doc(), landed);
}
