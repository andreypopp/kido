use std::collections::BTreeMap;
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::path::Path;
use std::process::{Command, ExitCode, Stdio};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

const GATE_DEADLINE: Duration = Duration::from_secs(10);
const POLL: Duration = Duration::from_millis(5);

fn env(name: &str) -> String {
    std::env::var(name).unwrap_or_default()
}

fn wait_gate(name: &str) {
    let gate = env(name);
    if gate.is_empty() {
        return;
    }
    let deadline = Instant::now() + GATE_DEADLINE;
    while !Path::new(&gate).exists() && Instant::now() < deadline {
        std::thread::sleep(POLL);
    }
}

fn append(name: &str, line: &str) {
    let path = env(name);
    if path.is_empty() {
        return;
    }
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(file, "{line}");
    }
}

fn log(name: &str, argv: &[String]) {
    append(name, &json!(argv).to_string());
}

fn text(row: &Value, key: &str) -> String {
    row[key].as_str().unwrap_or_default().to_owned()
}

fn rows(name: &str) -> Vec<Value> {
    let path = env(name);
    match fs::read_to_string(path)
        .ok()
        .and_then(|raw| serde_json::from_str(&raw).ok())
    {
        Some(Value::Array(rows)) => rows,
        _ => Vec::new(),
    }
}

fn after<'a>(argv: &'a [String], flag: &str) -> Option<&'a str> {
    argv.windows(2)
        .find(|pair| pair[0] == flag)
        .map(|pair| pair[1].as_str())
}

#[derive(Debug)]
struct Locked(String);

impl Locked {
    fn take(path: &str) -> Locked {
        let lock = format!("{path}.lock");
        let deadline = Instant::now() + GATE_DEADLINE;
        while OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&lock)
            .is_err()
            && Instant::now() < deadline
        {
            std::thread::sleep(POLL);
        }
        Locked(lock)
    }
}

