//! automata: verify the signature Rule-30 CRT refresh scanline flourish,
//! duration bounds on standard/ultrawide canvases, clean final frame,
//! determinism, performance on 300x90, edge cases, and timing options.

use std::hash::{DefaultHasher, Hash, Hasher};
use std::time::Instant;

use clap::Parser;

use ttfx::cli::Cli;
use ttfx::engine::ctx::Clock;
use ttfx::fx::Engine;
use ttfx::utils::rng::Rng;

const LOGO_PATH: &str = "/usr/share/omarchy/logo.txt";

fn logo_input() -> String {
    std::fs::read_to_string(LOGO_PATH).unwrap_or_else(|_| "OMARCHY\nhello world\n".to_string())
}

struct RunResult {
    frames: usize,
    trace: u64,
    flourish_active_frames: usize,
    engine: Engine,
}

fn run_automata(input: &str, args: &[&str], seed: u64) -> RunResult {
    let seed_str = seed.to_string();
    let mut argv = vec![
        "ttfx",
        "--ignore-terminal-dimensions",
        "--frame-rate",
        "120",
        "--seed",
        &seed_str,
    ];
    argv.extend_from_slice(args);
    let cli = Cli::try_parse_from(&argv).expect("cli parse");
    let config = cli.terminal_config();
    let command = cli.effect.as_ref().expect("effect");
    let mut effect = ttfx::fx::effects::build(command).expect("fx effect");
    let clock = Clock::virtual_with_frame_rate(config.frame_rate);
    let mut e = Engine::new(input, config, Rng::seeded(seed), clock).expect("engine");
    effect.build(&mut e).expect("build");

    let mut frames = 0usize;
    let mut trace = DefaultHasher::new();
    let mut flourish_active_frames = 0usize;

    while effect.next_frame(&mut e) {
        frames += 1;
        assert!(frames < 20_000, "{argv:?}: did not terminate");
        if frames % 5 == 0 {
            e.render_here();
            let mut parts = Vec::new();
            e.renderer().frame_parts(b"", b"", &mut parts);
            for part in &parts {
                part.hash(&mut trace);
            }
        }
        // Track whether any added helper is visible in the late window.
        if frames > 800 && e.added_chars.iter().any(|&slot| e.is_visible(slot)) {
            flourish_active_frames += 1;
        }
    }
    e.render_here();

    // Assert clean last frame: every input char home, visible if in canvas,
    // exact input symbol; every added char hidden; active_is_empty.
    let canvas = e.canvas.clone();
    for &slot in &e.input_chars.clone() {
        let home = e.input_coord(slot);
        assert_eq!(e.coord(slot), home, "{argv:?}: slot {slot} not home");
        let in_canvas = home.column >= canvas.left
            && home.column <= canvas.right
            && home.row >= canvas.bottom
            && home.row <= canvas.top;
        if in_canvas {
            assert!(
                e.is_visible(slot),
                "{argv:?}: in-canvas slot {slot} hidden"
            );
        }
        let info = e.visual_info(e.current_visual(slot));
        assert_eq!(info.sym, e.input_sym(slot), "{argv:?}: wrong symbol");
    }
    for &slot in &e.added_chars.clone() {
        assert!(
            !e.is_visible(slot),
            "{argv:?}: added slot {slot} still visible on last frame"
        );
    }
    assert!(e.active_is_empty(), "{argv:?}: active_is_empty false");

    RunResult {
        frames,
        trace: trace.finish(),
        flourish_active_frames,
        engine: e,
    }
}

#[test]
fn logo_runs_at_standard_and_ultrawide_canvases() {
    let logo = logo_input();
    for (w, h) in [("96", "24"), ("182", "45"), ("370", "48")] {
        let res = run_automata(
            &logo,
            &[
                "--canvas-width",
                w,
                "--canvas-height",
                h,
                "--anchor-canvas",
                "c",
                "--anchor-text",
                "c",
                "automata",
            ],
            7,
        );
        assert!(
            (960..=3000).contains(&res.frames),
            "{w}x{h}: {} frames outside 960..=3000",
            res.frames
        );
        assert!(
            res.flourish_active_frames > 0,
            "{w}x{h}: expected live scanline flourish activity in late frames"
        );
        eprintln!(
            "automata logo {w}x{h}: {} frames ({} active late flourish frames)",
            res.frames, res.flourish_active_frames
        );
    }
}

