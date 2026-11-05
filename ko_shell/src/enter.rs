use std::ffi::OsStr;
use std::fmt;
use std::fs::{self, File};
use std::io::{self, Read};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;

use ko_config::values::RuntimeName;
use ko_server::config::{path_with, terminal, terminfo_of};
use ko_server::ids::{PaneId, PaneToken};
use ko_server::ssh;

use crate::bin_dir;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TokenSource {
    File(PathBuf),
    Environment(Option<String>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Enter {
    pub socket: PathBuf,
    pub pane: PaneId,
    pub token: PaneToken,
    pub runtime: RuntimeName,
    pub cwd: Option<PathBuf>,
    pub env: Vec<(String, String)>,
    pub command: Vec<String>,
    pub path: String,
    pub agent: bool,
}

#[derive(Debug)]
pub struct Cwd {
    dir: PathBuf,
    message: String,
}

impl fmt::Display for Cwd {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "cwd {}: {}", self.dir.display(), self.message)
    }
}

#[derive(Debug)]
pub enum Failure {
    Cwd(Cwd),
    Exec(io::Error),
}

impl fmt::Display for Failure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Failure::Cwd(cwd) => cwd.fmt(f),
            Failure::Exec(error) => error.fmt(f),
        }
    }
}

fn os_message(error: &io::Error) -> String {
    let text = error.to_string();
    match text.rfind(" (os error ") {
        Some(at) => text.get(..at).unwrap_or(&text).to_owned(),
        None => text,
    }
}

fn read_private(path: &Path) -> Option<String> {
    let mut file = File::options()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .ok()?;
    let meta = file.metadata().ok()?;
    let private = meta.is_file() && meta.mode() & 0o077 == 0 && meta.uid() == ko_sys::sock::uid();
    let mut text = String::new();
    let read = private
        .then(|| file.read_to_string(&mut text))
        .and_then(Result::ok);
    let _ = fs::remove_file(path);
    read.map(|_| text)
}

pub fn token(source: &TokenSource) -> Option<PaneToken> {
    let text = match source {
        TokenSource::Environment(value) => value.clone()?,
        TokenSource::File(path) => read_private(path)?,
    };
    text.trim().parse().ok()
}

fn forwarded(env: &[(String, String)], agent: bool) -> impl Iterator<Item = &(String, String)> {
    env.iter()
        .filter(move |(name, _)| !(agent && name == "SSH_AUTH_SOCK"))
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteDir {
    pub dir: PathBuf,
    base: Option<PathBuf>,
}

impl RemoteDir {
    pub fn socket(&self) -> PathBuf {
        self.dir.join(ssh::SOCKET)
    }

    pub fn token_file(&self, pane: PaneId) -> PathBuf {
        self.dir.join(ssh::token_name(pane))
    }
}

pub fn remote_dir(
    runtime: &RuntimeName,
    chosen: Option<PathBuf>,
    xdg_runtime_dir: Option<&str>,
    uid: u32,
) -> RemoteDir {
    if let Some(dir) = chosen {
        return RemoteDir { dir, base: None };
    }
    let base = match xdg_runtime_dir.filter(|dir| dir.starts_with('/')) {
        Some(xdg) => Path::new(xdg).join("ko-rt"),
        None => PathBuf::from(format!("/tmp/ko-rt-{uid}")),
    };
    RemoteDir {
        dir: base.join(runtime.as_str()),
        base: Some(base),
    }
}

#[derive(Debug)]
pub enum PrepareError {
    Create(PathBuf, io::Error),
    NotPrivate(PathBuf),
    Clear(PathBuf, io::Error),
}

impl fmt::Display for PrepareError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PrepareError::Create(dir, error) => {
                write!(f, "{}: {}", dir.display(), os_message(error))
            }
            PrepareError::NotPrivate(dir) => {
                write!(
                    f,
                    "{} is not a private directory of this user",
                    dir.display()
                )
            }
            PrepareError::Clear(dir, error) => {
                write!(f, "cannot clear {}: {}", dir.display(), os_message(error))
            }
        }
    }
}

fn private_dir(dir: &Path) -> Result<(), PrepareError> {
    let private = fs::symlink_metadata(dir).is_ok_and(|meta| {
        meta.is_dir() && meta.mode() & 0o077 == 0 && meta.uid() == ko_sys::sock::uid()
    });
    if private {
        Ok(())
    } else {
        Err(PrepareError::NotPrivate(dir.to_path_buf()))
    }
}

pub fn prepare(remote: &RemoteDir) -> Result<(), PrepareError> {
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&remote.dir)
        .map_err(|error| PrepareError::Create(remote.dir.clone(), error))?;
    if let Some(base) = &remote.base {
        private_dir(base)?;
    }
    private_dir(&remote.dir)?;
    let clear = |error| PrepareError::Clear(remote.dir.clone(), error);
    for entry in fs::read_dir(&remote.dir).map_err(clear)? {
        let name = entry.map_err(clear)?.file_name();
        let stale = name == ssh::SOCKET
            || name
                .as_encoded_bytes()
                .ends_with(ssh::TOKEN_SUFFIX.as_bytes());
        if stale {
            fs::remove_file(remote.dir.join(name)).map_err(clear)?;
        }
    }
    Ok(())
}

pub(crate) fn check_cwd(dir: &Path) -> Result<(), Cwd> {
    let message = match fs::metadata(dir) {
        Ok(meta) if meta.is_dir() => return Ok(()),
        Ok(_) => "Not a directory".to_owned(),
        Err(error) => os_message(&error),
    };
    Err(Cwd {
        dir: dir.to_path_buf(),
        message,
    })
}

