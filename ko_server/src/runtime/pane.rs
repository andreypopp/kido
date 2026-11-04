use std::path::{Path, PathBuf};

use crate::ids::{PaneId, RuntimeName};
use crate::protocol::{PathMap, Variable};
use crate::runtime::file::Runtime;
use crate::runtime::{Ctx, Tokens};
use crate::ssh::quote_bytes;

pub(crate) fn directory(root: &Path, name: &RuntimeName) -> PathBuf {
    root.join(name.as_str())
}

pub(crate) fn socket_path(root: &Path, name: &RuntimeName) -> PathBuf {
    directory(root, name).join("socket")
}

pub(crate) fn token_directory(root: &Path, name: &RuntimeName) -> PathBuf {
    directory(root, name).join("panes")
}

pub(crate) fn token_path(socket: &Path, runtime: &Runtime, pane: PaneId) -> Option<PathBuf> {
    match runtime.tokens(pane) {
        Tokens::File { name, .. } => Some(socket.with_file_name("panes").join(name)),
        Tokens::Remote => None,
    }
}

fn map_cwd(paths: &[PathMap], default: Option<&Path>, host_cwd: &Path) -> Option<PathBuf> {
    paths
        .iter()
        .filter_map(|map| {
            let rest = host_cwd.strip_prefix(map.host.as_path()).ok()?;
            Some((map.host.as_path().components().count(), map, rest))
        })
        .max_by_key(|(depth, ..)| *depth)
        .map(|(_, map, rest)| map.runtime.as_path().join(rest))
        .or_else(|| default.map(Path::to_path_buf))
}

pub(crate) struct Wrap<'a> {
    pub(crate) exe: &'a Path,
    pub(crate) root: &'a Path,
    pub(crate) name: &'a RuntimeName,
    pub(crate) runtime: &'a Runtime,
    pub(crate) pane: PaneId,
    pub(crate) cwd: Option<&'a str>,
    pub(crate) env: &'a [Variable],
    pub(crate) server_env: &'a [Vec<u8>],
    pub(crate) from_runtime: bool,
}

fn bytes(path: &Path) -> Vec<u8> {
    path.as_os_str().as_encoded_bytes().to_vec()
}

fn text(text: &str) -> Vec<u8> {
    text.as_bytes().to_vec()
}

pub(crate) fn wrapper(wrap: &Wrap<'_>, inner: Option<&[Vec<u8>]>) -> Vec<Vec<u8>> {
    let Wrap {
        exe,
        root,
        name,
        runtime,
        pane,
        cwd,
        env,
        server_env,
        from_runtime,
    } = wrap;
    let cwd = match (cwd, from_runtime) {
        (Some(cwd), true) => Some(PathBuf::from(cwd)),
        (Some(cwd), false) => map_cwd(
            &runtime.paths(),
            runtime.cwd.as_ref().map(|cwd| cwd.as_path()),
            Path::new(cwd),
        ),
        (None, _) => runtime.cwd.as_ref().map(|cwd| cwd.as_path().to_path_buf()),
    };
    let socket = socket_path(root, name);
    let entry = runtime.entry(
        *pane,
        &Ctx {
            name,
            env: server_env,
            socket: &socket,
            exe,
        },
    );
    let mut argv = vec![
        bytes(exe),
        text("runtime-exec"),
        text(name.as_str()),
        text("--"),
    ];
    argv.extend(entry.prefix);
    let mut enter = entry.ko;
    enter.push(text("enter"));
    enter.extend(entry.location);
    enter.extend([text("--pane"), text(&pane.to_string())]);
    enter.extend(entry.token);
    enter.extend([text("--runtime"), text(name.as_str())]);
    if let Some(cwd) = cwd {
        enter.extend([text("--cwd"), bytes(&cwd)]);
    }
    let requested = env.iter().map(|Variable { name, value }| (name, value));
    for (variable, value) in runtime.env.iter().chain(requested) {
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
    use super::*;
    use crate::protocol::AbsPath;

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
    }
}
