//! Static effect registry (replaces upstream pkgutil discovery).
//!
//! One Cargo feature per effect. `all-effects` (the default) enables every
//! row in `define_effects!`. A single-effect binary or wasm is
//! `--no-default-features --features decrypt`. Wasm builds effects from
//! `Default` configs (`build_named_effect`) so clap stays out of that
//! artifact.
//!
//! Adding an effect: a row here, an empty feature in Cargo.toml, and the name
//! in the `all-effects` list. Keep those lists alphabetical by effect name.

pub mod common;

use clap::Subcommand;

use crate::engine::effect::Effect;

macro_rules! define_effects {
    ($(
        $name:literal,
        $mod:ident,
        $variant:ident,
        $config:ident,
        $effect:ident,
        $about:literal
    );* $(;)?) => {
        $(
            #[cfg(feature = $name)]
            pub mod $mod;
        )*

        #[cfg(not(any($(feature = $name),*)))]
        compile_error!(
            "no effects enabled; build with default features or --no-default-features --features <effect>"
        );

        #[derive(Subcommand, Debug, Clone)]
        pub enum EffectCommand {
            $(
                #[cfg(feature = $name)]
                #[doc = $about]
                $variant($mod::$config),
            )*
        }

        impl EffectCommand {
            pub fn build_effect(&self) -> Box<dyn Effect> {
                match self {
                    $(
                        #[cfg(feature = $name)]
                        EffectCommand::$variant(config) => Box::new($mod::$effect::new(config.clone())),
                    )*
                }
            }

            pub fn name(&self) -> &'static str {
                match self {
                    $(
                        #[cfg(feature = $name)]
                        EffectCommand::$variant(_) => $name,
                    )*
                }
            }

            pub fn with_defaults(name: &str) -> Option<Self> {
                match name {
                    $(
                        #[cfg(feature = $name)]
                        $name => Some(EffectCommand::$variant($mod::$config::default())),
                    )*
                    _ => None,
                }
            }

            pub fn apply_palette(
                &mut self,
                palette: &crate::utils::palette::Palette,
                skip: &::std::collections::HashSet<String>,
            ) {
                match self {
                    $(
                        #[cfg(feature = $name)]
                        EffectCommand::$variant(config) => {
                            crate::utils::palette::ApplyPalette::apply_palette(config, palette, skip)
                        }
                    )*
                }
            }
        }

        pub fn catalog_entries() -> &'static [(&'static str, &'static str)] {
            &[
                $(
                    #[cfg(feature = $name)]
                    ($name, $about),
                )*
            ]
        }

        pub fn build_named_effect(name: &str) -> Option<Box<dyn Effect>> {
            build_named_effect_with_palette(name, None)
        }

        pub fn build_named_effect_with_palette(
            name: &str,
            palette: Option<&crate::utils::palette::Palette>,
        ) -> Option<Box<dyn Effect>> {
            match name {
                $(
                    #[cfg(feature = $name)]
                    $name => {
                        let mut config = $mod::$config::default();
                        if let Some(palette) = palette {
                            crate::utils::palette::ApplyPalette::apply_palette(
                                &mut config,
                                palette,
                                &::std::collections::HashSet::new(),
                            );
                        }
                        Some(Box::new($mod::$effect::new(config)))
                    }
                )*
                _ => None,
            }
        }

        #[cfg(test)]
        const ALL_EFFECT_NAMES: &[&str] = &[$($name),*];
    };
}

