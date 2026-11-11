use ko_sys::pid::Exit;
use ko_wire::ssh::{self, QueryFailure};
use std::fmt;

#[cfg(not(target_os = "ios"))]
mod desktop;
#[cfg(not(target_os = "ios"))]
pub use desktop::{Error, Progress, Remote};

#[derive(Debug, PartialEq, Eq)]
pub enum Failure {
    Ssh(String),
    NoRemoteKo { host: String },
    Query { host: String, message: String },
    Refused { host: String },
    NoServer { host: String },
}

impl fmt::Display for Failure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Ssh(message) => f.write_str(message),
            Self::NoRemoteKo { host } => f.write_str(&ssh::no_remote_ko(host)),
            Self::Query { host, message } => {
                write!(f, "cannot find the ko socket on {host}: {message}")
            }
            Self::Refused { host } => f.write_str(&ssh::forwarding_refused(host)),
            Self::NoServer { host } => write!(
                f,
                "the ko server on {host} did not answer through the forward; reconnect"
            ),
        }
    }
}

pub(crate) fn remote_socket(
    host: &str,
    exit: Exit,
    stdout: &[u8],
    stderr: &[u8],
) -> Result<String, Failure> {
    let query = |message: String| Failure::Query {
        host: host.to_owned(),
        message,
    };
    match ssh::query_failure(exit, stderr) {
        None => {
            let text = String::from_utf8_lossy(stdout);
            ssh::reported_path(&text)
                .map(str::to_owned)
                .ok_or_else(|| query(format!("invalid socket path {:?}", text.trim())))
        }
        Some(QueryFailure::NoKo) => Err(Failure::NoRemoteKo {
            host: host.to_owned(),
        }),
        Some(QueryFailure::Ssh(message)) => Err(Failure::Ssh(message)),
        Some(QueryFailure::Exit { code, message }) => {
            Err(query(format!("{message} (exit {code})")))
        }
        Some(QueryFailure::Signal(signal)) => Err(query(format!("ssh died of signal {signal}"))),
    }
}

pub(crate) fn unreachable(host: &str, remote_answers: bool) -> Failure {
    let host = host.to_owned();
    if remote_answers {
        Failure::Refused { host }
    } else {
        Failure::NoServer { host }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_remote_query_maps_its_failures() {
        let ok = |out: &[u8]| remote_socket("h", Exit::Exited(0), out, b"");
        assert_eq!(
            ok(b"/home/u/.local/state/ko/socket\n"),
            Ok("/home/u/.local/state/ko/socket".to_owned())
        );
        for bad in [&b""[..], b"relative/socket", b"/a:b/socket", b"/a%h/socket"] {
            assert!(matches!(ok(bad), Err(Failure::Query { .. })), "{bad:?}");
        }
        assert_eq!(
            remote_socket("h", Exit::Exited(127), b"", b"sh: ko: not found"),
            Err(Failure::NoRemoteKo {
                host: "h".to_owned()
            })
        );
        assert_eq!(
            remote_socket("h", Exit::Exited(255), b"", b"Permission denied\n"),
            Err(Failure::Ssh("Permission denied".to_owned()))
        );
        assert!(
            Failure::NoRemoteKo {
                host: "h".to_owned()
            }
            .to_string()
            .contains("ko is not on the PATH of non-interactive ssh commands on h")
        );
    }

    #[test]
    fn a_server_that_answers_on_the_host_but_not_through_the_forward_means_refused_forwarding() {
        let refused = unreachable("h", true);
        let missing = unreachable("h", false);
        assert_eq!(
            refused,
            Failure::Refused {
                host: "h".to_owned()
            }
        );
        assert_eq!(
            missing,
            Failure::NoServer {
                host: "h".to_owned()
            }
        );
        assert!(
            refused
                .to_string()
                .contains("refuses unix-socket forwarding")
        );
        assert!(
            missing
                .to_string()
                .contains("did not answer through the forward; reconnect")
        );
    }
}
