use std::io::Write;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use ko_pane_wire::frame::History;
use ko_server::config::{Config, DEFAULT_LIMITS};
use ko_server::http::{Response, read_response, read_upgrade, request};
use ko_server::ids::PaneId;
use ko_server::protocol::{Images, Route, ViewOptions, json, version_headers};
use ko_server::server::{Server, Status, Timing};
use ko_sys::clock::cpu_time;
use tungstenite::protocol::Role;
use tungstenite::{Message, WebSocket};

const DEADLINE: Duration = Duration::from_secs(600);

#[derive(Debug, Default)]
struct Count {
    bytes: u64,
    records: u64,
    offset: Option<u64>,
    lost: u64,
    gaps: u64,
    invalid: u64,
    elapsed: Duration,
}

fn exchange(socket: &Path, route: &Route, body: &str) -> std::io::Result<Response> {
    let mut stream = UnixStream::connect(socket)?;
    send(&mut stream, route, &headers(body), body.as_bytes())?;
    read_response(&mut stream)
}

fn send(
    stream: &mut UnixStream,
    route: &Route,
    headers: &[(&str, String)],
    body: &[u8],
) -> std::io::Result<()> {
    let (method, target) = route.to_request();
    let headers: Vec<(&str, &str)> = headers
        .iter()
        .map(|(name, value)| (*name, value.as_str()))
        .collect();
    stream.write_all(&request(method, &target, &headers, body))
}

