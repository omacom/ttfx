//! Integration tests for the `snake` signature post-assembly flourish:
//! verifies duration at 96x24 / 182x45 / 370x48, clean final state,
//! determinism, performance at 300x90, edge cases, and timing options.

use std::time::Instant;

use clap::Parser;

use ttfx::cli::Cli;
use ttfx::engine::animation::ExistingColorHandling;
use ttfx::engine::ctx::Clock;
use ttfx::fx::Engine;
use ttfx::utils::rng::Rng;

const MAX_FRAMES: usize = 100_000;

const LOGO: &str = "                 ▄▄▄
 ▄█████▄    ▄███████████▄    ▄███████   ▄███████   ▄███████   ▄█   █▄    ▄█   █▄
███   ███  ███   ███   ███  ███   ███  ███   ███  ███   ███  ███   ███  ███   ███
███   ███  ███   ███   ███  ███   ███  ███   ███  ███   █▀   ███   ███  ███   ███
███   ███  ███   ███   ███ ▄███▄▄▄███ ▄███▄▄▄██▀  ███       ▄███▄▄▄███▄ ███▄▄▄███
███   ███  ███   ███   ███ ▀███▀▀▀███ ▀███▀▀▀▀    ███      ▀▀███▀▀▀███  ▀▀▀▀▀▀███
███   ███  ███   ███   ███  ███   ███ ██████████  ███   █▄   ███   ███  ▄██   ███
███   ███  ███   ███   ███  ███   ███  ███   ███  ███   ███  ███   ███  ███   ███
 ▀█████▀    ▀█   ███   █▀   ███   █▀   ███   ███  ███████▀   ███   █▀    ▀█████▀
                                       ███   █▀
";

struct RunResult {
    frames: usize,
    trace: Vec<u64>,
    late_changes: usize,
}

fn frame_checksum(e: &Engine) -> u64 {
    let mut h = 0xcbf2_9ce4_8422_2325u64;
    for slot in 0..e.char_count() as u32 {
        let c = e.coord(slot);
        for v in [
            c.column as u64,
            c.row as u64,
            e.current_visual(slot).0 as u64,
            e.is_visible(slot) as u64,
        ] {
            h = (h ^ v).wrapping_mul(0x0100_0000_01b3);
        }
    }
    h
}

fn run_snake(input: &str, global_args: &[&str], effect_args: &[&str]) -> Option<RunResult> {
    let mut argv = vec!["ttfx", "--seed", "7", "--frame-rate", "120"];
    argv.extend_from_slice(global_args);
    argv.push("snake");
    argv.extend_from_slice(effect_args);

    let cli = Cli::try_parse_from(&argv).expect("cli parse");
    let config = cli.terminal_config();
    let handling = config.existing_color_handling;
    let command = cli.effect.as_ref().expect("effect");
    let mut effect = ttfx::fx::effects::build(command).expect("fx effect");
    let clock = Clock::virtual_with_frame_rate(config.frame_rate);
    let mut e = match Engine::new(input, config, Rng::seeded(7), clock) {
        Ok(e) => e,
        Err(_) => return None,
    };
    effect.build(&mut e).expect("build");

    let mut trace = Vec::new();
    let mut frames = 0usize;
    while effect.next_frame(&mut e) {
        frames += 1;
        assert!(frames < MAX_FRAMES, "{argv:?}: did not terminate");
        trace.push(frame_checksum(&e));
    }

    // Rule 1: Clean last frame
    for &slot in &e.input_chars.clone() {
        assert_eq!(
            e.coord(slot),
            e.input_coord(slot),
            "{argv:?}: input slot {slot} not at input_coord"
        );
        if e.canvas.coord_is_in_canvas(e.input_coord(slot)) {
            assert!(
                e.is_visible(slot),
                "{argv:?}: visible input slot {slot} hidden"
            );
        }
        let info = e.visual_info(e.current_visual(slot));
        assert_eq!(
            info.sym,
            e.input_sym(slot),
            "{argv:?}: input slot {slot} wrong symbol"
        );
        let input_colors = (e.input_fg(slot), e.input_bg(slot));
        if handling == ExistingColorHandling::Dynamic
            || (handling == ExistingColorHandling::Always && e.uses_preexisting_colors(slot))
        {
            assert_eq!(
                (info.fg, info.bg),
                input_colors,
                "{argv:?}: input slot {slot} wrong preexisting final colors"
            );
        } else if handling == ExistingColorHandling::Ignore {
            assert!(
                info.fg.is_some(),
                "{argv:?}: input slot {slot} missing final gradient color"
            );
        }
    }
    for &slot in &e.added_chars.clone() {
        assert!(
            !e.is_visible(slot),
            "{argv:?}: added_chars slot {slot} still visible"
        );
    }
    assert!(e.active_is_empty(), "{argv:?}: active_is_empty() is false");

    // Count visual changes in the final 20% of the run to confirm the flourish is alive.
    let tail_start = trace.len().saturating_sub(trace.len() / 5);
    let late_changes = trace[tail_start..]
        .windows(2)
        .filter(|w| w[0] != w[1])
        .count();

    Some(RunResult {
        frames,
        trace,
        late_changes,
    })
}

