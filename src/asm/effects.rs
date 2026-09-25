//! Effect configs as the assembly engine reads them: a flat array of 8-byte
//! words per effect, laid out exactly as the effect's `struc` in
//! asm/effects/<name>.asm. Lists become (pointer, length) word pairs pointing
//! into arrays that `Words` owns for the duration of the run.

use super::ffi::color_word;
use crate::effects::EffectCommand;
use crate::utils::easing::Easing;
use crate::utils::graphics::{Color, Gradient, GradientDirection};

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

    /// A one-codepoint symbol packed as the engine's symbols are: the UTF-8
    /// bytes in the low bytes and the length in bits 32-39.
    fn symbol_word(symbol: &str) -> Result<u64, &'static str> {
        let bytes = symbol.as_bytes();
        if symbol.chars().count() != 1 {
            return Err("multi-codepoint symbols are not supported");
        }
        let packed = bytes.iter().rev().fold(0u64, |word, &b| word << 8 | b as u64);
        Ok(packed | (bytes.len() as u64) << 32)
    }

    fn symbol(&mut self, symbol: &str) -> Result<&mut Self, &'static str> {
        Ok(self.int(Self::symbol_word(symbol)? as i64))
    }

    fn symbols(&mut self, symbols: &[String]) -> Result<&mut Self, &'static str> {
        let words = symbols.iter().map(|s| Self::symbol_word(s)).collect::<Result<Vec<_>, _>>()?;
        Ok(self.array(words))
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
        EffectCommand::Blackhole(c) => {
            w.color(&c.blackhole_color)
                .colors(&c.star_colors)
                .colors(&c.final_gradient_stops)
                .ints(&c.final_gradient_steps)
                .direction(c.final_gradient_direction);
            2
        }
        EffectCommand::Bouncyballs(c) => {
            w.colors(&c.ball_colors)
                .symbols(&c.ball_symbols)?
                .int(c.ball_delay)
                .float(c.movement_speed)
                .easing(c.movement_easing)?
                .colors(&c.final_gradient_stops)
                .ints(&c.final_gradient_steps)
                .direction(c.final_gradient_direction);
            3
        }
        EffectCommand::Decrypt(c) => {
            w.int(c.typing_speed)
                .colors(&c.ciphertext_colors)
                .colors(&c.final_gradient_stops)
                .ints(&c.final_gradient_steps)
                .direction(c.final_gradient_direction);
            8
        }
        EffectCommand::Expand(c) => {
            w.easing(c.expand_easing)?
                .float(c.movement_speed)
                .colors(&c.final_gradient_stops)
                .ints(&c.final_gradient_steps)
                .direction(c.final_gradient_direction);
            10
        }
        EffectCommand::Fireworks(c) => {
            w.flag(c.explode_anywhere)
                .colors(&c.firework_colors)
                .symbol(&c.firework_symbol)?
                .float(c.firework_volume)
                .int(c.launch_delay)
                .float(c.explode_distance)
                .colors(&c.final_gradient_stops)
                .ints(&c.final_gradient_steps)
                .direction(c.final_gradient_direction);
            11
        }
        EffectCommand::Highlight(c) => {
            w.float(c.highlight_brightness)
                .int(c.highlight_direction as i64)
                .int(c.highlight_width)
                .colors(&c.final_gradient_stops)
                .ints(&c.final_gradient_steps)
                .direction(c.final_gradient_direction);
            12
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
        EffectCommand::Overflow(c) => {
            w.colors(&c.overflow_gradient_stops)
                .int(c.overflow_cycles_range.0)
                .int(c.overflow_cycles_range.1)
                .int(c.overflow_speed)
                .colors(&c.final_gradient_stops)
                .ints(&c.final_gradient_steps)
                .direction(c.final_gradient_direction);
            17
        }
        EffectCommand::Randomsequence(c) => {
            // frame durations are 32-bit in the engine
            let frames = i32::try_from(c.final_gradient_frames)
                .map_err(|_| "final gradient frames beyond 32 bits are not supported")?;
            w.float(c.speed)
                .colors(&c.final_gradient_stops)
                .ints(&c.final_gradient_steps)
                .int(frames as i64)
                .direction(c.final_gradient_direction);
            21
        }
        EffectCommand::Rings(c) => {
            w.colors(&c.ring_colors)
                .float(c.ring_gap)
                .int(c.spin_duration)
                .float(c.spin_speed.0)
                .float(c.spin_speed.1)
                .int(c.disperse_duration)
                .int(c.spin_disperse_cycles)
                .colors(&c.final_gradient_stops)
                .ints(&c.final_gradient_steps)
                .direction(c.final_gradient_direction);
            22
        }
        EffectCommand::Scattered(c) => {
            // frame durations are 32-bit in the engine
            if i32::try_from(c.final_gradient_frames).is_err() {
                return Err("final gradient frames out of range");
            }
            w.float(c.movement_speed)
                .easing(c.movement_easing)?
                .colors(&c.final_gradient_stops)
                .ints(&c.final_gradient_steps)
                .int(c.final_gradient_frames)
                .direction(c.final_gradient_direction);
            23
        }
        EffectCommand::Spray(c) => {
            w.int(c.spray_position as i64)
                .float(c.spray_volume)
                .float(c.movement_speed_range.0)
                .float(c.movement_speed_range.1)
                .easing(c.movement_easing)?
                .colors(&c.final_gradient_stops)
                .ints(&c.final_gradient_steps)
                .direction(c.final_gradient_direction);
            28
        }
        EffectCommand::Sweep(c) => {
            w.symbols(&c.sweep_symbols)?
                .int(c.first_sweep_direction as i64)
                .int(c.second_sweep_direction as i64)
                .colors(&c.final_gradient_stops)
                .ints(&c.final_gradient_steps)
                .direction(c.final_gradient_direction);
            30
        }
        EffectCommand::Synthgrid(c) => {
            w.colors(&c.grid_gradient_stops)
                .ints(&c.grid_gradient_steps)
                .direction(c.grid_gradient_direction)
                .colors(&c.text_gradient_stops)
                .ints(&c.text_gradient_steps)
                .direction(c.text_gradient_direction)
                .symbol(&c.grid_row_symbol)?
                .symbol(&c.grid_column_symbol)?
                .symbols(&c.text_generation_symbols)?
                .float(c.max_active_blocks);
            31
        }
        EffectCommand::Unstable(c) => {
            w.color(&c.unstable_color)
                .easing(c.explosion_ease)?
                .float(c.explosion_speed)
                .easing(c.reassembly_ease)?
                .float(c.reassembly_speed)
                .colors(&c.final_gradient_stops)
                .ints(&c.final_gradient_steps)
                .direction(c.final_gradient_direction);
            33
        }
        // glitch_wave_colors is never read by the effect
        EffectCommand::Vhstape(c) => {
            w.colors(&c.glitch_line_colors)
                .colors(&c.noise_colors)
                .float(c.glitch_line_chance)
                .float(c.noise_chance)
                .int(c.total_glitch_time)
                .colors(&c.final_gradient_stops)
                .ints(&c.final_gradient_steps)
                .direction(c.final_gradient_direction);
            34
        }
        EffectCommand::Waves(c) => {
            // Frame durations and the eased scene's step total are 32-bit in
            // the engine: each apply_gradient_to_symbols adds
            // max(symbols, spectrum) frames of wave_length ticks.
            let spectrum = Gradient::new(&c.wave_gradient_stops, &c.wave_gradient_steps, false, false)
                .map_err(|_| "invalid wave gradient")?
                .spectrum
                .len() as i64;
            let total = (c.wave_symbols.len() as i64)
                .max(spectrum)
                .checked_mul(c.wave_count)
                .and_then(|n| n.checked_mul(c.wave_length))
                .ok_or("wave scene too long")?;
            if total > i32::MAX as i64 {
                return Err("wave scene too long");
            }
            w.symbols(&c.wave_symbols)?
                .colors(&c.wave_gradient_stops)
                .ints(&c.wave_gradient_steps)
                .int(c.wave_count)
                .int(c.wave_length)
                .int(c.wave_direction as i64)
                .easing(c.wave_easing)?
                .colors(&c.final_gradient_stops)
                .ints(&c.final_gradient_steps)
                .direction(c.final_gradient_direction);
            35
        }
        EffectCommand::Wipe(c) => {
            // Frame durations are 32-bit in the engine; values below 1 still
            // reach it and fail like Rust.
            if i32::try_from(c.final_gradient_frames).is_err() {
                return Err("final gradient frames out of range");
            }
            w.int(c.wipe_direction as i64)
                .int(c.wipe_delay)
                .easing(c.wipe_ease)?
                .colors(&c.final_gradient_stops)
                .ints(&c.final_gradient_steps)
                .int(c.final_gradient_frames)
                .direction(c.final_gradient_direction);
            36
        }
        EffectCommand::Middleout(c) => {
            w.color(&c.starting_color)
                .int(c.expand_direction as i64)
                .float(c.center_movement_speed)
                .float(c.full_movement_speed)
                .easing(c.center_easing)?
                .easing(c.full_easing)?
                .colors(&c.final_gradient_stops)
                .ints(&c.final_gradient_steps)
                .direction(c.final_gradient_direction);
            15
        }
        EffectCommand::Rain(c) => {
            w.colors(&c.rain_colors)
                .float(c.movement_speed.0)
                .float(c.movement_speed.1)
                .symbols(&c.rain_symbols)?
                .colors(&c.final_gradient_stops)
                .ints(&c.final_gradient_steps)
                .direction(c.final_gradient_direction)
                .easing(c.movement_easing)?;
            20
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
        EffectCommand::Slice(c) => {
            let direction = match c.slice_direction.as_str() {
                "vertical" => 0,
                "horizontal" => 1,
                "diagonal" => 2,
                _ => return Err("unknown slice direction"),
            };
            w.int(direction)
                .float(c.movement_speed)
                .easing(c.movement_easing)?
                .colors(&c.final_gradient_stops)
                .ints(&c.final_gradient_steps)
                .direction(c.final_gradient_direction);
            24
        }
        EffectCommand::Colorshift(c) => {
            // frame durations are 32-bit in the engine
            let frames = i32::try_from(c.gradient_frames)
                .map_err(|_| "gradient frames beyond 32 bits are not supported")?;
            w.colors(&c.gradient_stops)
                .ints(&c.gradient_steps)
                .int(frames as i64)
                .flag(c.no_travel)
                .direction(c.travel_direction)
                .flag(c.reverse_travel_direction)
                .flag(c.no_loop)
                .int(c.cycles)
                .flag(c.skip_final_gradient)
                .colors(&c.final_gradient_stops)
                .ints(&c.final_gradient_steps)
                .direction(c.final_gradient_direction);
            6
        }
        EffectCommand::Pour(c) => {
            // frame durations are 32-bit in the engine; values below 1 still
            // reach it and fail like Rust
            if i32::try_from(c.final_gradient_frames).is_err() {
                return Err("final gradient frames out of range");
            }
            w.int(c.pour_direction as i64)
                .int(c.pour_speed)
                .float(c.movement_speed_range.0)
                .float(c.movement_speed_range.1)
                .int(c.gap)
                .color(&c.starting_color)
                .colors(&c.final_gradient_stops)
                .ints(&c.final_gradient_steps)
                .int(c.final_gradient_frames)
                .direction(c.final_gradient_direction)
                .easing(c.movement_easing)?;
            18
        }
        EffectCommand::Beams(c) => {
            if c.beam_gradient_frames > i32::MAX as i64 || c.final_gradient_frames > i32::MAX as i64 {
                return Err("beam frame durations exceed the assembly scene limit");
            }
            let symbols = |values: &[String]| -> Result<Vec<u64>, &'static str> {
                values.iter().map(|s| {
                    if s.chars().count() != 1 {
                        return Err("beam symbols must contain one codepoint");
                    }
                    let mut bytes = [0u8; 8];
                    bytes[..s.len()].copy_from_slice(s.as_bytes());
                    Ok(u64::from_le_bytes(bytes) | ((s.len() as u64) << 32))
                }).collect()
            };
            w.colors(&c.final_gradient_stops)
                .ints(&c.final_gradient_steps)
                .direction(c.final_gradient_direction)
                .array(symbols(&c.beam_row_symbols)?)
                .array(symbols(&c.beam_column_symbols)?)
                .int(c.beam_delay)
                .int(c.beam_row_speed_range.0).int(c.beam_row_speed_range.1)
                .int(c.beam_column_speed_range.0).int(c.beam_column_speed_range.1)
                .colors(&c.beam_gradient_stops).ints(&c.beam_gradient_steps)
                .int(c.beam_gradient_frames).int(c.final_gradient_frames)
                .int(c.final_wipe_speed);
            0
        }
        EffectCommand::Binarypath(c) => {
            w.colors(&c.final_gradient_stops)
                .ints(&c.final_gradient_steps)
                .direction(c.final_gradient_direction)
                .colors(&c.binary_colors)
                .float(c.movement_speed)
                .float(c.active_binary_groups);
            1
        }
        EffectCommand::Crumble(c) => {
            w.colors(&c.final_gradient_stops)
                .ints(&c.final_gradient_steps)
                .direction(c.final_gradient_direction);
            7
        }
        EffectCommand::Errorcorrect(c) => {
            w.float(c.error_pairs)
                .int(c.swap_delay)
                .color(&c.error_color)
                .color(&c.correct_color)
                .float(c.movement_speed)
                .colors(&c.final_gradient_stops)
                .ints(&c.final_gradient_steps)
                .direction(c.final_gradient_direction);
            9
        }
        EffectCommand::Print(c) => {
            w.float(c.print_head_return_speed)
                .int(c.print_speed)
                .easing(c.print_head_easing)?
                .colors(&c.final_gradient_stops)
                .ints(&c.final_gradient_steps)
                .direction(c.final_gradient_direction);
            19
        }
        EffectCommand::Bubbles(c) => {
            // movement_easing is never read upstream
            let pop_condition = match c.pop_condition {
                crate::effects::bubbles::PopCondition::Row => 0,
                crate::effects::bubbles::PopCondition::Bottom => 1,
                crate::effects::bubbles::PopCondition::Anywhere => 2,
            };
            w.flag(c.rainbow)
                .colors(&c.bubble_colors)
                .color(&c.pop_color)
                .float(c.bubble_speed)
                .int(c.bubble_delay)
                .int(pop_condition)
                .colors(&c.final_gradient_stops)
                .ints(&c.final_gradient_steps)
                .direction(c.final_gradient_direction);
            4
        }
        EffectCommand::Orbittingvolley(c) => {
            w.symbol(&c.top_launcher_symbol)?
                .symbol(&c.right_launcher_symbol)?
                .symbol(&c.bottom_launcher_symbol)?
                .symbol(&c.left_launcher_symbol)?
                .float(c.launcher_movement_speed)
                .float(c.character_movement_speed)
                .float(c.volley_size)
                .int(c.launch_delay)
                .easing(c.character_easing)?
                .colors(&c.final_gradient_stops)
                .ints(&c.final_gradient_steps)
                .direction(c.final_gradient_direction);
            16
        }
        _ => return Err("this effect is not ported yet"),
    };
    Ok((id, w))
}
