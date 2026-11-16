use std::cell::RefCell;
use std::collections::HashMap;
use std::fs;
use std::thread;

use serde_json::{Value, json};

use crate::harness::{PRINT_TOKEN, Server, poll, run_ko, start, start_with, which};
use crate::harness::{code, ko_command};
use crate::messages::{ack, answer, open, received};
use crate::panes::as_pane;

const AGENT_LOOP: &str =
    "printf '\\033]7501;state=idle:app=pi\\007'; while read line; do echo \"got: $line\"; done";
const PI_ROOT: &str = "printf '\\033]7501;state=idle:app=pi\\007'";

fn pi_vars(name: &str) -> Value {
    json!({"pi.session": format!("session-{name}"), "pi.name": name})
}

fn program(command: &str, vars: Value) -> Value {
    json!({
        "command": {"type": "shell", "command": format!("stty sane; {PRINT_TOKEN}; {command}")},
        "vars": vars
    })
}

fn rooted(s: &Server, pane: &str) {
    s.wait_row(pane, "its pi root", |row| {
        row["status"]["program_status"]["records"]
            .as_array()
            .is_some_and(|records| !records.is_empty())
    });
}

fn foreground(s: &Server, pane: &str, name: &str) {
    s.wait_row(pane, "its foreground", |row| {
        row["foreground"]["name"] == name
    });
}

fn left_editor(s: &Server, pane: &str) {
    s.wait_row(pane, "its shell back", |row| {
        !row["foreground"].is_null() && row["foreground"]["name"] != "nvim"
    });
}

fn agent(s: &Server, name: &str) -> String {
    let pane = s.new_pane(program(AGENT_LOOP, pi_vars(name)));
    s.screen_has(&pane, "TOKEN<");
    rooted(s, &pane);
    pane
}

fn splitting(tree: &mut Value, anchor: &str, new: &Value) {
    if tree["pane"] == anchor {
        *tree = json!({"split": "h", "children": [{"pane": anchor}, {"pane": {"new": new}}]});
        return;
    }
    for child in tree["children"].as_array_mut().into_iter().flatten() {
        splitting(child, anchor, new);
    }
}

fn split_into(s: &Server, anchor: &str, new: Value) -> String {
    let put = s.edit(|layout| {
        for session in layout["sessions"].as_array_mut().unwrap() {
            for window in session["windows"].as_array_mut().unwrap() {
                splitting(&mut window["tree"], anchor, &new);
            }
        }
    });
    let mut leaves = Vec::new();
    for window in crate::layout::windows(&put) {
        crate::layout::leaves(&window["tree"], &mut leaves);
    }
    let added = leaves
        .into_iter()
        .map(|leaf| leaf.0)
        .max_by_key(|pane| pane.trim_start_matches("pane_").parse::<u64>().unwrap_or(0));
    added.expect("the split pane")
}

thread_local! {
    static TOKENS: RefCell<HashMap<String, String>> = RefCell::new(HashMap::new());
}

// A split narrows its neighbours, and the screen of a narrowed pane no longer holds its token
// whole, so the token is read once, while the pane is new.
fn remembered(s: &Server, pane: String) -> String {
    poll(&format!("the token of {pane}"), || s.token(&pane).is_some());
    TOKENS.with(|tokens| {
        tokens
            .borrow_mut()
            .insert(pane.clone(), s.token(&pane).unwrap())
    });
    pane
}

fn pane_in(s: &Server, anchor: &str, new: Value) -> String {
    remembered(s, split_into(s, anchor, new))
}

fn prompt(s: &Server, from: &str, n: u32) -> (i32, String) {
    let (mut env, argv) = ko_command(s, Some(from), &["prompt"]);
    env.retain(|entry| !entry.starts_with(b"KO_PANE_TOKEN="));
    let token = TOKENS.with(|tokens| tokens.borrow()[from].clone());
    env.push(format!("KO_PANE_TOKEN={token}").into_bytes());
    let argv: Vec<&str> = argv.iter().map(String::as_str).collect();
    let run = run_ko(&s.scratch, &env, &argv, &format!("echo p{n}x$((40+2))"));
    (code(&run), run.stderr)
}

fn no_agent(s: &Server, from: &str, n: u32) {
    let (status, stderr) = prompt(s, from, n);
    assert_eq!(
        (status, stderr.as_str()),
        (4, "ko prompt: agent not found\n"),
        "prompt {n} from {from}"
    );
}

fn flat(s: &Server, pane: &str) -> String {
    s.screen(pane).split_whitespace().collect()
}

fn untouched(s: &Server, pane: &str, n: u32) {
    let screen = flat(s, pane);
    assert!(
        !screen.contains(&format!("p{n}x")),
        "{pane} got input: {screen}"
    );
}

fn shows(s: &Server, pane: &str, text: String) {
    poll(&format!("{text} on {pane}"), || {
        flat(s, pane).contains(&text)
    });
}