define_effects! {
    "beams", beams, Beams, BeamsConfig, Beams, "Create beams which travel over the canvas illuminating the characters behind them.";
    "binarypath", binarypath, Binarypath, BinaryPathConfig, BinaryPath, "Binary representations of each character move towards the home coordinate of the character.";
    "blackhole", blackhole, Blackhole, BlackholeConfig, Blackhole, "Characters are consumed by a black hole and explode outwards.";
    "bouncyballs", bouncyballs, Bouncyballs, BouncyBallsConfig, BouncyBalls, "Characters are bouncy balls falling from the top of the canvas.";
    "bubbles", bubbles, Bubbles, BubblesConfig, Bubbles, "Characters are formed into bubbles that float down and pop.";
    "burn", burn, Burn, BurnConfig, Burn, "Burns vertically in the canvas.";
    "colorshift", colorshift, Colorshift, ColorShiftConfig, ColorShift, "Display a gradient that shifts colors across the terminal.";
    "crumble", crumble, Crumble, CrumbleConfig, Crumble, "Characters lose color and crumble into dust, vacuumed up, and reformed.";
    "decrypt", decrypt, Decrypt, DecryptConfig, Decrypt, "Display a movie style decryption effect.";
    "errorcorrect", errorcorrect, Errorcorrect, ErrorCorrectConfig, ErrorCorrect, "Some characters start in the wrong position and are corrected in sequence.";
    "expand", expand, Expand, ExpandConfig, Expand, "Expands the text from a single point.";
    "fireworks", fireworks, Fireworks, FireworksConfig, Fireworks, "Characters launch and explode like fireworks and fall into place.";
    "highlight", highlight, Highlight, HighlightConfig, Highlight, "Run a specular highlight across the text.";
    "laseretch", laseretch, Laseretch, LaserEtchConfig, LaserEtch, "A laser etches characters onto the terminal.";
    "matrix", matrix, Matrix, MatrixConfig, Matrix, "Matrix digital rain effect.";
    "middleout", middleout, Middleout, MiddleoutConfig, Middleout, "Text expands in a single row or column in the middle of the canvas then out.";
    "orbittingvolley", orbittingvolley, Orbittingvolley, OrbittingVolleyConfig, OrbittingVolley, "Four launchers orbit the canvas firing volleys of characters inward to build the input text from the center out.";
    "overflow", overflow, Overflow, OverflowConfig, Overflow, "Input text overflows and scrolls the terminal in a random order until eventually appearing ordered.";
    "pour", pour, Pour, PourConfig, Pour, "Pours the characters into position from the given direction.";
    "print", print_effect, Print, PrintConfig, Print, "Lines are printed one at a time following a print head. Print head performs line feed, carriage return.";
    "rain", rain, Rain, RainConfig, Rain, "Rain characters from the top of the canvas.";
    "randomsequence", random_sequence, Randomsequence, RandomSequenceConfig, RandomSequence, "Prints the input data in a random sequence.";
    "rings", rings, Rings, RingsConfig, Rings, "Characters are dispersed and form into spinning rings.";
    "scattered", scattered, Scattered, ScatteredConfig, Scattered, "Text is scattered across the canvas and moves into position.";
    "slice", slice, Slice, SliceConfig, Slice, "Slices the input in half and slides it into place from opposite directions.";
    "slide", slide, Slide, SlideConfig, Slide, "Slide characters into view from outside the terminal.";
    "smoke", smoke, Smoke, SmokeConfig, Smoke, "Smoke floods the canvas colorizing any characters it crosses.";
    "spotlights", spotlights, Spotlights, SpotlightsConfig, Spotlights, "Spotlights search the text area, illuminating characters, before converging in the center and expanding.";
    "spray", spray, Spray, SprayConfig, Spray, "Draws the characters spawning at varying rates from a single point.";
    "swarm", swarm, Swarm, SwarmConfig, Swarm, "Characters are grouped into swarms and move around the terminal before settling into position.";
    "sweep", sweep, Sweep, SweepConfig, Sweep, "Sweep across the canvas to reveal uncolored text, reverse sweep to color the text.";
    "synthgrid", synthgrid, Synthgrid, SynthGridConfig, SynthGrid, "Create a grid which fills with characters dissolving into the final text.";
    "thunderstorm", thunderstorm, Thunderstorm, ThunderstormConfig, Thunderstorm, "Create a thunderstorm in the terminal.";
    "unstable", unstable, Unstable, UnstableConfig, Unstable, "Spawn characters jumbled, explode them to the edge of the canvas, then reassemble them in the correct layout.";
    "vhstape", vhstape, Vhstape, VhsTapeConfig, VhsTape, "Lines of characters glitch left and right and lose detail like an old VHS tape.";
    "waves", waves, Waves, WavesConfig, Waves, "Waves travel across the terminal leaving behind the characters.";
    "wipe", wipe, Wipe, WipeConfig, Wipe, "Wipes the text across the terminal to reveal characters.";
}

