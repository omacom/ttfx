//! ANSI escape sequences, ported from utils/ansitools.py + utils/colorterm.py.

use std::cell::{Cell, RefCell};
use std::fmt::Write;
use std::rc::Rc;

use crate::utils::hexterm;

// --- Live color transforms ----------------------------------------------------
// A current-thread color transform controlled by the embedding render loop.
// Embedders may update it once per frame from live inputs such as audio brightness
// and hue rotation. CharacterVisual applies it at emission time, so cached scenes
// react on the next frame. Identity when disabled or quiet.
/// Current-thread RGB transform applied when styled visuals are emitted.
pub type ColorTransform = Rc<dyn Fn(u8, u8, u8) -> (u8, u8, u8)>;

thread_local! {
    static AUDIO_COLOR: Cell<(bool, f32, [f32; 9])> =
        const { Cell::new((false, 1.0, [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0])) };
    static COLOR_TRANSFORM: RefCell<Option<ColorTransform>> = const { RefCell::new(None) };
}

/// Replace or disable the current thread's selective render-time transform.
/// Cached scenes are restyled when emitted on that thread.
pub fn set_color_transform(transform: Option<ColorTransform>) {
    COLOR_TRANSFORM.with(|slot| *slot.borrow_mut() = transform);
}

/// Set this frame's current-thread audio transform. `brightness` multiplies RGB;
/// `matrix` is a row-major 3x3 hue rotation. `active=false` bypasses it.
pub fn set_audio_color(active: bool, brightness: f32, matrix: [f32; 9]) {
    AUDIO_COLOR.with(|c| c.set((active, brightness, matrix)));
}

#[inline]
fn recolor(r: u8, g: u8, b: u8) -> (u8, u8, u8) {
    // Clone the Rc and drop the RefCell borrow before invoking user code. A
    // callback may therefore replace/disable itself without a borrow panic.
    let transform = COLOR_TRANSFORM.with(|slot| slot.borrow().clone());
    let (r, g, b) = match transform {
        Some(transform) => transform(r, g, b),
        None => (r, g, b),
    };
    let (active, bright, m) = AUDIO_COLOR.with(|c| c.get());
    if !active { return (r, g, b); }
    let (r, g, b) = (r as f32, g as f32, b as f32);
    let rr = (m[0] * r + m[1] * g + m[2] * b) * bright;
    let gg = (m[3] * r + m[4] * g + m[5] * b) * bright;
    let bb = (m[6] * r + m[7] * g + m[8] * b) * bright;
    (rr.clamp(0.0, 255.0) as u8, gg.clamp(0.0, 255.0) as u8, bb.clamp(0.0, 255.0) as u8)
}

#[inline]
pub(crate) fn transforms_active() -> bool {
    COLOR_TRANSFORM.with(|slot| slot.borrow().is_some()) || AUDIO_COLOR.with(|c| c.get().0)
}


pub const DEC_SAVE_CURSOR: &str = "\x1b7";
pub const DEC_RESTORE_CURSOR: &str = "\x1b8";
pub const HIDE_CURSOR: &str = "\x1b[?25l";
pub const SHOW_CURSOR: &str = "\x1b[?25h";
pub const RESET_ALL: &str = "\x1b[0m";
pub const CLEAR_TO_END_OF_SCREEN: &str = "\x1b[0J";
pub const BOLD: &str = "\x1b[1m";
pub const DIM: &str = "\x1b[2m";
pub const ITALIC: &str = "\x1b[3m";
pub const UNDERLINE: &str = "\x1b[4m";
pub const BLINK: &str = "\x1b[5m";
pub const REVERSE: &str = "\x1b[7m";
pub const HIDDEN: &str = "\x1b[8m";
pub const STRIKETHROUGH: &str = "\x1b[9m";

pub fn move_cursor_up(y: usize) -> String {
    format!("\x1b[{y}A")
}

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

/// Decimal digits of a byte, without going through core::fmt. Every restyled
/// character reassembles its SGR sequence, so the formatting machinery shows up
/// in profiles.
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
fn sgr_color(code: &ColorCode, location: u8, out: &mut String, live_transform: bool) {
    out.push_str("\x1b[");
    push_decimal(out, location);
    match code {
        ColorCode::Rgb(hex) => {
            let s = hex.trim_matches('#');
            let r = u8::from_str_radix(&s[0..2], 16).unwrap();
            let g = u8::from_str_radix(&s[2..4], 16).unwrap();
            let b = u8::from_str_radix(&s[4..6], 16).unwrap();
            let (r, g, b) = if live_transform { recolor(r, g, b) } else { (r, g, b) };
            out.push_str(";2;");
            push_decimal(out, r);
            out.push(';');
            push_decimal(out, g);
            out.push(';');
            push_decimal(out, b);
        }
        ColorCode::Xterm(n) => {
            if live_transform && transforms_active() {
                let hex = hexterm::xterm_to_hex(*n);
                let r = u8::from_str_radix(&hex[0..2], 16).unwrap();
                let g = u8::from_str_radix(&hex[2..4], 16).unwrap();
                let b = u8::from_str_radix(&hex[4..6], 16).unwrap();
                let (r, g, b) = recolor(r, g, b);
                let mapped = hexterm::rgb_to_xterm(r, g, b);
                out.push_str(";5;");
                push_decimal(out, mapped);
            } else {
                out.push_str(";5;"); push_decimal(out, *n);
            }
        }
    }
    out.push('m');
}

pub fn fg(code: &ColorCode, out: &mut String) { sgr_color(code, 38, out, true); }
pub fn bg(code: &ColorCode, out: &mut String) { sgr_color(code, 48, out, true); }
pub(crate) fn fg_raw(code: &ColorCode, out: &mut String) { sgr_color(code, 38, out, false); }
pub(crate) fn bg_raw(code: &ColorCode, out: &mut String) { sgr_color(code, 48, out, false); }

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

    #[test]
    fn live_transform_preserves_xterm_indexed_sgr() {
        set_color_transform(Some(Rc::new(|r, g, b| (r / 2, g / 2, b / 2))));
        let mut s = String::new();
        fg(&ColorCode::Xterm(196), &mut s); // canonical xterm red = ff0000
        assert_eq!(s, "\x1b[38;5;1m");
        set_color_transform(None);
    }

    #[test]
    fn selective_transform_composes_before_audio_transform() {
        set_color_transform(Some(Rc::new(|_, _, _| (100, 200, 50))));
        set_audio_color(true, 0.5, [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]);
        let mut s = String::new();
        fg(&ColorCode::Rgb("ffffff".into()), &mut s);
        assert_eq!(s, "\x1b[38;2;50;100;25m");
        set_audio_color(false, 1.0, [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]);
        set_color_transform(None);
    }

    #[test]
    fn transform_may_disable_itself_without_refcell_panic() {
        set_color_transform(Some(Rc::new(|r, g, b| {
            set_color_transform(None);
            (r, g, b)
        })));
        let mut first = String::new();
        fg(&ColorCode::Rgb("123456".into()), &mut first);
        let mut second = String::new();
        fg(&ColorCode::Rgb("123456".into()), &mut second);
        assert_eq!(first, second);
        assert!(!transforms_active());
    }
}
