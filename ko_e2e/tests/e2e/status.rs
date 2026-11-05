use serde_json::{Value, json};

use crate::harness::{Server, Ws, base64, start};

pub(crate) struct Probe<'a> {
    pub(crate) s: &'a Server,
    pub(crate) pane: String,
    watcher: Ws,
}

pub(crate) fn osc7501(body: &str) -> String {
    format!("\x1b]7501;{body}\x07")
}

impl<'a> Probe<'a> {
    pub(crate) fn new(s: &'a Server, pane: String) -> Probe<'a> {
        s.text(&pane, "\n");
        Probe::after(s, pane, "the status of cat", |status| {
            status["title"] == "cat"
        })
    }

    pub(crate) fn after(
        s: &'a Server,
        pane: String,
        what: &str,
        mut check: impl FnMut(&Value) -> bool,
    ) -> Probe<'a> {
        s.wait_row(&pane, what, |row| {
            !row["status"].is_null() && check(&row["status"])
        });
        let (watcher, _) = s.client(None);
        Probe { s, pane, watcher }
    }

    pub(crate) fn collect_until(
        &mut self,
        what: &str,
        mut check: impl FnMut(&Value) -> bool,
    ) -> Vec<Value> {
        let mut seen = Vec::new();
        for _ in 0..200 {
            let status = self.next();
            let done = check(&status);
            seen.push(status);
            if done {
                return seen;
            }
        }
        panic!("no status event: {what}");
    }

    pub(crate) fn feed(&self, bytes: &str) {
        self.s.text(&self.pane, bytes);
    }

    pub(crate) fn next(&mut self) -> Value {
        let event = self.watcher.event("status");
        assert_eq!(event["pane"], self.pane.as_str(), "{event}");
        event["status"].clone()
    }

    pub(crate) fn send(&mut self, bytes: &str) -> Value {
        self.feed(bytes);
        self.next()
    }

    pub(crate) fn osc(&mut self, body: &str) -> Value {
        self.send(&osc7501(body))
    }

    pub(crate) fn until(&mut self, what: &str, mut check: impl FnMut(&Value) -> bool) -> Value {
        for _ in 0..200 {
            let status = self.next();
            if check(&status) {
                return status;
            }
        }
        panic!("no status event: {what}");
    }
}

pub(crate) fn agent(status: &Value) -> &Value {
    &status["kind"]["status"]
}

pub(crate) fn state(status: &Value) -> &str {
    agent(status)["state"]["type"].as_str().unwrap_or_default()
}

pub(crate) fn phase(status: &Value) -> &Value {
    &status["kind"]["phase"]
}

pub(crate) fn serial(status: &Value) -> u64 {
    status["program_status"]["serial"].as_u64().unwrap()
}

pub(crate) fn records(status: &Value) -> Vec<(String, String)> {
    status["program_status"]["records"]
        .as_array()
        .unwrap()
        .iter()
        .map(|record| {
            (
                record["id"].as_str().unwrap().to_owned(),
                record["state"].as_str().unwrap().to_owned(),
            )
        })
        .collect()
}

