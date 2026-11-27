//! Integration tests for community/fishing's signature post-logo flourish,
//! timing bounds across standard/ultrawide screens, determinism, and edge cases.

use std::time::Instant;

use clap::Parser;

use ttfx::cli::Cli;
use ttfx::engine::animation::ExistingColorHandling;
use ttfx::engine::ctx::Clock;
use ttfx::fx::Engine;
use ttfx::utils::rng::Rng;

const LOGO: &str = r"                 ▄▄▄
 ▄█████▄    ▄███████████▄    ▄███████   ▄███████   ▄███████   ▄█   █▄    ▄█   █▄
███   ███  ███   ███   ███  ███   ███  ███   ███  ███   ███  ███   ███  ███   ███
███   ███  ███   ███   ███  ███   ███  ███   ███  ███   █▀   ███   ███  ███   ███
███   ███  ███   ███   ███ ▄███▄▄▄███ ▄███▄▄▄██▀  ███       ▄███▄▄▄███▄ ███▄▄▄███
███   ███  ███   ███   ███ ▀███▀▀▀███ ▀███▀▀▀▀    ███      ▀▀███▀▀▀███  ▀▀▀▀▀▀███
███   ███  ███   ███   ███  ███   ███ ██████████  ███   █▄   ███   ███  ▄██   ███
███   ███  ███   ███   ███  ███   ███  ███   ███  ███   ███  ███   ███  ███   ███
 ▀█████▀    ▀█   ███   █▀   ███   █▀   ███   ███  ███████▀   ███   █▀    ▀█████▀
                                       ███   █▀";

fn run_fishing(input: &str, seed: u64, args: &[&str]) -> (usize, Engine) {
    let seed_str = seed.to_string();
    let mut argv = vec!["ttfx", "--seed", &seed_str];
    argv.extend_from_slice(args);
    let cli = Cli::try_parse_from(&argv).expect("cli parse");
    let config = cli.terminal_config();
    let command = cli.effect.as_ref().expect("effect");
    let mut effect = ttfx::fx::effects::build(command).expect("fx effect");
    let clock = Clock::virtual_with_frame_rate(config.frame_rate);
    let mut e = Engine::new(input, config, Rng::seeded(seed), clock).expect("engine");
    effect.build(&mut e).expect("build");
    let mut frames = 0;
    while effect.next_frame(&mut e) {
        frames += 1;
        assert!(frames < 30_000, "{argv:?}: did not finish");
    }
    (frames, e)
}

fn assert_clean_final(e: &Engine, handling: ExistingColorHandling, label: &str) {
    for &slot in &e.input_chars {
        let input_coord = e.input_coord(slot);
        assert_eq!(e.coord(slot), input_coord, "{label}: input char off its cell");
        if e.canvas.coord_is_in_canvas(input_coord) {
            assert!(e.is_visible(slot), "{label}: in-canvas input char hidden");
        }
        let info = e.visual_info(e.current_visual(slot));
        assert_eq!(info.sym, e.input_sym(slot), "{label}: wrong final symbol");
        if matches!(
            handling,
            ExistingColorHandling::Dynamic | ExistingColorHandling::Always
        ) {
            assert_eq!(info.fg, e.input_fg(slot), "{label}: fg not preserved");
            assert_eq!(info.bg, e.input_bg(slot), "{label}: bg not preserved");
        }
    }
    for &slot in &e.added_chars {
        assert!(!e.is_visible(slot), "{label}: added helper left visible");
    }
    assert!(e.active_is_empty(), "{label}: active set not empty at end");
}

#[test]
fn logo_screensaver_bounds_and_clean_end() {
    let logo = std::fs::read_to_string("/usr/share/omarchy/logo.txt")
        .unwrap_or_else(|_| LOGO.to_string());
    for (w, h) in [(96, 24), (182, 45), (370, 48)] {
        let ws = w.to_string();
        let hs = h.to_string();
        let args = [
            "--canvas-width",
            &ws,
            "--canvas-height",
            &hs,
            "--anchor-canvas",
            "c",
            "--anchor-text",
            "c",
            "--frame-rate",
            "120",
            "fishing",
        ];
        let (frames, e) = run_fishing(&logo, 7, &args);
        eprintln!("fishing logo {w}x{h}: {frames} frames");
        assert!(
            (960..=3000).contains(&frames),
            "logo {w}x{h} out of 960..=3000 frames: got {frames}"
        );
        assert_clean_final(&e, ExistingColorHandling::Ignore, &format!("logo {w}x{h}"));
    }
}

