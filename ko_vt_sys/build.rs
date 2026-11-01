#![allow(clippy::expect_used)]

use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    let out = PathBuf::from(env::var_os("OUT_DIR").expect("OUT_DIR"));
    let ghostty = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"))
        .join("../third_party/ghostty");
    for input in ["build.zig", "build.zig.zon", "src", "include", "pkg"] {
        println!("cargo:rerun-if-changed={}", ghostty.join(input).display());
    }
    let target = out
        .ancestors()
        .find(|dir| dir.join("CACHEDIR.TAG").is_file())
        .expect("cargo's target directory");
    let cache = target.join("zig-cache");
    let status = Command::new("zig")
        .arg("build")
        .arg("--build-file")
        .arg(ghostty.join("build.zig"))
        .args([
            "-Demit-lib-vt",
            "-Demit-xcframework=false",
            "-Doptimize=ReleaseFast",
        ])
        .arg("--cache-dir")
        .arg(cache.join("local"))
        .arg("--prefix")
        .arg(out.join("zig-out"))
        .env("ZIG_GLOBAL_CACHE_DIR", cache.join("global"))
        .status()
        .expect("zig from PATH");
    assert!(status.success(), "zig build failed: {status}");
    println!(
        "cargo:rustc-link-search=native={}",
        out.join("zig-out/lib").display()
    );
    println!("cargo:rustc-link-lib=static=ghostty-vt");
    println!("cargo:rustc-link-lib=c++");
}