#[test]
fn status_events_for_an_agent() {
    let s = start(&[]);
    let pane = s.echo_pane();
    let mut probe = Probe::new(&s, pane.clone());

    let status = probe.osc("state=idle:app=claude-code");
    assert_eq!(status["kind"]["type"], "some_agent");
    assert_eq!(status["kind"]["name"], "claude-code");
    assert_eq!(status["title"], "claude-code");
    assert_eq!(state(&status), "idle");
    assert!(agent(&status)["state"]["outcome"].is_null());

    let status = probe.send("\x1b]2;Claude Code\x07");
    assert_eq!(status["title"], "Claude Code");
    let status = probe.send("\x1b]2;\x07");
    assert_eq!(status["title"], "claude-code");

    let status = probe.osc("state=working:app=claude-code");
    assert_eq!(state(&status), "running");
    let working = serial(&status);

    let status = probe.osc("state=done:app=claude-code");
    assert_eq!(state(&status), "idle");
    let done = serial(&status);
    assert!(done > working);
    assert_eq!(
        agent(&status)["state"]["outcome"],
        json!({"serial": done, "result": "success"})
    );

    let message = base64("Allow rm?".as_bytes());
    let status = probe.osc(&format!(
        "state=blocked:app=claude-code:kind=permission:msg={message}"
    ));
    assert_eq!(state(&status), "waiting");
    assert_eq!(agent(&status)["state"]["kind"], "permission");
    assert_eq!(agent(&status)["msg"], "Allow rm?");
    assert_eq!(status["message"], "Allow rm?");

    let status = probe.osc("state=idle:app=claude-code");
    assert_eq!(state(&status), "idle");
    assert!(agent(&status)["state"]["outcome"].is_null());
    let idle = serial(&status);

    probe.feed(&osc7501("state=idle:app=claude-code"));
    let status = probe.osc("state=working:app=claude-code");
    assert_eq!(state(&status), "running");
    assert_eq!(
        serial(&status),
        idle + 1,
        "an unchanged report moved neither the serial nor the events"
    );
}

fn report(status: &Value) -> &Value {
    &status["kind"]["report"]
}

fn record<'a>(status: &'a Value, id: &str) -> &'a Value {
    status["program_status"]["records"]
        .as_array()
        .unwrap()
        .iter()
        .find(|record| record["id"] == id)
        .unwrap_or_else(|| panic!("no record {id:?} in {}", status["program_status"]))
}

#[test]
fn program_status_records() {
    let s = start(&[]);
    let pane = s.echo_pane();
    let started = s.row(&pane)["started"].as_u64().unwrap();
    assert!(started > 0);
    let mut probe = Probe::new(&s, pane);
    let message = base64("compiling".as_bytes());
    let title = base64("Build".as_bytes());

    let status = probe.osc(&format!(
        "state=working:app=builder:title={title}:msg={message}"
    ));
    assert_eq!(status["kind"]["type"], "terminal");
    assert_eq!(report(&status)["state"]["type"], "running");
    assert_eq!(report(&status)["msg"], "compiling");
    assert_eq!(record(&status, "")["title"], "Build");
    assert!(record(&status, "").get("started").is_none());

    let long = "m".repeat(1500);
    let status = probe.osc(&format!(
        "state=working:app=builder:msg={}",
        base64(long.as_bytes())
    ));
    assert_eq!(report(&status)["msg"].as_str().map(str::len), Some(1500));

    let status = probe.osc("state=blocked:app=builder:kind=question");
    assert_eq!(report(&status)["state"]["type"], "waiting");
    assert_eq!(report(&status)["state"]["kind"], "question");

    let status = probe.osc("id=child:state=blocked:progress=42");
    assert_eq!(record(&status, "child")["progress"], 42);
    let child_started = record(&status, "child")["started"].as_u64().unwrap();
    assert!(record(&status, "child")["app"].is_null());
    assert_eq!(report(&status)["state"]["type"], "waiting");

    let status = probe.osc("state=working:app=builder");
    assert_eq!(report(&status)["state"]["type"], "waiting");
    let status = probe.osc("id=child:state=error");
    assert_eq!(record(&status, "child")["started"], child_started);
    assert_eq!(report(&status)["state"]["type"], "running");
    assert!(report(&status)["state"]["outcome"].is_null());
    let failed_at = serial(&status);

    let status = probe.osc("state=idle:app=builder");
    assert_eq!(
        report(&status)["state"],
        json!({"type": "idle", "outcome": {"serial": failed_at, "result": "failure"}})
    );

    let status = probe.osc("id=child:state=clear");
    assert!(!records(&status).iter().any(|(id, _)| id == "child"));
    assert_eq!(
        report(&status)["state"]["outcome"],
        json!({"serial": failed_at, "result": "failure"}),
        "clearing a record keeps the outcome"
    );
    let status = probe.osc("state=clear");
    assert!(records(&status).is_empty());
    assert_eq!(
        report(&status)["state"]["outcome"]["result"],
        "failure",
        "clearing everything keeps the failure"
    );

    let status = probe.osc("state=working:app=builder");
    assert_eq!(report(&status)["state"]["type"], "running");
    let status = probe.send("\x1b]133;A\x07");
    assert!(
        !records(&status).iter().any(|(_, state)| state == "working"),
        "a prompt start clears the working root: {status}"
    );

    let status = probe.osc("state=done:app=builder");
    let done = serial(&status);
    let outcome = json!({"serial": done, "result": "success"});
    assert_eq!(report(&status)["state"]["outcome"], outcome);
    let status = probe.osc(&format!(
        "state=done:app=builder:msg={}",
        base64("again".as_bytes())
    ));
    assert_eq!(report(&status)["state"]["outcome"], outcome);
    assert_eq!(report(&status)["msg"], "again");
    assert!(serial(&status) > done);
    let status = probe.osc("state=error:app=builder");
    assert_eq!(report(&status)["state"]["outcome"]["result"], "failure");
    assert_eq!(
        report(&status)["state"]["outcome"]["serial"],
        serial(&status)
    );
    let status = probe.osc("id=child:state=working");
    assert!(record(&status, "child")["started"].as_u64().unwrap() > child_started);
    assert_eq!(s.row(&probe.pane)["started"], started);
}

