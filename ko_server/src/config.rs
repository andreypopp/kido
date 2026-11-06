use std::cell::OnceCell;
use std::env;
use std::ffi::OsString;
use std::fs;
use std::io;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::Duration;

use ko_config::config::LoadError;
use ko_config::server::{Scrollback as Kept, Server};
use ko_pane_wire::frame::{Limits, Medium, Scrollback};

pub(crate) const BUILD: &str = env!("KO_BUILD");

pub const SUN_PATH_MAX: usize = 103;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Config {
    pub dir: PathBuf,
    pub socket: PathBuf,
    pub pane_exe: PathBuf,
    pub terminfo: PathBuf,
    pub default_shell: PathBuf,
    pub exe: PathBuf,
    pub bin_dir: Option<PathBuf>,
    pub media: Vec<Medium>,
    pub env: Vec<Vec<u8>>,
    pub cwd: PathBuf,
    pub hostname: String,
    pub stop_escalation: Duration,
    pub clipboard_wait: Duration,
    pub message_ack: Duration,
    pub view_queue: ViewQueue,
    pub runtimes: RuntimesConfig,
    pub file: PathBuf,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuntimesConfig {
    pub exec_wait: Duration,
    pub command_kind: bool,
}

pub const RUNTIME_EXEC_WAIT: Duration = Duration::from_secs(30);

pub(crate) const QUEUE_BYTES: usize = 64 << 20;
const SPILL_BYTES: u64 = 1 << 30;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ViewQueue {
    pub cap_bytes: usize,
    pub spill_bytes: u64,
}

impl Default for ViewQueue {
    fn default() -> ViewQueue {
        ViewQueue {
            cap_bytes: QUEUE_BYTES,
            spill_bytes: SPILL_BYTES,
        }
    }
}

pub const STOP_ESCALATION: Duration = Duration::from_secs(5);
pub const CLIPBOARD_WAIT: Duration = Duration::from_secs(8);
pub const MESSAGE_ACK: Duration = Duration::from_secs(2);

fn limits(server: &Server) -> Limits {
    Limits {
        scrollback: match server.scrollback {
            Kept::Off => Scrollback::Disabled,
            Kept::Bounded(bounds) => Scrollback::Bounded {
                max_bytes: bounds.bytes.get(),
                max_lines: bounds.lines.get(),
            },
        },
        apc_max_bytes: 65 << 20,
        kitty_images_max_bytes: server.kitty_images_max_bytes.get() as u64,
        continuation_max_bytes: 65 << 20,
    }
}

pub fn default_limits() -> Limits {
    limits(&Server::default())
}

pub(crate) fn server_settings(file: &Path) -> Server {
    Read::new(file).server()
}

#[derive(Debug)]
pub(crate) struct Read {
    file: PathBuf,
    loaded: OnceCell<Result<ko_config::config::Config, LoadError>>,
}

impl Read {
    pub(crate) fn new(file: &Path) -> Read {
        Read {
            file: file.to_path_buf(),
            loaded: OnceCell::new(),
        }
    }

    pub(crate) fn get(&self) -> &Result<ko_config::config::Config, LoadError> {
        self.loaded
            .get_or_init(|| ko_config::config::load(&self.file))
    }

    pub(crate) fn server(&self) -> Server {
        self.get()
            .as_ref()
            .map(|config| config.server.clone())
            .unwrap_or_default()
    }
}

#[derive(Debug, Clone)]
pub(crate) struct Settings {
    pub(crate) shell: PathBuf,
    pub(crate) limits: Limits,
}

pub fn scratch(dir: &Path, pane_exe: PathBuf) -> Config {
    Config {
        dir: dir.to_path_buf(),
        socket: dir.join("socket"),
        pane_exe,
        terminfo: dir.to_path_buf(),
        default_shell: PathBuf::from("/bin/sh"),
        exe: PathBuf::from("/nonexistent/ko"),
        bin_dir: None,
        media: Vec::new(),
        env: Vec::new(),
        cwd: PathBuf::from("/"),
        hostname: String::new(),
        stop_escalation: STOP_ESCALATION,
        clipboard_wait: CLIPBOARD_WAIT,
        message_ack: MESSAGE_ACK,
        view_queue: ViewQueue::default(),
        runtimes: RuntimesConfig {
            exec_wait: RUNTIME_EXEC_WAIT,
            command_kind: false,
        },
        file: dir.join("config.yaml"),
    }
}

pub fn variable(name: &[u8], value: &[u8]) -> Vec<u8> {
    [name, b"=", value].concat()
}

/// The given variables, then the inherited ones that they do not replace.
pub fn overlay(given: &[(&[u8], &[u8])], inherited: &[Vec<u8>]) -> Vec<Vec<u8>> {
    let replaced = |entry: &&Vec<u8>| {
        let name = entry.split(|&byte| byte == b'=').next().unwrap_or_default();
        given.iter().any(|(set, _)| *set == name)
    };
    given
        .iter()
        .map(|(name, value)| variable(name, value))
        .chain(inherited.iter().filter(|entry| !replaced(entry)).cloned())
        .collect()
}

fn set(name: &str) -> Option<OsString> {
    env::var_os(name).filter(|value| !value.is_empty())
}

fn count(value: Option<OsString>) -> Option<u64> {
    value?.to_str()?.parse().ok().filter(|count| *count > 0)
}

fn positive(name: &str) -> Option<u64> {
    count(set(name))
}

pub fn dir(chosen: Option<PathBuf>) -> PathBuf {
    if let Some(dir) = chosen.or_else(|| set("KO_STATE_DIR").map(PathBuf::from)) {
        return dir;
    }
    if let Some(state) = set("XDG_STATE_HOME") {
        return PathBuf::from(state).join("ko");
    }
    home().join(".local/state/ko")
}

fn home() -> PathBuf {
    set("HOME")
        .map(PathBuf::from)
        .or_else(env::home_dir)
        .unwrap_or_else(|| PathBuf::from("/"))
}

fn config_file(chosen: Option<PathBuf>) -> PathBuf {
    chosen.unwrap_or_else(|| {
        ko_config::config::default_path(
            set("XDG_CONFIG_HOME").map(PathBuf::from).as_deref(),
            &home(),
        )
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Dir {
    Create,
    Existing,
    /// The server of the caller's own pane, which KO_SOCKET named.
    Own,
}

pub fn socket_path(dir: &Path) -> Result<PathBuf, String> {
    let socket = dir.join("socket");
    if dir.as_os_str().as_encoded_bytes().contains(&b',') {
        return Err("server directory contains a comma".to_owned());
    }
    if socket.as_os_str().len() > SUN_PATH_MAX {
        return Err(format!("server socket path exceeds {SUN_PATH_MAX} bytes"));
    }
    Ok(socket)
}

pub fn socket(mode: Dir, dir: &Path) -> Result<PathBuf, String> {
    let socket = socket_path(dir)?;
    if mode == Dir::Create {
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(dir)
            .map_err(|error| error.to_string())?;
    }
    let meta = fs::symlink_metadata(dir).map_err(|error| error.to_string())?;
    if !meta.is_dir() {
        Err("server path is not a directory".to_owned())
    } else if mode == Dir::Own {
        // A container runtime makes the parent of the mounted socket, root-owned and 0755.
        Ok(socket)
    } else if meta.uid() != ko_sys::sock::uid() {
        Err("server directory is not owned by this user".to_owned())
    } else if meta.permissions().mode() & 0o077 != 0 {
        Err("server directory is accessible to other users".to_owned())
    } else {
        Ok(socket)
    }
}

pub const TERM_NAME: &str = "xterm-ghostty";

pub fn terminal(terminfo: Option<&Path>) -> Vec<(&'static str, Vec<u8>)> {
    let mut found = vec![
        ("TERM", TERM_NAME.as_bytes().to_vec()),
        ("TERM_PROGRAM", b"ko".to_vec()),
        ("TERM_PROGRAM_VERSION", BUILD.as_bytes().to_vec()),
    ];
    if let Some(terminfo) = terminfo {
        let mut dirs = terminfo.as_os_str().as_encoded_bytes().to_vec();
        dirs.push(b':');
        found.push(("TERMINFO_DIRS", dirs));
    }
    found
}

pub fn path_with(dir: &Path, inherited: &[u8]) -> Vec<u8> {
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
    path
}

pub fn look_path(path: &str, name: &str) -> Option<PathBuf> {
    path.split(':')
        .map(|dir| Path::new(if dir.is_empty() { "." } else { dir }).join(name))
        .find(|candidate| is_executable(candidate))
}

pub fn env_path(env: &[Vec<u8>]) -> &[u8] {
    env.iter()
        .find_map(|entry| entry.strip_prefix(b"PATH="))
        .unwrap_or_default()
}

pub fn program_path(path: &str, program: &str) -> Option<PathBuf> {
    if program.contains('/') {
        Some(PathBuf::from(program))
    } else {
        look_path(path, program)
    }
}

pub fn installed(exe: &Path, relative: &str) -> Vec<PathBuf> {
    candidates(exe)
        .iter()
        .filter_map(|exe| Some(exe.parent()?.parent()?.join(relative)))
        .collect()
}

pub fn terminfo_of(exe: &Path) -> Option<PathBuf> {
    installed(exe, "share/ko/terminfo")
        .into_iter()
        .find(|path| path.exists())
}

fn candidates(exe: &Path) -> Vec<PathBuf> {
    let resolved = fs::canonicalize(exe)
        .ok()
        .filter(|resolved| resolved != exe);
    std::iter::once(exe.to_path_buf()).chain(resolved).collect()
}

pub fn is_executable(path: &Path) -> bool {
    fs::metadata(path).is_ok_and(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
}

fn shipped(exe: &Path) -> Result<(PathBuf, PathBuf), String> {
    let candidates = candidates(exe);
    let beside = |name: &'static str| {
        candidates
            .iter()
            .filter_map(move |exe| Some(exe.parent()?.join(name)))
    };
    let pane_exe = beside("ko-pane")
        .find(|path| is_executable(path))
        .ok_or("ko-pane was not found beside ko")?;
    let terminfo =
        terminfo_of(exe).unwrap_or_else(|| pane_exe.with_file_name("../share/ko/terminfo"));
    Ok((pane_exe, terminfo))
}

impl Config {
    pub(crate) fn settings(&self, server: &Server) -> Settings {
        Settings {
            shell: server.shell.as_ref().map_or_else(
                || self.default_shell.clone(),
                |shell| PathBuf::from(shell.as_str()),
            ),
            limits: limits(server),
        }
    }

    pub(crate) fn linger(&self) -> Duration {
        server_settings(&self.file).linger_seconds.duration()
    }

    pub fn create(
        exe: &Path,
        chosen: Option<PathBuf>,
        bin_dir: Option<PathBuf>,
        file: Option<PathBuf>,
    ) -> Result<Config, String> {
        let default_shell = set("SHELL")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/bin/sh"));
        let (pane_exe, terminfo) = shipped(exe)?;
        if default_shell.is_relative() {
            return Err("shell must be an absolute path".to_owned());
        }
        let exe = std::path::absolute(exe).map_err(|error| error.to_string())?;
        let bin_dir = bin_dir
            .map(|dir| std::path::absolute(dir).map_err(|error| error.to_string()))
            .transpose()?;
        let file = std::path::absolute(config_file(file)).map_err(|error| error.to_string())?;
        let dir = dir(chosen);
        let socket = socket(Dir::Create, &dir)?;
        let cwd = env::current_dir().map_err(|error: io::Error| error.to_string())?;
        Ok(Config {
            dir,
            socket,
            pane_exe,
            terminfo,
            default_shell,
            exe,
            bin_dir,
            media: vec![Medium::SharedMem],
            env: env::vars_os()
                .map(|(name, value)| variable(name.as_encoded_bytes(), value.as_encoded_bytes()))
                .collect(),
            cwd,
            hostname: ko_sys::host::name().unwrap_or_default(),
            stop_escalation: positive("KO_STOP_ESCALATION_MS")
                .map_or(STOP_ESCALATION, Duration::from_millis),
            clipboard_wait: positive("KO_CLIPBOARD_TIMEOUT_MS")
                .map_or(CLIPBOARD_WAIT, Duration::from_millis),
            message_ack: positive("KO_MESSAGE_ACK_MS").map_or(MESSAGE_ACK, Duration::from_millis),
            view_queue: ViewQueue {
                cap_bytes: positive("KO_VIEW_QUEUE_BYTES")
                    .and_then(|bytes| usize::try_from(bytes).ok())
                    .unwrap_or(QUEUE_BYTES),
                spill_bytes: positive("KO_VIEW_SPILL_BYTES").unwrap_or(SPILL_BYTES),
            },
            runtimes: RuntimesConfig {
                exec_wait: positive("KO_RUNTIME_EXEC_WAIT_MS")
                    .map_or(RUNTIME_EXEC_WAIT, Duration::from_millis),
                command_kind: set("KO_RUNTIME_COMMAND_KIND").is_some_and(|value| value == "1"),
            },
            file,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_server_directory_must_be_private_and_short() {
        let scratch = tempdir();
        let dir = scratch.join("state");
        assert_eq!(socket(Dir::Create, &dir), Ok(dir.join("socket")));
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(
            socket(Dir::Existing, &dir),
            Err("server directory is accessible to other users".to_owned())
        );
        assert_eq!(
            socket(Dir::Existing, &scratch.join("a,b")),
            Err("server directory contains a comma".to_owned())
        );
        assert_eq!(
            socket(Dir::Existing, &scratch.join("x".repeat(100))),
            Err("server socket path exceeds 103 bytes".to_owned())
        );
        fs::remove_dir_all(scratch).unwrap();
    }

    #[test]
    fn a_duration_knob_is_a_positive_whole_number_or_the_default() {
        let read = |text: &str| count(Some(OsString::from(text)));
        assert_eq!(
            (
                read("30"),
                read("1"),
                read("0"),
                read("-2"),
                read("1.5"),
                read(""),
                read("x")
            ),
            (Some(30), Some(1), None, None, None, None, None)
        );
        assert_eq!(count(None), None);
    }

    fn tempdir() -> PathBuf {
        let dir = PathBuf::from(format!("/tmp/ko-config-{}", std::process::id()));
        fs::create_dir(&dir).unwrap();
        dir
    }
}
