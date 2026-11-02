use std::fmt::Display;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Sender};
use std::time::{Duration, Instant};

use ko_pane_wire::frame::{CellPx, Dim, History, Size};
use ko_server::config::{DEFAULT_LIMITS, scratch};
use ko_server::protocol::{
    self, ClientKind, ClientRequest, Hello, Images, Route, Row, ViewOptions, ViewRequest, json,
};
use ko_server::server::{Server, Status, Timing};
use ko_sys::clock::{Mono, children_cpu_time, process_cpu, thread_cpu_time};
use ko_sys::pid::Pid;
use ko_sys::signal::Signal;

use crate::alloc::allocations;
use crate::client::{
    Socket, Stamps, Typist, create_pane, dead, exchange, open_view, output, program_pids,
    screen_text, upgrade,
};

const DEADLINE: Duration = Duration::from_secs(900);

pub(crate) fn failed(error: impl Display) -> String {
    error.to_string()
}

fn number<T: std::str::FromStr>(text: &str, what: &str) -> Result<T, String> {
    text.parse().map_err(|_| format!("{what} must be a number"))
}

fn pane_exe() -> Result<PathBuf, String> {
    Ok(std::env::current_exe()
        .map_err(failed)?
        .with_file_name("ko-pane"))
}

fn produce() -> Result<String, String> {
    let exe = std::env::current_exe().map_err(failed)?;
    let root = exe
        .ancestors()
        .nth(3)
        .ok_or("ko-bench is not in <repo>/target/<profile>")?;
    Ok(root
        .join("build/bench/produce")
        .to_string_lossy()
        .into_owned())
}

fn gated(argv: Vec<String>) -> Vec<String> {
    let mut command = vec![
        "/bin/sh".to_owned(),
        "-c".to_owned(),
        "stty raw -echo; printf R; read go; exec \"$@\"".to_owned(),
        "sh".to_owned(),
    ];
    command.extend(argv);
    command
}

enum Message<T> {
    Begin(Vec<i32>),
    Done(Result<T, String>),
}

struct Mark {
    at: Instant,
    cpu: Duration,
    allocations: u64,
}

impl Mark {
    fn now() -> Mark {
        Mark {
            at: Instant::now(),
            cpu: thread_cpu_time(),
            allocations: allocations(),
        }
    }
}

struct Measured {
    seconds: f64,
    cpu: Duration,
    allocations: u64,
    pane_cpu: Duration,
}

fn parent(pid: i32) -> Option<i32> {
    let output = std::process::Command::new("ps")
        .args(["-o", "ppid=", "-p", &pid.to_string()])
        .output()
        .ok()?;
    String::from_utf8_lossy(&output.stdout).trim().parse().ok()
}

fn drive<T: Send + 'static>(
    timing: Timing,
    client: impl FnOnce(&Path, &Sender<Message<T>>) -> Result<T, String> + Send + 'static,
) -> Result<(Measured, T), String> {
    std::thread::spawn(|| {
        std::thread::sleep(DEADLINE);
        eprintln!("ko-bench: no result within {DEADLINE:?}");
        std::process::exit(1);
    });
    let dir = PathBuf::from(format!("/tmp/ko-bench-{}", std::process::id()));
    std::fs::create_dir_all(&dir).map_err(failed)?;
    let socket = dir.join("socket");
    let listener = UnixListener::bind(&socket).map_err(failed)?;
    let mut server = Server::new(scratch(&dir, pane_exe()?, DEFAULT_LIMITS), listener, timing)
        .map_err(failed)?;
    let (sender, messages) = mpsc::channel();
    let client_socket = socket.clone();
    std::thread::spawn(move || {
        let result = client(&client_socket, &sender);
        let _ = sender.send(Message::Done(result));
        let _ = UnixStream::connect(&client_socket);
    });
    let (mut began, mut pids) = (None, Vec::new());
    let (result, end) = loop {
        server.turn().map_err(failed)?;
        let mut done = None;
        while let Ok(message) = messages.try_recv() {
            match message {
                Message::Begin(started) => {
                    pids = started;
                    began = Some(Mark::now());
                }
                Message::Done(result) => done = Some((result, Mark::now())),
            }
        }
        if let Some(done) = done {
            break done;
        }
    };
    let pane_cpu = pids
        .iter()
        .filter_map(|pid| Pid::new(i64::from(*pid)))
        .filter_map(|pid| process_cpu(pid).ok())
        .map(|cpu| cpu.time)
        .sum();
    server.stop().map_err(failed)?;
    while server.turn().map_err(failed)? == Status::Running {}
    let _ = std::fs::remove_dir_all(&dir);
    let begin = began.ok_or("the client never began")?;
    Ok((
        Measured {
            seconds: end.at.duration_since(begin.at).as_secs_f64(),
            cpu: end.cpu.saturating_sub(begin.cpu),
            allocations: end.allocations.saturating_sub(begin.allocations),
            pane_cpu,
        },
        result?,
    ))
}

