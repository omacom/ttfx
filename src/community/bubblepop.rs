//! bubblepop: iridescent bubbles float up through the canvas, burst over the
//! input, and reveal crisp rainbow lettering one sparkling patch at a time.
//!
//! Original effect by Lukas Innig (@derluke), https://github.com/derluke/ttfx, MIT.
//! Rewritten for the fx engine: the whole timeline is a function of the frame
//! number, so every character is placed and painted directly each frame (no
//! scenes or paths). Visuals are interned once in build where they are fixed;
//! the fading colors are quantized so the visual pool stays small.
//!
//! The story, frame by frame: faint ambient bubbles drift up the whole
//! screen; the effect's bubbles rise to points spread evenly over the text,
//! shiver, and burst (the rim flies apart, sparks spray out); each burst
//! sends a ripple that paints the letters around it, a ring of sparkles at
//! its front and wet, bright letters behind it that dry to the gradient.
//! Once every letter is painted, tiny iridescent bubbles nucleate along the
//! letter bottoms, rise through the lettering catching each letter's color
//! with a soft wet gleam, and pop above the tops in crisp pinpricks before
//! the text settles.

use std::collections::HashMap;

use clap::Args;

use crate::cli::parse_color;
use crate::effects::common::{parse_gradient_direction, parse_gradient_steps, parse_positive_int};
use crate::engine::animation::ExistingColorHandling;
use crate::engine::error::EngineError;
use crate::engine::terminal::{CharacterFilter, CharacterSort};
use crate::fx::run::Effect;
use crate::fx::visual::{VisualInfo, BOLD, HAS_COLORS};
use crate::fx::{Engine, Hooks, Sym, Visual};
use crate::utils::geometry::Coord;
use crate::utils::graphics::{shift_color_towards, Color, Gradient, GradientDirection};

#[derive(Args, Debug, Clone)]
pub struct BubblePopConfig {
    /// Number of bubbles that rise and pop across the lettering.
    #[arg(long = "bubble-count", default_value_t = 28, value_parser = parse_positive_int)]
    pub bubble_count: i64,

    /// Frames each bubble spends floating up toward the text.
    #[arg(long = "rise-duration", default_value_t = 190, value_parser = parse_positive_int)]
    pub rise_duration: i64,

    /// Frames between successive bubble launches.
    #[arg(long = "launch-delay", default_value_t = 22, value_parser = parse_positive_int)]
    pub launch_delay: i64,

    /// Frames occupied by each sparkling pop.
    #[arg(long = "pop-duration", default_value_t = 30, value_parser = parse_positive_int)]
    pub pop_duration: i64,

    /// Frames to admire the completed text after the last bubbles clear.
    #[arg(long = "final-hold-time", default_value_t = 360, value_parser = parse_positive_int)]
    pub final_hold_time: i64,

