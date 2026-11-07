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

fn login_shell(in_runtime: bool) -> PathBuf {
    ["KO_SHELL", "SHELL"]
        .into_iter()
        .filter(|name| *name != "KO_SHELL" || !in_runtime)
        .filter_map(std::env::var_os)
        .map(PathBuf::from)
        .chain(std::iter::once_with(|| ko_sys::user::login_shell().ok().flatten()).flatten())
        .find(|shell| is_executable(shell))
        .unwrap_or_else(|| PathBuf::from("/bin/sh"))
}

pub fn exec(command: &[String], exe: &Path, in_runtime: bool) -> io::Error {
    let selected = match command {
        [program]
            if matches!(
                Path::new(program)
                    .file_name()
                    .and_then(|name| name.to_str()),
                Some("bash" | "zsh")
            ) =>
        {
            let path = PathBuf::from(program);
            if path.components().count() > 1 {
                Some(path)
            } else {
                std::env::var_os("PATH").and_then(|paths| {
                    std::env::split_paths(&paths)
                        .map(|dir| dir.join(program))
                        .find(|path| is_executable(path))
                })
            }
        }
        _ => None,
    };
    let remaining = command.split_first().filter(|_| selected.is_none());
    let path = selected.unwrap_or_else(|| login_shell(in_runtime));
    let bin_dir = bin_dir::of_exe(exe);
    let Some((program, arguments)) = remaining else {
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