impl Drop for Locked {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

fn runs_path() -> String {
    env("KO_FAKE_RUNS_FILE")
}

fn write_rows(rows: &[Value]) {
    let path = runs_path();
    if !path.is_empty() {
        let temp = format!("{path}.tmp");
        if fs::write(&temp, Value::Array(rows.to_vec()).to_string()).is_ok() {
            let _ = fs::rename(temp, path);
        }
    }
}

fn find_row(id: &str) -> Option<Value> {
    rows("KO_FAKE_RUNS_FILE")
        .into_iter()
        .find(|row| text(row, "id") == id)
}

fn with_outcome(mut row: Value, result: &str, outcome_text: &str) -> Value {
    row["outcome"] = json!({"result": result, "text": outcome_text});
    row
}

fn with_row(id: &str, change: impl Fn(Value) -> Value) {
    let path = runs_path();
    if path.is_empty() {
        return;
    }
    let _lock = Locked::take(&path);
    let changed: Vec<Value> = rows("KO_FAKE_RUNS_FILE")
        .into_iter()
        .map(|row| {
            if text(&row, "id") == id {
                change(row)
            } else {
                row
            }
        })
        .collect();
    write_rows(&changed);
}

fn positional(argv: &[String]) -> String {
    argv.get(1).cloned().unwrap_or_default()
}

fn exec(output: &str, command: &[String]) -> (&'static str, String) {
    let Some((program, args)) = command.split_first() else {
        return ("failed", "no command".to_owned());
    };
    let Ok(file) = fs::File::create(output) else {
        return ("failed", "no output".to_owned());
    };
    let Ok(copy) = file.try_clone() else {
        return ("failed", "no output".to_owned());
    };
    let status = Command::new(program)
        .args(args)
        .env("KO_RUN_OUTPUT", output)
        .stdin(Stdio::null())
        .stdout(file)
        .stderr(copy)
        .status();
    match status.map(|status| status.code()) {
        Ok(Some(0)) => ("completed", String::new()),
        Ok(Some(code)) => ("failed", format!("exit {code}")),
        _ => ("failed", "signal".to_owned()),
    }
}

fn run(argv: &[String]) -> ExitCode {
    log("KO_FAKE_RUN_LOG", argv);
    let run_id = std::env::var("KO_FAKE_RUN_ID").unwrap_or_else(|_| "fake-run-id".to_owned());
    wait_gate("KO_FAKE_RUN_GATE");
    let output = format!("{}/runs/{run_id}/output", env("KO_FAKE_STATE_DIR"));
    if let Some(parent) = Path::new(&output).parent() {
        let _ = fs::create_dir_all(parent);
    }
    let parent = if argv[0] == "run" {
        String::new()
    } else {
        positional(argv)
    };
    let command: Vec<String> = match argv.iter().position(|arg| arg == "--") {
        Some(at) => argv[at + 1..].to_vec(),
        None => Vec::new(),
    };
    let ending =
        (env("KO_FAKE_RUN_EXEC") == "1" && !command.is_empty()).then(|| exec(&output, &command));
    if !runs_path().is_empty() {
        let _lock = Locked::take(&runs_path());
        let mut all = rows("KO_FAKE_RUNS_FILE");
        let row = json!({
            "id": run_id,
            "name": after(argv, "--name").unwrap_or_default(),
            "parent": parent,
            "pane": "pane_9",
            "output": output,
            "startedAt": "2023-11-14T22:00:00Z",
        });
        all.push(match ending {
            Some((result, outcome_text)) => with_outcome(row, result, &outcome_text),
            None => row,
        });
        write_rows(&all);
    }
    println!(
        "{}",
        json!({"id": run_id, "window": "window_9", "pane": "pane_9", "output": output})
    );
    ExitCode::SUCCESS
}

fn runs(argv: &[String]) -> ExitCode {
    log("KO_FAKE_RUNS_LOG", argv);
    let once = env("KO_FAKE_RUNS_FAIL_ONCE");
    if !once.is_empty() && !Path::new(&once).exists() {
        let _ = fs::write(&once, "");
        return ExitCode::FAILURE;
    }
    wait_gate("KO_FAKE_RUNS_GATE");
    let (mut parent, mut id, mut all) = (None, None, false);
    let mut rest = argv.iter().skip(1);
    while let Some(arg) = rest.next() {
        match arg.as_str() {
            "--parent" => parent = rest.next().cloned(),
            "--json" => {}
            "--all" => all = true,
            other => {
                id.get_or_insert_with(|| other.to_owned());
            }
        }
    }
    if let Some(id) = id {
        return match find_row(&id) {
            Some(row) => {
                println!("{row}");
                ExitCode::SUCCESS
            }
            None => {
                eprintln!("run {id}: no such run");
                ExitCode::from(3)
            }
        };
    }
    let listed: Vec<Value> = rows("KO_FAKE_RUNS_FILE")
        .into_iter()
        .filter(|row| {
            parent
                .as_ref()
                .is_none_or(|parent| text(row, "parent") == *parent)
        })
        .filter(|row| all || row.get("outcome").is_none())
        .collect();
    println!("{}", Value::Array(listed));
    ExitCode::SUCCESS
}

fn run_wait(argv: &[String]) -> ExitCode {
    log("KO_FAKE_RUN_WAIT_LOG", argv);
    wait_gate("KO_FAKE_RUN_WAIT_GATE");
    let id = positional(argv);
    let stored = rows("KO_FAKE_RUNS_FILE")
        .into_iter()
        .find(|row| text(row, "id") == id)
        .and_then(|row| row.get("outcome").cloned());
    let answer = match std::env::var("KO_FAKE_RUN_WAIT_OUTCOME") {
        Ok(raw) => raw,
        Err(_) => stored.map_or_else(
            || "{\"result\":\"completed\"}".to_owned(),
            |json| json.to_string(),
        ),
    };
    println!("{answer}");
    let _ = std::io::stdout().flush();
    let ready = env("KO_FAKE_RUN_WAIT_READY");
    if !ready.is_empty() {
        let _ = fs::write(ready, "");
    }
    wait_gate("KO_FAKE_RUN_WAIT_EXIT_GATE");
    ExitCode::SUCCESS
}

fn run_stop(argv: &[String]) -> ExitCode {
    log("KO_FAKE_RUN_STOP_LOG", argv);
    wait_gate("KO_FAKE_RUN_STOP_GATE");
    let result = if after(argv, "--result") == Some("completed") {
        "completed"
    } else {
        "stopped"
    };
    let id = positional(argv);
    match find_row(&id) {
        None => {
            eprintln!("run {id}: no such run");
            ExitCode::from(3)
        }
        Some(row) => {
            if row.get("outcome").is_none() {
                with_row(&id, |row| with_outcome(row, result, ""));
            }
            println!("stopped run {id}; killed its pane");
            ExitCode::SUCCESS
        }
    }
}

fn run_outcome(argv: &[String]) -> ExitCode {
    log("KO_FAKE_RUN_OUTCOME_LOG", argv);
    let requested = after(argv, "--result").unwrap_or_default();
    if !["stopped", "completed", "failed"].contains(&requested) {
        eprintln!("run-outcome: result must be stopped, completed or failed");
        return ExitCode::FAILURE;
    }
    let outcome_text = after(argv, "--text").unwrap_or_default().to_owned();
    let mut id = String::new();
    let mut rest = argv.iter().skip(1);
    while let Some(arg) = rest.next() {
        match arg.as_str() {
            "--" => {
                id = rest.next().cloned().unwrap_or_default();
                break;
            }
            "--result" | "--text" => {
                rest.next();
            }
            other if !other.starts_with('-') => {
                id = other.to_owned();
                break;
            }
            _ => {}
        }
    }
    match find_row(&id) {
        None => {
            eprintln!("run {id}: no such run");
            ExitCode::from(3)
        }
        Some(row) if row.get("outcome").is_some() => {
            eprintln!("run {id} already has an outcome, or is gone");
            ExitCode::from(5)
        }
        Some(_) => {
            with_row(&id, |row| with_outcome(row, requested, &outcome_text));
            ExitCode::SUCCESS
        }
    }
}

fn pane_vars(row: &Value) -> BTreeMap<&'static str, String> {
    [
        ("pi.session", "pi_session"),
        ("pi.name", "pi_name"),
        ("pi.inbox", "pi_inbox"),
        ("pi.activity", "pi_activity"),
    ]
    .into_iter()
    .map(|(name, key)| (name, text(row, key)))
    .filter(|(_, value)| !value.is_empty())
    .collect()
}

