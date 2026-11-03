use std::collections::BTreeMap;
use std::num::NonZeroUsize;
use std::time::{Duration, Instant};

use ko_pane_wire::frame::{Dim, Limits, Scrollback, Size};
use ko_server::config::DEFAULT_LIMITS;
use ko_sys::clock::Mono;
use ko_vt::compress::{Compress, Tick};
use ko_vt::{Extent, Format, Terminal};

use crate::modes::failed;

fn number<T: std::str::FromStr>(text: &str, what: &str) -> Result<T, String> {
    text.parse().map_err(|_| format!("{what} must be a number"))
}

fn dim(value: usize) -> Result<Dim, String> {
    u16::try_from(value)
        .ok()
        .and_then(Dim::new)
        .ok_or_else(|| format!("{value} is not a terminal dimension"))
}

fn create(cols: usize, rows: usize, scrollback_bytes: Option<usize>) -> Result<Terminal, String> {
    let limits = match scrollback_bytes {
        Some(bytes) => Limits {
            scrollback: Scrollback::Bounded {
                max_bytes: NonZeroUsize::new(bytes),
                max_lines: None,
            },
            ..DEFAULT_LIMITS
        },
        None => DEFAULT_LIMITS,
    };
    Terminal::new(dim(cols)?, dim(rows)?, limits).map_err(failed)
}

fn resize(terminal: &mut Terminal, cols: usize, rows: usize) -> Result<(), String> {
    let size = Size {
        cols: dim(cols)?,
        rows: dim(rows)?,
        cell_px: None,
    };
    terminal.resize(size).map_err(failed)
}

fn decode(bytes: &[u8], extent: Extent) -> Result<Terminal, String> {
    Terminal::decode(&mut &bytes[..], extent).map_err(failed)
}

fn screen_snapshot(server: &mut Terminal) -> Result<Terminal, String> {
    decode(
        &server.snapshot_bytes(true).map_err(failed)?,
        Extent::Screen,
    )
}

struct Random(u64);

impl Random {
    fn below(&mut self, bound: usize) -> usize {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        usize::try_from(self.0 % u64::try_from(bound.max(1)).unwrap_or(1)).unwrap_or(0)
    }
}

struct Mirror {
    name: &'static str,
    terminal: Terminal,
    divergences: BTreeMap<String, u32>,
}

fn check(
    server: &Terminal,
    mirror: &mut Mirror,
    marker: usize,
    moment: &str,
) -> Result<(), String> {
    for kind in
        ko_vt::differences(server, &mirror.terminal, false, <[u8]>::to_vec).map_err(failed)?
    {
        let count = mirror
            .divergences
            .entry(format!("{moment}: {kind}"))
            .or_default();
        if *count == 0 {
            println!(
                "first divergence marker={marker} mirror={} {moment}: {kind}",
                mirror.name
            );
        }
        *count += 1;
    }
    Ok(())
}

fn determinism(iterations: usize, streams: &[&str]) -> Result<(), String> {
    let mut corpus = Vec::new();
    for stream in streams {
        corpus.extend(std::fs::read(stream).map_err(failed)?);
    }
    if corpus.is_empty() {
        return Err("no stream bytes".to_owned());
    }
    let mut random = Random(0x00b6_d7a1_9e37_79b9);
    let mut server = create(80, 24, None)?;
    let make = |name| -> Result<Mirror, String> {
        Ok(Mirror {
            name,
            terminal: create(80, 24, None)?,
            divergences: BTreeMap::new(),
        })
    };
    let mut full = make("full, applies resize")?;
    let mut partial = make("partial, screen snapshot after resize")?;
    let mut this = make("partial, applies resize itself")?;
    let mut offset = 0;
    for marker in 1..=iterations {
        let start = offset % corpus.len();
        let len = (1 + random.below(65536)).min(corpus.len() - start);
        let chunk = corpus.get(start..start + len).unwrap_or_default();
        offset += len;
        for terminal in [
            &mut server,
            &mut full.terminal,
            &mut partial.terminal,
            &mut this.terminal,
        ] {
            terminal.write(chunk);
        }
        for mirror in [&mut full, &mut partial, &mut this] {
            check(&server, mirror, marker, "after bytes")?;
        }
        this.terminal = screen_snapshot(&mut server)?;
        let (cols, rows) = (2 + random.below(200), 2 + random.below(70));
        for terminal in [&mut server, &mut full.terminal, &mut this.terminal] {
            resize(terminal, cols, rows)?;
        }
        partial.terminal = screen_snapshot(&mut server)?;
        for mirror in [&mut full, &mut partial, &mut this] {
            check(&server, mirror, marker, "after resize")?;
        }
    }
    println!("determinism markers={iterations} bytes={offset}");
    for mirror in [&full, &partial, &this] {
        let found = if mirror.divergences.is_empty() {
            " none".to_owned()
        } else {
            mirror
                .divergences
                .iter()
                .map(|(kind, count)| format!(" [{kind} x{count}]"))
                .collect()
        };
        println!("  mirror={}:{found}", mirror.name);
    }
    Ok(())
}

