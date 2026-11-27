//! fireflies: the run length stays bounded on big text and big canvases
//! (the cascade and the emergence share fixed budgets, long flights scale
//! with the canvas), every run still ends on the input text, and
//! `--landing-duration` feeds the length.

use clap::Parser;

use ttfx::cli::Cli;
use ttfx::engine::ctx::Clock;
use ttfx::fx::Engine;
use ttfx::utils::rng::Rng;

/// Run to completion; check the final state is the input text with every
/// helper hidden. Returns the frame count.
fn run(input: &str, args: &[&str]) -> usize {
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
        assert!(frames < 20_000, "{argv:?}: no end");
    }
    for &slot in &e.input_chars.clone() {
        assert_eq!(e.coord(slot), e.input_coord(slot), "{argv:?}: off its cell");
        let info = e.visual_info(e.current_visual(slot));
        assert_eq!(info.sym, e.input_sym(slot), "{argv:?}: wrong symbol");
    }
    for &slot in &e.added_chars.clone() {
        assert!(!e.is_visible(slot), "{argv:?}: helper still visible");
    }
    assert!(e.active_is_empty());
    frames
}

fn block() -> String {
    "The quick brown fox jumps over the lazy dog 0123456789 ".repeat(3) + "\n"
}

#[test]
fn big_text_and_big_canvases_stay_bounded() {
    let block = block().repeat(30);
    let long = "abcdefghij".repeat(80);
    // 8-25 s at 120 fps
    for canvas in [["96", "24"], ["190", "50"], ["300", "90"]] {
        for input in [block.as_str(), long.as_str()] {
            let args = [
                "--canvas-width",
                canvas[0],
                "--canvas-height",
                canvas[1],
                "--anchor-canvas",
                "c",
                "--anchor-text",
                "c",
                "fireflies",
            ];
            let frames = run(input, &args);
            assert!(
                (960..=3000).contains(&frames),
                "{canvas:?}: {frames} frames"
            );
        }
    }
}

#[test]
fn landing_duration_feeds_the_length() {
    // enough clusters that the cascade, not the slowest arrival, sets the end
    let block = block().repeat(4);
    let input = block.as_str();
    let base = ["--canvas-width", "180", "--canvas-height", "12", "fireflies"];
    let frames = |extra: &[&str]| {
        let mut args = base.to_vec();
        args.extend_from_slice(extra);
        run(input, &args)
    };
    let default = frames(&[]);
    assert!(frames(&["--landing-duration", "2000"]) > default);
    assert!(frames(&["--landing-duration", "60"]) < default);
}
