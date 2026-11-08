use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};

use ko_sys::pid::{Pid, signal_descendant};
use ko_sys::signal::Signal;
use serde_json::json;

use crate::harness::{DEADLINE, Dir, HEAVY, Server, quote, run_ko, start, text_of};
use crate::layout::{put_edit, window_size, windows};
use crate::outer::{DOWN_PRESS_RELEASE, FOCUS_IN, FOCUS_OUT, Keys, Outer, UP};

#[test]
fn the_client_lists_a_child_pane_under_its_parent_indented_one_column() {
    let s = start(&[]);
    let title = |name: &str| {
        serde_json::json!({
            "command": {"type": "shell", "command": format!("printf '\\033]0;{name}\\007'; {}; exec cat", crate::harness::PRINT_TOKEN)},
        })
    };
    let parent = s.new_pane(title("parent"));
    s.screen_has(&parent, "TOKEN<");
    let other = s.new_pane(title("other"));
    s.screen_has(&other, "TOKEN<");
    let mut request = title("child");
    request["parent"] = serde_json::json!(parent);
    request["close"] = serde_json::json!("on_exit");
    let child = s.new_pane(request);
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
    assert!(s.has_pane(&child));
    o.click(5, at("2   child") + 1);
    o.line("CHILD-SELECTED");
    s.screen_has(&child, "CHILD-SELECTED");
    let before = s.doc();
    o.prefix("%");
    o.line("CHILD-STILL-USABLE");
    s.screen_has(&child, "CHILD-STILL-USABLE");
    assert_eq!(s.doc()["layout"], before["layout"]);
    assert_eq!(s.doc()["revision"], before["revision"]);
    o.prefix("p");
    o.contains(&format!("TOKEN<{}>", s.token(&other).unwrap()));
    o.line("PREVIOUS-SKIPS-CHILD");
    s.screen_has(&other, "PREVIOUS-SKIPS-CHILD");
    o.prefix("n");
    o.contains(&format!("TOKEN<{}>", s.token(&parent).unwrap()));
    o.line("NEXT-WRAPS-TO-ROOT");
    s.screen_has(&parent, "NEXT-WRAPS-TO-ROOT");
    o.prefix("n");
    o.contains(&format!("TOKEN<{}>", s.token(&other).unwrap()));
    o.line("NEXT-SKIPS-CHILD");
    s.screen_has(&other, "NEXT-SKIPS-CHILD");
    o.detach();
}

const PANE_X: usize = 25;

const SPLIT_ECHO: &str = r#"import os,sys,tty
tty.setraw(0)
label=sys.argv[1]
for i in range(80): os.write(1, ('HISTORY-'+label+'-%03d\r\n'%i).encode())
os.write(1, ('READY-'+label).encode())
while True:
 b=os.read(0,1)
 os.write(1, ('\r\n'+label+'-KEY-'+b.hex()).encode())
"#;

fn split_echo_window(s: &Server) {
    use serde_json::json;
    s.pane(&format!("exec python3 -u -c {} one", quote(SPLIT_ECHO)));
    for (pane, axis, label) in [("pane_1", "h", "two"), ("pane_2", "v", "three")] {
        let edit = json!({"type": "split", "pane": pane, "axis": axis, "new": {"command": {"type": "shell", "command": format!("exec python3 -u -c {} {label}", quote(SPLIT_ECHO))}}});
        put_edit(s, &edit);
    }
}

#[test]
fn client_copy_mode_copies_and_pastes() {
    let s = start(&[]);
    let fixture = r#"import os,tty
tty.setraw(0)
os.write(1,b'\x1b[?2004hCOPY-one\r\nCOPY-two\r\nREADY-copy')
b=b''
while True:
 c=os.read(0,1)
 if c==b'!': os.write(1,b'\r\nOUTPUT-during-copy'); continue
 if c==b'#':
  os.write(1,b'\x1b[3J\x1b[H\x1b[2J')
  for i in range(80): os.write(1, ('%s-%02d\r\n'%('SEARCH-hit' if i in (10,50) else 'history',i)).encode())
  os.write(1,b'READY-search'); continue
 b+=c
 if b.endswith(b'\x1b[201~'):
  os.write(1,b'\r\nPASTED:'+b.hex().encode()); b=b''
"#;
    let pane = s.pane(&format!("exec python3 -u -c {}", quote(fixture)));
    let o = Outer::new(&s.dir, Keys::Extended);
    o.attach("cat");
    o.contains("READY-copy");
    o.prefix("[");
    o.contains("[copy]");
    o.raw("kVy");
    o.wait("copy writes OSC 52", || o.clipboard() == b"COPY-two");
    o.gone("[copy]");
    o.prefix("]");
    let pasted = format!("PASTED:{}", hex("\x1b[200~COPY-two\x1b[201~"));
    o.contains(&pasted);
    o.prefix("[");
    o.contains("[copy]");
    o.raw("k");
    o.quiet();
    let before = o.screen();
    let cursor = o.cursor();
    assert!(!cursor.0, "copy mode hides the real cursor");
    let inverse_cursor = || {
        assert!(
            o.cell(PANE_X + pasted.len(), 2)
                .style
                .attrs
                .has(ko_vt::render::Attribute::Inverse)
        )
    };
    inverse_cursor();
    s.text(&pane, "!");
    s.screen_has(&pane, "OUTPUT-during-copy");
    o.quiet();
    assert_eq!(
        o.screen(),
        before,
        "output must not move the frozen viewport"
    );
    assert_eq!(o.cursor(), cursor);
    inverse_cursor();
    o.raw("q");
    o.contains("OUTPUT-during-copy");
    o.gone("[copy]");
    s.text(&pane, "#");
    o.contains("READY-search");
    o.prefix("[");
    o.raw("?SEARCH-hit\r");
    o.contains("[50/");
    o.raw("v$y");
    o.wait("backward search places the cursor at match 50", || {
        o.clipboard() == b"SEARCH-hit-50"
    });
    o.gone("[copy]");
    o.prefix("[");
    o.raw("?SEARCH-hit\r");
    o.contains("[50/");
    o.raw("n");
    o.contains("[10/");
    o.raw("v$y");
    o.wait("repeat search places the cursor at match 10", || {
        o.clipboard() == b"SEARCH-hit-10"
    });
    o.gone("[copy]");
    o.prefix("[");
    o.contains("[copy]");
    o.resize(125, 30);
    o.gone("[copy]");
    o.detach();
}

#[test]
fn client_two_clients_one_window_and_the_sizer() {
    let s = start(&[]);
    split_echo_window(&s);
    let large = Outer::new(&s.dir, Keys::Extended);
    large.resize(120, 31);
    large.attach("cat");
    large.contains("READY-one");
    large.raw(FOCUS_OUT);
    let small = Outer::new(&s.dir, Keys::Extended);
    small.resize(105, 21);
    small.attach("cat");
    small.contains("READY-one");
    small.wait("the smaller focused client sizes the split window", || {
        let d = s.doc();
        window_size(&d, 0) == (80, 20)
    });
    let d = s.doc();
    let first = windows(&d)[0]["tree"]["children"][0]["cols"]
        .as_u64()
        .unwrap() as usize;
    large.wait("the larger client uses the server's divider column", || {
        large.cell(PANE_X + first, 0).text == "│"
    });
    large.wait("the smaller window is padded", || {
        large.cell(PANE_X + 80, 0).text.trim().is_empty()
    });
    assert_eq!(small.cell(PANE_X + first, 0).text, "│");
    small.detach();
    large.click(3, 2);
    large.wait("the remaining client's select claims the window", || {
        let d = s.doc();
        window_size(&d, 0) == (95, 30)
    });
    large.detach();
}

