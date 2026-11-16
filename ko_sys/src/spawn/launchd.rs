use std::fs::{File, OpenOptions};
use std::io::{self, Write};
use std::os::fd::AsFd;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{FileExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use super::Env;
use crate::pid::{Exit, Waited};
use crate::signal::Signal;

const LAUNCHCTL: &str = "/bin/launchctl";
const POLL: Duration = Duration::from_millis(2);

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message.to_owned())
}

fn escaped(value: &[u8]) -> io::Result<String> {
    let text =
        std::str::from_utf8(value).map_err(|_| invalid("a launchd job value is not UTF-8"))?;
    let mut out = String::new();
    for c in text.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&apos;"),
            '\r' => out.push_str("&#13;"),
            '\t' | '\n' => out.push(c),
            c if c < ' ' || c == '\u{FFFE}' || c == '\u{FFFF}' => {
                return Err(invalid("a launchd job value has a character XML refuses"));
            }
            c => out.push(c),
        }
    }
    Ok(out)
}

fn string(value: &[u8]) -> io::Result<String> {
    Ok(format!("<string>{}</string>\n", escaped(value)?))
}

fn plist(
    label: &str,
    argv: &[&[u8]],
    env: &[Vec<u8>],
    workdir: &Path,
    log: &Path,
) -> io::Result<String> {
    let mut out = String::from(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n<key>Label</key>\n",
    );
    out.push_str(&string(label.as_bytes())?);
    out.push_str("<key>ProgramArguments</key>\n<array>\n");
    for arg in argv {
        out.push_str(&string(arg)?);
    }
    out.push_str("</array>\n<key>EnvironmentVariables</key>\n<dict>\n");
    for entry in env {
        let at = entry
            .iter()
            .position(|byte| *byte == b'=')
            .ok_or_else(|| invalid("an environment entry has no '='"))?;
        let (name, value) = (
            entry.get(..at).unwrap_or_default(),
            entry.get(at + 1..).unwrap_or_default(),
        );
        out.push_str(&format!(
            "<key>{}</key>\n{}",
            escaped(name)?,
            string(value)?
        ));
    }
    let (workdir, log) = (workdir.as_os_str().as_bytes(), log.as_os_str().as_bytes());
    out.push_str("</dict>\n<key>WorkingDirectory</key>\n");
    out.push_str(&string(workdir)?);
    out.push_str("<key>StandardOutPath</key>\n");
    out.push_str(&string(log)?);
    out.push_str("<key>StandardErrorPath</key>\n");
    out.push_str(&string(log)?);
    out.push_str("<key>RunAtLoad</key>\n<true/>\n</dict>\n</plist>\n");
    Ok(out)
}

struct Launchctl<'a> {
    job_dir: &'a Path,
    deadline: Instant,
}

impl Launchctl<'_> {
    fn run(&self, args: &[&str]) -> io::Result<(Exit, String)> {
        let null = File::open("/dev/null")?;
        let output = crate::file::unlinked(self.job_dir, "launchctl")?;
        let pid = super::program(
            Path::new(LAUNCHCTL),
            args,
            &[(null.as_fd(), 0), (output.as_fd(), 1), (output.as_fd(), 2)],
            Env::Inherit,
            None,
        )?;
        let exit = loop {
            match pid.try_wait()? {
                Waited::Ended(exit) => break exit,
                Waited::NoChild => return Err(io::Error::other("launchctl vanished")),
                Waited::Running if Instant::now() >= self.deadline => {
                    let _ = pid.signal(Signal::Kill);
                    let _ = pid.wait();
                    return Err(io::Error::new(
                        io::ErrorKind::TimedOut,
                        format!("launchctl {} did not finish in time", args.join(" ")),
                    ));
                }
                Waited::Running => std::thread::sleep(POLL),
            }
        };
        let mut buffer =
            vec![0; usize::try_from(output.metadata()?.len().min(1 << 18)).unwrap_or(0)];
        let read = output.read_at(&mut buffer, 0)?;
        buffer.truncate(read);
        Ok((exit, String::from_utf8_lossy(&buffer).trim().to_owned()))
    }
}

