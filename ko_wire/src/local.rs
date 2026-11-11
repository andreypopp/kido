use std::env;
use std::ffi::OsString;
use std::fs;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};

use ko_sys::sock::SUN_PATH_MAX;

pub fn set(name: &str) -> Option<OsString> {
    env::var_os(name).filter(|value| !value.is_empty())
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

pub fn home() -> PathBuf {
    set("HOME")
        .map(PathBuf::from)
        .or_else(env::home_dir)
        .unwrap_or_else(|| PathBuf::from("/"))
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