#[test]
fn client_split_dividers_input_mouse_wheel_and_zoom() {
    use serde_json::json;
    let s = start(&[]);
    split_echo_window(&s);
    let o = Outer::new(&s.dir, Keys::Extended);
    o.resize(105, 25);
    o.attach("cat");
    o.contains("READY-one");
    o.contains("READY-two");
    o.contains("READY-three");
    let d = s.doc();
    let w = windows(&d)[0];
    let x = PANE_X + w["tree"]["children"][0]["cols"].as_u64().unwrap() as usize;
    let y = w["tree"]["children"][1]["children"][0]["rows"]
        .as_u64()
        .unwrap() as usize;
    o.wait("split dividers and their junction", || {
        o.cell(x, 0).text == "│" && o.cell(x, y).text == "├" && o.cell(x + 1, y).text == "─"
    });
    o.raw("a");
    o.contains("one-KEY-61");
    o.click(x + 3, 2);
    o.raw("b");
    o.contains("two-KEY-62");
    let before = o.lines()[0].clone();
    o.wheel_up(PANE_X + 2, 2);
    o.wait("the wheel scrolls the pane under the pointer", || {
        o.lines()[0] != before
    });
    o.contains("two-KEY-62");
    let zoom = json!({"type": "toggle_zoom", "pane": "pane_3"});
    put_edit(&s, &zoom);
    o.wait("zoom removes both dividers", || {
        o.cell(x, 0).text != "│" && o.cell(x, y).text != "├"
    });
    o.gone("READY-two");
    o.raw("c");
    o.contains("three-KEY-63");
    put_edit(&s, &zoom);
    o.wait("unzoom restores the dividers", || {
        o.cell(x, 0).text == "│" && o.cell(x, y).text == "├" && o.cell(x + 1, y).text == "─"
    });
    o.contains("READY-two");
    put_edit(&s, &zoom);
    o.wait("zoom before a sidebar jump", || o.cell(x, y).text != "├");
    put_edit(
        &s,
        &json!({"type": "split", "pane": "pane_2", "axis": "v", "new": {"command": {"type": "shell", "command": "printf '\\033]0;new-during-unzoom\\007'; exec cat"}}}),
    );
    o.click(3, 2);
    o.raw("d");
    o.contains("one-KEY-64");
    o.contains("new-during-unzoom");
    o.wait("a sidebar jump unzooms the hidden pane", || {
        windows(&s.doc())[0]["zoom"].is_null() && o.cell(x, y).text == "├"
    });
    o.detach();
}

#[test]
fn client_float_toggle_and_break_pane() {
    let s = start(&[]);
    s.pane(&format!("exec python3 -u -c {} one", quote(SPLIT_ECHO)));
    let o = Outer::new(&s.dir, Keys::Extended);
    o.resize(105, 25);
    o.attach("cat");
    o.contains("READY-one");
    o.prefix("%");
    o.line(&format!("exec python3 -u -c {} two", quote(SPLIT_ECHO)));
    o.contains("READY-two");
    o.prefix("*");
    o.wait("the active pane floats with a border", || {
        let d = s.doc();
        let w = &windows(&d)[0];
        let f = &w["floats"][0];
        if f["pane"] != "pane_2" || f["border"] != true {
            return false;
        }
        let x = PANE_X + (f["x"].as_u64().unwrap() as usize).saturating_sub(1);
        let y = (f["y"].as_u64().unwrap() as usize).saturating_sub(1);
        o.cell(x, y).text == "┌"
    });
    o.raw("a");
    o.contains("two-KEY-61");
    o.prefix("*");
    o.wait("the float docks beside the tiled pane", || {
        let d = s.doc();
        let w = &windows(&d)[0];
        w["floats"].as_array().unwrap().is_empty() && w["tree"]["children"][1]["pane"] == "pane_2"
    });
    o.prefix("!");
    o.wait("break selects the new window after the old one", || {
        let d = s.doc();
        let ws = windows(&d);
        ws.len() == 2
            && ws[0]["tree"]["pane"] == "pane_1"
            && ws[1]["tree"]["pane"] == "pane_2"
            && ws[1]["name"] == ws[0]["name"]
            && o.lines()
                .iter()
                .any(|line| line.starts_with("[test] 0:test- 1:test*"))
    });
    o.raw("b");
    o.contains("two-KEY-62");
}

#[test]
fn client_splits_zoom_and_directional_select() {
    let s = start(&[]);
    s.pane(&format!("exec python3 -u -c {} one", quote(SPLIT_ECHO)));
    let o = Outer::new(&s.dir, Keys::Extended);
    o.resize(105, 25);
    o.attach("cat");
    o.contains("READY-one");
    o.prefix("%");
    o.line(&format!("exec python3 -u -c {} two", quote(SPLIT_ECHO)));
    o.contains("READY-two");
    o.prefix("\"");
    o.line(&format!("exec python3 -u -c {} three", quote(SPLIT_ECHO)));
    o.contains("READY-three");
    let d = s.doc();
    let tree = &windows(&d)[0]["tree"];
    assert_eq!(crate::layout::tree(&d), "h[1:40x24 v[2:39x12 3:39x11]]");
    let x = PANE_X + tree["children"][0]["cols"].as_u64().unwrap() as usize;
    let y = tree["children"][1]["children"][0]["rows"].as_u64().unwrap() as usize;
    o.wait("the new splits have joined dividers", || {
        o.cell(x, 0).text == "│" && o.cell(x, y).text == "├" && o.cell(x + 1, y).text == "─"
    });
    for (key, label, letter) in [
        ("\x1b[D", "one", "a"),
        ("\x1b[C", "three", "b"),
        ("h", "one", "c"),
        ("l", "three", "d"),
        ("\x1b[104;5u", "one", "e"),
        ("\x1b[108;5u", "three", "f"),
    ] {
        o.prefix(key);
        o.raw(letter);
        o.contains(&format!("{label}-KEY-{}", hex(letter)));
    }
    let inactive = o.cell(x, 0).style.fg;
    o.prefix("\x1b[A");
    o.wait(
        "the first selection reply changes the active divider",
        || o.cell(x, 0).style.fg != inactive,
    );
    o.raw("\x1b[D");
    o.raw("g");
    o.contains("one-KEY-67");
    o.prefix(";");
    o.raw("i");
    o.contains("two-KEY-69");
    o.prefix("o");
    o.raw("m");
    o.contains("three-KEY-6d");
    o.prefix("z");
    o.wait("zoom hides the dividers", || {
        windows(&s.doc())[0]["zoom"] == "pane_3" && o.cell(x, y).text != "├"
    });
    o.prefix("h");
    o.raw("n");
    o.contains("one-KEY-6e");
    o.wait("directional selection ends zoom", || {
        windows(&s.doc())[0]["zoom"].is_null() && o.cell(x, y).text == "├"
    });
    o.prefix("z");
    o.wait("zoom the first pane", || {
        windows(&s.doc())[0]["zoom"] == "pane_1"
    });
    o.prefix("z");
    o.wait("unzoom", || windows(&s.doc())[0]["zoom"].is_null());
    o.prefix("}");
    o.wait("swap with next pane", || {
        windows(&s.doc())[0]["tree"]["children"][0]["pane"] == "pane_2"
    });
    o.prefix("{");
    o.wait("swap back", || {
        windows(&s.doc())[0]["tree"]["children"][0]["pane"] == "pane_1"
    });
    let first_cols = || {
        windows(&s.doc())[0]["tree"]["children"][0]["cols"]
            .as_u64()
            .unwrap()
    };
    o.prefix("\x1b[1;5D");
    o.raw("\x1b[1;5D");
    o.wait("two resize presses move the divider twice", || {
        first_cols() == (x - PANE_X - 2) as u64
    });
    o.prefix("\x1b[1;3D");
    o.wait("alt resize moves the divider five cells", || {
        first_cols() == (x - PANE_X - 7) as u64
    });
    o.prefix("E");
    o.wait("equalize restores the divider", || {
        first_cols() == (x - PANE_X) as u64
    });
    o.prefix("z");
    o.wait("zoom before splitting", || {
        windows(&s.doc())[0]["zoom"] == "pane_1"
    });
    o.prefix("%");
    o.line(&format!("exec python3 -u -c {} four", quote(SPLIT_ECHO)));
    o.contains("READY-four");
    o.raw("p");
    o.contains("four-KEY-70");
    assert!(windows(&s.doc())[0]["zoom"].is_null());
    put_edit(&s, &serde_json::json!({"type":"float", "pane":"pane_4"}));
    o.wait("the selected pane is floating", || {
        !windows(&s.doc())[0]["floats"]
            .as_array()
            .unwrap()
            .is_empty()
    });
    let before = crate::layout::tree(&s.doc());
    o.prefix("%");
    o.raw("q");
    o.contains("four-KEY-71");
    assert_eq!(crate::layout::tree(&s.doc()), before);
    o.detach();
}

