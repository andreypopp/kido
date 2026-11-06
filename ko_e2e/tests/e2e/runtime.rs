use std::fs;
use std::ops::Deref;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::Duration;

use ko_sys::pid::Pid;
use serde_json::{Value, json};

use crate::harness::{
    DEADLINE, Dir, Message, PRINT_TOKEN, Server, Ws, base64, poll, quote, run_ko, run_program, sh,
    start_in, start_with, stays, test_env, text_of, wait_gone,
};

use crate::outer::{Keys, Outer};
use crate::panes::{as_pane, headers, post, raw, raw_on, refuses, token_pane_in_new_session};

fn ids(rows: &Value) -> Vec<&str> {
    rows.as_array()
        .unwrap()
        .iter()
        .map(|row| row["id"].as_str().unwrap())
        .collect()
}

pub(crate) struct Rt {
    pub(crate) server: Server,
    pub(crate) config: Dir,
}

impl Deref for Rt {
    type Target = Server;

    fn deref(&self) -> &Server {
        &self.server
    }
}

fn serve(config: &str, env: &[(&str, &str)]) -> Rt {
    serve_in(Dir::new("ko-"), config, env)
}

impl Rt {
    fn rewrite(&self, config: &str) {
        fs::write(self.config.join("config.yaml"), config).unwrap();
    }
}

pub(crate) fn serve_in(dir: Dir, text: &str, env: &[(&str, &str)]) -> Rt {
    let config = Dir::new("ko-rtc-");
    let file = config.join("config.yaml");
    fs::write(&file, text).unwrap();
    let mut env = env.to_vec();
    env.push(("KO_RUNTIME_COMMAND_KIND", "1"));
    let server = start_in(
        dir,
        Path::new("/bin/sh"),
        &env,
        &["--config", text_of(&file)],
    );
    Rt { server, config }
}

fn sh_run(scratch: &Path, script: &str) {
    run_program(
        scratch,
        Path::new("/bin/sh"),
        &[],
        &["-c", script],
        "",
        DEADLINE,
    )
    .ok();
}

fn fifos(dir: &Path, names: &[String]) -> Vec<PathBuf> {
    let paths: Vec<PathBuf> = names.iter().map(|name| dir.join(name)).collect();
    let args: Vec<&str> = paths.iter().map(|path| text_of(path)).collect();
    run_program(dir, Path::new("/usr/bin/mkfifo"), &[], &args, "", DEADLINE).ok();
    paths
}

pub(crate) fn fifo(dir: &Path, name: &str) -> PathBuf {
    fifos(dir, &[name.to_owned()]).remove(0)
}

pub(crate) fn release(scratch: &Path, fifo: &Path, text: &str) {
    sh_run(
        scratch,
        &format!("printf '%s\\n' {} > {}", quote(text), quote(text_of(fifo))),
    );
}

pub(crate) fn rt_pane(s: &Server, runtime: &str, script: &str) -> String {
    s.new_pane(sh_in(runtime, script))
}

pub(crate) fn sh_in(runtime: &str, script: &str) -> Value {
    let mut request = sh(script);
    request["runtime"] = json!(runtime);
    request
}

fn rt_token_pane(s: &Server, runtime: &str) -> String {
    s.token_pane_with(json!({"runtime": runtime}), "exec cat")
}

pub(crate) fn info(s: &Server, runtime: &str) -> Value {
    serde_json::from_str(&s.request("GET", &format!("/runtimes/{runtime}"), None, 200)).unwrap()
}

pub(crate) fn state(s: &Server, runtime: &str) -> String {
    info(s, runtime)["state"]["type"]
        .as_str()
        .unwrap()
        .to_owned()
}

pub(crate) fn wait_state(s: &Server, runtime: &str, want: &str) -> Value {
    let mut last = Value::Null;
    poll(&format!("runtime {runtime} to be {want}"), || {
        last = info(s, runtime);
        last["state"]["type"] == want
    });
    last
}

fn via(
    s: &Server,
    runtime: &str,
    route: (&str, &str),
    who: Option<(&str, &str)>,
    body: &Value,
) -> (u16, Value) {
    let socket = s.dir.join("runtimes").join(runtime).join("io/socket");
    let extra: Vec<(&str, &str)> = who
        .map(|(pane, token)| vec![("Ko-Pane", pane), ("Ko-Pane-Token", token)])
        .unwrap_or_default();
    raw_on(s, &socket, route, &headers(s, &extra), body)
}

pub(crate) fn dead(s: &Server, pane: &str) -> Value {
    s.wait_row(pane, &format!("{pane} to end"), |row| {
        !row["dead"].is_null()
    })
}

pub(crate) fn stop_pane(s: &Server, pane: &str) {
    post(s, None, &format!("/panes/{pane}/stop"), &json!({}));
}