fn begin(socket: &Path, tx: &Sender<Message<impl Send>>) -> Result<(), String> {
    let programs = program_pids(socket).map_err(failed)?;
    let pids = programs.into_iter().filter_map(parent).collect();
    tx.send(Message::Begin(pids)).map_err(failed)
}

fn ready(view: &mut Socket) -> Result<(), String> {
    while let Some(message) = view.next().map_err(failed)? {
        if output(&message).is_some_and(|(_, bytes)| bytes.contains(&b'R')) {
            return Ok(());
        }
    }
    Err("the pane never became ready".to_owned())
}

#[derive(Debug, Default)]
struct Count {
    bytes: u64,
    records: u64,
    lost: u64,
    gaps: u64,
    invalid: u64,
}

pub(crate) fn throughput(bytes: &str, coalesce: &str, streams: &[&str]) -> Result<(), String> {
    let expected: u64 = number(bytes, "BYTES")?;
    if coalesce != "2" {
        return Err("production coalescing is 2 ms".to_owned());
    }
    let mut argv = vec![produce()?, bytes.to_owned()];
    argv.extend(streams.iter().map(|stream| (*stream).to_owned()));
    let (measured, count) = drive(Timing::DEFAULT, move |socket, tx| {
        let pane = create_pane(socket, &gated(argv)).map_err(failed)?;
        let mut view = open_view(socket, pane, History::None).map_err(failed)?;
        ready(&mut view)?;
        begin(socket, tx)?;
        Typist::connect(socket)
            .and_then(|mut typist| typist.type_text(pane, b"\n"))
            .map_err(failed)?;
        let mut count = Count::default();
        let mut next = None;
        while count.bytes < expected {
            let Some(message) = view.next().map_err(failed)? else {
                return Err(format!("the view closed after {} bytes", count.bytes));
            };
            if let Some((offset, data)) = output(&message) {
                if next.is_some_and(|next| next != offset) {
                    count.gaps += 1;
                }
                next = Some(offset + data.len() as u64);
                count.bytes += data.len() as u64;
                count.records += 1;
            } else if message.opcode == 1 && message.payload.starts_with(b"[\"skipped\"") {
                count.lost += 1;
            } else if message.opcode == 2 && !matches!(message.payload.first(), Some(1 | 2))
                || message.payload.first() == Some(&1) && message.payload.len() < 9
            {
                count.invalid += 1;
            }
        }
        Ok(count)
    })?;
    let cores = (measured.pane_cpu + measured.cpu).as_secs_f64() / measured.seconds;
    println!(
        "ko view=writev coalesce_ms=2 bytes={} seconds={:.3} MB/s={:.1} records={} \
         allocations/record={:.2} pane_cpu={:.3} coordinator_cpu={:.3} cores={cores:.2}",
        count.bytes,
        measured.seconds,
        count.bytes as f64 / measured.seconds / 1e6,
        count.records,
        measured.allocations as f64 / count.records.max(1) as f64,
        measured.pane_cpu.as_secs_f64(),
        measured.cpu.as_secs_f64(),
    );
    if count.lost > 0 || count.gaps > 0 || count.invalid > 0 || count.bytes != expected {
        return Err(format!("byte count mismatch: {count:?}"));
    }
    Ok(())
}

