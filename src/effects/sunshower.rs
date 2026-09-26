//! Sunshower: rain falls over the input while a sun rises, paints a rainbow
//! across the canvas, and leaves the text glowing in the same spectrum.

use std::collections::HashMap;

use clap::Args;

use crate::cli::parse_color;
use crate::effects::common::{parse_non_negative_int, parse_positive_float_range, parse_positive_int, parse_symbol};
use crate::engine::character::CharId;
use crate::engine::ctx::{EffectHooks, EngineCtx};
use crate::engine::effect::Effect;
use crate::engine::error::EngineError;
use crate::engine::events::EffectCallback;
use crate::engine::terminal::{CharacterFilter, CharacterSort};
use crate::utils::geometry::Coord;
use crate::utils::graphics::{shift_color_towards, Color, ColorPair};

#[derive(Args, Debug, Clone)]
pub struct SunshowerConfig {
    /// Number of independent raindrops in the shower.
    #[arg(long = "rain-density", default_value_t = 170, value_parser = parse_positive_int)]
    pub rain_density: i64,

    /// Falling speed range of the raindrops in cells per frame.
    #[arg(long = "rain-speed", default_value = "0.22-0.58", value_parser = parse_positive_float_range)]
    pub rain_speed: (f64, f64),

    /// Space separated list of symbols used for raindrops.
    #[arg(long = "rain-symbols", num_args = 1.., value_parser = parse_symbol,
          default_values = ["|", "/", ".", ","])]
    pub rain_symbols: Vec<String>,

    /// Space separated list of colors used for raindrops.
    #[arg(long = "rain-colors", num_args = 1.., value_parser = parse_color,
          default_values = ["3977a8", "55a6d9", "8bd3f7", "d4f1ff"])]
    pub rain_colors: Vec<Color>,

    /// Frame on which the sun begins to rise.
    #[arg(long = "sun-start", default_value_t = 75, value_parser = parse_non_negative_int)]
    pub sun_start: i64,

    /// Number of frames the sunrise takes.
    #[arg(long = "sunrise-duration", default_value_t = 95, value_parser = parse_positive_int)]
    pub sunrise_duration: i64,

    /// Color of the sun and its rays.
    #[arg(long = "sun-color", default_value = "ffd447", value_parser = parse_color)]
    pub sun_color: Color,

    /// Frame on which the rainbow begins to grow.
    #[arg(long = "rainbow-start", default_value_t = 150, value_parser = parse_non_negative_int)]
    pub rainbow_start: i64,

    /// Number of frames the rainbow takes to cross the canvas.
    #[arg(long = "rainbow-duration", default_value_t = 180, value_parser = parse_positive_int)]
    pub rainbow_duration: i64,

    /// Space separated colors for the rainbow, ordered outermost to innermost.
    #[arg(long = "rainbow-colors", num_args = 1.., value_parser = parse_color,
          default_values = ["ff3b30", "ff9500", "ffd60a", "34c759", "00b7ff", "5856d6", "af52de"])]
    pub rainbow_colors: Vec<Color>,

    /// Frames to hold the completed sunshower before the weather clears.
    #[arg(long = "hold-time", default_value_t = 90, value_parser = parse_non_negative_int)]
    pub hold_time: i64,

    /// Frames used to clear the rain, sun, and rainbow from the canvas.
    #[arg(long = "clear-duration", default_value_t = 75, value_parser = parse_positive_int)]
    pub clear_duration: i64,

    /// Frames to admire the rainbow-colored text after the sky clears.
    #[arg(long = "final-hold-time", default_value_t = 75, value_parser = parse_non_negative_int)]
    pub final_hold_time: i64,
}

struct Raindrop {
    id: CharId,
    column: i64,
    row: f64,
    speed: f64,
}

struct RainbowCell {
    id: CharId,
    reveal: f64,
}

struct Cloud {
    parts: Vec<(CharId, Coord)>,
    column: f64,
    row: i64,
    speed: f64,
}

struct Splash {
    id: CharId,
    column: i64,
    phase: i64,
    period: i64,
}

struct Sparkle {
    id: CharId,
    coord: Coord,
    phase: i64,
}