fn session_named(s: &Server, name: &str) -> String {
    s.doc()["layout"]["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|session| session["name"] == name)
        .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_owned()
}

fn define_command(s: &Server, pane: &str, name: &str) {
    s.ko_as(
        Some(pane),
        &[
            "api",
            "--method",
            "PUT",
            "--input",
            "-",
            &format!("/runtimes/{name}"),
        ],
        "{\"command\":{}}",
    )
    .ok();
}

#[test]
fn adhoc_boundary_runtime_connections_cannot_create_in_another_session() {
    let s = serve("", &[]);
    let a = token_pane_in_new_session(&s, "a");
    let b = token_pane_in_new_session(&s, "b");
    let sa = session_named(&s, "a");
    let sb = session_named(&s, "b");
    define_command(&s, &a, "dev");
    define_command(&s, &b, "dev");
    let pane = s.token_pane_with(json!({"session": sa, "runtime": "dev"}), "exec cat");
    let token = s.token(&pane).unwrap();
    refuses(
        via(
            &s,
            &format!("{sa}-dev"),
            ("PUT", "/runtimes/nested"),
            Some((&pane, &token)),
            &json!({"command": {}}),
        ),
        "PUT /runtimes/nested is not available on a runtime connection",
    );
    let response = via(
        &s,
        &format!("{sa}-dev"),
        ("POST", "/panes"),
        Some((&pane, &token)),
        &json!({"session": sb, "runtime": "dev", "command": {"type":"shell", "command":"exec cat"}}),
    );
    assert_eq!(
        response.0, 409,
        "cross-session runtime creation: {}",
        response.1
    );
    assert_eq!(response.1["kind"], "refused");
}

#[test]
fn adhoc_boundary_layout_removal_drops_the_session_definition() {
    let s = serve("", &[]);
    let a = token_pane_in_new_session(&s, "a");
    token_pane_in_new_session(&s, "b");
    let sa = session_named(&s, "a");
    define_command(&s, &a, "dev");
    let (mut client, _) = s.client(None);
    s.edit(|layout| {
        let sessions = layout["sessions"].as_array_mut().unwrap();
        let at = sessions
            .iter()
            .position(|session| session["id"] == sa)
            .unwrap();
        let removed = sessions.remove(at);
        let target = sessions
            .iter_mut()
            .find(|session| session["name"] == "b")
            .unwrap();
        target["windows"]
            .as_array_mut()
            .unwrap()
            .extend(removed["windows"].as_array().unwrap().iter().cloned());
    });
    let response = raw(
        &s,
        "GET",
        &format!("/runtimes/dev?session={sa}"),
        &s.headers(),
        &Value::Null,
    );
    assert_eq!(
        response.0, 404,
        "definition after PUT /layout removed its session: {}",
        response.1
    );
    loop {
        let Message::Text(text) = client.read() else {
            continue;
        };
        let event: Value = serde_json::from_str(&text).unwrap();
        if event
            == json!({"type":"runtime_deleted", "name":"dev", "source":{"type":"session", "id":sa}})
        {
            break;
        }
    }
}

#[test]
fn adhoc_boundary_a_configured_pane_cannot_move_under_a_session_shadow() {
    let s = serve("", &[]);
    token_pane_in_new_session(&s, "a");
    let b = token_pane_in_new_session(&s, "b");
    let sa = session_named(&s, "a");
    let sb = session_named(&s, "b");
    define_command(&s, &b, "dev");
    s.rewrite("runtimes:\n  dev: {command: {}}\n");
    let pane = s.token_pane_with(json!({"session":sa, "runtime":"dev"}), "exec cat");
    s.rewrite("runtimes: [");
    let renamed = s.edit(|layout| {
        layout["sessions"][0]["windows"][0]["name"] = json!("renamed");
    });
    assert_eq!(
        renamed["layout"]["sessions"][0]["windows"][0]["name"],
        "renamed"
    );
    s.rewrite("runtimes:\n  dev: {command: {}}\n");
    let mut doc = s.doc();
    let sessions = doc["layout"]["sessions"].as_array_mut().unwrap();
    let source = sessions
        .iter_mut()
        .find(|session| session["id"] == sa)
        .unwrap();
    let windows = source["windows"].as_array_mut().unwrap();
    let at = windows
        .iter()
        .position(|window| window["tree"]["pane"] == pane)
        .unwrap();
    let moved = windows.remove(at);
    sessions
        .iter_mut()
        .find(|session| session["id"] == sb)
        .unwrap()["windows"]
        .as_array_mut()
        .unwrap()
        .push(moved);
    let response = raw(&s, "PUT", "/layout", &s.headers(), &doc);
    assert_eq!(
        response.0, 400,
        "configured pane moved under shadow: {}",
        response.1
    );
    assert_eq!(response.1["kind"], "invalid");
}

#[test]
fn adhoc_containers_delete_stale_owned_state_once_and_delete_at_server_exit() {
    let files = Dir::new("ko-rtf-");
    let (kind, delete) = if cfg!(target_os = "linux") {
        ("podman", "rm")
    } else {
        ("container", "delete")
    };
    crate::shell::fake(&files, kind);
    let log = files.join("calls");
    let version = run_ko(&files, &test_env(&files), &["version"], "").ok();
    let path = format!("{}:/usr/bin:/bin", files.display());
    let s = serve(
        &format!(
            "runtimes:\n  configured:\n    {kind}:\n      from: {{image: image}}\n      ko: path\n"
        ),
        &[
            ("PATH", &path),
            ("KO_FAKE_ENGINE_LOG", text_of(&log)),
            ("KO_FAKE_ENGINE_VERSION", &version),
        ],
    );
    assert_eq!(
        s.ko(
            &["run", "container", "--name", "dev", "--from-image", "image"],
            ""
        )
        .error(1),
        "ko run: needs a pane\n"
    );
    assert_eq!(
        s.ko(&["run", "--name", "dev"], "").error(1),
        "ko run: needs a pane\n"
    );
    let mut nested = test_env(&files);
    nested.push(b"KO_RUNTIME=dev".to_vec());
    assert_eq!(
        run_ko(
            &files,
            &nested,
            &["run", "container", "--name", "dev", "--from-image", "image"],
            ""
        )
        .error(1),
        "ko run: inside runtime dev; run it from a host pane\n"
    );
    let host = token_pane_in_new_session(&s, "adhoc");
    s.ko_as(
        Some(&host),
        &["api", "--method", "PUT", "--input", "-", "/runtimes/dev"],
        &json!({kind: {"from": {"image": "image"}, "ko": "path"}}).to_string(),
    )
    .ok();
    assert_eq!(
        s.ko_as(Some(&host), &["run", "--name", "dev"], "").error(1),
        "ko run: needs the pane's terminal\n"
    );
    assert!(!log.exists());
    let definition: Value =
        serde_json::from_str(&s.ko_as(Some(&host), &["api", "/runtimes/dev"], "").ok()).unwrap();
    let session = definition["source"]["id"].as_str().unwrap();
    let run = || {
        let mut ws = s
            .dial_ws("/runtimes/dev/exec", Some(as_pane(&s, &host)), 101)
            .unwrap();
        ws.send(
            &json!({"type": "exec", "argv": ["/bin/sh", "-c", "printf works"], "stdin": false}),
        );
        let done = read_exec(&mut ws);
        assert_eq!(done.end, json!({"type": "exit", "status": 0}));
        let info: Value =
            serde_json::from_str(&s.ko_as(Some(&host), &["api", "/runtimes/dev"], "").ok())
                .unwrap();
        assert_eq!(info["state"]["type"], "up");
    };
    run();
    let calls = fs::read_to_string(&log).unwrap();
    assert!(
        calls.contains(&format!(
            "{delete} --force ko-{session}-dev\nrun -d --name ko-{session}-dev"
        )),
        "{calls}"
    );
    s.ko_as(
        Some(&host),
        &[
            "api",
            "--method",
            "POST",
            "--input",
            "-",
            "/runtimes/dev/down",
        ],
        "{}",
    )
    .ok();
    run();
    let calls = fs::read_to_string(&log).unwrap();
    assert_eq!(
        calls
            .lines()
            .filter(|line| line.starts_with(&format!("{delete} ")))
            .count(),
        1
    );
    let mut configured = start_exec(
        &s,
        "configured",
        json!({"argv": ["/bin/true"], "stdin": false}),
    );
    assert_eq!(
        read_exec(&mut configured).end,
        json!({"type": "exit", "status": 0})
    );
    assert_eq!(info(&s, "configured")["state"]["type"], "up");
    s.ko(&["kill-server"], "").ok();
    poll("the detached delete cleanup", || {
        fs::read_to_string(&log).is_ok_and(|text| {
            text.lines()
                .filter(|line| line.starts_with(&format!("{delete} ")))
                .count()
                == 2
                && text.lines().any(|line| line == "stop ko-configured")
        })
    });
    let calls = fs::read_to_string(&log).unwrap();
    assert!(
        !calls
            .lines()
            .any(|line| line == format!("{delete} --force ko-configured")),
        "{calls}"
    );
}

#[test]
fn adhoc_definitions_resolve_in_the_session_and_end_with_it() {
    let s = serve("runtimes:\n  configured:\n    command: {}\n", &[]);
    let a = token_pane_in_new_session(&s, "a");
    let b = token_pane_in_new_session(&s, "b");
    let doc = s.doc();
    let sessions = doc["layout"]["sessions"].as_array().unwrap();
    let sa = sessions[sessions.len() - 2]["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let sb = sessions[sessions.len() - 1]["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let definition = json!({"command": {}, "pi": "host"});
    let api = |pane: Option<&str>, method: &str, path: &str, body: &Value| -> Value {
        let mut args = vec!["api", "--method", method, path];
        if !body.is_null() {
            args.extend(["--input", "-"]);
        }
        let text = s.ko_as(pane, &args, &body.to_string()).ok();
        serde_json::from_str(&text).unwrap()
    };
    let (mut client, _) = s.client(None);
    let (status, error) = raw(
        &s,
        "PUT",
        "/runtimes/bad",
        &as_pane(&s, &a),
        &json!({"command": []}),
    );
    assert_eq!(status, 400);
    assert_eq!(error["kind"], "invalid");
    let registered = api(Some(&a), "PUT", "/runtimes/dev", &definition);
    assert_eq!(registered["source"], json!({"type": "session", "id": sa}));
    assert_eq!(registered["state"]["type"], "down");
    assert_eq!(
        api(Some(&a), "PUT", "/runtimes/dev", &definition),
        registered
    );
    let listed = api(Some(&a), "GET", "/runtimes", &Value::Null);
    assert!(
        listed
            .as_array()
            .unwrap()
            .iter()
            .any(|entry| entry["source"] == registered["source"])
    );
    assert!(
        !api(Some(&b), "GET", "/runtimes", &Value::Null)
            .as_array()
            .unwrap()
            .iter()
            .any(|entry| entry["name"] == "dev")
    );
    let (status, error) = raw(&s, "GET", "/runtimes/dev", &as_pane(&s, &b), &Value::Null);
    assert_eq!(status, 404);
    assert_eq!(
        error["message"],
        format!(
            "no runtime dev in {sb} or in {}",
            s.config.join("config.yaml").display()
        )
    );
    let (status, error) = raw(
        &s,
        "PUT",
        "/runtimes/dev",
        &as_pane(&s, &a),
        &json!({"command": {}, "pi": "runtime"}),
    );
    assert_eq!(status, 409);
    assert_eq!(
        error["message"],
        format!("runtime dev of {sa} has another definition; delete it or use another name")
    );
    let (status, error) = raw(
        &s,
        "PUT",
        "/runtimes/configured",
        &as_pane(&s, &a),
        &definition,
    );
    assert_eq!(status, 409);
    assert_eq!(
        error["message"],
        format!(
            "configured is a runtime of {}",
            s.config.join("config.yaml").display()
        )
    );
    let (status, error) = raw(&s, "PUT", "/runtimes/user", &s.headers(), &definition);
    assert_eq!(status, 409);
    assert_eq!(
        error["message"],
        "define an ad-hoc runtime from a pane of its session"
    );
    api(Some(&a), "PUT", "/runtimes/disposable", &definition);
    api(Some(&a), "DELETE", "/runtimes/disposable", &Value::Null);
    let (status, _) = raw(
        &s,
        "GET",
        "/runtimes/disposable",
        &as_pane(&s, &a),
        &Value::Null,
    );
    assert_eq!(status, 404);
    let second = api(
        Some(&b),
        "PUT",
        "/runtimes/dev",
        &json!({"command": {"prefix": ["/usr/bin/env", "SESSION_MARK=b"]}, "pi": "runtime"}),
    );
    assert_eq!(second["source"], json!({"type": "session", "id": sb}));
    assert_eq!(second["pi"], "runtime");
    let all = api(None, "GET", "/runtimes", &Value::Null);
    assert_eq!(
        all.as_array()
            .unwrap()
            .iter()
            .filter(|entry| entry["name"] == "dev")
            .count(),
        2
    );
    assert_eq!(
        api(
            None,
            "GET",
            &format!("/runtimes/dev?session={sa}"),
            &Value::Null
        ),
        registered
    );
    let mut exec = s
        .dial_ws("/runtimes/dev/exec", Some(as_pane(&s, &a)), 101)
        .unwrap();
    exec.send(&json!({"type": "exec", "argv": ["/bin/sh", "-c", "printf routed"], "stdin": false}));
    let done = read_exec(&mut exec);
    assert_eq!(done.stdout, b"routed");
    assert_eq!(done.end, json!({"type": "exit", "status": 0}));
    let mut request = sh(
        "ko api /version; printf 'RUNTIME=%s MARK=%s\\n' \"$KO_RUNTIME\" \"$SESSION_MARK\"; exec cat",
    );
    request["runtime"] = json!("dev");
    request["parent"] = json!(a);
    let pane = api(Some(&a), "POST", "/panes", &request)["pane"]
        .as_str()
        .unwrap()
        .to_owned();
    s.screen_has(&pane, "RUNTIME=dev MARK=");
    s.screen_has(&pane, "protocol");
    request["parent"] = json!(b);
    let other = api(Some(&b), "POST", "/panes", &request)["pane"]
        .as_str()
        .unwrap()
        .to_owned();
    s.screen_has(&other, "RUNTIME=dev MARK=b");
    s.screen_has(&other, "protocol");
    let put = s.edit(|layout| {
        let session = layout["sessions"].as_array_mut().unwrap().iter_mut().find(|session| session["id"] == sa).unwrap();
        session["windows"].as_array_mut().unwrap().push(json!({"name": "layout-born", "tree": {"pane": {"new": sh_in("dev", "printf layout-born; exec cat")}}}));
    });
    let layout_born = put["layout"]["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|session| session["id"] == sa)
        .unwrap()["windows"]
        .as_array()
        .unwrap()
        .last()
        .unwrap()["tree"]["pane"]
        .as_str()
        .unwrap()
        .to_owned();
    s.screen_has(&layout_born, "layout-born");
    s.rewrite("runtimes:\n  configured: {command: {}}\n  dev: {command: {}, pi: runtime}\n");
    assert_eq!(
        api(Some(&a), "GET", "/runtimes/dev", &Value::Null)["source"],
        registered["source"]
    );
    assert_eq!(
        api(None, "GET", "/runtimes/dev", &Value::Null)["source"],
        json!({"type": "config"})
    );
    s.rewrite("runtimes:\n  configured: {command: {}}\n");
    let mut moved = s.doc();
    let windows = moved["layout"]["sessions"].as_array_mut().unwrap();
    let source = windows
        .iter()
        .position(|session| session["id"] == sa)
        .unwrap();
    let target = windows
        .iter()
        .position(|session| session["id"] == sb)
        .unwrap();
    let at = windows[source]["windows"]
        .as_array()
        .unwrap()
        .iter()
        .position(|window| window["tree"]["pane"] == pane)
        .unwrap();
    let window = windows[source]["windows"]
        .as_array_mut()
        .unwrap()
        .remove(at);
    windows[target]["windows"]
        .as_array_mut()
        .unwrap()
        .push(window);
    let (status, error) = raw(&s, "PUT", "/layout", &s.headers(), &moved);
    assert_eq!(status, 400);
    assert_eq!(
        error["message"],
        format!("{pane} runs in runtime dev of {sa}")
    );
    api(None, "DELETE", &format!("/sessions/{sa}"), &Value::Null);
    let (status, _) = raw(
        &s,
        "GET",
        &format!("/runtimes/dev?session={sa}"),
        &s.headers(),
        &Value::Null,
    );
    assert_eq!(status, 404);
    poll("runtime socket to go", || {
        !s.dir.join(format!("runtimes/{sa}-dev/io/socket")).exists()
    });
    let expected =
        json!({"type": "runtime_deleted", "name": "dev", "source": {"type": "session", "id": sa}});
    loop {
        if let Message::Text(text) = client.read() {
            let event: Value = serde_json::from_str(&text).unwrap();
            if event == expected {
                break;
            }
        }
    }
}

#[test]
fn a_runtime_pane_runs_through_the_wrapper_and_its_token_file_is_private_and_used_once() {
    let files = Dir::new("ko-rtf-");
    let gate = fifo(&files, "gate");
    let wait = format!("read x < {}; exec \"$@\"", quote(text_of(&gate)));
    let s = serve(
        &format!(
            r#"
runtimes:
  dev:
    command:
      prefix: ["/bin/sh", "-c", {wait:?}, "sh"]
"#
        ),
        &[],
    );

    let script = format!("stty raw -echo; {PRINT_TOKEN}; exec cat");
    let pane = rt_pane(&s, "dev", &script);
    let file = s
        .dir
        .join("runtimes/dev/panes")
        .join(format!("{pane}.token"));
    poll("the token file", || file.exists());
    let mode = |path: &Path| fs::metadata(path).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode(&file), 0o600);
    assert_eq!(mode(file.parent().unwrap()), 0o700);
    assert_eq!(mode(&s.dir.join("runtimes/dev")), 0o755);
    assert_eq!(mode(&s.dir.join("runtimes/dev/io/socket")), 0o666);
    let written = fs::read_to_string(&file).unwrap();
    assert_eq!(written.len(), 32);
    let row = s.row(&pane);
    assert_eq!(row["runtime"], "dev");
    assert_eq!(
        row["command"],
        json!(["/bin/sh", "-c", script]),
        "the row records the command that was asked for, not the wrapper"
    );
    assert!(
        !row["command"].to_string().contains(&written),
        "the token is in no argv: {row}"
    );

    release(&s.scratch, &gate, "go");
    s.screen_has(&pane, "TOKEN<");
    assert_eq!(s.token(&pane).as_deref(), Some(written.as_str()));
    poll("ko enter to unlink the token file", || !file.exists());

    let second = rt_pane(&s, "dev", "exec cat");
    let second_file = s
        .dir
        .join("runtimes/dev/panes")
        .join(format!("{second}.token"));
    poll("the second token file", || second_file.exists());
    stop_pane(&s, &second);
    poll("the token file to go with its pane", || {
        !second_file.exists()
    });

    let listing = s.ko(&["panes"], "").ok();
    let header = listing.lines().next().unwrap();
    assert!(header.contains("RUNTIME"), "{listing}");
    let line_of = |pane: &str| {
        listing
            .lines()
            .find(|line| line.starts_with(pane))
            .unwrap()
            .to_owned()
    };
    assert!(line_of(&pane).contains("dev"), "{listing}");
    let host = s.pane("exec cat");
    let again = s.ko(&["panes"], "").ok();
    let host_line = again.lines().find(|line| line.starts_with(&host)).unwrap();
    assert!(
        host_line.split_whitespace().nth(3) == Some("-"),
        "a host pane has no runtime: {again}"
    );
}

#[test]
fn a_runtime_connection_acts_as_a_pane_of_its_runtime_and_sees_only_its_scope() {
    let maps = Dir::new("ko-rtm-");
    fs::create_dir_all(maps.join("host/sub")).unwrap();
    fs::create_dir_all(maps.join("rt/sub")).unwrap();
    let s = serve(
        &format!(
            r#"
runtimes:
  dev:
    command: {{}}
    env:
      RT_VAR: runtime
      BOTH: runtime
    cwd: /
    paths:
      - host: {host}
        runtime: {rt}
  other:
    command: {{}}
    pi: runtime
"#,
            host = text_of(&maps.join("host")),
            rt = text_of(&maps.join("rt")),
        ),
        &[],
    );
    let (dev, other) = (info(&s, "dev"), info(&s, "other"));
    assert_eq!((&dev["pi"], &dev["cwd"]), (&json!("host"), &json!("/")));
    assert_eq!((&other["pi"], other.get("cwd")), (&json!("runtime"), None));
    let host = s.token_pane("exec cat");
    let elsewhere = token_pane_in_new_session(&s, "elsewhere");
    let doc = s.doc();
    let sessions = doc["layout"]["sessions"].as_array().unwrap();
    let own = sessions.first().unwrap()["id"].as_str().unwrap();
    let other_session = sessions.last().unwrap()["id"].as_str().unwrap();
    let own_path = format!("/runtimes/dev?session={own}");
    refuses(
        raw(
            &s,
            "GET",
            &format!("/runtimes/dev?session={other_session}"),
            &as_pane(&s, &host),
            &Value::Null,
        ),
        "a pane may name only its own session",
    );
    for identity in [as_pane(&s, &host), s.headers()] {
        let (status, runtime) = raw(&s, "GET", &own_path, &identity, &Value::Null);
        assert_eq!(status, 200, "{runtime}");
        assert_eq!(runtime["source"], json!({"type": "config"}));
        assert_eq!(runtime["name"], "dev");
    }
    let r1 = rt_token_pane(&s, "dev");
    let r2 = rt_token_pane(&s, "other");
    let t1 = s.token(&r1).unwrap();
    let who = Some((r1.as_str(), t1.as_str()));
    let cat = json!({"type": "shell", "command": "exec cat"});
    let forged = "0123456789abcdef0123456789abcdef";
    let host_token = s.token(&host).unwrap();
    let other_token = s.token(&r2).unwrap();

    let read = |path: &str, who| via(&s, "dev", ("GET", path), who, &Value::Null);
    refuses(
        read("/panes", None),
        "a runtime connection must act as one of its panes",
    );
    refuses(
        read("/panes", Some((&r1, forged))),
        "Ko-Pane-Token does not match Ko-Pane",
    );
    refuses(
        read("/panes", Some((&host, &host_token))),
        "must act as one of its panes",
    );
    refuses(
        read("/panes", Some((&r2, &other_token))),
        "must act as one of its panes",
    );
    for path in [
        "/client",
        &format!("/panes/{r1}/view"),
        &format!("/panes/{r1}/search?needle=x"),
    ] {
        let socket = s.dir.join("runtimes/dev/io/socket");
        let mut sent = s.headers();
        sent.push(("Ko-Pane".to_owned(), r1.clone()));
        sent.push(("Ko-Pane-Token".to_owned(), t1.clone()));
        s.dial_ws_on(&socket, path, Some(sent), 409);
    }
    refuses(
        via(
            &s,
            "dev",
            ("PUT", "/layout"),
            who,
            &json!({"revision": 0, "layout": {"sessions": []}}),
        ),
        "not available on a runtime connection",
    );
    for path in ["/runtimes", "/runtimes/dev", "/runtimes/dev/wait"] {
        refuses(read(path, who), "not available on a runtime connection");
    }
    refuses(
        read("/runtimes/dev/exec", who),
        "not available on a runtime connection",
    );

    let made = |reply: (u16, Value)| {
        assert_eq!(reply.0, 200, "{}", reply.1);
        reply.1["pane"].as_str().unwrap().to_owned()
    };
    let inherited = made(via(
        &s,
        "dev",
        ("POST", "/panes"),
        who,
        &json!({"command": cat}),
    ));
    assert_eq!(
        s.row(&inherited)["runtime"],
        "dev",
        "no runtime: the connection's own"
    );
    let named = made(via(
        &s,
        "dev",
        ("POST", "/panes"),
        who,
        &json!({"command": cat, "runtime": "dev", "parent": r1}),
    ));
    assert_eq!(s.row(&named)["parent"], r1.as_str());
    refuses(
        via(
            &s,
            "dev",
            ("POST", "/panes"),
            who,
            &json!({"command": cat, "runtime": "other"}),
        ),
        "creates panes in dev, not in other",
    );
    refuses(
        via(
            &s,
            "dev",
            ("POST", "/panes"),
            who,
            &json!({"command": cat, "parent": host}),
        ),
        "may name only itself",
    );
    let from_user = post(
        &s,
        None,
        "/panes",
        &json!({"command": cat, "runtime": "other"}),
    );
    assert_eq!(
        s.row(from_user["pane"].as_str().unwrap())["runtime"],
        "other"
    );
    let child_command =
        json!({"type": "shell", "command": format!("stty raw -echo; {PRINT_TOKEN}; exec cat")});
    let child = {
        let reply = raw(
            &s,
            "POST",
            "/panes",
            &as_pane(&s, &host),
            &json!({"command": child_command, "runtime": "dev", "parent": host}),
        );
        assert_eq!(reply.0, 200, "{}", reply.1);
        reply.1["pane"].as_str().unwrap().to_owned()
    };
    assert_eq!(s.row(&child)["runtime"], "dev");
    assert_eq!(
        s.row(&child)["parent"],
        host.as_str(),
        "a host pane parents a runtime child"
    );
    s.screen_has(&child, "TOKEN<");
    let child_token = s.token(&child).unwrap();
    let as_child = Some((child.as_str(), child_token.as_str()));

    let (status, listing) = read("/panes", as_child);
    assert_eq!(status, 200);
    let seen = ids(&listing);
    assert!(
        seen.contains(&host.as_str()),
        "the parent is in the scope: {seen:?}"
    );
    assert!(
        seen.contains(&r1.as_str()) && seen.contains(&child.as_str()),
        "the runtime's panes: {seen:?}"
    );
    assert!(
        !seen.contains(&elsewhere.as_str()),
        "a pane of another session is hidden: {seen:?}"
    );
    let (_, layout) = read("/layout", as_child);
    assert_eq!(
        ids(&layout["panes"]),
        seen,
        "the layout names the same rows"
    );
    assert!(
        layout["layout"]["sessions"].as_array().unwrap().len() >= 2,
        "the document is whole: {layout}"
    );
    assert_eq!(read(&format!("/panes/{host}"), as_child).0, 200);
    refuses(
        read(&format!("/panes/{elsewhere}"), as_child),
        "is not visible to",
    );
    assert_eq!(read(&format!("/panes/{r1}/screen"), as_child).0, 200);
    refuses(
        read(&format!("/panes/{host}/screen"), as_child),
        "is not visible to",
    );
    refuses(
        read(&format!("/panes/{elsewhere}/screen"), as_child),
        "is not visible to",
    );
    let typed = json!({"type": "text", "data": base64(b"hi")});
    assert_eq!(
        via(
            &s,
            "dev",
            ("POST", &format!("/panes/{r1}/input")),
            as_child,
            &typed
        )
        .0,
        200
    );
    refuses(
        via(
            &s,
            "dev",
            ("POST", &format!("/panes/{elsewhere}/input")),
            as_child,
            &typed,
        ),
        "is not visible to",
    );

    let mapped = |cwd: Option<&str>, env: Value| {
        let script =
            "pwd -P; echo \"V=$RT_VAR/$BOTH/$REQ/$KO_RUNTIME\"; echo \"S=$KO_SOCKET\"; exec cat";
        let mut request = sh_in("dev", script);
        request["env"] = env;
        if let Some(cwd) = cwd {
            request["cwd"] = json!(cwd);
        }
        let pane = crate::panes::new_pane(&s, &request);
        s.screen_has(&pane, "S=");
        s.screen(&pane)
    };
    let canon = |path: PathBuf| {
        fs::canonicalize(path)
            .unwrap()
            .to_string_lossy()
            .into_owned()
    };
    let env = json!([{"name": "BOTH", "value": "request"}, {"name": "REQ", "value": "1"}]);
    let screen = mapped(Some(text_of(&maps.join("host/sub"))), env.clone());
    assert!(
        screen.contains(&canon(maps.join("rt/sub"))),
        "the host cwd maps: {screen}"
    );
    assert!(screen.contains("V=runtime/request/1/dev"), "{screen}");
    let socket = s.dir.join("runtimes/dev/io/socket");
    assert!(
        screen.contains(&format!("S={}", socket.display())),
        "{screen}"
    );
    let unmapped = mapped(None, json!([]));
    assert!(
        unmapped.lines().next().unwrap().trim() == "/",
        "the runtime's cwd: {unmapped}"
    );
    let passes = made(via(&s, "dev", ("POST", "/panes"), who, &{
        let mut request = sh("pwd -P; exec cat");
        request["cwd"] = json!(text_of(&maps.join("host")));
        request
    }));
    s.screen_has(&passes, &canon(maps.join("host")));

    let child_creds = headers(&s, &[("Ko-Pane", &child), ("Ko-Pane-Token", &child_token)]);
    let runtime_socket = s.dir.join("runtimes/dev/io/socket");
    let message =
        |text: &str| json!({"id": format!("msg-{text}"), "kind": "message", "text": text});
    let up = via(
        &s,
        "dev",
        ("POST", &format!("/panes/{host}/messages")),
        as_child,
        &message("upward"),
    );
    assert_eq!(
        (up.0, up.1["state"].as_str()),
        (200, Some("queued")),
        "{}",
        up.1
    );
    let down = raw(
        &s,
        "POST",
        &format!("/panes/{child}/messages"),
        &as_pane(&s, &host),
        &message("downward"),
    );
    assert_eq!(
        (down.0, down.1["state"].as_str()),
        (200, Some("queued")),
        "{}",
        down.1
    );
    let mut parent_stream = s
        .dial_ws(
            &format!("/panes/{host}/messages"),
            Some(as_pane(&s, &host)),
            101,
        )
        .unwrap();
    parent_stream.within(DEADLINE);
    let received = |stream: &mut Ws| {
        stream.within(DEADLINE);
        let Message::Text(text) = stream.read() else {
            panic!("a message is text");
        };
        serde_json::from_str::<Value>(&text).unwrap()
    };
    let arrived = received(&mut parent_stream);
    assert_eq!(
        (arrived["text"].as_str(), arrived["from"]["pane"].as_str()),
        (Some("upward"), Some(child.as_str())),
        "the child's message reached its host parent"
    );
    let mut child_stream = s
        .dial_ws_on(
            &runtime_socket,
            &format!("/panes/{child}/messages"),
            Some(child_creds.clone()),
            101,
        )
        .unwrap();
    assert_eq!(
        received(&mut child_stream)["text"],
        "downward",
        "the parent's message reached its child through the runtime socket"
    );
    s.dial_ws_on(
        &runtime_socket,
        &format!("/panes/{host}/messages"),
        Some(child_creds.clone()),
        409,
    );

    let agent = s.new_pane(json!({
        "command": {"type": "shell", "command": format!(
            "printf '\\033]7501;state=idle:app=pi\\007'; stty raw -echo; {PRINT_TOKEN}; exec cat"
        )},
    }));
    s.wait_row(&agent, "its pi root", |row| {
        row["status"]["program_status"]["records"]
            .as_array()
            .is_some_and(|records| !records.is_empty())
    });
    let candidates = via(
        &s,
        "dev",
        ("GET", &format!("/prompt/resolve?from={child}")),
        as_child,
        &Value::Null,
    );
    assert_eq!(candidates.0, 200, "{}", candidates.1);
    assert!(
        candidates
            .1
            .as_array()
            .unwrap()
            .iter()
            .any(|c| c["pane"] == agent.as_str()),
        "the host agent is a candidate: {}",
        candidates.1
    );
    refuses(
        via(
            &s,
            "dev",
            ("POST", "/prompt"),
            as_child,
            &json!({"from": child, "id": "prompt-0001", "target": agent, "text": "hello"}),
        ),
        "would get a paste",
    );
}

#[test]
fn the_first_pane_starts_a_runtime_and_a_failed_start_ends_it_with_its_message_and_retries() {
    let files = Dir::new("ko-rtf-");
    let up = fifo(&files, "up");
    let lead = fifo(&files, "lead");
    let log = files.join("lead.log");
    let gate = format!(
        "read code < {}; echo boom >&2; exit $code",
        quote(text_of(&up))
    );
    let led = format!(
        "echo led >> {}; read code < {}; [ $code = 0 ] || echo denied >&2; exit $code",
        quote(text_of(&log)),
        quote(text_of(&lead)),
    );
    let s = serve(
        &format!(
            r##"
runtimes:
  gate:
    color: "#d08a2a"
    command:
      up: ["/bin/sh", "-c", {gate:?}]
  lead:
    command:
      lead: ["/bin/sh", "-c", {led:?}]
"##
        ),
        &[],
    );
    let lines = || fs::read_to_string(&log).map_or(0, |text| text.lines().count());
    assert_eq!(info(&s, "gate")["color"], "#d08a2a");
    assert_eq!(info(&s, "lead").get("color"), None);
    let (mut client, welcome) = s.client(None);
    assert_eq!(
        welcome["runtimes"],
        json!([
            {"name": "gate", "source": {"type": "config"}, "kind": "command", "color": "#d08a2a", "state": {"type": "down"}},
            {"name": "lead", "source": {"type": "config"}, "kind": "command", "state": {"type": "down"}},
        ])
    );
    let mut announced = |name: &str| {
        let event = client.event("runtime");
        assert_eq!(event["name"], name, "{event}");
        event["state"].clone()
    };

    let first = rt_pane(&s, "gate", "echo ran; exec cat");
    let other = s.token_pane("exec cat");
    let retained = s.token_pane_with(json!({"close": "keep"}), "read line");
    s.text(&retained, "\n");
    dead(&s, &retained);
    crate::panes::refused(
        crate::panes::api(
            &s,
            None,
            "PATCH",
            &format!("/panes/{retained}"),
            &json!({"close": "exit"}),
        ),
        410,
        "gone",
        "is dead",
    );
    crate::panes::refused(
        crate::panes::api(
            &s,
            Some(&other),
            "PATCH",
            &format!("/panes/{first}"),
            &json!({"close": "keep"}),
        ),
        409,
        "refused",
        "change only itself",
    );
    s.screen_has(&first, "starting runtime gate");
    assert_eq!(state(&s, "gate"), "starting");
    assert_eq!(announced("gate"), json!({"type": "starting"}));
    let mut live = s.ws(&format!("/panes/{first}/view"));
    live.ready("starting runtime gate");
    release(&s.scratch, &up, "3");
    s.screen_has(&first, "runtime gate: boom");
    let row = dead(&s, &first);
    assert_eq!(
        row["dead"]["cause"],
        json!({"type": "exited", "code": 1}),
        "{row}"
    );
    loop {
        let marked = live.event("marked");
        if marked["marker"]["type"] == "dead" {
            assert_eq!(marked["marker"].get("cause"), None);
            assert_eq!(marked["marker"]["at"], row["dead"]["at"]);
            break;
        }
    }
    let mut view = s.ws(&format!("/panes/{first}/view"));
    let (snapshot, _) = view.snapshot();
    assert!(
        crate::harness::decode(&snapshot, false)
            .screen
            .contains("runtime gate: boom")
    );
    assert!(!s.screen(&first).contains("ran"), "{}", s.screen(&first));
    let failed = wait_state(&s, "gate", "failed");
    assert_eq!(failed["state"]["message"], "boom");
    assert_eq!(
        announced("gate"),
        json!({"type": "failed", "message": "boom"})
    );

    let retry = rt_pane(&s, "gate", "echo ran; exec cat");
    s.screen_has(&retry, "starting runtime gate");
    assert_eq!(
        state(&s, "gate"),
        "starting",
        "the next pane starts the runtime again"
    );
    assert_eq!(announced("gate"), json!({"type": "starting"}));
    release(&s.scratch, &up, "0");
    s.screen_has(&retry, "ran");
    wait_state(&s, "gate", "up");
    assert_eq!(announced("gate"), json!({"type": "up"}));

    let (p1, p2) = (
        rt_pane(&s, "lead", "echo up-$KO_RUNTIME; exec cat"),
        rt_pane(&s, "lead", "echo up-$KO_RUNTIME; exec cat"),
    );
    poll("the lead step to start", || lines() == 1);
    s.screen_has(&p1, "starting runtime lead");
    s.screen_has(&p2, "starting runtime lead");
    release(&s.scratch, &lead, "7");
    for pane in [&p1, &p2] {
        s.screen_has(pane, "runtime lead: denied");
        dead(&s, pane);
    }
    assert_eq!(
        wait_state(&s, "lead", "failed")["state"]["message"],
        "denied"
    );
    assert_eq!(lines(), 1, "one leader for two first panes");

    let (p3, p4) = (
        rt_pane(&s, "lead", "echo up-$KO_RUNTIME; exec cat"),
        rt_pane(&s, "lead", "echo up-$KO_RUNTIME; exec cat"),
    );
    poll("the new leader", || lines() == 2);
    release(&s.scratch, &lead, "0");
    s.screen_has(&p3, "up-lead");
    s.screen_has(&p4, "up-lead");
    assert_eq!(lines(), 2, "the retry elected one leader again");
    assert_eq!(info(&s, "lead")["panes"], 4);

    refuses(
        raw(
            &s,
            "POST",
            "/runtimes/lead/down",
            &headers(&s, &[]),
            &json!({}),
        ),
        "has live panes",
    );
    assert_eq!(state(&s, "lead"), "up");
    let forced = raw(
        &s,
        "POST",
        "/runtimes/lead/down",
        &headers(&s, &[]),
        &json!({"force": true}),
    );
    assert_eq!(forced.0, 200, "{}", forced.1);
    let after = wait_state(&s, "lead", "down");
    assert_eq!(after["panes"], 2, "the dead rows stay: {after}");
    assert!(
        !s.has_pane(&p3) && !s.has_pane(&p4),
        "the live panes were removed"
    );
    assert!(!s.dir.join("runtimes/lead/io/socket").exists());

    let leader = rt_pane(&s, "lead", "exec cat");
    poll("a third leader", || lines() == 3);
    stop_pane(&s, &leader);
    let ended = wait_state(&s, "lead", "failed");
    assert!(
        ended["state"]["message"]
            .as_str()
            .unwrap()
            .contains("the leading pane ended before"),
        "{ended}"
    );

    let deleted = raw(
        &s,
        "DELETE",
        "/runtimes/lead",
        &headers(&s, &[]),
        &Value::Null,
    );
    assert_eq!(deleted.0, 200, "{}", deleted.1);
    assert_eq!(
        fs::read_dir(s.dir.join("runtimes/lead/io"))
            .unwrap()
            .count(),
        0
    );
}

#[test]
fn runtime_visit_resolves_its_runtime_in_the_pane_session_at_the_visit_message() {
    let s = serve("", &[]);
    let pane = token_pane_in_new_session(&s, "before");
    let other = token_pane_in_new_session(&s, "after");
    define_command(&s, &pane, "dev");
    define_command(&s, &other, "dev");
    let destination = session_named(&s, "after");
    let mut visit = s
        .dial_ws("/runtimes/dev/visit", Some(as_pane(&s, &pane)), 101)
        .unwrap();
    s.edit(|layout| {
        let sessions = layout["sessions"].as_array_mut().unwrap();
        let source = sessions
            .iter_mut()
            .find(|session| session["name"] == "before")
            .unwrap();
        let window = source["windows"].as_array_mut().unwrap().remove(0);
        sessions.retain(|session| session["name"] != "before");
        sessions
            .iter_mut()
            .find(|session| session["id"] == destination)
            .unwrap()["windows"]
            .as_array_mut()
            .unwrap()
            .push(window);
    });
    visit.send(&json!({"type":"visit", "cwd":"/tmp"}));
    visit.event("up");
    let found: Value = serde_json::from_str(&s.request(
        "GET",
        &format!("/runtimes/dev?session={destination}"),
        None,
        200,
    ))
    .unwrap();
    assert_eq!(found["panes"], 1);
}

#[test]
fn runtime_visit_ends_on_an_interrupt_before_a_child_runs() {
    let files = Dir::new("ko-visit-int-");
    let gate = fifo(&files, "up");
    let step = format!("read answer < {}", quote(text_of(&gate)));
    let s = serve(
        &format!("runtimes:\n  dev: {{command: {{up: [/bin/sh, -c, {step:?}]}}}}\n"),
        &[],
    );
    let pane = s.new_pane(json!({"command":{"type":"argv", "argv":["/bin/sh"]}, "env":[{"name":"PS1", "value":"HOST> "}]}));
    let o = Outer::new(&s.dir, Keys::Extended);
    o.attach("cat");
    o.contains("HOST>");
    o.line("ko run --name dev; printf 'RETURN-%s\\n' $?");
    s.wait_row(&pane, "waiting visit", |row| row["runtime"] == "dev");
    o.ctrl('c');
    s.wait_row(
        &pane,
        "interrupted visit releases membership before up",
        |row| row["runtime"].is_null(),
    );
    o.contains("RETURN-130");
    o.line("printf 'HOST-%s\\n' READY");
    o.contains("HOST-READY");
    release(&files, &gate, "go");
    o.detach();
}

#[test]
fn runtime_visit_waiters_lead_fail_and_end_with_their_pane_or_session() {
    let s = serve(
        "server:\n  runtime_idle_seconds: none\nruntimes:\n  login: {command: {lead: [/usr/bin/true]}}\n  bad: {command: {up: [/bin/sh, -c, 'printf broken >&2; exit 1']}}\n",
        &[],
    );
    let pane = s.token_pane("exec cat");
    let follower = s.token_pane("exec cat");
    let revision = s.doc()["revision"].clone();
    let (mut client, _) = s.client(None);
    let mut visit = s
        .dial_ws("/runtimes/login/visit", Some(as_pane(&s, &pane)), 101)
        .unwrap();
    visit.send(&json!({"type":"visit", "cwd":"/tmp", "env":[]}));
    assert_eq!(client.event("pane_runtime")["runtime"], "login");
    visit.event("starting");
    assert_eq!(visit.event("lead")["argv"], json!(["/usr/bin/true"]));
    let mut waiter = s
        .dial_ws("/runtimes/login/visit", Some(as_pane(&s, &follower)), 101)
        .unwrap();
    waiter.send(&json!({"type":"visit", "cwd":"/tmp"}));
    waiter.event("starting");
    drop(visit);
    assert!(
        waiter.event("failed")["message"]
            .as_str()
            .unwrap()
            .contains("leading pane")
    );
    s.wait_row(&pane, "leader visit released", |row| {
        row["runtime"].is_null()
    });
    assert_eq!(s.doc()["revision"], revision);
    let mut visit = s
        .dial_ws("/runtimes/login/visit", Some(as_pane(&s, &pane)), 101)
        .unwrap();
    visit.send(&json!({"type":"visit", "cwd":"/tmp"}));
    visit.event("lead");
    visit.send(&json!({"type":"lead", "exit":0, "stderr":""}));
    let up = visit.event("up");
    let argv = up["argv"].as_array().unwrap();
    assert!(!argv.contains(&json!("runtime-exec")));
    assert!(argv.contains(&json!("enter")));
    let token_file = s
        .dir
        .join("runtimes/login/panes")
        .join(format!("{pane}.token"));
    assert_ne!(
        fs::read_to_string(&token_file).unwrap(),
        s.token(&pane).unwrap()
    );
    s.request("DELETE", &format!("/panes/{pane}"), None, 200);
    visit.event("ended");
    visit.closed("removed pane ends the visit");
    assert_eq!(visit.close_frame().map(|frame| frame.0), Some(1000));
    assert!(!token_file.exists());
    let pane = token_pane_in_new_session(&s, "visiting");
    define_command(&s, &pane, "dev");
    let session = session_named(&s, "visiting");
    let mut visit = s
        .dial_ws("/runtimes/dev/visit", Some(as_pane(&s, &pane)), 101)
        .unwrap();
    visit.send(&json!({"type":"visit", "cwd":"/tmp"}));
    visit.event("up");
    s.request("DELETE", &format!("/sessions/{session}"), None, 200);
    visit.event("ended");
    visit.closed("session deletion ends the visit");
    let pane = s.token_pane("exec cat");
    let mut failed = s
        .dial_ws("/runtimes/bad/visit", Some(as_pane(&s, &pane)), 101)
        .unwrap();
    failed.send(&json!({"type":"visit", "cwd":"/tmp"}));
    assert!(
        failed.event("failed")["message"]
            .as_str()
            .unwrap()
            .contains("broken")
    );
    failed.closed("failed runtime closes the visit");
    assert_eq!(failed.close_frame().map(|frame| frame.0), Some(1000));
    let row = s.wait_row(&pane, "failed visit released", |row| {
        row["runtime"].is_null()
    });
    assert!(row["dead"].is_null());
}

#[test]
fn runtime_visit_keeps_the_host_pane_and_scopes_its_temporary_identity() {
    let files = Dir::new("ko-visit-");
    let host_dir = files.join("host");
    let inner_dir = files.join("inner");
    fs::create_dir_all(host_dir.join("sub")).unwrap();
    fs::create_dir_all(inner_dir.join("sub")).unwrap();
    let s = serve(
        &format!(
            "server:\n  runtime_idle_seconds: 0.05\nruntimes:\n  dev:\n    command: {{}}\n    paths: [{{host: {}, runtime: {}}}]\n  sentinel: {{command: {{}}}}\n",
            host_dir.display(),
            inner_dir.display()
        ),
        &[("KO_STOP_ESCALATION_MS", "100")],
    );
    let pane = s.new_pane(json!({"cwd": host_dir, "command": {"type": "argv", "argv": ["/bin/sh"]}, "env": [{"name": "PS1", "value": "HOST> "}]}));
    let o = Outer::new(&s.dir, Keys::Extended);
    o.attach("cat");
    o.contains("HOST>");
    o.line(PRINT_TOKEN);
    o.contains("TOKEN<");
    let host = s.token(&pane).unwrap();
    let first = files.join("first");
    let background = fifo(&files, "background");
    o.line(&format!(
        "(read gate < {}; ko run --name dev </dev/tty)& ko run --name dev -- /bin/sh",
        quote(text_of(&background))
    ));
    s.wait_row(&pane, "visit membership", |row| row["runtime"] == "dev");
    o.wait("visit sidebar mark", || {
        o.lines().iter().any(|line| {
            line.chars()
                .take(24)
                .collect::<String>()
                .trim_end()
                .ends_with(" dev")
        })
    });
    o.line(&format!(
        "printf '%s' \"$KO_PANE_TOKEN\" > {}; ko api /version && printf 'VISIT-%s\\n' ONE",
        quote(text_of(&first))
    ));
    o.contains("VISIT-ONE");
    release(&files, &background, "go");
    o.contains(&format!("{pane} is already in runtime dev"));
    let token = fs::read_to_string(&first).unwrap();
    assert_ne!(token, host);
    assert_eq!(
        via(
            &s,
            "dev",
            ("GET", "/version"),
            Some((&pane, &token)),
            &Value::Null
        )
        .0,
        200
    );
    assert_eq!(
        via(
            &s,
            "dev",
            ("GET", "/version"),
            Some((&pane, &host)),
            &Value::Null
        )
        .0,
        409
    );
    assert_eq!(
        raw(
            &s,
            "GET",
            "/version",
            &headers(&s, &[("Ko-Pane", &pane), ("Ko-Pane-Token", &token)]),
            &Value::Null
        )
        .0,
        409
    );
    o.line("ko run --name dev");
    o.contains("inside runtime dev; run it from a host pane");
    let duplicate = s.dial_ws(
        "/runtimes/dev/visit",
        Some(headers(&s, &[("Ko-Pane", &pane), ("Ko-Pane-Token", &host)])),
        409,
    );
    assert!(duplicate.is_none());
    let down = raw(&s, "POST", "/runtimes/dev/down", &s.headers(), &json!({}));
    assert_eq!(down.0, 409);
    let mut sentinel = s.ws("/runtimes/sentinel/exec");
    sentinel.send(&json!({"type":"exec", "argv":["/usr/bin/true"], "stdin":false}));
    sentinel.event("exit");
    wait_state(&s, "sentinel", "down");
    assert_eq!(state(&s, "dev"), "up");
    o.line(&format!(
        "cd {}; printf '\\033]7;file://runtime{}\\007'; printf 'CWD-%s\\n' READY",
        quote(text_of(&inner_dir.join("sub"))),
        inner_dir.join("sub").display()
    ));
    o.contains("CWD-READY");
    s.wait_row(&pane, "runtime cwd", |row| {
        row["cwd"]
            .as_str()
            .is_some_and(|cwd| cwd.ends_with("/inner/sub"))
    });
    let mapped =
        s.new_pane(json!({"cwd": {"pane": pane}, "command": {"type":"argv", "argv":["/bin/cat"]}}));
    assert_eq!(
        s.row(&mapped)["cwd"],
        host_dir.join("sub").to_string_lossy().as_ref()
    );
    s.request("DELETE", &format!("/panes/{mapped}"), None, 200);
    o.prefix("c");
    poll("split of the visited pane", || s.rows().len() == 2);
    let split = s.rows().into_iter().find(|row| row["id"] != pane).unwrap();
    assert_eq!(split["runtime"], "dev");
    let split_id = split["id"].as_str().unwrap();
    s.request("DELETE", &format!("/panes/{split_id}"), None, 200);
    let mut hold = s.ws("/runtimes/dev/exec");
    hold.send(&json!({"type":"exec", "argv":["/bin/sh", "-c", "printf ready; cat"], "stdin":true}));
    hold.event("stdout");
    o.line("exit");
    s.wait_row(&pane, "visit ended", |row| row["runtime"].is_null());
    assert!(s.row(&pane)["dead"].is_null());
    assert_eq!(
        via(
            &s,
            "dev",
            ("GET", "/version"),
            Some((&pane, &token)),
            &Value::Null
        )
        .0,
        409
    );
    drop(hold);
    wait_state(&s, "dev", "down");
    let second = files.join("second");
    o.line("ko run --name dev --env VISIT=joined -- /bin/sh");
    s.wait_row(&pane, "second visit", |row| row["runtime"] == "dev");
    o.line(&format!(
        "trap '' HUP; printf '%s' \"$KO_PANE_TOKEN\" > {}; test \"$VISIT\" = joined && printf 'VISIT-%s\\n' TWO",
        quote(text_of(&second))
    ));
    o.contains("VISIT-TWO");
    assert_ne!(fs::read_to_string(second).unwrap(), token);
    s.request(
        "POST",
        "/runtimes/dev/down",
        Some(&json!({"force":true})),
        200,
    );
    o.contains("runtime dev: runtime taken down");
    s.wait_row(&pane, "forced visit ended", |row| row["runtime"].is_null());
    assert!(s.row(&pane)["dead"].is_null());
    o.line("printf 'HOST-%s\\n' BACK");
    o.contains("HOST-BACK");
    o.line("ko run command --name scratch --env VISIT=defined -- /bin/sh -c 'test \"$VISIT\" = defined && printf \"DEFINE-%s\\n\" OK; exit 7'; printf 'STATUS-%s\\n' $?");
    o.contains("DEFINE-OK");
    o.contains("STATUS-7");
    let visitor_pid = files.join("visitor-pid");
    let script = format!(
        "printf '%s' \"$PPID\" > {}; printf 'KILL-%s\\n' READY; exec cat",
        quote(text_of(&visitor_pid))
    );
    o.line(&format!(
        "ko run --name dev -- /bin/sh -c {}",
        quote(&script)
    ));
    o.contains("KILL-READY");
    let pid = Pid::new(fs::read_to_string(visitor_pid).unwrap().parse().unwrap()).unwrap();
    ko_sys::pid::signal_descendant(s.child.pid(), pid, ko_sys::signal::Signal::Kill).unwrap();
    s.wait_row(&pane, "killed visitor releases membership", |row| {
        row["runtime"].is_null()
    });
    assert!(s.row(&pane)["dead"].is_null());
    o.detach();
}

#[test]
fn the_terminal_client_marks_a_runtime_pane_in_the_sidebar_and_a_new_window_runs_in_the_same_runtime()
 {
    let s = serve("runtimes:\n  box: {command: {}}\n", &[]);
    let first = rt_pane(&s, "box", "printf 'pane-one\\n'; exec cat");
    let o = Outer::new(&s.dir, Keys::Extended);
    o.attach("cat");
    o.contains("pane-one");
    o.wait("the runtime after the title", || {
        o.lines().iter().any(|line| {
            let sidebar: String = line.chars().take(24).collect();
            sidebar.trim_end().ends_with(" box")
        })
    });
    o.prefix("c");
    poll("a second pane", || s.rows().len() == 2);
    let created = s
        .rows()
        .into_iter()
        .find(|row| row["id"] != first.as_str())
        .unwrap();
    assert_eq!(created["runtime"], "box", "{created}");
    o.detach();
}

#[test]
fn a_client_link_hears_of_a_runtime_that_the_configuration_gains_changes_or_loses() {
    let s = serve("runtimes:\n  a: {command: {}}\n  b: {command: {}}\n", &[]);
    let (mut client, welcome) = s.client(None);
    assert_eq!(welcome["runtimes"].as_array().map(Vec::len), Some(2));
    s.rewrite(
        r##"
runtimes:
  a: {command: {}, color: "#d08a2a"}
  c: {command: {}}
"##,
    );
    let listed = info(&s, "c");
    assert_eq!(listed["state"]["type"], "down");
    client.within(DEADLINE);
    let mut seen = Vec::new();
    while seen.len() < 3 {
        let Message::Text(text) = client.read() else {
            continue;
        };
        if let Some((tag, event)) = crate::harness::tagged(&text)
            && tag.starts_with("runtime")
        {
            seen.push((tag, event));
        }
    }
    assert_eq!(seen[0].0, "runtime_deleted");
    assert_eq!(seen[0].1["name"], "b");
    assert_eq!(seen[1].0, "runtime");
    assert_eq!(seen[1].1["name"], "a");
    assert_eq!(seen[1].1["color"], "#d08a2a");
    assert_eq!(seen[2].1["name"], "c");
    assert_eq!(seen[2].1["state"], json!({"type": "down"}));
}

#[test]
fn a_runtime_that_leaves_the_configuration_while_up_is_deleted_for_clients_when_its_link_ends() {
    let s = serve("runtimes:\n  a: {command: {}}\n  b: {command: {}}\n", &[]);
    let (mut client, _) = s.client(None);
    let pane = rt_pane(&s, "a", "exec cat");
    wait_state(&s, "a", "up");
    s.rewrite("runtimes:\n  b: {command: {}}\n");
    let listed: Value = serde_json::from_str(&s.request("GET", "/runtimes", None, 200)).unwrap();
    assert_eq!(
        listed
            .as_array()
            .unwrap()
            .iter()
            .map(|r| r["name"].clone())
            .collect::<Vec<_>>(),
        [json!("a"), json!("b")],
        "a live link keeps its runtime listed after the file dropped it"
    );
    stop_pane(&s, &pane);
    let forced = raw(
        &s,
        "POST",
        "/runtimes/a/down",
        &headers(&s, &[]),
        &json!({"force": true}),
    );
    assert_eq!(forced.0, 200, "{}", forced.1);
    client.within(DEADLINE);
    let mut states = Vec::new();
    loop {
        let Message::Text(text) = client.read() else {
            continue;
        };
        match crate::harness::tagged(&text) {
            Some((tag, event)) if tag == "runtime" && event["name"] == "a" => {
                states.push(event["state"]["type"].as_str().unwrap().to_owned());
            }
            Some((tag, event)) if tag == "runtime_deleted" => {
                assert_eq!(event["name"], "a");
                break;
            }
            _ => {}
        }
    }
    assert_eq!(states.last().map(String::as_str), Some("up"), "{states:?}");
}

#[test]
fn an_idle_runtime_goes_down_unless_a_pane_or_an_exec_session_holds_it() {
    let s = serve(
        "
server:
  runtime_idle_seconds: 0.3
runtimes:
  kept: {command: {}}
  idle: {command: {}}
  busy: {command: {}}
",
        &[],
    );
    let files = Dir::new("ko-rtf-");
    let gate = fifo(&files, "gate");
    let mut ws = s.ws("/runtimes/busy/exec");
    ws.send(&json!({
        "type": "exec", "stdin": false,
        "argv": ["/bin/sh", "-c", format!("read x < {}", quote(text_of(&gate)))],
    }));
    wait_state(&s, "busy", "up");
    let mut request = sh_in("kept", "exit 0");
    request["close"] = json!("keep");
    let dying = s.new_pane(request);
    dead(&s, &dying);
    let pane = rt_pane(&s, "idle", "exec cat");
    wait_state(&s, "idle", "up");
    stop_pane(&s, &pane);
    wait_state(&s, "idle", "down");
    assert!(!s.dir.join("runtimes/idle/io/socket").exists());
    assert_eq!(
        state(&s, "kept"),
        "up",
        "a dead row still counts as a pane of the runtime"
    );
    assert_eq!(
        state(&s, "busy"),
        "up",
        "an exec session holds its runtime like a pane"
    );
    release(&s.scratch, &gate, "go");
    ws.within(DEADLINE);
    assert_eq!(read_exec(&mut ws).end, json!({"type": "exit", "status": 0}));
    wait_state(&s, "busy", "down");
}

#[test]
fn a_retry_after_a_failed_start_reads_the_configuration_again() {
    let s = serve(
        r#"
runtimes:
  fix:
    command:
      up: [/bin/sh, -c, "echo broken >&2; exit 3"]
"#,
        &[],
    );
    let first = rt_pane(&s, "fix", "exec cat");
    s.screen_has(&first, "runtime fix: broken");
    wait_state(&s, "fix", "failed");

    s.rewrite(
        "
runtimes:
  fix:
    command:
      up: [/bin/sh, -c, exit 0]
",
    );
    let second = rt_pane(&s, "fix", "echo fixed; exec cat");
    s.screen_has(&second, "fixed");
    wait_state(&s, "fix", "up");
}

#[test]
fn a_configuration_that_cannot_be_used_fails_the_runtime_requests_and_not_the_server() {
    let dir = Dir::new("ko-rtc-");
    let file = dir.join("config.yaml");
    let s = start_with(Path::new("/bin/sh"), &[], &["--config", text_of(&file)]);
    let get = |path: &str| raw(&s, "GET", path, &headers(&s, &[]), &Value::Null);
    let created = |runtime: &str| {
        raw(
            &s,
            "POST",
            "/panes",
            &headers(&s, &[]),
            &json!({"runtime": runtime, "command": {"type": "shell", "command": "exec cat"}}),
        )
    };
    assert_eq!(
        get("/runtimes"),
        (200, json!([])),
        "a missing file is an empty configuration"
    );
    let (status, body) = get("/runtimes/dev");
    assert_eq!((status, body["kind"].as_str()), (404, Some("not_found")));
    assert!(
        body["message"]
            .as_str()
            .unwrap()
            .contains(&format!("no runtime dev in {}", file.display())),
        "{body}"
    );

    let caller = token_pane_in_new_session(&s, "definitions");
    let (status, body) = raw(
        &s,
        "PUT",
        "/runtimes/adhoc",
        &as_pane(&s, &caller),
        &json!({"command": {}}),
    );
    assert_eq!((status, body["kind"].as_str()), (400, Some("invalid")));
    assert_eq!(
        body["message"],
        "command is a test kind; set KO_RUNTIME_COMMAND_KIND=1"
    );
    fs::write(&file, "runtimes:\n  dev:\n    command: {}\n").unwrap();
    let (status, body) = get("/runtimes");
    assert_eq!((status, body["kind"].as_str()), (400, Some("invalid")));
    assert!(
        body["message"]
            .as_str()
            .unwrap()
            .contains("runtimes: dev: command: is a test kind; set KO_RUNTIME_COMMAND_KIND=1"),
        "without the knob a command runtime is an error that names the runtime and the field: {body}"
    );
    assert_eq!(created("dev").0, 400);
    assert_eq!(
        ids(&json!(s.rows())),
        [caller.as_str()],
        "the request that failed made no pane"
    );

    fs::write(&file, "runtimes:\n  dev: [").unwrap();
    let (status, body) = get("/runtimes");
    assert_eq!((status, body["kind"].as_str()), (400, Some("invalid")));
    let message = body["message"].as_str().unwrap();
    assert!(
        message.contains(&format!("{}: ", file.display())) && message.contains("line 3 column"),
        "the parser position: {message}"
    );
    s.request("GET", "/version", None, 200);
}

#[test]
fn a_runtime_socket_path_over_the_limit_fails_the_start_with_advice() {
    let long = Dir::new(&"x".repeat(64));
    let socket = long.join("socket").as_os_str().len();
    let runtime = long.join("runtimes/dev/io/socket").as_os_str().len();
    assert!(socket <= 103 && runtime > 103, "{socket} {runtime}");
    let s = serve_in(long, "runtimes:\n  dev: {command: {}}\n", &[]);
    let pane = rt_pane(&s, "dev", "exec cat");
    let message = "runtime socket path exceeds 103 bytes; set KO_STATE_DIR to a shorter path";
    s.screen_has(&pane, "runtime dev: runtime socket path exceeds 103 bytes;");
    let failed = wait_state(&s, "dev", "failed");
    assert_eq!(failed["state"]["message"], message);
}

#[test]
fn ko_enter_needs_a_private_token_and_a_directory_and_a_runtime_refuses_the_terminal_client() {
    let scratch = Dir::new("ko-rte-");
    let env = test_env(&scratch);
    let enter = |extra: &[&str]| {
        let mut args = vec![
            "enter",
            "--socket",
            "/nonexistent/socket",
            "--pane",
            "pane_1",
            "--runtime",
            "dev",
        ];
        args.extend_from_slice(extra);
        run_ko(&scratch, &env, &args, "")
    };
    let token = "0123456789abcdef0123456789abcdef";
    let private = scratch.join("private");
    fs::write(&private, token).unwrap();
    fs::set_permissions(&private, fs::Permissions::from_mode(0o600)).unwrap();
    let open = scratch.join("open");
    fs::write(&open, token).unwrap();
    fs::set_permissions(&open, fs::Permissions::from_mode(0o644)).unwrap();

    assert_eq!(
        enter(&["--token-file", text_of(&scratch.join("missing"))]).error(1),
        "ko enter: no token\n"
    );
    assert_eq!(
        enter(&["--token-file", text_of(&open)]).error(1),
        "ko enter: no token\n"
    );
    assert!(!open.exists(), "even a refused token file is removed");
    assert_eq!(
        enter(&[]).error(1),
        "ko enter: no token\n",
        "without a file the token is in the environment"
    );
    let message = enter(&[
        "--token-file",
        text_of(&private),
        "--cwd",
        "/nonexistent/dir",
    ])
    .error(1);
    assert_eq!(
        message,
        "ko enter: cwd /nonexistent/dir: No such file or directory\n"
    );
    assert!(
        !private.exists(),
        "ko enter unlinks the token file when it reads it"
    );

    let mut inside = env.clone();
    inside.push(b"KO_RUNTIME=dev".to_vec());
    let refused = run_ko(&scratch, &inside, &[], "").error(1);
    assert_eq!(refused, "ko: inside runtime dev; attach from the host\n");
}

#[derive(Debug, Default)]
pub(crate) struct Exec {
    pub(crate) stdout: Vec<u8>,
    pub(crate) stderr: Vec<u8>,
    pub(crate) end: Value,
}

pub(crate) fn decode(value: &Value) -> Vec<u8> {
    ko_pane_wire::base64::decode(value["data"].as_str().unwrap()).unwrap()
}

pub(crate) fn read_exec(ws: &mut crate::harness::Ws) -> Exec {
    let mut exec = Exec::default();
    loop {
        let crate::harness::Message::Text(text) = ws.read() else {
            panic!("a binary message in an exec session");
        };
        let message: Value = serde_json::from_str(&text).unwrap();
        match message["type"].as_str().unwrap() {
            "stdout" => exec.stdout.extend(decode(&message)),
            "stderr" => exec.stderr.extend(decode(&message)),
            _ => {
                exec.end = message;
                return exec;
            }
        }
    }
}

pub(crate) fn start_exec(s: &Server, runtime: &str, request: Value) -> crate::harness::Ws {
    let mut ws = s.ws(&format!("/runtimes/{runtime}/exec"));
    let mut message = request;
    message["type"] = json!("exec");
    ws.send(&message);
    ws
}

pub(crate) fn closed_with(ws: &mut crate::harness::Ws, code: u16) {
    ws.closed("the session to close");
    assert_eq!(ws.close_frame().map(|frame| frame.0), Some(code));
}

pub(crate) fn pid_of(file: &Path) -> Pid {
    poll("the pid file", || {
        fs::read_to_string(file).is_ok_and(|text| text.trim().parse::<i64>().is_ok())
    });
    Pid::new(fs::read_to_string(file).unwrap().trim().parse().unwrap()).unwrap()
}

#[test]
fn an_exec_session_runs_a_command_with_split_output_stdin_signals_and_an_exit() {
    let files = Dir::new("ko-rtf-");
    let work = Dir::new("ko-rtw-");
    let s = serve(
        &format!(
            r#"
runtimes:
  dev:
    command: {{}}
    env:
      RT_VAR: runtime
      BOTH: runtime
      PATH: /usr/bin:/bin
    cwd: {work}
  login:
    command:
      lead: [/bin/sh, -c, exit 0]
  broken:
    command:
      up: [/bin/sh, -c, "echo nope >&2; exit 4"]
"#,
            work = text_of(&work),
        ),
        &[
            ("KO_VIEW_QUEUE_BYTES", "262144"),
            ("KO_STOP_ESCALATION_MS", "300"),
        ],
    );
    let script = |script: &str| json!({"argv": ["/bin/sh", "-c", script], "stdin": false});

    let mut ws = start_exec(&s, "dev", script("printf out; printf err >&2; exit 3"));
    let done = read_exec(&mut ws);
    assert_eq!(
        (done.stdout, done.stderr, done.end),
        (
            b"out".to_vec(),
            b"err".to_vec(),
            json!({"type": "exit", "status": 3})
        )
    );
    closed_with(&mut ws, 1000);

    let mut ws = start_exec(&s, "dev", json!({"argv": ["/bin/cat"], "stdin": true}));
    ws.send(&json!({"type": "stdin", "data": base64(b"hello ")}));
    ws.send(&json!({"type": "stdin", "data": base64(b"world")}));
    ws.send(&json!({"type": "eof"}));
    let done = read_exec(&mut ws);
    assert_eq!(
        (done.stdout, done.end),
        (
            b"hello world".to_vec(),
            json!({"type": "exit", "status": 0})
        )
    );

    let mut ws = start_exec(
        &s,
        "dev",
        json!({
            "argv": ["/usr/bin/env"], "stdin": false,
            "cwd": text_of(&files),
            "env": {"BOTH": "request", "REQ": "1"},
        }),
    );
    let done = read_exec(&mut ws);
    let mut lines: Vec<String> = String::from_utf8(done.stdout)
        .unwrap()
        .lines()
        .map(str::to_owned)
        .collect();
    lines.sort();
    assert_eq!(
        lines,
        [
            "BOTH=request",
            "KO_RUNTIME=dev",
            "PATH=/usr/bin:/bin",
            "REQ=1",
            "RT_VAR=runtime"
        ],
        "the runtime's env, then the request's, then KO_RUNTIME; nothing of the server's"
    );
    let mut ws = start_exec(&s, "dev", script("pwd -P"));
    let here = String::from_utf8(read_exec(&mut ws).stdout).unwrap();
    assert_eq!(
        here.trim(),
        fs::canonicalize(&*work).unwrap().to_str().unwrap(),
        "the runtime's cwd"
    );
    let mut ws = start_exec(
        &s,
        "dev",
        json!({"argv": ["/bin/sh", "-c", "pwd -P"], "stdin": false, "cwd": text_of(&files)}),
    );
    let there = String::from_utf8(read_exec(&mut ws).stdout).unwrap();
    assert_eq!(
        there.trim(),
        fs::canonicalize(&*files).unwrap().to_str().unwrap(),
        "the request's cwd"
    );
    let mut ws = start_exec(&s, "dev", script("exit 9"));
    assert_eq!(read_exec(&mut ws).end, json!({"type": "exit", "status": 9}));

    let pid_file = files.join("signal.pid");
    let mut ws = start_exec(
        &s,
        "dev",
        script(&format!(
            "echo $$ > {}; exec sleep 60",
            quote(text_of(&pid_file))
        )),
    );
    pid_of(&pid_file);
    ws.send(&json!({"type": "signal", "signal": "term"}));
    assert_eq!(
        read_exec(&mut ws).end,
        json!({"type": "exit", "signal": "TERM"})
    );

    let bad = [
        (
            json!({"type": "stdin", "data": ""}),
            "the first message must be exec",
        ),
        (
            json!({"type": "exec", "argv": [], "stdin": false}),
            "argv needs a program",
        ),
    ];
    for (message, why) in bad {
        let mut ws = s.ws("/runtimes/dev/exec");
        ws.send(&message);
        let end = read_exec(&mut ws).end;
        assert_eq!(end["type"], "error");
        assert!(end["message"].as_str().unwrap().contains(why), "{end}");
        closed_with(&mut ws, 1011);
    }
    let mut ws = start_exec(
        &s,
        "dev",
        json!({"argv": ["no-such-program-ko"], "stdin": false}),
    );
    let done = read_exec(&mut ws);
    assert_eq!(done.end, json!({"type": "exit", "status": 127}));
    assert!(
        String::from_utf8(done.stderr)
            .unwrap()
            .contains("no-such-program-ko: command not found"),
        "a missing program is the ko inside's word on stderr and status 127"
    );
    let mut ws = start_exec(
        &s,
        "dev",
        json!({"argv": ["/bin/sh", "-c", "kill -USR1 $$"], "stdin": false}),
    );
    assert_eq!(
        read_exec(&mut ws).end,
        json!({"type": "exit", "signal": "USR1"}),
        "a signal exit keeps its name"
    );

    let mut ws = start_exec(&s, "login", script("true"));
    let end = read_exec(&mut ws).end;
    assert_eq!(
        end,
        json!({"type": "error", "message": "runtime login needs a pane to log in"})
    );
    closed_with(&mut ws, 1011);
    let mut ws = start_exec(&s, "broken", script("true"));
    assert_eq!(
        read_exec(&mut ws).end,
        json!({"type": "error", "message": "nope"})
    );
    refused_exec(&s, &work);

    let ignoring = files.join("ignore.pid");
    let ending = files.join("end.pid");
    let ws = start_exec(
        &s,
        "dev",
        script(&format!(
            "echo $$ > {}; exec sleep 60",
            quote(text_of(&ending))
        )),
    );
    let cut = pid_of(&ending);
    drop(ws);
    wait_gone(cut, "the socket closed");
    let ws = start_exec(
        &s,
        "dev",
        script(&format!(
            "trap '' TERM; echo $$ > {}; while :; do sleep 0.1; done",
            quote(text_of(&ignoring))
        )),
    );
    let stubborn = pid_of(&ignoring);
    drop(ws);
    wait_gone(stubborn, "the escalation to SIGKILL");
}

fn refused_exec(s: &Server, _work: &Path) {
    let r = rt_token_pane(s, "dev");
    let token = s.token(&r).unwrap();
    refuses(
        via(
            s,
            "dev",
            ("GET", "/runtimes/dev/exec"),
            Some((&r, &token)),
            &Value::Null,
        ),
        "not available on a runtime connection",
    );
}

#[test]
fn an_exec_session_reads_its_output_in_order_and_stops_the_command_while_the_reader_is_slow() {
    let files = Dir::new("ko-rtf-");
    let mark = files.join("done");
    let s = serve(
        "runtimes:\n  dev: {command: {}}\n",
        &[("KO_VIEW_QUEUE_BYTES", "262144")],
    );
    let lines = 600_000;
    let script = format!(
        "awk 'BEGIN {{ for (i = 0; i < {lines}; i++) printf \"%010d\\n\", i }}'; : > {}",
        quote(text_of(&mark))
    );
    let mut ws = start_exec(
        &s,
        "dev",
        json!({"argv": ["/bin/sh", "-c", script], "stdin": false}),
    );
    stays(
        "the command blocks while nothing reads",
        Duration::from_millis(400),
        || !mark.exists(),
    );
    ws.within(Duration::from_secs(20));
    let done = read_exec(&mut ws);
    assert_eq!(done.end, json!({"type": "exit", "status": 0}));
    let expected: String = (0..lines).map(|i| format!("{i:010}\n")).collect();
    assert!(
        done.stdout == expected.as_bytes(),
        "nothing is lost or reordered"
    );
    assert!(mark.exists());
}

const TREE: &str = r#"trap '' HUP TERM
dir=$1
case $2 in
child)
	sh "$0" "$dir" grandchild &
	echo $$ > "$dir/child"
	wait
	;;
grandchild)
	echo $$ > "$dir/grandchild"
	while :; do sleep 0.1; done
	;;
