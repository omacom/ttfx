//! roses: two curling vines climb the canvas from the lower corners, buds
//! form along them and open into round layered roses, petals drift down,
//! and the dim lettering flowers into a rose-gold gradient that spreads out
//! from the roses. Then the season turns: the vines dry and wither back from
//! the tip to the root, each rose lets go of its petals as the withering
//! reaches it, and as the garden vanishes a single last rose petal drifts
//! across the finished logo, making each letter it brushes blush velvet-rose
//! and fade gently back.
//!
//! Original effect by Lukas Innig (@derluke), https://github.com/derluke/ttfx, MIT.
//! Rewritten for the fx engine.
//!
//! Everything is driven by a frame counter, no scenes or paths. Differences
//! from the original: a rose does not open before its vine has grown to it
//! (so --vine-duration feeds the run length), the roses are round rather
//! than tall diamonds and open in a spiral, the vines grow with a bright
//! tip, the text blooms outward from the roses, after --final-hold-time
//! the garden withers away over --wither-duration, and a solitary rose petal
//! drifts across the logo leaving a fading rose blush so the last frame is
//! the clean text alone.

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
use crate::fx::{Engine, Hooks, Visual};
use crate::utils::geometry::Coord;
use crate::utils::graphics::{shift_color_towards, Color, Gradient, GradientDirection};

#[derive(Args, Debug, Clone)]
pub struct RosesConfig {
    /// Frames the two flowering vines take to climb the canvas.
    #[arg(long = "vine-duration", default_value_t = 300, value_parser = parse_positive_int)]
    pub vine_duration: i64,

    /// Frame on which the first rosebud begins to open.
    #[arg(long = "bloom-start", default_value_t = 150, value_parser = parse_non_negative_int)]
    pub bloom_start: i64,

    /// Frames each rose takes to unfurl all of its petals.
    #[arg(long = "bloom-duration", default_value_t = 110, value_parser = parse_positive_int)]
    pub bloom_duration: i64,

    /// Frames between successive rose blooms.
    #[arg(long = "bloom-delay", default_value_t = 26, value_parser = parse_non_negative_int)]
    pub bloom_delay: i64,

    /// Number of petals that drift from the completed garden.
    #[arg(long = "falling-petals", default_value_t = 72, value_parser = parse_positive_int)]
    pub falling_petals: i64,

    /// Frame on which the lettering begins to flower into color.
    #[arg(long = "text-bloom-start", default_value_t = 400, value_parser = parse_non_negative_int)]
    pub text_bloom_start: i64,

    /// Frames used for the sparkling text reveal.
    #[arg(long = "text-bloom-duration", default_value_t = 240, value_parser = parse_positive_int)]
    pub text_bloom_duration: i64,

    /// Frames to hold the completed rose garden.
    #[arg(long = "final-hold-time", default_value_t = 150, value_parser = parse_non_negative_int)]
    pub final_hold_time: i64,