fn summary(mut samples: Vec<f64>) -> String {
    if samples.is_empty() {
        return "samples=0".to_owned();
    }
    samples.sort_by(f64::total_cmp);
    let last = samples.len() - 1;
    format!(
        "samples={} p50_us={:.0} p99_us={:.0} max_us={:.0}",
        samples.len(),
        samples[samples.len() / 2],
        samples[samples.len() * 99 / 100],
        samples[last]
    )
}

pub(crate) fn latency(count: &str) -> Result<(), String> {
    let wanted: usize = number(count, "COUNT")?;
    let argv = vec![produce()?, "--latency".to_owned(), count.to_owned()];
    let (_, samples) = drive(Timing::DEFAULT, move |socket, tx| {
        let pane = create_pane(socket, &gated(argv)).map_err(failed)?;
        let mut view = open_view(socket, pane, History::None).map_err(failed)?;
        ready(&mut view)?;
        begin(socket, tx)?;
        Typist::connect(socket)
            .and_then(|mut typist| typist.type_text(pane, b"\n"))
            .map_err(failed)?;
        let (mut samples, mut stamps, mut last) = (Vec::new(), Stamps::default(), 0);
        while let Some(message) = view.next().map_err(failed)? {
            if let Some((_, data)) = output(&message) {
                let now = message.at.nanos();
                stamps.feed(data, |stamp| {
                    if stamp != last && stamp <= now {
                        last = stamp;
                        samples.push((now - stamp) as f64 / 1e3);
                    }
                });
            } else if dead(&message) {
                break;
            }
        }
        Ok(samples)
    })?;
    if samples.len() < wanted {
        return Err(format!("{} of {wanted} samples arrived", samples.len()));
    }
    println!("hop latency view=writev {}", summary(samples));
    Ok(())
}

fn resync(view: &mut Socket, history: History) -> Result<(u64, f64), String> {
    let started = Instant::now();
    let options = ViewOptions {
        history,
        images: Images::None,
    };
    view.send_text(&json(&ViewRequest::Resync(options)))
        .map_err(failed)?;
    slices(view, started)
}

fn slices(view: &mut Socket, started: Instant) -> Result<(u64, f64), String> {
    let mut total = 0;
    loop {
        let Some(message) = view.next().map_err(failed)? else {
            return Err("the view closed during a snapshot".to_owned());
        };
        let record = message.payload;
        if message.opcode == 2 && record.first() == Some(&2) && record.len() >= 11 {
            total += (record.len() - 11) as u64;
            if record[9] & 2 != 0 {
                return Ok((total, started.elapsed().as_secs_f64() * 1e3));
            }
        }
    }
}

pub(crate) fn snapshot(lines: &str) -> Result<(), String> {
    let count: u64 = number(lines, "LINES")?;
    let argv = vec![produce()?, "--lines".to_owned(), count.to_string()];
    let (_, results) = drive(Timing::DEFAULT, move |socket, tx| {
        let pane = create_pane(socket, &argv).map_err(failed)?;
        let mut view = open_view(socket, pane, History::None).map_err(failed)?;
        while let Some(message) = view.next().map_err(failed)? {
            if dead(&message) {
                break;
            }
        }
        tx.send(Message::Begin(Vec::new())).map_err(failed)?;
        let mut results = vec![("full", resync(&mut view, History::All)?)];
        results.push(("screen", resync(&mut view, History::None)?));
        let started = Instant::now();
        let mut client = upgrade(socket, &Route::Client).map_err(failed)?;
        let (cols, rows) = (Dim::new(100), Dim::new(30));
        let size = Size {
            cols: cols.ok_or("columns")?,
            rows: rows.ok_or("rows")?,
            cell_px: Some(CellPx::DEFAULT),
        };
        let hello = ClientRequest::Hello(Hello {
            kind: ClientKind::Terminal,
            name: "bench".to_owned(),
            pane: Some(pane),
            focused: true,
            size: protocol::Size(size),
            ignore_size: false,
        });
        client.send_text(&json(&hello)).map_err(failed)?;
        results.push(("resize+screen", slices(&mut view, started)?));
        Ok(results)
    })?;
    for (kind, (bytes, ms)) in results {
        println!("snapshot view=writev lines={count} kind={kind} bytes={bytes} ms={ms:.2}");
    }
    Ok(())
}