fn got(s: &Server, pane: &str, n: u32) {
    shows(s, pane, format!("got:echop{n}x"));
}

fn ran(s: &Server, pane: &str, n: u32) {
    shows(s, pane, format!("p{n}x42"));
}

#[test]
fn a_prompt_goes_to_the_one_live_agent_of_the_callers_window() {
    let s = start(&[]);
    let bin = s.dir.join("bin");
    fs::create_dir(&bin).unwrap();
    let nvim = crate::shell::fake(&bin, "nvim");
    let claude = crate::shell::fake(&bin, "claude");
    let (nvim, claude) = (nvim.display().to_string(), claude.display().to_string());
    let editing = |pane: &str| {
        s.text(pane, &format!("{PI_ROOT}\r"));
        rooted(&s, pane);
        s.text(pane, &format!("{nvim}\r"));
        foreground(&s, pane, "nvim");
    };

    let caller = remembered(&s, s.new_pane(program("exec sh -i", pi_vars("former"))));
    editing(&caller);
    let stale = pane_in(&s, &caller, program("exec sh -i", pi_vars("stale")));
    editing(&stale);
    let terminal = split_into(&s, &caller, json!({"cwd": "/tmp"}));
    let dead = split_into(
        &s,
        &caller,
        json!({
            "command": {"type": "shell", "command": format!("{PI_ROOT}; exit 0")},
            "vars": pi_vars("dead"), "close": "on_exit"
        }),
    );
    s.wait_row(&dead, "its end", |row| !row["dead"].is_null());
    let far = agent(&s, "far");

    no_agent(&s, &caller, 1);
    no_agent(&s, &stale, 2);
    for pane in [&caller, &stale, &terminal, &dead, &far] {
        untouched(&s, pane, 1);
        untouched(&s, pane, 2);
    }

    let user = remembered(&s, s.token_pane("exec cat"));
    let shell = pane_in(&s, &user, program("exec sh -i", pi_vars("shell")));
    s.text(&shell, &format!("{PI_ROOT}\r"));
    rooted(&s, &shell);
    assert_eq!(prompt(&s, &user, 3), (0, String::new()));
    ran(&s, &shell, 3);
    s.text(&shell, &format!("{nvim}\r"));
    foreground(&s, &shell, "nvim");
    no_agent(&s, &user, 4);
    untouched(&s, &shell, 4);
    s.text(&shell, "exit\r");
    left_editor(&s, &shell);
    assert_eq!(
        prompt(&s, &user, 5),
        (0, String::new()),
        "the agent is back without a new report"
    );
    ran(&s, &shell, 5);
    s.text(
        &shell,
        "printf '\\033]7501;state=done:app=pi\\007\\033]133;A\\007'\r",
    );
    s.text(&shell, &format!("{nvim}\r"));
    foreground(&s, &shell, "nvim");
    no_agent(&s, &user, 6);
    untouched(&s, &shell, 6);
    s.text(&shell, "exit\r");
    left_editor(&s, &shell);
    no_agent(&s, &user, 7);
    untouched(&s, &shell, 7);

    let pi = pane_in(&s, &user, program(AGENT_LOOP, pi_vars("one")));
    rooted(&s, &pi);
    assert_eq!(prompt(&s, &user, 8), (0, String::new()));
    got(&s, &pi, 8);
    for pane in [&user, &far] {
        untouched(&s, pane, 8);
    }

    let code_pane = pane_in(&s, &user, program(&format!("exec {claude}"), json!({})));
    s.text(&code_pane, "agent\r");
    rooted(&s, &code_pane);
    assert_eq!(prompt(&s, &user, 9).0, 5, "two agents in the window");
    untouched(&s, &pi, 9);
    untouched(&s, &code_pane, 9);
    assert_eq!(prompt(&s, &pi, 10), (0, String::new()));
    got(&s, &code_pane, 10);
    untouched(&s, &pi, 10);
    assert_eq!(prompt(&s, &code_pane, 11), (0, String::new()));
    got(&s, &pi, 11);
    untouched(&s, &code_pane, 11);
}

