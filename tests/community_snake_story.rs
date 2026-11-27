//! snake (refined): the run on the Omarchy logo at screensaver size is a
//! screensaver's length, and a huge text on a huge canvas stays quick.

use clap::Parser;

use ttfx::cli::Cli;
use ttfx::engine::ctx::Clock;
use ttfx::fx::Engine;
use ttfx::utils::rng::Rng;

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

fn frames(input: &str, args: &[&str]) -> usize {
    let mut argv = vec!["ttfx", "--seed", "7", "--frame-rate", "120"];
    argv.extend_from_slice(args);
    argv.push("snake");
    let cli = Cli::try_parse_from(&argv).expect("cli parse");
    let config = cli.terminal_config();
    let command = cli.effect.as_ref().expect("effect");
    let mut effect = ttfx::fx::effects::build(command).expect("fx effect");
    let clock = Clock::virtual_with_frame_rate(config.frame_rate);
    let mut e = Engine::new(input, config, Rng::seeded(7), clock).expect("engine");
    effect.build(&mut e).expect("build");
    let mut n = 0;
    while effect.next_frame(&mut e) {
        n += 1;
        assert!(n < 100_000, "no end");
    }
    for &slot in &e.added_chars.clone() {
        assert!(!e.is_visible(slot), "helper {slot} still visible");
    }
    n
}

#[test]
fn logo_run_is_screensaver_length() {
    let centered = [
        "--canvas-width",
        "96",
        "--canvas-height",
        "24",
        "--anchor-canvas",
        "c",
        "--anchor-text",
        "c",
    ];
    let n = frames(LOGO, &centered);
    eprintln!("logo 96x24: {n} frames");
    // 8-25 s at 120 fps
    assert!((960..=3000).contains(&n), "{n} frames");
    let mut big = centered;
    big[1] = "300";
    big[3] = "90";
    let n = frames(LOGO, &big);
    eprintln!("logo 300x90: {n} frames");
    assert!((960..=3600).contains(&n), "{n} frames");
}

#[test]
fn huge_text_stays_quick() {
    let text = "The quick brown fox jumps over the lazy dog 0123456789 ".repeat(5);
    let text = format!("{text}\n").repeat(88);
    let start = std::time::Instant::now();
    let n = frames(&text, &["--canvas-width", "300", "--canvas-height", "90"]);
    eprintln!("300x90 full: {n} frames in {:?}", start.elapsed());
    assert!(n < 6000, "{n} frames");
}
