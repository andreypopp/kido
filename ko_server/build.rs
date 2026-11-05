#![allow(clippy::expect_used, clippy::panic, clippy::print_stdout)]

use std::env;

fn main() {
    println!("cargo:rerun-if-env-changed=KO_VT");
    println!("cargo:rerun-if-env-changed=KO_BUILD_ID");
    let revision = env::var("KO_VT").expect("run cargo through make to set KO_VT");
    if revision.len() != 40 || !revision.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        panic!("invalid ghostty pin from make: {revision:?}");
    }
    let build = env::var("KO_BUILD_ID").expect("run cargo through make to set KO_BUILD_ID");
    println!("cargo:rustc-env=KO_VT={revision}");
    println!("cargo:rustc-env=KO_BUILD={build}");
}
