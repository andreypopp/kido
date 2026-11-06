use std::ffi::CString;
use std::io;
use std::os::fd::{AsRawFd, BorrowedFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::ptr;

use crate::pid::{Pid, Program};
use crate::retry::{check, check_code, retry};
use crate::signal::Signal;

unsafe extern "C" {
    static environ: *const *mut libc::c_char;
}

#[cfg(target_os = "macos")]
unsafe extern "C" {
    fn posix_spawn_file_actions_addinherit_np(
        actions: *mut libc::posix_spawn_file_actions_t,
        fd: libc::c_int,
    ) -> libc::c_int;
}

unsafe extern "C" {
    fn posix_spawn_file_actions_addchdir_np(
        actions: *mut libc::posix_spawn_file_actions_t,
        path: *const libc::c_char,
    ) -> libc::c_int;
}

#[derive(Debug)]
struct Actions(libc::posix_spawn_file_actions_t);

impl Drop for Actions {
    fn drop(&mut self) {
        // SAFETY: the actions were initialized and are destroyed once.
        unsafe { libc::posix_spawn_file_actions_destroy(&mut self.0) };
    }
}

#[derive(Debug)]
struct Attributes(libc::posix_spawnattr_t);

impl Drop for Attributes {
    fn drop(&mut self) {
        // SAFETY: the attributes were initialized and are destroyed once.
        unsafe { libc::posix_spawnattr_destroy(&mut self.0) };
    }
}

const DEFAULTS: [Signal; 8] = [
    Signal::Child,
    Signal::Hup,
    Signal::Int,
    Signal::Pipe,
    Signal::Quit,
    Signal::Term,
    Signal::Usr1,
    Signal::Winch,
];

const FIRST_FREE: libc::c_int = 16;

fn above_targets(fd: BorrowedFd<'_>) -> io::Result<OwnedFd> {
    // SAFETY: fd is open for the borrow; the copy is a new descriptor above every target.
    let raw = check(unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_DUPFD_CLOEXEC, FIRST_FREE) })?;
    // SAFETY: fcntl returned a new descriptor that nothing else owns.
    Ok(unsafe { OwnedFd::from_raw_fd(raw) })
}

