//! Static effect registry (replaces upstream pkgutil discovery).
//! GENERATED structure — keep alphabetical by variant when adding effects.

pub mod beams;
pub mod binarypath;
pub mod blackhole;
pub mod bouncyballs;
pub mod bubbles;
pub mod burn;
pub mod colorshift;
pub mod common;
pub mod crumble;
pub mod decrypt;
pub mod errorcorrect;
pub mod expand;
pub mod fireworks;
pub mod highlight;
pub mod laseretch;
pub mod matrix;
pub mod middleout;
pub mod orbittingvolley;
pub mod overflow;
pub mod pour;
pub mod print_effect;
pub mod rain;
pub mod random_sequence;
pub mod rings;
pub mod scattered;
pub mod slice;
pub mod slide;
pub mod smoke;
pub mod spotlights;
pub mod spray;
pub mod swarm;
pub mod sweep;
pub mod synthgrid;
pub mod thunderstorm;
pub mod unstable;
pub mod vhstape;
pub mod waves;
pub mod wipe;

use clap::Subcommand;

use crate::engine::effect::Effect;
use crate::utils::palette::ApplyPalette;

#[derive(Subcommand, Debug, Clone)]
pub enum EffectCommand {
    /// Create beams which travel over the canvas illuminating the characters behind them.
    Beams(beams::BeamsConfig),
    /// Binary representations of each character move towards the home coordinate of the character.
    Binarypath(binarypath::BinaryPathConfig),
    /// Characters are consumed by a black hole and explode outwards.
    Blackhole(blackhole::BlackholeConfig),
    /// Characters are bouncy balls falling from the top of the canvas.
    Bouncyballs(bouncyballs::BouncyBallsConfig),
    /// Characters are formed into bubbles that float down and pop.
    Bubbles(bubbles::BubblesConfig),
    /// Burns vertically in the canvas.
    Burn(burn::BurnConfig),
    /// Display a gradient that shifts colors across the terminal.
    Colorshift(colorshift::ColorShiftConfig),
    /// Characters lose color and crumble into dust, vacuumed up, and reformed.
    Crumble(crumble::CrumbleConfig),
    /// Display a movie style decryption effect.
    Decrypt(decrypt::DecryptConfig),
    /// Some characters start in the wrong position and are corrected in sequence.
    Errorcorrect(errorcorrect::ErrorCorrectConfig),
    /// Expands the text from a single point.
    Expand(expand::ExpandConfig),
    /// Characters launch and explode like fireworks and fall into place.
    Fireworks(fireworks::FireworksConfig),
    /// Run a specular highlight across the text.
    Highlight(highlight::HighlightConfig),
    /// A laser etches characters onto the terminal.
    Laseretch(laseretch::LaserEtchConfig),
    /// Matrix digital rain effect.
    Matrix(matrix::MatrixConfig),
    /// Text expands in a single row or column in the middle of the canvas then out.
    Middleout(middleout::MiddleoutConfig),
    /// Four launchers orbit the canvas firing volleys of characters inward to build the input text from the center out.
    Orbittingvolley(orbittingvolley::OrbittingVolleyConfig),
    /// Input text overflows and scrolls the terminal in a random order until eventually appearing ordered.
    Overflow(overflow::OverflowConfig),
    /// Pours the characters into position from the given direction.
    Pour(pour::PourConfig),
    /// Lines are printed one at a time following a print head. Print head performs line feed, carriage return.
    Print(print_effect::PrintConfig),
    /// Rain characters from the top of the canvas.
    Rain(rain::RainConfig),
    /// Prints the input data in a random sequence.
    Randomsequence(random_sequence::RandomSequenceConfig),
    /// Characters are dispersed and form into spinning rings.
    Rings(rings::RingsConfig),
    /// Text is scattered across the canvas and moves into position.
    Scattered(scattered::ScatteredConfig),
    /// Slices the input in half and slides it into place from opposite directions.
    Slice(slice::SliceConfig),
    /// Slide characters into view from outside the terminal.
    Slide(slide::SlideConfig),
    /// Smoke floods the canvas colorizing any characters it crosses.
    Smoke(smoke::SmokeConfig),
    /// Spotlights search the text area, illuminating characters, before converging in the center and expanding.
    Spotlights(spotlights::SpotlightsConfig),
    /// Draws the characters spawning at varying rates from a single point.
    Spray(spray::SprayConfig),
    /// Characters are grouped into swarms and move around the terminal before settling into position.
    Swarm(swarm::SwarmConfig),
    /// Sweep across the canvas to reveal uncolored text, reverse sweep to color the text.
    Sweep(sweep::SweepConfig),
    /// Create a grid which fills with characters dissolving into the final text.
    Synthgrid(synthgrid::SynthGridConfig),
    /// Create a thunderstorm in the terminal.
    Thunderstorm(thunderstorm::ThunderstormConfig),
    /// Spawn characters jumbled, explode them to the edge of the canvas, then reassemble them in the correct layout.
    Unstable(unstable::UnstableConfig),
    /// Lines of characters glitch left and right and lose detail like an old VHS tape.
    Vhstape(vhstape::VhsTapeConfig),
    /// Waves travel across the terminal leaving behind the characters.
    Waves(waves::WavesConfig),
    /// Wipes the text across the terminal to reveal characters.
    Wipe(wipe::WipeConfig),
}