#[test]
fn big_300x90_is_fast() {
    let logo = logo_input();
    let start = Instant::now();
    let res = run_automata(
        &logo,
        &[
            "--canvas-width",
            "300",
            "--canvas-height",
            "90",
            "--anchor-canvas",
            "c",
            "--anchor-text",
            "c",
            "automata",
        ],
        7,
    );
    let elapsed = start.elapsed();
    assert!(
        elapsed.as_secs_f64() < 1.0,
        "300x90 took {elapsed:?} ({} frames)",
        res.frames
    );
}

#[test]
fn deterministic_with_seed_7() {
    let logo = logo_input();
    let args = [
        "--canvas-width",
        "182",
        "--canvas-height",
        "45",
        "--anchor-canvas",
        "c",
        "--anchor-text",
        "c",
        "automata",
    ];
    let a = run_automata(&logo, &args, 7);
    let b = run_automata(&logo, &args, 7);
    assert_eq!(a.frames, b.frames);
    assert_eq!(a.trace, b.trace, "same seed produced different trace");
}

#[test]
fn edge_cases_and_existing_color_handling() {
    let long_500 = "A".repeat(500);
    let unicode = "日本語🎉 hello\nworld\n";
    let ansi_bg_space =
        "\x1b[38;2;255;80;40mRED\x1b[48;2;10;60;120m   \x1b[0m\x1b[1;32mBOLD\x1b[0m\n";

    // Tiny canvases
    for (w, h) in [("1", "1"), ("10", "3")] {
        run_automata(
            "OMARCHY\nhi\n",
            &[
                "--canvas-width",
                w,
                "--canvas-height",
                h,
                "automata",
                "--generation-time",
                "1",
                "--dissolve-duration",
                "30",
                "--final-hold-time",
                "40",
            ],
            7,
        );
    }

    // 500-char line & unicode
    for input in [long_500.as_str(), unicode] {
        run_automata(
            input,
            &[
                "--canvas-width",
                "96",
                "--canvas-height",
                "24",
                "automata",
                "--generation-time",
                "1",
                "--dissolve-duration",
                "30",
                "--final-hold-time",
                "40",
            ],
            7,
        );
    }

    // Existing color handling: dynamic and always (including bg-colored spaces)
    for mode in ["dynamic", "always"] {
        let res = run_automata(
            ansi_bg_space,
            &[
                "--canvas-width",
                "60",
                "--canvas-height",
                "12",
                "--existing-color-handling",
                mode,
                "automata",
                "--generation-time",
                "1",
                "--dissolve-duration",
                "30",
                "--final-hold-time",
                "50",
            ],
            7,
        );
        let e = &res.engine;
        for &slot in &e.input_chars {
            let info = e.visual_info(e.current_visual(slot));
            if mode == "dynamic" || e.uses_preexisting_colors(slot) {
                assert_eq!(
                    info.fg,
                    e.input_fg(slot),
                    "mode {mode}: slot {slot} fg mismatch"
                );
                assert_eq!(
                    info.bg,
                    e.input_bg(slot),
                    "mode {mode}: slot {slot} bg mismatch"
                );
            }
        }
    }
}

#[test]
fn timing_options_change_run_length() {
    let input = "OMARCHY\nautomata\n";
    let base = run_automata(
        input,
        &["--canvas-width", "80", "--canvas-height", "20", "automata"],
        7,
    )
    .frames;

    for (opt, val) in [
        ("--generation-time", "4"),
        ("--hold-time", "30"),
        ("--dissolve-duration", "120"),
        ("--final-hold-time", "80"),
    ] {
        let frames = run_automata(
            input,
            &[
                "--canvas-width",
                "80",
                "--canvas-height",
                "20",
                "automata",
                opt,
                val,
            ],
            7,
        )
        .frames;
        assert_ne!(frames, base, "{opt} {val} did not change run length {base}");
    }
}
