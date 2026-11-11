#![allow(clippy::print_stdout, clippy::print_stderr)]

use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, OpenOptions};
use std::io::{BufRead, Read, Write};
use std::os::fd::AsFd;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::{Duration, Instant};

use ko_config::runtime::RuntimePi;
use ko_pane_wire::frame;
use ko_sys::fd::Want;
use ko_sys::pid::Waited;
use ko_sys::signal::{Signal, Signals};
use ko_sys::spawn::Env;
use ko_wire::protocol::{self, *};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
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

fn fixture<T: Serialize + DeserializeOwned>(value: &Value) -> T {
    protocol::decode(value.to_string().as_bytes()).unwrap_or_else(|error| {
        eprintln!("fake ko: invalid fixture {value}: {error}");
        std::process::exit(1);
    })
}

fn emit_message(message: &impl Serialize) {
    emit(&protocol::json(message));
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

fn listing(row: &Value) -> Listing {
    let gate = env("KO_FAKE_PEER_IDENTITY_GATE");
    let identity = !gate.is_empty() && Path::new(&gate).exists() && row["fake_session"].is_string();
    let mut vars = row.get("vars").cloned().unwrap_or(json!({}));
    let kind = if identity {
        vars["pi.session"] = row["fake_session"].clone();
        Some(Live::Host {
            pane: Local::PiAgent {
                session: text(row, "fake_session"),
                status: Agent {
                    since: 0,
                    msg: None,
                    state: AgentState::Idle { outcome: None },
                },
            },
        })
    } else {
        row.get("status")
            .and_then(|status| status.get("kind"))
            .map(fixture)
    };
    let status = kind.map(|kind| PaneStatus {
        kind,
        program_status: row
            .get("program_status")
            .or_else(|| row["status"].get("program_status"))
            .map(fixture)
            .unwrap_or_default(),
        title: text(&row["status"], "title"),
        message: row["status"].get("message").map(fixture).unwrap_or(None),
        progress: row["status"].get("progress").map(fixture).unwrap_or(None),
        since: row["status"]["since"].as_u64().unwrap_or(0),
    });
    Listing {
        row: Row {
            webview: row.get("webview").map(fixture).unwrap_or(None),
            id: fixture(&row["id"]),
            started: row["started"].as_u64().unwrap_or(0),
            pid: row.get("pid").map(fixture).unwrap_or(Some(1)),
            command: row.get("command").map(fixture).unwrap_or_default(),
            cwd: row
                .get("cwd")
                .map(fixture)
                .unwrap_or_else(|| "/tmp".to_owned()),
            title: text(row, "title"),
            dead: row.get("dead").map(fixture).unwrap_or(None),
            foreground: row.get("foreground").map(fixture).unwrap_or(None),
            status,
            progress: row.get("progress").map(fixture).unwrap_or(None),
            parent: row.get("parent").map(fixture).unwrap_or(None),
            close: row.get("close").map(fixture).unwrap_or_default(),
            inbox: row["inbox"] == true,
            runtime: row.get("runtime").map(fixture).unwrap_or(None),
        },
        vars: fixture(&vars),
    }
}

type Windows = Vec<(String, Vec<String>)>;

fn layout(table: &[Value]) -> LayoutPanes {
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
    let leaf = |pane: &String| {
        Node::Leaf(Leaf {
            pane: fixture(&json!(pane)),
            cols: fixture(&json!(80)),
            rows: fixture(&json!(24)),
        })
    };
    let sessions = sessions
        .iter()
        .map(|(id, windows)| Session {
            id: fixture(&json!(id)),
            name: fixture(&json!(id)),
            vars: fixture(&json!({})),
            windows: windows
                .iter()
                .map(|(window, panes)| Window {
                    id: fixture(&json!(window)),
                    name: fixture(&json!(window)),
                    vars: fixture(&json!({})),
                    cols: fixture(&json!(80)),
                    rows: fixture(&json!(24)),
                    cell_px: None,
                    zoom: None,
                    focus: fixture(&json!(panes[0])),
                    tree: match panes.as_slice() {
                        [only] => leaf(only),
                        many => Node::Split {
                            split: Axis::Horizontal,
                            children: many.iter().map(leaf).collect(),
                        },
                    },
                    floats: Vec::new(),
                })
                .collect(),
        })
        .collect();
    LayoutPanes {
        snapshot: Snapshot {
            revision: fixture(&json!(1)),
            layout: Layout { sessions },
        },
        panes: table.iter().map(listing).collect(),
    }
}

fn http_error(status: u16, kind: ErrorKind, message: &str) -> ExitCode {
    println!(
        "{}",
        protocol::json(&protocol::Error {
            kind,
            message: message.to_owned()
        })
    );
    eprintln!("ko api: HTTP {status}");
    ExitCode::FAILURE
}

fn new_pane(body: &str) -> ExitCode {
    let Ok(request) = protocol::decode::<NewWindow>(body.as_bytes()) else {
        return http_error(400, ErrorKind::Invalid, "not a NewWindow");
    };
    let refusal = env("KO_FAKE_SPAWN_FAIL");
    if !refusal.is_empty() {
        return http_error(409, ErrorKind::Refused, &refusal);
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
        let session = request
            .session
            .as_ref()
            .map(|session| match session {
                SessionRef::Id(id) => id.to_string(),
                SessionRef::Name(name) => name.as_str().to_owned(),
            })
            .or_else(|| {
                request
                    .pane
                    .parent
                    .and_then(|parent| session_of(&parent.to_string()))
            })
            .or_else(|| session_of(&caller))
            .unwrap_or_else(|| "session_1".to_owned());
        let (pane, window) = (format!("pane_{next}"), format!("window_{next}"));
        let mut row = json!({
            "id": pane,
            "session": session,
            "window": window,
            "cwd": request.pane.cwd,
            "command": match &request.pane.command { Some(Command::Argv { argv }) => Some(argv), _ => None },
            "vars": request.pane.vars,
            "close": request.pane.close,
            "parent": request.pane.parent,
        });
        if !env("KO_FAKE_PEER_IDENTITY_GATE").is_empty() {
            row["fake_session"] = request
                .pane
                .env
                .iter()
                .find(|var| var.name == "KO_AGENT_SESSION")
                .map(|var| json!(var.value))
                .unwrap_or(Value::Null);
        }
        if let Some(fields) = row.as_object_mut() {
            fields.retain(|_, value| !value.is_null());
        }
        table.push(row);
        Placement {
            session: fixture(&json!(session)),
            window: fixture(&json!(window)),
            pane: fixture(&json!(pane)),
        }
    });
    println!("{}", protocol::json(&placed));
    ExitCode::SUCCESS
}

