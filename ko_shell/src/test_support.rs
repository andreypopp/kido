use std::fs;
use std::io::{Read, Write};
use std::os::fd::AsFd;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use ko_sys::spawn::{self, Env};

pub(crate) fn scratch(name: &str) -> PathBuf {
    let dir = PathBuf::from(format!("/tmp/ko-shell-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

pub(crate) fn write(path: &Path, body: &str, mode: u32) -> PathBuf {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, body).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(mode)).unwrap();
    path.to_path_buf()
}

pub(crate) fn run(program: &Path, args: &[&str], stdin: &str, env: &[(&str, &str)]) -> String {
    let (input, mut feed) = std::io::pipe().unwrap();
    let (mut output, sink) = std::io::pipe().unwrap();
    let env: Vec<Vec<u8>> = env
        .iter()
        .map(|(name, value)| format!("{name}={value}").into_bytes())
        .collect();
    let pid = spawn::program(
        program,
        args,
        &[(input.as_fd(), 0), (sink.as_fd(), 1), (sink.as_fd(), 2)],
        Env::Only(&env),
    )
    .unwrap();
    drop((input, sink));
    let _ = feed.write_all(stdin.as_bytes());
    drop(feed);
    let mut bytes = Vec::new();
    output.read_to_end(&mut bytes).unwrap();
    let _ = pid.wait();
    String::from_utf8_lossy(&bytes).into_owned()
}