    /// Frames the garden takes to wither and shed its petals at the end.
    #[arg(long = "wither-duration", default_value_t = 220, value_parser = parse_positive_int)]
    pub wither_duration: i64,

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

/// Text color fades are drawn in this many steps (bounds the visuals interned).
const LEVELS: usize = 24;
/// Fade steps of a shed petal and of a drying vine.
const FADES: usize = 6;
/// Where along each vine (0..1) a rose grows.
const ROSE_AT: [f64; 4] = [0.22, 0.43, 0.65, 0.86];
/// Vine growth covers 0..VINE_SPAN of the run so the tip is in before the end.
const VINE_SPAN: f64 = 0.92;
/// Share of the wither the retreat of the vines takes, tip to root.
const RETREAT: f64 = 0.5;
/// Frames after the hero petal finishes for the last letter's blush to fade back.
const BLUSH_TAIL: i64 = 90;
/// Frames a full blush takes to fade smoothly back to the final text color.
const BLUSH_DECAY_FRAMES: f64 = 78.0;
/// Number of trailing scent/petal-dust cells behind the hero petal.
const TRAIL_LEN: usize = 4;
/// Frame offsets of each trailing cell behind the hero petal.
const TRAIL_LAG: [f64; TRAIL_LEN] = [6.0, 13.0, 21.0, 30.0];
/// The colour a petal fades to as it falls, and a vine as it dries.
const PETAL_DUSK: (u8, u8, u8) = (0x3a, 0x10, 0x22);
const DRY: (u8, u8, u8) = (0x7c, 0x62, 0x3a);
const DRY_DUSK: (u8, u8, u8) = (0x2e, 0x26, 0x1c);

const SYM_CENTER: usize = 0;
const SYM_BUD: usize = 1;
const SYM_OPEN: usize = 2;
const SYM_HEART: usize = 3;
const SYM_DOT: usize = 4;
const PETAL_SYMBOLS: [&str; 5] = ["✦", "•", "●", "♥", "·"];

struct VineCell {
    slot: u32,
    /// Where in the growth (0..1) it appears.
    reveal: f64,
    /// Its visual in each vine color.
    visuals: Vec<Visual>,
    /// Its visual drying out, FADES steps from dry to dusk.
    dry: Vec<Visual>,
    /// Frame it starts to dry at the end.
    wither_at: i64,
    /// Per cell phase of the slow color shimmer.
    phase: f64,
}

struct RosePetal {
    slot: u32,
    offset: Coord,
    stage: f64,
    color_index: usize,
    center: bool,
    /// Frame it lets go at the end, how fast it falls and sways, and when
    /// it is gone.
    release: i64,
    gone: i64,
    fall_speed: f64,
    sway: f64,
    phase: f64,
}

struct Rose {
    center: Coord,
    petals: Vec<RosePetal>,
    /// Frame the vine reaches it (the bud shows) and it starts to open.
    bud: i64,
    start: i64,
}

struct FallingPetal {
    slot: u32,
    origin: Coord,
    born: i64,
    lifetime: i64,
    drift: f64,
    fall_speed: f64,
    phase: f64,
    color_index: usize,
}

struct Letter {
    slot: u32,
    coord: Coord,
    /// Where in the reveal (0..1) it starts.
    reveal: f64,
    /// Its gradient color (or input color, dynamic handling) to fade into.
    target: Color,
    spark: Visual,
    finished: Visual,
    /// Whether this cell has preexisting colors to respect during the blush.
    has_input_color: bool,
    /// Whether this cell has no input fg under dynamic handling (e.g. bg-only space).
    bg_only_dynamic: bool,
    /// The fade level last drawn (usize::MAX: none).
    level: usize,
    /// Current rose blush intensity in 0..=1.
    blush: f64,
    /// The quantized blush level last drawn (0: none).
    blush_level: usize,
}

/// The solitary rose petal that drifts across the finished logo during the
/// closing flourish, brushing each letter with a warm rose blush.
struct LastPetal {
    slot: u32,
    wing_l: u32,
    wing_r: u32,
    show_wings: bool,
    trail: [u32; TRAIL_LEN],
    start: i64,
    flight: i64,
    x0: f64,
    x1: f64,
    y0: f64,
    y1: f64,
    sway_x: f64,
    wave_y: f64,
    brush_rx: f64,
    brush_ry: f64,
    broad: Visual,
    tilt: Visual,
    glint: Visual,
    wing_l_vis: Visual,
    wing_r_vis: Visual,
    wing_tilt_l: Visual,
    wing_tilt_r: Visual,
    fade: Vec<Visual>,
    trail_visuals: [Visual; TRAIL_LEN],
    blush_rose: Color,
    blush_light: Color,
    blush_glow: Color,
}

pub struct Roses {
    config: RosesConfig,
    vines: Vec<VineCell>,
    roses: Vec<Rose>,
    falling: Vec<FallingPetal>,
    letters: Vec<Letter>,
    /// petal_visuals[(symbol * colors + color) * FADES + fade]
    petal_visuals: Vec<Visual>,
    /// The vine's bud before its rose opens.
    bud_visual: Option<Visual>,
    /// The solitary closing-flourish petal.
    last_petal: Option<LastPetal>,
    frame: i64,
    /// First frame of the wither (the garden's timeline plus the hold).
    wither_start: i64,
    /// First frame of the closing petal flourish.
    flourish_start: i64,
    end_frame: i64,
}

fn other(message: String) -> EngineError {
    EngineError::Other(message)
}

fn rgb((r, g, b): (u8, u8, u8)) -> Color {
    Color::from_rgb(r, g, b)
}

fn shift(from: &Color, to: &Color, amount: f64) -> Color {
    shift_color_towards(from, to, amount.clamp(0.0, 1.0)).unwrap_or(*from)
}

fn colored_bg(e: &mut Engine, symbol: &str, fg: Color, bg: Option<Color>, bold: bool) -> Visual {
    let sym = e.sym(symbol);
    e.visuals.make(
        &e.symbols,
        VisualInfo {
            sym,
            fg: Some(fg),
            bg,
            attrs: HAS_COLORS | if bold { BOLD } else { 0 },
        },
    )
}

fn colored(e: &mut Engine, symbol: &str, fg: Color, bold: bool) -> Visual {
    colored_bg(e, symbol, fg, None, bold)
}

/// An input character's visual, with Animation.set_appearance's override:
/// under --existing-color-handling always a character with input colors
/// keeps them (and its bold).
fn text_visual(
    e: &mut Engine,
    slot: u32,
    symbol: Option<&str>,
    fg: Option<Color>,
    bg: Option<Color>,
    bold: bool,
) -> Visual {
    let sym = match symbol {
        Some(s) => e.sym(s),
        None => e.input_sym(slot),
    };
    let info = if e.existing_color_handling() == ExistingColorHandling::Always
        && e.uses_preexisting_colors(slot)
    {
        VisualInfo {
            sym,
            fg: e.input_fg(slot),
            bg: e.input_bg(slot),
            attrs: HAS_COLORS | if e.input_bold(slot) { BOLD } else { 0 },
        }
    } else {
        VisualInfo {
            sym,
            fg,
            bg,
            attrs: HAS_COLORS | if bold { BOLD } else { 0 },
        }
    };
    e.visuals.make(&e.symbols, info)
}

/// A per-character value in 0..1 from its id (no RNG draw).
fn hash01(id: u32, salt: u32) -> f64 {
    let mut x = id.wrapping_mul(0x9e37_79b9) ^ salt.wrapping_mul(0x85eb_ca6b);
    x ^= x >> 15;
    x = x.wrapping_mul(0x2c1b_3c6d);
    x ^= x >> 12;
    (x % 10_000) as f64 / 10_000.0
}

/// The cells of a round rose of `radius` rows (twice as wide in columns, so
/// it looks round in a terminal): (dx, dy, stage, ring 0..1 from the
/// center out, tone). Petals open from the heart outward in a spiral, and
/// a darker crease (tone -1) curls in to the heart so it reads as a rose,
/// not a ball.
fn rose_layout(radius: i64) -> Vec<(i64, i64, f64, f64, i64)> {
    let reach = radius as f64 + 0.3;
    let mut cells = Vec::new();
    for dy in -radius..=radius {
        for dx in -2 * radius - 1..=2 * radius + 1 {
            let x = dx as f64 / 2.0;
            let y = dy as f64;
            let d = (x * x + y * y).sqrt();
            if d > reach {
                continue;
            }
            let ring = d / reach;
            let turn = (y.atan2(x) + d * 2.4).rem_euclid(std::f64::consts::TAU)
                / std::f64::consts::TAU;
            let stage = if dx == 0 && dy == 0 {
                0.0
            } else {
                0.06 + ring * 0.6 + turn * 0.14
            };
            // one darker crease curling in to the heart
            let crease = (y.atan2(x) + d * 2.0).rem_euclid(std::f64::consts::TAU)
                / std::f64::consts::TAU;
            let tone = if (dx != 0 || dy != 0) && crease < 0.2 {
                -1
            } else {
                0
            };
            cells.push((dx, dy, stage, ring, tone));
        }
    }
    cells
}

impl Roses {
    pub fn new(config: RosesConfig) -> Self {
        Roses {
            config,
            vines: Vec::new(),
            roses: Vec::new(),
            falling: Vec::new(),
            letters: Vec::new(),
            petal_visuals: Vec::new(),
            bud_visual: None,
            last_petal: None,
            frame: 0,
            wither_start: 0,
            flourish_start: 0,
            end_frame: 0,
        }
    }

