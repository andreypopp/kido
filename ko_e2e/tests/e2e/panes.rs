use std::fs;
use std::path::Path;
use std::time::{Duration, Instant};

use ko_sys::pid::signal_descendant;
use ko_sys::signal::Signal;
use serde_json::{Value, json};

use crate::harness::{
    PRINT_TOKEN, Run, Server, poll, run_ko, start_with, stays, test_env, wait_gone,
};
use crate::layout::windows;
use crate::runs::{caller, code, has_pane, id_of, ko_as, pane_of, run_of, wait_pane_gone};

type Headers = Vec<(String, String)>;

fn tuned() -> Server {
    start_with(
        Path::new("/bin/sh"),
        &[
            ("KO_LINGER_SECONDS", "0.2"),
            ("KO_STOP_ESCALATION_MS", "600"),
            ("KO_RUN_SCREEN_BYTES", "6000"),
        ],
        &[],
    )
}

fn api(s: &Server, who: Option<&str>, method: &str, path: &str, body: &Value) -> Run {
    let args = ["api", "-X", method, "--input", "-", path];
    ko_as(s, who, &args, &body.to_string())
}

fn post(s: &Server, who: Option<&str>, path: &str, body: &Value) -> Value {
    api(s, who, "POST", path, body).json()
}

fn refused(run: Run, status: u16, kind: &str, why: &str) {
    let body: Value = serde_json::from_str(&run.http_error(status)).unwrap();
    assert_eq!(body["kind"], kind, "{body}");
    assert!(body["message"].as_str().unwrap().contains(why), "{body}");
}

fn raw(s: &Server, method: &str, path: &str, headers: &Headers, body: &Value) -> (u16, Value) {
    let body = if body.is_null() {
        String::new()
    } else {
        body.to_string()
    };
    let (status, data) = s.exchange(method, path, headers, body.as_bytes());
    let text = String::from_utf8_lossy(&data).into_owned();
    (
        status,
        serde_json::from_str(&text).unwrap_or(Value::String(text)),
    )
}

fn window_names(s: &Server, session: usize) -> Vec<String> {
    s.doc()["layout"]["sessions"][session]["windows"]
        .as_array()
        .unwrap()
        .iter()
        .map(|window| window["name"].as_str().unwrap().to_owned())
        .collect()
}

fn cat() -> Value {
    json!({"type": "shell", "command": "exec cat"})
}

fn dies() -> Value {
    json!({"type": "shell", "command": "exit 0"})
}

fn token_pane_in_new_session(s: &Server, session: &str) -> String {
    let command = format!("stty raw -echo; {PRINT_TOKEN}; exec cat");
    let put = s.edit(|layout| {
        layout["sessions"].as_array_mut().unwrap().push(json!({
            "name": session,
            "windows": [{"name": "w", "tree": {"pane": {"new": {"command": {"type": "shell", "command": command}}}}}]
        }));
    });
    let pane = windows(&put).last().unwrap()["tree"]["pane"]
        .as_str()
        .unwrap()
        .to_owned();
    s.screen_has(&pane, "TOKEN<");
    pane
}

// A pane that goes on_exit as soon as it dies: once it is gone, the sweep has judged every pane
// that existed before it.
fn sweep_witness(s: &Server) {
    let made = post(
        s,
        None,
        "/panes",
        &json!({"close": "on_exit", "command": dies()}),
    );
    wait_pane_gone(s, made["pane"].as_str().unwrap());
}

