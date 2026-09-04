use clap::{CommandFactory, Parser};
use ttfx::engine::ctx::{Clock, EngineCtx};
use ttfx::engine::terminal::TerminalConfig;
use ttfx::utils::rng::Rng;

#[test]
fn every_registered_effect_builds_and_emits_a_frame() {
    let names: Vec<String> = ttfx::cli::Cli::command()
        .get_subcommands()
        .map(|command| command.get_name().to_string())
        .collect();
    assert!(!names.is_empty(), "clap effect registry is empty");

    for name in names {
        let mut effect = match ttfx::cli::Cli::try_parse_from(["ttfx", &name]).unwrap() {
            ttfx::cli::Cli {
                effect: Some(command),
                ..
            } => command.build_effect(),
            _ => panic!("effect not registered: {name}"),
        };
        let mut config = TerminalConfig::default();
        config.canvas_width = 40;
        config.canvas_height = 12;
        config.frame_rate = 60;
        let mut ctx = EngineCtx::new(
            "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
            config,
            Rng::seeded(42),
            Clock::virtual_with_frame_rate(60),
        )
        .unwrap_or_else(|error| panic!("{name}: context failed: {error}"));
        effect
            .build(&mut ctx)
            .unwrap_or_else(|error| panic!("{name}: build failed: {error}"));
        effect.on_audio(&mut ctx, 0.75, 0.6, true);
        assert!(
            effect.next_frame(&mut ctx).is_some(),
            "{name}: emitted no first frame"
        );
    }
}

#[test]
fn thunderstorm_handles_500_high_volume_audio_frames_without_stalling() {
    let cli = ttfx::cli::Cli::try_parse_from(["ttfx", "thunderstorm", "--storm-time", "1"]).unwrap();
    let mut effect = match cli.effect {
        Some(command) => command.build_effect(),
        None => panic!("thunderstorm not registered"),
    };
    let mut config = TerminalConfig::default();
    config.canvas_width = 40;
    config.canvas_height = 12;
    config.frame_rate = 60;
    let mut ctx = EngineCtx::new(
        "THUNDERSTORM AUDIO",
        config,
        Rng::seeded(4242),
        Clock::virtual_with_frame_rate(60),
    )
    .unwrap();
    effect.build(&mut ctx).unwrap();
    let mut frames = 0;
    while frames < 500 {
        effect.on_audio(&mut ctx, 1.0, 1.0, true);
        if effect.next_frame(&mut ctx).is_none() {
            break;
        }
        frames += 1;
    }
    assert_eq!(frames, 500, "thunderstorm ended during sustained audio load");
}
