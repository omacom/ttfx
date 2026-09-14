//! CLI root: the 15 TerminalConfig options (same names/defaults as upstream tte)
//! plus global args. Effect subcommands land in M3+.

use clap::Parser;

use crate::engine::animation::ExistingColorHandling;
use crate::engine::canvas::Anchor;
use crate::engine::terminal::TerminalConfig;
use crate::utils::graphics::{parse_color, Color};
use crate::utils::palette::{parse_palette_arg, Palette};

fn parse_positive_int(s: &str) -> Result<i64, String> {
    let v: i64 = s.parse().map_err(|_| format!("invalid int value: '{s}'"))?;
    if v > 0 {
        Ok(v)
    } else {
        Err(format!("{v} is not > 0"))
    }
}

fn parse_non_negative_int(s: &str) -> Result<i64, String> {
    let v: i64 = s.parse().map_err(|_| format!("invalid int value: '{s}'"))?;
    if v >= 0 {
        Ok(v)
    } else {
        Err(format!("{v} is not >= 0"))
    }
}

fn parse_canvas_dimension(s: &str) -> Result<i64, String> {
    let v: i64 = s.parse().map_err(|_| format!("invalid int value: '{s}'"))?;
    if v >= -1 {
        Ok(v)
    } else {
        Err(format!("{v} is not >= -1"))
    }
}

fn parse_anchor(s: &str) -> Result<Anchor, String> {
    Anchor::parse(s).ok_or_else(|| format!("invalid anchor: '{s}'"))
}

fn parse_existing_color_handling(s: &str) -> Result<ExistingColorHandling, String> {
    match s {
        "always" => Ok(ExistingColorHandling::Always),
        "dynamic" => Ok(ExistingColorHandling::Dynamic),
        "ignore" => Ok(ExistingColorHandling::Ignore),
        _ => Err(format!(
            "invalid choice: '{s}' (choose from 'always', 'dynamic', 'ignore')"
        )),
    }
}

#[derive(Parser, Debug)]
#[command(
    name = "ttfx",
    version,
    about = "Terminal text effects (Rust port of terminaltexteffects)",
    // upstream tte exposes --version/-v, so replace clap's default -V flag
    disable_version_flag = true
)]
pub struct Cli {
    /// Print the version and exit
    #[arg(short = 'v', long = "version", action = clap::ArgAction::Version)]
    pub version: Option<bool>,

    /// File to read input from
    #[arg(short = 'i', long = "input-file")]
    pub input_file: Option<std::path::PathBuf>,

    #[arg(long = "tab-width", default_value_t = 4, value_parser = parse_positive_int)]
    pub tab_width: i64,

    #[arg(long = "xterm-colors", default_value_t = false)]
    pub xterm_colors: bool,

    #[arg(long = "no-color", default_value_t = false)]
    pub no_color: bool,

    #[arg(long = "terminal-background-color", default_value = "#000000", value_parser = parse_color)]
    pub terminal_background_color: Color,

    #[arg(long = "existing-color-handling", default_value = "ignore", value_parser = parse_existing_color_handling)]
    pub existing_color_handling: ExistingColorHandling,

    #[arg(long = "wrap-text", default_value_t = false)]
    pub wrap_text: bool,

    #[arg(long = "frame-rate", default_value_t = 60, value_parser = parse_non_negative_int)]
    pub frame_rate: i64,

    #[arg(long = "canvas-width", default_value_t = -1, value_parser = parse_canvas_dimension, allow_negative_numbers = true)]
    pub canvas_width: i64,

    #[arg(long = "canvas-height", default_value_t = -1, value_parser = parse_canvas_dimension, allow_negative_numbers = true)]
    pub canvas_height: i64,

    #[arg(long = "anchor-canvas", default_value = "sw", value_parser = parse_anchor)]
    pub anchor_canvas: Anchor,

    #[arg(long = "anchor-text", default_value = "sw", value_parser = parse_anchor)]
    pub anchor_text: Anchor,

    #[arg(long = "ignore-terminal-dimensions", default_value_t = false)]
    pub ignore_terminal_dimensions: bool,

    #[arg(long = "reuse-canvas", default_value_t = false)]
    pub reuse_canvas: bool,

