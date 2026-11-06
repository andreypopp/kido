use std::path::{Component, Path, PathBuf};

use ko_config::runtime::PathMap;

use crate::ids::PaneId;
use crate::protocol::Variable;
use crate::runtime::RuntimeKey;
use crate::runtime::{Ctx, Tokens};
use crate::ssh::quote_bytes;
use ko_config::runtime::Runtime;

pub(crate) fn directory(root: &Path, key: &RuntimeKey) -> PathBuf {
    root.join(key.tag().to_string())
}

pub(crate) fn clear_directory(root: &Path, key: &RuntimeKey) -> std::io::Result<()> {
    let io = io_directory(root, key);
    for entry in std::fs::read_dir(directory(root, key))? {
        let entry = entry?;
        if entry.path() != io {
            if entry.file_type()?.is_dir() {
                std::fs::remove_dir_all(entry.path())?;
            } else {
                std::fs::remove_file(entry.path())?;
            }
        }
    }
    Ok(())
}

pub(crate) fn io_directory(root: &Path, key: &RuntimeKey) -> PathBuf {
    directory(root, key).join("io")
}

pub(crate) fn control_path(root: &Path, key: &RuntimeKey) -> PathBuf {
    directory(root, key).join(crate::ssh::CONTROL)
}

pub(crate) fn socket_path(root: &Path, key: &RuntimeKey) -> PathBuf {
    io_directory(root, key).join("socket")
}

pub(crate) fn token_directory(root: &Path, key: &RuntimeKey) -> PathBuf {
    directory(root, key).join("panes")
}

pub(crate) fn token_path(
    root: &Path,
    key: &RuntimeKey,
    runtime: &Runtime,
    pane: PaneId,
) -> Option<PathBuf> {
    match super::tokens(runtime, pane) {
        Tokens::File { name: file, .. } => Some(token_directory(root, key).join(file)),
        Tokens::Remote => None,
    }
}

fn translate<'a>(
    pairs: impl Iterator<Item = (&'a Path, &'a Path)>,
    path: &Path,
) -> Option<PathBuf> {
    if path.components().any(|part| part == Component::ParentDir) {
        return None;
    }
    pairs
        .filter_map(|(from, to)| {
            let rest = path.strip_prefix(from).ok()?;
            Some((from.components().count(), to, rest))
        })
        .max_by_key(|(depth, ..)| *depth)
        .map(|(_, to, rest)| to.join(rest))
}

fn map_cwd(paths: &[PathMap], default: Option<&Path>, host_cwd: &Path) -> Option<PathBuf> {
    translate(
        paths.iter().map(|map| {
            (
                Path::new(map.host.as_str()),
                Path::new(map.runtime.as_str()),
            )
        }),
        host_cwd,
    )
    .or_else(|| default.map(Path::to_path_buf))
}

pub(crate) fn host_cwd(paths: &[PathMap], runtime_cwd: &Path) -> Option<PathBuf> {
    translate(
        paths.iter().map(|map| {
            (
                Path::new(map.runtime.as_str()),
                Path::new(map.host.as_str()),
            )
        }),
        runtime_cwd,
    )
}

#[derive(Debug)]
pub(crate) enum Dir {
    Default,
    Host(PathBuf),
    Runtime(PathBuf),
}

impl Dir {
    pub(crate) fn host(&self) -> Option<&Path> {
        match self {
            Dir::Host(path) => Some(path),
            Dir::Runtime(_) | Dir::Default => None,
        }
    }

    pub(crate) fn in_runtime(&self, runtime: &Runtime) -> Option<PathBuf> {
        let default = runtime.cwd.as_ref().map(|cwd| Path::new(cwd.as_str()));
        match self {
            Dir::Runtime(cwd) => Some(cwd.clone()),
            Dir::Host(cwd) => map_cwd(&runtime.paths(), default, cwd),
            Dir::Default => default.map(Path::to_path_buf),
        }
    }
}

pub(crate) struct Wrap<'a> {
    pub(crate) exe: &'a Path,
    pub(crate) root: &'a Path,
    pub(crate) key: &'a RuntimeKey,
    pub(crate) runtime: &'a Runtime,
    pub(crate) pane: PaneId,
    pub(crate) cwd: &'a Dir,
    pub(crate) env: &'a [Variable],
    pub(crate) server_env: &'a [Vec<u8>],
}