#[test]
fn record_set_rules() {
    let s = start(&[]);
    let pane = s.echo_pane();
    let mut probe = Probe::new(&s, pane);
    let mut batch = String::new();
    for index in 0..65 {
        batch.push_str(&osc7501(&format!(
            "id=r{index:02}:state=working:progress=5"
        )));
    }
    probe.feed(&batch);
    let status = probe.until("all 65 reports", |status| {
        status["program_status"]["records"].as_array().map(Vec::len) == Some(64)
            && serial(status) == 65
    });
    let ids: Vec<String> = records(&status).into_iter().map(|(id, _)| id).collect();
    assert!(
        !ids.contains(&"r00".to_owned()),
        "the oldest is evicted: {ids:?}"
    );
    assert!(ids.contains(&"r64".to_owned()));

    let before = serial(&status);
    probe.feed(&osc7501("id=r01:state=working:progress=5"));
    let status = probe.osc("id=r02:state=working:progress=6");
    assert_eq!(
        serial(&status),
        before + 1,
        "an identical report moved nothing"
    );
    probe.osc("id=newest:state=working:progress=1");
    let status = probe.osc("id=newer:state=working:progress=1");
    let ids: Vec<String> = records(&status).into_iter().map(|(id, _)| id).collect();
    assert!(
        ids.contains(&"r02".to_owned()),
        "an updated record moved to the newest: {ids:?}"
    );
    assert!(
        !ids.contains(&"r01".to_owned()),
        "r01 became the oldest: {ids:?}"
    );

    probe.osc("state=clear");
    probe.osc("id=x:state=idle");
    probe.osc("id=x/y:state=idle");
    let status = probe.osc("id=xy:state=idle");
    assert_eq!(records(&status).len(), 3);
    let status = probe.osc("id=x:state=clear");
    assert_eq!(
        records(&status),
        [("xy".to_owned(), "idle".to_owned())],
        "clear x removes x/y and not xy"
    );
}

#[test]
fn child_records() {
    let s = start(&[]);
    let pane = s.echo_pane();
    let mut probe = Probe::new(&s, pane);
    for (id, app) in [("", "claude-code"), ("a", ""), ("a/b", ""), ("a-other", "")] {
        let app = if app.is_empty() {
            String::new()
        } else {
            format!(":app={app}")
        };
        let id = if id.is_empty() {
            String::new()
        } else {
            format!("id={id}:")
        };
        probe.osc(&format!("{id}state=working{app}"));
    }
    let status = probe.osc("id=a/b/c:state=idle");
    assert_eq!(
        records(&status)
            .into_iter()
            .map(|(id, _)| id)
            .collect::<Vec<_>>(),
        ["", "a", "a-other", "a/b", "a/b/c"],
        "published in bytewise order"
    );
    assert_eq!(status["kind"]["name"], "claude-code");
}

