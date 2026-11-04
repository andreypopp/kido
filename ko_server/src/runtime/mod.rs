use std::collections::{BTreeMap, VecDeque};
use std::fs::{self, File};
use std::io;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::time::Duration;

use ko_sys::event::{Poll, Ready, Timer, Token};
use ko_sys::pid::{Exit, Pid, Waited};

use crate::config::{Config, RuntimeIdle, SUN_PATH_MAX};
use crate::ids::{PaneId, PaneToken, RuntimeName};
use crate::protocol::{
    Error, ErrorKind, ExecRequest, LeadReport, LinkState, PathMap, Version, check_version, version,
};
use crate::server::{Listener, Origin, Timing, Verified};

pub(crate) mod command;
pub(crate) mod container;
pub(crate) mod exec;
pub(crate) mod file;
pub(crate) mod leaving;
pub(crate) mod pane;

use exec::{Helper, Launch, Mode};
use file::{Kind, LoadError, Runtime, Runtimes, Volume};
use pane::{directory, socket_path, token_directory, token_path};

const UP_LIMIT: Duration = Duration::from_secs(120);
pub(crate) const CLEANUP_LIMIT: Duration = Duration::from_secs(30);

#[derive(Debug)]
pub(crate) struct Outcome<'a> {
    pub(crate) exit: Exit,
    pub(crate) stdout: &'a [u8],
    pub(crate) tail: &'a [u8],
}

impl Outcome<'_> {
    pub(crate) fn ok(&self) -> bool {
        self.exit == Exit::Exited(0)
    }

    pub(crate) fn failure(&self, step: &str) -> String {
        last_line(self.tail).unwrap_or_else(|| exit_text(step, self.exit))
    }
}

#[derive(Debug)]
pub(crate) enum Next {
    Run(Launch),
    Up,
    Fail(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Cleanup {
    Stop,
    Delete,
}

pub(crate) struct Ctx<'a> {
    pub(crate) name: &'a RuntimeName,
    pub(crate) env: &'a [Vec<u8>],
    pub(crate) socket: &'a Path,
    pub(crate) exe: &'a Path,
}

/// What a kind puts into a pane's program before and after the shared `enter` words.
pub(crate) struct Entry {
    pub(crate) prefix: Vec<Vec<u8>>,
    pub(crate) ko: Vec<u8>,
    pub(crate) socket: Vec<u8>,
    pub(crate) token: Vec<Vec<u8>>,
}

pub(crate) fn version_next(name: &RuntimeName, out: &Outcome<'_>) -> Next {
    if !out.ok() {
        let absent = out.exit == Exit::Exited(127)
            || String::from_utf8_lossy(out.tail).contains("failed to find target executable");
        return Next::Fail(if absent {
            format!("ko is not installed in runtime {name}")
        } else {
            out.failure("version")
        });
    }
    let Ok(inner) = serde_json::from_slice::<Version>(out.stdout) else {
        return Next::Fail(format!("ko version printed no version in runtime {name}"));
    };
    if check_version(Some(&inner.protocol), Some(&inner.vt)).is_ok() {
        return Next::Up;
    }
    let show = |v: &Version| format!("{} (protocol {}, terminal {})", v.build, v.protocol, v.vt);
    Next::Fail(format!(
        "ko in runtime {name} is {}, but this server is {}",
        show(&inner),
        show(&version())
    ))
}

impl Runtime {
    pub(crate) fn lead(&self) -> Option<&[String]> {
        match &self.kind {
            Kind::Command(command) => command.lead.as_deref(),
            Kind::Container(_) => None,
        }
    }

    pub(crate) fn paths(&self) -> Vec<PathMap> {
        let volumes: &[Volume] = match &self.kind {
            Kind::Command(_) => &[],
            Kind::Container(container) => &container.volumes,
        };
        volumes
            .iter()
            .map(|volume| PathMap {
                host: volume.host.clone(),
                runtime: volume.runtime.clone(),
            })
            .chain(self.paths.iter().cloned())
            .collect()
    }

    pub(crate) fn token_file(&self, pane: PaneId) -> String {
        match &self.kind {
            Kind::Command(_) => format!("{pane}.token"),
            Kind::Container(_) => format!("{pane}.env"),
        }
    }

    fn token_text(&self, token: &PaneToken) -> String {
        match &self.kind {
            Kind::Command(_) => token.to_string(),
            Kind::Container(_) => container::token_text(token),
        }
    }

    pub(crate) fn entry(
        &self,
        name: &RuntimeName,
        pane: PaneId,
        (exe, root, env): (&Path, &Path, &[Vec<u8>]),
    ) -> Entry {
        let token = token_path(root, name, self, pane);
        match &self.kind {
            Kind::Command(command) => {
                command::entry(command, (exe, socket_path(root, name)), &token)
            }
            Kind::Container(container) => container::entry(name, container, (env, &token)),
        }
    }

