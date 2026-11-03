#![allow(clippy::print_stdout, clippy::print_stderr)]

mod alloc;
mod client;
mod modes;
mod terminal;

use std::process::ExitCode;

#[global_allocator]
static ALLOCATOR: alloc::Counting = alloc::Counting;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    let result = match args.as_slice() {
        ["throughput", "writev", bytes, coalesce_ms, streams @ ..] => {
            modes::throughput(bytes, coalesce_ms, streams)
        }
        ["flood", panes, views, bytes, window, streams @ ..] => {
            modes::flood(panes, views, bytes, window, streams)
        }
        ["latency", "writev", count, "2"] => modes::latency(count),
        ["snapshot", "writev", lines] => modes::snapshot(lines),
        ["cpu-check"] => modes::cpu_check(),
        ["mirror", iterations, streams @ ..] => terminal::mirror(iterations, streams),
        ["usage", lines, cols, rows] => terminal::usage(lines, cols, rows),
        _ => {
            eprintln!(
                "usage: ko-bench throughput|latency|snapshot writev ... | flood ... | cpu-check | mirror ITERATIONS STREAM... | usage LINES COLS ROWS"
            );
            return ExitCode::from(2);
        }
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("ko-bench: {message}");
            ExitCode::FAILURE
        }
    }
}
