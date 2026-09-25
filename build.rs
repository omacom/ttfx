//! Assembles the x86-64 engine (asm/, plans/asm-x86.md) with NASM and links it
//! into the binary. Only for x86_64 Linux with the `asm` feature (on by
//! default); everywhere else ttfx is pure Rust.

use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    println!("cargo::rustc-check-cfg=cfg(ttfx_asm)");
    println!("cargo::rerun-if-changed=asm");
    println!("cargo::rerun-if-env-changed=NASM");

    let arch = env::var("CARGO_CFG_TARGET_ARCH").unwrap_or_default();
    let os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if env::var_os("CARGO_FEATURE_ASM").is_none() || arch != "x86_64" || os != "linux" {
        return;
    }

    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    let object = out.join("ttfx_asm.o");
    let library = out.join("libttfx_asm.a");
    let nasm = env::var("NASM").unwrap_or_else(|_| "nasm".to_string());

    let status = Command::new(&nasm)
        .args(["-f", "elf64", "-O3", "-I", "asm/", "-o"])
        .arg(&object)
        .arg("asm/lib.asm")
        .status();
    match status {
        Ok(status) if status.success() => {}
        Ok(_) => panic!("NASM failed to assemble asm/lib.asm"),
        // No NASM: build the pure-Rust engine rather than failing the build.
        Err(e) => {
            println!(
                "cargo::warning=NASM not found ({nasm}: {e}); building without the assembly \
                 engine. Install NASM >= 3.0 (pacman -S nasm) or point NASM= at it."
            );
            return;
        }
    }
    let status = Command::new("ar").arg("crs").arg(&library).arg(&object).status().expect("ar");
    assert!(status.success(), "ar failed to archive the assembly engine");

    println!("cargo::rustc-link-search=native={}", out.display());
    println!("cargo::rustc-link-lib=static=ttfx_asm");
    println!("cargo::rustc-cfg=ttfx_asm");
}
