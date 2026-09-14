#[cfg(not(target_arch = "wasm32"))]
pub mod cli;
pub mod effects;
pub mod engine;
pub mod utils;

#[cfg(target_arch = "wasm32")]
pub mod wasm;

#[cfg(not(target_arch = "wasm32"))]
use std::sync::atomic::{AtomicBool, Ordering};

/// `println!` and `eprintln!` panic when their write fails, and a release
/// build aborts on panic — so on a terminal that has just gone away, reporting
/// the loss is what dumps the core, not the loss itself:
///
/// ```text
/// thread 'main' panicked at library/std/src/io/stdio.rs:1166:9:
/// failed printing to stderr: Input/output error (os error 5)
/// ```
///
/// Nothing ttfx says is worth dying over, so messages go out through these two
/// and a failed write is dropped (basecamp/omarchy#6762).
#[macro_export]
macro_rules! outln {
    ($($arg:tt)*) => {{
        let _ = ::std::io::Write::write_fmt(
            &mut ::std::io::stdout(),
            format_args!("{}\n", format_args!($($arg)*)),
        );
    }};
}

/// [`outln!`] for stderr.
#[macro_export]
macro_rules! errln {
    ($($arg:tt)*) => {{
        let _ = ::std::io::Write::write_fmt(
            &mut ::std::io::stderr(),
            format_args!("{}\n", format_args!($($arg)*)),
        );
    }};
}

#[cfg(target_arch = "wasm32")]
pub fn interrupted() -> bool {
    false
}

#[cfg(target_arch = "wasm32")]
pub fn terminated() -> bool {
    false
}

#[cfg(target_arch = "wasm32")]
pub fn take_terminal_resize() -> bool {
    false
}

#[cfg(not(target_arch = "wasm32"))]
static INTERRUPTED: AtomicBool = AtomicBool::new(false);
#[cfg(not(target_arch = "wasm32"))]
static TERMINATED: AtomicBool = AtomicBool::new(false);
#[cfg(not(target_arch = "wasm32"))]
static TERMINAL_RESIZED: AtomicBool = AtomicBool::new(false);

/// SIGINT is recorded and checked from the run loop so teardown (cursor
/// restore) happens through normal control flow — Drop alone would not run on
/// a raw signal exit (plan.md §8).
#[cfg(not(target_arch = "wasm32"))]
pub fn install_sigint_handler() {
    // SAFETY: signal(2) with a signal-safe handler that only stores a flag.
    unsafe {
        libc_signal(SIGINT, handle_sigint as *const () as usize);
    }
}

#[cfg(not(target_arch = "wasm32"))]
extern "C" fn handle_sigint(_: i32) {
    INTERRUPTED.store(true, Ordering::SeqCst);
}

#[cfg(not(target_arch = "wasm32"))]
pub fn interrupted() -> bool {
    INTERRUPTED.load(Ordering::SeqCst)
}

/// SIGTERM is recorded like SIGINT so a supervisor killing an animation gets
/// the normal teardown instead of a hidden cursor. `die_from_sigterm` then
/// finishes the job the handler deferred.
#[cfg(not(target_arch = "wasm32"))]
pub fn install_sigterm_handler() {
    // SAFETY: signal(2) with a signal-safe handler that only stores a flag.
    unsafe {
        libc_signal(SIGTERM, handle_sigterm as *const () as usize);
    }
}

#[cfg(not(target_arch = "wasm32"))]
extern "C" fn handle_sigterm(_: i32) {
    TERMINATED.store(true, Ordering::SeqCst);
}

#[cfg(not(target_arch = "wasm32"))]
pub fn terminated() -> bool {
    TERMINATED.load(Ordering::SeqCst)
}

/// Finish the SIGTERM we deferred: the cursor is back, so hand the signal to
/// the default action and die from it. A supervisor then sees a terminated
/// child, exactly as it would from the redirected run that never installs a
/// handler at all. SIGINT does not go through here — upstream exits 1 on
/// KeyboardInterrupt and parity outranks the convention (plan.md §8).
#[cfg(not(target_arch = "wasm32"))]
pub fn die_from_sigterm() -> ! {
    // SAFETY: restoring the default action and re-raising is the documented
    // way to exit with a signal's status; raise(2) here does not return.
    unsafe {
        libc_signal(SIGTERM, SIG_DFL);
        libc_raise(SIGTERM);
    }
    unreachable!("SIGTERM with the default action terminates the process");
}

/// Record terminal resizes so the CLI can rebuild effects whose canvas and
/// character positions were derived from the previous dimensions.
#[cfg(not(target_arch = "wasm32"))]
pub fn install_sigwinch_handler() {
    // SAFETY: signal(2) with a signal-safe handler that only stores a flag.
    unsafe {
        libc_signal(SIGWINCH, handle_sigwinch as *const () as usize);
    }
}

#[cfg(not(target_arch = "wasm32"))]
extern "C" fn handle_sigwinch(_: i32) {
    TERMINAL_RESIZED.store(true, Ordering::SeqCst);
}

/// Consume a pending terminal resize notification.
#[cfg(not(target_arch = "wasm32"))]
pub fn take_terminal_resize() -> bool {
    TERMINAL_RESIZED.swap(false, Ordering::SeqCst)
}

/// Restore default SIGPIPE so `ttfx ... | head` dies quietly like any Unix
/// tool instead of panicking on a broken pipe (Rust ignores SIGPIPE by default).
#[cfg(not(target_arch = "wasm32"))]
pub fn restore_sigpipe() {
    unsafe {
        libc_signal(SIGPIPE, SIG_DFL);
    }
}

#[cfg(not(target_arch = "wasm32"))]
const SIGINT: i32 = 2;
#[cfg(not(target_arch = "wasm32"))]
const SIGTERM: i32 = 15;
#[cfg(not(target_arch = "wasm32"))]
const SIGPIPE: i32 = 13;
/// 28 on Linux and on the BSDs, macOS included.
#[cfg(not(target_arch = "wasm32"))]
const SIGWINCH: i32 = 28;
#[cfg(not(target_arch = "wasm32"))]
const SIG_DFL: usize = 0;

#[cfg(not(target_arch = "wasm32"))]
unsafe fn libc_signal(signum: i32, handler: usize) {
    unsafe extern "C" {
        fn signal(signum: i32, handler: usize) -> usize;
    }
    unsafe {
        signal(signum, handler);
    }
}

#[cfg(not(target_arch = "wasm32"))]
unsafe fn libc_raise(signum: i32) {
    unsafe extern "C" {
        fn raise(signum: i32) -> i32;
    }
    unsafe {
        raise(signum);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn terminal_resize_notifications_are_consumed() {
        take_terminal_resize();
        handle_sigwinch(SIGWINCH);
        assert!(take_terminal_resize());
        assert!(!take_terminal_resize());
    }
}
