//! Malfunction: a cheerful little printer types nonsense, develops a harmless
//! paper jam, recovers, and proudly prints the input in a shower of loose type.

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
pub struct MalfunctionConfig {
    /// Frames spent waking the printer and feeding in its first sheet.
    #[arg(long = "warmup-duration", default_value_t = 65, value_parser = parse_positive_int)]
    pub warmup_duration: i64,

    /// Frames of increasingly dubious printing before the paper jam.
    #[arg(long = "printing-duration", default_value_t = 215, value_parser = parse_positive_int)]
    pub printing_duration: i64,

    /// Frames the printer rattles, glitches, and spits loose type.
    #[arg(long = "malfunction-duration", default_value_t = 125, value_parser = parse_positive_int)]
    pub malfunction_duration: i64,

    /// Frames the celebratory stream of loose type remains airborne.
    #[arg(long = "letter-flight-duration", default_value_t = 145, value_parser = parse_positive_int)]
    pub letter_flight_duration: i64,

    /// Frames in which the scattered type composes itself into the input.
    #[arg(long = "reassembly-duration", default_value_t = 165, value_parser = parse_positive_int)]
    pub reassembly_duration: i64,

    /// Frames to admire the correctly printed result.
    #[arg(long = "final-hold-time", default_value_t = 100, value_parser = parse_non_negative_int)]
    pub final_hold_time: i64,

    /// Number of colorful letters and paper flecks in the recovery celebration.
    #[arg(long = "celebration-particles", default_value_t = 105, value_parser = parse_positive_int)]
    pub celebration_particles: i64,

    /// Printer casing color.
    #[arg(long = "printer-color", default_value = "b8c4ce", value_parser = parse_color)]
    pub printer_color: Color,

    /// Color of the paper and fresh type.
    #[arg(long = "paper-color", default_value = "fff7e6", value_parser = parse_color)]
    pub paper_color: Color,

    /// Warning lamp and error-message color.
    #[arg(long = "error-color", default_value = "ff334f", value_parser = parse_color)]
    pub error_color: Color,

    /// Space separated colors for loose type, paper flecks, and happy confetti.
    #[arg(long = "letter-colors", num_args = 1.., value_parser = parse_color,
          default_values = ["ffffff", "ffe066", "ff9f1c", "ff5fa2", "7cdaff", "7ee787"])]
    pub letter_colors: Vec<Color>,

    /// Space separated colors for the final readable text.
    #[arg(long = "final-gradient-stops", num_args = 1.., value_parser = parse_color,
          default_values = ["00d9ff", "7c3aed", "ff2d95", "ff9f1c", "fff7e6"])]
    pub final_gradient_stops: Vec<Color>,

    /// Number of steps in the final text gradient.
    #[arg(long = "final-gradient-steps", num_args = 1.., value_parser = parse_gradient_steps,
          default_values = ["28"])]
    pub final_gradient_steps: Vec<i64>,

    /// Direction of the final text gradient.
    #[arg(long = "final-gradient-direction", default_value = "diagonal", value_parser = parse_gradient_direction)]
    pub final_gradient_direction: GradientDirection,
}

struct PrinterPart {
    id: CharId,
    offset: Coord,
    symbol: String,
}

struct PaperCell {
    id: CharId,
    offset: Coord,
    border: bool,
    order: f64,
}

struct LooseType {
    id: CharId,
    born: i64,
    start_x: f64,
    start_y: f64,
    velocity_x: f64,
    velocity_y: f64,
}

struct ConfettiParticle {
    id: CharId,
    delay: i64,
    velocity_x: f64,
    velocity_y: f64,
    lifetime: i64,
    color_index: usize,
    kind: usize,
}

struct TextPiece {
    id: CharId,
    home: Coord,
    scatter: Coord,
    delay: f64,
    random_symbol: String,
}

pub struct Malfunction {
    config: MalfunctionConfig,
    printer: Vec<PrinterPart>,
    paper: Vec<PaperCell>,
    loose_type: Vec<LooseType>,
    confetti: Vec<ConfettiParticle>,
    text: Vec<TextPiece>,
    text_colors: HashMap<CharId, Color>,
    anchor: Coord,
    frame: i64,
    print_start: i64,
    malfunction_start: i64,
    recovery_frame: i64,
    settle_start: i64,
    settle_end: i64,
    end_frame: i64,
}