fn snapshots() -> Result<(), String> {
    for lines in [10_000, 100_000] {
        let mut terminal = create(80, 24, None)?;
        for line in 1..=lines {
            terminal
                .write(format!("{line:06}: \x1b[32mok\x1b[0m build step completed\r\n").as_bytes());
        }
        for screen in [false, true] {
            let started = Instant::now();
            let bytes = terminal.snapshot_bytes(screen).map_err(failed)?;
            let encode = started.elapsed();
            let started = Instant::now();
            let restored = decode(&bytes, if screen { Extent::Screen } else { Extent::Full })?;
            let decoded = started.elapsed();
            println!(
                "snapshot lines={lines} rows_kept={} kind={} bytes={} encode_ms={:.2} decode_ms={:.2} rows_restored={} screen_equal={}",
                terminal.total_rows().map_err(failed)?,
                if screen { "screen" } else { "full" },
                bytes.len(),
                encode.as_secs_f64() * 1e3,
                decoded.as_secs_f64() * 1e3,
                restored.total_rows().map_err(failed)?,
                terminal.dump(Format::Vt).map_err(failed)?
                    == restored.dump(Format::Vt).map_err(failed)?,
            );
        }
    }
    Ok(())
}

pub(crate) fn mirror(iterations: &str, streams: &[&str]) -> Result<(), String> {
    determinism(number(iterations, "ITERATIONS")?, streams)?;
    snapshots()
}

fn mib(bytes: u64) -> f64 {
    bytes as f64 / 1_048_576.0
}

fn report(label: &str, terminal: &Terminal) -> Result<(), String> {
    let memory = terminal.memory().map_err(failed)?;
    println!(
        "{label}: {} pages, {} compressed, resident {:.1} MiB",
        memory.pages,
        memory.compressed_pages,
        mib(memory.resident_bytes)
    );
    Ok(())
}

pub(crate) fn usage(lines: &str, cols: &str, rows: &str) -> Result<(), String> {
    let lines: usize = number(lines, "LINES")?;
    let mut terminal = create(
        number(cols, "COLS")?,
        number(rows, "ROWS")?,
        Some(200_000_000),
    )?;
    let history: String = (1..=lines)
        .map(|i| format!("line {i:06} the quick brown fox jumps over the lazy dog 0123456789\r\n"))
        .collect();
    terminal.write(history.as_bytes());
    report("ko-pane terminal, history written", &terminal)?;
    let mut compress = Compress::new(Mono::now());
    let start = Mono::now().nanos() + 1_000_000_000;
    compress.tick(&mut terminal, Mono::from_nanos(start));
    let now = Mono::from_nanos(start + 250_000_000);
    let (mut steps, mut slowest, mut total) = (0, Duration::ZERO, Duration::ZERO);
    loop {
        let began = Instant::now();
        let tick = compress.tick(&mut terminal, now);
        let took = began.elapsed();
        steps += 1;
        total += took;
        slowest = slowest.max(took);
        if tick != Tick::Now {
            break;
        }
    }
    println!(
        "incremental compression: {steps} ticks, {:.1} ms total, slowest {:.2} ms",
        total.as_secs_f64() * 1e3,
        slowest.as_secs_f64() * 1e3
    );
    report("ko-pane terminal, compressed", &terminal)?;
    let bytes = terminal.snapshot_bytes(false).map_err(failed)?;
    println!("snapshot: {:.1} MiB", mib(bytes.len() as u64));
    let began = Instant::now();
    let mirror = decode(&bytes, Extent::Full)?;
    println!("decode: {:.1} ms", began.elapsed().as_secs_f64() * 1e3);
    report("client mirror, decoded", &mirror)
}