*)
	sh "$0" "$dir" child &
	echo $$ > "$dir/leader"
	wait
	;;
esac
"#;

// A command whose leader, child and grandchild share one process group and ignore HUP and
// TERM. They write their pids into `seen`, which is `files` as the runtime sees it.
pub(crate) fn start_tree(s: &Server, runtime: &str, (files, seen): (&Path, &str)) -> Ws {
    fs::write(files.join("tree.sh"), TREE).unwrap();
    start_exec(
        s,
        runtime,
        json!({"argv": ["/bin/sh", format!("{seen}/tree.sh"), seen], "stdin": true}),
    )
}

pub(crate) fn tree_pids(files: &Path) -> [Pid; 3] {
    ["leader", "child", "grandchild"].map(|name| pid_of(&files.join(name)))
}

#[test]
fn a_cancelled_exec_session_ends_its_whole_process_group_even_when_the_command_ignores_sigterm() {
    let s = serve(
        r#"
runtimes:
  dev:
    command: {}
  junk:
    command:
      prefix: [/bin/sh, -c, 'echo junk; exec "$@"', sh]
"#,
        &[("KO_STOP_ESCALATION_MS", "300")],
    );
    let files = Dir::new("ko-rtf-");
    let ws = start_tree(&s, "dev", (&files, text_of(&files)));
    let group = tree_pids(&files);
    drop(ws);
    for pid in group {
        wait_gone(
            pid,
            "the socket closed on a command that ignores HUP and TERM",
        );
    }

    let files = Dir::new("ko-rtf-");
    let mut ws = start_tree(&s, "dev", (&files, text_of(&files)));
    let group = tree_pids(&files);
    ws.send(&json!({"type": "signal", "signal": "term"}));
    stays(
        "a command that ignores SIGTERM keeps running after a term message",
        Duration::from_millis(300),
        || !group[0].has_ended(),
    );
    ws.send(&json!({"type": "signal", "signal": "kill"}));
    assert_eq!(
        read_exec(&mut ws).end,
        json!({"type": "exit", "signal": "KILL"})
    );
    for pid in group {
        wait_gone(pid, "a kill message");
    }

    let mut ws = start_exec(&s, "junk", json!({"argv": ["/bin/true"], "stdin": false}));
    let end = read_exec(&mut ws).end;
    assert_eq!(end["type"], "error");
    assert!(
        end["message"]
            .as_str()
            .unwrap()
            .contains("ko in runtime junk sent invalid output"),
        "{end}"
    );
    closed_with(&mut ws, 1011);
}