#[test]
fn client_resize_mode_and_divider_drag() {
    let s = start(&[]);
    split_echo_window(&s);
    let o = Outer::new(&s.dir, Keys::Extended);
    o.resize(105, 25);
    o.attach("cat");
    o.contains("READY-one");
    let first_cols = || {
        windows(&s.doc())[0]["tree"]["children"][0]["cols"]
            .as_u64()
            .unwrap() as usize
    };
    let before = first_cols();
    o.prefix("R");
    o.contains("[resize]");
    o.raw("hhh\r");
    o.wait("resize mode moves the divider three cells", || {
        first_cols() == before - 3
    });
    o.raw("a");
    o.contains("one-KEY-61");

    let before = first_cols();
    let x = PANE_X + before;
    let modes = o.modes();
    assert!(
        modes.split(',').any(|mode| matches!(mode, "1002" | "1003")),
        "divider drag needs button-motion reports; outer modes: {modes}"
    );
    o.press(x + 1, 3);
    o.raw(&format!("\x1b[<32;{};3M\x1b[<0;{};3m", x + 5, x + 5));
    o.wait("drag moves the divider four cells", || {
        first_cols() == before + 4
    });
    o.raw("c");
    o.contains("one-KEY-63");
    o.raw(&format!("\x1b[<32;{};3M", x + 8));
    o.raw("d");
    o.contains("one-KEY-64");
    assert_eq!(first_cols(), before + 4);

    let x = PANE_X + first_cols();
    o.press(x + 1, 3);
    o.raw(&format!("\x1b[<32;{};3M", x + 3));
    o.wait("drag without release moves the divider", || {
        first_cols() == before + 6
    });
    o.click(PANE_X + 3, 3);
    o.raw("e");
    o.contains("one-KEY-65");
    o.raw(&format!("\x1b[<32;{};3M", x + 8));
    o.raw("f");
    o.contains("one-KEY-66");
    assert_eq!(first_cols(), before + 6);

    put_edit(
        &s,
        &serde_json::json!({"type":"split", "pane":"pane_1", "axis":"h", "new":{"command":{"type":"shell","command":format!("exec python3 -u -c {} four", quote(SPLIT_ECHO))}}}),
    );
    o.contains("READY-four");
    let sizes = || {
        let d = s.doc();
        let children = windows(&d)[0]["tree"]["children"].as_array().unwrap();
        (
            children[0]["cols"].as_u64().unwrap() as usize,
            children[1]["cols"].as_u64().unwrap() as usize,
        )
    };
    let (first, second) = sizes();
    let divider = PANE_X + first + 1 + second;
    o.press(divider + 1, 3);
    put_edit(
        &s,
        &serde_json::json!({"type":"resize_pair", "first":"pane_1", "second":"pane_4", "first_size":first - 2}),
    );
    o.wait("the earlier divider changes the drag origin", || {
        o.cell(PANE_X + first - 2, 0).text == "│"
    });
    o.raw(&format!(
        "\x1b[<32;{};3M\x1b[<0;{};3m",
        divider + 4,
        divider + 4
    ));
    o.wait(
        "the refreshed grip puts the divider under the pointer",
        || {
            let (a, b) = sizes();
            PANE_X + a + 1 + b == divider + 3
        },
    );
    o.detach();
}

#[test]
fn client_mouse_release_stays_with_the_pressed_pane() {
    use serde_json::json;
    let s = start(&[]);
    let fixture = r#"import os,sys,tty
tty.setraw(0)
label=sys.argv[1]
os.write(1, ('\x1b[?1000h\x1b[?1006hREADY-'+label).encode())
b=b''
while True:
 b+=os.read(0,1)
 if b[-1:] in (b'M',b'm'):
  os.write(1, ('\r\n'+label+'-MOUSE:'+b.hex()).encode())
  b=b''
"#;
    s.pane(&format!("exec python3 -u -c {} A", quote(fixture)));
    put_edit(
        &s,
        &json!({"type": "split", "pane": "pane_1", "axis": "h", "new": {"command": {"type": "shell", "command": format!("exec python3 -u -c {} B", quote(fixture))}}}),
    );
    let o = Outer::new(&s.dir, Keys::Extended);
    o.resize(105, 25);
    o.attach("cat");
    o.contains("READY-A");
    o.contains("READY-B");
    let d = s.doc();
    let width = windows(&d)[0]["tree"]["children"][0]["cols"]
        .as_u64()
        .unwrap() as usize;
    o.press(PANE_X + 3, 3);
    o.raw(&format!("\x1b[<0;{};3m", PANE_X + width + 4));
    o.contains(&format!("A-MOUSE:{}", hex(&format!("\x1b[<0;{width};3m"))));
    o.gone("B-MOUSE:");
    o.detach();
}

fn pane_text(line: &str) -> String {
    line.chars().skip(PANE_X).collect()
}

fn count_sequences(data: &[u8], opener: &[u8], digits: &[u8]) -> usize {
    let mut count = 0;
    let mut at = 0;
    while at < data.len() {
        if data[at..].starts_with(opener) {
            let mut end = at + opener.len();
            while end < data.len() && digits.contains(&data[end]) {
                end += 1;
            }
            if data.get(end) == Some(&b'u') {
                count += 1;
            }
            at += opener.len();
        } else {
            at += 1;
        }
    }
    count
}

fn pager_fixture(dir: &Path) -> (PathBuf, PathBuf) {
    let path = dir.join("pager");
    let record = dir.join("pager-path");
    let script = format!(
        "#!/bin/sh\nprintf '%s' \"$1\" > {}\nprintf '\\nPAGER-OPEN\\n'\nread answer\n",
        quote(text_of(&record))
    );
    std::fs::write(&path, script).unwrap();
    std::fs::set_permissions(&path, std::os::unix::fs::PermissionsExt::from_mode(0o700)).unwrap();
    (path, record)
}

fn hex(text: &str) -> String {
    text.bytes().map(|byte| format!("{byte:02x}")).collect()
}

fn input(text: &str) -> String {
    format!("INPUT:{}", hex(text))
}

fn pane_saw_click(col: usize) -> String {
    input(&format!("\x1b[<0;{col};5M"))
}

fn read_file(path: &Path) -> Option<String> {
    std::fs::read_to_string(path).ok()
}

const INTERACTIVE_FIXTURE: &str = r#"import os,tty
tty.setraw(0)
os.write(1,b'\x1b]0;fixture\x07BASE')
while True:
 c=os.read(0,1)
 if c==b'o': os.write(1,b'\r\nOUTPUT-WITHOUT-INPUT\r\n')
 if c==b'f':
  w,h=os.get_terminal_size()
  for y in range(h): os.write(1,('\x1b[%d;1H'%(y+1)+'P'*w).encode())
 if c==b'h': os.write(1,b'\x1b[?2026h\x1b[1;1HHOLD-CHANGED')
 if c==b'r': os.write(1,b'\x1b[?2026l')
"#;

fn interactive_fixture(s: &Server) -> String {
    s.pane(&format!(
        "exec python3 -u -c {}",
        quote(INTERACTIVE_FIXTURE)
    ))
}

#[test]
fn client_lifecycle() {
    let s = start(&[]);
    let p1 = s.pane("printf '\x1b]0;one\x07pane-one\\n'; exec /bin/sh");
    s.pane("printf '\x1b]0;two\x07pane-two\\n'; exec /bin/sh");
    s.pane("printf '\x1b]0;three\x07pane-three\\n'; exec /bin/sh");
    let o = Outer::new(&s.dir, Keys::Extended);
    let (pager, record) = pager_fixture(&o.dir);
    o.attach(text_of(&pager));
    o.contains("pane-one");
    o.wait("outer mouse reporting on", || o.mouse_reporting());
    o.contains("1  one");

    o.prefix("\x13");
    o.gone("1  one");
    o.prefix("s");
    o.contains("1  one");

    o.raw(DOWN_PRESS_RELEASE);
    o.enter();
    o.contains("pane-two");
    o.prefix("p");
    o.contains("pane-one");
    o.prefix("n");
    o.contains("pane-two");
    o.prefix("p");
    o.contains("pane-one");
    o.click(3, 3);
    o.contains("pane-two");

    o.prefix("e");
    o.contains("PAGER-OPEN");
    let file = PathBuf::from(std::fs::read_to_string(&record).unwrap());
    let mode =
        std::os::unix::fs::PermissionsExt::mode(&std::fs::metadata(&file).unwrap().permissions());
    assert_eq!(mode & 0o777, 0o600, "pager file mode");
    o.line("done");
    o.contains("pane-two");
    o.wait("pager file removed", || !file.exists());

    o.prefix("c");
    o.wait("new pane listed", || s.pane_pids().len() == 4);
    o.ctrl('d');
    o.wait("exited pane removed", || s.pane_pids().len() == 3);

    o.detach();
    s.text(&p1, "printf 'AFTER-DETACH\\n'\n");
    o.attach("");
    o.contains("AFTER-DETACH");
    o.prefix("e");
    o.contains("(END)");
    o.raw("q");
    o.wait("outer mouse reporting on after the default pager", || {
        o.mouse_reporting()
    });
    o.detach();
}

