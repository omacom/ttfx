//! fx embedding audio: AudioLevels driving thunderstorm strikes. Silence
//! (all-zero levels) must keep the reference byte sequence, checked against
//! the original engine; driven levels must change it (audio strikes on top
//! of the ambient chance) and must not keep a timed storm from ending.

use clap::Parser;
use ttfx::cli::Cli;
use ttfx::engine::ctx::{Clock, EngineCtx};
use ttfx::fx::{self, AudioLevels, Engine};
use ttfx::utils::rng::Rng;

const INPUT: &str = "THUNDERSTORM\naudio reactive";

const ARGS: &[&str] = &[
    "ttfx",
    "--canvas-width",
    "40",
    "--canvas-height",
    "12",
    "--ignore-terminal-dimensions",
    "thunderstorm",
];

/// A short storm, so a run goes from the first frame to the last quickly.
const SHORT: &[&str] = &[
    "ttfx",
    "--canvas-width",
    "40",
    "--canvas-height",
    "12",
    "--ignore-terminal-dimensions",
    "thunderstorm",
    "--storm-time",
    "2",
];

fn build_seeded(args: &[&str], seed: u64) -> (Engine, Box<dyn fx::run::Effect>) {
    let cli = Cli::try_parse_from(args).unwrap();
    let config = cli.terminal_config();
    let command = cli.effect.unwrap();
    let engine = Engine::new(
        INPUT,
        config,
        Rng::seeded(seed),
        Clock::virtual_with_frame_rate(60),
    )
    .unwrap();
    let effect = fx::effects::build(&command).expect("fx builds thunderstorm");
    (engine, effect)
}

/// Every frame of a whole fx run fed `levels` each frame (at most `cap`).
fn fx_run(args: &[&str], levels: AudioLevels, cap: usize) -> Vec<Vec<u8>> {
    fx_run_seeded(args, 3, levels, cap)
}

fn fx_run_seeded(args: &[&str], seed: u64, levels: AudioLevels, cap: usize) -> Vec<Vec<u8>> {
    let (mut e, mut effect) = build_seeded(args, seed);
    effect.build(&mut e).unwrap();
    let mut frames = Vec::new();
    while frames.len() < cap {
        match frame_bytes(&mut e, effect.as_mut(), levels) {
            Some(f) => frames.push(f),
            None => break,
        }
    }
    frames
}

/// Every frame of the same run in the original engine, the reference fx
/// is checked against.
fn reference_run(args: &[&str], cap: usize) -> Vec<Vec<u8>> {
    let cli = Cli::try_parse_from(args).unwrap();
    let mut ctx = EngineCtx::new(
        INPUT,
        cli.terminal_config(),
        Rng::seeded(3),
        Clock::virtual_with_frame_rate(60),
    )
    .unwrap();
    let mut effect = cli.effect.unwrap().build_effect();
    effect.build(&mut ctx).unwrap();
    let mut frames = Vec::new();
    while frames.len() < cap {
        match effect.next_frame(&mut ctx) {
            Some(f) => frames.push(f.into_bytes()),
            None => break,
        }
    }
    frames
}

fn frame_bytes(
    e: &mut Engine,
    effect: &mut dyn fx::run::Effect,
    levels: AudioLevels,
) -> Option<Vec<u8>> {
    e.set_audio_levels(levels);
    if !effect.next_frame(e) {
        return None;
    }
    e.frame();
    e.render_here();
    let r = e.renderer();
    let mut parts: Vec<std::io::IoSlice<'_>> = Vec::new();
    r.frame_parts(b"", b"", &mut parts);
    let mut bytes = Vec::new();
    for part in &parts {
        bytes.extend_from_slice(part);
    }
    Some(bytes)
}

#[test]
fn driven_levels_change_the_storm() {
    let silence = AudioLevels::default();
    let driven = AudioLevels {
        volume: 0.9,
        beat: true,
    };
    let plain = fx_run(ARGS, silence, 240);

    // Driven levels change the sequence (audio strikes fire within a few
    // frames at 0.9 volume with the beat flag).
    let audio = fx_run(ARGS, driven, 240);
    assert_eq!(audio.len(), plain.len());
    let different = plain.iter().zip(&audio).filter(|(p, a)| p != a).count();
    assert!(
        different > 10,
        "driven audio must change many storm-phase frames, got {different}"
    );
}

#[test]
fn silence_matches_the_original_engine_byte_for_byte() {
    let silence = AudioLevels::default();
    // a whole run, through the unfade to the last frame
    let reference = reference_run(SHORT, 5000);
    let fx = fx_run(SHORT, silence, 5000);
    assert!(reference.len() < 5000, "the reference run ends");
    assert_eq!(fx.len(), reference.len(), "frame count");
    for (i, (f, r)) in fx.iter().zip(&reference).enumerate() {
        assert!(f == r, "frame {i} differs from the original engine");
    }
    // and the storm phase of a default-length run
    assert_eq!(fx_run(ARGS, silence, 600), reference_run(ARGS, 600));
}

#[test]
fn audio_starts_no_strike_once_storm_time_has_passed() {
    let silence = AudioLevels::default();
    let loud = AudioLevels {
        volume: 1.0,
        beat: true,
    };
    let mut changed = Vec::new();
    for seed in 1..=8 {
        // Audio only acts in the storm phase, so the first frame loud audio
        // changes is within a frame or two of the storm starting.
        let quiet = fx_run_seeded(SHORT, seed, silence, 5000);
        let driven = fx_run_seeded(SHORT, seed, loud, 5000);
        assert!(driven.len() < 5000, "seed {seed}: a loud storm still ends");
        let first = quiet
            .iter()
            .zip(&driven)
            .position(|(q, d)| q != d)
            .expect("loud audio changes the storm");
        // Going quiet once storm_time (2s at 60 fps) has passed changes
        // nothing: past the deadline audio lets the strike in flight finish
        // and starts no new one, so the storm ends as it would have.
        let cut = first + 2 * 60 + 5;
        let (mut e, mut effect) = build_seeded(SHORT, seed);
        effect.build(&mut e).unwrap();
        let mut cut_off = Vec::new();
        while cut_off.len() < 5000 {
            let levels = if cut_off.len() < cut { loud } else { silence };
            match frame_bytes(&mut e, effect.as_mut(), levels) {
                Some(f) => cut_off.push(f),
                None => break,
            }
        }
        if cut_off != driven {
            changed.push((seed, cut_off.len(), driven.len()));
        }
    }
    assert!(
        changed.is_empty(),
        "audio past storm_time changed the storm (seed, frames cut off, frames loud): {changed:?}"
    );
}