// A group member that outlives its leader and holds the command's stdout: only a signal to the
// group ends it.
const STRAGGLER: &str = r#"sh -c 'trap "" TERM; echo $$ > "$0/straggler"; while :; do sleep 0.1; done' "$1" &
exit 0
"#;

#[test]
fn a_cancel_after_the_leader_exited_still_ends_the_group_that_holds_the_output() {
    let s = serve(
        "runtimes:\n  dev: {command: {}}\n",
        &[("KO_STOP_ESCALATION_MS", "300")],
    );
    let files = Dir::new("ko-rtf-");
    let script = files.join("straggler.sh");
    fs::write(&script, STRAGGLER).unwrap();
    let ws = start_exec(
        &s,
        "dev",
        json!({"argv": ["/bin/sh", text_of(&script), text_of(&files)], "stdin": false}),
    );
    let straggler = pid_of(&files.join("straggler"));
    stays(
        "the session waits for the output that the straggler holds",
        Duration::from_millis(300),
        || !straggler.has_ended(),
    );
    drop(ws);
    wait_gone(straggler, "the session closed after its leader exited");
}

// The ko inside, alone: a command that never reads its stdin and ignores TERM, a client that
// pushes more than the ko buffers and then ends the stream. Frames are written by hand: a kind
// byte, a big-endian length, the payload.
#[test]
fn the_ko_inside_learns_that_the_transport_ended_while_it_reads_no_stdin() {
    use std::os::fd::AsFd;
    let files = Dir::new("ko-rtf-");
    fs::write(files.join("tree.sh"), TREE).unwrap();
    let (in_read, in_write) = std::io::pipe().unwrap();
    let (out_read, out_write) = std::io::pipe().unwrap();
    let mut ko = crate::harness::Child::spawn(
        &crate::harness::ko(),
        &["enter", "--exec"],
        &[],
        &[(in_read.as_fd(), 0), (out_write.as_fd(), 1)],
    );
    drop((in_read, out_write));
    let frame = |kind: u8, payload: &[u8]| {
        let mut bytes = vec![kind];
        bytes.extend((payload.len() as u32).to_be_bytes());
        bytes.extend(payload);
        bytes
    };
    let start = json!({
        "argv": ["/bin/sh", text_of(&files.join("tree.sh")), text_of(&files)],
        "env": [],
        "escalation_ms": 300,
    });
    let mut bytes = frame(1, start.to_string().as_bytes());
    for _ in 0..64 {
        bytes.extend(frame(2, &[b'x'; 65536]));
    }
    ko_sys::fd::set_nonblocking(in_write.as_fd()).unwrap();
    let mut sent = 0;
    while sent < bytes.len() {
        if !ko_sys::fd::wait_writable_within(in_write.as_fd(), Duration::from_millis(300)).unwrap()
        {
            break;
        }
        match ko_sys::fd::write(in_write.as_fd(), &bytes[sent..]) {
            Ok(count) => sent += count,
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
            Err(error) => panic!("{error}"),
        }
    }
    assert!(
        sent > 131_072 && sent < bytes.len(),
        "the ko stopped reading after {sent} of {} bytes",
        bytes.len()
    );
    let group = tree_pids(&files);
    assert_eq!(ko.wait(Duration::from_millis(100)), None);
    drop(in_write);
    for pid in group {
        wait_gone(pid, "the end of the ko's stdin while it read none");
    }
    assert!(ko.wait(DEADLINE).is_some(), "the ko ends with its group");
    drop(out_read);
}

