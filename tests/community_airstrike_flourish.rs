//! Integration tests for airstrike's signature victory flyby flourish,
//! duration budgets, determinism, performance, and edge cases.

use std::hash::{DefaultHasher, Hash, Hasher};
use std::time::Instant;

use clap::Parser;

use ttfx::cli::Cli;
use ttfx::engine::ctx::Clock;
use ttfx::fx::Engine;
use ttfx::utils::rng::Rng;

const LOGO_PATH: &str = "/usr/share/omarchy/logo.txt";

fn logo_text() -> String {
    std::fs::read_to_string(LOGO_PATH)
        .unwrap_or_else(|_| "OMARCHY\nhello world\n".to_string())
}

struct RunResult {
    frames: usize,
    trace: u64,
    engine: Engine,
}

fn run_airstrike(input: &str, seed: u64, args: &[&str]) -> RunResult {
    let seed_str = seed.to_string();
    let mut argv = vec![
        "ttfx",
        "--ignore-terminal-dimensions",
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

    let mut frames = 0;
    let mut trace = DefaultHasher::new();
    while effect.next_frame(&mut e) {
        frames += 1;
        assert!(frames < 20_000, "{argv:?}: did not terminate");
        if frames % 13 == 0 {
            e.render_here();
            let mut parts = Vec::new();
            e.renderer().frame_parts(b"", b"", &mut parts);
            for part in &parts {
                part.hash(&mut trace);
            }
        }
    }
    e.render_here();

    // Clean last frame checks
    for &slot in &e.input_chars.clone() {
        assert_eq!(e.coord(slot), e.input_coord(slot), "{argv:?}: input slot off home");
        assert!(e.is_visible(slot), "{argv:?}: input slot hidden");
        let info = e.visual_info(e.current_visual(slot));
        assert_eq!(info.sym, e.input_sym(slot), "{argv:?}: input slot wrong symbol");
    }
    for &slot in &e.added_chars.clone() {
        assert!(!e.is_visible(slot), "{argv:?}: added slot still visible");
    }
    assert!(e.active_is_empty(), "{argv:?}: active list not empty");

    RunResult {
        frames,
        trace: trace.finish(),
        engine: e,
    }
}

#[test]
fn logo_duration_and_clean_settle_across_canvases() {
    let logo = logo_text();
    for (w, h) in [("96", "24"), ("182", "45"), ("370", "48")] {
        let res = run_airstrike(
            &logo,
            7,
            &[
                "--canvas-width",
                w,
                "--canvas-height",
                h,
                "--anchor-canvas",
                "c",
                "--anchor-text",
                "c",
                "airstrike",
            ],
        );
        eprintln!("airstrike logo {w}x{h}: {} frames", res.frames);
        assert!(
            (960..=3000).contains(&res.frames),
            "canvas {w}x{h}: {} frames outside 960..=3000",
            res.frames
        );
    }
}

#[test]
fn large_canvas_300x90_is_fast() {
    let logo = logo_text();
    let start = Instant::now();
    let res = run_airstrike(
        &logo,
        7,
        &[
            "--canvas-width",
            "300",
            "--canvas-height",
            "90",
            "--anchor-canvas",
            "c",
            "--anchor-text",
            "c",
            "airstrike",
        ],
    );
    let elapsed = start.elapsed();
    assert!(res.frames > 0);
    assert!(
        elapsed.as_secs_f64() < 1.0,
        "300x90 took {:.3}s (expected < 1s)",
        elapsed.as_secs_f64()
    );
}

#[test]
fn deterministic_with_seed_7() {
    let logo = logo_text();
    let args = [
        "--canvas-width",
        "182",
        "--canvas-height",
        "45",
        "--anchor-canvas",
        "c",
        "--anchor-text",
        "c",
        "airstrike",
    ];
    let a = run_airstrike(&logo, 7, &args);
    let b = run_airstrike(&logo, 7, &args);
    assert_eq!(a.frames, b.frames);
    assert_eq!(a.trace, b.trace);

    let c = run_airstrike(&logo, 8, &args);
    assert_ne!(a.trace, c.trace, "different seed should change output");
}

#[test]
fn edge_cases_and_existing_colors() {
    let long_line = "X".repeat(500);
    let unicode = "日本語🎉 OMARCHY テスト\n";
    let ansi = "\x1b[38;2;255;80;0mRED\x1b[0m\x1b[48;2;10;40;80m   \x1b[0m\x1b[1;32mBOLD\x1b[0m\n";

    for (w, h) in [("1", "1"), ("10", "3"), ("120", "30")] {
        for input in [long_line.as_str(), unicode, ansi] {
            let _ = run_airstrike(
                input,
                7,
                &[
                    "--canvas-width",
                    w,
                    "--canvas-height",
                    h,
                    "airstrike",
                    "--launch-delay",
                    "10",
                    "--flight-speed",
                    "2.0",
                ],
            );
        }
    }

    for mode in ["dynamic", "always"] {
        let res = run_airstrike(
            ansi,
            7,
            &[
                "--canvas-width",
                "80",
                "--canvas-height",
                "20",
                "--existing-color-handling",
                mode,
                "airstrike",
                "--launch-delay",
                "10",
                "--flight-speed",
                "2.0",
            ],
        );
        let e = &res.engine;
        for &slot in &e.input_chars {
            if e.uses_preexisting_colors(slot) || mode == "dynamic" {
                let info = e.visual_info(e.current_visual(slot));
                assert_eq!(info.fg, e.input_fg(slot), "mode {mode}: fg mismatch on slot {slot}");
                assert_eq!(info.bg, e.input_bg(slot), "mode {mode}: bg mismatch on slot {slot}");
            }
        }
    }
}

#[test]
fn timing_options_change_run_length() {
    let input = "OMARCHY\nhello world\n";
    let base = run_airstrike(input, 7, &["airstrike"]).frames;
    for (opt, val) in [
        ("--plane-count", "9"),
        ("--flight-speed", "0.25"),
        ("--launch-delay", "110"),
        ("--debris-duration", "160"),
        ("--reassembly-duration", "220"),
        ("--final-hold-time", "80"),
        ("--final-hold-time", "0"),
    ] {
        let frames = run_airstrike(input, 7, &["airstrike", opt, val]).frames;
        assert_ne!(frames, base, "{opt} {val} did not change run length ({base})");
    }
}
