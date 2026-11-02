use std::env;
use std::ffi::OsString;
use std::fs;
use std::io;
use std::num::NonZeroUsize;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};

use ko_pane_wire::frame::{Limits, Medium, Scrollback};

pub(crate) const BUILD: &str = env!("KO_BUILD");

const SUN_PATH_MAX: usize = 103;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Config {
    pub dir: PathBuf,
    pub socket: PathBuf,
    pub pane_exe: PathBuf,
    pub terminfo: PathBuf,
    pub shell: PathBuf,
    pub exe: PathBuf,
    pub bin_dir: Option<PathBuf>,
    pub limits: Limits,
    pub media: Vec<Medium>,
    pub env: Vec<Vec<u8>>,
    pub cwd: PathBuf,
}

pub const DEFAULT_LIMITS: Limits = Limits {
    scrollback: Scrollback::Bounded {
        max_bytes: NonZeroUsize::new(50_000_000),
        max_lines: None,
    },
    apc_max_bytes: 65 << 20,
    kitty_images_max_bytes: 10_000_000,
    continuation_max_bytes: 65 << 20,
};

pub fn scratch(dir: &Path, pane_exe: PathBuf, limits: Limits) -> Config {
    Config {
        dir: dir.to_path_buf(),
        socket: dir.join("socket"),
        pane_exe,
        terminfo: dir.to_path_buf(),
        shell: PathBuf::from("/bin/sh"),
        exe: PathBuf::from("/nonexistent/ko"),
        bin_dir: None,
        limits,
        media: Vec::new(),
        env: Vec::new(),
        cwd: PathBuf::from("/"),
    }
}

pub(crate) fn variable(name: &[u8], value: &[u8]) -> Vec<u8> {
    [name, b"=", value].concat()
}

fn set(name: &str) -> Option<OsString> {
    env::var_os(name).filter(|value| !value.is_empty())
}

pub fn dir(chosen: Option<PathBuf>) -> PathBuf {
    if let Some(dir) = chosen.or_else(|| set("KO_STATE_DIR").map(PathBuf::from)) {
        return dir;
    }
    if let Some(state) = set("XDG_STATE_HOME") {
        return PathBuf::from(state).join("ko");
    }
    let home = set("HOME")
        .map(PathBuf::from)
        .or_else(env::home_dir)
        .unwrap_or_else(|| PathBuf::from("/"));
    home.join(".local/state/ko")
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Dir {
    Create,
    Existing,
}

pub fn socket(mode: Dir, dir: &Path) -> Result<PathBuf, String> {
    let socket = dir.join("socket");
    if dir.as_os_str().as_encoded_bytes().contains(&b',') {
        return Err("server directory contains a comma".to_owned());
    }
    if socket.as_os_str().len() > SUN_PATH_MAX {
        return Err(format!("server socket path exceeds {SUN_PATH_MAX} bytes"));
    }
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
    } else if meta.uid() != ko_sys::sock::uid() {
        Err("server directory is not owned by this user".to_owned())
    } else if meta.permissions().mode() & 0o077 != 0 {
        Err("server directory is accessible to other users".to_owned())
    } else {
        Ok(socket)
    }
}

pub fn candidates(exe: &Path) -> Vec<PathBuf> {
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
    let terminfo = beside("../share/ko/terminfo")
        .find(|path| path.exists())
        .unwrap_or_else(|| pane_exe.with_file_name("../share/ko/terminfo"));
    Ok((pane_exe, terminfo))
}

impl Config {
    pub fn create(
        exe: &Path,
        chosen: Option<PathBuf>,
        shell: Option<PathBuf>,
        bin_dir: Option<PathBuf>,
        scrollback: Scrollback,
    ) -> Result<Config, String> {
        let shell = shell
            .or_else(|| set("SHELL").map(PathBuf::from))
            .unwrap_or_else(|| PathBuf::from("/bin/sh"));
        let (pane_exe, terminfo) = shipped(exe)?;
        if shell.is_relative() {
            return Err("shell must be an absolute path".to_owned());
        }
        let exe = std::path::absolute(exe).map_err(|error| error.to_string())?;
        let bin_dir = bin_dir
            .map(|dir| std::path::absolute(dir).map_err(|error| error.to_string()))
            .transpose()?;
        let dir = dir(chosen);
        let socket = socket(Dir::Create, &dir)?;
        let cwd = env::current_dir().map_err(|error: io::Error| error.to_string())?;
        Ok(Config {
            dir,
            socket,
            pane_exe,
            terminfo,
            shell,
            exe,
            bin_dir,
            limits: Limits {
                scrollback,
                ..DEFAULT_LIMITS
            },
            media: Vec::new(),
            env: env::vars_os()
                .map(|(name, value)| variable(name.as_encoded_bytes(), value.as_encoded_bytes()))
                .collect(),
            cwd,
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

    fn tempdir() -> PathBuf {
        let dir = PathBuf::from(format!("/tmp/ko-config-{}", std::process::id()));
        fs::create_dir(&dir).unwrap();
        dir
    }
}
