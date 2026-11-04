use std::collections::BTreeMap;
use std::fs::{self, File};
use std::io;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::time::Duration;

use ko_sys::event::{Poll, Ready, Timer, Token};
use ko_sys::pid::{Exit, Pid};

use crate::config::{Config, RuntimeIdle, SUN_PATH_MAX};
use crate::ids::{PaneId, PaneToken, RuntimeName};
use crate::protocol::{AbsPath, Error, ErrorKind, ExecRequest, LeadReport, LinkState};
use crate::server::{Listener, Origin, Timing, Verified};

pub(crate) mod command;
pub(crate) mod exec;
pub(crate) mod file;
pub(crate) mod leaving;
pub(crate) mod pane;

use exec::{Helper, Launch, Mode};
use file::{Kind, LoadError, Runtime, Runtimes};
use pane::{directory, socket_path, token_directory, token_path};

const UP_LIMIT: Duration = Duration::from_secs(120);

pub(crate) struct Entry<'a> {
    pub(crate) prefix: &'a [String],
    pub(crate) socket: Option<&'a AbsPath>,
}

impl Runtime {
    pub(crate) fn lead(&self) -> Option<&[String]> {
        match &self.kind {
            Kind::Command(command) => command.lead.as_deref(),
        }
    }

    pub(crate) fn up(&self) -> Option<&[String]> {
        match &self.kind {
            Kind::Command(command) => command.up.as_deref(),
        }
    }

    pub(crate) fn entry(&self) -> Entry<'_> {
        match &self.kind {
            Kind::Command(command) => Entry {
                prefix: &command.prefix,
                socket: command.socket.as_ref(),
            },
        }
    }

    pub(crate) fn exec_launch(
        &self,
        name: &RuntimeName,
        request: &ExecRequest,
    ) -> Result<Launch, String> {
        match &self.kind {
            Kind::Command(command) => command::exec_launch(name, self, command, request),
        }
    }

    pub(crate) fn refused(&self, exit: Exit) -> bool {
        match &self.kind {
            Kind::Command(command) => command::refused(command, exit),
        }
    }
}

#[derive(Debug)]
enum Step {
    Lead(Option<PaneId>),
    Up { helper: Helper, deadline: Timer },
}

#[derive(Debug)]
enum Phase {
    Starting(Step),
    Up,
    Failed(String),
}

#[derive(Debug)]
struct Link {
    settings: Runtime,
    phase: Phase,
    listener: Option<Listener>,
    idle: Timer,
    occupied: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Who {
    Pane(PaneId),
    Exec,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Wait {
    pub(crate) conn: Token,
    pub(crate) who: Who,
}

#[derive(Debug)]
pub(crate) enum Due {
    Other,
    Handled,
    Idle(RuntimeName),
}

#[derive(Debug)]
pub(crate) struct Registry {
    file: PathBuf,
    command_kind: bool,
    idle: RuntimeIdle,
    root: PathBuf,
    env: Vec<Vec<u8>>,
    links: BTreeMap<RuntimeName, Link>,
    waits: Vec<(RuntimeName, Wait)>,
    dying: Vec<Pid>,
}

fn last_line(bytes: &[u8]) -> Option<String> {
    String::from_utf8_lossy(bytes)
        .lines()
        .map(str::trim)
        .rfind(|line| !line.is_empty())
        .map(str::to_owned)
}

fn exit_text(step: &str, exit: Exit) -> String {
    match exit {
        Exit::Exited(code) => format!("the {step} step exited with status {code}"),
        Exit::Signaled(signal) => format!("the {step} step ended with signal {signal}"),
    }
}

fn bind(root: &Path, name: &RuntimeName, poll: &mut Poll) -> Result<Listener, String> {
    let socket = socket_path(root, name);
    if socket.as_os_str().len() > SUN_PATH_MAX {
        return Err(format!(
            "runtime socket path exceeds {SUN_PATH_MAX} bytes; set KO_STATE_DIR to a shorter path"
        ));
    }
    let failed = |what: &str| {
        let what = what.to_owned();
        move |error: io::Error| format!("{what}: {error}")
    };
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o755)
        .create(directory(root, name))
        .map_err(failed("runtime directory"))?;
    match fs::remove_file(&socket) {
        Err(error) if error.kind() != io::ErrorKind::NotFound => {
            return Err(failed("runtime socket")(error));
        }
        _ => {}
    }
    let socket_listener = UnixListener::bind(&socket).map_err(failed("runtime socket"))?;
    fs::set_permissions(&socket, fs::Permissions::from_mode(0o666))
        .map_err(failed("runtime socket"))?;
    Listener::new(
        socket_listener,
        poll,
        Timing::DEFAULT.accept_retry,
        Origin::Runtime(name.clone()),
    )
    .map_err(failed("runtime socket"))
}

fn stop_helper(poll: &mut Poll, helper: &mut Helper, dying: &mut Vec<Pid>) {
    helper.release(poll);
    if helper.reap().is_none() {
        dying.push(helper.pid());
    }
}

impl Registry {
    pub(crate) fn new(config: &Config) -> Registry {
        Registry {
            file: config.runtimes.file.clone(),
            command_kind: config.runtimes.command_kind,
            idle: config.runtimes.idle,
            root: config.dir.join("runtimes"),
            env: config.env.clone(),
            links: BTreeMap::new(),
            waits: Vec::new(),
            dying: Vec::new(),
        }
    }