fn placement(s: &Server) {
    let (mut watcher, _) = s.client(None);
    let first = post(s, None, "/panes", &json!({"name": "w1", "command": cat()}));
    let doc = s.doc();
    let session = &doc["layout"]["sessions"][0];
    assert_eq!(session["name"], "", "no session: a new one with no name");
    assert_eq!(first["session"], session["id"]);
    assert_eq!(first["window"], session["windows"][0]["id"]);
    assert_eq!(first["pane"], session["windows"][0]["tree"]["pane"]);
    let p1 = first["pane"].as_str().unwrap().to_owned();
    let event = watcher.event("layout");
    assert_eq!(event["panes"][0]["id"], p1.as_str());
    assert_eq!(event["panes"][0].get("parent"), None);
    assert_eq!(event["panes"][0].get("close"), None);

    post(
        s,
        None,
        "/panes",
        &json!({"session": first["session"], "name": "w3", "command": cat()}),
    );
    let second = post(
        s,
        None,
        "/panes",
        &json!({"name": "w2", "parent": p1, "close": "on_exit", "command": cat()}),
    );
    assert_eq!(second["session"], first["session"], "the parent's session");
    assert_eq!(
        window_names(s, 0),
        ["w1", "w2", "w3"],
        "after the parent's window"
    );
    let p2 = second["pane"].as_str().unwrap();
    let row = s.row(p2);
    assert_eq!(
        (&row["parent"], &row["close"]),
        (&json!(p1), &json!("on_exit"))
    );
    assert_eq!(s.row(&p1).get("close"), None, "keep is the absent default");
    let layout = loop {
        let layout = watcher.event("layout");
        if layout["panes"][0]["id"] == p2 {
            break layout;
        }
    };
    assert_eq!(
        (&layout["panes"][0]["parent"], &layout["panes"][0]["close"]),
        (&json!(p1), &json!("on_exit")),
        "the layout event that adds the pane carries both"
    );

    let other = token_pane_in_new_session(s, "other");
    s.edit(|layout| {
        layout["sessions"][1]["windows"]
            .as_array_mut()
            .unwrap()
            .push(json!({"name": "tail", "tree": {"pane": {"new": {}}}}));
    });
    let third = post(
        s,
        Some(&other),
        "/panes",
        &json!({"name": "c1", "command": cat()}),
    );
    assert_eq!(
        window_names(s, 1),
        ["w", "c1", "tail"],
        "the caller's session, after the caller's window"
    );
    assert_eq!(s.row(third["pane"].as_str().unwrap()).get("parent"), None);
    post(
        s,
        Some(&other),
        "/panes",
        &json!({"session": first["session"], "name": "w4", "command": cat()}),
    );
    assert_eq!(
        window_names(s, 0),
        ["w1", "w2", "w3", "w4"],
        "a named session wins over the caller's, and the window goes last there"
    );

    let varred = post(
        s,
        None,
        "/panes",
        &json!({"vars": {"a": 1, "b": "x"}, "command": cat()}),
    );
    assert_eq!(
        s.row(varred["pane"].as_str().unwrap())["vars"],
        json!({"a": 1, "b": "x"})
    );
    assert_eq!(
        s.doc()["layout"]["sessions"].as_array().unwrap().len(),
        3,
        "no session and no parent or caller is a new session"
    );

    let run = run_of(s, &other, "placed", &["sleep", "300"]);
    assert_eq!(
        window_names(s, 1),
        ["w", "placed", "c1", "tail"],
        "a run goes where a pane goes: after its caller's window"
    );
    s.delete(&format!("/panes/{}", pane_of(&run))).ok();
}

