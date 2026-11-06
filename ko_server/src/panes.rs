use std::collections::BTreeSet;
use std::fmt;
use std::fs;
use std::io;
use std::path::Path;
use std::time::Duration;

use ko_config::values::env_valid;
use ko_pane_wire::frame::Size;
use ko_sys::clock::Mono;
use ko_sys::event::Token;

use crate::config::{Config, Settings, path_with, terminal};
use crate::delivery::{Stamps, mint_stamps};
use crate::ids::{PaneId, PaneToken, SessionId};
use crate::pane::{Birth, Pane, Program};
use crate::pane_proc::{Io, Launch, Life};
use crate::protocol::{Close, Command, CreatePane, Error, ErrorKind, Relation, Variable};
use crate::runtime::RuntimeKey;

#[derive(Debug)]
pub(crate) enum AddError {
    Invalid(&'static str),
    Io(io::Error),
}

impl fmt::Display for AddError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            AddError::Invalid(message) => f.write_str(message),
            AddError::Io(error) => error.fmt(f),
        }
    }
}

#[derive(Debug)]
pub(crate) struct Panes {
    stamps: Stamps,
    panes: Vec<Pane>,
    removed: Vec<Pane>,
}

impl Default for Panes {
    fn default() -> Panes {
        Panes {
            stamps: mint_stamps(),
            panes: Vec::new(),
            removed: Vec::new(),
        }
    }
}

fn environment(
    config: &Config,
    shell: &Path,
    id: PaneId,
    token: &PaneToken,
    requested: &[Variable],
) -> Vec<Vec<u8>> {
    let mut forced: Vec<(&str, Vec<u8>)> = terminal(Some(&config.terminfo));
    forced.extend([
        (
            "KO_SOCKET",
            config.socket.as_os_str().as_encoded_bytes().to_vec(),
        ),
        ("KO_PANE", id.to_string().into_bytes()),
        ("KO_PANE_TOKEN", token.to_string().into_bytes()),
        ("KO_SHELL", shell.as_os_str().as_encoded_bytes().to_vec()),
    ]);
    if let Some(dir) = &config.bin_dir {
        let path = path_with(dir, crate::config::env_path(&config.env));
        forced.push(("PATH", path));
    }
    let agent = (
        "SSH_AUTH_SOCK",
        crate::agent::socket(&config.dir)
            .as_os_str()
            .as_encoded_bytes()
            .to_vec(),
    );
    let requested_agent = requested.iter().any(|variable| variable.name == agent.0);
    let overrides: Vec<(&str, Vec<u8>)> = forced
        .iter()
        .cloned()
        .chain(
            requested
                .iter()
                .filter(|variable| forced.iter().all(|(forced, _)| *forced != variable.name))
                .map(|variable| (variable.name.as_str(), variable.value.clone().into_bytes())),
        )
        .chain((!requested_agent).then_some(agent))
        .collect();
    let given: Vec<(&[u8], &[u8])> = overrides
        .iter()
        .map(|(name, value)| (name.as_bytes(), value.as_slice()))
        .collect();
    crate::config::overlay(&given, &config.env)
}

pub(crate) type Wrap<'a> = &'a dyn Fn(Option<&[Vec<u8>]>) -> Vec<Vec<u8>>;