pub(crate) fn cpu_check() -> Result<(), String> {
    let null = std::fs::OpenOptions::new()
        .write(true)
        .open("/dev/null")
        .map_err(failed)?;
    let before = children_cpu_time();
    let child = ko_sys::spawn::program(
        Path::new("/usr/bin/yes"),
        &[],
        &[(std::os::fd::AsFd::as_fd(&null), 1)],
    )
    .map_err(failed)?;
    std::thread::sleep(Duration::from_secs(1));
    let cpu = process_cpu(child).map_err(failed)?;
    child.signal(Signal::Kill).map_err(failed)?;
    child.wait().map_err(failed)?;
    let children = children_cpu_time().saturating_sub(before);
    println!(
        "cpu check: proc_pid_rusage as ns={:.3} s, times mach_timebase={:.3} s, getrusage RUSAGE_CHILDREN={:.3} s",
        cpu.ticks.get() as f64 / 1e9,
        cpu.time.as_secs_f64(),
        children.as_secs_f64()
    );
    Ok(())
}

struct Reading {
    bytes: u64,
    records: u64,
    summary: String,
}

type Reader = std::thread::JoinHandle<Reading>;

fn reader(
    mut view: Socket,
    deaths: Option<(usize, Sender<(usize, Instant)>)>,
    timed: bool,
) -> Reader {
    std::thread::spawn(move || {
        let (mut bytes, mut records) = (0, 0);
        let (mut samples, mut stamps, mut last) = (Vec::new(), Stamps::default(), 0);
        while let Ok(Some(message)) = view.next() {
            if let Some((_, data)) = output(&message) {
                bytes += data.len() as u64;
                records += 1;
                if timed {
                    let now = message.at.nanos();
                    stamps.feed(data, |stamp| {
                        if stamp != last && stamp <= now {
                            last = stamp;
                            samples.push((now - stamp) as f64 / 1e3);
                        }
                    });
                }
            } else if let Some((index, sender)) = &deaths
                && dead(&message)
            {
                let _ = sender.send((*index, Instant::now()));
            }
        }
        Reading {
            bytes,
            records,
            summary: if timed {
                summary(samples)
            } else {
                String::new()
            },
        }
    })
}

struct Flood {
    died: Vec<f64>,
    readers: Vec<Reader>,
    echo: Reader,
}

