//! voronoi: integration tests for the cathedral sunbeam stained-glass flourish,
//! screensaver duration bounds, performance, determinism, edge cases, and CLI timing.

use clap::Parser;

use ttfx::cli::Cli;
use ttfx::engine::ctx::Clock;
use ttfx::fx::Engine;
use ttfx::utils::rng::Rng;

const FALLBACK_LOGO: &str = "                 ▄▄▄
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

fn load_logo() -> String {
    std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/omarchy-logo.txt"))
        .unwrap_or_else(|_| FALLBACK_LOGO.to_string())
}

fn build_engine(input: &str, args: &[&str]) -> (Box<dyn ttfx::fx::run::Effect>, Engine) {
    let mut argv = vec!["ttfx", "--seed", "7", "--frame-rate", "120"];
    argv.extend_from_slice(args);
    let cli = Cli::try_parse_from(&argv).expect("cli parse");
    let config = cli.terminal_config();
    let command = cli.effect.as_ref().expect("effect");
    let mut effect = ttfx::fx::effects::build(command).expect("fx effect");
    let clock = Clock::virtual_with_frame_rate(config.frame_rate);
    let mut e = Engine::new(input, config, Rng::seeded(7), clock).expect("engine");
    effect.build(&mut e).expect("build");
    (effect, e)
}

fn assert_clean_final(e: &Engine, label: &str) {
    let c = &e.canvas;
    for &slot in &e.input_chars {
        let coord = e.input_coord(slot);
        let in_canvas = coord.column >= c.left
            && coord.column <= c.right
            && coord.row >= c.bottom
            && coord.row <= c.top;
        assert_eq!(e.coord(slot), coord, "{label}: slot {slot} off input_coord");
        if in_canvas {
            assert!(e.is_visible(slot), "{label}: slot {slot} not visible");
        }
        let info = e.visual_info(e.current_visual(slot));
        assert_eq!(info.sym, e.input_sym(slot), "{label}: slot {slot} wrong symbol");
    }
    for &slot in &e.added_chars {
        assert!(!e.is_visible(slot), "{label}: added slot {slot} still visible");
    }
    assert!(e.active_is_empty(), "{label}: active list not empty");
}

fn run_to_end(input: &str, args: &[&str], label: &str) -> (usize, Engine) {
    let (mut effect, mut e) = build_engine(input, args);
    let mut frames = 0;
    while effect.next_frame(&mut e) {
        frames += 1;
        assert!(frames < 20_000, "{label}: did not finish");
    }
    assert_clean_final(&e, label);
    (frames, e)
}

#[test]
fn logo_runs_at_screensaver_sizes_and_ends_clean() {
    let logo = load_logo();
    for (w, h) in [("96", "24"), ("182", "45"), ("370", "48")] {
        let label = format!("logo {w}x{h}");
        let args = [
            "--canvas-width",
            w,
            "--canvas-height",
            h,
            "--anchor-canvas",
            "c",
            "--anchor-text",
            "c",
            "voronoi",
        ];
        let (frames, mut e) = run_to_end(&logo, &args, &label);
        eprintln!("{label}: {frames} frames");
        assert!(
            (960..=3000).contains(&frames),
            "{label}: expected 960..=3000 frames, got {frames}"
        );
        // Verify non-space letters settled with no lingering background glow.
        let space = e.sym(" ");
        for &slot in &e.input_chars {
            if e.input_sym(slot) != space {
                let info = e.visual_info(e.current_visual(slot));
                assert!(info.fg.is_some(), "{label}: settled letter missing gradient fg");
                assert!(info.bg.is_none(), "{label}: settled letter still has bg glow");
            }
        }
    }
}

#[test]
fn flourish_is_visibly_alive_with_backlit_glass_and_halo() {
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
        "voronoi",
    ];
    let (mut effect, mut e) = build_engine(&logo, &args);
    // Advance into the midpoint of the final flourish (shatter_end = 1140, end_frame = 1410 -> ~1260).
    let space = e.sym(" ");
    let mut saw_backlit_letter = false;
    let mut saw_halo_cell = false;
    for frame in 0..1411 {
        assert!(effect.next_frame(&mut e));
        if (1170..=1350).contains(&frame) {
            if !saw_backlit_letter {
                saw_backlit_letter = e.input_chars.iter().any(|&slot| {
                    e.input_sym(slot) != space
                        && e.visual_info(e.current_visual(slot)).bg.is_some()
                });
            }
            if !saw_halo_cell {
                saw_halo_cell = e.added_chars.iter().any(|&slot| e.is_visible(slot));
            }
        }
    }
    assert!(!effect.next_frame(&mut e));
    assert!(saw_backlit_letter, "letters should glow with stained-glass bg during sunbeam");
    assert!(saw_halo_cell, "local stained-glass halo should illuminate around logo during sunbeam");
    assert_clean_final(&e, "flourish_alive");
}

