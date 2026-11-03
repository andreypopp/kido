use std::fs::File;
use std::net::{TcpListener, TcpStream};
use std::os::fd::AsFd;
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::Duration;

use ko_sys::pid::{Exit, Pid, signal_descendant};
use ko_sys::signal::Signal;

use crate::harness::{
    Child, DEADLINE, Dir, Server, enabled, history_lines, ko, poll, quote, run_ko, run_program,
    start, start_with, test_env, text_of, which,
};
use crate::outer::{CHORD_UP, Keys, Outer};

const HOST: &str = "koremote";

// These tests run a private sshd of their own, so a test can refuse forwarding with its own
// configuration and nothing touches the user's ~/.ssh. sshd still starts the real user's shell for
// the remote command, which reads that user's dotfiles whatever HOME the test sets. They run only
// with KO_E2E_HOST_SSH=1; then a missing sshd is a failure, not a skip.
fn first_file(candidates: &[&str], name: &str) -> PathBuf {
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

struct Remote {
    dir: Dir,
    bin: PathBuf,
    block: PathBuf,
    _sshd: Child,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Forwarding {
    Allowed,
    Refused,
}

impl Remote {
    fn start(state: &Path, path: &str, forwarding: Forwarding) -> Remote {
        let dir = Dir::new("ko-ssh-");
        let env = test_env(&dir);
        for name in ["host_key", "client_key", "client_key.pub"] {
            std::fs::copy(keys().join(name), dir.join(name)).unwrap();
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
        let forwarding_line = match forwarding {
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
                 SetEnv KO_STATE_DIR={state} PATH={path}\n",
                d = text_of(&dir),
                state = text_of(state),
            ),
        )
        .unwrap();
        let config = dir.join("ssh_config");
        std::fs::write(
            &config,
            format!(
                "Host {HOST}\n  HostName 127.0.0.1\n  Port {port}\n  User {user}\n  \
                 IdentityFile {d}/client_key\n  IdentitiesOnly yes\n  IdentityAgent none\n  \
                 UserKnownHostsFile /dev/null\n  StrictHostKeyChecking no\n  BatchMode yes\n",
                d = text_of(&dir),
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
                "#!/bin/sh\n[ -e {} ] && exit 255\nexec {} -F {} \"$@\"\n",
                quote(text_of(&block)),
                quote(text_of(&real)),
                quote(text_of(&config)),
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

    fn with_ko(state: &Path) -> Remote {
        let bin = ko().parent().unwrap().to_path_buf();
        let path = format!("{}:/usr/bin:/bin:/usr/sbin:/sbin", text_of(&bin));
        Remote::start(state, &path, Forwarding::Allowed)
    }

    fn client_env(&self) -> Vec<Vec<u8>> {
        let mut env = test_env(&self.dir);
        env.retain(|entry| !entry.starts_with(b"PATH="));
        let path = std::env::var("PATH").unwrap_or_default();
        env.push(format!("PATH={}:{path}", text_of(&self.bin)).into_bytes());
        env
    }

    fn api(&self, args: &[&str]) -> crate::harness::Run {
        let mut argv = vec!["api", "--host", HOST];
        argv.extend_from_slice(args);
        run_ko(&self.dir, &self.client_env(), &argv, "")
    }

    fn private_dirs(home: &Path) -> Vec<PathBuf> {
        std::fs::read_dir(home.join("ko"))
            .into_iter()
            .flatten()
            .flatten()
            .map(|entry| entry.path())
            .filter(|path| {
                path.file_name()
                    .is_some_and(|name| name.to_string_lossy().starts_with("remote-"))
            })
            .collect()
    }

    fn private_dir(home: &Path) -> PathBuf {
        let mut found = None;
        poll("the private directory", || {
            found = Remote::private_dirs(home).pop();
            found.is_some()
        });
        found.unwrap()
    }

    fn master(&self, home: &Path) -> Pid {
        let ctl = Remote::private_dir(home).join("ctl");
        let wrapper = self.bin.join("ssh");
        let mut found = None;
        poll("a running ssh master", || {
            let check = run_program(
                &self.dir,
                &wrapper,
                &test_env(&self.dir),
                &["-S", text_of(&ctl), "-O", "check", HOST],
                "",
                DEADLINE,
            );
            found = check
                .stderr
                .split("pid=")
                .nth(1)
                .and_then(|rest| rest.split(')').next())
                .and_then(|digits| digits.trim().parse::<i64>().ok())
                .and_then(Pid::new);
            found.is_some()
        });
        found.unwrap()
    }

    fn nothing_left(&self, home: &Path, master: Option<Pid>) {
        poll("the private directory to be removed", || {
            Remote::private_dirs(home).is_empty()
        });
        if let Some(master) = master {
            poll("the ssh master to end", || master.has_ended());
        }
        let pgrep = first_file(&["/usr/bin/pgrep"], "pgrep");
        let pattern = format!("ControlPath={}/ko/", text_of(home));
        let found = run_program(
            &self.dir,
            &pgrep,
            &test_env(&self.dir),
            &["-f", &pattern],
            "",
            DEADLINE,
        );
        assert_eq!(found.exit, Exit::Exited(1), "a master is left: {found:?}");
    }
}

fn serve_history(s: &Server, title: &str, text: &str) -> String {
    let history = history_lines(100);
    let pane = s.pane(&format!(
        "{history}; stty raw -echo; printf '\\033]0;{title}\\007{text}'; exec cat"
    ));
    s.screen_has(&pane, text);
    pane
}

fn attach(remote: &Remote, state: &Path) -> Outer {
    let outer = Outer::new(state, Keys::Extended);
    outer.attach_host(HOST, &remote.bin);
    outer
}

#[test]
fn remote_forward_attach_reconnect_and_cleanup() {
    if !enabled("KO_E2E_HOST_SSH") {
        return;
    }
    let s = start(&[]);
    let pane = serve_history(&s, "first-title", "READY");
    let remote = Remote::with_ko(&s.dir);
    let outer = attach(&remote, &s.dir);
    outer.contains("READY");
    outer.contains("first-title");
    let master = remote.master(&outer.dir);
    let private = Remote::private_dir(&outer.dir);
    let mode = std::os::unix::fs::PermissionsExt::mode(
        &std::fs::metadata(&private).unwrap().permissions(),
    );
    assert_eq!(mode & 0o777, 0o700, "private directory mode");

    // The client's own directory exists only on this machine, so a remote attach sends none.
    outer.chord('n');
    poll("a second pane", || s.rows().len() == 2);
    let created = s
        .rows()
        .into_iter()
        .find(|row| row["id"] != pane.as_str())
        .unwrap();
    assert!(
        !created["cwd"]
            .as_str()
            .unwrap_or_default()
            .contains("ko-tui-"),
        "the new pane has the cwd of the client: {created}"
    );
    outer.gone("READY");
    outer.raw(CHORD_UP);
    outer.contains("READY");

    let pane_rows = |outer: &Outer| -> Vec<String> {
        outer
            .lines()
            .into_iter()
            .map(|line| {
                line.split_once('│')
                    .map_or(line.clone(), |(_, rest)| rest.to_owned())
            })
            .collect()
    };
    let first_history = |outer: &Outer| -> Option<u32> {
        pane_rows(outer)
            .first()?
            .trim()
            .strip_prefix("history-")?
            .parse()
            .ok()
    };
    let top = first_history(&outer).expect("a history line in the first pane row");
    for _ in 0..3 {
        outer.wheel_up(40, 5);
    }
    // One wheel event scrolls three rows.
    outer.wait("three wheel events applied", || {
        first_history(&outer) == top.checked_sub(9)
    });
    let scrolled = pane_rows(&outer);

    std::fs::write(&remote.block, "").unwrap();
    signal_descendant(outer.client_pid(), master, Signal::Kill).unwrap();
    outer.contains(&format!("reconnecting to {HOST}"));
    std::fs::remove_file(&remote.block).unwrap();
    outer.gone("reconnecting to");
    // A scrolled mirror that a snapshot does not replace keeps its place: the view resumed.
    outer.wait("the scrolled screen again", || {
        pane_rows(&outer) == scrolled
    });
    assert_ne!(remote.master(&outer.dir), master, "a new master");

    let master = remote.master(&outer.dir);
    std::fs::write(&remote.block, "").unwrap();
    signal_descendant(outer.client_pid(), master, Signal::Kill).unwrap();
    outer.contains(&format!("reconnecting to {HOST}"));
    s.text(&pane, "WHILE-DOWN\n");
    std::fs::remove_file(&remote.block).unwrap();
    outer.contains("WHILE-DOWN");

    let master = remote.master(&outer.dir);
    outer.detach();
    remote.nothing_left(&outer.dir, Some(master));
}

#[test]
fn remote_a_reconnected_client_selects_its_pane_again_so_the_pane_follows_its_size() {
    if !enabled("KO_E2E_HOST_SSH") {
        return;
    }
    let s = start(&[]);
    let pane = s.pane("printf '\\033]0;sized-title\\007'; exec sh");
    let remote = Remote::with_ko(&s.dir);
    let outer = attach(&remote, &s.dir);
    outer.contains("sized-title");
    let before = s.stty(&pane);
    let master = remote.master(&outer.dir);
    std::fs::write(&remote.block, "").unwrap();
    signal_descendant(outer.client_pid(), master, Signal::Kill).unwrap();
    outer.contains(&format!("reconnecting to {HOST}"));
    std::fs::remove_file(&remote.block).unwrap();
    outer.gone("reconnecting to");

    outer.resize(100, 30);
    poll("the pane to follow the reconnected client", || {
        s.stty(&pane) != before
    });
}

#[test]
fn remote_a_restarted_server_starts_a_fresh_model_and_a_signal_cleans_up() {
    if !enabled("KO_E2E_HOST_SSH") {
        return;
    }
    let mut s = start(&[]);
    serve_history(&s, "first-title", "READY");
    let remote = Remote::with_ko(&s.dir);
    let outer = attach(&remote, &s.dir);
    outer.contains("READY");
    outer.contains("first-title");

    // The new ring is longer than the old offset, so a wrong resume would find its offset inside
    // the ring, keep the old screen and append the tail of the new output to it.
    s.restart(&[]);
    let history = history_lines(300);
    s.pane(&format!(
        "{history}; printf '\\033]0;second-title\\007SECOND'; exec cat"
    ));
    outer.contains("second-title");
    outer.gone("first-title");
    outer.gone("READY");

    let master = remote.master(&outer.dir);
    signal_descendant(outer.shell_pid(), outer.client_pid(), Signal::Term).unwrap();
    outer.detached();
    remote.nothing_left(&outer.dir, Some(master));
}

#[test]
fn remote_api_uses_a_forward_and_a_stopped_server_names_the_command_that_starts_one() {
    if !enabled("KO_E2E_HOST_SSH") {
        return;
    }
    let mut s = start(&[]);
    let pane = s.pane("printf 'API-PANE'; exec cat");
    s.screen_has(&pane, "API-PANE");
    let remote = Remote::with_ko(&s.dir);
    let version = remote.api(&["/version"]).json();
    assert_eq!(version["protocol"], "1.0");
    let panes = remote.api(&["/panes"]).json();
    assert_eq!(panes[0]["id"], pane.as_str());
    remote.nothing_left(&remote.dir, None);

    s.stop();
    let message = remote.api(&["/version"]).error(1);
    assert_eq!(
        message,
        format!(
            "ko {HOST}: no ko server is running on {HOST}; start one there with: ssh {HOST} ko server\n"
        )
    );
    assert!(!s.dir.join("socket").exists(), "ko HOST started a server");
    remote.nothing_left(&remote.dir, None);
}

#[test]
fn remote_refused_forwarding_is_one_clear_error_and_leaves_nothing() {
    if !enabled("KO_E2E_HOST_SSH") {
        return;
    }
    let s = start(&[]);
    let bin = ko().parent().unwrap().to_path_buf();
    let path = format!("{}:/usr/bin:/bin", text_of(&bin));
    let remote = Remote::start(&s.dir, &path, Forwarding::Refused);
    let message = remote.api(&["/version"]).error(1);
    assert!(
        message.starts_with(&format!(
            "ko {HOST}: {HOST} refuses unix-socket forwarding, and ko needs it"
        )),
        "{message}"
    );
    assert_eq!(message.lines().count(), 1, "{message}");
    remote.nothing_left(&remote.dir, None);
}

#[test]
fn remote_without_ko_on_the_host_is_a_clear_error() {
    if !enabled("KO_E2E_HOST_SSH") {
        return;
    }
    let empty = Dir::new("ko-empty-");
    let remote = Remote::start(&empty, "/usr/bin:/bin", Forwarding::Allowed);
    let message = remote.api(&["/version"]).error(1);
    assert!(
        message.starts_with(&format!("ko {HOST}: ko was not found on {HOST}")),
        "{message}"
    );
    remote.nothing_left(&remote.dir, None);
}

#[test]
fn panes_get_the_agent_socket_of_the_server_directory() {
    let s = start(&[]);
    assert!(
        !s.dir.join("agent.sock").exists(),
        "agent.sock without an agent"
    );
    let pane = s.pane("printf 'AGENT=%s;' \"$SSH_AUTH_SOCK\"; exec cat");
    s.screen_has(
        &pane,
        &format!("AGENT={};", s.dir.join("agent.sock").display()),
    );
    let own = s.new_pane(serde_json::json!({
        "command": {"type": "shell", "command": "printf 'OWN=%s;' \"$SSH_AUTH_SOCK\"; exec cat"},
        "env": [{"name": "SSH_AUTH_SOCK", "value": "/explicit"}],
    }));
    s.screen_has(&own, "OWN=/explicit;");
}

fn agent_socket(dir: &Path, name: &str) -> UnixListener {
    let listener = UnixListener::bind(dir.join(name)).unwrap();
    listener.set_nonblocking(true).unwrap();
    listener
}

#[test]
fn the_inherited_agent_is_linked_to_the_server_directory() {
    let agents = Dir::new("ko-agents-");
    let first = agent_socket(&agents, "a");
    let (path_a, path_b) = (agents.join("a"), agents.join("b"));
    let (a, b) = (text_of(&path_a), text_of(&path_b));
    let mut s = start_with(Path::new("/bin/sh"), &[("SSH_AUTH_SOCK", a)], &[]);
    let link = s.dir.join("agent.sock");
    assert_eq!(std::fs::read_link(&link).unwrap(), Path::new(a));
    s.pane("ssh-add -l; exec cat");
    poll("ssh-add to reach the agent", || first.accept().is_ok());

    let second = agent_socket(&agents, "b");
    std::fs::remove_file(&link).unwrap();
    std::os::unix::fs::symlink(b, &link).unwrap();
    s.restart(&[("SSH_AUTH_SOCK", a)]);
    assert_eq!(std::fs::read_link(&link).unwrap(), Path::new(b));

    drop(second);
    std::fs::remove_file(b).unwrap();
    s.restart(&[("SSH_AUTH_SOCK", a)]);
    assert_eq!(std::fs::read_link(&link).unwrap(), Path::new(a));
}
