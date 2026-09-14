//! ANSI escape sequences, ported from utils/ansitools.py + utils/colorterm.py.

use std::fmt::Write;

#[cfg(not(target_arch = "wasm32"))]
pub const DEC_SAVE_CURSOR: &str = "\x1b7";
#[cfg(not(target_arch = "wasm32"))]
pub const DEC_RESTORE_CURSOR: &str = "\x1b8";
#[cfg(not(target_arch = "wasm32"))]
pub const HIDE_CURSOR: &str = "\x1b[?25l";
#[cfg(not(target_arch = "wasm32"))]
pub const SHOW_CURSOR: &str = "\x1b[?25h";
#[cfg(not(target_arch = "wasm32"))]
pub const RESET_ALL: &str = "\x1b[0m";
#[cfg(not(target_arch = "wasm32"))]
pub const CLEAR_TO_END_OF_SCREEN: &str = "\x1b[0J";
#[cfg(not(target_arch = "wasm32"))]
pub const BOLD: &str = "\x1b[1m";
#[cfg(not(target_arch = "wasm32"))]
pub const DIM: &str = "\x1b[2m";
#[cfg(not(target_arch = "wasm32"))]
pub const ITALIC: &str = "\x1b[3m";
#[cfg(not(target_arch = "wasm32"))]
pub const UNDERLINE: &str = "\x1b[4m";
#[cfg(not(target_arch = "wasm32"))]
pub const BLINK: &str = "\x1b[5m";
#[cfg(not(target_arch = "wasm32"))]
pub const REVERSE: &str = "\x1b[7m";
#[cfg(not(target_arch = "wasm32"))]
pub const HIDDEN: &str = "\x1b[8m";
#[cfg(not(target_arch = "wasm32"))]
pub const STRIKETHROUGH: &str = "\x1b[9m";

#[cfg(not(target_arch = "wasm32"))]
pub fn move_cursor_up(y: usize) -> String {
    format!("\x1b[{y}A")
}

#[cfg(not(target_arch = "wasm32"))]
pub fn move_cursor_to_column(x: usize) -> String {
    format!("\x1b[{x}G")
}

/// A resolved color code ready for SGR emission: hex string => 24-bit, int => 8-bit.
/// Mirrors the str|int union threaded through colorterm/animation upstream.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum ColorCode {
    Rgb(String), // hex without '#', case preserved as upstream passes it
    Xterm(u8),
}

impl ColorCode {
    /// Packed 0xAARRGGBB with opaque alpha.
    pub fn rgb_u32(&self) -> u32 {
        let (r, g, b) = match self {
            ColorCode::Rgb(hex) => {
                let s = hex.trim_matches('#');
                (
                    u8::from_str_radix(&s[0..2], 16).unwrap_or(0),
                    u8::from_str_radix(&s[2..4], 16).unwrap_or(0),
                    u8::from_str_radix(&s[4..6], 16).unwrap_or(0),
                )
            }
            ColorCode::Xterm(n) => {
                let [r, g, b] = crate::utils::hexterm::xterm_rgb(*n);
                (r, g, b)
            }
        };
        0xFF000000 | ((r as u32) << 16) | ((g as u32) << 8) | (b as u32)
    }
}

/// Decimal digits of a byte, without going through core::fmt. Every restyled
/// character reassembles its SGR sequence, so the formatting machinery shows up
/// in profiles.
#[cfg(not(target_arch = "wasm32"))]
#[inline]
fn push_decimal(out: &mut String, value: u8) {
    if value >= 100 {
        out.push((b'0' + value / 100) as char);
    }
    if value >= 10 {
        out.push((b'0' + (value / 10) % 10) as char);
    }
    out.push((b'0' + value % 10) as char);
}

/// colorterm._color: fg selector 38, bg selector 48.
#[cfg(not(target_arch = "wasm32"))]
fn sgr_color(code: &ColorCode, location: u8, out: &mut String) {
    out.push_str("\x1b[");
    push_decimal(out, location);
    match code {
        ColorCode::Rgb(hex) => {
            let s = hex.trim_matches('#');
            let r = u8::from_str_radix(&s[0..2], 16).unwrap();
            let g = u8::from_str_radix(&s[2..4], 16).unwrap();
            let b = u8::from_str_radix(&s[4..6], 16).unwrap();
            out.push_str(";2;");
            push_decimal(out, r);
            out.push(';');
            push_decimal(out, g);
            out.push(';');
            push_decimal(out, b);
        }
        ColorCode::Xterm(n) => {
            out.push_str(";5;");
            push_decimal(out, *n);
        }
    }
    out.push('m');
}

#[cfg(not(target_arch = "wasm32"))]
pub fn fg(code: &ColorCode, out: &mut String) {
    sgr_color(code, 38, out);
}

#[cfg(not(target_arch = "wasm32"))]
pub fn bg(code: &ColorCode, out: &mut String) {
    sgr_color(code, 48, out);
}

/// ansitools.parse_ansi_color_sequence: strips `\x1b[` prefix and trailing `m`s,
/// recognizes 38;2/48;2 (24-bit, empty channels -> 0, UPPERCASE hex) and
/// 38;5/48;5 (8-bit). Anything else is an error.
pub fn parse_ansi_color_sequence(sequence: &str) -> Result<ColorCode, String> {
    let s = sequence
        .strip_prefix("\x1b[")
        .unwrap_or(sequence)
        .trim_matches('m');
    if let Some(rest) = s.strip_prefix("38;2").or_else(|| s.strip_prefix("48;2")) {
        // upstream strips "38;2;" (with semicolon); bare "38;2" leaves "" -> single empty field -> "00"
        let rest = rest.strip_prefix(';').unwrap_or(rest);
        let mut hex = String::new();
        for field in rest.split(';') {
            let v: i64 = if field.is_empty() {
                0
            } else {
                field.parse().map_err(|_| "Invalid ANSI color sequence".to_string())?
            };
            write!(hex, "{v:02X}").unwrap();
        }
        return Ok(ColorCode::Rgb(hex));
    }
    if let Some(rest) = s.strip_prefix("38;5").or_else(|| s.strip_prefix("48;5")) {
        let rest = rest.strip_prefix(';').unwrap_or(rest);
        let v: i64 = rest.parse().map_err(|_| "Invalid ANSI color sequence".to_string())?;
        return Ok(ColorCode::Xterm(v as u8));
    }
    Err("Invalid ANSI color sequence".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_24_bit() {
        assert_eq!(
            parse_ansi_color_sequence("\x1b[38;2;255;0;128m"),
            Ok(ColorCode::Rgb("FF0080".into()))
        );
        // empty channel normalized to 0 (upstream doc example: 38;2;;0m).
        // Note upstream's prefix regex eats "38;2;" so ";;0" leaves TWO fields
        // ("", "0") -> "0000", not three. Faithful, if odd.
        assert_eq!(
            parse_ansi_color_sequence("\x1b[38;2;;0m"),
            Ok(ColorCode::Rgb("0000".into()))
        );
    }

    #[test]
    fn parse_8_bit() {
        assert_eq!(parse_ansi_color_sequence("\x1b[48;5;42m"), Ok(ColorCode::Xterm(42)));
    }

    #[test]
    fn sgr_emission() {
        let mut s = String::new();
        fg(&ColorCode::Rgb("ff0080".into()), &mut s);
        assert_eq!(s, "\x1b[38;2;255;0;128m");
        s.clear();
        bg(&ColorCode::Xterm(42), &mut s);
        assert_eq!(s, "\x1b[48;5;42m");
    }
}
