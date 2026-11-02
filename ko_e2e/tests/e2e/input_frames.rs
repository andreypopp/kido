use std::io::Write;

use serde_json::json;

use crate::harness::{masked_frame, start};

fn check_input_frames(split: bool) {
    let s = start(&[]);
    let pane = s.pane("printf 'INPUT-READY\\n'; exec /bin/sh");
    let mut view = s.ws(&format!("/panes/{pane}/view"));
    view.ready("INPUT-READY");
    let mut burst = Vec::new();
    let mut cut = 0;
    for (i, c) in b"echo abc\r".iter().enumerate() {
        let (mut key, mut codepoint, mut text) = (
            20 + i32::from(*c) - 97,
            i32::from(*c),
            char::from(*c).to_string(),
        );
        if *c == b' ' {
            key = 63;
        }
        if *c == b'\r' {
            key = 58;
            codepoint = 0;
            text = String::new();
        }
        let payload = json!(["input", ["key", {"action": "press", "key": key, "mods": 0, "unshifted_codepoint": codepoint, "text": text, "composing": false}]]);
        if i == 4 {
            cut = burst.len() + 3;
        }
        burst.extend(masked_frame(payload.to_string().as_bytes()));
    }
    if split {
        view.raw().write_all(&burst[..cut]).unwrap();
        view.output("echo");
        view.raw().write_all(&burst[cut..]).unwrap();
    } else {
        view.raw().write_all(&burst).unwrap();
    }
    view.output("\r\nabc\r\n");
}

#[test]
fn view_input_frames_in_one_write() {
    check_input_frames(false);
}

#[test]
fn view_input_frame_split_across_writes() {
    check_input_frames(true);
}