impl Malfunction {
    pub fn new(config: MalfunctionConfig) -> Self {
        Self {
            config,
            printer: Vec::new(),
            paper: Vec::new(),
            loose_type: Vec::new(),
            confetti: Vec::new(),
            text: Vec::new(),
            text_colors: HashMap::new(),
            anchor: Coord::new(0, 0),
            frame: 0,
            print_start: 0,
            malfunction_start: 0,
            recovery_frame: 0,
            settle_start: 0,
            settle_end: 0,
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

    fn random_type(seed: u64) -> &'static str {
        const TYPE: [&str; 42] = [
            "A", "B", "C", "D", "E", "F", "G", "H", "J", "K", "M", "N", "P", "Q", "R", "S", "T", "U", "V", "W", "X",
            "Y", "Z", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "#", "%", "&", "?", "!", "@", "*", "/", "=",
        ];
        TYPE[seed as usize % TYPE.len()]
    }

    fn machine_offset(&self) -> Coord {
        if self.frame < self.malfunction_start || self.frame >= self.recovery_frame {
            return Coord::new(0, 0);
        }
        let age = self.frame - self.malfunction_start;
        let intensity = (age as f64 / self.config.malfunction_duration as f64).clamp(0.0, 1.0);
        let dx = if age % 7 < 2 {
            1
        } else if age % 7 > 4 {
            -1
        } else {
            0
        };
        let dy = if intensity > 0.55 && age % 11 == 0 { 1 } else { 0 };
        Coord::new(dx, dy)
    }

    fn update_printer(&self, ctx: &mut EngineCtx) {
        let shake = self.machine_offset();
        let dim = Color::from_hex("59636e").unwrap();
        let settle = ((self.frame - self.settle_start) as f64 / 90.0).clamp(0.0, 1.0);
        let resting_drop = (settle * settle * (3.0 - 2.0 * settle) * 5.0).round() as i64;
        let happy_age = self.frame - self.recovery_frame;
        let happy_bounce = if (0..72).contains(&happy_age) && happy_age % 18 < 5 { 1 } else { 0 };
        let happy_green = Color::from_hex("7ee787").unwrap();
        for part in &self.printer {
            let coord = Coord::new(
                self.anchor.column + part.offset.column + shake.column,
                self.anchor.row + part.offset.row + shake.row - resting_drop + happy_bounce,
            );
            ctx.terminal.arena[part.id.0 as usize].motion.set_coordinate(coord);
            let error_lamp = part.symbol == "●";
            let recovered = self.frame >= self.recovery_frame;
            let color = if error_lamp && recovered {
                happy_green
            } else if error_lamp && self.frame >= self.malfunction_start {
                if (self.frame / 5) % 2 == 0 {
                    self.config.error_color
                } else {
                    dim
                }
            } else if self.frame < self.config.warmup_duration / 2 {
                dim
            } else {
                self.config.printer_color
            };
            let symbol = if error_lamp && recovered { "♥" } else { &part.symbol };
            Self::set_visual(ctx, part.id, symbol, color, error_lamp);
            ctx.terminal.set_character_visibility(part.id, true);
        }
    }

    fn update_paper(&self, ctx: &mut EngineCtx) {
        let shake = self.machine_offset();
        let settle = ((self.frame - self.settle_start) as f64 / 90.0).clamp(0.0, 1.0);
        let resting_drop = (settle * settle * (3.0 - 2.0 * settle) * 5.0).round() as i64;
        let mut feed = if self.frame < self.print_start {
            ((self.frame as f64 / self.print_start.max(1) as f64) * 7.0).floor() as i64
        } else {
            7
        };
        if self.frame >= self.settle_start {
            feed = (feed - (self.frame - self.settle_start) / 7).max(0);
        }
        let print_progress =
            ((self.frame - self.print_start) as f64 / self.config.printing_duration as f64).clamp(0.0, 1.0);
        for cell in &self.paper {
            if cell.offset.row - 3 >= feed {
                ctx.terminal.set_character_visibility(cell.id, false);
                continue;
            }
            let jam = self.frame >= self.malfunction_start;
            let jam_age = (self.frame - self.malfunction_start).max(0);
            let skew = if jam { (cell.offset.row - 3) * (jam_age / 25).min(2) / 3 } else { 0 };
            let coord = Coord::new(
                self.anchor.column + cell.offset.column + shake.column + skew,
                self.anchor.row + cell.offset.row + shake.row - resting_drop,
            );
            ctx.terminal.arena[cell.id.0 as usize].motion.set_coordinate(coord);
            let mut symbol = if cell.border {
                ctx.terminal.arena[cell.id.0 as usize].input_symbol.clone()
            } else if cell.order <= print_progress {
                Self::random_type(cell.id.0 as u64 * 97 + (self.frame.max(0) as u64 / if jam { 3 } else { 17 }))
                    .to_string()
            } else {
                " ".to_string()
            };
            let mut color = self.config.paper_color;
            if jam && !cell.border {
                let error_band = ((cell.offset.row + 2) * 5 + cell.offset.column).rem_euclid(17) < 4;
                if error_band {
                    symbol =
                        ["E", "R", "R", "!", "#"][(cell.id.0 as usize + (self.frame / 3) as usize) % 5].to_string();
                    color = self.config.error_color;
                }
            }
            Self::set_visual(ctx, cell.id, &symbol, color, jam && !cell.border);
            ctx.terminal.set_character_visibility(cell.id, symbol != " ");
        }
    }

    fn update_loose_type(&self, ctx: &mut EngineCtx) {
        for (index, piece) in self.loose_type.iter().enumerate() {
            let age = self.frame - piece.born;
            if age < 0 || age > 80 {
                ctx.terminal.set_character_visibility(piece.id, false);
                continue;
            }
            let t = age as f64;
            let coord = Coord::new(
                (piece.start_x + piece.velocity_x * t).round() as i64,
                (piece.start_y + piece.velocity_y * t - 0.007 * t * t).round() as i64,
            );
            ctx.terminal.arena[piece.id.0 as usize].motion.set_coordinate(coord);
            let symbol = Self::random_type(index as u64 * 71 + (self.frame / 4) as u64);
            let color = if index % 6 == 0 { self.config.error_color } else { self.config.paper_color };
            Self::set_visual(ctx, piece.id, symbol, color, index % 6 == 0);
            ctx.terminal.set_character_visibility(piece.id, true);
        }
    }

    fn update_confetti(&self, ctx: &mut EngineCtx) {
        let age = self.frame - self.recovery_frame;
        for particle in &self.confetti {
            let local = age - particle.delay;
            if local < 0 || local >= particle.lifetime {
                ctx.terminal.set_character_visibility(particle.id, false);
                continue;
            }
            let t = local as f64;
            let coord = Coord::new(
                (self.anchor.column as f64 + particle.velocity_x * t).round() as i64,
                (self.anchor.row as f64 + 3.0 + particle.velocity_y * t - 0.0045 * t * t).round() as i64,
            );
            ctx.terminal.arena[particle.id.0 as usize].motion.set_coordinate(coord);
            let symbols = match particle.kind {
                0 => ["A", "?", "+", "·"],
                1 => ["▱", "▫", "~", "·"],
                _ => ["#", "%", "♥", "."],
            };
            let stage = (local * 4 / particle.lifetime.max(1)).clamp(0, 3) as usize;
            let color = self.config.letter_colors[particle.color_index];
            Self::set_visual(ctx, particle.id, symbols[stage], color, stage < 2);
            ctx.terminal.set_character_visibility(particle.id, true);
        }
    }

    fn update_text(&self, ctx: &mut EngineCtx) {
        if self.frame < self.recovery_frame {
            for piece in &self.text {
                ctx.terminal.set_character_visibility(piece.id, false);
            }
            return;
        }
        let burst_progress =
            ((self.frame - self.recovery_frame) as f64 / self.config.letter_flight_duration as f64).clamp(0.0, 1.0);
        let settle_progress =
            ((self.frame - self.settle_start) as f64 / self.config.reassembly_duration as f64).clamp(0.0, 1.0);
        let white = Color::from_hex("ffffff").unwrap();
        for (index, piece) in self.text.iter().enumerate() {
            if self.frame < self.settle_start {
                let local = ((burst_progress - piece.delay) / (1.0 - piece.delay).max(0.05)).clamp(0.0, 1.0);
                let eased = 1.0 - (1.0 - local).powi(3);
                let arc = (std::f64::consts::PI * local).sin() * (4.0 + index as f64 % 5.0);
                let coord = Coord::new(
                    (self.anchor.column as f64 + (piece.scatter.column - self.anchor.column) as f64 * eased).round()
                        as i64,
                    (self.anchor.row as f64 + (piece.scatter.row - self.anchor.row) as f64 * eased + arc).round()
                        as i64,
                );
                ctx.terminal.arena[piece.id.0 as usize].motion.set_coordinate(coord);
                let color = self.config.letter_colors[index % self.config.letter_colors.len()];
                Self::set_visual(ctx, piece.id, &piece.random_symbol, color, local < 0.45);
                ctx.terminal.set_character_visibility(piece.id, local > 0.0);
                continue;
            }

            let stagger = (piece.home.column - ctx.terminal.canvas.text_left) as f64
                / (ctx.terminal.canvas.text_right - ctx.terminal.canvas.text_left).max(1) as f64
                * 0.20;
            let local = ((settle_progress - stagger) / (1.0 - stagger).max(0.01)).clamp(0.0, 1.0);
            let eased = local * local * (3.0 - 2.0 * local);
            let wobble = (local * std::f64::consts::TAU + index as f64).sin() * (1.0 - local) * 0.8;
            let coord = Coord::new(
                (piece.scatter.column as f64 + (piece.home.column - piece.scatter.column) as f64 * eased + wobble)
                    .round() as i64,
                (piece.scatter.row as f64 + (piece.home.row - piece.scatter.row) as f64 * eased).round() as i64,
            );
            ctx.terminal.arena[piece.id.0 as usize].motion.set_coordinate(coord);
            let input = ctx.terminal.arena[piece.id.0 as usize].input_symbol.clone();
            let symbol = if local < 0.58 { &piece.random_symbol } else { &input };
            let base = self.text_colors[&piece.id];
            let debris_color = self.config.letter_colors[index % self.config.letter_colors.len()];
            let color_progress = local * local * (3.0 - 2.0 * local);
            let color = if local > 0.92 && (self.frame + piece.id.0 as i64 * 11) % 61 < 2 {
                white
            } else {
                shift_color_towards(&debris_color, &base, color_progress).unwrap()
            };
            Self::set_visual(ctx, piece.id, symbol, color, local > 0.68);
            ctx.terminal.set_character_visibility(piece.id, true);
        }
    }
}

impl EffectHooks for Malfunction {
    fn dispatch_callback(&mut self, _ctx: &mut EngineCtx, _character: CharId, _callback: &EffectCallback) {}
}

impl Effect for Malfunction {
    fn build(&mut self, ctx: &mut EngineCtx) -> Result<(), EngineError> {
        let left = ctx.terminal.canvas.left;
        let right = ctx.terminal.canvas.right;
        let bottom = ctx.terminal.canvas.bottom;
        let top = ctx.terminal.canvas.top;
        self.anchor = Coord::new((left + right) / 2, bottom + ((top - bottom) as f64 * 0.34) as i64);

        self.print_start = self.config.warmup_duration;
        self.malfunction_start = self.print_start + self.config.printing_duration;
        self.recovery_frame = self.malfunction_start + self.config.malfunction_duration;
        self.settle_start = self.recovery_frame + self.config.letter_flight_duration;
        self.settle_end = self.settle_start + self.config.reassembly_duration;
        self.end_frame = self.settle_end + self.config.final_hold_time;

        let machine = [
            "     ╭─────────────────────────╮     ",
            "╭────┤  ▒▒ PRINT-O-MATIC ▒▒    ├────╮",
            "│    ╰─────────────────────────╯    │",
            "├───────────────────────────────────┤",
            "│ [■]    ═══════════════════   ◉  ● │",
            "╰───────────────────────────────────╯",
        ];
        for (line_index, line) in machine.iter().enumerate() {
            let row = 2 - line_index as i64;
            let width = line.chars().count() as i64;
            for (column, symbol) in line.chars().enumerate() {
                if symbol == ' ' {
                    continue;
                }
                let offset = Coord::new(column as i64 - width / 2, row);
                let id = ctx.terminal.add_character(
                    &symbol.to_string(),
                    Coord::new(self.anchor.column + offset.column, self.anchor.row + offset.row),
                );
                ctx.terminal.arena[id.0 as usize].layer = 5;
                ctx.terminal.set_character_visibility(id, false);
                self.printer.push(PrinterPart { id, offset, symbol: symbol.to_string() });
            }
        }

        // The sheet sits one cell inside the raised paper guide in the shared
        // 37-cell machine artwork above.
        let paper_width = 25_i64;
        let paper_height = 7_i64;
        for row in 0..paper_height {
            for column in 0..paper_width {
                let border = row == paper_height - 1 || column == 0 || column == paper_width - 1;
                let symbol = if row == paper_height - 1 {
                    if column == 0 {
                        "╭"
                    } else if column == paper_width - 1 {
                        "╮"
                    } else {
                        "─"
                    }
                } else if column == 0 || column == paper_width - 1 {
                    "│"
                } else {
                    " "
                };
                let offset = Coord::new(column - paper_width / 2, 3 + row);
                let id = ctx.terminal.add_character(
                    symbol,
                    Coord::new(self.anchor.column + offset.column, self.anchor.row + offset.row),
                );
                ctx.terminal.arena[id.0 as usize].layer = 3;
                ctx.terminal.set_character_visibility(id, false);
                let line_order = (paper_height - 1 - row) as f64 / paper_height as f64;
                let across = column as f64 / paper_width as f64 * 0.12;
                self.paper.push(PaperCell { id, offset, border, order: (line_order * 0.88 + across).min(1.0) });
            }
        }

        for index in 0..58 {
            let born = self.malfunction_start + index as i64 * 2 + ctx.rng.randint(0, 14);
            let id = ctx.terminal.add_character("?", self.anchor);
            ctx.terminal.arena[id.0 as usize].layer = 6;
            ctx.terminal.set_character_visibility(id, false);
            self.loose_type.push(LooseType {
                id,
                born,
                start_x: self.anchor.column as f64 + ctx.rng.uniform(-9.0, 9.0),
                start_y: self.anchor.row as f64 - 1.0,
                velocity_x: ctx.rng.uniform(-0.18, 0.18),
                velocity_y: ctx.rng.uniform(-0.05, 0.16),
            });
        }

        for index in 0..self.config.celebration_particles as usize {
            let id = ctx.terminal.add_character("*", Coord::new(self.anchor.column, self.anchor.row + 3));
            ctx.terminal.arena[id.0 as usize].layer = 7;
            ctx.terminal.set_character_visibility(id, false);
            self.confetti.push(ConfettiParticle {
                id,
                delay: ctx.rng.randint(0, 88),
                velocity_x: ctx.rng.uniform(-0.24, 0.24),
                velocity_y: ctx.rng.uniform(0.20, 0.46),
                lifetime: ctx.rng.randint(58, 125),
                color_index: index % self.config.letter_colors.len(),
                kind: index % 3,
            });
        }

        let ids = ctx.terminal.get_characters(
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
        for (index, id) in ids.into_iter().enumerate() {
            let home = ctx.terminal.arena[id.0 as usize].input_coord;
            let scatter = Coord::new(ctx.rng.randint(left, right + 1), ctx.rng.randint(bottom, top + 1));
            ctx.terminal.arena[id.0 as usize].layer = 8;
            ctx.terminal.set_character_visibility(id, false);
            self.text_colors.insert(id, *mapping.get(&home).expect("malfunction gradient coordinate"));
            self.text.push(TextPiece {
                id,
                home,
                scatter,
                delay: (index % 31) as f64 / 310.0,
                random_symbol: Self::random_type(id.0 as u64 * 113 + index as u64).to_string(),
            });
        }
        self.frame = 0;
        Ok(())
    }

    fn next_frame(&mut self, ctx: &mut EngineCtx) -> Option<String> {
        if self.frame > self.end_frame {
            return None;
        }
        self.update_printer(ctx);
        self.update_paper(ctx);
        self.update_loose_type(ctx);
        self.update_confetti(ctx);
        self.update_text(ctx);
        self.frame += 1;
        Some(ctx.frame())
    }
}
