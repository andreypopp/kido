use std::fmt;
use std::fs::{self, File, OpenOptions};

use std::os::fd::AsFd;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use ko_config::ssh_args::has_syntax;
use ko_server::config::{self, Dir};
use ko_server::ssh::{self, QueryFailure, control_args};
use ko_sys::fd::{self, Want};
use ko_sys::pid::{Exit, Pid, Waited};
use ko_sys::signal::{Signal, Signals};
use ko_sys::spawn::{self, Env};

const FIRST_MASTER_WITHIN: Duration = Duration::from_secs(60);
const MASTER_WITHIN: Duration = Duration::from_secs(15);
const COMMAND_WITHIN: Duration = Duration::from_secs(20);
const STOP_WITHIN: Duration = Duration::from_secs(2);
const TICK: Duration = Duration::from_millis(5);
const LOG_TAIL: usize = 400;

#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    Dir(String),
    DirTooLong(String),
    Ssh(String),
    Master { host: String, log: String },
    Timeout { host: String },
    NoRemoteKo { host: String },
    Query { host: String, message: String },
    Forward(String),
    Refused { host: String },
    NoServer { host: String },
    Interrupted,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Dir(message) | Error::DirTooLong(message) | Error::Ssh(message) => {
                f.write_str(message)
            }
            Error::Master { host, log } if log.is_empty() => write!(f, "ssh to {host} failed"),
            Error::Master { host, log } => write!(f, "ssh to {host} failed: {log}"),
            Error::Timeout { host } => write!(f, "ssh to {host} did not answer in time"),
            Error::NoRemoteKo { host } => f.write_str(&ssh::no_remote_ko(host)),
            Error::Query { host, message } => {
                write!(f, "cannot find the ko socket on {host}: {message}")
            }
            Error::Forward(message) => write!(f, "ssh cannot forward the socket: {message}"),
            Error::Refused { host } => f.write_str(&ssh::forwarding_refused(host)),
            Error::NoServer { host } => write!(
                f,
                "no ko server is running on {host}; start one there with: ssh {host} ko server"
            ),
            Error::Interrupted => f.write_str("interrupted"),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Progress {
    Pending(Instant),
    Up,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Stage {
    Down,
    Master(Instant),
    Query(Pid, Instant),
    Forward(Pid, Instant),
    Up,
}

#[derive(Debug)]
pub struct Remote {
    host: String,
    ssh: PathBuf,
    dir: PathBuf,
    remote_socket: Option<String>,
    master: Option<Pid>,
    stage: Stage,
    interactive: bool,
}

fn utf8(path: &Path) -> &str {
    path.to_str().unwrap_or_default()
}

fn master_args(ctl: &Path, host: &str, batch: bool) -> Vec<String> {
    let mut args: Vec<String> = [
        "-M",
        "-N",
        "-T",
        "-o",
        &format!("ControlPath={}", utf8(ctl)),
        "-o",
        "ControlMaster=yes",
        "-o",
        "ControlPersist=no",
    ]
    .map(str::to_owned)
    .to_vec();
    for option in ssh::MASTER_OPTIONS
        .into_iter()
        .chain(["StreamLocalBindUnlink=yes"])
    {
        args.extend(["-o".to_owned(), option.to_owned()]);
    }
    if batch {
        args.extend(["-o", "BatchMode=yes"].map(str::to_owned));
    }
    args.push(host.to_owned());
    args
}

fn forward_args(ctl: &Path, local: &Path, remote: &str, host: &str) -> Vec<String> {
    let spec = format!("{}:{remote}", utf8(local));
    control_args(ctl, &["-O", "forward", "-L", &spec], host)
}

fn remote_ko_args(ctl: &Path, host: &str, ko: &[&str]) -> Vec<String> {
    let mut args = control_args(
        ctl,
        &["-T", "-o", "RemoteCommand=none", "-o", "BatchMode=yes"],
        host,
    );
    args.push("ko".to_owned());
    args.extend(ko.iter().copied().map(str::to_owned));
    args
}

pub(crate) fn remote_socket(
    host: &str,
    exit: Exit,
    stdout: &[u8],
    stderr: &[u8],
) -> Result<String, Error> {
    let query = |message: String| Error::Query {
        host: host.to_owned(),
        message,
    };
    match ssh::query_failure(exit, stderr) {
        None => {
            let text = String::from_utf8_lossy(stdout);
            ssh::reported_path(&text)
                .map(str::to_owned)
                .ok_or_else(|| query(format!("invalid socket path {:?}", text.trim())))
        }
        Some(QueryFailure::NoKo) => Err(Error::NoRemoteKo {
            host: host.to_owned(),
        }),
        Some(QueryFailure::Ssh(message)) => Err(Error::Ssh(message)),
        Some(QueryFailure::Exit { code, message }) => {
            Err(query(format!("{message} (exit {code})")))
        }
        Some(QueryFailure::Signal(signal)) => Err(query(format!("ssh died of signal {signal}"))),
    }
}

pub(crate) fn unreachable(host: &str, remote_answers: bool) -> Error {
    let host = host.to_owned();
    if remote_answers {
        Error::Refused { host }
    } else {
        Error::NoServer { host }
    }
}

fn check_host(host: &str) -> Result<(), Error> {
    if host.is_empty() || host.starts_with('-') {
        Err(Error::Ssh(format!("invalid host {host:?}")))
    } else {
        Ok(())
    }
}

fn private_dir(base: &Path, name: &str) -> Result<PathBuf, Error> {
    let dir = base.join(name);
    let text = dir
        .to_str()
        .ok_or_else(|| Error::Dir("the private directory is not UTF-8".to_owned()))?;
    if text.len() > ssh::MAX_DIR {
        return Err(Error::DirTooLong(format!(
            "private directory {text} exceeds {} bytes",
            ssh::MAX_DIR
        )));
    }
    if text.contains(',') || has_syntax(text) {
        return Err(Error::Dir(format!(
            "private directory {text} contains a comma, a colon or a percent sign"
        )));
    }
    config::socket(Dir::Create, &dir)
        .map_err(|message| {
            let _ = fs::remove_dir(&dir);
            Error::Dir(format!("private directory {text}: {message}"))
        })
        .map(|_| dir)
}

fn create_dir(state: &Path) -> Result<PathBuf, Error> {
    let tag = ko_sys::entropy::hex(4).map_err(|error| Error::Dir(error.to_string()))?;
    match private_dir(state, &format!("remote-{tag}")) {
        Err(Error::DirTooLong(_)) => private_dir(
            Path::new("/tmp"),
            &format!("ko-remote-{}-{tag}", ko_sys::sock::uid()),
        ),
        other => other,
    }
}

fn ended_within(pid: Pid, within: Duration) -> Option<Exit> {
    let deadline = Instant::now() + within;
    loop {
        match pid.try_wait() {
            Ok(Waited::Running) if Instant::now() < deadline => std::thread::sleep(TICK),
            Ok(Waited::Ended(exit)) => return Some(exit),
            _ => return None,
        }
    }
}

fn kill(pid: Pid) {
    let _ = pid.signal(Signal::Kill);
    let _ = pid.wait();
}

impl Remote {
    pub fn open(host: &str, ssh: &Path, state: &Path, signals: &Signals) -> Result<Remote, Error> {
        check_host(host)?;
        let mut remote = Remote {
            host: host.to_owned(),
            ssh: ssh.to_path_buf(),
            dir: create_dir(state)?,
            remote_socket: None,
            master: None,
            stage: Stage::Down,
            interactive: true,
        };
        while let Progress::Pending(until) = remote.advance()? {
            let left = until.saturating_duration_since(Instant::now());
            fd::wait(signals.fd(), Want::Read, None, Some(left))
                .map_err(|error| Error::Ssh(error.to_string()))?;
            let mut pending = Vec::new();
            signals
                .take(&mut pending)
                .map_err(|error| Error::Ssh(error.to_string()))?;
            if pending.iter().any(|signal| {
                matches!(
                    signal,
                    Signal::Hup | Signal::Int | Signal::Term | Signal::Quit
                )
            }) {
                return Err(Error::Interrupted);
            }
        }
        Ok(remote)
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    pub fn socket(&self) -> PathBuf {
        self.dir.join("socket")
    }

    pub fn host(&self) -> &str {
        &self.host
    }

    fn ctl(&self) -> PathBuf {
        self.dir.join(ssh::CONTROL)
    }

    fn log(&self) -> String {
        let text = fs::read(self.dir.join("master.log")).unwrap_or_default();
        let text = String::from_utf8_lossy(&text);
        let text = text.trim();
        let skip = text.len().saturating_sub(LOG_TAIL);
        text.get(text.ceil_char_boundary(skip)..)
            .unwrap_or_default()
            .to_owned()
    }

    fn master_running(&mut self) -> bool {
        let Some(master) = self.master else {
            return false;
        };
        if matches!(master.try_wait(), Ok(Waited::Running)) {
            true
        } else {
            self.master = None;
            false
        }
    }

    pub fn lost(&mut self) -> bool {
        self.stage == Stage::Up && !self.master_running()
    }

    fn scratch(&self, name: &str) -> Result<File, Error> {
        OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(self.dir.join(name))
            .map_err(|error| Error::Ssh(error.to_string()))
    }

    fn spawn_ssh(&self, args: &[String], out: &File, err: &File) -> Result<Pid, Error> {
        let null = File::open("/dev/null").map_err(|error| Error::Ssh(error.to_string()))?;
        let args: Vec<&str> = args.iter().map(String::as_str).collect();
        spawn::program(
            &self.ssh,
            &args,
            &[(null.as_fd(), 0), (out.as_fd(), 1), (err.as_fd(), 2)],
            Env::Inherit,
            None,
        )
        .map_err(|error| Error::Ssh(format!("cannot run {}: {error}", self.ssh.display())))
    }

    fn spawn_step(&self, args: &[String]) -> Result<Pid, Error> {
        self.spawn_ssh(args, &self.scratch("out")?, &self.scratch("err")?)
    }

    fn step_output(&self, name: &str) -> Vec<u8> {
        fs::read(self.dir.join(name)).unwrap_or_default()
    }

    fn stop_master(&mut self) {
        let Some(master) = self.master.take() else {
            return;
        };
        let _ = master.signal(Signal::Term);
        if ended_within(master, STOP_WITHIN).is_none() {
            kill(master);
        }
    }

    fn start_master(&mut self) -> Result<(), Error> {
        for stale in [ssh::CONTROL, "socket"] {
            let _ = fs::remove_file(self.dir.join(stale));
        }
        let log = self.scratch("master.log")?;
        let args = master_args(&self.ctl(), &self.host, !self.interactive);
        self.master = Some(self.spawn_ssh(&args, &log, &log)?);
        let within = if self.interactive {
            FIRST_MASTER_WITHIN
        } else {
            MASTER_WITHIN
        };
        self.stage = Stage::Master(Instant::now() + within);
        Ok(())
    }

    fn retry_forward(&mut self, error: Error) -> Error {
        self.stage = Stage::Master(Instant::now() + MASTER_WITHIN);
        error
    }

    fn start_step(&mut self) -> Result<Progress, Error> {
        let deadline = Instant::now() + COMMAND_WITHIN;
        let (args, query) = match &self.remote_socket {
            Some(remote) => (
                forward_args(&self.ctl(), &self.socket(), remote, &self.host),
                false,
            ),
            None => (
                remote_ko_args(&self.ctl(), &self.host, &["server", "--print-socket"]),
                true,
            ),
        };
        let child = self.spawn_step(&args).map_err(|e| self.retry_forward(e))?;
        self.stage = if query {
            Stage::Query(child, deadline)
        } else {
            Stage::Forward(child, deadline)
        };
        Ok(Progress::Pending(deadline))
    }

    // Never blocks: it reaps what has ended and says when to call it again. A SIGCHLD calls it
    // earlier.
    pub fn advance(&mut self) -> Result<Progress, Error> {
        if self.stage == Stage::Up && !self.master_running() {
            self.stage = Stage::Down;
        }
        let now = Instant::now();
        match self.stage {
            Stage::Up => Ok(Progress::Up),
            Stage::Down => {
                self.start_master()?;
                Ok(Progress::Pending(now + TICK))
            }
            Stage::Master(deadline) => {
                if !self.master_running() {
                    self.stage = Stage::Down;
                    return Err(Error::Master {
                        host: self.host.clone(),
                        log: self.log(),
                    });
                }
                if self.ctl().exists() {
                    self.start_step()
                } else if now >= deadline {
                    self.stop_master();
                    self.stage = Stage::Down;
                    Err(Error::Timeout {
                        host: self.host.clone(),
                    })
                } else {
                    Ok(Progress::Pending(deadline.min(now + TICK)))
                }
            }
            Stage::Query(child, deadline) | Stage::Forward(child, deadline) => {
                let exit = match child.try_wait() {
                    Ok(Waited::Ended(exit)) => exit,
                    Ok(Waited::Running) if now < deadline => {
                        return Ok(Progress::Pending(deadline));
                    }
                    Ok(Waited::Running) => {
                        kill(child);
                        return Err(self.retry_forward(Error::Timeout {
                            host: self.host.clone(),
                        }));
                    }
                    _ => return Err(self.retry_forward(Error::Ssh("ssh was reaped".to_owned()))),
                };
                let stderr = self.step_output("err");
                if matches!(self.stage, Stage::Query(..)) {
                    let found = remote_socket(&self.host, exit, &self.step_output("out"), &stderr)
                        .map_err(|e| self.retry_forward(e))?;
                    self.remote_socket = Some(found);
                    self.start_step()
                } else if exit == Exit::Exited(0) {
                    self.stage = Stage::Up;
                    self.interactive = false;
                    Ok(Progress::Up)
                } else {
                    let message = String::from_utf8_lossy(&stderr).trim().to_owned();
                    Err(self.retry_forward(Error::Forward(message)))
                }
            }
        }
    }

    // After a request through the forward failed. It blocks, and only for the commands that
    // run before the screen exists or after it is gone.
    pub fn unreachable(&self) -> Error {
        let version = remote_ko_args(&self.ctl(), &self.host, &["api", "/version"]);
        let answers = match self.spawn_step(&version) {
            Ok(child) => match ended_within(child, COMMAND_WITHIN) {
                Some(exit) => exit == Exit::Exited(0),
                None => {
                    kill(child);
                    false
                }
            },
            Err(_) => false,
        };
        unreachable(&self.host, answers)
    }
}

impl Drop for Remote {
    fn drop(&mut self) {
        if let Stage::Query(child, _) | Stage::Forward(child, _) = self.stage {
            kill(child);
        }
        self.stop_master();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn scratch(name: &str) -> PathBuf {
        let dir = PathBuf::from(format!("/tmp/ko-remote-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn the_ssh_arguments_of_each_step() {
        let ctl = Path::new("/d/ctl");
        let master = |batch| master_args(ctl, "h", batch).join(" ");
        assert_eq!(
            master(false),
            "-M -N -T -o ControlPath=/d/ctl -o ControlMaster=yes -o ControlPersist=no -o ExitOnForwardFailure=yes -o ServerAliveInterval=5 -o ServerAliveCountMax=3 -o StreamLocalBindUnlink=yes h"
        );
        assert_eq!(
            master(true),
            "-M -N -T -o ControlPath=/d/ctl -o ControlMaster=yes -o ControlPersist=no -o ExitOnForwardFailure=yes -o ServerAliveInterval=5 -o ServerAliveCountMax=3 -o StreamLocalBindUnlink=yes -o BatchMode=yes h"
        );
        assert_eq!(
            forward_args(ctl, Path::new("/d/socket"), "/r/socket", "h").join(" "),
            "-S /d/ctl -O forward -L /d/socket:/r/socket h"
        );
        assert_eq!(
            remote_ko_args(ctl, "h", &["server", "--print-socket"]).join(" "),
            "-S /d/ctl -T -o RemoteCommand=none -o BatchMode=yes h ko server --print-socket"
        );
    }

    #[test]
    fn the_remote_query_maps_its_failures() {
        let ok = |out: &[u8]| remote_socket("h", Exit::Exited(0), out, b"");
        assert_eq!(
            ok(b"/home/u/.local/state/ko/socket\n"),
            Ok("/home/u/.local/state/ko/socket".to_owned())
        );
        for bad in [&b""[..], b"relative/socket", b"/a:b/socket", b"/a%h/socket"] {
            assert!(matches!(ok(bad), Err(Error::Query { .. })), "{bad:?}");
        }
        assert_eq!(
            remote_socket("h", Exit::Exited(127), b"", b"sh: ko: not found"),
            Err(Error::NoRemoteKo {
                host: "h".to_owned()
            })
        );
        assert_eq!(
            remote_socket("h", Exit::Exited(255), b"", b"Permission denied\n"),
            Err(Error::Ssh("Permission denied".to_owned()))
        );
        assert!(
            Error::NoRemoteKo {
                host: "h".to_owned()
            }
            .to_string()
            .contains("ko was not found on h")
        );
    }

    #[test]
    fn a_server_that_answers_on_the_host_but_not_through_the_forward_means_refused_forwarding() {
        let refused = unreachable("h", true);
        let missing = unreachable("h", false);
        assert_eq!(
            refused,
            Error::Refused {
                host: "h".to_owned()
            }
        );
        assert_eq!(
            missing,
            Error::NoServer {
                host: "h".to_owned()
            }
        );
        assert!(
            refused
                .to_string()
                .contains("refuses unix-socket forwarding")
        );
        assert!(missing.to_string().contains("ssh h ko server"));
    }

    #[test]
    fn the_private_directory_is_0700_short_and_removed_with_the_remote() {
        let base = scratch("dir");
        let dir = private_dir(&base, "remote-1").unwrap();
        let mode = fs::metadata(&dir).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o700);
        let long = private_dir(&base, &"x".repeat(ssh::MAX_DIR)).unwrap_err();
        assert!(matches!(&long, Error::DirTooLong(_)), "{long}");
        let odd = private_dir(&base, "a:b").unwrap_err();
        assert!(matches!(odd, Error::Dir(_)));
        let remote = Remote {
            host: "h".to_owned(),
            ssh: PathBuf::from("/nonexistent/ssh"),
            dir: dir.clone(),
            remote_socket: None,
            master: None,
            stage: Stage::Down,
            interactive: false,
        };
        drop(remote);
        assert!(!dir.exists());
        fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn a_state_directory_that_is_too_long_falls_back_to_a_short_path() {
        let base = scratch("long");
        let state = base.join("y".repeat(90));
        let dir = create_dir(&state).unwrap();
        assert!(dir.starts_with("/tmp"), "{}", dir.display());
        assert!(!state.exists());
        fs::remove_dir_all(dir).unwrap();
        fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn a_host_that_looks_like_an_option_is_refused() {
        assert!(matches!(check_host("-oProxyCommand=x"), Err(Error::Ssh(_))));
        assert!(matches!(check_host(""), Err(Error::Ssh(_))));
        assert_eq!(check_host("user@host"), Ok(()));
    }
}
