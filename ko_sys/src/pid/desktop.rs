use super::Exit;

#[cfg(target_os = "macos")]
use std::ffi::OsString;
use std::io;
#[cfg(target_os = "macos")]
use std::os::unix::ffi::OsStringExt;
use std::path::PathBuf;

use crate::retry::{check, retry};
use crate::signal::Signal;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Pid(libc::pid_t);

impl Exit {
    fn new(exited: bool, value: i32) -> Exit {
        if exited {
            Exit::Exited(value)
        } else {
            Exit::Signaled(value)
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Waited {
    Running,
    Ended(Exit),
    NoChild,
}

impl std::fmt::Display for Pid {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.0.fmt(f)
    }
}

impl Pid {
    pub fn new(raw: i64) -> Option<Pid> {
        let pid = libc::pid_t::try_from(raw).ok().filter(|&pid| pid > 1)?;
        // SAFETY: getpgrp has no preconditions.
        let group = unsafe { libc::getpgrp() };
        (u32::try_from(pid).ok()? != std::process::id() && pid != group).then_some(Pid(pid))
    }

    pub fn get(self) -> i32 {
        self.0
    }

    pub fn cwd(self, session: Pid) -> Option<PathBuf> {
        let before = identity(self)?;
        if before.pgid != self.0 || before.sid != session.0 {
            return None;
        }
        #[cfg(target_os = "linux")]
        let path = proc::cwd(self)?;
        #[cfg(target_os = "macos")]
        let path = {
            let info = pidinfo(self, VNODE_PATH)?;
            let bytes = info
                .pvi_cdir
                .vip_path
                .into_iter()
                .flatten()
                .map(|byte| byte.cast_unsigned())
                .take_while(|byte| *byte != 0)
                .collect();
            PathBuf::from(OsString::from_vec(bytes))
        };
        (identity(self)? == before).then_some(path)
    }

    pub fn signal(self, signal: Signal) -> io::Result<()> {
        // SAFETY: Pid holds a positive pid other than this process and its group.
        match check(unsafe { libc::kill(self.0, signal.number()) }) {
            Ok(_) => Ok(()),
            Err(error) if error.raw_os_error() == Some(libc::ESRCH) => Ok(()),
            Err(error) => Err(error),
        }
    }

    pub fn alive(self) -> bool {
        // SAFETY: Pid holds a positive pid other than this process and its group; signal 0 sends nothing.
        match check(unsafe { libc::kill(self.0, 0) }) {
            Ok(_) => true,
            Err(error) => error.raw_os_error() == Some(libc::EPERM),
        }
    }

    pub fn peek_exit(self) -> io::Result<Option<Exit>> {
        self.peek(libc::WNOHANG)
    }

    #[cfg(feature = "e2e")]
    pub fn wait_exit(self) -> io::Result<Exit> {
        self.peek(0)?
            .ok_or_else(|| io::Error::from(io::ErrorKind::NotFound))
    }

    // macOS reports a stopped or continued child to waitid(WEXITED); that is no exit. The report
    // is consumed, so that a blocking wait goes on to wait for the exit.
    fn peek(self, flags: libc::c_int) -> io::Result<Option<Exit>> {
        let id = libc::id_t::try_from(self.0).map_err(io::Error::other)?;
        loop {
            // SAFETY: an all-zero siginfo_t is valid, and waitid fills it.
            let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
            retry(|| {
                // SAFETY: info is writable; WNOWAIT leaves the child waitable.
                check(unsafe {
                    libc::waitid(
                        libc::P_PID,
                        id,
                        &mut info,
                        libc::WEXITED | flags | libc::WNOWAIT,
                    )
                })
            })?;
            let (child, status) = sigchld(&info);
            if child != self.0 {
                return Ok(None);
            }
            match info.si_code {
                libc::CLD_EXITED => return Ok(Some(Exit::Exited(status))),
                libc::CLD_KILLED | libc::CLD_DUMPED => return Ok(Some(Exit::Signaled(status))),
                _ => {}
            }
            retry(|| {
                // SAFETY: info is writable; this call consumes the stop or continue report.
                check(unsafe {
                    libc::waitid(
                        libc::P_PID,
                        id,
                        &mut info,
                        libc::WSTOPPED | libc::WCONTINUED | libc::WNOHANG,
                    )
                })
            })?;
            if flags & libc::WNOHANG != 0 {
                return Ok(None);
            }
        }
    }

    pub fn try_wait(self) -> io::Result<Waited> {
        self.waited(libc::WNOHANG)
    }

    pub fn wait(self) -> io::Result<Waited> {
        self.waited(0)
    }

    fn waited(self, flags: libc::c_int) -> io::Result<Waited> {
        let mut status = 0;
        // SAFETY: status receives the child's status.
        let waited = retry(|| check(unsafe { libc::waitpid(self.0, &mut status, flags) }));
        match waited {
            Ok(0) => Ok(Waited::Running),
            Ok(_) if libc::WIFEXITED(status) => {
                Ok(Waited::Ended(Exit::new(true, libc::WEXITSTATUS(status))))
            }
            Ok(_) => Ok(Waited::Ended(Exit::new(false, libc::WTERMSIG(status)))),
            Err(error) if error.raw_os_error() == Some(libc::ECHILD) => Ok(Waited::NoChild),
            Err(error) => Err(error),
        }
    }
}

#[cfg(target_os = "macos")]
fn sigchld(info: &libc::siginfo_t) -> (libc::pid_t, i32) {
    (info.si_pid, info.si_status)
}

#[cfg(target_os = "linux")]
fn sigchld(info: &libc::siginfo_t) -> (libc::pid_t, i32) {
    // SAFETY: info came from a successful waitid, which fills these union members.
    unsafe { (info.si_pid(), info.si_status()) }
}

#[cfg(feature = "e2e")]
const MAX_HOPS: usize = 64;

#[cfg(feature = "e2e")]
impl Pid {
    pub fn parent(self) -> Option<Pid> {
        Pid::new(i64::from(identity(self)?.ppid))
    }

    #[cfg(target_os = "macos")]
    pub fn has_ended(self) -> bool {
        // SZOMB, <sys/proc.h>
        pidinfo(self, BSD_INFO).is_none_or(|info| info.pbi_status == 5)
    }

    #[cfg(target_os = "linux")]
    pub fn has_ended(self) -> bool {
        proc::read(self).is_none_or(|stat| stat.zombie)
    }

    fn descends_from(self, root: Pid) -> bool {
        let mut at = self;
        for _ in 0..MAX_HOPS {
            if at == root {
                return true;
            }
            match at.parent() {
                Some(parent) => at = parent,
                None => return false,
            }
        }
        false
    }
}

#[cfg(feature = "e2e")]
pub fn signal_descendant(root: Pid, pid: Pid, signal: Signal) -> io::Result<()> {
    if !pid.descends_from(root) {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("refusing to signal pid {pid} under {root}"),
        ));
    }
    pid.signal(signal)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Identity {
    ppid: libc::pid_t,
    pgid: libc::pid_t,
    sid: libc::pid_t,
    start: u64,
}

#[cfg(target_os = "linux")]
mod proc;

#[cfg(target_os = "macos")]
#[derive(Debug, Clone, Copy)]
struct Flavor<T> {
    raw: libc::c_int,
    ty: std::marker::PhantomData<T>,
}

#[cfg(target_os = "macos")]
impl<T> Flavor<T> {
    const fn new(raw: libc::c_int) -> Self {
        Self {
            raw,
            ty: std::marker::PhantomData,
        }
    }
}

#[cfg(target_os = "macos")]
const BSD_INFO: Flavor<libc::proc_bsdinfo> = Flavor::new(libc::PROC_PIDTBSDINFO);
#[cfg(target_os = "macos")]
const VNODE_PATH: Flavor<libc::proc_vnodepathinfo> = Flavor::new(libc::PROC_PIDVNODEPATHINFO);

#[cfg(target_os = "macos")]
fn pidinfo<T>(pid: Pid, flavor: Flavor<T>) -> Option<T> {
    let size = libc::c_int::try_from(size_of::<T>()).ok()?;
    let mut info = std::mem::MaybeUninit::<T>::uninit();
    retry(|| {
        // SAFETY: the private typed constants pair T with the proc_pidinfo flavor;
        // info is writable for size bytes.
        let filled =
            unsafe { libc::proc_pidinfo(pid.0, flavor.raw, 0, info.as_mut_ptr().cast(), size) };
        if filled == size {
            Ok(())
        } else if filled == 0 {
            Err(io::Error::last_os_error())
        } else {
            Err(io::Error::from(io::ErrorKind::UnexpectedEof))
        }
    })
    .ok()?;
    // SAFETY: proc_pidinfo filled the complete record of the type the flavor specifies.
    Some(unsafe { info.assume_init() })
}

#[cfg(target_os = "linux")]
fn identity(pid: Pid) -> Option<Identity> {
    Some(proc::read(pid)?.identity)
}

#[cfg(target_os = "macos")]
fn identity(pid: Pid) -> Option<Identity> {
    let info = pidinfo(pid, BSD_INFO)?;
    // SAFETY: getsid has no preconditions.
    let sid = unsafe { libc::getsid(pid.0) };
    if sid < 0 {
        return None;
    }
    Some(Identity {
        ppid: libc::pid_t::try_from(info.pbi_ppid).ok()?,
        pgid: libc::pid_t::try_from(info.pbi_pgid).ok()?,
        sid,
        start: info
            .pbi_start_tvsec
            .saturating_mul(1_000_000)
            .saturating_add(info.pbi_start_tvusec),
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Proof {
    Start(u64),
    Held,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Group {
    leader: Pid,
    proof: Proof,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    Child(Group),
    Gone,
    Foreign,
}

impl Group {
    fn judge(parent: Pid, pid: Pid, found: Option<Identity>) -> Verdict {
        match found {
            None => Verdict::Gone,
            Some(found) if found.ppid == parent.0 && found.pgid == pid.0 && found.sid == pid.0 => {
                Verdict::Child(Group {
                    leader: pid,
                    proof: Proof::Start(found.start),
                })
            }
            Some(_) => Verdict::Foreign,
        }
    }

    pub fn verify(parent: Pid, raw: i64) -> Verdict {
        match Pid::new(raw) {
            None => Verdict::Foreign,
            Some(pid) => Group::judge(parent, pid, identity(pid)),
        }
    }

    fn held(leader: Pid) -> Group {
        Group {
            leader,
            proof: Proof::Held,
        }
    }

    pub fn leader(&self) -> Pid {
        self.leader
    }

    pub fn signal(&self, signal: Signal) -> io::Result<()> {
        let current = match self.proof {
            Proof::Start(start) => {
                matches!(identity(self.leader), Some(found) if found.start == start && found.pgid == self.leader.0)
            }
            Proof::Held => true,
        };
        if !current {
            return Ok(());
        }
        // SAFETY: the leader is a verified group leader whose start time still matches, or the
        // spawned child whose zombie its parent holds, so its pid and group id are not reused.
        match check(unsafe { libc::kill(-self.leader.0, signal.number()) }) {
            Ok(_) => Ok(()),
            // macOS can return EPERM for a group with only zombies or exiting processes.
            Err(error) if matches!(error.raw_os_error(), Some(libc::ESRCH | libc::EPERM)) => Ok(()),
            Err(error) => Err(error),
        }
    }
}

/// A child that leads its own process group. This process holds its zombie until `reap`, so the
/// group's id is not reused before then, and the type has no way to signal after the reap.
#[derive(Debug)]
pub struct Program {
    group: Group,
}

impl Program {
    pub(crate) fn held(leader: Pid) -> Program {
        Program {
            group: Group::held(leader),
        }
    }

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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spawn;
    use std::io::Read;
    use std::os::fd::AsFd;
    use std::path::Path;

    #[test]
    fn a_directory_is_read_only_for_a_group_leader_in_the_expected_session() {
        let (mut reader, output) = std::io::pipe().unwrap();
        let (input, release) = std::io::pipe().unwrap();
        let child = spawn::program(
            Path::new("/usr/bin/perl"),
            &["-e", "use POSIX; $|=1; POSIX::setsid(); print q(x); <>;"],
            &[(input.as_fd(), 0), (output.as_fd(), 1)],
            spawn::Env::Inherit,
            None,
        )
        .unwrap();
        drop(input);
        drop(output);
        assert_eq!(
            crate::fd::wait(
                reader.as_fd(),
                crate::fd::Want::Read,
                None,
                Some(std::time::Duration::from_secs(5))
            )
            .unwrap(),
            crate::fd::Waited::Ready
        );
        let mut ready = [0];
        reader.read_exact(&mut ready).unwrap();
        let expected = std::fs::canonicalize(".").unwrap();
        let matching = child.cwd(child);
        let foreign = child.cwd(Pid(i32::try_from(std::process::id()).unwrap()));
        drop(release);
        assert_eq!(child.wait().unwrap(), Waited::Ended(Exit::Exited(0)));
        assert_eq!(matching, Some(expected));
        assert_eq!(foreign, None);
    }

    fn killed_by_sigkill(pid: Pid) -> bool {
        pid.wait().unwrap() == Waited::Ended(Exit::Signaled(libc::SIGKILL))
    }

    #[cfg(feature = "e2e")]
    #[test]
    fn a_stopped_child_has_not_exited_and_its_exit_follows_a_kill() {
        use std::time::{Duration, Instant};
        let pid = spawn::program(
            Path::new("/bin/sleep"),
            &["30"],
            &[],
            spawn::Env::Inherit,
            None,
        )
        .unwrap();
        let id = libc::id_t::try_from(pid.get()).unwrap();
        pid.signal(Signal::Stop).unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            // SAFETY: an all-zero siginfo_t is valid, and waitid fills it.
            let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
            // SAFETY: info is writable; WNOWAIT leaves the stop report in place.
            let seen = unsafe {
                libc::waitid(
                    libc::P_PID,
                    id,
                    &mut info,
                    libc::WSTOPPED | libc::WNOHANG | libc::WNOWAIT,
                )
            };
            if seen == 0 && sigchld(&info).0 == pid.get() {
                break;
            }
            assert!(Instant::now() < deadline, "the child never stopped");
        }
        assert_eq!(pid.peek_exit().unwrap(), None);
        pid.signal(Signal::Cont).unwrap();
        assert_eq!(pid.peek_exit().unwrap(), None);
        pid.signal(Signal::Kill).unwrap();
        assert_eq!(pid.wait_exit().unwrap(), Exit::Signaled(libc::SIGKILL));
        assert!(killed_by_sigkill(pid));
    }

    #[test]
    fn new_refuses_what_no_caller_may_signal_and_accepts_a_child() {
        let own = i64::from(std::process::id());
        // SAFETY: getpgrp has no preconditions.
        let group = i64::from(unsafe { libc::getpgrp() });
        for raw in [
            -1,
            -4_294_967_295,
            4_294_967_295,
            0x8000_0000,
            0,
            1,
            own,
            group,
        ] {
            assert_eq!(Pid::new(raw), None, "{raw}");
        }
        let pid = spawn::program(
            Path::new("/bin/sleep"),
            &["30"],
            &[],
            spawn::Env::Inherit,
            None,
        )
        .unwrap();
        pid.signal(Signal::Kill).unwrap();
        assert!(killed_by_sigkill(pid));
        pid.signal(Signal::Kill).unwrap();
    }

    #[test]
    fn a_held_zombie_still_answers_peek_exit_and_signal_zero_until_it_is_reaped() {
        let pid = spawn::program(
            Path::new("/bin/sh"),
            &["-c", "exit 7"],
            &[],
            spawn::Env::Inherit,
            None,
        )
        .unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        let exit = loop {
            if let Some(exit) = pid.peek_exit().unwrap() {
                break exit;
            }
            assert!(std::time::Instant::now() < deadline, "no exit within 5 s");
            std::thread::sleep(std::time::Duration::from_millis(2));
        };
        assert_eq!(exit, Exit::Exited(7));
        assert_eq!(pid.peek_exit().unwrap(), Some(Exit::Exited(7)));
        assert!(pid.alive());
        assert_eq!(pid.wait().unwrap(), Waited::Ended(Exit::Exited(7)));
        assert!(!pid.alive());
    }

    #[test]
    fn only_the_parents_own_session_leader_is_a_child() {
        let parent = Pid(4242);
        let pid = Pid(900);
        let found = |ppid, pgid, sid| {
            Some(Identity {
                ppid,
                pgid,
                sid,
                start: 7,
            })
        };
        let verdict = |found| Group::judge(parent, pid, found);
        assert_eq!(verdict(found(1, 900, 900)), Verdict::Foreign);
        assert_eq!(verdict(found(4242, 1, 900)), Verdict::Foreign);
        assert_eq!(verdict(found(4242, 900, 1)), Verdict::Foreign);
        assert_eq!(
            verdict(found(4242, 900, 900)),
            Verdict::Child(Group {
                leader: pid,
                proof: Proof::Start(7)
            })
        );
        assert_eq!(verdict(None), Verdict::Gone);
    }

    #[test]
    fn only_a_group_that_matches_its_recorded_start_is_signalled() {
        let program = "use POSIX; $|=1; POSIX::setsid(); print qq(up\\n); exec q(sleep), q(30)";
        let (mut reader, writer) = std::io::pipe().unwrap();
        let child = spawn::program(
            Path::new("/usr/bin/perl"),
            &["-e", program],
            &[(writer.as_fd(), 1)],
            spawn::Env::Inherit,
            None,
        )
        .unwrap();
        drop(writer);
        let mut up = [0u8; 3];
        reader.read_exact(&mut up).unwrap();
        let parent = Pid(i32::try_from(std::process::id()).unwrap());
        let Verdict::Child(verified) = Group::verify(parent, i64::from(child.0)) else {
            child.signal(Signal::Kill).unwrap();
            panic!("child not verified");
        };
        assert_eq!(verified.leader, child);
        let Proof::Start(start) = verified.proof else {
            panic!("verified without a start time");
        };
        let tampered = Group {
            proof: Proof::Start(start + 1),
            ..verified
        };
        tampered.signal(Signal::Kill).unwrap();
        assert_eq!(child.try_wait().unwrap(), Waited::Running);
        verified.signal(Signal::Kill).unwrap();
        assert!(killed_by_sigkill(child));
    }
}
