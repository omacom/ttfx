//! Airstrike: ASCII planes dive into the input, scattering its glyphs through
//! fire and debris before the text pulls itself back together.

use std::collections::HashMap;

use clap::Args;

use crate::cli::parse_color;
use crate::effects::common::{
    parse_gradient_direction, parse_gradient_steps, parse_non_negative_int, parse_positive_float, parse_positive_int,
};
use crate::engine::animation::ExistingColorHandling;
use crate::engine::character::CharId;
use crate::engine::ctx::{EffectHooks, EngineCtx};
use crate::engine::effect::Effect;
use crate::engine::error::EngineError;
use crate::engine::events::EffectCallback;
use crate::engine::terminal::{CharacterFilter, CharacterSort};
use crate::utils::geometry::Coord;
use crate::utils::graphics::{Color, ColorPair, Gradient, GradientDirection};

#[derive(Args, Debug, Clone)]
pub struct AirstrikeConfig {
    /// Number of planes which strike the text.
    #[arg(long = "plane-count", default_value_t = 6, value_parser = parse_positive_int)]
    pub plane_count: i64,

    /// Plane travel speed in terminal cells per frame.
    #[arg(long = "flight-speed", default_value_t = 0.55, value_parser = parse_positive_float)]
    pub flight_speed: f64,

    /// Frames between successive plane launches.
    #[arg(long = "launch-delay", default_value_t = 50, value_parser = parse_non_negative_int)]
    pub launch_delay: i64,

    /// Radius, in terminal cells, affected by each impact.
    #[arg(long = "blast-radius", default_value_t = 20, value_parser = parse_positive_int)]
    pub blast_radius: i64,

    /// Frames the text glyphs spend flying outward as debris.
    #[arg(long = "debris-duration", default_value_t = 70, value_parser = parse_positive_int)]
    pub debris_duration: i64,

    /// Frames the scattered text takes to reassemble.
    #[arg(long = "reassembly-duration", default_value_t = 100, value_parser = parse_positive_int)]
    pub reassembly_duration: i64,

    /// Frames to hold the restored text after the smoke clears.
    #[arg(long = "final-hold-time", default_value_t = 70, value_parser = parse_non_negative_int)]
    pub final_hold_time: i64,

    /// Number of fire and shrapnel particles emitted by each impact.
    #[arg(long = "fire-particles", default_value_t = 52, value_parser = parse_positive_int)]
    pub fire_particles: i64,

    /// Color of the incoming aircraft.
    #[arg(long = "plane-color", default_value = "b8c4d6", value_parser = parse_color)]
    pub plane_color: Color,

    /// Space separated list of colors used by the fireball.
    #[arg(long = "fire-colors", num_args = 1.., value_parser = parse_color,
          default_values = ["fff3a3", "ffb000", "ff4d00", "7a1f00"])]
    pub fire_colors: Vec<Color>,

    /// Space separated list of colors for the restored text gradient.
    #[arg(long = "final-gradient-stops", num_args = 1.., value_parser = parse_color,
          default_values = ["ff5f00", "ffd166", "fff3b0"])]
    pub final_gradient_stops: Vec<Color>,

    /// Number of gradient steps to use.
    #[arg(long = "final-gradient-steps", num_args = 1.., value_parser = parse_gradient_steps,
          default_values = ["12"])]
    pub final_gradient_steps: Vec<i64>,

    /// Direction of the restored text gradient.
    #[arg(long = "final-gradient-direction", default_value = "diagonal", value_parser = parse_gradient_direction)]
    pub final_gradient_direction: GradientDirection,
}

struct Plane {
    parts: Vec<(CharId, Coord)>,
    start: Coord,
    target: Coord,
    launch_frame: i64,
    impact_frame: i64,
    impacted: bool,
}

struct Debris {
    id: CharId,
    home: Coord,
    impact: usize,
    velocity_x: f64,
    velocity_y: f64,
}

struct FireParticle {
    id: CharId,
    impact: usize,
    velocity_x: f64,
    velocity_y: f64,
    lifetime: i64,
}

struct TrailParticle {
    id: CharId,
    born: i64,
    origin_x: f64,
    origin_y: f64,
    velocity_x: f64,
    velocity_y: f64,
    lifetime: i64,
}

pub struct Airstrike {
    config: AirstrikeConfig,
    planes: Vec<Plane>,
    debris: Vec<Debris>,
    fire: Vec<FireParticle>,
    trails: Vec<TrailParticle>,
    final_colors: HashMap<CharId, ColorPair>,
    frame: i64,
    end_frame: i64,
}