    /// Number of faint background bubbles drifting up the screen (0: none;
    /// default: one per 6 canvas columns).
    #[arg(long = "ambient-bubbles")]
    pub ambient_bubbles: Option<u32>,

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

/// Sparks per pop.
const SPARKS: usize = 14;
/// Frames the rim flies apart before it is gone.
const BURST: i64 = 3;
/// Frames before the pop a bubble shivers (bright, bold rim).
const EXCITEMENT: i64 = 18;
/// Frames a revealed character shows a sparkle before its letter.
const REVEAL_SPARKLE: i64 = 4;
/// Frames a fresh letter takes to dry from the highlight to its color.
const DRY: i64 = 36;
/// Frames per cell (rows count double) the paint ripple takes to spread.
const WAVE_FRAMES_PER_CELL: f64 = 1.5;
/// Spark reach in cells (rows count double), per bubble size.
const RADIUS: [f64; 3] = [7.0, 9.5, 12.5];
/// The final frames are quiet, so the run ends on the settled text.
const QUIET_TAIL: i64 = 12;
/// Quantization of every fade (visual pool size).
const FADE_STEPS: f64 = 16.0;
/// Bubbles beyond this add nothing on any canvas and cost build time.
const MAX_BUBBLES: usize = 1024;
/// Tiny droplets sprayed by each flourish pinprick pop.
const FIZZ_DROPS: usize = 4;
/// Frames a rising flourish bubble swells at its apex before popping.
const FIZZ_SWELL: i64 = 6;
/// Frames a flourish pinprick flash + micro-droplet scatter lasts.
const FIZZ_POP: i64 = 14;
/// Maximum reusable fizz emitters during the ending flourish.
const MAX_FIZZ_EMITTERS: usize = 48;

const LAYER_AMBIENT: i32 = 3;
const LAYER_BUBBLE: i32 = 4;
const LAYER_TEXT: i32 = 6;
const LAYER_SPARK: i32 = 7;

struct Bubble {
    /// First slot of its parts; parts are consecutive.
    first: u32,
    size: usize,
    target: Coord,
    start_x: f64,
    start_y: f64,
    launch: i64,
    pop: i64,
    sway: f64,
    phase: f64,
    color_offset: usize,
    /// Where it actually is when it bursts: the sparks' and ripple's origin.
    burst: (f64, f64),
    /// First slot of its SPARKS sparks.
    first_spark: u32,
    spark_dir: [(f64, f64); SPARKS],
}

struct Ambient {
    slot: u32,
    x: f64,
    speed: f64,
    /// Frames to cross the canvas, and from one crossing's start to the next.
    travel: i64,
    period: i64,
    offset: i64,
    sway: f64,
    phase: f64,
    visual: Visual,
}

struct TextChar {
    slot: u32,
    reveal: i64,
    /// The color the letter dries to (None: the input's own uncolored look).
    color: Option<Color>,
    settled: Visual,
    sparkle: Visual,
}

struct FizzEvent {
    start_x: f64,
    start_y: f64,
    apex_y: f64,
    sway: f64,
    phase: f64,
    launch: i64,
    pop: i64,
    init_color: Color,
    large: bool,
    drop_dir: [(f64, f64); FIZZ_DROPS],
}

struct FizzEmitter {
    slot: u32,
    first_drop: u32,
    tint: Color,
    cursor: usize,
    events: Vec<FizzEvent>,
}

pub struct BubblePop {
    config: BubblePopConfig,
    bubbles: Vec<Bubble>,
    ambient: Vec<Ambient>,
    ambient_start_y: f64,
    text: Vec<TextChar>,
    /// Non-space text lookup by coordinate for O(1) flourish color-catching & gleam.
    text_grid: HashMap<Coord, usize>,
    /// Indices into `text` temporarily illuminated by a passing fizz bubble.
    touched_text: Vec<usize>,
    /// Effervescent micro-bubble emitters for the ending flourish.
    fizz: Vec<FizzEmitter>,
    /// Interned sprite symbols per size: (offset, symbol, highlight).
    sprites: [Vec<(Coord, Sym, bool)>; 3],
    spark_syms: [Sym; 3],
    /// Flourish symbols: [·, °, ◦, ○, ◯, ✦, ✧, •].
    fizz_syms: [Sym; 8],
    frame: i64,
    final_start: i64,
    end_frame: i64,
}

fn sprite(size: usize) -> &'static [(i64, i64, &'static str, bool)] {
    match size {
        0 => &[(0, 0, "◯", true)],
        1 => &[
            (-1, 1, "╭", false),
            (0, 1, "─", true),
            (1, 1, "╮", false),
            (-2, 0, "(", false),
            (0, 0, "°", true),
            (2, 0, ")", false),
            (-1, -1, "╰", false),
            (0, -1, "─", false),
            (1, -1, "╯", false),
        ],
        _ => &[
            (-2, 2, "╭", false),
            (-1, 2, "─", true),
            (0, 2, "─", true),
            (1, 2, "─", false),
            (2, 2, "╮", false),
            (-3, 1, "╱", false),
            (3, 1, "╲", false),
            (-4, 0, "(", false),
            (-1, 0, "°", true),
            (4, 0, ")", false),
            (-3, -1, "╲", false),
            (3, -1, "╱", false),
            (-2, -2, "╰", false),
            (-1, -2, "─", false),
            (0, -2, "─", false),
            (1, -2, "─", false),
            (2, -2, "╯", false),
        ],
    }
}

fn shift(from: &Color, to: &Color, factor: f64) -> Color {
    shift_color_towards(from, to, factor.clamp(0.0, 1.0)).unwrap_or(*to)
}

fn quantize(f: f64) -> f64 {
    (f.clamp(0.0, 1.0) * FADE_STEPS).round() / FADE_STEPS
}