fn headers(body: &str) -> Vec<(&'static str, String)> {
    let mut headers: Vec<(&'static str, String)> = version_headers().to_vec();
    headers.push(("host", "ko".to_owned()));
    headers.push(("content-length", body.len().to_string()));
    headers
}

fn watch(socket: &Path, argv: Vec<String>, expected: u64) -> std::io::Result<Count> {
    let mut command = vec![
        "/bin/sh".to_owned(),
        "-c".to_owned(),
        "stty raw -echo; printf R; read go; exec \"$@\"".to_owned(),
        "sh".to_owned(),
    ];
    command.extend(argv);
    let create = format!(r#"{{"cwd":"/","command":["argv",{}]}}"#, json(&command));
    let created = exchange(socket, &Route::CreatePane, &create)?;
    let pane: PaneId = String::from_utf8_lossy(&created.body)
        .split('"')
        .nth(3)
        .and_then(|pane| pane.parse().ok())
        .ok_or_else(|| std::io::Error::other("no pane created"))?;
    let options = ViewOptions {
        history: History::None,
        images: Images::None,
    };
    let mut stream = UnixStream::connect(socket)?;
    let mut upgrade = headers("");
    upgrade.extend([
        ("upgrade", "websocket".to_owned()),
        ("connection", "Upgrade".to_owned()),
        ("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==".to_owned()),
        ("sec-websocket-version", "13".to_owned()),
    ]);
    send(
        &mut stream,
        &Route::View(pane, options, None),
        &upgrade,
        b"",
    )?;
    let (_, rest) = read_upgrade(&mut stream)?;
    let mut view = WebSocket::from_partially_read(stream, rest, Role::Client, None);
    let mut next = || match view.read() {
        Ok(Message::Binary(payload)) => Ok(Some(payload.to_vec())),
        Ok(Message::Text(text)) => Ok((!text.starts_with("[\"skipped\"")).then(Vec::new)),
        Ok(_) => Ok(Some(Vec::new())),
        Err(error) => Err(std::io::Error::other(error.to_string())),
    };
    while !next()?.is_some_and(|payload| payload.first() == Some(&1)) {}
    exchange(socket, &Route::Input(pane), r#"["text","Cg=="]"#)?;
    let start = Instant::now();
    let mut count = Count::default();
    while count.bytes < expected {
        match next()? {
            None => count.lost += 1,
            Some(payload) if payload.len() >= 9 && payload[0] == 1 => {
                let offset = u64::from_le_bytes(payload[1..9].try_into().unwrap_or_default());
                let len = payload.len() as u64 - 9;
                if count.offset.is_some_and(|next| next != offset) {
                    count.gaps += 1;
                }
                count.offset = Some(offset + len);
                count.bytes += len;
                count.records += 1;
            }
            Some(payload) if payload.is_empty() || payload[0] == 2 => {}
            Some(_) => count.invalid += 1,
        }
    }
    count.elapsed = start.elapsed();
    Ok(count)
}

fn probe(pane_exe: PathBuf, argv: Vec<String>, expected: u64) -> Result<String, String> {
    let dir = PathBuf::from(format!("/tmp/ko-probe-{}", std::process::id()));
    std::fs::create_dir_all(&dir).map_err(|error| error.to_string())?;
    let socket = dir.join("socket");
    let listener = UnixListener::bind(&socket).map_err(|error| error.to_string())?;
    let config = Config {
        dir: dir.clone(),
        socket: socket.clone(),
        pane_exe,
        terminfo: dir.clone(),
        shell: PathBuf::from("/bin/sh"),
        limits: DEFAULT_LIMITS,
        media: Vec::new(),
        env: Vec::new(),
        cwd: PathBuf::from("/"),
    };
    let mut server =
        Server::new(config, listener, Timing::DEFAULT).map_err(|error| error.to_string())?;
    let (sender, results) = mpsc::channel();
    std::thread::spawn(move || {
        let _ = sender.send(watch(&socket, argv, expected).map_err(|error| error.to_string()));
    });
    let cpu = cpu_time();
    let mut result = None;
    let mut status = Status::Running;
    while status == Status::Running {
        status = server.turn().map_err(|error| error.to_string())?;
        if result.is_none()
            && let Ok(count) = results.try_recv()
        {
            result = Some(count?);
            server.stop().map_err(|error| error.to_string())?;
        }
    }
    let cpu = cpu_time() - cpu;
    std::fs::remove_dir_all(&dir).map_err(|error| error.to_string())?;
    let count = result.ok_or("the server stopped early")?;
    let seconds = count.elapsed.as_secs_f64();
    let gib = count.bytes as f64 / f64::from(1u32 << 30);
    let line = format!(
        "probe bytes={} expected={expected} records={} lost={} gaps={} invalid={} \
         seconds={seconds:.3} MB/s={:.1} process_cpu={:.3} cores={:.2} cpu_s_per_GiB={:.3}",
        count.bytes,
        count.records,
        count.lost,
        count.gaps,
        count.invalid,
        count.bytes as f64 / seconds / 1e6,
        cpu.as_secs_f64(),
        cpu.as_secs_f64() / seconds,
        cpu.as_secs_f64() / gib,
    );
    if count.lost == 0 && count.gaps == 0 && count.invalid == 0 && count.bytes == expected {
        Ok(line)
    } else {
        Err(line)
    }
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let [pane_exe, producer, bytes, streams @ ..] = args.as_slice() else {
        eprintln!("usage: ring_probe KO_PANE PRODUCER BYTES STREAM...");
        return ExitCode::from(2);
    };
    let Ok(expected) = bytes.parse() else {
        eprintln!("ring_probe: BYTES must be a number");
        return ExitCode::from(2);
    };
    std::thread::spawn(|| {
        std::thread::sleep(DEADLINE);
        eprintln!("ring_probe: no result within {DEADLINE:?}");
        std::process::exit(1);
    });
    let argv = [producer, bytes]
        .into_iter()
        .chain(streams)
        .cloned()
        .collect();
    match probe(PathBuf::from(pane_exe), argv, expected) {
        Ok(line) => {
            println!("{line}");
            ExitCode::SUCCESS
        }
        Err(message) => {
            eprintln!("ring_probe: {message}");
            ExitCode::FAILURE
        }
    }
}