fn listing(row: &Value) -> Value {
    let dead = (text(row, "pane_dead") == "1")
        .then(|| json!({"at": 0, "cause": {"type": "exited", "code": 0}}));
    let status: Value =
        serde_json::from_str(&text(row, "pane_program_status")).unwrap_or(Value::Null);
    json!({
        "id": text(row, "pane_id"),
        "pid": 1,
        "command": [],
        "cwd": text(row, "pane_current_path"),
        "title": text(row, "pane_title"),
        "dead": dead,
        "status": {"program_status": status},
        "vars": pane_vars(row),
    })
}

type Windows = Vec<(String, Vec<String>)>;

fn layout(table: &[Value]) -> Value {
    let mut sessions: Vec<(String, Windows)> = Vec::new();
    for row in table {
        let (session, window, pane) = (
            text(row, "session"),
            text(row, "window"),
            text(row, "pane_id"),
        );
        let at = match sessions.iter().position(|(id, _)| *id == session) {
            Some(at) => at,
            None => {
                sessions.push((session, Vec::new()));
                sessions.len() - 1
            }
        };
        let windows = &mut sessions[at].1;
        match windows.iter_mut().find(|(id, _)| *id == window) {
            Some((_, panes)) => panes.push(pane),
            None => windows.push((window, vec![pane])),
        }
    }
    let leaf = |pane: &String| json!({"pane": pane, "cols": 80, "rows": 24});
    let sessions: Vec<Value> = sessions
        .iter()
        .map(|(id, windows)| {
            let windows: Vec<Value> = windows
                .iter()
                .map(|(window, panes)| {
                    let tree = match panes.as_slice() {
                        [only] => leaf(only),
                        many => json!({"split": "h", "children": many.iter().map(leaf).collect::<Vec<_>>()}),
                    };
                    json!({"id": window, "name": window, "vars": {}, "cols": 80, "rows": 24, "tree": tree, "floats": []})
                })
                .collect();
            json!({"id": id, "name": id, "vars": {}, "windows": windows})
        })
        .collect();
    json!({"revision": 1, "layout": {"sessions": sessions}})
}

fn api(argv: &[String]) -> ExitCode {
    let mut method = "GET".to_owned();
    let (mut input, mut path) = (false, String::new());
    let mut rest = argv.iter().skip(1);
    while let Some(arg) = rest.next() {
        match arg.as_str() {
            "-X" | "--method" => method = rest.next().cloned().unwrap_or_default(),
            "--input" => {
                input = true;
                rest.next();
            }
            "--server" => {
                rest.next();
            }
            other if other.starts_with('/') => path = other.to_owned(),
            _ => {}
        }
    }
    let mut body = String::new();
    if input {
        let _ = std::io::stdin().read_to_string(&mut body);
    }
    append(
        "KO_FAKE_API_LOG",
        &json!({"method": method, "path": path, "body": body}).to_string(),
    );
    let reading = method == "GET" && (path == "/panes" || path == "/layout");
    if reading && env("KO_FAKE_PANES_FAIL") == "1" {
        return ExitCode::FAILURE;
    }
    let table = rows("KO_FAKE_PANES");
    let segments: Vec<&str> = path.split('/').collect();
    match (method.as_str(), segments.as_slice()) {
        ("GET", ["", "panes"]) => {
            wait_gate("KO_FAKE_PANES_GATE");
            println!("{}", Value::Array(table.iter().map(listing).collect()));
        }
        ("GET", ["", "layout"]) => println!("{}", layout(&table)),
        ("GET", ["", "panes", pane, "vars", name]) => {
            let value = table
                .iter()
                .find(|row| text(row, "pane_id") == *pane)
                .and_then(|row| pane_vars(row).get(name).cloned());
            match value {
                Some(value) => println!("{}", json!(value)),
                None => {
                    println!(
                        "{}",
                        json!({"kind": "not_found", "message": "variable not found"})
                    );
                    eprintln!("ko api: HTTP 404");
                    return ExitCode::FAILURE;
                }
            }
        }
        ("PUT" | "DELETE", ["", "panes", _, "vars", _]) => println!("{{}}"),
        _ => return ExitCode::FAILURE,
    }
    ExitCode::SUCCESS
}

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    append("KO_FAKE_LOG", &json!(argv).to_string());
    match argv.first().map(String::as_str) {
        Some("run" | "run-child") => run(&argv),
        Some("runs") => runs(&argv),
        Some("run-wait") => run_wait(&argv),
        Some("run-stop") => run_stop(&argv),
        Some("run-outcome") => run_outcome(&argv),
        Some("api") => api(&argv),
        _ => ExitCode::FAILURE,
    }
}