pub struct Sunshower {
    config: SunshowerConfig,
    rain: Vec<Raindrop>,
    sun: Vec<(CharId, Coord)>,
    clouds: Vec<Cloud>,
    splashes: Vec<Splash>,
    sparkles: Vec<Sparkle>,
    rainbow: Vec<RainbowCell>,
    text_colors: HashMap<CharId, Color>,
    text: Vec<CharId>,
    frame: i64,
    clear_start: i64,
    end_frame: i64,
}

impl Sunshower {
    pub fn new(config: SunshowerConfig) -> Self {
        Self {
            config,
            rain: Vec::new(),
            sun: Vec::new(),
            clouds: Vec::new(),
            splashes: Vec::new(),
            sparkles: Vec::new(),
            rainbow: Vec::new(),
            text_colors: HashMap::new(),
            text: Vec::new(),
            frame: 0,
            clear_start: 0,
            end_frame: 0,
        }
    }

    fn set_visual(ctx: &mut EngineCtx, id: CharId, symbol: &str, color: Color, bold: bool) {
        let uses_pre = ctx.terminal.arena[id.0 as usize].uses_input_preexisting_colors;
        ctx.terminal.arena[id.0 as usize].animation.set_appearance(
            symbol,
            uses_pre,
            Some(symbol),
            Some(ColorPair::new(Some(color), None)),
        );
        if bold {
            let visual = ctx.terminal.arena[id.0 as usize].animation.current_character_visual.clone();
            let params = crate::engine::animation::VisualParams {
                bold: true,
                colors: visual.colors,
                fg_color_code: visual.fg_color_code.clone(),
                bg_color_code: visual.bg_color_code.clone(),
                ..Default::default()
            };
            ctx.terminal.arena[id.0 as usize].animation.current_character_visual =
                crate::engine::animation::CharacterVisual::new(symbol, params).into();
        }
    }

    fn rainbow_color(&self, fraction: f64) -> Color {
        let index = (fraction.clamp(0.0, 0.999_999) * self.config.rainbow_colors.len() as f64) as usize;
        self.config.rainbow_colors[index.min(self.config.rainbow_colors.len() - 1)]
    }

    fn update_rain(&mut self, ctx: &mut EngineCtx) {
        let bottom = ctx.terminal.canvas.bottom;
        let top = ctx.terminal.canvas.top;
        let tapering = self.frame >= self.clear_start;
        let clear_progress = if tapering {
            ((self.frame - self.clear_start) as f64 / self.config.clear_duration as f64).clamp(0.0, 1.0)
        } else {
            0.0
        };
        for drop in &mut self.rain {
            let fallaway_order = ((drop.id.0.wrapping_mul(2654435761) % 1000) as f64) / 1000.0;
            if tapering && fallaway_order < clear_progress {
                ctx.terminal.set_character_visibility(drop.id, false);
                continue;
            }
            drop.row -= drop.speed;
            if drop.row < bottom as f64 {
                if tapering {
                    ctx.terminal.set_character_visibility(drop.id, false);
                    continue;
                }
                drop.column = ctx.terminal.canvas.random_column(&mut ctx.rng, false);
                drop.row = top as f64 + ctx.rng.uniform(0.0, 8.0);
                drop.speed = ctx.rng.uniform(self.config.rain_speed.0, self.config.rain_speed.1);
            }
            let coord = Coord::new(drop.column, drop.row.round() as i64);
            ctx.terminal.arena[drop.id.0 as usize].motion.set_coordinate(coord);
            ctx.terminal.set_character_visibility(drop.id, true);
        }
    }

    fn update_sun(&mut self, ctx: &mut EngineCtx) {
        if self.frame < self.config.sun_start {
            return;
        }
        let target = Coord::new(
            (ctx.terminal.canvas.right - 8).max(ctx.terminal.canvas.left + 4),
            (ctx.terminal.canvas.top - 5).max(ctx.terminal.canvas.bottom + 5),
        );
        // Begin with even the highest ray below the canvas so the complete
        // sun visibly rises through the bottom edge rather than popping in.
        let start_row = ctx.terminal.canvas.bottom - 7;
        let progress =
            ((self.frame - self.config.sun_start) as f64 / self.config.sunrise_duration as f64).clamp(0.0, 1.0);
        let eased = 1.0 - (1.0 - progress).powi(3);
        let mut center_row = start_row as f64 + (target.row - start_row) as f64 * eased;
        if self.frame >= self.clear_start {
            let clear = ((self.frame - self.clear_start) as f64 / self.config.clear_duration as f64).clamp(0.0, 1.0);
            center_row += clear * 7.0;
        }
        for &(id, offset) in &self.sun {
            let coord = Coord::new(target.column + offset.column, center_row.round() as i64 + offset.row);
            ctx.terminal.arena[id.0 as usize].motion.set_coordinate(coord);
            let is_ray = matches!(ctx.terminal.arena[id.0 as usize].input_symbol.as_str(), "|" | "/" | "\\" | "-");
            let twinkle = !is_ray || (self.frame + id.0 as i64) % 8 < 5;
            let clear_end = self.clear_start + self.config.clear_duration;
            ctx.terminal.set_character_visibility(
                id,
                self.frame < clear_end && clear_end - self.frame > offset.column.abs() && twinkle,
            );
        }
    }