#[test]
fn large_canvas_300x90_is_fast() {
    let logo = std::fs::read_to_string("/usr/share/omarchy/logo.txt")
        .unwrap_or_else(|_| LOGO.to_string());
    let started = Instant::now();
    let (frames, e) = run_fishing(
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
            "--frame-rate",
            "120",
            "fishing",
        ],
    );
    let elapsed = started.elapsed().as_secs_f64();
    eprintln!("fishing 300x90: {frames} frames in {elapsed:.3}s");
    assert!(elapsed < 1.0, "300x90 took {elapsed:.3}s (expected < 1.0s)");
    assert_clean_final(&e, ExistingColorHandling::Ignore, "300x90");
}

#[test]
fn deterministic_with_seed_7() {
    let trace = || {
        let cli = Cli::try_parse_from([
            "ttfx",
            "--seed",
            "7",
            "--canvas-width",
            "96",
            "--canvas-height",
            "24",
            "--anchor-canvas",
            "c",
            "--anchor-text",
            "c",
            "fishing",
            "--wrong-catch-chance",
            "0.4",
        ])
        .unwrap();
        let config = cli.terminal_config();
        let mut effect = ttfx::fx::effects::build(cli.effect.as_ref().unwrap()).unwrap();
        let clock = Clock::virtual_with_frame_rate(config.frame_rate);
        let mut e = Engine::new("OMARCHY\nfishing", config, Rng::seeded(7), clock).unwrap();
        effect.build(&mut e).unwrap();
        let mut snapshots = Vec::new();
        while effect.next_frame(&mut e) {
            snapshots.push((e.ch.coord.clone(), e.ch.flags.clone()));
        }
        snapshots
    };
    assert_eq!(trace(), trace());
}

#[test]
fn edge_cases_and_existing_color_handling() {
    let long_line = "x".repeat(500);
    let cases: Vec<(&str, &str, &str, &str)> = vec![
        ("1x1", "a", "1", "1"),
        ("10x3", "OMARCHY\nhi", "10", "3"),
        ("500-char", &long_line, "80", "10"),
        ("unicode", "日本語🎉\nfish 🐟", "40", "12"),
        (
            "ansi-bg-spaces",
            "\x1b[31mred\x1b[0m\x1b[44m   \x1b[0m\x1b[32mgreen\x1b[0m",
            "40",
            "12",
        ),
    ];
    for (name, input, w, h) in cases {
        let (_, e) = run_fishing(
            input,
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
                "fishing",
            ],
        );
        assert_clean_final(&e, ExistingColorHandling::Ignore, name);
    }

    let colored = "\x1b[31mred\x1b[0m\x1b[44m   \x1b[0m\x1b[38;2;10;200;120mmint\x1b[0m";
    for (flag, handling) in [
        ("dynamic", ExistingColorHandling::Dynamic),
        ("always", ExistingColorHandling::Always),
    ] {
        let (_, e) = run_fishing(
            colored,
            7,
            &[
                "--canvas-width",
                "40",
                "--canvas-height",
                "12",
                "--anchor-canvas",
                "c",
                "--anchor-text",
                "c",
                "--existing-color-handling",
                flag,
                "fishing",
            ],
        );
        assert_clean_final(&e, handling, flag);
    }
}

#[test]
fn timing_options_change_run_length() {
    let input = "OMARCHY\nhello world";
    let base_args = [
        "--canvas-width",
        "60",
        "--canvas-height",
        "16",
        "--anchor-canvas",
        "c",
        "--anchor-text",
        "c",
        "fishing",
        "--wrong-catch-chance",
        "0",
    ];
    let (base, _) = run_fishing(input, 7, &base_args);
    for extra in [
        &["--cast-speed", "0.3"][..],
        &["--reel-speed", "0.5"][..],
        &["--cast-delay", "20"][..],
        &["--hook-count", "1"][..],
    ] {
        let mut args = base_args.to_vec();
        args.extend_from_slice(extra);
        let (frames, _) = run_fishing(input, 7, &args);
        assert_ne!(frames, base, "{extra:?} did not change run length");
    }
    let (wrong_frames, _) = run_fishing(
        input,
        7,
        &[
            "--canvas-width",
            "60",
            "--canvas-height",
            "16",
            "--anchor-canvas",
            "c",
            "--anchor-text",
            "c",
            "fishing",
            "--wrong-catch-chance",
            "1",
        ],
    );
    assert_ne!(wrong_frames, base, "--wrong-catch-chance did not change run length");
}