#[test]
fn client_can_view_a_failed_start_and_switch_to_a_live_pane() {
    let s = start(&[]);
    let failed =
        s.new_pane(json!({"command": {"type": "argv", "argv": ["/no/such/kido-command"]}}));
    s.screen_has(&failed, "ko: exec: No such file or directory");
    s.new_pane(json!({"command": {"type": "argv", "argv": ["/bin/sh"]}, "env": [{"name": "PS1", "value": "LIVE> "}]}));
    let o = Outer::new(&s.dir, Keys::Extended);
    o.attach("cat");
    o.contains("[failed: exec: No such file or directory (os error 2)");
    o.contains("ko: exec: No such file or directory");
    o.prefix("n");
    o.contains("LIVE>");
    o.line("printf 'SEC%s\\n' OND");
    o.contains("SECOND");
    o.detach();
}

#[test]
fn client_stays_attached_when_the_shown_shell_exits() {
    let s = start(&[]);
    let first = s.new_pane(
        json!({"command": {"type": "argv", "argv": ["/bin/sh"]}, "env": [{"name": "PS1", "value": "FIRST> "}]}),
    );
    s.new_pane(
        json!({"command": {"type": "argv", "argv": ["/bin/sh"]}, "env": [{"name": "PS1", "value": "SECOND> "}]}),
    );
    let o = Outer::new(&s.dir, Keys::Extended);
    o.attach("cat");
    o.contains("FIRST>");
    o.ctrl('d');
    o.wait("the first shell to leave", || !s.has_pane(&first));
    o.contains("SECOND>");
    o.line("printf 'STILL-%s\\n' ATTACHED");
    o.contains("STILL-ATTACHED");
    o.detach();
}

#[test]
fn client_removing_the_only_pane_opens_a_replacement_that_takes_input() {
    let s = start(&[]);
    s.new_pane(json!({"close": "keep", "command": {"type": "shell", "command": "printf 'last words\\n'; exit 3"}}));
    let o = Outer::new(&s.dir, Keys::Extended);
    o.attach("cat");
    o.contains("[exited 3 \u{2014} Ctrl+D to remove]");
    o.ctrl('d');
    o.wait("the replacement pane", || {
        s.pane_pids()
            .iter()
            .map(|(id, _)| id.as_str())
            .eq(["pane_2"])
    });
    o.line("printf 'REPL-%s\\n' ACED");
    o.contains("REPL-ACED");
    o.gone("Ctrl+D to remove");
    o.detach();
}

#[test]
fn client_grouped_list_crosses_sessions_and_adds_a_window_to_the_shown_session() {
    let s = start(&[]);
    let named = |name: &str| {
        let command = format!("printf '\\033]0;{name}-title\\007pane-{name}\\n'; exec cat");
        serde_json::json!({"pane": {"new": crate::harness::sh(&command)}})
    };
    let sessions = ["alpha", "beta", "gamma"].map(
        |name| serde_json::json!({"name": name, "windows": [{"name": "w", "tree": named(name)}]}),
    );
    s.put(&serde_json::json!({"layout": {"sessions": sessions}}));
    let o = Outer::new(&s.dir, Keys::Extended);
    o.attach("cat");
    o.contains("pane-alpha");
    let rows = |o: &Outer| -> Vec<String> {
        o.lines()
            .iter()
            .take(7)
            .map(|line| {
                line.chars()
                    .take(PANE_X - 1)
                    .collect::<String>()
                    .trim()
                    .to_owned()
            })
            .collect()
    };
    o.wait("the grouped list", || {
        rows(&o)
            == [
                "alpha",
                "1  alpha-title",
                "beta",
                "2  beta-title",
                "gamma",
                "3  gamma-title",
                "",
            ]
    });
    o.prefix(")");
    o.contains("pane-beta");
    o.prefix(")");
    o.contains("pane-gamma");
    o.prefix(")");
    o.contains("pane-alpha");
    o.prefix("(");
    o.contains("pane-gamma");
    o.prefix(")");
    o.contains("pane-alpha");

    o.prefix("c");
    o.wait(
        "the new window's pane listed under the shown session",
        || {
            let rows = rows(&o);
            rows[..2] == ["alpha", "1  alpha-title"]
                && rows[2]
                    .strip_prefix("2  ")
                    .is_some_and(|title| !title.is_empty())
                && rows[3..] == ["beta", "3  beta-title", "gamma", "4  gamma-title"]
        },
    );
    let document = s.doc();
    let alpha = &document["layout"]["sessions"][0]["windows"];
    assert_eq!(alpha.as_array().map(Vec::len), Some(2));
    assert_eq!(alpha[1]["tree"]["pane"], serde_json::json!("pane_4"));
    o.detach();
}

#[derive(Debug)]
struct Resume<'a> {
    outer: &'a Outer,
    client: Pid,
    client_stopped: bool,
    shell_stopped: bool,
}

impl Drop for Resume<'_> {
    fn drop(&mut self) {
        if self.client_stopped {
            let _ = signal_descendant(self.outer.shell_pid(), self.client, Signal::Cont);
        }
        if self.shell_stopped {
            self.outer.resume_shell();
        }
    }
}

#[test]
fn client_history_and_alternate_screen() {
    let _heavy = HEAVY.lock().unwrap_or_else(|e| e.into_inner());
    let s = start(&[]);
    let history_pane = s.pane("seq 300; printf '\x1b]0;history\x07HISTORY-READY\\n'; exec cat");
    let o = Outer::new(&s.dir, Keys::Extended);
    let (pager, record) = pager_fixture(&o.dir);
    let pager = text_of(&pager);
    o.attach(pager);
    o.contains("HISTORY-READY");
    o.wheel_up(40, 5);
    o.gone("HISTORY-READY");
    o.raw("x");
    o.contains("HISTORY-READY");
    o.detach();

    o.attach(pager);
    o.contains("HISTORY-READY");
    o.prefix("e");
    o.contains("PAGER-OPEN");
    let path = std::fs::read_to_string(&record).unwrap();
    let data = std::fs::read_to_string(path).unwrap();
    let count = data
        .split('\n')
        .filter(|line| {
            line.trim()
                .parse::<u32>()
                .is_ok_and(|n| (1..=300).contains(&n))
        })
        .count();
    assert_eq!(count, 300, "history has {count} numeric lines, want 300");
    o.line("done");
    o.contains("HISTORY-READY");
    o.detach();

    s.ko(
        &["api", "-X", "DELETE", &format!("/panes/{history_pane}")],
        "",
    )
    .ok();
    let command = "seq 300; stty -icanon -echo; printf '\\033[?1049hPID\\n'; dd bs=1 count=1 >/dev/null 2>&1; stty icanon echo; printf '\\033[?1049lAFTER-ALT\\n'; exec /bin/sh";
    let alt_pane = s.pane(command);
    o.attach(pager);
    o.contains("PID");
    o.detach();
    o.attach(pager);
    o.contains("PID");
    o.raw("q");
    o.contains("AFTER-ALT");

    let _ = std::fs::remove_file(&record);
    let before = o.shown_marks(b"PAGER-OPEN");
    o.prefix("e");
    o.wait("pager started", || o.shown_marks(b"PAGER-OPEN") > before);
    let path = read_file(&record).unwrap_or_default();
    let data = read_file(Path::new(&path)).unwrap_or_default();
    assert!(
        data.contains("299"),
        "alternate screen round trip lost primary history"
    );
    o.line("done");
    o.contains("AFTER-ALT");

    let (client, shell) = (o.client_pid(), o.shell_pid());
    let mut resume = Resume {
        outer: &o,
        client,
        client_stopped: false,
        shell_stopped: false,
    };
    o.stop_shell();
    resume.shell_stopped = true;
    signal_descendant(shell, client, Signal::Stop).unwrap();
    resume.client_stopped = true;
    let producer = "for i in range(20000): print('H%05d'%i+'x'*70)";
    s.text(
        &alt_pane,
        &format!(
            "python3 -c {}; printf 'FLOOD-%s\\n' DONE\n",
            quote(producer)
        ),
    );
    o.wait("output while client is stopped", || {
        s.request(
            "GET",
            &format!("/panes/{alt_pane}/screen?format=plain"),
            None,
            200,
        )
        .contains("FLOOD-DONE")
    });
    signal_descendant(shell, client, Signal::Cont).unwrap();
    resume.client_stopped = false;
    let flooded = o.within(DEADLINE, || o.screen().contains("FLOOD-DONE"));
    assert!(
        flooded,
        "wait for FLOOD-DONE; outer screen:\n{}\npane screen:\n{}",
        o.screen(),
        s.request(
            "GET",
            &format!("/panes/{alt_pane}/screen?format=plain"),
            None,
            200
        )
    );
    o.wheel_up(40, 5);
    o.contains("H19970");

    o.prefix("d");
    o.wait("client exits before its shell resumes", || {
        client.has_ended()
    });
    o.resume_shell();
    resume.shell_stopped = false;
    o.detached();
}