pub fn pane(program: &Path, control: BorrowedFd<'_>, mapping: BorrowedFd<'_>) -> io::Result<Pid> {
    self::program(
        program,
        &[],
        &[(control, 0), (control, 1), (mapping, 3)],
        Env::Inherit,
        None,
    )
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Env<'a> {
    Inherit,
    Only(&'a [Vec<u8>]),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Session {
    Inherit,
    New,
}

// <sys/spawn.h>; the libc crate does not declare it for macOS.
#[cfg(target_os = "macos")]
const POSIX_SPAWN_SETSID: libc::c_int = 0x0400;
#[cfg(target_os = "linux")]
const POSIX_SPAWN_SETSID: libc::c_int = libc::POSIX_SPAWN_SETSID as libc::c_int;

pub fn detached(
    program: &Path,
    args: &[&str],
    log: BorrowedFd<'_>,
    env: Env<'_>,
) -> io::Result<Pid> {
    start(
        program,
        args,
        &[(log, 0), (log, 1), (log, 2)],
        (env, None),
        Session::New,
    )
}

pub fn program(
    program: &Path,
    args: &[&str],
    targets: &[(BorrowedFd<'_>, u8)],
    env: Env<'_>,
    dir: Option<&Path>,
) -> io::Result<Pid> {
    start(program, args, targets, (env, dir), Session::Inherit)
}

/// The program leads a new session and process group.
pub fn grouped(
    program: &Path,
    args: &[&str],
    targets: &[(BorrowedFd<'_>, u8)],
    env: Env<'_>,
    dir: Option<&Path>,
) -> io::Result<Program> {
    let pid = start(program, args, targets, (env, dir), Session::New)?;
    Ok(Program::held(pid))
}

// Every descriptor but the targets and stderr closes in the child. It returns the spawn flags
// that the rule needs. macOS closes them all unless told to inherit; Linux closes the ones
// below and above the targets, and std opens the rest close-on-exec.
#[cfg(target_os = "macos")]
fn confine(actions: &mut Actions, _targets: &[(BorrowedFd<'_>, u8)]) -> io::Result<libc::c_int> {
    // SAFETY: the actions are initialized; 2 is inherited past POSIX_SPAWN_CLOEXEC_DEFAULT.
    check_code(unsafe { posix_spawn_file_actions_addinherit_np(&mut actions.0, 2) })?;
    Ok(libc::POSIX_SPAWN_CLOEXEC_DEFAULT)
}

#[cfg(target_os = "linux")]
fn confine(actions: &mut Actions, targets: &[(BorrowedFd<'_>, u8)]) -> io::Result<libc::c_int> {
    let targets: Vec<u8> = targets.iter().map(|(_, target)| *target).collect();
    let (below, first) = closed_below(&targets);
    for fd in below {
        // SAFETY: the actions are initialized; glibc and musl ignore a close of a descriptor that is not open.
        check_code(unsafe { libc::posix_spawn_file_actions_addclose(&mut actions.0, fd) })?;
    }
    close_from(actions, first)?;
    Ok(0)
}

#[cfg(all(target_os = "linux", target_env = "gnu"))]
fn close_from(actions: &mut Actions, first: libc::c_int) -> io::Result<()> {
    // SAFETY: the actions are initialized.
    check_code(unsafe { libc::posix_spawn_file_actions_addclosefrom_np(&mut actions.0, first) })
}

// musl has no addclosefrom_np; its spawn ignores the error of a close of a descriptor that is
// not open, so the listing's own directory descriptor is harmless.
#[cfg(all(target_os = "linux", target_env = "musl"))]
fn close_from(actions: &mut Actions, first: libc::c_int) -> io::Result<()> {
    for entry in std::fs::read_dir("/proc/self/fd")? {
        let fd = entry?
            .file_name()
            .to_str()
            .and_then(|name| name.parse::<libc::c_int>().ok());
        if let Some(fd) = fd.filter(|fd| *fd >= first) {
            // SAFETY: the actions are initialized.
            check_code(unsafe { libc::posix_spawn_file_actions_addclose(&mut actions.0, fd) })?;
        }
    }
    Ok(())
}

#[cfg(target_os = "linux")]
fn closed_below(targets: &[u8]) -> (Vec<libc::c_int>, libc::c_int) {
    let first = targets
        .iter()
        .map(|target| libc::c_int::from(*target))
        .fold(2, libc::c_int::max)
        + 1;
    let below = (0..first)
        .filter(|fd| {
            *fd != 2
                && !targets
                    .iter()
                    .any(|target| libc::c_int::from(*target) == *fd)
        })
        .collect();
    (below, first)
}

fn start(
    program: &Path,
    args: &[&str],
    targets: &[(BorrowedFd<'_>, u8)],
    (env, dir): (Env<'_>, Option<&Path>),
    session: Session,
) -> io::Result<Pid> {
    let invalid = |_| io::Error::new(io::ErrorKind::InvalidInput, "NUL in a spawn argument");
    let program = CString::new(program.as_os_str().as_bytes()).map_err(invalid)?;
    let args = args
        .iter()
        .map(|arg| CString::new(*arg).map_err(invalid))
        .collect::<io::Result<Vec<CString>>>()?;
    let entries = match env {
        Env::Inherit => Vec::new(),
        Env::Only(entries) => entries
            .iter()
            .map(|entry| CString::new(entry.as_slice()).map_err(invalid))
            .collect::<io::Result<Vec<CString>>>()?,
    };
    let envp: Vec<*mut libc::c_char> = entries
        .iter()
        .map(|entry| entry.as_ptr().cast_mut())
        .chain([ptr::null_mut()])
        .collect();
    let copies = targets
        .iter()
        .map(|(fd, target)| Ok((above_targets(*fd)?, libc::c_int::from(*target))))
        .collect::<io::Result<Vec<(OwnedFd, libc::c_int)>>>()?;
    let mut actions = std::mem::MaybeUninit::uninit();
    // SAFETY: actions points to storage for the initializer's output.
    check_code(unsafe { libc::posix_spawn_file_actions_init(actions.as_mut_ptr()) })?;
    // SAFETY: the initializer succeeded; only this owner destroys its output.
    let mut actions = Actions(unsafe { actions.assume_init() });
    let dir = dir
        .map(|dir| CString::new(dir.as_os_str().as_bytes()).map_err(invalid))
        .transpose()?;
    if let Some(dir) = &dir {
        // SAFETY: the actions are initialized, and dir is NUL-terminated and outlives the spawn.
        check_code(unsafe { posix_spawn_file_actions_addchdir_np(&mut actions.0, dir.as_ptr()) })?;
    }
    for (fd, target) in &copies {
        // SAFETY: fd is open for the borrow, and the actions are initialized.
        check_code(unsafe {
            libc::posix_spawn_file_actions_adddup2(&mut actions.0, fd.as_raw_fd(), *target)
        })?;
    }
    let confined = confine(&mut actions, targets)?;
    let mut attributes = std::mem::MaybeUninit::uninit();
    // SAFETY: attributes points to storage for the initializer's output.
    check_code(unsafe { libc::posix_spawnattr_init(attributes.as_mut_ptr()) })?;
    // SAFETY: the initializer succeeded; only this owner destroys its output.
    let mut attributes = Attributes(unsafe { attributes.assume_init() });
    // SAFETY: an empty sigset_t, filled by sigemptyset and sigaddset below.
    let (mut empty, mut defaults): (libc::sigset_t, libc::sigset_t) = unsafe { std::mem::zeroed() };
    // SAFETY: both sets are valid sigset_t values.
    unsafe {
        libc::sigemptyset(&mut empty);
        libc::sigemptyset(&mut defaults);
        for signal in DEFAULTS {
            libc::sigaddset(&mut defaults, signal.number());
        }
    }
    let flags = confined
        | libc::POSIX_SPAWN_SETSIGDEF
        | libc::POSIX_SPAWN_SETSIGMASK
        | match session {
            Session::Inherit => 0,
            Session::New => POSIX_SPAWN_SETSID,
        };
    // SAFETY: the attributes are initialized, and the sets outlive the calls.
    unsafe {
        check_code(libc::posix_spawnattr_setflags(
            &mut attributes.0,
            libc::c_short::try_from(flags).unwrap_or(0),
        ))?;
        check_code(libc::posix_spawnattr_setsigdefault(
            &mut attributes.0,
            &defaults,
        ))?;
        check_code(libc::posix_spawnattr_setsigmask(&mut attributes.0, &empty))?;
    }
    let argv: Vec<*mut libc::c_char> = std::iter::once(&program)
        .chain(&args)
        .map(|arg| arg.as_ptr().cast_mut())
        .chain([ptr::null_mut()])
        .collect();
    let mut raw = 0;
    retry(|| {
        // SAFETY: program and argv are NUL-terminated, the actions and attributes are
        // initialized, and the environment is the process's own or the NUL-terminated envp.
        check_code(unsafe {
            libc::posix_spawn(
                &mut raw,
                program.as_ptr(),
                &actions.0,
                &attributes.0,
                argv.as_ptr(),
                match env {
                    Env::Inherit => environ,
                    Env::Only(_) => envp.as_ptr(),
                },
            )
        })
    })?;
    Pid::new(i64::from(raw)).ok_or_else(|| {
        let mut status = 0;
        // SAFETY: raw is the child just spawned, which this process reaps.
        let _ = retry(|| check(unsafe { libc::waitpid(raw, &mut status, 0) }));
        io::Error::other(format!("a spawn returned the refused pid {raw}"))
    })
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::*;
    use std::io::Read;
    use std::os::fd::AsFd;

    #[test]
    fn everything_below_the_first_free_descriptor_closes_but_the_targets_and_stderr() {
        assert_eq!(closed_below(&[]), (vec![0, 1], 3));
        assert_eq!(closed_below(&[1]), (vec![0], 3));
        assert_eq!(closed_below(&[0, 1, 3]), (vec![], 4));
        assert_eq!(closed_below(&[1, 5]), (vec![0, 3, 4], 6));
    }

    #[test]
    fn a_child_has_no_descriptor_in_a_gap_of_its_targets() {
        let (mut reader, writer) = std::io::pipe().unwrap();
        // SAFETY: an inheritable copy of the pipe, closed below.
        let gap = unsafe { libc::fcntl(writer.as_raw_fd(), libc::F_DUPFD, 5) };
        assert!((5..12).contains(&gap), "{gap}");
        let report = format!(
            "for n in 0 3 4 {gap}; do [ -e /proc/$$/fd/$n ] && echo open$n; done; echo done"
        );
        let child = program(
            Path::new("/bin/sh"),
            &["-c", &report],
            &[(writer.as_fd(), 1), (writer.as_fd(), 12)],
            Env::Inherit,
            None,
        );
        // SAFETY: gap is the copy made above, closed once.
        unsafe { libc::close(gap) };
        let child = child.unwrap();
        drop(writer);
        let mut text = String::new();
        reader.read_to_string(&mut text).unwrap();
        child.wait().unwrap();
        assert_eq!(text, "done\n");
    }
}
