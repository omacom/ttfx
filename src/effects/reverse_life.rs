//! Reverse Life: use the input glyphs as a Conway's Game of Life seed,
//! simulate forward, then play the generations backward into readable text.

use std::collections::HashMap;

use clap::Args;

use crate::cli::parse_color;
use crate::effects::common::{
    parse_gradient_direction, parse_gradient_steps, parse_non_negative_int, parse_positive_int, parse_symbol,
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
pub struct ReverseLifeConfig {
    /// Number of Conway generations to simulate before playing them backward.
    #[arg(long = "simulation-steps", default_value_t = 52, value_parser = parse_positive_int)]
    pub simulation_steps: i64,

    /// Frames to display each reversed generation.
    #[arg(long = "generation-time", default_value_t = 4, value_parser = parse_positive_int)]
    pub generation_time: i64,

    /// Frames to hold the most evolved, chaotic generation.
    #[arg(long = "chaos-hold-time", default_value_t = 65, value_parser = parse_non_negative_int)]
    pub chaos_hold_time: i64,

    /// Frames used to exchange the final cell silhouette for the original glyphs.
    #[arg(long = "resolve-duration", default_value_t = 150, value_parser = parse_positive_int)]
    pub resolve_duration: i64,

    /// Frames to hold the readable final text.
    #[arg(long = "final-hold-time", default_value_t = 85, value_parser = parse_non_negative_int)]
    pub final_hold_time: i64,

    /// Space separated symbols used for living cells.
    #[arg(long = "cell-symbols", num_args = 1.., value_parser = parse_symbol,
          default_values = ["◆", "✦", "•"])]
    pub cell_symbols: Vec<String>,

    /// Space separated colors applied smoothly across the living cell field.
    #[arg(long = "cell-colors", num_args = 1.., value_parser = parse_color,
          default_values = ["075985", "0891b2", "22d3ee", "a78bfa"])]
    pub cell_colors: Vec<Color>,

    /// Space separated colors for the final readable text gradient.
    #[arg(long = "final-gradient-stops", num_args = 1.., value_parser = parse_color,
          default_values = ["22d3ee", "a78bfa", "f8fafc"])]
    pub final_gradient_stops: Vec<Color>,

    /// Number of steps in the final text gradient.
    #[arg(long = "final-gradient-steps", num_args = 1.., value_parser = parse_gradient_steps,
          default_values = ["18"])]
    pub final_gradient_steps: Vec<i64>,

    /// Direction of the final text gradient.
    #[arg(long = "final-gradient-direction", default_value = "diagonal", value_parser = parse_gradient_direction)]
    pub final_gradient_direction: GradientDirection,
}

pub struct ReverseLife {
    config: ReverseLifeConfig,
    snapshots: Vec<Vec<bool>>,
    grid: Vec<CharId>,
    text: Vec<CharId>,
    text_colors: HashMap<CharId, Color>,
    width: usize,
    frame: i64,
    reverse_end: i64,
    resolve_end: i64,
    end_frame: i64,
}

impl ReverseLife {
    pub fn new(config: ReverseLifeConfig) -> Self {
        Self {
            config,
            snapshots: Vec::new(),
            grid: Vec::new(),
            text: Vec::new(),
            text_colors: HashMap::new(),
            width: 0,
            frame: 0,
            reverse_end: 0,
            resolve_end: 0,
            end_frame: 0,
        }
    }

    fn set_visual(ctx: &mut EngineCtx, id: CharId, symbol: &str, color: Color) {
        let uses_pre = ctx.terminal.arena[id.0 as usize].uses_input_preexisting_colors;
        ctx.terminal.arena[id.0 as usize].animation.set_appearance(
            symbol,
            uses_pre,
            Some(symbol),
            Some(ColorPair::new(Some(color), None)),
        );
    }

    fn life_step(current: &[bool], width: usize, height: usize) -> Vec<bool> {
        let mut next = vec![false; current.len()];
        for row in 0..height {
            for column in 0..width {
                let mut neighbors = 0;
                for row_offset in -1_i64..=1 {
                    for column_offset in -1_i64..=1 {
                        if row_offset == 0 && column_offset == 0 {
                            continue;
                        }
                        let other_row = row as i64 + row_offset;
                        let other_column = column as i64 + column_offset;
                        if other_row >= 0
                            && other_row < height as i64
                            && other_column >= 0
                            && other_column < width as i64
                            && current[other_row as usize * width + other_column as usize]
                        {
                            neighbors += 1;
                        }
                    }
                }
                let index = row * width + column;
                next[index] = neighbors == 3 || (current[index] && neighbors == 2);
            }
        }
        next
    }

    fn display_snapshot(&self, ctx: &mut EngineCtx, snapshot_index: usize) {
        let snapshot = &self.snapshots[snapshot_index];
        for (index, &id) in self.grid.iter().enumerate() {
            let alive = snapshot[index];
            let trailing = if snapshot_index + 1 < self.snapshots.len() {
                let end = (snapshot_index + 5).min(self.snapshots.len());
                self.snapshots[snapshot_index + 1..end].iter().any(|ghost| ghost[index])
            } else {
                let start = snapshot_index.saturating_sub(4);
                self.snapshots[start..snapshot_index].iter().any(|ghost| ghost[index])
            };
            if alive {
                let symbol_index = (index + snapshot_index / 3) % self.config.cell_symbols.len();
                let column = index % self.width;
                let color_index = (column * self.config.cell_colors.len() / self.width.max(1) + snapshot_index / 4)
                    % self.config.cell_colors.len();
                Self::set_visual(
                    ctx,
                    id,
                    &self.config.cell_symbols[symbol_index],
                    self.config.cell_colors[color_index],
                );
            } else if trailing {
                Self::set_visual(ctx, id, "·", self.config.cell_colors[0]);
            }
            ctx.terminal.set_character_visibility(id, alive || trailing);
        }
    }
}

