#![allow(clippy::expect_used, clippy::print_stdout)]

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
    println!("cargo:rerun-if-env-changed=KO_ZIG_CACHE");
    let cache = PathBuf::from(env::var_os("KO_ZIG_CACHE").expect("KO_ZIG_CACHE"));
    let musl = env::var("CARGO_CFG_TARGET_ENV").is_ok_and(|env| env == "musl");
    let linux = env::var("CARGO_CFG_TARGET_OS").is_ok_and(|os| os == "linux");
    let arch = env::var("CARGO_CFG_TARGET_ARCH").expect("CARGO_CFG_TARGET_ARCH");
    let mut zig = Command::new("zig");
    zig.arg("build");
    if musl {
        zig.arg(format!("-Dtarget={arch}-linux-musl"));
    } else if linux {
        // zig's native glibc detection keeps only the stdlib.h and sys/errno.h
        // directories of $CC, and Homebrew's gcc has the kernel headers in a
        // third one. An explicit target uses zig's own glibc headers.
        zig.arg(format!("-Dtarget={arch}-linux-gnu.2.34"))
            .arg("-Dcpu=native");
    }
    let status = zig
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
    let cxx = if musl || env::var("CARGO_CFG_TARGET_OS").is_ok_and(|os| os == "macos") {
        "c++"
    } else {
        "stdc++"
    };
    println!("cargo:rustc-link-lib={cxx}");
}
