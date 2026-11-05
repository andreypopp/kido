use std::fs::File;
use std::net::{TcpListener, TcpStream};
use std::os::fd::AsFd;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::Duration;

use crate::harness::{
    Child, DEADLINE, Dir, ko, poll, quote, run_program, test_env, text_of, which,
};

pub(crate) const HOST: &str = "koremote";

// These tests run a private sshd of their own, so a test can refuse forwarding with its own
// configuration and nothing touches the user's ~/.ssh. sshd still starts the real user's shell for
// the remote command, which reads that user's dotfiles whatever HOME the test sets. They run only
// with KO_E2E_HOST_SSH=1; then a missing sshd is a failure, not a skip.
pub(crate) fn first_file(candidates: &[&str], name: &str) -> PathBuf {
    candidates
        .iter()
        .map(PathBuf::from)
        .find(|path| path.is_file())
        .or_else(|| which(name))
        .unwrap_or_else(|| panic!("KO_E2E_HOST_SSH needs {name}"))
}

// Generated once for the process and shared by every sshd and client of these tests. The
// directory stays in /tmp, because a static is never dropped.
fn keys() -> &'static Path {
    static KEYS: OnceLock<Dir> = OnceLock::new();
    KEYS.get_or_init(|| {
        let dir = Dir::new("ko-ssh-keys-");
        let keygen = first_file(&["/usr/bin/ssh-keygen"], "ssh-keygen");
        for name in ["host_key", "client_key"] {
            let file = dir.join(name);
            let args = ["-q", "-t", "ed25519", "-N", "", "-f", text_of(&file)];
            run_program(&dir, &keygen, &test_env(&dir), &args, "", DEADLINE).ok();
        }
        dir
    })
}

