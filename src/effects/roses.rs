//! Roses: curling vines climb through the canvas, layered pink roses bloom,
//! petals drift, and the input flowers into a rose-gold gradient.

use std::collections::HashMap;

use clap::Args;

use crate::cli::parse_color;
use crate::effects::common::{
    parse_gradient_direction, parse_gradient_steps, parse_non_negative_int, parse_positive_int,
};
use crate::engine::character::CharId;
use crate::engine::ctx::{EffectHooks, EngineCtx};
use crate::engine::effect::Effect;
use crate::engine::error::EngineError;
use crate::engine::events::EffectCallback;
use crate::engine::terminal::{CharacterFilter, CharacterSort};
use crate::utils::geometry::Coord;
use crate::utils::graphics::{shift_color_towards, Color, ColorPair, Gradient, GradientDirection};

#[derive(Args, Debug, Clone)]
pub struct RosesConfig {
    /// Frames the two flowering vines take to climb the canvas.
    #[arg(long = "vine-duration", default_value_t = 180, value_parser = parse_positive_int)]
    pub vine_duration: i64,

    /// Frame on which the first rosebud begins to open.
    #[arg(long = "bloom-start", default_value_t = 95, value_parser = parse_non_negative_int)]
    pub bloom_start: i64,

    /// Frames each rose takes to unfurl all of its petals.
    #[arg(long = "bloom-duration", default_value_t = 85, value_parser = parse_positive_int)]
    pub bloom_duration: i64,

    /// Frames between successive rose blooms.
    #[arg(long = "bloom-delay", default_value_t = 20, value_parser = parse_non_negative_int)]
    pub bloom_delay: i64,

    /// Number of petals that drift from the completed garden.
    #[arg(long = "falling-petals", default_value_t = 72, value_parser = parse_positive_int)]
    pub falling_petals: i64,

    /// Frame on which the lettering begins to flower into color.
    #[arg(long = "text-bloom-start", default_value_t = 285, value_parser = parse_non_negative_int)]
    pub text_bloom_start: i64,

    /// Frames used for the sparkling text reveal.
    #[arg(long = "text-bloom-duration", default_value_t = 155, value_parser = parse_positive_int)]
    pub text_bloom_duration: i64,

    /// Frames to hold the completed rose garden.
    #[arg(long = "final-hold-time", default_value_t = 105, value_parser = parse_non_negative_int)]
    pub final_hold_time: i64,

    /// Space separated greens used by stems and leaves.
    #[arg(long = "vine-colors", num_args = 1.., value_parser = parse_color,
          default_values = ["14532d", "15803d", "22c55e", "86efac"])]
    pub vine_colors: Vec<Color>,

    /// Space separated pinks from the outer petals to the glowing center.
    #[arg(long = "rose-colors", num_args = 1.., value_parser = parse_color,
          default_values = ["831843", "be185d", "ec4899", "fb7185", "fbcfe8"])]
    pub rose_colors: Vec<Color>,

    /// Space separated colors for the final readable text.
    #[arg(long = "final-gradient-stops", num_args = 1.., value_parser = parse_color,
          default_values = ["f43f5e", "ec4899", "f9a8d4", "fde68a", "fff1f2"])]
    pub final_gradient_stops: Vec<Color>,

    /// Number of steps in the final text gradient.
    #[arg(long = "final-gradient-steps", num_args = 1.., value_parser = parse_gradient_steps,
          default_values = ["24"])]
    pub final_gradient_steps: Vec<i64>,

    /// Direction of the final text gradient.
    #[arg(long = "final-gradient-direction", default_value = "diagonal", value_parser = parse_gradient_direction)]
    pub final_gradient_direction: GradientDirection,

    /// Dim color of the lettering before it blooms.
    #[arg(long = "shadow-color", default_value = "263b32", value_parser = parse_color)]
    pub shadow_color: Color,
}

struct VineCell {
    id: CharId,
    reveal: f64,
    leaf: bool,
    side: usize,
}

struct RosePetal {
    id: CharId,
    offset: Coord,
    stage: f64,
    color_index: usize,
    center: bool,
}

struct Rose {
    center: Coord,
    petals: Vec<RosePetal>,
    start: i64,
}

struct FallingPetal {
    id: CharId,
    origin: Coord,
    born: i64,
    lifetime: i64,
    drift: f64,
    fall_speed: f64,
    phase: f64,
    color_index: usize,
}

pub struct Roses {
    config: RosesConfig,
    vines: Vec<VineCell>,
    roses: Vec<Rose>,
    falling_petals: Vec<FallingPetal>,
    text: Vec<CharId>,
    text_colors: HashMap<CharId, Color>,
    text_reveal: HashMap<CharId, f64>,
    frame: i64,
    end_frame: i64,
}