#[test]
fn large_canvas_300x90_is_fast() {
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
        "voronoi",
    ];
    let start = std::time::Instant::now();
    let (frames, _) = run_to_end(&logo, &args, "300x90");
    let elapsed = start.elapsed();
    eprintln!("300x90: {frames} frames in {elapsed:?}");
    assert!(
        elapsed.as_secs_f64() < 30.0,
        "300x90 took {elapsed:?} (hang guard)"
    );
}

#[test]
fn deterministic_frame_by_frame_for_seed_7() {
    let input = "OMARCHY\nhello world\n";
    let args = ["--canvas-width", "48", "--canvas-height", "12", "voronoi"];
    let (mut a, mut ea) = build_engine(input, &args);
    let (mut b, mut eb) = build_engine(input, &args);
    let mut frames = 0;
    loop {
        let na = a.next_frame(&mut ea);
        let nb = b.next_frame(&mut eb);
        assert_eq!(na, nb, "frame {frames}: termination mismatch");
        if !na {
            break;
        }
        assert_eq!(ea.char_count(), eb.char_count());
        for s in 0..ea.char_count() as u32 {
            assert_eq!(ea.coord(s), eb.coord(s), "frame {frames} slot {s} coord");
            assert_eq!(ea.is_visible(s), eb.is_visible(s), "frame {frames} slot {s} vis");
            assert_eq!(
                ea.visual_info(ea.current_visual(s)),
                eb.visual_info(eb.current_visual(s)),
                "frame {frames} slot {s} visual"
            );
        }
        frames += 1;
    }
    assert!(frames > 1000);
}

#[test]
fn edge_cases_and_existing_color_handling() {
    let long_line = "x".repeat(500);
    let cases: [(&str, &str, &str); 5] = [
        ("A", "1", "1"),
        ("OMARCHY\nhello\n", "10", "3"),
        (long_line.as_str(), "80", "10"),
        ("日本語🎉 stained glass\n", "40", "10"),
        ("", "20", "5"),
    ];
    for (input, w, h) in cases {
        let args = ["--canvas-width", w, "--canvas-height", h, "voronoi"];
        run_to_end(input, &args, &format!("edge {w}x{h}"));
    }

    // ANSI colors including bg-colored spaces under dynamic & always.
    let ansi = "\x1b[38;2;255;80;80mRED\x1b[0m\x1b[48;2;20;60;120m  \x1b[0mplain\n";
    for mode in ["dynamic", "always"] {
        let args = [
            "--canvas-width",
            "40",
            "--canvas-height",
            "8",
            "--existing-color-handling",
            mode,
            "voronoi",
        ];
        let (_, e) = run_to_end(ansi, &args, &format!("ansi {mode}"));
        for &slot in &e.input_chars {
            let info = e.visual_info(e.current_visual(slot));
            if e.input_fg(slot).is_some() {
                assert_eq!(info.fg, e.input_fg(slot), "{mode}: fg mismatch");
            }
            if e.input_bg(slot).is_some() {
                assert_eq!(info.bg, e.input_bg(slot), "{mode}: bg-colored space lost");
            }
        }
    }
}

#[test]
fn every_timing_option_changes_run_length() {
    let input = "OMARCHY\n";
    let base_args = ["--canvas-width", "30", "--canvas-height", "8", "voronoi"];
    let (base, _) = run_to_end(input, &base_args, "base");
    for (flag, val) in [
        ("--growth-duration", "330"),
        ("--living-duration", "450"),
        ("--shatter-duration", "450"),
        ("--final-hold-time", "300"),
    ] {
        let args = ["--canvas-width", "30", "--canvas-height", "8", "voronoi", flag, val];
        let (n, _) = run_to_end(input, &args, flag);
        assert_eq!(n, base + 30, "{flag} did not change run length as expected");
    }
}