fn stop_pane(pane: &str) -> ExitCode {
    let found = with_table(|table| {
        let before = table.len();
        table.retain(|row| text(row, "id") != pane);
        table.len() != before
    });
    if found {
        println!("{}", protocol::json(&Empty {}));
        ExitCode::SUCCESS
    } else {
        http_error(404, ErrorKind::Missing, &format!("no pane {pane}"))
    }
}

fn sent_path() -> String {
    env("KO_FAKE_SENT")
}

// The server's side of a post: the body must be a SendMessage for a live pane, an id that the pane has
// seen answers from its first state with duplicate set, and a scripted reply stands for a lost or late
// answer: an error reply still leaves the message delivered, an acked reply is the receiver's ack.
fn send_message(pane: &str, body: &str) -> ExitCode {
    let Ok(request) = protocol::decode::<SendMessage>(body.as_bytes()) else {
        return http_error(400, ErrorKind::Invalid, "not a SendMessage");
    };
    let id = String::from(request.id);
    let table = rows("KO_FAKE_PANES");
    let Some(row) = row_of(&table, pane) else {
        return http_error(404, ErrorKind::Missing, &format!("no pane {pane}"));
    };
    if !row["dead"].is_null() {
        return http_error(410, ErrorKind::Gone, &format!("{pane} is dead"));
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
        .map(|reply| fixture::<Posted>(&reply["body"]).state);
    let fallback = if row["inbox"] == true {
        MessageState::Acked
    } else {
        MessageState::Queued
    };
    let failure = scripted
        .as_ref()
        .filter(|reply| reply["status"].as_u64().unwrap_or(200) != 200);
    let duplicate = at.is_some();
    let message = match at {
        Some(at) => {
            if let Some(state) = scripted_state.filter(|state| *state == MessageState::Acked) {
                sent[at]["state"] = json!(state);
            }
            sent[at].clone()
        }
        None => {
            let seq = sent.iter().filter(|one| text(one, "pane") == pane).count() + 1;
            let state = if failure.is_some() {
                MessageState::Delivered
            } else {
                scripted_state.unwrap_or(fallback)
            };
            let one = json!({"pane": pane, "id": id, "state": state, "seq": seq});
            sent.push(one.clone());
            one
        }
    };
    write_rows(&sent_path(), &sent);
    if let Some(reply) = failure {
        let error: protocol::Error = fixture(&reply["body"]);
        println!("{}", protocol::json(&error));
        eprintln!("ko api: HTTP {}", reply["status"]);
        return ExitCode::FAILURE;
    }
    let answer = Posted {
        state: fixture(&message["state"]),
        seq: fixture(&message["seq"]),
        duplicate,
    };
    println!("{}", protocol::json(&answer));
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
        Err(_) => http_error(404, ErrorKind::Missing, "no screen"),
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
    let Ok(value) = protocol::decode::<Value>(body.as_bytes()) else {
        return http_error(400, ErrorKind::Invalid, "invalid variable value");
    };
    set_var(pane, name, Some(value));
    println!("{}", protocol::json(&Empty {}));
    ExitCode::SUCCESS
}

fn delete_vars(pane: &str, body: &str) -> ExitCode {
    let Ok(request) = protocol::decode::<DeleteVars>(body.as_bytes()) else {
        return http_error(400, ErrorKind::Invalid, "not a DeleteVars");
    };
    let table = rows("KO_FAKE_PANES");
    let held = |name: &str| row_of(&table, pane).map(|row| row["vars"][name].clone());
    if let Some(condition) = &request.condition
        && held(condition.name.as_str()).as_ref() != Some(&condition.value)
    {
        return http_error(
            412,
            ErrorKind::PreconditionFailed,
            "variable does not have the expected value",
        );
    }
    for name in request.names {
        set_var(pane, name.as_str(), None);
    }
    println!("{}", protocol::json(&Empty {}));
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
        .filter_map(|line| protocol::decode::<StreamRequest>(line.as_bytes()).ok())
        .any(|ack| match ack {
            StreamRequest::Ack { id: message } | StreamRequest::Refuse { id: message } => {
                String::from(message) == id
            }
        })
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawFeed {
    id: String,
    fake_raw: String,
}

fn dropped(name: &str) -> bool {
    let path = env(name);
    !path.is_empty() && fs::remove_file(path).is_ok()
}

fn stream_webview() -> ExitCode {
    if env("KO_PANE").is_empty() {
        return ExitCode::from(6);
    }
    let (ended, input) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut bytes = Vec::new();
        let _ = std::io::stdin().read_to_end(&mut bytes);
        let _ = ended.send(());
    });
    let mut printed = 0;
    loop {
        if input.try_recv().is_ok() {
            return ExitCode::SUCCESS;
        }
        if dropped("KO_FAKE_SERVE_DROP") {
            return ExitCode::FAILURE;
        }
        let feed = fs::read_to_string(env("KO_FAKE_SERVE")).unwrap_or_default();
        let lines: Vec<_> = feed.lines().collect();
        for line in lines.iter().skip(printed) {
            let message: webview::ServeOut = match protocol::decode(line.as_bytes()) {
                Ok(message) => message,
                Err(error) => return http_error(400, ErrorKind::Invalid, &error.to_string()),
            };
            emit_message(&message);
        }
        printed = lines.len();
        std::thread::sleep(POLL);
    }
}