impl EffectCommand {
    pub fn build_effect(&self) -> Box<dyn Effect> {
        match self {
            EffectCommand::Beams(config) => Box::new(beams::Beams::new(config.clone())),
            EffectCommand::Binarypath(config) => {
                Box::new(binarypath::BinaryPath::new(config.clone()))
            }
            EffectCommand::Blackhole(config) => Box::new(blackhole::Blackhole::new(config.clone())),
            EffectCommand::Bouncyballs(config) => {
                Box::new(bouncyballs::BouncyBalls::new(config.clone()))
            }
            EffectCommand::Bubbles(config) => Box::new(bubbles::Bubbles::new(config.clone())),
            EffectCommand::Burn(config) => Box::new(burn::Burn::new(config.clone())),
            EffectCommand::Colorshift(config) => {
                Box::new(colorshift::ColorShift::new(config.clone()))
            }
            EffectCommand::Crumble(config) => Box::new(crumble::Crumble::new(config.clone())),
            EffectCommand::Decrypt(config) => Box::new(decrypt::Decrypt::new(config.clone())),
            EffectCommand::Errorcorrect(config) => {
                Box::new(errorcorrect::ErrorCorrect::new(config.clone()))
            }
            EffectCommand::Expand(config) => Box::new(expand::Expand::new(config.clone())),
            EffectCommand::Fireworks(config) => Box::new(fireworks::Fireworks::new(config.clone())),
            EffectCommand::Highlight(config) => Box::new(highlight::Highlight::new(config.clone())),
            EffectCommand::Laseretch(config) => Box::new(laseretch::LaserEtch::new(config.clone())),
            EffectCommand::Matrix(config) => Box::new(matrix::Matrix::new(config.clone())),
            EffectCommand::Middleout(config) => Box::new(middleout::Middleout::new(config.clone())),
            EffectCommand::Orbittingvolley(config) => {
                Box::new(orbittingvolley::OrbittingVolley::new(config.clone()))
            }
            EffectCommand::Overflow(config) => Box::new(overflow::Overflow::new(config.clone())),
            EffectCommand::Pour(config) => Box::new(pour::Pour::new(config.clone())),
            EffectCommand::Print(config) => Box::new(print_effect::Print::new(config.clone())),
            EffectCommand::Rain(config) => Box::new(rain::Rain::new(config.clone())),
            EffectCommand::Randomsequence(config) => {
                Box::new(random_sequence::RandomSequence::new(config.clone()))
            }
            EffectCommand::Rings(config) => Box::new(rings::Rings::new(config.clone())),
            EffectCommand::Scattered(config) => Box::new(scattered::Scattered::new(config.clone())),
            EffectCommand::Slice(config) => Box::new(slice::Slice::new(config.clone())),
            EffectCommand::Slide(config) => Box::new(slide::Slide::new(config.clone())),
            EffectCommand::Smoke(config) => Box::new(smoke::Smoke::new(config.clone())),
            EffectCommand::Spotlights(config) => {
                Box::new(spotlights::Spotlights::new(config.clone()))
            }
            EffectCommand::Spray(config) => Box::new(spray::Spray::new(config.clone())),
            EffectCommand::Swarm(config) => Box::new(swarm::Swarm::new(config.clone())),
            EffectCommand::Sweep(config) => Box::new(sweep::Sweep::new(config.clone())),
            EffectCommand::Synthgrid(config) => Box::new(synthgrid::SynthGrid::new(config.clone())),
            EffectCommand::Thunderstorm(config) => {
                Box::new(thunderstorm::Thunderstorm::new(config.clone()))
            }
            EffectCommand::Unstable(config) => Box::new(unstable::Unstable::new(config.clone())),
            EffectCommand::Vhstape(config) => Box::new(vhstape::VhsTape::new(config.clone())),
            EffectCommand::Waves(config) => Box::new(waves::Waves::new(config.clone())),
            EffectCommand::Wipe(config) => Box::new(wipe::Wipe::new(config.clone())),
        }
    }