    pub(crate) fn exec_env<'a>(
        &'a self,
        name: &'a RuntimeName,
        request: &'a ExecRequest,
    ) -> BTreeMap<&'a str, &'a str> {
        let mut env: BTreeMap<&str, &str> = self
            .env
            .iter()
            .chain(&request.env)
            .map(|(variable, value)| (variable.as_str(), value.as_str()))
            .collect();
        env.insert("KO_RUNTIME", name.as_str());
        env
    }

    pub(crate) fn exec_launch(
        &self,
        name: &RuntimeName,
        request: &ExecRequest,
        env: &[Vec<u8>],
    ) -> Result<Launch, String> {
        match &self.kind {
            Kind::Command(command) => command::exec_launch(name, self, command, request),
            Kind::Container(container) => {
                container::exec_launch(name, self, container, (request, env))
            }
        }
    }

    pub(crate) fn refused(&self, exit: Exit) -> bool {
        match &self.kind {
            Kind::Command(command) => command::refused(command, exit),
            Kind::Container(_) => false,
        }
    }

    fn cleanup(&self, target: (&RuntimeName, &[Vec<u8>]), what: Cleanup) -> Option<Launch> {
        match &self.kind {
            Kind::Command(_) => None,
            Kind::Container(container) => container::cleanup(container, target, what),
        }
    }
}

const MISMATCH: &str = "the kind of the runtime changed during its start";

#[derive(Debug)]
enum Start {
    Command,
    Container(container::Stage),
}

impl Start {
    fn new(settings: &Runtime) -> Start {
        match &settings.kind {
            Kind::Command(_) => Start::Command,
            Kind::Container(_) => Start::Container(container::Stage::System),
        }
    }

    fn first(&self, settings: &Runtime, cx: &Ctx<'_>) -> Result<Option<Launch>, String> {
        match (&settings.kind, self) {
            (Kind::Command(command), Start::Command) => Ok(command::first(command, cx.env)),
            (Kind::Container(container), Start::Container(_)) => {
                container::first(container, cx).map(Some)
            }
            _ => Err(MISMATCH.to_owned()),
        }
    }

    fn next(&mut self, settings: &Runtime, cx: &Ctx<'_>, out: &Outcome<'_>) -> Next {
        match (&settings.kind, self) {
            (Kind::Command(_), Start::Command) => command::next(out),
            (Kind::Container(container), Start::Container(stage)) => {
                container::next(container, stage, cx, out)
            }
            _ => Next::Fail(MISMATCH.to_owned()),
        }
    }

    fn watch(&self, settings: &Runtime, cx: &Ctx<'_>) -> Result<Option<Launch>, String> {
        match (&settings.kind, self) {
            (Kind::Command(_), Start::Command) => Ok(None),
            (Kind::Container(container), Start::Container(_)) => {
                container::watch(container, cx).map(Some)
            }
            _ => Err(MISMATCH.to_owned()),
        }
    }
}

#[derive(Debug)]
enum Step {
    Lead(Option<PaneId>),
    Cleaning,
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
    start: Start,
    watch: Option<Helper>,
    phase: Phase,
    listener: Option<Listener>,
    idle: Timer,
    occupied: bool,
}

#[derive(Debug, Default)]
struct Pending {
    reaping: Vec<Pid>,
    queue: VecDeque<Launch>,
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
    cleaning: Vec<Pid>,
    cleanups: BTreeMap<RuntimeName, Pending>,
    exe: PathBuf,
}

pub(crate) fn last_line(bytes: &[u8]) -> Option<String> {
    String::from_utf8_lossy(bytes)
        .lines()
        .map(str::trim)
        .rfind(|line| !line.is_empty())
        .map(str::to_owned)
}

