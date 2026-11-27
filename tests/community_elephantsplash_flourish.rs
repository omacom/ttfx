//! Integration tests for elephantsplash's signature dripping-puddle flourish,
//! duration bounds, determinism, performance, and edge cases.

use std::time::Instant;

use clap::Parser;
use ttfx::cli::Cli;
use ttfx::engine::animation::ExistingColorHandling;
use ttfx::engine::ctx::Clock;
use ttfx::fx::Engine;
use ttfx::utils::rng::Rng;

fn run_cli(input: &str, args: &[&str], seed: u64) -> (usize, Engine) {
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
        assert!(frames < 20_000, "{argv:?}: did not finish");
    }
    assert_clean_end(&e, &argv);
    (frames, e)
}

fn assert_clean_end(e: &Engine, argv: &[&str]) {
    let dynamic = e.existing_color_handling() == ExistingColorHandling::Dynamic;
    for &slot in &e.input_chars.clone() {
        let ic = e.input_coord(slot);
        assert_eq!(e.coord(slot), ic, "{argv:?}: input char off its cell");
        if e.canvas.coord_is_in_canvas(ic) {
            assert!(e.is_visible(slot), "{argv:?}: in-canvas input char hidden");
        }
        let info = e.visual_info(e.current_visual(slot));
        assert_eq!(info.sym, e.input_sym(slot), "{argv:?}: wrong symbol");
        if dynamic {
            assert_eq!(info.fg, e.input_fg(slot), "{argv:?}: dynamic fg mismatch");
            assert_eq!(info.bg, e.input_bg(slot), "{argv:?}: dynamic bg mismatch");
        }
    }
    for &slot in &e.added_chars.clone() {
        assert!(!e.is_visible(slot), "{argv:?}: added char still visible");
    }
    assert!(e.active_is_empty(), "{argv:?}: active set not empty");
}

fn omarchy_logo() -> String {
    std::fs::read_to_string("/usr/share/omarchy/logo.txt")
        .unwrap_or_else(|_| "OMARCHY OMARCHY OMARCHY\n".repeat(8))
}

#[test]
fn logo_runs_in_bounds_and_flourish_is_alive() {
    let logo = omarchy_logo();
    for (w, h) in [(96, 24), (182, 45), (370, 48)] {
        let w_s = w.to_string();
        let h_s = h.to_string();
        let args = [
            "--canvas-width",
            &w_s,
            "--canvas-height",
            &h_s,
            "--anchor-canvas",
            "c",
            "--anchor-text",
            "c",
            "elephantsplash",
        ];
        let (frames, _) = run_cli(&logo, &args, 7);
        eprintln!("elephantsplash logo {w}x{h}: {frames} frames");
        assert!(
            (960..=3000).contains(&frames),
            "logo at {w}x{h} took {frames} frames (expected 960..=3000)"
        );
    }

    // Verify the flourish at 182x45 is visibly alive (not a static hold) near the end.
    let argv = [
        "ttfx",
        "--seed",
        "7",
        "--frame-rate",
        "120",
        "--canvas-width",
        "182",
        "--canvas-height",
        "45",
        "--anchor-canvas",
        "c",
        "--anchor-text",
        "c",
        "elephantsplash",
    ];
    let cli = Cli::try_parse_from(argv).expect("cli parse");
    let config = cli.terminal_config();
    let command = cli.effect.as_ref().expect("effect");
    let mut effect = ttfx::fx::effects::build(command).expect("fx effect");
    let mut e = Engine::new(
        &logo,
        config,
        Rng::seeded(7),
        Clock::virtual_with_frame_rate(120),
    )
    .expect("engine");
    effect.build(&mut e).expect("build");

    let mut total = 0usize;
    let mut flourish_changes = 0usize;
    let mut prev_added_vis: Vec<(bool, u32)> = Vec::new();
    while effect.next_frame(&mut e) {
        total += 1;
        // During the last ~400 frames (the hold/flourish window), added chars should animate.
        if total > 1100 {
            let cur: Vec<(bool, u32)> = e
                .added_chars
                .iter()
                .map(|&s| (e.is_visible(s), e.current_visual(s).0))
                .collect();
            if !prev_added_vis.is_empty() && cur != prev_added_vis && cur.iter().any(|&(v, _)| v) {
                flourish_changes += 1;
            }
            prev_added_vis = cur;
        }
    }
    assert!(
        flourish_changes >= 50,
        "expected lively flourish animation in final hold, got {flourish_changes} changes"
    );
    assert_clean_end(&e, &argv);
}