    pub(crate) fn root(&self) -> &Path {
        &self.root
    }

    pub(crate) fn take_dying(&mut self) -> Vec<Pid> {
        std::mem::take(&mut self.dying)
    }

    fn load(&self) -> Result<Runtimes, Error> {
        file::load(&self.file, self.command_kind).map_err(|error| match error {
            LoadError::Invalid(message) => Error::new(ErrorKind::Invalid, message),
            LoadError::Io(message) => Error::new(ErrorKind::Io, message),
        })
    }

    fn missing(&self, name: &RuntimeName) -> Error {
        Error::new(
            ErrorKind::Missing,
            format!("no runtime {name} in {}", self.file.display()),
        )
    }

    pub(crate) fn settings(&self, name: &RuntimeName) -> Result<Runtime, Error> {
        if let Some(link) = self.links.get(name)
            && matches!(link.phase, Phase::Starting(_) | Phase::Up)
        {
            return Ok(link.settings.clone());
        }
        self.load()?
            .runtimes
            .remove(name)
            .ok_or_else(|| self.missing(name))
    }

    pub(crate) fn known(&self) -> Result<Vec<(RuntimeName, Runtime)>, Error> {
        let mut known = self.load()?.runtimes;
        for (name, link) in &self.links {
            if matches!(link.phase, Phase::Starting(_) | Phase::Up) {
                known.insert(name.clone(), link.settings.clone());
            }
        }
        Ok(known.into_iter().collect())
    }

    pub(crate) fn state(&self, name: &RuntimeName) -> LinkState {
        match self.links.get(name).map(|link| &link.phase) {
            None => LinkState::Down,
            Some(Phase::Starting(_)) => LinkState::Starting,
            Some(Phase::Up) => LinkState::Up,
            Some(Phase::Failed(message)) => LinkState::Failed {
                message: message.clone(),
            },
        }
    }

    pub(crate) fn is_live(&self, name: &RuntimeName) -> bool {
        self.links.contains_key(name)
    }

    pub(crate) fn begin(&mut self, poll: &mut Poll, name: &RuntimeName, settings: Runtime) {
        if matches!(
            self.links.get(name).map(|link| &link.phase),
            Some(Phase::Starting(_) | Phase::Up)
        ) {
            return;
        }
        if let Some(old) = self.links.remove(name) {
            poll.free(old.idle);
        }
        let (phase, listener) = match bind(&self.root, name, poll) {
            Ok(listener) => (Phase::Up, Some(listener)),
            Err(message) => (Phase::Failed(message), None),
        };
        let bound = listener.is_some();
        self.links.insert(
            name.clone(),
            Link {
                settings,
                phase,
                listener,
                idle: poll.timer(),
                occupied: true,
            },
        );
        if bound {
            self.start_steps(poll, name, true);
        }
    }

    fn start_steps(&mut self, poll: &mut Poll, name: &RuntimeName, from_start: bool) {
        let Some(link) = self.links.get(name) else {
            return;
        };
        let phase = if from_start && link.settings.lead().is_some() {
            Phase::Starting(Step::Lead(None))
        } else if let Some(argv) = link.settings.up() {
            match self.spawn_up(poll, argv) {
                Ok(step) => Phase::Starting(step),
                Err(error) => {
                    let message = format!("the up step did not start: {error}");
                    return self.fail(poll, name, message);
                }
            }
        } else {
            Phase::Up
        };
        if let Some(link) = self.links.get_mut(name) {
            link.phase = phase;
        }
    }

    fn spawn_up(&self, poll: &mut Poll, argv: &[String]) -> io::Result<Step> {
        let (program, args) = argv
            .split_first()
            .ok_or_else(|| io::Error::from(io::ErrorKind::InvalidInput))?;
        let launch = Launch {
            program: PathBuf::from(program),
            args: args.to_vec(),
            dir: None,
            env: self.env.clone(),
        };
        let helper = exec::spawn(poll, &launch, Mode::Step)?;
        let deadline = poll.timer();
        poll.start(deadline, UP_LIMIT, None)?;
        Ok(Step::Up { helper, deadline })
    }