pub(crate) enum Start<'a> {
    Host(Option<&'a Path>),
    Runtime(Wrap<'a>),
}

pub(crate) fn program(
    config: &Config,
    shell: &Path,
    request: &CreatePane,
    start: Start<'_>,
) -> Result<Program, AddError> {
    if request
        .env
        .iter()
        .any(|variable| !env_valid(&variable.name, &variable.value))
    {
        return Err(AddError::Invalid("invalid environment"));
    }
    let bytes = |path: &std::path::Path| path.as_os_str().as_encoded_bytes().to_vec();
    let shell = match start {
        Start::Runtime(_) => b"/bin/sh".to_vec(),
        Start::Host(_) => bytes(shell),
    };
    let inner: Option<Vec<Vec<u8>>> = match &request.command {
        None => None,
        Some(Command::Argv { argv }) => {
            Some(argv.iter().map(|arg| arg.clone().into_bytes()).collect())
        }
        Some(Command::Shell { command }) => {
            Some(vec![shell, b"-c".to_vec(), command.clone().into_bytes()])
        }
    };
    let record = inner
        .clone()
        .unwrap_or_else(|| vec![bytes(&config.exe), b"shell".to_vec()]);
    Ok(match start {
        Start::Host(cwd) => Program {
            argv: record.clone(),
            record,
            cwd: cwd.map_or_else(|| config.cwd.clone(), Path::to_path_buf),
            env: request.env.clone(),
        },
        Start::Runtime(wrap) => Program {
            argv: wrap(inner.as_deref()),
            record,
            cwd: config.cwd.clone(),
            env: Vec::new(),
        },
    })
}

impl Panes {
    pub(crate) fn find(&self, id: PaneId) -> Option<&Pane> {
        self.panes.iter().find(|pane| pane.id() == id)
    }

    pub(crate) fn find_mut(&mut self, id: PaneId) -> Option<&mut Pane> {
        self.panes.iter_mut().find(|pane| pane.id() == id)
    }

    pub(crate) fn by_token(&mut self, token: Token) -> Option<&mut Pane> {
        self.panes
            .iter_mut()
            .find(|pane| pane.proc().token() == Some(token))
    }

    pub(crate) fn by_promotion(&self, timer: ko_sys::event::Timer) -> Option<PaneId> {
        self.panes
            .iter()
            .find(|pane| pane.model().promotion() == Some(timer))
            .map(Pane::id)
    }

    pub(crate) fn iter(&self) -> impl Iterator<Item = &Pane> {
        self.panes.iter()
    }

    pub(crate) fn iter_mut(&mut self) -> impl Iterator<Item = &mut Pane> {
        self.panes.iter_mut()
    }

    pub(crate) fn len(&self) -> usize {
        self.panes.len()
    }

    pub(crate) fn add(
        &mut self,
        config: &Config,
        settings: &Settings,
        id: PaneId,
        size: Size,
        birth: Birth,
        io: &mut Io<'_>,
    ) -> Result<(), AddError> {
        let program = &birth.program;
        if !program
            .record
            .first()
            .is_some_and(|executable| executable.starts_with(b"/"))
        {
            return Err(AddError::Invalid("command executable must be absolute"));
        }
        if program.cwd.is_relative() {
            return Err(AddError::Invalid("cwd must be absolute"));
        }
        let nul = |bytes: &[u8]| bytes.contains(&0);
        if nul(program.cwd.as_os_str().as_encoded_bytes())
            || program.argv.iter().any(|arg| nul(arg))
        {
            return Err(AddError::Invalid("NUL in pane request"));
        }
        match fs::metadata(&program.cwd) {
            Ok(meta) if meta.is_dir() => {}
            Ok(_) => return Err(AddError::Invalid("cwd must be a directory")),
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::NotFound
                        | io::ErrorKind::NotADirectory
                        | io::ErrorKind::PermissionDenied
                ) =>
            {
                return Err(AddError::Invalid("cwd must be a directory"));
            }
            Err(error) => return Err(AddError::Io(error)),
        }
        let token = PaneToken::mint().map_err(AddError::Io)?;
        let env = environment(config, &settings.shell, id, &token, &program.env);
        let (cwd, argv) = (program.cwd.clone(), program.argv.clone());
        let launch = Launch {
            id,
            cwd: &cwd,
            argv: &argv,
            env: &env,
            size,
            limits: settings.limits,
        };
        let pane = Pane::spawn(config, &launch, birth, token, &mut self.stamps, io)
            .map_err(AddError::Io)?;
        self.panes.push(pane);
        Ok(())
    }

    pub(crate) fn in_runtime<'a>(
        &'a self,
        runtime: &'a RuntimeKey,
    ) -> impl Iterator<Item = &'a Pane> {
        self.panes
            .iter()
            .filter(move |pane| pane.runtime() == Some(runtime))
    }

    pub(crate) fn is_in(&self, id: PaneId, runtime: &RuntimeKey) -> bool {
        self.find(id)
            .is_some_and(|pane| pane.runtime() == Some(runtime))
    }

    pub(crate) fn any_in(&self, runtime: &RuntimeKey) -> bool {
        self.in_runtime(runtime).next().is_some()
    }

    pub(crate) fn remove(&mut self, id: PaneId, io: &mut Io<'_>) {
        if let Some(at) = self.panes.iter().position(|pane| pane.id() == id) {
            let mut pane = self.panes.remove(at);
            pane.proc_mut().shutdown(io);
            self.removed.push(pane);
        }
    }

    fn all(&self) -> impl Iterator<Item = &Pane> {
        self.panes.iter().chain(&self.removed)
    }

    fn all_mut(&mut self) -> impl Iterator<Item = &mut Pane> {
        self.panes.iter_mut().chain(self.removed.iter_mut())
    }

    pub(crate) fn shutdown(&mut self, io: &mut Io<'_>) {
        for pane in self.all_mut() {
            pane.proc_mut().shutdown(io);
        }
    }

    pub(crate) fn kill_removed(&self, id: PaneId) -> io::Result<()> {
        self.removed
            .iter()
            .filter(|pane| pane.id() == id)
            .try_for_each(|pane| pane.proc().kill())
    }

    pub(crate) fn kill(&self) -> io::Result<()> {
        self.all().try_for_each(|pane| pane.proc().kill())
    }

    pub(crate) fn reap(&mut self, io: &mut Io<'_>) -> io::Result<()> {
        for pane in &mut self.removed {
            pane.proc_mut().reap(io)?;
        }
        self.removed
            .retain(|pane| pane.proc().life() != Life::Reaped);
        Ok(())
    }
}