macro_rules! impl_apply_palette {
    ($feature:literal, $ty:ty, $($field:ident),+ $(,)?) => {
        #[cfg(feature = $feature)]
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
    "beams",
    beams::BeamsConfig,
    beam_gradient_stops,
    final_gradient_stops
);
impl_apply_palette!(
    "binarypath",
    binarypath::BinaryPathConfig,
    final_gradient_stops,
    binary_colors
);
impl_apply_palette!(
    "blackhole",
    blackhole::BlackholeConfig,
    blackhole_color,
    star_colors,
    final_gradient_stops
);
impl_apply_palette!(
    "bouncyballs",
    bouncyballs::BouncyBallsConfig,
    ball_colors,
    final_gradient_stops
);
impl_apply_palette!(
    "bubbles",
    bubbles::BubblesConfig,
    bubble_colors,
    pop_color,
    final_gradient_stops
);
impl_apply_palette!(
    "burn",
    burn::BurnConfig,
    starting_color,
    burn_colors,
    final_gradient_stops
);
impl_apply_palette!(
    "colorshift",
    colorshift::ColorShiftConfig,
    gradient_stops,
    final_gradient_stops
);
impl_apply_palette!("crumble", crumble::CrumbleConfig, final_gradient_stops);
impl_apply_palette!(
    "decrypt",
    decrypt::DecryptConfig,
    ciphertext_colors,
    final_gradient_stops
);
impl_apply_palette!(
    "errorcorrect",
    errorcorrect::ErrorCorrectConfig,
    error_color,
    correct_color,
    final_gradient_stops
);
impl_apply_palette!("expand", expand::ExpandConfig, final_gradient_stops);
impl_apply_palette!(
    "fireworks",
    fireworks::FireworksConfig,
    firework_colors,
    final_gradient_stops
);
impl_apply_palette!(
    "highlight",
    highlight::HighlightConfig,
    final_gradient_stops
);
impl_apply_palette!(
    "laseretch",
    laseretch::LaserEtchConfig,
    cool_gradient_stops,
    laser_gradient_stops,
    spark_gradient_stops,
    final_gradient_stops
);
impl_apply_palette!(
    "matrix",
    matrix::MatrixConfig,
    highlight_color,
    rain_color_gradient,
    final_gradient_stops
);
impl_apply_palette!(
    "middleout",
    middleout::MiddleoutConfig,
    starting_color,
    final_gradient_stops
);
impl_apply_palette!(
    "orbittingvolley",
    orbittingvolley::OrbittingVolleyConfig,
    final_gradient_stops
);
impl_apply_palette!(
    "overflow",
    overflow::OverflowConfig,
    overflow_gradient_stops,
    final_gradient_stops
);
impl_apply_palette!(
    "pour",
    pour::PourConfig,
    starting_color,
    final_gradient_stops
);
impl_apply_palette!("print", print_effect::PrintConfig, final_gradient_stops);
impl_apply_palette!("rain", rain::RainConfig, rain_colors, final_gradient_stops);
impl_apply_palette!(
    "randomsequence",
    random_sequence::RandomSequenceConfig,
    final_gradient_stops
);
impl_apply_palette!(
    "rings",
    rings::RingsConfig,
    ring_colors,
    final_gradient_stops
);
impl_apply_palette!(
    "scattered",
    scattered::ScatteredConfig,
    final_gradient_stops
);
impl_apply_palette!("slice", slice::SliceConfig, final_gradient_stops);
impl_apply_palette!("slide", slide::SlideConfig, final_gradient_stops);
impl_apply_palette!(
    "smoke",
    smoke::SmokeConfig,
    starting_color,
    smoke_gradient_stops,
    final_gradient_stops
);
impl_apply_palette!(
    "spotlights",
    spotlights::SpotlightsConfig,
    final_gradient_stops
);
impl_apply_palette!("spray", spray::SprayConfig, final_gradient_stops);
impl_apply_palette!(
    "swarm",
    swarm::SwarmConfig,
    base_color,
    flash_color,
    final_gradient_stops
);
impl_apply_palette!("sweep", sweep::SweepConfig, final_gradient_stops);
impl_apply_palette!(
    "synthgrid",
    synthgrid::SynthGridConfig,
    grid_gradient_stops,
    text_gradient_stops
);
impl_apply_palette!(
    "thunderstorm",
    thunderstorm::ThunderstormConfig,
    lightning_color,
    glowing_text_color,
    spark_glow_color,
    final_gradient_stops
);
impl_apply_palette!(
    "unstable",
    unstable::UnstableConfig,
    unstable_color,
    final_gradient_stops
);
impl_apply_palette!(
    "vhstape",
    vhstape::VhsTapeConfig,
    glitch_line_colors,
    glitch_wave_colors,
    noise_colors,
    final_gradient_stops
);
impl_apply_palette!(
    "waves",
    waves::WavesConfig,
    wave_gradient_stops,
    final_gradient_stops
);
impl_apply_palette!("wipe", wipe::WipeConfig, final_gradient_stops);

#[cfg(test)]
mod tests {
    use clap::CommandFactory;
    #[cfg(all(feature = "decrypt", not(feature = "all-effects")))]
    use clap::Parser;

    use super::ALL_EFFECT_NAMES;
    use crate::cli::Cli;

    fn catalog_names() -> Vec<String> {
        Cli::command()
            .get_subcommands()
            .map(|cmd| cmd.get_name().to_string())
            .collect()
    }

    #[test]
    fn effect_inventory_is_alphabetical() {
        let mut sorted = ALL_EFFECT_NAMES.to_vec();
        sorted.sort_unstable();
        assert_eq!(ALL_EFFECT_NAMES, sorted.as_slice());
    }

    #[test]
    fn cargo_toml_declares_every_effect_feature() {
        let cargo = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/Cargo.toml"));
        for name in ALL_EFFECT_NAMES {
            let feature = format!("{name} = []");
            let umbrella = format!("    \"{name}\",");
            assert!(cargo.contains(&feature), "Cargo.toml missing `{feature}`");
            assert!(cargo.contains(&umbrella), "all-effects is missing `{name}`");
        }
    }

    #[cfg(feature = "all-effects")]
    #[test]
    fn default_registry_includes_every_effect() {
        assert_eq!(catalog_names(), ALL_EFFECT_NAMES);
    }

    #[cfg(feature = "decrypt")]
    #[test]
    fn decrypt_about_is_preserved() {
        let about = Cli::command()
            .get_subcommands()
            .find(|cmd| cmd.get_name() == "decrypt")
            .and_then(|cmd| cmd.get_about().map(|s| s.to_string()))
            .unwrap_or_default();
        assert!(about.contains("movie style decryption"), "{about:?}");
    }

    #[cfg(all(feature = "decrypt", not(feature = "all-effects")))]
    #[test]
    fn single_effect_build_exposes_only_decrypt() {
        assert_eq!(catalog_names(), ["decrypt"]);
        assert!(Cli::try_parse_from(["ttfx", "decrypt"])
            .unwrap()
            .effect
            .is_some());
        assert!(Cli::try_parse_from(["ttfx", "matrix"]).is_err());
    }

    #[test]
    fn named_catalog_lists_enabled_effects() {
        let names: Vec<&str> = super::catalog_entries()
            .iter()
            .map(|(name, _about)| *name)
            .collect();
        #[cfg(feature = "all-effects")]
        assert_eq!(names, ALL_EFFECT_NAMES);
        #[cfg(all(feature = "decrypt", not(feature = "all-effects")))]
        assert_eq!(names, ["decrypt"]);
    }

    #[test]
    fn unknown_effect_name_builds_nothing() {
        assert!(super::build_named_effect("not-an-effect").is_none());
    }

    #[cfg(feature = "decrypt")]
    #[test]
    fn decrypt_builds_from_name() {
        assert!(super::build_named_effect("decrypt").is_some());
    }

    #[cfg(feature = "decrypt")]
    #[test]
    fn named_effect_with_palette_builds() {
        use crate::utils::palette::Palette;
        let palette = Palette::from_hex_list("ff0000").unwrap();
        assert!(super::build_named_effect_with_palette("decrypt", Some(&palette)).is_some());
        assert!(super::build_named_effect_with_palette("decrypt", None).is_some());
    }

    #[cfg(all(not(target_arch = "wasm32"), feature = "all-effects"))]
    #[test]
    fn default_configs_match_clap_subcommand_defaults() {
        use clap::Parser;
        for name in ALL_EFFECT_NAMES {
            let via_clap = Cli::try_parse_from(["ttfx", *name])
                .unwrap()
                .effect
                .unwrap();
            let via_default = super::EffectCommand::with_defaults(name).unwrap();
            assert_eq!(
                format!("{via_clap:?}"),
                format!("{via_default:?}"),
                "{name}"
            );
        }
    }

    #[cfg(feature = "all-effects")]
    #[test]
    fn every_effect_applies_a_hex_palette() {
        use crate::utils::graphics::parse_color;
        use crate::utils::palette::Palette;
        let palette = Palette::new(vec![
            parse_color("ff0000").unwrap(),
            parse_color("00ff00").unwrap(),
        ])
        .unwrap();
        let skip = std::collections::HashSet::new();
        for name in ALL_EFFECT_NAMES {
            let original = format!("{:?}", super::EffectCommand::with_defaults(name).unwrap());
            let mut cmd = super::EffectCommand::with_defaults(name).unwrap();
            cmd.apply_palette(&palette, &skip);
            let paletted = format!("{cmd:?}");
            assert_ne!(original, paletted, "{name} ignored the palette");
            let _effect = cmd.build_effect();
        }
    }
}
