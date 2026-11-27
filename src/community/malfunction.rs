//! malfunction: a cheerful little printer types nonsense, develops a harmless
//! paper jam, recovers, and proudly prints the input in a shower of loose type.
//!
//! Original effect by Lukas Innig (@derluke), https://github.com/derluke/ttfx, MIT.
//! Rewritten for the fx engine: the timeline is a function of the frame
//! number, so every character is placed and painted directly each frame (no
//! scenes or paths).
//!
//! The story, beat by beat: the printer sits just below where the text will
//! appear. It powers up and feeds a sheet, then prints gibberish line by line
//! (each line typed left to right, the sheet rising as it goes, the lines
//! getting more dubious). The jam builds: the shaking, the lamp, the torn and
//! corrupted sheet and the sputtering loose type all ramp up until the sheet
//! bursts into a shower of type and confetti over the canvas. The relieved
//! printer then prints the input for real: the loose type lands in print
//! order, line by line and left to right, each letter flashing as it lands
//! (its display counts the percentage), and the printer sinks off the bottom,
//! so the run ends on the input text. Particle counts, speeds and the shower's
//! reach scale with the canvas.

use clap::Args;

use crate::cli::parse_color;
use crate::effects::common::{
    parse_gradient_direction, parse_gradient_steps, parse_non_negative_int, parse_positive_int,
};
use crate::engine::animation::ExistingColorHandling;
use crate::engine::error::EngineError;
use crate::engine::terminal::{CharacterFilter, CharacterSort};
use crate::fx::run::Effect;
use crate::fx::visual::{VisualInfo, BOLD, HAS_COLORS};
use crate::fx::{Engine, Hooks, Sym, Visual};
use crate::utils::geometry::Coord;
use crate::utils::graphics::{shift_color_towards, Color, Gradient, GradientDirection};

use std::f64::consts::PI;

#[derive(Args, Debug, Clone)]
pub struct MalfunctionConfig {
    /// Frames spent waking the printer and feeding in its first sheet.
    #[arg(long = "warmup-duration", default_value_t = 90, value_parser = parse_positive_int)]
    pub warmup_duration: i64,

    /// Frames of increasingly dubious printing before the paper jam.
    #[arg(long = "printing-duration", default_value_t = 250, value_parser = parse_positive_int)]
    pub printing_duration: i64,

    /// Frames the printer rattles, glitches, and spits loose type.
    #[arg(long = "malfunction-duration", default_value_t = 210, value_parser = parse_positive_int)]
    pub malfunction_duration: i64,

    /// Frames the celebratory stream of loose type remains airborne.
    #[arg(long = "letter-flight-duration", default_value_t = 190, value_parser = parse_positive_int)]
    pub letter_flight_duration: i64,

    /// Frames in which the scattered type composes itself into the input.
    #[arg(long = "reassembly-duration", default_value_t = 340, value_parser = parse_positive_int)]
    pub reassembly_duration: i64,

    /// Frames to admire the correctly printed result.
    #[arg(long = "final-hold-time", default_value_t = 280, value_parser = parse_non_negative_int)]
    pub final_hold_time: i64,

