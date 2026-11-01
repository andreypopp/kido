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

fn above_targets(fd: BorrowedFd<'_>) -> io::Result<OwnedFd> {
    // SAFETY: fd is open for the borrow; the copy is a new descriptor at 4 or above.
    let raw = check(unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 4) })?;
    // SAFETY: fcntl returned a new descriptor that nothing else owns.
    Ok(unsafe { OwnedFd::from_raw_fd(raw) })
}

pub fn pane(program: &Path, control: BorrowedFd<'_>, mapping: BorrowedFd<'_>) -> io::Result<Pid> {
    let program = CString::new(program.as_os_str().as_bytes())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "NUL in the program path"))?;
    let control = above_targets(control)?;
    let mapping = above_targets(mapping)?;
    let mut actions = Actions(ptr::null_mut());
    // SAFETY: actions receives an initialized file action list.
    check_code(unsafe { libc::posix_spawn_file_actions_init(&mut actions.0) })?;
    for (fd, target) in [(&control, 0), (&control, 1), (&mapping, 3)] {
        // SAFETY: fd is open for the borrow, and the actions are initialized.
        check_code(unsafe {
            libc::posix_spawn_file_actions_adddup2(&mut actions.0, fd.as_raw_fd(), target)
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
        | libc::POSIX_SPAWN_SETSIGMASK;
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
    let argv = [program.as_ptr().cast_mut(), ptr::null_mut()];
    let mut raw = 0;
    retry(|| {
        // SAFETY: program and argv are NUL-terminated, the actions and attributes are
        // initialized, and environ is the process environment.
        check_code(unsafe {
            libc::posix_spawn(
                &mut raw,
                program.as_ptr(),
                &actions.0,
                &attributes.0,
                argv.as_ptr(),
                environ,
            )
        })
    })?;
    Pid::new(i64::from(raw)).ok_or_else(|| {
        let mut status = 0;
        // SAFETY: raw is the child just spawned, which this process reaps.
        let _ = retry(|| check(unsafe { libc::waitpid(raw, &mut status, 0) }));
        io::Error::other(format!("ko-pane got the refused pid {raw}"))
    })
}
