use std::ffi::CString;
use std::fmt;
use std::io;
use std::os::fd::{AsFd, AsRawFd, BorrowedFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

use crate::pid::{Exit, Group, Pid, Waited};
use crate::retry::check;
use crate::signal::Signal;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Winsize {
    cols: u16,
    rows: u16,
    xpixel: u16,
    ypixel: u16,
}

fn pixels(cells: u16, each: u16) -> u16 {
    u16::try_from(u32::from(cells) * u32::from(each)).unwrap_or(u16::MAX)
}

impl Winsize {
    pub fn new(cols: u16, rows: u16, cell_width: u16, cell_height: u16) -> Winsize {
        Winsize {
            cols,
            rows,
            xpixel: pixels(cols, cell_width),
            ypixel: pixels(rows, cell_height),
        }
    }

    fn raw(self) -> libc::winsize {
        libc::winsize {
            ws_row: self.rows,
            ws_col: self.cols,
            ws_xpixel: self.xpixel,
            ws_ypixel: self.ypixel,
        }
    }
}

#[derive(Debug)]
pub struct Setup {
    call: &'static str,
    error: io::Error,
}

impl fmt::Display for Setup {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.call, self.error)
    }
}

#[derive(Debug)]
pub struct Pty {
    pub master: OwnedFd,
    pub program: Result<Program, Failed>,
}

#[derive(Debug)]
pub struct Program {
    group: Group,
}

impl Program {
    pub fn pid(&self) -> Pid {
        self.group.leader()
    }

    pub fn signal(&self, signal: Signal) -> io::Result<()> {
        self.group.signal(signal)
    }

    pub fn peek_exit(&self) -> io::Result<Option<Exit>> {
        self.pid().peek_exit()
    }

    pub fn reap(self) -> io::Result<Exit> {
        match self.pid().wait()? {
            Waited::Ended(exit) => Ok(exit),
            Waited::Running | Waited::NoChild => Err(io::Error::from(io::ErrorKind::NotFound)),
        }
    }
}

const SETUP_ERRORS: [i32; 4] = [libc::EAGAIN, libc::ENOMEM, libc::EMFILE, libc::ENFILE];
const OPENPTY_ATTEMPTS: u32 = 3;
const NOT_RUN: i32 = 126;
const NOT_EXECUTABLE: i32 = 127;
const RECORD: usize = 8;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Step {
    Sigmask = 1,
    Setsid,
    Tiocsctty,
    Dup2,
    Chdir,
    Exec,
}

impl Step {
    fn exit_code(self) -> i32 {
        if self == Step::Exec {
            NOT_EXECUTABLE
        } else {
            NOT_RUN
        }
    }

    fn of_code(code: u8) -> Option<Step> {
        Some(match code {
            1 => Step::Sigmask,
            2 => Step::Setsid,
            3 => Step::Tiocsctty,
            4 => Step::Dup2,
            5 => Step::Chdir,
            6 => Step::Exec,
            _ => return None,
        })
    }

    fn name(self) -> &'static str {
        match self {
            Step::Sigmask => "sigprocmask",
            Step::Setsid => "setsid",
            Step::Tiocsctty => "tiocsctty",
            Step::Dup2 => "dup2",
            Step::Chdir => "chdir",
            Step::Exec => "exec",
        }
    }
}

#[derive(Debug)]
pub struct Failed {
    pub exit: Exit,
    step: Step,
    error: io::Error,
}

impl fmt::Display for Failed {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.step.name(), self.error)
    }
}

fn setup(call: &'static str) -> impl FnOnce(io::Error) -> Setup {
    move |error| Setup { call, error }
}

fn c_string(bytes: &[u8]) -> Result<CString, Setup> {
    CString::new(bytes)
        .map_err(|error| setup("spawn")(io::Error::new(io::ErrorKind::InvalidInput, error)))
}

