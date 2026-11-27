//! Integration tests for reverselife's glider-bounce flourish, duration bounds,
//! performance, determinism, edge cases, and CLI timing options.

use std::time::Instant;

use clap::Parser;

use ttfx::cli::Cli;
use ttfx::engine::ctx::Clock;
use ttfx::fx::{Engine, Visual};
use ttfx::utils::geometry::Coord;
use ttfx::utils::rng::Rng;

const OMARCHY_LOGO_PATH: &str = "/usr/share/omarchy/logo.txt";

fn logo_text() -> String {
    std::fs::read_to_string(OMARCHY_LOGO_PATH)
        .unwrap_or_else(|_| "OMARCHY\nhello world\n".to_string())
}

fn run_reverselife(
    input: &str,
    args: &[&str],
) -> (usize, Engine, Vec<(bool, Coord, Visual)>, bool) {
    let mut argv = vec!["ttfx", "--seed", "7", "--frame-rate", "120"];
    argv.extend_from_slice(args);
    let cli = Cli::try_parse_from(&argv).expect("cli parse");
    let config = cli.terminal_config();
    let command = cli.effect.as_ref().expect("effect");
    let mut effect = ttfx::fx::effects::build(command).expect("fx effect");
    let clock = Clock::virtual_with_frame_rate(config.frame_rate);
    let mut e = Engine::new(input, config, Rng::seeded(7), clock).expect("engine");
    effect.build(&mut e).expect("build");

    let mut frames = 0usize;
    let mut saw_glider_or_flicker_in_final = false;
    while effect.next_frame(&mut e) {
        frames += 1;
        // During the final hold (~last 300 frames), check that gliders or flickers are alive.
        if frames > 820 && frames < 1100 {
            if e.added_chars.iter().any(|&s| e.is_visible(s))
                || e.input_chars.iter().any(|&s| !e.is_visible(s))
            {
                saw_glider_or_flicker_in_final = true;
            }
        }
        assert!(frames < 20_000, "{argv:?}: did not terminate");
    }

    // Verify clean last frame.
    let canvas = e.canvas.clone();
    for &slot in &e.input_chars.clone() {
        let coord = e.coord(slot);
        let in_canvas = coord.column >= canvas.left
            && coord.column <= canvas.right
            && coord.row >= canvas.bottom
            && coord.row <= canvas.top;
        if in_canvas {
            assert!(e.is_visible(slot), "{argv:?}: input char hidden at end");
        }
        assert_eq!(coord, e.input_coord(slot), "{argv:?}: input char moved");
        let info = e.visual_info(e.current_visual(slot));
        assert_eq!(info.sym, e.input_sym(slot), "{argv:?}: wrong final symbol");
    }
    for &slot in &e.added_chars.clone() {
        assert!(!e.is_visible(slot), "{argv:?}: helper still visible at end");
    }
    assert!(e.active_is_empty(), "{argv:?}: active set not empty");

    let state = (0..e.char_count() as u32)
        .map(|s| (e.is_visible(s), e.coord(s), e.current_visual(s)))
        .collect();
    (frames, e, state, saw_glider_or_flicker_in_final)
}

#[test]
fn logo_runs_in_duration_bounds_and_flourish_is_alive() {
    let logo = logo_text();
    for (w, h) in [("96", "24"), ("182", "45"), ("370", "48")] {
        let args = [
            "--canvas-width",
            w,
            "--canvas-height",
            h,
            "--anchor-canvas",
            "c",
            "--anchor-text",
            "c",
            "reverselife",
        ];
        let (frames, _, _, alive) = run_reverselife(&logo, &args);
        assert!(
            (960..=3000).contains(&frames),
            "{w}x{h}: expected 960..=3000 frames, got {frames}"
        );
        assert!(
            alive,
            "{w}x{h}: expected gliders/flickers to be visibly alive during the final hold"
        );
    }
}