    fn update_clouds(&mut self, ctx: &mut EngineCtx) {
        let clearing =
            ((self.frame - self.clear_start).max(0) as f64 / self.config.clear_duration as f64).clamp(0.0, 1.0);
        for cloud in &mut self.clouds {
            cloud.column += cloud.speed;
            if cloud.column > ctx.terminal.canvas.right as f64 + 12.0 {
                cloud.column = ctx.terminal.canvas.left as f64 - 12.0;
            }
            for &(id, offset) in &cloud.parts {
                let coord = Coord::new(cloud.column.round() as i64 + offset.column, cloud.row + offset.row);
                ctx.terminal.arena[id.0 as usize].motion.set_coordinate(coord);
                let order = ((id.0.wrapping_mul(97) % 100) as f64) / 100.0;
                ctx.terminal.set_character_visibility(id, order > clearing);
            }
        }
    }

    fn update_splashes(&mut self, ctx: &mut EngineCtx) {
        for splash in &self.splashes {
            let age = (self.frame + splash.phase) % splash.period;
            let active = self.frame < self.clear_start && age < 5;
            let (symbol, row) = match age {
                0 => ("·", ctx.terminal.canvas.bottom),
                1 | 2 => ("v", ctx.terminal.canvas.bottom + 1),
                _ => ("_", ctx.terminal.canvas.bottom),
            };
            ctx.terminal.arena[splash.id.0 as usize].motion.set_coordinate(Coord::new(splash.column, row));
            Self::set_visual(
                ctx,
                splash.id,
                symbol,
                self.config.rain_colors[2.min(self.config.rain_colors.len() - 1)],
                false,
            );
            ctx.terminal.set_character_visibility(splash.id, active);
        }
    }

    fn update_sparkles(&mut self, ctx: &mut EngineCtx) {
        let start = self.config.rainbow_start + self.config.rainbow_duration * 3 / 4;
        for sparkle in &self.sparkles {
            let age = self.frame - start + sparkle.phase;
            let pulse = age.rem_euclid(24);
            let active = self.frame >= start && self.frame <= self.end_frame && pulse < 9;
            let symbol = match pulse {
                0..=2 => ".",
                3..=5 => "+",
                _ => "*",
            };
            let fraction = (sparkle.coord.column - ctx.terminal.canvas.left) as f64
                / (ctx.terminal.canvas.right - ctx.terminal.canvas.left).max(1) as f64;
            Self::set_visual(ctx, sparkle.id, symbol, self.rainbow_color(fraction), true);
            ctx.terminal.set_character_visibility(sparkle.id, active);
        }
    }

    fn update_rainbow(&mut self, ctx: &mut EngineCtx) {
        if self.frame < self.config.rainbow_start {
            for cell in &self.rainbow {
                ctx.terminal.set_character_visibility(cell.id, false);
            }
            return;
        }
        let progress =
            ((self.frame - self.config.rainbow_start) as f64 / self.config.rainbow_duration as f64).clamp(0.0, 1.0);
        let clearing = if self.frame >= self.clear_start {
            ((self.frame - self.clear_start) as f64 / self.config.clear_duration as f64).clamp(0.0, 1.0)
        } else {
            0.0
        };
        for cell in &self.rainbow {
            let visible = cell.reveal <= progress && cell.reveal > clearing;
            ctx.terminal.set_character_visibility(cell.id, visible);
        }

        let left = ctx.terminal.canvas.text_left;
        let width = (ctx.terminal.canvas.text_right - left).max(1);
        for &id in &self.text {
            let coord = ctx.terminal.arena[id.0 as usize].input_coord;
            let reveal = (coord.column - left) as f64 / width as f64;
            if reveal <= progress {
                let symbol = ctx.terminal.arena[id.0 as usize].input_symbol.clone();
                Self::set_visual(ctx, id, &symbol, self.text_colors[&id], true);
            }
        }
    }
}