fn bytes(path: &Path) -> Vec<u8> {
    path.as_os_str().as_encoded_bytes().to_vec()
}

fn text(text: &str) -> Vec<u8> {
    text.as_bytes().to_vec()
}

pub(crate) fn wrapper(wrap: &Wrap<'_>, inner: Option<&[Vec<u8>]>) -> Vec<Vec<u8>> {
    let mut argv = vec![
        bytes(wrap.exe),
        text("runtime-exec"),
        text(wrap.key.name.as_str()),
        text("--"),
    ];
    argv.extend(transport(wrap, inner));
    argv
}

pub(crate) fn transport(wrap: &Wrap<'_>, inner: Option<&[Vec<u8>]>) -> Vec<Vec<u8>> {
    let Wrap {
        exe,
        root,
        key,
        runtime,
        pane,
        cwd,
        env,
        server_env,
    } = wrap;
    let cwd = cwd.in_runtime(runtime);
    let socket = socket_path(root, key);
    let entry = super::entry(
        runtime,
        *pane,
        &Ctx {
            root,
            key,
            env: server_env,
            socket: &socket,
            exe,
        },
    );
    let mut argv = entry.prefix;
    let mut enter = entry.ko;
    enter.push(text("enter"));
    enter.extend(entry.location);
    enter.extend([text("--pane"), text(&pane.to_string())]);
    enter.extend(entry.token);
    enter.extend([text("--runtime"), text(key.name.as_str())]);
    if let Some(tag) = key.tag_arg() {
        enter.extend([text("--tag"), text(&tag.to_string())]);
    }
    if let Some(cwd) = cwd {
        enter.extend([text("--cwd"), bytes(&cwd)]);
    }
    let requested = env.iter().map(|Variable { name, value }| (name, value));
    for (variable, value) in runtime.env.as_map().iter().chain(requested) {
        enter.extend([text("--env"), text(&format!("{variable}={value}"))]);
    }
    if let Some(inner) = inner {
        enter.push(text("--"));
        enter.extend(inner.iter().cloned());
    }
    if entry.quoted {
        enter = enter.iter().map(|word| quote_bytes(word)).collect();
    }
    argv.extend(enter);
    argv
}

#[cfg(test)]
mod tests {
    use ko_config::values::AbsPath;

    use super::*;

    fn map(host: &str, runtime: &str) -> PathMap {
        PathMap {
            host: AbsPath::try_from(host.to_owned()).unwrap(),
            runtime: AbsPath::try_from(runtime.to_owned()).unwrap(),
        }
    }

    #[test]
    fn a_host_cwd_maps_by_the_longest_matching_prefix_on_whole_components() {
        let paths = [map("/home/me", "/mnt/home"), map("/home/me/src", "/code")];
        let at = |cwd: &str, default: Option<&str>| {
            map_cwd(&paths, default.map(Path::new), Path::new(cwd))
        };
        assert_eq!(at("/home/me/src/ko", None), Some(PathBuf::from("/code/ko")));
        assert_eq!(at("/home/me/src", None), Some(PathBuf::from("/code")));
        assert_eq!(
            at("/home/me/doc", None),
            Some(PathBuf::from("/mnt/home/doc"))
        );
        assert_eq!(at("/home/mex", Some("/root")), Some(PathBuf::from("/root")));
        assert_eq!(at("/home/mex", None), None);
        assert_eq!(at("/elsewhere", None), None);
        assert_eq!(
            at("/home/me/../you", Some("/root")),
            Some(PathBuf::from("/root"))
        );
        assert_eq!(at("/home/me/src/..", None), None);
    }

    #[test]
    fn a_runtime_cwd_maps_back_by_the_longest_matching_prefix_on_whole_components() {
        let paths = [map("/home/me", "/mnt/home"), map("/home/me/src", "/code")];
        let at = |cwd: &str| host_cwd(&paths, Path::new(cwd));
        assert_eq!(at("/code/ko"), Some(PathBuf::from("/home/me/src/ko")));
        assert_eq!(at("/code"), Some(PathBuf::from("/home/me/src")));
        assert_eq!(at("/mnt/home/doc"), Some(PathBuf::from("/home/me/doc")));
        assert_eq!(at("/codex"), None);
        assert_eq!(at("/tmp"), None);
        assert_eq!(at("/code/../etc"), None);
    }
}