fn refusals_leave_the_document(s: &Server) {
    let live = s.pane("exec cat");
    let dead = s.pane("exit 0");
    poll("the pane to die", || s.row(&dead)["dead"].is_object());
    let before = s.doc();
    let huge = "x".repeat(1 << 20);
    let cases = [
        (json!({"name": 5}), 400, "invalid"),
        (json!({"cwd": "/nonexistent"}), 400, "invalid"),
        (json!({"cwd": "relative"}), 400, "invalid"),
        (
            json!({"command": {"type": "argv", "argv": ["sh"]}}),
            400,
            "invalid",
        ),
        (json!({"vars": {"big": huge}}), 400, "invalid"),
        (json!({"session": "absent"}), 404, "not_found"),
        (json!({"session": "session_999"}), 404, "not_found"),
        (json!({"parent": "pane_999"}), 404, "not_found"),
        (json!({"parent": dead}), 410, "gone"),
    ];
    for (body, status, kind) in cases {
        refused(api(s, None, "POST", "/panes", &body), status, kind, "");
    }
    let put_with = |parent: &str, close: &str| {
        let mut document = before.clone();
        document["layout"]["sessions"][0]["windows"]
            .as_array_mut()
            .unwrap()
            .push(json!({"name": "kid", "tree": {"pane": {"new": {"parent": parent, "close": close}}}}));
        document
    };
    s.request("PUT", "/layout", Some(&put_with("pane_999", "keep")), 404);
    s.request("PUT", "/layout", Some(&put_with(&dead, "keep")), 410);
    let after = s.doc();
    assert_eq!(
        (&after["layout"], &after["revision"]),
        (&before["layout"], &before["revision"]),
        "no refused request changed the document"
    );
    assert!(has_pane(s, &live));

    let put = s.put(&put_with(&live, "on_exit"));
    let kid = put["layout"]["sessions"][0]["windows"]
        .as_array()
        .unwrap()
        .last()
        .unwrap()["tree"]["pane"]
        .as_str()
        .unwrap()
        .to_owned();
    let row = s.row(&kid);
    assert_eq!(
        (&row["parent"], &row["close"]),
        (&json!(live), &json!("on_exit"))
    );

    let version = s.ko(&["api", "/version"], "").json();
    assert_eq!(
        version["instance"].as_str().map(str::len),
        Some(32),
        "{version}"
    );
    let local = run_ko(&s.scratch, &test_env(&s.dir), &["version"], "").json();
    assert_eq!(local.get("instance"), None, "a local ko is no server");
}

fn stops(s: &Server) {
    let caller = caller(s);
    let stop = |pane: &str, wait_ms: u64| {
        api(
            s,
            None,
            "POST",
            &format!("/panes/{pane}/stop"),
            &json!({"wait_ms": wait_ms}),
        )
    };

    let polite = s.pane("sleep 0.6; exit 0");
    let began = Instant::now();
    stop(&polite, 4000).ok();
    let took = began.elapsed();
    assert!(
        took >= Duration::from_millis(400) && took < Duration::from_secs(3),
        "the stop ended with the pane: {took:?}"
    );
    assert!(!has_pane(s, &polite));

    let patient = s.pane("exec cat");
    let began = Instant::now();
    stop(&patient, 300).ok();
    assert!(began.elapsed() >= Duration::from_millis(250));
    assert!(!has_pane(s, &patient), "removed when the wait ran out");

    let hasty = s.pane("exec cat");
    stop(&hasty, 0).ok();
    assert!(!has_pane(s, &hasty), "no wait removes at once");

    let ended = s.pane("exit 0");
    poll("the pane to die", || s.row(&ended)["dead"].is_object());
    stop(&ended, 4000).ok();
    assert!(!has_pane(s, &ended), "a dead pane is removed at once");

    refused(stop("pane_999", 0), 404, "not_found", "");
    refused(stop(&caller, 3_600_001), 400, "invalid", "too long");
    assert!(has_pane(s, &caller), "a refused stop removes nothing");

    let run = run_of(s, &caller, "stopped-by-pane", &["sleep", "300"]);
    stop(pane_of(&run), 0).ok();
    wait_pane_gone(s, pane_of(&run));
    assert_eq!(
        crate::runs::ending(s, id_of(&run)).0,
        "died",
        "a pane stop records no outcome of the run"
    );
}

fn escalation(s: &Server) {
    let delay = Duration::from_millis(600);
    let pane = s.pane("trap '' HUP; exec sleep 300");
    let program = s.pane_program(&pane);
    let pane_process = program.parent().expect("the pane process");
    signal_descendant(s.child.pid(), pane_process, Signal::Stop).unwrap();

    let began = Instant::now();
    api(s, None, "POST", &format!("/panes/{pane}/stop"), &json!({})).ok();
    wait_pane_gone(s, &pane);
    stays(
        "the program lived on while its stopped pane process could not hang it up",
        Duration::from_millis(250),
        || !program.has_ended(),
    );
    wait_gone(program, "the coordinator's escalation");
    wait_gone(pane_process, "the coordinator's escalation");
    let took = began.elapsed();
    assert!(took >= delay, "{took:?}");
    assert!(
        took < Duration::from_secs(3),
        "the configured delay, not the 5 s default: {took:?}"
    );
}