#[test]
fn at_most_32_exec_sessions_of_a_runtime_run_and_the_others_wait_in_order_then_give_up() {
    let files = Dir::new("ko-rtf-");
    let names: Vec<String> = (0..=34).map(|i| format!("gate-{i}")).collect();
    let gates = fifos(&files, &names);
    let started = files.join("started");
    fs::create_dir(&started).unwrap();
    let s = serve(
        "runtimes:\n  dev: {command: {}}\n",
        &[("KO_RUNTIME_EXEC_WAIT_MS", "1500")],
    );
    let session = |index: usize| {
        let script = format!(
            "echo up > {}; read x < {}",
            quote(text_of(&started.join(index.to_string()))),
            quote(text_of(&gates[index]))
        );
        start_exec(
            &s,
            "dev",
            json!({"argv": ["/bin/sh", "-c", script], "stdin": false}),
        )
    };
    let mut sessions: Vec<_> = (0..32).map(session).collect();
    poll("32 sessions to run", || {
        (0..32).all(|index| started.join(index.to_string()).exists())
    });
    let mut waiting = session(32);
    stays("the 33rd session waits", Duration::from_millis(250), || {
        !started.join("32").exists()
    });
    release(&s.scratch, &gates[0], "go");
    let first = sessions.remove(0);
    let mut first = first;
    first.within(DEADLINE);
    assert_eq!(
        read_exec(&mut first).end,
        json!({"type": "exit", "status": 0})
    );
    poll("the 33rd session to start when one ends", || {
        started.join("32").exists()
    });

    let mut late = session(0);
    late.within(Duration::from_secs(5));
    let end = read_exec(&mut late).end;
    assert_eq!(end["type"], "error");
    assert!(
        end["message"]
            .as_str()
            .unwrap()
            .contains("no exec slot of runtime dev within 1500 ms"),
        "{end}"
    );
    closed_with(&mut late, 1011);
    release(&s.scratch, &gates[32], "go");
    waiting.within(DEADLINE);
    assert_eq!(
        read_exec(&mut waiting).end,
        json!({"type": "exit", "status": 0})
    );

    let filler = session(34);
    poll("the filler to run", || started.join("34").exists());
    let mut queued = session(33);
    let down = raw(
        &s,
        "POST",
        "/runtimes/dev/down",
        &headers(&s, &[]),
        &json!({"force": true}),
    );
    assert_eq!(down.0, 200, "{}", down.1);
    queued.within(DEADLINE);
    let end = read_exec(&mut queued).end;
    assert_eq!(end["type"], "error");
    assert!(
        end["message"].as_str().unwrap().contains("went down"),
        "{end}"
    );
    assert!(
        !started.join("33").exists(),
        "a forced down starts none of the queued sessions"
    );
    drop(filler);
}

