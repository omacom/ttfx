//! snake and fireflies (community ports): every run ends, ends on the input
//! text, is deterministic per seed, and survives the edge-case inputs.

use clap::Parser;

use ttfx::cli::Cli;
use ttfx::engine::animation::ExistingColorHandling;
use ttfx::engine::ctx::Clock;
use ttfx::fx::Engine;
use ttfx::utils::rng::Rng;

/// Frame cap: far beyond any legitimate run of these inputs.
const MAX_FRAMES: usize = 200_000;

struct Run {
    frames: usize,
    /// One checksum per frame (coordinates, visuals, visibility).
    trace: Vec<u64>,
}

fn checksum(e: &Engine) -> u64 {
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

/// Run `args` (global options then the effect) on `input` to completion and
/// check the final state shows exactly the input text.
fn run(input: &str, args: &[&str]) -> Option<Run> {
    let mut argv = vec!["ttfx", "--seed", "7"];
    argv.extend_from_slice(args);
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
    let mut frames = 0;
    while effect.next_frame(&mut e) {
        frames += 1;
        assert!(
            frames < MAX_FRAMES,
            "{argv:?}: no end after {frames} frames"
        );
        trace.push(checksum(&e));
    }
    // the final frame is the input text
    for &slot in &e.input_chars.clone() {
        assert_eq!(
            e.coord(slot),
            e.input_coord(slot),
            "{argv:?}: slot {slot} off its cell"
        );
        if e.canvas.coord_is_in_canvas(e.input_coord(slot)) {
            assert!(e.is_visible(slot), "{argv:?}: slot {slot} hidden");
        }
        let info = e.visual_info(e.current_visual(slot));
        assert_eq!(
            info.sym,
            e.input_sym(slot),
            "{argv:?}: slot {slot} wrong symbol"
        );
        // dynamic ends on the input colors (none for plain text); always
        // shows them on every character that has them
        let input_colors = (e.input_fg(slot), e.input_bg(slot));
        if handling == ExistingColorHandling::Dynamic
            || (handling == ExistingColorHandling::Always && e.uses_preexisting_colors(slot))
        {
            assert_eq!(
                (info.fg, info.bg),
                input_colors,
                "{argv:?}: slot {slot} wrong final colors"
            );
        } else if handling == ExistingColorHandling::Ignore {
            assert!(
                info.fg.is_some(),
                "{argv:?}: slot {slot} lacks its gradient color"
            );
        }
    }
    for &slot in &e.added_chars.clone() {
        assert!(!e.is_visible(slot), "{argv:?}: helper {slot} still visible");
    }
    assert!(e.active_is_empty(), "{argv:?}: active characters left");
    Some(Run { frames, trace })
}

const INPUTS: &[&str] = &[
    "OMARCHY\nhello world\n",
    "x",
    "   \n  ",
    "日本語テキスト wide\n絵文字🎉 ok\n",
    "\x1b[31mred\x1b[0m \x1b[42;34mgreen\x1b[0m plain\n\x1b[1;33mbold\x1b[0m",
    // a background-colored space is input too
    "\x1b[42m \x1b[0m\x1b[38;5;196;48;5;106mX\x1b[0m",
];

fn long_line() -> String {
    "abcdefghij".repeat(80)
}

fn block() -> String {
    "The quick brown fox jumps over the lazy dog 0123456789\n".repeat(12)
}

/// `heavy`: also the long inputs on the large canvas (fireflies' run grows
/// with the cluster count, so it skips those).
fn every_input(effect_args: &[&str], heavy: bool) {
    let canvases: &[&[&str]] = &[
        &["--canvas-width", "40", "--canvas-height", "8"],
        &["--canvas-width", "10", "--canvas-height", "3"],
        &["--canvas-width", "1", "--canvas-height", "1"],
        &["--canvas-width", "240", "--canvas-height", "70"],
    ];
    let colors: &[&[&str]] = &[
        &[],
        &["--existing-color-handling", "dynamic"],
        &["--existing-color-handling", "always"],
    ];
    let long = long_line();
    let block = block();
    let mut inputs: Vec<&str> = INPUTS.to_vec();
    inputs.push(&long);
    inputs.push(&block);
    for canvas in canvases {
        for color in colors {
            for input in &inputs {
                if !heavy && canvas[1] == "240" && input.len() > 100 {
                    continue;
                }
                let mut args: Vec<&str> = canvas.to_vec();
                args.extend_from_slice(color);
                args.extend_from_slice(effect_args);
                run(input, &args);
            }
        }
    }
}

fn frames(input: &str, args: &[&str]) -> usize {
    let mut all = vec!["--canvas-width", "60", "--canvas-height", "12"];
    all.extend_from_slice(args);
    run(input, &all).expect("engine").frames
}

#[test]
fn snake_edge_cases() {
    every_input(&["snake"], true);
    every_input(
        &[
            "snake",
            "--snake-count",
            "1",
            "--spawn-delay",
            "0",
            "--movement-speed",
            "3.5",
        ],
        true,
    );
    every_input(
        &[
            "snake",
            "--snake-count",
            "9",
            "--head-symbol",
            "@",
            "--snake-colors",
            "ff0000",
        ],
        true,
    );
}

#[test]
fn fireflies_edge_cases() {
    every_input(&["fireflies"], false);
    every_input(
        &[
            "fireflies",
            "--firefly-colors",
            "ffcc00",
            "--firefly-symbols",
            "+",
            "--auxiliary-count",
            "0",
            "--wander-cycles",
            "1",
            "--movement-speed",
            "2",
        ],
        false,
    );
}

#[test]
fn deterministic_per_seed() {
    let input = "OMARCHY\nhello world\n";
    for effect in [&["snake"][..], &["fireflies"][..]] {
        let mut args = vec!["--canvas-width", "50", "--canvas-height", "10"];
        args.extend_from_slice(effect);
        let a = run(input, &args).unwrap();
        let b = run(input, &args).unwrap();
        assert_eq!(a.frames, b.frames);
        assert_eq!(a.trace, b.trace);
    }
}

#[test]
fn snake_timing_options_change_the_length() {
    let input = "OMARCHY\nhello world\nsnakes carry text\n";
    let base = frames(input, &["snake"]);
    assert!(frames(input, &["snake", "--movement-speed", "0.25"]) > base);
    assert!(frames(input, &["snake", "--movement-speed", "4"]) < base);
    assert!(frames(input, &["snake", "--spawn-delay", "40"]) > base);
    assert!(frames(input, &["snake", "--spawn-delay", "0"]) <= base);
}

#[test]
fn fireflies_timing_options_change_the_length() {
    let input = "OMARCHY\nhello world\n";
    let base = frames(input, &["fireflies"]);
    assert!(frames(input, &["fireflies", "--movement-speed", "0.05"]) > base);
    assert!(frames(input, &["fireflies", "--movement-speed", "1.5"]) < base);
    assert!(frames(input, &["fireflies", "--wander-cycles", "12"]) > base);
}

#[test]
fn snake_small_run_is_short() {
    // the refined snake no longer replays the Python original's frame count
    // (58 here): it paces its steps for a screensaver and wanders in from a
    // random point on its edge. A small text on a small canvas stays brief.
    let args = ["--canvas-width", "40", "--canvas-height", "8", "snake"];
    let frames = run("OMARCHY\nhello world\n", &args).unwrap().frames;
    assert!((60..=1200).contains(&frames), "{frames} frames");
}