fn closing(s: &Server) {
    let new = |body: Value| {
        post(s, None, "/panes", &body)["pane"]
            .as_str()
            .unwrap()
            .to_owned()
    };
    let gone = new(json!({"command": dies(), "close": "on_exit"}));
    let kept = new(json!({"command": dies(), "close": "keep"}));
    let shown = new(json!({"command": dies(), "close": "on_exit"}));
    let (mut client, _) = s.app_client(json!({"pane": shown}), true, (80, 24));
    wait_pane_gone(s, &gone);
    sweep_witness(s);
    assert!(
        has_pane(s, &kept) && has_pane(s, &shown),
        "a pane that keeps, or that a focused client shows, went"
    );
    client.send(&json!({"type": "focused", "focused": false}));
    wait_pane_gone(s, &shown);
    assert!(has_pane(s, &kept), "keep stays dead");

    let parent = new(json!({"command": cat()}));
    let live_child = new(json!({"parent": parent, "command": cat()}));
    let dead_child = new(json!({"parent": parent, "command": dies()}));
    let grandchild = new(json!({"parent": live_child, "command": cat()}));
    poll("the dead child to die", || {
        s.row(&dead_child)["dead"].is_object()
    });
    sweep_witness(s);
    assert!(
        [&live_child, &dead_child, &grandchild]
            .iter()
            .all(|pane| has_pane(s, pane)),
        "a child went while its parent lived"
    );
    s.delete(&format!("/panes/{parent}")).ok();
    for pane in [&live_child, &dead_child, &grandchild] {
        wait_pane_gone(s, pane);
    }

    let gate = s.scratch.join("gate");
    let wait = format!("while [ ! -f {} ]; do sleep 0.05; done", gate.display());
    let mortal = new(json!({"command": {"type": "shell", "command": wait}}));
    let dependent = new(json!({"parent": mortal, "command": cat()}));
    fs::write(&gate, "").unwrap();
    wait_pane_gone(s, &dependent);
    assert!(
        s.row(&mortal)["dead"].is_object(),
        "a dead parent that keeps stays, and its child goes"
    );
}

fn captured_screen(s: &Server) {
    let caller = caller(s);
    let run = run_of(
        s,
        &caller,
        "long",
        &["sh", "-c", "seq 1 1500; echo LAST-LINE; exit 3"],
    );
    wait_pane_gone(s, pane_of(&run));
    let screen = s
        .ko(&["api", &format!("/runs/{}/screen", id_of(&run))], "")
        .ok();
    assert_eq!(
        screen.len(),
        6000,
        "the end up to the configured size: {}",
        screen.len()
    );
    assert!(screen.contains("LAST-LINE"));
    assert!(
        screen.contains("\n400\n"),
        "the history from before the last 1000 rows is kept"
    );
    assert!(!screen.contains("\n50\n"), "the head beyond the cap is cut");
    let shown = ko_as(s, None, &["runs", id_of(&run)], "").ok();
    assert!(
        shown.contains("screen:\n") && shown.contains("LAST-LINE"),
        "{shown}"
    );
    let listed = ko_as(s, None, &["runs", "--json", id_of(&run)], "").json();
    assert_eq!(listed.get("screen"), None, "the detail names no screen");
    let none = ko_as(
        s,
        None,
        &["api", "/runs/00000000000000000000000000000000/screen"],
        "",
    );
    assert_eq!(code(&none), 1);
}