fn environment(env: &[Vec<u8>]) -> Result<Vec<CString>, Setup> {
    let mut kept: Vec<&Vec<u8>> = Vec::new();
    for entry in env {
        let Some(at) = entry
            .iter()
            .position(|&byte| byte == b'=')
            .filter(|&at| at > 0)
        else {
            continue;
        };
        kept.retain(|earlier| earlier.get(..=at) != entry.get(..=at));
        kept.push(entry);
    }
    kept.into_iter().map(|entry| c_string(entry)).collect()
}

struct Prepared {
    program: *const libc::c_char,
    argv: *const *const libc::c_char,
    envp: *const *const libc::c_char,
    cwd: *const libc::c_char,
    empty: *const libc::sigset_t,
    slave: libc::c_int,
    report: libc::c_int,
}

macro_rules! again {
    ($call:expr) => {
        loop {
            let result = $call;
            if result >= 0 || *crate::retry::errno() != libc::EINTR {
                break result;
            }
        }
    };
}

// SAFETY (whole function): runs between fork and exec, so it calls only async-signal-safe
// functions (sigprocmask, signal, setsid, ioctl, dup2, chdir, execve, write, _exit); it
// allocates nothing, takes no lock and formats nothing. Every pointer in `Prepared` was built
// before the fork and outlives it.
unsafe fn child(prepared: &Prepared) -> ! {
    // SAFETY: see the function comment.
    unsafe {
        let step =
            if libc::sigprocmask(libc::SIG_SETMASK, prepared.empty, std::ptr::null_mut()) != 0 {
                Step::Sigmask
            } else {
                for signal in [libc::SIGPIPE, libc::SIGHUP, libc::SIGINT, libc::SIGTERM] {
                    libc::signal(signal, libc::SIG_DFL);
                }
                if libc::setsid() < 0 {
                    Step::Setsid
                } else if again!(libc::ioctl(prepared.slave, libc::TIOCSCTTY as _, 0)) < 0 {
                    Step::Tiocsctty
                } else if (0..3).any(|target| again!(libc::dup2(prepared.slave, target)) < 0) {
                    Step::Dup2
                } else if again!(libc::chdir(prepared.cwd)) < 0 {
                    Step::Chdir
                } else {
                    libc::execve(prepared.program, prepared.argv, prepared.envp);
                    Step::Exec
                }
            };
        let [e0, e1, e2, e3] = (*crate::retry::errno()).to_le_bytes();
        let record = [step as u8, e0, e1, e2, e3, 0, 0, 0];
        let mut sent = 0;
        while sent < RECORD {
            let wrote = libc::write(
                prepared.report,
                record.as_ptr().add(sent).cast(),
                RECORD - sent,
            );
            if wrote > 0 {
                sent += wrote as usize;
            } else if wrote == 0 || *crate::retry::errno() != libc::EINTR {
                break;
            }
        }
        libc::_exit(step.exit_code())
    }
}

fn pipe() -> Result<(OwnedFd, OwnedFd), Setup> {
    let mut ends = [-1; 2];
    // SAFETY: ends receives two new descriptors.
    check(unsafe { libc::pipe(ends.as_mut_ptr()) }).map_err(setup("pipe"))?;
    // SAFETY: pipe returned two new descriptors that nothing else owns.
    let (read, write) = unsafe { (OwnedFd::from_raw_fd(ends[0]), OwnedFd::from_raw_fd(ends[1])) };
    for end in [&read, &write] {
        crate::fd::set_cloexec(end.as_fd()).map_err(setup("fcntl"))?;
    }
    Ok((read, write))
}