fn stream_messages(pane: &str) -> ExitCode {
    set_inbox(pane, true);
    std::thread::spawn(|| {
        for line in std::io::stdin().lock().lines().map_while(Result::ok) {
            if let Ok(message) = protocol::decode::<StreamRequest>(line.as_bytes()) {
                append("KO_FAKE_ACKS", &protocol::json(&message));
            }
        }
    });
    let mut printed = BTreeSet::new();
    loop {
        if dropped("KO_FAKE_STREAM_DROP") {
            set_inbox(pane, false);
            eprintln!("ko api: closed: 1011 dropped");
            return ExitCode::FAILURE;
        }
        let queue = fs::read_to_string(env("KO_FAKE_FEED")).unwrap_or_default();
        for line in queue.lines() {
            let (id, output) = match serde_json::from_str::<RawFeed>(line) {
                Ok(raw) => (raw.id, raw.fake_raw),
                Err(_) => match protocol::decode::<Message>(line.as_bytes()) {
                    Ok(message) => (String::from(message.id.clone()), protocol::json(&message)),
                    Err(error) => {
                        eprintln!("fake ko: invalid message fixture: {error}");
                        return ExitCode::FAILURE;
                    }
                },
            };
            if !printed.contains(&id) && !answered(&id) {
                emit(&output);
                printed.insert(id);
            }
        }
        std::thread::sleep(POLL);
    }
}