    fn petal_visual(&self, symbol: usize, color: usize, fade: usize) -> Visual {
        let colors = self.config.rose_colors.len();
        self.petal_visuals[(symbol * colors + color.min(colors - 1)) * FADES + fade.min(FADES - 1)]
    }

    fn vine_coord(e: &Engine, side: usize, t: f64) -> Coord {
        let c = &e.canvas;
        let width = (c.right - c.left).max(1) as f64;
        let height = (c.top - c.bottom).max(1) as f64;
        let amplitude = (width / 12.0).clamp(3.0, 7.0);
        let wave = (t * std::f64::consts::TAU * 1.75 + side as f64 * 1.4).sin() * amplitude;
        let column = if side == 0 {
            c.left as f64 + 4.0 + t * width * 0.28 + wave
        } else {
            c.right as f64 - 4.0 - t * width * 0.28 - wave
        };
        Coord::new(
            column.round() as i64,
            (c.bottom as f64 + t * height).round() as i64,
        )
    }

    /// First frame on which the vine has grown past `reveal`.
    fn vine_reaches(&self, reveal: f64) -> i64 {
        (reveal * self.config.vine_duration as f64).ceil() as i64
    }

    /// Frame the withering, running from the tip down, reaches `reveal`.
    fn withers_at(&self, reveal: f64) -> i64 {
        let from_tip = (1.0 - reveal / (VINE_SPAN + 0.03)).clamp(0.0, 1.0);
        self.wither_start
            + (from_tip * RETREAT * self.config.wither_duration as f64).round() as i64
    }

    fn update_vines(&self, e: &mut Engine) {
        let progress = (self.frame as f64 / self.config.vine_duration as f64).clamp(0.0, 1.0);
        let colors = self.config.vine_colors.len();
        let dry_frames = (self.config.wither_duration as f64 * 0.18).max(1.0);
        for vine in &self.vines {
            if vine.reveal > progress {
                e.set_visible(vine.slot, false);
                continue;
            }
            if self.frame >= vine.wither_at {
                let fade = ((self.frame - vine.wither_at) as f64 / dry_frames * FADES as f64)
                    as usize;
                if fade >= FADES {
                    e.set_visible(vine.slot, false);
                } else {
                    e.set_visual(vine.slot, vine.dry[fade]);
                }
                continue;
            }
            // a fresh tip in the lightest green, the grown stem shimmering
            // slowly through the darker ones
            let behind = progress - vine.reveal;
            let color = if progress < 1.0 && behind < 0.025 {
                colors - 1
            } else if colors == 1 {
                0
            } else {
                let wave = ((self.frame as f64 * 0.035 - vine.reveal * 9.0 + vine.phase).sin()
                    + 1.0)
                    / 2.0;
                ((wave * (colors - 1) as f64).round() as usize).min(colors - 2)
            };
            e.set_visual(vine.slot, vine.visuals[color]);
            e.set_visible(vine.slot, true);
        }
    }

    fn update_roses(&self, e: &mut Engine) {
        let duration = self.config.bloom_duration as f64;
        let colors = self.config.rose_colors.len();
        for rose in &self.roses {
            let progress = ((self.frame - rose.start) as f64 / duration).clamp(0.0, 1.0);
            for petal in &rose.petals {
                if self.frame >= petal.release {
                    self.shed(e, rose, petal);
                    continue;
                }
                if self.frame < rose.start {
                    // a green bud waits on the vine
                    let bud = petal.center && self.frame >= rose.bud;
                    if let (true, Some(visual)) = (bud, self.bud_visual) {
                        e.set_coordinate(petal.slot, rose.center);
                        e.set_visual(petal.slot, visual);
                    }
                    e.set_visible(petal.slot, bud);
                    continue;
                }
                if progress < petal.stage {
                    e.set_visible(petal.slot, false);
                    continue;
                }
                let local =
                    ((progress - petal.stage) / (1.0 - petal.stage).max(0.01)).clamp(0.0, 1.0);
                let eased = 1.0 - (1.0 - local).powi(3);
                e.set_coordinate(
                    petal.slot,
                    Coord::new(
                        rose.center.column + (petal.offset.column as f64 * eased).round() as i64,
                        rose.center.row + (petal.offset.row as f64 * eased).round() as i64,
                    ),
                );
                let id = e.ch.id[petal.slot as usize] as i64;
                let shimmer = usize::from(progress >= 1.0 && (self.frame + id) % 53 < 3);
                // a petal opens in a lighter pink and settles into its own
                let opening = ((1.0 - local) * 2.0).round() as usize;
                let symbol = if petal.center {
                    SYM_CENTER
                } else if local < 0.4 {
                    SYM_BUD
                } else {
                    SYM_OPEN
                };
                let color = (petal.color_index + shimmer + opening).min(colors - 1);
                e.set_visual(petal.slot, self.petal_visual(symbol, color, 0));
                e.set_visible(petal.slot, true);
            }
        }
    }

    /// A petal let go at the end: it falls, sways and fades to nothing.
    fn shed(&self, e: &mut Engine, rose: &Rose, petal: &RosePetal) {
        if self.frame >= petal.gone || self.frame < rose.start {
            e.set_visible(petal.slot, false);
            return;
        }
        let t = (self.frame - petal.release) as f64;
        let life = (petal.gone - petal.release).max(1) as f64;
        let ratio = t / life;
        let sway = (t * 0.11 + petal.phase).sin() * petal.sway;
        e.set_coordinate(
            petal.slot,
            Coord::new(
                (rose.center.column as f64 + petal.offset.column as f64 + sway).round() as i64,
                (rose.center.row as f64 + petal.offset.row as f64
                    - petal.fall_speed * t * (0.4 + ratio))
                    .round() as i64,
            ),
        );
        let symbol = if petal.center {
            SYM_CENTER
        } else if ratio < 0.55 {
            SYM_OPEN
        } else if ratio < 0.8 {
            SYM_BUD
        } else {
            SYM_DOT
        };
        let fade = (ratio * FADES as f64) as usize;
        e.set_visual(
            petal.slot,
            self.petal_visual(symbol, petal.color_index, fade),
        );
        e.set_visible(petal.slot, true);
    }

