use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::fs::{self, File};
use std::io;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::time::Duration;

use ko_config::config::{self as settings, LoadError};
use ko_config::runtime::{Kind, Runtime};
use ko_config::server::Idle;
use ko_config::values::{RuntimeColor, RuntimeName};
use ko_sys::event::{Poll, Ready, Timer, Token};
use ko_sys::pid::{Exit, Pid, Waited};

use crate::config::{Config, SUN_PATH_MAX, server_settings};
use crate::exec_wire::Start as ExecStart;
use crate::ids::{PaneId, PaneToken};
use crate::protocol::{
    ClientEvent, ClientRuntime, Error, ErrorKind, ExecRequest, LeadReport, LinkState, RuntimeKind,
    Variable, Version, check_version, version,
};
use crate::server::{Listener, Origin, Timing, Verified};
use crate::ssh::token_name;

pub(crate) mod command;
pub(crate) mod container;
pub(crate) mod exec;
pub(crate) mod leaving;
pub(crate) mod pane;
pub(crate) mod ssh;

use exec::{Helper, Launch, Mode, Source};
use pane::{directory, socket_path, token_directory, token_path};

const UP_LIMIT: Duration = Duration::from_secs(120);
const QUICK_LIMIT: Duration = Duration::from_secs(15);
pub(crate) const PASS_HOLD: Duration = Duration::from_secs(20);
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
    /// An interactive step that one waiting pane runs on its terminal, as the argv.
    Lead(Vec<String>),
    Up,
    Fail(String),
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Ending {
    Exit,
    Refused(String),
    Error(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Cleanup {
    Stop,
    Delete,
}

pub(crate) enum Tokens {
    /// A private file on the host, which the program of the pane reads.
    File {
        name: String,
        text: fn(&PaneToken) -> String,
    },
    /// The server writes it inside the runtime, through a step of the link, when a pane starts.
    Remote,
}

pub(crate) struct Ctx<'a> {
    pub(crate) name: &'a RuntimeName,
    pub(crate) env: &'a [Vec<u8>],
    pub(crate) socket: &'a Path,
    pub(crate) exe: &'a Path,
}

/// What a kind puts into a pane's program before and after the shared `enter` words.
/// `quoted` has the words from `ko` on single-quoted for the remote shell.
pub(crate) struct Entry {
    pub(crate) prefix: Vec<Vec<u8>>,
    pub(crate) ko: Vec<Vec<u8>>,
    pub(crate) location: Vec<Vec<u8>>,
    pub(crate) token: Vec<Vec<u8>>,
    pub(crate) quoted: bool,
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

pub(crate) fn kind(runtime: &Runtime) -> RuntimeKind {
    match runtime.kind {
        Kind::Ssh(_) => RuntimeKind::Ssh,
        Kind::Command(_) => RuntimeKind::Command,
        Kind::Container(_) => RuntimeKind::Container,
    }
}

/// How a pane's token reaches the runtime.
pub(crate) fn tokens(runtime: &Runtime, pane: PaneId) -> Tokens {
    match &runtime.kind {
        Kind::Command(_) => Tokens::File {
            name: token_name(pane),
            text: |token| token.to_string(),
        },
        Kind::Container(_) => Tokens::File {
            name: format!("{pane}.env"),
            text: container::token_text,
        },
        Kind::Ssh(_) => Tokens::Remote,
    }
}

pub(crate) fn entry(runtime: &Runtime, pane: PaneId, cx: &Ctx<'_>) -> Entry {
    match &runtime.kind {
        Kind::Command(command) => {
            let token = token_path(cx.socket, runtime, pane).unwrap_or_default();
            command::entry(command, (cx.exe, cx.socket.to_path_buf()), &token)
        }
        Kind::Container(container) => {
            let token = token_path(cx.socket, runtime, pane).unwrap_or_default();
            container::entry(cx.name, container, (cx.env, &token))
        }
        Kind::Ssh(remote) => ssh::entry(remote, cx),
    }
}

pub(crate) fn exec_env<'a>(
    runtime: &'a Runtime,
    name: &'a RuntimeName,
    request: &'a ExecRequest,
) -> BTreeMap<&'a str, &'a str> {
    let mut env: BTreeMap<&str, &str> = runtime
        .env
        .as_map()
        .iter()
        .chain(&request.env)
        .map(|(variable, value)| (variable.as_str(), value.as_str()))
        .collect();
    env.insert("KO_RUNTIME", name.as_str());
    if let Kind::Command(_) = runtime.kind {
        env.entry("PATH").or_insert(command::DEFAULT_PATH);
    }
    env
}

/// What the ko inside the runtime runs: the request under the runtime's cwd and env.
pub(crate) fn exec_start(
    runtime: &Runtime,
    name: &RuntimeName,
    request: &ExecRequest,
    escalation: Duration,
) -> ExecStart {
    ExecStart {
        argv: request.argv.clone(),
        cwd: request.cwd.clone().or_else(|| runtime.cwd.clone()),
        env: exec_env(runtime, name, request)
            .into_iter()
            .map(|(name, value)| Variable {
                name: name.to_owned(),
                value: value.to_owned(),
            })
            .collect(),
        escalation_ms: u64::try_from(escalation.as_millis()).unwrap_or(u64::MAX),
    }
}

/// The helper process that runs `ko enter --exec` inside the runtime.
pub(crate) fn exec_launch(
    runtime: &Runtime,
    request: &ExecRequest,
    cx: &Ctx<'_>,
) -> Result<Launch, String> {
    match &runtime.kind {
        Kind::Ssh(remote) => ssh::exec_launch(remote, cx),
        Kind::Command(command) => command::exec_launch(runtime, command, (request, cx)),
        Kind::Container(container) => container::exec_launch(container, cx),
    }
}

pub(crate) fn ending(runtime: &Runtime, exit: Exit, stderr: &[u8]) -> Ending {
    match &runtime.kind {
        Kind::Ssh(_) => ssh::ending(exit, stderr),
        Kind::Command(_) | Kind::Container(_) => Ending::Exit,
    }
}

pub(crate) fn cleanup(runtime: &Runtime, cx: &Ctx<'_>, what: Cleanup) -> Option<Launch> {
    match &runtime.kind {
        Kind::Command(_) => None,
        Kind::Container(container) => container::cleanup(container, (cx.name, cx.env), what),
        Kind::Ssh(remote) => ssh::cleanup(remote, cx, what),
    }
}

const MISMATCH: &str = "the kind of the runtime changed during its start";

#[derive(Debug)]
enum Start {
    Command,
    Container(container::Stage),
    Ssh(ssh::Link),
}

impl Start {
    fn new(settings: &Runtime) -> Start {
        match &settings.kind {
            Kind::Command(_) => Start::Command,
            Kind::Container(_) => Start::Container(container::Stage::System),
            Kind::Ssh(_) => Start::Ssh(ssh::Link::new()),
        }
    }

    fn first(&self, settings: &Runtime, cx: &Ctx<'_>) -> Result<Option<Launch>, String> {
        match (&settings.kind, self) {
            (Kind::Command(command), Start::Command) => Ok(command::first(command, cx.env)),
            (Kind::Container(container), Start::Container(_)) => {
                container::first(container, cx).map(Some)
            }
            (Kind::Ssh(remote), Start::Ssh(_)) => ssh::first(remote, cx).map(Some),
            _ => Err(MISMATCH.to_owned()),
        }
    }

    // The step after the interactive one.
    fn resume(&mut self, settings: &Runtime, cx: &Ctx<'_>) -> Result<Option<Launch>, String> {
        match (&settings.kind, self) {
            (Kind::Ssh(remote), Start::Ssh(link)) => ssh::resume(remote, link, cx).map(Some),
            (Kind::Command(command), Start::Command) => Ok(command::first(command, cx.env)),
            _ => Err(MISMATCH.to_owned()),
        }
    }

    fn next(&mut self, settings: &Runtime, cx: &Ctx<'_>, out: &Outcome<'_>) -> Next {
        match (&settings.kind, self) {
            (Kind::Command(_), Start::Command) => command::next(out),
            (Kind::Container(container), Start::Container(stage)) => {
                container::next(container, stage, cx, out)
            }
            (Kind::Ssh(remote), Start::Ssh(link)) => ssh::next(remote, link, cx, out),
            _ => Next::Fail(MISMATCH.to_owned()),
        }
    }

    fn watch(&self, settings: &Runtime, cx: &Ctx<'_>) -> Result<Option<Launch>, String> {
        match (&settings.kind, self) {
            (Kind::Command(_), Start::Command) => Ok(None),
            (Kind::Container(container), Start::Container(_)) => {
                container::watch(container, cx).map(Some)
            }
            (Kind::Ssh(_), Start::Ssh(_)) => Ok(None),
            _ => Err(MISMATCH.to_owned()),
        }
    }

    // Whether the link still answers, for the kinds whose link can die unseen.
    fn alive(&self, settings: &Runtime, cx: &Ctx<'_>) -> Result<Option<Launch>, String> {
        match (&settings.kind, self) {
            (Kind::Ssh(remote), Start::Ssh(_)) => ssh::check(remote, cx).map(Some),
            _ => Ok(None),
        }
    }

    // The step that puts a pane's token into the runtime, for `Tokens::Remote`.
    fn deliver(
        &self,
        settings: &Runtime,
        cx: &Ctx<'_>,
        pane: PaneId,
    ) -> Result<Option<Launch>, String> {
        match (&settings.kind, self) {
            (Kind::Ssh(remote), Start::Ssh(link)) => ssh::token(remote, link, cx, pane).map(Some),
            _ => Ok(None),
        }
    }
}

#[derive(Debug)]
enum Step {
    Lead {
        argv: Vec<String>,
        leader: Option<PaneId>,
    },
    Cleaning,
    Up {
        helper: Helper,
        deadline: Timer,
    },
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

#[derive(Debug)]
struct Pass {
    pane: PaneId,
    conn: Token,
    token: String,
}

// The steps of the server that stand between a pane and its program: whether the link still
// answers, and the delivery of the token.
#[derive(Debug)]
enum Job {
    Check(Option<Pass>),
    Deliver(Token),
}

#[derive(Debug)]
struct Child {
    name: RuntimeName,
    helper: Helper,
    deadline: Timer,
    job: Job,
}

#[derive(Debug, Default)]
struct Pending {
    reaping: Vec<Pid>,
    commands: Vec<Pid>,
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

type Configured = BTreeMap<RuntimeName, (RuntimeKind, Option<RuntimeColor>)>;

#[derive(Debug)]
pub(crate) struct Registry {
    file: PathBuf,
    command_kind: bool,
    root: PathBuf,
    env: Vec<Vec<u8>>,
    links: BTreeMap<RuntimeName, Link>,
    waits: Vec<(RuntimeName, Wait)>,
    dying: Vec<Pid>,
    cleaning: Vec<Pid>,
    cleanups: BTreeMap<RuntimeName, Pending>,
    deleting: BTreeSet<RuntimeName>,
    released: Vec<Pid>,
    children: Vec<Child>,
    passed: Vec<(Token, LinkState)>,
    announced: BTreeMap<RuntimeName, ClientRuntime>,
    pending: Vec<ClientEvent>,
    configured: Option<Configured>,
    dirty: bool,
    exe: PathBuf,
    escalation: Duration,
}

pub(crate) fn text(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

pub(crate) fn words(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
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
            file: config.file.clone(),
            command_kind: config.runtimes.command_kind,
            root: config.dir.join("runtimes"),
            env: config.env.clone(),
            links: BTreeMap::new(),
            waits: Vec::new(),
            dying: Vec::new(),
            cleaning: Vec::new(),
            cleanups: BTreeMap::new(),
            deleting: BTreeSet::new(),
            released: Vec::new(),
            children: Vec::new(),
            passed: Vec::new(),
            announced: BTreeMap::new(),
            pending: Vec::new(),
            configured: None,
            dirty: false,
            exe: config.exe.clone(),
            escalation: config.stop_escalation / 2,
        }
    }

    pub(crate) fn root(&self) -> &Path {
        &self.root
    }

    pub(crate) fn exec_launch(
        &self,
        name: &RuntimeName,
        runtime: &Runtime,
        request: &ExecRequest,
    ) -> Result<(Launch, ExecStart), String> {
        let socket = socket_path(&self.root, name);
        let cx = Ctx {
            name,
            env: &self.env,
            socket: &socket,
            exe: &self.exe,
        };
        let launch = exec_launch(runtime, request, &cx)?;
        Ok((launch, exec_start(runtime, name, request, self.escalation)))
    }

    pub(crate) fn take_dying(&mut self) -> Vec<Pid> {
        std::mem::take(&mut self.dying)
    }

    pub(crate) fn take_cleaning(&mut self) -> Vec<Pid> {
        std::mem::take(&mut self.cleaning)
    }

    fn adopt<'a>(
        &mut self,
        loaded: &'a Result<settings::Config, LoadError>,
    ) -> Result<&'a settings::Config, Error> {
        let config = loaded.as_ref().map_err(|error| match error {
            LoadError::Invalid(problem) => Error::new(
                ErrorKind::Invalid,
                format!("{}: {problem}", self.file.display()),
            ),
            LoadError::Io(message) => Error::new(ErrorKind::Io, message.clone()),
        })?;
        if let Some(name) = config
            .runtimes
            .iter()
            .find_map(|(name, runtime)| matches!(runtime.kind, Kind::Command(_)).then_some(name))
            .filter(|_| !self.command_kind)
        {
            return Err(Error::new(
                ErrorKind::Invalid,
                format!(
                    "{}: runtimes: {name}: command: is a test kind; set KO_RUNTIME_COMMAND_KIND=1",
                    self.file.display()
                ),
            ));
        }
        self.configured = Some(
            config
                .runtimes
                .iter()
                .map(|(name, runtime)| (name.clone(), (kind(runtime), runtime.color.clone())))
                .collect(),
        );
        self.dirty = true;
        Ok(config)
    }

    fn missing(&self, name: &RuntimeName) -> Error {
        Error::new(
            ErrorKind::Missing,
            format!("no runtime {name} in {}", self.file.display()),
        )
    }

    pub(crate) fn settings(&mut self, name: &RuntimeName) -> Result<Runtime, Error> {
        let loaded = settings::load(&self.file);
        self.settings_in(name, &loaded)
    }

    pub(crate) fn settings_in(
        &mut self,
        name: &RuntimeName,
        loaded: &Result<settings::Config, LoadError>,
    ) -> Result<Runtime, Error> {
        if let Some(link) = self.links.get(name)
            && matches!(link.phase, Phase::Starting(_) | Phase::Up)
        {
            return Ok(link.settings.clone());
        }
        self.adopt(loaded)?
            .runtimes
            .get(name)
            .cloned()
            .ok_or_else(|| self.missing(name))
    }

    pub(crate) fn known(&mut self) -> Result<Vec<(RuntimeName, Runtime)>, Error> {
        let loaded = settings::load(&self.file);
        let mut known = self.adopt(&loaded)?.runtimes.clone();
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

    // The runtimes that clients hear of are the ones that the registry last announced. The configuration
    // that it last read and the live links decide what is listed; a quiet turn changes neither.
    pub(crate) fn take_changes(&mut self) -> Vec<ClientEvent> {
        if std::mem::take(&mut self.dirty) {
            self.sync();
        }
        std::mem::take(&mut self.pending)
    }

    fn sync(&mut self) {
        let mut desired: Configured = self.configured.clone().unwrap_or_default();
        for (name, link) in &self.links {
            if matches!(link.phase, Phase::Starting(_) | Phase::Up) {
                desired.insert(
                    name.clone(),
                    (kind(&link.settings), link.settings.color.clone()),
                );
            }
        }
        let gone: Vec<RuntimeName> = self
            .announced
            .keys()
            .filter(|name| !desired.contains_key(*name))
            .cloned()
            .collect();
        for name in gone {
            self.announced.remove(&name);
            self.pending.push(ClientEvent::RuntimeDeleted { name });
        }
        for (name, (kind, color)) in desired {
            let entry = ClientRuntime {
                state: self.state(&name),
                name: name.clone(),
                kind,
                color,
            };
            if self.announced.get(&name) != Some(&entry) {
                self.announced.insert(name, entry.clone());
                self.pending.push(ClientEvent::Runtime(entry));
            }
        }
    }

    pub(crate) fn listed(
        &mut self,
        loaded: &Result<settings::Config, LoadError>,
    ) -> Vec<ClientRuntime> {
        let _ = self.adopt(loaded);
        self.sync();
        self.dirty = false;
        self.announced.values().cloned().collect()
    }

    pub(crate) fn is_live(&self, name: &RuntimeName) -> bool {
        self.links.contains_key(name)
    }

    pub(crate) fn begin(&mut self, poll: &mut Poll, name: &RuntimeName, settings: Runtime) {
        self.dirty = true;
        if matches!(
            self.links.get(name).map(|link| &link.phase),
            Some(Phase::Starting(_) | Phase::Up)
        ) {
            return;
        }
        if let Some(old) = self.links.remove(name) {
            poll.free(old.idle);
        }
        // A deletion waits for the cleanup, and a start that follows it keeps the directory.
        self.deleting.remove(name);
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
        self.dirty = true;
        let socket = socket_path(&self.root, name);
        let Some(link) = self.links.get_mut(name) else {
            return;
        };
        let cx = Ctx {
            name,
            env: &self.env,
            socket: &socket,
            exe: &self.exe,
        };
        let lead = link.settings.lead().filter(|_| from_start);
        let next = if let Some(argv) = lead {
            Next::Lead(argv.to_vec())
        } else {
            let launched = if from_start {
                link.start.first(&link.settings, &cx)
            } else {
                link.start.resume(&link.settings, &cx)
            };
            match launched {
                Err(message) => Next::Fail(message),
                Ok(None) => Next::Up,
                Ok(Some(launch)) => Next::Run(launch),
            }
        };
        let phase = match next {
            Next::Fail(message) => return self.fail(poll, name, message),
            Next::Up => Phase::Up,
            Next::Lead(argv) => Phase::Starting(Step::Lead { argv, leader: None }),
            Next::Run(launch) => match Registry::spawn_up(poll, &launch) {
                Ok(step) => Phase::Starting(step),
                Err(error) => {
                    let message = format!("the up step did not start: {error}");
                    return self.fail(poll, name, message);
                }
            },
        };
        if let Some(link) = self.links.get_mut(name) {
            link.phase = phase;
        }
    }

    fn spawn_up(poll: &mut Poll, launch: &Launch) -> io::Result<Step> {
        let helper = exec::spawn(poll, launch, Mode::Capture { stdin: false })?;
        let deadline = poll.timer();
        poll.start(deadline, UP_LIMIT, None)?;
        Ok(Step::Up { helper, deadline })
    }

    fn fail(&mut self, poll: &mut Poll, name: &RuntimeName, message: String) {
        self.dirty = true;
        let Some(mut link) = self.links.remove(name) else {
            return;
        };
        let answer = LinkState::Failed {
            message: message.clone(),
        };
        self.end(poll, name, &mut link, (false, &answer));
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
                pending.commands.push(pid);
                self.cleaning.push(pid);
            }
        }
        self.cleanups
            .retain(|_, pending| !pending.reaping.is_empty() || !pending.queue.is_empty());
    }

    fn settle(&mut self, poll: &mut Poll) {
        self.drive();
        let removable: Vec<RuntimeName> = self
            .deleting
            .iter()
            .filter(|name| !self.cleanups.contains_key(*name))
            .cloned()
            .collect();
        for name in removable {
            self.deleting.remove(&name);
            let _ = fs::remove_dir_all(directory(&self.root, &name));
        }
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

    // The children of the link end, and the panes that wait behind them get the answer.
    fn end(
        &mut self,
        poll: &mut Poll,
        name: &RuntimeName,
        link: &mut Link,
        (detach, answer): (bool, &LinkState),
    ) {
        let mut reaping = Vec::new();
        let (mine, rest): (Vec<Child>, Vec<Child>) = std::mem::take(&mut self.children)
            .into_iter()
            .partition(|child| child.name == *name);
        self.children = rest;
        for mut child in mine {
            poll.free(child.deadline);
            reaping.extend(stop_helper(poll, &mut child.helper, &mut self.dying));
            match child.job {
                Job::Check(Some(Pass { conn, .. })) | Job::Deliver(conn) => {
                    self.passed.push((conn, answer.clone()));
                }
                Job::Check(None) => {}
            }
        }
        if let Phase::Starting(Step::Up { helper, deadline }) = &mut link.phase {
            poll.free(*deadline);
            reaping.extend(stop_helper(poll, helper, &mut self.dying));
        }
        if let Some(mut watch) = link.watch.take() {
            reaping.extend(stop_helper(poll, &mut watch, &mut self.dying));
        }
        let socket = socket_path(&self.root, name);
        let cx = Ctx {
            name,
            env: &self.env,
            socket: &socket,
            exe: &self.exe,
        };
        let stop = cleanup(&link.settings, &cx, Cleanup::Stop)
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

    pub(crate) fn forget_wait(&mut self, poll: &mut Poll, conn: Token) {
        self.waits.retain(|(_, wait)| wait.conn != conn);
        self.end_pass(poll, conn);
    }

    fn end_pass(&mut self, poll: &mut Poll, conn: Token) -> bool {
        let Some(at) = self.children.iter().position(|child| match &child.job {
            Job::Check(Some(pass)) => pass.conn == conn,
            Job::Deliver(waiting) => *waiting == conn,
            Job::Check(None) => false,
        }) else {
            return false;
        };
        let mut child = self.children.swap_remove(at);
        poll.free(child.deadline);
        stop_helper(poll, &mut child.helper, &mut self.dying);
        true
    }

    // The state to answer a pane whose wait ran out.
    pub(crate) fn expire_pane_wait(&mut self, poll: &mut Poll, conn: Token) -> Option<LinkState> {
        if self.end_pass(poll, conn) {
            return Some(LinkState::Starting);
        }
        let at = self
            .waits
            .iter()
            .position(|(_, wait)| wait.conn == conn && matches!(wait.who, Who::Pane(_)))?;
        let name = self.waits.swap_remove(at).0;
        Some(self.state(&name))
    }

    pub(crate) fn needs_pane(&self, name: &RuntimeName) -> bool {
        matches!(
            self.links.get(name).map(|link| &link.phase),
            Some(Phase::Starting(Step::Lead { leader: None, .. }))
        )
    }

    pub(crate) fn elect(&mut self, name: &RuntimeName, pane: PaneId) -> Option<Vec<String>> {
        let link = self.links.get_mut(name)?;
        let Phase::Starting(Step::Lead {
            argv,
            leader: leader @ None,
        }) = &mut link.phase
        else {
            return None;
        };
        *leader = Some(pane);
        Some(argv.clone())
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
            Some(Phase::Starting(Step::Lead { leader: Some(leader), .. })) if *leader == pane
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
                matches!(&link.phase, Phase::Starting(Step::Lead { leader: Some(leader), .. }) if *leader == pane)
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
        let (done, pending): (Vec<_>, Vec<_>) = waits.into_iter().partition(|(name, _)| {
            !matches!(self.state(name), LinkState::Starting) || self.needs_pane(name)
        });
        self.waits = pending;
        done.into_iter()
            .map(|(name, wait)| {
                let state = self.state(&name);
                (name, wait, state)
            })
            .collect()
    }

    pub(crate) fn down(&mut self, poll: &mut Poll, name: &RuntimeName, detach: bool) {
        self.dirty = true;
        let Some(mut link) = self.links.remove(name) else {
            return;
        };
        self.end(poll, name, &mut link, (detach, &LinkState::Down));
        poll.free(link.idle);
    }

    // A master that died unseen: the link starts again, and the pane that found out may lead.
    fn restart(&mut self, poll: &mut Poll, name: &RuntimeName) {
        self.dirty = true;
        let Some(mut link) = self.links.remove(name) else {
            return;
        };
        if !matches!(link.phase, Phase::Up) {
            self.links.insert(name.clone(), link);
            return;
        }
        self.end(poll, name, &mut link, (false, &LinkState::Starting));
        poll.free(link.idle);
        self.begin(poll, name, link.settings);
    }

    pub(crate) fn delete(&mut self, name: &RuntimeName, settings: &Runtime) {
        let socket = socket_path(&self.root, name);
        let cx = Ctx {
            name,
            env: &self.env,
            socket: &socket,
            exe: &self.exe,
        };
        let launches = cleanup(settings, &cx, Cleanup::Delete)
            .into_iter()
            .collect();
        self.schedule(name, launches, Vec::new());
        self.drive();
    }

    pub(crate) fn take_passed(&mut self) -> Vec<(Token, LinkState)> {
        std::mem::take(&mut self.passed)
    }

    pub(crate) fn waiters_of(&mut self, name: &RuntimeName) -> Vec<Wait> {
        let (mine, rest): (Vec<_>, Vec<_>) = std::mem::take(&mut self.waits)
            .into_iter()
            .partition(|(waiting, _)| waiting == name);
        self.waits = rest;
        mine.into_iter().map(|(_, wait)| wait).collect()
    }

    // The directory holds the control socket that a cleanup may still use.
    pub(crate) fn remove_directory(&mut self, name: &RuntimeName) {
        if self.cleanups.contains_key(name) {
            self.deleting.insert(name.clone());
        } else {
            let _ = fs::remove_dir_all(directory(&self.root, name));
        }
    }

    pub(crate) fn remote_tokens(&self, name: &RuntimeName, pane: PaneId) -> bool {
        self.links.get(name).is_some_and(|link| {
            matches!(link.phase, Phase::Up)
                && matches!(tokens(&link.settings, pane), Tokens::Remote)
        })
    }

    fn spawn_child(
        &mut self,
        poll: &mut Poll,
        name: &RuntimeName,
        (launch, mode): (&Launch, Mode),
        job: Job,
    ) -> io::Result<()> {
        let mut helper = exec::spawn(poll, launch, mode)?;
        let deadline = poll.timer();
        if let Err(error) = poll.start(deadline, QUICK_LIMIT, None) {
            stop_helper(poll, &mut helper, &mut self.dying);
            poll.free(deadline);
            return Err(error);
        }
        self.children.push(Child {
            name: name.clone(),
            helper,
            deadline,
            job,
        });
        Ok(())
    }

    fn step_launch(
        &self,
        name: &RuntimeName,
        pick: impl FnOnce(&Link, &Ctx<'_>) -> Result<Option<Launch>, String>,
    ) -> Result<Launch, String> {
        let link = self
            .links
            .get(name)
            .ok_or_else(|| format!("runtime {name} is down"))?;
        let socket = socket_path(&self.root, name);
        let cx = Ctx {
            name,
            env: &self.env,
            socket: &socket,
            exe: &self.exe,
        };
        pick(link, &cx)?.ok_or_else(|| format!("runtime {name} has no such step"))
    }

    pub(crate) fn pass(
        &mut self,
        poll: &mut Poll,
        name: &RuntimeName,
        (conn, pane): (Token, PaneId),
        token: String,
    ) -> Result<(), String> {
        let launch = self.step_launch(name, |link, cx| link.start.alive(&link.settings, cx))?;
        let job = Job::Check(Some(Pass { pane, conn, token }));
        let mode = Mode::Capture { stdin: false };
        self.spawn_child(poll, name, (&launch, mode), job)
            .map_err(|error| format!("cannot check the link: {error}"))
    }

    // An exec found the link gone: the next request starts it again.
    pub(crate) fn suspect(&mut self, poll: &mut Poll, name: &RuntimeName) {
        let alone = !self
            .children
            .iter()
            .any(|child| child.name == *name && matches!(child.job, Job::Check(None)));
        if !alone {
            return;
        }
        if let Ok(launch) = self.step_launch(name, |link, cx| link.start.alive(&link.settings, cx))
        {
            let mode = Mode::Capture { stdin: false };
            let _ = self.spawn_child(poll, name, (&launch, mode), Job::Check(None));
        }
    }

    fn deliver(&mut self, poll: &mut Poll, name: &RuntimeName, pass: Pass) {
        let Pass { pane, conn, token } = pass;
        let started = self
            .step_launch(name, |link, cx| {
                link.start.deliver(&link.settings, cx, pane)
            })
            .and_then(|launch| {
                let mode = Mode::Capture { stdin: true };
                self.spawn_child(poll, name, (&launch, mode), Job::Deliver(conn))
                    .map_err(|error| format!("cannot deliver the token: {error}"))
            });
        match started {
            Ok(()) => {
                if let Some(child) = self.children.last_mut() {
                    child.helper.write_stdin(poll, token.into_bytes());
                    child.helper.close_stdin(poll);
                }
            }
            Err(message) => self.passed.push((conn, LinkState::Failed { message })),
        }
    }

    fn finish(&mut self, poll: &mut Poll, child: Child) {
        let Child {
            name, helper, job, ..
        } = child;
        let exit = helper.exit().unwrap_or(Exit::Exited(1));
        match job {
            Job::Check(pass) if exit == Exit::Exited(0) => {
                if let Some(pass) = pass {
                    self.deliver(poll, &name, pass);
                }
            }
            Job::Check(pass) => {
                self.restart(poll, &name);
                if let Some(Pass { conn, .. }) = pass {
                    self.passed.push((conn, LinkState::Starting));
                }
            }
            Job::Deliver(conn) => {
                let state = if exit == Exit::Exited(0) {
                    LinkState::Up
                } else {
                    let why = last_line(helper.tail()).unwrap_or_else(|| exit_text("token", exit));
                    LinkState::Failed {
                        message: format!("cannot deliver the token to {name}: {why}"),
                    }
                };
                self.passed.push((conn, state));
            }
        }
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
        let Tokens::File { text, .. } = tokens(&link.settings, pane) else {
            return Ok(());
        };
        let Some(path) = token_path(&socket_path(&self.root, name), &link.settings, pane) else {
            return Ok(());
        };
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(token_directory(&self.root, name))?;
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
        file.write_all(text(token).as_bytes())
    }

    pub(crate) fn remove_token(&self, name: &RuntimeName, pane: PaneId) {
        let socket = socket_path(&self.root, name);
        if let Some(path) = self
            .links
            .get(name)
            .and_then(|link| token_path(&socket, &link.settings, pane))
        {
            let _ = fs::remove_file(path);
        }
    }

    pub(crate) fn occupy(&mut self, poll: &mut Poll, name: &RuntimeName, occupied: bool) {
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
        } else if let Idle::After(after) = server_settings(&self.file).runtime_idle_seconds {
            let _ = poll.start(link.idle, after.duration(), None);
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
        let found = self
            .children
            .iter_mut()
            .find_map(|child| child.helper.owns(ready.token).map(|source| (child, source)));
        match found {
            Some((child, Source::Output)) => {
                child.helper.collect(poll);
                return true;
            }
            Some((child, Source::Stdin)) => {
                child.helper.flush_stdin(poll);
                return true;
            }
            None => {}
        }
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
        if let Some(at) = self
            .children
            .iter()
            .position(|child| child.deadline == timer)
        {
            let mut child = self.children.swap_remove(at);
            poll.free(child.deadline);
            stop_helper(poll, &mut child.helper, &mut self.dying);
            if let Job::Check(Some(Pass { conn, .. })) | Job::Deliver(conn) = child.job {
                let message = format!("runtime {} did not answer in time", child.name);
                self.passed.push((conn, LinkState::Failed { message }));
            }
            return Due::Handled;
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
        self.dirty = true;
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
            Next::Lead(argv) => {
                poll.free(deadline);
                if let Some(link) = self.links.get_mut(name) {
                    link.phase = Phase::Starting(Step::Lead { argv, leader: None });
                }
            }
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
        let helper = exec::spawn(poll, launch, Mode::Capture { stdin: false })?;
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
                .map(|launch| exec::spawn(poll, &launch, Mode::Capture { stdin: true }))
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
        let mut done = Vec::new();
        for mut child in std::mem::take(&mut self.children) {
            if child.helper.reap().is_some() {
                done.push(child);
            } else {
                self.children.push(child);
            }
        }
        for mut child in done {
            poll.free(child.deadline);
            child.helper.collect(poll);
            child.helper.release(poll);
            self.finish(poll, child);
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
        // What a down or a delete queued earlier still runs after the server.
        for pending in std::mem::take(&mut self.cleanups).into_values() {
            for launch in &pending.queue {
                let _ = exec::detached(launch);
            }
            self.released.extend(pending.commands);
        }
    }

    pub(crate) fn take_released(&mut self) -> Vec<Pid> {
        std::mem::take(&mut self.released)
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
