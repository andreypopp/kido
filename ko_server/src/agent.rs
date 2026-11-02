use std::ffi::OsStr;
use std::fs;
use std::io;
use std::os::unix::fs::{FileTypeExt, symlink};
use std::path::{Path, PathBuf};

pub fn socket(dir: &Path) -> PathBuf {
    dir.join("agent.sock")
}

fn is_socket(path: &Path) -> bool {
    fs::metadata(path).is_ok_and(|metadata| metadata.file_type().is_socket())
}

pub fn publish(dir: &Path, inherited: Option<&OsStr>) -> io::Result<()> {
    let stable = socket(dir);
    let Some(inherited) = inherited.map(Path::new) else {
        return Ok(());
    };
    if !inherited.is_absolute() || inherited == stable || !is_socket(inherited) {
        return Ok(());
    }
    match fs::symlink_metadata(&stable) {
        Ok(metadata) if !metadata.file_type().is_symlink() || is_socket(&stable) => return Ok(()),
        Ok(_) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    let pid = std::process::id();
    let mut n = 0u32;
    let temporary = loop {
        let candidate = dir.join(format!(".agent.sock.{pid}.{n}"));
        match symlink(inherited, &candidate) {
            Ok(()) => break candidate,
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                n = n.checked_add(1).ok_or(error)?;
            }
            Err(error) => return Err(error),
        }
    };
    fs::rename(&temporary, &stable).inspect_err(|_| {
        let _ = fs::remove_file(&temporary);
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixListener;

    fn tempdir(name: &str) -> PathBuf {
        let dir = PathBuf::from(format!("/tmp/ko-agent-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir(&dir).unwrap();
        dir
    }

    fn listen(dir: &Path, name: &str) -> (UnixListener, PathBuf) {
        let path = dir.join(name);
        (UnixListener::bind(&path).unwrap(), path)
    }

    fn names(dir: &Path) -> Vec<String> {
        let mut names: Vec<String> = fs::read_dir(dir)
            .unwrap()
            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
            .collect();
        names.sort();
        names
    }

    #[test]
    fn an_absent_path_gets_the_inherited_socket() {
        let dir = tempdir("absent");
        let (_listener, agent) = listen(&dir, "a");
        publish(&dir, Some(agent.as_os_str())).unwrap();
        assert_eq!(fs::read_link(socket(&dir)).unwrap(), agent);
        assert_eq!(names(&dir), ["a", "agent.sock"]);
    }

    #[test]
    fn a_dangling_link_is_replaced() {
        let dir = tempdir("dangling");
        let (_listener, agent) = listen(&dir, "a");
        symlink(dir.join("gone"), socket(&dir)).unwrap();
        publish(&dir, Some(agent.as_os_str())).unwrap();
        assert_eq!(fs::read_link(socket(&dir)).unwrap(), agent);
        assert_eq!(names(&dir), ["a", "agent.sock"]);
    }

    #[test]
    fn a_link_to_a_live_socket_is_kept() {
        let dir = tempdir("live");
        let (_a, agent) = listen(&dir, "a");
        let (_b, other) = listen(&dir, "b");
        symlink(&other, socket(&dir)).unwrap();
        publish(&dir, Some(agent.as_os_str())).unwrap();
        assert_eq!(fs::read_link(socket(&dir)).unwrap(), other);
        assert_eq!(names(&dir), ["a", "agent.sock", "b"]);
    }

    #[test]
    fn a_file_is_kept() {
        let dir = tempdir("file");
        let (_listener, agent) = listen(&dir, "a");
        fs::write(socket(&dir), b"mine").unwrap();
        publish(&dir, Some(agent.as_os_str())).unwrap();
        assert_eq!(fs::read(socket(&dir)).unwrap(), b"mine");
        assert_eq!(names(&dir), ["a", "agent.sock"]);
    }

    #[test]
    fn a_socket_is_kept() {
        let dir = tempdir("socket");
        let (_listener, agent) = listen(&dir, "a");
        let _own = UnixListener::bind(socket(&dir)).unwrap();
        publish(&dir, Some(agent.as_os_str())).unwrap();
        assert!(
            fs::symlink_metadata(socket(&dir))
                .unwrap()
                .file_type()
                .is_socket()
        );
        assert_eq!(names(&dir), ["a", "agent.sock"]);
    }

    #[test]
    fn a_value_that_is_no_agent_changes_nothing() {
        let dir = tempdir("none");
        let (_listener, agent) = listen(&dir, "a");
        fs::write(dir.join("plain"), b"x").unwrap();
        let _own = UnixListener::bind(socket(&dir)).unwrap();
        fs::remove_file(socket(&dir)).unwrap();
        for inherited in [
            None,
            Some(OsStr::new("")),
            Some(OsStr::new("a")),
            Some(socket(&dir).as_os_str()),
            Some(dir.join("plain").as_os_str()),
            Some(dir.join("gone").as_os_str()),
        ] {
            publish(&dir, inherited).unwrap();
            assert_eq!(names(&dir), ["a", "plain"]);
        }
        publish(&dir, Some(agent.as_os_str())).unwrap();
        assert_eq!(names(&dir), ["a", "agent.sock", "plain"]);
    }
}