#[test]
fn a_start_step_that_ignores_sigterm_is_killed_when_the_server_exits() {
    let files = Dir::new("ko-rtf-");
    let pidfile = files.join("pid");
    let script = format!(
        "echo $$ > {}; trap '' TERM; exec sleep 60",
        quote(text_of(&pidfile))
    );
    let mut s = serve(
        &format!(
            r#"
runtimes:
  dev:
    command:
      up: ["/bin/sh", "-c", {script:?}]
"#
        ),
        &[],
    );
    rt_pane(&s, "dev", "exec cat");
    let step = pid_of(&pidfile);
    s.server.stop();
    wait_gone(step, "the start step that ignores SIGTERM");
}

#[test]
fn a_pane_starts_in_the_directory_of_another_pane_mapped_through_the_paths_of_the_runtimes() {
    let scratch = Dir::new("ko-rtd-");
    let maps = fs::canonicalize(&*scratch).unwrap();
    let canon = |path: PathBuf| {
        fs::canonicalize(path)
            .unwrap()
            .to_string_lossy()
            .into_owned()
    };
    for sub in [
        "host/sub",
        "host/sp ace",
        "rt/sub",
        "rt/sp ace",
        "outside",
        "other",
    ] {
        fs::create_dir_all(maps.join(sub)).unwrap();
    }
    let s = serve(
        &format!(
            r#"
runtimes:
  dev:
    command: {{}}
    cwd: /
    paths:
      - host: {host}
        runtime: {rt}
  other:
    command: {{}}
    cwd: {other}
"#,
            host = text_of(&maps.join("host")),
            rt = text_of(&maps.join("rt")),
            other = text_of(&maps.join("other")),
        ),
        &[],
    );
    let reports_from = |machine: &str, dir: &Path| {
        let uri = format!("file://{machine}{}", dir.display()).replace(' ', "%20");
        format!(
            "stty raw -echo; printf '\\033]7;%s\\a' {}; exec cat",
            quote(&uri)
        )
    };
    let reports = |dir: &Path| reports_from("somewhere", dir);
    let reported = |pane: String| {
        s.wait_row(&pane, &format!("{pane} to report its directory"), |row| {
            row["cwd"].as_str().unwrap().starts_with("file://")
        });
        pane
    };
    let at = |new: Value| {
        let mut request = sh("pwd -P; echo DONE; exec cat");
        request.as_object_mut().unwrap().remove("cwd");
        request
            .as_object_mut()
            .unwrap()
            .extend(new.as_object().unwrap().clone());
        let pane = crate::panes::new_pane(&s, &request);
        s.screen_has(&pane, "DONE");
        s.screen(&pane).lines().next().unwrap().trim().to_owned()
    };
    let from = |pane: &str| json!({"cwd": {"pane": pane}});
    let into = |pane: &str, runtime: &str| json!({"cwd": {"pane": pane}, "runtime": runtime});

    let spawned = {
        let mut request = sh("exec cat");
        request["cwd"] = json!(text_of(&maps.join("host/sub")));
        s.new_pane(request)
    };
    let host = reported(s.pane(&reports_from("localhost", &maps.join("host/sp ace"))));
    let rt_reports = |dir: &str| reported(rt_pane(&s, "dev", &reports(&maps.join(dir))));
    let rt = rt_reports("rt/sp ace");
    let rt_outside = rt_reports("outside");
    let mut foreign = sh(&reports_from("elsewhere.example", &maps.join("host/sub")));
    foreign.as_object_mut().unwrap().remove("cwd");
    let foreign = reported(s.new_pane(foreign));
    let rt_unknown = rt_pane(&s, "dev", "exec cat");
    let plain = at(json!({}));

    assert_eq!(
        at(from(&spawned)),
        canon(maps.join("host/sub")),
        "the spawn directory of a host pane"
    );
    assert_eq!(
        at(from(&host)),
        canon(maps.join("host/sp ace")),
        "a reported directory is decoded"
    );
    assert_eq!(
        at(into(&spawned, "dev")),
        canon(maps.join("rt/sub")),
        "host to runtime maps"
    );
    assert_eq!(at(into(&host, "dev")), canon(maps.join("rt/sp ace")));
    assert_eq!(
        at(into(&rt, "dev")),
        canon(maps.join("rt/sp ace")),
        "runtime to its runtime is as it is"
    );
    assert_eq!(
        at(from(&rt)),
        canon(maps.join("host/sp ace")),
        "runtime to host maps back"
    );
    assert_eq!(
        at(from(&rt_outside)),
        plain,
        "no path maps back: the default"
    );
    assert_eq!(
        at(from(&rt_unknown)),
        plain,
        "a runtime pane that reported nothing has no directory"
    );
    assert_eq!(
        at(from(&foreign)),
        plain,
        "a host pane that reports another machine has no directory"
    );
    assert_eq!(at(into(&foreign, "dev")), "/");
    assert_eq!(at(into(&rt_unknown, "dev")), "/", "the runtime's default");
    assert_eq!(
        at(into(&rt, "other")),
        canon(maps.join("other")),
        "another runtime: the default when nothing maps"
    );
    assert_eq!(at(into(&rt_outside, "dev")), canon(maps.join("outside")));

    let put = s.new_pane(json!({"cwd": {"pane": rt}, "command": {"type": "shell", "command": "pwd -P; echo DONE; exec cat"}}));
    s.screen_has(&put, "DONE");
    assert_eq!(
        s.screen(&put).lines().next().unwrap().trim(),
        canon(maps.join("host/sp ace"))
    );
    let elsewhere = token_pane_in_new_session(&s, "elsewhere");
    let caller = rt_token_pane(&s, "dev");
    let token = s.token(&caller).unwrap();
    let who = Some((caller.as_str(), token.as_str()));
    let cat = json!({"type": "shell", "command": "pwd -P; echo DONE; exec cat"});
    let reply = via(
        &s,
        "dev",
        ("POST", "/panes"),
        who,
        &json!({"command": cat, "cwd": {"pane": rt}}),
    );
    assert_eq!(reply.0, 200, "{}", reply.1);
    let pane = reply.1["pane"].as_str().unwrap();
    s.screen_has(pane, "DONE");
    assert_eq!(
        s.screen(pane).lines().next().unwrap().trim(),
        canon(maps.join("rt/sp ace"))
    );
    refuses(
        via(
            &s,
            "dev",
            ("POST", "/panes"),
            who,
            &json!({"command": cat, "cwd": {"pane": elsewhere}}),
        ),
        "is not visible to",
    );
    let (status, missing) = via(
        &s,
        "dev",
        ("POST", "/panes"),
        who,
        &json!({"command": cat, "cwd": {"pane": "pane_999"}}),
    );
    assert_eq!(
        (status, missing["kind"].as_str()),
        (404, Some("not_found")),
        "{missing}"
    );
    assert!(
        missing["message"]
            .as_str()
            .unwrap()
            .contains("no pane pane_999 to start in"),
        "{missing}"
    );
}
