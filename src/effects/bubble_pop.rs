//! Bubble pop: iridescent bubbles float up through the canvas, burst over the
//! input, and reveal crisp rainbow lettering one sparkling patch at a time.

use std::collections::HashMap;

use clap::Args;

use crate::cli::parse_color;
use crate::effects::common::{parse_gradient_direction, parse_gradient_steps, parse_positive_int};
use crate::engine::character::CharId;
use crate::engine::ctx::{EffectHooks, EngineCtx};
use crate::engine::effect::Effect;
use crate::engine::error::EngineError;
use crate::engine::events::EffectCallback;
use crate::engine::terminal::{CharacterFilter, CharacterSort};
use crate::utils::geometry::Coord;
use crate::utils::graphics::{shift_color_towards, Color, ColorPair, Gradient, GradientDirection};

#[derive(Args, Debug, Clone)]
pub struct BubblePopConfig {
    /// Number of bubbles that rise and pop across the lettering.
    #[arg(long = "bubble-count", default_value_t = 28, value_parser = parse_positive_int)]
    pub bubble_count: i64,

    /// Frames each bubble spends floating up toward the text.
    #[arg(long = "rise-duration", default_value_t = 175, value_parser = parse_positive_int)]
    pub rise_duration: i64,

    /// Frames between successive bubble launches.
    #[arg(long = "launch-delay", default_value_t = 8, value_parser = parse_positive_int)]
    pub launch_delay: i64,

    /// Frames occupied by each sparkling pop.
    #[arg(long = "pop-duration", default_value_t = 24, value_parser = parse_positive_int)]
    pub pop_duration: i64,

    /// Frames to admire the completed text after the last bubbles clear.
    #[arg(long = "final-hold-time", default_value_t = 105, value_parser = parse_positive_int)]
    pub final_hold_time: i64,

    /// Rainbow colors that travel around the bubble rims.
    #[arg(long = "bubble-colors", num_args = 1.., value_parser = parse_color,
          default_values = ["ff3b8d", "ff7a18", "ffe14a", "50e991", "36d9ff", "6384ff", "b45cff"])]
    pub bubble_colors: Vec<Color>,

    /// Bright reflection color on the bubbles and their pops.
    #[arg(long = "highlight-color", default_value = "ffffff", value_parser = parse_color)]
    pub highlight_color: Color,

    /// Space separated colors for the final readable text.
    #[arg(long = "final-gradient-stops", num_args = 1.., value_parser = parse_color,
          default_values = ["ff3b8d", "ff9f1c", "ffe66d", "4de8a5", "35d8ff", "7386ff", "c65cff"])]
    pub final_gradient_stops: Vec<Color>,

    /// Number of steps in the final text gradient.
    #[arg(long = "final-gradient-steps", num_args = 1.., value_parser = parse_gradient_steps,
          default_values = ["30"])]
    pub final_gradient_steps: Vec<i64>,

    /// Direction of the final text gradient.
    #[arg(long = "final-gradient-direction", default_value = "diagonal", value_parser = parse_gradient_direction)]
    pub final_gradient_direction: GradientDirection,
}

struct BubblePart {
    id: CharId,
    offset: Coord,
    symbol: &'static str,
    highlight: bool,
}

struct Bubble {
    parts: Vec<BubblePart>,
    target: Coord,
    start_x: f64,
    start_y: f64,
    launch: i64,
    pop: i64,
    sway: f64,
    phase: f64,
    color_offset: usize,
}

struct PopSpark {
    id: CharId,
    bubble: usize,
    dx: f64,
    dy: f64,
    color_offset: usize,
}

pub struct BubblePop {
    config: BubblePopConfig,
    bubbles: Vec<Bubble>,
    sparks: Vec<PopSpark>,
    text: Vec<CharId>,
    text_colors: HashMap<CharId, Color>,
    text_reveal: HashMap<CharId, i64>,
    frame: i64,
    final_start: i64,
    end_frame: i64,
}

