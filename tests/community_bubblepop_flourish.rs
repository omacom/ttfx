//! Integration tests for bubblepop's signature effervescent micro-bubble flourish,
//! duration bounds, determinism, performance, and edge cases.

use std::time::Instant;

use clap::Parser;

use ttfx::cli::Cli;
use ttfx::engine::ctx::Clock;
use ttfx::fx::Engine;
use ttfx::utils::rng::Rng;

fn load_logo() -> String {
    std::fs::read_to_string("/usr/share/omarchy/logo.txt")
        .unwrap_or_else(|_| "OMARCHY OMARCHY OMARCHY\n".repeat(9))
}

fn try_run(input: &str, args: &[&str], seed: u64) -> Option<(usize, Engine)> {
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
    let mut frames = 0;
    while effect.next_frame(&mut e) {
        frames += 1;
        assert!(frames < 20_000, "{argv:?}: did not terminate");
    }
    Some((frames, e))
}

fn assert_clean_end(e: &Engine, label: &str) {
    for &slot in &e.input_chars {
        let coord = e.input_coord(slot);
        if e.canvas.coord_is_in_canvas(coord) {
            assert!(
                e.is_visible(slot),
                "{label}: in-canvas input slot {slot} hidden"
            );
        }
        assert_eq!(e.coord(slot), coord, "{label}: slot {slot} off input_coord");
        let info = e.visual_info(e.current_visual(slot));
        assert_eq!(
            info.sym,
            e.input_sym(slot),
            "{label}: slot {slot} wrong symbol"
        );
    }
    for &slot in &e.added_chars {
        assert!(
            !e.is_visible(slot),
            "{label}: added_chars slot {slot} still visible"
        );
    }
    assert!(e.active_is_empty(), "{label}: active chars not empty");
}

#[test]
fn logo_runs_in_bounds_and_ends_clean() {
    let logo = load_logo();
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
            "--frame-rate",
            "120",
            "bubblepop",
        ];
        let (frames, e) = try_run(&logo, &args, 7).expect("engine");
        assert!(
            (960..=3000).contains(&frames),
            "{w}x{h}: expected 960..=3000 frames, got {frames}"
        );
        assert_clean_end(&e, &format!("{w}x{h}"));
    }
}

#[test]
fn flourish_is_visibly_alive_during_ending() {
    let logo = load_logo();
    let args = [
        "--canvas-width",
        "182",
        "--canvas-height",
        "45",
        "--anchor-canvas",
        "c",
        "--anchor-text",
        "c",
        "--frame-rate",
        "120",
        "bubblepop",
        "--ambient-bubbles",
        "0",
    ];
    let mut argv = vec!["ttfx", "--seed", "7"];
    argv.extend_from_slice(&args);
    let cli = Cli::try_parse_from(&argv).expect("cli parse");
    let config = cli.terminal_config();
    let command = cli.effect.as_ref().expect("effect");
    let mut effect = ttfx::fx::effects::build(command).expect("fx effect");
    let clock = Clock::virtual_with_frame_rate(config.frame_rate);
    let mut e = Engine::new(&logo, config, Rng::seeded(7), clock).expect("engine");
    effect.build(&mut e).expect("build");

    // Collect snapshots during the last 300 frames (the flourish window)
    let mut total = 0usize;
    let mut active_added_in_ending = 0usize;
    while effect.next_frame(&mut e) {
        total += 1;
        if total > 900 && total < 1150 {
            let visible_added = e.added_chars.iter().filter(|&&s| e.is_visible(s)).count();
            if visible_added > 0 {
                active_added_in_ending += 1;
            }
        }
    }
    assert!(
        active_added_in_ending > 150,
        "flourish should keep micro-bubbles visibly alive during ending, got {active_added_in_ending} active frames"
    );
    assert_clean_end(&e, "flourish_alive");
}

#[test]
fn big_canvas_300x90_is_fast() {
    let logo = load_logo();
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
        "bubblepop",
    ];
    let start = Instant::now();
    let (frames, e) = try_run(&logo, &args, 7).expect("engine");
    let elapsed = start.elapsed();
    assert!(
        elapsed.as_secs_f64() < 1.0,
        "300x90 took {:.3}s ({frames} frames), expected < 1s",
        elapsed.as_secs_f64()
    );
    assert_clean_end(&e, "300x90");
}