const WINCH_COUNTER: &str = r#"import os,signal
n=0
def changed(*args):
 global n
 n+=1
 open(COUNTER,'w').write(str(n))
signal.signal(signal.SIGWINCH,changed)
open(COUNTER,'w').write('0')
print('WINCH-READY',flush=True)
while True: signal.pause()
"#;

#[test]
fn client_winch_and_outer_modes() {
    let s = start(&[]);
    let counter = s.dir.join("winch");
    let program = WINCH_COUNTER.replace("COUNTER", &format!("{:?}", text_of(&counter)));
    s.pane(&format!("exec python3 -c {}", quote(&program)));
    let o = Outer::new(&s.dir, Keys::Extended);
    o.wait("WINCH handler", || counter.exists());
    o.line("printf '\\033[?1003h\\033[?1006h\\033[?1004h\\033[?2004h\\033[?25l'");
    o.wait("pre-existing outer modes", || {
        let modes = format!(",{},", o.modes());
        [",1003,", ",1004,", ",1006,", ",2004,"]
            .iter()
            .all(|mode| modes.contains(mode))
            && !modes.contains(",25,")
    });
    let before = o.modes();
    let count = |expected: &str| read_file(&counter).as_deref() == Some(expected);

    o.attach("cat");
    o.contains("WINCH-READY");
    o.wait("one attach resize", || count("1"));
    o.detach();
    let after = o.modes();
    assert_eq!(before, after, "outer modes changed");

    o.attach("cat");
    o.contains("WINCH-READY");
    o.prefix("\x13");
    o.wait(
        "one real width change and no same-size attach resize",
        || count("2"),
    );
    o.resize(130, 31);
    o.wait("one outer terminal resize", || count("3"));
    o.resize(130, 31);
    o.resize(131, 31);
    o.wait("same-size resize sends no WINCH", || count("4"));
    o.detach();
}

struct KillOnDrop<'a> {
    dir: &'a Path,
    env: &'a [Vec<u8>],
    scratch: &'a Path,
}

impl Drop for KillOnDrop<'_> {
    fn drop(&mut self) {
        run_ko(
            self.scratch,
            self.env,
            &["kill-server", "--server", text_of(self.dir)],
            "",
        );
    }
}

#[test]
fn client_incompatible_server_reports_restart_command_and_both_versions() {
    let dir = Dir::new("ko-mismatch-");
    let env = crate::harness::test_env(&dir);
    let _server = crate::harness::Child::spawn(
        Path::new(env!("CARGO_BIN_EXE_ko-fake")),
        &["mismatch-server", text_of(&dir)],
        &env,
        &[],
    );
    crate::harness::poll("incompatible server socket", || dir.join("socket").exists());
    let scratch = Dir::new("ko-mismatch-run-");
    let run = run_ko(&scratch, &env, &["--server", text_of(&dir)], "");
    assert_eq!(run.exit, ko_sys::pid::Exit::Exited(1));
    assert_eq!(run.stdout, "");
    assert!(
        run.stderr.contains(
            "The running server is a different version and must be restarted to upgrade."
        ),
        "{}",
        run.stderr
    );
    assert!(
        run.stderr
            .contains("terminal different, build incompatible-test"),
        "{}",
        run.stderr
    );
    assert!(
        run.stderr.contains(&format!(
            "build {}",
            serde_json::from_str::<serde_json::Value>(
                &run_ko(&scratch, &env, &["version"], "").ok()
            )
            .unwrap()["build"]
                .as_str()
                .unwrap()
        )),
        "{}",
        run.stderr
    );
    assert!(
        run.stderr
            .contains(&format!("ko kill-server --server '{}'", text_of(&dir))),
        "{}",
        run.stderr
    );
    assert!(
        run.stderr
            .contains("then start again. All sessions and panes will end."),
        "{}",
        run.stderr
    );
}

#[test]
fn client_attach_or_start() {
    let dir = Dir::new("ko-auto-");
    let stale = UnixListener::bind(dir.join("socket")).unwrap();
    drop(stale);
    let o = Outer::new(&dir, Keys::Extended);
    let scratch = Dir::new("ko-run-");
    let _kill = KillOnDrop {
        dir: &dir,
        env: &o.env,
        scratch: &scratch,
    };
    let peer = Outer::new(&dir, Keys::Extended);
    o.attach("cat");
    peer.attach("cat");
    o.wait("the client attached", || o.mouse_reporting());
    peer.wait("the peer attached", || peer.mouse_reporting());
    UnixStream::connect(dir.join("socket")).unwrap();
    o.detach();
    peer.detach();
    let run = run_ko(
        &scratch,
        &o.env,
        &["kill-server", "--server", text_of(&dir)],
        "",
    );
    assert_eq!(run.ok(), "");
}

const DA1_AND_MODES: &str = r#"import os,select,tty
tty.setraw(0)
os.write(1,b'\x1b[c')
if not select.select([0],[],[],3)[0]: raise RuntimeError('no DA1')
r=os.read(0,1024)
print('DA1-ANSWERED' if r.startswith(b'\x1b[?') else repr(r),flush=True)
os.write(1,b'\x1b[?1h\x1b[?1000h\x1b[?1002h\x1b[?1004h\x1b[?1006h\x1b[?2004h\x1b[=3;1uMODE-READY')
while True:
 r=os.read(0,1024)
 print('INPUT:'+r.hex(),end='\r\n',flush=True)
"#;

#[test]
fn client_modes_before_attach_and_unattached_da1() {
    let s = start(&[]);
    let pane = s.pane(&format!("exec python3 -c {}", quote(DA1_AND_MODES)));
    let o = Outer::new(&s.dir, Keys::Extended);
    o.wait("server answers DA1 without a view", || {
        s.request(
            "GET",
            &format!("/panes/{pane}/screen?format=plain&history=all"),
            None,
            200,
        )
        .contains("MODE-READY")
    });

    o.attach("cat");
    o.contains("DA1-ANSWERED");
    o.contains("MODE-READY");

    // The pane reads whatever the client forwarded since its last read as one input; waiting for
    // each line's own count keeps the inputs apart. The client forwards a focus-in on attach.
    let lines_with = |needle: &str| o.screen().matches(needle).count();
    o.contains(&input(FOCUS_IN));
    o.raw(FOCUS_OUT);
    o.contains(&input(FOCUS_OUT));
    let focus_ins = lines_with(&input(FOCUS_IN));
    o.raw(FOCUS_IN);
    o.wait("focus-in forwarded", || {
        lines_with(&input(FOCUS_IN)) > focus_ins
    });
    o.raw(UP);
    o.contains(&input("\x1b[1;1:1A"));
    o.press(40, 5);
    o.contains(&pane_saw_click(40 - PANE_X));
    o.press(PANE_X, 5);
    o.press(PANE_X + 1, 5);
    o.contains(&pane_saw_click(1));
    assert!(
        !o.screen().contains(&hex("\x1b[<0;0;5M")),
        "a click on the bar reached the pane"
    );
    let pasted = "\x1b[200~abc\x1b[201~";
    o.raw(pasted);
    o.contains(&input(pasted));
    let pane_screen = || {
        s.request(
            "GET",
            &format!("/panes/{pane}/screen?format=plain&history=all"),
            None,
            200,
        )
    };
    let focus_outs = pane_screen().matches(&input(FOCUS_OUT)).count();
    o.detach();
    o.wait("focus-out of the detach read by the pane", || {
        pane_screen().matches(&input(FOCUS_OUT)).count() > focus_outs
    });

    o.attach("cat");
    o.contains("MODE-READY");
    o.wait("focus-in forwarded on reattach", || {
        lines_with(&input(FOCUS_IN)) == focus_ins + 2
    });
    o.raw(UP);
    o.wait("kitty mode input survives reattach", || {
        lines_with(&input("\x1b[1;1:1A")) == 2
    });
    o.detach();
}