impl Roses {
    pub fn new(config: RosesConfig) -> Self {
        Self {
            config,
            vines: Vec::new(),
            roses: Vec::new(),
            falling_petals: Vec::new(),
            text: Vec::new(),
            text_colors: HashMap::new(),
            text_reveal: HashMap::new(),
            frame: 0,
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

    fn vine_coord(ctx: &EngineCtx, side: usize, t: f64) -> Coord {
        let left = ctx.terminal.canvas.left;
        let right = ctx.terminal.canvas.right;
        let bottom = ctx.terminal.canvas.bottom;
        let top = ctx.terminal.canvas.top;
        let width = (right - left).max(1) as f64;
        let height = (top - bottom).max(1) as f64;
        let amplitude = (width / 12.0).clamp(3.0, 7.0);
        let wave = (t * std::f64::consts::TAU * 1.75 + side as f64 * 1.4).sin() * amplitude;
        let column = if side == 0 {
            left as f64 + 4.0 + t * width * 0.28 + wave
        } else {
            right as f64 - 4.0 - t * width * 0.28 - wave
        };
        Coord::new(column.round() as i64, (bottom as f64 + t * height).round() as i64)
    }

    fn update_vines(&self, ctx: &mut EngineCtx) {
        let progress = (self.frame as f64 / self.config.vine_duration as f64).clamp(0.0, 1.0);
        for vine in &self.vines {
            if vine.reveal > progress {
                ctx.terminal.set_character_visibility(vine.id, false);
                continue;
            }
            let pulse = ((self.frame / 18) as usize + vine.side) % self.config.vine_colors.len();
            let color = self.config.vine_colors[pulse];
            let input_symbol = ctx.terminal.arena[vine.id.0 as usize].input_symbol.clone();
            let symbol = if vine.leaf && (self.frame + vine.id.0 as i64) % 28 < 14 {
                if vine.side == 0 {
                    ")"
                } else {
                    "("
                }
            } else {
                &input_symbol
            };
            Self::set_visual(ctx, vine.id, symbol, color, vine.leaf);
            ctx.terminal.set_character_visibility(vine.id, true);
        }
    }

    fn update_roses(&self, ctx: &mut EngineCtx) {
        for rose in &self.roses {
            let progress = ((self.frame - rose.start) as f64 / self.config.bloom_duration as f64).clamp(0.0, 1.0);
            for petal in &rose.petals {
                if self.frame < rose.start || progress < petal.stage {
                    ctx.terminal.set_character_visibility(petal.id, false);
                    continue;
                }
                let local = ((progress - petal.stage) / (1.0 - petal.stage).max(0.01)).clamp(0.0, 1.0);
                let eased = 1.0 - (1.0 - local).powi(3);
                let coord = Coord::new(
                    rose.center.column + (petal.offset.column as f64 * eased).round() as i64,
                    rose.center.row + (petal.offset.row as f64 * eased).round() as i64,
                );
                ctx.terminal.arena[petal.id.0 as usize].motion.set_coordinate(coord);
                let shimmer = if progress >= 1.0 && (self.frame + petal.id.0 as i64) % 41 < 3 { 1 } else { 0 };
                let color_index = (petal.color_index + shimmer).min(self.config.rose_colors.len() - 1);
                let symbol = if petal.center {
                    "✦"
                } else if local < 0.45 {
                    "•"
                } else {
                    "●"
                };
                Self::set_visual(ctx, petal.id, symbol, self.config.rose_colors[color_index], true);
                ctx.terminal.set_character_visibility(petal.id, true);
            }
        }
    }

    fn update_falling_petals(&self, ctx: &mut EngineCtx) {
        for petal in &self.falling_petals {
            let age = self.frame - petal.born;
            if age < 0 || age >= petal.lifetime {
                ctx.terminal.set_character_visibility(petal.id, false);
                continue;
            }
            let t = age as f64;
            let sway = (t * 0.13 + petal.phase).sin() * 2.2;
            let coord = Coord::new(
                (petal.origin.column as f64 + petal.drift * t + sway).round() as i64,
                (petal.origin.row as f64 - petal.fall_speed * t).round() as i64,
            );
            ctx.terminal.arena[petal.id.0 as usize].motion.set_coordinate(coord);
            let ratio = age as f64 / petal.lifetime as f64;
            let symbol = if ratio < 0.70 { "♥" } else { "·" };
            let color_index =
                (petal.color_index + (ratio * 2.0).floor() as usize).min(self.config.rose_colors.len() - 1);
            Self::set_visual(ctx, petal.id, symbol, self.config.rose_colors[color_index], true);
            ctx.terminal.set_character_visibility(petal.id, true);
        }
    }

    fn update_text(&self, ctx: &mut EngineCtx) {
        let progress = ((self.frame - self.config.text_bloom_start) as f64 / self.config.text_bloom_duration as f64)
            .clamp(0.0, 1.0);
        let white = Color::from_hex("ffffff").unwrap();
        for &id in &self.text {
            let symbol = ctx.terminal.arena[id.0 as usize].input_symbol.clone();
            if self.frame < self.config.text_bloom_start {
                Self::set_visual(ctx, id, &symbol, self.config.shadow_color, false);
                ctx.terminal.set_character_visibility(id, true);
                continue;
            }
            let start = self.text_reveal[&id] * 0.62;
            let local = ((progress - start) / 0.38).clamp(0.0, 1.0);
            if local <= 0.0 {
                continue;
            }
            if local < 0.16 {
                Self::set_visual(ctx, id, "✦", white, true);
            } else {
                let color_progress = ((local - 0.16) / 0.84).clamp(0.0, 1.0);
                let color = shift_color_towards(
                    &self.config.rose_colors[1.min(self.config.rose_colors.len() - 1)],
                    &self.text_colors[&id],
                    1.0 - (1.0 - color_progress).powi(3),
                )
                .unwrap();
                Self::set_visual(ctx, id, &symbol, color, true);
            }
            ctx.terminal.set_character_visibility(id, true);
        }
    }
}

impl EffectHooks for Roses {
    fn dispatch_callback(&mut self, _ctx: &mut EngineCtx, _character: CharId, _callback: &EffectCallback) {}
}

impl Effect for Roses {
    fn build(&mut self, ctx: &mut EngineCtx) -> Result<(), EngineError> {
        self.text = ctx.terminal.get_characters(
            &mut ctx.rng,
            CharacterFilter::default(),
            CharacterSort::TopToBottomLeftToRight,
        );
        let gradient =
            Gradient::new(&self.config.final_gradient_stops, &self.config.final_gradient_steps, false, false)
                .map_err(EngineError::Other)?;
        let mapping = gradient
            .build_coordinate_color_mapping(
                ctx.terminal.canvas.text_bottom,
                ctx.terminal.canvas.text_top,
                ctx.terminal.canvas.text_left,
                ctx.terminal.canvas.text_right,
                self.config.final_gradient_direction,
            )
            .map_err(EngineError::Other)?;
        let text_width = (ctx.terminal.canvas.text_right - ctx.terminal.canvas.text_left).max(1) as f64;
        let text_height = (ctx.terminal.canvas.text_top - ctx.terminal.canvas.text_bottom).max(1) as f64;
        for &id in &self.text {
            let coord = ctx.terminal.arena[id.0 as usize].input_coord;
            let symbol = ctx.terminal.arena[id.0 as usize].input_symbol.clone();
            ctx.terminal.arena[id.0 as usize].layer = 6;
            self.text_colors.insert(id, *mapping.get(&coord).expect("rose gradient coordinate"));
            let diagonal = ((coord.column - ctx.terminal.canvas.text_left) as f64 / text_width
                + (ctx.terminal.canvas.text_top - coord.row) as f64 / text_height)
                / 2.0;
            let jitter = (id.0.wrapping_mul(89) % 100) as f64 / 1000.0;
            self.text_reveal.insert(id, (diagonal + jitter).min(1.0));
            Self::set_visual(ctx, id, &symbol, self.config.shadow_color, false);
            ctx.terminal.set_character_visibility(id, true);
        }

        let steps = ((ctx.terminal.canvas.top - ctx.terminal.canvas.bottom).max(1) * 4) as usize;
        let mut rose_centers = Vec::new();
        for side in 0..2 {
            let mut previous = Self::vine_coord(ctx, side, 0.0);
            for step in 0..=steps {
                let t = step as f64 / steps.max(1) as f64;
                let coord = Self::vine_coord(ctx, side, t);
                let dx = coord.column - previous.column;
                let symbol = if dx > 0 {
                    "/"
                } else if dx < 0 {
                    "\\"
                } else {
                    "│"
                };
                let id = ctx.terminal.add_character(symbol, coord);
                ctx.terminal.arena[id.0 as usize].layer = 2;
                Self::set_visual(ctx, id, symbol, self.config.vine_colors[0], false);
                ctx.terminal.set_character_visibility(id, false);
                self.vines.push(VineCell { id, reveal: t * 0.92, leaf: false, side });
                if step % 13 == 7 {
                    let leaf_coord = Coord::new(coord.column + if side == 0 { 1 } else { -1 }, coord.row);
                    let leaf_symbol = if side == 0 { ")" } else { "(" };
                    let leaf_id = ctx.terminal.add_character(leaf_symbol, leaf_coord);
                    ctx.terminal.arena[leaf_id.0 as usize].layer = 2;
                    Self::set_visual(
                        ctx,
                        leaf_id,
                        leaf_symbol,
                        self.config.vine_colors[2.min(self.config.vine_colors.len() - 1)],
                        true,
                    );
                    ctx.terminal.set_character_visibility(leaf_id, false);
                    self.vines.push(VineCell { id: leaf_id, reveal: t * 0.92 + 0.025, leaf: true, side });
                }
                previous = coord;
            }
            for &t in &[0.22, 0.43, 0.65, 0.86] {
                rose_centers.push(Self::vine_coord(ctx, side, t));
            }
        }

        let petal_layout: [(i64, i64, f64, usize, bool); 23] = [
            (0, 0, 0.00, 4, true),
            (-1, 0, 0.16, 3, false),
            (1, 0, 0.16, 3, false),
            (0, 1, 0.16, 3, false),
            (0, -1, 0.16, 3, false),
            (-1, 1, 0.31, 2, false),
            (1, 1, 0.31, 2, false),
            (-1, -1, 0.31, 2, false),
            (1, -1, 0.31, 2, false),
            (-2, 0, 0.48, 1, false),
            (2, 0, 0.48, 1, false),
            (0, 2, 0.48, 1, false),
            (0, -2, 0.48, 1, false),
            (-2, 1, 0.58, 0, false),
            (-2, -1, 0.58, 0, false),
            (2, 1, 0.58, 0, false),
            (2, -1, 0.58, 0, false),
            (-1, 2, 0.64, 0, false),
            (1, 2, 0.64, 0, false),
            (-1, -2, 0.64, 0, false),
            (1, -2, 0.64, 0, false),
            (-3, 0, 0.72, 0, false),
            (3, 0, 0.72, 0, false),
        ];
        for (index, &center) in rose_centers.iter().enumerate() {
            let mut petals = Vec::new();
            for &(dx, dy, stage, color_index, is_center) in &petal_layout {
                let id = ctx.terminal.add_character("•", center);
                ctx.terminal.arena[id.0 as usize].layer = 4;
                Self::set_visual(
                    ctx,
                    id,
                    "•",
                    self.config.rose_colors[color_index.min(self.config.rose_colors.len() - 1)],
                    true,
                );
                ctx.terminal.set_character_visibility(id, false);
                petals.push(RosePetal {
                    id,
                    offset: Coord::new(dx, dy),
                    stage,
                    color_index: color_index.min(self.config.rose_colors.len() - 1),
                    center: is_center,
                });
            }
            self.roses.push(Rose {
                center,
                petals,
                start: self.config.bloom_start + index as i64 * self.config.bloom_delay,
            });
        }

        let mut last_petal_death = 0;
        for index in 0..self.config.falling_petals {
            let rose_index = index as usize % self.roses.len();
            let wave = index as usize / self.roses.len();
            let rose = &self.roses[rose_index];
            let born = rose.start + self.config.bloom_duration + wave as i64 * 13;
            let lifetime = ctx.rng.randint(120, 181);
            let id = ctx.terminal.add_character("♥", rose.center);
            ctx.terminal.arena[id.0 as usize].layer = 5;
            ctx.terminal.set_character_visibility(id, false);
            self.falling_petals.push(FallingPetal {
                id,
                origin: rose.center,
                born,
                lifetime,
                drift: ctx.rng.uniform(-0.045, 0.045),
                fall_speed: ctx.rng.uniform(0.055, 0.12),
                phase: ctx.rng.uniform(0.0, std::f64::consts::TAU),
                color_index: ctx.rng.randint(1, self.config.rose_colors.len() as i64) as usize,
            });
            last_petal_death = last_petal_death.max(born + lifetime);
        }

        let text_end = self.config.text_bloom_start + self.config.text_bloom_duration;
        let last_bloom = self.roses.last().map(|rose| rose.start + self.config.bloom_duration).unwrap_or(0);
        self.end_frame = text_end.max(last_bloom).max(last_petal_death) + self.config.final_hold_time;
        self.frame = 0;
        Ok(())
    }

    fn next_frame(&mut self, ctx: &mut EngineCtx) -> Option<String> {
        if self.frame > self.end_frame {
            return None;
        }
        self.update_vines(ctx);
        self.update_roses(ctx);
        self.update_falling_petals(ctx);
        self.update_text(ctx);
        self.frame += 1;
        Some(ctx.frame())
    }
}
