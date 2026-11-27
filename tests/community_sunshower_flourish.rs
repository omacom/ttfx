//! Integration tests for sunshower's signature golden lighthouse-rays and
//! last golden raindrops flourish, duration bounds, performance, determinism,
//! edge cases, and timing options.

use std::time::Instant;

use clap::Parser;

use ttfx::cli::Cli;
use ttfx::engine::ctx::Clock;
use ttfx::fx::Engine;
use ttfx::utils::rng::Rng;

const LOGO: &str = include_str!("/usr/share/omarchy/logo.txt");

fn run_checked(input: &str, args: &[&str]) -> (usize, Vec<(i64, i64, bool, u32)>) {
    let mut argv = vec!["ttfx", "--seed", "7"];
    argv.extend_from_slice(args);
    let cli = Cli::try_parse_from(&argv).expect("cli parse");
    let config = cli.terminal_config();
    let command = cli.effect.as_ref().expect("effect");
    let mut effect = ttfx::fx::effects::build(command).expect("fx effect");
    let clock = Clock::virtual_with_frame_rate(config.frame_rate);
    let mut e = Engine::new(input, config, Rng::seeded(7), clock).expect("engine");
    effect.build(&mut e).expect("build");
    let mut frames = 0;
    while effect.next_frame(&mut e) {
        frames += 1;
        assert!(frames < 20_000, "{argv:?}: did not terminate");
    }
    for &slot in &e.input_chars.clone() {
        assert_eq!(e.coord(slot), e.input_coord(slot), "{argv:?}: input char off coord");
        let info = e.visual_info(e.current_visual(slot));
        assert_eq!(info.sym, e.input_sym(slot), "{argv:?}: input char wrong sym");
        if e.canvas.coord_is_in_canvas(e.input_coord(slot)) {
            assert!(e.is_visible(slot), "{argv:?}: in-canvas input char hidden");
        }
    }
    for &slot in &e.added_chars.clone() {
        assert!(!e.is_visible(slot), "{argv:?}: added char {slot} still visible");
    }
    assert!(e.active_is_empty(), "{argv:?}: engine still has active characters");

    let snapshot = (0..e.char_count() as u32)
        .map(|s| {
            let c = e.coord(s);
            (c.column, c.row, e.is_visible(s), e.current_visual(s).0)
        })
        .collect();
    (frames, snapshot)
}

#[test]
fn logo_duration_and_clean_end_across_canvases() {
    for [w, h] in [["96", "24"], ["182", "45"], ["370", "48"]] {
        let args = [
            "--canvas-width",
            w,
            "--canvas-height",
            h,
            "--anchor-canvas",
            "c",
            "--anchor-text",
            "c",
            "sunshower",
        ];
        let (frames, _) = run_checked(LOGO, &args);
        assert!(
            (960..=3000).contains(&frames),
            "logo on {w}x{h} ran {frames} frames (expected 960..=3000)"
        );
    }
}