    pub fn name(&self) -> &'static str {
        match self {
            EffectCommand::Beams(_) => "beams",
            EffectCommand::Binarypath(_) => "binarypath",
            EffectCommand::Blackhole(_) => "blackhole",
            EffectCommand::Bouncyballs(_) => "bouncyballs",
            EffectCommand::Bubbles(_) => "bubbles",
            EffectCommand::Burn(_) => "burn",
            EffectCommand::Colorshift(_) => "colorshift",
            EffectCommand::Crumble(_) => "crumble",
            EffectCommand::Decrypt(_) => "decrypt",
            EffectCommand::Errorcorrect(_) => "errorcorrect",
            EffectCommand::Expand(_) => "expand",
            EffectCommand::Fireworks(_) => "fireworks",
            EffectCommand::Highlight(_) => "highlight",
            EffectCommand::Laseretch(_) => "laseretch",
            EffectCommand::Matrix(_) => "matrix",
            EffectCommand::Middleout(_) => "middleout",
            EffectCommand::Orbittingvolley(_) => "orbittingvolley",
            EffectCommand::Overflow(_) => "overflow",
            EffectCommand::Pour(_) => "pour",
            EffectCommand::Print(_) => "print",
            EffectCommand::Rain(_) => "rain",
            EffectCommand::Randomsequence(_) => "randomsequence",
            EffectCommand::Rings(_) => "rings",
            EffectCommand::Scattered(_) => "scattered",
            EffectCommand::Slice(_) => "slice",
            EffectCommand::Slide(_) => "slide",
            EffectCommand::Smoke(_) => "smoke",
            EffectCommand::Spotlights(_) => "spotlights",
            EffectCommand::Spray(_) => "spray",
            EffectCommand::Swarm(_) => "swarm",
            EffectCommand::Sweep(_) => "sweep",
            EffectCommand::Synthgrid(_) => "synthgrid",
            EffectCommand::Thunderstorm(_) => "thunderstorm",
            EffectCommand::Unstable(_) => "unstable",
            EffectCommand::Vhstape(_) => "vhstape",
            EffectCommand::Waves(_) => "waves",
            EffectCommand::Wipe(_) => "wipe",
        }
    }

    /// The effect's default clap config, as if the user named only the effect.
    pub fn with_defaults(name: &str) -> Option<Self> {
        use clap::Parser;
        match crate::cli::Cli::try_parse_from(["ttfx", name]) {
            Ok(cli) => cli.effect,
            Err(_) => None,
        }
    }

    pub fn apply_palette(
        &mut self,
        palette: &crate::utils::palette::Palette,
        skip: &::std::collections::HashSet<String>,
    ) {
        match self {
            EffectCommand::Beams(config) => config.apply_palette(palette, skip),
            EffectCommand::Binarypath(config) => config.apply_palette(palette, skip),
            EffectCommand::Blackhole(config) => config.apply_palette(palette, skip),
            EffectCommand::Bouncyballs(config) => config.apply_palette(palette, skip),
            EffectCommand::Bubbles(config) => config.apply_palette(palette, skip),
            EffectCommand::Burn(config) => config.apply_palette(palette, skip),
            EffectCommand::Colorshift(config) => config.apply_palette(palette, skip),
            EffectCommand::Crumble(config) => config.apply_palette(palette, skip),
            EffectCommand::Decrypt(config) => config.apply_palette(palette, skip),
            EffectCommand::Errorcorrect(config) => config.apply_palette(palette, skip),
            EffectCommand::Expand(config) => config.apply_palette(palette, skip),
            EffectCommand::Fireworks(config) => config.apply_palette(palette, skip),
            EffectCommand::Highlight(config) => config.apply_palette(palette, skip),
            EffectCommand::Laseretch(config) => config.apply_palette(palette, skip),
            EffectCommand::Matrix(config) => config.apply_palette(palette, skip),
            EffectCommand::Middleout(config) => config.apply_palette(palette, skip),
            EffectCommand::Orbittingvolley(config) => config.apply_palette(palette, skip),
            EffectCommand::Overflow(config) => config.apply_palette(palette, skip),
            EffectCommand::Pour(config) => config.apply_palette(palette, skip),
            EffectCommand::Print(config) => config.apply_palette(palette, skip),
            EffectCommand::Rain(config) => config.apply_palette(palette, skip),
            EffectCommand::Randomsequence(config) => config.apply_palette(palette, skip),
            EffectCommand::Rings(config) => config.apply_palette(palette, skip),
            EffectCommand::Scattered(config) => config.apply_palette(palette, skip),
            EffectCommand::Slice(config) => config.apply_palette(palette, skip),
            EffectCommand::Slide(config) => config.apply_palette(palette, skip),
            EffectCommand::Smoke(config) => config.apply_palette(palette, skip),
            EffectCommand::Spotlights(config) => config.apply_palette(palette, skip),
            EffectCommand::Spray(config) => config.apply_palette(palette, skip),
            EffectCommand::Swarm(config) => config.apply_palette(palette, skip),
            EffectCommand::Sweep(config) => config.apply_palette(palette, skip),
            EffectCommand::Synthgrid(config) => config.apply_palette(palette, skip),
            EffectCommand::Thunderstorm(config) => config.apply_palette(palette, skip),
            EffectCommand::Unstable(config) => config.apply_palette(palette, skip),
            EffectCommand::Vhstape(config) => config.apply_palette(palette, skip),
            EffectCommand::Waves(config) => config.apply_palette(palette, skip),
            EffectCommand::Wipe(config) => config.apply_palette(palette, skip),
        }
    }
}

