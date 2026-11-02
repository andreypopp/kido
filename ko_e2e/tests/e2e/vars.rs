use serde_json::{Value, json};

use crate::harness::start;

const MAX_VALUE: usize = (1 << 20) - 4096;

fn put(s: &crate::harness::Server, pane: &str, name: &str, body: &str) -> (u16, String) {
    let (status, reply) = s.exchange(
        "PUT",
        &format!("/panes/{pane}/vars/{name}"),
        &s.headers(),
        body.as_bytes(),
    );
    (status, String::from_utf8_lossy(&reply).into_owned())
}

fn message(reply: &str) -> String {
    serde_json::from_str::<Value>(reply)
        .map(|value| value["message"].as_str().unwrap_or_default().to_owned())
        .unwrap_or_default()
}

#[test]
fn variables() {
    let s = start(&[]);
    let pane = s.pane("printf READY; read x");
    s.screen_has(&pane, "READY");
    let (mut watcher, _) = s.client(None);
    let route = |name: &str| format!("/panes/{pane}/vars/{name}");

    assert_eq!(
        s.ko(
            &["api", "-X", "PUT", "--input", "-", &route("ssh.dest")],
            "\"deploy@example.test\""
        )
        .ok(),
        "{}"
    );
    let event = watcher.event("var");
    assert_eq!(
        event,
        json!({"type": "var", "pane": pane, "name": "ssh.dest", "value": "deploy@example.test"})
    );
    assert_eq!(
        s.ko(&["api", &route("ssh.dest")], "").ok(),
        "\"deploy@example.test\""
    );
    assert_eq!(
        s.ko(&["api", &format!("/panes/{pane}/vars")], "").json(),
        json!({"ssh.dest": "deploy@example.test"})
    );
    assert_eq!(
        s.row(&pane)["vars"],
        json!({"ssh.dest": "deploy@example.test"})
    );

    s.ko(
        &["api", "-X", "PUT", "--input", "-", &route("ssh.dest")],
        "\"deploy@example.test\"",
    )
    .ok();
    s.ko(
        &["api", "-X", "PUT", "--input", "-", &route("list")],
        "[1, {\"a\": null}]",
    )
    .ok();
    let event = watcher.event("var");
    assert_eq!(event["name"], "list", "an equal PUT sends no event");
    assert_eq!(event["value"], json!([1, {"a": null}]));

    assert_eq!(
        s.ko(&["api", "-X", "DELETE", &route("list")], "").ok(),
        "{}"
    );
    assert_eq!(
        watcher.event("var_deleted"),
        json!({"type": "var_deleted", "pane": pane, "name": "list"})
    );
    assert_eq!(
        s.ko(&["api", "-X", "DELETE", &route("list")], "").ok(),
        "{}",
        "deleting an absent name succeeds"
    );
    s.ko(&["api", "-X", "PUT", "--input", "-", &route("last")], "0")
        .ok();
    assert_eq!(
        watcher.event("var")["name"],
        "last",
        "deleting an absent name sends no event"
    );
    let missing = s.ko(&["api", &route("list")], "").http_error(404);
    assert_eq!(
        missing,
        r#"{"kind":"not_found","message":"variable not found"}"#
    );
    s.ko(&["api", "/panes/pane_99/vars"], "").http_error(404);
    assert_eq!(
        put(&s, &pane, "bad", "{").0,
        400,
        "the body must be one JSON value"
    );

    let big = |len: usize| format!("\"{}\"", "x".repeat(len));
    let name: String = (0..256)
        .map(|at| if at % 2 == 0 { '"' } else { '\\' })
        .collect();
    let encoded: String = name.bytes().map(|byte| format!("%{byte:02X}")).collect();
    let (mut limit_watcher, _) = s.client(None);
    assert_eq!(put(&s, &pane, &encoded, &big(MAX_VALUE - 2)).0, 200);
    let event = limit_watcher.event("var");
    assert_eq!(event["name"], name.as_str());
    assert_eq!(event["value"].as_str().map(str::len), Some(MAX_VALUE - 2));
    assert_eq!(put(&s, &pane, "after", "1").0, 200);
    assert_eq!(
        limit_watcher.event("var")["name"],
        "after",
        "the watcher stays connected after the largest event"
    );
    let (status, reply) = put(&s, &pane, "too-big", &big(MAX_VALUE - 1));
    assert_eq!(
        (status, message(&reply).as_str()),
        (400, "variable too large")
    );
    s.request("DELETE", &route(&encoded), None, 200);

    for index in 0..8 {
        assert_eq!(put(&s, &pane, &format!("m{index}"), &big(1_044_000)).0, 200);
    }
    let (status, reply) = put(&s, &pane, "m8", &big(1_044_000));
    assert_eq!(
        (status, message(&reply).as_str()),
        (400, "pane variables too large")
    );

    let other = s.pane("printf READY; read x");
    s.screen_has(&other, "READY");
    for index in 0..1024 {
        assert_eq!(put(&s, &other, &format!("n{index}"), "null").0, 200);
    }
    let (status, reply) = put(&s, &other, "n1024", "null");
    assert_eq!(
        (status, message(&reply).as_str()),
        (400, "too many variables")
    );
    assert_eq!(
        put(&s, &other, "n0", "true").0,
        200,
        "a replacement is not a new name"
    );

    s.request("DELETE", &format!("/panes/{other}/vars/n1"), None, 200);
    assert_eq!(put(&s, &other, &"n".repeat(256), "1").0, 200);
    let (status, reply) = put(&s, &other, &"n".repeat(257), "1");
    assert_eq!(
        (status, message(&reply).as_str()),
        (400, "invalid variable name")
    );

    for index in 0..8 {
        s.request("DELETE", &route(&format!("m{index}")), None, 200);
    }
    let (mut late, _) = s.client(None);
    s.text(&pane, "\n");
    late.event("dead");
    assert_eq!(
        s.ko(&["api", &route("ssh.dest")], "").ok(),
        "\"deploy@example.test\"",
        "a dead pane keeps its variables"
    );
}
