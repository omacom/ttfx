//! Automata: an elementary cellular automaton grows down the canvas, forming
//! a fractal lattice whose living cells stream into the input text.

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
use crate::utils::graphics::{Color, ColorPair, Gradient, GradientDirection};

#[derive(Args, Debug, Clone)]
pub struct AutomataConfig {
    /// Elementary cellular automaton rule, from 0 to 255. Rule 90 produces a Sierpinski triangle.
    #[arg(long = "rule", default_value_t = 90)]
    pub rule: u8,

    /// Number of evenly spaced living cells in the initial generation.
    #[arg(long = "seed-cells", default_value_t = 1, value_parser = parse_positive_int)]
    pub seed_cells: i64,

    /// Frames to display before adding each new generation.
    #[arg(long = "generation-time", default_value_t = 5, value_parser = parse_positive_int)]
    pub generation_time: i64,

    /// Frames to hold the completed cellular pattern.
    #[arg(long = "hold-time", default_value_t = 75, value_parser = parse_non_negative_int)]
    pub hold_time: i64,

    /// Frames over which the cellular pattern dissolves into the text.
    #[arg(long = "dissolve-duration", default_value_t = 180, value_parser = parse_positive_int)]
    pub dissolve_duration: i64,

    /// Frames to hold the readable text after the fractal has flowed into it.
    #[arg(long = "final-hold-time", default_value_t = 85, value_parser = parse_non_negative_int)]
    pub final_hold_time: i64,

    /// Space separated symbols used for living cells.
    #[arg(long = "cell-symbols", num_args = 1.., value_parser = parse_symbol,
          default_values = ["█", "▓", "▒", "◆"])]
    pub cell_symbols: Vec<String>,

    /// Space separated colors used by the fractal.
    #[arg(long = "cell-colors", num_args = 1.., value_parser = parse_color,
          default_values = ["00f5d4", "00bbf9", "4361ee", "7209b7", "f72585"])]
    pub cell_colors: Vec<Color>,

    /// Space separated colors for the final readable text gradient.
    #[arg(long = "final-gradient-stops", num_args = 1.., value_parser = parse_color,
          default_values = ["00f5d4", "4361ee", "a78bfa", "f8fafc"])]
    pub final_gradient_stops: Vec<Color>,

    /// Number of steps in the final text gradient.
    #[arg(long = "final-gradient-steps", num_args = 1.., value_parser = parse_gradient_steps,
          default_values = ["20"])]
    pub final_gradient_steps: Vec<i64>,

    /// Direction of the final text gradient.
    #[arg(long = "final-gradient-direction", default_value = "diagonal", value_parser = parse_gradient_direction)]
    pub final_gradient_direction: GradientDirection,

    /// Color of the text before the automaton resolves into it.
    #[arg(long = "shadow-color", default_value = "283747", value_parser = parse_color)]
    pub shadow_color: Color,
}

struct Cell {
    id: CharId,
    coord: Coord,
    generation: i64,
    dissolve_order: f64,
    destination: Coord,
}

pub struct Automata {
    config: AutomataConfig,
    cells: Vec<Cell>,
    text: Vec<CharId>,
    text_colors: HashMap<CharId, Color>,
    text_origins: HashMap<CharId, Coord>,
    text_reveal: HashMap<CharId, f64>,
    frame: i64,
    growth_end: i64,
    dissolve_start: i64,
    end_frame: i64,
}

