use std::ffi::OsString;
use std::io;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;

use ko_server::config::is_executable;

use crate::bin_dir::{self, path_prepend_script};
use crate::prime::{self, Mode};

fn argv(path: &Path, mode: Mode) -> Vec<OsString> {
    match mode {
        Mode::Plain => {
            let name = path.file_name().unwrap_or(path.as_os_str());
            let mut dashed = OsString::from("-");
            dashed.push(name);
            vec![dashed]
        }
        Mode::Zsh | Mode::Bash => std::iter::once(path.as_os_str().to_owned())
            .chain(prime::shell_args(mode).iter().map(OsString::from))
            .collect(),
    }
}

fn login_shell() -> PathBuf {
    ["KO_SHELL", "SHELL"]
        .iter()
        .filter_map(std::env::var_os)
        .map(PathBuf::from)
        .find(|shell| is_executable(shell))
        .unwrap_or_else(|| PathBuf::from("/bin/sh"))
}

pub fn exec(command: &[String], exe: &Path) -> io::Error {
    let path = login_shell();
    let bin_dir = bin_dir::of_exe(exe);
    let Some((program, arguments)) = command.split_first() else {
        let zdotdir = std::env::var("ZDOTDIR").ok().filter(|dir| !dir.is_empty());
        let dotdir = zdotdir
            .clone()
            .or_else(|| std::env::var("HOME").ok())
            .unwrap_or_default();
        let mode = prime::local_mode(Path::new(&dotdir), &path);
        let (mode, add) = prime::local(zdotdir.as_deref(), bin_dir.as_deref(), mode)
            .map_or((Mode::Plain, Vec::new()), |add| (mode, add));
        let argv = argv(&path, mode);
        let mut process = Command::new(&path);
        process.envs(add);
        if let Some((first, rest)) = argv.split_first() {
            process.arg0(first).args(rest);
        }
        return process.exec();
    };
    let name = path.file_name().and_then(|name| name.to_str());
    if matches!(name, Some("bash" | "zsh" | "sh" | "dash" | "ksh")) {
        let script = format!(
            "{}exec \"$@\"",
            bin_dir
                .as_deref()
                .map_or(String::new(), path_prepend_script)
        );
        Command::new(&path)
            .args(["-l", "-i", "-c", &script])
            .arg(&path)
            .args(command)
            .exec()
    } else {
        Command::new(program).args(arguments).exec()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn argv_per_mode() {
        let shown = |path: &str, mode| {
            argv(Path::new(path), mode)
                .iter()
                .map(|arg| arg.to_string_lossy().into_owned())
                .collect::<Vec<_>>()
                .join(" ")
        };
        assert_eq!(shown("/bin/zsh", Mode::Zsh), "/bin/zsh -l");
        assert_eq!(shown("/bin/bash", Mode::Bash), "/bin/bash --login --posix");
        assert_eq!(shown("/usr/bin/fish", Mode::Plain), "-fish");
    }
}