    /// Number of colorful letters and paper flecks in the recovery celebration
    /// (scaled up on large canvases, at most 4096).
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

/// The casing; the display window (row 1, columns 6..=30) is drawn per frame.
const MACHINE: [&str; 6] = [
    "     ╭─────────────────────────╮     ",
    "╭────┤                         ├────╮",
    "│    ╰─────────────────────────╯    │",
    "├───────────────────────────────────┤",
    "│ [■]    ═══════════════════   ◉  ● │",
    "╰───────────────────────────────────╯",
];
const MACHINE_HALF: i64 = 18;
const DISPLAY_LEFT: i64 = 6;
const DISPLAY_WIDTH: usize = 25;
const PAPER_WIDTH: i64 = 25;
/// Printed lines on the sheet (plus its top edge).
const PAPER_LINES: i64 = 6;
/// Fraction of a line's time the print head spends typing it.
const LINE_TYPING: f64 = 0.85;
/// Frames the finished printer takes to sink off the canvas.
const EXIT_FRAMES: i64 = 60;
const MAX_CONFETTI: i64 = 4096;
/// The final frames hold clean on the settled text with all helpers hidden.
const QUIET_TAIL: i64 = 6;
/// Quantization of color blends (visual pool size).
const BLEND_STEPS: f64 = 16.0;
/// Fraction of the reassembly each letter spends flying home.
const HOMING_WINDOW: f64 = 0.24;
/// Fraction of the letter flight spent launching; the rest is hovering.
const LAUNCH_SPAN: f64 = 0.55;
/// Frames a landed letter flashes white, then fades into its color.
const LAND_FLASH: f64 = 4.0;
const LAND_FADE: f64 = 26.0;

const TYPE: [&str; 42] = [
    "A", "B", "C", "D", "E", "F", "G", "H", "J", "K", "M", "N", "P", "Q", "R", "S", "T", "U", "V",
    "W", "X", "Y", "Z", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "#", "%", "&", "?", "!",
    "@", "*", "/", "=",
];
const ERR: [&str; 10] = ["E", "R", "R", "!", "#", "▒", "░", "▓", "?", "%"];
const CONFETTI: [[&str; 4]; 3] = [
    ["A", "?", "+", "·"],
    ["▱", "▫", "~", "·"],
    ["#", "%", "♥", "."],
];

struct PrinterPart {
    slot: u32,
    offset: Coord,
    sym: Sym,
    lamp: bool,
}

struct PaperCell {
    slot: u32,
    column: i64,
    row: i64,
}

#[derive(Clone, Copy)]
enum ProofKind {
    Edge,
    Body { ok_accent: bool, muted: bool },
}

struct ProofCell {
    slot: u32,
    dx: i64,
    dy: i64,
    sym: Sym,
    kind: ProofKind,
}

struct LooseType {
    slot: u32,
    born: i64,
    life: i64,
    start_x: f64,
    start_y: f64,
    velocity_x: f64,
    velocity_y: f64,
    red: bool,
}

struct Confetti {
    slot: u32,
    delay: i64,
    velocity_x: f64,
    velocity_y: f64,
    lifetime: i64,
    color_index: usize,
    kind: usize,
}

struct TextPiece {
    slot: u32,
    id: i64,
    home: Coord,
    /// Where on the jammed sheet it bursts from.
    origin: (f64, f64),
    /// Where it hangs in the air after the burst.
    scatter: (f64, f64),
    /// Launch delay, as a fraction of the letter flight.
    delay: f64,
    arc: f64,
    phase: f64,
    /// Start of its flight home, as a fraction of the reassembly (print order).
    start: f64,
    /// Normalized diagonal coordinate (0..1) for the ink-dry shimmer.
    diag: f64,
    base: Color,
    debris: Color,
    settled: Visual,
    /// The bright white of a landing flash.
    flash: Visual,
}

pub struct Malfunction {
    config: MalfunctionConfig,
    printer: Vec<PrinterPart>,
    display: Vec<u32>,
    paper: Vec<PaperCell>,
    proof_sheet: Vec<ProofCell>,
    loose_type: Vec<LooseType>,
    confetti: Vec<Confetti>,
    text: Vec<TextPiece>,
    type_syms: Vec<Sym>,
    err_syms: Vec<Sym>,
    confetti_syms: [[Sym; 4]; 3],
    edge_syms: [Sym; 4],
    heart_sym: Sym,
    lamp_off_sym: Sym,
    anchor: Coord,
    canvas_left: i64,
    canvas_right: i64,
    proof_row: i64,
    proof_width: i64,
    /// Rows the printer sinks to leave the canvas.
    exit_drop: i64,
    gravity: f64,
    confetti_gravity: f64,
    frame: i64,
    print_start: i64,
    malfunction_start: i64,
    recovery_frame: i64,
    settle_start: i64,
    settle_end: i64,
    exit_start: i64,
    exit_end: i64,
    flourish_end: i64,
    end_frame: i64,
}

fn shift(from: &Color, to: &Color, factor: f64) -> Color {
    let factor = (factor.clamp(0.0, 1.0) * BLEND_STEPS).round() / BLEND_STEPS;
    shift_color_towards(from, to, factor).unwrap_or(*to)
}

/// The visual for an effect color, or the input's colors under
/// --existing-color-handling always for a character that has them.
fn paint(e: &mut Engine, slot: u32, sym: Sym, color: Color, bold: bool) -> Visual {
    paint_bg(e, slot, sym, color, None, bold)
}

fn paint_bg(
    e: &mut Engine,
    slot: u32,
    sym: Sym,
    fg: Color,
    bg: Option<Color>,
    bold: bool,
) -> Visual {
    let mut info = VisualInfo {
        sym,
        fg: Some(fg),
        bg,
        attrs: HAS_COLORS | if bold { BOLD } else { 0 },
    };
    if e.existing_color_handling() == ExistingColorHandling::Always
        && e.uses_preexisting_colors(slot)
    {
        info.fg = e.input_fg(slot);
        info.bg = e.input_bg(slot);
        info.attrs = HAS_COLORS | if e.input_bold(slot) { BOLD } else { 0 };
    }
    e.visuals.make(&e.symbols, info)
}

fn smoothstep(t: f64) -> f64 {
    let t = t.clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

/// A deterministic hash, for per-frame flicker that needs no RNG state.
fn hash(mut x: u64) -> u64 {
    x = x.wrapping_add(0x9e37_79b9_7f4a_7c15);
    x = (x ^ (x >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
    x = (x ^ (x >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
    x ^ (x >> 31)
}

fn unit(x: u64) -> f64 {
    (hash(x) >> 11) as f64 / (1u64 << 53) as f64
}

fn key(a: i64, b: i64, c: i64) -> u64 {
    (a as u64)
        .wrapping_mul(0x1_0000_01b3)
        .wrapping_add((b as u64).wrapping_mul(0x9e37))
        .wrapping_add((c as u64).wrapping_mul(0x85eb_ca6b))
}

impl Malfunction {
    pub fn new(config: MalfunctionConfig) -> Self {
        Malfunction {
            config,
            printer: Vec::new(),
            display: Vec::new(),
            paper: Vec::new(),
            proof_sheet: Vec::new(),
            loose_type: Vec::new(),
            confetti: Vec::new(),
            text: Vec::new(),
            type_syms: Vec::new(),
            err_syms: Vec::new(),
            confetti_syms: [[Sym(0); 4]; 3],
            edge_syms: [Sym(0); 4],
            heart_sym: Sym(0),
            lamp_off_sym: Sym(0),
            anchor: Coord::new(0, 0),
            canvas_left: 0,
            canvas_right: 0,
            proof_row: 0,
            proof_width: 0,
            exit_drop: 0,
            gravity: 0.012,
            confetti_gravity: 0.006,
            frame: 0,
            print_start: 0,
            malfunction_start: 0,
            recovery_frame: 0,
            settle_start: 0,
            settle_end: 0,
            exit_start: 0,
            exit_end: 0,
            flourish_end: 0,
            end_frame: 0,
        }
    }

    fn random_type(&self, seed: u64) -> Sym {
        self.type_syms[(hash(seed) % self.type_syms.len() as u64) as usize]
    }

    /// How far into the jam, 0..1 (0 outside it).
    fn jam(&self) -> f64 {
        if self.frame < self.malfunction_start || self.frame >= self.recovery_frame {
            return 0.0;
        }
        ((self.frame - self.malfunction_start) as f64 / self.config.malfunction_duration as f64)
            .clamp(0.0, 1.0)
    }

    /// The rattle builds with the jam: wider, faster, and finally jumping.
    fn machine_offset(&self) -> Coord {
        if self.frame < self.malfunction_start || self.frame >= self.recovery_frame {
            return Coord::new(0, 0);
        }
        let age = self.frame - self.malfunction_start;
        let i = self.jam();
        let amp = 0.35 + 1.9 * i.powf(1.5);
        let wave = (age as f64 * (0.9 + 1.4 * i)).sin();
        let noise = unit(key(age, 1, 77)) - 0.5;
        let dx = ((wave + noise) * amp).round() as i64;
        let dy = (i > 0.55 && hash(key(age, 2, 91)) % 9 < (2.0 + 5.0 * i) as u64) as i64;
        Coord::new(dx, dy)
    }

    /// Vertical motion of the printer: a recoil and happy hops after the
    /// burst, a proud confirmation bounce at settle, then the sink off canvas.
    fn lift(&self) -> i64 {
        let happy = self.frame - self.recovery_frame;
        let mut lift = 0;
        if (0..5).contains(&happy) {
            lift = -1;
        } else if (8..80).contains(&happy) && (happy - 8) % 18 < 5 {
            lift = 1;
        }
        if self.flourish_end > self.settle_end
            && self.frame >= self.settle_end
            && self.frame < self.exit_start
        {
            let since = self.frame - self.settle_end;
            if (2..9).contains(&since) {
                lift = 1;
            }
        }
        if self.frame >= self.exit_start {
            let dur = (self.exit_end - self.exit_start).max(1) as f64;
            let t = ((self.frame - self.exit_start) as f64 / dur).clamp(0.0, 1.0);
            lift -= (t * t * self.exit_drop as f64).round() as i64;
        }
        lift
    }

    fn machine_gone(&self) -> bool {
        self.frame >= self.exit_end
    }

    /// True when the post-settle OK status LED is on its bright pulse.
    fn ok_led_on(&self) -> bool {
        let since = (self.frame - self.settle_end).max(0);
        // Three crisp OK blinks (14 on / 14 off), then steady green.
        since >= 84 || (since / 14) % 2 == 0
    }

    fn update_printer(&self, e: &mut Engine) {
        if self.machine_gone() {
            for part in &self.printer {
                e.set_visible(part.slot, false);
            }
            return;
        }
        let dim = Color::from_rgb(0x59, 0x63, 0x6e);
        let happy_green = Color::from_rgb(0x7e, 0xe7, 0x87);
        let dim_green = Color::from_rgb(0x2d, 0x6a, 0x3e);
        let led_halo = Color::from_rgb(0x14, 0x38, 0x22);
        let shake = self.machine_offset();
        let lift = self.lift();
        let recovered = self.frame >= self.recovery_frame;
        let settled = self.frame >= self.settle_end;
        let jam = self.jam();
        let warm = self.config.warmup_duration as f64;
        // power-up: a few flickers, then the casing brightens
        let power = smoothstep(self.frame as f64 / (warm * 0.6).max(1.0));
        let flicker = (self.frame as f64) < warm * 0.35 && hash(key(self.frame / 3, 5, 3)) % 3 == 0;
        let mut casing = if flicker {
            dim
        } else {
            shift(&dim, &self.config.printer_color, power)
        };
        // the casing glows hot as the jam peaks
        if jam > 0.0 {
            let pulse = 0.5 + 0.5 * (self.frame as f64 * 0.35).sin();
            casing = shift(&casing, &self.config.error_color, jam * jam * 0.55 * pulse);
        } else if settled && self.flourish_end > self.settle_end && self.ok_led_on() {
            let since = (self.frame - self.settle_end) as f64;
            let fade = (1.0 - since / 90.0).clamp(0.0, 1.0);
            casing = shift(&casing, &happy_green, 0.14 * fade);
        }
        // the lamp blinks faster and faster through the jam
        let period = (12.0 - 9.0 * jam).round().max(2.0) as i64;
        let lamp_on = (self.frame - self.malfunction_start).rem_euclid(period * 2) < period;
        let ok_on = self.ok_led_on();
        for part in &self.printer {
            let coord = Coord::new(
                self.anchor.column + part.offset.column + shake.column,
                self.anchor.row + part.offset.row + shake.row + lift,
            );
            let (sym, color, bg, bold) = if part.lamp && settled {
                if self.flourish_end > self.settle_end && !ok_on {
                    (self.lamp_off_sym, dim_green, None, false)
                } else {
                    (part.sym, happy_green, Some(led_halo), true)
                }
            } else if part.lamp && recovered {
                (self.heart_sym, happy_green, None, true)
            } else if part.lamp && self.frame >= self.malfunction_start {
                (
                    part.sym,
                    if lamp_on {
                        self.config.error_color
                    } else {
                        dim
                    },
                    None,
                    true,
                )
            } else {
                (part.sym, casing, None, part.lamp)
            };
            let visual = paint_bg(e, part.slot, sym, color, bg, bold);
            e.set_visual(part.slot, visual);
            e.set_coordinate(part.slot, coord);
            e.set_visible(part.slot, true);
        }
    }

    /// The display window's message: (text, color, glitch amount).
    fn display_message(&self) -> (String, Color, f64) {
        let green = Color::from_rgb(0x7e, 0xe7, 0x87);
        let soft_green = Color::from_rgb(0x48, 0xa8, 0x68);
        let warm = self.config.warmup_duration;
        let f = self.frame;
        if f < warm / 2 {
            (String::new(), self.config.printer_color, 0.0)
        } else if f < self.print_start {
            ("PRINT-O-MATIC".into(), self.config.paper_color, 0.0)
        } else if f < self.malfunction_start {
            let dots = ((f - self.print_start) / 18 % 4) as usize;
            (
                format!("PRINTING{:<3}", ".".repeat(dots)),
                self.config.paper_color,
                0.0,
            )
        } else if f < self.recovery_frame {
            let jam = self.jam();
            let period = (12.0 - 9.0 * jam).round().max(2.0) as i64;
            let on = (f - self.malfunction_start).rem_euclid(period * 2) < period;
            let text = if jam < 0.25 {
                "PAPER JAM?"
            } else {
                "!! PAPER JAM !!"
            };
            if on {
                (
                    text.into(),
                    self.config.error_color,
                    ((jam - 0.5) * 1.4).max(0.0),
                )
            } else {
                (String::new(), self.config.error_color, 0.0)
            }
        } else if f < self.settle_start {
            ("♥ ALL BETTER ♥".into(), green, 0.0)
        } else if f < self.settle_end {
            let progress = (f - self.settle_start) as f64 / self.config.reassembly_duration as f64;
            let pct = (progress * 100.0).floor().clamp(0.0, 99.0) as i64;
            (format!("PRINTING {pct:>2}%"), green, 0.0)
        } else if self.flourish_end > self.settle_end && f < self.exit_start {
            if self.ok_led_on() {
                ("● OK · JOB COMPLETE".into(), green, 0.0)
            } else {
                ("○ OK · JOB COMPLETE".into(), soft_green, 0.0)
            }
        } else {
            ("✓ PRINT OK".into(), green, 0.0)
        }
    }

    fn update_display(&self, e: &mut Engine) {
        if self.machine_gone() {
            for &slot in &self.display {
                e.set_visible(slot, false);
            }
            return;
        }
        let (text, color, glitch) = self.display_message();
        let chars: Vec<char> = text.chars().collect();
        let pad = DISPLAY_WIDTH.saturating_sub(chars.len()) / 2;
        let shake = self.machine_offset();
        let lift = self.lift();
        for (k, &slot) in self.display.iter().enumerate() {
            // blank cells stay drawn, so the window hides the type behind it
            let ch = k
                .checked_sub(pad)
                .and_then(|i| chars.get(i))
                .copied()
                .unwrap_or(' ');
            let sym =
                if glitch > 0.0 && ch != ' ' && unit(key(k as i64, self.frame / 3, 17)) < glitch {
                    self.err_syms
                        [(hash(key(k as i64, self.frame, 4)) % self.err_syms.len() as u64) as usize]
                } else {
                    e.symbols.intern_char(ch)
                };
            let visual = paint(e, slot, sym, color, true);
            e.set_visual(slot, visual);
            e.set_coordinate(
                slot,
                Coord::new(
                    self.anchor.column + DISPLAY_LEFT + k as i64 - MACHINE_HALF + shake.column,
                    self.anchor.row + 1 + shake.row + lift,
                ),
            );
            e.set_visible(slot, true);
        }
    }

    /// Gibberish printed on the sheet: line `line`, column `column` (inner).
    fn printed(&self, line: i64, column: i64) -> Option<(Sym, bool)> {
        let h = hash(key(line, column, 4242));
        if h % 100 < 13 {
            return None; // word gaps
        }
        // later lines get more dubious
        let dubious = line as f64 / (PAPER_LINES - 1) as f64 * 0.22;
        if unit(h) < dubious {
            let k = (h >> 20) as usize % self.err_syms.len();
            return Some((self.err_syms[k], true));
        }
        Some((self.random_type(h >> 7), false))
    }

    fn update_paper(&self, e: &mut Engine) {
        let warm = self.config.warmup_duration;
        let hidden = self.frame < warm / 2 || self.frame >= self.recovery_frame;
        if hidden {
            for cell in &self.paper {
                e.set_visible(cell.slot, false);
            }
            return;
        }
        // lines fed out of the printer, the line being typed, and its head
        let (fed, typing, head) = if self.frame < self.print_start {
            (0, -1, 0)
        } else if self.frame < self.malfunction_start {
            let per_line = self.config.printing_duration as f64 / PAPER_LINES as f64;
            let t = (self.frame - self.print_start) as f64;
            let line = ((t / per_line).floor() as i64).clamp(0, PAPER_LINES - 1);
            let frac = (t - line as f64 * per_line) / per_line;
            let head = ((frac / LINE_TYPING) * (PAPER_WIDTH - 2) as f64).floor() as i64;
            (line + 1, line, head.clamp(0, PAPER_WIDTH - 2))
        } else {
            (PAPER_LINES, PAPER_LINES, 0)
        };
        let shake = self.machine_offset();
        let jam = self.jam();
        let age = (self.frame - self.malfunction_start).max(0);
        let white = Color::from_rgb(0xff, 0xff, 0xff);
        for cell in &self.paper {
            let (row, column) = (cell.row, cell.column);
            if row > fed {
                e.set_visible(cell.slot, false);
                continue;
            }
            let inner = column > 0 && column < PAPER_WIDTH - 1;
            let mut color = self.config.paper_color;
            let mut bold = false;
            let mut sym = if row == fed {
                Some(if column == 0 {
                    self.edge_syms[0]
                } else if column == PAPER_WIDTH - 1 {
                    self.edge_syms[1]
                } else {
                    self.edge_syms[2]
                })
            } else if !inner {
                Some(self.edge_syms[3])
            } else {
                let line = fed - 1 - row;
                let done = line < typing || (line == typing && column - 1 < head);
                if done {
                    self.printed(line, column).map(|(s, err)| {
                        if err {
                            color = self.config.error_color;
                        }
                        if line == typing && column == head {
                            color = white;
                            bold = true;
                        }
                        s
                    })
                } else {
                    None
                }
            };
            let mut dx = 0;
            if jam > 0.0 {
                // the sheet crumples: rows jitter and lean, type corrupts,
                // and late in the jam the paper tears
                let wobble = unit(key(row, age / 5, 9)) - 0.5;
                dx = (wobble * 2.0 * jam * 2.6 + row as f64 * jam * jam * 0.45).round() as i64;
                if inner && row < fed && unit(key(cell.slot as i64, age / 4, 21)) < jam * 0.6 {
                    let k = hash(key(cell.slot as i64, age / 3, 8)) as usize % self.err_syms.len();
                    sym = Some(self.err_syms[k]);
                    color = self.config.error_color;
                    bold = true;
                }
                if unit(key(cell.slot as i64, 3, 33)) < (jam - 0.55) * 1.1 {
                    sym = None;
                }
            }
            let Some(sym) = sym else {
                e.set_visible(cell.slot, false);
                continue;
            };
            let visual = paint(e, cell.slot, sym, color, bold);
            e.set_visual(cell.slot, visual);
            e.set_coordinate(
                cell.slot,
                Coord::new(
                    self.anchor.column + column - PAPER_WIDTH / 2 + shake.column + dx,
                    self.anchor.row + 3 + row + shake.row,
                ),
            );
            e.set_visible(cell.slot, true);
        }
    }

    fn update_loose_type(&self, e: &mut Engine) {
        for (index, piece) in self.loose_type.iter().enumerate() {
            let age = self.frame - piece.born;
            if !(0..piece.life).contains(&age) {
                e.set_visible(piece.slot, false);
                continue;
            }
            let t = age as f64;
            let coord = Coord::new(
                (piece.start_x + piece.velocity_x * t).round() as i64,
                (piece.start_y + piece.velocity_y * t - 0.5 * self.gravity * t * t).round() as i64,
            );
            let sym = self.random_type(index as u64 * 71 + (self.frame / 5) as u64);
            let color = if piece.red {
                self.config.error_color
            } else {
                self.config.paper_color
            };
            let visual = paint(e, piece.slot, sym, color, piece.red);
            e.set_visual(piece.slot, visual);
            e.set_coordinate(piece.slot, coord);
            e.set_visible(piece.slot, true);
        }
    }

    fn update_confetti(&self, e: &mut Engine) {
        let age = self.frame - self.recovery_frame;
        if age < 0 {
            return;
        }
        let origin_x = self.anchor.column as f64;
        let origin_y = (self.anchor.row + 3 + PAPER_LINES / 2) as f64;
        for particle in &self.confetti {
            let local = age - particle.delay;
            if local < 0 || local >= particle.lifetime {
                e.set_visible(particle.slot, false);
                continue;
            }
            let t = local as f64;
            // air drag slows the sideways spread
            let spread = (1.0 - (-t / 45.0).exp()) * 45.0;
            let coord = Coord::new(
                (origin_x + particle.velocity_x * spread).round() as i64,
                (origin_y + particle.velocity_y * t - 0.5 * self.confetti_gravity * t * t).round()
                    as i64,
            );
            let stage = (local * 4 / particle.lifetime.max(1)).clamp(0, 3) as usize;
            let sym = self.confetti_syms[particle.kind][stage];
            let color = self.config.letter_colors[particle.color_index];
            let visual = paint(e, particle.slot, sym, color, stage < 2);
            e.set_visual(particle.slot, visual);
            e.set_coordinate(particle.slot, coord);
            e.set_visible(particle.slot, true);
        }
    }

    /// Where a burst letter is in the air (None before it launches).
    fn airborne(&self, piece: &TextPiece) -> Option<(f64, f64)> {
        let flight =
            (self.frame - self.recovery_frame) as f64 / self.config.letter_flight_duration as f64;
        if flight < piece.delay {
            return None;
        }
        let u = ((flight - piece.delay) / LAUNCH_SPAN).clamp(0.0, 1.0);
        let eased = 1.0 - (1.0 - u).powi(3);
        let f = self.frame as f64;
        let drift_x = (f * 0.031 + piece.phase).sin() * 1.3 * eased;
        let drift_y = (f * 0.023 + piece.phase * 1.7).sin() * 0.6 * eased;
        Some((
            piece.origin.0 + (piece.scatter.0 - piece.origin.0) * eased + drift_x,
            piece.origin.1
                + (piece.scatter.1 - piece.origin.1) * eased
                + piece.arc * (PI * u).sin()
                + drift_y,
        ))
    }

    /// The last sheet (a crisp proof slip) slides out horizontally under the
    /// logo as the printer finishes its OK blink, pauses while the ink dries,
    /// and glides cleanly off to the right.
    fn update_proof_sheet(&self, e: &mut Engine) {
        if self.proof_sheet.is_empty() || self.flourish_end <= self.settle_end {
            for cell in &self.proof_sheet {
                e.set_visible(cell.slot, false);
            }
            return;
        }
        let avail = self.flourish_end - self.settle_end;
        let sheet_start = self.settle_end + (avail * 14) / 100;
        let sheet_in_end = self.settle_end + (avail * 44) / 100;
        let sheet_hold_end = self.settle_end + (avail * 70) / 100;
        let sheet_out_end = self.settle_end + (avail * 94) / 100;

        if self.frame < sheet_start || self.frame >= sheet_out_end {
            for cell in &self.proof_sheet {
                e.set_visible(cell.slot, false);
            }
            return;
        }

        let canvas_w = (self.canvas_right - self.canvas_left + 1).max(1) as f64;
        let in_dist = (self.proof_width as f64 * 0.55).min(24.0);
        let out_dist = (self.proof_width as f64 * 0.75 + 10.0).min((canvas_w * 0.35).max(20.0));

        let (x_offset, alpha) = if self.frame < sheet_in_end {
            let dur = (sheet_in_end - sheet_start).max(1) as f64;
            let u = ((self.frame - sheet_start) as f64 / dur).clamp(0.0, 1.0);
            let eased = 1.0 - (1.0 - u).powi(3);
            (
                (-in_dist * (1.0 - eased)).round() as i64,
                smoothstep((u * 2.4).min(1.0)),
            )
        } else if self.frame < sheet_hold_end {
            (0, 1.0)
        } else {
            let dur = (sheet_out_end - sheet_hold_end).max(1) as f64;
            let u = ((self.frame - sheet_hold_end) as f64 / dur).clamp(0.0, 1.0);
            let eased = u * u;
            let fade = 1.0 - smoothstep(((u - 0.30) / 0.70).clamp(0.0, 1.0));
            ((out_dist * eased).round() as i64, fade)
        };

        if alpha <= 0.04 {
            for cell in &self.proof_sheet {
                e.set_visible(cell.slot, false);
            }
            return;
        }

        let black = Color::from_rgb(0x00, 0x00, 0x00);
        let paper_full = shift(&black, &self.config.paper_color, 0.88);
        let paper = shift(&black, &paper_full, alpha);
        let ink = shift(&black, &Color::from_rgb(0x1b, 0x20, 0x28), alpha);
        let ok_ink = shift(&black, &Color::from_rgb(0x12, 0x73, 0x34), alpha);
        let muted_ink = shift(&black, &Color::from_rgb(0x88, 0x80, 0x72), alpha);

        for cell in &self.proof_sheet {
            let col = self.anchor.column + cell.dx + x_offset;
            if col < self.canvas_left || col > self.canvas_right {
                e.set_visible(cell.slot, false);
                continue;
            }
            let coord = Coord::new(col, self.proof_row + cell.dy);
            let visual = match cell.kind {
                ProofKind::Edge => paint_bg(e, cell.slot, cell.sym, paper, None, false),
                ProofKind::Body { ok_accent, muted } => {
                    let fg = if ok_accent {
                        ok_ink
                    } else if muted {
                        muted_ink
                    } else {
                        ink
                    };
                    paint_bg(e, cell.slot, cell.sym, fg, Some(paper), !muted)
                }
            };
            e.set_visual(cell.slot, visual);
            e.set_coordinate(cell.slot, coord);
            e.set_visible(cell.slot, true);
        }
    }

    fn update_text(&self, e: &mut Engine) {
        if self.frame < self.recovery_frame {
            return;
        }
        let white = Color::from_rgb(0xff, 0xff, 0xff);
        let black = Color::from_rgb(0x00, 0x00, 0x00);
        let reassembly = self.config.reassembly_duration as f64;
        let settle = (self.frame - self.settle_start) as f64 / reassembly;
        let dusk = Color::from_rgb(0x30, 0x34, 0x44);
        let step_back = (settle * 3.0).clamp(0.0, 1.0) * 0.45;
        let shimmer_start = self.settle_end + 8;
        let shimmer_active = self.flourish_end > shimmer_start
            && self.frame >= shimmer_start
            && self.frame < self.flourish_end;
        let (front1, front2, show_second, env) = if shimmer_active {
            let dur = (self.flourish_end - shimmer_start).max(1) as f64;
            let u = ((self.frame - shimmer_start) as f64 / dur).clamp(0.0, 1.0);
            let f1 = -0.18 + 1.36 * smoothstep(u);
            let u2 = ((u - 0.24) / 0.76).clamp(0.0, 1.0);
            let f2 = -0.18 + 1.36 * smoothstep(u2);
            let env = smoothstep((u * 6.0).min(1.0)) * smoothstep(((1.0 - u) * 5.0).min(1.0));
            (f1, f2, u > 0.24, env)
        } else {
            (0.0, 0.0, false, 0.0)
        };
        let handling = e.existing_color_handling();
        for piece in &self.text {
            let local = if self.frame < self.settle_start {
                0.0
            } else {
                ((settle - piece.start) / HOMING_WINDOW).clamp(0.0, 1.0)
            };
            let glyph =
                self.random_type(piece.id as u64 * 113 + ((self.frame + piece.id * 3) / 7) as u64);
            if local <= 0.0 {
                let Some((x, y)) = self.airborne(piece) else {
                    continue;
                };
                let flight = (self.frame - self.recovery_frame) as f64
                    / self.config.letter_flight_duration as f64;
                let fresh = flight - piece.delay < LAUNCH_SPAN * 0.4;
                // once the real print starts, the waiting type steps back
                let color = shift(&piece.debris, &dusk, step_back);
                let visual = paint(e, piece.slot, glyph, color, fresh);
                e.set_visual(piece.slot, visual);
                e.set_coordinate(piece.slot, Coord::new(x.round() as i64, y.round() as i64));
                e.set_visible(piece.slot, true);
                continue;
            }
            e.set_visible(piece.slot, true);
            if local < 1.0 {
                let (x, y) = self
                    .airborne(piece)
                    .unwrap_or((piece.scatter.0, piece.scatter.1));
                let ex = smoothstep(local);
                let ey = smoothstep(local.powf(0.8));
                let coord = Coord::new(
                    (x + (piece.home.column as f64 - x) * ex).round() as i64,
                    (y + (piece.home.row as f64 - y) * ey).round() as i64,
                );
                let sym = if local < 0.82 {
                    glyph
                } else {
                    e.input_sym(piece.slot)
                };
                let waiting = shift(&piece.debris, &dusk, step_back);
                let color = shift(&waiting, &white, local * 1.6);
                let visual = paint(e, piece.slot, sym, color, local > 0.6);
                e.set_visual(piece.slot, visual);
                e.set_coordinate(piece.slot, coord);
                continue;
            }
            // landed: a white flash that cools into its color, then a faint
            // diagonal ink-dry sheen sweeps across the settled logo
            e.set_coordinate(piece.slot, piece.home);
            let landed_at = self.settle_start as f64 + (piece.start + HOMING_WINDOW) * reassembly;
            let since = self.frame as f64 - landed_at;
            let visual = if since < LAND_FLASH {
                piece.flash
            } else if since < LAND_FLASH + LAND_FADE {
                let sym = e.input_sym(piece.slot);
                let color = shift(&white, &piece.base, (since - LAND_FLASH) / LAND_FADE);
                paint(e, piece.slot, sym, color, true)
            } else if shimmer_active {
                let d1 = piece.diag - front1;
                let w1 = if d1 >= 0.0 { 0.065 } else { 0.145 };
                let s1 = (-(d1 / w1).powi(2)).exp();
                let s2 = if show_second {
                    let d2 = piece.diag - front2;
                    let w2 = if d2 >= 0.0 { 0.08 } else { 0.16 };
                    0.48 * (-(d2 / w2).powi(2)).exp()
                } else {
                    0.0
                };
                let sheen = (s1.max(s2) * env).clamp(0.0, 1.0);
                let preserve_existing = (handling == ExistingColorHandling::Always
                    && e.uses_preexisting_colors(piece.slot))
                    || (handling == ExistingColorHandling::Dynamic
                        && e.input_bg(piece.slot).is_some());
                if sheen > 0.05 && !preserve_existing {
                    let sym = e.input_sym(piece.slot);
                    let fg = shift(&piece.base, &self.config.paper_color, sheen * 0.45);
                    let bg = if sheen > 0.18 {
                        Some(shift(&black, &piece.base, sheen * 0.16))
                    } else {
                        None
                    };
                    paint_bg(e, piece.slot, sym, fg, bg, true)
                } else {
                    piece.settled
                }
            } else {
                piece.settled
            };
            e.set_visual(piece.slot, visual);
        }
    }
}

impl Hooks for Malfunction {}

impl Effect for Malfunction {
    fn build(&mut self, e: &mut Engine) -> Result<(), EngineError> {
        let config = self.config.clone();
        let canvas = e.canvas.clone();
        let (left, right, bottom, top) = (canvas.left, canvas.right, canvas.bottom, canvas.top);
        let right = right.max(left);
        let top = top.max(bottom);
        let width = (right - left + 1) as f64;
        let height = (top - bottom + 1) as f64;
        // the printer sits just below the text, its sheet rising into it
        let center_column = (canvas.text_left + canvas.text_right) / 2;
        let center_column = if (left..=right).contains(&center_column) {
            center_column
        } else {
            (left + right) / 2
        };
        self.anchor = Coord::new(center_column, (canvas.text_bottom - 3).max(bottom + 3));
        self.canvas_left = left;
        self.canvas_right = right;
        self.exit_drop = (self.anchor.row + 3 - bottom + 2).max(8);
        // taller canvases fling things higher
        let tall = (height / 24.0).max(1.0);
        self.gravity = 0.012;
        self.confetti_gravity = 0.006;

        self.print_start = config.warmup_duration;
        self.malfunction_start = self.print_start.saturating_add(config.printing_duration);
        self.recovery_frame = self
            .malfunction_start
            .saturating_add(config.malfunction_duration);
        self.settle_start = self
            .recovery_frame
            .saturating_add(config.letter_flight_duration);
        self.settle_end = self.settle_start.saturating_add(config.reassembly_duration);
        self.exit_end = self.settle_end.saturating_add(EXIT_FRAMES);

        self.type_syms = TYPE.iter().map(|s| e.sym(s)).collect();
        self.err_syms = ERR.iter().map(|s| e.sym(s)).collect();
        for (kind, symbols) in CONFETTI.iter().enumerate() {
            for (stage, s) in symbols.iter().enumerate() {
                self.confetti_syms[kind][stage] = e.sym(s);
            }
        }
        self.edge_syms = [e.sym("╭"), e.sym("╮"), e.sym("─"), e.sym("│")];
        let lamp_sym = e.sym("●");
        self.lamp_off_sym = e.sym("○");
        self.heart_sym = e.sym("♥");

        for (line_index, line) in MACHINE.iter().enumerate() {
            let row = 2 - line_index as i64;
            let first = line.find(|c| c != ' ').map(|b| line[..b].chars().count());
            let last =
                line.chars().count() - 1 - line.chars().rev().take_while(|&c| c == ' ').count();
            for (column, symbol) in line.chars().enumerate() {
                // the body's inner blanks are drawn too, so it hides the type
                // flying behind it (the display window has its own cells)
                let window = line_index == 1
                    && (DISPLAY_LEFT..DISPLAY_LEFT + DISPLAY_WIDTH as i64)
                        .contains(&(column as i64));
                let inside =
                    line_index > 0 && first.is_some_and(|f| column > f) && column < last && !window;
                if symbol == ' ' && !inside {
                    continue;
                }
                let offset = Coord::new(column as i64 - MACHINE_HALF, row);
                let sym = e.symbols.intern_char(symbol);
                let slot = e.add_character_sym(
                    sym,
                    Coord::new(
                        self.anchor.column + offset.column,
                        self.anchor.row + offset.row,
                    ),
                );
                e.set_layer(slot, 9);
                self.printer.push(PrinterPart {
                    slot,
                    offset,
                    sym,
                    lamp: sym == lamp_sym,
                });
            }
        }
        let blank = e.sym("·");
        for k in 0..DISPLAY_WIDTH as i64 {
            let slot = e.add_character_sym(
                blank,
                Coord::new(
                    self.anchor.column + DISPLAY_LEFT + k - MACHINE_HALF,
                    self.anchor.row + 1,
                ),
            );
            e.set_layer(slot, 10);
            self.display.push(slot);
        }

        for row in 0..=PAPER_LINES {
            for column in 0..PAPER_WIDTH {
                let slot = e.add_character_sym(
                    self.edge_syms[2],
                    Coord::new(
                        self.anchor.column + column - PAPER_WIDTH / 2,
                        self.anchor.row + 3 + row,
                    ),
                );
                e.set_layer(slot, 3);
                self.paper.push(PaperCell { slot, column, row });
            }
        }

        // The last sheet: a crisp proof slip that could slide out under the
        // logo during the post-settle flourish. Off: the finished logo reads
        // better on its own, with only the printer's OK light and the ink-dry
        // shimmer. Kept so the slip can come back behind an option.
        const PROOF_SLIP: bool = false;
        let canvas_w = right - left + 1;
        let text_w_i = (canvas.text_right - canvas.text_left + 1).max(1);
        let sheet_w = ((text_w_i as f64 * 0.58).round() as i64)
            .clamp(24, 52)
            .min(canvas_w - 2);
        if PROOF_SLIP && sheet_w >= 16 && canvas.text_bottom - 2 >= bottom {
            let three_rows = canvas.text_bottom - 3 >= bottom + 1;
            self.proof_row = if three_rows {
                canvas.text_bottom - 3
            } else {
                canvas.text_bottom - 2
            };
            self.proof_width = sheet_w;
            let half = sheet_w / 2;
            let top_edge = e.sym("▁");
            let bot_edge = e.sym("▔");
            let left_edge = e.sym("▐");
            let right_edge = e.sym("▌");

            let label = if sheet_w >= 38 {
                "·  ✓ OK  ───  PRINT COMPLETE  ───  ·"
            } else if sheet_w >= 28 {
                "·  ✓ OK · PRINT COMPLETE  ·"
            } else {
                "· ✓ OK · DONE ·"
            };
            let label_chars: Vec<char> = label.chars().collect();
            let inner_w = (sheet_w - 2) as usize;
            let pad = inner_w.saturating_sub(label_chars.len()) / 2;

            for col in 0..sheet_w {
                let dx = col - half;
                let base_coord = Coord::new(self.anchor.column + dx, self.proof_row);
                if col == 0 || col == sheet_w - 1 {
                    let sym = if col == 0 { left_edge } else { right_edge };
                    let slot = e.add_character_sym(sym, base_coord);
                    e.set_layer(slot, 7);
                    e.set_visible(slot, false);
                    self.proof_sheet.push(ProofCell {
                        slot,
                        dx,
                        dy: 0,
                        sym,
                        kind: ProofKind::Edge,
                    });
                } else {
                    let inner_i = (col - 1) as usize;
                    let ch = inner_i
                        .checked_sub(pad)
                        .and_then(|i| label_chars.get(i))
                        .copied()
                        .unwrap_or(' ');
                    let ok_accent = matches!(ch, '✓' | 'O' | 'K')
                        && inner_i
                            .checked_sub(pad)
                            .is_some_and(|i| i < 9);
                    let muted = matches!(ch, '·' | '─');
                    let sym = e.symbols.intern_char(ch);
                    let slot = e.add_character_sym(sym, base_coord);
                    e.set_layer(slot, 7);
                    e.set_visible(slot, false);
                    self.proof_sheet.push(ProofCell {
                        slot,
                        dx,
                        dy: 0,
                        sym,
                        kind: ProofKind::Body { ok_accent, muted },
                    });

                    if three_rows {
                        for (dy, edge_sym) in [(1, top_edge), (-1, bot_edge)] {
                            let edge_slot = e.add_character_sym(
                                edge_sym,
                                Coord::new(self.anchor.column + dx, self.proof_row + dy),
                            );
                            e.set_layer(edge_slot, 7);
                            e.set_visible(edge_slot, false);
                            self.proof_sheet.push(ProofCell {
                                slot: edge_slot,
                                dx,
                                dy,
                                sym: edge_sym,
                                kind: ProofKind::Edge,
                            });
                        }
                    }
                }
            }
        }

        let question = e.sym("?");
        let mut particles_end = self.exit_end;
        // the jam sputters more and more loose type, flung higher on tall canvases
        let loose = ((width * height / 40.0) as usize).clamp(40, 220);
        let throw = tall.sqrt();
        for index in 0..loose {
            let u = e.rng.uniform(0.0, 1.0);
            let born = self
                .malfunction_start
                .saturating_add((config.malfunction_duration as f64 * u.sqrt()) as i64);
            let life = e.rng.randint(70, 110) + (20.0 * (tall - 1.0)).min(80.0) as i64;
            let slot = e.add_character_sym(question, self.anchor);
            e.set_layer(slot, 6);
            particles_end = particles_end.max(born.saturating_add(life));
            self.loose_type.push(LooseType {
                slot,
                born,
                life,
                start_x: self.anchor.column as f64 + e.rng.uniform(-11.0, 11.0),
                start_y: (self.anchor.row + 3) as f64 + e.rng.uniform(0.0, PAPER_LINES as f64),
                velocity_x: e.rng.uniform(-0.45, 0.45) * throw,
                velocity_y: e.rng.uniform(0.05, 0.42) * throw,
                red: index % 5 == 0,
            });
        }

        let star = e.sym("*");
        let colors = config.letter_colors.len();
        let crowd = (width * height / (96.0 * 24.0)).clamp(1.0, 3.0);
        let count = ((config.celebration_particles as f64 * crowd) as i64).min(MAX_CONFETTI);
        let reach_x = (width * 0.42).max(20.0);
        let reach_y = (height * 0.5).max(10.0);
        for index in 0..count as usize {
            let slot =
                e.add_character_sym(star, Coord::new(self.anchor.column, self.anchor.row + 3));
            e.set_layer(slot, 7);
            // most burst with the sheet, a few sprinkle down afterwards
            let delay = if index % 4 == 0 {
                e.rng.randint(0, 90)
            } else {
                e.rng.randint(0, 10)
            };
            let lifetime = e.rng.randint(70, 140);
            // rise to about reach_y at the peak of a typical arc
            let peak = (2.0 * self.confetti_gravity * reach_y).sqrt();
            let velocity_y = e.rng.uniform(0.35, 1.05) * peak;
            let velocity_x = e.rng.uniform(-1.0, 1.0) * reach_x / 45.0;
            particles_end = particles_end.max(self.recovery_frame.saturating_add(delay + lifetime));
            self.confetti.push(Confetti {
                slot,
                delay,
                velocity_x,
                velocity_y,
                lifetime,
                color_index: index % colors,
                kind: index % 3,
            });
        }

        let text = e.get_characters(
            CharacterFilter::default(),
            CharacterSort::TopToBottomLeftToRight,
        );
        let gradient = Gradient::new(
            &config.final_gradient_stops,
            &config.final_gradient_steps,
            false,
            false,
        )
        .map_err(EngineError::Other)?;
        let mapping = gradient
            .build_coordinate_color_mapping(
                canvas.text_bottom,
                canvas.text_top,
                canvas.text_left,
                canvas.text_right,
                config.final_gradient_direction,
            )
            .map_err(EngineError::Other)?;
        let fallback = gradient
            .spectrum
            .first()
            .copied()
            .unwrap_or(config.paper_color);
        let text_span = (canvas.text_right - canvas.text_left).max(1) as f64;
        let dynamic = e.existing_color_handling() == ExistingColorHandling::Dynamic;
        let white = Color::from_rgb(0xff, 0xff, 0xff);

        // print order: line by line from the top, left to right in a line
        let mut rows: Vec<i64> = text.iter().map(|&slot| e.input_coord(slot).row).collect();
        rows.sort_unstable_by(|a, b| b.cmp(a));
        rows.dedup();
        let lines = rows.len().max(1) as f64;

        // the shower hangs over (and around) the text
        let text_w = (canvas.text_right - canvas.text_left + 1) as f64;
        let text_h = (canvas.text_top - canvas.text_bottom + 1) as f64;
        let cx = (canvas.text_left + canvas.text_right) as f64 / 2.0;
        let cy = (canvas.text_bottom + canvas.text_top) as f64 / 2.0;
        let half_w = (text_w * 0.85).max(width * 0.36).min(width / 2.0);
        let half_h = (text_h * 1.3).max(height * 0.36).min(height / 2.0);
        let x_lo = (cx - half_w).max(left as f64);
        let x_hi = (cx + half_w).min(right as f64).max(x_lo);
        let y_lo = (cy - half_h).max(bottom as f64);
        let y_hi = (cy + half_h).min(top as f64).max(y_lo);

        for (index, slot) in text.into_iter().enumerate() {
            let home = e.input_coord(slot);
            let id = e.ch.id[slot as usize] as i64;
            let origin = (
                self.anchor.column as f64 + e.rng.uniform(-11.0, 11.0),
                (self.anchor.row + 3) as f64 + e.rng.uniform(0.0, PAPER_LINES as f64),
            );
            let scatter = (e.rng.uniform(x_lo, x_hi), e.rng.uniform(y_lo, y_hi));
            let delay = e.rng.uniform(0.0, 0.14);
            let arc = e.rng.uniform(2.0, 6.0) * tall.sqrt();
            let phase = e.rng.uniform(0.0, std::f64::consts::TAU);
            let line = rows.iter().position(|&r| r == home.row).unwrap_or(0) as f64;
            let across = ((home.column - canvas.text_left) as f64 / text_span).clamp(0.0, 0.999);
            let text_row_span = (canvas.text_top - canvas.text_bottom).max(1) as f64;
            let down = ((canvas.text_top - home.row) as f64 / text_row_span).clamp(0.0, 1.0);
            let diag = 0.78 * across + 0.22 * down;
            let start = (line + across) / lines * (1.0 - HOMING_WINDOW);
            let gradient_color = mapping.get(&home).copied().unwrap_or(fallback);
            let debris = config.letter_colors[index % colors];
            let sym = e.input_sym(slot);
            let (base, settled) = if dynamic {
                // the input's own colors (none for uncolored input), as wipe
                let info = VisualInfo {
                    sym,
                    fg: e.input_fg(slot),
                    bg: e.input_bg(slot),
                    attrs: HAS_COLORS | if e.input_bold(slot) { BOLD } else { 0 },
                };
                (
                    e.input_fg(slot).unwrap_or(gradient_color),
                    e.visuals.make(&e.symbols, info),
                )
            } else {
                (gradient_color, paint(e, slot, sym, gradient_color, true))
            };
            let piece = TextPiece {
                slot,
                id,
                home,
                origin,
                scatter,
                delay,
                arc,
                phase,
                start,
                diag,
                base,
                debris,
                settled,
                flash: paint(e, slot, sym, white, true),
            };
            e.set_layer(slot, 8);
            e.set_visible(slot, false);
            self.text.push(piece);
        }

        // every timing option and every particle's flight feed the end
        self.end_frame = particles_end.saturating_add(config.final_hold_time);
        let flourish_end = (self.end_frame - QUIET_TAIL).max(self.settle_end);
        if config.final_hold_time > 0 && flourish_end > self.settle_end + EXIT_FRAMES {
            let avail = flourish_end - self.settle_end;
            let ok_hold = ((avail * 38) / 100).min(130).min(avail - EXIT_FRAMES);
            self.exit_start = self.settle_end + ok_hold;
            self.exit_end = self.exit_start + EXIT_FRAMES;
            self.flourish_end = flourish_end;
        } else {
            self.exit_start = self.settle_end;
            self.exit_end = self.settle_end.saturating_add(EXIT_FRAMES);
            self.flourish_end = self.settle_end;
        }
        self.frame = 0;
        Ok(())
    }

    fn next_frame(&mut self, e: &mut Engine) -> bool {
        if self.frame > self.end_frame {
            return false;
        }
        self.update_printer(e);
        self.update_display(e);
        self.update_paper(e);
        self.update_proof_sheet(e);
        self.update_loose_type(e);
        self.update_confetti(e);
        self.update_text(e);
        self.frame += 1;
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::ctx::Clock;
    use crate::engine::terminal::TerminalConfig;
    use crate::utils::rng::Rng;
    use clap::Parser;

    /// Run an effect to completion: (frame count, final engine).
    fn run(
        effect: &mut dyn Effect,
        input: &str,
        width: i64,
        height: i64,
        handling: ExistingColorHandling,
        seed: u64,
    ) -> (u64, Engine) {
        try_run(effect, input, width, height, handling, seed).expect("engine")
    }

    /// run(), or None when the engine itself refuses the input (every
    /// character outside the canvas), before the effect is involved.
    fn try_run(
        effect: &mut dyn Effect,
        input: &str,
        width: i64,
        height: i64,
        handling: ExistingColorHandling,
        seed: u64,
    ) -> Option<(u64, Engine)> {
        let config = TerminalConfig {
            canvas_width: width,
            canvas_height: height,
            existing_color_handling: handling,
            ..TerminalConfig::default()
        };
        let mut e = Engine::new(
            input,
            config,
            Rng::seeded(seed),
            Clock::virtual_with_frame_rate(60),
        )
        .ok()?;
        effect.build(&mut e).expect("build");
        let mut frames = 0u64;
        while effect.next_frame(&mut e) {
            e.render_here();
            frames += 1;
            assert!(frames < 200_000, "effect does not terminate");
        }
        Some((frames, e))
    }

    /// The final state is the input: every input character visible at home
    /// with its symbol, every added character hidden.
    fn assert_settled(e: &Engine) {
        for &slot in &e.input_chars {
            assert!(e.is_visible(slot), "input character {slot} hidden");
            assert_eq!(e.coord(slot), e.input_coord(slot));
            let info = e.visual_info(e.current_visual(slot));
            assert_eq!(info.sym, e.input_sym(slot));
        }
        for &slot in &e.added_chars {
            assert!(!e.is_visible(slot), "added character {slot} still visible");
        }
    }

    fn assert_dynamic_red(e: &Engine) {
        let red = (255, 0, 0);
        let mut seen = 0;
        for &slot in &e.input_chars {
            if e.input_fg(slot).map(|c| c.rgb_ints()) == Some(red) {
                let info = e.visual_info(e.current_visual(slot));
                assert_eq!(
                    info.fg.map(|c| c.rgb_ints()),
                    Some(red),
                    "dynamic run lost the input color"
                );
                seen += 1;
            }
        }
        assert!(seen > 0);
    }

    fn config(args: &[&str]) -> MalfunctionConfig {
        let mut argv = vec!["ttfx", "malfunction"];
        argv.extend_from_slice(args);
        match crate::cli::Cli::try_parse_from(argv).expect("parse").effect {
            Some(crate::effects::EffectCommand::Malfunction(c)) => c,
            _ => unreachable!(),
        }
    }

    fn frames(args: &[&str]) -> u64 {
        let input = "OMARCHY\nhello world\n";
        run(
            &mut Malfunction::new(config(args)),
            input,
            60,
            20,
            ExistingColorHandling::Ignore,
            1,
        )
        .0
    }

    #[test]
    fn edge_inputs_settle() {
        let long = "x".repeat(500);
        // (whitespace-only input never reaches an effect: main prints NO INPUT.)
        let inputs = [
            "OMARCHY\nhello world\n",
            "a",
            "  a  ",
            &long,
            "日本語 wide ✦ chars",
            "a\n\n\nb",
        ];
        let mut ran = 0;
        for input in inputs {
            for (w, h) in [(10, 3), (1, 1), (80, 24), (300, 80), (0, 0)] {
                if let Some((_, e)) = try_run(
                    &mut Malfunction::new(config(&[])),
                    input,
                    w,
                    h,
                    ExistingColorHandling::Ignore,
                    7,
                ) {
                    assert_settled(&e);
                    ran += 1;
                }
            }
        }
        // only the 1x1 canvas can drop every character of an input
        assert!(ran >= inputs.len() * 4, "{ran} runs");
    }

    #[test]
    fn deterministic_and_fast_on_a_big_canvas() {
        let logo = "OMARCHY\n".repeat(10) + &"x".repeat(80);
        let start = std::time::Instant::now();
        let (frames_a, a) = run(
            &mut Malfunction::new(config(&[])),
            &logo,
            300,
            90,
            ExistingColorHandling::Ignore,
            7,
        );
        let elapsed = start.elapsed();
        assert_settled(&a);
        assert!(elapsed.as_secs_f64() < 30.0, "300x90 run took {elapsed:?}");
        let (frames_b, b) = run(
            &mut Malfunction::new(config(&[])),
            &logo,
            300,
            90,
            ExistingColorHandling::Ignore,
            7,
        );
        assert_eq!(frames_a, frames_b);
        for slot in 0..a.char_count() as u32 {
            assert_eq!(a.coord(slot), b.coord(slot));
            assert_eq!(a.current_visual(slot), b.current_visual(slot));
        }
    }

    #[test]
    fn short_and_extreme_timings_settle() {
        let c = config(&[
            "--warmup-duration",
            "1",
            "--printing-duration",
            "1",
            "--malfunction-duration",
            "1",
            "--letter-flight-duration",
            "1",
            "--reassembly-duration",
            "1",
            "--final-hold-time",
            "0",
            "--celebration-particles",
            "1000000000",
        ]);
        let (_, e) = run(
            &mut Malfunction::new(c),
            "OMARCHY\nhello world\n",
            20,
            5,
            ExistingColorHandling::Ignore,
            3,
        );
        assert_settled(&e);
    }

    #[test]
    fn dynamic_keeps_input_colors() {
        let input = "\x1b[38;2;255;0;0mred\x1b[0m text";
        let (_, e) = run(
            &mut Malfunction::new(config(&[])),
            input,
            40,
            12,
            ExistingColorHandling::Dynamic,
            2,
        );
        assert_settled(&e);
        assert_dynamic_red(&e);
        let (_, e) = run(
            &mut Malfunction::new(config(&[])),
            input,
            40,
            12,
            ExistingColorHandling::Always,
            2,
        );
        assert_settled(&e);
    }

    #[test]
    fn every_timing_option_moves_the_end() {
        let base = frames(&[]);
        for args in [
            ["--warmup-duration", "10"],
            ["--printing-duration", "10"],
            ["--malfunction-duration", "10"],
            ["--letter-flight-duration", "10"],
            ["--reassembly-duration", "10"],
            ["--final-hold-time", "0"],
        ] {
            assert_ne!(
                frames(&args),
                base,
                "{args:?} does not change the run length"
            );
        }
        // short phases: the confetti, not the reassembly or the printer's
        // exit, set the end (settled at 90 + 250 + 210 + 1 + 1 = 552, gone
        // 60 frames later; confetti from the burst at 550 live 70+)
        let short = [
            "--letter-flight-duration",
            "1",
            "--reassembly-duration",
            "1",
            "--final-hold-time",
            "0",
        ];
        assert!(frames(&short) > 552 + EXIT_FRAMES as u64);
        assert!(frames(&short) >= 550 + 70);
    }
}