fn stream_client() -> ExitCode {
    let mut hello = String::new();
    let _ = std::io::stdin().read_line(&mut hello);
    let Ok(ClientRequest::Hello(hello)) = protocol::decode(hello.as_bytes()) else {
        return http_error(400, ErrorKind::Invalid, "invalid observer hello");
    };
    if hello.focused
        || hello.sizing != Sizing::Disabled
        || hello.selection.pane.is_some()
        || hello.selection.window.is_some()
        || hello.selection.session.is_some()
    {
        return http_error(400, ErrorKind::Invalid, "invalid observer hello");
    }
    emit_message(&ClientEvent::Welcome(Welcome {
        client: fixture(&json!("client_1")),
        instance: fixture(&json!(env("KO_FAKE_INSTANCE"))),
        limits: Limits::of(
            frame::Limits {
                scrollback: frame::Scrollback::Disabled,
                apc_max_bytes: 0,
                kitty_images_max_bytes: 0,
                continuation_max_bytes: 0,
            },
            &[],
        ),
        now: 0,
        runtimes: Vec::new(),
        runtimes_error: None,
    }));
    let mut previous = String::new();
    let mut known = BTreeSet::new();
    let mut fed = 0;
    loop {
        let drop = env("KO_FAKE_CLIENT_DROP");
        if !drop.is_empty() && Path::new(&drop).exists() {
            let _ = fs::remove_file(drop);
            return ExitCode::FAILURE;
        }
        let table = if Path::new(&env("KO_FAKE_CLIENT_PANES")).exists() {
            rows("KO_FAKE_CLIENT_PANES")
        } else {
            rows("KO_FAKE_PANES")
        };
        let snapshot = layout(&table);
        let raw = protocol::json(&snapshot);
        if raw != previous {
            let mut event = snapshot;
            event
                .panes
                .retain(|listing| !known.contains(&listing.row.id.to_string()));
            let event = ClientEvent::Layout(event);
            known = table.iter().map(|row| text(row, "id")).collect();
            emit_message(&event);
            append("KO_FAKE_CLIENT_LAYOUTS", &protocol::json(&event));
            previous = raw;
        }
        let feed = fs::read_to_string(env("KO_FAKE_CLIENT_FEED")).unwrap_or_default();
        let lines: Vec<_> = feed.lines().collect();
        for line in lines.iter().skip(fed) {
            let event: ClientEvent = match protocol::decode(line.as_bytes()) {
                Ok(event) => event,
                Err(error) => return http_error(400, ErrorKind::Invalid, &error.to_string()),
            };
            emit_message(&event);
        }
        fed = lines.len();
        std::thread::sleep(POLL);
    }
}

fn runtime_entry(name: &str) -> Option<Value> {
    let raw = fs::read_to_string(env("KO_FAKE_RUNTIMES")).ok()?;
    let mut all: Value = serde_json::from_str(&raw).ok()?;
    all.as_object_mut()?.remove(name)
}