    #[arg(long = "no-eol", default_value_t = false)]
    pub no_eol: bool,

    #[arg(long = "no-restore-cursor", default_value_t = false)]
    pub no_restore_cursor: bool,

    /// Seed for the random number generator (deterministic within ttfx)
    #[arg(long = "seed")]
    pub seed: Option<u64>,

    /// Hex colors that replace the effect's default colors. Repeat the flag
    /// or separate colors with commas. Color flags given on the effect still
    /// apply.
    #[arg(long = "palette", value_name = "HEX[,HEX...]", action = clap::ArgAction::Append, value_parser = parse_palette_arg)]
    pub palette_args: Vec<Vec<Color>>,

    /// Color the word in 4-3-4-3-5 field bands using --palette (crest, hover,
    /// lit, mid, dim from the top). Requires --palette.
    #[arg(long = "bands", default_value_t = false)]
    pub bands: bool,

    /// Print a shell completion script and exit
    #[arg(long = "print-completion", value_name = "SHELL", value_parser = ["bash", "zsh"])]
    pub print_completion: Option<String>,

    /// Run a random effect
    #[arg(short = 'R', long = "random-effect", default_value_t = false)]
    pub random_effect: bool,

    /// Limit random-effect selection to these effects
    #[arg(long = "include-effects", num_args = 1.., conflicts_with = "exclude_effects")]
    pub include_effects: Vec<String>,

    /// Exclude these effects from random-effect selection
    #[arg(long = "exclude-effects", num_args = 1..)]
    pub exclude_effects: Vec<String>,

    /// M0 debug: make every canvas character visible and print the first frame
    /// (used by the parity harness; hidden from help)
    #[arg(long = "m0-dump", default_value_t = false, hide = true)]
    pub m0_dump: bool,

    /// Parity harness: dump length-prefixed frames deterministically (requires --seed)
    #[arg(long = "parity-dump", default_value_t = false, hide = true)]
    pub parity_dump: bool,

    /// Parity harness: stop after N frames
    #[arg(long = "max-frames", hide = true)]
    pub max_frames: Option<u64>,

    /// Parity harness: drive the clock virtually (1/frame_rate per frame) so
    /// clock-dependent effects (matrix, thunderstorm) are reproducible on the
    /// real tty output path. Implied by --parity-dump.
    #[arg(long = "virtual-clock", default_value_t = false, hide = true)]
    pub virtual_clock: bool,

    #[command(subcommand)]
    pub effect: Option<crate::effects::EffectCommand>,
}

impl Cli {
    pub fn terminal_config(&self) -> TerminalConfig {
        TerminalConfig {
            tab_width: self.tab_width,
            xterm_colors: self.xterm_colors,
            no_color: self.no_color,
            terminal_background_color: self.terminal_background_color.clone(),
            existing_color_handling: self.existing_color_handling,
            wrap_text: self.wrap_text,
            frame_rate: self.frame_rate,
            canvas_width: self.canvas_width,
            canvas_height: self.canvas_height,
            anchor_canvas: self.anchor_canvas,
            anchor_text: self.anchor_text,
            ignore_terminal_dimensions: self.ignore_terminal_dimensions,
            reuse_canvas: self.reuse_canvas,
            no_eol: self.no_eol,
            no_restore_cursor: self.no_restore_cursor,
            terminal_size: None,
        }
    }

    pub fn palette(&self) -> Option<Palette> {
        let colors: Vec<Color> = self.palette_args.iter().flatten().copied().collect();
        Palette::new(colors).ok()
    }
}

#[cfg(all(test, feature = "decrypt"))]
mod tests {
    use clap::{CommandFactory, FromArgMatches, Parser};

    use super::Cli;
    use crate::effects::EffectCommand;
    use crate::utils::graphics::parse_color;
    use crate::utils::palette::{command_line_arg_ids, Palette};

    fn color(hex: &str) -> crate::utils::graphics::Color {
        parse_color(hex).expect("test hex")
    }

    fn decrypt_config(effect: EffectCommand) -> crate::effects::decrypt::DecryptConfig {
        #[allow(unreachable_patterns)]
        match effect {
            EffectCommand::Decrypt(config) => config,
            _ => panic!("expected decrypt"),
        }
    }