#[derive(Debug, Clone, Copy)]
pub(crate) enum Condition {
    Live,
    Dead { at: Mono },
    Failed { at: Mono },
}

#[derive(Debug, Clone)]
pub(crate) struct Seen {
    pub(crate) id: PaneId,
    pub(crate) condition: Condition,
    pub(crate) parent: Option<PaneId>,
    pub(crate) close: Close,
    pub(crate) shown: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Standing {
    Live,
    Dead,
    Gone,
}

pub(crate) fn standing(panes: &[Seen], id: PaneId) -> Standing {
    match panes.iter().find(|pane| pane.id == id) {
        None => Standing::Gone,
        Some(pane)
            if matches!(
                pane.condition,
                Condition::Dead { .. } | Condition::Failed { .. }
            ) =>
        {
            Standing::Dead
        }
        Some(_) => Standing::Live,
    }
}

#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct Swept {
    pub(crate) removed: Vec<PaneId>,
    pub(crate) next: Option<Duration>,
}

pub(crate) fn sweep(panes: &[Seen], now: Mono, linger: impl Fn() -> Duration) -> Swept {
    let mut swept = Swept::default();
    let grace = std::cell::OnceCell::new();
    for pane in panes {
        let orphan = pane
            .parent
            .is_some_and(|parent| standing(panes, parent) != Standing::Live);
        let lingered = match pane.condition {
            Condition::Dead { at } | Condition::Failed { at } if pane.close == Close::OnExit => {
                let age = Duration::from_nanos(now.nanos().saturating_sub(at.nanos()));
                let grace = *grace.get_or_init(&linger);
                if age < grace {
                    let left = grace.saturating_sub(age);
                    swept.next = Some(swept.next.map_or(left, |next| next.min(left)));
                }
                age >= grace
            }
            _ => false,
        };
        let exited = pane.close == Close::Exit && matches!(pane.condition, Condition::Dead { .. });
        if exited || (!pane.shown && (orphan || lingered)) {
            swept.removed.push(pane.id);
        }
    }
    swept
}

