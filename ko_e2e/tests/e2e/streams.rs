use serde_json::json;

use crate::harness::{decode, size, start};

#[test]
fn stalled_view_skips() {
    let mut s = start(&[]);
    let (mut c, _) = s.client("");
    let p = s.pane(
        "printf READY; IFS= read -r start; head -c 8388608 /dev/zero | tr '\\000' x; printf LAST",
    );
    let mut v = s.ws(&format!("/panes/{p}/view"));
    v.ready("READY");
    s.text(&p, "\n");
    c.event("dead");
    v.event("skipped");
    let (data, _) = v.snapshot();
    assert!(
        decode(&data, false).screen.contains("LAST"),
        "skip snapshot is not current"
    );
}

#[test]
fn detach_keeps_kitty_input() {
    let mut s = start(&[]);
    let record = s.dir.join("input");
    let p = s.pane(&format!(
        "stty raw -echo; printf '\x1b[=3;1uREADY'; tee '{}'",
        record.display()
    ));
    let (c, _) = s.client(&p);
    let view = format!("/panes/{p}/view?history=all");
    let mut v = s.ws(&view);
    v.ready("READY");
    let key = json!(["input", ["key", {"action": "press", "key": 20, "mods": 2, "unshifted_codepoint": 97, "text": "a", "composing": false}]]);
    v.send(&key);
    v.type_text("FIRST");
    v.output("FIRST");
    drop(c);
    drop(v);
    let _c = s.client(&p);
    let mut v = s.ws(&view);
    v.snapshot();
    v.send(&key);
    v.type_text("BARRIER");
    v.output("BARRIER");
    let input = std::fs::read(&record).unwrap();
    assert_eq!(
        input, b"\x1b[97;5uFIRST\x1b[97;5uBARRIER",
        "pty input: {input:?}"
    );
}

#[test]
fn partial_resize_snapshot() {
    let mut s = start(&[]);
    let p = s.pane("printf READY; cat");
    let (mut c, _) = s.client(&p);
    let mut v = s.ws(&format!("/panes/{p}/view?history=none"));
    v.snapshot();
    c.send(&json!(["size", size(51, 13)]));
    let (data, _) = v.snapshot();
    assert_eq!(decode(&data, false).rows, 13, "partial resize");
}