pub(crate) struct Remote {
    pub(crate) dir: Dir,
    pub(crate) bin: PathBuf,
    pub(crate) block: PathBuf,
    _sshd: Child,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum Forwarding {
    Allowed,
    Refused,
}

// What a test changes in the private sshd and in the client's configuration of it.
#[derive(Clone, Copy)]
pub(crate) struct Options {
    pub(crate) forwarding: Forwarding,
    pub(crate) max_sessions: Option<u32>,
    // The client key has this passphrase, and the client configuration asks for it on the
    // terminal instead of the batch mode.
    pub(crate) passphrase: Option<&'static str>,
    // sshd accepts PATH and HOME from the client, and the client configuration sends them.
    pub(crate) send_env: bool,
}

impl Default for Options {
    fn default() -> Options {
        Options {
            forwarding: Forwarding::Allowed,
            max_sessions: None,
            passphrase: None,
            send_env: false,
        }
    }
}

impl Remote {
    pub(crate) fn start(state: &Path, path: &str, options: Options) -> Remote {
        let dir = Dir::new("ko-ssh-");
        let env = test_env(&dir);
        for name in ["host_key", "client_key", "client_key.pub"] {
            std::fs::copy(keys().join(name), dir.join(name)).unwrap();
        }
        if let Some(passphrase) = options.passphrase {
            let keygen = first_file(&["/usr/bin/ssh-keygen"], "ssh-keygen");
            let key = dir.join("client_key");
            let args = [
                "-q",
                "-t",
                "ed25519",
                "-a",
                "1",
                "-N",
                passphrase,
                "-f",
                text_of(&key),
            ];
            std::fs::remove_file(&key).unwrap();
            run_program(&dir, &keygen, &env, &args, "", DEADLINE).ok();
        }
        std::fs::copy(dir.join("client_key.pub"), dir.join("authorized_keys")).unwrap();
        let port = TcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap()
            .port();
        let user = std::env::var("USER")
            .or_else(|_| std::env::var("LOGNAME"))
            .unwrap_or_else(|_| {
                let id = first_file(&["/usr/bin/id"], "id");
                run_program(&dir, &id, &env, &["-un"], "", DEADLINE)
                    .ok()
                    .trim()
                    .to_owned()
            });
        let forwarding_line = match options.forwarding {
            Forwarding::Allowed => "yes",
            Forwarding::Refused => "no",
        };
        std::fs::write(
            dir.join("sshd_config"),
            format!(
                "Port {port}\nListenAddress 127.0.0.1\nHostKey {d}/host_key\nPidFile {d}/sshd.pid\n\
                 AuthorizedKeysFile {d}/authorized_keys\nStrictModes no\nUsePAM no\n\
                 PasswordAuthentication no\nKbdInteractiveAuthentication no\n\
                 PubkeyAuthentication yes\nAllowStreamLocalForwarding {forwarding_line}\n\
                 SetEnv KO_STATE_DIR={state} PATH={path}\nAcceptEnv KO_E2E_MARK{env}\n{sessions}",
                d = text_of(&dir),
                state = text_of(state),
                env = if options.send_env { " PATH HOME" } else { "" },
                sessions = options
                    .max_sessions
                    .map_or(String::new(), |count| format!("MaxSessions {count}\n")),
            ),
        )
        .unwrap();
        let config = dir.join("ssh_config");
        std::fs::write(
            &config,
            format!(
                "Host {HOST}\n  HostName 127.0.0.1\n  Port {port}\n  User {user}\n  \
                 IdentityFile {d}/client_key\n  IdentitiesOnly yes\n  IdentityAgent none\n  \
                 UserKnownHostsFile /dev/null\n  StrictHostKeyChecking no\n  SendEnv KO_E2E_MARK{env}\n{batch}",
                d = text_of(&dir),
                env = if options.send_env { " PATH HOME" } else { "" },
                batch = if options.passphrase.is_some() {
                    ""
                } else {
                    "  BatchMode yes\n"
                },
            ),
        )
        .unwrap();
        let sshd = first_file(
            &[
                "/usr/sbin/sshd",
                "/usr/local/sbin/sshd",
                "/usr/libexec/openssh/sshd",
                "/opt/homebrew/sbin/sshd",
            ],
            "sshd",
        );
        let (null, log) = (
            File::open("/dev/null").unwrap(),
            File::create(dir.join("sshd.log")).unwrap(),
        );
        let mut child = Child::spawn(
            &sshd,
            &["-D", "-e", "-f", text_of(&dir.join("sshd_config"))],
            &env,
            &[(null.as_fd(), 0), (log.as_fd(), 1), (log.as_fd(), 2)],
        );
        poll("sshd to listen", || {
            assert!(
                child.wait(Duration::ZERO).is_none(),
                "sshd exited: {}",
                std::fs::read_to_string(dir.join("sshd.log")).unwrap_or_default()
            );
            TcpStream::connect(("127.0.0.1", port)).is_ok()
        });
        let block = dir.join("block");
        let real = first_file(&["/usr/bin/ssh"], "ssh");
        let bin = dir.join("bin");
        std::fs::create_dir(&bin).unwrap();
        let wrapper = bin.join("ssh");
        std::fs::write(
            &wrapper,
            format!(
                "#!/bin/sh\n[ -e {} ] && exit 255\nprintf '%s\\n' \"$*\" >> {}\n\
                 [ -p {hold} ] && case \"$*\" in *\"-O exit\"*) read x < {hold};; esac\nexec {} -F {} \"$@\"\n",
                quote(text_of(&block)),
                quote(text_of(&dir.join("calls"))),
                quote(text_of(&real)),
                quote(text_of(&config)),
                hold = quote(text_of(&dir.join("hold"))),
            ),
        )
        .unwrap();
        std::fs::set_permissions(
            &wrapper,
            std::os::unix::fs::PermissionsExt::from_mode(0o700),
        )
        .unwrap();
        Remote {
            dir,
            bin,
            block,
            _sshd: child,
        }
    }

    pub(crate) fn with_ko(state: &Path) -> Remote {
        Remote::with_ko_options(state, Options::default())
    }

    pub(crate) fn with_ko_options(state: &Path, options: Options) -> Remote {
        let bin = ko().parent().unwrap().to_path_buf();
        let path = format!("{}:/usr/bin:/bin:/usr/sbin:/sbin", text_of(&bin));
        Remote::start(state, &path, options)
    }

    pub(crate) fn calls(&self) -> Vec<String> {
        std::fs::read_to_string(self.dir.join("calls"))
            .unwrap_or_default()
            .lines()
            .map(str::to_owned)
            .collect()
    }

    pub(crate) fn client_env(&self) -> Vec<Vec<u8>> {
        let mut env = test_env(&self.dir);
        env.retain(|entry| !entry.starts_with(b"PATH="));
        let path = std::env::var("PATH").unwrap_or_default();
        env.push(format!("PATH={}:{path}", text_of(&self.bin)).into_bytes());
        env
    }
}