#[test]
fn flourish_is_visibly_alive_during_final_hold() {
    let args = [
        "--canvas-width",
        "182",
        "--canvas-height",
        "45",
        "--anchor-canvas",
        "c",
        "--anchor-text",
        "c",
        "sunshower",
    ];
    let mut argv = vec!["ttfx", "--seed", "7"];
    argv.extend_from_slice(&args);
    let cli = Cli::try_parse_from(&argv).expect("cli parse");
    let config = cli.terminal_config();
    let command = cli.effect.as_ref().expect("effect");
    let mut effect = ttfx::fx::effects::build(command).expect("fx effect");
    let clock = Clock::virtual_with_frame_rate(config.frame_rate);
    let mut e = Engine::new(LOGO, config, Rng::seeded(7), clock).expect("engine");
    effect.build(&mut e).expect("build");

    // Advance to the start of the flourish (clear_end = 1110)
    for _ in 0..1110 {
        assert!(effect.next_frame(&mut e));
    }
    let mut flourish_visible_frames = 0usize;
    let mut prev_vis_count = 0usize;
    let mut changed_frames = 0usize;
    for _ in 0..380 {
        assert!(effect.next_frame(&mut e));
        let vis_added = e.added_chars.iter().filter(|&&s| e.is_visible(s)).count();
        if vis_added > 0 {
            flourish_visible_frames += 1;
        }
        if vis_added != prev_vis_count {
            changed_frames += 1;
            prev_vis_count = vis_added;
        }
    }
    assert!(
        flourish_visible_frames > 250,
        "flourish should stay visibly alive (only {flourish_visible_frames} frames had visible rays/drops)"
    );
    assert!(
        changed_frames > 40,
        "flourish should animate continuously, not hold static ({changed_frames} changes)"
    );
    // Final frame ends completely clean
    assert!(effect.next_frame(&mut e));
    assert!(!effect.next_frame(&mut e));
    for &slot in &e.added_chars {
        assert!(!e.is_visible(slot));
    }
    assert!(e.active_is_empty());
}

#[test]
fn large_canvas_300x90_computes_fast() {
    let args = [
        "--canvas-width",
        "300",
        "--canvas-height",
        "90",
        "--anchor-canvas",
        "c",
        "--anchor-text",
        "c",
        "sunshower",
    ];
    let start = Instant::now();
    let (frames, _) = run_checked(LOGO, &args);
    let elapsed = start.elapsed();
    assert!((960..=3000).contains(&frames));
    assert!(
        elapsed.as_secs_f64() < 1.0,
        "300x90 took {:.3}s (must be well under 1s)",
        elapsed.as_secs_f64()
    );
}

#[test]
fn deterministic_with_seed_7() {
    let args = [
        "--canvas-width",
        "96",
        "--canvas-height",
        "24",
        "--anchor-canvas",
        "c",
        "--anchor-text",
        "c",
        "sunshower",
    ];
    let (f1, s1) = run_checked(LOGO, &args);
    let (f2, s2) = run_checked(LOGO, &args);
    assert_eq!(f1, f2);
    assert_eq!(s1, s2);
}

#[test]
fn edge_cases_and_existing_color_handling() {
    let long = "x".repeat(500);
    let ansi = "\x1b[38;2;255;120;40mOMARCHY\x1b[48;2;20;40;80m   \x1b[0mplain\n";
    let cases: [(&str, &str, &str); 6] = [
        ("A", "1", "1"),
        ("OMARCHY\nhello\n", "10", "3"),
        (long.as_str(), "96", "24"),
        ("日本語🎉 test\n", "60", "16"),
        (ansi, "60", "16"),
        ("", "20", "5"),
    ];
    for (input, w, h) in cases {
        run_checked(input, &["--canvas-width", w, "--canvas-height", h, "sunshower"]);
    }
    for handling in ["dynamic", "always"] {
        run_checked(
            ansi,
            &[
                "--canvas-width",
                "60",
                "--canvas-height",
                "16",
                "--existing-color-handling",
                handling,
                "sunshower",
            ],
        );
    }
}

#[test]
fn timing_options_change_run_length() {
    let base = run_checked("OMARCHY\n", &["--canvas-width", "60", "--canvas-height", "16", "sunshower"]).0;
    for (flag, val) in [
        ("--sun-start", "800"),
        ("--sunrise-duration", "800"),
        ("--rainbow-start", "400"),
        ("--rainbow-duration", "400"),
        ("--hold-time", "350"),
        ("--clear-duration", "320"),
        ("--final-hold-time", "500"),
    ] {
        let frames = run_checked(
            "OMARCHY\n",
            &["--canvas-width", "60", "--canvas-height", "16", "sunshower", flag, val],
        )
        .0;
        assert_ne!(frames, base, "{flag} {val} did not change run length");
    }
}