fn runtime_info(name: &str, entry: &Value) -> RuntimeInfo {
    RuntimeInfo {
        runtime: ClientRuntime {
            name: fixture(&json!(name)),
            source: entry
                .get("source")
                .map(fixture)
                .unwrap_or(RuntimeSource::Config),
            kind: entry
                .get("kind")
                .map(fixture)
                .unwrap_or(RuntimeKind::Command),
            color: entry.get("color").map(fixture).unwrap_or(None),
            state: entry.get("state").map(fixture).unwrap_or(LinkState::Up),
        },
        panes: entry.get("panes").map(fixture).unwrap_or(0),
        socket: text(entry, "socket"),
        paths: entry.get("paths").map(fixture).unwrap_or_default(),
        cwd: entry.get("cwd").map(fixture).unwrap_or(None),
        pi: entry.get("pi").map(fixture).unwrap_or(RuntimePi::Host),
    }
}

fn get_runtimes(name: Option<&str>) -> ExitCode {
    let raw = fs::read_to_string(env("KO_FAKE_RUNTIMES")).unwrap_or_default();
    let all: BTreeMap<String, Value> = serde_json::from_str(&raw).unwrap_or_default();
    match name {
        None => println!(
            "{}",
            protocol::json(
                &all.iter()
                    .map(|(name, entry)| runtime_info(name, entry))
                    .collect::<Vec<_>>()
            )
        ),
        Some(name) => match all.get(name) {
            Some(entry) => {
                if let Some(message) = entry["not_found"].as_str() {
                    return http_error(404, ErrorKind::Missing, message);
                }
                println!("{}", protocol::json(&runtime_info(name, entry)));
            }
            None => {
                return http_error(
                    404,
                    ErrorKind::Missing,
                    &format!("no runtime {name} in the fake"),
                );
            }
        },
    }
    ExitCode::SUCCESS
}

fn exec_failed(message: &str) -> ExitCode {
    emit_message(&ExecServer::Error {
        message: message.to_owned(),
    });
    eprintln!("ko api: closed: 1011 {message}");
    ExitCode::FAILURE
}

