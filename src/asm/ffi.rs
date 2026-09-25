//! The C ABI between Rust and asm/lib.asm. Field offsets here are mirrored by
//! the RQ_* constants in asm/ttfx.inc; change both together.

use std::ffi::c_void;
use std::time::Instant;

use super::effects::{self, Words};
use super::Run;
use crate::engine::animation::ExistingColorHandling;
use crate::engine::effect::RunOutcome;
use crate::engine::error::EngineError;
use crate::engine::terminal::{self, TerminalConfig};
use crate::utils::graphics::Color;
use crate::utils::rng::Rng;

#[repr(C)]
struct Request {
    input_ptr: *const u8,
    input_len: u64,
    effect: u64,
    effect_config: *const u64,
    tab_width: i64,
    frame_rate: i64,
    canvas_width: i64,
    canvas_height: i64,
    anchor_canvas: u64,
    anchor_text: u64,
    existing_colors: u64,
    background: u64,
    flags: u64,
    max_frames: u64,
    term_width: i64,
    term_height: i64,
    rng_state: [u64; 4],
    stop_check: extern "C" fn(*mut c_void) -> u64,
    stop_ctx: *mut c_void,
    line_lengths: *const i64,
    line_count: u64,
    error_ptr: *const u8,
    error_len: u64,
    error_kind: u64,
}

const FL_XTERM_COLORS: u64 = 1 << 0;
const FL_NO_COLOR: u64 = 1 << 1;
const FL_WRAP_TEXT: u64 = 1 << 2;
const FL_IGNORE_DIMS: u64 = 1 << 3;
const FL_REUSE_CANVAS: u64 = 1 << 4;
const FL_NO_EOL: u64 = 1 << 5;
const FL_NO_RESTORE: u64 = 1 << 6;
const FL_PARITY_DUMP: u64 = 1 << 7;
const FL_VIRTUAL_CLOCK: u64 = 1 << 8;
const FL_TTY_OUTPUT: u64 = 1 << 9;

const OUT_DECLINED: i64 = 0;
const OUT_COMPLETE: i64 = 1;
const OUT_INTERRUPTED: i64 = 2;
const OUT_TERMINATED: i64 = 3;
const OUT_RESIZED: i64 = 4;
const OUT_OUTPUT_CLOSED: i64 = 5;
const OUT_ERROR: i64 = 6;

const STOP_NONE: u64 = 0;
const STOP_INTERRUPT: u64 = 1;
const STOP_TERMINATE: u64 = 2;
const STOP_RESIZE: u64 = 3;

const ERR_ANSI: u64 = 1;

extern "C" {
    fn ttfx_asm_tier() -> i32;
    fn ttfx_asm_effect_supported(effect: u64) -> i32;
    fn ttfx_asm_run(request: *mut Request) -> i64;
}

/// What the stop check needs; lives on the stack for the duration of a run.
struct StopContext<'a> {
    config: &'a TerminalConfig,
    tty_output: bool,
    dimensions: (i64, i64),
    request: *const Request,
    resize_seen_at: Option<Instant>,
}

