//! Color, ColorPair, and Gradient, ported from utils/graphics.py.

use std::collections::HashMap;
use std::fmt;
use std::ops::Deref;

use crate::utils::geometry::{self, Coord};
use crate::utils::hexterm;
use crate::utils::pycompat::floor_div;
use crate::utils::rng::Rng;

/// The original constructor argument, preserved because upstream `Color.__eq__`
/// and `__hash__` compare `color_arg` — `Color(255) != Color("ffffff")` even
/// when they resolve to the same RGB. Dict/set keying depends on this.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ColorArg {
    Xterm(u8),
    Hex(RgbString), // stored stripped of '#', case preserved (upstream strips '#' only)
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub struct RgbString {
    bytes: [u8; 7],
    len: u8,
}

impl RgbString {
    fn new(value: &str) -> Self {
        debug_assert!(value.len() <= 7);
        let mut bytes = [0; 7];
        bytes[..value.len()].copy_from_slice(value.as_bytes());
        RgbString {
            bytes,
            len: value.len() as u8,
        }
    }

    fn from_rgb([r, g, b]: [u8; 3]) -> Self {
        const HEX: &[u8; 16] = b"0123456789abcdef";
        let mut bytes = [0; 7];
        bytes[0] = HEX[(r >> 4) as usize];
        bytes[1] = HEX[(r & 0x0f) as usize];
        bytes[2] = HEX[(g >> 4) as usize];
        bytes[3] = HEX[(g & 0x0f) as usize];
        bytes[4] = HEX[(b >> 4) as usize];
        bytes[5] = HEX[(b & 0x0f) as usize];
        RgbString { bytes, len: 6 }
    }
}

impl Deref for RgbString {
    type Target = str;

    fn deref(&self) -> &Self::Target {
        std::str::from_utf8(&self.bytes[..self.len as usize]).unwrap()
    }
}

impl AsRef<str> for RgbString {
    fn as_ref(&self) -> &str {
        self
    }
}

impl std::borrow::Borrow<str> for RgbString {
    fn borrow(&self) -> &str {
        self
    }
}

impl std::hash::Hash for RgbString {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        std::hash::Hash::hash(&**self, state);
    }
}

impl fmt::Display for RgbString {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self)
    }
}

impl fmt::Debug for RgbString {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Debug::fmt(&**self, f)
    }
}

#[derive(Clone, Copy)]
pub struct Color {
    pub color_arg: ColorArg,
    /// Some(code) when constructed from an xterm int, None for hex strings.
    pub xterm_color: Option<u8>,
    /// hex string without '#'
    pub rgb_color: RgbString,
    rgb: [u8; 3],
}

impl fmt::Debug for Color {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Color")
            .field("color_arg", &self.color_arg)
            .field("xterm_color", &self.xterm_color)
            .field("rgb_color", &self.rgb_color)
            .finish()
    }
}

impl PartialEq for Color {
    fn eq(&self, other: &Self) -> bool {
        self.color_arg == other.color_arg
    }
}
impl Eq for Color {}
impl std::hash::Hash for Color {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        self.color_arg.hash(state);
    }
}

impl Color {
    pub fn from_xterm(code: u8) -> Self {
        let rgb = hexterm::xterm_rgb(code);
        Color {
            color_arg: ColorArg::Xterm(code),
            xterm_color: Some(code),
            rgb,
            rgb_color: RgbString::from_rgb(rgb),
        }
    }

    /// Hex-string constructor. Errors mirror upstream ValueError.
    pub fn from_hex(hex: &str) -> Result<Self, String> {
        let stripped = hex.trim_matches('#');
        if !hexterm::is_valid_hex_color(stripped) {
            return Err(
                "Invalid color value. Color must be an XTerm-256 color code or an RGB hex color string. \
                 Example: 255 or 'ffffff' or '#ffffff'"
                    .to_string(),
            );
        }
        let rgb_color = RgbString::new(stripped);
        Ok(Color {
            color_arg: ColorArg::Hex(rgb_color),
            xterm_color: None,
            rgb: Self::parse_rgb(&rgb_color),
            rgb_color,
        })
    }

    pub fn rgb_ints(&self) -> (u8, u8, u8) {
        (self.rgb[0], self.rgb[1], self.rgb[2])
    }

    /// RGB constructor used by gradient generation. Same `color_arg` as a
    /// lowercase hex string, without going through `format!` / `from_hex`.
    pub fn from_rgb(r: u8, g: u8, b: u8) -> Self {
        let rgb = [r, g, b];
        let rgb_color = RgbString::from_rgb(rgb);
        Color {
            color_arg: ColorArg::Hex(rgb_color),
            xterm_color: None,
            rgb,
            rgb_color,
        }
    }

    fn parse_rgb(s: &str) -> [u8; 3] {
        [
            u8::from_str_radix(&s[0..2], 16).unwrap(),
            u8::from_str_radix(&s[2..4], 16).unwrap(),
            u8::from_str_radix(&s[4..6], 16).unwrap(),
        ]
    }
}