#[test]
fn client_initial_cursor_and_synchronized_output() {
    let s = start(&[]);
    let pane = interactive_fixture(&s);
    let o = Outer::new(&s.dir, Keys::Extended);
    o.attach("cat");
    o.contains("BASE");
    let after_base = |data: &[u8]| {
        let text = String::from_utf8_lossy(data).into_owned();
        text.find("BASE").map(|first| text[first + 4..].to_owned())
    };
    o.wait("first pane frame completes", || {
        after_base(&o.output()).is_some_and(|frame| frame.contains("\x1b[?2026l"))
    });
    let mut first_frame = after_base(&o.output()).expect("first pane frame missing");
    if let Some(next) = first_frame.find("\x1b[?2026l") {
        first_frame.truncate(next);
    }
    assert!(
        !first_frame.contains("\x1b[?25l"),
        "first pane frame leaves its cursor hidden"
    );
    o.wait("visible initial pane cursor at pane column 4", || {
        o.cursor() == (true, PANE_X + 4, 0)
    });
    s.text(&pane, "h");
    o.contains("HOLD-CHANGED");
    s.text(&pane, "r");
    let shell = s.pane("printf '\\033]0;shell\\007'; exec /bin/sh");
    o.contains("2  shell");
    o.click(3, 3);
    s.text(&shell, "printf 'SWITCHED\\n'\n");
    o.contains("SWITCHED");
    o.quiet();
    o.line("echo abc");
    o.wait("complete echo output without another input", || {
        o.lines().iter().any(|line| pane_text(line).trim() == "abc")
    });
    s.text(&shell, "printf 'POST-%s\\n' OUTPUT\n");
    o.contains("POST-OUTPUT");
    s.text(&shell, "printf 'COLORS:%s\\n' \"$(tput colors)\"\n");
    o.contains("COLORS:256");
    o.detach();
}

#[test]
fn client_sidebar_keyboard_focus_and_selection() {
    let s = start(&[]);
    let first = s.pane(&format!("exec python3 -u -c {} one", quote(SPLIT_ECHO)));
    s.pane(&format!("exec python3 -u -c {} two", quote(SPLIT_ECHO)));
    let o = Outer::new(&s.dir, Keys::Extended);
    o.attach("cat");
    o.contains("READY-one");
    o.prefix("h");
    o.contains("[sidebar]");
    assert!(
        o.cell(0, 1)
            .style
            .attrs
            .has(ko_vt::render::Attribute::Inverse)
    );
    o.raw("X\x1b[27uY");
    o.contains("one-KEY-59");
    assert!(!s.screen(&first).contains("one-KEY-58"));
    o.gone("[sidebar]");
    o.prefix("\x1b[D");
    o.contains("[sidebar]");
    o.prefix("\x13");
    o.gone("[sidebar]");
    o.raw("Z");
    o.contains("one-KEY-5a");
    o.prefix("\x13");
    o.prefix("\x1b[104;5u");
    o.contains("[sidebar]");
    o.raw("j\r");
    o.contains("READY-two");
    o.gone("[sidebar]");
    o.raw("Q");
    o.contains("two-KEY-51");
    o.prefix("h");
    o.contains("[sidebar]");
    o.prefix("l");
    o.gone("[sidebar]");
    o.raw("S");
    o.contains("two-KEY-53");
    o.prefix("[");
    o.contains("[copy]");
    o.click(3, 3);
    o.raw("q");
    o.gone("[copy]");
    o.raw("T");
    o.contains("two-KEY-54");
    o.resize(101, 25);
    o.wait("initial pane area excludes the sidebar", || {
        window_size(&s.doc(), 1) == (76, 24)
    });
    o.prefix("h");
    o.prefix("R");
    o.contains("[resize]");
    o.wait("sidebar separator is yellow", || {
        o.cell(24, 0).style.fg == ko_vt::render::Colour::Indexed(3)
    });
    o.raw("h");
    o.wait("keyboard narrows the sidebar by one", || {
        window_size(&s.doc(), 1) == (77, 24)
    });
    o.raw("L");
    o.wait("keyboard widens the sidebar by five", || {
        window_size(&s.doc(), 1) == (72, 24)
    });
    o.raw("HHHHHHHHHH");
    o.wait("keyboard width reaches minimum", || {
        window_size(&s.doc(), 1) == (90, 24)
    });
    o.raw("LLLLLLLLLLLL");
    o.wait("keyboard width reaches maximum", || {
        window_size(&s.doc(), 1) == (50, 24)
    });
    o.raw("q");
    o.contains("[sidebar]");
    o.prefix("R");
    o.contains("[resize]");
    o.click(60, 3);
    o.gone("[resize]");
    o.raw("V");
    o.contains("two-KEY-56");
    o.prefix("h");
    o.prefix("R");
    o.contains("[resize]");
    o.prefix("\x13");
    o.gone("[resize]");
    o.raw("U");
    o.contains("two-KEY-55");
    o.prefix("\x13");
    o.press(51, 3);
    o.raw("\x1b[<32;25;3M\x1b[<0;25;3m");
    o.wait("restore sidebar width for drag", || {
        window_size(&s.doc(), 1) == (76, 24)
    });
    o.press(25, 3);
    o.raw("\x1b[<32;35;3M\x1b[<32;41;3M\x1b[<0;41;3m");
    o.wait("separator drag resizes the pane area", || {
        window_size(&s.doc(), 1) == (60, 24)
    });
    o.wait("separator follows the pointer", || {
        o.cell(40, 0).text == "│"
    });
    o.press(41, 3);
    o.raw("\x1b[<32;1;3M\x1b[<0;1;3m");
    o.wait("minimum sidebar width is ten", || {
        window_size(&s.doc(), 1) == (90, 24)
    });
    o.press(11, 3);
    o.raw("\x1b[<32;101;3M");
    o.wait("maximum width rounds half down", || {
        window_size(&s.doc(), 1) == (50, 24)
    });
    o.resize(61, 25);
    o.wait("outer resize clamps an active drag", || {
        window_size(&s.doc(), 1) == (30, 24)
    });
    o.raw("\x1b[<32;61;3M\x1b[<0;61;3mA");
    o.contains("two-KEY-41");
    assert_eq!(window_size(&s.doc(), 1), (30, 24));
    o.detach();
}

#[test]
fn client_sidebar_ownership() {
    let s = start(&[]);
    let pane = interactive_fixture(&s);
    let o = Outer::new(&s.dir, Keys::Extended);
    o.attach("cat");
    o.contains("BASE");
    for (y, line) in o.lines().iter().take(29).enumerate() {
        let cells: Vec<char> = line.chars().collect();
        assert!(
            cells.len() >= PANE_X && cells[PANE_X - 1] == '│',
            "no bar left of the pane in row {y}: {line:?}"
        );
    }
    o.prefix("\x13");
    s.text(&pane, "f");
    o.wait("pane draws across the hidden sidebar", || {
        o.raw("z");
        let lines = o.lines();
        lines.len() > 3 && lines[3].starts_with(&"P".repeat(24))
    });
    assert!(
        !o.screen().contains('│'),
        "bar drawn while the sidebar is hidden"
    );
    o.prefix("\x13");
    o.contains("1  fixture");
    for (y, line) in o.lines().iter().enumerate() {
        if line.starts_with("[test]") {
            continue;
        }
        let bytes = line.as_bytes();
        let line = String::from_utf8_lossy(&bytes[..bytes.len().min(24)]).into_owned();
        let text = line.trim();
        if (y == 0 && text == "test") || (y == 1 && text == "1  fixture") {
            continue;
        }
        assert!(text.is_empty(), "stale sidebar cells in row {y}: {line:?}");
    }
    o.detach();
}

