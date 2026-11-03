use std::collections::BTreeSet;
use std::fmt;
use std::fs;
use std::io;
use std::path::PathBuf;
use std::time::Duration;

use ko_pane_wire::frame::Size;
use ko_sys::clock::Mono;
use ko_sys::event::Token;

use crate::config::{BUILD, Config, variable};
use crate::delivery::{Stamps, mint_stamps};
use crate::ids::{PaneId, PaneToken, RunId, SessionId};
use crate::pane::{Birth, Pane};
use crate::pane_proc::{Cause, Io, Launch, Life};
use crate::protocol::{Close, Command, CreatePane, Error, ErrorKind, Variable};

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
    id: PaneId,
    token: &PaneToken,
    requested: &[Variable],
) -> Vec<Vec<u8>> {
    let mut terminfo = config.terminfo.as_os_str().as_encoded_bytes().to_vec();
    terminfo.push(b':');
    let mut forced: Vec<(&str, Vec<u8>)> = vec![
        ("TERM", b"xterm-ghostty".to_vec()),
        ("TERM_PROGRAM", b"ko".to_vec()),
        ("TERM_PROGRAM_VERSION", BUILD.as_bytes().to_vec()),
        ("TERMINFO_DIRS", terminfo),
        (
            "KO_SOCKET",
            config.socket.as_os_str().as_encoded_bytes().to_vec(),
        ),
        ("KO_PANE", id.to_string().into_bytes()),
        ("KO_PANE_TOKEN", token.to_string().into_bytes()),
        (
            "KO_SHELL",
            config.shell.as_os_str().as_encoded_bytes().to_vec(),
        ),
    ];
    if let Some(dir) = &config.bin_dir {
        let inherited = config
            .env
            .iter()
            .find_map(|entry| entry.strip_prefix(b"PATH="))
            .unwrap_or_default();
        let mut path = dir.as_os_str().as_encoded_bytes().to_vec();
        for entry in inherited
            .split(|&byte| byte == b':')
            .filter(|entry| !entry.is_empty())
        {
            if entry != dir.as_os_str().as_encoded_bytes() {
                path.push(b':');
                path.extend_from_slice(entry);
            }
        }
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
    let overridden = |entry: &&Vec<u8>| {
        let name = entry.split(|&byte| byte == b'=').next().unwrap_or_default();
        overrides.iter().any(|(set, _)| set.as_bytes() == name)
    };
    let inherited: Vec<Vec<u8>> = config
        .env
        .iter()
        .filter(|entry| !overridden(entry))
        .cloned()
        .collect();
    overrides
        .into_iter()
        .map(|(name, value)| variable(name.as_bytes(), &value))
        .chain(inherited)
        .collect()
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
        id: PaneId,
        size: Size,
        request: &CreatePane,
        birth: Birth,
        io: &mut Io<'_>,
    ) -> Result<(), AddError> {
        let cwd = request
            .cwd
            .as_ref()
            .map_or_else(|| config.cwd.clone(), PathBuf::from);
        let shell = || config.shell.as_os_str().as_encoded_bytes().to_vec();
        let command: Vec<Vec<u8>> = match &request.command {
            None => vec![
                config.exe.as_os_str().as_encoded_bytes().to_vec(),
                b"shell".to_vec(),
            ],
            Some(Command::Argv { argv }) => {
                argv.iter().map(|arg| arg.clone().into_bytes()).collect()
            }
            Some(Command::Shell { command }) => {
                vec![shell(), b"-c".to_vec(), command.clone().into_bytes()]
            }
        };
        if !command
            .first()
            .is_some_and(|executable| executable.starts_with(b"/"))
        {
            return Err(AddError::Invalid("command executable must be absolute"));
        }
        if cwd.is_relative() {
            return Err(AddError::Invalid("cwd must be absolute"));
        }
        let nul = |bytes: &[u8]| bytes.contains(&0);
        if nul(cwd.as_os_str().as_encoded_bytes()) || command.iter().any(|arg| nul(arg)) {
            return Err(AddError::Invalid("NUL in pane request"));
        }
        match fs::metadata(&cwd) {
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
        let invalid = |Variable { name, value }: &Variable| {
            name.is_empty() || name.contains(['=', '\0']) || value.contains('\0')
        };
        if request.env.iter().any(invalid) {
            return Err(AddError::Invalid("invalid environment"));
        }
        let token = PaneToken::mint().map_err(AddError::Io)?;
        let env = environment(config, id, &token, &request.env);
        let pane = Pane::spawn(
            config,
            &Launch {
                id,
                cwd: &cwd,
                argv: &command,
                env: &env,
                size,
            },
            birth,
            token,
            &mut self.stamps,
            io,
        )
        .map_err(AddError::Io)?;
        self.panes.push(pane);
        Ok(())
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
pub(crate) enum Condition<'a> {
    Live,
    Dead { at: Mono, cause: &'a Cause },
}

#[derive(Debug, Clone)]
pub(crate) struct Seen<'a> {
    pub(crate) id: PaneId,
    pub(crate) run: Option<RunId>,
    pub(crate) condition: Condition<'a>,
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

pub(crate) fn standing(panes: &[Seen<'_>], id: PaneId) -> Standing {
    match panes.iter().find(|pane| pane.id == id) {
        None => Standing::Gone,
        Some(pane) if matches!(pane.condition, Condition::Dead { .. }) => Standing::Dead,
        Some(_) => Standing::Live,
    }
}

#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct Swept {
    pub(crate) removed: Vec<PaneId>,
    pub(crate) next: Option<Duration>,
}

pub(crate) fn sweep(panes: &[Seen<'_>], now: Mono, grace: Duration) -> Swept {
    let mut swept = Swept::default();
    for pane in panes {
        let orphan = pane
            .parent
            .is_some_and(|parent| standing(panes, parent) != Standing::Live);
        let lingered = match pane.condition {
            Condition::Dead { at, .. } if pane.close == Close::OnExit => {
                let age = Duration::from_nanos(now.nanos().saturating_sub(at.nanos()));
                if age < grace {
                    let left = grace.saturating_sub(age);
                    swept.next = Some(swept.next.map_or(left, |next| next.min(left)));
                }
                age >= grace
            }
            _ => false,
        };
        if !pane.shown && (orphan || lingered) {
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
    let mut reach: BTreeSet<PaneId> = edges
        .iter()
        .filter(|edge| edge.session == me.session && edge.parent == Some(caller))
        .map(|edge| edge.pane)
        .chain(siblings(me))
        .collect();
    let mut at = me;
    for _ in edges {
        let Some(above) = at
            .parent
            .and_then(|parent| edges.iter().find(|edge| edge.pane == parent))
        else {
            break;
        };
        if above.session == me.session {
            reach.insert(above.pane);
            reach.extend(siblings(above));
        }
        at = above;
    }
    reach
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_scope_is_children_siblings_ancestors_and_their_siblings_in_one_session() {
        let edge = |pane, parent: Option<u64>, session| Edge {
            pane: PaneId::new(pane),
            parent: parent.map(PaneId::new),
            session: SessionId::new(session),
        };
        // 1 and 2 are roots; 3 and 4 are children of 1; 5 is a child of 3;
        // 6 is a root of another session; 7 is a child of 1 in another session.
        let edges = [
            edge(1, None, 1),
            edge(2, None, 1),
            edge(3, Some(1), 1),
            edge(4, Some(1), 1),
            edge(5, Some(3), 1),
            edge(6, None, 2),
            edge(7, Some(1), 2),
        ];
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

    fn config() -> Config {
        Config {
            dir: PathBuf::from("/tmp"),
            socket: PathBuf::from("/tmp/ko/socket"),
            pane_exe: PathBuf::from("/nonexistent/ko-pane"),
            terminfo: PathBuf::from("/share/terminfo"),
            shell: PathBuf::from("/bin/sh"),
            exe: PathBuf::from("/bin/ko"),
            bin_dir: None,
            limits: crate::config::DEFAULT_LIMITS,
            media: Vec::new(),
            env: vec![
                b"TERM=dumb".to_vec(),
                b"HOME=/home".to_vec(),
                b"LANG=C".to_vec(),
            ],
            cwd: PathBuf::from("/"),
            linger: crate::config::LINGER,
            stop_escalation: crate::config::STOP_ESCALATION,
            run_screen_bytes: crate::config::RUN_SCREEN_BYTES,
            clipboard_wait: crate::config::CLIPBOARD_WAIT,
            view_queue: crate::config::ViewQueue::default(),
        }
    }

    const NOW: u64 = 1_000_000_000_000;
    const GRACE: Duration = Duration::from_secs(1);

    fn seen(id: u64, parent: Option<u64>, close: Close, condition: Condition<'_>) -> Seen<'_> {
        Seen {
            id: PaneId::new(id),
            run: None,
            condition,
            parent: parent.map(PaneId::new),
            close,
            shown: false,
        }
    }

    fn dead(secs_ago: u64, cause: &Cause) -> Condition<'_> {
        Condition::Dead {
            at: Mono::from_nanos(NOW - secs_ago * 1_000_000_000),
            cause,
        }
    }

    fn removed(panes: &[Seen<'_>]) -> Vec<u64> {
        sweep(panes, Mono::from_nanos(NOW), GRACE)
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
        let cause = Cause::Exit(ko_sys::pid::Exit::Exited(0));
        let live = Condition::Live;
        let panes = [
            seen(1, None, Close::OnExit, dead(5, &cause)),
            seen(2, None, Close::Keep, dead(5, &cause)),
            seen(3, None, Close::OnExit, dead(0, &cause)),
            seen(4, None, Close::Keep, live),
            seen(5, Some(4), Close::Keep, live),
            seen(6, Some(2), Close::Keep, live),
            seen(7, Some(9), Close::Keep, dead(0, &cause)),
        ];
        assert_eq!(removed(&panes), [1, 6, 7]);
        assert_eq!(
            sweep(&panes, Mono::from_nanos(NOW), GRACE).next,
            Some(GRACE),
            "the young on_exit pane is due when its grace ends"
        );
        let shown = Seen {
            shown: true,
            ..seen(1, None, Close::OnExit, dead(5, &cause))
        };
        assert_eq!(removed(&[shown]), Vec::<u64>::new(), "a shown pane stays");
        assert_eq!(standing(&panes, PaneId::new(2)), Standing::Dead);
        assert_eq!(standing(&panes, PaneId::new(4)), Standing::Live);
        assert_eq!(standing(&panes, PaneId::new(8)), Standing::Gone);
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
        let env: Vec<String> = environment(&config(), PaneId::new(3), &token(), &requested)
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
        let env: Vec<String> = environment(&config(), PaneId::new(3), &token(), &requested)
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
        let request = |cwd: &str, command: Option<Command>, env: &[(&str, &str)]| CreatePane {
            cwd: Some(cwd.to_owned()),
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
        };
        let argv = |argv: &[&str]| {
            Some(Command::Argv {
                argv: argv.iter().map(|a| (*a).to_owned()).collect(),
            })
        };
        let cases = [
            (
                request("/", argv(&["sh"]), &[]),
                "command executable must be absolute",
            ),
            (request("tmp", None, &[]), "cwd must be absolute"),
            (
                request("/", argv(&["/bin/sh", "a\0b"]), &[]),
                "NUL in pane request",
            ),
            (
                request("/nonexistent", None, &[]),
                "cwd must be a directory",
            ),
            (request("/etc/hosts", None, &[]), "cwd must be a directory"),
            (request("/", None, &[("A=B", "c")]), "invalid environment"),
            (request("/", None, &[("", "c")]), "invalid environment"),
        ];
        for (request, message) in cases {
            let refused = panes
                .add(
                    &config(),
                    PaneId::new(1),
                    Size::DEFAULT,
                    &request,
                    Birth::default(),
                    &mut io,
                )
                .unwrap_err();
            assert_eq!(refused.to_string(), message);
        }
        let spawned = panes.add(
            &config(),
            PaneId::new(1),
            Size::DEFAULT,
            &request("/", None, &[]),
            Birth::default(),
            &mut io,
        );
        assert!(matches!(spawned, Err(AddError::Io(_))));
        assert!(panes.iter().next().is_none());
    }
}
