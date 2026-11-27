//! Integration tests for malfunction's signature post-settle flourish:
//! - logo runs at 96x24, 182x45, 370x48 stay in 960..=3000 frames at 120 fps
//!   and end cleanly on the settled logo with all helpers hidden
//! - 300x90 computes well under 1 s
//! - determinism with --seed 7
//! - edge cases (1x1, 10x3, 500-char line, unicode, ANSI colors incl. bg spaces,
//!   --existing-color-handling dynamic and always)
//! - every timing option changes run length

use std::time::Instant;

use clap::Parser;

use ttfx::cli::Cli;
use ttfx::engine::ctx::Clock;
use ttfx::fx::Engine;
use ttfx::utils::rng::Rng;

const LOGO: &str = include_str!("/usr/share/omarchy/logo.txt");

fn try_run(input: &str, seed: u64, args: &[&str]) -> Option<(usize, Engine)> {
    let seed_str = seed.to_string();
    let mut argv = vec!["ttfx", "--seed", &seed_str];
    argv.extend_from_slice(args);
    let cli = Cli::try_parse_from(&argv).expect("cli parse");
    let config = cli.terminal_config();
    let command = cli.effect.as_ref().expect("effect");
    let mut effect = ttfx::fx::effects::build(command).expect("fx effect");
    let clock = Clock::virtual_with_frame_rate(config.frame_rate);
    let mut e = Engine::new(input, config, Rng::seeded(seed), clock).ok()?;
    effect.build(&mut e).expect("build");
    let mut frames = 0usize;
    while effect.next_frame(&mut e) {
        e.render_here();
        frames += 1;
        assert!(frames < 20_000, "{argv:?}: no end");
    }
    Some((frames, e))
}

fn assert_clean_final(e: &Engine, label: &str) {
    for &slot in &e.input_chars {
        assert!(e.is_visible(slot), "{label}: input char {slot} hidden");
        assert_eq!(
            e.coord(slot),
            e.input_coord(slot),
            "{label}: input char {slot} off home"
        );
        let info = e.visual_info(e.current_visual(slot));
        assert_eq!(
            info.sym,
            e.input_sym(slot),
            "{label}: input char {slot} wrong symbol"
        );
    }
    for &slot in &e.added_chars {
        assert!(
            !e.is_visible(slot),
            "{label}: added helper char {slot} still visible"
        );
    }
    assert!(e.active_is_empty(), "{label}: active set not empty");
}

#[test]
fn logo_runs_in_bounds_and_ends_cleanly() {
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
            "malfunction",
        ];
        let (frames, e) = try_run(LOGO, 7, &args).expect("logo run");
        assert!(
            (960..=3000).contains(&frames),
            "{w}x{h}: {frames} frames outside 960..=3000"
        );
        assert_clean_final(&e, &format!("{w}x{h}"));
    }
}

#[test]
fn big_canvas_300x90_is_fast() {
    let args = [
        "--canvas-width",
        "300",
        "--canvas-height",
        "90",
        "--anchor-canvas",
        "c",
        "--anchor-text",
        "c",
        "malfunction",
    ];
    let start = Instant::now();
    let (frames, e) = try_run(LOGO, 7, &args).expect("300x90 run");
    let elapsed = start.elapsed();
    assert_clean_final(&e, "300x90");
    assert!(
        (960..=3000).contains(&frames),
        "300x90: {frames} frames outside 960..=3000"
    );
    assert!(
        elapsed.as_secs_f64() < 1.0,
        "300x90 took {elapsed:?} (must be < 1s)"
    );
}

