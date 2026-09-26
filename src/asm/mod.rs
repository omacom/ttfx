//! In-process dispatch to the x86-64 assembly engine (asm/, plans/asm-x86.md).
//!
//! Rust stays the front end: it parses the command line, reads and validates
//! the input, seeds the RNG and installs the signal handlers. Each run is then
//! offered to the assembly engine, which either declines before doing anything
//! observable — so the Rust engine runs it instead — or runs the effect to the
//! end and reports how it ended. Output is byte-identical either way.
//!
//! `TTFX_ASM=0` forces the Rust engine; `TTFX_ASM=force` turns a decline into
//! an error, so tests cannot silently fall back.
//!
//! The engine is assembled once per x86-64 level (v1 = SSE2, v2, v3 = AVX2,
//! v4 = AVX-512), and the best one the CPU supports runs; every tier's output
//! is byte-identical. `TTFX_ASM_TIER=1|2|3|4` forces a lower tier for testing:
//! a tier above the CPU's, or one the build left out, is a decline (exit 3
//! under `TTFX_ASM=force`). `TTFX_ASM_SHOW_TIER=1` prints on stderr which
//! engine ran: the asm tier chosen, or why the Rust engine ran instead. See asm/PORTING.md, "CPU tiers".

use crate::effects::EffectCommand;
use crate::engine::effect::RunOutcome;
use crate::engine::error::EngineError;
use crate::engine::terminal::TerminalConfig;
use crate::utils::rng::Rng;

#[cfg(ttfx_asm)]
mod effects;
#[cfg(ttfx_asm)]
mod ffi;

/// One run as the front end sees it.
pub struct Run<'a> {
    pub effect: &'a EffectCommand,
    pub input: &'a str,
    pub config: &'a TerminalConfig,
    pub rng: &'a mut Rng,
    pub parity_dump: bool,
    pub virtual_clock: bool,
    pub max_frames: Option<u64>,
    pub tty_output: bool,
}

/// Run the effect on the assembly engine when it can take it. None means the
/// Rust engine must run it (nothing was written and the RNG is untouched).
pub fn try_run(run: Run<'_>) -> Option<Result<RunOutcome, EngineError>> {
    let mode = std::env::var("TTFX_ASM").unwrap_or_default();
    let show = std::env::var_os("TTFX_ASM_SHOW_TIER").is_some();
    if mode == "0" || mode == "off" {
        if show {
            crate::errln!("ttfx: Rust engine (TTFX_ASM={mode})");
        }
        return None;
    }
    let result = offer(run);
    if let Err(reason) = &result {
        if mode == "force" {
            crate::errln!("ttfx: TTFX_ASM=force, but the assembly engine declined: {reason}");
            std::process::exit(3);
        }
        if show {
            crate::errln!("ttfx: Rust engine (the assembly engine declined: {reason})");
        }
    }
    result.ok()
}

#[cfg(not(ttfx_asm))]
fn offer(_run: Run<'_>) -> Result<Result<RunOutcome, EngineError>, &'static str> {
    Err("this build has no assembly engine")
}

#[cfg(ttfx_asm)]
fn offer(run: Run<'_>) -> Result<Result<RunOutcome, EngineError>, &'static str> {
    ffi::offer(run)
}
