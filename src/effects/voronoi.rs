//! Voronoi: living stained glass grows from drifting sites, breathes as a
//! jewel-colored mosaic, then collapses into crisp readable text.

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
pub struct VoronoiConfig {
    /// Number of moving sites which shape the stained-glass territories.
    #[arg(long = "site-count", default_value_t = 18, value_parser = parse_positive_int)]
    pub site_count: i64,

    /// Maximum horizontal and vertical drift of each site, in cells.
    #[arg(long = "site-drift", default_value_t = 4, value_parser = parse_positive_int)]
    pub site_drift: i64,

    /// Frames over which the glass grows outward from the sites.
    #[arg(long = "growth-duration", default_value_t = 135, value_parser = parse_positive_int)]
    pub growth_duration: i64,

    /// Frames the completed living mosaic spends breathing and reshaping.
    #[arg(long = "living-duration", default_value_t = 175, value_parser = parse_positive_int)]
    pub living_duration: i64,

    /// Frames the crystalline shards take to stream into the text.
    #[arg(long = "shatter-duration", default_value_t = 165, value_parser = parse_positive_int)]
    pub shatter_duration: i64,

    /// Frames to admire the final lettering after the glass clears.
    #[arg(long = "final-hold-time", default_value_t = 95, value_parser = parse_positive_int)]
    pub final_hold_time: i64,

    /// Jewel colors assigned to the moving Voronoi territories.
    #[arg(long = "glass-colors", num_args = 1.., value_parser = parse_color,
          default_values = ["ff2d95", "ff6b35", "ffd60a", "34c759", "00d9ff", "3478f6", "7c3aed", "c026d3"])]
    pub glass_colors: Vec<Color>,

    /// Color used to illuminate the borders between territories.
    #[arg(long = "border-color", default_value = "fff7ed", value_parser = parse_color)]
    pub border_color: Color,

    /// Space separated colors for the final readable text.
    #[arg(long = "final-gradient-stops", num_args = 1.., value_parser = parse_color,
          default_values = ["00d9ff", "7c3aed", "ff2d95", "ffd60a", "fff7ed"])]
    pub final_gradient_stops: Vec<Color>,

    /// Number of steps in the final text gradient.
    #[arg(long = "final-gradient-steps", num_args = 1.., value_parser = parse_gradient_steps,
          default_values = ["28"])]
    pub final_gradient_steps: Vec<i64>,

    /// Direction of the final text gradient.
    #[arg(long = "final-gradient-direction", default_value = "diagonal", value_parser = parse_gradient_direction)]
    pub final_gradient_direction: GradientDirection,
}

struct Site {
    id: CharId,
    base_x: f64,
    base_y: f64,
    amplitude_x: f64,
    amplitude_y: f64,
    phase_x: f64,
    phase_y: f64,
    color_index: usize,
}

struct GlassCell {
    id: CharId,
    coord: Coord,
    target: Coord,
    growth_order: f64,
    shatter_order: f64,
}

pub struct Voronoi {
    config: VoronoiConfig,
    sites: Vec<Site>,
    cells: Vec<GlassCell>,
    text: Vec<CharId>,
    text_colors: HashMap<CharId, Color>,
    text_reveal: HashMap<CharId, f64>,
    width: usize,
    height: usize,
    frame: i64,
    growth_end: i64,
    shatter_start: i64,
    shatter_end: i64,
    end_frame: i64,
}