const TERMINAL_PROXY: &str = r##"#!/usr/bin/env python3
import fcntl,os,pty,re,select,struct,sys,termios,tty,time
saved=termios.tcgetattr(0)
pid,fd=pty.fork()
if pid==0:
 w,h=os.get_terminal_size(1)
 fcntl.ioctl(0,termios.TIOCSWINSZ,struct.pack('HHHH',h,w,0,0))
 os.execv(sys.argv[1],[sys.argv[1]]+sys.argv[2:])
tty.setraw(0)
pending=b''
try:
 deadline=time.monotonic()+20
 while time.monotonic()<deadline:
  ready,_,_=select.select([0,fd],[],[],min(1,deadline-time.monotonic()))
  if 0 in ready: os.write(fd,os.read(0,65536))
  if fd in ready:
   try: data=os.read(fd,65536)
   except OSError: break
   if not data: break
   pending+=data
   if b'\x1b[?25$p' in pending:
    os.write(fd,b'\x1b[?25;0$y')
    pending=pending.replace(b'\x1b[?25$p',b'')
   if b'\x1b[?u' in pending:
    os.write(fd,b'\x1b[?0u')
    pending=pending.replace(b'\x1b[?u',b'')
   last=pending.rfind(b'\x1b')
   if last>=0 and not re.fullmatch(rb'\x1b\[[0-?]*[ -/]*[@-~]',pending[last:]) and len(pending)-last<16:
    os.write(1,pending[:last]);pending=pending[last:]
   else: os.write(1,pending);pending=b''
finally:
 if pending: os.write(1,pending)
 termios.tcsetattr(0,termios.TCSANOW,saved)
 os.close(fd)
 deadline=time.monotonic()+2
 killed=False
 while True:
  done,_=os.waitpid(pid,os.WNOHANG)
  if done: break
  if time.monotonic()>=deadline:
   if killed: raise RuntimeError('client did not exit')
   os.kill(pid,9);killed=True;deadline=time.monotonic()+1
  select.select([],[],[],0.01)
"##;

#[test]
fn client_unknown_cursor_mode_and_keyboard_stack() {
    let s = start(&[]);
    interactive_fixture(&s);
    let mut o = Outer::new(&s.dir, Keys::Extended);
    let proxy = o.dir.join("terminal-proxy");
    std::fs::write(&proxy, TERMINAL_PROXY).unwrap();
    std::fs::set_permissions(&proxy, std::os::unix::fs::PermissionsExt::from_mode(0o700)).unwrap();
    o.executable = proxy;
    o.arguments = vec![text_of(&crate::harness::ko()).to_owned()];
    o.attach("cat");
    o.contains("BASE");
    o.detach();
    assert!(o.cursor().0, "unknown saved cursor mode restored hidden");
    let data = o.output();
    let pushes = count_sequences(&data, b"\x1b[>", b"0123456789;");
    let pops = count_sequences(&data, b"\x1b[<", b"0123456789");
    assert!(
        pushes == 1 && pops == pushes,
        "kitty stack: pushes={pushes} pops={pops}, want one owned entry"
    );
}

#[test]
fn client_different_sizes_and_signal_cleanup() {
    let s = start(&[]);
    interactive_fixture(&s);
    let large = Outer::new(&s.dir, Keys::Extended);
    large.attach("cat");
    large.contains("BASE");
    let small = Outer::new(&s.dir, Keys::Extended);
    small.resize(85, 20);
    small.attach("cat");
    small.contains("BASE");
    large.contains("BASE");
    small.detach();
    large.detach();
    let o = Outer::new(&s.dir, Keys::Extended);
    let mut errors = Vec::new();
    for signal in [Signal::Hup, Signal::Term] {
        let before = o.modes();
        o.attach("cat");
        o.contains("BASE");
        signal_descendant(o.shell_pid(), o.client_pid(), signal).unwrap();
        o.detached();
        let after = o.modes();
        if before != after {
            errors.push(format!(
                "signal {signal:?}: modes before {before:?} after {after:?}"
            ));
        }
    }
    let data = o.output();
    let push = count_sequences(&data, b"\x1b[>", b"0123456789;");
    let pop = count_sequences(&data, b"\x1b[<", b"0123456789");
    if push != pop {
        errors.push(format!("signal cleanup kitty pushes={push} pops={pop}"));
    }
    assert!(errors.is_empty(), "{errors:?}");
}

const SELECTS_THEN_ECHOES_INPUT: &str = r#"import os,sys,tty
tty.setraw(0)
os.write(1,b'\x1b[?1000h\x1b[?1006hSELECTED-'+sys.argv[1].encode())
b=b''
while not b.endswith(b'x'): b+=os.read(0,4096)
os.write(1,('INPUT:'+b.hex()).encode())
while True: os.read(0,4096)
"#;

#[test]
fn client_mouse_bounds_exclude_the_status_line_and_the_prefix_works_without_extended_keys() {
    let s = start(&[]);
    for i in 1..=5 {
        s.pane(&format!(
            "exec python3 -u -c {} {i}",
            quote(SELECTS_THEN_ECHOES_INPUT)
        ));
    }
    let o = Outer::new(&s.dir, Keys::Extended);
    o.resize(120, 5);
    o.attach("cat");
    o.contains("SELECTED-1");
    o.press(1, 5);
    o.press(30, 5);
    o.raw("x");
    o.contains("INPUT:78");
    o.contains("SELECTED-1");
    o.detach();

    let plain = Outer::new(&s.dir, Keys::Unconfirmed);
    plain.attach("cat");
    plain.contains("SELECTED-1");
    plain.click(3, 3);
    plain.contains("SELECTED-2");
    plain.prefix("\x01");
    plain.raw("x");
    plain.contains("INPUT:0178");
    plain.detach();
}

#[test]
fn client_dead_pane_line() {
    let s = start(&[]);
    let fill = "yes '' | head -40; printf last; ";
    s.new_pane(
        json!({"close": "keep", "command": {"type": "shell", "command": format!("{fill}exit 3")}}),
    );
    s.new_pane(json!({"close": "keep", "command": {"type": "shell", "command": format!("{fill}kill -TERM $$")}}));
    s.pane("printf 'live\\n'; exec cat");
    let o = Outer::new(&s.dir, Keys::Extended);
    o.attach("cat");
    let line = |text: &str| {
        o.wait(text, || {
            o.lines()
                .windows(2)
                .any(|w| pane_text(&w[0]).starts_with("last") && pane_text(&w[1]).starts_with(text))
        });
    };
    line("[exited 3 \u{2014} Ctrl+D to remove]");
    o.click(3, 3);
    line("[killed by SIGTERM \u{2014} Ctrl+D to remove]");
    o.click(3, 4);
    o.contains("live");
    o.gone("Ctrl+D");
    o.detach();
}

