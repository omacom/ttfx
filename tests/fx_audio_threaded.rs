//! A color transform installed mid-run on a threaded run: the renderer
//! comes back to the effect's thread, and the transform shows from the frame
//! that installed it, exactly as on a run that was never threaded. One test
//! in its own binary, as it points stdout (where run_effect writes) at a file.

use std::io::{Read, Seek, Write};
use std::os::fd::AsRawFd;

use clap::Parser;
use ttfx::cli::Cli;
use ttfx::engine::ctx::Clock;
use ttfx::engine::error::EngineError;
use ttfx::fx::{self, AudioColor, Engine, Hooks};
use ttfx::utils::rng::Rng;

const ARGS: &[&str] = &[
    "ttfx",
    "--canvas-width",
    "24",
    "--canvas-height",
    "8",
    "--ignore-terminal-dimensions",
    "decrypt",
];

/// An effect that installs a transform before its `at`th frame; `primed`,
/// it first renders a frame under one and removes it again.
struct Late {
    inner: Box<dyn fx::run::Effect>,
    frame: u32,
    at: u32,
    primed: bool,
}

const HALF: AudioColor = AudioColor {
    brightness: 0.5,
    matrix: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
};

impl Hooks for Late {
    fn callback(&mut self, e: &mut Engine, slot: u32, id: u32, arg: i64) {
        self.inner.callback(e, slot, id, arg);
    }
}

impl fx::run::Effect for Late {
    fn build(&mut self, e: &mut Engine) -> Result<(), EngineError> {
        self.inner.build(e)?;
        if self.primed {
            e.set_audio_color(Some(HALF));
            self.inner.next_frame(e);
            e.frame();
            e.render_here();
            e.set_audio_color(None);
        }
        Ok(())
    }

    fn next_frame(&mut self, e: &mut Engine) -> bool {
        self.frame += 1;
        if self.frame == self.at {
            e.set_audio_color(Some(HALF));
        }
        self.inner.next_frame(e)
    }
}

unsafe extern "C" {
    fn dup(fd: i32) -> i32;
    fn dup2(from: i32, to: i32) -> i32;
    fn close(fd: i32) -> i32;
}

/// A new file of our own in the temp directory. `create_new` refuses a path
/// that already exists, a symlink included, so a name planted ahead of us
/// is skipped rather than followed and truncated.
fn scratch_file() -> (std::path::PathBuf, std::fs::File) {
    use std::os::unix::fs::OpenOptionsExt;
    static NEXT: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.subsec_nanos());
    for _ in 0..100 {
        let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "ttfx-threaded-{}-{nanos:08x}-{n}",
            std::process::id()
        ));
        match std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&path)
        {
            Ok(file) => return (path, file),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => panic!("creating {}: {e}", path.display()),
        }
    }
    panic!("no free scratch file name in the temp directory");
}

/// What run_effect writes with TTFX_THREADS=`threads`, the transform
/// installed before frame `at` (0: never).
fn run(threads: &str, at: u32, primed: bool) -> Vec<u8> {
    std::env::set_var("TTFX_THREADS", threads);
    let cli = Cli::try_parse_from(ARGS).unwrap();
    let mut e = Engine::new(
        "LIVE COLORS 0123456789\nthe quick brown fox",
        cli.terminal_config(),
        Rng::seeded(7),
        Clock::virtual_with_frame_rate(60),
    )
    .unwrap();
    let mut effect = Late {
        inner: fx::effects::build(&cli.effect.unwrap()).unwrap(),
        frame: 0,
        at,
        primed,
    };
    let (path, file) = scratch_file();
    std::io::stdout().flush().unwrap();
    // SAFETY: plain descriptor calls; stdout is restored before anything
    // else writes to it.
    let saved = unsafe { dup(1) };
    assert!(saved >= 0 && unsafe { dup2(file.as_raw_fd(), 1) } == 1);
    let outcome = fx::run::run_effect(&mut effect, &mut e, false);
    unsafe {
        dup2(saved, 1);
        close(saved);
    }
    outcome.unwrap();
    // read back through the descriptor we created, not the name
    let mut file = file;
    let mut bytes = Vec::new();
    file.seek(std::io::SeekFrom::Start(0)).unwrap();
    file.read_to_end(&mut bytes).unwrap();
    std::fs::remove_file(&path).unwrap();
    bytes
}

#[test]
fn a_transform_installed_mid_run_shows_on_a_threaded_run() {
    let in_place = run("1", 5, false);
    assert!(in_place != run("1", 0, false), "the transform shows in place");
    // threaded wherever there are two CPUs to run on
    let threaded = run("2", 5, false);
    assert!(
        threaded == in_place,
        "threaded output differs: {} bytes against {}",
        threaded.len(),
        in_place.len()
    );

    // a transform removed before a threaded run starts stays removed
    let (in_place, threaded) = (run("1", 0, true), run("2", 0, true));
    assert!(
        threaded == in_place,
        "removed transform still shows: {} bytes against {}",
        threaded.len(),
        in_place.len()
    );
}