use std::path::PathBuf;

use crate::harness::{DEADLINE, Dir, run_program, which};

pub(crate) enum Flavour {
    Zsh,
    Bash,
}

pub(crate) fn shell_of(flavour: &Flavour) -> Option<PathBuf> {
    match flavour {
        Flavour::Zsh => which("zsh"),
        Flavour::Bash => {
            let bash = which("bash")?;
            let probe = Dir::new("ko-bash-probe-");
            let version = run_program(
                &probe,
                &bash,
                &[],
                &["-c", "echo ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"],
                "",
                DEADLINE,
            )
            .stdout;
            let (major, minor) = version.trim().split_once('.')?;
            let (major, minor): (u32, u32) = (major.parse().ok()?, minor.parse().ok()?);
            (major > 4 || (major == 4 && minor >= 4)).then_some(bash)
        }
    }
}

pub(crate) fn dotfiles(flavour: &Flavour, home: &std::path::Path, extra: &str) {
    let (name, body) = match flavour {
        Flavour::Zsh => (".zshrc", format!("PROMPT='READY> '\n{extra}")),
        Flavour::Bash => (".bash_profile", format!("PS1='READY> '\n{extra}")),
    };
    std::fs::write(home.join(name), body).unwrap();
}

pub(crate) fn command_of(phase: &Value) -> Option<&str> {
    phase["origin"]["command"].as_str()
}

fn shell_phases(flavour: Flavour) {
    let Some(shell) = shell_of(&flavour) else {
        eprintln!("skipped: no suitable shell on PATH");
        return;
    };
    let s = crate::harness::start_with(&shell, &[], &[]);
    dotfiles(&flavour, &s.dir, "");
    let pane = s.shell_pane();
    let mut probe = Probe::after(&s, pane.clone(), "the first prompt", |status| {
        status["kind"]["phase"]["type"] == "idle"
    });
    let row = s.row(&pane);
    assert!(
        row["status"]["kind"]["phase"]["last"].is_null(),
        "no exit at the first prompt: {row}"
    );

    s.text(&pane, "sleep 1\r");
    let seen = probe.collect_until("sleep 1 running", |status| {
        phase(status)["type"] == "running"
    });
    let running = seen.last().unwrap();
    assert_eq!(command_of(phase(running)), Some("sleep 1"));
    assert_eq!(phase(running)["fullscreen"], false);
    let started = phase(running)["origin"]["started_at"].as_u64().unwrap();
    let promoted = running["since"].as_u64().unwrap();
    assert!(
        promoted - started >= 200_000_000,
        "promoted {} ms after the command started",
        (promoted - started) / 1_000_000
    );
    assert!(
        seen[..seen.len() - 1]
            .iter()
            .all(|status| phase(status)["type"] != "running"),
        "no running phase before the debounce: {seen:?}"
    );
    let seen = probe.collect_until("sleep 1 done", |status| {
        phase(status)["type"] == "idle" && !phase(status)["last"].is_null()
    });
    let last = &phase(seen.last().unwrap())["last"];
    assert_eq!(last["code"], 0);
    assert_eq!(last["command"], "sleep 1");

    s.text(&pane, "false\r");
    let seen = probe.collect_until("false done", |status| {
        phase(status)["last"]["command"] == "false"
    });
    assert_eq!(phase(seen.last().unwrap())["last"]["code"], 1);
    assert!(
        seen.iter().all(|status| phase(status)["type"] != "running"),
        "a short command never shows running: {seen:?}"
    );

    s.text(&pane, "true\r");
    let seen = probe.collect_until("true done", |status| {
        phase(status)["last"]["command"] == "true"
    });
    assert_eq!(phase(seen.last().unwrap())["last"]["code"], 0);
    assert!(seen.iter().all(|status| phase(status)["type"] != "running"));
}