fn identity(s: &Server) {
    let user = s.headers();
    let p = caller(s);
    let q = s.token_pane("exec cat");
    let r = token_pane_in_new_session(s, "elsewhere");
    let (by_p, by_q) = (s.as_pane(&p), s.as_pane(&q));
    let token_p = s.token(&p).unwrap();
    let forged = "0123456789abcdef0123456789abcdef";
    let put = |headers: &Headers, pane: &str| {
        raw(
            s,
            "PUT",
            &format!("/panes/{pane}/vars/x"),
            headers,
            &json!(1),
        )
    };
    let refuses = |(status, reply): (u16, Value), why: &str| {
        assert_eq!(
            (status, reply["kind"].as_str()),
            (409, Some("refused")),
            "{reply}"
        );
        assert!(reply["message"].as_str().unwrap().contains(why), "{reply}");
    };

    refuses(
        put(
            &s.headers_with(&[("Ko-Pane", &p), ("Ko-Pane-Token", forged)]),
            &p,
        ),
        "does not match",
    );
    refuses(
        put(&s.headers_with(&[("Ko-Pane", &p)]), &p),
        "needs Ko-Pane-Token",
    );
    refuses(
        put(&s.headers_with(&[("Ko-Pane-Token", &token_p)]), &p),
        "needs Ko-Pane",
    );
    refuses(
        put(
            &s.headers_with(&[("Ko-Pane", &q), ("Ko-Pane-Token", &token_p)]),
            &p,
        ),
        "does not match",
    );
    refuses(
        put(
            &s.headers_with(&[("Ko-Pane", "pane_999"), ("Ko-Pane-Token", &token_p)]),
            &p,
        ),
        "does not match",
    );
    refuses(
        put(
            &s.headers_with(&[("Ko-Pane", &p), ("Ko-Pane-Token", "short")]),
            &p,
        ),
        "does not match",
    );
    let ended = s.token_pane("exit 0");
    poll("the pane to die", || s.row(&ended)["dead"].is_object());
    refuses(put(&s.as_pane(&ended), &ended), "does not match");

    assert_eq!(put(&by_p, &p).0, 200, "a pane sets its own variable");
    refuses(put(&by_p, &q), "only its own variables");
    refuses(
        raw(
            s,
            "DELETE",
            &format!("/panes/{q}/vars/x"),
            &by_p,
            &Value::Null,
        ),
        "only its own variables",
    );
    assert_eq!(put(&user, &q).0, 200, "the user may set any variable");
    assert_eq!(put(&by_q, &q).0, 200);

    let child_body = |parent: &str| json!({"parent": parent, "command": cat()});
    refused(
        api(s, Some(&p), "POST", "/panes", &child_body(&q)),
        409,
        "refused",
        "name only itself",
    );
    let child = post(s, Some(&p), "/panes", &child_body(&p))["pane"]
        .as_str()
        .unwrap()
        .to_owned();

    let run_body =
        |parent: &str| json!({"name": "r", "argv": ["/bin/sleep", "300"], "parent": parent});
    refused(
        api(s, Some(&p), "POST", "/runs", &run_body(&q)),
        409,
        "refused",
        "name only itself",
    );
    let run = post(s, Some(&p), "/runs", &run_body(&p));
    assert_eq!(s.row(run["pane"].as_str().unwrap())["parent"], p.as_str());

    let stop = |who: Option<&str>, pane: &str| {
        api(s, who, "POST", &format!("/panes/{pane}/stop"), &json!({}))
    };
    refused(
        stop(Some(&p), &r),
        409,
        "refused",
        "not a child, sibling or ancestor",
    );
    assert!(has_pane(s, &r));
    stop(Some(&p), &q).ok();
    assert!(!has_pane(s, &q), "a sibling is in scope");
    stop(Some(&p), &child).ok();
    assert!(!has_pane(s, &child), "a child is in scope");
    stop(None, &r).ok();
    assert!(!has_pane(s, &r), "the user stops any pane");

    let other = s.token_pane("exec cat");
    refused(
        api(
            s,
            Some(&p),
            "PUT",
            &format!("/panes/{other}/vars/y"),
            &json!(1),
        ),
        409,
        "refused",
        "only its own variables",
    );
    api(s, Some(&p), "PUT", &format!("/panes/{p}/vars/y"), &json!(1)).ok();
    api(s, None, "PUT", &format!("/panes/{other}/vars/y"), &json!(1)).ok();
}

#[test]
fn panes_are_made_stopped_swept_and_acted_for_by_their_token() {
    let s = tuned();
    placement(&s);
    refusals_leave_the_document(&s);
    stops(&s);
    escalation(&s);
    closing(&s);
    captured_screen(&s);
    identity(&s);
}