    fn update_falling(&self, e: &mut Engine) {
        for petal in &self.falling {
            let age = self.frame - petal.born;
            if age < 0 || age >= petal.lifetime {
                e.set_visible(petal.slot, false);
                continue;
            }
            let t = age as f64;
            let sway = (t * 0.13 + petal.phase).sin() * 2.2;
            e.set_coordinate(
                petal.slot,
                Coord::new(
                    (petal.origin.column as f64 + petal.drift * t + sway).round() as i64,
                    (petal.origin.row as f64 - petal.fall_speed * t).round() as i64,
                ),
            );
            let ratio = t / petal.lifetime as f64;
            let symbol = if ratio < 0.70 { SYM_HEART } else { SYM_DOT };
            let color = petal.color_index + (ratio * 2.0).floor() as usize;
            let fade = ((ratio - 0.6).max(0.0) / 0.4 * (FADES - 1) as f64) as usize;
            e.set_visual(petal.slot, self.petal_visual(symbol, color, fade));
            e.set_visible(petal.slot, true);
        }
    }

    fn update_text(&mut self, e: &mut Engine) {
        let c = &self.config;
        if self.frame < c.text_bloom_start {
            return;
        }
        let progress = ((self.frame - c.text_bloom_start) as f64 / c.text_bloom_duration as f64)
            .clamp(0.0, 1.0);
        let from = c.rose_colors[1.min(c.rose_colors.len() - 1)];
        for letter in &mut self.letters {
            let local = ((progress - letter.reveal * 0.62) / 0.38).clamp(0.0, 1.0);
            if local <= 0.0 {
                continue;
            }
            if local < 0.16 {
                e.set_visual(letter.slot, letter.spark);
                continue;
            }
            let color_progress = ((local - 0.16) / 0.84).clamp(0.0, 1.0);
            let eased = 1.0 - (1.0 - color_progress).powi(3);
            let level = (eased * LEVELS as f64).round() as usize;
            if level == letter.level {
                continue;
            }
            letter.level = level;
            let visual = if level >= LEVELS {
                letter.finished
            } else {
                let color = shift(&from, &letter.target, level as f64 / LEVELS as f64);
                text_visual(e, letter.slot, None, Some(color), None, true)
            };
            e.set_visual(letter.slot, visual);
        }
    }

