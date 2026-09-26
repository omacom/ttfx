//! Assembles the x86-64 engine (asm/, plans/asm-x86.md) with NASM and links it
//! into the binary. Only for x86_64 Linux with the `asm` feature (on by
//! default); everywhere else ttfx is pure Rust.
//!
//! asm/lib.asm is assembled once per CPU tier (-DTIER=1..4, x86-64-v1..v4);
//! each object exports its entry points with a `_v<tier>` suffix. asm/tier.asm
//! (CPU detection and the test thunks) is assembled once at the baseline.
//! Every tier's object must pass tools/asm/isa-audit.sh before it is linked;
//! a tier that fails to assemble or audit is left out with a warning, and
//! src/asm/ffi.rs only offers the tiers built (`cfg(ttfx_asm_tier = "n")`).
//!
//! `TTFX_ASM_UNCHECKED_TIERS=1` links every tier without NASM's CPU level or
//! the audit: a development build for checking lower tiers' output on a CPU
//! that runs everything. Its lower tiers may crash on real older CPUs.

use std::env;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

const TIERS: [u32; 4] = [1, 2, 3, 4];

fn main() {
    println!("cargo::rustc-check-cfg=cfg(ttfx_asm)");
    println!("cargo::rustc-check-cfg=cfg(ttfx_asm_tier, values(\"1\", \"2\", \"3\", \"4\"))");
    println!("cargo::rerun-if-changed=asm");
    println!("cargo::rerun-if-changed=tools/asm/isa-audit.sh");
    println!("cargo::rerun-if-env-changed=NASM");
    println!("cargo::rerun-if-env-changed=TTFX_ASM_UNCHECKED_TIERS");

    let arch = env::var("CARGO_CFG_TARGET_ARCH").unwrap_or_default();
    let os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if env::var_os("CARGO_FEATURE_ASM").is_none() || arch != "x86_64" || os != "linux" {
        return;
    }

    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    let nasm = env::var("NASM").unwrap_or_else(|_| "nasm".to_string());
    let unchecked = env::var("TTFX_ASM_UNCHECKED_TIERS").is_ok_and(|v| v == "1");

    // Assemble the four tiers in parallel.
    let mut jobs = Vec::new();
    for tier in TIERS {
        let object = out.join(format!("ttfx_asm_v{tier}.o"));
        let mut command = Command::new(&nasm);
        command.args(["-f", "elf64", "-O3", "-I", "asm/"]).arg(format!("-DTIER={tier}"));
        if unchecked {
            command.arg("-DTTFX_NO_CPU_CHECK");
        }
        command.arg("-o").arg(&object).arg("asm/lib.asm").stderr(Stdio::piped());
        match command.spawn() {
            Ok(child) => jobs.push((tier, object, child)),
            // No NASM: build the pure-Rust engine rather than failing the build.
            Err(e) => {
                println!(
                    "cargo::warning=NASM not found ({nasm}: {e}); building without the assembly \
                     engine. Install NASM >= 3.0 (pacman -S nasm) or point NASM= at it."
                );
                return;
            }
        }
    }
    let mut built = Vec::new();
    for (tier, object, child) in jobs {
        let output = child.wait_with_output().expect("NASM");
        if output.status.success() {
            built.push((tier, object));
            continue;
        }
        let errors = String::from_utf8_lossy(&output.stderr);
        let errors: Vec<&str> = errors.lines().filter(|l| l.contains("error")).collect();
        println!(
            "cargo::warning=asm tier {tier} left out: NASM rejected it ({} errors, first: {})",
            errors.len(),
            errors.first().unwrap_or(&"?")
        );
    }

    // Audit each object against its tier's instruction set.
    let audits: Vec<_> = built
        .iter()
        .map(|(tier, object)| {
            Command::new("bash")
                .arg("tools/asm/isa-audit.sh")
                .arg("-q")
                .arg(tier.to_string())
                .arg(object)
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
        })
        .collect();
    let mut linked = Vec::new();
    for ((tier, object), audit) in built.into_iter().zip(audits) {
        match audit.and_then(|child| child.wait_with_output()) {
            Ok(output) if output.status.success() => linked.push((tier, object)),
            Ok(output) if output.status.code() == Some(1) => {
                let summary = String::from_utf8_lossy(&output.stdout);
                if unchecked {
                    println!("cargo::warning=asm tier {tier} linked UNCHECKED: {}", summary.trim());
                    linked.push((tier, object));
                } else {
                    println!("cargo::warning=asm tier {tier} left out: {}", summary.trim());
                }
            }
            Ok(output) => {
                println!(
                    "cargo::warning=could not audit asm tier {tier} (needs bash, objdump and python3): {}",
                    String::from_utf8_lossy(&output.stderr).trim()
                );
                linked.push((tier, object));
            }
            Err(e) => {
                println!("cargo::warning=could not audit asm tier {tier}: {e}");
                linked.push((tier, object));
            }
        }
    }
    if linked.is_empty() {
        println!("cargo::warning=no asm tier could be built; building without the assembly engine");
        return;
    }

    // The tier-independent object: detection and the test thunks' dispatch.
    let mask: u32 = linked.iter().map(|(tier, _)| 1 << tier).sum();
    write_test_thunks(&out.join("test_thunks.inc"));
    let tier_object = out.join("ttfx_asm_tier.o");
    let status = Command::new(&nasm)
        .args(["-f", "elf64", "-O3", "-I", "asm/", "-I"])
        .arg(format!("{}/", out.display()))
        .args(["-DTIER=1", &format!("-DTIERS_BUILT={mask}"), "-o"])
        .arg(&tier_object)
        .arg("asm/tier.asm")
        .status()
        .expect("NASM");
    assert!(status.success(), "NASM failed to assemble asm/tier.asm");

    let library = out.join("libttfx_asm.a");
    let _ = std::fs::remove_file(&library);
    let status = Command::new("ar")
        .arg("crs")
        .arg(&library)
        .arg(&tier_object)
        .args(linked.iter().map(|(_, object)| object))
        .status()
        .expect("ar");
    assert!(status.success(), "ar failed to archive the assembly engine");

    println!("cargo::rustc-link-search=native={}", out.display());
    println!("cargo::rustc-link-lib=static=ttfx_asm");
    println!("cargo::rustc-cfg=ttfx_asm");
    for (tier, _) in &linked {
        println!("cargo::rustc-cfg=ttfx_asm_tier=\"{tier}\"");
    }
}

/// The TEST_THUNK list asm/tier.asm includes: every EXPORT in asm/tests.asm.
fn write_test_thunks(path: &Path) {
    let tests = std::fs::read_to_string("asm/tests.asm").expect("asm/tests.asm");
    let thunks: String = tests
        .lines()
        .filter_map(|line| line.trim().strip_prefix("EXPORT "))
        .map(|name| format!("TEST_THUNK {}\n", name.trim()))
        .collect();
    std::fs::write(path, thunks).expect("test_thunks.inc");
}