    fn fail(&mut self, poll: &mut Poll, name: &RuntimeName, message: String) {
        let Registry {
            links, dying, root, ..
        } = self;
        let Some(link) = links.get_mut(name) else {
            return;
        };
        Registry::end(poll, root, name, link, dying);
        link.phase = Phase::Failed(message);
    }

    fn end(
        poll: &mut Poll,
        root: &Path,
        name: &RuntimeName,
        link: &mut Link,
        dying: &mut Vec<Pid>,
    ) {
        if let Phase::Starting(Step::Up { helper, deadline }) = &mut link.phase {
            poll.free(*deadline);
            stop_helper(poll, helper, dying);
        }
        if let Some(listener) = link.listener.take() {
            listener.close(poll);
        }
        let _ = fs::remove_file(socket_path(root, name));
        let _ = fs::remove_dir_all(token_directory(root, name));
        poll.stop(link.idle);
    }

    pub(crate) fn wait(&mut self, name: &RuntimeName, wait: Wait) {
        self.waits.push((name.clone(), wait));
    }

    pub(crate) fn forget_wait(&mut self, conn: Token) {
        self.waits.retain(|(_, wait)| wait.conn != conn);
    }

    pub(crate) fn expire_pane_wait(&mut self, conn: Token) -> Option<RuntimeName> {
        let at = self
            .waits
            .iter()
            .position(|(_, wait)| wait.conn == conn && matches!(wait.who, Who::Pane(_)))?;
        Some(self.waits.swap_remove(at).0)
    }

    pub(crate) fn needs_pane(&self, name: &RuntimeName) -> bool {
        matches!(
            self.links.get(name).map(|link| &link.phase),
            Some(Phase::Starting(Step::Lead(None)))
        )
    }

    pub(crate) fn elect(&mut self, name: &RuntimeName, pane: PaneId) -> Option<Vec<String>> {
        let link = self.links.get_mut(name)?;
        let Phase::Starting(Step::Lead(leader @ None)) = &mut link.phase else {
            return None;
        };
        *leader = Some(pane);
        link.settings.lead().map(<[String]>::to_vec)
    }

    pub(crate) fn report_lead(
        &mut self,
        poll: &mut Poll,
        name: &RuntimeName,
        pane: PaneId,
        report: LeadReport,
    ) -> Result<(), Error> {
        let leading = matches!(
            self.links.get(name).map(|link| &link.phase),
            Some(Phase::Starting(Step::Lead(Some(leader)))) if *leader == pane
        );
        if !leading {
            return Err(Error::new(
                ErrorKind::Refused,
                format!("{pane} is not the pane that leads the start of runtime {name}"),
            ));
        }
        if report.exit == 0 {
            self.start_steps(poll, name, false);
        } else {
            let message = last_line(report.stderr.as_bytes())
                .unwrap_or_else(|| exit_text("lead", Exit::Exited(report.exit)));
            self.fail(poll, name, message);
        }
        Ok(())
    }

    pub(crate) fn pane_ended(&mut self, poll: &mut Poll, pane: PaneId) {
        let leading: Vec<RuntimeName> = self
            .links
            .iter()
            .filter(|(_, link)| {
                matches!(&link.phase, Phase::Starting(Step::Lead(Some(leader))) if *leader == pane)
            })
            .map(|(name, _)| name.clone())
            .collect();
        for name in leading {
            self.fail(
                poll,
                &name,
                "the leading pane ended before it reported the lead step".to_owned(),
            );
        }
    }

    pub(crate) fn take_settled(&mut self) -> Vec<(RuntimeName, Wait, LinkState)> {
        let waits = std::mem::take(&mut self.waits);
        let (done, pending): (Vec<_>, Vec<_>) = waits
            .into_iter()
            .partition(|(name, _)| !matches!(self.state(name), LinkState::Starting));
        self.waits = pending;
        done.into_iter()
            .map(|(name, wait)| {
                let state = self.state(&name);
                (name, wait, state)
            })
            .collect()
    }

    pub(crate) fn down(&mut self, poll: &mut Poll, name: &RuntimeName) {
        let Registry {
            links, dying, root, ..
        } = self;
        let Some(mut link) = links.remove(name) else {
            return;
        };
        Registry::end(poll, root, name, &mut link, dying);
        poll.free(link.idle);
    }

    pub(crate) fn waiters_of(&mut self, name: &RuntimeName) -> Vec<Wait> {
        let (mine, rest): (Vec<_>, Vec<_>) = std::mem::take(&mut self.waits)
            .into_iter()
            .partition(|(waiting, _)| waiting == name);
        self.waits = rest;
        mine.into_iter().map(|(_, wait)| wait).collect()
    }

    pub(crate) fn remove_directory(&self, name: &RuntimeName) {
        let _ = fs::remove_dir_all(directory(&self.root, name));
    }