#[test]
fn deterministic_with_seed_7() {
    let input = "OMARCHY\nbubblepop test\n";
    let snapshot = || {
        let argv = [
            "ttfx",
            "--seed",
            "7",
            "--canvas-width",
            "48",
            "--canvas-height",
            "16",
            "bubblepop",
        ];
        let cli = Cli::try_parse_from(argv).expect("cli parse");
        let config = cli.terminal_config();
        let command = cli.effect.as_ref().expect("effect");
        let mut effect = ttfx::fx::effects::build(command).expect("fx effect");
        let clock = Clock::virtual_with_frame_rate(config.frame_rate);
        let mut e = Engine::new(input, config, Rng::seeded(7), clock).expect("engine");
        effect.build(&mut e).expect("build");
        let mut trace = Vec::new();
        while effect.next_frame(&mut e) {
            for s in 0..e.char_count() as u32 {
                trace.push((e.is_visible(s), e.coord(s), e.current_visual(s)));
            }
        }
        trace
    };
    assert_eq!(snapshot(), snapshot());
}

#[test]
fn edge_cases_and_existing_colors() {
    let long = "A".repeat(500);
    let ansi = "\x1b[38;2;255;80;120mOMARCHY\x1b[0m \x1b[48;2;20;40;80m   \x1b[0m \x1b[38;2;80;220;255mPOP\x1b[0m";
    let inputs = [
        ("short", "OMARCHY\nhello"),
        ("long500", long.as_str()),
        ("unicode", "日本語🎉\nOMARCHY"),
        ("ansi", ansi),
    ];

    for (name, input) in inputs {
        for (w, h) in [("1", "1"), ("10", "3"), ("80", "24")] {
            let args = [
                "--canvas-width",
                w,
                "--canvas-height",
                h,
                "bubblepop",
            ];
            if let Some((_, e)) = try_run(input, &args, 7) {
                assert_clean_end(&e, &format!("{name}_{w}x{h}"));
            }
        }
    }

    for mode in ["dynamic", "always"] {
        let args = [
            "--canvas-width",
            "60",
            "--canvas-height",
            "12",
            "--existing-color-handling",
            mode,
            "bubblepop",
        ];
        let (_, e) = try_run(ansi, &args, 7).expect("ansi run");
        assert_clean_end(&e, &format!("ansi_{mode}"));
        let mut checked_fg = 0;
        let mut checked_bg = 0;
        for &slot in &e.input_chars {
            let info = e.visual_info(e.current_visual(slot));
            if let Some(fg) = e.input_fg(slot) {
                assert_eq!(
                    info.fg.map(|c| c.rgb_ints()),
                    Some(fg.rgb_ints()),
                    "{mode}: lost input fg"
                );
                checked_fg += 1;
            }
            if let Some(bg) = e.input_bg(slot) {
                assert_eq!(
                    info.bg.map(|c| c.rgb_ints()),
                    Some(bg.rgb_ints()),
                    "{mode}: lost input bg"
                );
                checked_bg += 1;
            }
        }
        assert!(checked_fg > 0, "{mode}: no fg checked");
        assert!(checked_bg > 0, "{mode}: no bg checked");
    }
}

#[test]
fn timing_options_change_run_length() {
    let input = "OMARCHY\nbubblepop timing\n";
    let run_with = |extra: &[&str]| {
        let mut args = vec!["--canvas-width", "60", "--canvas-height", "16", "bubblepop"];
        args.extend_from_slice(extra);
        try_run(input, &args, 7).expect("run").0
    };
    let base = run_with(&[]);
    for opt in [
        ["--bubble-count", "4"],
        ["--rise-duration", "260"],
        ["--launch-delay", "35"],
        ["--pop-duration", "70"],
        ["--final-hold-time", "120"],
    ] {
        assert_ne!(
            run_with(&opt),
            base,
            "{opt:?} did not change run length (base={base})"
        );
    }
}