/// argutils.ColorArg: <=3 chars -> xterm int 0-255, else hex.
pub fn parse_color(s: &str) -> Result<Color, String> {
    if s.len() <= 3 {
        let code: u8 = s.parse().map_err(|_| format!("invalid color value: '{s}'"))?;
        Ok(Color::from_xterm(code))
    } else {
        Color::from_hex(s)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct ColorPair {
    pub fg_color: Option<Color>,
    pub bg_color: Option<Color>,
}

impl ColorPair {
    pub fn new(fg: Option<Color>, bg: Option<Color>) -> Self {
        ColorPair { fg_color: fg, bg_color: bg }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GradientDirection {
    Vertical,
    Horizontal,
    Radial,
    Diagonal,
}

/// Insertion-ordered Coord -> Color mapping (upstream returns a dict; iteration
/// order is Python dict insertion order, which some effects walk).
#[derive(Debug, Clone, Default)]
pub struct CoordColorMap {
    pub order: Vec<Coord>,
    map: HashMap<Coord, Color>,
}

impl CoordColorMap {
    fn insert(&mut self, coord: Coord, color: Color) {
        if self.map.insert(coord, color).is_none() {
            self.order.push(coord);
        }
    }

    pub fn get(&self, coord: &Coord) -> Option<&Color> {
        self.map.get(coord)
    }

    pub fn iter(&self) -> impl Iterator<Item = (Coord, &Color)> {
        self.order.iter().map(move |c| (*c, &self.map[c]))
    }
}

/// graphics.Gradient. The spectrum is NOT float lerp: channel deltas use
/// Python integer floor division and the exact end stop is appended per pair
/// (plan.md §5.2).
#[derive(Debug, Clone)]
pub struct Gradient {
    pub spectrum: Vec<Color>,
}

impl Gradient {
    /// Gradient(*stops, steps=...). `steps_was_int` mirrors the upstream quirk
    /// that only scalar (int) steps are validated before generation.
    pub fn new(stops: &[Color], steps: &[i64], steps_was_int: bool, do_loop: bool) -> Result<Self, String> {
        if stops.is_empty() {
            return Err("At least one stop must be provided.".to_string());
        }
        if steps_was_int {
            for &step in steps {
                if step < 1 {
                    return Err("Steps must be greater than 0.".to_string());
                }
            }
        }
        let mut spectrum: Vec<Color> = Vec::new();
        if stops.len() == 1 {
            for _ in 0..steps[0] {
                spectrum.push(stops[0].clone());
            }
            return Ok(Gradient { spectrum });
        }
        let mut stops: Vec<Color> = stops.to_vec();
        if do_loop {
            stops.push(stops[0].clone());
        }
        let pair_count = stops.len() - 1;
        let mut steps: Vec<i64> = steps[..steps.len().min(pair_count)].to_vec();
        while steps.len() < pair_count {
            steps.push(*steps.last().unwrap());
        }
        for (pair_index, step_count) in steps.iter().copied().enumerate() {
            if step_count < 1 {
                return Err(format!("Invalid steps: {step_count} | Steps must be greater than 0."));
            }
            let start = &stops[pair_index];
            let end = &stops[pair_index + 1];
            let (sr, sg, sb) = start.rgb_ints();
            let (er, eg, eb) = end.rgb_ints();
            let (sr, sg, sb) = (sr as i64, sg as i64, sb as i64);
            let red_delta = floor_div(er as i64 - sr, step_count);
            let green_delta = floor_div(eg as i64 - sg, step_count);
            let blue_delta = floor_div(eb as i64 - sb, step_count);
            let range_start = i64::from(!spectrum.is_empty());
            for i in range_start..step_count.max(0) {
                let red = (sr + red_delta * i).clamp(0, 255);
                let green = (sg + green_delta * i).clamp(0, 255);
                let blue = (sb + blue_delta * i).clamp(0, 255);
                spectrum.push(Color::from_rgb(red as u8, green as u8, blue as u8));
            }
            spectrum.push(end.clone());
        }
        Ok(Gradient { spectrum })
    }

    /// Convenience: single scalar step count (the common upstream call shape).
    pub fn with_steps(stops: &[Color], steps: i64, do_loop: bool) -> Result<Self, String> {
        Gradient::new(stops, &[steps], true, do_loop)
    }

    /// get_color_at_fraction: first i in 1..=len with fraction <= i/len.
    pub fn get_color_at_fraction(&self, fraction: f64) -> Result<&Color, String> {
        if !(0.0..=1.0).contains(&fraction) {
            return Err("Fraction must be 0 <= fraction <= 1.".to_string());
        }
        let len = self.spectrum.len();
        for i in 1..=len {
            if fraction <= i as f64 / len as f64 {
                return Ok(&self.spectrum[i - 1]);
            }
        }
        Ok(self.spectrum.last().unwrap())
    }

    /// build_coordinate_color_mapping with upstream's insertion order per direction.
    pub fn build_coordinate_color_mapping(
        &self,
        min_row: i64,
        max_row: i64,
        min_column: i64,
        max_column: i64,
        direction: GradientDirection,
    ) -> Result<CoordColorMap, String> {
        if max_row < 1 || max_column < 1 || min_row < 1 || min_column < 1 {
            return Err("max_row and max_column must be greater than 0.".to_string());
        }
        if min_row > max_row || min_column > max_column {
            return Err("min_row and min_column must be less than or equal to max_row and max_column.".to_string());
        }
        let row_offset = min_row - 1;
        let column_offset = min_column - 1;
        let mut mapping = CoordColorMap::default();
        match direction {
            GradientDirection::Vertical => {
                for row in min_row..=max_row {
                    let fraction = (row - row_offset) as f64 / (max_row - row_offset) as f64;
                    let color = self.get_color_at_fraction(fraction)?.clone();
                    for column in min_column..=max_column {
                        mapping.insert(Coord::new(column, row), color.clone());
                    }
                }
            }
            GradientDirection::Horizontal => {
                for column in min_column..=max_column {
                    let fraction = (column - column_offset) as f64 / (max_column - column_offset) as f64;
                    let color = self.get_color_at_fraction(fraction)?.clone();
                    for row in min_row..=max_row {
                        mapping.insert(Coord::new(column, row), color.clone());
                    }
                }
            }
            GradientDirection::Radial => {
                for row in min_row..=max_row {
                    for column in min_column..=max_column {
                        let distance = geometry::find_normalized_distance_from_center(
                            min_row,
                            max_row,
                            min_column,
                            max_column,
                            Coord::new(column, row),
                        )?;
                        let color = self.get_color_at_fraction(distance)?.clone();
                        mapping.insert(Coord::new(column, row), color);
                    }
                }
            }
            GradientDirection::Diagonal => {
                for row in min_row..=max_row {
                    for column in min_column..=max_column {
                        let fraction = (((row - row_offset) * 2) + (column - column_offset)) as f64
                            / (((max_row - row_offset) * 2) + (max_column - column_offset)) as f64;
                        let color = self.get_color_at_fraction(fraction)?.clone();
                        mapping.insert(Coord::new(column, row), color);
                    }
                }
            }
        }
        Ok(mapping)
    }
}

/// graphics.random_color.
pub fn random_color(rng: &mut Rng) -> Color {
    let n = rng.randint(0, 0xFFFFFF) as u32;
    Color::from_rgb(((n >> 16) & 0xff) as u8, ((n >> 8) & 0xff) as u8, (n & 0xff) as u8)
}

/// graphics.shift_color_towards: float lerp with int() TRUNCATION back to hex
/// (unlike adjust_color_brightness's round()). Negative components format
/// Python-style ("-3" not two's complement) so error conditions match.
pub fn shift_color_towards(color: &Color, target_color: &Color, factor: f64) -> Result<Color, String> {
    let interpolate = |start: f64, end: f64, factor: f64| start + (end - start) * factor;
    let norm = |c: &Color| {
        let (r, g, b) = c.rgb_ints();
        (r as f64 / 255.0, g as f64 / 255.0, b as f64 / 255.0)
    };
    let (cr, cg, cb) = norm(color);
    let (tr, tg, tb) = norm(target_color);
    let py_hex = |v: f64| {
        let i = (v * 255.0) as i64; // int() truncation
        if i < 0 {
            format!("-{:01x}", -i)
        } else {
            format!("{i:02x}")
        }
    };
    let hex = format!(
        "{}{}{}",
        py_hex(interpolate(cr, tr, factor)),
        py_hex(interpolate(cg, tg, factor)),
        py_hex(interpolate(cb, tb, factor))
    );
    Color::from_hex(&hex)
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use super::{parse_color, Color};

    #[test]
    fn rgb_string_borrowed_lookup_matches_str_hash() {
        let rgb = Color::from_hex("12AbEf7").unwrap().rgb_color;
        let mut colors = HashMap::new();
        colors.insert(rgb, 1);
        assert_eq!(colors.get("12AbEf7"), Some(&1));
    }

    #[test]
    fn color_debug_hides_the_cached_representation() {
        let color = Color::from_hex("12AbEf7").unwrap();
        assert_eq!(
            format!("{color:?}"),
            "Color { color_arg: Hex(\"12AbEf7\"), xterm_color: None, rgb_color: \"12AbEf7\" }"
        );
    }

    #[test]
    fn parse_color_accepts_xterm_codes_and_hex() {
        assert_eq!(parse_color("255").unwrap(), Color::from_xterm(255));
        assert_eq!(parse_color("12AbEf").unwrap(), Color::from_hex("12AbEf").unwrap());
        assert!(parse_color("not-a-color").is_err());
    }
}