pub(crate) fn acts_as(caller: Option<PaneId>, target: PaneId, what: &str) -> Result<(), Error> {
    match caller {
        Some(caller) if caller != target => Err(Error::new(
            ErrorKind::Refused,
            format!("{caller} may {what}, not {target}"),
        )),
        _ => Ok(()),
    }
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct Edge {
    pub(crate) pane: PaneId,
    pub(crate) parent: Option<PaneId>,
    pub(crate) session: SessionId,
}

fn children<'a>(edges: &'a [Edge], me: &'a Edge) -> impl Iterator<Item = &'a Edge> {
    edges
        .iter()
        .filter(move |edge| edge.session == me.session && edge.parent == Some(me.pane))
}

fn ancestors(edges: &[Edge], of: &Edge) -> Vec<Edge> {
    let mut found: Vec<Edge> = Vec::new();
    let mut at = *of;
    for _ in edges {
        let Some(above) = at
            .parent
            .and_then(|parent| edges.iter().find(|edge| edge.pane == parent))
        else {
            break;
        };
        found.push(*above);
        at = *above;
    }
    found
}

pub(crate) fn scope(edges: &[Edge], caller: PaneId) -> BTreeSet<PaneId> {
    let Some(me) = edges.iter().find(|edge| edge.pane == caller) else {
        return BTreeSet::new();
    };
    let siblings = |of: &Edge| {
        edges
            .iter()
            .filter(|edge| edge.session == me.session && edge.pane != of.pane)
            .filter(|edge| edge.parent == of.parent)
            .map(|edge| edge.pane)
            .collect::<Vec<_>>()
    };
    let mut reach: BTreeSet<PaneId> = children(edges, me)
        .map(|edge| edge.pane)
        .chain(siblings(me))
        .collect();
    for above in ancestors(edges, me)
        .iter()
        .filter(|above| above.session == me.session)
    {
        reach.insert(above.pane);
        reach.extend(siblings(above));
    }
    reach
}

pub(crate) fn is_descendant(edges: &[Edge], caller: PaneId, target: PaneId) -> bool {
    edges
        .iter()
        .find(|edge| edge.pane == target)
        .is_some_and(|edge| {
            ancestors(edges, edge)
                .iter()
                .any(|above| above.pane == caller)
        })
}

pub(crate) fn relation(edges: &[Edge], sender: PaneId, receiver: PaneId) -> Option<Relation> {
    let find = |pane| edges.iter().find(|edge| edge.pane == pane);
    let (from, to) = (find(sender)?, find(receiver)?);
    if from.session != to.session || sender == receiver {
        return None;
    }
    let above = ancestors(edges, from);
    if to.parent == Some(sender) {
        Some(Relation::Parent)
    } else if from.parent == Some(receiver) {
        Some(Relation::Child)
    } else if from.parent == to.parent {
        Some(Relation::Sibling)
    } else if above.iter().any(|edge| edge.pane == receiver) {
        Some(Relation::Descendant)
    } else if above
        .iter()
        .any(|edge| edge.session == from.session && edge.parent == to.parent)
    {
        Some(Relation::SiblingDescendant)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::BUILD;
    use std::path::PathBuf;

    #[test]
    fn a_descendant_is_a_child_or_a_child_of_a_descendant() {
        let edge = |pane, parent: Option<u64>| Edge {
            pane: PaneId::new(pane),
            parent: parent.map(PaneId::new),
            session: SessionId::new(1),
        };
        let edges = [
            edge(1, None),
            edge(2, Some(1)),
            edge(3, Some(2)),
            edge(4, None),
        ];
        let is = |caller, target| is_descendant(&edges, PaneId::new(caller), PaneId::new(target));
        assert!(is(1, 2) && is(1, 3) && is(2, 3));
        assert!(!is(3, 1) && !is(1, 4) && !is(1, 1) && !is(1, 9));
    }

    // 1 and 2 are roots; 3 and 4 are children of 1; 5 is a child of 3;
    // 6 is a root of another session; 7 is a child of 1 in another session.
    fn fixture() -> [Edge; 7] {
        let edge = |pane, parent: Option<u64>, session| Edge {
            pane: PaneId::new(pane),
            parent: parent.map(PaneId::new),
            session: SessionId::new(session),
        };
        [
            edge(1, None, 1),
            edge(2, None, 1),
            edge(3, Some(1), 1),
            edge(4, Some(1), 1),
            edge(5, Some(3), 1),
            edge(6, None, 2),
            edge(7, Some(1), 2),
        ]
    }

    #[test]
    fn the_relation_is_what_the_sender_is_to_the_receiver() {
        let edges = fixture();
        let of = |sender, receiver| relation(&edges, PaneId::new(sender), PaneId::new(receiver));
        assert_eq!(of(1, 3), Some(Relation::Parent));
        assert_eq!(of(3, 5), Some(Relation::Parent));
        assert_eq!(of(3, 1), Some(Relation::Child));
        assert_eq!(of(5, 3), Some(Relation::Child));
        assert_eq!(of(3, 4), Some(Relation::Sibling));
        assert_eq!(of(1, 2), Some(Relation::Sibling));
        assert_eq!(of(5, 1), Some(Relation::Descendant));
        assert_eq!(of(5, 4), Some(Relation::SiblingDescendant));
        assert_eq!(of(5, 2), Some(Relation::SiblingDescendant));
        assert_eq!(of(3, 2), Some(Relation::SiblingDescendant));
        assert_eq!(of(1, 5), None, "a pane cannot reach its descendants");
        assert_eq!(of(4, 5), None);
        assert_eq!(of(6, 1), None, "another session");
        assert_eq!(of(7, 1), None, "another session");
        assert_eq!(of(3, 3), None);
        assert_eq!(of(9, 1), None);
        for sender in 1..=7 {
            for receiver in 1..=7 {
                let reaches = scope(&edges, PaneId::new(sender)).contains(&PaneId::new(receiver));
                assert_eq!(
                    of(sender, receiver).is_some(),
                    reaches,
                    "{sender} to {receiver}"
                );
            }
        }
    }

    #[test]
    fn the_scope_is_children_siblings_ancestors_and_their_siblings_in_one_session() {
        let edges = fixture();
        let scope_of = |pane| {
            scope(&edges, PaneId::new(pane))
                .into_iter()
                .map(|pane| pane.to_string())
                .collect::<Vec<_>>()
        };
        assert_eq!(scope_of(5), ["pane_1", "pane_2", "pane_3", "pane_4"]);
        assert_eq!(scope_of(3), ["pane_1", "pane_2", "pane_4", "pane_5"]);
        assert_eq!(scope_of(1), ["pane_2", "pane_3", "pane_4"]);
        assert_eq!(scope_of(6), Vec::<String>::new());
        assert_eq!(scope_of(9), Vec::<String>::new());
    }

    fn settings() -> Settings {
        config().settings(&ko_config::server::Server::default())
    }

    fn config() -> Config {
        Config {
            dir: PathBuf::from("/tmp"),
            socket: PathBuf::from("/tmp/ko/socket"),
            pane_exe: PathBuf::from("/nonexistent/ko-pane"),
            terminfo: PathBuf::from("/share/terminfo"),
            default_shell: PathBuf::from("/bin/sh"),
            exe: PathBuf::from("/bin/ko"),
            bin_dir: None,
            media: Vec::new(),
            env: vec![
                b"TERM=dumb".to_vec(),
                b"HOME=/home".to_vec(),
                b"LANG=C".to_vec(),
            ],
            cwd: PathBuf::from("/"),
            hostname: String::new(),
            stop_escalation: crate::config::STOP_ESCALATION,
            clipboard_wait: crate::config::CLIPBOARD_WAIT,
            message_ack: crate::config::MESSAGE_ACK,
            view_queue: crate::config::ViewQueue::default(),
            runtimes: crate::config::RuntimesConfig {
                exec_wait: crate::config::RUNTIME_EXEC_WAIT,
                command_kind: false,
            },
            file: PathBuf::from("/tmp/config.yaml"),
        }
    }

    const NOW: u64 = 1_000_000_000_000;
    const GRACE: Duration = Duration::from_secs(1);

    fn seen(id: u64, parent: Option<u64>, close: Close, condition: Condition) -> Seen {
        Seen {
            id: PaneId::new(id),
            condition,
            parent: parent.map(PaneId::new),
            close,
            shown: false,
        }
    }

    fn dead(secs_ago: u64) -> Condition {
        Condition::Dead {
            at: Mono::from_nanos(NOW - secs_ago * 1_000_000_000),
        }
    }

    fn removed(panes: &[Seen]) -> Vec<u64> {
        sweep(panes, Mono::from_nanos(NOW), || GRACE)
            .removed
            .iter()
            .map(|pane| {
                pane.to_string()
                    .trim_start_matches("pane_")
                    .parse()
                    .unwrap()
            })
            .collect()
    }

    #[test]
    fn the_sweep_removes_a_lingered_on_exit_pane_and_a_pane_whose_parent_is_gone_or_dead() {
        let live = Condition::Live;
        let panes = [
            seen(1, None, Close::OnExit, dead(5)),
            seen(2, None, Close::Keep, dead(5)),
            seen(3, None, Close::OnExit, dead(0)),
            seen(4, None, Close::Keep, live),
            seen(5, Some(4), Close::Keep, live),
            seen(6, Some(2), Close::Keep, live),
            seen(7, Some(9), Close::Keep, dead(0)),
        ];
        assert_eq!(removed(&panes), [1, 6, 7]);
        assert_eq!(
            sweep(&panes, Mono::from_nanos(NOW), || GRACE).next,
            Some(GRACE),
            "the young on_exit pane is due when its grace ends"
        );
        let shown = Seen {
            shown: true,
            ..seen(1, None, Close::OnExit, dead(5))
        };
        assert_eq!(removed(&[shown]), Vec::<u64>::new(), "a shown pane stays");
        assert_eq!(standing(&panes, PaneId::new(2)), Standing::Dead);
        assert_eq!(standing(&panes, PaneId::new(4)), Standing::Live);
        assert_eq!(standing(&panes, PaneId::new(8)), Standing::Gone);
    }

    #[test]
    fn exit_removes_focused_dead_panes_but_keeps_failed_starts() {
        let panes = [
            Seen {
                shown: true,
                ..seen(1, None, Close::Exit, dead(0))
            },
            seen(
                2,
                None,
                Close::Exit,
                Condition::Failed {
                    at: Mono::from_nanos(NOW),
                },
            ),
            seen(3, None, Close::Exit, Condition::Live),
            seen(4, None, Close::Keep, dead(0)),
            seen(5, None, Close::OnExit, dead(0)),
        ];
        assert_eq!(removed(&panes), [1]);
        assert_eq!(standing(&panes, PaneId::new(2)), Standing::Dead);
    }

    #[test]
    fn the_sweep_reads_the_linger_once_and_only_for_a_dead_on_exit_pane() {
        let reads = std::cell::Cell::new(0);
        let read = || {
            reads.set(reads.get() + 1);
            GRACE
        };
        let idle = [
            seen(1, None, Close::OnExit, Condition::Live),
            seen(2, None, Close::Keep, dead(5)),
        ];
        sweep(&idle, Mono::from_nanos(NOW), read);
        assert_eq!(reads.get(), 0);
        let two = [
            seen(1, None, Close::OnExit, dead(5)),
            seen(2, None, Close::OnExit, dead(0)),
        ];
        sweep(&two, Mono::from_nanos(NOW), read);
        assert_eq!(reads.get(), 1);
    }

    fn token() -> PaneToken {
        PaneToken::try_from("0123456789abcdef0123456789abcdef".to_owned()).unwrap()
    }

    #[test]
    fn the_forced_variables_override_the_request_and_the_inherited_environment() {
        let requested = [("TERM", "vt100"), ("LANG", "en")].map(|(name, value)| Variable {
            name: name.to_owned(),
            value: value.to_owned(),
        });
        let env: Vec<String> = environment(
            &config(),
            Path::new("/bin/sh"),
            PaneId::new(3),
            &token(),
            &requested,
        )
        .into_iter()
        .map(|entry| String::from_utf8(entry).unwrap())
        .collect();
        assert_eq!(
            env,
            [
                "TERM=xterm-ghostty".to_owned(),
                "TERM_PROGRAM=ko".to_owned(),
                format!("TERM_PROGRAM_VERSION={BUILD}"),
                "TERMINFO_DIRS=/share/terminfo:".to_owned(),
                "KO_SOCKET=/tmp/ko/socket".to_owned(),
                "KO_PANE=pane_3".to_owned(),
                format!("KO_PANE_TOKEN={}", token()),
                "KO_SHELL=/bin/sh".to_owned(),
                "LANG=en".to_owned(),
                "SSH_AUTH_SOCK=/tmp/agent.sock".to_owned(),
                "HOME=/home".to_owned(),
            ]
        );
    }

    #[test]
    fn a_requested_ssh_auth_sock_wins_over_the_default_agent_socket() {
        let requested = [Variable {
            name: "SSH_AUTH_SOCK".to_owned(),
            value: "/mine".to_owned(),
        }];
        let env: Vec<String> = environment(
            &config(),
            Path::new("/bin/sh"),
            PaneId::new(3),
            &token(),
            &requested,
        )
        .into_iter()
        .map(|entry| String::from_utf8(entry).unwrap())
        .filter(|entry| entry.starts_with("SSH_AUTH_SOCK"))
        .collect();
        assert_eq!(env, ["SSH_AUTH_SOCK=/mine".to_owned()]);
    }

    #[test]
    fn a_request_is_checked_before_anything_starts() {
        let mut panes = Panes::default();
        let mut poll = ko_sys::event::Poll::new();
        let mut events = Vec::new();
        let mut io = Io {
            poll: &mut poll,
            events: &mut events,
            sink: &mut crate::pane_proc::discard,
        };
        let request = |command: Option<Command>, env: &[(&str, &str)]| CreatePane {
            cwd: None,
            command,
            env: env
                .iter()
                .map(|(name, value)| Variable {
                    name: (*name).to_owned(),
                    value: (*value).to_owned(),
                })
                .collect(),
            vars: Default::default(),
            parent: None,
            close: Default::default(),
            runtime: None,
        };
        let argv = |argv: &[&str]| {
            Some(Command::Argv {
                argv: argv.iter().map(|a| (*a).to_owned()).collect(),
            })
        };
        let cases = [
            (
                "/",
                request(argv(&["sh"]), &[]),
                "command executable must be absolute",
            ),
            (
                "/",
                request(argv(&["/bin/sh", "a\0b"]), &[]),
                "NUL in pane request",
            ),
            (
                "/nonexistent",
                request(None, &[]),
                "cwd must be a directory",
            ),
            ("/etc/hosts", request(None, &[]), "cwd must be a directory"),
            ("/", request(None, &[("A=B", "c")]), "invalid environment"),
            ("/", request(None, &[("", "c")]), "invalid environment"),
        ];
        let add = |panes: &mut Panes, io: &mut Io<'_>, (cwd, request): (&str, &CreatePane)| {
            let program = program(
                &config(),
                Path::new("/bin/sh"),
                request,
                Start::Host(Some(Path::new(cwd))),
            )?;
            let birth = Birth {
                vars: Default::default(),
                parent: None,
                close: Default::default(),
                runtime: None,
                program,
            };
            panes.add(
                &config(),
                &settings(),
                PaneId::new(1),
                Size::DEFAULT,
                birth,
                io,
            )
        };
        for (cwd, request, message) in cases {
            let refused = add(&mut panes, &mut io, (cwd, &request)).unwrap_err();
            assert_eq!(refused.to_string(), message);
        }
        let spawned = add(&mut panes, &mut io, ("/", &request(None, &[])));
        assert!(matches!(spawned, Err(AddError::Io(_))));
        assert!(panes.iter().next().is_none());
    }

    #[test]
    fn a_runtime_pane_records_the_command_that_was_asked_for_and_runs_the_wrapper() {
        let request = CreatePane {
            cwd: None,
            command: Some(Command::Shell {
                command: "echo hi".to_owned(),
            }),
            env: Vec::new(),
            vars: Default::default(),
            parent: None,
            close: Default::default(),
            runtime: None,
        };
        let wrap = |inner: Option<&[Vec<u8>]>| {
            let mut argv = vec![b"/bin/ko".to_vec(), b"runtime-exec".to_vec()];
            argv.extend(inner.unwrap_or_default().iter().cloned());
            argv
        };
        let program = program(
            &config(),
            Path::new("/bin/sh"),
            &request,
            Start::Runtime(&wrap),
        )
        .unwrap();
        let text = |argv: &[Vec<u8>]| {
            argv.iter()
                .map(|arg| String::from_utf8_lossy(arg).into_owned())
                .collect::<Vec<_>>()
        };
        assert_eq!(text(&program.record), ["/bin/sh", "-c", "echo hi"]);
        assert_eq!(
            text(&program.argv),
            ["/bin/ko", "runtime-exec", "/bin/sh", "-c", "echo hi"]
        );
        assert_eq!(
            program.cwd,
            config().cwd,
            "the wrapper runs where the server does"
        );
    }
}
