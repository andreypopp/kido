#![allow(clippy::print_stdout, clippy::print_stderr)]

use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, OpenOptions};
use std::io::{BufRead, Read, Write};
use std::os::fd::AsFd;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::{Duration, Instant};

use ko_pane_wire::base64;
use ko_sys::fd::Want;
use ko_sys::pid::{Exit, Waited};
use ko_sys::signal::{Signal, Signals};
use ko_sys::spawn::Env;
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
        let _ = file.write_all(format!("{line}\n").as_bytes());
    }
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

fn write_rows(path: &str, rows: &[Value]) {
    if !path.is_empty() {
        let temp = format!("{path}.tmp");
        if fs::write(&temp, Value::Array(rows.to_vec()).to_string()).is_ok() {
            let _ = fs::rename(temp, path);
        }
    }
}

fn panes_path() -> String {
    env("KO_FAKE_PANES")
}

fn with_table<T>(change: impl FnOnce(&mut Vec<Value>) -> T) -> T {
    let path = panes_path();
    let _lock = Locked::take(&path);
    let mut table = rows("KO_FAKE_PANES");
    let result = change(&mut table);
    write_rows(&path, &table);
    result
}

fn row_of<'a>(table: &'a [Value], pane: &str) -> Option<&'a Value> {
    table.iter().find(|row| text(row, "id") == pane)
}

fn listing(row: &Value) -> Value {
    let mut listed = row.clone();
    if let Some(fields) = listed.as_object_mut() {
        fields.remove("session");
        fields.remove("window");
        fields.entry("pid").or_insert(json!(1));
        fields.entry("command").or_insert(json!([]));
        fields.entry("cwd").or_insert(json!("/tmp"));
        fields.entry("title").or_insert(json!(""));
        fields.entry("dead").or_insert(Value::Null);
        fields.entry("vars").or_insert(json!({}));
        if let Some(status) = fields.remove("program_status") {
            fields.insert("status".to_owned(), json!({"program_status": status}));
        }
    }
    listed
}

type Windows = Vec<(String, Vec<String>)>;