impl EffectHooks for Sunshower {
    fn dispatch_callback(&mut self, _ctx: &mut EngineCtx, _character: CharId, _callback: &EffectCallback) {}
}

impl Effect for Sunshower {
    fn build(&mut self, ctx: &mut EngineCtx) -> Result<(), EngineError> {
        let dim = Color::from_hex("526675").unwrap();
        self.text = ctx.terminal.get_characters(
            &mut ctx.rng,
            CharacterFilter::default(),
            CharacterSort::TopToBottomLeftToRight,
        );
        let left = ctx.terminal.canvas.text_left;
        let right = ctx.terminal.canvas.text_right;
        let bottom = ctx.terminal.canvas.text_bottom;
        let top = ctx.terminal.canvas.text_top;
        let width = (right - left).max(1);
        let height = (top - bottom).max(1);
        for &id in &self.text {
            let coord = ctx.terminal.arena[id.0 as usize].input_coord;
            let symbol = ctx.terminal.arena[id.0 as usize].input_symbol.clone();
            let diagonal =
                (((coord.column - left) as f64 / width as f64) + ((top - coord.row) as f64 / height as f64)) / 2.0;
            self.text_colors.insert(id, self.rainbow_color(diagonal));
            ctx.terminal.arena[id.0 as usize].layer = 5;
            Self::set_visual(ctx, id, &symbol, dim, false);
            ctx.terminal.set_character_visibility(id, true);
        }

        for _ in 0..self.config.rain_density {
            let column = ctx.terminal.canvas.random_column(&mut ctx.rng, false);
            let row = ctx.rng.uniform(bottom as f64, top as f64 + 8.0);
            let speed = ctx.rng.uniform(self.config.rain_speed.0, self.config.rain_speed.1);
            let symbol = ctx.rng.choice(&self.config.rain_symbols).clone();
            let color = *ctx.rng.choice(&self.config.rain_colors);
            let id = ctx.terminal.add_character(&symbol, Coord::new(column, row.round() as i64));
            ctx.terminal.arena[id.0 as usize].layer = 3;
            Self::set_visual(ctx, id, &symbol, color, false);
            self.rain.push(Raindrop { id, column, row, speed });
        }

        let sun_sprite = [
            ("|", 0, 5),
            ("/", -5, 4),
            ("\\", 5, 4),
            ("—", -7, 0),
            ("—", 7, 0),
            ("\\", -5, -4),
            ("/", 5, -4),
            ("|", 0, -5),
            ("▄", -2, 2),
            ("▄", -1, 2),
            ("▄", 0, 2),
            ("▄", 1, 2),
            ("▄", 2, 2),
            ("█", -3, 1),
            ("█", -2, 1),
            ("█", -1, 1),
            ("█", 0, 1),
            ("█", 1, 1),
            ("█", 2, 1),
            ("█", 3, 1),
            ("█", -3, 0),
            ("█", -2, 0),
            ("█", -1, 0),
            ("█", 0, 0),
            ("█", 1, 0),
            ("█", 2, 0),
            ("█", 3, 0),
            ("█", -3, -1),
            ("█", -2, -1),
            ("█", -1, -1),
            ("█", 0, -1),
            ("█", 1, -1),
            ("█", 2, -1),
            ("█", 3, -1),
            ("▀", -2, -2),
            ("▀", -1, -2),
            ("▀", 0, -2),
            ("▀", 1, -2),
            ("▀", 2, -2),
        ];
        for (symbol, dx, dy) in sun_sprite {
            let id = ctx.terminal.add_character(symbol, Coord::new(0, 0));
            ctx.terminal.arena[id.0 as usize].layer = 6;
            Self::set_visual(ctx, id, symbol, self.config.sun_color, true);
            self.sun.push((id, Coord::new(dx, dy)));
        }

        let cloud_sprite = [
            ("▄", -2, 2),
            ("▄", -1, 2),
            ("▄", 0, 2),
            ("▄", 1, 2),
            ("▒", -4, 1),
            ("▓", -3, 1),
            ("▓", -2, 1),
            ("▓", -1, 1),
            ("▓", 0, 1),
            ("▓", 1, 1),
            ("▓", 2, 1),
            ("▓", 3, 1),
            ("▒", 4, 1),
            ("▀", -6, 0),
            ("▀", -5, 0),
            ("▀", -4, 0),
            ("▀", -3, 0),
            ("▀", -2, 0),
            ("▀", -1, 0),
            ("▀", 0, 0),
            ("▀", 1, 0),
            ("▀", 2, 0),
            ("▀", 3, 0),
            ("▀", 4, 0),
            ("▀", 5, 0),
            ("▀", 6, 0),
        ];
        let cloud_color = Color::from_hex("a9bdca").unwrap();
        for index in 0..3 {
            let mut parts = Vec::new();
            for (symbol, dx, dy) in cloud_sprite {
                let id = ctx.terminal.add_character(symbol, Coord::new(0, 0));
                ctx.terminal.arena[id.0 as usize].layer = 4;
                Self::set_visual(ctx, id, symbol, cloud_color, symbol == "▓");
                parts.push((id, Coord::new(dx, dy)));
            }
            self.clouds.push(Cloud {
                parts,
                column: ctx.terminal.canvas.left as f64 - 8.0 + index as f64 * 31.0,
                row: ctx.terminal.canvas.top - 3 - (index % 2) as i64 * 4,
                speed: 0.035 + index as f64 * 0.014,
            });
        }

        for index in 0..48 {
            let column = ctx.terminal.canvas.random_column(&mut ctx.rng, false);
            let id = ctx.terminal.add_character("·", Coord::new(column, ctx.terminal.canvas.bottom));
            ctx.terminal.arena[id.0 as usize].layer = 4;
            self.splashes.push(Splash { id, column, phase: index * 7, period: 19 + index % 23 });
        }

        let center_col = (left + right) / 2;
        let base_row = bottom + 1;
        let outer_x = (width / 2).max(4);
        let outer_y = (outer_x / 2).min((height - 2).max(3));
        let colors = self.config.rainbow_colors.clone();
        let sky = Color::from_hex("12121a").unwrap();
        for (band, color) in colors.into_iter().enumerate() {
            let radius_x = (outer_x - band as i64 * 2).max(2);
            let radius_y = (outer_y - band as i64).max(1);
            for dx in -radius_x..=radius_x {
                if (dx + band as i64 * 2).rem_euclid(4) == 0 {
                    continue;
                }
                let normalized = dx as f64 / radius_x as f64;
                let dy = ((1.0 - normalized * normalized).max(0.0).sqrt() * radius_y as f64).round() as i64;
                let coord = Coord::new(center_col + dx, base_row + dy);
                if coord.column < ctx.terminal.canvas.left || coord.column > ctx.terminal.canvas.right {
                    continue;
                }
                let symbol = if (dx + band as i64).rem_euclid(2) == 0 { "░" } else { "·" };
                let transparent = shift_color_towards(&color, &sky, 0.14).unwrap();
                let id = ctx.terminal.add_character(symbol, coord);
                ctx.terminal.arena[id.0 as usize].layer = -1;
                Self::set_visual(ctx, id, symbol, transparent, false);
                self.rainbow.push(RainbowCell { id, reveal: (dx + radius_x) as f64 / (radius_x * 2).max(1) as f64 });
            }
        }

        for index in 0..42 {
            let coord = Coord::new(
                ctx.terminal.canvas.random_column(&mut ctx.rng, false),
                ctx.terminal.canvas.random_row(&mut ctx.rng, false),
            );
            let id = ctx.terminal.add_character(".", coord);
            ctx.terminal.arena[id.0 as usize].layer = 7;
            ctx.terminal.set_character_visibility(id, false);
            self.sparkles.push(Sparkle { id, coord, phase: index * 11 });
        }

        self.clear_start = self.config.rainbow_start + self.config.rainbow_duration + self.config.hold_time;
        self.end_frame = self.clear_start + self.config.clear_duration + self.config.final_hold_time;
        self.frame = 0;
        Ok(())
    }

    fn next_frame(&mut self, ctx: &mut EngineCtx) -> Option<String> {
        if self.frame > self.end_frame {
            return None;
        }
        self.update_rain(ctx);
        self.update_clouds(ctx);
        self.update_splashes(ctx);
        self.update_sun(ctx);
        self.update_rainbow(ctx);
        self.update_sparkles(ctx);
        self.frame += 1;
        Some(ctx.frame())
    }
}