fn report(read: &OwnedFd) -> Result<Option<(Step, io::Error)>, Setup> {
    let mut record = [0u8; RECORD];
    let mut have = 0;
    while have < RECORD {
        let Some(room) = record.get_mut(have..) else {
            break;
        };
        match crate::fd::read(read.as_fd(), room).map_err(setup("read"))? {
            0 => break,
            count => have = have.saturating_add(count),
        }
    }
    match (have, record) {
        (0, _) => Ok(None),
        (RECORD, [code, e0, e1, e2, e3, ..]) => Step::of_code(code)
            .map(|step| {
                Some((
                    step,
                    io::Error::from_raw_os_error(i32::from_le_bytes([e0, e1, e2, e3])),
                ))
            })
            .ok_or_else(|| setup("spawn")(io::Error::from(io::ErrorKind::InvalidData))),
        _ => Err(setup("spawn")(io::Error::from(io::ErrorKind::InvalidData))),
    }
}

pub fn spawn(size: Winsize, cwd: &Path, argv: &[Vec<u8>], env: &[Vec<u8>]) -> Result<Pty, Setup> {
    let (mut master, mut slave) = (-1, -1);
    let mut winsize = size.raw();
    // openpty takes a *mut winsize on macOS and a *const on Linux.
    let winsize = &raw mut winsize;
    let mut attempts = 0;
    // macOS openpty fails now and then with errno -6 when other processes allocate ptys at the
    // same moment; the next call succeeds.
    loop {
        attempts += 1;
        // SAFETY: master and slave receive the new descriptors, and the winsize is read only.
        let opened = check(unsafe {
            libc::openpty(
                &mut master,
                &mut slave,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                winsize,
            )
        });
        match opened {
            Err(error)
                if attempts < OPENPTY_ATTEMPTS
                    && !error
                        .raw_os_error()
                        .is_some_and(|code| SETUP_ERRORS.contains(&code)) => {}
            opened => {
                opened.map_err(setup("openpty"))?;
                break;
            }
        }
    }
    // SAFETY: openpty returned two new descriptors that nothing else owns.
    let (master, slave) = unsafe { (OwnedFd::from_raw_fd(master), OwnedFd::from_raw_fd(slave)) };
    for fd in [&master, &slave] {
        crate::fd::set_cloexec(fd.as_fd()).map_err(setup("fcntl"))?;
    }
    crate::fd::set_nonblocking(master.as_fd()).map_err(setup("fcntl"))?;
    if argv.is_empty() {
        return Err(setup("spawn")(io::Error::from(io::ErrorKind::InvalidInput)));
    }
    let argv: Vec<CString> = argv
        .iter()
        .map(|arg| c_string(arg))
        .collect::<Result<_, _>>()?;
    let envp = environment(env)?;
    let cwd = c_string(cwd.as_os_str().as_bytes())?;
    let pointers = |strings: &[CString]| -> Vec<*const libc::c_char> {
        strings
            .iter()
            .map(|string| string.as_ptr())
            .chain([std::ptr::null()])
            .collect()
    };
    let (argv_pointers, env_pointers) = (pointers(&argv), pointers(&envp));
    // SAFETY: an all-zero sigset_t is valid, and sigemptyset fills it.
    let mut empty: libc::sigset_t = unsafe { std::mem::zeroed() };
    // SAFETY: empty is a valid sigset_t.
    unsafe { libc::sigemptyset(&mut empty) };
    let (read, write) = pipe()?;
    let prepared = Prepared {
        program: argv
            .first()
            .map_or(std::ptr::null(), |program| program.as_ptr()),
        argv: argv_pointers.as_ptr(),
        envp: env_pointers.as_ptr(),
        cwd: cwd.as_ptr(),
        empty: &empty,
        slave: slave.as_raw_fd(),
        report: write.as_raw_fd(),
    };
    // SAFETY: the child calls only async-signal-safe functions on memory prepared above.
    let forked = check(unsafe { libc::fork() }).map_err(setup("fork"))?;
    if forked == 0 {
        // SAFETY: this is the child, and `prepared` was built before the fork.
        unsafe { child(&prepared) }
    }
    drop(write);
    drop(slave);
    let leader = Pid::new(i64::from(forked))
        .ok_or_else(|| setup("fork")(io::Error::other("a child with a refused pid")))?;
    match report(&read) {
        Ok(None) => Ok(Pty {
            master,
            program: Ok(Program {
                group: Group::held(leader),
            }),
        }),
        Ok(Some((step, error))) => match leader.wait() {
            Ok(Waited::Ended(exit)) if exit == Exit::Exited(step.exit_code()) => Ok(Pty {
                master,
                program: Err(Failed { exit, step, error }),
            }),
            Ok(_) => Err(setup("spawn")(io::Error::from(io::ErrorKind::InvalidData))),
            Err(error) => Err(setup("wait")(error)),
        },
        Err(error) => {
            let _ = leader.signal(Signal::Kill);
            let _ = leader.wait();
            Err(error)
        }
    }
}

