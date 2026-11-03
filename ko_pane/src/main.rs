use std::io::Write;
use std::process::ExitCode;

use ko_pane::pane::Pane;
use ko_pane::run::{Outcome, run};
use ko_pane_wire::ring::Writer;
use ko_sys::fd;
use ko_sys::signal::{Signal, Signals};

fn main() -> ExitCode {
    let Some(mut pane) = start() else {
        return ExitCode::from(2);
    };
    let outcome = run(&mut pane);
    pane.finish();
    match outcome {
        Outcome::Stopped => ExitCode::SUCCESS,
        Outcome::Failed(failure) => {
            let _ = writeln!(std::io::stderr().lock(), "pane control failed: {failure}");
            ExitCode::from(2)
        }
    }
}

fn start() -> Option<Pane> {
    let (input, output, ring) = (
        fd::inherited(0).ok()?,
        fd::inherited(1).ok()?,
        fd::inherited(3).ok()?,
    );
    let writer = Writer::open(ring).ok()?;
    fd::set_nonblocking(std::os::fd::AsFd::as_fd(&input)).ok()?;
    fd::set_nonblocking(std::os::fd::AsFd::as_fd(&output)).ok()?;
    let signals = Signals::install(&[Signal::Child, Signal::Hup, Signal::Term]).ok()?;
    let tmpdir = std::env::var("TMPDIR")
        .ok()
        .filter(|dir| !dir.is_empty())
        .unwrap_or_else(|| "/tmp".to_owned());
    Some(Pane::new(writer, input, output, Some(signals), tmpdir))
}
