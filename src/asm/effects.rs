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

    /// Single-codepoint symbols in the engine's packed format (UTF-8 bytes
    /// from the low byte up, the length in bits 32-39).
    fn symbols(&mut self, symbols: &[String]) -> Result<&mut Self, &'static str> {
        let mut packed = Vec::with_capacity(symbols.len());
        for symbol in symbols {
            if symbol.chars().count() != 1 {
                return Err("multi-codepoint symbols are not supported");
            }
            let bytes = symbol.as_bytes();
            let word = bytes.iter().enumerate().fold(0u64, |w, (i, &b)| w | (b as u64) << (8 * i));
            packed.push(word | (bytes.len() as u64) << 32);
        }
        Ok(self.array(packed))
    }

    /// A frame duration: the engine keeps durations and eased step totals in
    /// u32, so larger values (runs of years) go to the Rust engine.
    fn duration(&mut self, frames: i64) -> Result<&mut Self, &'static str> {
        if !(1..=1 << 24).contains(&frames) {
            return Err("frame durations above 2^24 are not supported");
        }
        Ok(self.int(frames))
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
        EffectCommand::Thunderstorm(c) => {
            // final_gradient_frames is accepted but unused upstream.
            w.color(&c.lightning_color)
                .color(&c.glowing_text_color)
                .duration(c.text_glow_time)?
                .symbols(&c.raindrop_symbols)?
                .symbols(&c.spark_symbols)?
                .color(&c.spark_glow_color)
                .duration(c.spark_glow_time)?
                .int(c.storm_time)
                .colors(&c.final_gradient_stops)
                .ints(&c.final_gradient_steps)
                .direction(c.final_gradient_direction);
            32
        }
        _ => return Err("this effect is not ported yet"),
    };
    Ok((id, w))
}
