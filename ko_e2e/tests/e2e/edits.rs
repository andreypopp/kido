use serde_json::{Value, json};

use crate::harness::start;
use crate::layout::{consistent, new, put_edit, shell, split, windows};

fn panes(document: &Value) -> usize {
    fn leaves(node: &Value) -> usize {
        node["children"]
            .as_array()
            .map_or(1, |children| children.iter().map(leaves).sum())
    }
    windows(document)
        .iter()
        .map(|window| leaves(&window["tree"]) + window["floats"].as_array().unwrap().len())
        .sum()
}

#[test]
fn every_kind_of_edit_puts_a_document_that_the_server_keeps_as_it_is() {
    let s = start(&[]);
    s.put(&json!({"layout": {"sessions": [
        {"name": "main", "windows": [
            {"name": "w", "tree": split("h", vec![new(), split("v", vec![new(), new()])]),
             "floats": [{"pane": {"new": shell()}, "x": 3, "y": 2, "cols": 20, "rows": 6}]},
            {"name": "x", "tree": new()}]}]}}));
    let edits = [
        (
            json!({"type": "split", "pane": "pane_2", "axis": "v", "new": {}}),
            1,
        ),
        (
            json!({"type": "resize_by", "pane": "pane_1", "edge": "right", "delta": 5}),
            0,
        ),
        (
            json!({"type": "resize_by", "pane": "pane_3", "edge": "top", "delta": 4}),
            0,
        ),
        (
            json!({"type": "resize_pair", "first": "pane_1", "second": "pane_2", "first_size": 20}),
            0,
        ),
        (json!({"type": "equalize", "pane": "pane_3"}), 0),
        (
            json!({"type": "zoom", "window": "window_1", "pane": "pane_2"}),
            0,
        ),
        (json!({"type": "zoom", "window": "window_1"}), 0),
        (json!({"type": "toggle_zoom", "pane": "pane_2"}), 0),
        (json!({"type": "toggle_zoom", "pane": "pane_2"}), 0),
        (
            json!({"type": "swap", "pane": "pane_1", "other": "pane_5"}),
            0,
        ),
        (
            json!({"type": "unfloat", "pane": "pane_4", "target": "pane_2", "edge": "left"}),
            0,
        ),
        (
            json!({"type": "float", "pane": "pane_3", "x": 5, "z": 2}),
            0,
        ),
        (
            json!({"type": "float", "pane": "pane_3", "z": 9, "title": "t", "border": true}),
            0,
        ),
        (
            json!({"type": "dock", "pane": "pane_6", "target": "pane_1", "edge": "top"}),
            0,
        ),
        (
            json!({"type": "dock_window", "pane": "pane_3", "window": "window_1", "edge": "bottom"}),
            0,
        ),
        (
            json!({"type": "add_window", "session": "session_1", "after": "window_1", "new": {}}),
            1,
        ),
        (
            json!({"type": "add_session", "name": "other", "new": {}}),
            1,
        ),
        (
            json!({"type": "rename_window", "window": "window_1", "name": "renamed"}),
            0,
        ),
        (
            json!({"type": "rename_session", "session": "session_1", "name": "main2"}),
            0,
        ),
        (
            json!({"type": "reorder_windows", "session": "session_1", "order": ["window_3", "window_1"]}),
            0,
        ),
        (
            json!({"type": "reorder_sessions", "order": ["session_2"]}),
            0,
        ),
    ];
    let mut count = panes(&s.doc());
    for (edit, added) in edits {
        let done = put_edit(&s, &edit);
        count += added;
        assert_eq!(panes(&done), count, "{edit}");
        for window in windows(&done) {
            consistent(&window["tree"]);
        }
        let again = s.put(&done);
        assert_eq!(again, done, "a put of the result is a fixed point: {edit}");
    }
}
