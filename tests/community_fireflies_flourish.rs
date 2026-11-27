//! Focused verification for the `fireflies` signature lantern flourish:
//! duration bounds on the Omarchy logo across 96x24 / 182x45 / 370x48,
//! clean last frame, flourish liveness, 300x90 release speed, determinism,
//! edge cases, and timing CLI options.

use std::time::Instant;

use clap::Parser;

use ttfx::cli::Cli;
use ttfx::engine::animation::ExistingColorHandling;
use ttfx::engine::ctx::Clock;
use ttfx::fx::Engine;
use ttfx::utils::rng::Rng;

const MAX_FRAMES: usize = 20_000;

struct RunReport {
    frames: usize,
    trace: Vec<u64>,
    flourish_frames_alive: usize,
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

fn run_checked(input: &str, args: &[&str], record_trace: bool) -> RunReport {
    let mut argv = vec!["ttfx", "--seed", "7"];
    argv.extend_from_slice(args);
    let cli = Cli::try_parse_from(&argv).expect("cli parse");
    let config = cli.terminal_config();
    let handling = config.existing_color_handling;
    let command = cli.effect.as_ref().expect("effect");
    let mut effect = ttfx::fx::effects::build(command).expect("fx effect");
    let clock = Clock::virtual_with_frame_rate(config.frame_rate);
    let mut e = Engine::new(input, config, Rng::seeded(7), clock).expect("engine");
    effect.build(&mut e).expect("build");

    let input_slots = e.input_chars.clone();
    let added_slots = e.added_chars.clone();
    let mut trace = Vec::new();
    let mut frames = 0usize;
    let mut prev_hash = 0u64;
    let mut flourish_frames_alive = 0usize;

    while effect.next_frame(&mut e) {
        frames += 1;
        assert!(frames < MAX_FRAMES, "{argv:?}: did not terminate");

        let all_landed = !input_slots.is_empty()
            && input_slots.iter().all(|&s| {
                e.coord(s) == e.input_coord(s)
                    && e.visual_info(e.current_visual(s)).sym == e.input_sym(s)
            });
        let any_helper_visible = added_slots.iter().any(|&s| e.is_visible(s));

        if record_trace || all_landed {
            let h = frame_checksum(&e);
            if all_landed && any_helper_visible && h != prev_hash {
                flourish_frames_alive += 1;
            }
            if record_trace {
                trace.push(h);
            }
            prev_hash = h;
        }
    }

    // Verify clean final frame.
    for &slot in &input_slots {
        assert_eq!(
            e.coord(slot),
            e.input_coord(slot),
            "{argv:?}: slot {slot} off its input coord"
        );
        if e.canvas.coord_is_in_canvas(e.input_coord(slot)) {
            assert!(e.is_visible(slot), "{argv:?}: slot {slot} hidden on final frame");
        }
        let info = e.visual_info(e.current_visual(slot));
        assert_eq!(
            info.sym,
            e.input_sym(slot),
            "{argv:?}: slot {slot} wrong final symbol"
        );
        let input_colors = (e.input_fg(slot), e.input_bg(slot));
        if handling == ExistingColorHandling::Dynamic
            || (handling == ExistingColorHandling::Always && e.uses_preexisting_colors(slot))
        {
            assert_eq!(
                (info.fg, info.bg),
                input_colors,
                "{argv:?}: slot {slot} wrong final colors under {handling:?}"
            );
        } else if handling == ExistingColorHandling::Ignore {
            assert!(
                info.fg.is_some(),
                "{argv:?}: slot {slot} missing final gradient color"
            );
            assert!(
                info.bg.is_none(),
                "{argv:?}: slot {slot} leftover background glow on final frame"
            );
        }
    }
    for &slot in &added_slots {
        assert!(
            !e.is_visible(slot),
            "{argv:?}: helper slot {slot} still visible on final frame"
        );
    }
    assert!(e.active_is_empty(), "{argv:?}: active characters remain");

    RunReport {
        frames,
        trace,
        flourish_frames_alive,
    }
}

fn omarchy_logo() -> String {
    std::fs::read_to_string("/usr/share/omarchy/logo.txt").expect("read /usr/share/omarchy/logo.txt")
}

#[test]
fn omarchy_logo_duration_and_flourish_across_canvases() {
    let logo = omarchy_logo();
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
            "fireflies",
        ];
        let report = run_checked(&logo, &args, false);
        assert!(
            (960..=3000).contains(&report.frames),
            "logo at {w}x{h}: {} frames (expected 960..=3000)",
            report.frames
        );
        assert!(
            report.flourish_frames_alive >= 120,
            "logo at {w}x{h}: flourish only had {} visibly alive frames",
            report.flourish_frames_alive
        );
        eprintln!(
            "fireflies logo {w}x{h}: {} frames ({} alive flourish frames)",
            report.frames, report.flourish_frames_alive
        );
    }
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
        "fireflies",
    ];
    let start = Instant::now();
    let report = run_checked(&logo, &args, false);
    let elapsed = start.elapsed();
    assert!(
        (960..=3000).contains(&report.frames),
        "300x90: {} frames",
        report.frames
    );
    assert!(
        elapsed.as_secs_f64() < 1.0,
        "300x90 took {:.3}s (must be well under 1s)",
        elapsed.as_secs_f64()
    );
}

#[test]
fn deterministic_with_seed_7() {
    let logo = omarchy_logo();
    let args = [
        "--canvas-width",
        "120",
        "--canvas-height",
        "30",
        "--anchor-canvas",
        "c",
        "--anchor-text",
        "c",
        "fireflies",
    ];
    let a = run_checked(&logo, &args, true);
    let b = run_checked(&logo, &args, true);
    assert_eq!(a.frames, b.frames);
    assert_eq!(a.trace, b.trace);
}

#[test]
fn edge_cases_and_existing_color_handling() {
    let line_500 = "a".repeat(500);
    let inputs = [
        "OMARCHY",
        line_500.as_str(),
        "日本語🎉\nfireflies",
        "\x1b[31mred\x1b[0m \x1b[42;34mgreen\x1b[0m \x1b[42m \x1b[0m\x1b[1;33mbold\x1b[0m",
    ];
    let canvases = [["1", "1"], ["10", "3"], ["60", "12"]];
    let color_modes: &[&[&str]] = &[
        &[],
        &["--existing-color-handling", "dynamic"],
        &["--existing-color-handling", "always"],
    ];

    for [w, h] in canvases {
        for mode in color_modes {
            for input in &inputs {
                let mut args = vec!["--canvas-width", w, "--canvas-height", h];
                args.extend_from_slice(mode);
                args.push("fireflies");
                run_checked(input, &args, false);
            }
        }
    }
}

#[test]
fn timing_options_change_run_length() {
    let input = "OMARCHY\nhello world\nthe quick brown fox jumps over the lazy dog\n".repeat(3);
    let run_len = |extra: &[&str]| {
        let mut args = vec!["--canvas-width", "120", "--canvas-height", "24", "fireflies"];
        args.extend_from_slice(extra);
        run_checked(&input, &args, false).frames
    };
    let base = run_len(&[]);
    assert!(run_len(&["--movement-speed", "0.06"]) > base);
    assert!(run_len(&["--movement-speed", "1.5"]) < base);
    assert!(run_len(&["--wander-cycles", "10"]) > base);
    assert!(run_len(&["--landing-duration", "1600"]) > base);
    assert!(run_len(&["--landing-duration", "60"]) < base);
}
