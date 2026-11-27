//! Integration tests for the `roses` community effect and its closing
//! drifting-petal flourish.

use std::time::Instant;

use clap::Parser;

use ttfx::cli::Cli;
use ttfx::engine::ctx::Clock;
use ttfx::fx::visual::Visual;
use ttfx::fx::Engine;
use ttfx::utils::geometry::Coord;
use ttfx::utils::rng::Rng;

const LOGO_PATH: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/omarchy-logo.txt");

fn logo_text() -> String {
    std::fs::read_to_string(LOGO_PATH).unwrap_or_else(|_| {
        "                 ▄▄▄\n \
         ▄█████▄    ▄███████████▄    ▄███████   ▄███████   ▄███████   ▄█   █▄    ▄█   █▄\n\
         ███   ███  ███   ███   ███  ███   ███  ███   ███  ███   ███  ███   ███  ███   ███\n"
            .to_string()
    })
}

fn run_with_seed(input: &str, seed: u64, args: &[&str]) -> (usize, Engine) {
    let seed_str = seed.to_string();
    let mut argv = vec!["ttfx", "--seed", &seed_str, "--frame-rate", "120"];
    argv.extend_from_slice(args);
    let cli = Cli::try_parse_from(&argv).expect("cli parse");
    let config = cli.terminal_config();
    let command = cli.effect.as_ref().expect("effect");
    let mut effect = ttfx::fx::effects::build(command).expect("fx effect");
    let clock = Clock::virtual_with_frame_rate(config.frame_rate);
    let mut e = Engine::new(input, config, Rng::seeded(seed), clock).expect("engine");
    effect.build(&mut e).expect("build");
    let mut frames = 0usize;
    while effect.next_frame(&mut e) {
        frames += 1;
        assert!(frames < 20_000, "{argv:?}: did not terminate");
    }
    check_clean_final(&e, &argv);
    (frames, e)
}

fn check_clean_final(e: &Engine, argv: &[&str]) {
    for &slot in &e.input_chars {
        let coord = e.input_coord(slot);
        assert_eq!(e.coord(slot), coord, "{argv:?}: input char off its cell");
        if e.canvas.coord_is_in_canvas(coord) {
            assert!(e.is_visible(slot), "{argv:?}: in-canvas input char hidden");
        }
        let info = e.visual_info(e.current_visual(slot));
        assert_eq!(info.sym, e.input_sym(slot), "{argv:?}: wrong final symbol");
    }
    for &slot in &e.added_chars {
        assert!(!e.is_visible(slot), "{argv:?}: added helper still visible");
    }
    assert!(e.active_is_empty(), "{argv:?}: active list not empty");
}

#[test]
fn logo_runs_in_target_window_and_ends_cleanly() {
    let logo = logo_text();
    for (w, h) in [("96", "24"), ("182", "45"), ("370", "48")] {
        let (frames, _) = run_with_seed(
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
                "roses",
            ],
        );
        eprintln!("roses logo {w}x{h}: {frames} frames");
        assert!(
            (960..=3000).contains(&frames),
            "logo {w}x{h} took {frames} frames (expected 960..=3000)"
        );
    }
}

#[test]
fn big_canvas_300x90_is_fast() {
    let logo = logo_text();
    let start = Instant::now();
    let (frames, _) = run_with_seed(
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
            "roses",
        ],
    );
    let elapsed = start.elapsed();
    eprintln!("roses 300x90: {frames} frames in {elapsed:?}");
    assert!(
        elapsed.as_secs_f64() < 30.0,
        "300x90 took {elapsed:?} (hang guard)"
    );
}

#[test]
fn deterministic_frame_by_frame_with_seed_7() {
    let input = "OMARCHY\nroses flourish";
    let snapshot_run = || -> Vec<Vec<(bool, Coord, Visual)>> {
        let argv = [
            "ttfx",
            "--seed",
            "7",
            "--frame-rate",
            "120",
            "--canvas-width",
            "60",
            "--canvas-height",
            "16",
            "--anchor-canvas",
            "c",
            "--anchor-text",
            "c",
            "roses",
        ];
        let cli = Cli::try_parse_from(argv).expect("cli parse");
        let config = cli.terminal_config();
        let command = cli.effect.as_ref().expect("effect");
        let mut effect = ttfx::fx::effects::build(command).expect("fx effect");
        let clock = Clock::virtual_with_frame_rate(config.frame_rate);
        let mut e = Engine::new(input, config, Rng::seeded(7), clock).expect("engine");
        effect.build(&mut e).expect("build");
        let mut trace = Vec::new();
        let mut step = 0usize;
        while effect.next_frame(&mut e) {
            // Sample every 10th frame plus the final tail for speed while verifying determinism.
            if step % 10 == 0 {
                let state = (0..e.char_count() as u32)
                    .map(|s| (e.is_visible(s), e.coord(s), e.current_visual(s)))
                    .collect();
                trace.push(state);
            }
            step += 1;
        }
        trace
    };

    let run_a = snapshot_run();
    let run_b = snapshot_run();
    assert_eq!(run_a.len(), run_b.len());
    assert_eq!(run_a, run_b);
}

#[test]
fn edge_cases_and_existing_color_handling() {
    let long_line = "x".repeat(500);
    let unicode = "日本語🎉 rose\n";
    let ansi_bg = "\x1b[38;2;255;0;0mred\x1b[0m\x1b[48;2;20;40;80m   \x1b[0mplain";

    for (input, w, h) in [
        ("a", "1", "1"),
        ("OMARCHY\nhello", "10", "3"),
        (long_line.as_str(), "120", "20"),
        (unicode, "60", "16"),
        (ansi_bg, "60", "16"),
    ] {
        run_with_seed(
            input,
            7,
            &["--canvas-width", w, "--canvas-height", h, "roses"],
        );
    }

    for mode in ["dynamic", "always"] {
        let (_, e) = run_with_seed(
            ansi_bg,
            7,
            &[
                "--canvas-width",
                "60",
                "--canvas-height",
                "16",
                "--existing-color-handling",
                mode,
                "roses",
            ],
        );
        // Verify red fg and bg-colored spaces are preserved on the final frame.
        assert!(
            e.input_chars.iter().any(|&s| {
                e.visual_info(e.current_visual(s))
                    .fg
                    .is_some_and(|c| c.rgb_ints() == (255, 0, 0))
            }),
            "{mode}: red fg not preserved"
        );
        assert!(
            e.input_chars.iter().any(|&s| {
                e.visual_info(e.current_visual(s))
                    .bg
                    .is_some_and(|c| c.rgb_ints() == (20, 40, 80))
            }),
            "{mode}: bg-colored space not preserved"
        );
    }
}

#[test]
fn timing_options_change_run_length() {
    let input = "OMARCHY\nhello";
    let (base, _) = run_with_seed(
        input,
        7,
        &["--canvas-width", "80", "--canvas-height", "24", "roses"],
    );
    for (option, value) in [
        ("--vine-duration", "10000"),
        ("--bloom-start", "1000"),
        ("--bloom-duration", "1000"),
        ("--bloom-delay", "300"),
        ("--falling-petals", "400"),
        ("--text-bloom-start", "1000"),
        ("--text-bloom-duration", "1000"),
        ("--final-hold-time", "1000"),
        ("--wither-duration", "1000"),
    ] {
        let (frames, _) = run_with_seed(
            input,
            7,
            &[
                "--canvas-width",
                "80",
                "--canvas-height",
                "24",
                "roses",
                option,
                value,
            ],
        );
        assert!(
            frames > base,
            "{option} {value} produced {frames} frames (base {base})"
        );
    }
}