#[test]
fn large_canvas_300x90_is_fast() {
    let logo = logo_text();
    let t0 = Instant::now();
    let (frames, _, _, _) = run_reverselife(
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
            "reverselife",
        ],
    );
    let elapsed = t0.elapsed();
    assert!((960..=3000).contains(&frames));
    assert!(
        elapsed.as_secs_f64() < 1.0,
        "300x90 took {:.3}s (must be < 1.0s)",
        elapsed.as_secs_f64()
    );
}

#[test]
fn deterministic_with_seed_7() {
    let logo = logo_text();
    let args = [
        "--canvas-width",
        "120",
        "--canvas-height",
        "30",
        "--anchor-canvas",
        "c",
        "--anchor-text",
        "c",
        "reverselife",
    ];
    let (fa, _, sa, _) = run_reverselife(&logo, &args);
    let (fb, _, sb, _) = run_reverselife(&logo, &args);
    assert_eq!(fa, fb);
    assert_eq!(sa, sb);
}

#[test]
fn edge_cases_and_existing_color_handling() {
    let long_line = "x".repeat(500);
    let unicode = "日本語🎉テスト\nOMARCHY ✦";
    let ansi = "\x1b[38;2;255;80;80mRED\x1b[0m \x1b[48;2;0;128;255m   \x1b[0m \x1b[38;2;80;255;120mGRN\x1b[0m";

    for (input, w, h) in [
        ("a", "1", "1"),
        ("OMARCHY\nhi", "10", "3"),
        (long_line.as_str(), "96", "24"),
        (unicode, "96", "24"),
        (ansi, "96", "24"),
    ] {
        let args = [
            "--canvas-width",
            w,
            "--canvas-height",
            h,
            "reverselife",
            "--simulation-steps",
            "15",
            "--final-hold-time",
            "90",
        ];
        run_reverselife(input, &args);
    }

    for mode in ["dynamic", "always"] {
        let args = [
            "--canvas-width",
            "96",
            "--canvas-height",
            "24",
            "--existing-color-handling",
            mode,
            "reverselife",
            "--simulation-steps",
            "15",
            "--final-hold-time",
            "90",
        ];
        let (_, e, _, _) = run_reverselife(ansi, &args);
        let has_red = e.input_chars.iter().any(|&s| {
            e.visual_info(e.current_visual(s))
                .fg
                .is_some_and(|c| c.rgb_ints() == (255, 80, 80))
        });
        let has_bg_space = e.input_chars.iter().any(|&s| {
            e.visual_info(e.current_visual(s))
                .bg
                .is_some_and(|c| c.rgb_ints() == (0, 128, 255))
        });
        assert!(has_red, "{mode}: red fg lost on final frame");
        assert!(has_bg_space, "{mode}: bg-colored space lost on final frame");
    }
}

#[test]
fn timing_options_change_run_length() {
    let input = "OMARCHY\nhello";
    let base_args = ["--canvas-width", "60", "--canvas-height", "16", "reverselife"];
    let (base, _, _, _) = run_reverselife(input, &base_args);
    for (opt, val) in [
        ("--simulation-steps", "100"),
        ("--generation-time", "12"),
        ("--chaos-hold-time", "200"),
        ("--resolve-duration", "300"),
        ("--final-hold-time", "500"),
    ] {
        let args = [
            "--canvas-width",
            "60",
            "--canvas-height",
            "16",
            "reverselife",
            opt,
            val,
        ];
        let (frames, _, _, _) = run_reverselife(input, &args);
        assert!(frames > base, "{opt} {val} did not lengthen run ({frames} <= {base})");
    }
    // Also verify --final-hold-time 0 ends cleanly and shortens run.
    let (zero_hold, _, _, _) = run_reverselife(
        input,
        &[
            "--canvas-width",
            "60",
            "--canvas-height",
            "16",
            "reverselife",
            "--final-hold-time",
            "0",
        ],
    );
    assert!(zero_hold < base);
}