#[test]
fn shell_phase_zsh() {
    shell_phases(Flavour::Zsh);
}

#[test]
fn shell_phase_bash() {
    shell_phases(Flavour::Bash);
}

#[test]
fn heal_rule() {
    let s = start(&[]);
    let pane = s.echo_pane();
    let mut probe = Probe::new(&s, pane);
    probe.feed("\x1b]133;C;cmdline_url=lost\x07");
    probe.collect_until("lost running", |status| phase(status)["type"] == "running");
    let status = probe.send("\x1b]133;A\x07");
    assert_eq!(phase(&status), &json!({"type": "idle"}));
}

#[test]
fn alternate_screen() {
    let s = start(&[]);
    let pane = s.echo_pane();
    let mut probe = Probe::new(&s, pane);
    probe.feed("\x1b]133;C;cmdline_url=vim\x07\x1b[?1049h");
    let seen = probe.collect_until("fullscreen at once", |status| {
        phase(status)["fullscreen"] == true
    });
    let running = seen.last().unwrap().clone();
    assert_eq!(command_of(phase(&running)), Some("vim"), "{seen:?}");
    let started = phase(&running)["origin"]["started_at"].as_u64().unwrap();
    assert!(
        running["since"].as_u64().unwrap() - started < 200_000_000,
        "the alternate screen runs at once, without the debounce"
    );
    let status = probe.send("\x1b[?1049l");
    assert_eq!(phase(&status)["type"], "running");
    assert_eq!(phase(&status)["fullscreen"], false);
    assert_eq!(command_of(phase(&status)), Some("vim"));
}

#[test]
fn foreground_on_events() {
    let Some(shell) = shell_of(&Flavour::Zsh) else {
        eprintln!("skipped: no zsh on PATH");
        return;
    };
    let s = crate::harness::start_with(&shell, &[], &[]);
    dotfiles(&Flavour::Zsh, &s.dir, "");
    let pane = s.shell_pane();
    s.wait_row(&pane, "the first prompt", |row| {
        row["status"]["kind"]["phase"]["type"] == "idle"
    });
    assert_eq!(s.row(&pane)["foreground"]["name"], "zsh");
    let probe_dir = Dir::new("ko-probe-");
    crate::shell::fake(&probe_dir, "ko-probe");
    s.text(
        &pane,
        &format!("{}\r", probe_dir.join("ko-probe").display()),
    );
    let row = s.wait_row(
        &pane,
        "the program in the foreground at its output",
        |row| row["foreground"]["name"] == "ko-probe",
    );
    assert!(row["foreground"]["pid"].as_u64().unwrap() > 1);
    s.text(&pane, "\r");
    s.wait_row(&pane, "zsh back in the foreground at the prompt", |row| {
        row["foreground"]["name"] == "zsh"
    });
}

#[test]
fn pi_variables_gate() {
    let s = start(&[]);
    let pane = s.echo_pane();
    let mut probe = Probe::new(&s, pane.clone());
    for (name, value) in [
        ("pi.session", "s1"),
        ("pi.name", "Worker"),
        ("pi.activity", "checking"),
    ] {
        s.set_var(&pane, name, &json!(value));
    }
    let status = s.wait_row(&pane, "the variables", |row| {
        row["vars"]["pi.activity"] == "checking"
    })["status"]
        .clone();
    assert_eq!(status["kind"]["type"], "terminal");
    assert_ne!(
        status["title"], "Worker",
        "options need a pi root: {status}"
    );

    let status = probe.osc("state=idle:app=pi");
    assert_eq!(status["kind"]["type"], "pi_agent");
    assert_eq!(status["kind"]["session"], "s1");
    assert_eq!(status["title"], "Worker");
    assert_eq!(status["message"], "checking");

    let status = probe.osc("state=clear");
    assert_eq!(status["kind"]["type"], "terminal");
    assert_ne!(status["title"], "Worker");
}
