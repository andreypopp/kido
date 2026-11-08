use serde_json::json;

use crate::harness::{base64, start};

#[test]
fn webview_page_lifecycle() {
    let s = start(&[]);
    let pane = s.pane("stty raw -echo; exec cat");
    s.text(&pane, "ready\n");
    s.screen_has(&pane, "ready");
    let (mut watcher, _) = s.client(None);
    let enter = |path: &str| format!("\x1b]7502;a=enter:p={}\x07", base64(path.as_bytes()));
    for clear in ["\x1b]7502;a=leave\x07", "\x1bc", "\x1b]133;A\x07"] {
        s.text(&pane, &enter("/page?x=1"));
        let event = watcher.event("webview");
        assert_eq!(event["pane"], pane);
        assert_eq!(
            event["webview"],
            json!({"page":{"path":"/page?x=1"},"serving":false})
        );
        assert_eq!(s.row(&pane)["webview"], event["webview"]);
        s.text(&pane, clear);
        assert_eq!(watcher.event("webview")["webview"], json!(null));
    }
    s.text(&pane, &format!("{}\x1b[?1049h", enter("/alternate")));
    assert_eq!(
        watcher.event("webview")["webview"]["page"]["path"],
        "/alternate"
    );
    s.text(&pane, "\x1b[?1049l\x1b]7502;a=enter:p=cmVsYXRpdmU=\x07");
    s.text(&pane, "marker");
    s.screen_has(&pane, "marker");
    assert_eq!(s.row(&pane)["webview"]["page"]["path"], "/alternate");
    for path in [format!("/{}", "x".repeat(2048)), "/\n".into()] {
        s.text(&pane, &enter(&path));
    }
    s.text(
        &pane,
        &format!("\x1b]7502;a=leave:x={}\x07tail", "x".repeat(4096)),
    );
    s.screen_has(&pane, "tail");
    assert_eq!(s.row(&pane)["webview"]["page"]["path"], "/alternate");
    let ending = s.pane("stty raw -echo; printf ready; dd bs=1 count=15 2>/dev/null");
    s.screen_has(&ending, "ready");
    s.text(&ending, "\x1b]7502;a=enter\x07");
    assert_eq!(watcher.event("webview")["webview"]["page"]["path"], "/");
    assert_eq!(watcher.event("webview")["webview"], json!(null));
}

#[test]
fn webview_supported_query_follows_client_capability() {
    let s = start(&[]);
    let pane = s.pane(r#"stty raw -echo; printf '\033]7502;?\007'; reply=$(dd bs=1 count=41 2>/dev/null); if [ "$reply" = "$(printf '\033]7502;?:actions=enter,leave:supported=0\007')" ]; then printf FIRST; fi; dd bs=1 count=1 >/dev/null 2>&1; printf '\033]7502;?\033\\'; reply=$(dd bs=1 count=42 2>/dev/null); if [ "$reply" = "$(printf '\033]7502;?:actions=enter,leave:supported=1\033\\')" ]; then printf SECOND; fi; exec cat"#);
    s.screen_has(&pane, "FIRST");
    let mut client = s.ws("/client");
    client.send(
        &json!({"type":"hello","name":"webview","webview":true,"focused":false,"sizing":{"type":"disabled"}}),
    );
    client.welcome();
    s.text(&pane, "x");
    s.screen_has(&pane, "SECOND");
}