pub fn set_size(master: &OwnedFd, size: Winsize) -> io::Result<()> {
    // SAFETY: master is a pty master and the winsize is read only.
    check(unsafe { libc::ioctl(master.as_raw_fd(), libc::TIOCSWINSZ as _, &size.raw()) })?;
    Ok(())
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Foreground {
    pub group: u32,
    pub name: Vec<u8>,
}

#[cfg(target_os = "macos")]
fn process_name(pid: libc::pid_t) -> Vec<u8> {
    let mut name = [0u8; 256];
    // SAFETY: name is writable for the size that proc_name receives.
    let length = unsafe { libc::proc_name(pid, name.as_mut_ptr().cast(), name.len() as u32) };
    let length = usize::try_from(length).unwrap_or(0).min(name.len());
    name.get(..length).unwrap_or_default().to_vec()
}

#[cfg(target_os = "linux")]
fn process_name(pid: libc::pid_t) -> Vec<u8> {
    let mut name = std::fs::read(format!("/proc/{pid}/comm")).unwrap_or_default();
    if name.last() == Some(&b'\n') {
        name.pop();
    }
    name
}

pub fn foreground(master: BorrowedFd<'_>) -> Option<Foreground> {
    // SAFETY: master is an open pty master.
    let group = unsafe { libc::tcgetpgrp(master.as_raw_fd()) };
    Some(Foreground {
        group: u32::try_from(group).ok().filter(|&group| group > 0)?,
        name: process_name(group),
    })
}

pub fn read(master: BorrowedFd<'_>, buffer: &mut [u8]) -> io::Result<usize> {
    match crate::fd::read(master, buffer) {
        Err(error) if error.raw_os_error() == Some(libc::EIO) => Ok(0),
        read => read,
    }
}

#[cfg(test)]
mod tests {
    use std::os::fd::OwnedFd;
    use std::time::{Duration, Instant};

    use super::*;

    fn size() -> Winsize {
        Winsize::new(80, 24, 8, 16)
    }

    fn argv(parts: &[&str]) -> Vec<Vec<u8>> {
        parts.iter().map(|part| part.as_bytes().to_vec()).collect()
    }

    fn read_until(master: &OwnedFd, needle: &str) -> String {
        let deadline = Instant::now() + Duration::from_secs(10);
        let mut seen = String::new();
        while !seen.contains(needle) {
            assert!(Instant::now() < deadline, "no {needle:?} in {seen:?}");
            let mut buffer = [0u8; 4096];
            match read(master.as_fd(), &mut buffer) {
                Ok(0) => break,
                Ok(count) => seen.push_str(&String::from_utf8_lossy(&buffer[..count])),
                Err(_) => std::thread::sleep(Duration::from_millis(2)),
            }
        }
        seen
    }

    #[test]
    fn the_pixel_size_of_a_grid_saturates_at_a_u16() {
        let size = Winsize::new(4096, 24, 65535, 16);
        assert_eq!((size.xpixel, size.ypixel), (65535, 384));
        let size = Winsize::new(80, 0, 8, 16);
        assert_eq!((size.xpixel, size.ypixel), (640, 0));
        assert_eq!(pixels(65535, 65535), 65535);
    }

    #[test]
    fn programs_start_on_a_pty_in_a_process_that_no_other_test_shares() {
        let exe = std::env::current_exe().unwrap();
        let stdout = std::io::stdout();
        let child = crate::spawn::program(
            Path::new(&exe),
            &[
                "--ignored",
                "--exact",
                "pty::tests::programs",
                "--nocapture",
            ],
            &[(stdout.as_fd(), 1)],
            crate::spawn::Env::Inherit,
            None,
        )
        .unwrap();
        assert_eq!(child.wait().unwrap(), Waited::Ended(Exit::Exited(0)));
    }

    #[test]
    #[ignore = "run in a process of its own by the test above: spawn forks while other threads own sockets"]
    fn programs() {
        let tmp = std::fs::canonicalize("/tmp").unwrap();
        let script =
            "echo \"$KO_PTY_TEST $PWD ${HOME-unset}\"; echo controlling > /dev/tty; stty size";
        let started = spawn(
            size(),
            &tmp,
            &argv(&["/bin/sh", "-c", script]),
            &argv(&["KO_PTY_TEST=value", "PATH=/usr/bin:/bin"]),
        )
        .unwrap();
        let program = started.program.unwrap();
        let seen = read_until(&started.master, "24 80");
        assert!(
            seen.contains(&format!("value {} unset\r\n", tmp.display())),
            "{seen:?}"
        );
        assert!(seen.contains("controlling\r\n"), "{seen:?}");
        assert_eq!(program.reap().unwrap(), Exit::Exited(0));

        let status = |cwd: &Path, program: &[&str]| {
            let failed = spawn(size(), cwd, &argv(program), &[])
                .unwrap()
                .program
                .unwrap_err();
            (failed.exit, failed.to_string())
        };
        assert_eq!(
            status(&tmp, &["/no/such/program"]),
            (
                Exit::Exited(127),
                "exec: No such file or directory (os error 2)".to_owned()
            )
        );
        assert_eq!(
            status(Path::new("/no/such/dir"), &["/bin/sh"]),
            (
                Exit::Exited(126),
                "chdir: No such file or directory (os error 2)".to_owned()
            )
        );
        let locked = tmp.join(format!("ko-pty-locked-{}", std::process::id()));
        std::fs::create_dir(&locked).unwrap();
        std::fs::set_permissions(&locked, std::os::unix::fs::PermissionsExt::from_mode(0o000))
            .unwrap();
        let unsearchable = status(&locked, &["/bin/sh"]);
        std::fs::set_permissions(&locked, std::os::unix::fs::PermissionsExt::from_mode(0o700))
            .unwrap();
        std::fs::remove_dir(&locked).unwrap();
        assert_eq!(
            unsearchable,
            (
                Exit::Exited(126),
                "chdir: Permission denied (os error 13)".to_owned()
            )
        );

        let started = spawn(
            size(),
            &tmp,
            &argv(&["/bin/sh", "-c", "trap '' HUP; sleep 30 & echo $!"]),
            &argv(&["PATH=/usr/bin:/bin"]),
        )
        .unwrap();
        let program = started.program.unwrap();
        let seen = read_until(&started.master, "\n");
        let descendant = Pid::new(seen.trim().parse().unwrap()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        while program.peek_exit().unwrap().is_none() {
            assert!(Instant::now() < deadline, "the leader did not exit");
            std::thread::sleep(Duration::from_millis(2));
        }
        assert!(descendant.alive());
        program.signal(Signal::Kill).unwrap();
        while descendant.alive() {
            assert!(
                Instant::now() < deadline,
                "the descendant survived the group signal"
            );
            std::thread::sleep(Duration::from_millis(2));
        }
        assert_eq!(program.reap().unwrap(), Exit::Exited(0));
    }
}