/// The visual for an effect color, or the input's colors under
/// --existing-color-handling always for a character that has them.
fn paint(e: &mut Engine, slot: u32, sym: Sym, color: Color, bold: bool) -> Visual {
    let mut info = VisualInfo {
        sym,
        fg: Some(color),
        bg: None,
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

impl Bubble {
    /// The bubble's center (column, row) at `frame`: an eased rise from
    /// below that arrives exactly when it pops (or early, then hovers), with
    /// a sideways wobble that grows as it slows.
    fn center(&self, frame: i64, rise: i64) -> (f64, f64) {
        let age = frame - self.launch;
        let travel = rise.min(self.pop - self.launch).max(1);
        let progress = (age as f64 / travel as f64).clamp(0.0, 1.0);
        let eased = 1.0 - (1.0 - progress).powi(3);
        let sway = (age as f64 * 0.055 + self.phase).sin() * self.sway * (0.72 + progress * 0.28);
        (
            self.start_x + (self.target.column as f64 - self.start_x) * eased + sway,
            self.start_y + (self.target.row as f64 - self.start_y) * eased,
        )
    }
}

/// Elliptical distance in cells: rows are about twice as tall as columns.
fn cells(dx: f64, dy: f64) -> f64 {
    (dx * dx + 4.0 * dy * dy).sqrt()
}

/// `count` points spread evenly over `points`: each next one is the point
/// farthest from all chosen so far, so early pops land far apart and later
/// ones fill the gaps.
fn spread(points: &[Coord], count: usize, first: usize) -> Vec<Coord> {
    let mut chosen = Vec::with_capacity(count);
    let mut nearest = vec![i64::MAX; points.len()];
    let mut next = first;
    for _ in 0..count {
        let pick = points[next];
        chosen.push(pick);
        let mut best = (-1, 0);
        for (i, p) in points.iter().enumerate() {
            let dx = p.column - pick.column;
            let dy = p.row - pick.row;
            nearest[i] = nearest[i].min(dx * dx + 4 * dy * dy);
            if nearest[i] > best.0 {
                best = (nearest[i], i);
            }
        }
        next = best.1;
    }
    chosen
}

impl BubblePop {
    pub fn new(config: BubblePopConfig) -> Self {
        BubblePop {
            config,
            bubbles: Vec::new(),
            ambient: Vec::new(),
            ambient_start_y: 0.0,
            text: Vec::new(),
            text_grid: HashMap::new(),
            touched_text: Vec::new(),
            fizz: Vec::new(),
            sprites: [Vec::new(), Vec::new(), Vec::new()],
            spark_syms: [Sym(0); 3],
            fizz_syms: [Sym(0); 8],
            frame: 0,
            final_start: 0,
            end_frame: 0,
        }
    }

    fn update_bubbles(&self, e: &mut Engine) {
        let black = Color::from_rgb(0x07, 0x0b, 0x18);
        let colors = &self.config.bubble_colors;
        let rise = self.config.rise_duration;
        let frame = self.frame;
        for (index, bubble) in self.bubbles.iter().enumerate() {
            let parts = &self.sprites[bubble.size];
            let age = frame - bubble.launch;
            // before launch and long after there is nothing to do
            if age < 0 || frame > bubble.pop + BURST {
                continue;
            }
            if frame == bubble.pop + BURST {
                for k in 0..parts.len() as u32 {
                    e.set_visible(bubble.first + k, false);
                }
                continue;
            }
            let burst = frame - bubble.pop;
            let (cx, cy) = if burst >= 0 {
                bubble.burst
            } else {
                bubble.center(frame, rise)
            };
            let excitement = frame >= bubble.pop - EXCITEMENT;
            for (k, &(offset, sym, highlight)) in parts.iter().enumerate() {
                let slot = bubble.first + k as u32;
                let base =
                    colors[((frame / 4) as usize + bubble.color_offset + k * 2) % colors.len()];
                let (coord, visual) = if burst >= 0 {
                    // the rim flies apart: a white flash of the whole rim,
                    // then its fragments thrown outward
                    let spread = 1.0 + 0.7 * burst as f64;
                    let (ox, oy) = if offset.column == 0 && offset.row == 0 {
                        (0.0, 0.0)
                    } else {
                        (offset.column as f64 * spread, offset.row as f64 * spread)
                    };
                    let (sym, color) = if burst == 0 {
                        (sym, self.config.highlight_color)
                    } else {
                        (self.spark_syms[2], shift(&base, &self.config.highlight_color, 0.55))
                    };
                    let coord = Coord::new((cx + ox).round() as i64, (cy + oy).round() as i64);
                    (coord, paint(e, slot, sym, color, true))
                } else {
                    let gleam = highlight || (frame as usize + k * 7 + index * 3) % 29 < 2;
                    // shivering just before the pop: the rim flickers bright
                    let flicker = excitement && (frame + k as i64) % 3 == 0;
                    let color = if gleam || flicker {
                        let f = if excitement { 0.92 } else { 0.70 };
                        shift(&base, &self.config.highlight_color, f)
                    } else {
                        shift(&base, &black, 0.12)
                    };
                    let coord = Coord::new(
                        cx.round() as i64 + offset.column,
                        cy.round() as i64 + offset.row,
                    );
                    (coord, paint(e, slot, sym, color, gleam || excitement))
                };
                e.set_visual(slot, visual);
                e.set_coordinate(slot, coord);
                e.set_visible(slot, true);
            }
        }
    }

    fn update_sparks(&self, e: &mut Engine) {
        let colors = &self.config.bubble_colors;
        let duration = self.config.pop_duration;
        for (index, bubble) in self.bubbles.iter().enumerate() {
            let age = self.frame - bubble.pop;
            if age < 0 || age > duration + 1 {
                continue;
            }
            if age > duration {
                for k in 0..SPARKS as u32 {
                    e.set_visible(bubble.first_spark + k, false);
                }
                continue;
            }
            let progress = age as f64 / duration as f64;
            let distance = 1.0 - (1.0 - progress).powi(2);
            let fade = quantize((1.0 - progress) * 0.62);
            let sym = if progress < 0.22 {
                self.spark_syms[0]
            } else if progress < 0.58 {
                self.spark_syms[1]
            } else {
                self.spark_syms[2]
            };
            let (bx, by) = bubble.burst;
            for (k, &(dx, dy)) in bubble.spark_dir.iter().enumerate() {
                let slot = bubble.first_spark + k as u32;
                let offset = index * 3 + k;
                let base = colors[(offset + (self.frame / 3) as usize) % colors.len()];
                let color = shift(&base, &self.config.highlight_color, fade);
                let visual = paint(e, slot, sym, color, progress < 0.45);
                e.set_visual(slot, visual);
                e.set_coordinate(
                    slot,
                    Coord::new(
                        (bx + dx * distance).round() as i64,
                        (by + dy * distance).round() as i64,
                    ),
                );
                e.set_visible(slot, true);
            }
        }
    }

    fn update_ambient(&self, e: &mut Engine) {
        let frame = self.frame;
        let last = self.end_frame - QUIET_TAIL;
        for a in &self.ambient {
            let into = (frame - a.offset).rem_euclid(a.period);
            let start = frame - into;
            let shown = start >= 0 && into < a.travel && start + a.travel <= last;
            if shown {
                let y = self.ambient_start_y + into as f64 * a.speed;
                let x = a.x + (into as f64 * 0.04 + a.phase).sin() * a.sway;
                e.set_coordinate(a.slot, Coord::new(x.round() as i64, y.round() as i64));
                e.set_visual(a.slot, a.visual);
            }
            e.set_visible(a.slot, shown);
        }
    }

    fn update_text(&self, e: &mut Engine) {
        let frame = self.frame;
        let highlight = self.config.highlight_color;
        for t in &self.text {
            if frame < t.reveal {
                continue;
            }
            let age = frame - t.reveal;
            let mut shine = 0.0;
            if age >= REVEAL_SPARKLE && age < REVEAL_SPARKLE + DRY {
                let dry = (age - REVEAL_SPARKLE) as f64 / DRY as f64;
                shine = 0.85 * (1.0 - dry).powi(2);
            }
            let shine = quantize(shine);
            let visual = if age < REVEAL_SPARKLE {
                t.sparkle
            } else if shine > 0.0 && t.color.is_some() {
                let color = shift(&t.color.unwrap_or(highlight), &highlight, shine);
                let sym = e.input_sym(t.slot);
                paint(e, t.slot, sym, color, true)
            } else {
                t.settled
            };
            e.set_visual(t.slot, visual);
            if age == 0 {
                e.set_visible(t.slot, true);
            }
        }
    }

    /// Paint a subtle translucent bubble-lens gleam on a letter cell as a
    /// flourish micro-bubble rises through it.
    fn paint_bubble_gleam(&self, e: &mut Engine, idx: usize, fg_shift: f64, bg_shift: f64) {
        let t = &self.text[idx];
        let Some(base) = t.color else {
            return;
        };
        let handling = e.existing_color_handling();
        if handling == ExistingColorHandling::Always && e.uses_preexisting_colors(t.slot) {
            return;
        }
        let black = Color::from_rgb(0x07, 0x0b, 0x18);
        let fg = shift(&base, &self.config.highlight_color, fg_shift);
        let bg = if handling == ExistingColorHandling::Dynamic {
            e.input_bg(t.slot)
        } else {
            Some(shift(&black, &base, bg_shift))
        };
        let info = VisualInfo {
            sym: e.input_sym(t.slot),
            fg: Some(fg),
            bg,
            attrs: HAS_COLORS | BOLD,
        };
        let visual = e.visuals.make(&e.symbols, info);
        e.set_visual(t.slot, visual);
    }

    fn update_fizz(&mut self, e: &mut Engine) {
        // Restore any letter cells grazed by a micro-bubble on the previous frame.
        for idx in self.touched_text.drain(..) {
            let t = &self.text[idx];
            e.set_visual(t.slot, t.settled);
        }

        let frame = self.frame;
        let last = self.end_frame - QUIET_TAIL;
        if frame < self.final_start || self.fizz.is_empty() {
            return;
        }
        if frame > last {
            for em in &self.fizz {
                e.set_visible(em.slot, false);
                for k in 0..FIZZ_DROPS as u32 {
                    e.set_visible(em.first_drop + k, false);
                }
            }
            return;
        }

        let highlight = self.config.highlight_color;
        let black = Color::from_rgb(0x07, 0x0b, 0x18);
        let syms = self.fizz_syms;
        let mut to_gleam: Vec<(usize, f64, f64)> = Vec::new();

        for em in &mut self.fizz {
            while em.cursor < em.events.len() && frame > em.events[em.cursor].pop + FIZZ_POP {
                em.cursor += 1;
            }
            if em.cursor >= em.events.len() {
                e.set_visible(em.slot, false);
                for k in 0..FIZZ_DROPS as u32 {
                    e.set_visible(em.first_drop + k, false);
                }
                continue;
            }
            let ev = &em.events[em.cursor];
            if frame < ev.launch {
                e.set_visible(em.slot, false);
                for k in 0..FIZZ_DROPS as u32 {
                    e.set_visible(em.first_drop + k, false);
                }
                continue;
            }
            if frame == ev.launch {
                em.tint = ev.init_color;
            }

            if frame < ev.pop {
                // Rising micro-bubble
                for k in 0..FIZZ_DROPS as u32 {
                    e.set_visible(em.first_drop + k, false);
                }
                let rise = (ev.pop - ev.launch).max(1) as f64;
                let age = (frame - ev.launch) as f64;
                let p = (age / rise).clamp(0.0, 1.0);
                let y = ev.start_y + (ev.apex_y - ev.start_y) * p;
                let x = ev.start_x + (age * 0.08 + ev.phase).sin() * ev.sway * p;
                let coord = Coord::new(x.round() as i64, y.round() as i64);

                if let Some(&t_idx) = self.text_grid.get(&coord) {
                    // Catch the letter's color as the bubble passes through it
                    if let Some(c) = self.text[t_idx].color {
                        em.tint = c;
                    }
                    to_gleam.push((t_idx, 0.80, 0.38));
                    if let Some(&wake1) =
                        self.text_grid.get(&Coord::new(coord.column, coord.row - 1))
                    {
                        to_gleam.push((wake1, 0.45, 0.22));
                    }
                    if let Some(&wake2) =
                        self.text_grid.get(&Coord::new(coord.column, coord.row - 2))
                    {
                        to_gleam.push((wake2, 0.22, 0.10));
                    }
                    // Keep the solid letter glyph completely crisp and readable
                    e.set_visible(em.slot, false);
                } else {
                    let swelling = frame >= ev.pop - FIZZ_SWELL;
                    let sym = if frame - ev.launch < 4 {
                        syms[1] // °
                    } else if swelling {
                        if ev.large {
                            syms[4] // ◯
                        } else {
                            syms[3] // ○
                        }
                    } else if p < 0.30 {
                        syms[2] // ◦
                    } else if ev.large && p > 0.62 {
                        syms[4] // ◯
                    } else {
                        syms[3] // ○
                    };
                    let (color, bold) = if swelling {
                        (shift(&em.tint, &highlight, 0.78), true)
                    } else {
                        (shift(&em.tint, &highlight, 0.35), true)
                    };
                    let visual = paint(e, em.slot, sym, color, bold);
                    e.set_visual(em.slot, visual);
                    e.set_coordinate(em.slot, coord);
                    e.set_visible(em.slot, true);
                }
            } else {
                // Crisp pinprick pop at the apex
                let age = frame - ev.pop;
                if age >= FIZZ_POP {
                    e.set_visible(em.slot, false);
                    for k in 0..FIZZ_DROPS as u32 {
                        e.set_visible(em.first_drop + k, false);
                    }
                    continue;
                }
                let rise_age = (ev.pop - ev.launch) as f64;
                let ax = ev.start_x + (rise_age * 0.08 + ev.phase).sin() * ev.sway;
                let ay = ev.apex_y;
                let apex_coord = Coord::new(ax.round() as i64, ay.round() as i64);

                if age < 4 {
                    let (sym, f, bold) = match age {
                        0 | 1 => (syms[5], 0.95, true), // ✦
                        2 => (syms[6], 0.72, true),     // ✧
                        _ => (syms[0], 0.45, false),    // ·
                    };
                    let color = shift(&em.tint, &highlight, f);
                    let visual = paint(e, em.slot, sym, color, bold);
                    e.set_visual(em.slot, visual);
                    e.set_coordinate(em.slot, apex_coord);
                    e.set_visible(em.slot, true);
                } else {
                    e.set_visible(em.slot, false);
                }

                if age >= 1 {
                    let dp = (age - 1) as f64 / (FIZZ_POP - 1) as f64;
                    let reach = 1.0 - (1.0 - dp).powi(2);
                    let color = if dp < 0.35 {
                        shift(&em.tint, &highlight, 0.50)
                    } else {
                        let fade = quantize(((dp - 0.35) / 0.65) * 0.72);
                        shift(&em.tint, &black, fade)
                    };
                    let drop_sym = if dp < 0.42 { syms[7] } else { syms[0] }; // • -> ·
                    for (k, &(dx, dy)) in ev.drop_dir.iter().enumerate() {
                        let dslot = em.first_drop + k as u32;
                        let dcoord = Coord::new(
                            (ax + dx * reach).round() as i64,
                            (ay + dy * reach).round() as i64,
                        );
                        if self.text_grid.contains_key(&dcoord) {
                            e.set_visible(dslot, false);
                        } else {
                            let visual = paint(e, dslot, drop_sym, color, dp < 0.50);
                            e.set_visual(dslot, visual);
                            e.set_coordinate(dslot, dcoord);
                            e.set_visible(dslot, true);
                        }
                    }
                } else {
                    for k in 0..FIZZ_DROPS as u32 {
                        e.set_visible(em.first_drop + k, false);
                    }
                }
            }
        }

        for (t_idx, fg_shift, bg_shift) in to_gleam {
            self.paint_bubble_gleam(e, t_idx, fg_shift, bg_shift);
            self.touched_text.push(t_idx);
        }
    }
}

impl Hooks for BubblePop {}

impl Effect for BubblePop {
    fn build(&mut self, e: &mut Engine) -> Result<(), EngineError> {
        let config = &self.config;
        let canvas = e.canvas.clone();
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
        let fallback_color = gradient
            .spectrum
            .first()
            .copied()
            .unwrap_or(config.highlight_color);

        for size in 0..3 {
            self.sprites[size] = sprite(size)
                .iter()
                .map(|&(c, r, s, h)| (Coord::new(c, r), e.sym(s), h))
                .collect();
        }
        self.spark_syms = [e.sym("✦"), e.sym("•"), e.sym("·")];
        self.fizz_syms = [
            e.sym("·"),
            e.sym("°"),
            e.sym("◦"),
            e.sym("○"),
            e.sym("◯"),
            e.sym("✦"),
            e.sym("✧"),
            e.sym("•"),
        ];
        let space = e.sym(" ");

        let mut non_space: Vec<Coord> = text
            .iter()
            .filter(|&&s| e.input_sym(s) != space)
            .map(|&s| e.input_coord(s))
            .collect();
        if non_space.is_empty() {
            non_space.push(Coord::new(
                (canvas.text_left + canvas.text_right) / 2,
                (canvas.text_bottom + canvas.text_top) / 2,
            ));
        }

        let count = (config.bubble_count.max(1) as usize)
            .min(non_space.len())
            .min(MAX_BUBBLES);
        let first = e.rng.randint(0, non_space.len() as i64 - 1) as usize;
        let targets = spread(&non_space, count, first);
        let rise = config.rise_duration;
        let below = canvas.bottom - 4;
        let right = canvas.right.max(canvas.left);
        let top = canvas.top.max(canvas.bottom);
        for (index, sample) in targets.into_iter().enumerate() {
            let target = Coord::new(
                (sample.column + e.rng.randint(-1, 1)).clamp(canvas.left, right),
                sample.row.clamp(canvas.bottom, top),
            );
            let launch = (index as i64).saturating_mul(config.launch_delay);
            // never pops before it is launched, however short the rise
            let pop = launch
                .saturating_add(rise)
                .saturating_add(e.rng.randint(-12, 12))
                .max(launch.saturating_add(1));
            let size = if index % 7 == 0 {
                2
            } else if index % 3 == 0 {
                1
            } else {
                0
            };
            let mut first = u32::MAX;
            for &(_, sym, _) in &self.sprites[size] {
                let slot = e.add_character_sym(sym, Coord::new(target.column, below));
                e.set_layer(slot, LAYER_BUBBLE);
                if first == u32::MAX {
                    first = slot;
                }
            }
            // on a big screen they come from farther afield
            let wander = (canvas.width / 8).max(14);
            let start_x = (target.column + e.rng.randint(-wander, wander)) as f64;
            let sway = e.rng.uniform(1.4, 4.2);
            let phase = e.rng.uniform(0.0, std::f64::consts::TAU);
            let mut bubble = Bubble {
                first,
                size,
                target,
                start_x,
                start_y: (below - size as i64) as f64,
                launch,
                pop,
                sway,
                phase,
                color_offset: index * 3 % config.bubble_colors.len(),
                burst: (0.0, 0.0),
                first_spark: 0,
                spark_dir: [(0.0, 0.0); SPARKS],
            };
            let (bx, by) = bubble.center(pop, rise);
            bubble.burst = (bx.round(), by.round());
            self.bubbles.push(bubble);
        }

        for bubble in &mut self.bubbles {
            let radius = RADIUS[bubble.size];
            for k in 0..SPARKS {
                let angle =
                    k as f64 / SPARKS as f64 * std::f64::consts::TAU + e.rng.uniform(-0.12, 0.12);
                // a few long sparks mark the ripple's reach, the rest spray inside it
                let reach = if k % 3 == 0 {
                    e.rng.uniform(0.85, 1.2)
                } else {
                    e.rng.uniform(0.45, 0.8)
                } * radius;
                let slot = e.add_character_sym(self.spark_syms[0], bubble.target);
                e.set_layer(slot, LAYER_SPARK);
                if k == 0 {
                    bubble.first_spark = slot;
                }
                bubble.spark_dir[k] = (angle.cos() * reach, angle.sin() * reach * 0.5);
            }
        }

        let last_pop = self.bubbles.iter().map(|b| b.pop).max().unwrap_or(rise);
        let dynamic = e.existing_color_handling() == ExistingColorHandling::Dynamic;
        let highlight = config.highlight_color;
        let sparkle_sym = self.spark_syms[0];
        for &slot in &text {
            let coord = e.input_coord(slot);
            let (column, row) = (coord.column as f64, coord.row as f64);
            // its nearest burst paints it, when that burst's ripple arrives:
            // every pop owns its own patch of letters
            let reveal = self
                .bubbles
                .iter()
                .map(|b| (cells(column - b.burst.0, row - b.burst.1), b.pop))
                .min_by(|a, b| a.0.total_cmp(&b.0))
                .map(|(d, pop)| pop.saturating_add((d * WAVE_FRAMES_PER_CELL).round() as i64))
                .unwrap_or(last_pop);
            let sym = e.input_sym(slot);
            let gradient_color = mapping.get(&coord).copied().unwrap_or(fallback_color);
            let (settled, color) = if dynamic {
                // the input's own colors (none for uncolored input), as wipe
                let info = VisualInfo {
                    sym,
                    fg: e.input_fg(slot),
                    bg: e.input_bg(slot),
                    attrs: HAS_COLORS | if e.input_bold(slot) { BOLD } else { 0 },
                };
                (e.visuals.make(&e.symbols, info), e.input_fg(slot))
            } else {
                (paint(e, slot, sym, gradient_color, true), Some(gradient_color))
            };
            // blanks inside the text's box reveal silently: only letters sparkle
            let sparkle = if sym == space {
                settled
            } else {
                paint(e, slot, sparkle_sym, highlight, true)
            };
            e.set_layer(slot, LAYER_TEXT);
            e.set_visible(slot, false);
            let idx = self.text.len();
            if sym != space {
                self.text_grid.insert(coord, idx);
            }
            self.text.push(TextChar {
                slot,
                reveal,
                color,
                settled,
                sparkle,
            });
        }

        // every timing option feeds the end: the last pop, its sparks, the
        // last letter revealed and dried, then the hold
        let last_reveal = self.text.iter().map(|t| t.reveal).max().unwrap_or(0);
        self.final_start = last_pop
            .saturating_add(config.pop_duration)
            .saturating_add(24)
            .max(last_reveal.saturating_add(REVEAL_SPARKLE + DRY));
        self.end_frame = self.final_start.saturating_add(config.final_hold_time);

        // Signature ending flourish: tiny iridescent micro-bubbles nucleate
        // along the letter bottoms, rise through the lettering catching each
        // letter's color, and pop above the tops with a crisp pinprick.
        let fizz_end = self.end_frame - QUIET_TAIL;
        let hold = fizz_end - self.final_start;
        if hold >= 28 && !self.text_grid.is_empty() {
            let mut col_top: HashMap<i64, i64> = HashMap::new();
            let mut bottom_sites: Vec<(Coord, usize)> = Vec::new();
            for (&coord, &idx) in &self.text_grid {
                col_top
                    .entry(coord.column)
                    .and_modify(|r| *r = (*r).max(coord.row))
                    .or_insert(coord.row);
                if !self
                    .text_grid
                    .contains_key(&Coord::new(coord.column, coord.row - 1))
                {
                    bottom_sites.push((coord, idx));
                }
            }
            // Sort deterministically by (column, row) before RNG sampling
            bottom_sites.sort_unstable_by_key(|&(c, _)| (c.column, c.row));

            if !bottom_sites.is_empty() {
                let site_coords: Vec<Coord> = bottom_sites.iter().map(|&(c, _)| c).collect();
                let num_emitters = (bottom_sites.len() * 2 / 3)
                    .clamp(16, MAX_FIZZ_EMITTERS)
                    .min(bottom_sites.len());
                let first_site = e.rng.randint(0, bottom_sites.len() as i64 - 1) as usize;
                let initial_coords = spread(&site_coords, num_emitters, first_site);
                let stagger_span = (hold / 4).clamp(16, 72);
                let speed_scale = (canvas.height as f64 / 34.0).clamp(0.90, 1.45);

                for (i, init_coord) in initial_coords.into_iter().enumerate() {
                    let slot = e.add_character_sym(self.fizz_syms[1], init_coord);
                    e.set_layer(slot, LAYER_SPARK);
                    e.set_visible(slot, false);
                    let mut first_drop = u32::MAX;
                    for _ in 0..FIZZ_DROPS {
                        let dslot = e.add_character_sym(self.fizz_syms[0], init_coord);
                        e.set_layer(dslot, LAYER_SPARK);
                        e.set_visible(dslot, false);
                        if first_drop == u32::MAX {
                            first_drop = dslot;
                        }
                    }

                    let mut events = Vec::new();
                    let mut launch = self
                        .final_start
                        .saturating_add(e.rng.randint(0, stagger_span));
                    let mut wave = 0usize;
                    while launch + 16 + FIZZ_POP <= fizz_end && events.len() < 14 {
                        let (site_coord, site_idx) = if wave == 0 {
                            let idx = self.text_grid[&init_coord];
                            (init_coord, idx)
                        } else {
                            let pick = e.rng.randint(0, bottom_sites.len() as i64 - 1) as usize;
                            bottom_sites[pick]
                        };
                        let top_row = col_top
                            .get(&site_coord.column)
                            .copied()
                            .unwrap_or(site_coord.row);
                        let start_y = (site_coord.row - 1).max(canvas.bottom) as f64;
                        let headroom = (top - top_row).max(0);
                        let overshoot = if headroom >= 3 {
                            e.rng.uniform(3.0, (headroom as f64 * 0.72).clamp(4.0, 13.0))
                        } else if headroom >= 1 {
                            e.rng.uniform(1.0, headroom as f64)
                        } else {
                            0.0
                        };
                        let apex_y = (top_row as f64 + overshoot).min(top as f64);
                        let dist = (apex_y - start_y).max(1.0);
                        let speed = e.rng.uniform(0.16, 0.26) * speed_scale;
                        let max_rise = (fizz_end - launch - FIZZ_POP).max(16);
                        let rise_frames = ((dist / speed).round() as i64).clamp(16, max_rise);
                        let pop = launch.saturating_add(rise_frames);
                        if pop.saturating_add(FIZZ_POP) > fizz_end {
                            break;
                        }
                        let init_color = self.text[site_idx].color.unwrap_or_else(|| {
                            config.bubble_colors[(i + wave) % config.bubble_colors.len()]
                        });
                        let mut drop_dir = [(0.0, 0.0); FIZZ_DROPS];
                        for (k, dir) in drop_dir.iter_mut().enumerate() {
                            // Crisp 4-point pinprick crown radiating outward
                            let base_angle = match k {
                                0 => 0.35,  // up-right
                                1 => 1.25,  // high-right
                                2 => 1.89,  // high-left
                                _ => 2.79,  // up-left
                            };
                            let angle = base_angle + e.rng.uniform(-0.22, 0.22);
                            let reach = e.rng.uniform(1.8, 3.2);
                            *dir = (angle.cos() * reach, angle.sin() * reach * 0.55);
                        }
                        events.push(FizzEvent {
                            start_x: site_coord.column as f64,
                            start_y,
                            apex_y,
                            sway: e.rng.uniform(0.4, 1.35),
                            phase: e.rng.uniform(0.0, std::f64::consts::TAU),
                            launch,
                            pop,
                            init_color,
                            large: (i + wave) % 2 == 0,
                            drop_dir,
                        });
                        launch = pop
                            .saturating_add(FIZZ_POP)
                            .saturating_add(e.rng.randint(6, 22));
                        wave += 1;
                    }

                    if !events.is_empty() {
                        let tint = events[0].init_color;
                        self.fizz.push(FizzEmitter {
                            slot,
                            first_drop,
                            tint,
                            cursor: 0,
                            events,
                        });
                    }
                }
            }
        }

        // faint bubbles drifting up the whole screen behind everything
        let ambient = config
            .ambient_bubbles
            .map(|n| n as i64)
            .unwrap_or(canvas.width / 6)
            .min(400);
        if canvas.height >= 6 {
            self.ambient_start_y = (canvas.bottom - 1) as f64;
            let ambient_syms = [e.sym("°"), e.sym("◦"), e.sym("○")];
            let black = Color::from_rgb(0x07, 0x0b, 0x18);
            for k in 0..ambient.max(0) {
                // taller screens, faster drift: a crossing always takes 2-6 s
                let speed = e.rng.uniform(0.07, 0.18) * (canvas.height as f64 / 30.0).max(1.0);
                let travel = ((canvas.height + 2) as f64 / speed).ceil() as i64;
                let period = travel + e.rng.randint(0, travel);
                let offset = e.rng.randint(0, period - 1);
                let x = e.rng.uniform(canvas.left as f64, canvas.right as f64);
                let sway = e.rng.uniform(0.4, 1.6);
                let phase = e.rng.uniform(0.0, std::f64::consts::TAU);
                let sym = ambient_syms[(k as usize) % 3];
                let base = config.bubble_colors[(k as usize * 2) % config.bubble_colors.len()];
                let slot = e.add_character_sym(sym, Coord::new(x as i64, canvas.bottom - 1));
                e.set_layer(slot, LAYER_AMBIENT);
                let visual = paint(e, slot, sym, shift(&base, &black, 0.55), false);
                self.ambient.push(Ambient {
                    slot,
                    x,
                    speed,
                    travel,
                    period,
                    offset,
                    sway,
                    phase,
                    visual,
                });
            }
        }
        self.frame = 0;
        Ok(())
    }

    fn next_frame(&mut self, e: &mut Engine) -> bool {
        if self.frame > self.end_frame {
            return false;
        }
        self.update_ambient(e);
        self.update_bubbles(e);
        self.update_sparks(e);
        if self.frame <= self.final_start {
            self.update_text(e);
        }
        self.update_fizz(e);
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

    fn config(args: &[&str]) -> BubblePopConfig {
        let mut argv = vec!["ttfx", "bubblepop"];
        argv.extend_from_slice(args);
        match crate::cli::Cli::try_parse_from(argv).expect("parse").effect {
            Some(crate::effects::EffectCommand::Bubblepop(c)) => c,
            _ => unreachable!(),
        }
    }

    fn frames(args: &[&str], input: &str) -> u64 {
        run(
            &mut BubblePop::new(config(args)),
            input,
            40,
            10,
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
                    &mut BubblePop::new(config(&[])),
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
    fn short_and_extreme_timings_settle() {
        let c = config(&[
            "--rise-duration",
            "1",
            "--launch-delay",
            "1",
            "--pop-duration",
            "1",
            "--final-hold-time",
            "1",
            "--bubble-count",
            "100000",
        ]);
        let (_, e) = run(
            &mut BubblePop::new(c),
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
            &mut BubblePop::new(config(&[])),
            input,
            20,
            4,
            ExistingColorHandling::Dynamic,
            2,
        );
        assert_settled(&e);
        assert_dynamic_red(&e);
        let (_, e) = run(
            &mut BubblePop::new(config(&[])),
            input,
            20,
            4,
            ExistingColorHandling::Always,
            2,
        );
        assert_settled(&e);
    }

    #[test]
    fn every_timing_option_moves_the_end() {
        let input = "OMARCHY\nhello world\n";
        let base = frames(&[], input);
        for args in [
            ["--rise-duration", "300"],
            ["--launch-delay", "20"],
            ["--pop-duration", "80"],
            ["--final-hold-time", "10"],
            ["--bubble-count", "3"],
        ] {
            assert_ne!(
                frames(&args, input),
                base,
                "{args:?} does not change the run length"
            );
        }
    }

    #[test]
    fn deterministic_for_a_seed() {
        let input = "OMARCHY\nhello world\n";
        let snapshot = |seed| {
            let mut effect = BubblePop::new(config(&[]));
            let config = TerminalConfig {
                canvas_width: 30,
                canvas_height: 8,
                ..TerminalConfig::default()
            };
            let mut e = Engine::new(
                input,
                config,
                Rng::seeded(seed),
                Clock::virtual_with_frame_rate(60),
            )
            .unwrap();
            effect.build(&mut e).unwrap();
            let mut trace = Vec::new();
            while effect.next_frame(&mut e) {
                e.render_here();
                for s in 0..e.char_count() as u32 {
                    trace.push((e.is_visible(s), e.coord(s), e.current_visual(s)));
                }
            }
            trace
        };
        assert_eq!(snapshot(5), snapshot(5));
        assert_ne!(snapshot(5), snapshot(6));
    }

    #[test]
    fn ambient_bubbles_settle_and_can_be_off() {
        for n in ["0", "300"] {
            let (_, e) = run(
                &mut BubblePop::new(config(&["--ambient-bubbles", n])),
                "OMARCHY\nhello world\n",
                120,
                40,
                ExistingColorHandling::Ignore,
                4,
            );
            assert_settled(&e);
        }
    }

    #[test]
    fn every_pop_paints_letters() {
        let logo = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/omarchy-logo.txt"))
            .unwrap_or_else(|_| "OMARCHY OMARCHY OMARCHY\n".repeat(9));
        let config = TerminalConfig {
            canvas_width: 96,
            canvas_height: 24,
            ..TerminalConfig::default()
        };
        let mut e = Engine::new(
            &logo,
            config,
            Rng::seeded(7),
            Clock::virtual_with_frame_rate(60),
        )
        .unwrap();
        let mut effect = BubblePop::new(super::tests::config(&[]));
        effect.build(&mut e).unwrap();
        let space = e.sym(" ");
        for b in &effect.bubbles {
            let painted = effect.text.iter().any(|t| {
                e.input_sym(t.slot) != space
                    && t.reveal >= b.pop
                    && cells(
                        e.input_coord(t.slot).column as f64 - b.burst.0,
                        e.input_coord(t.slot).row as f64 - b.burst.1,
                    ) * WAVE_FRAMES_PER_CELL
                        >= (t.reveal - b.pop) as f64 - 0.5
                    && (t.reveal - b.pop) as f64
                        >= cells(
                            e.input_coord(t.slot).column as f64 - b.burst.0,
                            e.input_coord(t.slot).row as f64 - b.burst.1,
                        ) * WAVE_FRAMES_PER_CELL
                            - 0.5
            });
            assert!(painted, "the pop at frame {} paints nothing", b.pop);
        }
    }

    #[test]
    fn cli_names_do_not_clash() {
        use clap::CommandFactory;
        crate::cli::Cli::command().debug_assert();
    }
}