/// run_effect's requested_stop, called by the engine at the same points.
extern "C" fn stop_check(context: *mut c_void) -> u64 {
    // SAFETY: the engine passes back the pointer offer() gave it, which
    // outlives the run; nothing else holds a reference to it meanwhile.
    let context = unsafe { &mut *(context as *mut StopContext<'_>) };
    if crate::interrupted() {
        return STOP_INTERRUPT;
    }
    if crate::terminated() {
        return STOP_TERMINATE;
    }
    if context.tty_output {
        // SAFETY: the engine publishes the line lengths before its first stop
        // check and keeps them alive for the whole run.
        let line_lengths = unsafe {
            let request = &*context.request;
            if request.line_lengths.is_null() {
                &[][..]
            } else {
                std::slice::from_raw_parts(request.line_lengths, request.line_count as usize)
            }
        };
        if terminal::resize_settled(&mut context.resize_seen_at, context.config, line_lengths, context.dimensions) {
            return STOP_RESIZE;
        }
    }
    STOP_NONE
}

/// The engine's color format: 0xRRGGBB, plus the xterm code in bits 32-39 and
/// bit 40 for colors built from one (they render as that code under
/// --xterm-colors instead of the nearest match).
pub fn color_word(color: &Color) -> u64 {
    let (r, g, b) = color.rgb_ints();
    let rgb = (r as u64) << 16 | (g as u64) << 8 | b as u64;
    match color.xterm_color {
        Some(code) => rgb | (code as u64) << 32 | 1 << 40,
        None => rgb,
    }
}

pub fn offer(run: Run<'_>) -> Result<Result<RunOutcome, EngineError>, &'static str> {
    // SAFETY: ttfx_asm_tier only executes CPUID and XGETBV.
    if unsafe { ttfx_asm_tier() } == 0 {
        return Err("this CPU lacks the instruction sets of every assembled tier");
    }
    let config = run.config;
    if run.input.contains('\x1b') {
        return Err("ANSI sequences in the input are not ported yet");
    }
    if config.wrap_text {
        return Err("--wrap-text is not ported yet");
    }
    if config.existing_color_handling != ExistingColorHandling::Ignore {
        return Err("--existing-color-handling is not ported yet");
    }
    let (id, words): (u64, Words) = effects::marshal(run.effect)?;
    // SAFETY: a pure query of the engine's effect table.
    if unsafe { ttfx_asm_effect_supported(id) } == 0 {
        return Err("this effect is not ported yet");
    }

    let dimensions = terminal::get_terminal_dimensions();
    let flags = [
        (config.xterm_colors, FL_XTERM_COLORS),
        (config.no_color, FL_NO_COLOR),
        (config.wrap_text, FL_WRAP_TEXT),
        (config.ignore_terminal_dimensions, FL_IGNORE_DIMS),
        (config.reuse_canvas, FL_REUSE_CANVAS),
        (config.no_eol, FL_NO_EOL),
        (config.no_restore_cursor, FL_NO_RESTORE),
        (run.parity_dump, FL_PARITY_DUMP),
        (run.virtual_clock, FL_VIRTUAL_CLOCK),
        (run.tty_output, FL_TTY_OUTPUT),
    ]
    .iter()
    .filter(|(on, _)| *on)
    .fold(0, |flags, (_, bit)| flags | bit);

    let mut request = Box::new(Request {
        input_ptr: run.input.as_ptr(),
        input_len: run.input.len() as u64,
        effect: id,
        effect_config: words.as_ptr(),
        tab_width: config.tab_width,
        frame_rate: config.frame_rate,
        canvas_width: config.canvas_width,
        canvas_height: config.canvas_height,
        anchor_canvas: config.anchor_canvas as u64,
        anchor_text: config.anchor_text as u64,
        existing_colors: config.existing_color_handling as u64,
        background: color_word(&config.terminal_background_color),
        flags,
        max_frames: run.max_frames.unwrap_or(u64::MAX),
        term_width: dimensions.0,
        term_height: dimensions.1,
        rng_state: run.rng.state(),
        stop_check,
        stop_ctx: std::ptr::null_mut(),
        line_lengths: std::ptr::null(),
        line_count: 0,
        error_ptr: std::ptr::null(),
        error_len: 0,
        error_kind: 0,
    });
    let mut stop = StopContext {
        config,
        tty_output: run.tty_output,
        dimensions,
        request: &*request,
        resize_seen_at: None,
    };
    request.stop_ctx = &mut stop as *mut StopContext<'_> as *mut c_void;

    // SAFETY: the request and everything it points to (input, config words,
    // stop context) outlive the call; the engine writes only the out fields.
    let outcome = unsafe { ttfx_asm_run(&mut *request) };
    drop(words);
    if outcome == OUT_DECLINED {
        return Err("the engine declined the run");
    }
    *run.rng = Rng::from_state(request.rng_state);
    Ok(match outcome {
        OUT_COMPLETE => Ok(RunOutcome::Complete),
        OUT_INTERRUPTED => Ok(RunOutcome::Interrupted),
        OUT_TERMINATED => Ok(RunOutcome::Terminated),
        OUT_RESIZED => Ok(RunOutcome::TerminalResized),
        OUT_OUTPUT_CLOSED => Ok(RunOutcome::OutputClosed),
        OUT_ERROR => {
            // SAFETY: the engine points the error at static data or at the
            // input, both alive here.
            let bytes = unsafe { std::slice::from_raw_parts(request.error_ptr, request.error_len as usize) };
            let text = String::from_utf8_lossy(bytes).into_owned();
            Err(if request.error_kind == ERR_ANSI {
                EngineError::UnsupportedAnsiSequence(text)
            } else {
                EngineError::Other(text)
            })
        }
        errno if errno < 0 => Err(EngineError::Other(format!(
            "io error: {}",
            std::io::Error::from_raw_os_error(-errno as i32)
        ))),
        other => Err(EngineError::Other(format!("asm engine: unknown outcome {other}"))),
    })
}