#[test]
fn large_canvas_300x90_is_fast() {
    let logo = omarchy_logo();
    let args = [
        "--canvas-width",
        "300",
        "--canvas-height",
        "90",
        "--anchor-canvas",
        "c",
        "--anchor-text",
        "c",
        "elephantsplash",
    ];
    let start = Instant::now();
    let (frames, _) = run_cli(&logo, &args, 7);
    let elapsed = start.elapsed();
    assert!(
        (960..=3000).contains(&frames),
        "300x90 took {frames} frames"
    );
    assert!(
        elapsed.as_secs_f64() < 1.0,
        "300x90 took {:.3}s (expected < 1.0s)",
        elapsed.as_secs_f64()
    );
}

#[test]
fn deterministic_with_seed_7() {
    let logo = omarchy_logo();
    let capture = || {
        let argv = [
            "ttfx",
            "--seed",
            "7",
            "--frame-rate",
            "120",
            "--canvas-width",
            "96",
            "--canvas-height",
            "24",
            "--anchor-canvas",
            "c",
            "--anchor-text",
            "c",
            "elephantsplash",
        ];
        let cli = Cli::try_parse_from(argv).expect("cli parse");
        let config = cli.terminal_config();
        let command = cli.effect.as_ref().expect("effect");
        let mut effect = ttfx::fx::effects::build(command).expect("fx effect");
        let mut e = Engine::new(
            &logo,
            config,
            Rng::seeded(7),
            Clock::virtual_with_frame_rate(120),
        )
        .expect("engine");
        effect.build(&mut e).expect("build");
        let mut trace = Vec::new();
        while effect.next_frame(&mut e) {
            trace.push((
                e.ch.coord.clone(),
                e.ch.visual.iter().map(|v| v.0).collect::<Vec<_>>(),
            ));
        }
        trace
    };
    assert_eq!(capture(), capture());
}

#[test]
fn edge_cases_and_existing_colors() {
    let long = "x".repeat(500);
    let unicode = "日本語🎉\nOMARCHY";
    let ansi = "\x1b[31mred\x1b[0m\x1b[44m   \x1b[0m\x1b[1;32mgreen\x1b[0m";

    let cases: Vec<(&str, &str, &str)> = vec![
        ("a", "1", "1"),
        ("OMARCHY", "10", "3"),
        (&long, "120", "24"),
        (unicode, "60", "20"),
        (ansi, "60", "20"),
    ];
    for (input, w, h) in cases {
        run_cli(
            input,
            &["--canvas-width", w, "--canvas-height", h, "elephantsplash"],
            7,
        );
        run_cli(
            input,
            &[
                "--canvas-width",
                w,
                "--canvas-height",
                h,
                "elephantsplash",
                "--final-hold-frames",
                "0",
            ],
            7,
        );
    }

    for handling in ["dynamic", "always"] {
        run_cli(
            ansi,
            &[
                "--canvas-width",
                "80",
                "--canvas-height",
                "24",
                "--existing-color-handling",
                handling,
                "elephantsplash",
            ],
            7,
        );
    }
}

#[test]
fn timing_options_change_run_length() {
    let input = "OMARCHY\nhello world";
    let base_args = [
        "--canvas-width",
        "96",
        "--canvas-height",
        "24",
        "--anchor-canvas",
        "c",
        "--anchor-text",
        "c",
        "elephantsplash",
    ];
    let (base, _) = run_cli(input, &base_args, 7);
    for extra in [
        &["--walk-pose-frames", "3"][..],
        &["--horizontal-step-frames", "2"][..],
        &["--final-gradient-frames", "9"][..],
        &["--final-hold-frames", "60"][..],
        &["--movement-speed", "0.1"][..],
    ] {
        let mut args = base_args.to_vec();
        args.extend_from_slice(extra);
        let (frames, _) = run_cli(input, &args, 7);
        assert_ne!(frames, base, "{extra:?} did not change run length");
    }
}
