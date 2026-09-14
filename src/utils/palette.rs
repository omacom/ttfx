//! A list of hex colors that replace an effect's default colors.

use std::collections::HashSet;

use clap::parser::ValueSource;
use clap::ArgMatches;

use crate::utils::graphics::{parse_color, Color};

/// One or more colors used in place of each effect's default color arguments.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Palette {
    colors: Vec<Color>,
}

impl Palette {
    pub fn new(colors: Vec<Color>) -> Result<Self, String> {
        if colors.is_empty() {
            Err("palette must contain at least one hex color".to_string())
        } else {
            Ok(Palette { colors })
        }
    }

    pub fn from_hex_list(s: &str) -> Result<Self, String> {
        Self::new(parse_palette_arg(s)?)
    }

    pub fn colors(&self) -> &[Color] {
        &self.colors
    }

    pub fn color(&self, index: usize) -> Color {
        self.colors[index % self.colors.len()]
    }

    pub fn stops(&self, n: usize) -> Vec<Color> {
        (0..n).map(|i| self.color(i)).collect()
    }
}

/// Split a `--palette` value on commas and whitespace.
pub fn parse_palette_arg(s: &str) -> Result<Vec<Color>, String> {
    let mut colors = Vec::new();
    for part in s.split(|c: char| c == ',' || c.is_whitespace()) {
        if part.is_empty() {
            continue;
        }
        colors.push(parse_color(part)?);
    }
    if colors.is_empty() {
        Err("palette must contain at least one hex color".to_string())
    } else {
        Ok(colors)
    }
}

/// Clap ids the user set on the command line (so those color flags stay put).
pub fn command_line_arg_ids(matches: &ArgMatches) -> HashSet<String> {
    matches
        .ids()
        .filter(|id| matches.value_source(id.as_str()) == Some(ValueSource::CommandLine))
        .map(|id| id.as_str().to_string())
        .collect()
}

pub trait ApplyPalette {
    fn apply_palette(&mut self, palette: &Palette, skip: &HashSet<String>);
}

pub trait Recolor {
    fn recolor(&mut self, palette: &Palette, single_index: &mut usize);
}

impl Recolor for Color {
    fn recolor(&mut self, palette: &Palette, single_index: &mut usize) {
        *self = palette.color(*single_index);
        *single_index += 1;
    }
}

impl Recolor for Vec<Color> {
    fn recolor(&mut self, palette: &Palette, _single_index: &mut usize) {
        let n = self.len();
        if n == 0 {
            return;
        }
        *self = palette.stops(n);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn color(hex: &str) -> Color {
        parse_color(hex).expect("test hex")
    }

    #[test]
    fn parse_palette_arg_splits_commas_whitespace_and_hashes() {
        assert_eq!(
            parse_palette_arg("#7aa2f7, c0caf5\tf7768e").unwrap(),
            vec![color("#7aa2f7"), color("c0caf5"), color("f7768e")]
        );
    }

    #[test]
    fn parse_palette_arg_rejects_empty_and_invalid() {
        assert!(parse_palette_arg("").is_err());
        assert!(parse_palette_arg("  ,  ").is_err());
        assert!(parse_palette_arg("not-a-color").is_err());
        assert!(parse_palette_arg("ff0000,gg0000").is_err());
    }

    #[test]
    fn stops_cycle_when_the_list_is_short() {
        let palette = Palette::new(vec![color("ff0000"), color("00ff00")]).unwrap();
        assert_eq!(
            palette.stops(3),
            vec![color("ff0000"), color("00ff00"), color("ff0000")]
        );
        assert_eq!(palette.stops(1), vec![color("ff0000")]);
    }

    #[test]
    fn recolor_lists_use_the_full_palette_and_singles_advance() {
        let palette = Palette::new(vec![color("ff0000"), color("00ff00")]).unwrap();
        let mut list = vec![color("111111"), color("222222"), color("333333")];
        let mut first = color("aaaaaa");
        let mut second = color("bbbbbb");
        let mut index = 0usize;
        list.recolor(&palette, &mut index);
        first.recolor(&palette, &mut index);
        second.recolor(&palette, &mut index);
        assert_eq!(index, 2);
        assert_eq!(
            list,
            vec![color("ff0000"), color("00ff00"), color("ff0000")]
        );
        assert_eq!(first, color("ff0000"));
        assert_eq!(second, color("00ff00"));
    }
}