    #[test]
    fn bands_flag_defaults_off() {
        let cli = Cli::try_parse_from(["ttfx", "--palette", "7aa2f7", "decrypt"]).unwrap();
        assert!(!cli.bands);
    }

    #[test]
    fn bands_flag_is_accepted_with_palette() {
        let cli = Cli::try_parse_from([
            "ttfx",
            "--palette",
            "aa0000,00aa00,0000aa,aaaa00,00aaaa",
            "--bands",
            "decrypt",
        ])
        .unwrap();
        assert!(cli.bands);
        assert_eq!(cli.palette().unwrap().colors().len(), 5);
    }

    #[test]
    fn palette_flag_accepts_comma_separated_hex() {
        let cli = Cli::try_parse_from(["ttfx", "--palette", "#7aa2f7,#f7768e", "decrypt"]).unwrap();
        assert_eq!(
            cli.palette().unwrap().colors(),
            &[color("#7aa2f7"), color("#f7768e")]
        );
        assert!(matches!(cli.effect, Some(EffectCommand::Decrypt(_))));
    }

    #[test]
    fn palette_flag_is_repeatable_and_splits_whitespace() {
        let cli = Cli::try_parse_from([
            "ttfx",
            "--palette",
            "7aa2f7",
            "--palette",
            "c0caf5 f7768e",
            "decrypt",
        ])
        .unwrap();
        assert_eq!(
            cli.palette().unwrap().colors(),
            &[color("7aa2f7"), color("c0caf5"), color("f7768e")]
        );
    }

    #[test]
    fn palette_does_not_eat_the_effect_name() {
        let cli = Cli::try_parse_from(["ttfx", "--palette", "7aa2f7", "decrypt"]).unwrap();
        assert!(matches!(cli.effect, Some(EffectCommand::Decrypt(_))));
        assert_eq!(cli.palette().unwrap().colors().len(), 1);
    }

    #[test]
    fn palette_rejects_an_empty_value() {
        assert!(Cli::try_parse_from(["ttfx", "--palette", ",", "decrypt"]).is_err());
    }

    #[test]
    fn palette_rejects_invalid_hex() {
        assert!(Cli::try_parse_from(["ttfx", "--palette", "not-a-color", "decrypt"]).is_err());
    }

    #[test]
    fn apply_palette_recolors_default_decrypt_colors() {
        let matches = Cli::command().get_matches_from([
            "ttfx",
            "--palette",
            "ff0000,00ff00,0000ff",
            "decrypt",
        ]);
        let mut cli = Cli::from_arg_matches(&matches).unwrap();
        let palette = cli.palette().unwrap();
        let mut effect = cli.effect.take().unwrap();
        effect.apply_palette(
            &palette,
            &command_line_arg_ids(matches.subcommand().unwrap().1),
        );
        let config = decrypt_config(effect);
        assert_eq!(
            config.ciphertext_colors,
            vec![color("ff0000"), color("00ff00"), color("0000ff")]
        );
        assert_eq!(config.final_gradient_stops, vec![color("ff0000")]);
    }

    #[test]
    fn apply_palette_leaves_explicit_color_flags_alone() {
        let matches = Cli::command().get_matches_from([
            "ttfx",
            "--palette",
            "ff0000,00ff00",
            "decrypt",
            "--final-gradient-stops",
            "ffffff",
        ]);
        let mut cli = Cli::from_arg_matches(&matches).unwrap();
        let palette = cli.palette().unwrap();
        let skip = command_line_arg_ids(matches.subcommand().unwrap().1);
        let mut effect = cli.effect.take().unwrap();
        effect.apply_palette(&palette, &skip);
        let config = decrypt_config(effect);
        assert_eq!(config.final_gradient_stops, vec![color("ffffff")]);
        assert_eq!(
            config.ciphertext_colors,
            vec![color("ff0000"), color("00ff00"), color("ff0000")]
        );
    }

    #[test]
    fn palette_new_rejects_empty() {
        assert!(Palette::new(Vec::new()).is_err());
    }
}