impl Voronoi {
    pub fn new(config: VoronoiConfig) -> Self {
        Self {
            config,
            sites: Vec::new(),
            cells: Vec::new(),
            text: Vec::new(),
            text_colors: HashMap::new(),
            text_reveal: HashMap::new(),
            width: 0,
            height: 0,
            frame: 0,
            growth_end: 0,
            shatter_start: 0,
            shatter_end: 0,
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

    fn site_positions(&self, frame: i64) -> Vec<(f64, f64)> {
        let motion_frame = frame.min(self.shatter_start) as f64;
        self.sites
            .iter()
            .map(|site| {
                (
                    site.base_x + (motion_frame * 0.020 + site.phase_x).sin() * site.amplitude_x,
                    site.base_y + (motion_frame * 0.017 + site.phase_y).cos() * site.amplitude_y,
                )
            })
            .collect()
    }

    fn nearest_site(&self, coord: Coord, positions: &[(f64, f64)]) -> (usize, f64) {
        positions
            .iter()
            .enumerate()
            .map(|(index, &(x, y))| {
                let dx = coord.column as f64 - x;
                let dy = (coord.row as f64 - y) * 1.75;
                (index, dx * dx + dy * dy)
            })
            .min_by(|a, b| a.1.total_cmp(&b.1))
            .unwrap_or((0, 0.0))
    }

    fn owner_map(&self, positions: &[(f64, f64)]) -> Vec<usize> {
        self.cells.iter().map(|cell| self.nearest_site(cell.coord, positions).0).collect()
    }

    fn is_border(&self, index: usize, owners: &[usize]) -> bool {
        let owner = owners[index];
        let column = index % self.width;
        let row = index / self.width;
        (column > 0 && owners[index - 1] != owner)
            || (column + 1 < self.width && owners[index + 1] != owner)
            || (row > 0 && owners[index - self.width] != owner)
            || (row + 1 < self.height && owners[index + self.width] != owner)
    }

    fn border_symbol(&self, index: usize, owners: &[usize]) -> &'static str {
        let owner = owners[index];
        let column = index % self.width;
        let row = index / self.width;
        let left = column > 0 && owners[index - 1] != owner;
        let right = column + 1 < self.width && owners[index + 1] != owner;
        let down = row > 0 && owners[index - self.width] != owner;
        let up = row + 1 < self.height && owners[index + self.width] != owner;
        match (left || right, down || up) {
            (true, true) if (left && up) || (right && down) => "╲",
            (true, true) => "╱",
            (true, false) => "│",
            (false, true) => "─",
            (false, false) => "·",
        }
    }

    fn update_sites(&self, ctx: &mut EngineCtx, positions: &[(f64, f64)]) {
        let visible = self.frame < self.shatter_start;
        for (index, site) in self.sites.iter().enumerate() {
            let coord = Coord::new(positions[index].0.round() as i64, positions[index].1.round() as i64);
            ctx.terminal.arena[site.id.0 as usize].motion.set_coordinate(coord);
            let symbol = if (self.frame + index as i64 * 5) % 24 < 8 { "✦" } else { "◆" };
            Self::set_visual(ctx, site.id, symbol, self.config.border_color, true);
            ctx.terminal.set_character_visibility(site.id, visible);
        }
    }

    fn update_intro_text(&self, ctx: &mut EngineCtx) {
        let hold = 18;
        let intro_end = self.config.growth_duration * 2 / 3;
        let erosion = ((self.frame - hold).max(0) as f64 / (intro_end - hold).max(1) as f64).clamp(0.0, 1.0);
        let black = Color::from_hex("080812").unwrap();
        let white = Color::from_hex("ffffff").unwrap();
        for &id in &self.text {
            let order = (id.0.wrapping_mul(83) % 1000) as f64 / 1000.0;
            if self.frame >= intro_end || order < erosion {
                ctx.terminal.set_character_visibility(id, false);
                continue;
            }
            let symbol = ctx.terminal.arena[id.0 as usize].input_symbol.clone();
            let glint = (self.frame + id.0 as i64 * 7) % 47 < 2;
            let base = self.text_colors[&id];
            let color = if glint { white } else { shift_color_towards(&base, &black, 0.62).unwrap() };
            Self::set_visual(ctx, id, &symbol, color, glint);
            ctx.terminal.set_character_visibility(id, true);
        }
    }

    fn update_living_glass(&self, ctx: &mut EngineCtx, positions: &[(f64, f64)], owners: &[usize]) {
        let progress = (self.frame as f64 / self.config.growth_duration as f64).clamp(0.0, 1.0);
        let black = Color::from_hex("080812").unwrap();
        for (index, cell) in self.cells.iter().enumerate() {
            if cell.growth_order > progress {
                ctx.terminal.set_character_visibility(cell.id, false);
                continue;
            }
            ctx.terminal.arena[cell.id.0 as usize].motion.set_coordinate(cell.coord);
            let owner = owners[index];
            let site = &self.sites[owner];
            let base = self.config.glass_colors[site.color_index];
            let border = self.is_border(index, owners);
            let distance = self.nearest_site(cell.coord, positions).1.sqrt();
            let at_site = distance < 1.4;
            let dx = cell.coord.column as f64 - positions[owner].0;
            let dy = (cell.coord.row as f64 - positions[owner].1) * 1.75;
            let facet_down = (dx - dy).abs() < 0.72 && distance > 2.0;
            let facet_up = (dx + dy).abs() < 0.72 && distance > 2.0;
            let faceted = facet_down || facet_up;
            let breath = ((self.frame as f64 * 0.045 + owner as f64 * 1.7).sin() + 1.0) * 0.5;
            let color = if border {
                shift_color_towards(&base, &self.config.border_color, 0.48 + breath * 0.30).unwrap()
            } else if faceted {
                shift_color_towards(&base, &self.config.border_color, 0.22 + breath * 0.18).unwrap()
            } else {
                shift_color_towards(&base, &black, 0.40 - breath * 0.10).unwrap()
            };
            let symbol = if at_site {
                "✦"
            } else if border {
                self.border_symbol(index, owners)
            } else if facet_down {
                "╲"
            } else if facet_up {
                "╱"
            } else if (index + (self.frame / 16) as usize) % 11 == 0 {
                "◇"
            } else {
                "·"
            };
            Self::set_visual(ctx, cell.id, symbol, color, border || faceted || at_site);
            ctx.terminal.set_character_visibility(cell.id, true);
        }
    }

    fn update_shatter(&self, ctx: &mut EngineCtx, owners: &[usize]) {
        let progress = ((self.frame - self.shatter_start) as f64 / self.config.shatter_duration as f64).clamp(0.0, 1.0);
        for (index, cell) in self.cells.iter().enumerate() {
            let local = ((progress - cell.shatter_order) / (1.0 - cell.shatter_order)).clamp(0.0, 1.0);
            if local >= 1.0 {
                ctx.terminal.set_character_visibility(cell.id, false);
                continue;
            }
            let eased = local * local * (3.0 - 2.0 * local);
            let coord = Coord::new(
                (cell.coord.column as f64 + (cell.target.column - cell.coord.column) as f64 * eased).round() as i64,
                (cell.coord.row as f64 + (cell.target.row - cell.coord.row) as f64 * eased).round() as i64,
            );
            ctx.terminal.arena[cell.id.0 as usize].motion.set_coordinate(coord);
            let base = self.config.glass_colors[self.sites[owners[index]].color_index];
            let color = shift_color_towards(&base, &self.config.border_color, local * 0.82).unwrap();
            let symbol = if local < 0.24 && self.is_border(index, owners) {
                self.border_symbol(index, owners)
            } else if local < 0.55 {
                if (index + owners[index]) % 2 == 0 {
                    "◇"
                } else {
                    "◆"
                }
            } else if local < 0.84 {
                "✦"
            } else {
                "·"
            };
            Self::set_visual(ctx, cell.id, symbol, color, local > 0.30);
            ctx.terminal.set_character_visibility(cell.id, true);
        }

        let white = Color::from_hex("ffffff").unwrap();
        for &id in &self.text {
            let start = self.text_reveal[&id];
            if progress < start {
                ctx.terminal.set_character_visibility(id, false);
                continue;
            }
            let local = ((progress - start) / (1.0 - start).max(0.01)).clamp(0.0, 1.0);
            let symbol = ctx.terminal.arena[id.0 as usize].input_symbol.clone();
            if local < 0.18 {
                Self::set_visual(ctx, id, "✦", white, true);
            } else {
                let color = shift_color_towards(
                    &self.config.glass_colors[id.0 as usize % self.config.glass_colors.len()],
                    &self.text_colors[&id],
                    ((local - 0.18) / 0.82).clamp(0.0, 1.0),
                )
                .unwrap();
                Self::set_visual(ctx, id, &symbol, color, true);
            }
            ctx.terminal.set_character_visibility(id, true);
        }
    }

    fn update_final(&self, ctx: &mut EngineCtx) {
        for cell in &self.cells {
            ctx.terminal.set_character_visibility(cell.id, false);
        }
        let white = Color::from_hex("ffffff").unwrap();
        for &id in &self.text {
            let symbol = ctx.terminal.arena[id.0 as usize].input_symbol.clone();
            let twinkle = (self.frame + id.0 as i64 * 13) % 53 < 2;
            Self::set_visual(ctx, id, &symbol, if twinkle { white } else { self.text_colors[&id] }, true);
            ctx.terminal.set_character_visibility(id, true);
        }
    }
}

impl EffectHooks for Voronoi {
    fn dispatch_callback(&mut self, _ctx: &mut EngineCtx, _character: CharId, _callback: &EffectCallback) {}
}

impl Effect for Voronoi {
    fn build(&mut self, ctx: &mut EngineCtx) -> Result<(), EngineError> {
        let left = ctx.terminal.canvas.left;
        let right = ctx.terminal.canvas.right;
        let bottom = ctx.terminal.canvas.bottom;
        let top = ctx.terminal.canvas.top;
        self.width = (right - left + 1).max(1) as usize;
        self.height = (top - bottom + 1).max(1) as usize;

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
        for &id in &self.text {
            let coord = ctx.terminal.arena[id.0 as usize].input_coord;
            ctx.terminal.arena[id.0 as usize].layer = 6;
            self.text_colors.insert(id, *mapping.get(&coord).expect("Voronoi gradient coordinate"));
            let across = (coord.column - ctx.terminal.canvas.text_left) as f64 / text_width;
            let jitter = (id.0.wrapping_mul(97) % 100) as f64 / 1000.0;
            self.text_reveal.insert(id, 0.43 + across * 0.23 + jitter);
            let black = Color::from_hex("080812").unwrap();
            let initial = shift_color_towards(&self.text_colors[&id], &black, 0.62).unwrap();
            let symbol = ctx.terminal.arena[id.0 as usize].input_symbol.clone();
            Self::set_visual(ctx, id, &symbol, initial, false);
            ctx.terminal.set_character_visibility(id, true);
        }

        let non_space_text: Vec<Coord> = self
            .text
            .iter()
            .filter(|&&id| ctx.terminal.arena[id.0 as usize].input_symbol != " ")
            .map(|&id| ctx.terminal.arena[id.0 as usize].input_coord)
            .collect();
        let columns = ((self.config.site_count as f64 * 1.8).sqrt().ceil() as usize).max(1);
        let rows = (self.config.site_count as usize).div_ceil(columns).max(1);
        for index in 0..self.config.site_count as usize {
            let column = index % columns;
            let row = index / columns;
            let (base_x, base_y) = if non_space_text.is_empty() {
                (
                    left as f64 + (column + 1) as f64 / (columns + 1) as f64 * (right - left) as f64,
                    bottom as f64 + (row + 1) as f64 / (rows + 1) as f64 * (top - bottom) as f64,
                )
            } else {
                let sample =
                    ((index * non_space_text.len()) / self.config.site_count as usize).min(non_space_text.len() - 1);
                let coord = non_space_text[sample];
                (coord.column as f64 + ctx.rng.uniform(-0.65, 0.65), coord.row as f64 + ctx.rng.uniform(-0.35, 0.35))
            };
            let id = ctx.terminal.add_character("✦", Coord::new(base_x.round() as i64, base_y.round() as i64));
            ctx.terminal.arena[id.0 as usize].layer = 7;
            ctx.terminal.set_character_visibility(id, false);
            self.sites.push(Site {
                id,
                base_x,
                base_y,
                amplitude_x: ctx.rng.uniform(0.6, (self.config.site_drift as f64).max(0.6)),
                amplitude_y: ctx.rng.uniform(0.4, (self.config.site_drift as f64 * 0.65).max(0.4)),
                phase_x: ctx.rng.uniform(0.0, std::f64::consts::TAU),
                phase_y: ctx.rng.uniform(0.0, std::f64::consts::TAU),
                color_index: index % self.config.glass_colors.len(),
            });
        }

        let base_positions: Vec<(f64, f64)> = self.sites.iter().map(|site| (site.base_x, site.base_y)).collect();
        let fallback = Coord::new((left + right) / 2, (bottom + top) / 2);
        let mut distances = Vec::with_capacity(self.width * self.height);
        for row in 0..self.height {
            for column in 0..self.width {
                let coord = Coord::new(left + column as i64, bottom + row as i64);
                let (_, distance) = self.nearest_site(coord, &base_positions);
                distances.push(distance.sqrt());
                let target = non_space_text
                    .iter()
                    .min_by_key(|target| {
                        let dx = target.column - coord.column;
                        let dy = target.row - coord.row;
                        dx * dx + 3 * dy * dy
                    })
                    .copied()
                    .unwrap_or(fallback);
                let id = ctx.terminal.add_character("░", coord);
                ctx.terminal.arena[id.0 as usize].layer = 2;
                ctx.terminal.set_character_visibility(id, false);
                let hash = (coord.column as u64)
                    .wrapping_mul(0x9e37_79b9)
                    .wrapping_add((coord.row as u64).wrapping_mul(0x85eb_ca6b));
                self.cells.push(GlassCell {
                    id,
                    coord,
                    target,
                    growth_order: 0.0,
                    shatter_order: (hash % 10_000) as f64 / 10_000.0 * 0.24,
                });
            }
        }
        let max_distance = distances.iter().copied().fold(1.0_f64, f64::max);
        for (cell, distance) in self.cells.iter_mut().zip(distances) {
            let radial = distance / max_distance;
            let jitter = (cell.id.0.wrapping_mul(61) % 100) as f64 / 1000.0;
            cell.growth_order = (radial * 0.86 + jitter).min(1.0);
        }

        self.growth_end = self.config.growth_duration;
        self.shatter_start = self.growth_end + self.config.living_duration;
        self.shatter_end = self.shatter_start + self.config.shatter_duration;
        self.end_frame = self.shatter_end + self.config.final_hold_time;
        self.frame = 0;
        Ok(())
    }

    fn next_frame(&mut self, ctx: &mut EngineCtx) -> Option<String> {
        if self.frame > self.end_frame {
            return None;
        }
        let positions = self.site_positions(self.frame);
        let owners = self.owner_map(&positions);
        if self.frame < self.shatter_start {
            self.update_living_glass(ctx, &positions, &owners);
            self.update_sites(ctx, &positions);
            self.update_intro_text(ctx);
        } else if self.frame < self.shatter_end {
            self.update_sites(ctx, &positions);
            self.update_shatter(ctx, &owners);
        } else {
            self.update_sites(ctx, &positions);
            self.update_final(ctx);
        }
        self.frame += 1;
        Some(ctx.frame())
    }
}
