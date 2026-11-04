use std::path::{Path, PathBuf};

use crate::ids::{PaneId, RuntimeName};
use crate::protocol::{PathMap, Variable};
use crate::runtime::Runtime;

pub(crate) fn directory(root: &Path, name: &RuntimeName) -> PathBuf {
    root.join(name.as_str())
}

pub(crate) fn socket_path(root: &Path, name: &RuntimeName) -> PathBuf {
    directory(root, name).join("socket")
}

pub(crate) fn token_directory(root: &Path, name: &RuntimeName) -> PathBuf {
    directory(root, name).join("panes")
}

pub(crate) fn token_path(root: &Path, name: &RuntimeName, pane: PaneId) -> PathBuf {
    token_directory(root, name).join(format!("{pane}.token"))
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
        from_runtime,
    } = wrap;
    let entry = runtime.entry();
    let cwd = match (cwd, from_runtime) {
        (Some(cwd), true) => Some(PathBuf::from(cwd)),
        (Some(cwd), false) => map_cwd(
            &runtime.paths,
            runtime.cwd.as_ref().map(|cwd| cwd.as_path()),
            Path::new(cwd),
        ),
        (None, _) => runtime.cwd.as_ref().map(|cwd| cwd.as_path().to_path_buf()),
    };
    let socket = entry.socket.map_or_else(
        || socket_path(root, name),
        |socket| socket.as_path().to_path_buf(),
    );
    let mut argv = vec![
        bytes(exe),
        text("runtime-exec"),
        text(name.as_str()),
        text("--"),
    ];
    argv.extend(entry.prefix.iter().map(|arg| text(arg)));
    argv.extend([
        bytes(exe),
        text("enter"),
        text("--socket"),
        bytes(&socket),
        text("--pane"),
        text(&pane.to_string()),
        text("--token-file"),
        bytes(&token_path(root, name, *pane)),
        text("--runtime"),
        text(name.as_str()),
    ]);
    if let Some(cwd) = cwd {
        argv.extend([text("--cwd"), bytes(&cwd)]);
    }
    let requested = env.iter().map(|Variable { name, value }| (name, value));
    for (variable, value) in runtime.env.iter().chain(requested) {
        argv.extend([text("--env"), text(&format!("{variable}={value}"))]);
    }
    if let Some(inner) = inner {
        argv.push(text("--"));
        argv.extend(inner.iter().cloned());
    }
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
