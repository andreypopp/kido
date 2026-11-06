use std::path::Path;

use ko_config::ssh_args::remote_dir_valid;
use ko_sys::pid::Exit;

use crate::config::SUN_PATH_MAX;
use crate::ids::PaneId;

pub const SOCKET: &str = "socket";
pub const TOKEN_SUFFIX: &str = ".token";

pub fn token_name(pane: PaneId) -> String {
    format!("{pane}{TOKEN_SUFFIX}")
}

/// The name of the master's control socket in the directory of a link.
pub const CONTROL: &str = "ctl";

// ssh creates the master's socket as "<ControlPath>." and 16 random characters before it renames
// the file into place, and that name must fit in sun_path too.
pub(crate) const MASTER_SUFFIX: usize = "/".len() + CONTROL.len() + ".".len() + 16;
pub const MAX_DIR: usize = SUN_PATH_MAX - MASTER_SUFFIX;

pub const MASTER_OPTIONS: [&str; 3] = [
    "ExitOnForwardFailure=yes",
    "ServerAliveInterval=5",
    "ServerAliveCountMax=3",
];

pub fn quote(word: &str) -> String {
    String::from_utf8_lossy(&quote_bytes(word.as_bytes())).into_owned()
}

pub(crate) fn quote_bytes(word: &[u8]) -> Vec<u8> {
    let mut quoted = vec![b'\''];
    for &byte in word {
        if byte == b'\'' {
            quoted.extend_from_slice(b"'\\''");
        } else {
            quoted.push(byte);
        }
    }
    quoted.push(b'\'');
    quoted
}

pub fn control_args(ctl: &Path, operation: &[&str], host: &str) -> Vec<String> {
    ["-S", &ctl.to_string_lossy()]
        .into_iter()
        .chain(operation.iter().copied())
        .chain([host])
        .map(str::to_owned)
        .collect()
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum QueryFailure {
    NoKo,
    Ssh(String),
    Exit { code: i32, message: String },
    Signal(i32),
}

// The outcome of a command that runs ko on the remote and reports on stdout.
pub fn query_failure(exit: Exit, stderr: &[u8]) -> Option<QueryFailure> {
    let message = String::from_utf8_lossy(stderr).trim().to_owned();
    match exit {
        Exit::Exited(0) => None,
        Exit::Exited(127) => Some(QueryFailure::NoKo),
        Exit::Exited(255) => Some(QueryFailure::Ssh(message)),
        Exit::Exited(code) => Some(QueryFailure::Exit { code, message }),
        Exit::Signaled(signal) => Some(QueryFailure::Signal(signal)),
    }
}

pub fn reported_path(text: &str) -> Option<&str> {
    let path = text.trim();
    remote_dir_valid(path).then_some(path)
}

pub fn no_remote_ko(host: &str) -> String {
    format!(
        "ko is not on the PATH of non-interactive ssh commands on {host}; \
         put the line that adds it to PATH (for Homebrew: eval \"$(brew shellenv)\" \
         with brew's full path) in ~/.bashrc before its non-interactive return, \
         or in ~/.zshenv"
    )
}

pub fn forwarding_refused(host: &str) -> String {
    format!(
        "{host} refuses unix-socket forwarding, and ko needs it (sshd AllowStreamLocalForwarding)"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn query_failures_and_reported_paths() {
        let fail = |exit, stderr: &[u8]| query_failure(exit, stderr);
        assert_eq!(fail(Exit::Exited(0), b""), None);
        assert_eq!(fail(Exit::Exited(127), b"x"), Some(QueryFailure::NoKo));
        assert_eq!(
            fail(Exit::Exited(255), b" denied \n"),
            Some(QueryFailure::Ssh("denied".to_owned()))
        );
        assert_eq!(
            fail(Exit::Exited(3), b"boom"),
            Some(QueryFailure::Exit {
                code: 3,
                message: "boom".to_owned()
            })
        );
        assert_eq!(reported_path("/a/b\n"), Some("/a/b"));
        for bad in ["a", "/a:b", "/a%b", "/a\nb", "/a\0b"] {
            assert_eq!(reported_path(bad), None, "{bad:?}");
        }
    }
}