    pub(crate) fn write_token(
        &self,
        name: &RuntimeName,
        pane: PaneId,
        token: &PaneToken,
    ) -> io::Result<()> {
        use std::io::Write;
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(token_directory(&self.root, name))?;
        let path = token_path(&self.root, name, pane);
        match fs::remove_file(&path) {
            Err(error) if error.kind() != io::ErrorKind::NotFound => return Err(error),
            _ => {}
        }
        let mut file = File::options()
            .write(true)
            .create_new(true)
            .custom_flags(libc::O_NOFOLLOW)
            .mode(0o600)
            .open(path)?;
        file.write_all(token.to_string().as_bytes())
    }

    pub(crate) fn remove_token(&self, name: &RuntimeName, pane: PaneId) {
        let _ = fs::remove_file(token_path(&self.root, name, pane));
    }

    pub(crate) fn occupy(&mut self, poll: &mut Poll, name: &RuntimeName, occupied: bool) {
        let RuntimeIdle::After(after) = self.idle else {
            return;
        };
        let Some(link) = self
            .links
            .get_mut(name)
            .filter(|link| link.listener.is_some() && link.occupied != occupied)
        else {
            return;
        };
        link.occupied = occupied;
        if occupied {
            poll.stop(link.idle);
        } else {
            let _ = poll.start(link.idle, after, None);
        }
    }

    pub(crate) fn accept(
        &self,
        poll: &mut Poll,
        ready: Ready,
        accepted: &mut Vec<Verified>,
    ) -> bool {
        let Some(listener) = self
            .links
            .values()
            .filter_map(|link| link.listener.as_ref())
            .find(|listener| listener.token() == ready.token)
        else {
            return false;
        };
        if poll.wants(ready).read {
            let _ = listener.accept(poll, accepted);
        }
        true
    }

    pub(crate) fn helper_ready(&mut self, poll: &mut Poll, ready: Ready) -> bool {
        let helper = self
            .links
            .values_mut()
            .find_map(|link| match &mut link.phase {
                Phase::Starting(Step::Up { helper, .. }) if helper.owns(ready.token).is_some() => {
                    Some(helper)
                }
                _ => None,
            });
        match helper {
            Some(helper) => {
                helper.collect(poll);
                true
            }
            None => false,
        }
    }

    pub(crate) fn due(&mut self, poll: &mut Poll, timer: Timer) -> Due {
        if let Some(listener) = self
            .links
            .values()
            .filter_map(|link| link.listener.as_ref())
            .find(|listener| listener.resume_timer() == timer)
        {
            listener.resume(poll);
            return Due::Handled;
        }
        if let Some(name) = self
            .links
            .iter()
            .find(|(_, link)| link.idle == timer)
            .map(|(name, _)| name.clone())
        {
            return Due::Idle(name);
        }
        let late = self
            .links
            .iter()
            .find_map(|(name, link)| match &link.phase {
                Phase::Starting(Step::Up { deadline, .. }) if *deadline == timer => {
                    Some(name.clone())
                }
                _ => None,
            });
        match late {
            Some(name) => {
                self.fail(poll, &name, "the up step took too long".to_owned());
                Due::Handled
            }
            None => Due::Other,
        }
    }

    pub(crate) fn reap(&mut self, poll: &mut Poll) {
        let ended: Vec<RuntimeName> = self
            .links
            .iter_mut()
            .filter_map(|(name, link)| match &mut link.phase {
                Phase::Starting(Step::Up { helper, .. }) => helper.reap().map(|_| name.clone()),
                _ => None,
            })
            .collect();
        for name in ended {
            let Some(link) = self.links.get_mut(&name) else {
                continue;
            };
            let Phase::Starting(Step::Up {
                mut helper,
                deadline,
            }) = std::mem::replace(&mut link.phase, Phase::Up)
            else {
                continue;
            };
            poll.free(deadline);
            helper.collect(poll);
            helper.release(poll);
            match helper.exit() {
                Some(Exit::Exited(0)) => {}
                Some(exit) => {
                    let message = last_line(helper.tail()).unwrap_or_else(|| exit_text("up", exit));
                    self.fail(poll, &name, message);
                }
                None => self.fail(poll, &name, "the up step vanished".to_owned()),
            }
        }
    }

    pub(crate) fn shutdown(&mut self, poll: &mut Poll) {
        let names: Vec<RuntimeName> = self.links.keys().cloned().collect();
        for name in names {
            self.down(poll, &name);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_message_of_a_failed_step_is_the_last_line_that_says_something() {
        assert_eq!(last_line(b"a\nboom\n\n  \n"), Some("boom".to_owned()));
        assert_eq!(last_line(b"only"), Some("only".to_owned()));
        assert_eq!(last_line(b"\n \n"), None);
        assert_eq!(last_line(b""), None);
    }
}