pub(crate) fn exit_text(step: &str, exit: Exit) -> String {
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

fn stop_helper(poll: &mut Poll, helper: &mut Helper, dying: &mut Vec<Pid>) -> Option<Pid> {
    helper.release(poll);
    helper.reap().is_none().then(|| {
        dying.push(helper.pid());
        helper.pid()
    })
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
            cleaning: Vec::new(),
            cleanups: BTreeMap::new(),
            exe: config.exe.clone(),
        }
    }

    pub(crate) fn root(&self) -> &Path {
        &self.root
    }

    pub(crate) fn take_dying(&mut self) -> Vec<Pid> {
        std::mem::take(&mut self.dying)
    }

    pub(crate) fn take_cleaning(&mut self) -> Vec<Pid> {
        std::mem::take(&mut self.cleaning)
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
        let start = Start::new(&settings);
        let socket = socket_path(&self.root, name);
        let cx = Ctx {
            name,
            env: &self.env,
            socket: &socket,
            exe: &self.exe,
        };
        let bound = start
            .first(&settings, &cx)
            .and_then(|_| bind(&self.root, name, poll));
        let (phase, listener) = match bound {
            Ok(listener) => (Phase::Up, Some(listener)),
            Err(message) => (Phase::Failed(message), None),
        };
        let started = listener.is_some();
        self.links.insert(
            name.clone(),
            Link {
                settings,
                start,
                watch: None,
                phase,
                listener,
                idle: poll.timer(),
                occupied: true,
            },
        );
        if started && self.cleanups.contains_key(name) {
            if let Some(link) = self.links.get_mut(name) {
                link.phase = Phase::Starting(Step::Cleaning);
            }
        } else if started {
            self.start_steps(poll, name, true);
        }
    }

    fn start_steps(&mut self, poll: &mut Poll, name: &RuntimeName, from_start: bool) {
        let socket = socket_path(&self.root, name);
        let Some(link) = self.links.get(name) else {
            return;
        };
        let cx = Ctx {
            name,
            env: &self.env,
            socket: &socket,
            exe: &self.exe,
        };
        let first = link.start.first(&link.settings, &cx);
        let phase = if from_start && link.settings.lead().is_some() {
            Phase::Starting(Step::Lead(None))
        } else {
            match first {
                Err(message) => return self.fail(poll, name, message),
                Ok(None) => Phase::Up,
                Ok(Some(launch)) => match Registry::spawn_up(poll, &launch) {
                    Ok(step) => Phase::Starting(step),
                    Err(error) => {
                        let message = format!("the up step did not start: {error}");
                        return self.fail(poll, name, message);
                    }
                },
            }
        };
        if let Some(link) = self.links.get_mut(name) {
            link.phase = phase;
        }
    }

    fn spawn_up(poll: &mut Poll, launch: &Launch) -> io::Result<Step> {
        let helper = exec::spawn(poll, launch, Mode::Capture)?;
        let deadline = poll.timer();
        poll.start(deadline, UP_LIMIT, None)?;
        Ok(Step::Up { helper, deadline })
    }

    fn fail(&mut self, poll: &mut Poll, name: &RuntimeName, message: String) {
        let Some(mut link) = self.links.remove(name) else {
            return;
        };
        self.end(poll, name, &mut link, false);
        link.phase = Phase::Failed(message);
        self.links.insert(name.clone(), link);
    }

    fn schedule(&mut self, name: &RuntimeName, launches: Vec<Launch>, reaping: Vec<Pid>) {
        if launches.is_empty() && reaping.is_empty() {
            return;
        }
        let pending = self.cleanups.entry(name.clone()).or_default();
        pending.queue.extend(launches);
        pending.reaping.extend(reaping);
    }

    fn drive(&mut self) {
        for pending in self.cleanups.values_mut() {
            pending
                .reaping
                .retain(|pid| matches!(pid.try_wait(), Ok(Waited::Running)));
            if pending.reaping.is_empty()
                && let Some(launch) = pending.queue.pop_front()
                && let Ok(pid) = exec::detached(&launch)
            {
                pending.reaping.push(pid);
                self.cleaning.push(pid);
            }
        }
        self.cleanups
            .retain(|_, pending| !pending.reaping.is_empty() || !pending.queue.is_empty());
    }

    fn settle(&mut self, poll: &mut Poll) {
        self.drive();
        let ready: Vec<RuntimeName> = self
            .links
            .iter()
            .filter(|(name, link)| {
                matches!(link.phase, Phase::Starting(Step::Cleaning))
                    && !self.cleanups.contains_key(*name)
            })
            .map(|(name, _)| name.clone())
            .collect();
        for name in ready {
            self.start_steps(poll, &name, true);
        }
    }

    fn end(&mut self, poll: &mut Poll, name: &RuntimeName, link: &mut Link, detach: bool) {
        let mut reaping = Vec::new();
        if let Phase::Starting(Step::Up { helper, deadline }) = &mut link.phase {
            poll.free(*deadline);
            reaping.extend(stop_helper(poll, helper, &mut self.dying));
        }
        if let Some(mut watch) = link.watch.take() {
            reaping.extend(stop_helper(poll, &mut watch, &mut self.dying));
        }
        let stop = link
            .settings
            .cleanup((name, &self.env), Cleanup::Stop)
            .into_iter()
            .collect::<Vec<_>>();
        if detach {
            for launch in &stop {
                let _ = exec::detached(launch);
            }
        } else {
            self.schedule(name, stop, reaping);
            self.drive();
        }
        if let Some(listener) = link.listener.take() {
            listener.close(poll);
        }
        let _ = fs::remove_file(socket_path(&self.root, name));
        let _ = fs::remove_dir_all(token_directory(&self.root, name));
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

    pub(crate) fn down(&mut self, poll: &mut Poll, name: &RuntimeName, detach: bool) {
        let Some(mut link) = self.links.remove(name) else {
            return;
        };
        self.end(poll, name, &mut link, detach);
        poll.free(link.idle);
    }

    pub(crate) fn delete(&mut self, name: &RuntimeName, settings: &Runtime) {
        let launches = settings
            .cleanup((name, &self.env), Cleanup::Delete)
            .into_iter()
            .collect();
        self.schedule(name, launches, Vec::new());
        self.drive();
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
        let Some(link) = self.links.get(name) else {
            return Ok(());
        };
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(token_directory(&self.root, name))?;
        let path = token_path(&self.root, name, &link.settings, pane);
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
        file.write_all(link.settings.token_text(token).as_bytes())
    }

    pub(crate) fn remove_token(&self, name: &RuntimeName, pane: PaneId) {
        if let Some(link) = self.links.get(name) {
            let _ = fs::remove_file(token_path(&self.root, name, &link.settings, pane));
        }
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
        let helper = self.links.values_mut().find_map(|link| {
            let starting = match &mut link.phase {
                Phase::Starting(Step::Up { helper, .. }) => Some(helper),
                _ => None,
            };
            starting
                .into_iter()
                .chain(link.watch.as_mut())
                .find(|helper| helper.owns(ready.token).is_some())
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

    fn advance(&mut self, poll: &mut Poll, name: &RuntimeName) {
        let socket = socket_path(&self.root, name);
        let Some(link) = self.links.get_mut(name) else {
            return;
        };
        let Phase::Starting(Step::Up {
            mut helper,
            deadline,
        }) = std::mem::replace(&mut link.phase, Phase::Up)
        else {
            return;
        };
        helper.collect(poll);
        helper.release(poll);
        let next = match helper.exit() {
            None => Next::Fail("the up step vanished".to_owned()),
            Some(exit) => {
                let cx = Ctx {
                    name,
                    env: &self.env,
                    socket: &socket,
                    exe: &self.exe,
                };
                let out = Outcome {
                    exit,
                    stdout: helper.stdout(),
                    tail: helper.tail(),
                };
                link.start.next(&link.settings, &cx, &out)
            }
        };
        match next {
            Next::Run(launch) => match Registry::next_step(poll, &launch, deadline) {
                Ok(step) => {
                    if let Some(link) = self.links.get_mut(name) {
                        link.phase = Phase::Starting(step);
                    }
                }
                Err(error) => {
                    poll.free(deadline);
                    let message = format!("the up step did not start: {error}");
                    self.fail(poll, name, message);
                }
            },
            Next::Up => {
                poll.free(deadline);
                self.watch(poll, name, &socket);
            }
            Next::Fail(message) => {
                poll.free(deadline);
                self.fail(poll, name, message);
            }
        }
    }

    fn next_step(poll: &mut Poll, launch: &Launch, deadline: Timer) -> io::Result<Step> {
        let helper = exec::spawn(poll, launch, Mode::Capture)?;
        Ok(Step::Up { helper, deadline })
    }

    fn watch(&mut self, poll: &mut Poll, name: &RuntimeName, socket: &Path) {
        let Some(link) = self.links.get(name) else {
            return;
        };
        let cx = Ctx {
            name,
            env: &self.env,
            socket,
            exe: &self.exe,
        };
        let spawned = link.start.watch(&link.settings, &cx).and_then(|launch| {
            launch
                .map(|launch| exec::spawn(poll, &launch, Mode::Exec { stdin: true }))
                .transpose()
                .map_err(|error| error.to_string())
        });
        match spawned {
            Ok(helper) => {
                if let Some(link) = self.links.get_mut(name) {
                    link.watch = helper;
                }
            }
            Err(error) => {
                let message = format!("the container watch did not start: {error}");
                self.fail(poll, name, message);
            }
        }
    }

    pub(crate) fn reap(&mut self, poll: &mut Poll) -> Vec<RuntimeName> {
        let ended: Vec<RuntimeName> = self
            .links
            .iter_mut()
            .filter_map(|(name, link)| match &mut link.phase {
                Phase::Starting(Step::Up { helper, .. }) => helper.reap().map(|_| name.clone()),
                _ => None,
            })
            .collect();
        for name in ended {
            self.advance(poll, &name);
        }
        self.settle(poll);
        self.links
            .iter_mut()
            .filter_map(|(name, link)| link.watch.as_mut()?.reap().map(|_| name.clone()))
            .collect()
    }

    pub(crate) fn shutdown(&mut self, poll: &mut Poll) {
        let names: Vec<RuntimeName> = self.links.keys().cloned().collect();
        for name in names {
            self.down(poll, &name, true);
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