#[test]
fn client_legacy_shifted_key() {
    type Row = (&'static str, &'static str, &'static str);
    let groups: [(u8, &[Row]); 4] = [
        (
            3,
            &[
                ("plain colon", ":", ":"),
                ("plain A", "A", "A"),
                ("plain É", "É", "É"),
                ("CSI u colon without text", "\x1b[59;2u", ":"),
                ("CSI u A without text", "\x1b[97;2u", "A"),
                ("CSI u ! without text", "\x1b[49;2u", "!"),
                ("CSI u é without text", "\x1b[233;2u", "É"),
                ("CSI u with explicit text", "\x1b[97;2;937u", "Ω"),
                ("Shift+Space", "\x1b[32;2u", "\x1b[32;2u"),
                ("Shift+Enter", "\x1b[13;2u", "\x1b[13;2u"),
                ("Alt+Shift+A", "\x1b[97;4u", "\x1b[97;4u"),
            ],
        ),
        (
            31,
            &[
                ("plain colon", ":", "\x1b[59:58;2;58u"),
                ("plain A", "A", "\x1b[97:65;2;65u"),
                ("CSI u A without text", "\x1b[97;2u", "\x1b[97:65;2;65u"),
            ],
        ),
        (
            0,
            &[
                ("plain A", "A", "A"),
                ("CSI u A without text", "\x1b[97;2u", "A"),
                ("Alt+Shift+A", "\x1b[97;4u", "\x1bA"),
                ("Alt+b", "\x1b[98;3u", "\x1bb"),
            ],
        ),
        (
            1,
            &[
                ("plain A", "A", "A"),
                ("CSI u A without text", "\x1b[97;2u", "A"),
                ("CSI u colon without text", "\x1b[59;2u", ":"),
            ],
        ),
    ];
    let cases: Vec<_> = groups
        .iter()
        .flat_map(|(flags, rows)| rows.iter().map(move |row| (flags, row)))
        .collect();
    let plan: Vec<String> = cases.iter().map(|(flags, _)| flags.to_string()).collect();
    let s = start(&[]);
    let program = format!("import os,tty\ntty.setraw(0)\nf=[{}]\n", plan.join(","))
        + r#"os.write(1,b'\x1b[>%du'%f[0]+b'KEY-READY')
n=0
while True:
 b=os.read(0,4096)
 n+=1
 nxt=b'\x1b[=%d;1u'%f[n] if n<len(f) else b''
 os.write(1,nxt+('\r\nKEY%d:'%n+b.hex()+'\r\n').encode())"#;
    s.pane(&format!("exec python3 -u -c {}", quote(&program)));
    let o = Outer::new(&s.dir, Keys::Extended);
    o.attach("cat");
    o.contains("KEY-READY");
    for (i, (flags, (name, typed, want))) in cases.iter().enumerate() {
        o.raw(typed);
        let expected = format!("KEY{}:{}\n", i + 1, hex(want));
        o.wait(&format!("flags {flags}, {name}: {expected}"), || {
            o.screen().contains(&expected)
        });
    }
    o.detach();
}

fn mark(o: &Outer, row: usize) -> (String, ko_vt::render::Colour, bool, bool) {
    use ko_vt::render::Attribute;
    let cell = o.cell(2, row);
    (
        cell.text,
        cell.style.fg,
        cell.style.attrs.has(Attribute::Bold),
        cell.style.attrs.has(Attribute::Inverse),
    )
}

#[test]
fn sidebar_mark_column() {
    use ko_vt::render::Colour;
    let Some(shell) = crate::status::shell_of(&crate::status::Flavour::Zsh) else {
        eprintln!("skipped: no zsh on PATH");
        return;
    };
    let s = crate::harness::start_with(&shell, &[], &[]);
    crate::status::dotfiles(&crate::status::Flavour::Zsh, &s.dir, "");
    let (first, second) = (s.shell_pane(), s.shell_pane());
    for pane in [&first, &second] {
        s.wait_row(pane, "the first prompt", |row| {
            row["status"]["kind"]["pane"]["phase"]["type"] == "idle"
        });
    }
    let o = Outer::new(&s.dir, Keys::Extended);
    o.attach("");
    o.contains("1  zsh");
    o.contains("2  zsh");
    let green = Colour::Indexed(2);

    s.text(&second, "sleep 1\r");
    o.wait("a green running mark", || {
        o.lines()[2].starts_with("2 \u{25fc}sleep 1")
            && mark(&o, 2) == ("\u{25fc}".into(), green, false, false)
    });
    o.wait("a green done mark", || {
        o.lines()[2].starts_with("2 \u{2713}zsh")
            && mark(&o, 2) == ("\u{2713}".into(), green, true, false)
    });
    s.text(&second, "false\r");
    o.wait("a red failed mark", || {
        o.lines()[2].starts_with("2 \u{25fc}zsh")
            && mark(&o, 2) == ("\u{25fc}".into(), Colour::Indexed(1), false, false)
    });

    o.prefix("n");
    o.wait("the visit clears the mark", || {
        o.lines()[2].starts_with("2  zsh") && mark(&o, 2).3
    });
    o.prefix("p");
    o.wait("the first pane shown again", || {
        mark(&o, 1).3 && !mark(&o, 2).3
    });
    assert_eq!(
        o.lines()[2].chars().take(6).collect::<String>(),
        "2  zsh",
        "a visit acknowledged the exit"
    );

    s.text(&second, "true\r");
    o.wait("an unseen exit while shown elsewhere", || {
        o.lines()[2].starts_with("2 \u{2713}zsh")
    });

    o.line("sleep 1");
    o.wait("the shown row's mark has no colour", || {
        o.lines()[1].starts_with("1 \u{25fc}sleep 1")
            && mark(&o, 1) == ("\u{25fc}".into(), Colour::Default, false, true)
    });
    let lines = o.lines();
    assert_eq!(
        (lines[1].chars().nth(3), lines[2].chars().nth(3)),
        (Some('s'), Some('z')),
        "titles align with and without a mark"
    );
    o.detach();
}

#[test]
fn client_a_signal_ends_it_while_the_pager_runs_and_removes_the_pager_file() {
    let s = start(&[]);
    s.pane("printf 'pane-one\\n'; exec /bin/sh");
    let o = Outer::new(&s.dir, Keys::Extended);
    let (pager, record) = pager_fixture(&o.dir);
    o.attach(text_of(&pager));
    o.contains("pane-one");
    o.prefix("e");
    o.contains("PAGER-OPEN");
    let file = PathBuf::from(std::fs::read_to_string(&record).unwrap());
    signal_descendant(o.shell_pid(), o.client_pid(), Signal::Term).unwrap();
    o.detached();
    o.wait("pager file removed", || !file.exists());
}

#[test]
fn client_a_new_window_starts_in_the_directory_of_the_focused_pane() {
    let s = start(&[]);
    let first = s.pane("printf 'pane-one\\n'; exec /bin/sh");
    let o = Outer::new(&s.dir, Keys::Extended);
    o.attach("cat");
    o.contains("pane-one");
    o.prefix("c");
    crate::harness::poll("a second pane", || s.rows().len() == 2);
    let created = s
        .rows()
        .into_iter()
        .find(|row| row["id"] != first.as_str())
        .unwrap();
    assert_eq!(
        created["cwd"],
        text_of(&std::fs::canonicalize("/tmp").unwrap()),
        "{created}"
    );
    assert_eq!(created["runtime"], serde_json::Value::Null, "{created}");
    o.detach();
}

#[test]
fn client_status_line_windows_and_prompts() {
    let s = start(&[]);
    s.pane("printf 'pane-one\\n'; exec cat");
    let o = Outer::new(&s.dir, Keys::Extended);
    o.attach("cat");
    o.contains("pane-one");
    o.contains("[test] 0:test*");
    let status = |o: &Outer| {
        o.lines()
            .into_iter()
            .find(|line| line.starts_with("[test]"))
            .unwrap_or_default()
    };
    let names = || -> Vec<String> {
        s.doc()["layout"]["sessions"][0]["windows"]
            .as_array()
            .unwrap()
            .iter()
            .map(|window| window["name"].as_str().unwrap().to_owned())
            .collect()
    };

    o.prefix("c");
    o.wait("the new window is shown and marked", || {
        status(&o).starts_with("[test] 0:test- 1:") && status(&o).contains('*')
    });
    let windows = names();
    assert_eq!(windows.len(), 2);
    let marked = |first: &str, second: &str| {
        format!("[test] 0:{}{first} 1:{}{second}", windows[0], windows[1])
    };
    o.prefix("0");
    o.wait("window 0 selected", || {
        status(&o).starts_with(&marked("*", "-"))
    });
    o.prefix("\t");
    o.wait("Tab selects the last window", || {
        status(&o).starts_with(&marked("-", "*"))
    });
    o.prefix("0");
    o.wait("window 0 selected again", || {
        status(&o).starts_with(&marked("*", "-"))
    });
    o.prefix("1");
    o.wait("window 1 selected", || {
        status(&o).starts_with(&marked("-", "*"))
    });

    o.prefix("?");
    o.contains("send C-a to the pane");
    o.raw("z");
    o.gone("send C-a to the pane");

    o.prefix(",");
    o.raw("two");
    o.contains("(rename-window) two");
    o.enter();
    o.wait("the window renamed", || status(&o).contains(" 1:two*"));
    assert_eq!(names()[1], "two");

    o.prefix("&");
    o.contains("kill-window two? (y/n)");
    o.raw("y");
    o.wait("only window 0 listed", || {
        status(&o).starts_with("[test] 0:test*") && !status(&o).contains("two")
    });

    o.prefix("x");
    o.contains("kill-pane? (y/n)");
    o.raw("n");
    o.gone("kill-pane?");
    assert_eq!(s.pane_pids().len(), 1);
    o.detach();
}