#[test]
fn logo_durations_and_clean_ending() {
    let logo = std::fs::read_to_string("/usr/share/omarchy/logo.txt").unwrap_or_else(|_| LOGO.to_string());
    for (w, h) in [("96", "24"), ("182", "45"), ("370", "48")] {
        let res = run_snake(
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
            ],
            &[],
        )
        .expect("logo engine");
        eprintln!("logo {w}x{h}: {} frames (late_changes={})", res.frames, res.late_changes);
        assert!(
            (960..=3000).contains(&res.frames),
            "logo {w}x{h}: {} frames outside 960..=3000",
            res.frames
        );
        assert!(
            res.late_changes >= 50,
            "logo {w}x{h}: flourish appears static (only {} late changes)",
            res.late_changes
        );
    }
}

#[test]
fn performance_300x90_under_one_second() {
    let logo = std::fs::read_to_string("/usr/share/omarchy/logo.txt").unwrap_or_else(|_| LOGO.to_string());
    let start = Instant::now();
    let res = run_snake(
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
        ],
        &[],
    )
    .expect("300x90 engine");
    let elapsed = start.elapsed();
    eprintln!("logo 300x90: {} frames in {:?}", res.frames, elapsed);
    assert!(
        elapsed.as_secs_f64() < 1.0,
        "300x90 took {:?} (expected < 1s)",
        elapsed
    );
}

#[test]
fn deterministic_with_seed_7() {
    let args = [
        "--canvas-width",
        "182",
        "--canvas-height",
        "45",
        "--anchor-canvas",
        "c",
        "--anchor-text",
        "c",
    ];
    let a = run_snake(LOGO, &args, &[]).expect("run a");
    let b = run_snake(LOGO, &args, &[]).expect("run b");
    assert_eq!(a.frames, b.frames);
    assert_eq!(a.trace, b.trace);
}

#[test]
fn edge_cases_and_color_handling() {
    let long_500 = "x".repeat(500);
    let inputs: &[&str] = &[
        "x",
        "   \n  ",
        "日本語🎉\nhello",
        &long_500,
        "\x1b[31mred\x1b[0m \x1b[42m \x1b[0m \x1b[38;5;196;48;5;106mOMARCHY\x1b[0m",
    ];
    let canvases: &[&[&str]] = &[
        &["--canvas-width", "1", "--canvas-height", "1"],
        &["--canvas-width", "10", "--canvas-height", "3"],
        &["--canvas-width", "60", "--canvas-height", "16"],
    ];
    let modes: &[&[&str]] = &[
        &[],
        &["--existing-color-handling", "dynamic"],
        &["--existing-color-handling", "always"],
    ];
    for canvas in canvases {
        for mode in modes {
            for input in inputs {
                let mut g = canvas.to_vec();
                g.extend_from_slice(mode);
                run_snake(input, &g, &[]);
            }
        }
    }
}

#[test]
fn timing_options_change_run_length() {
    let g = [
        "--canvas-width",
        "96",
        "--canvas-height",
        "24",
        "--anchor-canvas",
        "c",
        "--anchor-text",
        "c",
    ];
    let base = run_snake(LOGO, &g, &[]).expect("base").frames;
    let slower = run_snake(LOGO, &g, &["--movement-speed", "0.5"])
        .expect("slower")
        .frames;
    let faster = run_snake(LOGO, &g, &["--movement-speed", "2.0"])
        .expect("faster")
        .frames;
    let delayed = run_snake(LOGO, &g, &["--spawn-delay", "60"])
        .expect("delayed")
        .frames;
    let instant = run_snake(LOGO, &g, &["--spawn-delay", "0"])
        .expect("instant")
        .frames;
    assert!(slower > base, "slower {slower} <= base {base}");
    assert!(faster < base, "faster {faster} >= base {base}");
    assert!(delayed > base, "delayed {delayed} <= base {base}");
    assert!(instant < base, "instant {instant} >= base {base}");
}