impl EffectHooks for ReverseLife {
    fn dispatch_callback(&mut self, _ctx: &mut EngineCtx, _character: CharId, _callback: &EffectCallback) {}
}

impl Effect for ReverseLife {
    fn build(&mut self, ctx: &mut EngineCtx) -> Result<(), EngineError> {
        let left = ctx.terminal.canvas.left;
        let right = ctx.terminal.canvas.right;
        let bottom = ctx.terminal.canvas.bottom;
        let top = ctx.terminal.canvas.top;
        self.width = (right - left + 1).max(1) as usize;
        let height = (top - bottom + 1).max(1) as usize;

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
        let mut seed = vec![false; self.width * height];
        for &id in &self.text {
            let coord = ctx.terminal.arena[id.0 as usize].input_coord;
            let column = (coord.column - left) as usize;
            let row = (coord.row - bottom) as usize;
            if ctx.terminal.arena[id.0 as usize].input_symbol != " " {
                seed[row * self.width + column] = true;
            }
            self.text_colors.insert(id, *mapping.get(&coord).expect("final gradient coordinate"));
            ctx.terminal.set_character_visibility(id, false);
        }

        self.snapshots.push(seed);
        for _ in 0..self.config.simulation_steps {
            let next = Self::life_step(self.snapshots.last().unwrap(), self.width, height);
            self.snapshots.push(next);
        }

        for row in 0..height {
            for column in 0..self.width {
                let coord = Coord::new(left + column as i64, bottom + row as i64);
                let symbol = ctx.rng.choice(&self.config.cell_symbols).clone();
                let fraction = column as f64 / self.width.max(1) as f64;
                let color_index = (fraction * self.config.cell_colors.len() as f64) as usize;
                let color = self.config.cell_colors[color_index.min(self.config.cell_colors.len() - 1)];
                let id = ctx.terminal.add_character(&symbol, coord);
                ctx.terminal.arena[id.0 as usize].layer = 3;
                Self::set_visual(ctx, id, &symbol, color);
                self.grid.push(id);
            }
        }

        self.reverse_end =
            self.config.chaos_hold_time + (self.config.simulation_steps + 1) * self.config.generation_time;
        self.resolve_end = self.reverse_end + self.config.resolve_duration;
        self.end_frame = self.resolve_end + self.config.final_hold_time;
        self.frame = 0;
        Ok(())
    }

    fn next_frame(&mut self, ctx: &mut EngineCtx) -> Option<String> {
        if self.frame > self.end_frame {
            return None;
        }

        if self.frame < self.config.chaos_hold_time {
            self.display_snapshot(ctx, self.config.simulation_steps as usize);
        } else if self.frame < self.reverse_end {
            let elapsed = self.frame - self.config.chaos_hold_time;
            let generations_back = elapsed / self.config.generation_time;
            let snapshot = (self.config.simulation_steps - generations_back).max(0) as usize;
            self.display_snapshot(ctx, snapshot);
        } else if self.frame < self.resolve_end {
            let elapsed = self.frame - self.reverse_end;
            let pulse_duration = (self.config.resolve_duration / 5).max(1);
            let seed = &self.snapshots[0];
            if elapsed < pulse_duration {
                let pulse = elapsed as f64 / pulse_duration as f64;
                let white = Color::from_hex("ffffff").unwrap();
                for (index, &id) in self.grid.iter().enumerate() {
                    if seed[index] {
                        let symbol = if pulse < 0.45 { "◆" } else { "✦" };
                        let column = index % self.width;
                        let base_index = column * self.config.cell_colors.len() / self.width.max(1);
                        let base = self.config.cell_colors[base_index.min(self.config.cell_colors.len() - 1)];
                        let brightness = (pulse * 1.35).min(1.0);
                        let color = shift_color_towards(&base, &white, brightness).unwrap();
                        Self::set_visual(ctx, id, symbol, color);
                    }
                    ctx.terminal.set_character_visibility(id, seed[index]);
                }
                for &id in &self.text {
                    ctx.terminal.set_character_visibility(id, false);
                }
            } else {
                for &id in &self.grid {
                    ctx.terminal.set_character_visibility(id, false);
                }
                let color_duration = (self.config.resolve_duration - pulse_duration).max(1);
                let progress = ((elapsed - pulse_duration) as f64 / color_duration as f64).clamp(0.0, 1.0);
                let eased = 1.0 - (1.0 - progress).powi(3);
                let white = Color::from_hex("ffffff").unwrap();
                for &id in &self.text {
                    let symbol = ctx.terminal.arena[id.0 as usize].input_symbol.clone();
                    let mut color =
                        shift_color_towards(&self.config.cell_colors[0], &self.text_colors[&id], eased).unwrap();
                    let gleam = ((id.0.wrapping_mul(47) % 100) as f64) / 100.0;
                    if (gleam - progress).abs() < 0.018 {
                        color = white;
                    }
                    Self::set_visual(ctx, id, &symbol, color);
                    ctx.terminal.set_character_visibility(id, true);
                }
            }
        } else {
            for &id in &self.grid {
                ctx.terminal.set_character_visibility(id, false);
            }
            for &id in &self.text {
                let symbol = ctx.terminal.arena[id.0 as usize].input_symbol.clone();
                let white = Color::from_hex("ffffff").unwrap();
                let twinkle = (self.frame + id.0 as i64 * 11) % 43 < 2;
                Self::set_visual(ctx, id, &symbol, if twinkle { white } else { self.text_colors[&id] });
                ctx.terminal.set_character_visibility(id, true);
            }
        }

        self.frame += 1;
        Some(ctx.frame())
    }
}