pub fn catalog_entries() -> Vec<(String, String)> {
    use clap::CommandFactory;
    crate::cli::Cli::command()
        .get_subcommands()
        .map(|cmd| {
            (
                cmd.get_name().to_string(),
                cmd.get_about().map(|s| s.to_string()).unwrap_or_default(),
            )
        })
        .collect()
}

macro_rules! impl_apply_palette {
    ($ty:ty, $($field:ident),+ $(,)?) => {
        impl crate::utils::palette::ApplyPalette for $ty {
            fn apply_palette(
                &mut self,
                palette: &crate::utils::palette::Palette,
                skip: &::std::collections::HashSet<String>,
            ) {
                let mut single_index = 0usize;
                $(
                    if !skip.contains(stringify!($field)) {
                        crate::utils::palette::Recolor::recolor(
                            &mut self.$field,
                            palette,
                            &mut single_index,
                        );
                    }
                )+
            }
        }
    };
}

impl_apply_palette!(
    beams::BeamsConfig,
    beam_gradient_stops,
    final_gradient_stops
);
impl_apply_palette!(
    binarypath::BinaryPathConfig,
    final_gradient_stops,
    binary_colors
);
impl_apply_palette!(
    blackhole::BlackholeConfig,
    blackhole_color,
    star_colors,
    final_gradient_stops
);
impl_apply_palette!(
    bouncyballs::BouncyBallsConfig,
    ball_colors,
    final_gradient_stops
);
impl_apply_palette!(
    bubbles::BubblesConfig,
    bubble_colors,
    pop_color,
    final_gradient_stops
);
impl_apply_palette!(
    burn::BurnConfig,
    starting_color,
    burn_colors,
    final_gradient_stops
);
impl_apply_palette!(
    colorshift::ColorShiftConfig,
    gradient_stops,
    final_gradient_stops
);
impl_apply_palette!(crumble::CrumbleConfig, final_gradient_stops);
impl_apply_palette!(
    decrypt::DecryptConfig,
    ciphertext_colors,
    final_gradient_stops
);
impl_apply_palette!(
    errorcorrect::ErrorCorrectConfig,
    error_color,
    correct_color,
    final_gradient_stops
);
impl_apply_palette!(expand::ExpandConfig, final_gradient_stops);
impl_apply_palette!(
    fireworks::FireworksConfig,
    firework_colors,
    final_gradient_stops
);
impl_apply_palette!(highlight::HighlightConfig, final_gradient_stops);
impl_apply_palette!(
    laseretch::LaserEtchConfig,
    cool_gradient_stops,
    laser_gradient_stops,
    spark_gradient_stops,
    final_gradient_stops
);
impl_apply_palette!(
    matrix::MatrixConfig,
    highlight_color,
    rain_color_gradient,
    final_gradient_stops
);
impl_apply_palette!(
    middleout::MiddleoutConfig,
    starting_color,
    final_gradient_stops
);
impl_apply_palette!(orbittingvolley::OrbittingVolleyConfig, final_gradient_stops);
impl_apply_palette!(
    overflow::OverflowConfig,
    overflow_gradient_stops,
    final_gradient_stops
);
impl_apply_palette!(pour::PourConfig, starting_color, final_gradient_stops);
impl_apply_palette!(print_effect::PrintConfig, final_gradient_stops);
impl_apply_palette!(rain::RainConfig, rain_colors, final_gradient_stops);
impl_apply_palette!(random_sequence::RandomSequenceConfig, final_gradient_stops);
impl_apply_palette!(rings::RingsConfig, ring_colors, final_gradient_stops);
impl_apply_palette!(scattered::ScatteredConfig, final_gradient_stops);
impl_apply_palette!(slice::SliceConfig, final_gradient_stops);
impl_apply_palette!(slide::SlideConfig, final_gradient_stops);
impl_apply_palette!(
    smoke::SmokeConfig,
    starting_color,
    smoke_gradient_stops,
    final_gradient_stops
);
impl_apply_palette!(spotlights::SpotlightsConfig, final_gradient_stops);
impl_apply_palette!(spray::SprayConfig, final_gradient_stops);
impl_apply_palette!(
    swarm::SwarmConfig,
    base_color,
    flash_color,
    final_gradient_stops
);
impl_apply_palette!(sweep::SweepConfig, final_gradient_stops);
impl_apply_palette!(
    synthgrid::SynthGridConfig,
    grid_gradient_stops,
    text_gradient_stops
);
impl_apply_palette!(
    thunderstorm::ThunderstormConfig,
    lightning_color,
    glowing_text_color,
    spark_glow_color,
    final_gradient_stops
);
impl_apply_palette!(
    unstable::UnstableConfig,
    unstable_color,
    final_gradient_stops
);
impl_apply_palette!(
    vhstape::VhsTapeConfig,
    glitch_line_colors,
    glitch_wave_colors,
    noise_colors,
    final_gradient_stops
);
impl_apply_palette!(
    waves::WavesConfig,
    wave_gradient_stops,
    final_gradient_stops
);
impl_apply_palette!(wipe::WipeConfig, final_gradient_stops);

