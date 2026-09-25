//! Effect configs as the assembly engine reads them: a flat array of 8-byte
//! words per effect, laid out exactly as the effect's `struc` in
//! asm/effects/<name>.asm. Lists become (pointer, length) word pairs pointing
//! into arrays that `Words` owns for the duration of the run.

use super::ffi::color_word;
use crate::effects::EffectCommand;
use crate::utils::easing::Easing;
use crate::utils::graphics::{Color, GradientDirection};

#[derive(Default)]
pub struct Words {
    words: Vec<u64>,
    arrays: Vec<Vec<u64>>,
}

#[allow(dead_code)] // helpers land as effects are ported
impl Words {
    pub fn as_ptr(&self) -> *const u64 {
        self.words.as_ptr()
    }

    fn int(&mut self, value: i64) -> &mut Self {
        self.words.push(value as u64);
        self
    }

    fn float(&mut self, value: f64) -> &mut Self {
        self.words.push(value.to_bits());
        self
    }

    fn flag(&mut self, value: bool) -> &mut Self {
        self.words.push(value as u64);
        self
    }

    fn color(&mut self, color: &Color) -> &mut Self {
        self.words.push(color_word(color));
        self
    }

    fn array(&mut self, values: Vec<u64>) -> &mut Self {
        // The heap buffer does not move when `arrays` grows, so the pointer
        // stays valid for as long as `self` lives.
        self.words.push(values.as_ptr() as u64);
        self.words.push(values.len() as u64);
        self.arrays.push(values);
        self
    }

    fn colors(&mut self, colors: &[Color]) -> &mut Self {
        self.array(colors.iter().map(color_word).collect())
    }

    fn ints(&mut self, values: &[i64]) -> &mut Self {
        self.array(values.iter().map(|&v| v as u64).collect())
    }

    fn easing(&mut self, easing: Easing) -> Result<&mut Self, &'static str> {
        Ok(self.int(easing.asm_id().ok_or("custom cubic bezier easing is not supported")?))
    }

    fn direction(&mut self, direction: GradientDirection) -> &mut Self {
        self.int(direction as i64)
    }
}

/// The effect's id (EffectCommand order, asm/effects/ids.inc) and its words,
/// or why the assembly engine cannot take it.
pub fn marshal(effect: &EffectCommand) -> Result<(u64, Words), &'static str> {
    let mut w = Words::default();
    let id = match effect {
        EffectCommand::Decrypt(c) => {
            w.int(c.typing_speed)
                .colors(&c.ciphertext_colors)
                .colors(&c.final_gradient_stops)
                .ints(&c.final_gradient_steps)
                .direction(c.final_gradient_direction);
            8
        }
        EffectCommand::Matrix(c) => {
            if c.final_gradient_frames > i32::MAX as i64 {
                return Err("--final-gradient-frames beyond i32 is not supported");
            }
            // Matrix compares colors (Color == compares the hex string as
            // given), so a hex color whose spelling differs from the one
            // Color::from_rgb would generate gets a tag in bits 48+ that
            // keeps it distinct from generated colors of the same RGB. The
            // renderer and color math only read bits 0-40.
            let mut spellings: Vec<String> = Vec::new();
            let mut tagged = |color: &Color| -> u64 {
                let word = color_word(color);
                let spelled = color.rgb_color.to_string();
                let (r, g, b) = color.rgb_ints();
                if color.xterm_color.is_some() || spelled == format!("{r:02x}{g:02x}{b:02x}") {
                    return word;
                }
                let index = spellings.iter().position(|s| *s == spelled).unwrap_or_else(|| {
                    spellings.push(spelled);
                    spellings.len() - 1
                });
                word | (index as u64 + 1) << 48
            };
            let highlight = tagged(&c.highlight_color);
            let rain: Vec<u64> = c.rain_color_gradient.iter().map(&mut tagged).collect();
            let symbols: Vec<u64> = c
                .rain_symbols
                .iter()
                .map(|s| {
                    let bytes = s.as_bytes();
                    let packed = bytes.iter().rev().fold(0u64, |acc, &b| acc << 8 | b as u64);
                    packed | (bytes.len() as u64) << 32
                })
                .collect();
            w.int(highlight as i64)
                .array(rain)
                .array(symbols)
                .int(c.rain_fall_delay_range.0)
                .int(c.rain_fall_delay_range.1)
                .int(c.rain_column_delay_range.0)
                .int(c.rain_column_delay_range.1)
                .int(c.rain_time)
                .float(c.symbol_swap_chance)
                .float(c.color_swap_chance)
                .int(c.resolve_delay)
                .colors(&c.final_gradient_stops)
                .ints(&c.final_gradient_steps)
                .int(c.final_gradient_frames)
                .direction(c.final_gradient_direction);
            14
        }
        _ => return Err("this effect is not ported yet"),
    };
    Ok((id, w))
}
