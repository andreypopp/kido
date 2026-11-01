use std::os::unix::net::UnixListener;
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::{Duration, Instant};

use ko_pane_wire::ring::{Pos, Reader, RecordKind};
use ko_server::config::{Config, DEFAULT_LIMITS};
use ko_server::pane_proc::{Cause, Delivery};
use ko_server::panes::{Command, Create};
use ko_server::server::{Server, Status, Timing};
use ko_sys::clock::cpu_time;
use ko_sys::pid::Exit;

const DEADLINE: Duration = Duration::from_secs(600);

#[derive(Debug, Default)]
struct Count {
    counted: Option<Pos>,
    bytes: u64,
    records: u64,
    offset: u64,
    lost: u64,
    gaps: u64,
    invalid: u64,
}

impl Count {
    fn record(&mut self, ring: &Reader) {
        let upper = ring.seen();
        let mut at = self.counted.unwrap_or(ring.tail());
        if at < ring.tail() {
            self.lost += 1;
            at = ring.tail();
        }
        while at < upper {
            let Ok(record) = ring.record(at) else {
                self.invalid += 1;
                break;
            };
            if record.kind == RecordKind::Bytes {
                if record.offset.get() != self.offset {
                    self.gaps += 1;
                }
                self.offset = record.offset.get() + record.len;
                self.bytes += record.len;
                self.records += 1;
            }
            at = record.next;
        }
        self.counted = Some(at);
    }
}

fn probe(pane_exe: PathBuf, argv: Vec<String>, expected: u64) -> Result<String, String> {
    let dir = PathBuf::from(format!("/tmp/ko-probe-{}", std::process::id()));
    std::fs::create_dir_all(&dir).map_err(|error| error.to_string())?;
    let socket = dir.join("socket");
    let listener = UnixListener::bind(&socket).map_err(|error| error.to_string())?;
    let config = Config {
        dir: dir.clone(),
        socket,
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
    let start = Instant::now();
    let cpu = cpu_time();
    let id = server
        .add_pane(&Create {
            cwd: Some(PathBuf::from("/")),
            command: Some(Command::Argv(argv)),
            env: Vec::new(),
        })
        .map_err(|error| error.to_string())?;
    let mut count = Count::default();
    let mut accepted = Vec::new();
    let mut elapsed = None;
    let mut status = Status::Running;
    while status == Status::Running {
        status = server
            .turn(&mut accepted, &mut |_, ring, delivery| {
                if delivery == Delivery::Scanned {
                    count.record(ring);
                }
            })
            .map_err(|error| error.to_string())?;
        let dead = server
            .panes()
            .find(id)
            .and_then(|pane| pane.proc().dead())
            .map(|death| death.cause.clone());
        match dead {
            None => {}
            Some(Cause::Exit(Exit::Exited(0))) => {
                if elapsed.is_none() && count.bytes >= expected {
                    elapsed = Some(start.elapsed());
                    server.stop().map_err(|error| error.to_string())?;
                }
            }
            Some(cause) => return Err(format!("the pane ended: {cause:?}")),
        }
    }
    let cpu = cpu_time() - cpu;
    std::fs::remove_dir_all(&dir).map_err(|error| error.to_string())?;
    let seconds = elapsed.ok_or("the server stopped early")?.as_secs_f64();
    let gib = count.bytes as f64 / f64::from(1u32 << 30);
    let line = format!(
        "probe bytes={} expected={expected} records={} lost={} gaps={} invalid={} \
         seconds={seconds:.3} MB/s={:.1} coordinator_cpu={:.3} cores={:.2} cpu_s_per_GiB={:.3}",
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