#[cfg(test)]
mod tests {
    use super::*;
    use crate::utils::palette::Palette;

    const ALL_EFFECT_NAMES: &[&str] = &[
        "beams",
        "binarypath",
        "blackhole",
        "bouncyballs",
        "bubbles",
        "burn",
        "colorshift",
        "crumble",
        "decrypt",
        "errorcorrect",
        "expand",
        "fireworks",
        "highlight",
        "laseretch",
        "matrix",
        "middleout",
        "orbittingvolley",
        "overflow",
        "pour",
        "print",
        "rain",
        "randomsequence",
        "rings",
        "scattered",
        "slice",
        "slide",
        "smoke",
        "spotlights",
        "spray",
        "swarm",
        "sweep",
        "synthgrid",
        "thunderstorm",
        "unstable",
        "vhstape",
        "waves",
        "wipe",
    ];

    #[test]
    fn named_effect_with_palette_builds() {
        let palette = Palette::from_hex_list("ff0000").unwrap();
        let mut command = EffectCommand::with_defaults("decrypt").unwrap();
        command.apply_palette(&palette, &Default::default());
        assert!(crate::fx::effects::build(&command).is_some());
        assert!(EffectCommand::with_defaults("decrypt").is_some());
        assert!(EffectCommand::with_defaults("not-an-effect").is_none());
    }

    #[test]
    fn every_effect_applies_a_hex_palette() {
        let palette = Palette::new(vec![
            crate::utils::graphics::Color::from_hex("ff0000").unwrap(),
            crate::utils::graphics::Color::from_hex("00ff00").unwrap(),
            crate::utils::graphics::Color::from_hex("0000ff").unwrap(),
        ])
        .unwrap();
        for name in ALL_EFFECT_NAMES {
            let mut cmd = EffectCommand::with_defaults(name).expect(name);
            let original = format!("{cmd:?}");
            cmd.apply_palette(&palette, &Default::default());
            let paletted = format!("{cmd:?}");
            assert_ne!(original, paletted, "{name} ignored the palette");
        }
    }
}
