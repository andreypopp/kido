use std::fmt;
use std::fs;
use std::io;
use std::path::PathBuf;

use ko_pane_wire::frame::Size;
use ko_sys::event::Token;

use crate::config::{BUILD, Config, variable};
use crate::delivery::{Stamps, mint_stamps};
use crate::ids::PaneId;
use crate::pane::Pane;
use crate::pane_proc::{Io, Launch, Life};
use crate::protocol::{Command, CreatePane, Variable};
use crate::vars::Vars;

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

fn environment(config: &Config, id: PaneId, requested: &[Variable]) -> Vec<Vec<u8>> {
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
    let overrides: Vec<(&str, Vec<u8>)> = forced
        .iter()
        .cloned()
        .chain(
            requested
                .iter()
                .filter(|variable| forced.iter().all(|(forced, _)| *forced != variable.name))
                .map(|variable| (variable.name.as_str(), variable.value.clone().into_bytes())),
        )
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
        vars: Vars,
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
        let env = environment(config, id, &request.env);
        let pane = Pane::spawn(
            config,
            &Launch {
                id,
                cwd: &cwd,
                argv: &command,
                env: &env,
                size,
            },
            vars,
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

    pub(crate) fn kill(&self) -> io::Result<()> {
        self.all().try_for_each(|pane| pane.proc().kill())
    }

    pub(crate) fn reap(&mut self, io: &mut Io<'_>) -> io::Result<()> {
        for pane in self.all_mut() {
            pane.proc_mut().reap(io)?;
        }
        self.removed
            .retain(|pane| pane.proc().life() != Life::Reaped);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
        }
    }

    #[test]
    fn the_forced_variables_override_the_request_and_the_inherited_environment() {
        let requested = [("TERM", "vt100"), ("LANG", "en")].map(|(name, value)| Variable {
            name: name.to_owned(),
            value: value.to_owned(),
        });
        let env: Vec<String> = environment(&config(), PaneId::new(3), &requested)
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
                "KO_SHELL=/bin/sh".to_owned(),
                "LANG=en".to_owned(),
                "HOME=/home".to_owned(),
            ]
        );
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
                    Vars::default(),
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
            Vars::default(),
            &mut io,
        );
        assert!(matches!(spawned, Err(AddError::Io(_))));
        assert!(panes.iter().next().is_none());
    }
}