impl Airstrike {
    pub fn new(config: AirstrikeConfig) -> Self {
        Self {
            config,
            planes: Vec::new(),
            debris: Vec::new(),
            fire: Vec::new(),
            trails: Vec::new(),
            final_colors: HashMap::new(),
            frame: 0,
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

    fn impact(&mut self, ctx: &mut EngineCtx, plane_index: usize) {
        let target = self.planes[plane_index].target;
        for &(id, _) in &self.planes[plane_index].parts {
            ctx.terminal.set_character_visibility(id, false);
        }
        self.planes[plane_index].impacted = true;

        for piece in self.debris.iter_mut().filter(|piece| piece.impact == plane_index) {
            let dx = piece.home.column - target.column;
            let dy = piece.home.row - target.row;
            let distance = ((dx * dx + dy * dy) as f64).sqrt().max(1.0);
            let force = (1.0 - distance / (self.config.blast_radius as f64 * 1.35)).clamp(0.15, 1.0);
            piece.velocity_x = dx as f64 / distance * (0.18 + force * 0.45) + ctx.rng.uniform(-0.18, 0.18);
            piece.velocity_y = dy as f64 / distance * (0.12 + force * 0.30) + ctx.rng.uniform(0.18, 0.55);
        }
    }

    fn update_planes(&mut self, ctx: &mut EngineCtx) {
        for index in 0..self.planes.len() {
            if self.frame < self.planes[index].launch_frame || self.planes[index].impacted {
                continue;
            }
            if self.frame >= self.planes[index].impact_frame {
                self.impact(ctx, index);
                continue;
            }
            let plane = &self.planes[index];
            let duration = (plane.impact_frame - plane.launch_frame).max(1);
            let progress = (self.frame - plane.launch_frame) as f64 / duration as f64;
            let column = plane.start.column as f64 + (plane.target.column - plane.start.column) as f64 * progress;
            let row = plane.start.row as f64 + (plane.target.row - plane.start.row) as f64 * progress;
            for &(id, offset) in &plane.parts {
                ctx.terminal.arena[id.0 as usize]
                    .motion
                    .set_coordinate(Coord::new(column.round() as i64 + offset.column, row.round() as i64 + offset.row));
                ctx.terminal.set_character_visibility(id, true);
            }

            if (self.frame - plane.launch_frame) % 3 == 0 {
                let direction = if plane.start.column < plane.target.column { -1.0 } else { 1.0 };
                let origin_x = column + direction * 3.6;
                let origin_y = row + ctx.rng.uniform(-0.25, 0.25);
                let id = ctx.terminal.add_character("*", Coord::new(origin_x.round() as i64, origin_y.round() as i64));
                ctx.terminal.arena[id.0 as usize].layer = 2;
                self.trails.push(TrailParticle {
                    id,
                    born: self.frame,
                    origin_x,
                    origin_y,
                    velocity_x: direction * ctx.rng.uniform(0.03, 0.11),
                    velocity_y: ctx.rng.uniform(0.01, 0.08),
                    lifetime: ctx.rng.randint(24, 43),
                });
            }
        }
    }

    fn update_trails(&mut self, ctx: &mut EngineCtx) {
        for particle in &self.trails {
            let age = self.frame - particle.born;
            if age < 0 || age >= particle.lifetime {
                ctx.terminal.set_character_visibility(particle.id, false);
                continue;
            }
            let t = age as f64;
            ctx.terminal.arena[particle.id.0 as usize].motion.set_coordinate(Coord::new(
                (particle.origin_x + particle.velocity_x * t).round() as i64,
                (particle.origin_y + particle.velocity_y * t + 0.003 * t * t).round() as i64,
            ));
            let ratio = age as f64 / particle.lifetime as f64;
            let symbol = if ratio < 0.25 {
                "*"
            } else if ratio < 0.65 {
                "+"
            } else {
                "."
            };
            let color_index =
                ((ratio * self.config.fire_colors.len() as f64) as usize).min(self.config.fire_colors.len() - 1);
            Self::set_visual(ctx, particle.id, symbol, self.config.fire_colors[color_index]);
            ctx.terminal.set_character_visibility(particle.id, true);
        }
    }

    fn update_debris(&mut self, ctx: &mut EngineCtx) {
        let hot = self.config.fire_colors[1.min(self.config.fire_colors.len() - 1)];
        let soot = Color::from_hex("6b625f").unwrap();
        for piece in &self.debris {
            let impact_frame = self.planes[piece.impact].impact_frame;
            let age = self.frame - impact_frame;
            if age < 0 {
                continue;
            }
            let input_symbol = ctx.terminal.arena[piece.id.0 as usize].input_symbol.clone();
            if age < self.config.debris_duration {
                let t = age as f64;
                let coord = Coord::new(
                    (piece.home.column as f64 + piece.velocity_x * t).round() as i64,
                    (piece.home.row as f64 + piece.velocity_y * t - 0.010 * t * t).round() as i64,
                );
                ctx.terminal.arena[piece.id.0 as usize].motion.set_coordinate(coord);
                let color = if age < self.config.debris_duration / 3 { hot } else { soot };
                Self::set_visual(ctx, piece.id, &input_symbol, color);
            } else if age < self.config.debris_duration + self.config.reassembly_duration {
                let elapsed = age - self.config.debris_duration;
                let t = elapsed as f64 / self.config.reassembly_duration as f64;
                let eased = 1.0 - (1.0 - t).powi(3);
                let blast_t = self.config.debris_duration as f64;
                let from_col = piece.home.column as f64 + piece.velocity_x * blast_t;
                let from_row = piece.home.row as f64 + piece.velocity_y * blast_t - 0.010 * blast_t * blast_t;
                let coord = Coord::new(
                    (from_col + (piece.home.column as f64 - from_col) * eased).round() as i64,
                    (from_row + (piece.home.row as f64 - from_row) * eased).round() as i64,
                );
                ctx.terminal.arena[piece.id.0 as usize].motion.set_coordinate(coord);
                let colors = self.final_colors.get(&piece.id).cloned().unwrap_or_default();
                let uses_pre = ctx.terminal.arena[piece.id.0 as usize].uses_input_preexisting_colors;
                ctx.terminal.arena[piece.id.0 as usize].animation.set_appearance(
                    &input_symbol,
                    uses_pre,
                    Some(&input_symbol),
                    Some(colors),
                );
            } else {
                ctx.terminal.arena[piece.id.0 as usize].motion.set_coordinate(piece.home);
            }
        }
    }

    fn update_fire(&mut self, ctx: &mut EngineCtx) {
        for particle in &self.fire {
            let impact_frame = self.planes[particle.impact].impact_frame;
            let age = self.frame - impact_frame;
            if age < 0 || age >= particle.lifetime {
                ctx.terminal.set_character_visibility(particle.id, false);
                continue;
            }
            let target = self.planes[particle.impact].target;
            let t = age as f64;
            let coord = Coord::new(
                (target.column as f64 + particle.velocity_x * t).round() as i64,
                (target.row as f64 + particle.velocity_y * t - 0.025 * t * t).round() as i64,
            );
            ctx.terminal.arena[particle.id.0 as usize].motion.set_coordinate(coord);
            let ratio = age as f64 / particle.lifetime as f64;
            let color_index =
                ((ratio * self.config.fire_colors.len() as f64) as usize).min(self.config.fire_colors.len() - 1);
            let symbol = if ratio < 0.2 {
                "*"
            } else if ratio < 0.65 {
                "+"
            } else {
                "."
            };
            Self::set_visual(ctx, particle.id, symbol, self.config.fire_colors[color_index]);
            ctx.terminal.set_character_visibility(particle.id, true);
        }
    }
}

impl EffectHooks for Airstrike {
    fn dispatch_callback(&mut self, _ctx: &mut EngineCtx, _character: CharId, _callback: &EffectCallback) {}
}

impl Effect for Airstrike {
    fn build(&mut self, ctx: &mut EngineCtx) -> Result<(), EngineError> {
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
        let dynamic = ctx.terminal.config.existing_color_handling == ExistingColorHandling::Dynamic;
        let characters = ctx.terminal.get_characters(
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

        for index in 0..self.config.plane_count {
            let fraction = (index + 1) as f64 / (self.config.plane_count + 1) as f64;
            let rough_target = Coord::new(
                left + (width as f64 * fraction).round() as i64,
                top - (height as f64 * fraction).round() as i64,
            );
            let target = characters
                .iter()
                .filter(|&&id| ctx.terminal.arena[id.0 as usize].input_symbol != " ")
                .min_by_key(|&&id| {
                    let c = ctx.terminal.arena[id.0 as usize].input_coord;
                    (c.column - rough_target.column).pow(2) + 3 * (c.row - rough_target.row).pow(2)
                })
                .map(|&id| ctx.terminal.arena[id.0 as usize].input_coord)
                .unwrap_or(rough_target);
            let from_left = index % 2 == 0;
            let start = Coord::new(
                if from_left { ctx.terminal.canvas.left - 5 } else { ctx.terminal.canvas.right + 5 },
                (top + 4 - index * 2).min(ctx.terminal.canvas.top + 3),
            );
            let distance = (((target.column - start.column).pow(2) + (target.row - start.row).pow(2)) as f64).sqrt();
            let launch_frame = index * self.config.launch_delay;
            let impact_frame = launch_frame + (distance / self.config.flight_speed).ceil() as i64;
            let sprite: [(&str, i64, i64); 7] = if from_left {
                [("=", -3, 0), ("=", -2, 0), ("=", -1, 0), (">", 0, 0), ("/", -2, 1), ("\\", -2, -1), ("o", -3, 1)]
            } else {
                [("<", 0, 0), ("=", 1, 0), ("=", 2, 0), ("=", 3, 0), ("\\", 2, 1), ("/", 2, -1), ("o", 3, 1)]
            };
            let mut parts = Vec::new();
            for (symbol, dx, dy) in sprite {
                let id = ctx.terminal.add_character(symbol, start);
                ctx.terminal.arena[id.0 as usize].layer = 3;
                Self::set_visual(ctx, id, symbol, self.config.plane_color);
                parts.push((id, Coord::new(dx, dy)));
            }
            self.planes.push(Plane { parts, start, target, launch_frame, impact_frame, impacted: false });
        }

        for id in characters {
            let home = ctx.terminal.arena[id.0 as usize].input_coord;
            let symbol = ctx.terminal.arena[id.0 as usize].input_symbol.clone();
            let colors = if dynamic {
                let animation = &ctx.terminal.arena[id.0 as usize].animation;
                ColorPair::new(animation.input_fg_color, animation.input_bg_color)
            } else {
                ColorPair::new(Some(*mapping.get(&home).unwrap()), None)
            };
            self.final_colors.insert(id, colors);
            let uses_pre = ctx.terminal.arena[id.0 as usize].uses_input_preexisting_colors;
            ctx.terminal.arena[id.0 as usize].animation.set_appearance(&symbol, uses_pre, Some(&symbol), Some(colors));
            ctx.terminal.set_character_visibility(id, true);
            if symbol != " " {
                let impact = self
                    .planes
                    .iter()
                    .enumerate()
                    .min_by_key(|(_, plane)| {
                        let dx = home.column - plane.target.column;
                        let dy = home.row - plane.target.row;
                        dx * dx + dy * dy
                    })
                    .map(|(index, _)| index)
                    .unwrap_or(0);
                let target = self.planes[impact].target;
                let dx = home.column - target.column;
                let dy = home.row - target.row;
                if dx * dx + dy * dy <= self.config.blast_radius * self.config.blast_radius {
                    self.debris.push(Debris { id, home, impact, velocity_x: 0.0, velocity_y: 0.0 });
                }
            }
        }

        for impact in 0..self.planes.len() {
            for _ in 0..self.config.fire_particles {
                let symbol = "*";
                let id = ctx.terminal.add_character(symbol, self.planes[impact].target);
                ctx.terminal.arena[id.0 as usize].layer = 4;
                let angle = ctx.rng.uniform(0.0, std::f64::consts::TAU);
                let speed = ctx.rng.uniform(0.18, 1.10);
                self.fire.push(FireParticle {
                    id,
                    impact,
                    velocity_x: angle.cos() * speed,
                    velocity_y: angle.sin() * speed + 0.35,
                    lifetime: ctx.rng.randint(28, 66),
                });
            }
        }

        let last_impact = self.planes.iter().map(|plane| plane.impact_frame).max().unwrap_or(0);
        self.end_frame =
            last_impact + self.config.debris_duration + self.config.reassembly_duration + self.config.final_hold_time;
        self.frame = 0;
        Ok(())
    }

    fn next_frame(&mut self, ctx: &mut EngineCtx) -> Option<String> {
        if self.frame > self.end_frame {
            return None;
        }
        self.update_planes(ctx);
        self.update_trails(ctx);
        self.update_debris(ctx);
        self.update_fire(ctx);
        self.frame += 1;
        Some(ctx.frame())
    }
}