    /// Solitary last rose petal drifting across the finished logo; each letter
    /// it brushes blushes velvet-rose (with a subtle dark-rose halo) and fades
    /// smoothly back to its final color.
    fn update_flourish(&mut self, e: &mut Engine) {
        let Some(petal) = &self.last_petal else {
            return;
        };
        let last = self.frame >= self.end_frame;
        let age = (self.frame - petal.start) as f64;
        let flight = petal.flight.max(1) as f64;
        let u = age / flight;
        let petal_active = !last && (0.0..=1.0).contains(&u);

        let petal_pos = |t: f64| -> (f64, f64) {
            let taper = 1.0 - (2.0 * t - 1.0).powi(4);
            let x = petal.x0
                + (petal.x1 - petal.x0) * t
                + (t * std::f64::consts::TAU * 2.0).sin() * petal.sway_x * taper;
            let env = (t * (1.0 - t) * 4.0).max(0.0).sqrt();
            let y = petal.y0
                + (petal.y1 - petal.y0) * t
                + (t * std::f64::consts::TAU * 1.75 + 0.4).sin() * petal.wave_y * env;
            (x, y)
        };

        let (px, py) = if petal_active {
            let (px, py) = petal_pos(u);
            let col = px.round() as i64;
            let row = py.round() as i64;
            e.set_coordinate(petal.slot, Coord::new(col, row));
            if u > 0.84 {
                let f = (((u - 0.84) / 0.16) * FADES as f64) as usize;
                e.set_visual(petal.slot, petal.fade[f.min(FADES - 1)]);
                e.set_visible(petal.slot, true);
                e.set_visible(petal.wing_l, false);
                e.set_visible(petal.wing_r, false);
            } else {
                // Rock and tumble gently in the breeze at the crests/troughs of the S-wave
                let slope = (u * std::f64::consts::TAU * 1.75 + 0.4).cos();
                let turn = slope.abs();
                let (core_vis, left_vis, right_vis) = if turn < 0.08 {
                    (petal.glint, None, None)
                } else if turn < 0.30 {
                    if slope >= 0.0 {
                        (petal.tilt, Some(petal.wing_tilt_l), None)
                    } else {
                        (petal.tilt, None, Some(petal.wing_tilt_r))
                    }
                } else {
                    (petal.broad, Some(petal.wing_l_vis), Some(petal.wing_r_vis))
                };
                e.set_visual(petal.slot, core_vis);
                e.set_visible(petal.slot, true);
                if petal.show_wings {
                    if let Some(vis) = left_vis {
                        e.set_coordinate(petal.wing_l, Coord::new(col - 1, row));
                        e.set_visual(petal.wing_l, vis);
                        e.set_visible(petal.wing_l, true);
                    } else {
                        e.set_visible(petal.wing_l, false);
                    }
                    if let Some(vis) = right_vis {
                        e.set_coordinate(petal.wing_r, Coord::new(col + 1, row));
                        e.set_visual(petal.wing_r, vis);
                        e.set_visible(petal.wing_r, true);
                    } else {
                        e.set_visible(petal.wing_r, false);
                    }
                } else {
                    e.set_visible(petal.wing_l, false);
                    e.set_visible(petal.wing_r, false);
                }
            }
            (px, py)
        } else {
            e.set_visible(petal.slot, false);
            e.set_visible(petal.wing_l, false);
            e.set_visible(petal.wing_r, false);
            (0.0, 0.0)
        };

        // Subtle trailing scent/petal-dust wake behind the hero petal
        for (i, &trail_slot) in petal.trail.iter().enumerate() {
            let tu = (age - TRAIL_LAG[i]) / flight;
            if !last && tu > 0.02 && tu < 0.96 {
                let (tx, ty) = petal_pos(tu);
                e.set_coordinate(trail_slot, Coord::new(tx.round() as i64, ty.round() as i64));
                e.set_visual(trail_slot, petal.trail_visuals[i]);
                e.set_visible(trail_slot, true);
            } else {
                e.set_visible(trail_slot, false);
            }
        }

        // Update the rose blush on each letter; only touch cells whose quantized
        // blush level changes so 120 Hz redraw stays minimal and local.
        let decay = 1.0 / BLUSH_DECAY_FRAMES;
        let fade_env = if petal_active && u <= 0.96 {
            ((1.0 - u) / 0.12).clamp(0.0, 1.0) * (u / 0.06).clamp(0.0, 1.0)
        } else {
            0.0
        };
        let rx = petal.brush_rx;
        let ry = petal.brush_ry;
        let blush_rose = petal.blush_rose;
        let blush_light = petal.blush_light;
        let blush_glow = petal.blush_glow;
        let black = Color::from_rgb(0, 0, 0);
        let handling = e.existing_color_handling();

        for letter in &mut self.letters {
            if last {
                letter.blush = 0.0;
            } else {
                letter.blush = (letter.blush - decay).max(0.0);
                if fade_env > 0.0 && !letter.bg_only_dynamic {
                    let dx = (letter.coord.column as f64 - px) / rx;
                    let dy = (letter.coord.row as f64 - py) / ry;
                    let d2 = dx * dx + dy * dy;
                    if d2 < 1.0 {
                        let touch = (1.0 - d2).powf(1.3) * fade_env;
                        if touch > letter.blush {
                            letter.blush += (touch - letter.blush) * 0.35;
                        }
                    }
                }
            }

            let level = if last {
                0
            } else {
                (letter.blush * LEVELS as f64).round().clamp(0.0, LEVELS as f64) as usize
            };
            if level == letter.blush_level {
                continue;
            }
            letter.blush_level = level;
            let visual = if level == 0 {
                letter.finished
            } else {
                let t = level as f64 / LEVELS as f64;
                let fg = if t <= 0.75 {
                    shift(&letter.target, &blush_rose, (t / 0.75) * 0.85)
                } else {
                    let core = shift(&letter.target, &blush_rose, 0.85);
                    shift(&core, &blush_light, ((t - 0.75) / 0.25) * 0.45)
                };
                let bg = if handling != ExistingColorHandling::Ignore && letter.has_input_color {
                    e.input_bg(letter.slot)
                } else if t > 0.25 {
                    let glow = ((t - 0.25) / 0.75).powf(1.4);
                    Some(shift(&black, &blush_glow, glow))
                } else {
                    None
                };
                text_visual(e, letter.slot, None, Some(fg), bg, true)
            };
            e.set_visual(letter.slot, visual);
        }
    }
}

impl Hooks for Roses {}

impl Effect for Roses {
    fn build(&mut self, e: &mut Engine) -> Result<(), EngineError> {
        let config = self.config.clone();
        let canvas = e.canvas.clone();
        let dynamic = e.existing_color_handling() == ExistingColorHandling::Dynamic;
        let gradient = Gradient::new(
            &config.final_gradient_stops,
            &config.final_gradient_steps,
            false,
            false,
        )
        .map_err(other)?;
        let mapping = gradient
            .build_coordinate_color_mapping(
                canvas.text_bottom,
                canvas.text_top,
                canvas.text_left,
                canvas.text_right,
                config.final_gradient_direction,
            )
            .map_err(other)?;
        let fallback = config.final_gradient_stops[0];
        let white = Color::from_rgb(255, 255, 255);
        let colors = config.rose_colors.len();
        let vine_colors = config.vine_colors.len();

        // the timeline, worked out before anything is placed: the roses
        // open in turn up both vines at once, each once its vine is there
        let mut sites = Vec::new();
        for (index, &t) in ROSE_AT.iter().enumerate() {
            for side in 0..2 {
                sites.push((index, side, t, Self::vine_coord(e, side, t)));
            }
        }
        let mut starts = Vec::with_capacity(sites.len());
        for (order, &(_, _, t, _)) in sites.iter().enumerate() {
            let bud = self.vine_reaches(t * VINE_SPAN);
            starts.push((
                bud,
                (config.bloom_start + order as i64 * config.bloom_delay).max(bud + 1),
            ));
        }
        // petals drift from the open roses in waves
        let lifetimes: Vec<i64> = (0..config.falling_petals)
            .map(|_| e.rng.randint(120, 181))
            .collect();
        let mut last_death = 0;
        for (index, &lifetime) in lifetimes.iter().enumerate() {
            let wave = (index / sites.len()) as i64;
            let born = starts[index % sites.len()].1 + config.bloom_duration + wave * 13;
            last_death = last_death.max(born + lifetime);
        }
        let text_end = config.text_bloom_start + config.text_bloom_duration;
        let last_bloom = starts
            .iter()
            .map(|s| s.1 + config.bloom_duration)
            .max()
            .unwrap_or(0);
        let garden_end = text_end
            .max(last_bloom)
            .max(last_death)
            .max(config.vine_duration);
        self.wither_start = garden_end + config.final_hold_time;
        let wither_end = self.wither_start + config.wither_duration;
        let text_width = (canvas.text_right - canvas.text_left).max(1) as f64;
        let text_height = (canvas.text_top - canvas.text_bottom).max(1) as f64;
        let overlap = (config.wither_duration / 8).min(24);
        self.flourish_start = (wither_end - overlap).max(text_end + 1);
        let flight_frames = (160.0 + text_width * 1.1).clamp(160.0, 280.0).round() as i64;
        self.end_frame = self.flourish_start + flight_frames + BLUSH_TAIL;

        // the lettering: dim, on top of the garden; it flowers outward from
        // the nearest rose
        let rose_distance = |coord: Coord| {
            sites
                .iter()
                .map(|&(_, _, _, c)| {
                    let x = (coord.column - c.column) as f64 / 2.0;
                    let y = (coord.row - c.row) as f64;
                    (x * x + y * y).sqrt()
                })
                .fold(f64::MAX, f64::min)
        };
        let slots = e.get_characters(
            CharacterFilter::default(),
            CharacterSort::TopToBottomLeftToRight,
        );
        let distances: Vec<f64> = slots
            .iter()
            .map(|&s| rose_distance(e.input_coord(s)))
            .collect();
        let near = distances.iter().copied().fold(f64::MAX, f64::min);
        let far = distances.iter().copied().fold(0.0, f64::max);
        for (&slot, &distance) in slots.iter().zip(&distances) {
            let coord = e.input_coord(slot);
            let color = mapping.get(&coord).copied().unwrap_or(fallback);
            let has_input_color = e.uses_preexisting_colors(slot);
            let bg_only_dynamic = dynamic && e.input_fg(slot).is_none();
            let (target, finished) = if dynamic {
                let (fg, bg) = (e.input_fg(slot), e.input_bg(slot));
                (
                    fg.unwrap_or(color),
                    text_visual(e, slot, None, fg, bg, false),
                )
            } else {
                (color, text_visual(e, slot, None, Some(color), None, true))
            };
            let spread = if far > near {
                (distance - near) / (far - near)
            } else {
                0.0
            };
            let id = e.ch.id[slot as usize];
            let jitter = hash01(id, 3) * 0.12;
            let shadow = text_visual(e, slot, None, Some(config.shadow_color), None, false);
            let spark = text_visual(e, slot, Some("✦"), Some(white), None, true);
            e.set_layer(slot, 6);
            e.set_visual(slot, shadow);
            e.set_visible(slot, true);
            self.letters.push(Letter {
                slot,
                coord,
                reveal: (spread * 0.9 + jitter).clamp(0.0, 1.0),
                target,
                spark,
                finished,
                has_input_color,
                bg_only_dynamic,
                level: usize::MAX,
                blush: 0.0,
                blush_level: 0,
            });
        }

        // the two vines, one cell per step of the curve, a leaf now and then
        let steps = ((canvas.top - canvas.bottom).max(1) * 6) as usize;
        let dry = rgb(DRY);
        let dry_dusk = rgb(DRY_DUSK);
        for side in 0..2 {
            let mut path: Vec<(Coord, f64)> = Vec::new();
            for step in 0..=steps {
                let t = step as f64 / steps as f64;
                let coord = Self::vine_coord(e, side, t);
                if path.last().is_none_or(|&(last, _)| last != coord) {
                    path.push((coord, t));
                }
            }
            for (index, &(coord, t)) in path.iter().enumerate() {
                let previous = path[index.saturating_sub(1)].0;
                let next = path[(index + 1).min(path.len() - 1)].0;
                let dx = next.column - previous.column;
                let dy = (next.row - previous.row).max(0);
                let symbol = if dx == 0 || dy > dx.abs() * 2 {
                    "│"
                } else if dx > 0 {
                    "/"
                } else {
                    "\\"
                };
                let reveal = t * VINE_SPAN;
                self.add_vine(e, symbol, coord, reveal, false, dry, dry_dusk);
                if index % 9 == 5 {
                    let outward = if (index / 9) % 2 == 0 { 1 } else { -1 };
                    let toward = if side == 0 { outward } else { -outward };
                    let leaf = if toward > 0 { ")" } else { "(" };
                    let leaf_coord = Coord::new(coord.column + toward, coord.row);
                    self.add_vine(e, leaf, leaf_coord, reveal + 0.025, true, dry, dry_dusk);
                }
            }
        }
        let bud_color = config.vine_colors[2.min(vine_colors - 1)];
        self.bud_visual = Some(colored(e, "●", bud_color, true));

        let dusk = rgb(PETAL_DUSK);
        for symbol in PETAL_SYMBOLS {
            for &color in &config.rose_colors {
                for fade in 0..FADES {
                    let shade = shift(&color, &dusk, fade as f64 / FADES as f64);
                    let visual = colored(e, symbol, shade, true);
                    self.petal_visuals.push(visual);
                }
            }
        }

        // the roses, bigger on a big canvas
        let radius = if canvas.top - canvas.bottom >= 40 { 3 } else { 2 };
        let layout = rose_layout(radius);
        let wither = config.wither_duration as f64;
        for (order, &(_, _, t, center)) in sites.iter().enumerate() {
            let (bud, start) = starts[order];
            let release = self.withers_at(t * VINE_SPAN);
            let mut petals = Vec::with_capacity(layout.len());
            for &(dx, dy, stage, ring, tone) in &layout {
                let slot = e.add_character("•", center);
                e.set_layer(slot, 4);
                let id = e.ch.id[slot as usize];
                // the outer petals let go first, the heart last
                let petal_release =
                    release + ((1.0 - ring) * 0.1 * wither + hash01(id, 11) * 0.06 * wither) as i64;
                let room = (wither_end - petal_release).max(1) as f64;
                let gone = petal_release + (room * (0.55 + hash01(id, 13) * 0.4)) as i64;
                let center_petal = dx == 0 && dy == 0;
                let color_index = if center_petal {
                    colors - 1
                } else {
                    let base = ((1.0 - ring) * (colors - 1) as f64).round() as i64;
                    (base + tone).clamp(0, colors as i64 - 1) as usize
                };
                petals.push(RosePetal {
                    slot,
                    offset: Coord::new(dx, dy),
                    stage,
                    color_index,
                    center: center_petal,
                    release: petal_release,
                    gone: gone.min(wither_end),
                    fall_speed: 0.09 + hash01(id, 17) * 0.12,
                    sway: 0.8 + hash01(id, 19) * 1.6,
                    phase: hash01(id, 23) * std::f64::consts::TAU,
                });
            }
            self.roses.push(Rose {
                center,
                petals,
                bud,
                start,
            });
        }

        for (index, &lifetime) in lifetimes.iter().enumerate() {
            let rose = &self.roses[index % self.roses.len()];
            let wave = (index / self.roses.len()) as i64;
            let born = rose.start + config.bloom_duration + wave * 13;
            let origin = rose.center;
            let slot = e.add_character("♥", origin);
            e.set_layer(slot, 5);
            let drift = e.rng.uniform(-0.045, 0.045);
            let fall_speed = e.rng.uniform(0.055, 0.12);
            let phase = e.rng.uniform(0.0, std::f64::consts::TAU);
            let color_index = e.rng.randint(1, colors as i64) as usize;
            self.falling.push(FallingPetal {
                slot,
                origin,
                born,
                lifetime,
                drift,
                fall_speed,
                phase,
                color_index,
            });
        }

        // Solitary hero petal for the closing flourish, drifting above the
        // finished logo and brushing each letter into a warm rose blush.
        let margin_x = (text_width * 0.06).clamp(1.0, 5.0);
        let x0 = (canvas.text_left as f64 - margin_x).max(canvas.left as f64);
        let x1 = (canvas.text_right as f64 + margin_x).min(canvas.right as f64);
        let y0 = (canvas.text_top as f64 + (text_height * 0.5).clamp(2.0, 4.0))
            .min(canvas.top as f64);
        let y1 = (canvas.text_bottom as f64 - (text_height * 0.4).clamp(2.0, 4.0))
            .max(canvas.bottom as f64);
        let start_coord = Coord::new(x0.round() as i64, y0.round() as i64);
        let hero_slot = e.add_character("♥", start_coord);
        e.set_layer(hero_slot, 8);
        e.set_visible(hero_slot, false);
        let wing_l = e.add_character("▗", start_coord);
        e.set_layer(wing_l, 8);
        e.set_visible(wing_l, false);
        let wing_r = e.add_character("▘", start_coord);
        e.set_layer(wing_r, 8);
        e.set_visible(wing_r, false);
        let show_wings = (canvas.right - canvas.left) >= 20;
        let mut trail = [0u32; TRAIL_LEN];
        for slot in &mut trail {
            let s = e.add_character("·", start_coord);
            e.set_layer(s, 7);
            e.set_visible(s, false);
            *slot = s;
        }
        let rose_dark = config.rose_colors[0];
        let rose_deep = config.rose_colors[1.min(colors - 1)];
        let rose_mid = config.rose_colors[2.min(colors - 1)];
        let rose_bright = config.rose_colors[3.min(colors - 1)];
        let rose_light = config.rose_colors[colors - 1];
        let broad_color = shift(&rose_bright, &white, 0.18);
        let petal_bg = shift(&Color::from_rgb(0, 0, 0), &rose_dark, 0.42);
        let broad = colored_bg(e, "♥", broad_color, Some(petal_bg), true);
        let tilt = colored_bg(e, "●", rose_mid, Some(petal_bg), true);
        let glint = colored(e, "✦", rose_light, true);
        let wing_l_vis = colored(e, "▗", rose_deep, false);
        let wing_r_vis = colored(e, "▘", rose_mid, false);
        let wing_tilt_l = colored(e, "▄", rose_deep, false);
        let wing_tilt_r = colored(e, "▀", rose_mid, false);
        let fade = (0..FADES)
            .map(|step| {
                let sym = if step < FADES / 2 {
                    "♥"
                } else if step + 1 < FADES {
                    "•"
                } else {
                    "·"
                };
                let shade = shift(&broad_color, &dusk, step as f64 / FADES as f64);
                colored(e, sym, shade, step < FADES / 2)
            })
            .collect();
        let trail_visuals = [
            colored(e, "•", shift(&rose_bright, &dusk, 0.22), false),
            colored(e, "·", shift(&rose_mid, &dusk, 0.42), false),
            colored(e, "·", shift(&rose_deep, &dusk, 0.62), false),
            colored(e, "·", shift(&rose_deep, &dusk, 0.82), false),
        ];
        let blush_rose = shift(&rose_deep, &rose_mid, 0.42);
        let blush_glow = shift(&Color::from_rgb(0, 0, 0), &blush_rose, 0.36);
        let brush_ry = (text_height * 0.55).clamp(2.5, 5.5);
        let brush_rx = brush_ry * 2.1;
        self.last_petal = Some(LastPetal {
            slot: hero_slot,
            wing_l,
            wing_r,
            show_wings,
            trail,
            start: self.flourish_start,
            flight: flight_frames,
            x0,
            x1,
            y0,
            y1,
            sway_x: (text_width * 0.03).clamp(0.5, 2.5),
            wave_y: (text_height * 0.36).clamp(1.0, 4.2),
            brush_rx,
            brush_ry,
            broad,
            tilt,
            glint,
            wing_l_vis,
            wing_r_vis,
            wing_tilt_l,
            wing_tilt_r,
            fade,
            trail_visuals,
            blush_rose,
            blush_light: rose_light,
            blush_glow,
        });

        self.frame = 0;
        Ok(())
    }

