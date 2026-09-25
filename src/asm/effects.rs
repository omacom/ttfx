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
        EffectCommand::Binarypath(c) => {
            w.colors(&c.final_gradient_stops)
                .ints(&c.final_gradient_steps)
                .direction(c.final_gradient_direction)
                .colors(&c.binary_colors)
                .float(c.movement_speed)
                .float(c.active_binary_groups);
            1
        }
        EffectCommand::Decrypt(c) => {
            w.int(c.typing_speed)
                .colors(&c.ciphertext_colors)
                .colors(&c.final_gradient_stops)
                .ints(&c.final_gradient_steps)
                .direction(c.final_gradient_direction);
            8
        }
        _ => return Err("this effect is not ported yet"),
    };
    Ok((id, w))
}
