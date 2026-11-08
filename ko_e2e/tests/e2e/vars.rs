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
    let pane = s.new_pane(
        json!({"close": "keep", "command": {"type": "shell", "command": "printf READY; read x"}}),
    );
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
        s.row(&pane)["vars"],
        json!({"ssh.dest": "deploy@example.test"})
    );
    assert_eq!(
        s.ko(&["api", &format!("/panes/{pane}")], "").json()["vars"],
        json!({"ssh.dest": "deploy@example.test"}),
        "one pane, with its variables"
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
    assert_eq!(s.row(&pane)["vars"].get("list"), None);
    for read in [route("list"), format!("/panes/{pane}/vars")] {
        s.ko(&["api", &read], "").http_error(404);
    }
    assert_eq!(
        s.ko(&["api", "/panes/pane_99"], "").http_error(404),
        r#"{"kind":"not_found","message":"pane not found"}"#
    );
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
        (400, "variables too large")
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
        s.row(&pane)["vars"]["ssh.dest"],
        "deploy@example.test",
        "a dead pane keeps its variables"
    );
}

#[test]
fn a_layout_put_takes_vars_on_new_panes_sessions_and_windows_under_the_limits_of_the_vars_route() {
    let s = start(&[]);
    let attempt = |vars: &Value, place: &str| {
        let mut document = s.doc();
        let (mut session, mut window, mut new) =
            (json!({}), json!({}), crate::harness::sh("exec cat"));
        match place {
            "pane" => new["vars"] = vars.clone(),
            "window" => window["vars"] = vars.clone(),
            _ => session["vars"] = vars.clone(),
        }
        window["name"] = json!("w");
        window["tree"] = json!({"pane": {"new": new}});
        session["name"] = json!("s");
        session["windows"] = json!([window]);
        document["layout"]["sessions"]
            .as_array_mut()
            .unwrap()
            .push(session);
        s.ko(
            &["api", "-X", "PUT", "--input", "-", "/layout"],
            &document.to_string(),
        )
    };

    let crowded: serde_json::Map<String, Value> =
        (0..1025).map(|n| (format!("n{n}"), Value::Null)).collect();
    for place in ["pane", "window", "session"] {
        for (vars, refusal) in [
            (
                json!({"big": "x".repeat(MAX_VALUE - 1)}),
                "variable too large",
            ),
            (Value::Object(crowded.clone()), "too many variables"),
            (json!({"n".repeat(257): 1}), "invalid variable name"),
            (json!({"": 1}), "invalid variable name"),
        ] {
            let body = attempt(&vars, place).http_error(400);
            let kind: Value = serde_json::from_str(&body).unwrap();
            assert_eq!(kind["kind"], "invalid", "{place}: {body}");
            assert!(
                kind["message"]
                    .as_str()
                    .is_some_and(|text| text.contains(refusal)),
                "{place} {refusal}: {body}"
            );
            assert_eq!(
                s.request("GET", "/panes", None, 200),
                "[]",
                "{place}: no pane started"
            );
        }
    }

    let vars = json!({
        "ssh.dest": "deploy@example.test",
        "n": [1, {"a": null}],
        "big": "x".repeat(MAX_VALUE - 2),
    });
    let put = attempt(&vars, "pane").json();
    let session = &put["layout"]["sessions"][0];
    assert_eq!(
        (session["id"].as_str(), session["windows"][0]["id"].as_str()),
        (Some("session_1"), Some("window_1"))
    );
    assert_eq!(session["windows"][0]["tree"]["pane"], "pane_1");
    let found = s.row("pane_1")["vars"].clone();
    assert_eq!(found["ssh.dest"], "deploy@example.test");
    assert_eq!(found["n"], json!([1, {"a": null}]));
    assert_eq!(found["big"].as_str().map(str::len), Some(MAX_VALUE - 2));

    let small = json!({"k": 1});
    let put = attempt(&small, "window").json();
    assert_eq!(put["layout"]["sessions"][1]["windows"][0]["vars"], small);
    let put = attempt(&small, "session").json();
    assert_eq!(put["layout"]["sessions"][2]["vars"], small);
}