pub(crate) fn flood(
    panes: &str,
    views: &str,
    bytes: &str,
    window: &str,
    streams: &[&str],
) -> Result<(), String> {
    let (panes, views): (usize, usize) = (number(panes, "PANES")?, number(views, "VIEWS")?);
    let (per_pane, window_ms): (u64, u64) = (number(bytes, "BYTES")?, number(window, "WINDOW")?);
    let streams: Vec<String> = streams.iter().map(|stream| (*stream).to_owned()).collect();
    let timing = Timing {
        output_tick: Duration::from_millis(window_ms),
        ..Timing::DEFAULT
    };
    let (measured, flood) = drive(timing, move |socket, tx| {
        let command = |stamped: bool| {
            let mut argv = vec![produce()?];
            if stamped {
                argv.push("--stamped".to_owned());
            }
            argv.push(per_pane.to_string());
            argv.extend(streams.iter().cloned());
            Ok::<_, String>(gated(argv))
        };
        let (deaths, died) = mpsc::channel();
        let mut flooded = Vec::new();
        let mut readers = Vec::new();
        for i in 0..panes {
            let pane = create_pane(socket, &command(i == 0)?).map_err(failed)?;
            flooded.push(pane);
            if i < views {
                let view = open_view(socket, pane, History::None).map_err(failed)?;
                readers.push(reader(view, Some((i, deaths.clone())), i == 0));
            }
        }
        let quiet = create_pane(socket, &["/bin/cat".to_owned()]).map_err(failed)?;
        let echo = reader(
            open_view(socket, quiet, History::None).map_err(failed)?,
            None,
            true,
        );
        let waiting = Instant::now() + Duration::from_secs(30);
        for pane in &flooded {
            while !screen_text(socket, *pane).map_err(failed)?.contains('R') {
                if Instant::now() > waiting {
                    return Err("a producer never became ready".to_owned());
                }
                std::thread::sleep(Duration::from_millis(5));
            }
        }
        tx.send(Message::Begin(Vec::new())).map_err(failed)?;
        let started = Instant::now();
        let mut typist = Typist::connect(socket).map_err(failed)?;
        for pane in &flooded {
            typist.type_text(*pane, b"\n").map_err(failed)?;
        }
        let stop = Arc::new(AtomicBool::new(false));
        let echoing = {
            let (stop, socket) = (stop.clone(), socket.to_path_buf());
            std::thread::spawn(move || -> Result<(), String> {
                let mut typist = Typist::connect(&socket).map_err(failed)?;
                while !stop.load(Ordering::SeqCst) {
                    let text = format!("T{:020}\n", Mono::now().nanos());
                    typist.type_text(quiet, text.as_bytes()).map_err(failed)?;
                    std::thread::sleep(Duration::from_millis(10));
                }
                Ok(())
            })
        };
        let mut seconds = vec![f64::NAN; panes];
        for _ in 0..readers.len() {
            let (index, at) = died
                .recv_timeout(Duration::from_secs(120))
                .map_err(|_| "benchmark deadline".to_owned())?;
            seconds[index] = at.duration_since(started).as_secs_f64();
        }
        if views < panes {
            while exchange(socket, &Route::ListPanes, "")
                .map_err(failed)
                .and_then(|response| protocol::decode::<Vec<Row>>(&response.body).map_err(failed))?
                .iter()
                .any(|row| row.dead.is_none() && flooded.contains(&row.id))
            {
                std::thread::sleep(Duration::from_millis(25));
            }
            let all = started.elapsed().as_secs_f64();
            seconds.iter_mut().skip(views).for_each(|s| *s = all);
        }
        stop.store(true, Ordering::SeqCst);
        echoing
            .join()
            .map_err(|_| "the echo panicked".to_owned())??;
        Ok(Flood {
            died: seconds,
            readers,
            echo,
        })
    })?;
    let mut records = 0;
    let mut flood_summary = String::new();
    for (i, reader) in flood.readers.into_iter().enumerate() {
        let reading = reader.join().map_err(|_| "a reader panicked".to_owned())?;
        records += reading.records;
        if i == 0 {
            flood_summary = format!("flood bytes={} {}", reading.bytes, reading.summary);
        }
    }
    let echo = flood
        .echo
        .join()
        .map_err(|_| "a reader panicked".to_owned())?;
    let rates: Vec<f64> = flood
        .died
        .iter()
        .map(|seconds| per_pane as f64 / seconds / 1e6)
        .collect();
    let lowest = rates.iter().copied().fold(f64::INFINITY, f64::min);
    let highest = rates.iter().copied().fold(0.0, f64::max);
    println!(
        "flood panes={panes} views={views} window_ms={window_ms} bytes_per_pane={per_pane} \
         seconds={:.2} total_MBps={:.1} pane_MBps_min={lowest:.1} pane_MBps_max={highest:.1} \
         coordinator_cores={:.2} records={records} allocations_per_record={:.2}",
        measured.seconds,
        per_pane as f64 * panes as f64 / measured.seconds / 1e6,
        measured.cpu.as_secs_f64() / measured.seconds,
        measured.allocations as f64 / records.max(1) as f64,
    );
    eprintln!("{flood_summary}");
    eprintln!("echo bytes={} {}", echo.bytes, echo.summary);
    Ok(())
}
