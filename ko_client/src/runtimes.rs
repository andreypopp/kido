use std::io;
use std::os::fd::AsFd;
use std::path::Path;

use std::time::{Duration, Instant};

use ko_config::values::RuntimeName;
use ko_server::api::{Route, WaitMs};

use ko_server::protocol::{Empty, LeadReport, LinkState, RuntimeWait, STDERR_TAIL};

use ko_server::config::{env_path, program_path};
use ko_sys::fd::{self, Waited, Want};
use ko_sys::pid::{Exit, Pid};
use ko_sys::signal::{Signal, Signals};
use ko_sys::spawn::{self, Env};

use crate::api::{ReplyError, call, describe};
use crate::wire::{self, Caller};

pub(crate) const STILL_STARTING: Duration = Duration::from_secs(120);
const POLL: Duration = Duration::from_secs(30);

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Up {
    Up,
    Failed(String),
    StillStarting,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Shown<'a> {
    Starting,
    Stderr(&'a [u8]),
}

pub fn wait(
    dir: &Path,
    caller: Option<Caller>,
    name: &RuntimeName,
    timeout: Duration,
) -> Result<RuntimeWait, ReplyError> {
    let milliseconds = u64::try_from(timeout.as_millis()).unwrap_or(WaitMs::MAX.get());
    call(
        dir,
        &Route::WaitRuntime {
            name: name.clone(),
            timeout_ms: WaitMs::clamped(milliseconds),
        },
        caller,
        None::<&Empty>,
        timeout.saturating_add(wire::READ_TIMEOUT),
    )
}

pub fn report_lead(
    dir: &Path,
    caller: Option<Caller>,
    name: &RuntimeName,
    report: &LeadReport,
) -> Result<(), ReplyError> {
    call::<Empty>(
        dir,
        &Route::ReportLead { name: name.clone() },
        caller,
        Some(report),
        wire::READ_TIMEOUT,
    )
    .map(|_| ())
}

fn failed(message: impl Into<String>) -> LeadReport {
    LeadReport {
        exit: 1,
        stderr: message.into(),
    }
}

pub(crate) fn drain(
    stderr: &io::PipeReader,
    tail: &mut Vec<u8>,
    shown: &mut impl FnMut(Shown<'_>),
) -> bool {
    let mut buffer = [0u8; 1024];
    for _ in 0..16 {
        match fd::read(stderr.as_fd(), &mut buffer) {
            Ok(count) if count > 0 => {
                let chunk = buffer.get(..count).unwrap_or_default();
                shown(Shown::Stderr(chunk));
                tail.extend_from_slice(chunk);
                let excess = tail.len().saturating_sub(STDERR_TAIL);
                tail.drain(..excess);
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => return true,
            _ => return false,
        }
    }
    true
}

pub(crate) fn exit_code(exit: Exit) -> i32 {
    match exit {
        Exit::Exited(code) => code,
        Exit::Signaled(signal) => 128 + signal,
    }
}

pub(crate) fn lead_step(
    program: &str,
    rest: &[String],
    env: &[Vec<u8>],
) -> io::Result<(Pid, io::PipeReader)> {
    let (reader, writer) = io::pipe()?;
    fd::set_nonblocking(reader.as_fd())?;
    let path = program_path(&String::from_utf8_lossy(env_path(env)), program)
        .ok_or_else(|| io::Error::from(io::ErrorKind::NotFound))?;
    let args: Vec<_> = rest.iter().map(String::as_str).collect();
    let pid = spawn::program(
        &path,
        &args,
        &[
            (io::stdin().as_fd(), 0),
            (io::stdout().as_fd(), 1),
            (writer.as_fd(), 2),
        ],
        Env::Only(env),
        None,
    )?;
    Ok((pid, reader))
}

fn lead(
    argv: &[String],
    deadline: Instant,
    env: &[Vec<u8>],
    shown: &mut impl FnMut(Shown<'_>),
) -> LeadReport {
    let Some((program, rest)) = argv.split_first() else {
        return failed("no lead command");
    };
    let signals = match Signals::install(&[Signal::Child]) {
        Ok(signals) => signals,
        Err(error) => return failed(error.to_string()),
    };
    let (child, stderr) = match lead_step(program, rest, env) {
        Ok(child) => child,
        Err(error) => return failed(format!("{program}: {error}")),
    };
    let (mut tail, mut open) = (Vec::new(), true);
    let status = loop {
        match child.peek_exit() {
            Ok(Some(status)) => {
                let _ = child.wait();
                break status;
            }
            Ok(None) => {}
            Err(error) => return failed(error.to_string()),
        }
        let Some(left) = deadline
            .checked_duration_since(Instant::now())
            .filter(|left| !left.is_zero())
        else {
            let _ = child.signal(Signal::Kill);
            let _ = child.wait();
            return failed("the lead step took too long");
        };
        let mut pending = Vec::new();
        let waited = if open {
            fd::wait(stderr.as_fd(), Want::Read, Some(signals.fd()), Some(left))
        } else {
            fd::wait(signals.fd(), Want::Read, None, Some(left)).map(|waited| match waited {
                Waited::Ready => Waited::Cancelled,
                other => other,
            })
        };
        match waited {
            Ok(Waited::Ready) => open = drain(&stderr, &mut tail, shown),
            Ok(Waited::Cancelled) => {
                let _ = signals.take(&mut pending);
            }
            _ => {}
        }
    };
    drain(&stderr, &mut tail, shown);
    LeadReport {
        exit: exit_code(status),
        stderr: String::from_utf8_lossy(&tail).into_owned(),
    }
}

pub fn bring_up(
    dir: &Path,
    caller: Option<Caller>,
    name: &RuntimeName,
    env: &[Vec<u8>],
    shown: &mut impl FnMut(Shown<'_>),
) -> Up {
    let started = Instant::now();
    let mut announced = false;
    let mut poll = Duration::ZERO;
    loop {
        let reply = match wait(dir, caller.clone(), name, poll) {
            Ok(reply) => reply,
            Err(failure) => return Up::Failed(describe(dir, failure)),
        };
        match reply.state {
            LinkState::Up => return Up::Up,
            LinkState::Failed { message } => return Up::Failed(message),
            LinkState::Down => return Up::Failed("is down".to_owned()),
            LinkState::Starting => {}
        }
        if !announced {
            shown(Shown::Starting);
            announced = true;
        }
        if let Some(argv) = reply.lead {
            let report = lead(&argv, started + STILL_STARTING, env, shown);
            if let Err(failure) = report_lead(dir, caller.clone(), name, &report) {
                return Up::Failed(describe(dir, failure));
            }
        }
        let left = STILL_STARTING.saturating_sub(started.elapsed());
        if left.is_zero() {
            return Up::StillStarting;
        }
        poll = left.min(POLL);
    }
}