fn pump_output(
    mut source: impl Read + Send + 'static,
    stderr: bool,
) -> std::thread::JoinHandle<()> {
    std::thread::spawn(move || {
        let mut chunk = vec![0u8; 64 << 10];
        while let Ok(count) = source.read(&mut chunk) {
            if count == 0 {
                break;
            }
            let data = Text(chunk[..count].to_vec());
            emit_message(&if stderr {
                ExecServer::Stderr { data }
            } else {
                ExecServer::Stdout { data }
            });
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
    let Ok(line) = messages.recv() else {
        return exec_failed("missing exec request");
    };
    let Ok(ExecClient::Exec(request)) = protocol::decode(line.as_bytes()) else {
        return exec_failed("invalid exec request");
    };
    append(
        "KO_FAKE_EXEC_LOG",
        &json!({"runtime": name, "request": protocol::decode::<Value>(line.as_bytes()).unwrap_or(Value::Null)}).to_string(),
    );
    wait_gate("KO_FAKE_EXEC_GATE");
    let Some(entry) = runtime_entry(name) else {
        return exec_failed(&format!("no runtime {name} in the fake"));
    };
    if entry["state"]["type"] == "failed" {
        return exec_failed(entry["state"]["message"].as_str().unwrap_or("failed"));
    }
    let Some((program, args)) = request.argv.split_first() else {
        return exec_failed("argv needs a program");
    };
    let mut variables = BTreeMap::from([
        ("PATH".to_owned(), "/usr/bin:/bin".to_owned()),
        ("HOME".to_owned(), "/var/empty".to_owned()),
    ]);
    for (key, value) in entry["env"].as_object().into_iter().flatten() {
        variables.insert(key.clone(), value.as_str().unwrap_or_default().to_owned());
    }
    variables.extend(request.env.clone());
    variables.insert("KO_RUNTIME".to_owned(), name.to_owned());
    let Some(found) = find_program(program, &variables["PATH"]) else {
        return exec_failed(&format!("{program}: No such file or directory"));
    };
    let environment: Vec<Vec<u8>> = variables
        .iter()
        .map(|(key, value)| format!("{key}={value}").into_bytes())
        .collect();
    let words: Vec<&str> = args.iter().map(String::as_str).collect();
    let dir = request
        .cwd
        .as_ref()
        .map(|cwd| cwd.as_str())
        .or(entry["cwd"].as_str());
    let (Ok((out_read, out_write)), Ok((err_read, err_write)), Ok((in_read, in_write))) =
        (std::io::pipe(), std::io::pipe(), std::io::pipe())
    else {
        return exec_failed("pipe failed");
    };
    let null = std::fs::File::open("/dev/null");
    let Ok(null) = null else {
        return exec_failed("/dev/null");
    };
    let stdin = if request.stdin {
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
            let message = match protocol::decode::<ExecClient>(line.as_bytes()) {
                Ok(message) => message,
                Err(_) => {
                    exec_failed("invalid exec message");
                    std::process::exit(1);
                }
            };
            match message {
                ExecClient::Stdin { data: Text(bytes) } => {
                    if let Some(pipe) = input.as_mut() {
                        let _ = pipe.write_all(&bytes);
                    }
                }
                ExecClient::Eof {} => input = None,
                _ => {}
            }
        }
    });
    let pumps = [pump_output(out_read, false), pump_output(err_read, true)];
    let ended = pid.wait();
    for pump in pumps {
        let _ = pump.join();
    }
    emit_message(&ExecServer::Exit {
        ended: match ended {
            Ok(Waited::Ended(exit)) => exit.into(),
            _ => Ended::Status { status: 255 },
        },
    });
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
        ("STREAM", ["", "panes", pane, "messages"]) if *pane == env("KO_PANE") => {
            return stream_messages(pane);
        }
        ("STREAM", ["", "client"]) => return stream_client(),
        ("STREAM", ["", "runtimes", name, "exec"]) => return exec_session(name),
        ("GET", ["", "runtimes"]) => return get_runtimes(None),
        ("GET", ["", "runtimes", name]) => return get_runtimes(Some(name)),
        ("GET", ["", "layout"]) => {
            wait_gate("KO_FAKE_LAYOUT_GATE");
            if env("KO_FAKE_LAYOUT_FAIL") == "1" {
                return ExitCode::FAILURE;
            }
            println!("{}", protocol::json(&layout(&rows("KO_FAKE_PANES"))));
        }
        ("GET", ["", "version"]) => {
            let instance = Some(env("KO_FAKE_INSTANCE")).filter(|text| !text.is_empty());
            let instance = instance.unwrap_or_else(|| "0".repeat(32));
            println!(
                "{}",
                protocol::json(&ServerVersion {
                    instance: fixture(&json!(instance)),
                    version: Version {
                        build: "fake".to_owned(),
                        protocol: "1".to_owned(),
                        vt: "fake".to_owned()
                    }
                })
            );
        }
        ("POST", ["", "panes"]) => return new_pane(&body),
        ("POST", ["", "panes", pane, "stop"]) => {
            if protocol::decode::<StopPane>(body.as_bytes()).is_err() {
                return http_error(400, ErrorKind::Invalid, "not a StopPane");
            }
            return stop_pane(pane);
        }
        ("POST", ["", "panes", _, "status"]) => {
            if protocol::decode::<StatusReport>(body.as_bytes()).is_err() {
                return http_error(400, ErrorKind::Invalid, "not a StatusReport");
            }
            println!("{}", protocol::json(&Empty {}));
        }
        ("POST", ["", "panes", pane, "messages"]) => return send_message(pane, &body),
        ("GET", ["", "panes", _, "screen"]) => return screen(&path),
        ("PUT", ["", "panes", pane, "vars", name]) => return put_var(pane, name, &body),
        ("DELETE", ["", "panes", pane, "vars", name]) => {
            set_var(pane, name, None);
            println!("{}", protocol::json(&Empty {}));
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
        Some("webview") if argv.get(1).map(String::as_str) == Some("serve") => stream_webview(),
        Some("webview") if matches!(argv.get(1).map(String::as_str), Some("enter" | "leave")) => {
            ExitCode::SUCCESS
        }
        _ => ExitCode::FAILURE,
    }
}