#[test]
fn deterministic_with_same_seed() {
    let args = [
        "--canvas-width",
        "182",
        "--canvas-height",
        "45",
        "--anchor-canvas",
        "c",
        "--anchor-text",
        "c",
        "malfunction",
    ];
    let run_frames = || {
        let mut argv = vec!["ttfx", "--seed", "7"];
        argv.extend_from_slice(&args);
        let cli = Cli::try_parse_from(&argv).expect("cli parse");
        let config = cli.terminal_config();
        let command = cli.effect.as_ref().expect("effect");
        let mut effect = ttfx::fx::effects::build(command).expect("fx effect");
        let clock = Clock::virtual_with_frame_rate(config.frame_rate);
        let mut e = Engine::new(LOGO, config, Rng::seeded(7), clock).expect("engine");
        effect.build(&mut e).expect("build");
        let mut snapshots = Vec::new();
        let mut frames = 0usize;
        while effect.next_frame(&mut e) {
            e.render_here();
            if frames % 100 == 0 || frames > 1070 {
                let state: Vec<_> = (0..e.char_count() as u32)
                    .map(|slot| (e.is_visible(slot), e.coord(slot), e.current_visual(slot)))
                    .collect();
                snapshots.push(state);
            }
            frames += 1;
        }
        (frames, snapshots)
    };
    let (fa, sa) = run_frames();
    let (fb, sb) = run_frames();
    assert_eq!(fa, fb);
    assert_eq!(sa, sb);
}

#[test]
fn edge_cases_and_existing_colors() {
    let long = "x".repeat(500);
    let unicode = "日本語🎉 wide ✦ chars";
    let ansi = "\x1b[38;2;255;0;0mRED\x1b[0m \x1b[48;2;0;128;255m   \x1b[0m plain";

    for (label, input, w, h) in [
        ("1x1", "A", "1", "1"),
        ("10x3", "OMARCHY", "10", "3"),
        ("500-char", long.as_str(), "80", "24"),
        ("unicode", unicode, "60", "20"),
        ("ansi-ignore", ansi, "60", "20"),
    ] {
        let args = ["--canvas-width", w, "--canvas-height", h, "malfunction"];
        if let Some((_, e)) = try_run(input, 7, &args) {
            assert_clean_final(&e, label);
        }
    }

    for mode in ["dynamic", "always"] {
        let args = [
            "--canvas-width",
            "60",
            "--canvas-height",
            "20",
            "--existing-color-handling",
            mode,
            "malfunction",
        ];
        let (_, e) = try_run(ansi, 7, &args).expect("ansi run");
        assert_clean_final(&e, mode);
        let mut saw_red = false;
        let mut saw_bg_space = false;
        for &slot in &e.input_chars {
            let info = e.visual_info(e.current_visual(slot));
            if e.input_fg(slot).map(|c| c.rgb_ints()) == Some((255, 0, 0)) {
                assert_eq!(info.fg.map(|c| c.rgb_ints()), Some((255, 0, 0)));
                saw_red = true;
            }
            if e.input_bg(slot).map(|c| c.rgb_ints()) == Some((0, 128, 255)) {
                assert_eq!(info.bg.map(|c| c.rgb_ints()), Some((0, 128, 255)));
                saw_bg_space = true;
            }
        }
        assert!(saw_red, "{mode}: red foreground not preserved");
        assert!(saw_bg_space, "{mode}: bg-colored space not preserved");
    }
}

#[test]
fn timing_options_change_run_length() {
    let input = "OMARCHY\nhello world\n";
    let run_with = |extra: &[&str]| {
        let mut args = vec!["--canvas-width", "80", "--canvas-height", "24", "malfunction"];
        args.extend_from_slice(extra);
        let (frames, e) = try_run(input, 7, &args).expect("timing run");
        assert_clean_final(&e, &format!("{extra:?}"));
        frames
    };
    let base = run_with(&[]);
    for opt in [
        ["--warmup-duration", "20"],
        ["--printing-duration", "50"],
        ["--malfunction-duration", "50"],
        ["--letter-flight-duration", "50"],
        ["--reassembly-duration", "80"],
        ["--final-hold-time", "0"],
    ] {
        assert_ne!(
            run_with(&opt),
            base,
            "{opt:?} did not change run length"
        );
    }
}