    fn next_frame(&mut self, e: &mut Engine) -> bool {
        if self.frame > self.end_frame {
            return false;
        }
        self.update_vines(e);
        self.update_roses(e);
        self.update_falling(e);
        self.update_text(e);
        if self.frame >= self.flourish_start {
            self.update_flourish(e);
        }
        if self.frame >= self.end_frame {
            for index in 0..e.added_chars.len() {
                let slot = e.added_chars[index];
                e.set_visible(slot, false);
            }
        }
        self.frame += 1;
        true
    }
}

impl Roses {
    #[allow(clippy::too_many_arguments)]
    fn add_vine(
        &mut self,
        e: &mut Engine,
        symbol: &str,
        coord: Coord,
        reveal: f64,
        leaf: bool,
        dry: Color,
        dry_dusk: Color,
    ) {
        let slot = e.add_character(symbol, coord);
        e.set_layer(slot, 2);
        let visuals = self
            .config
            .vine_colors
            .iter()
            .map(|&c| colored(e, symbol, c, leaf))
            .collect();
        let dry = (0..FADES)
            .map(|fade| {
                let shade = shift(&dry, &dry_dusk, fade as f64 / FADES as f64);
                colored(e, symbol, shade, false)
            })
            .collect();
        let id = e.ch.id[slot as usize];
        self.vines.push(VineCell {
            slot,
            reveal,
            visuals,
            dry,
            wither_at: self.withers_at(reveal),
            phase: hash01(id, 5) * 0.8,
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::ctx::Clock;
    use crate::engine::terminal::TerminalConfig;
    use crate::utils::rng::Rng;
    use clap::Parser;

    #[derive(Parser)]
    struct Cli {
        #[command(flatten)]
        config: RosesConfig,
    }

    fn config(args: &[&str]) -> RosesConfig {
        let mut all = vec!["roses"];
        all.extend_from_slice(args);
        Cli::parse_from(all).config
    }

    /// Run to completion: the frame count, the engine, and per slot
    /// (visible, coord, visual) at the end. None when the engine turns the
    /// input away (the CLI does so for blank input before any effect runs).
    fn run(
        input: &str,
        width: i64,
        height: i64,
        handling: ExistingColorHandling,
        seed: u64,
        args: &[&str],
    ) -> Option<(u64, Engine, Vec<(bool, Coord, Visual)>)> {
        let terminal = TerminalConfig {
            canvas_width: if width == 0 { -1 } else { width },
            canvas_height: if height == 0 { -1 } else { height },
            ignore_terminal_dimensions: true,
            existing_color_handling: handling,
            ..TerminalConfig::default()
        };
        let mut e = Engine::new(
            input,
            terminal,
            Rng::seeded(seed),
            Clock::virtual_with_frame_rate(60),
        )
        .ok()?;
        let mut effect = Roses::new(config(args));
        effect.build(&mut e).expect("build");
        let mut frames = 0u64;
        while effect.next_frame(&mut e) {
            e.render_here();
            frames += 1;
            assert!(frames < 1_000_000, "roses does not end");
        }
        let state = (0..e.char_count() as u32)
            .map(|s| (e.is_visible(s), e.coord(s), e.current_visual(s)))
            .collect();
        Some((frames, e, state))
    }

    fn check_final(e: &Engine, dynamic: bool) {
        for &slot in &e.input_chars {
            assert!(e.is_visible(slot));
            assert_eq!(e.coord(slot), e.input_coord(slot));
            let info = e.visual_info(e.current_visual(slot));
            assert_eq!(info.sym, e.input_sym(slot));
            if dynamic {
                assert_eq!(info.fg, e.input_fg(slot));
            }
        }
        for &slot in &e.added_chars {
            assert!(!e.is_visible(slot));
        }
    }

    #[test]
    fn edge_inputs_end_with_the_text() {
        let long = "x".repeat(500);
        let cases: &[(&str, i64, i64)] = &[
            ("OMARCHY\nhello world\n", 0, 0),
            ("x", 0, 0),
            (&long, 0, 0),
            ("OMARCHY\nhello world\n", 10, 3),
            ("a", 1, 1),
            ("日本語テキスト wide ✦\n", 0, 0),
            ("\x1b[38;2;255;0;0mred\x1b[0m text", 0, 0),
            ("big canvas", 200, 50),
        ];
        for &(input, w, h) in cases {
            let (_, e, _) = run(input, w, h, ExistingColorHandling::Ignore, 1, &[])
                .unwrap_or_else(|| panic!("no engine for {input:?}"));
            check_final(&e, false);
        }
    }

    #[test]
    fn dynamic_and_always_keep_input_colors() {
        let input = "\x1b[38;2;255;0;0mred\x1b[0m plain";
        let (_, e, _) = run(input, 0, 0, ExistingColorHandling::Dynamic, 1, &[]).expect("engine");
        check_final(&e, true);
        assert!(e.input_chars.iter().any(|&s| {
            e.visual_info(e.current_visual(s))
                .fg
                .is_some_and(|c| c.rgb_ints() == (255, 0, 0))
        }));
        let (_, e, _) = run(input, 0, 0, ExistingColorHandling::Always, 1, &[]).expect("engine");
        check_final(&e, false);
    }

    #[test]
    fn every_timing_option_moves_the_end() {
        let input = "OMARCHY\nhello";
        let (base, _, _) = run(input, 0, 0, ExistingColorHandling::Ignore, 1, &[]).expect("engine");
        for (option, value) in [
            ("--vine-duration", "10000"),
            ("--bloom-start", "1000"),
            ("--bloom-duration", "1000"),
            ("--bloom-delay", "300"),
            ("--falling-petals", "400"),
            ("--text-bloom-start", "1000"),
            ("--text-bloom-duration", "1000"),
            ("--final-hold-time", "1000"),
            ("--wither-duration", "1000"),
        ] {
            let (frames, e, _) = run(
                input,
                0,
                0,
                ExistingColorHandling::Ignore,
                1,
                &[option, value],
            )
            .expect("engine");
            assert!(frames > base, "{option} does not lengthen the run");
            check_final(&e, false);
        }
    }

    #[test]
    fn same_seed_same_run() {
        let input = "OMARCHY\nhello world";
        let (fa, _, a) = run(input, 40, 10, ExistingColorHandling::Ignore, 3, &[]).expect("engine");
        let (fb, _, b) = run(input, 40, 10, ExistingColorHandling::Ignore, 3, &[]).expect("engine");
        assert_eq!(fa, fb);
        assert_eq!(a, b);
    }

    #[test]
    fn single_colors() {
        let (_, e, _) = run(
            "hi there",
            0,
            0,
            ExistingColorHandling::Ignore,
            1,
            &[
                "--vine-colors",
                "00ff00",
                "--rose-colors",
                "ff0000",
                "--final-gradient-stops",
                "0000ff",
            ],
        )
        .expect("engine");
        check_final(&e, false);
    }
}
