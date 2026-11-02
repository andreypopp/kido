use std::ffi::CString;
use std::io;
use std::os::fd::{AsRawFd, BorrowedFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::ptr;

use crate::pid::Pid;
use crate::retry::{check, check_code, retry};
use crate::signal::Signal;

unsafe extern "C" {
    static environ: *const *mut libc::c_char;
    fn posix_spawn_file_actions_addinherit_np(
        actions: *mut libc::posix_spawn_file_actions_t,
        fd: libc::c_int,
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
const POSIX_SPAWN_SETSID: libc::c_int = 0x0400;

pub fn detached(program: &Path, args: &[&str], log: BorrowedFd<'_>) -> io::Result<Pid> {
    start(
        program,
        args,
        &[(log, 0), (log, 1), (log, 2)],
        Env::Inherit,
        Session::New,
    )
}

pub fn program(
    program: &Path,
    args: &[&str],
    targets: &[(BorrowedFd<'_>, u8)],
    env: Env<'_>,
) -> io::Result<Pid> {
    start(program, args, targets, env, Session::Inherit)
}

fn start(
    program: &Path,
    args: &[&str],
    targets: &[(BorrowedFd<'_>, u8)],
    env: Env<'_>,
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
    let mut actions = Actions(ptr::null_mut());
    // SAFETY: actions receives an initialized file action list.
    check_code(unsafe { libc::posix_spawn_file_actions_init(&mut actions.0) })?;
    for (fd, target) in &copies {
        // SAFETY: fd is open for the borrow, and the actions are initialized.
        check_code(unsafe {
            libc::posix_spawn_file_actions_adddup2(&mut actions.0, fd.as_raw_fd(), *target)
        })?;
    }
    // SAFETY: the actions are initialized; 2 is inherited past POSIX_SPAWN_CLOEXEC_DEFAULT.
    check_code(unsafe { posix_spawn_file_actions_addinherit_np(&mut actions.0, 2) })?;
    let mut attributes = Attributes(ptr::null_mut());
    // SAFETY: attributes receives an initialized attribute object.
    check_code(unsafe { libc::posix_spawnattr_init(&mut attributes.0) })?;
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
    let flags = libc::POSIX_SPAWN_CLOEXEC_DEFAULT
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