#[test]
fn a_conditional_delete_removes_its_names_together_and_changes_nothing_when_the_condition_fails() {
    let s = start(&[]);
    let pane = s.pane("printf READY; read x");
    s.screen_has(&pane, "READY");
    let (mut watcher, _) = s.client(None);
    for (name, value) in [
        ("pi.session", "\"mine\""),
        ("pi.name", "\"N\""),
        ("keep", "1"),
    ] {
        let route = format!("/panes/{pane}/vars/{name}");
        s.ko(&["api", "-X", "PUT", "--input", "-", &route], value)
            .ok();
    }
    let route = format!("/panes/{pane}/vars");
    let delete = |body: &str| s.ko(&["api", "-X", "DELETE", "--input", "-", &route], body);
    let all = || s.row(&pane)["vars"].clone();
    let before = json!({"keep": 1, "pi.name": "N", "pi.session": "mine"});
    assert_eq!(all(), before);

    let refused =
        delete(r#"{"names":["pi.session","pi.name"],"if":{"name":"pi.session","value":"theirs"}}"#)
            .http_error(412);
    assert_eq!(
        serde_json::from_str::<Value>(&refused).unwrap()["kind"],
        json!("precondition_failed")
    );
    delete(r#"{"names":["keep"],"if":{"name":"absent","value":null}}"#).http_error(412);
    assert_eq!(all(), before, "a failed condition deletes nothing");

    assert_eq!(
        delete(
            r#"{"names":["pi.session","never-set","pi.name"],"if":{"name":"pi.session","value":"mine"}}"#
        )
        .ok(),
        "{}"
    );
    assert_eq!(all(), json!({"keep": 1}));
    assert_eq!(delete(r#"{"names":["keep"]}"#).ok(), "{}");
    assert_eq!(all(), json!({}));
    let deleted: Vec<Value> = (0..3)
        .map(|_| watcher.event("var_deleted")["name"].clone())
        .collect();
    assert_eq!(
        deleted,
        [json!("pi.session"), json!("pi.name"), json!("keep")],
        "one event for each name that existed, in order; none for the refused delete or an absent name"
    );

    delete(r#"{"names":["bad\u0001"]}"#).http_error(400);
    delete("{").http_error(400);
    delete(r#"{"names":[],"if":{"name":"x"}}"#).http_error(400);
    s.ko(
        &["api", "-X", "DELETE", "--input", "-", "/panes/pane_99/vars"],
        r#"{"names":[]}"#,
    )
    .http_error(404);
}

#[test]
fn a_welcome_with_variables_over_a_mebibyte_arrives_whole_and_a_variable_write_moves_no_revision() {
    let s = start(&[]);
    let pane = s.pane("printf READY; read x");
    s.screen_has(&pane, "READY");
    let big = json!("x".repeat(MAX_VALUE - 2));
    let before = s.doc();
    for name in ["a", "b", "c"] {
        s.set_var(&pane, name, &big);
    }
    assert_eq!(
        s.doc()["revision"],
        before["revision"],
        "a variable write is not a layout change"
    );
    assert_eq!(
        s.put(&before)["revision"],
        before["revision"],
        "so the layout from before it is still current"
    );
    let mut ws = s.ws("/client");
    ws.send(&json!({
        "type": "hello", "webview": false, "name": "test", "focused": false,
        "sizing": {"type": "disabled"}
    }));
    let layout = ws.event("layout");
    let vars = &layout["panes"][0]["vars"];
    assert_eq!(
        ["a", "b", "c"].map(|name| vars[name].as_str().map(str::len)),
        [Some(MAX_VALUE - 2); 3],
        "three variables of about a mebibyte each, in one server message"
    );
}
