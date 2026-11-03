#![allow(clippy::expect_used, clippy::panic, clippy::print_stdout)]

use std::env;
use std::path::PathBuf;
use std::process::Command;

fn git(root: &PathBuf, args: &[&str]) -> String {
    let output = Command::new("git")
        .arg("-C")
        .arg(root)
        .args(args)
        .output()
        .expect("git from PATH");
    assert!(output.status.success(), "git {args:?} failed");
    String::from_utf8(output.stdout).expect("git prints UTF-8")
}

fn main() {
    let root =
        PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR")).join("..");
    let listed = git(&root, &["ls-files", "-s", "third_party/ghostty"]);
    let revision = listed.split_whitespace().nth(1).unwrap_or_default();
    if revision.len() != 40 || !revision.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        panic!("no ghostty pin in the index: {listed:?}");
    }
    let index = git(
        &root,
        &["rev-parse", "--path-format=absolute", "--git-path", "index"],
    );
    println!(
        "cargo:rerun-if-changed={}",
        root.join(".gitmodules").display()
    );
    println!("cargo:rerun-if-changed={}", index.trim());
    println!("cargo:rustc-env=KO_VT={revision}");
    println!("cargo:rerun-if-env-changed=KO_BUILD_ID");
    let build = env::var("KO_BUILD_ID").unwrap_or_else(|_| "unknown".to_owned());
    println!("cargo:rustc-env=KO_BUILD={build}");
}
