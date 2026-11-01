use std::io;
use std::process::ExitCode;

use ko_vt::{Error, Extent, Format, Terminal};
use serde::Serialize;

#[derive(Debug, Serialize)]
struct Decoded {
    sync: bool,
    rows: usize,
    screen: String,
    history: String,
}

fn decoded(full: bool) -> Result<Decoded, Error> {
    let extent = if full { Extent::Full } else { Extent::Screen };
    let terminal = Terminal::decode(&mut io::stdin().lock(), extent)?;
    let history = if full {
        terminal.dump_history(Format::Plain)?
    } else {
        Vec::new()
    };
    Ok(Decoded {
        sync: terminal.mode(2026)?,
        rows: terminal.total_rows()?,
        screen: String::from_utf8_lossy(&terminal.dump(Format::Plain)?).into_owned(),
        history: String::from_utf8_lossy(&history).into_owned(),
    })
}

fn main() -> ExitCode {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    let full = match args.as_slice() {
        [] => false,
        [flag] if flag == "--full" => true,
        _ => {
            eprintln!("usage: decode [--full] < snapshot");
            return ExitCode::from(2);
        }
    };
    let line = decoded(full)
        .map_err(|error| error.to_string())
        .and_then(|decoded| serde_json::to_string(&decoded).map_err(|error| error.to_string()));
    match line {
        Ok(line) => {
            println!("{line}");
            ExitCode::SUCCESS
        }
        Err(message) => {
            eprintln!("decode: {message}");
            ExitCode::FAILURE
        }
    }
}