impl Automata {
    pub fn new(config: AutomataConfig) -> Self {
        Self {
            config,
            cells: Vec::new(),
            text: Vec::new(),
            text_colors: HashMap::new(),
            text_origins: HashMap::new(),
            text_reveal: HashMap::new(),
            frame: 0,
            growth_end: 0,
            dissolve_start: 0,
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

    fn next_generation(rule: u8, current: &[bool]) -> Vec<bool> {
        let mut next = vec![false; current.len()];
        for index in 0..current.len() {
            let left = index.checked_sub(1).is_some_and(|i| current[i]) as u8;
            let center = current[index] as u8;
            let right = (index + 1 < current.len() && current[index + 1]) as u8;
            let neighborhood = (left << 2) | (center << 1) | right;
            next[index] = (rule >> neighborhood) & 1 == 1;
        }
        next
    }
}

impl EffectHooks for Automata {
    fn dispatch_callback(&mut self, _ctx: &mut EngineCtx, _character: CharId, _callback: &EffectCallback) {}
}

impl Effect for Automata {
    fn build(&mut self, ctx: &mut EngineCtx) -> Result<(), EngineError> {
        let canvas_left = ctx.terminal.canvas.left;
        let canvas_right = ctx.terminal.canvas.right;
        let canvas_top = ctx.terminal.canvas.top;
        let canvas_bottom = ctx.terminal.canvas.bottom;
        let width = (canvas_right - canvas_left + 1).max(1) as usize;
        let height = (canvas_top - canvas_bottom + 1).max(1);

        self.text = ctx.terminal.get_characters(
            &mut ctx.rng,
            CharacterFilter::default(),
            CharacterSort::TopToBottomLeftToRight,
        );
        let final_gradient =
            Gradient::new(&self.config.final_gradient_stops, &self.config.final_gradient_steps, false, false)
                .map_err(EngineError::Other)?;
        let final_mapping = final_gradient
            .build_coordinate_color_mapping(
                ctx.terminal.canvas.text_bottom,
                ctx.terminal.canvas.text_top,
                ctx.terminal.canvas.text_left,
                ctx.terminal.canvas.text_right,
                self.config.final_gradient_direction,
            )
            .map_err(EngineError::Other)?;
        for &id in &self.text {
            let coord = ctx.terminal.arena[id.0 as usize].input_coord;
            let symbol = ctx.terminal.arena[id.0 as usize].input_symbol.clone();
            self.text_colors.insert(id, *final_mapping.get(&coord).expect("final gradient coordinate"));
            Self::set_visual(ctx, id, &symbol, self.config.shadow_color);
            ctx.terminal.set_character_visibility(id, true);
        }

        let mut generation = vec![false; width];
        for seed in 0..self.config.seed_cells {
            let position = (((seed + 1) as f64 / (self.config.seed_cells + 1) as f64)
                * (width.saturating_sub(1)) as f64)
                .round() as usize;
            generation[position.min(width - 1)] = true;
        }

        for row_index in 0..height {
            for (column_index, &alive) in generation.iter().enumerate() {
                if !alive {
                    continue;
                }
                let coord = Coord::new(canvas_left + column_index as i64, canvas_top - row_index);
                let symbol = ctx.rng.choice(&self.config.cell_symbols).clone();
                let color_index = ((row_index as usize / 3) + column_index / 7) % self.config.cell_colors.len();
                let id = ctx.terminal.add_character(&symbol, coord);
                ctx.terminal.arena[id.0 as usize].layer = 3;
                Self::set_visual(ctx, id, &symbol, self.config.cell_colors[color_index]);
                let hash = (coord.column as u64)
                    .wrapping_mul(0x9e37_79b9)
                    .wrapping_add((coord.row as u64).wrapping_mul(0x85eb_ca6b));
                self.cells.push(Cell {
                    id,
                    coord,
                    generation: row_index,
                    dissolve_order: (hash % 10_000) as f64 / 10_000.0,
                    destination: coord,
                });
            }
            generation = Self::next_generation(self.config.rule, &generation);
        }

        // Couple the resolution to the fractal itself. Each input glyph is
        // sourced from its nearest automaton cell; the cell's deterministic
        // dissolve order becomes the glyph's departure time.
        for &id in &self.text {
            let home = ctx.terminal.arena[id.0 as usize].input_coord;
            let source = self
                .cells
                .iter()
                .min_by_key(|cell| {
                    let dx = home.column - cell.coord.column;
                    let dy = home.row - cell.coord.row;
                    dx * dx + 4 * dy * dy
                })
                .expect("automaton has at least one living cell");
            self.text_origins.insert(id, source.coord);
            self.text_reveal.insert(id, source.dissolve_order * 0.55);
        }

        // Every living cell gets a destination inside the lettering. During
        // the finale the complete fractal therefore streams into the text,
        // rather than merely disappearing behind it.
        for cell in &mut self.cells {
            cell.destination = self
                .text
                .iter()
                .filter(|&&id| ctx.terminal.arena[id.0 as usize].input_symbol != " ")
                .min_by_key(|&&id| {
                    let home = ctx.terminal.arena[id.0 as usize].input_coord;
                    let dx = home.column - cell.coord.column;
                    let dy = home.row - cell.coord.row;
                    dx * dx + 3 * dy * dy
                })
                .map(|&id| ctx.terminal.arena[id.0 as usize].input_coord)
                .unwrap_or(cell.coord);
        }

        self.growth_end = height * self.config.generation_time;
        self.dissolve_start = self.growth_end + self.config.hold_time;
        self.end_frame = self.dissolve_start + self.config.dissolve_duration + self.config.final_hold_time;
        self.frame = 0;
        Ok(())
    }

    fn next_frame(&mut self, ctx: &mut EngineCtx) -> Option<String> {
        if self.frame > self.end_frame {
            return None;
        }

        if self.frame < self.dissolve_start {
            for cell in &self.cells {
                let born = cell.generation * self.config.generation_time;
                let visible = self.frame >= born;
                if visible {
                    let pulse = ((self.frame - born) / 12).max(0) as usize;
                    let color_index = (cell.generation as usize / 3 + pulse) % self.config.cell_colors.len();
                    let symbol_index = (cell.generation as usize + pulse / 2) % self.config.cell_symbols.len();
                    Self::set_visual(
                        ctx,
                        cell.id,
                        &self.config.cell_symbols[symbol_index],
                        self.config.cell_colors[color_index],
                    );
                }
                ctx.terminal.set_character_visibility(cell.id, visible);
            }
        } else {
            let progress =
                ((self.frame - self.dissolve_start) as f64 / self.config.dissolve_duration as f64).clamp(0.0, 1.0);
            for cell in &self.cells {
                let departure = cell.dissolve_order * 0.65;
                if progress < departure {
                    ctx.terminal.arena[cell.id.0 as usize].motion.set_coordinate(cell.coord);
                    ctx.terminal.set_character_visibility(cell.id, true);
                    continue;
                }
                let local = ((progress - departure) / 0.28).clamp(0.0, 1.0);
                if local >= 1.0 {
                    ctx.terminal.set_character_visibility(cell.id, false);
                    continue;
                }
                let eased = local * local * (3.0 - 2.0 * local);
                let coord = Coord::new(
                    (cell.coord.column as f64 + (cell.destination.column - cell.coord.column) as f64 * eased).round()
                        as i64,
                    (cell.coord.row as f64 + (cell.destination.row - cell.coord.row) as f64 * eased).round() as i64,
                );
                ctx.terminal.arena[cell.id.0 as usize].motion.set_coordinate(coord);
                let symbol = if local < 0.40 {
                    "◆"
                } else if local < 0.75 {
                    "•"
                } else {
                    "·"
                };
                let color_index = ((1.0 - local) * (self.config.cell_colors.len() - 1) as f64).round() as usize;
                Self::set_visual(ctx, cell.id, symbol, self.config.cell_colors[color_index]);
                ctx.terminal.set_character_visibility(cell.id, true);
            }
            for &id in &self.text {
                let start = self.text_reveal[&id];
                if progress < start {
                    ctx.terminal.set_character_visibility(id, false);
                    continue;
                }
                let local = ((progress - start) / 0.40).clamp(0.0, 1.0);
                let eased = 1.0 - (1.0 - local).powi(3);
                let origin = self.text_origins[&id];
                let home = ctx.terminal.arena[id.0 as usize].input_coord;
                let coord = Coord::new(
                    (origin.column as f64 + (home.column - origin.column) as f64 * eased).round() as i64,
                    (origin.row as f64 + (home.row - origin.row) as f64 * eased).round() as i64,
                );
                let symbol = ctx.terminal.arena[id.0 as usize].input_symbol.clone();
                ctx.terminal.arena[id.0 as usize].motion.set_coordinate(coord);
                Self::set_visual(ctx, id, &symbol, self.text_colors[&id]);
                ctx.terminal.set_character_visibility(id, true);
            }

            if progress >= 1.0 {
                let white = Color::from_hex("ffffff").unwrap();
                for &id in &self.text {
                    let symbol = ctx.terminal.arena[id.0 as usize].input_symbol.clone();
                    let twinkle = (self.frame + id.0 as i64 * 7) % 37 < 2;
                    Self::set_visual(ctx, id, &symbol, if twinkle { white } else { self.text_colors[&id] });
                }
            }
        }

        self.frame += 1;
        Some(ctx.frame())
    }
}