#[test]
fn a_prompt_goes_through_the_message_queue_when_the_agent_has_a_stream() {
    let s = start(&[]);
    let from = s.token_pane("exec cat");
    let pane = pane_in(&s, &from, program(AGENT_LOOP, pi_vars("streamer")));
    rooted(&s, &pane);
    let mut stream = open(&s, &pane);
    let mut next = || {
        let message = received(&mut stream);
        ack(&mut stream, message["id"].as_str().unwrap());
        message
    };

    let (env, argv) = ko_command(&s, Some(&from), &["prompt"]);
    let argv: Vec<&str> = argv.iter().map(String::as_str).collect();
    let scratch = &s.scratch;
    let (sent, message) = thread::scope(|scope| {
        let sending = scope.spawn(|| run_ko(scratch, &env, &argv, "over the stream"));
        let message = next();
        (sending.join().unwrap(), message)
    });
    assert_eq!((code(&sent), sent.stderr.as_str()), (0, ""));
    assert_eq!(
        (
            message["kind"].as_str(),
            message["text"].as_str(),
            message["from"].clone(),
            message["relation"].as_str()
        ),
        (
            Some("user"),
            Some("over the stream"),
            json!({"type": "pane", "pane": from}),
            Some("sibling")
        ),
        "a pane sender is stamped"
    );
    assert!(
        !s.screen(&pane).contains("got: over the stream"),
        "a queued prompt types nothing"
    );

    let body = json!({"from": from, "id": "prompt-user-1", "target": pane, "text": "as the user"});
    let waiting = s.send_request("POST", "/prompt", &s.headers(), body.to_string().as_bytes());
    let message = next();
    assert_eq!(
        answer(&s, waiting),
        (
            200,
            json!({"via": {"type": "message", "state": "acked", "seq": 2}})
        )
    );
    assert_eq!(message["from"], json!({"type": "user"}));
    assert_eq!(message.get("relation"), None);

    let lost_body =
        json!({"from": from, "id": "prompt-lost-1", "target": pane, "text": "lost reply"})
            .to_string();
    let lost = s.send_request("POST", "/prompt", &s.headers(), lost_body.as_bytes());
    assert_eq!(received(&mut stream)["id"], "prompt-lost-1");
    drop(lost);
    drop(stream);
    s.wait_row(&pane, "its stream to close", |row| {
        row.get("inbox").is_none()
    });
    let (status, repeat) = s.exchange("POST", "/prompt", &s.headers(), lost_body.as_bytes());
    assert_eq!(
        (status, serde_json::from_slice::<Value>(&repeat).unwrap()),
        (
            200,
            json!({"via": {"type": "message", "state": "queued", "seq": 3, "duplicate": true}})
        ),
        "a repeat of a prompt id that the queue knows goes by the queue, not by a paste"
    );

    let far = agent(&s, "far");
    let headers = as_pane(&s, &from);
    let send_as = |who: &crate::panes::Headers, from: &str, target: &str, text: &str| {
        let body = json!({"from": from, "id": "prompt-0001", "target": target, "text": text});
        s.exchange("POST", "/prompt", who, body.to_string().as_bytes())
            .0
    };
    let resolved = s.exchange(
        "GET",
        &format!("/prompt/resolve?from={from}"),
        &headers,
        b"",
    );
    let panes: Vec<String> = serde_json::from_slice::<Vec<Value>>(&resolved.1)
        .unwrap()
        .iter()
        .map(|candidate| candidate["pane"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!((resolved.0, panes), (200, vec![pane.clone(), far.clone()]));
    assert_eq!(
        send_as(&headers, &from, &from, "x"),
        400,
        "a terminal is no agent"
    );
    assert_eq!(send_as(&headers, &from, &pane, ""), 400);
    assert_eq!(
        send_as(&headers, &pane, &far, "x"),
        409,
        "a pane identity names only itself"
    );
    assert_eq!(send_as(&s.headers(), &from, &far, "explicit"), 200);
    shows(&s, &far, "got:explicit".to_owned());
    let missing = s.exchange("GET", "/prompt/resolve", &s.headers(), b"");
    assert_eq!(missing.0, 400, "no pane to prompt from");
}

#[test]
fn a_multi_line_prompt_reaches_the_agent_as_one_paste() {
    let Some(zsh) = which("zsh") else {
        return;
    };
    let s = start_with(std::path::Path::new("/bin/sh"), &[], &[]);
    let from = s.token_pane("exec cat");
    let pane = pane_in(
        &s,
        &from,
        program(&format!("exec {} -f", zsh.display()), pi_vars("multi")),
    );
    poll("a zsh prompt", || {
        s.screen(&pane)
            .lines()
            .any(|line| line.trim_end().ends_with('%'))
    });
    s.text(&pane, &format!("{PI_ROOT}\r"));
    rooted(&s, &pane);

    let run = s.ko_as(Some(&from), &["prompt"], "echo AAA\necho BBB");
    assert_eq!((code(&run), run.stderr.as_str()), (0, ""));
    poll("both lines to have run", || {
        s.screen(&pane).lines().any(|line| line.trim() == "BBB")
    });
    let screen = s.screen(&pane);
    let rows: Vec<&str> = screen.lines().map(str::trim).collect();
    let echo_bbb = rows
        .iter()
        .position(|row| row.contains("echo BBB"))
        .unwrap();
    let out_aaa = rows.iter().position(|row| *row == "AAA").unwrap();
    assert!(
        echo_bbb < out_aaa,
        "the two lines were one input, so both echoes show before either output: {screen}"
    );
}
