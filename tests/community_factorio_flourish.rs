//! Integration tests for community/factorio signature flourish, duration bounds,
//! determinism, edge cases, and timing options.

use std::time::Instant;

use clap::Parser;

use ttfx::cli::Cli;
use ttfx::engine::ctx::Clock;
use ttfx::fx::Engine;
use ttfx::utils::rng::Rng;

const LOGO: &str = "                 ▄▄▄\n\
 ▄█████▄    ▄███████████▄    ▄███████   ▄███████   ▄███████   ▄█   █▄    ▄█   █▄\n\
███   ███  ███   ███   ███  ███   ███  ███   ███  ███   ███  ███   ███  ███   ███\n\
███   ███  ███   ███   ███  ███   ███  ███   ███  ███   █▀   ███   ███  ███   ███\n\
███   ███  ███   ███   ███ ▄███▄▄▄███ ▄███▄▄▄██▀  ███       ▄███▄▄▄███▄ ███▄▄▄███\n\
███   ███  ███   ███   ███ ▀███▀▀▀███ ▀███▀▀▀▀    ███      ▀▀███▀▀▀███  ▀▀▀▀▀▀███\n\
███   ███  ███   ███   ███  ███   ███ ██████████  ███   █▄   ███   ███  ▄██   ███\n\
███   ███  ███   ███   ███  ███   ███  ███   ███  ███   ███  ███   ███  ███   ███\n\
 ▀█████▀    ▀█   ███   █▀   ███   █▀   ███   ███  ███████▀   ███   █▀    ▀█████▀\n\
                                       ███   █▀";

fn run_checked(input: &str, args: &[&str], seed: u64) -> (usize, Vec<String>) {
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

    let mut frames = 0usize;
    let mut sampled = Vec::new();
    while effect.next_frame(&mut e) {
        frames += 1;
        assert!(frames < 20_000, "{argv:?}: effect did not end");
        if frames % 30 == 0 || frames == 1 {
            e.render_here();
            let mut parts = Vec::new();
            e.renderer().frame_parts(b"", b"", &mut parts);
            let bytes: Vec<u8> = parts.iter().flat_map(|p| p.iter().copied()).collect();
            sampled.push(String::from_utf8(bytes).unwrap());
        }
    }
    // Capture final frame as well
    e.render_here();
    let mut parts = Vec::new();
    e.renderer().frame_parts(b"", b"", &mut parts);
    let bytes: Vec<u8> = parts.iter().flat_map(|p| p.iter().copied()).collect();
    sampled.push(String::from_utf8(bytes).unwrap());

    // Rule 1: clean last frame
    for &slot in &e.input_chars.clone() {
        assert_eq!(e.coord(slot), e.input_coord(slot), "{argv:?}: off its cell");
        let info = e.visual_info(e.current_visual(slot));
        assert_eq!(info.sym, e.input_sym(slot), "{argv:?}: wrong symbol");
        if e.canvas.coord_is_in_canvas(e.input_coord(slot)) {
            assert!(e.is_visible(slot), "{argv:?}: visible input char hidden");
        }
    }
    for &slot in &e.added_chars.clone() {
        assert!(!e.is_visible(slot), "{argv:?}: helper still visible");
    }
    assert!(e.active_is_empty(), "{argv:?}: active queue not empty");
    (frames, sampled)
}

fn strip_ansi(s: &str) -> String {
    let mut out = String::new();
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c == '\x1b' {
            for c in chars.by_ref() {
                if c.is_ascii_alphabetic() {
                    break;
                }
            }
        } else {
            out.push(c);
        }
    }
    out
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
            "--frame-rate",
            "120",
            "factorio",
        ];
        let (frames, sampled) = run_checked(LOGO, &args, 7);
        eprintln!("factorio {w}x{h}: {frames} frames");
        assert!(
            (960..=3000).contains(&frames),
            "{w}x{h}: {frames} frames (expected 960..=3000)"
        );
        // Flourish should show ONLINE indicator before final shutdown
        assert!(
            sampled.iter().any(|f| strip_ansi(f).contains("ONLINE")),
            "{w}x{h}: ONLINE indicator never appeared during flourish"
        );
        // Last frame must NOT contain ONLINE decor
        let last = strip_ansi(sampled.last().unwrap());
        assert!(!last.contains("ONLINE"), "{w}x{h}: ONLINE leaked onto last frame");
    }
}

#[test]
fn big_canvas_300x90_runs_well_under_one_second() {
    let args = [
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
        "factorio",
    ];
    let t0 = Instant::now();
    let (frames, _) = run_checked(LOGO, &args, 7);
    let elapsed = t0.elapsed();
    assert!(frames >= 960);
    assert!(
        elapsed.as_secs_f64() < 1.0,
        "300x90 took {:.3}s (must be < 1.0s)",
        elapsed.as_secs_f64()
    );
}

#[test]
fn deterministic_with_same_seed() {
    let args = [
        "--canvas-width",
        "96",
        "--canvas-height",
        "24",
        "--anchor-canvas",
        "c",
        "--anchor-text",
        "c",
        "--frame-rate",
        "120",
        "factorio",
        "--build-order",
        "random",
    ];
    let (f1, s1) = run_checked(LOGO, &args, 7);
    let (f2, s2) = run_checked(LOGO, &args, 7);
    assert_eq!(f1, f2);
    assert_eq!(s1, s2);
}

#[test]
fn edge_cases_and_existing_color_handling() {
    let line500 = "A".repeat(500);
    let unicode = "日本語🎉\nOMARCHY";
    let ansi = "\x1b[38;2;255;0;0mRED\x1b[0m \x1b[48;2;0;128;255m   \x1b[0m \x1b[1;32mBOLD\x1b[0m";

    for (input, w, h) in [
        ("X", "1", "1"),
        ("OMARCHY", "10", "3"),
        (line500.as_str(), "96", "24"),
        (unicode, "40", "10"),
        (ansi, "40", "10"),
    ] {
        for handling in ["ignore", "dynamic", "always"] {
            let args = [
                "--canvas-width",
                w,
                "--canvas-height",
                h,
                "--existing-color-handling",
                handling,
                "--frame-rate",
                "60",
                "factorio",
            ];
            let (frames, sampled) = run_checked(input, &args, 7);
            assert!(frames > 0, "{w}x{h} {handling}: 0 frames");
            if input == ansi && handling != "ignore" {
                let last = sampled.last().unwrap();
                assert!(
                    last.contains("38;2;255;0;0"),
                    "{handling}: lost red fg on last frame"
                );
                assert!(
                    last.contains("48;2;0;128;255"),
                    "{handling}: lost blue bg space on last frame"
                );
            }
        }
    }
}

#[test]
fn timing_options_change_run_length() {
    let input = "OMARCHY FACTORY";
    let base_args = [
        "--canvas-width",
        "60",
        "--canvas-height",
        "12",
        "--frame-rate",
        "60",
        "factorio",
    ];
    let base = run_checked(input, &base_args, 7).0;
    for extra in [
        &["--place-delay", "10"][..],
        &["--lift-frames", "5"],
        &["--cool-frames", "40"],
        &["--hold-frames", "30"],
        &["--inserters", "3"],
        &["--cycles", "2"],
    ] {
        let mut args = base_args.to_vec();
        args.extend_from_slice(extra);
        let n = run_checked(input, &args, 7).0;
        assert_ne!(n, base, "{extra:?} did not change run length ({n} == {base})");
    }
}