fn layout(table: &[Value]) -> Value {
    let mut sessions: Vec<(String, Windows)> = Vec::new();
    for row in table {
        let (session, window, pane) = (text(row, "session"), text(row, "window"), text(row, "id"));
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
    json!({
        "revision": 1,
        "layout": {"sessions": sessions},
        "panes": table.iter().map(listing).collect::<Vec<_>>(),
    })
}

fn http_error(status: u16, kind: &str, message: &str) -> ExitCode {
    println!("{}", json!({"kind": kind, "message": message}));
    eprintln!("ko api: HTTP {status}");
    ExitCode::FAILURE
}

fn new_pane(body: &str) -> ExitCode {
    let request: Value = serde_json::from_str(body).unwrap_or(Value::Null);
    let refusal = env("KO_FAKE_SPAWN_FAIL");
    if !refusal.is_empty() {
        return http_error(409, "refused", &refusal);
    }
    let caller = env("KO_PANE");
    let placed = with_table(|table| {
        let next = table
            .iter()
            .filter_map(|row| text(row, "id").strip_prefix("pane_")?.parse::<u64>().ok())
            .max()
            .unwrap_or(1)
            .max(9)
            + 1;
        let session_of = |pane: &str| row_of(table, pane).map(|row| text(row, "session"));
        let session = request["session"]
            .as_str()
            .map(str::to_owned)
            .or_else(|| request["parent"].as_str().and_then(session_of))
            .or_else(|| session_of(&caller))
            .unwrap_or_else(|| "session_1".to_owned());
        let (pane, window) = (format!("pane_{next}"), format!("window_{next}"));
        let mut row = json!({
            "id": pane,
            "session": session,
            "window": window,
            "cwd": request["cwd"],
            "command": request["command"]["argv"],
            "vars": request["vars"],
            "close": request["close"],
            "parent": request["parent"],
        });
        if let Some(fields) = row.as_object_mut() {
            fields.retain(|_, value| !value.is_null());
        }
        table.push(row);
        json!({"session": session, "window": window, "pane": pane})
    });
    println!("{placed}");
    ExitCode::SUCCESS
}

fn stop_pane(pane: &str) -> ExitCode {
    let found = with_table(|table| {
        let before = table.len();
        table.retain(|row| text(row, "id") != pane);
        table.len() != before
    });
    if found {
        println!("{{}}");
        ExitCode::SUCCESS
    } else {
        http_error(404, "not_found", &format!("no pane {pane}"))
    }
}

fn sent_path() -> String {
    env("KO_FAKE_SENT")
}

// The server's side of a post: the body must be a SendMessage for a live pane, an id that the pane has
// seen answers from its first state with duplicate set, and a scripted reply stands for a lost or late
// answer: an error reply still leaves the message delivered, an acked reply is the receiver's ack.
fn send_message(pane: &str, body: &str) -> ExitCode {
    let request: Value = serde_json::from_str(body).unwrap_or(Value::Null);
    let id = text(&request, "id");
    let valid = (8..=64).contains(&id.len())
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        && ["message", "steer", "interrupt", "stop", "notice"]
            .contains(&text(&request, "kind").as_str())
        && request["text"].is_string();
    if !valid {
        return http_error(400, "invalid", "not a SendMessage");
    }
    let table = rows("KO_FAKE_PANES");
    let Some(row) = row_of(&table, pane) else {
        return http_error(404, "not_found", &format!("no pane {pane}"));
    };
    if !row["dead"].is_null() {
        return http_error(410, "gone", &format!("{pane} is dead"));
    }
    wait_gate("KO_FAKE_SEND_GATE");
    let script = env("KO_FAKE_SEND_SCRIPT");
    let scripted = if script.is_empty() {
        None
    } else {
        let _lock = Locked::take(&script);
        let mut queued = rows("KO_FAKE_SEND_SCRIPT");
        let next = (!queued.is_empty()).then(|| queued.remove(0));
        write_rows(&script, &queued);
        next
    };
    let _lock = Locked::take(&sent_path());
    let mut sent = rows("KO_FAKE_SENT");
    let at = sent
        .iter()
        .position(|one| text(one, "pane") == pane && text(one, "id") == id);
    let scripted_state = scripted
        .as_ref()
        .filter(|reply| reply["status"].as_u64().unwrap_or(200) == 200)
        .and_then(|reply| reply["body"]["state"].as_str().map(str::to_owned));
    let fallback = if row["inbox"] == true {
        "acked"
    } else {
        "queued"
    };
    let failure = scripted
        .as_ref()
        .filter(|reply| reply["status"].as_u64().unwrap_or(200) != 200);
    let duplicate = at.is_some();
    let message = match at {
        Some(at) => {
            if let Some(state) = scripted_state.as_deref().filter(|state| *state == "acked") {
                sent[at]["state"] = json!(state);
            }
            sent[at].clone()
        }
        None => {
            let seq = sent.iter().filter(|one| text(one, "pane") == pane).count() + 1;
            let state = if failure.is_some() {
                "delivered"
            } else {
                scripted_state.as_deref().unwrap_or(fallback)
            };
            let one = json!({"pane": pane, "id": id, "state": state, "seq": seq});
            sent.push(one.clone());
            one
        }
    };
    write_rows(&sent_path(), &sent);
    if let Some(reply) = failure {
        println!("{}", reply["body"]);
        eprintln!("ko api: HTTP {}", reply["status"]);
        return ExitCode::FAILURE;
    }
    let mut answer = json!({"state": message["state"], "seq": message["seq"]});
    if duplicate {
        answer["duplicate"] = json!(true);
    }
    println!("{answer}");
    ExitCode::SUCCESS
}

fn screen(path: &str) -> ExitCode {
    let name = match path
        .split('?')
        .next()
        .unwrap_or_default()
        .split('/')
        .collect::<Vec<_>>()[..]
    {
        ["", "panes", pane, "screen"] => pane.to_owned(),
        _ => return ExitCode::FAILURE,
    };
    match fs::read_to_string(Path::new(&env("KO_FAKE_SCREENS")).join(name)) {
        Ok(screen) => {
            print!("{screen}");
            ExitCode::SUCCESS
        }
        Err(_) => http_error(404, "not_found", "no screen"),
    }
}

fn set_var(pane: &str, name: &str, value: Option<Value>) {
    with_table(|table| {
        let Some(vars) = table
            .iter_mut()
            .find(|row| text(row, "id") == pane)
            .and_then(|row| row.get_mut("vars"))
            .and_then(Value::as_object_mut)
        else {
            return;
        };
        match value {
            Some(value) => vars.insert(name.to_owned(), value),
            None => vars.remove(name),
        };
    });
}

fn put_var(pane: &str, name: &str, body: &str) -> ExitCode {
    set_var(pane, name, serde_json::from_str(body).ok());
    println!("{{}}");
    ExitCode::SUCCESS
}

fn delete_vars(pane: &str, body: &str) -> ExitCode {
    let request: Value = serde_json::from_str(body).unwrap_or(Value::Null);
    let table = rows("KO_FAKE_PANES");
    let held = |name: &str| row_of(&table, pane).map(|row| row["vars"][name].clone());
    let condition = &request["if"];
    if let Some(name) = condition["name"].as_str()
        && held(name).as_ref() != Some(&condition["value"])
    {
        return http_error(
            412,
            "precondition_failed",
            "variable does not have the expected value",
        );
    }
    for name in request["names"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
    {
        set_var(pane, name, None);
    }
    println!("{{}}");
    ExitCode::SUCCESS
}

fn set_inbox(pane: &str, open: bool) {
    with_table(|table| {
        if let Some(row) = table.iter_mut().find(|row| text(row, "id") == pane) {
            row["inbox"] = json!(open);
        }
    });
}

fn emit(line: &str) {
    println!("{line}");
    let _ = std::io::stdout().flush();
}

fn answered(id: &str) -> bool {
    let acks = fs::read_to_string(env("KO_FAKE_ACKS")).unwrap_or_default();
    acks.lines()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .any(|ack| ack["id"] == id)
}

fn stream_messages(pane: &str) -> ExitCode {
    set_inbox(pane, true);
    std::thread::spawn(|| {
        for line in std::io::stdin().lock().lines().map_while(Result::ok) {
            append("KO_FAKE_ACKS", &line);
        }
    });
    let mut printed = BTreeSet::new();
    loop {
        let drop = env("KO_FAKE_STREAM_DROP");
        if !drop.is_empty() && Path::new(&drop).exists() {
            let _ = fs::remove_file(drop);
            set_inbox(pane, false);
            eprintln!("ko api: closed: 1011 dropped");
            return ExitCode::FAILURE;
        }
        let queue = fs::read_to_string(env("KO_FAKE_FEED")).unwrap_or_default();
        for line in queue.lines() {
            let Ok(message) = serde_json::from_str::<Value>(line) else {
                continue;
            };
            let id = text(&message, "id");
            if !printed.contains(&id) && !answered(&id) {
                emit(line);
                printed.insert(id);
            }
        }
        std::thread::sleep(POLL);
    }
}

fn runtime_entry(name: &str) -> Option<Value> {
    let raw = fs::read_to_string(env("KO_FAKE_RUNTIMES")).ok()?;
    let mut all: Value = serde_json::from_str(&raw).ok()?;
    all.as_object_mut()?.remove(name)
}

fn runtime_info(name: &str, entry: &Value) -> Value {
    let mut info = entry.clone();
    if let Some(fields) = info.as_object_mut() {
        fields.remove("env");
        fields.insert("name".to_owned(), json!(name));
        fields.entry("kind").or_insert(json!("command"));
        fields.entry("state").or_insert(json!({"type": "up"}));
        fields.entry("panes").or_insert(json!(0));
        fields.entry("socket").or_insert(json!(""));
        fields.entry("paths").or_insert(json!([]));
        fields.entry("pi").or_insert(json!("host"));
    }
    info
}

fn get_runtimes(name: Option<&str>) -> ExitCode {
    let raw = fs::read_to_string(env("KO_FAKE_RUNTIMES")).unwrap_or_default();
    let all: BTreeMap<String, Value> = serde_json::from_str(&raw).unwrap_or_default();
    match name {
        None => println!(
            "{}",
            Value::Array(
                all.iter()
                    .map(|(name, entry)| runtime_info(name, entry))
                    .collect()
            )
        ),
        Some(name) => match all.get(name) {
            Some(entry) => println!("{}", runtime_info(name, entry)),
            None => return http_error(404, "not_found", &format!("no runtime {name} in the fake")),
        },
    }
    ExitCode::SUCCESS
}

fn exec_failed(message: &str) -> ExitCode {
    emit(&json!({"type": "error", "message": message}).to_string());
    eprintln!("ko api: closed: 1011 {message}");
    ExitCode::FAILURE
}

fn signal_name(number: i32) -> &'static str {
    match number {
        1 => "HUP",
        2 => "INT",
        3 => "QUIT",
        6 => "ABRT",
        9 => "KILL",
        11 => "SEGV",
        13 => "PIPE",
        15 => "TERM",
        _ => "OTHER",
    }
}

fn pump_output(
    mut source: impl Read + Send + 'static,
    kind: &'static str,
) -> std::thread::JoinHandle<()> {
    std::thread::spawn(move || {
        let mut chunk = vec![0u8; 64 << 10];
        while let Ok(count) = source.read(&mut chunk) {
            if count == 0 {
                break;
            }
            emit(&json!({"type": kind, "data": base64::encode(&chunk[..count])}).to_string());
        }
    })
}

fn find_program(program: &str, path: &str) -> Option<PathBuf> {
    if program.contains('/') {
        return Some(PathBuf::from(program));
    }
    path.split(':')
        .map(|dir| Path::new(dir).join(program))
        .find(|candidate| candidate.is_file())
}

fn exec_session(name: &str) -> ExitCode {
    let (lines, messages) = std::sync::mpsc::channel::<String>();
    std::thread::spawn(move || {
        for line in std::io::stdin().lock().lines().map_while(Result::ok) {
            if lines.send(line).is_err() {
                break;
            }
        }
    });
    let request: Value = messages
        .recv()
        .ok()
        .and_then(|line| serde_json::from_str(&line).ok())
        .unwrap_or(Value::Null);
    append(
        "KO_FAKE_EXEC_LOG",
        &json!({"runtime": name, "request": request}).to_string(),
    );
    wait_gate("KO_FAKE_EXEC_GATE");
    let Some(entry) = runtime_entry(name) else {
        return exec_failed(&format!("no runtime {name} in the fake"));
    };
    if entry["state"]["type"] == "failed" {
        return exec_failed(entry["state"]["message"].as_str().unwrap_or("failed"));
    }
    let argv: Vec<String> = request["argv"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|word| word.as_str().map(str::to_owned))
        .collect();
    let Some((program, args)) = argv.split_first() else {
        return exec_failed("argv needs a program");
    };
    let mut variables = BTreeMap::from([
        ("PATH".to_owned(), "/usr/bin:/bin".to_owned()),
        ("HOME".to_owned(), "/var/empty".to_owned()),
    ]);
    for source in [&entry["env"], &request["env"]] {
        for (key, value) in source.as_object().into_iter().flatten() {
            variables.insert(key.clone(), value.as_str().unwrap_or_default().to_owned());
        }
    }
    variables.insert("KO_RUNTIME".to_owned(), name.to_owned());
    let Some(found) = find_program(program, &variables["PATH"]) else {
        return exec_failed(&format!("{program}: No such file or directory"));
    };
    let environment: Vec<Vec<u8>> = variables
        .iter()
        .map(|(key, value)| format!("{key}={value}").into_bytes())
        .collect();
    let words: Vec<&str> = args.iter().map(String::as_str).collect();
    let dir = request["cwd"].as_str().or(entry["cwd"].as_str());
    let (Ok((out_read, out_write)), Ok((err_read, err_write)), Ok((in_read, in_write))) =
        (std::io::pipe(), std::io::pipe(), std::io::pipe())
    else {
        return exec_failed("pipe failed");
    };
    let null = std::fs::File::open("/dev/null");
    let Ok(null) = null else {
        return exec_failed("/dev/null");
    };
    let stdin = if request["stdin"] == true {
        in_read.as_fd()
    } else {
        null.as_fd()
    };
    let started = ko_sys::spawn::program(
        &found,
        &words,
        &[(stdin, 0), (out_write.as_fd(), 1), (err_write.as_fd(), 2)],
        Env::Only(&environment),
        dir.map(Path::new),
    );
    let pid = match started {
        Ok(pid) => pid,
        Err(error) => return exec_failed(&format!("{program}: {error}")),
    };
    drop((out_write, err_write, in_read));
    if let Ok(signals) = Signals::install(&[Signal::Term]) {
        std::thread::spawn(move || {
            let _ = ko_sys::fd::wait(signals.fd(), Want::Read, None, None);
            let _ = pid.signal(Signal::Kill);
            std::process::exit(143);
        });
    }
    let mut input = Some(in_write);
    std::thread::spawn(move || {
        for line in messages {
            let message: Value = serde_json::from_str(&line).unwrap_or(Value::Null);
            match message["type"].as_str() {
                Some("stdin") => {
                    let Some(bytes) = base64::decode(&text(&message, "data")) else {
                        exec_failed("stdin data is not base64");
                        std::process::exit(1);
                    };
                    if let Some(pipe) = input.as_mut() {
                        let _ = pipe.write_all(&bytes);
                    }
                }
                Some("eof") => input = None,
                _ => {}
            }
        }
    });
    let pumps = [
        pump_output(out_read, "stdout"),
        pump_output(err_read, "stderr"),
    ];
    let ended = pid.wait();
    for pump in pumps {
        let _ = pump.join();
    }
    emit(
        &match ended {
            Ok(Waited::Ended(Exit::Exited(code))) => json!({"type": "exit", "status": code}),
            Ok(Waited::Ended(Exit::Signaled(signal))) => {
                json!({"type": "exit", "signal": signal_name(signal)})
            }
            _ => json!({"type": "exit", "status": 255}),
        }
        .to_string(),
    );
    ExitCode::SUCCESS
}

fn api(argv: &[String]) -> ExitCode {
    let mut method = "GET".to_owned();
    let (mut input, mut path, mut stream) = (false, String::new(), false);
    let mut rest = argv.iter().skip(1);
    while let Some(arg) = rest.next() {
        match arg.as_str() {
            "-X" | "--method" => method = rest.next().cloned().unwrap_or_default(),
            "--input" => {
                input = true;
                rest.next();
            }
            "--stream" => stream = true,
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
    if stream {
        method = "STREAM".to_owned();
    }
    append(
        "KO_FAKE_API_LOG",
        &json!({"method": method, "path": path, "body": body}).to_string(),
    );
    let route = path
        .split_once('?')
        .map_or(path.as_str(), |(route, _)| route);
    let segments: Vec<&str> = route.split('/').collect();
    match (method.as_str(), segments.as_slice()) {
        ("STREAM", ["", "panes", pane, "messages"]) => return stream_messages(pane),
        ("STREAM", ["", "runtimes", name, "exec"]) => return exec_session(name),
        ("GET", ["", "runtimes"]) => return get_runtimes(None),
        ("GET", ["", "runtimes", name]) => return get_runtimes(Some(name)),
        ("GET", ["", "layout"]) => {
            wait_gate("KO_FAKE_LAYOUT_GATE");
            if env("KO_FAKE_LAYOUT_FAIL") == "1" {
                return ExitCode::FAILURE;
            }
            println!("{}", layout(&rows("KO_FAKE_PANES")));
        }
        ("GET", ["", "version"]) => {
            let instance = Some(env("KO_FAKE_INSTANCE")).filter(|text| !text.is_empty());
            let instance = instance.unwrap_or_else(|| "0".repeat(32));
            println!(
                "{}",
                json!({"build": "fake", "instance": instance, "protocol": "1", "vt": "fake"})
            );
        }
        ("POST", ["", "panes"]) => return new_pane(&body),
        ("POST", ["", "panes", pane, "stop"]) => return stop_pane(pane),
        ("POST", ["", "panes", pane, "messages"]) => return send_message(pane, &body),
        ("GET", ["", "panes", _, "screen"]) => return screen(&path),
        ("PUT", ["", "panes", pane, "vars", name]) => return put_var(pane, name, &body),
        ("DELETE", ["", "panes", pane, "vars", name]) => {
            set_var(pane, name, None);
            println!("{{}}");
        }
        ("DELETE", ["", "panes", pane, "vars"]) => return delete_vars(pane, &body),
        _ => return ExitCode::FAILURE,
    }
    ExitCode::SUCCESS
}

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    append("KO_FAKE_LOG", &json!(argv).to_string());
    match argv.first().map(String::as_str) {
        Some("api") => api(&argv),
        _ => ExitCode::FAILURE,
    }
}