impl BubblePop {
    pub fn new(config: BubblePopConfig) -> Self {
        Self {
            config,
            bubbles: Vec::new(),
            sparks: Vec::new(),
            text: Vec::new(),
            text_colors: HashMap::new(),
            text_reveal: HashMap::new(),
            frame: 0,
            final_start: 0,
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

    fn sprite(size: usize) -> Vec<(Coord, &'static str, bool)> {
        match size {
            0 => vec![(Coord::new(0, 0), "◯", true)],
            1 => vec![
                (Coord::new(-1, 1), "╭", false),
                (Coord::new(0, 1), "─", true),
                (Coord::new(1, 1), "╮", false),
                (Coord::new(-2, 0), "(", false),
                (Coord::new(0, 0), "°", true),
                (Coord::new(2, 0), ")", false),
                (Coord::new(-1, -1), "╰", false),
                (Coord::new(0, -1), "─", false),
                (Coord::new(1, -1), "╯", false),
            ],
            _ => vec![
                (Coord::new(-2, 2), "╭", false),
                (Coord::new(-1, 2), "─", true),
                (Coord::new(0, 2), "─", true),
                (Coord::new(1, 2), "─", false),
                (Coord::new(2, 2), "╮", false),
                (Coord::new(-3, 1), "╱", false),
                (Coord::new(3, 1), "╲", false),
                (Coord::new(-4, 0), "(", false),
                (Coord::new(-1, 0), "°", true),
                (Coord::new(4, 0), ")", false),
                (Coord::new(-3, -1), "╲", false),
                (Coord::new(3, -1), "╱", false),
                (Coord::new(-2, -2), "╰", false),
                (Coord::new(-1, -2), "─", false),
                (Coord::new(0, -2), "─", false),
                (Coord::new(1, -2), "─", false),
                (Coord::new(2, -2), "╯", false),
            ],
        }
    }

    fn update_bubbles(&self, ctx: &mut EngineCtx) {
        let black = Color::from_hex("070b18").unwrap();
        for (index, bubble) in self.bubbles.iter().enumerate() {
            let age = self.frame - bubble.launch;
            let visible = age >= 0 && self.frame < bubble.pop;
            if !visible {
                for part in &bubble.parts {
                    ctx.terminal.set_character_visibility(part.id, false);
                }
                continue;
            }

            let progress = (age as f64 / self.config.rise_duration as f64).clamp(0.0, 1.0);
            let eased = 1.0 - (1.0 - progress).powi(3);
            let sway = (age as f64 * 0.055 + bubble.phase).sin() * bubble.sway * (0.72 + progress * 0.28);
            let center_x = bubble.start_x + (bubble.target.column as f64 - bubble.start_x) * eased + sway;
            let center_y = bubble.start_y + (bubble.target.row as f64 - bubble.start_y) * eased;
            let excitement = self.frame >= bubble.pop - 18;

            for (part_index, part) in bubble.parts.iter().enumerate() {
                let coord =
                    Coord::new(center_x.round() as i64 + part.offset.column, center_y.round() as i64 + part.offset.row);
                ctx.terminal.arena[part.id.0 as usize].motion.set_coordinate(coord);
                let traveling = ((self.frame / 4) as usize + bubble.color_offset + part_index * 2)
                    % self.config.bubble_colors.len();
                let base = self.config.bubble_colors[traveling];
                let gleam = part.highlight || (self.frame as usize + part_index * 7 + index * 3) % 29 < 2;
                let color = if gleam {
                    shift_color_towards(&base, &self.config.highlight_color, if excitement { 0.92 } else { 0.70 })
                        .unwrap()
                } else {
                    shift_color_towards(&base, &black, 0.12).unwrap()
                };
                Self::set_visual(ctx, part.id, part.symbol, color, gleam || excitement);
                ctx.terminal.set_character_visibility(part.id, true);
            }
        }
    }

    fn update_sparks(&self, ctx: &mut EngineCtx) {
        for spark in &self.sparks {
            let bubble = &self.bubbles[spark.bubble];
            let age = self.frame - bubble.pop;
            if age < 0 || age > self.config.pop_duration {
                ctx.terminal.set_character_visibility(spark.id, false);
                continue;
            }
            let progress = age as f64 / self.config.pop_duration as f64;
            let distance = (1.0 - (1.0 - progress).powi(2)) * 1.16;
            let coord = Coord::new(
                (bubble.target.column as f64 + spark.dx * distance).round() as i64,
                (bubble.target.row as f64 + spark.dy * distance).round() as i64,
            );
            ctx.terminal.arena[spark.id.0 as usize].motion.set_coordinate(coord);
            let color_index = (spark.color_offset + (self.frame / 3) as usize) % self.config.bubble_colors.len();
            let base = self.config.bubble_colors[color_index];
            let color = shift_color_towards(&base, &self.config.highlight_color, (1.0 - progress) * 0.62).unwrap();
            let symbol = if progress < 0.22 {
                "✦"
            } else if progress < 0.58 {
                "•"
            } else {
                "·"
            };
            Self::set_visual(ctx, spark.id, symbol, color, progress < 0.45);
            ctx.terminal.set_character_visibility(spark.id, true);
        }
    }

    fn update_text(&self, ctx: &mut EngineCtx) {
        for &id in &self.text {
            let reveal = self.text_reveal[&id];
            if self.frame < reveal {
                ctx.terminal.set_character_visibility(id, false);
                continue;
            }
            let age = self.frame - reveal;
            let symbol = ctx.terminal.arena[id.0 as usize].input_symbol.clone();
            let twinkle = age < 5 || (self.frame >= self.final_start && (self.frame + id.0 as i64 * 11) % 67 < 2);
            if age < 5 {
                Self::set_visual(ctx, id, "✦", self.config.highlight_color, true);
            } else {
                let color = if twinkle { self.config.highlight_color } else { self.text_colors[&id] };
                Self::set_visual(ctx, id, &symbol, color, true);
            }
            ctx.terminal.set_character_visibility(id, true);
        }
    }
}

impl EffectHooks for BubblePop {
    fn dispatch_callback(&mut self, _ctx: &mut EngineCtx, _character: CharId, _callback: &EffectCallback) {}
}

impl Effect for BubblePop {
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

        let non_space: Vec<Coord> = self
            .text
            .iter()
            .filter(|&&id| ctx.terminal.arena[id.0 as usize].input_symbol != " ")
            .map(|&id| ctx.terminal.arena[id.0 as usize].input_coord)
            .collect();
        for &id in &self.text {
            let coord = ctx.terminal.arena[id.0 as usize].input_coord;
            self.text_colors.insert(id, *mapping.get(&coord).expect("bubble-pop gradient coordinate"));
            ctx.terminal.arena[id.0 as usize].layer = 6;
            ctx.terminal.set_character_visibility(id, false);
        }

        let count = (self.config.bubble_count as usize).min(non_space.len().max(1));
        let fallback = Coord::new(
            (ctx.terminal.canvas.text_left + ctx.terminal.canvas.text_right) / 2,
            (ctx.terminal.canvas.text_bottom + ctx.terminal.canvas.text_top) / 2,
        );
        for index in 0..count {
            let sample = if non_space.is_empty() {
                fallback
            } else {
                non_space[((index * non_space.len()) / count + index * 17) % non_space.len()]
            };
            let target = Coord::new(
                (sample.column + ctx.rng.randint(-3, 3)).clamp(ctx.terminal.canvas.left, ctx.terminal.canvas.right),
                (sample.row + ctx.rng.randint(-1, 1)).clamp(ctx.terminal.canvas.bottom, ctx.terminal.canvas.top),
            );
            let launch = index as i64 * self.config.launch_delay;
            let pop = launch + self.config.rise_duration + ctx.rng.randint(-12, 12);
            let size = if index % 7 == 0 {
                2
            } else if index % 3 == 0 {
                1
            } else {
                0
            };
            let mut parts = Vec::new();
            for (offset, symbol, highlight) in Self::sprite(size) {
                let id = ctx.terminal.add_character(symbol, Coord::new(target.column, ctx.terminal.canvas.bottom - 4));
                ctx.terminal.arena[id.0 as usize].layer = 4;
                ctx.terminal.set_character_visibility(id, false);
                parts.push(BubblePart { id, offset, symbol, highlight });
            }
            self.bubbles.push(Bubble {
                parts,
                target,
                start_x: (target.column + ctx.rng.randint(-14, 14)) as f64,
                start_y: (ctx.terminal.canvas.bottom - 4 - size as i64) as f64,
                launch,
                pop,
                sway: ctx.rng.uniform(1.4, 4.2),
                phase: ctx.rng.uniform(0.0, std::f64::consts::TAU),
                color_offset: index * 3 % self.config.bubble_colors.len(),
            });
        }

        for bubble_index in 0..self.bubbles.len() {
            for spark_index in 0..14 {
                let angle = spark_index as f64 / 14.0 * std::f64::consts::TAU + ctx.rng.uniform(-0.12, 0.12);
                let reach = if spark_index % 3 == 0 { ctx.rng.uniform(6.0, 9.0) } else { ctx.rng.uniform(3.0, 6.5) };
                let id = ctx.terminal.add_character("✦", self.bubbles[bubble_index].target);
                ctx.terminal.arena[id.0 as usize].layer = 7;
                ctx.terminal.set_character_visibility(id, false);
                self.sparks.push(PopSpark {
                    id,
                    bubble: bubble_index,
                    dx: angle.cos() * reach,
                    dy: angle.sin() * reach * 0.52,
                    color_offset: bubble_index * 3 + spark_index,
                });
            }
        }

        let last_pop = self.bubbles.iter().map(|bubble| bubble.pop).max().unwrap_or(self.config.rise_duration);
        for &id in &self.text {
            let coord = ctx.terminal.arena[id.0 as usize].input_coord;
            let reveal = self
                .bubbles
                .iter()
                .min_by_key(|bubble| {
                    let dx = (coord.column - bubble.target.column).abs();
                    let dy = (coord.row - bubble.target.row).abs();
                    dx * dx + dy * dy * 3
                })
                .map(|bubble| {
                    let dx = (coord.column - bubble.target.column).abs();
                    let dy = (coord.row - bubble.target.row).abs();
                    bubble.pop + (dx + dy * 2).min(10) * 2
                })
                .unwrap_or(last_pop);
            self.text_reveal.insert(id, reveal);
        }
        self.final_start = last_pop + self.config.pop_duration + 24;
        self.end_frame = self.final_start + self.config.final_hold_time;
        self.frame = 0;
        Ok(())
    }

    fn next_frame(&mut self, ctx: &mut EngineCtx) -> Option<String> {
        if self.frame > self.end_frame {
            return None;
        }
        self.update_bubbles(ctx);
        self.update_sparks(ctx);
        self.update_text(ctx);
        self.frame += 1;
        Some(ctx.frame())
    }
}