fn failure(args: &[&str], exit: Exit, message: &str) -> io::Error {
    io::Error::other(format!(
        "launchctl {} failed ({exit:?}): {message}",
        args.join(" ")
    ))
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Job {
    target: String,
    dir: PathBuf,
}

impl Job {
    /// True when the job ran at least once and no longer runs, or its exec failed. It parses the text of `launchctl print`.
    pub fn ended(&self, deadline: Instant) -> io::Result<bool> {
        let launchctl = Launchctl {
            job_dir: &self.dir,
            deadline,
        };
        match launchctl.run(&["print", &self.target])? {
            (Exit::Exited(0), text) => Ok(has_ended(&text)),
            (exit, message) => Err(failure(&["print", &self.target], exit, &message)),
        }
    }
}

fn has_ended(text: &str) -> bool {
    let value = |key: &str| {
        text.lines()
            .find_map(|line| line.trim().strip_prefix(key)?.strip_prefix(" = "))
    };
    matches!(value("state"), Some("not running" | "spawn scheduled"))
        && value("runs").and_then(|runs| runs.parse::<u64>().ok()) >= Some(1)
}

fn target(job_dir: &Path) -> io::Result<String> {
    let meta = std::fs::metadata(job_dir)?;
    Ok(format!(
        "gui/{}/ko.server.{:x}.{:x}",
        crate::sock::uid(),
        meta.dev(),
        meta.ino()
    ))
}

fn boot_out(launchctl: &Launchctl<'_>, target: &str) -> io::Result<()> {
    let bootout = ["bootout", target];
    match launchctl.run(&bootout)? {
        (Exit::Exited(0), _) => Ok(()),
        (Exit::Exited(3), message) if message.contains("No such process") => Ok(()),
        (exit, message) => Err(failure(&bootout, exit, &message)),
    }
}

pub(super) fn unload(job_dir: &Path, deadline: Instant) -> io::Result<()> {
    if !job_dir.join("server.plist").exists() {
        return Ok(());
    }
    boot_out(&Launchctl { job_dir, deadline }, &target(job_dir)?)
}

/// Starts the server as a launchd job of the user's GUI domain; `None` when that domain is absent.
pub(super) fn start(
    program: &Path,
    args: &[&str],
    (log, cwd, job_dir): (&Path, Option<&Path>, &Path),
    env: Env<'_>,
    deadline: Instant,
) -> io::Result<Option<Job>> {
    let launchctl = Launchctl { job_dir, deadline };
    let domain = format!("gui/{}", crate::sock::uid());
    if !matches!(launchctl.run(&["print", &domain])?.0, Exit::Exited(0)) {
        return Ok(None);
    }
    let target = target(job_dir)?;
    let program = std::path::absolute(program)?;
    let job_dir = std::path::absolute(job_dir)?;
    let workdir = match cwd {
        Some(cwd) => std::path::absolute(cwd)?,
        None => std::env::current_dir()?,
    };
    let argv: Vec<&[u8]> = std::iter::once(program.as_os_str().as_bytes())
        .chain(args.iter().map(|arg| arg.as_bytes()))
        .collect();
    let inherited: Vec<Vec<u8>>;
    let entries = match env {
        Env::Only(entries) => entries,
        Env::Inherit => {
            inherited = std::env::vars_os()
                .map(|(key, value)| [key.as_bytes(), b"=", value.as_bytes()].concat())
                .collect();
            &inherited
        }
    };
    let label = target.rsplit('/').next().unwrap_or_default();
    let body = plist(label, &argv, entries, &workdir, &std::path::absolute(log)?)?;
    let file = job_dir.join("server.plist");
    OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&file)?
        .write_all(body.as_bytes())?;
    std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600))?;
    boot_out(&launchctl, &target)?;
    let file = file.to_string_lossy();
    let bootstrap = ["bootstrap", &domain, &file];
    match launchctl.run(&bootstrap)? {
        (Exit::Exited(0), _) => Ok(Some(Job {
            target,
            dir: job_dir,
        })),
        (exit, message) => Err(failure(&bootstrap, exit, &message)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_plist_escapes_values_and_splits_the_environment_at_the_first_equals() {
        let body = plist(
            "ko.server.1.2",
            &[b"/bin/ko", b"a&b<c>\"d'\r"],
            &[b"K=a=b".to_vec(), b"E=".to_vec()],
            Path::new("/w"),
            Path::new("/l"),
        )
        .unwrap();
        assert!(body.contains("<string>a&amp;b&lt;c&gt;&quot;d&apos;&#13;</string>"));
        assert!(body.contains("<key>K</key>\n<string>a=b</string>"));
        assert!(body.contains("<key>E</key>\n<string></string>"));
        assert!(body.contains("<key>StandardErrorPath</key>\n<string>/l</string>"));
    }

    #[test]
    fn a_job_has_ended_only_when_it_is_not_running_after_a_run() {
        let print = |state: &str, runs: u32| {
            format!(
                "x = {{\n\tstate = {state}\n\truns = {runs}\n\tproperties = {{\n\t\tstate = active\n\t}}\n}}"
            )
        };
        assert!(has_ended(&print("not running", 1)));
        assert!(has_ended(&print("spawn scheduled", 1)));
        assert!(!has_ended(&print("not running", 0)));
        assert!(!has_ended(&print("running", 1)));
        assert!(!has_ended(&print("xpcproxy", 1)));
    }

    #[test]
    fn the_plist_refuses_what_xml_cannot_hold() {
        let make = |arg: &[u8], env: &[u8]| {
            plist(
                "l",
                &[b"/bin/ko", arg],
                &[env.to_vec()],
                Path::new("/w"),
                Path::new("/l"),
            )
        };
        assert!(make(b"\xff", b"A=b").is_err());
        assert!(make(b"a\x01", b"A=b").is_err());
        assert!(make(b"a", b"NOEQUALS").is_err());
        assert!(make(b"a", b"A=\x00").is_err());
        assert!(make(b"a\tb\n", b"A=b").is_ok());
    }
}