pub fn exec(enter: &Enter, exe: &Path) -> Failure {
    let token = &enter.token;
    if let Some(dir) = &enter.cwd
        && let Err(cwd) = check_cwd(dir)
    {
        return Failure::Cwd(cwd);
    }
    let mut process = Command::new(exe);
    process.arg("shell");
    if !enter.command.is_empty() {
        process.arg("--").args(&enter.command);
    }
    if let Some(dir) = &enter.cwd {
        process.current_dir(dir);
    }
    process.envs(forwarded(&enter.env, enter.agent).map(|(name, value)| (name, value)));
    process
        .env("KO_SOCKET", &enter.socket)
        .env("KO_PANE", enter.pane.to_string())
        .env("KO_PANE_TOKEN", token.to_string())
        .env("KO_RUNTIME", enter.runtime.as_str());
    for (name, value) in terminal(terminfo_of(exe).as_deref()) {
        process.env(name, OsStr::from_bytes(&value));
    }
    if let Some(bin_dir) = bin_dir::of_exe(exe) {
        let inherited = enter
            .env
            .iter()
            .rev()
            .find(|(name, _)| name == "PATH")
            .map_or(enter.path.as_str(), |(_, value)| value.as_str());
        process.env(
            "PATH",
            OsStr::from_bytes(&path_with(&bin_dir, inherited.as_bytes())),
        );
    }
    Failure::Exec(process.exec())
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::{PermissionsExt, symlink};

    use super::*;
    use crate::test_support::{scratch, write};

    const TOKEN: &str = "0123456789abcdef0123456789abcdef";

    #[test]
    fn a_token_file_is_read_once_and_only_when_private() {
        let dir = scratch("enter-token");
        let private = write(&dir.join("private"), TOKEN, 0o600);
        let open = write(&dir.join("open"), TOKEN, 0o644);
        let source = |path: &Path| TokenSource::File(path.to_path_buf());
        assert_eq!(
            token(&source(&private)).map(|t| t.to_string()),
            Some(TOKEN.to_owned())
        );
        assert!(!private.exists());
        assert!(token(&source(&private)).is_none());
        fs::set_permissions(&open, fs::Permissions::from_mode(0o644)).unwrap();
        assert!(token(&source(&open)).is_none());
        assert!(!open.exists());
        assert!(token(&source(&dir.join("absent"))).is_none());
    }

    #[test]
    fn a_token_file_that_is_a_symlink_is_not_followed() {
        let dir = scratch("enter-link");
        let target = write(&dir.join("target"), TOKEN, 0o600);
        let link = dir.join("link");
        symlink(&target, &link).unwrap();
        assert!(token(&TokenSource::File(link)).is_none());
        assert!(target.exists(), "the file behind the link stays");
    }

    #[test]
    fn an_environment_token_is_the_given_value() {
        assert!(token(&TokenSource::Environment(Some(TOKEN.to_owned()))).is_some());
        assert!(token(&TokenSource::Environment(None)).is_none());
        assert!(token(&TokenSource::Environment(Some("short".to_owned()))).is_none());
    }

    #[test]
    fn an_inherited_agent_socket_is_not_overridden_by_an_env_option() {
        let env = vec![
            ("SSH_AUTH_SOCK".to_owned(), "/x".to_owned()),
            ("A".to_owned(), "1".to_owned()),
        ];
        let names = |agent| -> Vec<&str> {
            forwarded(&env, agent)
                .map(|(name, _)| name.as_str())
                .collect()
        };
        assert_eq!(names(true), ["A"]);
        assert_eq!(names(false), ["SSH_AUTH_SOCK", "A"]);
    }

    #[test]
    fn the_remote_directory_is_the_chosen_one_else_a_private_default() {
        let dev: RuntimeName = "dev".parse().unwrap();
        let at = |chosen: Option<&str>, xdg: Option<&str>| {
            remote_dir(&dev, chosen.map(PathBuf::from), xdg, 501).dir
        };
        assert_eq!(
            at(Some("/srv/ko"), Some("/run/user/501")),
            Path::new("/srv/ko")
        );
        assert_eq!(
            at(None, Some("/run/user/501")),
            Path::new("/run/user/501/ko-rt/dev")
        );
        assert_eq!(at(None, None), Path::new("/tmp/ko-rt-501/dev"));
        assert_eq!(at(None, Some("relative")), Path::new("/tmp/ko-rt-501/dev"));
    }

    #[test]
    fn preparing_refuses_a_default_base_that_is_open_and_a_directory_behind_a_link() {
        let base = scratch("enter-prepare");
        let dir = base.join("rt/dev");
        let remote = RemoteDir {
            dir: dir.clone(),
            base: Some(base.join("rt")),
        };
        prepare(&remote).unwrap();
        assert_eq!(fs::metadata(base.join("rt")).unwrap().mode() & 0o777, 0o700);
        fs::set_permissions(base.join("rt"), fs::Permissions::from_mode(0o755)).unwrap();
        assert!(matches!(prepare(&remote), Err(PrepareError::NotPrivate(_))));
        let link = base.join("link");
        symlink(&dir, &link).unwrap();
        let through = RemoteDir {
            dir: link,
            base: None,
        };
        assert!(matches!(
            prepare(&through),
            Err(PrepareError::NotPrivate(_))
        ));
    }

    #[test]
    fn a_missing_directory_has_the_message_without_the_os_number() {
        let error = fs::metadata("/nonexistent/ko-enter").unwrap_err();
        assert_eq!(os_message(&error), "No such file or directory");
    }
}
